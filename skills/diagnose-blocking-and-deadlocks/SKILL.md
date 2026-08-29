---
name: diagnose-blocking-and-deadlocks
description: >-
  Finds who is blocking whom on Azure SQL Database right now, and reads a completed deadlock graph
  out of the system_health session once one has happened. Use when someone reports a query or app
  that hangs under load, pastes "Msg 1205" or "was deadlocked on lock resources", asks who is
  blocking a session or what the head blocker is running, or ran a blocking query that came back
  empty and assumes nothing is blocked. Covers the database permission an ordinary login needs
  before it can see another session's blocking at all, why an idle session with an open transaction
  can be the head blocker and never appear in sys.dm_exec_requests, and how optimized locking's
  wait types and resource names differ from the classic lock manager. Does not tune a
  slow-but-unblocked query (diagnose-slow-query), does not diagnose CPU, memory or IO pressure
  (diagnose-resource-pressure), does not build a custom Extended Events session
  (capture-with-extended-events), and does not read the resulting execution plan
  (read-execution-plan).
---

# Diagnose blocking and read a deadlock on Azure SQL Database

**Check who is asking, and where it is connected, before you trust what came back.** The DMV
queries that find blocking, and the session that captures a deadlock, all exist and all work on
Azure SQL Database. A clean-looking empty result can come from two different, unrelated causes:
which login ran the blocking query, or which database it was connected to when it read
`system_health`. Treating both as the same problem leads to the wrong fix for each.

Measured on 2026-08-29 against a live engine reporting `EngineEdition` 5 and Edition `SQL Azure`,
using an actual induced deadlock, an actual multi-session blocking chain, three logins with
different permission grants, and the same login queried twice, once connected to `master` and once
to a user database. Full commands and outputs are in
[references/verified-behaviour.md](references/verified-behaviour.md).

## The facts that shape this

- **An ordinary login sees only its own session in `sys.dm_exec_requests`,
  `sys.dm_os_waiting_tasks` and `sys.dm_tran_locks` until it holds `VIEW DATABASE STATE`.** Measured:
  a real blocking chain between two other logins was completely invisible, as an empty extra row
  rather than an error, to a third login with no grant. Granting `VIEW DATABASE STATE` on the
  database, with no other change, made the same query show the whole chain. Grant this once to
  whatever login does diagnosis, rather than re-running the same query and trusting a quiet result.
- **`sys.dm_xe_sessions`, `sys.server_event_sessions` and `sys.dm_xe_session_targets` are a
  database-context thing, not a permission thing.** Measured with the SAME login run twice: connected
  to a user database it raised `Msg 208, Invalid object name 'sys.dm_xe_sessions'`; connected to
  `master`, with nothing else changed, it returned `system_health` and read its ring buffer. This is
  not the blocking-chain story above and does not share its fix. `GRANT VIEW SERVER STATE` was tried
  on the login while it sat in the user database and changed nothing, because there was no permission
  boundary being enforced there to grant past; the object is simply not exposed outside `master`. Do
  not report "no system_health session" from a query run against a user database; reconnect to
  `master` and run it again before drawing that conclusion.
- **A session can be the head blocker while holding no row at all in `sys.dm_exec_requests`.** An
  open transaction that already ran its statement and is now waiting on the application shows
  `status = sleeping` and `open_transaction_count > 0` in `sys.dm_exec_sessions`, with nothing in
  `sys.dm_exec_requests`. A chain-walking query anchored only on `sys.dm_exec_requests` can miss it
  entirely: the exact anchor form "start from whoever is not blocked" returned zero rows against a
  real, measured three-session chain, because the head blocker never had a row to start from.
- **Optimized locking is on by default and changes what a lock or a wait looks like.** A plain
  writer-vs-writer block measured `LCK_M_S_XACT_MODIFY`, not the classic `LCK_M_U` or `LCK_M_X`, and
  `sys.dm_tran_locks` showed a `resource_type` of `XACT` rather than `KEY`. Advice written for the
  classic lock manager will not recognize this as the same kind of block.
- **Read committed snapshot is also on by default.** A plain `SELECT` against a row an open
  transaction had already changed did not block and did not return the uncommitted value; it
  returned the last committed value with no wait. Only a second writer against the same row blocked.
  Do not predict reader blocking that this database will not produce.

## Steps

1. **Confirm the login can see more than itself.** Run `SELECT session_id, blocking_session_id FROM
   sys.dm_exec_requests` twice from two different logins if there is any doubt, or check
   `sys.database_permissions` for `VIEW DATABASE STATE` on the login being used. If it is missing,
   get it granted before drawing any conclusion from an empty result.
