---
name: schema-migrations-safely
description: >-
  Decides whether a schema change is safe to apply to a live Azure SQL Database, and rewrites the
  migration script so it is. Use when someone asks "is this migration safe to run in production",
  "can I add this column without downtime", "zero downtime schema change", "expand and contract",
  "blue green database deploy", "make this migration re-runnable or idempotent", "should the app
  run migrations at startup", or "how do I roll this back"; and when a deployment blocked every
  query, several instances fought over the same migration, or a retried migration applied its
  backfill twice. Covers which alterations are metadata only and which rewrite the table, the
  schema lock that blocks readers even under snapshot isolation, why a guard is not a guard under
  concurrency or retry, and rollback as a forward migration. The tools carrying the change are
  sql-database-projects, github-actions-for-sql, ef-core-azure-sql, prisma-azure-sql and
  sqlalchemy-azure-sql. The schema itself is design-azure-sql-schema.
license: MIT
---

# Apply a schema change to a live Azure SQL Database

This is the doctrine every migration tool inherits, and none of them enforces. It is about the
engine underneath, so it applies whether the change is carried by a project publish, a pipeline
step, an ORM migration or a hand written script.

Measured on 2026-08-28 against a live engine reporting `SERVERPROPERTY('EngineEdition')` 5 and
Edition `SQL Azure`, at compatibility level 170, with read committed snapshot isolation on, which
is the Azure SQL Database default. Table under test: 2,000,000 rows, 230 MB. Every number below
came from a run, and the runs are in
[references/verified-behaviour.md](references/verified-behaviour.md).

## The correction

An agent asked whether a migration is safe answers with expand and contract, adds `IF NOT EXISTS`
guards, and calls the script idempotent. All three beliefs break here in ways nothing reports:

1. **`ALTER TABLE` is not uniformly cheap, and the expensive ones are not the ones that look
   expensive.** Adding a `NOT NULL` column with a constant default to 2 million rows took 1.7 ms.
   Widening `varchar(50)` to `varchar(max)` took 7.3 seconds and wrote 572 MB of log.
2. **The lock a schema change takes is the one thing snapshot isolation does not save you from.**
   A plain read, a `SNAPSHOT` read and a `NOLOCK` read all waited on it, measured.
3. **A guard protects the statement it wraps and nothing else.** Eight instances starting at once
   all passed the same `IF NOT EXISTS` checks and applied the same backfill eight times.

**What being wrong costs:** the changes that stall a database are indistinguishable from the ones
that do not until they run in production against production data volume, and the failures in 2 and
3 are silent or arrive attributed to the wrong thing.

## 1. Which alterations are metadata only, and which rewrite every row

Log bytes are the honest signal: a metadata only change writes a fixed couple of kilobytes whatever
the row count, a rewrite writes more log than the table occupies.

| Change | Time | Log written |
|---|---|---|
| `ADD` nullable column, no default | 3.6 ms | 1.2 KB |
| `ADD` `NOT NULL` column, **constant** default | 1.7 ms | 2.2 KB |
| `ADD` `NOT NULL` column, `SYSUTCDATETIME()` default | 1.5 ms | 2.2 KB |
| `ALTER COLUMN` widen `varchar(20)` to `varchar(50)` | 1.0 ms | 1.1 KB |
| `ADD CONSTRAINT ... CHECK` `WITH NOCHECK` | 1.5 ms | 1.4 KB |
| `DROP COLUMN` | 2.9 ms | 1.2 KB |
| `ADD CONSTRAINT ... CHECK`, validated | 521 ms | 1.7 KB (scan, no writes) |
| `CREATE INDEX`, offline | 628 ms | 37 MB |
| **`ADD` `NOT NULL` column, `NEWID()` default** | **4.6 s** | **448 MB** |
| **`ALTER COLUMN` `int` to `bigint`** | **6.1 s** | **509 MB** |
| **`ALTER COLUMN` `varchar` to `nvarchar`** | **5.1 s** | **426 MB** |
| **`ALTER COLUMN` `varchar(50)` to `varchar(max)`** | **7.3 s** | **572 MB** |
| **`ALTER COLUMN` `NULL` to `NOT NULL`** | **14.5 s** | **661 MB** |

The dividing line is not "adding is cheap, changing is expensive". A `NOT NULL` column with a
default is free **if the default is evaluated once**: `SYSUTCDATETIME()` is, so it is free;
`NEWID()` is evaluated per row, so it rewrote 2 million. Widening a string is free **unless the
target is `MAX`**, which changes the storage. Changing nullability rewrites even when every row
already has a value.

