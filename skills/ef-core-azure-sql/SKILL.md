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
  the other object relational mappers have skills of their own.
---

# EF Core against Azure SQL Database

This is the Azure SQL Database delta on top of EF Core, not an EF Core tutorial. Modelling, LINQ,
change tracking and `Include` work the same everywhere and are not repeated here.

Command output and compiler results below were captured 2026-09-03 on
`Microsoft.EntityFrameworkCore.SqlServer` 9.0.19 with `dotnet ef` 9.0.19 on .NET SDK 8.0.421.
Runtime behaviour was measured 2026-08-27 against a live engine reporting `EngineEdition` 5.
EF Core 10 is the supported long term release and EF Core 9 is still serviced.
Open [references/retry-transactions-and-type-mapping.md](references/retry-transactions-and-type-mapping.md) when a
number below disagrees with what you are seeing, or before reproducing a run.

## The correction

Retry is not a setting on this database. It is on in every current answer: `EnableRetryOnFailure`
in the older corpus shape, `UseAzureSql` in the newer one. Both produce
`SqlServerRetryingExecutionStrategy`, and **turning it on silently redefines what a transaction
is.** The visible half is an exception, and it is not the problem. The problem is what an agent
writes next, because the exception dictates its own remedy and the remedy is incomplete:

```csharp
// Retry on, so this unit is replayed on a transient fault. Measured: a fault arriving after
// Commit runs the delegate again, inserts the order a SECOND time, and Execute returns
// success. Nothing is thrown. Nothing is logged. The caller is told it worked.
var strategy = context.Database.CreateExecutionStrategy();
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
write waiting for a network fault it was configured to expect. Both call shapes carry this
identically, so switching call does not fix it and staying on the old call does not cause it.

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

The guard fires on EF's own pipeline, not on raw SQL, and on the first execution of the path rather
than under load:

> `InvalidOperationException: The configured execution strategy 'SqlServerRetryingExecutionStrategy'
> does not support user-initiated transactions. Use the execution strategy returned by
> 'DbContext.Database.CreateExecutionStrategy()' to execute all the operations in the transaction as
> a retriable unit.`

**This exception is cheap**: deterministic, milliseconds, on the first run of the path, and it names
its own fix. Treat it as a compiler error that arrives late. **The fix it names is not the whole
fix**, and nothing after it fails loudly. That is the next section, and it is why this skill exists.

## The measured duplicate write

Same delegate, same configured strategy, one variable: where the transient fault lands.

| Fault arrives | Delegate runs | Rows committed | What the caller sees |
|---|---|---|---|
| Before `Commit` | 2 | **1** | Success. Correct, the first attempt rolled back |
| After `Commit` | 2 | **2** | Success. **No exception, no warning, no log line** |

The window is the commit acknowledgement. The commit reached the server, the acknowledgement did
not reach the client, and the strategy cannot tell that apart from a commit that never happened, so
it replays a unit that already succeeded. Learn calls this the idempotency issue and says it can
lead to data corruption. The blast radius is a silent double write on a transactional path, in
production only, on exactly the transient faults this database is configured to expect.

### Making the unit safe to run twice

In order of preference.

1. **Give the write a natural idempotency key and a unique index**, so a replay collides with
   `Msg 2601` instead of duplicating. This is the only defence that survives a process crash
   between the two attempts.
2. **Hand the transaction to `ExecuteInTransaction` with a `verifySucceeded` predicate.** The
   strategy owns the transaction and, when the commit fails with an unknown outcome, asks the
   predicate whether the work already landed before retrying:

```csharp
var strategy = db.Database.CreateExecutionStrategy();
db.Orders.Add(order);

await strategy.ExecuteInTransactionAsync(
    db,
    operation: (context, cancellationToken) =>
        context.SaveChangesAsync(acceptAllChangesOnSuccess: false, cancellationToken),
    verifySucceeded: (context, cancellationToken) =>
        context.Orders.AsNoTracking().AnyAsync(o => o.Key == order.Key, cancellationToken),
    cancellationToken: ct);

