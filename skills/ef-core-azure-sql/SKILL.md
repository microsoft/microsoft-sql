---
name: ef-core-azure-sql
description: >-
  Configures Entity Framework Core against Azure SQL Database, where retry is on by default and
  that redefines a transaction: the execution strategy refuses a user-initiated transaction, and
  the wrapper the exception tells you to write replays the whole unit, so a fault arriving after
  the commit writes the row twice and reports success. Also covers UseAzureSql versus UseSqlServer
  with a hand written EnableRetryOnFailure, the compatibility level behind JSON mapping, and split
  versus single queries. Use when a DbContext targets Azure SQL Database, and when someone asks
  "EnableRetryOnFailure", "connection resiliency for EF Core", "UseAzureSql or UseSqlServer",
  "AsSplitQuery", reports "does not support user-initiated transactions", reports duplicated rows
  after a retry, or asks why a migration retypes JSON columns. Not general EF Core: pooling is
  connect-from-dotnet, connection retry is connect-to-azure-sql, identity is entra-id-auth, and
  the other mappers are prisma-azure-sql and sqlalchemy-azure-sql.
license: MIT
---

# EF Core against Azure SQL Database

This is the Azure SQL Database delta on top of EF Core, not an EF Core tutorial. Modelling, LINQ,
change tracking and `Include` work the same everywhere and are not repeated here.

Verified on 2026-08-27 by compiling and running `Microsoft.EntityFrameworkCore.SqlServer` 9.0.19
against a **live Azure SQL Database engine** (`SERVERPROPERTY('EngineEdition')` returns 5), and by
reading the 10.0.11 assembly metadata. Current releases: **EF Core 10 is the supported long term
release**, EF Core 9 is still serviced, and EF Core 11 is in preview. Every number below came from a
run, and the runs are in [references/verified-behaviour.md](references/verified-behaviour.md).

## The correction

Retry is not a setting on this database. It is on in every current answer: `EnableRetryOnFailure`
in the older corpus shape, `UseAzureSql` in the newer one. Both produce
`SqlServerRetryingExecutionStrategy`, and **turning it on silently redefines what a transaction is.**

The visible half is an exception, and it is not the problem. The problem is what happens after an
agent fixes it, because the exception dictates its own remedy and the remedy is incomplete:

```csharp
// Retry on, so this unit is replayed on a transient fault. Measured: a fault arriving after
// Commit runs the delegate again, inserts the order a SECOND time, and Execute returns
// success. Nothing is thrown. Nothing is logged. The caller is told it worked.
strategy.Execute(() =>
{
    using var tx = context.Database.BeginTransaction();
    context.Orders.Add(order);
    context.SaveChanges();
    tx.Commit();
});
```

**A retriable unit is a unit that will be run more than once.** Retry does not make a transaction
resilient. It makes it repeatable, and a repeatable write that is not idempotent is a duplicate
write waiting for a network fault it was configured to expect.

The choice between `UseAzureSql` and `UseSqlServer` is the small half of this skill. The corpus shape
compiles, runs and retries correctly. It also carries this hazard identically, so switching call
does not fix it and staying on the old call does not cause it.

## What actually refuses, and what does not

Measured on 9.0.19 against the live engine. The commonly repeated claim, that
`Database.BeginTransaction` throws, is wrong.

| Call, with the retrying strategy configured | Result |
|---|---|
| `Database.BeginTransaction()` on its own | **Succeeds.** No exception |
| A LINQ query while that transaction is open | Throws `InvalidOperationException` in about 60 ms |
| `SaveChanges` while that transaction is open | Throws `InvalidOperationException` in about 20 ms |
| `Database.ExecuteSqlRaw` while that transaction is open | **Succeeds.** Not guarded at all |
| `SaveChanges` with no explicit transaction | Succeeds. EF's own transaction is a unit it created |

So the guard fires on EF's own pipeline and not on raw SQL, and it fires on the first execution of
the path rather than under load. The message:

> `InvalidOperationException: The configured execution strategy 'SqlServerRetryingExecutionStrategy'
> does not support user-initiated transactions. Use the execution strategy returned by
> 'DbContext.Database.CreateExecutionStrategy()' to execute all the operations in the transaction as
> a retriable unit.`

Two things follow, and they pull in opposite directions:

- **This exception is cheap.** It is deterministic, it arrives in milliseconds on the first run of
  the path, and it names its own fix. Any test or manual run that touches the transactional path
  finds it. Treat it as a compiler error that happens to arrive late.