**Cost of getting this wrong:** the two cheapest looking statements in that list, "add a column
with a default" and "widen a column", are the two that took seconds and half a gigabyte of log.
Section 2 is what those seconds do to everything else.

## 2. The lock, and the queue behind it

Every `ALTER TABLE` above held a **schema modification lock, `Sch-M`, on the object**, for the
duration of its transaction. It is incompatible with every other lock mode, including the schema
stability lock that a plain `SELECT` takes.

Azure SQL Database runs with read committed snapshot isolation on by default, which teaches
everyone that readers neither block nor are blocked. Measured with an uncommitted `Sch-M` held for
3 seconds:

| Reader | Waited |
|---|---|
| default read committed snapshot | 3.10 s, `LCK_M_SCH_S` |
| explicit `SET TRANSACTION ISOLATION LEVEL SNAPSHOT` | 3.10 s, `LCK_M_SCH_S` |
| `WITH (NOLOCK)` | 3.10 s, `LCK_M_SCH_S` |

**Then the part that turns a fast change into an outage.** One reporting query holding the table
for 10 seconds was already running. A `SELECT` arriving after the `ALTER` is not blocked by the
reporting query, it is blocked by the *pending* `ALTER`:

| Session | Own work | Waited |
|---|---|---|
| reporting query | 10 s | 10.0 s |
| `ALTER TABLE ... ADD c int NULL` | ~2 ms | **9.0 s**, `LCK_M_SCH_M` |
| three trivial `SELECT`s issued after it | ~1 ms each | **8.0 s each**, blocked by the `ALTER` |

A 2 millisecond change stalled the whole table for 8 seconds because one slow query was in flight.
Nothing in the migration output says so. The evidence is in the application's latency graph, and
the deployment gets blamed for the wrong reason.

## 3. Two settings that decide whether anyone notices

**`WITH (ONLINE = ON)` on `ALTER COLUMN` and on rebuilds.** Same change, same table, twice:

| Statement | Its own time | Two concurrent `SELECT`s |
|---|---|---|
| `ALTER COLUMN w2 bigint` | 8.4 s | **7.17 s each** |
| `ALTER COLUMN w2 bigint WITH (ONLINE = ON)` | 3.5 s | **74 ms and 76 ms** |

The online form is not always faster in isolation. It is the difference between a stalled database
and an unaffected one. It also does not convoy: an online change waiting behind the same 10 second
reader let `SELECT`s issued after it through in 80 ms, where the offline form made them wait 8 s.

Measured: accepted on `ALTER COLUMN`, on `ALTER TABLE ... REBUILD`, on `CREATE INDEX` and on
`ALTER INDEX ... REBUILD`. A syntax error on `ADD` and on `DROP COLUMN`, which do not need it since
both are metadata only. `ALTER COLUMN` is refused outright, online or not, when an index or a
default constraint references the column, with `Msg 5074`.

**`SET LOCK_TIMEOUT` in front of the change.** With the same 10 second reader in flight, an
offline `ALTER COLUMN` under `SET LOCK_TIMEOUT 2000` gave up after 2.1 s with `Msg 1222`, and the
queries behind it waited 1.1 s instead of 8 s. A change that fails cleanly and is retried in the
next window is cheaper than one that succeeds after taking the database with it.

For rebuilds only, `WAIT_AT_LOW_PRIORITY` is more precise. Verified to run on
`ALTER INDEX ... REBUILD` and `ALTER TABLE ... REBUILD`, and rejected with `Msg 102` on
`ALTER COLUMN`:

```sql
ALTER INDEX ix_orders_customer ON dbo.orders REBUILD
WITH (ONLINE = ON (WAIT_AT_LOW_PRIORITY (MAX_DURATION = 1 MINUTES, ABORT_AFTER_WAIT = SELF)));
```

## 4. Expand and contract, and why it is the only shape that works here

"How do I do a blue green database deploy" has the same answer as "how do I deploy at all": there
is one database, it cannot be swapped, and the schema has to satisfy the code either side of the
change. That is also true of a rolling restart and of a rollback, which is why expand and contract
is not one option among several.

**Expand.** Add, never alter or rename, and add nullable or with a constant default so it lands in
milliseconds. New code writes both shapes. Old code is unaffected.

