# Retry, transactions and type mapping: what was measured, and how to measure it again

## Contents

- [Why this file exists](#why-this-file-exists)
- [Versions in play on the verification date](#versions-in-play-on-the-verification-date)
- [Reproducing the measurements](#reproducing-the-measurements)
- [Measurement 1: the duplicate write, which is the headline](#measurement-1-the-duplicate-write-which-is-the-headline)
- [Measurement 2: what the execution strategy actually refuses](#measurement-2-what-the-execution-strategy-actually-refuses)
- [Measurement 3: what retry costs when it does not help](#measurement-3-what-retry-costs-when-it-does-not-help)
- [Measurement 4: UseAzureSql exists only from EF Core 9](#measurement-4-useazuresql-exists-only-from-ef-core-9)
- [Measurement 5: the four ways to reach a retrying strategy](#measurement-5-the-four-ways-to-reach-a-retrying-strategy)
- [Measurement 6: compatibility level defaults](#measurement-6-compatibility-level-defaults)
- [Measurement 7: what an unconfigured model maps to, and what the engine then does](#measurement-7-what-an-unconfigured-model-maps-to-and-what-the-engine-then-does)
- [Measurement 8: the server clock](#measurement-8-the-server-clock)
- [Measurement 9: the dotnet ef tool runs, 2026-09-03](#measurement-9-the-dotnet-ef-tool-runs-2026-09-03)
- [What was not verified by execution](#what-was-not-verified-by-execution)
- [Claims this file previously got wrong](#claims-this-file-previously-got-wrong)

## Why this file exists

Every table in `SKILL.md` came from a compiler or a running process rather than from a
documentation page, because the questions are about API surface, defaults and runtime behaviour,
which go stale between a release and the article describing it. This file records what was run so
the claims can be rechecked against a version that did not exist on the verification date.

Runtime behaviour: **2026-08-27**, against a live engine. Tool and compiler output: **2026-09-03**,
in measurement 9.

## Versions in play on the verification date

| Package or product | Version |
|---|---|
| `Microsoft.EntityFrameworkCore.SqlServer`, latest supported long term release | 10.0.11 |
| `Microsoft.EntityFrameworkCore.SqlServer`, latest EF Core 9 patch | 9.0.19 |
| `Microsoft.EntityFrameworkCore.SqlServer`, next release | 11.0.0 preview |
| Versions compiled | 8.0.11 and 9.0.19 |
| Version executed against an engine | 9.0.19 |
| Version read as assembly metadata only | 10.0.11 |
| Engine the runtime measurements ran against | Azure SQL Database container, `EngineEdition` 5, `Edition` `SQL Azure`, `ProductVersion` 12.0.2000.8 |

EF Core 10 requires the .NET 10 runtime, so on a host with an earlier software development kit it
can be inspected but not executed. Its public surface was read with a metadata load context, which
needs no matching runtime.

## Reproducing the measurements

```bash
dotnet new console -o efprobe
cd efprobe
dotnet add package Microsoft.EntityFrameworkCore.SqlServer --version 9.0.19
```

The API level measurements need no database: `CreateExecutionStrategy` and the model builder never
open a connection. Measurements 1, 2, 3, 7 and 8 need a reachable Azure SQL engine, which is what
the local container is for.

A transient fault cannot be summoned on demand, so it is **simulated by declaring an error number
transient**. `EnableRetryOnFailure` takes a list of additional error numbers, and `RAISERROR` with a
message string raises 50000, so:

```csharp
options.UseAzureSql(connectionString, o => o.EnableRetryOnFailure(3, TimeSpan.FromSeconds(1), new[] { 50000 }));

using var context = new AppDbContext(options.Options);
context.Database.ExecuteSqlRaw("RAISERROR('dropped', 16, 1)");
```

makes the strategy treat that statement as a transient failure and retry the unit. The retry
machinery under test is the real one; only the classification of the error is arranged.

## Measurement 1: the duplicate write, which is the headline

One delegate, handed to `CreateExecutionStrategy().Execute`, containing a hand written
`BeginTransaction`, a `SaveChanges` and a `Commit`. The only variable is where the simulated
transient fault lands.

| Fault arrives | Delegate runs | Rows committed | What `Execute` returned |
|---|---|---|---|
| Before `Commit` | 2 | 1 | success |
| After `Commit` | 2 | **2** | **success** |

Captured output:

```text
fault BEFORE commit: Execute returned SUCCESS, delegate ran 2x, rows = 1
fault AFTER  commit: Execute returned SUCCESS, delegate ran 2x, rows = 2
```

The same shape under the corpus configuration, `UseSqlServer` with `EnableRetryOnFailure`, is
identical:

```text
Execute returned SUCCESS
delegate ran 2x, rows = 2
```

So the hazard is a property of retry, not of `UseAzureSql`. The window is the commit
acknowledgement: the commit reached the server, the acknowledgement did not reach the client, and
the strategy cannot distinguish that from a commit that never happened.

The guarded form, `ExecuteInTransaction` with a `verifySucceeded` predicate, was run against the
same fault and committed exactly one row:

```text
ExecuteInTransaction returned after 2 delegate runs
rows committed = 1
```

## Measurement 2: what the execution strategy actually refuses

On 9.0.19 against the live engine, with the retrying strategy configured:

```text
BeginTransaction alone                           OK (11 ms)
BeginTransaction then a LINQ query               THREW InvalidOperationException (63 ms)
BeginTransaction then SaveChanges                THREW InvalidOperationException (20 ms)
BeginTransaction then ExecuteSqlRaw only         OK (25 ms)
no transaction, SaveChanges                      OK (38 ms)
```

Three things this settles:

- **`Database.BeginTransaction` does not throw.** The common telling of this trap, repeated by the
  previous revision of `SKILL.md`, puts the exception on that call. It is on the first EF operation
  performed while the transaction is open.
- **Raw SQL is not guarded.** `ExecuteSqlRaw` inside a user-initiated transaction is permitted.
- **The refusal is immediate and deterministic**, tens of milliseconds on the first execution of the
  path, so it is not a load-dependent failure and any run of the path finds it.

The message, captured rather than quoted:

```text
The configured execution strategy 'SqlServerRetryingExecutionStrategy' does not support
user-initiated transactions. Use the execution strategy returned by
'DbContext.Database.CreateExecutionStrategy()' to execute all the operations in the transaction as
a retriable unit.
```

It names a remedy and says nothing about idempotency, which is measurement 1.

## Measurement 3: what retry costs when it does not help

At the `UseAzureSql` defaults, 6 retries with a 30 second cap, against an operation that fails every
time:

```text
RetryLimitExceededException after 7 attempts, 56.9 s total
attempt start times (s): 0.0, 0.0, 1.0, 4.1, 11.6, 26.9, 56.9
```

Seven attempts, so the delays are roughly 0, 1, 3, 7.5, 15 and 30 seconds, the last one at the cap.
One failing operation holds a thread for the better part of a minute.

## Measurement 4: UseAzureSql exists only from EF Core 9

Against 8.0.11, `optionsBuilder.UseAzureSql(...)` does not compile:

```text
error CS1061: 'DbContextOptionsBuilder' does not contain a definition for 'UseAzureSql'
and no accessible extension method 'UseAzureSql' accepting a first argument of type
'DbContextOptionsBuilder' could be found
```

Against 9.0.0, 9.0.19 and 10.0.11 the method is present on
`SqlServerDbContextOptionsExtensions`, in eight overloads that mirror the `UseSqlServer` set exactly.
The options builder handed to the callback is `AzureSqlDbContextOptionsBuilder`. It carries
`EnableRetryOnFailure` in four overloads and `UseCompatibilityLevel(int)`. `UseAzureSql` therefore
**defaults** retry rather than removing the knob.

## Measurement 5: the four ways to reach a retrying strategy

All measured on 9.0.19. The engine type column is the one that gets overlooked.

| Configuration | Engine type | Strategy | Retry count and cap |
|---|---|---|---|
| `UseAzureSql(cs)` | `AzureSql` | retrying | 6, 30 seconds |
| `UseAzureSql(cs, o => o.EnableRetryOnFailure(3, TimeSpan.FromSeconds(10), null))` | `AzureSql` | retrying | 3, 10 seconds |
| `UseSqlServer(cs, o => o.UseAzureSqlDefaults(true))` | **`SqlServer`** | retrying | 6, 30 seconds |
| `UseSqlServer(cs, o => o.EnableRetryOnFailure(6, TimeSpan.FromSeconds(30), null))` | **`SqlServer`** | retrying | 6, 30 seconds |

Captured:

```text
UseSqlServer                       engine=SqlServer strategy=SqlServerExecutionStrategy retries=False
UseAzureSql                        engine=AzureSql  strategy=SqlServerRetryingExecutionStrategy retries=True
                                   MaxRetryCount=6 MaxRetryDelay=00:00:30
UseSqlServer+UseAzureSqlDefaults   engine=SqlServer strategy=SqlServerRetryingExecutionStrategy retries=True
                                   MaxRetryCount=6 MaxRetryDelay=00:00:30
```

## Measurement 6: compatibility level defaults

Read from the provider's own options on 9.0.19, and from the 10.0 source constants:

```text
UseSqlServer: EngineType=SqlServer  SqlServerCompatibilityLevel=150  AzureSqlCompatibilityLevel=150
UseAzureSql:  EngineType=AzureSql   SqlServerCompatibilityLevel=150  AzureSqlCompatibilityLevel=150
```

For 10.0.11 the defaults are static readonly fields rather than literals, so they were decoded from
the type initializer of `SqlServerOptionsExtension` in the shipped assembly:

```text
SqlServerDefaultCompatibilityLevel = 150
AzureSqlDefaultCompatibilityLevel = 170
AzureSynapseDefaultCompatibilityLevel = 30
```

| Provider version | `UseSqlServer` default | `UseAzureSql` default |
|---|---|---|
| 9.0.19 | 150 | 150 |
| 10.0.11 | 150 | **170** |

Level 170 is the gate on the native `json` mapping, and on that alone. **It does not gate
`SqlVector<float>`.** That last point is read from the provider's type mapping source, where the
type resolves with no compatibility check of any kind, and not measured here: it depends on EF Core
10 and on the server supporting the `vector` type, and raising the level does not unlock it.

## Measurement 7: what an unconfigured model maps to, and what the engine then does

An entity with no explicit configuration and one index on a string property, on 9.0.19:

```sql
CREATE TABLE [Blogs] (
    [Id] int NOT NULL IDENTITY,
    [Name] nvarchar(450) NOT NULL,
    [Price] decimal(18,2) NOT NULL,
    [CreatedAt] datetime2 NOT NULL,
    [Contact] nvarchar(max) NOT NULL,
    CONSTRAINT [PK_Blogs] PRIMARY KEY ([Id])
);
CREATE INDEX [IX_Blogs_Name] ON [Blogs] ([Name]);
```

`Name` is `nvarchar(450)`, not `nvarchar(max)`: indexing a string property narrows it. The question
the previous revision answered wrongly is what happens next. Inserting 500 characters through
`SaveChanges`:

```text
actual column type: Name nvarchar(450)
THREW DbUpdateException: Msg 2628 / String or binary data would be truncated in table
'appdb.dbo.Blogs', column 'Name'.
```

And adding the index later, over a column that already holds 600 characters:

```text
ALTER THREW Msg 2628: String or binary data would be truncated in table 'appdb.dbo.Wide',
column 'Name'. The statement has been terminated.
```

So **neither the write nor the migration is silent**. The `CREATE INDEX` succeeds and the engine
refuses the data, at insert time and at `ALTER COLUMN` time alike. The correct advice is to set
`HasMaxLength` deliberately, not to fear silent data loss.

`Price` is `decimal(18,2)`, and the provider carries a warning whose exact text is: "No store type
was specified for the decimal property '{property}' on entity type '{entityType}'. This will cause
values to be silently truncated if they do not fit in the default precision and scale." Provider
behaviour rather than Azure SQL Database behaviour.

## Measurement 8: the server clock

On the container, from the same session as the rest:

```text
GETDATE()              = Aug 28 2026  5:36AM
SYSUTCDATETIME()       = 2026-08-28 05:36:37.3657578
SYSDATETIMEOFFSET()    = 2026-08-28 05:36:37.3746771 +00:00
CURRENT_TIMEZONE()     = (UTC) Coordinated Universal Time
host local now         = 8/27/2026 11:36:37 PM
```

The host was six hours behind, and `GETDATE()` returned the UTC time, so the container agrees with
the cloud rather than with the machine running it. A `GETDATE()` default therefore behaves the same
locally and in Azure, and only a model carried over from an engine running on local time changes
meaning.

## Measurement 9: the dotnet ef tool runs, 2026-09-03

Host: .NET SDK 8.0.421, `dotnet ef` 9.0.19 installed with
`dotnet tool install --global dotnet-ef --version 9.0.19`, provider package 9.0.19. EF Core 9
targets `net8.0`, so `UseAzureSql` is reachable from an SDK 8 host.

The fixture: a console project with one entity carrying a non-unique index on a `string` property,
a unique index on a `Guid` key, and a `string[]` collection property.

**`dotnet ef dbcontext info` is the only command that prints the engine type.** Under
`options.UseAzureSql(...)`:

```text
Type: AppDbContext
Provider name: Microsoft.EntityFrameworkCore.SqlServer
Database name: appdb
Data source: tcp:127.0.0.1,1433
Options: EngineType=AzureSql
```

Changing that one call to `options.UseSqlServer(...)`, with nothing else touched, and rerunning:

```text
Options: EngineType=SqlServer
```

The provider name is identical in both, and so is the connection string. That line is the only
thing that tells the two configurations apart.

**`dotnet ef migrations has-pending-model-changes` carries its answer in the exit code.**

```text
$ dotnet ef migrations has-pending-model-changes ; echo $?
No changes have been made to the model since the last migration.
0
$ dotnet ef migrations has-pending-model-changes ; echo $?
Changes have been made to the model since the last migration. Add a new migration.
1
```

The second run followed adding one property to the entity and nothing else. Exit 1 is usable in CI.

**The generated script, from `dotnet ef migrations script --idempotent --output migrate.sql`**, on
EF Core 9:

```text
[Name] nvarchar(450) NOT NULL,
[Tags] nvarchar(max) NOT NULL,
CREATE UNIQUE INDEX [IX_Orders_IdempotencyKey] ON [Orders] ([IdempotencyKey]);
CREATE INDEX [IX_Orders_Name] ON [Orders] ([Name]);
```

`Name` is the indexed string, narrowed to 450, confirming measurement 7 on a second host. `Tags` is
the `string[]`, `nvarchar(max)` on EF Core 9, and it is exactly the column EF Core 10 with
`UseAzureSql` retypes to `json`.

**Compiler results on 9.0.19**, three configurations built in one project:

```text
warning CS0618: 'SqlServerDbContextOptionsBuilder.UseAzureSqlDefaults(bool)' is obsolete:
'Use UseAzureSql instead of UseSqlServer with UseAzureSqlDefaults.'
```

That is the only diagnostic in the build. `ConfigureSqlEngine(c => c.EnableRetryOnFailureByDefault())`,
which Microsoft Learn gives as the EF Core 9 answer for a `UseSqlServer` call you do not control,
compiled with no warning, and so did `UseAzureSql(cs, o => o.UseCompatibilityLevel(170))` and the
`ExecuteInTransactionAsync(db, operation:, verifySucceeded:, cancellationToken:)` form quoted in
`SKILL.md`.

## What was not verified by execution

Stated so that nobody reads this file as more than it is.

- **EF Core 10 was read, not run.** Its public surface and its compatibility level constants are
  first hand, decoded from the 10.0.11 assembly on this host; its runtime behaviour is taken from
  the release notes.
- **The `SqlVector<float>` gating claim is a source reading**, carried forward from the previous
  revision, not something this host executed.
- **Measurement 9 opened no connection.** `dbcontext info`, `migrations script` and
  `has-pending-model-changes` are design-time commands; the server on the connection string was not
  running.
- **The JSON retype on first migration** is quoted from the EF Core 10 release notes, which state
  that existing `nvarchar` JSON columns are changed to `json` by the first migration, and name the
  two ways to opt out. It was not observed against a database.
- **The transient fault was simulated**, by declaring error 50000 retriable, rather than produced by
  a real network partition. The retry machinery, the delegate replay and the row counts are real.
- **The single and split query trade-off was not benchmarked.** It is a latency argument, and this
  measurement host is a container on the same machine, which is the one topology where the argument
  does not apply.

## Claims this file previously got wrong

Kept rather than deleted, because a reference file that quietly rewrites itself teaches nothing.

- **"No live database was involved."** True of the previous revision, and it is what allowed the two
  errors below. An engine that would not start was accepted as a reason to quote documentation.
- **"Indexing a string property narrows it silently, and the silent narrowing is what truncates
  data."** Wrong. The narrowing is real, the truncation is not silent: the engine raises Msg 2628.
- **The exception was placed on `Database.BeginTransaction`.** Wrong. That call succeeds, and the
  next EF operation inside the transaction is what throws.
