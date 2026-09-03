---
name: capture-with-extended-events
description: >-
  Creates, starts, reads back and drops a database-scoped Extended Events session on Azure SQL
  Database, and names the ways such a session reports success while capturing nothing. Use when
  someone asks to capture query text, blocking or deadlocks with Extended Events, XEvents or an XE
  session on Azure SQL Database, or pastes a session that ran without error and left an empty ring
  buffer. Covers ON DATABASE scope and the error ON SERVER raises, the ring buffer shredded from
  XML into a rowset, the event_file target's requirement for a blob URL and a credential named
  after the container, the events and actions the service refuses, the per-database session and
  memory limits, and the fact that there is no built-in system_health session to fall back on.
  Does not diagnose slow queries, blocking or resource pressure once the data exists, which belong
  to diagnose-slow-query, diagnose-blocking-and-deadlocks and diagnose-resource-pressure, and does
  not read an execution plan, which belongs to read-execution-plan.
---

# Capture with Extended Events on Azure SQL Database

Builds a database-scoped event session, starts it, reads its target back as a rowset, and drops it.
What the captured data *means* belongs to the diagnostic skills that consume it.

Checked 2026-09-03 against Microsoft Learn's Azure SQL Database Extended Events pages and its
Database Engine error tables, and on 2026-08-29 against a local Azure SQL Database container
reporting `EngineEdition` 5. **Where the two disagree this file follows Learn**, because the
container is a different engine build and the subject here is the cloud service. Every
disagreement is named at the point it matters.

## Four things the service changes, and the error number for each

| | |
|---|---|
| **Scope** | Sessions are database-scoped only. `ON SERVER` fails with `Msg 25737`, and so does `ON DATABASE` against a system database |
| **Names** | Catalog views and DMVs take a `database_` prefix, never `server_`: `sys.database_event_sessions`, `sys.dm_xe_database_sessions` |
| **Durable target** | `event_file` writes to an Azure Storage blob and nowhere else. A local path fails at `CREATE` with `Msg 40538` |
| **No baseline** | **There is no built-in `system_health` session in Azure SQL Database.** Nothing is capturing anything until you build a session |

That last row changes behaviour. On SQL Server an agent leans on `system_health` for deadlocks and
skips building anything; here Learn states there is no such session, so there is no fallback and no
`master` connection that reveals one. There *is* an internal `dl` session, and Learn's instruction
is not to read it: `sys.fn_xe_file_target_read_file` over a large `dl` file can raise an
out-of-memory error in `master` and disrupt login processing.

## Steps

### 1. Write the session, with the `ACTION()` clauses attribution needs

An event carries only its own native fields. Who ran the statement, from what application, and the
statement text are *actions*, and an event added without them captures none of the three.

```sql
CREATE EVENT SESSION capture_statements ON DATABASE
ADD EVENT sqlserver.sql_statement_completed (
    ACTION (sqlserver.sql_text, sqlserver.username, sqlserver.client_app_name)
    WHERE duration > 500000
)
ADD TARGET package0.ring_buffer (SET max_memory = 4096)
WITH (MAX_MEMORY = 4 MB, MAX_DISPATCH_LATENCY = 5 SECONDS, STARTUP_STATE = OFF);
```

Two details in that statement earn their place:

- **`duration > 500000` is half a second, not eight minutes.** `sql_statement_completed` and
  `rpc_completed` report `duration` in microseconds; `wait_info` and `wait_completed` report it in
  milliseconds. A threshold copied between them is wrong by a factor of 1000 and the session gives
  no sign of it. Confirm the unit for the event you are actually using before you write a
  predicate, with the query in step 5.
- **`STARTUP_STATE`** decides whether the session comes back after a failover: Learn's guidance is
  `ON` for a continuous session, `OFF` for ad hoc troubleshooting. A ring buffer is cleared whenever
  the session stops, so `ON` restarts the session and still loses the events.

### 2. Create and start it on a connection to the user database

Creating a session does not start it. Run both, on one connection, to the user database and never
to `master`:

```bash
cat > capture-session.sql <<'SQL'
ALTER EVENT SESSION capture_statements ON DATABASE STATE = START;
SQL

sqlcmd -S <server-name>.database.windows.net -d <database-name> -G -N -b -i capture-session.sql
```