**Migrate.** Backfill in bounded batches, outside the schema change, in its own deployment. Section
7 is what makes it re-runnable, because it is the statement no guard protects.

**Contract.** Drop the old shape only after every instance referencing it is gone. Measured: after
another session dropped a column, a connection already using the old shape got `Msg 207, Invalid
column name` on its very next write, while its `SELECT *` kept working with one fewer column. The
failure is per statement, immediate, and it hits the instances not yet replaced.

**Never rename in place.** `sp_rename` on a column raised no error. It raised an informational
message, class 01, number 15477, "Caution: Changing any part of an object name could break scripts
and stored procedures", which a runner logging only exceptions discards. A view and a procedure
over that column both kept existing and then failed with `Msg 207` **when they were next called**,
while `sys.sql_expression_dependencies` still resolved both with `is_ambiguous = 0`. The rename
succeeds, the dependency metadata says everything is fine, the breakage arrives later at the
caller. Add the new column, backfill, cut over, drop the old one.

## 5. Never migrate on application startup, measured

The reason usually given is a vague appeal to concurrency. What actually happens, with eight
instances starting at once, each running the same four step migration (add a column, backfill a
value, create an index, record the version):

| Script shape | Outcome |
|---|---|
| No guards, no transaction | 8 of 8 decided to apply. **7 failed with `Msg 2705`**, duplicate column name. One succeeded |
| `IF NOT EXISTS` guards, no transaction | 8 of 8 applied. Backfill ran **8 times**: 4000 where 500 was correct. The only error raised was `Msg 2627` on the version row, **after** the data was wrong |
| `IF NOT EXISTS` guards, one transaction | 8 of 8 attempted, 7 rolled back. Data correct. 7 instances still reported failure |
| `sp_getapplock` first | **1 applied, 7 skipped, 0 errors** |

Read row two again. The guards worked exactly as written and the migration was still wrong, because
`UPDATE ... SET tier = tier + 1` has no `IF NOT EXISTS` form. The error that surfaced was a primary
key violation on the history table, which reads as a harmless double record, and the number that
was wrong was in a column nobody was looking at. Row one is the visible failure and it is the
better one: seven instances crash on startup, the deployment stalls, somebody looks. Row two ships.

The remaining objections stand on their own. Startup migration means the runtime identity holds
schema altering permission permanently, and every instance restart is a potential schema change.
Migrations are a deployment step with their own identity, run once, and the two skills that carry
that step are `sql-database-projects` and `github-actions-for-sql`.

**If a runner genuinely has to be safe against concurrent starts**, take an application lock first
and hold it for the whole migration. It is the one shape above that produced no errors at all:

```sql
BEGIN TRAN;
DECLARE @rc int;
EXEC @rc = sp_getapplock @Resource = 'schema-migrations',
                         @LockMode = 'Exclusive',
                         @LockOwner = 'Transaction',
                         @LockTimeout = 30000;
IF @rc < 0 THROW 50000, 'Could not acquire the migration lock', 1;
-- re-read the history table HERE, inside the lock, then apply
COMMIT;
```

## 6. Retry and migrations, which is the hazard nothing reports

Retry is not optional on Azure SQL Database, so every path to the database has a retry policy on
it, including the one the migration runs over. `connect-to-azure-sql` owns that doctrine.

**A retriable unit is a unit that will be run more than once.** Reproduced on the engine: a four
step migration with `IF NOT EXISTS` guards, faulted once after the backfill committed and before
the version row was written, under a retry policy that classifies a broken connection as transient.

```text
attempt 1: FAILED, "Connection may have been terminated by the server", classified transient
attempt 2: applied, no error
runner reported success: True
final state: version 1 recorded, backfill applied TWICE (1000 where 500 was correct)
```

**No exception, no warning, no log line.** The runner exited zero. The history table says the
migration is applied. The value is double.

The same script with all four steps inside **one transaction**, faulted at the same point, ended
correct: the fault rolled the whole unit back, the retry re-applied it once, final value 500.

The fault was injected with a session kill, which reaches the client as a broken connection. That
is the error class every transient fault policy is built to retry, which is why this is not exotic.
It is the same shape `ef-core-azure-sql` measured at the row level, at the scale of a whole
migration.

