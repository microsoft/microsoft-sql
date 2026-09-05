---
name: schema-migrations-safely
description: >-
  Decides whether a schema change is safe to apply to a live Azure SQL Database, and rewrites the
  migration script so it is. Use when someone asks "is this migration safe to run in production",
  "can I add this column without downtime", "zero downtime schema change", "expand and contract",
  "blue green database deploy", "make this migration re-runnable", "should the app run migrations
  at startup", or "how do I roll this back"; and when a deployment blocked every query, several
  instances fought over the same migration, or a retried migration applied its backfill twice.
  Covers which alterations are metadata only and which rewrite the table, the schema lock that
  blocks readers even under snapshot isolation, ONLINE and RESUMABLE and the setting that refuses
  an offline change, why a guard is not a guard under concurrency or retry, and rollback as a
  forward migration. The tools carrying the change are sql-database-projects,
  github-actions-for-sql and the per ORM migration skills. The schema is design-azure-sql-schema.
---

# Apply a schema change to a live Azure SQL Database

The doctrine every migration tool inherits and none enforces. It holds whether the change travels by
project publish, pipeline step, ORM migration or hand written script.

Timings and log bytes measured 2026-08-28 against a live engine reporting
`SERVERPROPERTY('EngineEdition')` 5 and Edition `SQL Azure`, at compatibility level 170, read
committed snapshot isolation on, over a 2,000,000 row 230 MB table. Options checked against
Microsoft Learn the same week; every statement below runs on Azure SQL Database.

## The correction

An agent asked whether a migration is safe answers with expand and contract, adds `IF NOT EXISTS`
guards, and calls the script idempotent. All three break here, silently:

1. **`ALTER TABLE` is not uniformly cheap, and the expensive ones do not look expensive.** A
   `NOT NULL` column with a constant default added to 2 million rows took 1.7 ms; widening
   `varchar(50)` to `varchar(max)` took 7.3 seconds and wrote 572 MB of log.
2. **The lock a schema change takes is the one thing snapshot isolation does not save you from.**
   A plain read, a `SNAPSHOT` read and a `NOLOCK` read all waited on it, measured.
3. **A guard protects the statement it wraps and nothing else.** Eight instances starting at once
   all passed the same `IF NOT EXISTS` checks and applied the same backfill eight times.

## 1. Which alterations are metadata only, and which rewrite every row

Log bytes are the honest signal: metadata only writes kilobytes whatever the row count, a rewrite
writes more log than the table holds.

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

The line is not "adding is cheap, changing is expensive". Learn's rule, which the measurements obey:
a `NOT NULL` column with a default is metadata only when the default is a **runtime constant**,
giving the same value for every row. `SYSUTCDATETIME()` is one; `NEWID()` and `NEWSEQUENTIALID()`
are named as not, so those "always run offline and an exclusive (Sch-M) lock is acquired for the
duration". Never online: `max` and LOB types, and any column pushing the row size past 8,060 bytes.
Widening a string is free **unless the target is `MAX`**, and changing nullability rewrites even
when every row already has a value.

## 2. The lock, and the queue behind it

Every `ALTER TABLE` above held a **schema modification lock, `Sch-M`**, for its whole transaction,
incompatible with every other mode including the schema stability lock a plain `SELECT` takes.
Against an uncommitted `Sch-M` held 3 seconds, a default read committed snapshot read, an explicit
`SET TRANSACTION ISOLATION LEVEL SNAPSHOT` read and a `WITH (NOLOCK)` read each waited 3.10 s on
`LCK_M_SCH_S`. None is exempt.

**Then the part that turns a fast change into an outage.** With one 10 second reporting query in
flight, a `SELECT` arriving after the `ALTER` is blocked by the *pending* `ALTER`, not the slow
query:

| Session | Own work | Waited |
|---|---|---|
| reporting query | 10 s | 10.0 s |
| `ALTER TABLE ... ADD c int NULL` | ~2 ms | **9.0 s**, `LCK_M_SCH_M` |
| three trivial `SELECT`s issued after it | ~1 ms each | **8.0 s each**, blocked by the `ALTER` |

A 2 millisecond change stalled the table for 8 seconds, and nothing in the migration output says so.