- **The fix it names is not the whole fix**, and nothing after it fails loudly. That is the section
  below, and it is why this skill exists.

## The measured duplicate write

Same delegate, same configured strategy, one variable: where the transient fault lands.

| Fault arrives | Delegate runs | Rows committed | What the caller sees |
|---|---|---|---|
| Before `Commit` | 2 | **1** | Success. Correct, the first attempt rolled back |
| After `Commit` | 2 | **2** | Success. **No exception, no warning, no log line** |

The window is the commit acknowledgement. The commit reached the server, the acknowledgement did
not reach the client, and the strategy cannot tell that apart from a commit that never happened, so
it replays a unit that already succeeded. Identical under `UseSqlServer` with `EnableRetryOnFailure`
and under `UseAzureSql`.

This is the blast radius: **a silent double write on a transactional path, in production only, on
exactly the transient faults this database is configured to expect.** Duplicated orders, doubled
ledger entries, a webhook delivered twice. The row is written by the same code the exception told
you to write, and no error is ever raised.

### Making the unit safe to run twice

In order of preference.

1. **Give the write a natural idempotency key** and a unique index, so a replay collides instead of
   duplicating. This is the only defence that survives a process crash between the two attempts.
2. **Hand the transaction to `ExecuteInTransaction` with a `verifySucceeded` predicate.** The
   strategy owns the transaction, and on failure it asks the predicate whether the work already
   landed before it retries. Measured against the same fault, this commits exactly one row:

```csharp
var strategy = context.Database.CreateExecutionStrategy();

await strategy.ExecuteInTransactionAsync(
    operation: async () =>
    {
        context.Orders.Add(order);
        await context.SaveChangesAsync(cancellationToken);
    },
    verifySucceeded: async () =>
    {
        await using var probe = new AppDbContext(options);
        return await probe.Orders.AnyAsync(o => o.IdempotencyKey == order.IdempotencyKey);
    });
```

3. **Only then** the bare `CreateExecutionStrategy().ExecuteAsync` wrapper, and only for units that
   are already safe to run twice. The delegate must not capture entities tracked by an outer
   context, must not generate identifiers before it runs, and must not send an email, enqueue a
   message or charge a card inside it.

The remaining honest answer is that some units cannot be made idempotent, and for those the choice
is to accept the duplicate risk or to narrow the retry set. Do not disable retry to make the
exception go away: that trades one visible error for intermittent production failures.

## What retry costs when it does not help

`UseAzureSql` defaults to 6 retries with a 30 second cap. That is 7 attempts, and measured
end to end a permanently failing operation gives up after **57 seconds**, with attempts starting at
0.0, 0.0, 1.0, 4.1, 11.6, 26.9 and 56.9 seconds.

A request thread is held for that whole minute. Behind a 30 second gateway timeout, the caller has
already given up and the work is still running. Size the retry budget against the deadline of the
thing calling you, and put a `CancellationToken` through every async call so the abandoned work
stops.

## UseAzureSql, and the near miss

From **EF Core 9** there is a call named for this database:

```csharp
options.UseAzureSql(connectionString);
```

It is the current call, and it is worth using. It does **not** delete `EnableRetryOnFailure`; it
changes the default from off to on and leaves the knob.

| | `UseSqlServer` | `UseAzureSql` |
|---|---|---|
| Engine type | `SqlServer` | `AzureSql` |
| Execution strategy | `SqlServerExecutionStrategy`, no retry | `SqlServerRetryingExecutionStrategy`, 6 retries, 30 second cap |
| Default compatibility level, EF Core 9 | 150 | 150 |
| Default compatibility level, EF Core 10 | 150 | **170** |
| Native `json` column type, EF Core 10 | only at level 170 or above | on by default |

- **It is a compile time API.** On EF Core 8 the call does not exist, and the error is
  `error CS1061: 'DbContextOptionsBuilder' does not contain a definition for 'UseAzureSql'`. Upgrade
  the provider package rather than inventing an extension method.
- **`UseAzureSqlDefaults(true)` is not a synonym**, and it is not silent either: on 9.0.19 it is
  marked obsolete and the build says so, `warning CS0618: 'UseAzureSqlDefaults(bool)' is obsolete:
  'Use UseAzureSql instead of UseSqlServer with UseAzureSqlDefaults.'` It installs the retrying
  strategy while leaving the engine type as `SqlServer`, so the type mapping does not follow. Reach
  for it only where `UseSqlServer` is called by code that cannot be changed.
