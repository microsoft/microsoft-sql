---
name: check-live-blocking
description: "Use when queries hang right now: who is blocking, the head blocker, why a blocking DMV looks empty. Has tested queries and rules common answers miss, e.g. a sleeping head blocker is absent from sys.dm_exec_requests. For past blocking, use read-only blocking root-cause investigation using the host SQL tools."
---

# Check Live Blocking Sessions

## Azure SQL Database specialization

For Azure SQL Database (EngineEdition 5), read [Azure-specific guidance](references/azure-sql/guidance.md) before choosing diagnostic queries. It preserves the service-specific permissions, capture limitations and error interpretation. Keep this skill's scope and authorization rules; the reference is not a second workflow to run unconditionally.

### Visibility, graph and historical evidence

Establish the caller's visibility before interpreting an empty DMV result. Limited database-scoped state permissions can hide other sessions without an error. A sleeping transaction owner may be missing from `sys.dm_exec_requests`; join sessions and connections separately.

Build blocked-session → positive-blocker edges. A head blocks others but is not itself blocked; intermediate blockers are not heads. Detect cycles and missing endpoints, and count distinct downstream sessions rather than parallel waiting tasks. Negative blocking codes are not session IDs. Optimized-locking `XACT` waits require transaction-ID interpretation, not a KEY/PAGE parser. Follow [incident evidence rules](references/incident-evidence.md) and report unknowns when the snapshot is incomplete.

For completed Azure deadlocks, hand off to `deadlock-analysis-azuresql`. Azure SQL Database does not provide SQL Server's server-scoped `system_health` history; a past graph needs a capture that was already active. A new database-scoped XE capture can investigate the next occurrence, subject to authorization. Diagnostic access never authorizes KILL or plan forcing.


## Purpose

Creates a comprehensive live blocking analysis report using DMV queries. This skill answers
"Is there blocking happening RIGHT NOW?" and provides detailed analysis of head blockers,
blocking chains, impact severity, and actionable recommendations.

This skill is typically invoked:
- After read-only wait-category analysis using the host SQL tools identifies Lock as the dominant wait category
- When a user directly asks about blocking ("who is blocking my queries?")
- As part of the `slow-query-investigation` skill workflow when blocking is suspected

## Prerequisites

- Must be connected to a SQL Server or Azure SQL database.
- No special setup required — uses standard DMVs available on all SQL Server versions.

## Required tools

