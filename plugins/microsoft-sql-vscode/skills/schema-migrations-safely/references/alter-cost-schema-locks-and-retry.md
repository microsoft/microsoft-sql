# Schema locks, alter cost and retries: checks you can run

## Contents

- [Before you run these](#before-you-run-these)
- [Which alterations rewrite every row](#which-alterations-rewrite-every-row)
- [A schema lock blocks snapshot and NOLOCK readers](#a-schema-lock-blocks-snapshot-and-nolock-readers)
- [A pending schema change blocks every query behind it](#a-pending-schema-change-blocks-every-query-behind-it)
- [A lock timeout or an online alteration keeps readers moving](#a-lock-timeout-or-an-online-alteration-keeps-readers-moving)
- [A pausable build, and a rebuild that gives up](#a-pausable-build-and-a-rebuild-that-gives-up)
- [Concurrent startup migrations: only an application lock is safe](#concurrent-startup-migrations-only-an-application-lock-is-safe)
- [A retried migration re-applies an unguarded backfill](#a-retried-migration-re-applies-an-unguarded-backfill)
- [Which idempotent forms parse](#which-idempotent-forms-parse)
- [Rename, contract, and drop then re-add](#rename-contract-and-drop-then-re-add)
- [Assumptions that are false here](#assumptions-that-are-false-here)

## Before you run these

Every check runs on Azure SQL Database. The snapshot reader check needs read committed snapshot
and snapshot isolation on: `is_read_committed_snapshot_on = 1` and
`snapshot_isolation_state_desc = ON` in `sys.databases`.

You need a table large enough that a rewrite is visible, millions of rows rather than thousands,
and two or more client connections: two for most checks, one per simulated instance for the startup
check. Run each session on its own connection, not as nested batches on one.

Open every session with autocommit on and issue `BEGIN TRAN` and `COMMIT` explicitly. A client
opened with autocommit off wraps the explicit transaction in a driver transaction and rolls it back
at close, so log bytes read near zero and every alteration looks metadata only.

Watch three things: wall clock at the client; `wait_type` and `blocking_session_id` from
`sys.dm_exec_requests`, sampled from a session not involved in the check; and
`database_transaction_log_bytes_used` from `sys.dm_tran_database_transactions`, read before the
commit.

The table the checks use:

```sql
CREATE TABLE dbo.orders (
  id int IDENTITY(1,1) PRIMARY KEY,
  customer_id int NOT NULL,
  status varchar(20) NOT NULL,
  amount decimal(12,2) NOT NULL,
  note nvarchar(100) NULL,
  created_at datetime2 NOT NULL DEFAULT SYSUTCDATETIME()
);
```

## Which alterations rewrite every row

A metadata only change writes a few kilobytes of log in a handful of records, effectively instant
at any row count. A rewrite touches every row: about one log record per row, more log than the
table holds, and time that grows with the table.

Run each statement inside `BEGIN TRAN` and, before `COMMIT`, read
`sys.dm_tran_database_transactions.database_transaction_log_bytes_used` for
`CURRENT_TRANSACTION_ID()`.

| Statement | Result |
|---|---|
| `ALTER TABLE dbo.orders ADD c1 int NULL` | metadata only |
| `ADD c2 int NOT NULL CONSTRAINT df_c2 DEFAULT (0)` | metadata only |
| `ADD c3 uniqueidentifier NOT NULL DEFAULT (NEWID())` | **rewrites every row** |
| `ADD c4 datetime2 NOT NULL DEFAULT (SYSUTCDATETIME())` | metadata only |
| `ADD c5 varchar(max) NULL` | metadata only |
| `ALTER COLUMN status varchar(50) NOT NULL` (from 20) | metadata only |
| `ALTER COLUMN status varchar(max) NOT NULL` | **rewrites every row** |
| `ALTER COLUMN note2 nvarchar(50)` (from `varchar(50)`) | **rewrites every row** |
| `ALTER COLUMN customer_id bigint NOT NULL` | **rewrites every row** |
| `ALTER COLUMN note nvarchar(100) NOT NULL` (from `NULL`) | **rewrites every row** |
| `ADD CONSTRAINT ck_amt CHECK (amount >= 0)` | scans every row to validate, writes kilobytes of log |
| `WITH NOCHECK ADD CONSTRAINT ck_amt2 CHECK (...)` | metadata only |
| `DROP COLUMN c5` | metadata only |
| `CREATE INDEX ix_off ON dbo.orders(customer_id)` | builds the index; log grows with the index, not one record per row |
| `CREATE INDEX ix_on ON dbo.orders(amount) WITH (ONLINE=ON)` | can be slower than the offline build, and logs little in the session's transaction |

While each transaction is open, `sys.dm_tran_locks` read from a second session shows `OBJECT` /
`Sch-M` for every `ALTER TABLE`, and `HOBT` / `Sch-M` plus `OBJECT` / `Sch-S` for the index builds.

## A schema lock blocks snapshot and NOLOCK readers

Every read takes a schema stability lock, `Sch-S`, which is incompatible with `Sch-M`. Read
committed snapshot, `SNAPSHOT` isolation and `WITH (NOLOCK)` all wait behind an uncommitted schema
change, however cheap the change itself is.

Session A: `BEGIN TRAN; ALTER TABLE dbo.orders ADD z1 int NULL;`, held open for a few seconds, then
committed. Start three readers at once, one per connection: a default read committed snapshot
read, a read under `SET TRANSACTION ISOLATION LEVEL SNAPSHOT` in an explicit transaction, and a
`SELECT ... WITH (NOLOCK)`.

`sys.dm_exec_requests` shows all three on `LCK_M_SCH_S`. The first names session A as its blocker;
the later ones may name the first waiting reader, because they queue behind it. Each reader returns
only when session A commits. The `ALTER` is metadata only: what blocks is the open transaction
holding `Sch-M`, not the work.

## A pending schema change blocks every query behind it

A schema change waiting for its `Sch-M` lock blocks every query that arrives after it. One slow
reader and one cheap `ALTER` stall the table for as long as the reader runs.

Session A: `BEGIN TRAN; SELECT TOP 1 id FROM dbo.orders WITH (REPEATABLEREAD); WAITFOR DELAY
'00:00:10'; COMMIT;`
Session B, 1 s later: `ALTER TABLE dbo.orders ADD z1 int NULL`.
Sessions C, D, E, 1 s after that: `SELECT TOP 1 id FROM dbo.orders`.

`sys.dm_exec_requests` shows session B on `LCK_M_SCH_M`, blocked by A, and C, D and E on
`LCK_M_SCH_S`, blocked by B, not by the long reader. C, D and E return only after A commits and B
completes, each having waited out the rest of A's `WAITFOR` for a read that takes milliseconds.
This is what turns a metadata only change into a full stall.

## A lock timeout or an online alteration keeps readers moving

**`SET LOCK_TIMEOUT` makes the change give up instead of holding the queue.** Put
`SET LOCK_TIMEOUT 2000` in front of an offline `ALTER COLUMN`, with the same 10 second reader in
flight. The `ALTER` fails with `Msg 1222, Lock request time out period exceeded` once the timeout
passes, and the `SELECT`s queued behind it return then, instead of waiting for the reader to
commit.

**Online does not block readers.** Change the same column both ways. Use a column, `w2` here, that
no index or default constraint references, so neither form is refused, and start two concurrent
`SELECT TOP 1` readers while the change runs:

| Statement | Readers |
|---|---|
| `ALTER COLUMN w2 bigint NULL` | wait on `LCK_M_SCH_S` until the change finishes |
| `ALTER COLUMN w2 int NULL WITH (ONLINE = ON)` | return in milliseconds, no `LCK_M_SCH_S` waits |
| `ALTER COLUMN w2 bigint NULL WITH (ONLINE = ON)` | return in milliseconds, no `LCK_M_SCH_S` waits |

**Online does not convoy.** With the 10 second reader in flight and an online `ALTER COLUMN`
waiting behind it, `SELECT`s arriving after the `ALTER` return in milliseconds. Behind the offline
form they wait for the reader to commit.

**Where `ONLINE = ON` is accepted:**

| Statement | Result |
|---|---|
| `ALTER TABLE ... ALTER COLUMN ... WITH (ONLINE = ON)` | accepted |
| `ALTER TABLE ... REBUILD WITH (ONLINE = ON)` | accepted |
| `CREATE INDEX ... WITH (ONLINE = ON)` | accepted, inside and outside an explicit transaction |
| `ALTER TABLE ... ADD col ... WITH (ONLINE = ON)` | `Msg 102`, syntax error |
| `ALTER TABLE ... DROP COLUMN c1 WITH (ONLINE = ON)` | `Msg 156`, syntax error |
| `ALTER COLUMN` on a column an index references | `Msg 5074`, online or not |
| `ALTER COLUMN` on a column a default constraint references | `Msg 5074`, online or not |

**`WAIT_AT_LOW_PRIORITY`:**

| Statement | Result |
|---|---|
| `ALTER INDEX ... REBUILD WITH (ONLINE = ON (WAIT_AT_LOW_PRIORITY (MAX_DURATION = 1 MINUTES, ABORT_AFTER_WAIT = SELF)))` | parses and runs |
| `ALTER TABLE ... REBUILD WITH (ONLINE = ON (WAIT_AT_LOW_PRIORITY (...)))` | parses and runs |
| `ALTER TABLE ... ALTER COLUMN ... WITH (ONLINE = ON (WAIT_AT_LOW_PRIORITY (...)))` | **`Msg 102`, syntax error** |

## A pausable build, and a rebuild that gives up

A resumable build requires `ONLINE = ON`, cannot run inside an explicit transaction, pauses to fit
a window, and is watched in `sys.index_resumable_operations`. A rebuild with
`WAIT_AT_LOW_PRIORITY` gives up rather than queueing the workload behind itself; it is for rebuilds
only, per the table above.

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

`sys.index_resumable_operations` lists the build with its `state_desc` and `percent_complete`
until it completes or is aborted. The rebuild either gets its lock within `MAX_DURATION` or, with
`ABORT_AFTER_WAIT = SELF`, cancels itself instead of making the workload wait.

## Concurrent startup migrations: only an application lock is safe

Runners that start together each read the history table before any of them records the version,
so every one decides to apply. What happens next depends only on the shape of the script.

Reset before each mode: `dbo.__migrations(version int PRIMARY KEY, applied_at)` and
`dbo.customers(id, name, tier int NOT NULL DEFAULT 0)` with a few hundred rows, all `tier = 0`.

Start several runners at once, each on its own connection. Each checks the history table and, if
version 1 is absent, runs four statements with a 50 ms pause between them:

```text
1  ALTER TABLE dbo.customers ADD region nvarchar(20) NULL
2  UPDATE dbo.customers SET tier = tier + 1
3  CREATE INDEX ix_cust_tier ON dbo.customers(tier)
4  INSERT INTO dbo.__migrations (version) VALUES (1)
```

The correct final state is one version row, `region` present, the index present, and `SUM(tier)`
equal to the row count.

| Mode | What you will see |
|---|---|
| no guards, no transaction | One runner applies; every other fails on statement 1 with `Msg 2705`. `SUM(tier)` is correct |
| `IF NOT EXISTS` guards on 1 and 3, no transaction | Every runner passes the guards and runs the backfill, so `SUM(tier)` is the row count times the number of runners. The only errors are `Msg 2627` on statement 4, in every runner but one, **after the data is wrong** |
| the same guards, all four inside one transaction | Every runner but one fails on statement 4 with `Msg 2627` and rolls back. `SUM(tier)` is correct, and those runners report failure |
| `sp_getapplock` Exclusive, Transaction owner, before the check | **One runner applies, the rest skip, no errors.** `SUM(tier)` is correct |

The messages:

```text
2705  Column names in each table must be unique. Column name 'region' in table
      'dbo.customers' is specified more than once.
2627  Violation of PRIMARY KEY constraint 'PK____migrat__...'. Cannot insert duplicate key
      in object 'dbo.__migrations'. The duplicate key value is (1).
```

Row two is the one that matters. The guards do their job, every runner passes them, and the
`UPDATE`, which has no guard form, runs once per runner. The only error surfaces on the history
insert, after the data is already wrong.

Related re-run errors: `Msg 2714` for a `CREATE TABLE` or a named constraint that already exists,
`Msg 1913` for an index name that already exists.

## A retried migration re-applies an unguarded backfill

A retry policy reruns the whole unit. When the backfill committed before the fault, the rerun
applies it again, and the runner reports success.

Migration: the same guarded four steps, with `WAITFOR DELAY '00:00:03'` inserted before the history
insert to stand in for the rest of a real migration. Runner: retry up to three attempts, treating a
broken connection or a documented transient error number as retriable, which is the shape every
data access guide teaches. Fault: from a second session, `KILL <spid>` while attempt 1 is inside
the `WAITFOR`, that is after the backfill committed and before the history row.

**No transaction.** Attempt 1 fails on a broken connection with no SQL error number; the ODBC
driver reports native error 0, `Unspecified error occurred on SQL Server. Connection may have been
terminated by the server.` The policy classifies it as transient and retries. Attempt 2 applies
with no error, the runner reports success, version 1 is recorded once, and `SUM(tier)` is twice
the correct value. Nothing is raised, nothing is logged, and the exit code is zero.

**All steps inside one transaction, same fault at the same point.** Attempt 1 fails the same way,
attempt 2 applies, the runner reports success, and `SUM(tier)` is correct.

`KILL` stands in for a real transient fault here. A broken connection with no SQL error number is
the class of failure transient fault policies exist to retry, but this does not show that a
specific library's classifier agrees; check yours.

**Transaction limits**, each statement inside `BEGIN TRAN`:

| Statement | Inside a transaction |
|---|---|
| `CREATE INDEX`, offline or `WITH (ONLINE = ON)` | accepted |
| `ALTER TABLE ... REBUILD WITH (ONLINE = ON)` | accepted |
| `ALTER DATABASE CURRENT SET COMPATIBILITY_LEVEL = 160` | **`Msg 226`**, not allowed within a multi statement transaction |

## Which idempotent forms parse

Most guard syntax from other databases is a syntax error on Azure SQL Database. Run each line on
its own:

| Written | Result |
|---|---|
| `CREATE TABLE IF NOT EXISTS dbo.t (id int)` | `Msg 156`, incorrect syntax near the keyword 'IF' |
| `CREATE INDEX IF NOT EXISTS ix ON ...` | `Msg 156` |
| `ALTER TABLE dbo.parts ADD IF NOT EXISTS zz int NULL` | `Msg 156` |
| `CREATE OR ALTER TABLE dbo.t (id int)` | `Msg 156`, incorrect syntax near the keyword 'TABLE' |
| `IF OBJECT_ID('dbo.v_x') IS NULL CREATE VIEW dbo.v_x AS ...` | `Msg 156`, incorrect syntax near the keyword 'VIEW' |
| `SELECT 1; CREATE VIEW dbo.v_y AS ...` | `Msg 111`, `CREATE VIEW` must be the first statement in a query batch |
| `IF SCHEMA_ID('app') IS NULL CREATE SCHEMA app` | `Msg 156`, incorrect syntax near the keyword 'SCHEMA' |
| `IF OBJECT_ID('dbo.v_x') IS NULL EXEC sp_executesql N'CREATE VIEW dbo.v_x AS ...'` | works |
| `CREATE OR ALTER VIEW dbo.v_x AS ...` | works, inside and outside a transaction |
| `DROP TABLE IF EXISTS dbo.t` | works |

## Rename, contract, and drop then re-add

**`sp_rename` on a column raises no error.** `EXEC sp_rename 'dbo.parts.sku', 'part_number',
'COLUMN'` succeeds, and the driver receives one informational message:

```text
[01000] (15477)  Caution: Changing any part of an object name could break scripts and
                 stored procedures.
```

A view and a procedure written over `sku` then fail with `Msg 207, Invalid column name 'sku'` at
the next `SELECT` and the next `EXEC`. `sys.sql_expression_dependencies` still returns both
referencing objects against `dbo.parts` with `is_ambiguous = 0`, so the dependency metadata gives
no signal that either is broken.

**Contract breaks an instance that has not been replaced, one statement at a time.** Insert from
one connection, run `ALTER TABLE dbo.parts2 DROP COLUMN legacy_note` from another, then return to
the first connection:

```text
its very next INSERT naming legacy_note   Msg 207, Invalid column name 'legacy_note'
its SELECT *                              still works, with one fewer column
```

**`DROP COLUMN` frees neither space nor row budget.** Take a table
`dbo.wide2(id int IDENTITY PRIMARY KEY, a char(4000) NOT NULL, b char(3000) NOT NULL)` with a few
hundred rows, drop `a`, and add it back:

```text
ALTER TABLE dbo.wide2 ADD a char(4000) NOT NULL DEFAULT ''
  Msg 1701: Creating or altering table 'wide2' failed because the minimum row size would be
  11011, including 7 bytes of internal overhead. This exceeds the maximum allowable table
  row size of 8060 bytes.
```

`used_page_count` does not change when the column is dropped. After `ALTER TABLE dbo.wide2
REBUILD` it falls, and the re-add succeeds.

11011 is the row size counting the dropped `char(4000)`, which no longer appears in
`sys.columns`. On Azure SQL Database `sys.system_internals_partition_columns`, the catalog view
that would show it, returns `Msg 208, Invalid object name`, so the space cannot be inspected
directly.

**An unnamed default constraint gets a name you did not choose.** A column declared
`qty int NOT NULL DEFAULT (0)` gets a generated name such as `DF__parts__qty__123EB7A3`.
`ALTER TABLE dbo.parts DROP COLUMN qty` then fails with
`Msg 5074, The object 'DF__parts__qty__123EB7A3' is dependent on column 'qty'`. Looking the name up
in `sys.default_constraints` and dropping it through `sp_executesql` succeeds. The generated suffix
differs per environment, so a script naming it literally works where it was written and nowhere
else.

## Assumptions that are false here

- **"Online index operations cannot run inside an explicit transaction."** False on Azure SQL
  Database: `CREATE INDEX ... WITH (ONLINE = ON)` and `ALTER TABLE ... REBUILD WITH (ONLINE = ON)`
  both run inside `BEGIN TRAN` and commit.
- **`WAIT_AT_LOW_PRIORITY` as a general answer to the convoy.** It is rejected with `Msg 102` on
  `ALTER TABLE ... ALTER COLUMN`, so it covers rebuilds only. `SET LOCK_TIMEOUT` is the setting that
  applies to every statement.
- **Near zero log bytes as proof of a metadata only change.** A driver transaction opened with
  autocommit off rolls each case back and makes every alteration look metadata only; see
  [Before you run these](#before-you-run-these).
- **The `sp_rename` caution as a warning the operator sees.** It is class 01, informational. The
  client library puts it in a messages collection and raises nothing. A runner that logs only
  exceptions logs nothing.