`-G` selects Microsoft Entra authentication (`-U <login> -P` instead, for a SQL authentication
login), `-N` requests an encrypted connection, and `-b` makes sqlcmd exit non-zero on error, so a
failed `START` fails the script instead of scrolling past.

Creating the session needs `CREATE ANY DATABASE EVENT SESSION` in the database and starting it
needs `ALTER ANY DATABASE EVENT SESSION`. These are the database-scoped permissions, not the
`ALTER ANY EVENT SESSION` server permission an example written for SQL Server will ask for. Both
are included in `CONTROL` on the database, held by `dbo`, by `db_owner` and by the server
administrator.

### 3. Read the ring buffer back as a rowset

`target_data` arrives as XML. Shred it rather than eyeballing it:

```bash
sqlcmd -S <server-name>.database.windows.net -d <database-name> -G -N -b -Q "
WITH RingBuffer AS (
    SELECT CAST(xst.target_data AS xml) AS TargetData
    FROM sys.dm_xe_database_session_targets AS xst
    JOIN sys.dm_xe_database_sessions AS xs ON xst.event_session_address = xs.address
    WHERE xs.name = N'capture_statements' AND xst.target_name = N'ring_buffer'
),
EventNode AS (
    SELECT CAST(n.NodeData.query('.') AS xml) AS EventInfo
    FROM RingBuffer AS rb CROSS APPLY rb.TargetData.nodes('/RingBufferTarget/event') AS n(NodeData)
)
SELECT EventInfo.value('(event/@timestamp)[1]', 'datetimeoffset')                         AS event_time,
       EventInfo.value('(event/data[@name=\"duration\"]/value)[1]', 'bigint')             AS duration,
       EventInfo.value('(event/action[@name=\"username\"]/value)[1]', 'sysname')          AS username,
       EventInfo.value('(event/action[@name=\"client_app_name\"]/value)[1]', 'nvarchar(128)') AS app_name,
       EventInfo.value('(event/action[@name=\"sql_text\"]/value)[1]', 'nvarchar(max)')    AS sql_text
FROM EventNode
ORDER BY event_time DESC;"
```

The three `action` columns come back `NULL` for a session built without the `ACTION()` clause in
step 1. Event counts are identical either way, so this is the only place the difference shows.

### 4. Stop and drop when the capture is done

```sql
ALTER EVENT SESSION capture_statements ON DATABASE STATE = STOP;
DROP EVENT SESSION capture_statements ON DATABASE;
```

Stopping empties a ring buffer, so read it first. A stopped session still appears in
`sys.database_event_sessions` and disappears from `sys.dm_xe_database_sessions`; only `DROP` removes
the definition. Sessions are database-scoped, so dropping the database takes them with it.

### 5. The three metadata queries worth keeping

```sql
-- the duration unit for one event, read rather than assumed
SELECT o.name AS event_name, c.name AS column_name, c.description
FROM sys.dm_xe_objects AS o
JOIN sys.dm_xe_object_columns AS c ON c.object_name = o.name AND c.object_package_guid = o.package_guid
WHERE o.name IN (N'sql_statement_completed', N'wait_info') AND c.name = N'duration';

-- whether an event, action or target exists on this platform at all
SELECT o.object_type, o.name, o.description
FROM sys.dm_xe_objects AS o
WHERE o.object_type IN ('action', 'event', 'target') AND o.name LIKE '%deadlock%';

-- memory this database is spending on started sessions, against the 128 MB cap
SELECT name AS session_name, total_buffer_size + total_target_memory AS total_session_memory
FROM sys.dm_xe_database_sessions;
```

Session memory is capped at 128 MB per single database and 512 MB across an elastic pool, and
*started* sessions at 100 per database or pool. Exceeding the memory cap raises `Msg 25746` or
`Msg 25747`, which name `sys.dm_xe_database_sessions` and tell you to stop or shrink a session.

## Check it worked

Run this immediately after step 2. It is four assertions with stated expected values, and each one
distinguishes a specific silent failure from success.

