---
name: capture-with-extended-events
description: >-
  Creates, reads and cleans up a database-scoped Extended Events session on Azure SQL Database, and
  names the specific ways such a session reports success while capturing nothing. Use when someone
  asks to capture query text, blocking, deadlocks or resource waits with Extended Events, XEvents or
  an XE session on Azure SQL Database, or pastes a session that ran without error and produced an
  empty ring buffer. Covers session scope, the ring buffer target read back as XML, the event_file
  target's requirement for Azure Blob Storage, the system_health session and why a user database
  connection cannot see it, and which diagnostic events actually fire in this scope. Does not
  diagnose slow queries, blocking or resource pressure once the data exists, which belong to
  diagnose-slow-query, diagnose-blocking-and-deadlocks and diagnose-resource-pressure, and does not
  read an execution plan, which belongs to read-execution-plan.
---

# Capture with Extended Events on Azure SQL Database

Creates a database-scoped Extended Events session, starts it, reads its target back, and drops it
again. This is the mechanism only: what to do with the captured data belongs to the diagnostic
skills that use it.

Measured on 2026-08-29 against a live engine reporting `EngineEdition` 5 and Edition `SQL Azure`.
Every claim below with a specific error number, message or event outcome was produced by actually
running it, not inferred from documentation. Two things could not be checked there and are marked
as such below: writing an `event_file` target all the way through to Azure Blob Storage, and
session persistence across an engine restart.

## The facts that shape this, before the steps

- **Extended Events on Azure SQL Database is database-scoped only, for a connection to a user
  database.** There is no `ON SERVER` scope available from there, and the server-scope DMVs and
  catalog views this event data normally lives in are not exposed from a user database connection
  at all.
- **A server-scoped `system_health` session exists and is running, and it already captures
  deadlocks.** It is not built by you, and it is not visible from a user database. Reaching it
  needs a connection to `master`, which is the single most important thing in this file: do not
  conclude nothing is watching just because a user database connection cannot see it.
- **A session can also be created, started and reported healthy while its target stays empty
  forever, for reasons that have nothing to do with `master` versus a user database.** Two such
  cases are measured and reproduced below, alongside `system_health`'s deadlock capture, and it
  matters that a reader can tell the two kinds of empty apart.
- **The catalog view and the DMV answer different questions, in either scope.** A `*_event_sessions`
  catalog view lists every session **definition** that exists, whether or not it is running. A
  `dm_xe_*_sessions` DMV lists only sessions that are currently **started**. Reading the wrong one
  produces the opposite of the right conclusion, and this applies the same way to
  `sys.server_event_sessions` versus `sys.dm_xe_sessions` in `master` as it does to
  `sys.database_event_sessions` versus `sys.dm_xe_database_sessions` in a user database.

## Steps

1. **Before building anything, check whether `system_health` in `master` already has it.** Connect
   to `master` specifically, with a login that can reach it, and read its ring buffer:

   ```sql
   SELECT CAST(t.target_data AS xml) AS target_xml
   FROM sys.dm_xe_session_targets AS t
   JOIN sys.dm_xe_sessions AS s
     ON s.address = t.event_session_address
   WHERE s.name = 'system_health'
     AND t.target_name = 'ring_buffer';
   ```

   Confirmed on this engine: `system_health` is present in `sys.dm_xe_sessions` (three sessions:
   `hkenginexesession`, `system_health`, `sp_server_diagnostics session`) and in
   `sys.server_event_sessions` (`system_health`, `AlwaysOn_health`) when queried from `master`, and
   `sys.server_event_session_events` lists roughly twenty events wired into it, including
   `xml_deadlock_report`. Reading its ring buffer from `master` after a real, confirmed deadlock
   (SQL error 1205 raised) returned that deadlock's `xml_deadlock_report` event, captured with no
   session built for the purpose at all. This step is the highest-value one in this file precisely
   because it needs nothing created, started or cleaned up.

   The catch, also confirmed: none of the queries above work from a connection to a user database.
   `sys.dm_xe_sessions` there fails outright with `Msg 208, Invalid object name 'sys.dm_xe_sessions'`,
   and `sys.database_event_sessions` correctly returns zero rows, because no *database-scoped*
   session was ever created there, which is a true but unrelated fact about that database rather
   than evidence about `system_health`. **The variable that decides whether you can see
   `system_health` is which database you are connected to, not a permission you are missing and not
   an absence of anything running.** In the cloud, `master` is administrative and most application
   identities are never connected to it at all, which is worth confirming for the identity you are
   using before promising this path will work for it.

