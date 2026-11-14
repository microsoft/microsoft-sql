---
name: table-health-check
description: "Use when the user asks about table corruption, consistency errors, suspect pages, repair, or structural issues: heaps, no primary key, disabled or fragmented indexes. For table activity, use `table-access-analysis`."
user-invocable: true
argument-hint: "[SchemaName] [TableName] [TopN] [MinRowCount] [FragmentationThresholdPct]"
---

# Table Health Check

Use this skill when a user or DBA asks about **table health**, **table corruption**, **consistency errors**, **suspect pages**, **table repair**, tables with structural issues, or wants an overview of table quality in the current database.

The T-SQL in this skill targets the supported platforms listed below. Platform-specific commands (e.g. `msdb.dbo.suspect_pages`, `DBCC CHECKTABLE` repair options) are guarded by an `EngineEdition` check.

## Prerequisites

- Must be connected to the target database.
- DMV checks can require `VIEW SERVER STATE` / `VIEW SERVER PERFORMANCE STATE` on SQL Server or `VIEW DATABASE STATE` / `VIEW DATABASE PERFORMANCE STATE` on database-scoped platforms, depending on engine version and service tier. If a query is denied, report the denied permission and continue with checks that succeed.
- `DBCC CHECKTABLE` requires appropriate database permissions. Do not elevate permissions or execute any repair, index maintenance, or schema change as part of this diagnostic skill.

## Required tools

