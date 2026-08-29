# Verified behaviour: blocking, deadlocks, and who is allowed to see either

## Contents

- [How this was measured](#how-this-was-measured)
- [The blocking-chain gap: a real permission artifact](#the-blocking-chain-gap-a-real-permission-artifact)
- [The system_health gap: a database-context artifact, not a permission artifact](#the-system_health-gap-a-database-context-artifact-not-a-permission-artifact)
- [The idle head blocker, measured](#the-idle-head-blocker-measured)
- [The induced deadlock](#the-induced-deadlock)
- [The deadlock graph out of system_health](#the-deadlock-graph-out-of-system_health)
- [Optimized locking changes the wait type and the resource name](#optimized-locking-changes-the-wait-type-and-the-resource-name)
- [Read committed snapshot changes who blocks whom](#read-committed-snapshot-changes-who-blocks-whom)
- [What is documented rather than measured](#what-is-documented-rather-than-measured)

## How this was measured

One engine, reachable over the network, reporting `SERVERPROPERTY('EngineEdition')` = 5 and
`SERVERPROPERTY('Edition')` = `SQL Azure`. Date of the run: 2026-08-29. A dedicated database
held every test, with two accounts:

- an administrative login, equivalent to the Azure SQL Database server admin
- an ordinary login created for this check, added to `db_datareader` and `db_datawriter` on the
  test database and nothing else, matching an application connection string

Two independent variables were tested separately, and the results below are organized by which
variable actually moved the outcome: **which login** ran the query, and **which database** it was
connected to when it did. The first section changes only the login. The second changes only the
database, using the identical login both times.

Concurrent sessions were separate client processes against the same database. An idle session
holding an open transaction was produced by opening one client process and sending it statements
without a terminating `COMMIT` while a second process ran concurrently, rather than by simulating
it inside a single script.

## The blocking-chain gap: a real permission artifact

Every row below is a separate command actually run, in order, and the only thing changing across
these rows is **which login** ran the query.

| Step | Command | Result |
|---|---|---|
| 1 | Ordinary login: `SELECT session_id, blocking_session_id FROM sys.dm_exec_requests` while a genuine block was running elsewhere between two other logins | Returned only its own session, `blocking_session_id = 0`. No error, no hint that anything else was blocked |
| 2 | Admin: `GRANT VIEW DATABASE STATE TO <ordinary login>` on the test database | Succeeded |
| 3 | Same ordinary login, same query, same live block | Now returned the blocked session with the correct `blocking_session_id`, `wait_type` and `status` |
| 4 | A third, previously untouched login queried `sys.dm_os_waiting_tasks` and `sys.dm_tran_locks` during the same live block, with `VIEW DATABASE STATE` already granted | Both returned every session's rows, not just its own |

Step 1 is the dangerous one. It is not an error. It is a syntactically and semantically valid
query that runs, returns a well-formed single row, and gives no indication that a second, third and
fourth session exist and are deadlocked in slow motion three feet away. `VIEW DATABASE STATE` is
the one grant that changed it (step 2 to step 3, same login, same database, same query), and it is a
normal, grantable, database-scoped permission with no dependency on server admin rights. This is a
genuine permission artifact: the login was the only thing that changed, and the grant was what fixed
it.

## The system_health gap: a database-context artifact, not a permission artifact

This looks like the same shape of problem and is not. Every row below holds the login fixed and
changes only **which database it is connected to**.

| Step | Command | Result |
|---|---|---|
| 1 | Ordinary login, connected to the test (user) database: `SELECT name FROM sys.dm_xe_sessions` | `Msg 208, Invalid object name 'sys.dm_xe_sessions'` |
| 2 | Same ordinary login, connected to the test database: `SELECT name FROM sys.server_event_sessions` | `Msg 208, Invalid object name 'sys.server_event_sessions'` |
| 3 | Admin: `GRANT VIEW SERVER STATE TO <ordinary login>` | Succeeded, no error |
| 4 | Admin: confirm the grant in `sys.server_permissions` | `VIEW SERVER STATE`, state `GRANT`, present |
| 5 | Same ordinary login, still connected to the test database, same query as step 1 | Still `Msg 208, Invalid object name 'sys.dm_xe_sessions'`, despite the grant |
| 6 | Same ordinary login, reconnected to `master`, same query as step 1, no grant of any kind involved | `hkenginexesession`, `system_health`, `sp_server_diagnostics session`, three rows |
| 7 | Admin login, connected to `master`: `SELECT name FROM sys.dm_xe_sessions` | Same three rows as step 6 |
| 8 | Admin login, connected to the test database: `SELECT COUNT(*) FROM sys.dm_xe_sessions` | `Msg 208, Invalid object name`, same as the ordinary login got |

Steps 6 through 8 are the ones that settle it. The ordinary login with no special grant saw
`system_health` the moment it connected to `master` (step 6), and the admin login, which had seen it
without trying, lost visibility the moment it connected to the test database instead (step 8). Login
identity did not move the outcome anywhere in this table; database context did, for both logins,
in both directions. Step 3's `GRANT VIEW SERVER STATE` (confirmed present in step 4) changed nothing
in step 5, because there was no permission boundary in the test database for it to grant past.
`sys.dm_xe_sessions`, `sys.server_event_sessions` and `sys.dm_xe_session_targets` are simply not
exposed as objects outside `master`, for any login tried here.

Do not read the earlier permission story as also explaining this one. They were tested with the
opposite variable held constant, on purpose, once the two looked suspiciously similar.

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

A three-level chain was also produced and measured (79 blocked by 78, 78 blocked by idle session
77). A recursive walk of the chain that starts by anchoring on
`sys.dm_exec_requests WHERE blocking_session_id = 0 OR blocking_session_id IS NULL`, meaning "start
from whoever is not blocked," never finds session 77 at all, because 77 has no row to anchor on.
Run against this exact three-session chain, that recursive form returned **zero rows**, chain and
all, even though the chain was real and actively holding two other sessions. The corrected form
below does not anchor on an unblocked row; it walks every `blocking_session_id` present in
`sys.dm_exec_requests` and separately flags, for each blocker named, whether that blocker has a
request row of its own:

```sql
SELECT
    r.session_id       AS blocked_session,
    r.blocking_session_id AS blocker_session,
    r.wait_type,
    r.wait_time,
    CASE WHEN EXISTS (
            SELECT 1 FROM sys.dm_exec_requests r2 WHERE r2.session_id = r.blocking_session_id
         )
         THEN 'blocker has an active request'
         ELSE 'blocker is idle: open transaction, no active request'
    END AS blocker_state
FROM sys.dm_exec_requests r
WHERE r.blocking_session_id > 0;
```

Run against the measured chain this returned both blocked sessions, and correctly labelled
session 77 (named only as somebody else's `blocking_session_id`, never appearing as its own row) as
idle with an open transaction.

## The induced deadlock

Two sessions, opposite update order, no delay needed beyond a `WAITFOR` to make the race
deterministic:

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

The state code was 72 in this run. Treat the state code as informational, not as something to match
against; it varies with build and with the lock manager in play. The message text and Msg 1205 are
the stable part.

## The deadlock graph out of system_health

Queried immediately after the deadlock above, connected to `master` (this was run from the administrative login, but the database-context test above shows the login is not what makes this query resolve; connecting to `master` is what does):

```sql
DECLARE @xml XML;
SELECT @xml = CAST(t.target_data AS XML)
FROM sys.dm_xe_session_targets t
JOIN sys.dm_xe_sessions s ON s.address = t.event_session_address
WHERE s.name = 'system_health' AND t.target_name = 'ring_buffer';

SELECT event_xml.query('.') AS deadlock_report
FROM @xml.nodes('//RingBufferTarget/event[@name="xml_deadlock_report"]') AS T(event_xml)
ORDER BY event_xml.value('(@timestamp)[1]', 'datetime2') DESC;
```

This requires `SET QUOTED_IDENTIFIER ON`, which `sqlcmd` does not set by default; without it the
query fails with `Msg 1934` naming `QUOTED_IDENTIFIER` rather than anything about permissions or
Extended Events.

The event returned within the same second as the deadlock (deadlock at `08:27:02.959`, event
timestamp `08:27:02.959Z`). The report's `<deadlock>` element carried:

- a `<victim-list>` naming the losing process
- a `<process-list>` with **two** `<process>` entries, the victim and the survivor, each with its
  `spid`, `loginname`, `hostname`, `isolationlevel`, `lasttranstarted`, and the text of the batch it
  was running in `<inputbuf>`
- a `<resource-list>` with an `<xactlock>` entry per contested key, each carrying an `<owner-list>`
  and a `<waiter-list>` naming which process held the lock and which was waiting

So the graph names the blocker, not only the victim. Whatever produced the belief that only the
victim is recoverable was not this mechanism; it did not reproduce here. The full raw event,
unedited, is preserved in the commit history of this reference file's authoring session and is not
reproduced here in full because the stack-frame addresses alone run past a thousand characters and
add nothing a reader needs twice.

**Name this event precisely.** It is `sqlserver.xml_deadlock_report`, fired by the server-scoped
`system_health` session and read here from `master`. A sibling skill (capture-with-extended-events)
separately measured `sqlserver.database_xml_deadlock_report`, a differently named, database-scoped
event added to a custom Extended Events session, and found it captured zero events across two
confirmed deadlocks. These are two different events with similar names, not two measurements of the
same one; do not cite one result as evidence for the other.

## Optimized locking changes the wait type and the resource name

The test database had `is_optimized_locking_on = 1` by default (also
`is_read_committed_snapshot_on = 1` and `is_accelerated_database_recovery_on = 1`), with no
opt-in step taken to enable any of the three.

A plain writer-vs-writer block, no deadlock, produced this wait, not the classic
`LCK_M_U` or `LCK_M_X` against a `KEY:` resource:

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

Advice written against the classic lock manager, expecting a `KEY` resource type and a `U` or `X`
request mode as the first thing to look for, will not recognize this shape as the same kind of
block. It is the same kind of block. The resource is described in terms of the transaction ID that
owns it first, and the underlying key only as a secondary detail.

## Read committed snapshot changes who blocks whom

With `is_read_committed_snapshot_on = 1`, a plain `SELECT` against a row an open transaction has
already modified but not committed did **not** block, and did **not** return the uncommitted value.
Measured: session C updated `id = 1` to a new balance and held the transaction open; session D, a
plain `SELECT ... WHERE id = 1` issued while C was still open, returned the value from before C's
transaction started, immediately, with no wait. This is a versioned read, not a dirty read and not
a blocked read.

Only a second **writer** against the same row blocked, as shown above. An agent expecting the
classic default, where a plain read blocks behind an uncommitted write, will predict blocking that
this database does not produce, and will separately need to be told that the read still returned
the pre-transaction value rather than the in-flight one.

## What is documented rather than measured

These come from Microsoft Learn, read on 2026-08-29, and were not independently reproduced against
the live engine here.

- `VIEW DATABASE STATE` is the Azure SQL Database equivalent of the classic
  `VIEW SERVER STATE` for database-scoped dynamic management views, which matches what was measured
  in the blocking-chain table above, but the boundary of exactly which views fall under one grant or
  the other beyond the ones tested was not enumerated exhaustively.
- Optimized locking's wait types and lock-accumulation behaviour, beyond the shapes reproduced here,
  are described more fully in the feature's own documentation.
- Why `sys.dm_xe_sessions` and its neighbours are exposed only from `master` was not found documented
  in the time available; it was measured cleanly (both logins, both directions, in the table above)
  but the underlying design reason for scoping these particular catalog views to `master` is stated
  here as an observed fact, not a cited one. Do not extend this finding to other DMVs without
  checking each one; not every server-scoped view necessarily follows the same rule.
