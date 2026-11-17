---
name: schema-migrations-safely
description: "Use when asking if a schema change is safe on a live Azure SQL Database: add or alter a column, NOT NULL, deploys timing out, rollback. Has verified behavior common answers miss, e.g. a NEWID() default rewrites the table; a constant one doesn't."
---

# Apply a schema change to a live Azure SQL Database

The doctrine every migration tool inherits and none enforces, whether the change travels by project
publish, pipeline step, ORM migration or hand written script.

Every statement below runs on Azure SQL Database; what it says about readers assumes read committed
snapshot isolation is on.

## The correction

The usual answer to "is this migration safe" is expand and contract, `IF NOT EXISTS` guards, and
calling the script idempotent. All three break here, silently:

1. **`ALTER TABLE` is not uniformly cheap, and the expensive ones do not look expensive.** A
   `NOT NULL` column with a constant default is metadata only, effectively instant at any table
   size; widening `varchar(50)` to `varchar(max)` rewrites every row, so its time and log grow with
   the table.
2. **The lock a schema change takes is the one thing snapshot isolation does not save you from.**
   A plain, a `SNAPSHOT` and a `NOLOCK` read all wait on it.
3. **A guard protects the statement it wraps and nothing else.** Instances starting at once all
   pass the same `IF NOT EXISTS` checks, and each applies the same backfill again.

## 1. Which alterations are metadata only, and which rewrite every row

Log bytes are the honest signal: metadata only writes kilobytes whatever the row count; a rewrite
writes more log than the table holds.

| Change | Cost | Log written |
|---|---|---|
| `ADD` nullable column, no default | metadata only | kilobytes |
| `ADD` `NOT NULL` column, **constant** default | metadata only | kilobytes |
| `ADD` `NOT NULL` column, `SYSUTCDATETIME()` default | metadata only | kilobytes |
| `ALTER COLUMN` widen `varchar(20)` to `varchar(50)` | metadata only | kilobytes |
| `ADD CONSTRAINT ... CHECK` `WITH NOCHECK` | metadata only | kilobytes |
| `DROP COLUMN` | metadata only | kilobytes |
| `ADD CONSTRAINT ... CHECK`, validated | scans every row | kilobytes (scan, no writes) |
| `CREATE INDEX`, offline | builds the index | grows with the index |
| **`ADD` `NOT NULL` column, `NEWID()` default** | **rewrites every row** | **more than the table holds** |
| **`ALTER COLUMN` `int` to `bigint`** | **rewrites every row** | **more than the table holds** |
| **`ALTER COLUMN` `varchar` to `nvarchar`** | **rewrites every row** | **more than the table holds** |
| **`ALTER COLUMN` `varchar(50)` to `varchar(max)`** | **rewrites every row** | **more than the table holds** |
| **`ALTER COLUMN` `NULL` to `NOT NULL`** | **rewrites every row** | **more than the table holds** |

The line is not "adding is cheap, changing is expensive". Learn's rule, which the table follows:
a `NOT NULL` column with a default is metadata only when the default is a **runtime constant**, the
same value for every row. `SYSUTCDATETIME()` is one; `NEWID()` and `NEWSEQUENTIALID()` are named as
not, so those "always run offline and an exclusive (Sch-M) lock is acquired for the duration". Never
online: `max` and LOB types, and any column pushing the row past 8,060 bytes. Widening a string is
free **unless the target is `MAX`**; changing nullability rewrites even when every row has a value.

## 2. The lock, and the queue behind it

Every `ALTER TABLE` above holds a **schema modification lock, `Sch-M`**, for its whole transaction,
incompatible with every other mode, the schema stability lock a plain `SELECT` takes included.
Behind an uncommitted `Sch-M`, a default read committed snapshot read, an explicit `SNAPSHOT`
isolation read and a `WITH (NOLOCK)` read each wait on `LCK_M_SCH_S` until it commits.

**Then the part that turns a fast change into an outage.** With one long reporting query in
flight, a `SELECT` arriving after the `ALTER` is blocked by the *pending* `ALTER`, not the slow
query:

