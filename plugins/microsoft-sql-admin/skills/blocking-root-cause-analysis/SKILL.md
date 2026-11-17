---
name: blocking-root-cause-analysis
description: "Use when the user asks what caused blocking that already ended (yesterday's incident, intermittent lock waits) or who is behind a supplied blocking chain. For blocking happening now, use `check-live-blocking`."
---

# Blocking Root Cause Analysis

## Purpose

This is the **final step** in the blocking investigation workflow. After:
1. the `query-store-volatile-historical-slow-queries-comparison` skill (Step 1) found suspect queries
2. the `wait-category-analysis` skill confirmed Lock waits as the root cause
3. the `check-live-blocking` skill found no active blocking (intermittent)
4. the `create-xe-session` skill set up passive monitoring

...this skill retrieves the captured XE data and combines it with Query Store waits and
live DMV state to build a complete root cause picture. The key output is **WHO** (which
application, host, and login) is causing the blocking.

## Scope

- Also analyzes blocking-chain session details that the user supplies. Captured history requires the
  BlockingInvestigation XE session created earlier with the `create-xe-session` skill.
- For blocking happening right now (which sessions are blocked, the head blocker), use the
  `check-live-blocking` skill.

## Prerequisites

- Must be connected to the database where the XE session was created.
- The BlockingInvestigation XE session must have been created (via the `create-xe-session` skill)
  and must have captured data (the suspect workload ran while the session was active).

## Required tools