2. **If step 1 does not cover it, create your own session with `ON DATABASE`, never `ON SERVER`.**
   `ON SERVER` fails immediately with:

   ```
   Msg 25737, Level 16, State 1
   Database scoped extended event sessions are not available in server scope or system databases in Azure DB.
   ```

   This is a hard error, not a silent failure, so it is the easy one. It still surfaces constantly
   because most Extended Events examples in the wild are written for SQL Server and use `ON SERVER`
   by default.

3. **Add `ACTION()` clauses for anything you intend to filter or attribute by.** An event added with
   no actions only carries the fields that are native to that specific event. Add
   `sqlserver.sql_text`, `sqlserver.username` and `sqlserver.client_app_name` explicitly when you
   need to know which query and which caller:

   ```sql
   CREATE EVENT SESSION capture_statements ON DATABASE
   ADD EVENT sqlserver.sql_statement_completed(
       ACTION (sqlserver.sql_text, sqlserver.username, sqlserver.client_app_name)
       WHERE duration > 500000
   )
   ADD TARGET package0.ring_buffer(SET max_memory = 4096)
   WITH (MAX_DISPATCH_LATENCY = 5 SECONDS);
   ```

   Measured side by side: the same event without an `ACTION()` clause still fires and still counts
   events, but the captured XML carries no `username`, `client_app_name` or `sql_text` action at
   all, only whatever the event happens to expose natively. A session that "works" and tells you
   nothing about who ran what is usually this, not a bug.

4. **Get the duration unit right for the specific event, because it is not the same across events.**
   `sql_statement_completed`, `rpc_completed` and `lock_acquired` report `duration` in
   **microseconds**. `wait_info` and `wait_completed` report it in **milliseconds**. A predicate
   written for one and reused on the other is off by a factor of 1000 and fails silently: the
   session runs, matches nothing or matches everything, and gives no indication the threshold was
   wrong. Confirmed both from `sys.dm_xe_object_columns` and empirically: a session filtering
   `sql_statement_completed` on `duration > 500000` correctly captured a one-second `WAITFOR` (whose
   measured duration came back as `1000292`, consistent with microseconds) and correctly ignored a
   sub-millisecond statement.

5. **Start it, generate the activity, then read the target back as XML.** Creating a session does
   not start it. Start it explicitly, and read the ring buffer by casting `target_data` to `xml`
   through the database-scoped DMVs:

   ```sql
   ALTER EVENT SESSION capture_statements ON DATABASE STATE = START;

   -- run the workload here

   SELECT CAST(t.target_data AS xml) AS target_xml
   FROM sys.dm_xe_database_session_targets AS t
   JOIN sys.dm_xe_database_sessions AS s
     ON s.address = t.event_session_address
   WHERE s.name = 'capture_statements'
     AND t.target_name = 'ring_buffer';
   ```

   The ring buffer is a fixed-size, in-memory, wrap-around target: it holds recent events only, and
   it does not survive a session stop. For anything that has to persist, use `event_file` instead,
   and read step 6 before you reach for it.