- **Retry numbers are defaults, not overrides.** Supplying `EnableRetryOnFailure(3,
  TimeSpan.FromSeconds(10), null)` alongside `UseAzureSql` replaces the 6 and the 30 seconds. Do
  that with a measured reason, never by copying numbers out of a blog post.

Whether to retry at all is not a question on this database, and that doctrine, including the error a
first connection to a paused database returns, belongs to `connect-to-azure-sql`. **The split is
clean: `connect-to-azure-sql` owns retry at the driver and connection level, this skill owns the EF
Core execution strategy above it, and the transaction semantics that only exist up here.**

## Compatibility level, and the migration nobody expects

On EF Core 10, `UseAzureSql` defaults the compatibility level to **170**, and at 170 the provider
maps JSON to the native `json` column type instead of `nvarchar(max)`.

So a project that already stores JSON, upgrades to EF Core 10 and switches to `UseAzureSql` gets a
**next migration that retypes existing columns**. That is a data movement operation on a live table,
generated by a change that reads as configuration.

1. **Read the generated migration before applying it.** Look for `ALTER COLUMN ... json`.
2. **State the level rather than inheriting it:**
   `options.UseAzureSql(connectionString, o => o.UseCompatibilityLevel(170));`
3. **Pin a column** to `nvarchar(max)` with `HasColumnType` where the retype must wait.

The same level gates the `vector(n)` type, which EF Core 10 surfaces as `SqlVector<float>` and
`EF.Functions.VectorDistance`. Storing embeddings is `vector-search-azure-sql`.

## Type mapping, honestly scoped

Most EF Core type mapping advice applies to any engine this provider talks to and belongs to
`design-azure-sql-schema`. What is different here:

| Mapping | Why it is different here |
|---|---|
| `DateTime` with `HasDefaultValueSql("GETDATE()")` | Azure SQL Database offers no time zone choice. `CURRENT_TIMEZONE()` returns UTC and `GETDATE()` equals `SYSUTCDATETIME()`, on the container and in the cloud alike. A model carried over from an engine on local time changes meaning without changing shape. Prefer `DateTimeOffset`, or `SYSUTCDATETIME()`, and be explicit either way |
| Anything JSON shaped | Retyped by compatibility level, as above |
| `SqlVector<float>` | Needs EF Core 10 and a server supporting the `vector` type. It is **not** gated on the compatibility level, unlike the `json` mapping, so do not raise the level expecting to unlock it |

One belief to correct, because both common tellings of it are wrong. **An indexed `string` with no
`MaxLength` is narrowed to `nvarchar(450)`, and neither the index nor the data fails silently.** The
`CREATE INDEX` succeeds, and the engine then refuses anything longer:
`Msg 2628, String or binary data would be truncated in table '<table>', column '<column>'`. Adding
the index later to a column that already holds longer values fails the same way, on the
`ALTER COLUMN`, so the migration stops rather than trimming the data. Set `HasMaxLength` deliberately
instead of discovering the 450 at deployment.

`decimal` does default to `decimal(18,2)`, and the provider logs that values "will cause values to be
silently truncated". Real, worth fixing with `HasPrecision`, and general EF Core hygiene rather than
an Azure SQL Database behaviour.

## Single and split queries over a wide area network

`Include` of two sibling collections produces a cross product. That is engine independent. **What
changes here is the arithmetic of the fix**, because each extra query is a real network round trip.

- **Prefer split** when the cartesian product is large. Moving duplicated megabytes costs more.
- **Prefer single** for small collections and chatty request paths.
- **Measure.** The break even point moves with row width and with distance.

Split queries are not one consistent read unless wrapped in a snapshot or serializable transaction,
which puts them back under everything above. Slow query triage itself is `diagnose-slow-query`.

## Migrations against a cloud database

Migration doctrine is `schema-migrations-safely`, the declarative alternative is
`sql-database-projects`, and shipping migrations as a discrete deployment step is
`ef-core-migrations-azure-sql`. Only the Azure SQL Database specific parts belong here:

- **`dotnet ef database update` runs from wherever it is invoked**, so that machine needs a server
  firewall rule for its own address and a principal that can change the schema. Neither is the
  application's runtime identity.
- **The database itself is not created by a migration.** That is `provision-azure-sql-db`.
- **Do not migrate from application startup here.** EF Core 9 added a database wide lock, so the
  concurrency objection an agent will recall is out of date. The objection that survives is
  permissions: startup migration means the runtime identity holds schema rights permanently.

## Connecting with an identity rather than a password

Nothing in the `DbContext` changes. `UseAzureSql` takes the same connection string a bare driver
would, so passwordless access stays a connection string concern:

```text
Server=tcp:<your-server>.database.windows.net,1433;Database=<your-database>;Authentication=Active Directory Default;Encrypt=Mandatory;
```

Getting an identity to a working connection is `entra-id-auth`. Packages, authentication modes and
pooling are `connect-from-dotnet`.

## Validation rules

- Every unit passed to `CreateExecutionStrategy().Execute` is safe to run twice: it has an
  idempotency key with a unique index, or it uses `ExecuteInTransaction` with a `verifySucceeded`
  predicate, or a comment records why replay cannot duplicate anything.
- No non idempotent side effect, such as sending mail, enqueuing a message or taking a payment, sits
  inside a retried delegate.
- Every `BeginTransaction` or `BeginTransactionAsync` sits inside a delegate passed to the execution
  strategy, and not the other way round.
- The retry budget is smaller than the deadline of whatever calls the application, and a
  `CancellationToken` reaches every async database call.
- The context is configured with `UseAzureSql`, and the provider package is 9.0 or later.
- If `EnableRetryOnFailure` appears, it carries a stated reason for differing from the defaults.
- The compatibility level is set explicitly, or the team has recorded that the provider default is
  the intended one.
- On EF Core 10, the first migration generated after switching to `UseAzureSql` has been read, and
  any `ALTER COLUMN` retyping a JSON column is deliberate.
- Indexed string properties state `HasMaxLength`, so the 450 is a decision rather than a deployment
  surprise.
- Queries with two or more sibling collection `Include` calls state `AsSplitQuery` or
  `AsSingleQuery`.
- The application's runtime identity has no schema permission, and migrations are applied by a
  separate step with a separate identity.
- No connection string, password or server hostname appears in source.

## Do not

- Do not treat the execution strategy exception as the end of the work. It is the visible half, and
  the silent half is a duplicate write.
- Do not put a hand written `BeginTransaction` and `Commit` inside a retried delegate without an
  idempotency key or a `verifySucceeded` predicate. It compiles, it passes review, and it doubles a
  row on the fault it was configured to expect.
- Do not put non idempotent work inside an execution strategy delegate.
- Do not assume `Database.BeginTransaction` throws. It succeeds, and the next query or `SaveChanges`
  throws. Raw SQL inside that transaction is not guarded at all.
- Do not disable retry to make a transaction error disappear.
- Do not leave the retry budget larger than the caller's timeout, and do not omit the
  `CancellationToken` that lets abandoned work stop.
- Do not claim `UseAzureSql` removes `EnableRetryOnFailure`. It sets its default.
- Do not treat `UseAzureSqlDefaults(true)` as equivalent to `UseAzureSql`. It leaves the engine type
  unchanged, and it is obsolete.
- Do not upgrade to EF Core 10 and switch to `UseAzureSql` in the same change without reading the
  next migration.
- Do not add `AsSplitQuery` everywhere by reflex. Over a network it can cost more than it saves.
- Do not apply migrations from application startup against a cloud database.
- Do not use this skill for Prisma, SQLAlchemy or raw `Microsoft.Data.SqlClient` work.

## References

- [references/verified-behaviour.md](references/verified-behaviour.md): the measured output behind
  every table above, including the two runs that produced one row and two rows from the same
  delegate, and how to reproduce them against a live engine.
- [Connection resiliency](https://learn.microsoft.com/ef/core/miscellaneous/connection-resiliency):
  execution strategies, the transaction rule, and the four documented answers to a commit that fails
  with an unknown outcome. Read it before writing anything transactional.
- [Microsoft SQL Server database provider](https://learn.microsoft.com/ef/core/providers/sql-server/):
  the first party statement of `UseAzureSql`, compatibility levels and automatic connection
  resiliency.
- [Single vs split queries](https://learn.microsoft.com/ef/core/querying/single-split-queries):
  cartesian explosion and every characteristic of split queries.
- [What is new in EF Core 10](https://learn.microsoft.com/ef/core/what-is-new/ef-core-10.0/whatsnew):
  the `json` and `vector` type support and the compatibility level that gates them.
- `connect-to-azure-sql`: retry and transient fault doctrine at the connection level, and pool sizing.
- `connect-from-dotnet`: the driver, packages, encryption defaults and pooling underneath this.
- `entra-id-auth`: getting an identity to a working passwordless connection.
- `design-azure-sql-schema`: key lengths, string sizing, collation and the rest of schema design.
- `schema-migrations-safely` and `ef-core-migrations-azure-sql`: how migrations reach a database.