## 3. The three settings that decide whether anyone notices

**`WITH (ONLINE = ON)`.** Same change, same table, twice:

| Statement | Its own time | Two concurrent `SELECT`s |
|---|---|---|
| `ALTER COLUMN w2 bigint` | 8.4 s | **7.17 s each** |
| `ALTER COLUMN w2 bigint WITH (ONLINE = ON)` | 3.5 s | **74 ms and 76 ms** |

Not always faster in isolation, but it does not convoy: behind the same 10 second reader it still
let `SELECT`s issued after it through in 80 ms. Learn scopes it to "data type, column length or
precision, nullability, sparseness, and collation". Measured: accepted on `ALTER COLUMN`,
`ALTER TABLE REBUILD`, `CREATE INDEX`, `ALTER INDEX REBUILD`; a syntax error on `ADD` and
`DROP COLUMN`; and `ALTER COLUMN` refused with `Msg 5074`, online or not, when an index or default
constraint references the column.

**`ELEVATE_ONLINE`, which makes forgetting it impossible.** Learn: default `OFF`, `WHEN_SUPPORTED`
runs online whatever can, `FAIL_UNSUPPORTED` **fails the statement** when it cannot, naming the
non-nullable column add as the case it refuses. It touches only statements that did not say `ONLINE`
themselves, so it is a floor, not an override, and it turns section 1's `NEWID()` default from a
review question into a refusal.

```sql
ALTER DATABASE SCOPED CONFIGURATION SET ELEVATE_ONLINE = FAIL_UNSUPPORTED;
SELECT name, value FROM sys.database_scoped_configurations
WHERE name IN ('ELEVATE_ONLINE', 'ELEVATE_RESUMABLE');
```

**`SET LOCK_TIMEOUT`.** With the same reader in flight, an offline `ALTER COLUMN` under
`SET LOCK_TIMEOUT 2000` gave up after 2.1 s with `Msg 1222` and the queries behind it waited 1.1 s
instead of 8 s. The trap, from Learn: `Msg 1222` cancels the statement and **does not roll back the
transaction containing it**, so a lock timeout inside `BEGIN TRAN` needs `SET XACT_ABORT ON` or the
script carries on with a statement missing.

For rebuilds only, `WAIT_AT_LOW_PRIORITY` is more precise; Learn says it "can't be used with online
`ALTER COLUMN`", the `Msg 102` measured here. `RESUMABLE = ON` requires `ONLINE = ON`, pauses to fit
a window and survives a failover, but **cannot run inside an explicit transaction**:

```sql
-- Pausable build. Not inside BEGIN TRAN.
CREATE INDEX ix_orders_customer ON dbo.orders (customer_id)
WITH (ONLINE = ON, RESUMABLE = ON, MAX_DURATION = 20 MINUTES);
SELECT name, state_desc, percent_complete FROM sys.index_resumable_operations;
ALTER INDEX ix_orders_customer ON dbo.orders PAUSE;

-- Rebuild that gives up rather than queueing the workload behind itself.
ALTER INDEX ix_orders_customer ON dbo.orders REBUILD
WITH (ONLINE = ON (WAIT_AT_LOW_PRIORITY (MAX_DURATION = 1 MINUTES, ABORT_AFTER_WAIT = SELF)));
```

A paused build still costs disk and DML, and any statement needing a table level exclusive lock,
such as `INSERT ... WITH (TABLOCK)`, fails with error `10637` until resumed or `ABORT`ed.

## 4. Expand and contract, the only shape that works here

There is one database, it cannot be swapped, and the schema has to satisfy the code either side of
the change, so "blue green database deploy" reduces to this. **Expand** adds, never alters or
renames, nullable or with a runtime constant default, so it lands in milliseconds. **Migrate**
backfills in bounded batches, in its own deployment. **Contract** drops the old shape only after
every instance referencing it is gone: measured, after another session dropped a column, a
connection on the old shape got `Msg 207, Invalid column name` on its next write while its
`SELECT *` kept working. The failure is per statement and hits instances not yet replaced.

