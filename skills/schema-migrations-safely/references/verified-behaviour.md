# Verified behaviour: every run behind the migration doctrine

## Contents

- [The engine and the fixture](#the-engine-and-the-fixture)
- [Run 1: metadata only versus rewrite](#run-1-metadata-only-versus-rewrite)
- [Run 2: does a schema lock block a snapshot reader](#run-2-does-a-schema-lock-block-a-snapshot-reader)
- [Run 3: the convoy behind a pending schema change](#run-3-the-convoy-behind-a-pending-schema-change)
- [Run 4: lock timeout, online, and wait at low priority](#run-4-lock-timeout-online-and-wait-at-low-priority)
- [Run 5: eight instances migrating at startup](#run-5-eight-instances-migrating-at-startup)
- [Run 6: a migration under a retry policy, faulted mid script](#run-6-a-migration-under-a-retry-policy-faulted-mid-script)
- [Run 7: what parses as an idempotent script](#run-7-what-parses-as-an-idempotent-script)
- [Run 8: rename, contract, and drop then re-add](#run-8-rename-contract-and-drop-then-re-add)
- [What did not hold](#what-did-not-hold)
- [Reproducing this](#reproducing-this)

## The engine and the fixture

All runs 2026-08-28, on one engine, one database.

```text
SERVERPROPERTY('EngineEdition')   5
SERVERPROPERTY('Edition')         SQL Azure
compatibility_level               170
is_read_committed_snapshot_on     1
snapshot_isolation_state_desc     ON
```

Fixture, in `appdb`:

```sql
CREATE TABLE dbo.orders (
  id int IDENTITY(1,1) PRIMARY KEY,
  customer_id int NOT NULL,
  status varchar(20) NOT NULL,
  amount decimal(12,2) NOT NULL,
  note nvarchar(100) NULL,
  created_at datetime2 NOT NULL DEFAULT SYSUTCDATETIME()
);
-- 2,000,000 rows, 230 MB reserved
```

Concurrency was driven by separate client connections, one per thread, not by nested batches.

## Run 1: metadata only versus rewrite

Each statement ran inside `BEGIN TRAN`, was timed, then
`sys.dm_tran_database_transactions.database_transaction_log_bytes_used` was read for
`CURRENT_TRANSACTION_ID()` before `COMMIT`.

| Statement | Time | Log bytes | Log records |
|---|---|---|---|
| `ALTER TABLE dbo.orders ADD c1 int NULL` | 3.6 ms | 1,240 | 11 |
| `ADD c2 int NOT NULL CONSTRAINT df_c2 DEFAULT (0)` | 1.7 ms | 2,200 | 19 |
| `ADD c3 uniqueidentifier NOT NULL DEFAULT (NEWID())` | **4,585 ms** | **448,002,068** | **2,000,018** |
| `ADD c4 datetime2 NOT NULL DEFAULT (SYSUTCDATETIME())` | 1.5 ms | 2,220 | 19 |
| `ADD c5 varchar(max) NULL` | 1.6 ms | 2,336 | 23 |
| `ALTER COLUMN status varchar(50) NOT NULL` (from 20) | 1.0 ms | 1,068 | 10 |
| `ALTER COLUMN status varchar(max) NOT NULL` | **7,260 ms** | **572,400,240** | **2,000,018** |
| `ALTER COLUMN note2 nvarchar(50)` (from `varchar(50)`) | **5,070 ms** | **426,473,648** | **2,000,027** |
| `ALTER COLUMN customer_id bigint NOT NULL` | **6,053 ms** | **508,588,372** | **2,000,018** |
| `ALTER COLUMN note nvarchar(100) NOT NULL` (from `NULL`) | **14,508 ms** | **661,262,280** | **2,000,023** |
| `ADD CONSTRAINT ck_amt CHECK (amount >= 0)` | 521 ms | 1,704 | 17 |
| `WITH NOCHECK ADD CONSTRAINT ck_amt2 CHECK (...)` | 1.5 ms | 1,388 | 12 |
| `DROP COLUMN c5` | 2.9 ms | 1,224 | 12 |
| `CREATE INDEX ix_off ON dbo.orders(customer_id)` | 628 ms | 37,714,632 | 4,510 |
| `CREATE INDEX ix_on ON dbo.orders(amount) WITH (ONLINE=ON)` | 3,489 ms | 1,712 | 12 |

`sys.dm_tran_locks` sampled from a second session while each transaction was open showed
`OBJECT` / `Sch-M` for every `ALTER TABLE`, and `HOBT` / `Sch-M` plus `OBJECT` / `Sch-S` for the
index builds.

A first pass of this run reported near zero log bytes for most statements. The cause was the client
being opened with autocommit off, so an outer driver transaction wrapped the explicit one and
rolled everything back at close. The table above is the corrected run, with autocommit on and
`BEGIN TRAN` and `COMMIT` issued explicitly. Worth recording, because the first pass looked
plausible.

## Run 2: does a schema lock block a snapshot reader

Session A: `BEGIN TRAN; ALTER TABLE dbo.orders ADD z1 int NULL;` held open 3 seconds, then
committed. Three readers started 0 ms later, one per connection.

```text
sys.dm_exec_requests, 2 s in:
  52  LCK_M_SCH_S  wait_time 2047  blocked by 51
  53  LCK_M_SCH_S  wait_time 2044  blocked by 52
  54  LCK_M_SCH_S  wait_time 2042  blocked by 52

elapsed at the client:
  default read committed snapshot   3,098 ms
  SET TRANSACTION ISOLATION LEVEL SNAPSHOT, explicit tran   3,102 ms
  SELECT ... WITH (NOLOCK)          3,100 ms
```

All three waited the full hold. The `ALTER` itself was a 2 ms metadata only change; what blocked
was the transaction holding `Sch-M`, not the work.

## Run 3: the convoy behind a pending schema change

Session A: `BEGIN TRAN; SELECT TOP 1 id FROM dbo.orders WITH (REPEATABLEREAD); WAITFOR DELAY
'00:00:10'; COMMIT;`
Session B, 1 s later: `ALTER TABLE dbo.orders ADD z1 int NULL`.
Sessions C, D, E, 1 s after that: `SELECT TOP 1 id FROM dbo.orders`.

```text
sys.dm_exec_requests, 3 s in:
  51  LCK_M_SCH_M  blocked by 54   ALTER TABLE dbo.orders ADD z1 int NULL
  52  LCK_M_SCH_S  blocked by 51   SELECT TOP 1 id FROM dbo.orders
  53  LCK_M_SCH_S  blocked by 51   SELECT TOP 1 id FROM dbo.orders
  55  LCK_M_SCH_S  blocked by 51   SELECT TOP 1 id FROM dbo.orders

elapsed:
  long reader        10,011 ms
  ALTER (2 ms work)   9,017 ms
  tiny SELECT #0      8,025 ms
  tiny SELECT #1      8,020 ms
  tiny SELECT #2      8,023 ms
```

The three trivial reads are blocked by the `ALTER`, not by the long reader. This is what turns a
metadata only change into a full stall.

## Run 4: lock timeout, online, and wait at low priority

**`SET LOCK_TIMEOUT 2000` in front of an offline `ALTER COLUMN`**, same 10 second reader in flight:

```text
the ALTER          ERR Msg 1222, Lock request time out period exceeded,  2,099 ms
tiny SELECT #0     1,095 ms
tiny SELECT #1     1,077 ms
```

Compare the 8,020 ms in run 3 with no timeout set.

**Online versus offline on the same column**, `w2`, no index and no default constraint on it, so
neither form is refused. Two concurrent `SELECT TOP 1` readers started 1.2 s into the change:

| Statement | Its own time | Reader 1 | Reader 2 |
|---|---|---|---|
| `ALTER COLUMN w2 bigint NULL` | 8,369 ms | 7,169 ms | 7,169 ms |
| `ALTER COLUMN w2 int NULL WITH (ONLINE = ON)` | 4,085 ms | 75 ms | 95 ms |
| `ALTER COLUMN w2 bigint NULL WITH (ONLINE = ON)` | 3,513 ms | 74 ms | 76 ms |

`sys.dm_exec_requests` showed `LCK_M_SCH_S` waiters during the offline run and none during either
online run.

**Online does not convoy.** With the 10 second reader in flight and an online `ALTER COLUMN`
waiting behind it, `SELECT`s arriving after the `ALTER` returned in 80 and 82 ms, against 8,020 ms
for the offline form in run 3.

**Where `ONLINE = ON` is accepted:**

| Statement | Result |
|---|---|
| `ALTER TABLE ... ALTER COLUMN ... WITH (ONLINE = ON)` | accepted |
| `ALTER TABLE ... REBUILD WITH (ONLINE = ON)` | accepted, 2,961 ms |
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

## Run 5: eight instances migrating at startup

Fixture reset before each mode: `dbo.__migrations(version int PRIMARY KEY, applied_at)` and
`dbo.customers(id, name, tier int NOT NULL DEFAULT 0)` with 500 rows, all `tier = 0`.

Each of eight threads, on its own connection, checked the history table and, if version 1 was
absent, ran four statements with a 50 ms pause between them:

```text
1  ALTER TABLE dbo.customers ADD region nvarchar(20) NULL
2  UPDATE dbo.customers SET tier = tier + 1
3  CREATE INDEX ix_cust_tier ON dbo.customers(tier)
4  INSERT INTO dbo.__migrations (version) VALUES (1)
```

Correct final state is version count 1, `region` present, index present, `SUM(tier) = 500`.

| Mode | Decided to apply | Errors | Final `SUM(tier)` |
|---|---|---|---|
| no guards, no transaction | 8 | 7 x `Msg 2705` on statement 1 | 500 |
| `IF NOT EXISTS` guards on 1 and 3, no transaction | 8 | 7 x `Msg 2627` on statement 4 | **4000** |
| the same guards, all four inside one transaction | 8 | 7 x `Msg 2627` on statement 4 | 500 |
| `sp_getapplock` Exclusive, Transaction owner, before the check | **1 applied, 7 skipped** | **0** | 500 |

Exact messages:

```text
2705  Column names in each table must be unique. Column name 'region' in table
      'dbo.customers' is specified more than once.
2627  Violation of PRIMARY KEY constraint 'PK____migrat__...'. Cannot insert duplicate key
      in object 'dbo.__migrations'. The duplicate key value is (1).
```

Row two is the one that matters. The guards did their job, every runner passed them, and the
un-guardable `UPDATE` ran eight times. The only error surfaced on the history insert, after the
data was already wrong.

Related re-run errors, captured separately: `Msg 2714` for a `CREATE TABLE` or a named constraint
that already exists, `Msg 1913` for an index name that already exists.

## Run 6: a migration under a retry policy, faulted mid script

Migration: the same guarded four steps, with `WAITFOR DELAY '00:00:03'` inserted before the history
insert to stand in for the rest of a real migration. Runner: retry up to three attempts, treating a
broken connection or a documented transient error number as retriable, which is the shape every
data access guide teaches. Fault: a second session issued `KILL <spid>` 1.5 s into attempt 1, which
lands inside the `WAITFOR`, that is after the backfill committed and before the history row.

**No transaction:**

```text
attempt 1: FAILED err=None [TRANSIENT -> retried]
           [Microsoft][ODBC Driver 18 for SQL Server]Unspecified error occurred on SQL Server.
           Connection may have been terminated by the server. (0)
attempt 2: applied, no error
runner reported success: True
final: versions 1, region present, SUM(tier) = 1000     <- correct is 500
```

**Same script, all steps inside one transaction, same fault at the same point:**

```text
attempt 1: FAILED, same transient classification
attempt 2: applied, no error
runner reported success: True
final: versions 1, region present, SUM(tier) = 500      <- correct
```

The hazard reproduces. Nothing raised, nothing logged, exit zero, data doubled. Two caveats stated
plainly: the fault was injected with `KILL` rather than by waiting for a real transient fault, and
what the client saw was a broken connection with no SQL error number, surfaced by the driver as
native error 0. That is the class of failure transient fault policies exist to retry, so the
classification in the harness is the same one a production policy would make, but it is not proof
that a specific library's classifier would agree.

**Transaction limits found while testing this**, each attempted inside `BEGIN TRAN`:

| Statement | Inside a transaction |
|---|---|
| `CREATE INDEX`, offline or `WITH (ONLINE = ON)` | accepted |
| `ALTER TABLE ... REBUILD WITH (ONLINE = ON)` | accepted |
| `ALTER DATABASE CURRENT SET COMPATIBILITY_LEVEL = 160` | **`Msg 226`**, not allowed within a multi statement transaction |

## Run 7: what parses as an idempotent script

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

## Run 8: rename, contract, and drop then re-add

**`sp_rename` on a column.** `EXEC sp_rename 'dbo.parts.sku', 'part_number', 'COLUMN'` raised no
error. The driver received one informational message:

```text
[01000] (15477)  Caution: Changing any part of an object name could break scripts and
                 stored procedures.
```

A view and a procedure written over `sku` then failed with `Msg 207, Invalid column name 'sku'` at
the next `SELECT` and the next `EXEC`. `sys.sql_expression_dependencies` still returned both
referencing objects against `dbo.parts` with `is_ambiguous = 0`, so the dependency metadata gives
no signal that either is broken.

**Contract, from the point of view of an instance that has not been replaced.** A connection
inserted successfully, another session ran `ALTER TABLE dbo.parts2 DROP COLUMN legacy_note`, then
the same connection:

```text
its very next INSERT naming legacy_note   Msg 207, Invalid column name 'legacy_note'
its SELECT *                              still works, with one fewer column
```

**Drop then re-add.** Table `dbo.wide2(id int IDENTITY PRIMARY KEY, a char(4000) NOT NULL,
b char(3000) NOT NULL)`, 200 rows.

```text
used_page_count before DROP COLUMN a      202
used_page_count after  DROP COLUMN a      202          <- nothing reclaimed
ALTER TABLE dbo.wide2 ADD a char(4000) NOT NULL DEFAULT ''
  Msg 1701: Creating or altering table 'wide2' failed because the minimum row size would be
  11011, including 7 bytes of internal overhead. This exceeds the maximum allowable table
  row size of 8060 bytes.
ALTER TABLE dbo.wide2 REBUILD
used_page_count after REBUILD             102
re-add after REBUILD                      succeeded
```

11011 is the row size counting the dropped `char(4000)`, which no longer appears in
`sys.columns`. `sys.system_internals_partition_columns`, the catalog view that would show it,
returned `Msg 208, Invalid object name` here, so the space cannot be inspected directly.

**Unnamed default constraint.** A column declared `qty int NOT NULL DEFAULT (0)` produced
`DF__parts__qty__123EB7A3`. `ALTER TABLE dbo.parts DROP COLUMN qty` failed with
`Msg 5074, The object 'DF__parts__qty__123EB7A3' is dependent on column 'qty'`. Looking the name up
in `sys.default_constraints` and dropping it through `sp_executesql` succeeded. The generated suffix
differs per environment, so a script naming it literally works where it was written and nowhere
else.

## What did not hold

- **"Online index operations cannot run inside an explicit transaction."** Expected, and false
  here. `CREATE INDEX ... WITH (ONLINE = ON)` and `ALTER TABLE ... REBUILD WITH (ONLINE = ON)` both
  ran inside `BEGIN TRAN` and committed. The claim was dropped rather than softened.
- **`WAIT_AT_LOW_PRIORITY` as a general answer to the convoy.** It is rejected with `Msg 102` on
  `ALTER TABLE ... ALTER COLUMN`, so it covers rebuilds only. `SET LOCK_TIMEOUT` is the setting that
  applies to every statement.
- **A first attempt at run 1** reported near zero log bytes for almost every statement, which would
  have made every alteration look metadata only. Cause was an outer driver transaction rolling each
  case back. Corrected before anything was written down.
- **The `sp_rename` caution as a warning the operator sees.** It is class 01, informational. The
  client library surfaced it in a messages collection and raised nothing. A runner that logs only
  exceptions logs nothing.

## Reproducing this

Everything above needs one Azure SQL Database engine, a table large enough that a rewrite is
visible, and two or more client connections. Two sessions are enough for runs 2, 3, 4 and 8, and
eight for run 5. The measurements that matter are wall clock at the client, `wait_type` and
`blocking_session_id` from `sys.dm_exec_requests` sampled from an uninvolved session, and
`database_transaction_log_bytes_used` from `sys.dm_tran_database_transactions` read before the
commit. Open every session with autocommit on and issue `BEGIN TRAN` explicitly, or the driver's
own transaction will silently undo the case being measured.
