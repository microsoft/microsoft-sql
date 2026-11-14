---
name: deadlock-analysis-azuresql
description: "Use when the user asks about deadlocks, deadlock history or prevention on Azure SQL Database or Fabric SQL Database. For SQL Server, Managed Instance or a supplied deadlock XML, use `deadlock-analysis`."
user-invocable: true
---

# Deadlock Analysis — Azure SQL Database

For a request to set up a future capture (especially over hours or days), load `create-xe-session` for session design, attribution actions, durable storage, bounded retention and capture verification. Return here to interpret the resulting deadlock graphs. The capture examples below are starting points: successful CREATE/START alone does not prove useful events were recorded, and event-level actions must not be confused with attribution for every participant in a deadlock graph.


Use this skill when the user asks about deadlocks, deadlock reports, or deadlock history on **Azure SQL Database** or **Fabric SQL Database**.

> **Platform Guard**: This skill targets Engine Edition 5 (Azure SQL DB) or 11 (Fabric SQL DB). If the connected database is SQL Server (Engine Edition 1–4) or Managed Instance (Engine Edition 8), use the `deadlock-analysis` skill instead.

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

## SQL Queries

### Check for Active Deadlock XE Session
```sql
SELECT
    es.name AS [Session Name],
    des.create_time AS [Created],
    CASE WHEN des.address IS NOT NULL THEN 'Running' ELSE 'Stopped' END AS [Status],
    det.target_name AS [Target Type]
FROM sys.database_event_sessions AS es
LEFT JOIN sys.dm_xe_database_sessions AS des
    ON es.name = des.name
LEFT JOIN sys.dm_xe_database_session_targets AS det
    ON des.address = det.event_session_address
WHERE es.name LIKE '%deadlock%';
```

### Check Cumulative Deadlock Count
```sql
SELECT
    cntr_value AS cumulative_deadlock_count
FROM sys.dm_os_performance_counters
WHERE counter_name = 'Number of Deadlocks/sec'
  AND instance_name = '_Total';
```

### Read Deadlock Reports from Ring Buffer
```sql
DECLARE @tracename AS sysname = N'deadlocks';

WITH ring_buffer
AS (SELECT CAST (target_data AS XML) AS rb
    FROM sys.dm_xe_database_sessions AS s
         INNER JOIN sys.dm_xe_database_session_targets AS t
             ON CAST (t.event_session_address AS BINARY (8)) = CAST (s.address AS BINARY (8))
    WHERE s.name = @tracename
          AND t.target_name = N'ring_buffer'),
 dx
AS (SELECT dxdr.evtdata.query('.') AS deadlock_xml_deadlock_report
    FROM ring_buffer
CROSS APPLY rb.nodes('/RingBufferTarget/event[@name=''database_xml_deadlock_report'']') AS dxdr(evtdata))
SELECT d.query('/event/data[@name=''deadlock_cycle_id'']/value').value('(/value)[1]', 'int') AS [deadlock_cycle_id],
       d.value('(/event/@timestamp)[1]', 'DateTime2') AS [deadlock_timestamp],
       d.query('/event/data[@name=''database_name'']/value').value('(/value)[1]', 'nvarchar(256)') AS [database_name],
       d.query('/event/data[@name=''xml_report'']/value/deadlock') AS deadlock_xml,
       LTRIM(RTRIM(REPLACE(REPLACE(d.value('.', 'nvarchar(2000)'), CHAR(10), ' '), CHAR(13), ' '))) AS query_text
FROM dx
CROSS APPLY deadlock_xml_deadlock_report.nodes('(/event/data/value/deadlock/process-list/process/inputbuf)') AS ib(d)
ORDER BY [deadlock_timestamp] DESC;
GO
```

### Read Deadlock Reports from Event File Target
```sql
DECLARE @tracename AS sysname = N'deadlocks_eventfile', @filename AS NVARCHAR (2000);

WITH eft
AS (SELECT CAST (target_data AS XML) AS rb
    FROM sys.dm_xe_database_sessions AS s
         INNER JOIN sys.dm_xe_database_session_targets AS t
             ON CAST (t.event_session_address AS BINARY (8)) = CAST (s.address AS BINARY (8))
    WHERE s.name = @tracename
          AND t.target_name = N'event_file')
SELECT @filename = ft.evtdata.value('(@name)[1]', 'nvarchar(2000)')
FROM eft
CROSS APPLY rb.nodes('EventFileTarget/File') AS ft(evtdata);

IF @filename IS NULL
    SELECT 'No active event file session found for: ' + @tracename AS [Error];
ELSE
BEGIN
    ;WITH xevents
    AS (SELECT CAST (event_data AS XML) AS ed
        FROM sys.fn_xe_file_target_read_file(@filename, NULL, NULL, NULL)),
     dx
    AS (SELECT dxdr.evtdata.query('.') AS deadlock_xml_deadlock_report
        FROM xevents
    CROSS APPLY ed.nodes('/event[@name=''database_xml_deadlock_report'']') AS dxdr(evtdata))
    SELECT d.query('/event/data[@name=''deadlock_cycle_id'']/value').value('(/value)[1]', 'int') AS [deadlock_cycle_id],
           d.value('(/event/@timestamp)[1]', 'DateTime2') AS [deadlock_timestamp],
           d.query('/event/data[@name=''database_name'']/value').value('(/value)[1]', 'nvarchar(256)') AS [database_name],
           d.query('/event/data[@name=''xml_report'']/value/deadlock') AS deadlock_xml,
           LTRIM(RTRIM(REPLACE(REPLACE(d.value('.', 'nvarchar(2000)'), CHAR(10), ' '), CHAR(13), ' '))) AS query_text
    FROM dx
    CROSS APPLY deadlock_xml_deadlock_report.nodes('(/event/data/value/deadlock/process-list/process/inputbuf)') AS ib(d)
    ORDER BY [deadlock_timestamp] DESC;
END
```

