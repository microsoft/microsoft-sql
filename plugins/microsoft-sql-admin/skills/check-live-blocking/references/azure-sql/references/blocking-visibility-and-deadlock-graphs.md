# Blocking visibility and deadlock graphs on Azure SQL Database: checks you can run

## Contents

- [What you need](#what-you-need)
- [A login without VIEW DATABASE STATE sees only itself](#a-login-without-view-database-state-sees-only-itself)
- [Server-scoped Extended Events views do not resolve in a user database](#server-scoped-extended-events-views-do-not-resolve-in-a-user-database)
- [An idle head blocker has no request row](#an-idle-head-blocker-has-no-request-row)
- [Induce a deadlock](#induce-a-deadlock)
- [The deadlock graph](#the-deadlock-graph)
- [Optimized locking changes the wait type](#optimized-locking-changes-the-wait-type)
- [Read committed snapshot changes who blocks whom](#read-committed-snapshot-changes-who-blocks-whom)
- [What Microsoft Learn says](#what-microsoft-learn-says)

## What you need

A dedicated test database on Azure SQL Database (`SERVERPROPERTY('EngineEdition')` = 5,
`SERVERPROPERTY('Edition')` = `SQL Azure`) and two logins:

- an administrative login, equivalent to the Azure SQL Database server admin
- an ordinary login in `db_datareader` and `db_datawriter` on the test database and nothing else,
  matching an application connection string

Run concurrent sessions as separate client processes, not as a simulation inside one script. The
first check below changes only **which login** runs the query, the second only **which database**
it is connected to.

## A login without VIEW DATABASE STATE sees only itself

Without `VIEW DATABASE STATE`, a login's blocking DMVs return only its own session, with no error.
Run each row as a separate command, in order; only **which login** runs the query changes.

| Step | Command | Result |
|---|---|---|
| 1 | Ordinary login: `SELECT session_id, blocking_session_id FROM sys.dm_exec_requests` while a block runs between two other logins | Returns only its own session, `blocking_session_id = 0`. No error, no hint that anything else is blocked |
| 2 | Admin: `GRANT VIEW DATABASE STATE TO <ordinary login>` on the test database | Succeeds |
| 3 | Same ordinary login, same query, same live block | Now returns the blocked session with the correct `blocking_session_id`, `wait_type` and `status` |
| 4 | A third login, with `VIEW DATABASE STATE` already granted, queries `sys.dm_os_waiting_tasks` and `sys.dm_tran_locks` during the same live block | Both return every session's rows, not just its own |

Step 1 is the dangerous one, because it is not an error. The query runs, returns a well-formed
single row, and gives no sign that other sessions are locked together. `VIEW DATABASE STATE` is the
only thing that changes between steps 1 and 3. On some service objectives that grant is not enough:
see the tier split in the Learn section below.

## Server-scoped Extended Events views do not resolve in a user database

Every row below holds the login fixed and changes only **which database it is connected to**.

| Step | Command | Result |
|---|---|---|
| 1 | Ordinary login, in the test database: `SELECT name FROM sys.dm_xe_sessions` | `Msg 208, Invalid object name 'sys.dm_xe_sessions'` |
| 2 | Same, `SELECT name FROM sys.server_event_sessions` | `Msg 208, Invalid object name` |
| 3 | Admin: `GRANT VIEW SERVER STATE TO <ordinary login>` | Learn states this cannot be granted on Azure SQL Database. A local Azure SQL Database container accepts it |
| 4 | Same ordinary login, still in the test database, step 1 repeated | Still `Msg 208`, even where the grant succeeded |
| 5 | Same login, reconnected to `master`, step 1 repeated | Azure SQL Database has no built-in `system_health` session. A local container returns `hkenginexesession`, `system_health`, `sp_server_diagnostics session` |
| 6 | Admin login, in the test database | `Msg 208`, same as the ordinary login |

Steps 1, 2, 4 and 6 hold on Azure SQL Database: the server-scoped Extended Events views do not
resolve in a user database, and no grant changes that. Steps 3 and 5 differ in a local Azure SQL
Database container, which ships a real `master` carrying a real `system_health` session. Azure SQL
Database does not, so reconnecting to `master` is not a fix on the cloud service.

## An idle head blocker has no request row

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

Add a third session so the chain has three levels: 79 blocked by 78, 78 blocked by idle session 77.
A recursive walk anchored on `WHERE blocking_session_id = 0 OR blocking_session_id IS NULL`, meaning
"start from whoever is not blocked," never finds 77 at all, because 77 has no row to anchor on. On
this chain that form returns **zero rows**, chain and all. The corrected form in section 3 of the
Azure SQL guidance walks every `blocking_session_id` present instead, and flags per blocker whether
it has a request row of its own. It returns both blocked sessions and labels 77, named only as
somebody else's `blocking_session_id`, as idle with an open transaction.

## Induce a deadlock

Two sessions update a test table `dbo.accounts`, holding rows `id = 1` and `id = 2`, in opposite
order, with a `WAITFOR` to make the race deterministic:

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

Session A commits. Session B's caller receives:

```text
Msg 1205, Level 13, State 72, Server SQL Azure, Line 7
Transaction (Process ID 78) was deadlocked on lock resources with another process and has been
chosen as the deadlock victim. Rerun the transaction.
```

Treat the state code (`72` above) as informational, not something to match on: it varies with
build and lock manager. `Msg 1205` and the message text are the stable part.

## The deadlock graph

On Azure SQL Database, read the graph out of a database-scoped session on
`sqlserver.database_xml_deadlock_report`, which is what Learn documents for the cloud service and
what section 5 of the Azure SQL guidance does. Reading a `system_health` ring buffer from `master`
works only in a local Azure SQL Database container. The graph's anatomy is the same either way.

Either query calls `.nodes()`, which requires `QUOTED_IDENTIFIER` ON; without it the query fails
with `Msg 1934` naming `QUOTED_IDENTIFIER` rather than anything about permissions or Extended
Events. Which client you use decides whether you notice. go-sqlcmd (`sqlcmd` 1.x) documents
`-I, --enable-quoted-identifiers` as "provided for backward compatibility. Quoted identifiers are
always enabled", so the error does not occur there; the older `mssql-tools` `sqlcmd` does not set
it. Pass `-I` and the snippet is portable across both.

The event appears almost immediately after the deadlock. The report's `<deadlock>` element carries:

- a `<victim-list>` naming the losing process
- a `<process-list>` with **two** `<process>` entries, the victim and the survivor, each with its
  `spid`, `loginname`, `hostname`, `isolationlevel`, `lasttranstarted`, and the text of the batch it
  was running in `<inputbuf>`
- a `<resource-list>` with an `<xactlock>` entry per contested key, each carrying an `<owner-list>`
  and a `<waiter-list>` naming which process held the lock and which was waiting

So the graph names the blocker, not only the victim. The raw event is not reprinted: its stack-frame
addresses alone run past a thousand characters.

**Name this event precisely.** `sqlserver.xml_deadlock_report` is the server-scoped event a local
container's `system_health` session fires. `sqlserver.database_xml_deadlock_report` is a different,
database-scoped event, and it is the one Azure SQL Database has. In a local container a session on
it can capture nothing for a real deadlock; create-xe-session covers that gap and follows Learn for
the cloud service. They are two similarly named events, not one; do not cite either as evidence for
the other.

## Optimized locking changes the wait type

On a new database all three flags from section 2 of the Azure SQL guidance are `1`, with no opt-in
step. A single reading of read committed snapshot as off can be transient: re-run before concluding
the default has changed.

A plain writer-vs-writer block, no deadlock, produces this wait, not the classic `LCK_M_U` or
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

If session C updates `id = 1` and holds the transaction open, session D's plain
`SELECT ... WHERE id = 1` issued while C is open returns the value from before C started,
immediately, with no wait. Not a dirty read and not a blocked read: a versioned one. Only a second
**writer** against the same row blocks, as shown above. Reasoning from the classic default predicts
blocking this database does not produce, and the in-flight value rather than the pre-transaction
one.

## What Microsoft Learn says

Cited rather than copied. These establish which of the behaviours above hold on the cloud service.

- **Optimized locking is always on in the cloud.**
  [Optimized locking, Availability](https://learn.microsoft.com/sql/relational-databases/performance/optimized-locking#availability)
  lists Azure SQL Database as "Yes (always enabled)", and the same page states accelerated database
  recovery is always enabled there and read committed snapshot on by default. So `1/1/1` is the
  cloud's behaviour and the `_XACT_` wait shapes are expected there. A self-hosted engine is the
  opposite case, where it is available but off by default, which is why advice written for one does
  not carry over.
- **The three wait types, named exactly.** The same page lists `LCK_M_S_XACT_READ`,
  `LCK_M_S_XACT_MODIFY` and `LCK_M_S_XACT`, `XACT` resources in `sys.dm_tran_locks` and
  `sys.dm_exec_requests`, and an `<xactlock>` per resource in the report's `<resource-list>`.
- **`READCOMMITTEDLOCK` is the documented way to force blocking back on.** Same page, FAQ.
- **`VIEW DATABASE STATE` cannot be granted in `master`.**
  [sys.dm_exec_sessions, Permissions](https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-objects/sys-dm-exec-sessions-transact-sql#permissions)
  states it plainly, so the two gaps in this file cannot share a fix even by accident. The same
  page's example C is the documented idiom for idle sessions holding open transactions, which
  section 4 of the Azure SQL guidance uses.
- **There is no built-in `system_health` session on Azure SQL Database.**
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
  and notes it takes minutes.