**Never rename in place.** `sp_rename` on a column raised no error, only an informational message at
severity 10, number 15477, "Caution: Changing any part of an object name could break scripts and
stored procedures", which a runner logging only exceptions discards. A view and a procedure over the
column kept existing and failed with `Msg 207` **when next called**, while
`sys.sql_expression_dependencies` still resolved both with `is_ambiguous = 0`.

## 5. Never migrate on application startup, measured

Eight instances starting at once, each running the same four steps: add a column, backfill a value,
create an index, record the version.

| Script shape | Outcome |
|---|---|
| No guards, no transaction | 8 of 8 applied. **7 failed with `Msg 2705`**, duplicate column name. One succeeded |
| `IF NOT EXISTS` guards, no transaction | 8 of 8 applied. Backfill ran **8 times**: 4000 where 500 was correct. Only error was `Msg 2627` on the version row, **after** the data was wrong |
| The same guards, one transaction | 8 of 8 attempted, 7 rolled back. Data correct, 7 instances reported failure |
| `sp_getapplock` first | **1 applied, 7 skipped, 0 errors** |

Read row two again. The guards worked exactly as written and the migration was still wrong, because
`UPDATE ... SET tier = tier + 1` has no `IF NOT EXISTS` form. What surfaced was a duplicate key on
the history table, reading as a harmless double record, while the wrong number sat in a column
nobody was watching. Row one is the visible failure and the better one. Row two ships.

Startup migration also holds schema altering permission on the runtime identity permanently and
makes every restart a potential schema change. Migrations are a deployment step with their own
identity, and `sql-database-projects` and `github-actions-for-sql` carry it.

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

Retry is not optional on Azure SQL Database, so every path carries a retry policy including the
migration's; `connect-to-azure-sql` owns that doctrine. **A retriable unit is a unit
that will be run more than once.** Reproduced: the same guarded four steps, faulted once after the
backfill committed and before the version row was written, under a policy treating a broken
connection as transient.

```text
attempt 1: FAILED, "Connection may have been terminated by the server", classified transient
attempt 2: applied, no error
runner reported success: True
final state: version 1 recorded, backfill applied TWICE (1000 where 500 was correct)
```

No exception, no warning, and the history table says applied. The same script with all four steps in
**one transaction**, faulted at the same point, ended correct.

So: **either the whole migration is one transaction, or every statement in it is idempotent, data
statements included.** A guard on the DDL and none on the backfill is the shape that reproduced.
Three limits decide where it is split:

- `ALTER DATABASE ... SET` is refused inside a multi statement transaction with `Msg 226`.
- `RESUMABLE = ON` cannot run inside an explicit transaction at all.
- `CREATE INDEX WITH (ONLINE = ON)` **is** accepted there, and Learn warns why you should still not:
  its final `S` or `Sch-M` lock is then held until commit, rebuilding section 2's convoy by hand.

## 7. Idempotent scripts on this engine

The syntax an agent reaches for from another database mostly does not exist here. Verified:

| Written | Result |
|---|---|
| `CREATE TABLE IF NOT EXISTS` | `Msg 156`, syntax error. Does not exist |
| `CREATE INDEX IF NOT EXISTS` | `Msg 156`. Does not exist |
| `ALTER TABLE ... ADD IF NOT EXISTS` | `Msg 156`. Does not exist |
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
IF @df IS NOT NULL EXEC sys.sp_executesql N'ALTER TABLE dbo.customers DROP CONSTRAINT ' + @df;
ALTER TABLE dbo.customers DROP COLUMN IF EXISTS legacy;