2. **Find live blocking with a query that does not depend on the blocker having a request row.**

   ```sql
   SELECT
       r.session_id          AS blocked_session,
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

   Walk this outward: whatever is named as `blocker_session` here and is itself never a
   `blocked_session` is the head blocker, whether or not it has its own row.
3. **For the head blocker, get what it last ran, not what it is running.** An idle head blocker has
   no current statement. Use `sys.dm_exec_sessions` for `open_transaction_count` and
   `last_request_end_time`, and `sys.dm_exec_connections` joined to `sys.dm_exec_sql_text` on
   `most_recent_sql_handle` for the text of its last batch, rather than looking in
   `sys.dm_exec_requests`, which will not have it.
4. **If a deadlock already happened, read it from `system_health` connected to `master`.** The
   query below fails with `Invalid object name` from a user database regardless of the login; switch
   the connection's database to `master` first, no elevated permission required for this step beyond
   whatever the login already has in `master` by default.

   ```sql
   SET QUOTED_IDENTIFIER ON;
   DECLARE @xml XML;
   SELECT @xml = CAST(t.target_data AS XML)
   FROM sys.dm_xe_session_targets t
   JOIN sys.dm_xe_sessions s ON s.address = t.event_session_address
   WHERE s.name = 'system_health' AND t.target_name = 'ring_buffer';

   SELECT event_xml.query('.') AS deadlock_report
   FROM @xml.nodes('//RingBufferTarget/event[@name="xml_deadlock_report"]') AS T(event_xml)
   ORDER BY event_xml.value('(@timestamp)[1]', 'datetime2') DESC;
   ```

   `QUOTED_IDENTIFIER` must be `ON` for the `.nodes()` call; without it the error names that setting,
   not a database context or a missing session. The event filtered on here is
   `sqlserver.xml_deadlock_report`, the server-scoped event inside `system_health`. It is a
   different event from `sqlserver.database_xml_deadlock_report`, the database-scoped event a custom
   Extended Events session can add; that one is covered, including a case where it captured nothing,
   in capture-with-extended-events. Name the event exactly when writing either one down.
5. **Read the graph as a pair, not as a victim.** The `<process-list>` holds both the victim named in
   `<victim-list>` and the process that survived. The `<resource-list>` names, per contested key,
   who held it (`<owner-list>`) and who was waiting (`<waiter-list>`). The fix usually follows from
   the pair: the same two objects touched in opposite order, which is fixed by touching them in a
   consistent order, or a shared range lock with no narrow index to make it a key-range lock, which
   is fixed by adding one.

## Validation rules

- Before reporting "nothing is blocked," the login that ran the check is confirmed to hold
  `VIEW DATABASE STATE` on that database.
- Before reporting "there is no system_health session," the query was run connected to `master` and
  still failed to resolve the object, not merely from a login sitting in a user database.
- A blocking-chain query does not assume every blocker has a row in `sys.dm_exec_requests`.
- A wait type or resource description is read against what this database actually reports
  (`_XACT_` waits and `XACT:`/`xactlock` resources are normal here), not against the classic
  `LCK_M_U`/`LCK_M_X` and `KEY:` shapes alone.
- A deadlock diagnosis names both processes from the graph, not only the victim.

## Do not

- Do not report that nothing is blocked because a query against `sys.dm_exec_requests`,
  `sys.dm_os_waiting_tasks` or `sys.dm_tran_locks` came back with only one row. Confirm the login
  holds `VIEW DATABASE STATE` first; the query succeeds and looks complete either way.
- Do not report that Azure SQL Database has no `system_health` session because
  `sys.dm_xe_sessions` returned `Invalid object name`. Reconnect the SAME login to `master` and run
  it again before concluding the session does not exist; measured here, that alone was enough to
  make it appear, with no grant involved.
- Do not treat the `system_health` visibility gap and the blocking-chain visibility gap as the same
  kind of problem. One is fixed by `GRANT VIEW DATABASE STATE`; the other is fixed by connecting to
  `master`, and a grant does not touch it. Measured here: `GRANT VIEW SERVER STATE` was tried against
  the `system_health` gap specifically and changed nothing, because there was no permission being
  enforced there to grant past.
- Do not predict that a plain `SELECT` blocks behind an uncommitted write. With read committed
  snapshot on, it does not, and it does not return the uncommitted value either.
- Do not read a wait type against the classic lock manager's names alone. `LCK_M_S_XACT_MODIFY` and
  an `XACT:` resource are optimized locking working as designed, not a new or unknown wait.
- Do not conclude a deadlock report only names the victim. The graph carries both processes; read
  the pair.
- Do not build a new Extended Events session to catch the next deadlock. `system_health` already
  runs and already includes `sqlserver.xml_deadlock_report`; a custom session belongs to
  capture-with-extended-events only when the built-in session's scope genuinely does not cover what
  is needed.

## References

- [references/verified-behaviour.md](references/verified-behaviour.md): every command behind this
  page, in the order it was run, including the blocking-chain permission story, the separate
  database-context story behind `system_health`, the idle-head-blocker chain that a naive query
  missed, and the raw deadlock graph's shape. Read it before disputing a claim here or changing one
  of the wait-type, permission or database-context details.