db.ChangeTracker.AcceptAllChanges();
```

`acceptAllChangesOnSuccess: false` is load bearing, not decoration: it leaves the entity `Added` so
the same unit can be replayed if the commit is what failed, and `AcceptAllChanges` afterwards is
what finishes the save. The verifying context needs its own execution strategy, because the
connection that just failed is likely to fail again during the check.

3. **Only then** the bare `CreateExecutionStrategy().ExecuteAsync` wrapper, and only for units that
   are already safe to run twice. The delegate must not capture entities tracked by an outer
   context, must not rely on store generated keys, and must not send an email, enqueue a message or
   charge a card inside it.

Some units cannot be made idempotent, and for those the choice is to accept the duplicate risk or
to narrow the retry set, never to disable retry so the exception goes away.

## What retry costs when it does not help

`UseAzureSql` defaults to 6 retries with a 30 second cap, so 7 attempts, and measured end to end a
permanently failing operation gives up after **57 seconds**, with attempts starting at 0.0, 0.0,
1.0, 4.1, 11.6, 26.9 and 56.9 seconds. A request thread is held for that whole minute, and behind a
30 second gateway timeout the caller has already given up. Size the retry budget against the
deadline of the thing calling you, and put a `CancellationToken` through every async call.

## UseAzureSql, and the near miss

From **EF Core 9** there is a call named for this database, and Learn's own Azure SQL Database tab
uses it. It does **not** delete `EnableRetryOnFailure`; it changes the default from off to on:

```csharp
options.UseAzureSql(connectionString, o => o.UseCompatibilityLevel(170));
```

| | `UseSqlServer` | `UseAzureSql` |
|---|---|---|
| Engine type | `SqlServer` | `AzureSql` |
| Execution strategy | `SqlServerExecutionStrategy`, no retry | `SqlServerRetryingExecutionStrategy`, 6 retries, 30 second cap |
| Default compatibility level, EF Core 9 | 150 | 150 |
| Default compatibility level, EF Core 10 | 150 | **170** |
| Native `json` column type, EF Core 10 | only at level 170 or above | on by default |

- **It is a compile time API.** On EF Core 8 the call does not exist and the build says
  `error CS1061: 'DbContextOptionsBuilder' does not contain a definition for 'UseAzureSql'`.
  Upgrade the provider package rather than inventing an extension method.
- **When `UseSqlServer` is called by code you cannot change**, EF Core 9 has a first party answer
  that is not obsolete, and it compiled clean here: `options.ConfigureSqlEngine(c =>
  c.EnableRetryOnFailureByDefault());`. `UseSqlServer(cs, o => o.UseAzureSqlDefaults(true))` also
  installs the retrying strategy, but it warns `CS0618: 'UseAzureSqlDefaults(bool)' is obsolete` and
  leaves the engine type as `SqlServer`, so the type mapping does not follow.
- **Retry numbers are defaults, not overrides.** Supplying them alongside `UseAzureSql` replaces the
  6 and the 30 seconds. Do that with a measured reason, never by copying a blog post:

```csharp
options.UseAzureSql(
    connectionString,
    o => o.EnableRetryOnFailure(maxRetryCount: 3, maxRetryDelay: TimeSpan.FromSeconds(10), errorNumbersToAdd: null));