```sql
SET NOCOUNT ON;
DECLARE @name sysname = N'capture_statements', @fail int = 0, @n int;

-- 1. the definition exists. Zero here means CREATE never ran, or ran in another database
SELECT @n = COUNT(*) FROM sys.database_event_sessions WHERE name = @name;
IF @n <> 1 BEGIN PRINT 'FAIL 1: no session definition. CREATE did not run in this database'; SET @fail = 1; END

-- 2. it is STARTED. The catalog view above says nothing about this, and this is the usual answer
--    to "the session exists and the ring buffer is empty"
SELECT @n = COUNT(*) FROM sys.dm_xe_database_sessions WHERE name = @name;
IF @n <> 1 BEGIN PRINT 'FAIL 2: defined but never started. Run ALTER EVENT SESSION capture_statements ON DATABASE STATE = START'; SET @fail = 1; END

-- 3. the actions are attached. Expect 3: sql_text, username, client_app_name
SELECT @n = COUNT(*)
FROM sys.database_event_session_actions AS a
JOIN sys.database_event_sessions AS s ON s.event_session_id = a.event_session_id
WHERE s.name = @name;
IF @n <> 3 BEGIN PRINT CONCAT('FAIL 3: ', @n, ' actions attached, expected 3. Captured rows will have no caller'); SET @fail = 1; END

-- 4. the target is processing events. Zero AFTER a workload that should match the predicate means
--    the predicate, the unit, or the event choice is wrong, not the session
SELECT @n = ISNULL(SUM(execution_count), 0) FROM sys.dm_xe_database_session_targets AS t
JOIN sys.dm_xe_database_sessions AS s ON s.address = t.event_session_address WHERE s.name = @name;
IF @n = 0 BEGIN PRINT 'WARN 4: target has processed nothing yet. Expected after a matching workload'; END

IF @fail = 1 THROW 50001, 'event session is not capturing', 1;
PRINT 'event session: DEFINED, STARTED, ACTIONS ATTACHED';
```

Assertions 1 and 2 are the pair that gets read backwards. The catalog view lists every session
*definition* whether or not it runs; the DMV lists only *started* sessions. Read one for the other
and you get the opposite of the truth about whether a capture is live.

## Sessions that create, start and capture nothing

Three cases, and none of them raise an error at any point.

- **No `ACTION()` clause.** Events fire and are counted, and every attribution column is `NULL`.
  Assertion 3 above is what catches it.
- **`blocked_process_report`.** Its threshold is set with
  `sp_configure 'blocked process threshold'`, an option Learn documents for SQL Server only. Here
  that statement fails with
  `Msg 40510, Statement 'CONFIG' is not supported in this version of SQL Server`, and
  `sys.database_scoped_configurations` has no equivalent key. Measured on the container: this event
  created, started and captured zero across a 28 second real lock wait. **The supported route to
  blocked process reports here is not an event session at all**: enable the `Blocks` diagnostic
  settings category and read `blocked_process_filtered_s` out of the streamed resource logs.
- **An event or action the platform does not carry.** These are rejected at `CREATE` rather than
  silently: `Msg 25742` for a target, `Msg 25743` for an event, `Msg 25744` for an action. Check
  with the second query in step 5 first.

**On deadlocks, Learn and the container disagree, and this file follows Learn.** Learn's documented
way to capture deadlock graphs on Azure SQL Database is a database-scoped session on
`sqlserver.database_xml_deadlock_report`. On the container that event created, started and captured
zero events across two confirmed deadlocks (`Msg 1205` each time), while `sqlserver.lock_deadlock`
captured one. That gap has not been reproduced on the cloud service and is not evidence about it,
so build the session Learn documents and verify it with assertion 4 above against a deadlock you
cause deliberately. Keep `lock_deadlock` as the fallback only if that verification comes back empty.

When a session runs clean and its target stays empty, open
[references/sessions-that-capture-nothing.md](references/sessions-that-capture-nothing.md) for the
captured XML of each case above, the container measurements behind them, and the
`sys.dm_xe_object_columns` duration text for a specific event.

## The `event_file` target, in one paragraph