6. **Before choosing `event_file`, know it only writes to Azure Blob Storage.** A local filesystem
   path is rejected at creation, not merely unwritten:

   ```
   Msg 40538, Level 16, State 3
   A valid URL beginning with 'https://' is required as value for any filepath specified.
   ```

   An `https://` blob URL is accepted at `CREATE` time with no error at all, credential or not. The
   failure shows up only when you `START` the session, and only if the credential is missing or
   wrong:

   ```
   Msg 25602, Level 16, State 1
   The target, "...package0.event_file", encountered a configuration error during initialization.
   Object cannot be added to the event session. The operating system returned error 86:
   'The specified network password is not correct.' while creating the file '...'.
   ```

   That message names a Windows network error, not a storage or permission error, because the
   engine is reporting the file system layer underneath the blob mount. It means the database has
   no working access to that blob container, not that the file itself is broken. Getting `START`
   past this needs a `DATABASE SCOPED CREDENTIAL` holding a SAS token scoped to the container (which
   itself needs a master key in the database first, or fails with
   `Msg 15581, Please create a master key in the database...`), or granting the server's managed
   identity `Storage Blob Data Contributor` on the storage account. **Neither path was tested end to
   end here**, because it needs a real Azure Storage account and this session ran entirely against
   the local container. Treat the credential and role assignment steps as documented, not measured,
   and verify the actual write against your own storage account before relying on it.
   [references/event-file-and-read-back.md](references/event-file-and-read-back.md) has the full
   credential syntax and how to read the `.xel` files back once they exist.

7. **Stop and drop the session when you are done with it.** `ALTER EVENT SESSION ... STATE = STOP`
   then `DROP EVENT SESSION ... ON DATABASE`. A stopped session still appears in
   `sys.database_event_sessions` and disappears from `sys.dm_xe_database_sessions`; only `DROP`
   removes the definition. A database-scoped session lives and dies with its database: dropping the
   database drops the session, and there is nothing further to clean up on the server. This step
   does not apply to `system_health`: it is server-scoped, not yours to stop, and not yours to drop.

## Events that create and start cleanly and still capture nothing, and the one that is not what it looks like

Three cases, each reproduced with a real, confirmed condition on the local engine, and each one a
session that gave no error at any point:

- **`blocked_process_report`** created and started without error. A genuine lock wait was then held
  for roughly 28 seconds by one session while a second session blocked behind it, confirmed by both
  sessions completing in sequence rather than erroring. The session's ring buffer captured **zero**
  events. Azure SQL Database exposes no way to set the blocked process threshold this event depends
  on: `sp_configure 'blocked process threshold'` fails outright with
  `Msg 40510, Statement 'CONFIG' is not supported in this version of SQL Server`, and no equivalent
  key exists in `sys.database_scoped_configurations`. Do not build a diagnosis around this event on
  Azure SQL Database; it is not that the threshold is high, it is that there is no threshold to
  cross.
- **`database_xml_deadlock_report`**, a *database-scoped* event, created and started without error
  as a database-scoped session, and is listed by the engine itself as visible in this scope. A real
  deadlock was produced twice, independently, each time confirmed by the actual SQL Server error the
  loser received: `Msg 1205, ... has been chosen as the deadlock victim`. Both times the session's
  ring buffer captured **zero** events. This is a real, reproduced gap in this specific event, not a
  claim that Azure SQL Database cannot see deadlocks at all: see the next point.
- **`xml_deadlock_report`**, a *different, server-scoped* event with a similar name, is the one
  wired into `system_health` in `master`, and it does fire: step 1 above captured it for the same
  kind of deadlock, from `master`, with no session built by hand at all. `database_xml_deadlock_report`
  is not a database-scoped alias for it; the two are separate events with separate implementations,
  one of which fires here and one of which does not, and the near-identical names are exactly why
  they get conflated. `lock_deadlock`, the lower-level *database-scoped* event, was also tested
  directly against the same kind of deadlock and **did** capture one event, with the resource type,
  lock mode, transaction id and deadlock id all present in the XML. If a database-scoped session is
  the only option available to you and `system_health` cannot be reached, prefer `lock_deadlock` over
  `database_xml_deadlock_report` for a deadlock capture.