- A read-only SQL query tool connected to the target server and database. Prefer, in order: the SQL
  Tools MCP server that ships with the `microsoft-sql-admin` plugin (`mssql_list_database_connections`,
  `mssql_connect_database`, then `mssql_execute_query`); any other SQL tool the agent host provides for
  running T-SQL and reading result sets;
  [`sqlcmd`](https://learn.microsoft.com/sql/tools/sqlcmd/sqlcmd-utility) from a terminal. If the SQL
  Tools MCP server is not connected or lists no connections, follow the SQL tools of the Visual Studio Code MSSQL extension; this plugin does not ship the standalone SQL Tools MCP server,
  which asks before installing or configuring anything. If no SQL tool can be made available, give the
  user the T-SQL to run and ask for the results.
- Least privilege: connect that tool with a diagnostic login that cannot write, for example one that
  holds only `VIEW SERVER PERFORMANCE STATE` (`VIEW SERVER STATE` before SQL Server 2022) or, on Azure
  SQL Database, `VIEW DATABASE PERFORMANCE STATE` or `##MS_ServerStateReader##`, plus any other read
  permission these queries need. A tool is only as read-only as the login it connects with.

## Data Collection

Execute Queries 1–3 below in sequence with the SQL query tool, then Query 4 and Query 5 to
resolve each `wait_resource` to the locked object. All of them are needed to build the complete
report. Every query in this section is read-only. The Azure guidance's section 6, which reproduces a
block for testing, is the one exception: it creates and drops a table, so run it only in a test
database and only after the user agrees.

### Query 1: Check for Blocked Sessions

```sql
SELECT TOP (50)
    r.session_id AS [Session ID],
    r.blocking_session_id AS [Blocking Session ID],
    DB_NAME(r.database_id) AS [Database],
    s.program_name AS [Application Name],
    s.host_name AS [Host Name],
    s.login_name AS [Login Name],
    r.status AS [Request Status],
    r.command AS [Command],
    r.wait_type AS [Wait Type],
    r.wait_time AS [Wait Time (ms)],
    r.wait_resource AS [Wait Resource],
    r.start_time AS [Request Start Time],
    DATEDIFF(SECOND, r.start_time, GETDATE()) AS [Elapsed Seconds],
    r.open_transaction_count AS [Open Transactions],    r.query_hash AS [Query Hash],
    r.plan_handle AS [Plan Handle]
FROM sys.dm_exec_sessions s
INNER JOIN sys.dm_exec_connections c
    ON s.session_id = c.session_id
INNER JOIN sys.dm_exec_requests r
    ON s.session_id = r.session_id
    AND (
        r.connection_id IS NULL
        OR r.connection_id = c.connection_id
        )
WHERE s.is_user_process = 1
    AND r.blocking_session_id <> 0
OPTION (MAXDOP 1, USE HINT ('FORCE_DEFAULT_CARDINALITY_ESTIMATION','QUERY_OPTIMIZER_COMPATIBILITY_LEVEL_160','ENABLE_QUERY_OPTIMIZER_HOTFIXES'))
```

### Query 2: Get Head Blocker Details

```sql
SELECT TOP (50)
    s.session_id AS [Session ID],
    s.program_name AS [Application Name],
    s.host_name AS [Host Name],
    s.login_name AS [Login Name],
    s.status AS [Session Status],
    s.cpu_time AS [CPU Time (ms)],
    s.memory_usage * 8 AS [Memory Usage (KB)],
    s.last_request_start_time AS [Last Request Start],
    s.last_request_end_time AS [Last Request End],
    s.open_transaction_count AS [Open Transactions],
    r.command AS [Current Command],
    r.wait_type AS [Current Wait Type],
    r.status AS [Request Status],
    c.connect_time AS [Connect Time],    COALESCE(r.query_hash, CAST(c.most_recent_sql_handle AS VARBINARY(8))) AS [Query Hash],
    blocked_counts.BlockedSessionCount AS [Sessions Blocked]
FROM sys.dm_exec_sessions s
INNER JOIN sys.dm_exec_connections c
    ON s.session_id = c.session_id
LEFT JOIN sys.dm_exec_requests r
    ON s.session_id = r.session_id
INNER JOIN (
    SELECT blocking_session_id, COUNT(*) AS BlockedSessionCount
    FROM sys.dm_exec_requests
    WHERE blocking_session_id <> 0
    GROUP BY blocking_session_id
) blocked_counts ON s.session_id = blocked_counts.blocking_session_id
WHERE NOT EXISTS (
    SELECT 1
    FROM sys.dm_exec_requests r2
    WHERE r2.session_id = s.session_id
      AND r2.blocking_session_id <> 0
)
OPTION (MAXDOP 1, USE HINT ('FORCE_DEFAULT_CARDINALITY_ESTIMATION','QUERY_OPTIMIZER_COMPATIBILITY_LEVEL_160','ENABLE_QUERY_OPTIMIZER_HOTFIXES'))
```

### Query 3: Get Blocking Chain Hierarchy

```sql
;WITH BlockingChain AS (
    SELECT
        r.session_id,
        r.blocking_session_id,
        0 AS chain_level,
        CAST(CAST(r.blocking_session_id AS VARCHAR(10)) + ' -> ' + CAST(r.session_id AS VARCHAR(10)) AS VARCHAR(4000)) AS blocking_chain
    FROM sys.dm_exec_requests r
    WHERE r.blocking_session_id <> 0
      AND NOT EXISTS (
          SELECT 1
          FROM sys.dm_exec_requests r2
          WHERE r2.session_id = r.blocking_session_id
            AND r2.blocking_session_id <> 0
      )
    UNION ALL
    SELECT
        r.session_id,
        r.blocking_session_id,
        bc.chain_level + 1,
        CAST(bc.blocking_chain + ' -> ' + CAST(r.session_id AS VARCHAR(10)) AS VARCHAR(4000))
    FROM sys.dm_exec_requests r
    INNER JOIN BlockingChain bc ON r.blocking_session_id = bc.session_id
    WHERE r.blocking_session_id <> 0
)
SELECT TOP (50)
    bc.blocking_chain AS [Blocking Chain],
    bc.chain_level AS [Chain Depth],
    bc.session_id AS [Blocked Session ID],
    bc.blocking_session_id AS [Blocked By],
    s.program_name AS [Application Name],
    r.command AS [Command],
    r.wait_type AS [Wait Type],
    r.wait_time AS [Wait Time (ms)],
    r.wait_resource AS [Wait Resource],    r.query_hash AS [Query Hash]
FROM BlockingChain bc
INNER JOIN sys.dm_exec_sessions s ON bc.session_id = s.session_id
INNER JOIN sys.dm_exec_requests r ON bc.session_id = r.session_id
ORDER BY bc.blocking_chain, bc.chain_level
OPTION (MAXDOP 1, USE HINT ('FORCE_DEFAULT_CARDINALITY_ESTIMATION','QUERY_OPTIMIZER_COMPATIBILITY_LEVEL_160','ENABLE_QUERY_OPTIMIZER_HOTFIXES'))
```

### Query 4: Get the Waiting Lock Resource for Each Blocked Session

`wait_resource` (for example `KEY: 5:72057594046382080 (8194443284a0)`) only contains IDs. The
waiting lock in `sys.dm_tran_locks` exposes the same resource with its type, database ID, and
associated entity: a `hobt_id` for `KEY`, `PAGE`, `RID`, and `HOBT` locks, or an `object_id` for
`OBJECT` locks.

```sql
SELECT
    tl.request_session_id AS [Session ID],
    r.blocking_session_id AS [Blocked By],
    r.wait_resource AS [Wait Resource],
    tl.resource_type AS [Resource Type],
    tl.resource_database_id AS [Database ID],
    DB_NAME(tl.resource_database_id) AS [Database],
    tl.resource_associated_entity_id AS [Associated Entity ID],
    tl.resource_description AS [Resource Description],
    tl.request_mode AS [Requested Mode]
FROM sys.dm_tran_locks AS tl
INNER JOIN sys.dm_exec_requests AS r
    ON r.session_id = tl.request_session_id
    AND r.request_id = tl.request_request_id
WHERE tl.request_status = N'WAIT'
  AND r.blocking_session_id <> 0
OPTION (MAXDOP 1);
```

### Query 5: Resolve the Locked Object Name (database.schema.object and index)

Run once per distinct (`Database ID`, `Resource Type`, `Associated Entity ID`) returned by Query 4,
substituting the three values. `KEY`/`PAGE`/`RID`/`HOBT` resolve through `sys.partitions.hobt_id` to
the object and index; `OBJECT` resolves directly through `sys.objects`. The catalog views are read in
the database that owns the lock, so the query works even when that is not the current database.

```sql
DECLARE @database_id   int          = 5;                     -- [Database ID] from Query 4
DECLARE @resource_type nvarchar(60) = N'KEY';                -- [Resource Type] from Query 4
DECLARE @entity_id     bigint       = 72057594046382080;     -- [Associated Entity ID] from Query 4
DECLARE @db sysname = DB_NAME(@database_id);
DECLARE @sql nvarchar(max);

IF @db IS NULL
    SELECT N'Database ID ' + CAST(@database_id AS nvarchar(10)) + N' not found or not visible' AS [Message];
ELSE
BEGIN
    SET @sql = N'
    SELECT DB_NAME(@database_id) AS [Database], s.name AS [Schema], o.name AS [Object],
           o.type_desc AS [Object Type], i.name AS [Index], i.type_desc AS [Index Type],
           p.partition_number AS [Partition]
    FROM ' + QUOTENAME(@db) + N'.sys.partitions AS p
    INNER JOIN ' + QUOTENAME(@db) + N'.sys.objects AS o ON o.object_id = p.object_id
    INNER JOIN ' + QUOTENAME(@db) + N'.sys.schemas AS s ON s.schema_id = o.schema_id
    LEFT JOIN ' + QUOTENAME(@db) + N'.sys.indexes AS i ON i.object_id = p.object_id AND i.index_id = p.index_id
    WHERE @resource_type IN (N''KEY'', N''PAGE'', N''RID'', N''HOBT'')
      AND p.hobt_id = @entity_id
    UNION ALL
    SELECT DB_NAME(@database_id), s.name, o.name, o.type_desc, NULL, NULL, NULL
    FROM ' + QUOTENAME(@db) + N'.sys.objects AS o
    INNER JOIN ' + QUOTENAME(@db) + N'.sys.schemas AS s ON s.schema_id = o.schema_id
    WHERE @resource_type = N''OBJECT''
      AND o.object_id = @entity_id
    OPTION (MAXDOP 1);';

    EXEC sys.sp_executesql @sql,
        N'@database_id int, @resource_type nvarchar(60), @entity_id bigint',
        @database_id = @database_id, @resource_type = @resource_type, @entity_id = @entity_id;
END
```

Report the result as `database.schema.object` plus the index name (and partition) when present.

**Fallback — parse `wait_resource` directly** when a blocked session has no row in Query 4 (for
example a latch wait rather than a lock wait, or no permission on `sys.dm_tran_locks`):

| `wait_resource` format | Meaning | How to resolve |
|---|---|---|
| `KEY: <db_id>:<hobt_id> (<key hash>)` | Row lock in an index | Query 5 with `KEY` and the `hobt_id` |
| `HOBT: <db_id>:<hobt_id>` | Heap or B-tree lock | Query 5 with `HOBT` and the `hobt_id` |
| `OBJECT: <db_id>:<object_id>:<lock_partition>` | Table or other object lock | Query 5 with `OBJECT` and the `object_id` |
| `PAGE: <db_id>:<file_id>:<page_id>` | Page lock or latch | Page query below |
| `RID: <db_id>:<file_id>:<page_id>:<slot>` | Row lock in a heap | Page query below with the first three numbers |
| `<db_id>:<file_id>:<page_id>` (no prefix) | Page latch (`PAGELATCH_*` / `PAGEIOLATCH_*`) | Page query below |

Page to object on SQL Server 2019+ and Azure SQL (`sys.dm_db_page_info`; requires `VIEW DATABASE STATE`
in that database):

```sql
SELECT DB_NAME(pi.database_id) AS [Database],
       OBJECT_SCHEMA_NAME(pi.object_id, pi.database_id) AS [Schema],
       OBJECT_NAME(pi.object_id, pi.database_id) AS [Object],
       pi.index_id AS [Index ID], pi.partition_id AS [Partition ID], pi.page_type_desc AS [Page Type]
FROM sys.dm_db_page_info(5, 1, 12345, 'LIMITED') AS pi   -- substitute db_id, file_id, page_id
OPTION (MAXDOP 1);
```

Resolve `Index ID` to a name with `sys.indexes` in the same database. Before SQL Server 2019 there is
no documented page-to-object function: use the waiting lock's `hobt_id` from Query 4 instead. If the
locked object cannot be resolved (for example, the database is not accessible to this login), report
the raw `wait_resource` and the IDs and say the name could not be resolved.

> On Azure SQL Database, `sys.dm_tran_locks` and the catalog views cover only the current database,
> so the locked object is always in the current database.

## Report Template

Present the combined results in this exact format:

```
## Blocking Sessions Report
Database: {{database name}}
Date: {{current date in YYYY-MM-DD format}}

---

### Overview
{{If no blocking was detected (Query 1 returns no rows):}}
  "No blocking detected at the time of this report."
  {{Skip the remaining sections.}}

{{If blocking was detected:}}
  "{{count}} head blocker(s) detected, blocking a total of {{count}} sessions.
   Longest wait time observed: {{max wait time}} ms.
   Locked object(s): {{database.schema.object (index) from Query 5, or the raw wait_resource if it could not be resolved}}."

---

### Head Blockers
{{For each head blocker from Query 2:}}

#### Session {{session_id}} — {{application name}}

| Property | Value |
|----------|-------|
| Login | {{login name}} |
| Host | {{host name}} |
| Session Status | {{session status}} |
| Open Transactions | {{open transaction count}} |
| Connect Time | {{connect time}} |
| Last Request Start | {{last request start time}} |
| Sessions Being Blocked | {{blocked session count}} |

**SQL Text:**
```sql
{{query_hash of the head blocker}}
```

---

### Blocking Chains
{{Display the blocking chain hierarchy from Query 3 using arrow notation:}}
{{For each distinct chain:}}
Head Blocker ({{session_id}}) → Blocked ({{session_id}}) → Blocked ({{session_id}})

---

### Blocked Sessions Detail

| Session ID | Blocked By | Application | Command | Wait Type | Wait Time (ms) | Wait Resource | Locked Object (Index) | Lock Mode | Query Hash |
|------------|------------|-------------|---------|-----------|----------------|---------------|-----------------------|-----------|---------------------|
{{one row per blocked session from Query 1, show query_hash; fill Locked Object as database.schema.object (index) and Lock Mode from Queries 4–5, or "unresolved" with the raw IDs}}

---

### Impact Assessment

- **Severity**: {{Assess using this scale:}}
  - Low: < 5 second waits, 1-2 blocked sessions
  - Moderate: 5-30 second waits or 3-5 blocked sessions
  - High: > 30 second waits or > 5 blocked sessions
- **Affected Applications**: {{List the distinct application names that are blocked}}
- **Contended Resources**: {{Name each locked object as database.schema.object and index, with the resource type (KEY/PAGE/RID/OBJECT/HOBT) and requested lock mode, resolved from wait_resource by Queries 4–5; never report only the raw wait_resource when it can be resolved}}
- **Root Cause Indication**: {{1-2 sentences about the likely cause:}}
  - If head blocker has idle session with open transactions → "Uncommitted transaction: Head blocker session is idle but holding locks due to an open transaction."
  - If head blocker is running a long UPDATE/DELETE → "Long-running DML: Head blocker is executing a large data modification holding locks."
  - If many sessions contend on same resource → "Hot spot contention: Multiple sessions competing for locks on the same resource."

---

### Recommendations

{{Based on the blocking analysis, provide 2-4 specific, actionable recommendations from this list:}}

- If head blocker has an idle session with open transactions:
  → "Investigate the application '{{app name}}' on host '{{host}}' for uncommitted transactions. The session is idle but holding locks. Check for missing COMMIT/ROLLBACK statements or connection pool issues."

- If long-running UPDATE/DELETE:
  → "Consider breaking the large data modification into smaller batches to reduce lock duration and allow other sessions to proceed between batches."

- If many sessions blocked on same resource:
  → "Review indexing on the contended table(s) to reduce lock scope. Adding a more selective index can reduce the number of rows locked per operation."

- If applicable to the workload:
  → "Consider enabling READ COMMITTED SNAPSHOT isolation (RCSI) to allow readers to proceed without being blocked by writers."

- Always include:
  → "If this blocking is intermittent and cannot be caught live, use the `create-xe-session` skill to set up passive monitoring that captures the blocker's identity next time it occurs."
```

## No Blocking Detected

If Query 1 returns no rows, provide a concise report:
- State that no active blocking was found
- If the user was directed here from read-only wait-category analysis using the host SQL tools (Lock waits were detected), explain:
  "Lock waits were detected in Query Store over the lookback period, but no blocking is active right now. The blocking is intermittent."
- Recommend: "To capture the blocker's identity next time it occurs, use the `create-xe-session` skill with a text pattern matching the affected query."