A local filesystem path is rejected at `CREATE`, not left unwritten:
`Msg 40538, A valid URL beginning with 'https://' is required as value for any filepath specified`.
An `https://` blob URL is accepted at `CREATE` with no credential check at all; the credential is
evaluated only at `START`, which fails with `Msg 25739` when it is missing outright, or `Msg 25602`
when the target cannot initialise. The most common cause of the latter is documented and specific:
**the database scoped credential's name must be the blob container URL itself, with no trailing
slash.** Open
[references/event-file-to-blob-storage.md](references/event-file-to-blob-storage.md) before you
choose `event_file` over the ring buffer, because it carries the credential and managed identity
syntax and the table that maps each operating system error number at `START` to its cause.

## Validation rules

- The session is created `ON DATABASE`, on a connection to the user database, never `ON SERVER` and
  never against `master`.
- Every event that will be attributed or filtered by caller carries the `ACTION()` clauses that
  attribution needs, and assertion 3 in "Check it worked" confirms the count.
- The session is confirmed present in `sys.dm_xe_database_sessions`, not merely in
  `sys.database_event_sessions`, before an empty target is believed.
- Any `duration` predicate names the event it was written for, and its unit came from
  `sys.dm_xe_object_columns`.
- `STARTUP_STATE` is a deliberate choice, and a ring buffer is read before the session is stopped.
- An `event_file` target points at an `https://` blob URL, and access was proved by a successful
  `START`, never by the `CREATE` succeeding.
- Started sessions and their memory were checked against the 100 session and 128 MB per database
  limits before another was added, and every session built by hand is dropped when it is done.

## Do not

- Do not look for a `system_health` session on Azure SQL Database. There is not one, and the time
  spent hunting is time nothing is being captured.
- Do not read the internal `dl` event session. A large read from it can raise an out-of-memory
  error in `master` and affect login processing.
- Do not scope a session `ON SERVER` for Azure SQL Database. The fix is `ON DATABASE`, not a
  permissions escalation.
- Do not grant `ALTER ANY EVENT SESSION` and expect it to work. The database-scoped permissions are
  the `ANY DATABASE EVENT SESSION` family.
- Do not reuse a `duration` threshold across events. Microseconds and milliseconds both appear, and
  the wrong one fails silently in whichever direction is less noticeable.
- Do not point `event_file` at a local path. It is refused at `CREATE` and no retry changes that.
- Do not treat a successful `CREATE` with a blob target as evidence the credential works, and do not
  name that credential after the session or the storage account. Its name must be the container URL,
  and a trailing slash on it is its own failure.
- Do not build a blocking diagnosis on `blocked_process_report` on Azure SQL Database. Use the
  `Blocks` diagnostic settings category, which is the supported source for that report.
- Do not restate what the captured queries, waits or blocking chains mean. That belongs to
  diagnose-slow-query, diagnose-blocking-and-deadlocks and diagnose-resource-pressure.

## References

- [references/sessions-that-capture-nothing.md](references/sessions-that-capture-nothing.md) when a
  session runs clean and its target stays empty: the container measurements behind each case, the
  captured XML, the duration column text for the events named here, and the `ACTION()` comparison
  run side by side.
- [references/event-file-to-blob-storage.md](references/event-file-to-blob-storage.md) before
  choosing `event_file` over the ring buffer, and again if `START` fails: the credential and managed
  identity syntax, the SAS token permissions, the operating system error numbers at `START` and what
  each one means, and reading `.xel` files back.
- [Extended Events in Azure SQL](https://learn.microsoft.com/azure/azure-sql/database/xevent-db-diff-from-svr):
  scope, permissions, storage authorization and the resource limits quoted above. Read it before
  trusting any Extended Events example not written for this platform.
- [Collect deadlock graphs in Azure SQL Database](https://learn.microsoft.com/azure/azure-sql/database/analyze-prevent-deadlocks):
  the documented deadlock session, both targets, and the query that shreds a graph out of a ring
  buffer. Read it when the capture you need is deadlocks.
- `diagnose-slow-query`, `diagnose-blocking-and-deadlocks`, `diagnose-resource-pressure`: what the
  captured data means, once this skill has produced it.
- `read-execution-plan`: the plan for a statement this session identified.