- A read-only SQL query tool connected to the target server and database. Prefer, in order: the SQL
  Tools MCP server that ships with the `microsoft-sql-admin` plugin (`mssql_list_database_connections`,
  `mssql_connect_database`, then `mssql_execute_query`); any other SQL tool the agent host provides for
  running T-SQL and reading result sets;
  [`sqlcmd`](https://learn.microsoft.com/sql/tools/sqlcmd/sqlcmd-utility) from a terminal. If the SQL
  Tools MCP server is not connected or lists no connections, follow the `sql-tools-mcp-setup` skill,
  which asks before installing or configuring anything. If no SQL tool can be made available, give the
  user the T-SQL to run and ask for the results.
- Least privilege: connect that tool with a diagnostic login that cannot write, for example one that
  holds only `VIEW SERVER PERFORMANCE STATE` (`VIEW SERVER STATE` before SQL Server 2022) or, on Azure
  SQL Database, `VIEW DATABASE PERFORMANCE STATE` or `##MS_ServerStateReader##`, plus any other read
  permission these queries need. A tool is only as read-only as the login it connects with.

## Platform Detection

Confirm which server and database you are connected to, and detect the engine edition, to determine
which XE data retrieval query to use:

```sql
SELECT
    @@SERVERNAME                                   AS [Server],
    DB_NAME()                                      AS [Database],
    SUSER_SNAME()                                  AS [Login],
    CAST(SERVERPROPERTY('EngineEdition') AS INT)   AS [Engine Edition],
    SERVERPROPERTY('Edition')                      AS [Edition],
    SERVERPROPERTY('ProductVersion')               AS [Product Version];
```

- **Azure SQL Database / Fabric SQL DB** (Engine Edition 5, 11, or 12) → Use the **Azure SQL variant** for Query 1
- **SQL Server / Managed Instance** (Engine Edition 1-4 or 8) → Use the **SQL Server variant** for Query 1

Queries 2 and 3 are platform-universal and used on all platforms.

## Data Collection

Execute the appropriate Query 1 variant below, plus Queries 2 and 3, in sequence with the SQL query tool.

### Query 1 — Azure SQL Variant: Retrieve XE Session Data

Use when connected to **Azure SQL Database** or **Fabric SQL Database**:

```sql
;WITH XEData AS (
    SELECT
        CAST(xet.target_data AS XML) AS target_data
    FROM sys.dm_xe_database_sessions AS xes
    INNER JOIN sys.dm_xe_database_session_targets AS xet
        ON xes.address = xet.event_session_address
    WHERE xes.name = 'BlockingInvestigation'
      AND xet.target_name = 'ring_buffer'
),
RawEvents AS (
    SELECT
        evt.value('(@name)', 'nvarchar(100)') AS event_name,
        evt.value('(@timestamp)', 'datetime2') AS event_time_utc,
        evt.value('(data[@name="duration"]/value)[1]', 'bigint') AS duration_us,
        evt.value('(data[@name="cpu_time"]/value)[1]', 'bigint') AS cpu_time_us,
        evt.value('(data[@name="logical_reads"]/value)[1]', 'bigint') AS logical_reads,
        evt.value('(data[@name="row_count"]/value)[1]', 'bigint') AS row_count,
        evt.value('(data[@name="statement"]/value)[1]', 'nvarchar(max)') AS sql_statement,
        evt.value('(action[@name="client_app_name"]/value)[1]', 'nvarchar(256)') AS client_app_name,
        evt.value('(action[@name="client_hostname"]/value)[1]', 'nvarchar(256)') AS client_hostname,
        evt.value('(action[@name="server_principal_name"]/value)[1]', 'nvarchar(256)') AS login_name,
        evt.value('(action[@name="session_id"]/value)[1]', 'int') AS session_id
    FROM XEData
    CROSS APPLY target_data.nodes('RingBufferTarget/event') AS t(evt)
)
SELECT
    event_time_utc AS [Event Time (UTC)],
    event_name AS [Event],
    duration_us / 1000 AS [Duration (ms)],
    cpu_time_us / 1000 AS [CPU Time (ms)],
    logical_reads AS [Logical Reads],
    row_count AS [Row Count],
    session_id AS [Session ID],
    client_app_name AS [Application Name],
    client_hostname AS [Host Name],
    login_name AS [Login Name],
    LEFT(sql_statement, 200) AS [SQL Text (truncated)]
FROM RawEvents
ORDER BY event_time_utc DESC;
```

### Query 1 — SQL Server Variant: Retrieve XE Session Data

Use when connected to **SQL Server** (on-premises) or **Azure SQL Managed Instance**:

```sql
;WITH XEData AS (
    SELECT
        CAST(xet.target_data AS XML) AS target_data
    FROM sys.dm_xe_sessions AS xes
    INNER JOIN sys.dm_xe_session_targets AS xet
        ON xes.address = xet.event_session_address
    WHERE xes.name = 'BlockingInvestigation'
      AND xet.target_name = 'ring_buffer'
),
RawEvents AS (
    SELECT
        evt.value('(@name)', 'nvarchar(100)') AS event_name,
        evt.value('(@timestamp)', 'datetime2') AS event_time_utc,
        evt.value('(data[@name="duration"]/value)[1]', 'bigint') AS duration_us,
        evt.value('(data[@name="cpu_time"]/value)[1]', 'bigint') AS cpu_time_us,
        evt.value('(data[@name="logical_reads"]/value)[1]', 'bigint') AS logical_reads,
        evt.value('(data[@name="row_count"]/value)[1]', 'bigint') AS row_count,
        evt.value('(data[@name="statement"]/value)[1]', 'nvarchar(max)') AS sql_statement,
        evt.value('(action[@name="client_app_name"]/value)[1]', 'nvarchar(256)') AS client_app_name,
        evt.value('(action[@name="client_hostname"]/value)[1]', 'nvarchar(256)') AS client_hostname,
        evt.value('(action[@name="server_principal_name"]/value)[1]', 'nvarchar(256)') AS login_name,
        evt.value('(action[@name="session_id"]/value)[1]', 'int') AS session_id
    FROM XEData
    CROSS APPLY target_data.nodes('RingBufferTarget/event') AS t(evt)
)
SELECT
    event_time_utc AS [Event Time (UTC)],
    event_name AS [Event],
    duration_us / 1000 AS [Duration (ms)],
    cpu_time_us / 1000 AS [CPU Time (ms)],
    logical_reads AS [Logical Reads],
    row_count AS [Row Count],
    session_id AS [Session ID],
    client_app_name AS [Application Name],
    client_hostname AS [Host Name],
    login_name AS [Login Name],
    LEFT(sql_statement, 200) AS [SQL Text (truncated)]
FROM RawEvents
ORDER BY event_time_utc DESC;
```

Key difference: Uses `sys.dm_xe_sessions` and `sys.dm_xe_session_targets` (server-scoped DMVs)
instead of `sys.dm_xe_database_sessions` and `sys.dm_xe_database_session_targets`.

### Query 2: Query Store Wait Categories (Universal)

This query works on all platforms with Query Store enabled:

```sql
SELECT TOP (20)
    q.query_id AS [Query ID],    q.query_hash AS [Query Hash],
    ws.wait_category_desc AS [Wait Category],
    SUM(ws.total_query_wait_time_ms) AS [Total Wait Time (ms)],
    SUM(ws.avg_query_wait_time_ms * ws.total_query_wait_time_ms)
        / NULLIF(SUM(ws.total_query_wait_time_ms), 0) AS [Weighted Avg Wait (ms)],
    SUM(ws.total_query_wait_time_ms) * 100.0
        / NULLIF(SUM(SUM(ws.total_query_wait_time_ms)) OVER (PARTITION BY q.query_id), 0)
        AS [Wait Category % of Query Total],
    COUNT(DISTINCT p.plan_id) AS [Plan Count]
FROM sys.query_store_query q
INNER JOIN sys.query_store_query_text qt
    ON q.query_text_id = qt.query_text_id
INNER JOIN sys.query_store_plan p
    ON q.query_id = p.query_id
INNER JOIN sys.query_store_wait_stats ws
    ON p.plan_id = ws.plan_id
INNER JOIN sys.query_store_runtime_stats_interval rsi
    ON ws.runtime_stats_interval_id = rsi.runtime_stats_interval_id
WHERE rsi.start_time >= DATEADD(MINUTE, -60, GETUTCDATE())
  AND q.is_internal_query = 0
GROUP BY q.query_id, ws.wait_category_desc
ORDER BY [Total Wait Time (ms)] DESC;
```

### Query 3: Check for Currently Active Blocking (Universal)

This query works on all platforms:

```sql
SELECT
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

## Report Template

Present the combined results in this exact format:

```
## Query Blocking Root Cause Report
Database: {{database name}}
Date: {{current date in YYYY-MM-DD format}}
Data Sources: BlockingInvestigation XE Session + Query Store + DMVs

---

### Prerequisites Check

{{If Query 1 (XE data) returns no rows, display this and STOP:}}

> **The BlockingInvestigation XE session has not captured any data yet.** This could mean:
> 1. The XE session has not been created. Use the `create-xe-session` skill to set it up.
> 2. The suspect query has not executed since the session was started. Wait for the workload to run and try again.
> 3. The query text pattern used when creating the session does not match the suspect query.

{{Skip the remaining sections if no XE data.}}

---

### XE Captured Executions

{{Display all captured query executions from Query 1:}}

| Time (UTC) | Event | Duration (ms) | CPU (ms) | Logical Reads | Session ID | Application | Host | Login | Query Hash |
|------------|-------|---------------|----------|---------------|------------|-------------|------|-------|---------------------|
{{one row per captured event, truncate SQL to 100 characters}}

---

### Source Identification

{{This is the CRITICAL section. Analyze the XE data to identify the blocking source:}}

#### Sessions Running the Suspect Query

| Application Name | Host Name | Login | # Executions | Avg Duration (ms) | Max Duration (ms) |
|------------------|-----------|-------|--------------|--------------------|-------------------|
{{Group XE data by application, host, login — these are the sessions running the query that gets blocked}}

#### Currently Active Blocking (if any)

{{If Query 3 returned results, display a summary table.}}
{{If no active blocking: "No active blocking detected at the time of this report."}}

---

### Query Store Wait Correlation

{{Show the wait categories from Query 2 for the queries that match the XE-captured SQL text:}}

| Wait Category | Total Wait Time (ms) | Interpretation |
|---------------|---------------------|----------------|
{{If Lock waits are present: "CONFIRMED — Lock waits detected, confirming blocking as the root cause."}}
{{Note any other significant wait categories that may be contributing.}}

---

### Root Cause Assessment

{{Provide a clear 2-3 sentence assessment:}}

1. **Source**: Identify the application(s) and host(s) running the suspect query based on XE data.
2. **Confirmation**: State whether blocking was confirmed via Lock waits in Query Store.
3. **Pattern**: If the XE captured both high-duration and low-duration executions of the same query,
   the blocking is intermittent. If ALL executions are high-duration, blocking may be persistent.
4. **Blocker Identity**: Note that the XE session captures the VICTIM's identity (the session running
   the suspect query). The BLOCKER is the other session holding the lock. If active blocking is
   detected (Query 3), the blocker's identity is known. If not, the blocker has already released
   the locks.