Also confirmed: `sys.dm_xe_database_objects`, which sounds like the database-scoped counterpart to
`sys.dm_xe_objects`, does not exist at all, from either `master` or a user database:
`Msg 208, Invalid object name 'sys.dm_xe_database_objects'`. Metadata about available events, actions
and targets comes from the ordinary `sys.dm_xe_objects` in whichever scope you are connected to, not
from a database-prefixed variant of it.

Read the source values in
[references/event-catalog-quirks.md](references/event-catalog-quirks.md) if a reviewer wants the
exact captured XML rather than the summary above.

## Validation rules

- `master` was checked for an existing `system_health` capture before a new session was built for
  something `system_health` already covers, and the identity used to check it was confirmed able to
  connect to `master` in the first place.
- The session was created `ON DATABASE`, never `ON SERVER`, when a new one was needed.
- Every event that will be filtered or attributed by identity carries the `ACTION()` clauses that
  attribution needs; a session without them was not mistaken for a working one.
- Any `duration` predicate names the event it was written for, because the unit is not the same
  across events.
- The session was confirmed running in the DMV for its scope (`sys.dm_xe_sessions` in `master`,
  `sys.dm_xe_database_sessions` for a database-scoped session), not merely present in the matching
  catalog view, before its target was trusted to be empty for a real reason.
- If the target is `event_file`, the destination is an `https://` blob URL, and the credential or
  managed identity access was verified by an actual successful `START`, not assumed from the
  `CREATE` succeeding.
- A deadlock capture used `xml_deadlock_report` from `system_health` when `master` was reachable,
  and `lock_deadlock` otherwise, rather than `database_xml_deadlock_report` alone.
- `blocked_process_report` was not relied on as the sole evidence of blocking on Azure SQL Database.
- Any session built by hand was stopped and dropped when the capture was done. `system_health` was
  left alone.

## Do not

- Do not conclude that nothing is capturing an event just because a user database connection cannot
  see `system_health`. Check from `master` first.
- Do not treat `sys.database_event_sessions` returning zero rows in a user database as evidence
  about `system_health` or anything else server-scoped. It only answers whether that one database
  has database-scoped sessions of its own.
- Do not write `CREATE EVENT SESSION ... ON SERVER` for Azure SQL Database. It always fails, and the
  fix is `ON DATABASE`, not a permissions escalation.
- Do not conclude a database-scoped session is idle from an empty `sys.dm_xe_database_sessions`
  result without first checking `sys.database_event_sessions` for whether it was ever started.
- Do not reuse a `duration` threshold across events without checking its unit for that specific
  event in `sys.dm_xe_object_columns`.
- Do not point `event_file` at a local path; it is rejected at creation, and no amount of retrying
  the same path will change that.
- Do not treat a successful `CREATE EVENT SESSION` with an `event_file` blob target as evidence the
  credential works. It is not evaluated until `START`.
- Do not confuse `database_xml_deadlock_report` with `xml_deadlock_report`. They are different
  events with similar names, one database-scoped and empty in testing, the other server-scoped and
  the one `system_health` actually uses.
- Do not build a blocking diagnosis on `blocked_process_report` alone on Azure SQL Database without
  first confirming, on the target database, that the event actually fires.
- Do not restate what a query and its wait or blocking chain mean once captured; that belongs to
  diagnose-slow-query, diagnose-blocking-and-deadlocks and diagnose-resource-pressure.

## References

- [references/event-catalog-quirks.md](references/event-catalog-quirks.md): the captured XML for
  each measured case above, the `system_health` and `master` versus user-database evidence in full,
  the exact `sys.dm_xe_object_columns` duration units for the events named in this file, and the
  full ACTION-vs-no-ACTION comparison. Read this when a claim above needs its source.
- [references/event-file-and-read-back.md](references/event-file-and-read-back.md): the database
  scoped credential syntax for a blob `event_file` target, the managed identity alternative, and how
  to read `.xel` files back with `sys.fn_xe_file_target_read_file`, including that a wrong or
  missing filename returns zero rows rather than an error. Read this before choosing `event_file`
  over the ring buffer.