| Session | Own work | Waits |
|---|---|---|
| reporting query | long | none |
| `ALTER TABLE ... ADD c int NULL` | milliseconds | **until the reporting query ends**, on `LCK_M_SCH_M` |
| trivial `SELECT`s issued after it | milliseconds | **until the `ALTER` completes**, blocked by the `ALTER` |

A change that takes milliseconds stalls the table for as long as the slowest query in flight, and
nothing in the migration output says so.

## 3. The three settings that decide whether anyone notices

**`WITH (ONLINE = ON)`.** An offline `ALTER COLUMN` holds concurrent `SELECT`s for as long as it
runs; with `WITH (ONLINE = ON)` they return in milliseconds. Not always faster in isolation, but it
does not convoy: behind the same long reader, later `SELECT`s still get through in milliseconds.
Learn scopes it to "data type, column length or precision, nullability, sparseness, and collation".
On Azure SQL Database it is accepted on `ALTER COLUMN`, `ALTER TABLE REBUILD`, `CREATE INDEX`,
`ALTER INDEX REBUILD`; it is a syntax error on `ADD` and `DROP COLUMN`; and `ALTER COLUMN` is
refused with `Msg 5074`, online or not, when an index or default constraint references the column.

**`ELEVATE_ONLINE`, which makes forgetting it impossible.** Learn: default `OFF`; `WHEN_SUPPORTED`
runs online whatever can; `FAIL_UNSUPPORTED` **fails the statement** when it cannot, naming the
non-nullable column add as the case it refuses. It touches only statements that did not say `ONLINE`,
so it is a floor, not an override, and turns section 1's `NEWID()` default from a review question
into a refusal.

```sql
ALTER DATABASE SCOPED CONFIGURATION SET ELEVATE_ONLINE = FAIL_UNSUPPORTED;
SELECT name, value FROM sys.database_scoped_configurations
WHERE name IN ('ELEVATE_ONLINE', 'ELEVATE_RESUMABLE');
```

**`SET LOCK_TIMEOUT`.** With the same reader in flight, an offline `ALTER COLUMN` under
`SET LOCK_TIMEOUT 2000` gives up when the timeout passes, with `Msg 1222`, and the queries behind it
wait only that long instead of until the reader finishes. The trap, from Learn: `Msg 1222` cancels
the statement and **does not roll back its transaction**, so a lock timeout inside `BEGIN TRAN`
needs `SET XACT_ABORT ON` or the script carries on missing a statement.