```

Whether to retry at all is not a question on this database. **The split is clean:
`connect-to-azure-sql` owns retry at the driver and connection level, this skill owns the EF Core
execution strategy above it and the transaction semantics that only exist up here.**

## Compatibility level, and the migration nobody expects

On EF Core 10, `UseAzureSql` defaults the compatibility level to **170**, and at 170 the provider
maps JSON to the native `json` column type instead of `nvarchar(max)`. Learn states it as a
breaking change: upgrading an application that already uses `UseAzureSql` generates a migration that
alters every existing `nvarchar(max)` JSON column to `json`: data movement on a live table,
produced by a change that reads as configuration.

Generate the migration and read it before it reaches a database:

```bash
dotnet ef migrations add UpgradeToEfCore10
dotnet ef migrations script --idempotent --output migrate.sql
grep -nE 'ALTER COLUMN|json' migrate.sql
```

Then choose, rather than inherit:

- **State the level.** Learn names a level below 170 as the opt out, and its own example is
  `o.UseCompatibilityLevel(160)`, which keeps `nvarchar(max)`.
- **Pin one column** with `HasColumnType("nvarchar(max)")` where only part of the model must wait.
- **Take the retype deliberately**, in a window sized for the table, because the `ALTER` rewrites it.

The level does **not** gate `vector(n)`, which EF Core 10 surfaces as `SqlVector<float>` and
`EF.Functions.VectorDistance`, so do not raise it expecting to unlock vectors. Storing embeddings is
`vector-search-azure-sql`.

## Type mapping, honestly scoped

Most EF Core type mapping advice applies to any engine this provider talks to and belongs to
`design-azure-sql-schema`. Two things are different here.

**`DateTime` with `HasDefaultValueSql("GETDATE()")`.** Azure SQL Database offers no time zone
choice: `CURRENT_TIMEZONE()` returns UTC and `GETDATE()` equals `SYSUTCDATETIME()`, in the container
and in the cloud alike. A model carried over from an engine running on local time changes meaning
without changing shape. Prefer `DateTimeOffset`, or `SYSUTCDATETIME()`, and be explicit either way.

**An indexed `string` with no `MaxLength` is narrowed to `nvarchar(450)`**, and neither the index
nor the data fails silently. From the script generated above, for one indexed string property:

```text
[Name] nvarchar(450) NOT NULL,
CREATE INDEX [IX_Orders_Name] ON [Orders] ([Name]);
```

The `CREATE INDEX` succeeds and the engine then refuses anything longer, with
`Msg 2628, String or binary data would be truncated in table '<table>', column '<column>'`. Adding
the index later to a column already holding longer values fails the same way on the `ALTER COLUMN`,
so the migration stops rather than trimming data. Set `HasMaxLength` deliberately instead of
discovering the 450 at deployment.

## Single and split queries over a wide area network

`Include` of two sibling collections produces a cross product. That is engine independent. **What
changes here is the arithmetic of the fix**, because each extra query is a real network round trip.

- **Prefer split** when the cartesian product is large: moving duplicated megabytes costs more.
- **Prefer single** for small collections and chatty request paths.
- **Measure.** The break even point moves with row width and with distance.
- Split queries are not one consistent read unless wrapped in a snapshot or serializable
  transaction, which puts them back under everything above.

Slow query triage is `diagnose-slow-query`.

## Migrations against a cloud database

Doctrine is `schema-migrations-safely`, the declarative alternative `sql-database-projects`, the
deployment step `ef-core-migrations-azure-sql`. Only the Azure SQL Database parts are here:

```bash
dotnet ef database update \
  --connection "Server=tcp:your-server.database.windows.net,1433;Database=your-database;Authentication=Active Directory Default;Encrypt=Mandatory;"
