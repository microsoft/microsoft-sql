> Supporting Azure SQL guidance for `check-live-blocking`. This is a reference, not a separate skill entry point. Follow the owning skill for task scope and authorization.

# Diagnose blocking and read a deadlock on Azure SQL Database

**Two empty results, two different causes, and the fix for one does nothing for the other.** The
blocking DMVs answer only as far as the login's grant reaches. Extended Events does not work the way
SQL Server taught you: Microsoft Learn states there is
[no built-in `system_health` session in Azure SQL Database](https://learn.microsoft.com/sql/relational-databases/extended-events/use-the-system-health-session#the-system_health-session-in-azure-sql)
and that sessions are database-scoped, so nothing captured your deadlock unless someone built a
session first.

| What you see | Cause | Fix |
|---|---|---|
| one row, `blocking_session_id = 0`, no error, while a real chain runs | the login cannot see past its own session | section 1, and which grant depends on the service objective |
| `Msg 208, Invalid object name 'sys.dm_xe_sessions'` | there are no server-scoped Extended Events views here | section 5. No grant and no `master` produces them |

No permission moves the second one:
[`VIEW SERVER STATE` cannot be granted in Azure SQL Database](https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-objects/sys-dm-exec-requests-transact-sql#permissions)
at all.

Each section is cited to Learn below. A local Azure SQL Database container (`EngineEdition` 5,
`Edition` `SQL Azure`) differs from the cloud service on section 5: it carries a `master` and a
`system_health` session that the cloud service does not, so do not read deadlocks out of them;
section 5 follows Learn. Blocks run once this helper exists:

```bash
export SQL_SERVER="<server>.database.windows.net" SQL_DB="<database>" SQL_USER="<login>"
# Export SQLCMDPASSWORD from your secret store (never a file in the repository); sqlcmd reads it from
# the environment, so the password stays off the command line. Encryption is on and the server
# certificate is validated: never add -C (trust server certificate) for *.database.windows.net.
q() {
  sqlcmd -S "$SQL_SERVER" -d "${2:-$SQL_DB}" -U "$SQL_USER" -N mandatory -b -I -W -Q "$1"
}
```

With Microsoft Entra ID, replace `-U "$SQL_USER"` with `--authentication-method ActiveDirectoryDefault`
and no password is needed.

`-I` is for section 5: `.nodes()` needs `QUOTED_IDENTIFIER` ON or it fails with `Msg 1934` naming
that setting rather than Extended Events. With go-sqlcmd (`sqlcmd` 1.x) it is always on; with the
`mssql-tools` `sqlcmd` it is not.

## 1. Prove the login can see past its own session

```bash
q "SELECT HAS_PERMS_BY_NAME(DB_NAME(), 'DATABASE', 'VIEW DATABASE STATE') AS can_see_others,
          DATABASEPROPERTYEX(DB_NAME(), 'ServiceObjective') AS slo;"
```

`1` and the results below mean what they say. `NULL` means the class or permission name was
mistyped. `0` and every empty result is worthless, and **which grant fixes it depends on the second
column**, which returns `Basic`, `S0`, `S1`, `S2`, `S3`, `P1` to `P3` or `ElasticPool`. On `Basic`,
`S0`, `S1` and any `ElasticPool` database `VIEW DATABASE STATE` is not enough: it takes the server
admin, the Microsoft Entra admin, or the server role, from `master`.

```bash
q "ALTER SERVER ROLE [##MS_ServerStateReader##] ADD MEMBER [<login>];" master
```

Learn carries that split on every DMV this page uses, including
[sys.dm_exec_connections](https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-objects/sys-dm-exec-connections-transact-sql#permissions),
and says the role takes minutes to take effect. Elsewhere run
`GRANT VIEW DATABASE STATE TO [<login>];` in that database instead. Either way the chain appears.

## 2. Prove which lock manager you are on

```bash
q "SELECT is_optimized_locking_on, is_read_committed_snapshot_on,
          is_accelerated_database_recovery_on
     FROM sys.databases WHERE database_id = DB_ID();"
```

Expect `1 1 1`. Not a local quirk: Learn lists optimized locking as
[always enabled on Azure SQL Database](https://learn.microsoft.com/sql/relational-databases/performance/optimized-locking#availability)
along with accelerated database recovery, and read committed snapshot as on by default. A `0` here
means the classic lock manager's names apply and every wait name on this page does not.

## 3. Find the block without assuming the blocker has a request row

```bash
q "SELECT r.session_id AS blocked, r.blocking_session_id AS blocker, r.wait_type, r.wait_resource,
          CASE WHEN EXISTS (SELECT 1 FROM sys.dm_exec_requests AS r2
                            WHERE r2.session_id = r.blocking_session_id)
               THEN 'active request' ELSE 'idle, open transaction' END AS blocker_state
     FROM sys.dm_exec_requests AS r WHERE r.blocking_session_id > 0;"
```

Whatever appears as `blocker` and never as `blocked` is the head blocker. Do not anchor a recursive
walk on "rows where `blocking_session_id = 0`": a sleeping head blocker has no request row to
anchor on, so that walk returns zero rows for the whole chain.

## 4. Name the head blocker and what it last ran

An idle head blocker has no current statement, so take its text from the connection:

```bash
q "SELECT s.session_id, s.status, s.open_transaction_count, s.last_request_end_time, t.text
     FROM sys.dm_exec_sessions AS s
     JOIN sys.dm_exec_connections AS c ON c.session_id = s.session_id
     CROSS APPLY sys.dm_exec_sql_text(c.most_recent_sql_handle) AS t
    WHERE s.is_user_process = 1
      AND EXISTS (SELECT 1 FROM sys.dm_tran_session_transactions AS x
                  WHERE x.session_id = s.session_id)
      AND NOT EXISTS (SELECT 1 FROM sys.dm_exec_requests AS r
                      WHERE r.session_id = s.session_id);"
```

`status = sleeping` with `open_transaction_count > 0` is an application holding a transaction open
between statements: a head blocker with no row at all in `sys.dm_exec_requests`.

## 5. Read a completed deadlock, out of the session that captured it

Sessions are database-scoped, so they are found through the database-scoped views, in the user
database, never `master`:

```bash
q "SELECT name FROM sys.dm_xe_database_sessions;"
```

Zero rows is an answer, not a failure: nothing is capturing, the deadlock that already happened is
gone, and the next one will be too. create-xe-session builds the session, on Learn's
event `sqlserver.database_xml_deadlock_report`. With a ring buffer session named `deadlocks`
running, this is Learn's own read of it:

```bash
q "DECLARE @tracename sysname = N'deadlocks';
   WITH ring_buffer AS (
     SELECT CAST(t.target_data AS XML) AS rb
       FROM sys.dm_xe_database_sessions AS s
       JOIN sys.dm_xe_database_session_targets AS t
         ON CAST(t.event_session_address AS BINARY(8)) = CAST(s.address AS BINARY(8))
      WHERE s.name = @tracename AND t.target_name = N'ring_buffer')
   SELECT d.evtdata.query('.') AS deadlock_report
     FROM ring_buffer
    CROSS APPLY rb.nodes('/RingBufferTarget/event[@name=''database_xml_deadlock_report'']') AS d(evtdata);"
```

`sqlserver.xml_deadlock_report` is a different, server-scoped event that does not exist on Azure SQL
Database. Name whichever you mean exactly.

**Read the graph as a pair.** `<victim-list>` names the loser, `<process-list>` carries both
processes and their `<inputbuf>`, and `<resource-list>` an `<xactlock>` per contested resource with
its `<owner-list>` and `<waiter-list>`. The fix follows from the pair: two objects touched in
opposite order, fixed by ordering them, or a range with no narrow index, fixed by adding one.

## 6. Reproduce a block on demand, to test any of the above

**Test database only, and ask first.** Unlike the rest of this page, this section writes: it creates
a table and then drops it. The first command stops if a table of that name already exists, so it
never touches one it did not create.

```bash
q "IF OBJECT_ID(N'dbo.blocking_repro_test') IS NOT NULL THROW 50000, 'dbo.blocking_repro_test already exists; not touching it', 1;
   CREATE TABLE dbo.blocking_repro_test (id int PRIMARY KEY, v int); INSERT dbo.blocking_repro_test VALUES (1,10),(2,20);"
q "BEGIN TRAN; UPDATE dbo.blocking_repro_test SET v = v + 1 WHERE id = 1; WAITFOR DELAY '00:00:20'; ROLLBACK;" &
sleep 2
q "BEGIN TRAN; UPDATE dbo.blocking_repro_test SET v = v + 5 WHERE id = 1; ROLLBACK;" &
sleep 2
q "SELECT * FROM dbo.blocking_repro_test WHERE id = 1;"
q "SELECT * FROM dbo.blocking_repro_test WITH (READCOMMITTEDLOCK) WHERE id = 1;"
```

The first `SELECT` returns `1 10` at once: read committed snapshot versions it, so it neither blocks
nor sees the uncommitted `11`. The second waits, because `READCOMMITTEDLOCK` is Learn's documented
way to force blocking back on. Then drop the table this section created:
`DROP TABLE dbo.blocking_repro_test;`.

## Check it worked

Run all three. Each has one stated answer, and a diagnosis holds only when all three do.

```bash
q "SELECT HAS_PERMS_BY_NAME(DB_NAME(),'DATABASE','VIEW DATABASE STATE') AS grant_ok,
          DATABASEPROPERTYEX(DB_NAME(),'ServiceObjective') AS slo;"
q "SELECT COUNT(*) AS capture_running FROM sys.dm_xe_database_sessions;"
q "SELECT resource_type, request_mode, request_status FROM sys.dm_tran_locks
    WHERE request_session_id <> @@SPID AND resource_type IN ('PAGE','RID','KEY','XACT');"
```

- `grant_ok = 1`, so "nothing is blocked" means nothing is blocked, not "I cannot see it". On
  `Basic`, `S0`, `S1` or `ElasticPool` that `1` alone is not enough; section 1's role settles it.
- `capture_running` above `0`, so "no deadlock recorded" is about your workload. `0` means nothing
  was capturing and the answer is about your tooling.
- Run during section 6, the third returns `XACT`, mode `X`, status `GRANT`. A `KEY` row instead
  means optimized locking is off and every wait name above is the wrong one.

## Do not

- Do not report "nothing is blocked" from a single-row result. It succeeds and looks complete
  whether or not the login can see past itself.
- Do not hunt for a `system_health` session, and do not reconnect to `master` to find one. Learn
  states there is no built-in one here and that sessions are database-scoped, so `Msg 208` from
  `sys.dm_xe_sessions` is the correct answer, not a context bug, and no grant moves it. A local
  Azure SQL Database container carries both, so a result read there does not carry over.
- Do not read deadlocks out of the built-in `dl` session. Learn says not to:
  `sys.fn_xe_file_target_read_file()` over many collected deadlock events can raise an
  out-of-memory error in `master`, disrupt login processing, and take the application down.
- Do not predict that a plain `SELECT` blocks behind an uncommitted write, and do not read a wait
  type against the classic lock manager's names alone. `LCK_M_S_XACT_MODIFY` against an `XACT`
  resource is optimized locking working as designed.
- Do not conclude a deadlock report names only the victim. `<process-list>` carries both, and a fix
  that changes only the victim usually changes nothing.

## References

- [Checks you can run: the permission gap, the idle chain, the deadlock graph, and why `master` is not a route](references/blocking-visibility-and-deadlock-graphs.md): open it before disputing a wait type or either empty result, or to rerun the sequence behind one.
- [Optimized locking](https://learn.microsoft.com/sql/relational-databases/performance/optimized-locking):
  open it when a lock or wait shape here does not match what you see, for the full wait-type list.