So: **either the whole migration is one transaction, or every statement in it is idempotent, data
statements included.** A guard on the DDL and none on the backfill is the shape that reproduced.
One limit: `ALTER DATABASE ... SET` is refused inside a multi statement transaction with `Msg 226`,
so a database option change cannot be atomic with the rest and belongs in its own step.
`CREATE INDEX`, including `WITH (ONLINE = ON)`, was accepted inside an explicit transaction here.

## 7. Idempotent scripts, concretely, on this engine

The syntax an agent reaches for from another database mostly does not exist here. Verified:

| Written | Result |
|---|---|
| `CREATE TABLE IF NOT EXISTS` | `Msg 156`, syntax error. Does not exist |
| `CREATE INDEX IF NOT EXISTS` | `Msg 156`, syntax error. Does not exist |
| `ALTER TABLE ... ADD IF NOT EXISTS` | `Msg 156`, syntax error. Does not exist |
| `IF OBJECT_ID(...) IS NULL CREATE VIEW ...` | `Msg 156`. `CREATE VIEW` cannot follow `IF` |
| `SELECT 1; CREATE VIEW ...` | `Msg 111`, must be the first statement in the batch |
| `IF SCHEMA_ID(...) IS NULL CREATE SCHEMA ...` | `Msg 156`, same batch rule |
| `CREATE OR ALTER TABLE` | `Msg 156`. Only programmability objects have this |
| `IF ... EXEC sp_executesql N'CREATE VIEW ...'` | works |
| `CREATE OR ALTER VIEW` | works, and needs no guard |
| `DROP TABLE IF EXISTS` | works |

So the patterns that hold:

- **`CREATE OR ALTER`** for views, procedures, functions and triggers. No guard, no race, no batch
  problem. This is the only genuinely idempotent create the engine offers.
- **A guard around `sp_executesql`** for anything that must be first in its batch.
- **`IF NOT EXISTS (SELECT 1 FROM sys.columns ...)`** for `ALTER TABLE ADD`, and the equivalent over
  `sys.indexes` for `CREATE INDEX`. Correct for a single runner. **A race with two.**
- **The backfill carries its own predicate.** `UPDATE ... WHERE tier IS NULL` rather than
  `SET tier = tier + 1`. A statement whose second execution is a no operation needs no guard and
  cannot be un-guarded by a retry.

**Where a guard is a race rather than a guard.** Every `IF NOT EXISTS` above reads the catalog,
releases the lock, and then acts. Two runners both read absent and both act, and section 5 measured
eight of eight doing exactly that. A guard is not what makes a script safe to run twice.
Serialisation is, by application lock or by being the only runner.

**Names you did not choose will break the script.** A default constraint created inline gets a
generated name, `DF__parts__qty__123EB7A3` here, different in every environment.
`ALTER TABLE ... DROP COLUMN qty` failed with `Msg 5074`, "The object 'DF__parts__qty__123EB7A3' is
dependent on column 'qty'". A contract script has to resolve the name from
`sys.default_constraints` and drop it dynamically, or the constraint has to have been named
explicitly when it was created. The same `Msg 5074` blocks `ALTER COLUMN` when an index references
the column.

The safe re-run errors to recognise when a script is not idempotent: `Msg 2705` duplicate column,
`Msg 2714` object already exists, `Msg 1913` index name already exists, `Msg 2627` duplicate key on
the history table.

## 8. Rollback is a forward migration

A down script is fiction the moment data has moved, and the engine makes that concrete rather than
philosophical.

- **A down script that drops the column loses every value written since the up ran.** The up
  migration was deployed because something started writing to that column.
- **`DROP COLUMN` is metadata only, so the space is not reclaimed and the row budget is not
  released.** Measured: a table with `char(4000)` and `char(3000)` columns occupied 202 pages before
  the drop and 202 pages after. Re-adding a `char(4000)` column, which is exactly what
  "roll back, fix, roll forward" does, failed with **`Msg 1701`, "the minimum row size would be
  11011 ... exceeds the maximum allowable table row size of 8060 bytes"**, for a column that no
  longer exists. `ALTER TABLE ... REBUILD` reclaimed it, 202 pages down to 102, after which the
  re-add succeeded.
- **The reversing statement is often the expensive one.** Widening to `varchar(max)` cost 7.3 s;
  narrowing back is another rewrite, and it fails outright if any row no longer fits.

So plan the change so that not proceeding is free, which is what expand and contract already gives
you. Expand is additive and reversible by being ignored. Contract is the irreversible step, so it
is a separate deployment gated on the old code being gone. If a change has to be undone after
contract, the undo is a new forward migration written against the state the database is in.