```

- **It runs from wherever it is invoked**, so that machine needs a server firewall rule for its own
  address and a principal that can change the schema. Neither is the application's runtime identity,
  and `--connection` is how the two are kept apart: it overrides the string in `AddDbContext` or
  `OnConfiguring` without editing the application.
- **The database itself is not created by a migration.** That is `provision-azure-sql-db`.
- **Do not migrate from application startup here.** EF Core 9 added a database wide lock, so the
  concurrency objection an agent will recall is out of date. The objection that survives is
  permissions: startup migration means the runtime identity holds schema rights permanently.

## Connecting with an identity rather than a password

Nothing in the `DbContext` changes. `UseAzureSql` takes the same connection string a bare driver
would, so passwordless access stays a connection string concern:

```text
Server=tcp:your-server.database.windows.net,1433;Database=your-database;Authentication=Active Directory Default;Encrypt=Mandatory;
```

Getting an identity to a working connection is `entra-id-auth`. Packages, authentication modes and
pooling are `connect-from-dotnet`.

## Check it worked

Three checks, in the order they catch things.

**The context is on the Azure SQL Database path at all.** Nothing in the connection string says so,
and this is the only command that prints it:

```bash
dotnet ef dbcontext info
```

Expect `Options: EngineType=AzureSql`. Under `UseSqlServer`, with or without a hand written
`EnableRetryOnFailure`, the same line reads `Options: EngineType=SqlServer`, which is how a
`UseAzureSqlDefaults` configuration is caught: it retries, and it still prints `SqlServer`.

**The model and the migrations agree**, before a deployment discovers they do not:

```bash
dotnet ef migrations has-pending-model-changes
```

Expect exit code 0 and `No changes have been made to the model since the last migration.` Exit code
1 and `Changes have been made to the model since the last migration.` is the failure, and it is the
one that becomes an unexplained `ALTER` in somebody else's release.

**A replayed unit collides instead of duplicating.** An idempotency key is only a defence if the
index over it is unique:

```sql
SELECT i.name, i.is_unique
FROM sys.indexes AS i
WHERE i.object_id = OBJECT_ID('dbo.Orders') AND i.is_unique = 1;
```

Expect one row, the index over the key column. With `is_unique` 1 a replayed insert fails with
`Msg 2601, Cannot insert duplicate key row in object 'dbo.Orders' with unique index`; with a
non-unique index the replay writes a second row and the whole defence is decorative.

## Do not

- Do not treat the execution strategy exception as the end of the work. It is the visible half, and
  the silent half is a duplicate write.
- Do not put a hand written `BeginTransaction` and `Commit` inside a retried delegate without an
  idempotency key or a `verifySucceeded` predicate. It compiles, it passes review, and it doubles a
  row on the fault it was configured to expect.
- Do not drop `acceptAllChangesOnSuccess: false` from the `ExecuteInTransaction` form. Without it
  the entity is marked `Unchanged` and the replay saves nothing.
- Do not assume `Database.BeginTransaction` throws. It succeeds, and the next query or `SaveChanges`
  throws. Raw SQL inside that transaction is not guarded at all.
- Do not disable retry to make a transaction error disappear, and do not leave the retry budget
  larger than the caller's timeout.
- Do not claim `UseAzureSql` removes `EnableRetryOnFailure`. It sets its default.
- Do not reach for `UseAzureSqlDefaults(true)`. It is obsolete, and it leaves the engine type
  unchanged; `ConfigureSqlEngine(c => c.EnableRetryOnFailureByDefault())` is the supported form.
- Do not upgrade to EF Core 10 and switch to `UseAzureSql` in the same change without reading the
  next migration.
- Do not add `AsSplitQuery` everywhere by reflex. Over a network it can cost more than it saves.
- Do not apply migrations from application startup against a cloud database.
- Do not leave an indexed string property without `HasMaxLength`, and do not leave two sibling
  collection `Include` calls without `AsSplitQuery` or `AsSingleQuery`.
- Do not give the application's runtime identity schema permission, and do not put a connection
  string, password or server hostname in source.
- Do not use this skill for a different object relational mapper, or for raw
  `Microsoft.Data.SqlClient` work.

## References

- [Every run behind the tables above, and how to reproduce one](references/retry-transactions-and-type-mapping.md)
- [Connection resiliency](https://learn.microsoft.com/ef/core/miscellaneous/connection-resiliency):
  execution strategies, the transaction rule, and the four documented answers to a commit that fails
  with an unknown outcome. Read it before writing anything transactional.
- [Microsoft SQL Server database provider](https://learn.microsoft.com/ef/core/providers/sql-server/):
  the first party statement of `UseAzureSql`, `UseCompatibilityLevel` and `ConfigureSqlEngine`.
- [Breaking changes in EF Core 10](https://learn.microsoft.com/ef/core/what-is-new/ef-core-10.0/breaking-changes):
  read before an EF Core 10 upgrade, for the JSON retype and the compatibility level that gates it.
- [Single vs split queries](https://learn.microsoft.com/ef/core/querying/single-split-queries):
  cartesian explosion and every characteristic of split queries.
- Underneath this skill: `connect-to-azure-sql` for retry and pool sizing at the connection level,
  `connect-from-dotnet` for the driver and packages, `entra-id-auth` for a passwordless identity.
- Beside it: `design-azure-sql-schema` for string sizing and collation, `schema-migrations-safely`
  and `ef-core-migrations-azure-sql` for how migrations reach a database.