For rebuilds only, `WAIT_AT_LOW_PRIORITY` is more precise; Learn says it "can't be used with online
`ALTER COLUMN`", and there it fails with `Msg 102`. `RESUMABLE = ON` requires `ONLINE = ON`, pauses
to fit a window and survives a failover, but **cannot run inside an explicit transaction**. Before
writing either, open
[a pausable build, and a rebuild that gives up](references/alter-cost-schema-locks-and-retry.md#a-pausable-build-and-a-rebuild-that-gives-up)
for a worked pausable build, its `PAUSE`, and a rebuild that gives up rather than queue the
workload.

A paused build still costs disk and DML, and any statement needing a table level exclusive lock,
such as `INSERT ... WITH (TABLOCK)`, fails with error `10637` until resumed or `ABORT`ed.

## 4. Expand and contract, the only shape that works here

One database, which cannot be swapped, must satisfy the code either side of the change, so "blue
green database deploy" reduces to this. **Expand** adds, never alters or renames, nullable or with a
runtime constant default, so it lands in milliseconds. **Migrate**
backfills in bounded batches, in its own deployment. **Contract** drops the old shape only after
every instance referencing it is gone: after another session drops a column, a connection on the
old shape gets `Msg 207, Invalid column name` on its next write while its `SELECT *` keeps working.
The failure is per statement and hits instances not yet replaced.

**Never rename in place.** `sp_rename` on a column raises no error, only informational message
15477 at severity 10, "Caution: Changing any part of an object name could break scripts and
stored procedures", which a runner logging only exceptions discards. A view and a procedure over the
column keep existing and fail with `Msg 207` **when next called**, while
`sys.sql_expression_dependencies` still resolves both with `is_ambiguous = 0`.

## 5. Never migrate on application startup

Several instances starting at once, each running four steps: add a column, backfill a value, create
an index, record the version.

| Script shape | Outcome |
|---|---|
| No guards, no transaction | **One succeeds; every other fails with `Msg 2705`**, duplicate column name |
| `IF NOT EXISTS` guards, no transaction | Every instance passes the guards and the backfill runs **once per instance**, so the data is wrong before the first error. Only error: `Msg 2627` on the version row, **after** the data is wrong |
| The same guards, one transaction | Every instance but one rolls back. Data correct, but those instances report failure |
| `sp_getapplock` first | **One applies, the rest skip, no errors** |

In row two the guards work as written and the data is still wrong, because
`UPDATE ... SET tier = tier + 1` has no `IF NOT EXISTS` form; what surfaces is a duplicate key on
the history table, reading as a harmless double record, while the wrong number sits in a column
nobody watches. Row one fails visibly, the better failure. Row two ships.

Startup migration also leaves schema altering permission on the runtime identity for good and makes
every restart a potential schema change. Migrations are a deployment step with their own identity,
carried by `sql-database-projects` and `github-actions-for-sql`.

**If a runner must survive concurrent starts**, hold an application lock for the whole migration.
Learn's return codes: `0` granted, `1` granted after waiting, `-1` timed out, `-2` cancelled, `-3`
deadlock victim, `-999` a bad call. `@LockOwner = 'Transaction'` must run inside one.

```sql
SET XACT_ABORT ON;
BEGIN TRAN;
DECLARE @rc int;
EXEC @rc = sys.sp_getapplock @Resource = 'schema-migrations', @LockMode = 'Exclusive',
                             @LockOwner = 'Transaction', @LockTimeout = 30000;
IF @rc < 0 THROW 50000, 'Could not acquire the migration lock', 1;
-- re-read the history table HERE, inside the lock, then apply
COMMIT;
```

## 6. Retry and migrations, the hazard nothing reports

Retry is not optional on Azure SQL Database, so every path carries a retry policy, the migration's
included; `connect-to-azure-sql` owns that doctrine. **A retriable unit will be run more than
once.** Take the same guarded four steps, break the connection once after the backfill commits
and before the version row is written, under a policy treating a broken connection as transient,
and the runner's log reads:

```text
attempt 1: FAILED, "Connection may have been terminated by the server", classified transient
attempt 2: applied, no error
runner reported success: True
final state: version 1 recorded, backfill applied TWICE
```

No exception, no warning, and the history table says applied. The same four steps in **one
transaction**, faulted at the same point, end correct.

So: **either the whole migration is one transaction, or every statement in it is idempotent, data
statements included.** A guard on the DDL and none on the backfill is the shape that fails.
Three limits decide where it is split:

- `ALTER DATABASE ... SET` is refused inside a multi statement transaction with `Msg 226`.
- `RESUMABLE = ON` cannot run inside an explicit transaction at all.
- `CREATE INDEX WITH (ONLINE = ON)` **is** accepted there, and Learn warns why you should still not:
  its final `S` or `Sch-M` lock is then held until commit, rebuilding section 2's convoy by hand.

## 7. Idempotent scripts on this engine

The guard syntax other databases offer mostly does not exist here:

| Written | Result |
|---|---|
| `CREATE TABLE IF NOT EXISTS` | `Msg 156`, syntax error. Does not exist |
| `CREATE INDEX IF NOT EXISTS` | `Msg 156`, same |
| `ALTER TABLE ... ADD IF NOT EXISTS` | `Msg 156`, same |
| `ALTER TABLE ... DROP COLUMN IF EXISTS` | **works**, and `DROP CONSTRAINT IF EXISTS` too |
| `IF OBJECT_ID(...) IS NULL CREATE VIEW ...`, same for `CREATE SCHEMA` | `Msg 156`. Cannot follow `IF` |
| `SELECT 1; CREATE VIEW ...` | `Msg 111`, must be first in the batch |
| `CREATE OR ALTER TABLE` | `Msg 156`. Only programmability objects have this |
| `IF ... EXEC sp_executesql N'CREATE VIEW ...'` | works |
| `CREATE OR ALTER VIEW` | works, and needs no guard |
| `DROP TABLE IF EXISTS` | works |

Rows three and four are the asymmetry: contract is idempotent for free, expand is not. So expand is
guarded, anything that must be first in its batch goes inside `sp_executesql`, the backfill carries
its own predicate, and the history row is written in the same transaction as the change, because
that gap is where a retry re-applies.

```sql
SET XACT_ABORT ON;
BEGIN TRAN;

-- Expand: guarded, there is no ADD IF NOT EXISTS.
IF NOT EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID('dbo.customers') AND name = 'region')
  ALTER TABLE dbo.customers ADD region nvarchar(20) NULL;

-- Backfill: unguarded, the predicate makes a second run a no operation.
UPDATE TOP (5000) dbo.customers SET region = N'unknown' WHERE region IS NULL;

-- Contract: the constraint name is resolved, never typed.
DECLARE @df sysname = (SELECT d.name FROM sys.default_constraints AS d
                       JOIN sys.columns AS c ON c.object_id = d.parent_object_id
                                            AND c.column_id = d.parent_column_id
                       WHERE d.parent_object_id = OBJECT_ID('dbo.customers') AND c.name = 'legacy');
DECLARE @drop_df nvarchar(max) = N'ALTER TABLE dbo.customers DROP CONSTRAINT ' + QUOTENAME(@df);
IF @df IS NOT NULL EXEC sys.sp_executesql @drop_df;
ALTER TABLE dbo.customers DROP COLUMN IF EXISTS legacy;

INSERT INTO dbo.__migrations (version) VALUES (7);
COMMIT;
```

**A guard is a race, not a guard.** Every `IF NOT EXISTS` reads the catalog, releases the lock, then
acts, so two runners both read absent and both act, as every instance does in section 5. Only
serialisation makes a script safe to run twice.

**Names you did not choose will break the script.** An inline default constraint gets a generated
name that differs per environment, and `DROP COLUMN qty` fails with `Msg 5074, The object
'DF__parts__qty__123EB7A3' is dependent on column 'qty'`. Hence the lookup above. Re-run errors
meaning a script is not idempotent: `Msg 2705`, `Msg 2714`, `Msg 1913`, and `Msg 2627` on the
history table.

## 8. Rollback is a forward migration

- **A down script that drops the column loses every value written since the up ran**, and the up
  shipped because something started writing to that column.
- **`DROP COLUMN` is metadata only, so the space is not reclaimed and the row budget is not
  released.** Re-adding a dropped `char(4000)` column beside a `char(3000)` one, which is what "roll
  back, fix, roll forward" does, fails with **`Msg 1701`**: the minimum row size still counts the
  dropped column, no longer in `sys.columns`, and passes the 8060 byte maximum.
  `ALTER TABLE ... REBUILD` reclaims it and the re-add succeeds; the steps and the full message are
  in [the reference](references/alter-cost-schema-locks-and-retry.md#rename-contract-and-drop-then-re-add).
- **The reversing statement is often the expensive one.** Widening to `varchar(max)` rewrites every
  row; narrowing back is another rewrite and fails outright if any row no longer fits.

Plan so that not proceeding is free. Expand is reversible by being ignored; contract is the
irreversible step, gated on the old code being gone. After it, the undo is a new forward migration
against the state the database is in.

## Check it worked

Run the migration through `sqlcmd` with **`-m-1`**, no space between flag and value. `-b` sets a
non-zero exit only above severity 10, so alone it reports success on the section 4 `sp_rename`
caution, and without `-m-1` that message prints with no `Msg` number. **`-m-1` is an ODBC `sqlcmd`
instruction**, the 18.x build from `mssql-tools18`. With go-sqlcmd 1.10.0, a severity 10 message
prints no `Msg` header at any `-m` value, so there the caution arrives unnumbered:

```bash
export SQLCMDPASSWORD='<password>'
SQLCMD="sqlcmd -S <server-name>.database.windows.net,1433 -d <database> -U <user> -C -m-1"
$SQLCMD -b -i migration.sql -o migration.out
echo "exit $?"
grep -nE '^Msg |Caution:' migration.out
```

Expect `exit 0` and no output from `grep`. A `Msg 15477` line is a rename nobody asked for. Then ask
the database what happened, as `migration-check.sql`:

```sql
-- 1. The change landed and the history agrees. Expect applied = 1, a non-NULL length.
SELECT (SELECT COUNT(*) FROM dbo.__migrations WHERE version = 7) AS applied,
       COL_LENGTH('dbo.customers', 'region') AS region_bytes;

-- 2. Nothing left half applied by a retry or a bounded batch. Expect zero rows.
SELECT TOP (5) id, region FROM dbo.customers WHERE region IS NULL;

-- 3. No transaction still open, and the lock timeout this session ran under. Expect 0.
SELECT @@TRANCOUNT AS open_transactions, @@LOCK_TIMEOUT AS lock_timeout_ms;

-- 4. No resumable index build left paused. Expect zero rows.
SELECT OBJECT_NAME(object_id) AS table_name, name, state_desc, percent_complete
FROM sys.index_resumable_operations;
```

```bash
# same shell as above, $SQLCMD and SQLCMDPASSWORD already set
$SQLCMD -W -i migration-check.sql
```

Check 3 is the one people skip: a non-zero `@@TRANCOUNT` after a script that set a lock timeout is
the section 3 `Msg 1222` trap, with the migration holding locks right now. A row in check 4 is a
paused build still blocking exclusive table locks with error `10637`.

## Do not

- Do not call an `ALTER TABLE` cheap without saying which kind, assume snapshot isolation protects
  readers from one, or run an offline `ALTER COLUMN` or index build on a live table when the online
  form is accepted.
- Do not set a lock timeout inside a transaction without `SET XACT_ABORT ON`, or put a
  `RESUMABLE = ON` build inside the migration transaction; it is refused.
- Do not treat `IF NOT EXISTS` as idempotence, migrate from application startup, or leave a backfill
  in a retried unit without a predicate making the second run a no operation.
- Do not `sp_rename` anything referenced, treat a down script as the rollback plan, or use this skill
  to choose a migration tool: it is the doctrine under all of them.

## References

- Open [the checks you can run](references/alter-cost-schema-locks-and-retry.md) for the statement
  behind a claim above, the lock repros, the retry fault injection, or the assumptions that are
  false here. Read it before changing a claim here.
- [ALTER TABLE](https://learn.microsoft.com/sql/t-sql/statements/alter-table-transact-sql) before an
  online alteration: the runtime constant rule and the `ONLINE` restrictions.
- [Guidelines for online index operations](https://learn.microsoft.com/sql/relational-databases/indexes/guidelines-for-online-index-operations)
  before a resumable build, and when error 10637 blocks a `TABLOCK` insert.
- [ALTER DATABASE SCOPED CONFIGURATION](https://learn.microsoft.com/sql/t-sql/statements/alter-database-scoped-configuration-transact-sql)
  before setting `ELEVATE_ONLINE` or `ELEVATE_RESUMABLE` on a shared database.
- [Transaction locking and row versioning](https://learn.microsoft.com/sql/relational-databases/sql-server-transaction-locking-and-row-versioning-guide)
  for the lock compatibility matrix and section 3's `LOCK_TIMEOUT` rollback rule.
- [sys.sp_getapplock](https://learn.microsoft.com/sql/relational-databases/system-stored-procedures/sp-getapplock-transact-sql)
  for return codes and lock owner semantics.
- This skill decides whether a change is safe; `sql-database-projects` and `github-actions-for-sql`
  carry it, `ef-core-azure-sql` and `sqlalchemy-azure-sql` are per tool workflows. Also
  `design-azure-sql-schema`, `connect-to-azure-sql` for retry, and `deploy-app-to-azure` for
  rolling the instances.