---

### Recommendations

{{Based on the root cause, provide 3-5 specific, actionable recommendations:}}

1. **Investigate the blocking application**: "The application '{{app name}}' on host '{{host}}'
   running as login '{{login}}' is the source. Review its transaction management — look for
   long-running transactions, missing COMMIT/ROLLBACK, or excessive lock scope."

2. **Reduce lock duration**: "If the blocking query performs large data modifications,
   consider breaking it into smaller batches (e.g., process 1,000 rows per transaction
   instead of the entire dataset)."

3. **Add retry logic**: "Add retry logic with exponential backoff in the affected application
   for transient blocking. This improves resilience without changing the database."

4. **Improve indexing**: "Review indexes on the contended tables. More selective indexes
   reduce the number of rows locked per operation, reducing lock conflicts."

5. **Schedule off-peak**: "If the blocking comes from a batch job or maintenance operation,
   consider scheduling it during off-peak hours when contention is lower."

6. **Consider isolation level changes**: "If the workload supports it, enabling READ COMMITTED
   SNAPSHOT (RCSI) allows readers to proceed without being blocked by writers."

7. **Live monitoring**: "To see the blocking in real-time next time it occurs, use
   the `check-live-blocking` skill when users report slowness."
```

## Correlating incident captures

Use the [shared incident evidence rules](references/incident-evidence.md): execution-weighted averages, per-query time windows, positive-session blocking graphs, sleeping heads and distinct downstream counts. Keep diagnostic candidates separate from authorized actions.