- A read-only SQL query tool connected to the target server and database. Prefer, in order: the SQL
  Tools MCP server that ships with the `microsoft-sql-admin` plugin
  (`mssql_list_database_connections`, `mssql_connect_database`, then `mssql_execute_query`); any
  other SQL tool the agent host provides for running T-SQL and reading result sets;
  [`sqlcmd`](https://learn.microsoft.com/sql/tools/sqlcmd/sqlcmd-utility) from a terminal. If the
  SQL Tools MCP server is not connected or lists no connections, follow the `sql-tools-mcp-setup`
  skill, which asks before installing or configuring anything. If no SQL tool can be made available,
  provide the T-SQL for the user to run and ask for the results.
- Least privilege: connect that tool with a diagnostic login that cannot write, for example one that
  holds only `VIEW SERVER PERFORMANCE STATE` (`VIEW SERVER STATE` before SQL Server 2022) or, on Azure
  SQL Database, `VIEW DATABASE PERFORMANCE STATE` or `##MS_ServerStateReader##`, plus any other read
  permission these queries need. A tool is only as read-only as the login it connects with.

## Parameters

All parameters are optional. Substitute the `{{Placeholder}}` tokens in the queries below before executing. When empty, the check runs database-wide with sensible defaults.

| Parameter | Default | Description |
|---|---|---|
| `SchemaName` | *(empty)* | Restrict all checks to this schema. Empty = all schemas. |
| `TableName` | *(empty)* | Restrict all checks to this table (single-table health check). Empty = all tables. **Required** for `RunTableConsistencyCheck`. |
| `TopN` | 20 | Number of rows to return for the busiest-tables ranking. |
| `MinRowCount` | 0 | Minimum table row count to include in the no-index / heap findings. |
| `FragmentationThresholdPct` | 10 | Minimum average fragmentation percent to report an index in `FindFragmentedIndexes`. |

> **Single-table mode**: set `TableName` (and optionally `SchemaName`) to focus the entire checklist on one table. Leave both empty for a full-database sweep.

### Parameter handling

- Treat `TopN`, `MinRowCount`, and `FragmentationThresholdPct` as integers. Reject nonnumeric values; require `TopN` in 1–1000, `MinRowCount >= 0`, and `FragmentationThresholdPct` in 0–100.
- Before substituting `SchemaName` or `TableName` into an `N'...'` literal, escape each single quote as two single quotes. Do not paste untrusted text into any other part of a query.
- Replace every `{{Placeholder}}` before execution. Never send a query containing an unresolved placeholder.

## Platform Compatibility

| EngineEdition | Platform | Corruption tooling notes |
|---|---|---|
| 1–4 | SQL Server (on-prem / SQL VM / IaaS) — Personal(1), Standard(2), Enterprise(3), Express(4) | Full access: `msdb.dbo.suspect_pages`, and `DBCC CHECKDB`/`CHECKTABLE` with repair options (you can set `SINGLE_USER`) |
| 8 | Azure SQL Managed Instance | `msdb.dbo.suspect_pages` and customer-initiated `DBCC CHECKDB`/`CHECKTABLE` available for **detection**. **Repair options are not available** (cannot set `SINGLE_USER`) — Microsoft performs repair; restore from automated backups instead |
| 5 | Azure SQL Database | Microsoft-managed integrity: `CHECKSUM` page verification, I/O lost-write (LSN) detection, and automatic page repair from replicas. `msdb` not accessible → `suspect_pages` unavailable. Customer-initiated `DBCC CHECKDB`/`CHECKTABLE` available for **detection only** (no repair). Hyperscale: `DBCC CHECKDB` unavailable — use `DBCC CHECKTABLE ('<Table>') WITH TABLOCK` |
| 12 | Fabric SQL Database | Behaves like Azure SQL Database (single-database, fully managed storage). Corruption is detected and repaired by the platform |
| 9 | Azure SQL Edge | SQL Server-based engine, but no `msdb`/Agent — `suspect_pages` unavailable. Structural, fragmentation, and `DBCC CHECKTABLE` checks apply |
| 6, 11 | Azure Synapse Analytics (6) / Synapse serverless or Microsoft Fabric analytics (11) | Not supported — table internals differ significantly |

> **Managed-platform data integrity** (Azure SQL DB / MI / Fabric): Microsoft continuously verifies pages with `CHECKSUM`, detects I/O “lost writes” via LSN tracking, and performs automatic page repair from replicas. Running `DBCC CHECKDB`/`CHECKTABLE` yourself is an optional **extra detection layer** that consumes compute/IO — it complements (does not replace) the platform protection. If you hit a data-integrity error before Microsoft notifies you, file an Azure support case.

> **Repair safety**: Never run `DBCC ... WITH REPAIR_ALLOW_DATA_LOSS` as a first response. It can silently discard data. Always attempt a **restore from a known-good backup** first. On Azure SQL DB, MI, and Fabric, storage-level corruption is repaired by the platform; open a support case rather than repairing manually.

## Data Collection Steps

Run these in order. After step 1, stop with an unsupported-platform result for EngineEdition 6 or 11. Steps 2–11 are read-only diagnostics on supported platforms; step 12 can be resource-intensive and is on demand only. Substitute and validate the parameters as described above before executing.

1. **Detect platform** — execute `DetectPlatform`; record `EngineEdition` to interpret later steps.
2. **Detect suspect/corrupt pages** — for EngineEdition 1–4 or 8, execute `DetectSuspectPages`. For 5, 9, or 12, mark this check Not assessed because `msdb.dbo.suspect_pages` is unavailable.
3. **Check database updateability & state** — execute `CheckDatabaseState`. If `Updateability = READ_ONLY` (e.g. a geo-secondary or readable AG replica), treat every structural finding as **advisory for this endpoint**: rebuilds, index/PK additions, and repairs must be applied on the **primary**. An empty `FindTop20MostUsedTables` is also expected here because usage stats aren't tracked on a read-only replica.
4. **Identify priority tables** — execute `FindTop20MostUsedTables`; focus the health review below on these tables first. If it returns no rows because DMV history is empty (after a restart/failover) or because the database is a read-only replica (usage stats aren't tracked there), execute `FindLargestTablesFallback` and explicitly label the ranking as size-based rather than activity-based.
5. **Find fragmented indexes** — execute `FindFragmentedIndexes`.
6. **Find tables with no indexes** — execute `FindTablesWithNoIndexes`.
7. **Find tables with no primary key** — execute `FindTablesWithNoPrimaryKeys`.
8. **Find heap tables** — execute `FindHeapTables`.
9. **Find disabled indexes** — execute `FindDisabledIndexes`.
10. **Find filestream columns** — execute `FindColumnsUsingFilestream`.
11. **Find tables with triggers** — execute `FindTablesWithTriggers`.
12. **Optional consistency check** — on explicit user request, or when corruption is suspected, use `RunTableConsistencyCheck` for a specific table. Return the substituted `DBCC` command for the user or DBA to review and run with an appropriately privileged SQL client; mark the check Not assessed until results are provided. `DetectSuspectPages` identifies database pages, not owning tables, so do not claim that it directly flagged a table.

If a check is unsupported or permission-denied, mark it **Not assessed** with the reason and continue. Do not interpret an unavailable check as a pass.

## SQL Queries

### DetectPlatform
```sql
SELECT
    CAST(SERVERPROPERTY('EngineEdition') AS INT) AS EngineEdition,
    CASE CAST(SERVERPROPERTY('EngineEdition') AS INT)
        WHEN 1 THEN 'SQL Server (Personal/Desktop)'
        WHEN 2 THEN 'SQL Server (Standard)'
        WHEN 3 THEN 'SQL Server (Enterprise)'
        WHEN 4 THEN 'SQL Server (Express)'
        WHEN 5 THEN 'Azure SQL Database'
        WHEN 6 THEN 'Azure Synapse Analytics'
        WHEN 8 THEN 'Azure SQL Managed Instance'
        WHEN 9 THEN 'Azure SQL Edge'
        WHEN 11 THEN 'Azure Synapse serverless / Microsoft Fabric analytics'
        WHEN 12 THEN 'Fabric SQL Database'
        ELSE 'Other/Unsupported'
    END AS PlatformName,
    DB_NAME() AS DatabaseName,
    CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(64)) AS ProductVersion,
    SYSUTCDATETIME() AS AsOfUtc
OPTION (MAXDOP 1);
```

### DetectSuspectPages
Corrupt/suspect pages recorded by the engine. Execute this query **only** when `DetectPlatform` returned EngineEdition 1–4 or 8. Do not wrap it in dynamic SQL; execute it only on the supported engine editions. On EngineEdition 5, 9, or 12, do not execute this query; report the platform limitation instead.
```sql
SET NOCOUNT ON;
SELECT
    DB_NAME(sp.database_id) AS DatabaseName,
    sp.file_id AS FileId,
    sp.page_id AS PageId,
    sp.event_type AS EventTypeCode,
    CASE sp.event_type
        WHEN 1 THEN '823 error / 824 error (other than bad checksum or torn page)'
        WHEN 2 THEN 'Bad checksum'
        WHEN 3 THEN 'Torn page'
        WHEN 4 THEN 'Restored (page was restored)'
        WHEN 5 THEN 'Repaired (DBCC repaired)'
        WHEN 7 THEN 'Deallocated (by DBCC)'
        ELSE 'Unknown'
    END AS EventType,
    sp.error_count AS ErrorCount,
    sp.last_update_date AS LastUpdate
FROM msdb.dbo.suspect_pages AS sp
WHERE sp.database_id = DB_ID()
ORDER BY sp.last_update_date DESC
OPTION (MAXDOP 1);
```

### CheckDatabaseState
Confirms the database is online and updateable — a database in `SUSPECT`, `RECOVERY_PENDING`, or `EMERGENCY` state indicates possible corruption.
```sql
SELECT
    d.name AS DatabaseName,
    d.state_desc AS State,
    d.user_access_desc AS UserAccess,
    CAST(DATABASEPROPERTYEX(d.name, 'Updateability') AS NVARCHAR(64)) AS Updateability,
    d.page_verify_option_desc AS PageVerify,
    d.recovery_model_desc AS RecoveryModel
FROM sys.databases d
WHERE d.database_id = DB_ID()
OPTION (MAXDOP 1);
```

### FindTop20MostUsedTables
Ranks the busiest tables (default top 20, controlled by `TopN`) by total access activity (`seeks + scans + lookups + updates`) from `sys.dm_db_index_usage_stats`. This DMV is available on all platforms. Counts are cumulative since the last engine/database restart (or failover on managed platforms), so treat them as a workload snapshot. These are the tables to prioritize in the health checklist below.
```sql
SET NOCOUNT ON;
DECLARE @Schema SYSNAME = NULLIF(N'{{SchemaName}}', N''), @Table SYSNAME = NULLIF(N'{{TableName}}', N'');
SELECT TOP ({{TopN}})
    SCHEMA_NAME(t.schema_id) AS SchemaName,
    t.name AS TableName,
    SUM(us.user_seeks + us.user_scans + us.user_lookups) AS TotalReads,
    SUM(us.user_updates) AS TotalWrites,
    SUM(us.user_seeks + us.user_scans + us.user_lookups + us.user_updates) AS TotalActivity,
    MAX(us.last_user_seek) AS LastUserSeek,
    MAX(us.last_user_scan) AS LastUserScan,
    MAX(us.last_user_update) AS LastUserUpdate,
    (SELECT SUM(p.rows) FROM sys.partitions p WHERE p.object_id = t.object_id AND p.index_id IN (0,1)) AS [RowCount]
FROM sys.dm_db_index_usage_stats us
INNER JOIN sys.tables t ON us.object_id = t.object_id
INNER JOIN sys.indexes i ON us.object_id = i.object_id AND us.index_id = i.index_id
WHERE us.database_id = DB_ID()
  AND (@Schema IS NULL OR SCHEMA_NAME(t.schema_id) = @Schema)
  AND (@Table IS NULL OR t.name = @Table)
GROUP BY t.schema_id, t.name, t.object_id
ORDER BY TotalActivity DESC
OPTION (MAXDOP 1);
```

### FindLargestTablesFallback
Use only when `FindTop20MostUsedTables` returns no rows. This keeps the review useful after a restart or failover, but table size is not evidence of workload activity.
```sql
SET NOCOUNT ON;
DECLARE @Schema SYSNAME = NULLIF(N'{{SchemaName}}', N''), @Table SYSNAME = NULLIF(N'{{TableName}}', N'');
SELECT TOP ({{TopN}})
        SCHEMA_NAME(t.schema_id) AS SchemaName,
        t.name AS TableName,
        SUM(p.rows) AS [RowCount]
FROM sys.tables t
INNER JOIN sys.partitions p ON t.object_id = p.object_id AND p.index_id IN (0,1)
WHERE (@Schema IS NULL OR SCHEMA_NAME(t.schema_id) = @Schema)
    AND (@Table IS NULL OR t.name = @Table)
GROUP BY t.schema_id, t.name
ORDER BY [RowCount] DESC, SchemaName, TableName
OPTION (MAXDOP 1);
```

### FindFragmentedIndexes
Uses `LIMITED` scan mode, which is safe and lightweight on every platform (including Azure SQL DB and Fabric). `sys.dm_db_index_physical_stats` returns a row per partition, so results are aggregated to one row per index — max fragmentation and total page count across partitions — ensuring a heavily partitioned index can't crowd others out of the `TOP (50)` cap. `FragmentedPartitions` shows how many partitions qualified. Columnstore indexes (`type` 5/6) are excluded because `avg_fragmentation_in_percent` is not a meaningful health metric for them — assess columnstore separately via rowgroup quality.
```sql
SET NOCOUNT ON;
DECLARE @Schema SYSNAME = NULLIF(N'{{SchemaName}}', N''), @Table SYSNAME = NULLIF(N'{{TableName}}', N'');
SELECT TOP (50)
    SCHEMA_NAME(t.schema_id) AS SchemaName,
    t.name AS TableName,
    i.name AS IndexName,
    i.type_desc AS IndexType,
    COUNT(*) AS FragmentedPartitions,
    SUM(ips.page_count) AS PageCount,
    CAST(MAX(ips.avg_fragmentation_in_percent) AS DECIMAL(5,2)) AS MaxAvgFragmentationPct,
    CASE
        WHEN MAX(ips.avg_fragmentation_in_percent) >= 30 THEN 'REBUILD'
        WHEN MAX(ips.avg_fragmentation_in_percent) >= 10 THEN 'REORGANIZE'
        ELSE 'OK'
    END AS Recommendation
FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'LIMITED') ips
INNER JOIN sys.tables t ON ips.object_id = t.object_id
INNER JOIN sys.indexes i ON ips.object_id = i.object_id AND ips.index_id = i.index_id
WHERE i.index_id > 0
  AND i.type NOT IN (5, 6)
  AND ips.page_count >= 128
  AND ips.avg_fragmentation_in_percent >= {{FragmentationThresholdPct}}
  AND (@Schema IS NULL OR SCHEMA_NAME(t.schema_id) = @Schema)
  AND (@Table IS NULL OR t.name = @Table)
GROUP BY t.schema_id, t.name, i.name, i.type_desc
ORDER BY MAX(ips.avg_fragmentation_in_percent) DESC
OPTION (MAXDOP 1);
```

### FindTablesWithNoIndexes
```sql
SET NOCOUNT ON;
DECLARE @Schema SYSNAME = NULLIF(N'{{SchemaName}}', N''), @Table SYSNAME = NULLIF(N'{{TableName}}', N'');
SELECT
    SCHEMA_NAME(t.schema_id) AS SchemaName,
    t.name AS TableName,
    SUM(p.rows) AS [RowCount]
FROM sys.tables t
LEFT JOIN sys.indexes i ON t.object_id = i.object_id AND i.index_id > 0
INNER JOIN sys.partitions p ON t.object_id = p.object_id AND p.index_id IN (0,1)
WHERE i.object_id IS NULL
  AND (@Schema IS NULL OR SCHEMA_NAME(t.schema_id) = @Schema)
  AND (@Table IS NULL OR t.name = @Table)
GROUP BY t.schema_id, t.name
HAVING SUM(p.rows) >= {{MinRowCount}}
ORDER BY [RowCount] DESC
OPTION (MAXDOP 1);
```

### FindTablesWithNoPrimaryKeys
```sql
SET NOCOUNT ON;
DECLARE @Schema SYSNAME = NULLIF(N'{{SchemaName}}', N''), @Table SYSNAME = NULLIF(N'{{TableName}}', N'');
SELECT
    SCHEMA_NAME(t.schema_id) AS SchemaName,
    t.name AS TableName
FROM sys.tables t
WHERE NOT EXISTS (
    SELECT 1 FROM sys.indexes i
    WHERE i.object_id = t.object_id AND i.is_primary_key = 1
)
  AND (@Schema IS NULL OR SCHEMA_NAME(t.schema_id) = @Schema)
  AND (@Table IS NULL OR t.name = @Table)
ORDER BY SchemaName, TableName
OPTION (MAXDOP 1);
```

### FindHeapTables
```sql
SET NOCOUNT ON;
DECLARE @Schema SYSNAME = NULLIF(N'{{SchemaName}}', N''), @Table SYSNAME = NULLIF(N'{{TableName}}', N'');
SELECT
    SCHEMA_NAME(t.schema_id) AS SchemaName,
    t.name AS TableName,
    SUM(p.rows) AS [RowCount]
FROM sys.tables t
INNER JOIN sys.indexes i ON t.object_id = i.object_id
INNER JOIN sys.partitions p ON i.object_id = p.object_id AND i.index_id = p.index_id
WHERE i.type = 0
  AND (@Schema IS NULL OR SCHEMA_NAME(t.schema_id) = @Schema)
  AND (@Table IS NULL OR t.name = @Table)
GROUP BY t.schema_id, t.name
HAVING SUM(p.rows) >= {{MinRowCount}}
ORDER BY [RowCount] DESC
OPTION (MAXDOP 1);
```

### FindDisabledIndexes
```sql
SET NOCOUNT ON;
DECLARE @Schema SYSNAME = NULLIF(N'{{SchemaName}}', N''), @Table SYSNAME = NULLIF(N'{{TableName}}', N'');
SELECT
    SCHEMA_NAME(t.schema_id) AS SchemaName,
    t.name AS TableName,
    i.name AS IndexName,
    i.type_desc AS IndexType,
    CASE WHEN i.type = 1 THEN 'CRITICAL - disabled clustered index makes the table inaccessible' ELSE 'Review' END AS Impact
FROM sys.indexes i
INNER JOIN sys.tables t ON i.object_id = t.object_id
WHERE i.is_disabled = 1
  AND (@Schema IS NULL OR SCHEMA_NAME(t.schema_id) = @Schema)
  AND (@Table IS NULL OR t.name = @Table)
ORDER BY SchemaName, TableName, IndexName
OPTION (MAXDOP 1);
```

### FindColumnsUsingFilestream
Filestream is unsupported on Azure SQL DB and Fabric; the query runs cleanly and simply returns no rows there.
```sql
SET NOCOUNT ON;
DECLARE @Schema SYSNAME = NULLIF(N'{{SchemaName}}', N''), @Table SYSNAME = NULLIF(N'{{TableName}}', N'');
SELECT
    SCHEMA_NAME(t.schema_id) AS SchemaName,
    t.name AS TableName,
    c.name AS ColumnName,
    ty.name AS DataType
FROM sys.columns c
INNER JOIN sys.tables t ON c.object_id = t.object_id
INNER JOIN sys.types ty ON c.user_type_id = ty.user_type_id
WHERE c.is_filestream = 1
  AND (@Schema IS NULL OR SCHEMA_NAME(t.schema_id) = @Schema)
  AND (@Table IS NULL OR t.name = @Table)
ORDER BY SchemaName, TableName, ColumnName
OPTION (MAXDOP 1);
```

### FindTablesWithTriggers
```sql
SET NOCOUNT ON;
DECLARE @Schema SYSNAME = NULLIF(N'{{SchemaName}}', N''), @Table SYSNAME = NULLIF(N'{{TableName}}', N'');
SELECT
    SCHEMA_NAME(t.schema_id) AS SchemaName,
    t.name AS TableName,
    tr.name AS TriggerName,
    tr.is_disabled AS IsDisabled,
    CASE
        WHEN tr.is_instead_of_trigger = 1 THEN 'INSTEAD OF'
        ELSE 'AFTER'
    END AS TriggerType
FROM sys.triggers tr
INNER JOIN sys.tables t ON tr.parent_id = t.object_id
WHERE (@Schema IS NULL OR SCHEMA_NAME(t.schema_id) = @Schema)
  AND (@Table IS NULL OR t.name = @Table)
ORDER BY SchemaName, TableName, TriggerName
OPTION (MAXDOP 1);
```

### RunTableConsistencyCheck
Generates a physical/logical consistency-check command for a **single** table. Requires `TableName` (uses `SchemaName`, defaulting to `dbo`). This query returns a safely quoted `DBCC CHECKTABLE` command for the user or DBA to review and run manually with an appropriately privileged SQL client. `DBCC CHECKTABLE` is a supported customer-initiated integrity check on every platform including Azure SQL DB and MI (repair options are only valid on SQL Server / SQL VM in single-user mode). Prefer running during low-traffic windows on large tables. On **Azure SQL Database Hyperscale** (where `DBCC CHECKDB` is unavailable), add `WITH TABLOCK` to the returned command.

> **Azure SQL Database & Azure SQL Managed Instance**: Microsoft already maintains continuous data-integrity checks for these platforms — pages are verified with `CHECKSUM`, I/O "lost writes" are detected via LSN tracking, and corrupt pages are automatically repaired from replicas ([Azure SQL DB data integrity](https://learn.microsoft.com/en-us/azure/azure-sql/database/data-integrity?view=azuresql), [Azure SQL MI data integrity](https://learn.microsoft.com/en-us/azure/azure-sql/managed-instance/data-integrity?view=azuresql)). Running `DBCC CHECKTABLE` here is an **optional supplemental check**, not a requirement, and it consumes extra compute/IO. Repair is Microsoft-managed on these platforms; if you find an integrity error, restore from automated backups or file an Azure support case rather than attempting repair.

```sql
SET NOCOUNT ON;
DECLARE @Schema SYSNAME = ISNULL(NULLIF(N'{{SchemaName}}', N''), N'dbo'), @Table SYSNAME = NULLIF(N'{{TableName}}', N'');
IF @Table IS NULL
BEGIN
    SELECT 'MISSING_PARAMETER' AS Status,
           'Provide TableName (and optionally SchemaName) to run a consistency check.' AS Detail;
    RETURN;
END;
DECLARE @Target NVARCHAR(520) = QUOTENAME(@Schema) + N'.' + QUOTENAME(@Table);
IF OBJECT_ID(@Target, N'U') IS NULL
BEGIN
    SELECT 'NOT_FOUND' AS Status, @Target + N' does not exist.' AS Detail;
    RETURN;
END;
-- Return the DBCC command for the user or DBA to review and run manually.
-- Do not execute repair commands as part of this diagnostic workflow.
DECLARE @DbccCommand NVARCHAR(1200) =
    N'DBCC CHECKTABLE (''' + REPLACE(@Target, N'''', N'''''') + N''') WITH NO_INFOMSGS, ALL_ERRORMSGS;';

SELECT
    'RUN_MANUALLY' AS Status,
    @Target AS TargetObject,
    @DbccCommand AS CommandToRun;
```

## Repair Guidance

Customer-runnable `DBCC ... REPAIR_*` options apply **only to SQL Server (1–4)** on-prem / SQL VM, where you can set `SINGLE_USER` mode. On **Azure SQL Managed Instance (8)**, **Azure SQL Database (5)**, and **Fabric (12)** you **cannot** run repair (no `SINGLE_USER`) — Microsoft performs repair; restore from automated backups or file an Azure support case.

1. **Confirm the corruption**: run `RunTableConsistencyCheck` (or `DBCC CHECKDB`) and read the reported error level and index IDs.
2. **Restore first**: the preferred fix is always a restore from a known-good full/differential/log backup chain, or page-level restore of the affected pages. This is lossless.
3. **Repair as last resort** (SQL Server on-prem / SQL VM only): if no backup exists, set the database to single-user and run the **minimum** repair level DBCC recommends. `REPAIR_ALLOW_DATA_LOSS` can deallocate corrupt pages and **permanently lose data** — take a backup of the corrupt database first and document what was lost.
4. **Root-cause the storage**: corruption is usually caused by the I/O subsystem. Check the Windows System event log for I/O errors, verify `PAGE_VERIFY CHECKSUM` is enabled, and validate the storage/driver/firmware.

> On managed platforms Microsoft's repair steps (in coordination with the customer) can include rebuilding an index, `DBCC CHECKDB WITH REPAIR_REBUILD` (no data loss), `REPAIR_ALLOW_DATA_LOSS` (with approval), or point-in-time restore followed by manual transaction replay.

## DBA Checklist — Top 20 Most-Used Tables

Run `FindTop20MostUsedTables` first; if it returns no rows, use `FindLargestTablesFallback`. Then work through this checklist for **each** table in the selected list. Cross-reference the results from the queries above rather than re-querying per table. Record **Pass**, **Warn**, **Fail**, or **Not assessed** per row. Do not run `DBCC CHECKTABLE` against every selected table unless the user explicitly requests that scope.

| # | Check | How to verify | Pass criteria |
|---|---|---|---|
| 1 | No known suspect/corrupt pages in the database | `DetectSuspectPages` | No unresolved suspect-page rows for the current database |
| 2 | Consistency clean (when explicitly checked) | `RunTableConsistencyCheck` for the table | `DBCC CHECKTABLE` returns no errors; otherwise Not assessed |
| 3 | Has a primary key | `FindTablesWithNoPrimaryKeys` | Table not present in results |
| 4 | Has a clustered index (not a heap) | `FindHeapTables` | Table not present in results |
| 5 | Indexes not fragmented | `FindFragmentedIndexes` | No index ≥ 30% (rebuild) / ≥ 10% (reorganize) |
| 6 | No disabled indexes | `FindDisabledIndexes` | Table not present in results |
| 7 | Page verification is `CHECKSUM` | `CheckDatabaseState` (`PageVerify`) | `PageVerify = CHECKSUM` (SQL Server / MI) |
| 8 | Statistics current | Review update dates (see `investigate-statistics-issues` skill) | Recently updated relative to write volume |
| 9 | Read/write ratio sensible | `FindTop20MostUsedTables` (`TotalReads` vs `TotalWrites`) | Heavy-write tables have lean, justified indexes |
| 10 | Trigger overhead reviewed | `FindTablesWithTriggers` | No unexpected / heavy triggers on hot tables |
| 11 | Row count vs. indexing appropriate | `FindTop20MostUsedTables` (`RowCount`) | Large hot tables are indexed for their query patterns |

> Prioritize failures on the highest-`TotalActivity` tables first — a health issue on a top-accessed table has the widest workload impact. On Azure SQL DB and Fabric, check 1 (`suspect_pages`) is unavailable (`msdb` not accessible), but check 2 (`DBCC CHECKTABLE`) is still supported as an optional extra integrity layer. Repair is Microsoft-managed on all Azure platforms — restore or file a support case instead of repairing.

## Required Output

Return a concise report containing:

1. Target database, detected platform, collection time, and applied scope/thresholds.
2. A **Critical findings** section first, including suspect pages, database state problems, and consistency errors.
3. A table of structural findings with severity, schema/table, evidence, and recommended next action.
4. A **Not assessed** section listing every skipped, unsupported, or permission-denied check and why.
5. A prioritized next-actions list. Clearly label all repair, index maintenance, and schema changes as recommendations requiring DBA review and explicit approval; do not execute them.

State when no rows were returned, but do not say the database or table is fully healthy if any required check was not assessed. If the database is `READ_ONLY` (geo-secondary or readable replica), state clearly that structural remediations must be applied on the primary. Treat missing primary keys, heaps, triggers, and fragmentation as review signals rather than automatic defects; workload and design intent determine whether remediation is appropriate.

## Interpretation Guidance

| Finding | Severity | Recommendation |
|---|---|---|
| Suspect/corrupt pages present | Critical | Restore from backup; root-cause storage. Do not delay |
| Database not `ONLINE` / not updateable | Critical | Investigate recovery state; restore if `SUSPECT` |
| `DBCC CHECKTABLE` reports errors | Critical | Follow Repair Guidance — restore before repair |
| `PAGE_VERIFY` not `CHECKSUM` | High | Set `PAGE_VERIFY CHECKSUM` to detect future corruption (SQL Server / MI) |
| Index fragmentation ≥ 30% | Medium | Rebuild the index |
| Index fragmentation 10–30% | Low | Reorganize the index |
| Disabled clustered index | Critical | Table is inaccessible until the clustered index is rebuilt |
| Tables with no indexes | High (if row count > 1000) | Add indexes based on query patterns |
| Tables with no primary keys | Medium | Add primary keys for data integrity and performance |
| Heap tables | Medium (if row count > 10000) | Consider adding a clustered index |
| Disabled indexes | Low | Investigate why disabled; rebuild or drop |
| Filestream columns | Informational | Ensure filestream is properly configured (SQL Server only) |
| Tables with triggers | Informational | Review trigger logic for performance impact |