## Validation rules

- Every `ALTER TABLE` in the script has been classified metadata only or rewrite, and every rewrite
  has a stated expected duration at production row count, not at development row count.
- Every rewriting `ALTER COLUMN` and every index build on a live table carries `WITH (ONLINE = ON)`,
  or a stated reason there are no concurrent readers.
- The script sets a lock timeout, or a maintenance window is stated, so a change cannot queue the
  workload behind itself indefinitely.
- No column is renamed, retyped in place or dropped in the same deployment that adds its
  replacement.
- The migration does not run from application startup. It is a deployment step with its own
  identity, and the runtime identity has no schema permission.
- The migration is either one transaction, or every statement in it, including data statements, is
  a no operation on its second execution.
- Every backfill carries a predicate that makes re-running it harmless, and runs in bounded batches
  outside the schema change.
- The version or history row is written in the same transaction as the change it records.
- Any default constraint the script drops is resolved from `sys.default_constraints` rather than
  named literally.
- There is no down script. The rollback plan names the deployment that can be skipped, and states
  that contract is one way.
- Concurrency and locking claims came from two sessions, not from a comment.

## Do not

- Do not call an `ALTER TABLE` cheap without saying which kind it is. Two of the cheapest looking
  statements measured here rewrote 2 million rows and wrote over 400 MB of log.
- Do not assume snapshot isolation protects readers from a schema change. A plain read, a snapshot
  read and a `NOLOCK` read all waited on the schema modification lock, measured.
- Do not run an offline `ALTER COLUMN` or index build against a live table when the online form is
  accepted. The measured difference was 7.17 seconds of stall against 74 milliseconds.
- Do not run a schema change with no lock timeout while a long query may be in flight. The change
  waits, and everything arriving after it waits behind the change.
- Do not treat `IF NOT EXISTS` as making a script idempotent. It guards one statement, it is a race
  with two runners, and it does nothing for the data statements between the guards.
- Do not run migrations from application startup, and do not accept a framework's own migration
  lock as a reason to. The permission and retry arguments both survive it.
- Do not leave a backfill inside a retried unit without a predicate that makes the second run a no
  operation. It reproduced here as a doubled value with the runner reporting success.
- Do not write the migration history row outside the transaction that applies the change. That gap
  is exactly where the retry re-applies.
- Do not use `sp_rename` on a column, a table or an index that anything references. It succeeds,
  the dependency metadata still resolves, and the caller fails later with `Msg 207`.
- Do not write a down script and treat it as the rollback plan. It cannot return data that has been
  written, and after `DROP COLUMN` the re-add can fail with `Msg 1701` on space a dropped column
  still holds.
- Do not use this skill to choose or configure a migration tool. It is the doctrine underneath all
  of them.

## References

- [references/verified-behaviour.md](references/verified-behaviour.md): every run behind this page,
  with the statements, session counts, timings, log bytes and exact messages, plus the two claims
  that did not hold. Read it before changing a number here, or when one is disputed.
- [ALTER TABLE](https://learn.microsoft.com/sql/t-sql/statements/alter-table-transact-sql): the
  full `ONLINE` and `LOW_PRIORITY_LOCK_WAIT` syntax and every restriction on them. Read it before
  writing an online alteration.
- [Transaction locking and row versioning](https://learn.microsoft.com/sql/relational-databases/sql-server-transaction-locking-and-row-versioning-guide):
  the lock compatibility matrix, including why `Sch-M` is incompatible with everything.
- [sp_getapplock](https://learn.microsoft.com/sql/relational-databases/system-stored-procedures/sp-getapplock-transact-sql):
  return codes and lock owner semantics. Read it when a runner must survive concurrent starts.
- `sql-database-projects` and `github-actions-for-sql`: the declarative project and the pipeline
  that carry a change to the database. This skill decides whether the change is safe; those two
  decide how it travels.
- `ef-core-azure-sql`, `prisma-azure-sql`, `sqlalchemy-azure-sql`: the per tool migration
  workflows, each of which inherits everything above.
- `design-azure-sql-schema`: the schema itself, including what an alteration will cost later.
- `connect-to-azure-sql`: retry and transient fault doctrine. Section 6 is where it meets a
  migration.
- `deploy-app-to-azure`: rolling the instances this change has to stay compatible with.