INSERT INTO dbo.__migrations (version) VALUES (7);
COMMIT;
```

**A guard is a race, not a guard.** Every `IF NOT EXISTS` reads the catalog, releases the lock, then
acts. Two runners both read absent and both act; section 5 measured eight of eight doing it. Only
serialisation makes a script safe to run twice.

**Names you did not choose will break the script.** An inline default constraint gets a generated
name, differing per environment, and `DROP COLUMN qty` failed with `Msg 5074, The object
'DF__parts__qty__123EB7A3' is dependent on column 'qty'`. Hence the lookup above. Re-run errors
meaning a script is not idempotent: `Msg 2705`, `Msg 2714`, `Msg 1913`, and `Msg 2627` on the
history table.

## 8. Rollback is a forward migration

- **A down script that drops the column loses every value written since the up ran.** The up
  migration shipped because something started writing to that column.
- **`DROP COLUMN` is metadata only, so the space is not reclaimed and the row budget is not
  released.** Re-adding the dropped `char(4000)` column, which is what "roll back, fix, roll
  forward" does, failed with **`Msg 1701`**, minimum row size 11011 against a maximum of 8060 bytes,
  counting a column no longer in `sys.columns`. `ALTER TABLE ... REBUILD` reclaimed it and the
  re-add then succeeded. Page counts and the full message are in the reference.
- **The reversing statement is often the expensive one.** Widening to `varchar(max)` cost 7.3 s;
  narrowing back is another rewrite and fails outright if any row no longer fits.

Plan so that not proceeding is free. Expand is reversible by being ignored; contract is the
irreversible step, gated on the old code being gone. After it, the undo is a new forward migration
against the state the database is in.

## Check it worked

Run the migration through `sqlcmd` with **`-m-1`**, no space between flag and value. `-b` sets a
non-zero exit only above severity 10, so alone it reports success on the section 4 `sp_rename`
caution, and without `-m-1` that message prints with no `Msg` number. **`-m-1` is an ODBC `sqlcmd`
instruction**, the 18.x build from `mssql-tools18`; go-sqlcmd 1.10.0 prints no `Msg` header on a
severity 10 message at any `-m` value, measured 2026-09-05, so there the caution reaches the file
unnumbered. `build-app-on-azure-sql` tells the builds apart:

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
the section 3 `Msg 1222` trap, and the migration is holding locks right now. A row in check 4 is a
paused build still blocking exclusive table locks with error `10637`.

## Do not

- Do not call an `ALTER TABLE` cheap without saying which kind it is, assume snapshot isolation
  protects readers from one, or run an offline `ALTER COLUMN` or index build against a live table
  when the online form is accepted.
- Do not set a lock timeout inside a transaction without `SET XACT_ABORT ON`, and do not put a
  `RESUMABLE = ON` build inside the migration transaction; it is refused.
- Do not treat `IF NOT EXISTS` as making a script idempotent, migrate from application startup, or
  leave a backfill in a retried unit without a predicate making the second run a no operation.
- Do not use `sp_rename` on anything referenced, treat a down script as the rollback plan, or use
  this skill to choose a migration tool. It is the doctrine under all of them.

## References

- Open [the measured runs](references/alter-cost-schema-locks-and-retry.md) when you need the
  statement behind a number above, the lock traces, the retry fault injection, or the two claims
  that did not hold. Read it before changing any figure here.
- [ALTER TABLE](https://learn.microsoft.com/sql/t-sql/statements/alter-table-transact-sql) before
  writing an online alteration: the runtime constant rule and the `ONLINE` restrictions.
- [Guidelines for online index operations](https://learn.microsoft.com/sql/relational-databases/indexes/guidelines-for-online-index-operations)
  before making a build resumable, and when error 10637 blocks a `TABLOCK` insert.
- [ALTER DATABASE SCOPED CONFIGURATION](https://learn.microsoft.com/sql/t-sql/statements/alter-database-scoped-configuration-transact-sql)
  before setting `ELEVATE_ONLINE` or `ELEVATE_RESUMABLE` on a shared database.
- [Transaction locking and row versioning](https://learn.microsoft.com/sql/relational-databases/sql-server-transaction-locking-and-row-versioning-guide)
  for the lock compatibility matrix and the `LOCK_TIMEOUT` rollback rule in section 3.
- [sys.sp_getapplock](https://learn.microsoft.com/sql/relational-databases/system-stored-procedures/sp-getapplock-transact-sql)
  when a runner must survive concurrent starts: return codes and lock owner semantics.
- This skill decides whether a change is safe. `sql-database-projects` and `github-actions-for-sql`
  carry it, `ef-core-azure-sql` and `sqlalchemy-azure-sql` are the per tool workflows and the rest
  are in `skill.spec.jsonc`; also `design-azure-sql-schema`, `connect-to-azure-sql` for the retry
  doctrine, `deploy-app-to-azure` for rolling the instances.