### Check RCSI Status
```sql
SELECT name,
       is_read_committed_snapshot_on,
       snapshot_isolation_state_desc
FROM sys.databases
WHERE name = DB_NAME();
```

### Find Query Execution Plan by Query Plan Hash (from deadlock XML)
```sql
-- Replace the hash value below with the query_plan_hash from the deadlock XML process node
DECLARE @query_plan_hash BINARY(8) = 0x0000000000000000;

SELECT
    q.query_id,
    qt.query_sql_text,
    p.plan_id,
    p.query_plan_hash,
    TRY_CAST(p.query_plan AS XML) AS query_plan_xml,
    rs.avg_duration / 1000000.0 AS avg_duration_sec,
    rs.avg_logical_io_reads,
    rs.count_executions
FROM sys.query_store_plan AS p
INNER JOIN sys.query_store_query AS q
    ON p.query_id = q.query_id
INNER JOIN sys.query_store_query_text AS qt
    ON q.query_text_id = qt.query_text_id
LEFT JOIN sys.query_store_runtime_stats AS rs
    ON p.plan_id = rs.plan_id
WHERE p.query_plan_hash = @query_plan_hash
ORDER BY rs.last_execution_time DESC;
```

### Check Indexes on a Table Involved in Deadlock
```sql
-- Replace with the schema.table from the deadlock XML resource-list
DECLARE @table_name NVARCHAR(256) = N'dbo.YourTableName';

EXECUTE sp_helpindex @table_name;
```


## Behavioral Guidance

- **Start by checking for an existing XE session** — run the "Check for Active Deadlock XE Session" query first.
- If a deadlock XE session exists and is running, **check the target type**. Use the ring buffer query if `ring_buffer`, or the event file query if `event_file`. Set `@tracename` to match the session name.
- **Event file target may require blob storage access** — if the event file query fails with a permissions error, inform the user that reading event files from Azure Blob Storage may require appropriate access depending on how the XE session was configured (SAS token vs. managed identity). Recommend falling back to the ring buffer query or enabling Azure Monitor diagnostic settings as alternatives.
- If no XE session exists, **run "Check Cumulative Deadlock Count"**. If non-zero, inform the user deadlocks occurred but no capture session exists. Recommend creating a database-scoped XE session with `sqlserver.database_xml_deadlock_report` + ring buffer target, or enabling Azure Monitor diagnostic settings with the `Deadlocks` category.
- **Do NOT read from the built-in `dl` event session** — Microsoft warns this can cause OOM in master and impact login processing.
- The correct event for Azure SQL DB is **`sqlserver.database_xml_deadlock_report`** (not `sqlserver.xml_deadlock_report`).
- When presenting deadlock reports, **group rows by `deadlock_cycle_id`** — a 2-process deadlock produces 2 rows sharing the same cycle ID. Summarize each deadlock in 30 words or less.
- Database names appear as **GUIDs** in deadlock XML (the `physical_database_name`).
- When investigating a specific deadlock, extract `query_plan_hash` from the XML and use the Query Store lookup. Check indexes on involved tables with `sp_helpindex`.
- Conclude by offering to provide more details or guidance on preventing deadlocks.

## Deadlock Prevention Guidance

When the user asks how to prevent deadlocks, recommend in order of risk:

1. **Tune nonclustered indexes** — lowest risk; helps queries access less data, reducing lock contention.
2. **Check RCSI** — verify `is_read_committed_snapshot_on = 1`. Azure SQL DB enables RCSI by default; if disabled, investigate why before re-enabling.
3. **Force a query plan** via Query Store — if a specific plan causes the deadlock.
4. **Rewrite Transact-SQL** — break explicit transactions into smaller ones (highest risk, requires careful testing).

## Important Notes

- **`sys.event_log` is NOT usable from a user database connection** — it exists only in `master`. 
- Azure SQL DB does not expose the `system_health` session for deadlock file reads.
- Use **database-scoped** XE sessions (`ON DATABASE`), not server-scoped. The DMVs are `sys.dm_xe_database_sessions` and `sys.dm_xe_database_session_targets`.
- For persistent monitoring, an **event file target** writing to Azure Blob Storage is recommended (persists across failovers).
- For alerting, enable **Azure Monitor diagnostic settings** with the `Deadlocks` signal.
