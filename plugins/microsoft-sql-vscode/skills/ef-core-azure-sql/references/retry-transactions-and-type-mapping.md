# Retry, transactions and type mapping: checks you can run

## Contents

- [Setup](#setup)
- [A fault after Commit duplicates the write](#a-fault-after-commit-duplicates-the-write)
- [What the execution strategy refuses](#what-the-execution-strategy-refuses)
- [What retry costs when it does not help](#what-retry-costs-when-it-does-not-help)
- [UseAzureSql exists only from EF Core 9](#useazuresql-exists-only-from-ef-core-9)
- [The four ways to reach a retrying strategy](#the-four-ways-to-reach-a-retrying-strategy)
- [Compatibility level defaults](#compatibility-level-defaults)
- [What an unconfigured model maps to, and what the engine then does](#what-an-unconfigured-model-maps-to-and-what-the-engine-then-does)
- [The server clock is UTC](#the-server-clock-is-utc)
- [What the dotnet ef tool prints](#what-the-dotnet-ef-tool-prints)
- [Claims that do not hold](#claims-that-do-not-hold)

The tables in `SKILL.md` are about API surface, defaults and runtime behaviour, which go stale
between a release and the article describing it. Rerun these checks against the provider version
you have.

## Setup

```bash
dotnet new console -o efprobe
cd efprobe || exit 1
dotnet add package Microsoft.EntityFrameworkCore.SqlServer --version 9.0.19
```

The API level checks need no database: `CreateExecutionStrategy` and the model builder never open a
connection. The duplicate write, the refusals, the retry cost, the type mapping and the server clock
need a reachable Azure SQL engine, and the local Azure SQL Database container is enough for them.
It is not enough for the single and split query trade-off in `SKILL.md`, which is a latency
argument: with the engine on the same machine as the client, that trade-off does not show. EF Core
10 requires the .NET 10 runtime.

A transient fault cannot be summoned on demand, so **simulate one by declaring an error number
transient**. `EnableRetryOnFailure` takes a list of additional error numbers, and `RAISERROR` with a
message string raises 50000, so:

```csharp
options.UseAzureSql(connectionString, o => o.EnableRetryOnFailure(3, TimeSpan.FromSeconds(1), new[] { 50000 }));

using var context = new AppDbContext(options.Options);
context.Database.ExecuteSqlRaw("RAISERROR('dropped', 16, 1)");
```

makes the strategy treat that statement as a transient failure and retry the unit. The retry
machinery is the real one; only the classification of the error is arranged.

## A fault after Commit duplicates the write

Hand one delegate to `CreateExecutionStrategy().Execute`, containing a hand written
`BeginTransaction`, a `SaveChanges` and a `Commit`, and vary only where the simulated transient
fault lands. When it lands after `Commit`, the delegate runs again, a second row is committed, and
`Execute` still returns success.

| Fault arrives | Delegate runs | Rows committed | What `Execute` returned |
|---|---|---|---|
| Before `Commit` | 2 | 1 | success |
| After `Commit` | 2 | **2** | **success** |

The result:

```text
fault BEFORE commit: Execute returned SUCCESS, delegate ran 2x, rows = 1
fault AFTER  commit: Execute returned SUCCESS, delegate ran 2x, rows = 2
```

The same shape under the older configuration, `UseSqlServer` with `EnableRetryOnFailure`, is
identical:

```text
Execute returned SUCCESS
delegate ran 2x, rows = 2
```

So the hazard is a property of retry, not of `UseAzureSql`. The window is the commit
acknowledgement: the commit reached the server, the acknowledgement did not reach the client, and
the strategy cannot distinguish that from a commit that never happened.

The guarded form, `ExecuteInTransaction` with a `verifySucceeded` predicate, commits exactly one row
under the same fault:

```text
ExecuteInTransaction returned after 2 delegate runs
rows committed = 1
```

## What the execution strategy refuses

With EF Core 9 and the retrying strategy configured:

```text
BeginTransaction alone                           OK
BeginTransaction then a LINQ query               THREW InvalidOperationException
BeginTransaction then SaveChanges                THREW InvalidOperationException
BeginTransaction then ExecuteSqlRaw only         OK
no transaction, SaveChanges                      OK
```

Three things follow:

- **`Database.BeginTransaction` does not throw.** The common telling of this trap puts the exception
  on that call. It is on the first EF operation performed while the transaction is open.
- **Raw SQL is not guarded.** `ExecuteSqlRaw` inside a user-initiated transaction is permitted.
- **The refusal is immediate and deterministic**, tens of milliseconds on the first execution of the
  path, so it is not a load-dependent failure and any run of the path finds it.

The message in full:

```text
The configured execution strategy 'SqlServerRetryingExecutionStrategy' does not support
user-initiated transactions. Use the execution strategy returned by
'DbContext.Database.CreateExecutionStrategy()' to execute all the operations in the transaction as
a retriable unit.
```

It names a remedy and says nothing about idempotency, which is
[the duplicate write above](#a-fault-after-commit-duplicates-the-write).

## What retry costs when it does not help

At the `UseAzureSql` defaults, 6 retries with a 30 second cap, an operation that fails every time
ends like this:

```text
RetryLimitExceededException after 7 attempts, 56.9 s total
attempt start times (s): 0.0, 0.0, 1.0, 4.1, 11.6, 26.9, 56.9
```

Seven attempts, so the delays are roughly 0, 1, 3, 7.5, 15 and 30 seconds, the last one at the cap.
One failing operation holds a thread for the better part of a minute.

## UseAzureSql exists only from EF Core 9

On EF Core 8, `optionsBuilder.UseAzureSql(...)` does not compile:

```text
error CS1061: 'DbContextOptionsBuilder' does not contain a definition for 'UseAzureSql'
and no accessible extension method 'UseAzureSql' accepting a first argument of type
'DbContextOptionsBuilder' could be found
```

From EF Core 9.0.0 on, EF Core 10 included, the method is present on
`SqlServerDbContextOptionsExtensions`, in eight overloads that mirror the `UseSqlServer` set exactly.
The options builder handed to the callback is `AzureSqlDbContextOptionsBuilder`. It carries
`EnableRetryOnFailure` in four overloads and `UseCompatibilityLevel(int)`. `UseAzureSql` therefore
**defaults** retry rather than removing the knob.

## The four ways to reach a retrying strategy

On EF Core 9. The engine type column is the one that gets overlooked.

| Configuration | Engine type | Strategy | Retry count and cap |
|---|---|---|---|
| `UseAzureSql(cs)` | `AzureSql` | retrying | 6, 30 seconds |
| `UseAzureSql(cs, o => o.EnableRetryOnFailure(3, TimeSpan.FromSeconds(10), null))` | `AzureSql` | retrying | 3, 10 seconds |
| `UseSqlServer(cs, o => o.UseAzureSqlDefaults(true))` | **`SqlServer`** | retrying | 6, 30 seconds |
| `UseSqlServer(cs, o => o.EnableRetryOnFailure(6, TimeSpan.FromSeconds(30), null))` | **`SqlServer`** | retrying | 6, 30 seconds |

Reading the configured options back:

```text
UseSqlServer                       engine=SqlServer strategy=SqlServerExecutionStrategy retries=False
UseAzureSql                        engine=AzureSql  strategy=SqlServerRetryingExecutionStrategy retries=True
                                   MaxRetryCount=6 MaxRetryDelay=00:00:30
UseSqlServer+UseAzureSqlDefaults   engine=SqlServer strategy=SqlServerRetryingExecutionStrategy retries=True
                                   MaxRetryCount=6 MaxRetryDelay=00:00:30
```

## Compatibility level defaults

The provider's own options on EF Core 9:

```text
UseSqlServer: EngineType=SqlServer  SqlServerCompatibilityLevel=150  AzureSqlCompatibilityLevel=150
UseAzureSql:  EngineType=AzureSql   SqlServerCompatibilityLevel=150  AzureSqlCompatibilityLevel=150
```

In EF Core 10 the defaults are static readonly fields rather than literals, set in the type
initializer of `SqlServerOptionsExtension`:

```text
SqlServerDefaultCompatibilityLevel = 150
AzureSqlDefaultCompatibilityLevel = 170
AzureSynapseDefaultCompatibilityLevel = 30
```

| Provider version | `UseSqlServer` default | `UseAzureSql` default |
|---|---|---|
| EF Core 9 | 150 | 150 |
| EF Core 10 | 150 | **170** |

Level 170 is the gate on the native `json` mapping, and on that alone. The EF Core 10 release notes
state that the first migration after the upgrade changes existing `nvarchar` JSON columns to `json`,
and name the two ways to opt out. **Level 170 does not gate `SqlVector<float>`.** In the provider's
type mapping source the type resolves with no compatibility check of any kind: it depends on EF
Core 10 and on the server supporting the `vector` type, and raising the level does not unlock it.

## What an unconfigured model maps to, and what the engine then does

An entity with no explicit configuration and one index on a string property, on EF Core 9:

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

`Name` is `nvarchar(450)`, not `nvarchar(max)`: indexing a string property narrows it. What matters
is what happens next. Insert 500 characters through `SaveChanges`:

```text
actual column type: Name nvarchar(450)
THREW DbUpdateException: Msg 2628 / String or binary data would be truncated in table
'appdb.dbo.Blogs', column 'Name'.
```

Add the index later, over a column that already holds 600 characters:

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

## The server clock is UTC

Run this in the local Azure SQL Database container, from a host whose own clock is not on UTC:

```sql
SELECT GETDATE(), SYSUTCDATETIME(), SYSDATETIMEOFFSET(), CURRENT_TIMEZONE();
```

`GETDATE()` returns the UTC time, the same as `SYSUTCDATETIME()`, `SYSDATETIMEOFFSET()` ends in
`+00:00`, and `CURRENT_TIMEZONE()` returns `(UTC) Coordinated Universal Time`. The container agrees
with the cloud rather than with the machine running it. A `GETDATE()` default therefore behaves the
same locally and in Azure, and only a model carried over from an engine running on local time
changes meaning.

## What the dotnet ef tool prints

Install the tool to match the provider package, with
`dotnet tool install --global dotnet-ef --version 9.0.19`. EF Core 9 targets `net8.0`, so
`UseAzureSql` is reachable from a .NET 8 SDK. The output below comes from a console project with one
entity carrying a non-unique index on a `string` property, a unique index on a `Guid` key, and a
`string[]` collection property. `dbcontext info`, `migrations script` and
`has-pending-model-changes` are design-time commands and open no connection, so the server on the
connection string does not need to be running.

**`dotnet ef dbcontext info` is the only command that prints the engine type.** Under
`options.UseAzureSql(...)`:

```text
Type: AppDbContext
Provider name: Microsoft.EntityFrameworkCore.SqlServer
Database name: appdb
Data source: tcp:127.0.0.1,1433
Options: EngineType=AzureSql
```

Change that one call to `options.UseSqlServer(...)`, with nothing else touched, and rerun:

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

The second result follows adding one property to the entity and nothing else. Exit 1 is usable in
CI.

**The generated script, from `dotnet ef migrations script --idempotent --output migrate.sql`**, on
EF Core 9:

```text
[Name] nvarchar(450) NOT NULL,
[Tags] nvarchar(max) NOT NULL,
CREATE UNIQUE INDEX [IX_Orders_IdempotencyKey] ON [Orders] ([IdempotencyKey]);
CREATE INDEX [IX_Orders_Name] ON [Orders] ([Name]);
```

`Name` is the indexed string, narrowed to 450, as in
[the unconfigured model above](#what-an-unconfigured-model-maps-to-and-what-the-engine-then-does).
`Tags` is the `string[]`, `nvarchar(max)` on EF Core 9, and it is exactly the column EF Core 10 with
`UseAzureSql` retypes to `json`.

**Compiler results on EF Core 9**, three configurations built in one project:

```text
warning CS0618: 'SqlServerDbContextOptionsBuilder.UseAzureSqlDefaults(bool)' is obsolete:
'Use UseAzureSql instead of UseSqlServer with UseAzureSqlDefaults.'
```

That is the only diagnostic in the build. `ConfigureSqlEngine(c => c.EnableRetryOnFailureByDefault())`,
which Microsoft Learn gives as the EF Core 9 answer for a `UseSqlServer` call you do not control,
compiles with no warning, and so do `UseAzureSql(cs, o => o.UseCompatibilityLevel(170))` and the
`ExecuteInTransactionAsync(db, operation:, verifySucceeded:, cancellationToken:)` form quoted in
`SKILL.md`.

## Claims that do not hold

- **"Indexing a string property narrows it silently, and the silent narrowing is what truncates
  data."** Wrong. The narrowing is real, the truncation is not silent: the engine raises Msg 2628.
- **"`Database.BeginTransaction` throws under a retrying strategy."** Wrong. That call succeeds,
  and the next EF operation inside the transaction is what throws.
