# Blocking visibility and deadlock graphs on Azure SQL Database: what was measured

## Contents

- [How this was measured](#how-this-was-measured)
- [The blocking-chain gap: a real permission artifact](#the-blocking-chain-gap-a-real-permission-artifact)
- [The system_health result was the container](#the-system_health-result-was-the-container)
- [The idle head blocker, measured](#the-idle-head-blocker-measured)
- [The induced deadlock](#the-induced-deadlock)
- [The deadlock graph](#the-deadlock-graph)
- [Optimized locking changes the wait type](#optimized-locking-changes-the-wait-type)
- [Read committed snapshot changes who blocks whom](#read-committed-snapshot-changes-who-blocks-whom)
- [What Microsoft Learn says](#what-microsoft-learn-says)

## How this was measured

**The local Azure SQL Database container**, reporting `SERVERPROPERTY('EngineEdition')` = 5 and
`SERVERPROPERTY('Edition')` = `SQL Azure`, run 2026-08-29. Naming the substrate matters here: one
result below turned out to be a container property presented as cloud behaviour for four days. A dedicated database held every test, with two accounts:

- an administrative login, equivalent to the Azure SQL Database server admin
- an ordinary login in `db_datareader` and `db_datawriter` on the test database and nothing else,
  matching an application connection string

Two variables were moved separately: **which login** ran the query, and **which database** it was
connected to. The first section below moves only the login, the second only the database.
Concurrent sessions were separate client processes, not a simulation inside one script.

## The blocking-chain gap: a real permission artifact

Every row below is a separate command actually run, in order, and the only thing changing across
these rows is **which login** ran the query.

| Step | Command | Result |
|---|---|---|
| 1 | Ordinary login: `SELECT session_id, blocking_session_id FROM sys.dm_exec_requests` while a genuine block was running elsewhere between two other logins | Returned only its own session, `blocking_session_id = 0`. No error, no hint that anything else was blocked |
| 2 | Admin: `GRANT VIEW DATABASE STATE TO <ordinary login>` on the test database | Succeeded |
| 3 | Same ordinary login, same query, same live block | Now returned the blocked session with the correct `blocking_session_id`, `wait_type` and `status` |
| 4 | A third, previously untouched login queried `sys.dm_os_waiting_tasks` and `sys.dm_tran_locks` during the same live block, with `VIEW DATABASE STATE` already granted | Both returned every session's rows, not just its own |

Step 1 is the dangerous one, because it is not an error. The query runs, returns a well-formed
single row, and gives no sign that three other sessions are locked together. `VIEW DATABASE STATE`
is the only thing that changed between steps 1 and 3. Note the service objective this did **not**
cover: see the tier split in the Learn section below.

## The system_health result was the container

Every row below holds the login fixed and changes only **which database it is connected to**.

| Step | Command | Result |
|---|---|---|
| 1 | Ordinary login, in the test database: `SELECT name FROM sys.dm_xe_sessions` | `Msg 208, Invalid object name 'sys.dm_xe_sessions'` |
| 2 | Same, `SELECT name FROM sys.server_event_sessions` | `Msg 208, Invalid object name` |
| 3 | Admin: `GRANT VIEW SERVER STATE TO <ordinary login>`, confirmed in `sys.server_permissions` | Succeeded |
| 4 | Same ordinary login, still in the test database, step 1 repeated | Still `Msg 208`, despite the grant |
| 5 | Same login, reconnected to `master`, step 1 repeated | `hkenginexesession`, `system_health`, `sp_server_diagnostics session` |
| 6 | Admin login, in the test database | `Msg 208`, same as the ordinary login |

**Read step 5 as evidence about the container and nothing else.** Steps 1, 2, 4 and 6 generalize:
the server-scoped Extended Events views do not resolve in a user database. Step 3 does not, and is
itself a container tell, because Learn states `VIEW SERVER STATE` cannot be granted in Azure SQL
Database at all. Step 5 is the one that misled this skill until 2026-09-03: the container ships a
real `master` carrying a real `system_health` session and Azure SQL Database does not, so
reconnecting to `master` is not a fix a cloud reader can apply.

## The idle head blocker, measured

An open transaction that has issued its statement and is now waiting on the application, not on the
engine, produces a session with no row at all in `sys.dm_exec_requests`:

```text
session_id  status    open_transaction_count  active_request_session_id
77          sleeping  1                        NULL
```

A second session blocked behind it shows the correct `blocking_session_id`:

```text
session_id  status     blocking_session_id  wait_type             command
78          suspended  77                   LCK_M_S_XACT_MODIFY   UPDATE
```

A three-level chain was also measured (79 blocked by 78, 78 blocked by idle session 77). A recursive
walk anchored on `WHERE blocking_session_id = 0 OR blocking_session_id IS NULL`, meaning "start from
whoever is not blocked," never finds 77 at all, because 77 has no row to anchor on. Against this
exact chain that form returned **zero rows**, chain and all. The corrected form in section 3 of
SKILL.md walks every `blocking_session_id` present instead, and flags per blocker whether it has a
request row of its own. It returned both blocked sessions and correctly labelled 77, named only as
somebody else's `blocking_session_id`, as idle with an open transaction.

## The induced deadlock

Two sessions, opposite update order, with a `WAITFOR` to make the race deterministic:

```sql
-- Session A
BEGIN TRAN;
UPDATE dbo.accounts SET balance = balance - 10 WHERE id = 1;
WAITFOR DELAY '00:00:05';
UPDATE dbo.accounts SET balance = balance + 10 WHERE id = 2;
COMMIT;

-- Session B, started about a second later
BEGIN TRAN;
UPDATE dbo.accounts SET balance = balance - 10 WHERE id = 2;
WAITFOR DELAY '00:00:05';
UPDATE dbo.accounts SET balance = balance + 10 WHERE id = 1;
COMMIT;
```

Session A committed. Session B's caller received:

```text
Msg 1205, Level 13, State 72, Server SQL Azure, Line 7
Transaction (Process ID 78) was deadlocked on lock resources with another process and has been
chosen as the deadlock victim. Rerun the transaction.
```

The state code was 72 in this run. Treat it as informational, not something to match on: it varies
with build and lock manager. `Msg 1205` and the message text are the stable part.

## The deadlock graph

The graph below was read out of the container's `system_health` ring buffer from `master`, which is
a route Azure SQL Database does not have. **The route did not generalize; the graph's shape did.**
Section 5 of SKILL.md therefore reads the same anatomy out of a database-scoped session on
`sqlserver.database_xml_deadlock_report`, which is what Learn documents for the cloud service.

Either query calls `.nodes()`, which requires `QUOTED_IDENTIFIER` ON; without it the query fails
with `Msg 1934` naming `QUOTED_IDENTIFIER` rather than anything about permissions or Extended
Events. Which client you use decides whether you notice. Checked against local help output on
2026-09-03, `sqlcmd` 1.10.0 (go-sqlcmd) documents `-I, --enable-quoted-identifiers` as "provided for
backward compatibility. Quoted identifiers are always enabled", so it does not reproduce there; the
older `mssql-tools` `sqlcmd` does not set it. Pass `-I` and the snippet is portable across both.

The event returned within the same second as the deadlock (deadlock at `08:27:02.959`, event
timestamp `08:27:02.959Z`). The report's `<deadlock>` element carried:

- a `<victim-list>` naming the losing process
- a `<process-list>` with **two** `<process>` entries, the victim and the survivor, each with its
  `spid`, `loginname`, `hostname`, `isolationlevel`, `lasttranstarted`, and the text of the batch it
  was running in `<inputbuf>`
- a `<resource-list>` with an `<xactlock>` entry per contested key, each carrying an `<owner-list>`
  and a `<waiter-list>` naming which process held the lock and which was waiting

So the graph names the blocker, not only the victim. The raw event is not reprinted: its stack-frame
addresses alone run past a thousand characters.

**Name this event precisely.** What was read here is `sqlserver.xml_deadlock_report`, the
server-scoped event the container's `system_health` session fires.
`sqlserver.database_xml_deadlock_report` is a different, database-scoped event, and it is the one
Azure SQL Database has. capture-with-extended-events measured that one capturing zero events across
two confirmed deadlocks on the container, and states that gap is unreproduced against the cloud
service. Two similarly named events, not two measurements of one; do not cite either as evidence
for the other.

## Optimized locking changes the wait type

All three flags were `1` with no opt-in step taken. Re-measured 2026-09-02 across four consecutive
fresh databases: `1/1/1` every time. A fifth run reported read committed snapshot off, did not
reproduce, and should be read as transient. Re-run before concluding the default has changed.

A plain writer-vs-writer block, no deadlock, produced this wait, not the classic `LCK_M_U` or
`LCK_M_X` against a `KEY:` resource:

```text
session_id  status     blocking_session_id  wait_type
78          suspended  77                    LCK_M_S_XACT_MODIFY
```

and in `sys.dm_os_waiting_tasks`:

```text
resource_description: xactlock xdesIdLow=996 xdesIdHigh=0 dbid=7 id=lockc80746800 mode=X
                       UnderlyingResource keylock hobtid=72057594047627264 dbid=7
```

and in `sys.dm_tran_locks`:

```text
request_session_id  resource_type  request_mode  request_status
78                   XACT           X             GRANT
```

Advice written against the classic lock manager looks for a `KEY` resource type and a `U` or `X`
request mode, and will not recognize this as the same block. It is the same block, described in
terms of the transaction ID that owns it, with the underlying key as a secondary detail.

## Read committed snapshot changes who blocks whom

Session C updated `id = 1` and held the transaction open; session D's plain `SELECT ... WHERE id = 1`
issued while C was open returned the value from before C started, immediately, with no wait. Not a
dirty read and not a blocked read: a versioned one. Only a second **writer** against the same row
blocked, as shown above. An agent expecting the classic default will predict blocking this database
does not produce, and will also expect the in-flight value rather than the pre-transaction one.

## What Microsoft Learn says

Read 2026-09-03, cited rather than copied. These settle whether the measurements above generalize
past this one engine.

- **Optimized locking is always on in the cloud, not only on the container build.**
  [Optimized locking, Availability](https://learn.microsoft.com/sql/relational-databases/performance/optimized-locking#availability)
  lists Azure SQL Database as "Yes (always enabled)", and the same page states accelerated database
  recovery is always enabled there and read committed snapshot on by default. So the `1/1/1`
  measured locally is the cloud's behaviour too and the `_XACT_` wait shapes are not a local
  artifact. A self-hosted engine is the opposite case, where it is available but off by default,
  which is why advice written for one does not carry over.
- **The three wait types, named exactly.** The same page lists `LCK_M_S_XACT_READ`,
  `LCK_M_S_XACT_MODIFY` and `LCK_M_S_XACT`, `XACT` resources in `sys.dm_tran_locks` and
  `sys.dm_exec_requests`, and an `<xactlock>` per resource in the report's `<resource-list>`. Only
  `LCK_M_S_XACT_MODIFY` was reproduced here; the other two are documented, not induced.
- **`READCOMMITTEDLOCK` is the documented way to force blocking back on.** Same page, FAQ.
- **`VIEW DATABASE STATE` cannot be granted in `master`.**
  [sys.dm_exec_sessions, Permissions](https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-objects/sys-dm-exec-sessions-transact-sql#permissions)
  states it plainly, so the two gaps in this file cannot share a fix even by accident. The same
  page's example C is the documented idiom for idle sessions holding open transactions, which
  section 4 of SKILL.md uses.
- **There is no built-in `system_health` session on Azure SQL Database. This file said the opposite
  until 2026-09-03.**
  [Use the system_health session](https://learn.microsoft.com/sql/relational-databases/extended-events/use-the-system-health-session#the-system_health-session-in-azure-sql)
  states it plainly, and Azure SQL Database is not in that page's applies-to line.
  [Extended Events in Azure SQL](https://learn.microsoft.com/azure/azure-sql/database/xevent-db-diff-from-svr)
  gives the reason, that sessions there are always database-scoped, created `ON DATABASE` and read
  through `sys.dm_xe_database_sessions`, and warns not to read deadlocks out of the built-in `dl`
  session because `sys.fn_xe_file_target_read_file()` over many events can raise an out-of-memory
  error in `master`. The documented cloud route is a database-scoped session on
  `sqlserver.database_xml_deadlock_report`:
  [Analyze and prevent deadlocks](https://learn.microsoft.com/azure/azure-sql/database/analyze-prevent-deadlocks#collect-deadlock-graphs-in-azure-sql-database-with-extended-events).
- **The tier split on `VIEW DATABASE STATE`,** carried on every DMV this skill uses, including
  [sys.dm_exec_connections](https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-objects/sys-dm-exec-connections-transact-sql#permissions):
  on Basic, S0, S1 and elastic pool databases it takes the server admin, the Microsoft Entra admin,
  or `##MS_ServerStateReader##`; everywhere else `VIEW DATABASE STATE` is enough.
  [Monitor performance using DMVs](https://learn.microsoft.com/azure/azure-sql/database/monitoring-with-dmvs#permissions)
  gives the grant, `ALTER SERVER ROLE [##MS_ServerStateReader##] ADD MEMBER [login];` in `master`,
  and notes it takes minutes. The 2026-08-29 run was administrative throughout and never crossed
  this boundary, so this one is cited, not measured.
