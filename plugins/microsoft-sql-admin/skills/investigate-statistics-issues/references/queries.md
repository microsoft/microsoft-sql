# Statistics Issues Investigation — Queries

Execute each query with the SQL query tool.

### Step 1: Detect Platform and Capabilities

Execute with the SQL query tool. Determines the SQL Server engine edition and version to route
subsequent queries to platform-appropriate DMVs.

| EngineEdition | Platform | Key DMV Differences |
|---|---|---|
| 5 | Azure SQL Database | Single-database scope, no cross-database queries |
| 8 | Azure SQL Managed Instance | Instance-wide scope, most on-prem DMVs available |
| 12 | Fabric SQL Database | Behaves like Azure SQL Database (single-database scope) |
| 6, 11 | SQL Data Warehouse / Synapse | Not supported — statistics behavior differs significantly in DW |
| other | SQL Server on-prem / IaaS | Full DMV access including DBCC commands |

```sql
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @SqlMajorVersion INT = CAST(SERVERPROPERTY('ProductMajorVersion') AS INT);

SELECT
      CAST(SERVERPROPERTY('Edition') AS NVARCHAR(128))           AS sql_edition
    , CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(128))    AS sql_version
    , @SqlMajorVersion                                           AS major_version
    , CASE @EngineEdition
        WHEN 5  THEN 'Azure SQL Database'
        WHEN 8  THEN 'Azure SQL Managed Instance'
        WHEN 12 THEN 'Fabric SQL Database'
        WHEN 6  THEN 'SQL Data Warehouse (not supported by this skill)'
        WHEN 11 THEN 'Azure Synapse Analytics (not supported by this skill)'
        ELSE         'SQL Server (on-prem / IaaS)'
      END                                                        AS engine_type
    , @EngineEdition                                             AS engine_edition
    , CASE WHEN @EngineEdition IN (6, 11) THEN 1 ELSE 0 END     AS is_unsupported_dw
    -- Capability flags
    , CASE WHEN @SqlMajorVersion >= 13 THEN 1 ELSE 0 END         AS supports_persisted_sample
    , CASE WHEN @SqlMajorVersion >= 12 THEN 1 ELSE 0 END         AS supports_incremental_stats
    , CASE WHEN @SqlMajorVersion >= 16 THEN 1 ELSE 0 END         AS supports_auto_drop
    , CASE WHEN @EngineEdition IN (5, 8, 12) THEN 0 ELSE 1 END   AS supports_dbcc_show_statistics
    , DB_NAME()                                                  AS current_database
    , (SELECT compatibility_level 
       FROM sys.databases 
       WHERE database_id = DB_ID())                              AS compatibility_level
       OPTION (MAXDOP 1);
```

**Interpreting results:**
- `is_unsupported_dw = 1`: Stop here — this skill is not designed for SQL Data Warehouse / Synapse Analytics (engine editions 6, 11). Statistics behavior differs significantly in DW environments.
- `engine_edition = 12` (Fabric SQL Database): Behaves like Azure SQL Database — proceed with all steps.
- `supports_persisted_sample`: SQL 2016+ supports `has_persisted_sample` in sys.stats
- `supports_incremental_stats`: SQL 2014+ supports incremental statistics
- `supports_auto_drop`: SQL 2022+ supports auto-drop statistics
- `compatibility_level >= 130`: Uses dynamic statistics auto-update threshold (sqrt formula)

---

### Step 2: Identify Stale Statistics (High Modification Count)

Execute with the SQL query tool. Finds statistics where the modification counter exceeds the
configured threshold percentage. These are prime candidates for manual UPDATE STATISTICS.

```sql
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

IF @EngineEdition IN (6, 11)
BEGIN
    SELECT 'This step is not supported on SQL Data Warehouse / Synapse Analytics (EngineEdition '
           + CAST(@EngineEdition AS VARCHAR(10)) + '). Statistics DMV behavior differs significantly in DW environments.'
           AS unsupported_message;
    RETURN;
END

DECLARE @ModificationThresholdPct DECIMAL(5,2) = {{ModificationThresholdPct}};
DECLARE @MinRowsInTable BIGINT = {{MinRowsInTable}};
DECLARE @StaleDaysThreshold INT = {{StaleDaysThreshold}};
DECLARE @CompatLevel INT;
SELECT @CompatLevel = compatibility_level FROM sys.databases WHERE database_id = DB_ID();

SELECT TOP ({{TopN}})
      QUOTENAME(DB_NAME())                                            AS database_name
    , QUOTENAME(sch.name)                                             AS schema_name
    , QUOTENAME(OBJECT_NAME(s.object_id))                             AS table_name
    , CASE o.type
        WHEN 'U' THEN 'Table'
        WHEN 'V' THEN 'View'
      END                                                             AS object_type
    , QUOTENAME(s.name)                                               AS stats_name
    , CASE 
        WHEN s.auto_created = 0 AND s.user_created = 0 THEN 'Index_Statistic'
        WHEN s.auto_created = 0 AND s.user_created = 1 THEN 'User_Created'
        WHEN s.auto_created = 1 AND s.user_created = 0 THEN 'Auto_Created'
      END                                                             AS statistic_type
    , sp.last_updated                                                 AS last_updated
    , DATEDIFF(DAY, sp.last_updated, SYSUTCDATETIME())                AS days_since_update
    , sp.rows                                                         AS rows_at_last_update
    , sp.rows_sampled                                                 AS rows_sampled
    , CAST(100.0 * sp.rows_sampled / NULLIF(sp.rows, 0) 
           AS DECIMAL(5,2))                                           AS sample_percent
    , sp.modification_counter                                         AS modification_count
    , CAST(100.0 * sp.modification_counter / NULLIF(sp.rows, 0) 
           AS DECIMAL(10,2))                                          AS modification_percent
    -- Current table row count
    , (SELECT SUM(p.rows) 
       FROM sys.partitions p 
       WHERE p.object_id = s.object_id AND p.index_id <= 1)           AS current_row_count
    -- Auto-update threshold calculation
    , CASE 
        WHEN @CompatLevel >= 130
             AND COALESCE(sp.unfiltered_rows, 0) >= 25001
        THEN 'Dynamic (sqrt)'
        ELSE 'Static (500+20%)'
      END                                                             AS auto_update_threshold_type
    , CASE 
        WHEN @CompatLevel >= 130
             AND COALESCE(sp.unfiltered_rows, 0) >= 25001
        THEN CAST(SQRT(1000.0 * COALESCE(sp.unfiltered_rows, 0)) AS BIGINT)
        ELSE CASE
               WHEN COALESCE(sp.unfiltered_rows, 0) <= 500 THEN 501
               ELSE 500 + CAST(COALESCE(sp.unfiltered_rows, 0) * 0.2 AS BIGINT)
             END
      END                                                             AS auto_update_threshold
    , CASE 
        WHEN sp.modification_counter >= 
             CASE 
               WHEN @CompatLevel >= 130
                    AND COALESCE(sp.unfiltered_rows, 0) >= 25001
               THEN CAST(SQRT(1000.0 * COALESCE(sp.unfiltered_rows, 0)) AS BIGINT)
               ELSE CASE
                      WHEN COALESCE(sp.unfiltered_rows, 0) <= 500 THEN 501
                      ELSE 500 + CAST(COALESCE(sp.unfiltered_rows, 0) * 0.2 AS BIGINT)
                    END
             END
        THEN 'Yes - Will auto-update on next query'
        ELSE 'No - Below threshold'
      END                                                             AS qualifies_for_auto_update
    , s.has_filter                                                    AS is_filtered
    , s.filter_definition                                             AS filter_definition
FROM sys.stats s
INNER JOIN sys.objects o ON s.object_id = o.object_id
INNER JOIN sys.schemas sch ON o.schema_id = sch.schema_id
CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) sp
WHERE o.type IN ('U'{{, 'V' -- include indexed views only when IncludeViews = true}})  -- User tables (and optionally indexed views)
  AND sp.rows >= @MinRowsInTable
  AND (
       -- Modification percentage exceeds threshold
       (100.0 * sp.modification_counter / NULLIF(sp.rows, 0)) >= @ModificationThresholdPct
       OR
       -- Or last update was more than threshold days ago
       DATEDIFF(DAY, sp.last_updated, SYSUTCDATETIME()) > @StaleDaysThreshold
      )
ORDER BY modification_percent DESC, days_since_update DESC;
```

**Typical interpretations:**
- `modification_percent > 20%`: Statistics are significantly stale, likely causing poor estimates
- `qualifies_for_auto_update = 'Yes'`: Next query using this statistic will trigger auto-update
- `sample_percent < 10%`: Low sample rate may cause inaccurate histograms

**What to Do:**

| Scenario | Action |
|----------|--------|
| `modification_percent > 20%` and `qualifies_for_auto_update = 'No'` | Manually update: `UPDATE STATISTICS [schema].[table] [stats_name] WITH FULLSCAN;` — the auto-update threshold hasn't been reached but the data is significantly stale |
| `modification_percent > 20%` and `qualifies_for_auto_update = 'Yes'` | The next query compilation will trigger auto-update, but auto-update uses a low sample rate on large tables. Proactively run `UPDATE STATISTICS ... WITH FULLSCAN` or `SAMPLE 50 PERCENT` for better histogram quality |
| `sample_percent < 10%` on tables > 1M rows | Run `UPDATE STATISTICS ... WITH SAMPLE 50 PERCENT` or `FULLSCAN`. Default auto-update sampling on very large tables can be as low as 1–2% |
| `days_since_update > 30` even with low `modification_percent` | Data distribution may have shifted. Run `UPDATE STATISTICS ... WITH FULLSCAN` to refresh the histogram |
| Many stale statistics on the same table | Update all at once: `UPDATE STATISTICS [schema].[table] WITH FULLSCAN;` (omit the stats name to update all statistics on the table) |
| `auto_update_threshold_type = 'Static (500+20%)'` on large tables | Consider upgrading to compatibility level 130+ to enable the dynamic sqrt threshold, which triggers updates much sooner on large tables |

---

### Step 3: Statistics Sampling and Histogram Quality Analysis

Execute with the SQL query tool. Analyzes the quality of statistics histograms by examining
sample rates, step counts, and density values.

```sql
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

IF @EngineEdition IN (6, 11)
BEGIN
    SELECT 'This step is not supported on SQL Data Warehouse / Synapse Analytics (EngineEdition '
           + CAST(@EngineEdition AS VARCHAR(10)) + '). Statistics DMV behavior differs significantly in DW environments.'
           AS unsupported_message;
    RETURN;
END

DECLARE @MinRowsInTable BIGINT = {{MinRowsInTable}};

SELECT TOP ({{TopN}})
      QUOTENAME(DB_NAME())                                            AS database_name
    , QUOTENAME(OBJECT_SCHEMA_NAME(s.object_id))                      AS schema_name
    , QUOTENAME(OBJECT_NAME(s.object_id))                             AS table_name
    , QUOTENAME(s.name)                                               AS stats_name
    , c.name                                                          AS leading_column
    , TYPE_NAME(c.user_type_id)                                       AS column_data_type
    , c.max_length                                                    AS column_max_length
    , sp.rows                                                         AS rows_at_last_update
    , sp.rows_sampled                                                 AS rows_sampled
    , CAST(100.0 * sp.rows_sampled / NULLIF(sp.rows, 0) 
           AS DECIMAL(5,2))                                           AS sample_percent
    , sp.steps                                                        AS histogram_steps
    -- Histogram quality indicators
    , CASE 
        WHEN sp.steps < 10 AND sp.rows > 10000 THEN 'Poor - Very few steps for table size'
        WHEN sp.steps = 200 THEN 'Maximum - May miss data distribution nuances'
        WHEN sp.steps >= 100 THEN 'Good'
        WHEN sp.steps >= 50 THEN 'Moderate'
        ELSE 'Limited'
      END                                                             AS histogram_quality
    , CASE 
        WHEN CAST(100.0 * sp.rows_sampled / NULLIF(sp.rows, 0) AS DECIMAL(5,2)) >= 100 
        THEN 'Full Scan'
        WHEN CAST(100.0 * sp.rows_sampled / NULLIF(sp.rows, 0) AS DECIMAL(5,2)) >= 50 
        THEN 'High Sample'
        WHEN CAST(100.0 * sp.rows_sampled / NULLIF(sp.rows, 0) AS DECIMAL(5,2)) >= 20 
        THEN 'Moderate Sample'
        ELSE 'Low Sample - Consider FULLSCAN'
      END                                                             AS sample_quality
    , sp.modification_counter                                         AS modifications
    , sp.unfiltered_rows                                              AS unfiltered_rows
    , s.has_filter                                                    AS is_filtered
    , s.no_recompute                                                  AS no_recompute
    , s.auto_created                                                  AS auto_created
FROM sys.stats s
INNER JOIN sys.objects o ON s.object_id = o.object_id
INNER JOIN sys.stats_columns sc ON s.object_id = sc.object_id AND s.stats_id = sc.stats_id
INNER JOIN sys.columns c ON sc.object_id = c.object_id AND sc.column_id = c.column_id
CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) sp
WHERE o.type = 'U'
  AND sc.stats_column_id = 1  -- Leading column only
  AND sp.rows >= @MinRowsInTable
ORDER BY sample_percent ASC, sp.rows DESC
OPTION (MAXDOP 1);
```

**Key indicators:**
- `histogram_steps = 200`: Maximum steps reached; complex data distributions may not be fully captured
- `sample_percent < 20%`: Consider running UPDATE STATISTICS with FULLSCAN or higher sample rate
- `no_recompute = 1`: Auto-update is disabled for this statistic

**What to Do:**

| Scenario | Action |
|----------|--------|
| `sample_quality = 'Low Sample'` | Refresh with `UPDATE STATISTICS [schema].[table] [stats_name] WITH FULLSCAN;`. FULLSCAN is ideal but may be slow on very large tables (100M+ rows); `WITH SAMPLE 50 PERCENT` is a good compromise |
| `histogram_quality = 'Poor'` on high-row tables | Run `UPDATE STATISTICS ... WITH FULLSCAN` — more sampled rows produce more histogram steps and better distribution representation |
| `histogram_steps = 200` (maximum) | The histogram has maximum detail already. If cardinality estimates are still poor, consider creating filtered statistics on key value ranges or adding multi-column statistics |
| `no_recompute = 1` | Someone disabled auto-update with `NORECOMPUTE`. Either schedule manual updates via a maintenance job, or re-enable: `UPDATE STATISTICS [schema].[table] [stats_name] WITH RESAMPLE, NORECOMPUTE=OFF;` |
| `is_filtered = 1` with `sample_quality = 'Low Sample'` | Filtered statistics benefit significantly from FULLSCAN since they cover a subset of rows. Always prefer FULLSCAN for filtered statistics |

> **Why you should NOT blindly use `sp_updatestats`:**
> - `sp_updatestats` uses the **default sample rate** which can be as low as 1–2% on large tables — producing poor histograms that may be worse than the stale ones.
> - It updates **all** statistics, including those that don't need it, wasting IO and CPU during maintenance windows.
> - It does **not** support incremental (partition-level) updates — it always scans the entire table.
>
> **Better approach — prioritized, targeted updates:**
> 1. **Filter by `modification_counter`**: Only update statistics where `modification_percent > 20%` (from Step 2) or `modification_counter` exceeds the auto-update threshold (from Step 6).
> 2. **Adjust sample rate by table size**: For tables < 1M rows, use `FULLSCAN`. For tables 1M–100M rows, use `SAMPLE 50 PERCENT`. For tables > 100M rows, use `SAMPLE 25 PERCENT` or incremental updates.
> 3. **Use partition-level updates on partitioned tables**: If `is_incremental = 1` (from Step 9), update only the modified partition: `UPDATE STATISTICS [table] [stats] WITH RESAMPLE ON PARTITIONS (N);` — this avoids scanning the entire table.
> 4. **Persist sample rates** (SQL 2016 SP1+): After a FULLSCAN or high-sample update, add `PERSIST_SAMPLE_PERCENT = ON` so auto-updates don't revert to a low sample rate.
> 5. **Schedule by priority**: Update the highest `modification_percent` statistics first. If the maintenance window is limited, stop after the top N most stale — partial improvement is better than none.

---

### Step 4: Statistics Usage in Plan Cache

Execute with the SQL query tool. Identifies which statistics are referenced by cached execution
plans and correlates with query performance metrics.

```sql
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

IF @EngineEdition IN (6, 11)
BEGIN
    SELECT 'This step is not supported on SQL Data Warehouse / Synapse Analytics (EngineEdition '
           + CAST(@EngineEdition AS VARCHAR(10)) + '). Statistics DMV behavior differs significantly in DW environments.'
           AS unsupported_message;
    RETURN;
END

-- Pre-filters plan cache by database (via sys.dm_exec_plan_attributes) BEFORE
-- decompressing XML plans. Without this, CROSS APPLY sys.dm_exec_query_plan()
-- decompresses every cached plan on the server — 60-300+ seconds on 50K+ plans.
;WITH XMLNAMESPACES('http://schemas.microsoft.com/sqlserver/2004/07/showplan' AS p)
, FilteredPlans AS (
    -- Step A: identify plan handles scoped to this database without XML decompression
    SELECT qs.query_hash
         , qs.query_plan_hash
         , qs.plan_handle
         , qs.execution_count
         , qs.total_worker_time / 1000                                 AS total_cpu_time_ms
         , qs.total_elapsed_time / 1000                                AS total_elapsed_time_ms
         , qs.total_logical_reads
         , qs.last_execution_time
    FROM sys.dm_exec_query_stats qs
    INNER JOIN sys.dm_exec_cached_plans cp ON qs.plan_handle = cp.plan_handle
    CROSS APPLY (
        SELECT CAST(pa.value AS INT) AS dbid
        FROM sys.dm_exec_plan_attributes(qs.plan_handle) pa
        WHERE pa.attribute = 'dbid'
    ) pa
    WHERE qs.execution_count >= {{MinExecutionCount}}
      AND cp.objtype IN ('Proc', 'Prepared', 'Adhoc')
      AND pa.dbid = DB_ID()
)
, CachedStats AS (
    -- Step B: decompress XML only for database-scoped plans
    SELECT
          fp.query_hash
        , fp.query_plan_hash
        , fp.plan_handle
        , fp.execution_count
        , fp.total_cpu_time_ms
        , fp.total_elapsed_time_ms
        , fp.total_logical_reads
        , fp.last_execution_time
        , qp.query_plan
    FROM FilteredPlans fp
    CROSS APPLY sys.dm_exec_query_plan(fp.plan_handle) qp
    WHERE qp.query_plan IS NOT NULL
)
, StatsUsage AS (
    SELECT
          cs.query_hash
        , cs.query_plan_hash
        , cs.execution_count
        , cs.total_cpu_time_ms
        , cs.total_elapsed_time_ms
        , cs.total_logical_reads
        , cs.last_execution_time
        , stats_info.value('@Database', 'sysname')                    AS stats_database
        , stats_info.value('@Schema', 'sysname')                      AS stats_schema
        , stats_info.value('@Table', 'sysname')                       AS stats_table
        , stats_info.value('@Statistics', 'sysname')                  AS stats_name
        , stats_info.value('@ModificationCount', 'bigint')            AS modification_count_at_compile
        , stats_info.value('@SamplingPercent', 'float')               AS sample_percent_at_compile
    FROM CachedStats cs
    CROSS APPLY cs.query_plan.nodes('//p:OptimizerStatsUsage/p:StatisticsInfo') AS t(stats_info)
)
SELECT TOP ({{TopN}})
      su.stats_database
    , su.stats_schema
    , su.stats_table
    , su.stats_name
    , COUNT(DISTINCT su.query_hash)                                   AS distinct_queries_using
    , COUNT(DISTINCT su.query_plan_hash)                              AS distinct_plans_using
    , SUM(su.execution_count)                                         AS total_executions
    , SUM(su.total_cpu_time_ms)                                       AS total_cpu_time_ms
    , SUM(su.total_elapsed_time_ms)                                   AS total_elapsed_time_ms
    , SUM(su.total_logical_reads)                                     AS total_logical_reads
    , MAX(su.last_execution_time)                                     AS last_execution_time
    , AVG(su.modification_count_at_compile)                           AS avg_mods_at_compile
    , AVG(su.sample_percent_at_compile)                               AS avg_sample_pct_at_compile
    -- Current statistics state
    , sp.modification_counter                                         AS current_modification_count
    , CAST(100.0 * sp.rows_sampled / NULLIF(sp.rows, 0) 
           AS DECIMAL(5,2))                                           AS current_sample_percent
    , CASE 
        WHEN sp.modification_counter > AVG(su.modification_count_at_compile) * 2
        THEN 'Significantly changed since plans compiled'
        WHEN sp.modification_counter > AVG(su.modification_count_at_compile)
        THEN 'Changed since plans compiled'
        ELSE 'Stable'
      END                                                             AS staleness_since_compile
FROM StatsUsage su
LEFT JOIN sys.stats s 
    ON s.name = su.stats_name
    AND OBJECT_NAME(s.object_id) = su.stats_table
    AND OBJECT_SCHEMA_NAME(s.object_id) = su.stats_schema
OUTER APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) sp
WHERE su.stats_database = DB_NAME()
GROUP BY 
      su.stats_database
    , su.stats_schema
    , su.stats_table
    , su.stats_name
    , sp.modification_counter
    , sp.rows_sampled
    , sp.rows
ORDER BY total_cpu_time_ms DESC
OPTION (MAXDOP 1);
```

**Typical interpretations:**
- `staleness_since_compile = 'Significantly changed'`: Plans may be using outdated cardinality estimates
- `distinct_plans_using > 5`: High-impact statistic; ensure it's well-maintained
- `current_modification_count >> avg_mods_at_compile`: Recompilation may improve performance

**What to Do:**

| Scenario | Action |
|----------|--------|
| `staleness_since_compile = 'Significantly changed'` | 1. Update the statistic: `UPDATE STATISTICS [schema].[table] [stats_name] WITH FULLSCAN;` 2. Force plan recompilation: `EXEC sp_recompile '[schema].[table]';` — this invalidates all cached plans referencing the table so they recompile with fresh statistics |
| `distinct_queries_using > 5` with high `total_cpu_time_ms` | This statistic is a high-impact dependency. Schedule regular FULLSCAN updates and consider enabling `AUTO_UPDATE_STATISTICS_ASYNC` to avoid blocking queries during updates |
| `total_cpu_time_ms` dominated by one stats name | Focus on that statistic first — updating it and recompiling dependent plans will have the highest workload impact |
| `avg_sample_pct_at_compile < 20%` | Plans were compiled with low-quality statistics. Update with `FULLSCAN` and recompile to let the optimizer see a more accurate histogram |

---

### Step 5: Index Usage Correlation with Statistics Health

Execute with the SQL query tool. Correlates index usage patterns with statistics health to
identify statistics on heavily-used indexes that may need attention.

```sql
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

IF @EngineEdition IN (6, 11)
BEGIN
    SELECT 'This step is not supported on SQL Data Warehouse / Synapse Analytics (EngineEdition '
           + CAST(@EngineEdition AS VARCHAR(10)) + '). Statistics DMV behavior differs significantly in DW environments.'
           AS unsupported_message;
    RETURN;
END

SELECT TOP ({{TopN}})
      QUOTENAME(DB_NAME())                                            AS database_name
    , QUOTENAME(OBJECT_SCHEMA_NAME(s.object_id))                      AS schema_name
    , QUOTENAME(OBJECT_NAME(s.object_id))                             AS table_name
    , QUOTENAME(s.name)                                               AS stats_name
    , CASE 
        WHEN s.auto_created = 0 AND s.user_created = 0 THEN 'Index_Statistic'
        WHEN s.auto_created = 0 AND s.user_created = 1 THEN 'User_Created'
        WHEN s.auto_created = 1 AND s.user_created = 0 THEN 'Auto_Created'
      END                                                             AS statistic_type
    -- Index usage stats (for index-backed statistics)
    , ius.user_seeks
    , ius.user_scans
    , ius.user_lookups
    , ius.user_updates
    , ius.last_user_seek
    , ius.last_user_scan
    , ius.last_user_lookup
    -- Operational stats
    , ios.range_scan_count
    , ios.singleton_lookup_count
    , ios.leaf_insert_count + ios.leaf_delete_count + ios.leaf_update_count AS leaf_modifications
    -- Statistics properties
    , sp.last_updated                                                 AS stats_last_updated
    , sp.rows                                                         AS rows_at_update
    , sp.modification_counter                                         AS modification_count
    , CAST(100.0 * sp.modification_counter / NULLIF(sp.rows, 0) 
           AS DECIMAL(10,2))                                          AS modification_percent
    -- Analysis flags
    , CASE 
        WHEN (COALESCE(ius.user_seeks, 0) + COALESCE(ius.user_scans, 0)) > 10000 
             AND (100.0 * sp.modification_counter / NULLIF(sp.rows, 0)) > 10
        THEN 'High usage, stale stats - UPDATE RECOMMENDED'
        WHEN (COALESCE(ius.user_seeks, 0) + COALESCE(ius.user_scans, 0)) > 1000 
             AND (100.0 * sp.modification_counter / NULLIF(sp.rows, 0)) > 20
        THEN 'Medium usage, very stale - UPDATE RECOMMENDED'
        WHEN COALESCE(ius.user_seeks, 0) = 0 AND COALESCE(ius.user_scans, 0) = 0 
             AND COALESCE(ius.user_lookups, 0) = 0 AND COALESCE(ius.user_updates, 0) > 0
        THEN 'Unused index - Consider removal'
        ELSE 'OK'
      END                                                             AS recommendation
FROM sys.stats s
INNER JOIN sys.objects o ON s.object_id = o.object_id
CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) sp
LEFT JOIN sys.indexes i 
    ON s.object_id = i.object_id AND s.stats_id = i.index_id
LEFT JOIN sys.dm_db_index_usage_stats ius 
    ON i.object_id = ius.object_id 
    AND i.index_id = ius.index_id 
    AND ius.database_id = DB_ID()
OUTER APPLY (
    SELECT 
          SUM(range_scan_count) AS range_scan_count
        , SUM(singleton_lookup_count) AS singleton_lookup_count
        , SUM(leaf_insert_count) AS leaf_insert_count
        , SUM(leaf_delete_count) AS leaf_delete_count
        , SUM(leaf_update_count) AS leaf_update_count
    FROM sys.dm_db_index_operational_stats(DB_ID(), s.object_id, i.index_id, NULL)
) ios
WHERE o.type = 'U'
  AND s.auto_created = 0  -- Focus on index statistics
  AND s.user_created = 0
ORDER BY 
    CASE 
      WHEN COALESCE(ius.user_seeks, 0) + COALESCE(ius.user_scans, 0) > 10000 THEN 0
      WHEN COALESCE(ius.user_seeks, 0) + COALESCE(ius.user_scans, 0) > 1000 THEN 1
      ELSE 2
    END,
    (100.0 * sp.modification_counter / NULLIF(sp.rows, 0)) DESC
    OPTION (MAXDOP 1);
```

**Key insights:**
- `High usage, stale stats`: Prioritize updating these statistics
- `Unused index`: Statistics on unused indexes can be ignored or the index removed
- `leaf_modifications` high + `modification_percent` high: Confirms data churn

---

### Step 6: Detect Auto-Update Threshold Issues

Execute with the SQL query tool. Identifies statistics that are near or have exceeded the
auto-update threshold but may not have triggered updates due to workload patterns.

```sql
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

IF @EngineEdition IN (6, 11)
BEGIN
    SELECT 'This step is not supported on SQL Data Warehouse / Synapse Analytics (EngineEdition '
           + CAST(@EngineEdition AS VARCHAR(10)) + '). Statistics DMV behavior differs significantly in DW environments.'
           AS unsupported_message;
    RETURN;
END

DECLARE @MinRowsInTable BIGINT = {{MinRowsInTable}};
DECLARE @CompatLevel INT;
SELECT @CompatLevel = compatibility_level FROM sys.databases WHERE database_id = DB_ID();

;WITH ModificationVelocity AS (
    SELECT
          s.object_id
        , s.stats_id
        , s.name AS stats_name
        , sp.rows
        , sp.modification_counter
        , sp.unfiltered_rows
        , sp.last_updated
        , @CompatLevel                                                AS compat_level
        -- Calculate threshold based on compatibility level
        , CASE 
            WHEN @CompatLevel >= 130
                 AND COALESCE(sp.unfiltered_rows, 0) >= 25001
            THEN CAST(SQRT(1000.0 * COALESCE(sp.unfiltered_rows, 0)) AS BIGINT)
            ELSE CASE
                   WHEN COALESCE(sp.unfiltered_rows, 0) <= 500 THEN 501
                   ELSE 500 + CAST(COALESCE(sp.unfiltered_rows, 0) * 0.2 AS BIGINT)
                 END
          END                                                         AS recompile_trigger_point
    FROM sys.stats s
    INNER JOIN sys.objects o ON s.object_id = o.object_id
    CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) sp
    WHERE o.type = 'U'
      AND sp.rows >= @MinRowsInTable
)
SELECT TOP ({{TopN}})
      QUOTENAME(DB_NAME())                                            AS database_name
    , QUOTENAME(OBJECT_SCHEMA_NAME(mv.object_id))                     AS schema_name
    , QUOTENAME(OBJECT_NAME(mv.object_id))                            AS table_name
    , QUOTENAME(mv.stats_name)                                        AS stats_name
    , mv.rows                                                         AS rows_at_update
    , mv.modification_counter                                         AS pending_changes
    , mv.recompile_trigger_point
    , CASE 
        WHEN mv.compat_level >= 130 AND mv.unfiltered_rows >= 25001 
        THEN 'Dynamic (sqrt(1000 * rows))'
        ELSE 'Static (500 + 20%)'
      END                                                             AS algorithm_type
    , CAST(100.0 * mv.modification_counter / NULLIF(mv.recompile_trigger_point, 0) 
           AS DECIMAL(10,2))                                          AS staleness_ratio_pct
    , CASE 
        WHEN mv.modification_counter >= mv.recompile_trigger_point 
        THEN 'OVERDUE - Will update on next query compile'
        WHEN mv.modification_counter >= mv.recompile_trigger_point * 0.9 
        THEN 'IMMINENT - Update imminent'
        WHEN mv.modification_counter >= mv.recompile_trigger_point * 0.75 
        THEN 'WARMING (75%+)'
        WHEN mv.modification_counter >= mv.recompile_trigger_point * 0.5 
        THEN 'MODERATE (50%+)'
        ELSE 'LOW'
      END                                                             AS urgency_level
    , mv.last_updated                                                 AS last_updated
    , DATEDIFF(HOUR, mv.last_updated, SYSUTCDATETIME())               AS hours_since_update
    , CAST(1.0 * mv.modification_counter
           / NULLIF(DATEDIFF(HOUR, mv.last_updated, SYSUTCDATETIME()), 0)
           AS DECIMAL(18,2))                                          AS velocity_per_hour
    , CASE
        WHEN mv.modification_counter >= mv.recompile_trigger_point THEN 0
        ELSE CAST((mv.recompile_trigger_point - mv.modification_counter)
                  / NULLIF(
                      1.0 * mv.modification_counter
                      / NULLIF(DATEDIFF(HOUR, mv.last_updated, SYSUTCDATETIME()), 0)
                    , 0)
                  AS DECIMAL(18,2))
      END                                                             AS estimated_hours_to_trigger
    -- For tables with NORECOMPUTE
    , s.no_recompute                                                  AS auto_update_disabled
    , CASE 
        WHEN s.no_recompute = 1 AND mv.modification_counter >= mv.recompile_trigger_point
        THEN 'Manual update REQUIRED - Auto-update disabled'
        ELSE ''
      END                                                             AS warning
FROM ModificationVelocity mv
INNER JOIN sys.stats s ON mv.object_id = s.object_id AND mv.stats_id = s.stats_id
WHERE mv.modification_counter >= mv.recompile_trigger_point * 0.5  -- At least 50% toward threshold
ORDER BY 
    CASE 
      WHEN mv.modification_counter >= mv.recompile_trigger_point THEN 0
      WHEN mv.modification_counter >= mv.recompile_trigger_point * 0.9 THEN 1
      ELSE 2
    END,
    (100.0 * mv.modification_counter / NULLIF(mv.recompile_trigger_point, 0)) DESC
    OPTION (MAXDOP 1);
```

**Interpreting urgency levels:**
- `OVERDUE`: Auto-update will trigger on next query compilation using this statistic
- `IMMINENT`: Very close to triggering; consider proactive update
- `auto_update_disabled = 1`: NORECOMPUTE is set; manual updates required
- `velocity_per_hour`: Rate of row modifications per hour — helps predict when the threshold will be reached
- `estimated_hours_to_trigger`: Projected hours until the recompile trigger point is reached at the current velocity

**What to Do:**

| Scenario | Action |
|----------|--------|
| `urgency_level = 'OVERDUE'` and `auto_update_disabled = 0` | No action needed — the next query that triggers compilation will auto-update. If query latency spikes are a concern, proactively update now: `UPDATE STATISTICS [schema].[table] [stats_name] WITH FULLSCAN;` |
| `urgency_level = 'OVERDUE'` and `auto_update_disabled = 1` | **Urgent** — auto-update is blocked by `NORECOMPUTE`. Manually update: `UPDATE STATISTICS [schema].[table] [stats_name] WITH FULLSCAN;` Consider removing `NORECOMPUTE` if it was set unintentionally |
| `urgency_level = 'IMMINENT'` | Proactively update during a maintenance window to avoid runtime auto-update latency during business hours |
| `algorithm_type = 'Static (500 + 20%)'` on tables > 25K rows | The database is using the legacy threshold. Upgrade compatibility level to 130+ to enable the dynamic sqrt formula which triggers updates much earlier: `ALTER DATABASE [db] SET COMPATIBILITY_LEVEL = 130;` (test workload first) |
| `estimated_hours_to_trigger` is small | Even if `urgency_level` is only MODERATE, a high `velocity_per_hour` means the threshold will be reached soon. Plan a proactive update to avoid runtime auto-update latency |
| `hours_since_update` very large | Even if below threshold, very old statistics may have shifted distributions. Consider a proactive FULLSCAN update |

> **Best practice:** Enable `AUTO_UPDATE_STATISTICS_ASYNC` on OLTP databases to avoid blocking queries when auto-update triggers: `ALTER DATABASE [db] SET AUTO_UPDATE_STATISTICS_ASYNC ON;`

---

### Step 7: Statistics Column Details and Multi-Column Analysis

Execute with the SQL query tool. Analyzes multi-column statistics to identify potential
ascending key issues and column ordering concerns.

```sql
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

IF @EngineEdition IN (6, 11)
BEGIN
    SELECT 'This step is not supported on SQL Data Warehouse / Synapse Analytics (EngineEdition '
           + CAST(@EngineEdition AS VARCHAR(10)) + '). Statistics DMV behavior differs significantly in DW environments.'
           AS unsupported_message;
    RETURN;
END

;WITH StatsColumns AS (
    SELECT
          s.object_id
        , s.stats_id
        , s.name AS stats_name
        , sc.stats_column_id
        , c.name AS column_name
        , c.column_id
        , TYPE_NAME(c.user_type_id) AS data_type
        , c.max_length
        , c.is_identity
        , c.is_computed
        , ic.is_descending_key
    FROM sys.stats s
    INNER JOIN sys.stats_columns sc ON s.object_id = sc.object_id AND s.stats_id = sc.stats_id
    INNER JOIN sys.columns c ON sc.object_id = c.object_id AND sc.column_id = c.column_id
    LEFT JOIN sys.index_columns ic 
        ON s.object_id = ic.object_id 
        AND s.stats_id = ic.index_id 
        AND c.column_id = ic.column_id
    WHERE OBJECTPROPERTY(s.object_id, 'IsUserTable') = 1
)
SELECT TOP ({{TopN}})
      QUOTENAME(DB_NAME())                                            AS database_name
    , QUOTENAME(OBJECT_SCHEMA_NAME(sc.object_id))                     AS schema_name
    , QUOTENAME(OBJECT_NAME(sc.object_id))                            AS table_name
    , QUOTENAME(sc.stats_name)                                        AS stats_name
    -- Compatible with SQL 2012+; STRING_AGG requires SQL 2017+
    , STUFF((
        SELECT ', ' + sc2.column_name
        FROM StatsColumns sc2
        WHERE sc2.object_id = sc.object_id AND sc2.stats_id = sc.stats_id
        ORDER BY sc2.stats_column_id
        FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, '') AS columns_in_order
    , COUNT(*)                                                        AS column_count
    , MAX(CASE WHEN sc.stats_column_id = 1 THEN sc.data_type END)     AS leading_column_type
    , MAX(CASE 
        WHEN sc.stats_column_id = 1 
        THEN CAST(sc.is_identity AS int) 
     END)   AS leading_is_identity
    -- Potential ascending key detection
    , CASE 
        WHEN MAX(CASE 
        WHEN sc.stats_column_id = 1 
        THEN CAST(sc.is_identity AS int) 
     END) = 1
        THEN 'Potential ascending key issue'
        WHEN MAX(CASE WHEN sc.stats_column_id = 1 THEN sc.data_type END) 
             IN ('datetime', 'datetime2', 'date', 'timestamp')
        THEN 'Date/Time leading column - watch for ascending key'
        ELSE 'Normal'
      END                                                             AS ascending_key_risk
    , sp.rows                                                         AS rows_at_update
    , sp.steps                                                        AS histogram_steps
    , sp.modification_counter                                         AS modifications
    , sp.last_updated                                                 AS last_updated
    , s.has_filter                                                    AS is_filtered
    , s.filter_definition                                             AS filter_definition
FROM StatsColumns sc
INNER JOIN sys.stats s ON sc.object_id = s.object_id AND sc.stats_id = s.stats_id
CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) sp
GROUP BY 
      sc.object_id
    , sc.stats_id
    , sc.stats_name
    , sp.rows
    , sp.steps
    , sp.modification_counter
    , sp.last_updated
    , s.has_filter
    , s.filter_definition
HAVING COUNT(*) > 1  -- Multi-column statistics only
ORDER BY COUNT(*) DESC, sp.rows DESC
OPTION (MAXDOP 1);
```

**Ascending key analysis:**
- `leading_is_identity = 1`: Identity columns are ascending; histogram trailing edge may be stale
- Date/Time leading columns: Common ascending key pattern; consider trace flag 2371 implications
- `histogram_steps = 200`: Maximum reached; ascending values may extend beyond histogram coverage

**What to Do:**

| Scenario | Action |
|----------|--------|
| `ascending_key_risk = 'Potential ascending key issue'` | New values inserted beyond the histogram's last step get estimated as 1 row. Fix: update statistics more frequently, or on SQL 2016+ use `OPTION (QUERYTRACEON 2389)` or `OPTION (QUERYTRACEON 2390)` to enable ascending key detection at the query level |
| `ascending_key_risk` = Date/Time leading column | Same issue as identity — new dates extend beyond histogram. Schedule more frequent `UPDATE STATISTICS ... WITH FULLSCAN` on these tables (e.g., hourly or after each batch load) |
| `column_count > 3` | Multi-column statistics with many columns have diminishing returns. The optimizer only uses density vectors for columns beyond the first. Review whether the statistic is actually used by cached plans (cross-reference with Step 4) |
| `histogram_steps = 200` on ascending key | The histogram is full and new values spill past the last step. Consider creating a filtered statistic on recent data ranges: `CREATE STATISTICS [stat_recent] ON [table]([col]) WHERE [col] >= '2024-01-01' WITH FULLSCAN;` |
| `is_filtered = 1` with ascending key risk | Filtered statistics on ascending columns need more frequent updates since the filter predicate may exclude new data. Ensure the filter range covers the active data window |

---

### Step 8: Version-Compatible Statistics Modification Counter Inventory

Execute with the SQL query tool. Provides a complete inventory of statistics modification
counters and last-updated dates across all user-table statistics in the current database.
Branches on SQL Server build to use the appropriate system catalog:

| SQL Server build | Source for `modification_counter` |
|---|---|
| 2008 R2 SP3+ (10.50.4000+), 2012 SP3+ (11.3000+), 2014+ | `sys.dm_db_stats_properties` |
| Earlier builds | `sys.sysindexes.rowmodctr` (legacy; less precise) |

Use this step when:
- A broad, flat inventory of all statistics dates and modification counts is needed
- The SQL Server version may be older (pre-2014) and `sys.dm_db_stats_properties` availability is uncertain
- You want to cross-check stale statistics findings from Step 2 against the raw counter values

```sql
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

IF @EngineEdition IN (6, 11)
BEGIN
    SELECT 'This step is not supported on SQL Data Warehouse / Synapse Analytics (EngineEdition '
           + CAST(@EngineEdition AS VARCHAR(10)) + '). Statistics DMV behavior differs significantly in DW environments.'
           AS unsupported_message;
    RETURN;
END

DECLARE @sqlmajorver INT, @sqlminorver INT, @sqlbuild INT;
SELECT @sqlmajorver = CONVERT(INT, (@@microsoftversion / 0x1000000) & 0xff);
SELECT @sqlminorver = CONVERT(INT, (@@microsoftversion / 0x10000)   & 0xff);
SELECT @sqlbuild    = CONVERT(INT,  @@microsoftversion               & 0xffff);

-- sys.dm_db_stats_properties is available from:
--   SQL 2008 R2 SP3 (10.50.4000+), SQL 2012 SP3 (11.3000+), SQL 2014+ (any build)
IF   (@sqlmajorver = 10 AND @sqlminorver = 50 AND @sqlbuild >= 4000)
  OR (@sqlmajorver = 11 AND @sqlbuild >= 3000)
  OR  @sqlmajorver > 11
BEGIN
    -- Modern path: uses sys.dm_db_stats_properties for accurate per-partition row counts
    SELECT TOP ({{TopN}})
          DB_ID()                                                          AS database_id
        , mst.[object_id]                                                  AS object_id
        , ss.stats_id
        , QUOTENAME(DB_NAME())                                             AS database_name
        , QUOTENAME(t.name)                                                AS schema_name
        , QUOTENAME(OBJECT_NAME(mst.[object_id]))                          AS table_name
        , QUOTENAME(ss.name)                                               AS stats_name
        , ISNULL(sp.[rows], SUM(p.[rows]))                                 AS rows
        , sp.modification_counter
        , STATS_DATE(o.[object_id], ss.stats_id)                          AS stats_date
        , DATEDIFF(DAY, STATS_DATE(o.[object_id], ss.stats_id),
                   SYSUTCDATETIME())                                       AS days_since_update
    FROM sys.stats            AS ss
    INNER JOIN sys.objects    AS o   ON o.[object_id]   = ss.[object_id]
    INNER JOIN sys.tables     AS mst ON mst.[object_id] = o.[object_id]
    INNER JOIN sys.schemas    AS t   ON t.[schema_id]   = mst.[schema_id]
    INNER JOIN sys.partitions AS p   ON p.[object_id]   = ss.[object_id] AND p.index_id <= 1
    CROSS APPLY sys.dm_db_stats_properties(ss.[object_id], ss.stats_id) AS sp
    GROUP BY
          o.[object_id], mst.[object_id], t.name
        , ss.stats_id, ss.name
        , sp.[rows], sp.modification_counter
    ORDER BY t.name, OBJECT_NAME(mst.[object_id]), ss.name
    OPTION (MAXDOP 1);
END
ELSE
BEGIN
    -- Legacy path: uses sys.sysindexes.rowmodctr for pre-2008R2SP3 / pre-2012SP3 instances
    -- rowmodctr is a cumulative count reset at service restart and less precise than dm_db_stats_properties
    SELECT TOP ({{TopN}})
          DB_ID()                                                          AS database_id
        , mst.[object_id]                                                  AS object_id
        , ss.stats_id
        , QUOTENAME(DB_NAME())                                             AS database_name
        , QUOTENAME(t.name)                                                AS schema_name
        , QUOTENAME(OBJECT_NAME(mst.[object_id]))                          AS table_name
        , QUOTENAME(ss.name)                                               AS stats_name
        , SUM(p.[rows])                                                    AS rows
        , si.rowmodctr                                                     AS modification_counter
        , STATS_DATE(o.[object_id], ss.stats_id)                          AS stats_date
        , DATEDIFF(DAY, STATS_DATE(o.[object_id], ss.stats_id),
                   SYSUTCDATETIME())                                       AS days_since_update
    FROM sys.stats            AS ss
    INNER JOIN sys.sysindexes AS si  ON si.id         = ss.[object_id]
    INNER JOIN sys.objects    AS o   ON o.[object_id] = si.id
    INNER JOIN sys.tables     AS mst ON mst.[object_id] = o.[object_id]
    INNER JOIN sys.schemas    AS t   ON t.[schema_id] = mst.[schema_id]
    INNER JOIN sys.partitions AS p   ON p.[object_id] = ss.[object_id] AND p.index_id <= 1
    LEFT JOIN  sys.indexes    AS i   ON si.id = i.[object_id] AND si.indid = i.index_id
    WHERE o.type <> 'S'   -- exclude system objects
      AND i.name IS NOT NULL
    GROUP BY
          o.[object_id], mst.[object_id], t.name
        , si.rowmodctr, ss.stats_id, ss.name
    ORDER BY t.name, OBJECT_NAME(mst.[object_id]), ss.name
    OPTION (MAXDOP 1);
END
```

**Interpreting results:**
- `modification_counter = 0`: No modifications since last statistics update (or just updated)
- `days_since_update` is NULL: Statistics have **never** been updated — run `UPDATE STATISTICS` immediately
- Legacy path `rowmodctr`: Resets on service restart and aggregates across all indexes on the object; treat as indicative, not exact
- Combine with Step 2 output: Step 2 adds threshold analysis and qualification flags; this step provides the raw flat inventory for bulk review

---

### Step 9: Incremental Statistics Detection

Execute with the SQL query tool. Identifies tables using incremental statistics (SQL 2014+,
partitioned tables only). Incremental statistics maintain per-partition stats that merge into
a global histogram, avoiding full-table scans on statistics update. This step finds which
tables use them, which should but don't, and detects partition-level staleness.

**Skip this step** if `supports_incremental_stats = 0` from Step 1 (SQL Server < 2014).

```sql
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

IF @EngineEdition IN (6, 11)
BEGIN
    SELECT 'This step is not supported on SQL Data Warehouse / Synapse Analytics (EngineEdition '
           + CAST(@EngineEdition AS VARCHAR(10)) + '). Statistics DMV behavior differs significantly in DW environments.'
           AS unsupported_message;
    RETURN;
END

DECLARE @MinRowsInTable BIGINT = {{MinRowsInTable}};

-- Part 1: Existing incremental statistics and their partition-level health
SELECT TOP ({{TopN}})
      QUOTENAME(DB_NAME())                                            AS database_name
    , QUOTENAME(OBJECT_SCHEMA_NAME(s.object_id))                      AS schema_name
    , QUOTENAME(OBJECT_NAME(s.object_id))                             AS table_name
    , QUOTENAME(s.name)                                               AS stats_name
    , s.is_incremental                                                AS uses_partition_stats
    , pi.partition_function_name
    , pi.partition_scheme_name
    , pi.segment_count
    , sp.rows                                                         AS total_rows
    , sp.modification_counter                                         AS pending_changes_global
    , sp.last_updated                                                 AS last_updated
    , CAST(100.0 * sp.rows_sampled / NULLIF(sp.rows, 0)
           AS DECIMAL(5,2))                                           AS coverage_pct
    , CAST(sp.rows * 8.0 / 1024 / 1024 AS DECIMAL(12,2))             AS estimated_fullscan_cost_mb
    , CASE
        WHEN s.is_incremental = 1 THEN 'Per-segment'
        WHEN s.is_incremental = 0
             AND pi.segment_count > 1
        THEN 'Full-scan required – partition-level updates available'
        ELSE 'Non-partitioned (N/A)'
      END                                                             AS partition_strategy
FROM sys.stats s
INNER JOIN sys.objects o ON s.object_id = o.object_id
CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) sp
CROSS APPLY (
    SELECT
          COUNT(DISTINCT p.partition_number) AS segment_count
        , MAX(pf.name)                      AS partition_function_name
        , MAX(ps.name)                      AS partition_scheme_name
    FROM sys.partitions p
    INNER JOIN sys.indexes ix
        ON p.object_id = ix.object_id AND ix.index_id <= 1
    LEFT JOIN sys.partition_schemes ps
        ON ix.data_space_id = ps.data_space_id
    LEFT JOIN sys.partition_functions pf
        ON ps.function_id = pf.function_id
    WHERE p.object_id = s.object_id
      AND p.index_id <= 1
) pi
WHERE o.type = 'U'
  AND sp.rows >= @MinRowsInTable
  AND pi.segment_count > 1  -- Partitioned tables only
ORDER BY
    CASE WHEN s.is_incremental = 0 THEN 0 ELSE 1 END,  -- Non-incremental first (candidates)
    sp.modification_counter DESC
    OPTION (MAXDOP 1);
```

**Key insights:**
- `Full-scan required – partition-level updates available`: Consider `CREATE STATISTICS ... WITH INCREMENTAL = ON` or `ALTER INDEX ... REBUILD WITH (STATISTICS_INCREMENTAL = ON)` to avoid full-table scans on stats update
- `uses_partition_stats = 1`: Per-partition statistics are maintained; updates only scan modified partitions
- Large `segment_count` with `uses_partition_stats = 0`: Biggest beneficiaries of enabling incremental stats
- `estimated_fullscan_cost_mb`: Rough IO cost estimate for a full scan — higher values mean more savings from per-segment updates

---

### Step 10: Statistics on Computed Columns

Execute with the SQL query tool. Identifies statistics defined on computed columns. Computed
column statistics are important for queries that filter or join on expressions, but can become
stale faster if the underlying columns change frequently. This step flags computed column
statistics and their health.

```sql
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

IF @EngineEdition IN (6, 11)
BEGIN
    SELECT 'This step is not supported on SQL Data Warehouse / Synapse Analytics (EngineEdition '
           + CAST(@EngineEdition AS VARCHAR(10)) + '). Statistics DMV behavior differs significantly in DW environments.'
           AS unsupported_message;
    RETURN;
END

DECLARE @MinRowsInTable BIGINT = {{MinRowsInTable}};

SELECT TOP ({{TopN}})
      QUOTENAME(DB_NAME())                                            AS database_name
    , QUOTENAME(OBJECT_SCHEMA_NAME(s.object_id))                      AS schema_name
    , QUOTENAME(OBJECT_NAME(s.object_id))                             AS table_name
    , QUOTENAME(s.name)                                               AS stats_name
    , c.name                                                          AS computed_column_name
    , cc.definition                                                   AS computed_column_definition
    , cc.is_persisted                                                 AS is_persisted
    , CASE
        WHEN s.auto_created = 0 AND s.user_created = 0 THEN 'Index_Statistic'
        WHEN s.auto_created = 0 AND s.user_created = 1 THEN 'User_Created'
        WHEN s.auto_created = 1 AND s.user_created = 0 THEN 'Auto_Created'
      END                                                             AS statistic_type
    , sp.last_updated                                                 AS last_updated
    , DATEDIFF(DAY, sp.last_updated, SYSUTCDATETIME())                AS days_since_update
    , sp.rows                                                         AS rows_at_update
    , sp.rows_sampled                                                 AS rows_sampled
    , CAST(100.0 * sp.rows_sampled / NULLIF(sp.rows, 0)
           AS DECIMAL(5,2))                                           AS sample_percent
    , sp.modification_counter                                         AS modification_count
    , CAST(100.0 * sp.modification_counter / NULLIF(sp.rows, 0)
           AS DECIMAL(10,2))                                          AS modification_percent
    , sp.steps                                                        AS histogram_steps
    , CASE
        WHEN cc.is_persisted = 0
             AND (100.0 * sp.modification_counter / NULLIF(sp.rows, 0)) > 10
        THEN 'Non-persisted + stale - UPDATE with FULLSCAN recommended'
        WHEN (100.0 * sp.modification_counter / NULLIF(sp.rows, 0)) > 20
        THEN 'Stale - UPDATE recommended'
        ELSE 'OK'
      END                                                             AS recommendation
FROM sys.stats s
INNER JOIN sys.stats_columns sc ON s.object_id = sc.object_id AND s.stats_id = sc.stats_id
INNER JOIN sys.columns c ON sc.object_id = c.object_id AND sc.column_id = c.column_id
INNER JOIN sys.computed_columns cc ON c.object_id = cc.object_id AND c.column_id = cc.column_id
INNER JOIN sys.objects o ON s.object_id = o.object_id
CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) sp
WHERE o.type = 'U'
  AND sc.stats_column_id = 1  -- Leading column is computed
  AND sp.rows >= @MinRowsInTable
ORDER BY modification_percent DESC, sp.rows DESC
OPTION (MAXDOP 1);
```

**Key insights:**
- `is_persisted = 0`: Non-persisted computed columns are re-evaluated at query time; stale statistics have higher impact on cardinality estimates
- `is_persisted = 1`: Persisted computed columns store values physically; statistics behave like regular columns
- No results: No statistics exist on computed columns in this database (common in many workloads)
- Consider creating statistics on frequently-queried computed columns that lack them

---

### Step 11: Correlation with Missing Index Recommendations

Execute with the SQL query tool. Cross-references tables that have stale statistics with
tables that also appear in missing index recommendations. Stale statistics on tables with
missing indexes compound performance problems: the optimizer may both lack good indexes
and have inaccurate cardinality estimates.

```sql
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

IF @EngineEdition IN (6, 11)
BEGIN
    SELECT 'This step is not supported on SQL Data Warehouse / Synapse Analytics (EngineEdition '
           + CAST(@EngineEdition AS VARCHAR(10)) + '). Statistics DMV behavior differs significantly in DW environments.'
           AS unsupported_message;
    RETURN;
END

DECLARE @ModificationThresholdPct DECIMAL(5,2) = {{ModificationThresholdPct}};
DECLARE @MinRowsInTable BIGINT = {{MinRowsInTable}};

;WITH StaleStats AS (
    SELECT
          s.object_id
        , QUOTENAME(OBJECT_SCHEMA_NAME(s.object_id))                   AS schema_name
        , QUOTENAME(OBJECT_NAME(s.object_id))                          AS table_name
        , COUNT(*)                                                     AS stale_stats_count
        , MAX(CAST(100.0 * sp.modification_counter / NULLIF(sp.rows, 0)
              AS DECIMAL(10,2)))                                       AS max_modification_percent
        , MAX(sp.modification_counter)                                 AS max_modification_count
        , MIN(sp.last_updated)                                         AS oldest_stats_update
    FROM sys.stats s
    INNER JOIN sys.objects o ON s.object_id = o.object_id
    CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) sp
    WHERE o.type = 'U'
      AND sp.rows >= @MinRowsInTable
      AND (100.0 * sp.modification_counter / NULLIF(sp.rows, 0)) >= @ModificationThresholdPct
    GROUP BY s.object_id
)
SELECT TOP ({{TopN}})
      QUOTENAME(DB_NAME())                                            AS database_name
    , ss.schema_name
    , ss.table_name
    , ss.stale_stats_count
    , ss.max_modification_percent
    , ss.oldest_stats_update
    -- Missing index details
    , mid.equality_columns
    , mid.inequality_columns
    , mid.included_columns
    , migs.unique_compiles                                            AS missing_idx_compiles
    , migs.user_seeks                                                 AS missing_idx_seeks
    , migs.user_scans                                                 AS missing_idx_scans
    , migs.avg_total_user_cost                                        AS missing_idx_avg_cost
    , migs.avg_user_impact                                            AS missing_idx_avg_impact_pct
    -- Combined severity score: higher = more urgent
    , CAST(
        migs.avg_user_impact * migs.avg_total_user_cost
        * (migs.user_seeks + migs.user_scans)
        * (ss.max_modification_percent / 100.0)
        AS DECIMAL(18,2))                                             AS combined_severity_score
    , CASE
        WHEN ss.max_modification_percent > 20
             AND migs.avg_user_impact > 50
        THEN 'CRITICAL - Stale stats + high-impact missing index'
        WHEN ss.max_modification_percent > 10
             AND migs.user_seeks > 1000
        THEN 'HIGH - Stale stats on frequently-sought table'
        ELSE 'MODERATE - Review both statistics and indexing'
      END                                                             AS severity
FROM StaleStats ss
INNER JOIN sys.dm_db_missing_index_details mid
    ON mid.object_id = ss.object_id
    AND mid.database_id = DB_ID()
INNER JOIN sys.dm_db_missing_index_groups mig
    ON mid.index_handle = mig.index_handle
INNER JOIN sys.dm_db_missing_index_group_stats migs
    ON mig.index_group_handle = migs.group_handle
ORDER BY combined_severity_score DESC
OPTION (MAXDOP 1);
```

**Key insights:**
- `CRITICAL` severity: These tables need both statistics updates AND index review — double performance impact
- `combined_severity_score`: Prioritization metric combining stale stats impact with missing index cost; higher = fix first
- `stale_stats_count > 3` on a table with missing indexes: Strong indicator of neglected maintenance
- After updating statistics, re-evaluate missing index recommendations — some may disappear with better cardinality estimates

**What to Do:**

| Scenario | Action |
|----------|--------|
| `severity = 'CRITICAL'` | **Fix both issues in order:** 1. Update statistics first: `UPDATE STATISTICS [schema].[table] WITH FULLSCAN;` 2. Recompile plans: `EXEC sp_recompile '[schema].[table]';` 3. Re-check missing index DMVs — some recommendations may vanish with fresh statistics. 4. For remaining missing indexes, evaluate and create using the columns shown |
| `severity = 'HIGH'` with `missing_idx_seeks > 10000` | The missing index is heavily sought. Create it using the `equality_columns`, `inequality_columns`, and `included_columns` shown. Then update statistics on the new index |
| `stale_stats_count > 3` | The entire table's statistics are neglected. Run `UPDATE STATISTICS [schema].[table] WITH FULLSCAN;` to update all statistics on the table at once |
| `missing_idx_avg_impact_pct > 90` | The optimizer estimates >90% cost reduction with this index. Strong candidate for creation — but update statistics and recompile first to verify the recommendation persists |

> **Important:** Always update statistics before creating missing indexes. Stale statistics can generate misleading missing index recommendations. After updating, wait for the workload to generate fresh missing index data before re-evaluating. Do not flush the plan cache to speed this up: `DBCC FREEPROCCACHE` without an argument clears every cached plan on the instance. If one plan must go, scope it to that plan (`DBCC FREEPROCCACHE (<plan_handle>)`) and run it only after the user's explicit confirmation for that command.

---

### Step 12: Database-Level Statistics Settings Audit

Execute with the SQL query tool. Reviews the database-level configuration settings that control
automatic statistics behavior. Misconfigured settings are a root cause of many statistics
problems — for example, disabling `auto_create_statistics` means the optimizer never creates
column-level statistics for queries that would benefit from them.

**Why it matters:** A single misconfigured database setting can silently affect every query in
the database. This is a foundational check that should be run before investigating individual
statistics issues.

```sql
SELECT
      QUOTENAME(d.name)                                               AS database_name
    , d.compatibility_level
    , d.is_auto_create_stats_on
    , d.is_auto_update_stats_on
    , d.is_auto_update_stats_async_on
    , d.is_auto_create_stats_incremental_on
    , CASE
        WHEN d.is_auto_create_stats_on = 0
        THEN 'CRITICAL - Auto-create disabled: optimizer cannot create column stats'
        WHEN d.is_auto_update_stats_on = 0
        THEN 'CRITICAL - Auto-update disabled: statistics will go stale silently'
        WHEN d.is_auto_update_stats_async_on = 0
             AND d.is_auto_update_stats_on = 1
        THEN 'ADVISORY - Async auto-update OFF: queries may block during stats update'
        WHEN d.compatibility_level < 130
        THEN 'ADVISORY - Compat level < 130: using legacy static auto-update threshold (500+20%)'
        ELSE 'OK'
      END                                                             AS recommendation
FROM sys.databases d
WHERE d.database_id = DB_ID()
OPTION (MAXDOP 1);
```

**What to Do:**

| Scenario | Action |
|----------|--------|
| `is_auto_create_stats_on = 0` | **Critical.** Re-enable immediately: `ALTER DATABASE [db] SET AUTO_CREATE_STATISTICS ON;` Without this, the optimizer cannot create column-level statistics for predicates, leading to cardinality estimation errors across the workload |
| `is_auto_update_stats_on = 0` | **Critical.** Re-enable: `ALTER DATABASE [db] SET AUTO_UPDATE_STATISTICS ON;` Disabling this means statistics go stale indefinitely unless manually updated. Only disable if you have a robust scheduled maintenance plan |
| `is_auto_update_stats_async_on = 0` on OLTP databases | Enable async updates to prevent query blocking: `ALTER DATABASE [db] SET AUTO_UPDATE_STATISTICS_ASYNC ON;` Synchronous auto-update blocks the triggering query while statistics are refreshed — on large tables this can cause multi-second stalls |
| `compatibility_level < 130` on SQL 2016+ | Consider upgrading: `ALTER DATABASE [db] SET COMPATIBILITY_LEVEL = 130;` (test first). Level 130+ enables the dynamic sqrt auto-update threshold, which triggers statistics updates much earlier on large tables |
| `is_auto_create_stats_incremental_on = 0` with partitioned tables | If you have large partitioned tables, consider enabling: `ALTER DATABASE [db] SET AUTO_CREATE_STATISTICS ON (INCREMENTAL = ON);` This creates partition-aware statistics that update faster |

---

### Step 13: Duplicate Statistics Detection

Execute with the SQL query tool. Finds statistics with identical leading key columns on the
same table. Duplicate statistics waste plan compilation time because the optimizer evaluates
each one, and they consume storage and maintenance overhead without providing additional
information.

**Why it matters:** Every duplicate statistic is evaluated during query compilation, adding
CPU overhead. On busy OLTP systems with thousands of compilations per second, redundant
statistics can measurably increase compilation time. They also double the maintenance cost
of UPDATE STATISTICS operations.

```sql
;WITH ColumnFingerprint AS (
    SELECT
          s.object_id
        , s.stats_id
        , s.name                                                      AS stats_name
        , s.auto_created
        , s.user_created
        , s.has_filter
        , s.filter_definition
        , CASE
            WHEN s.auto_created = 0 AND s.user_created = 0 THEN 'Idx'
            WHEN s.auto_created = 0 AND s.user_created = 1 THEN 'Manual'
            WHEN s.auto_created = 1 AND s.user_created = 0 THEN 'Auto'
          END                                                         AS origin
        , STUFF((
            SELECT ', ' + c2.name
            FROM sys.stats_columns sc2
            INNER JOIN sys.columns c2 ON sc2.object_id = c2.object_id AND sc2.column_id = c2.column_id
            WHERE sc2.object_id = s.object_id AND sc2.stats_id = s.stats_id
            ORDER BY sc2.stats_column_id
            FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, '') AS column_signature
        , COUNT(*)                                                    AS key_depth
    FROM sys.stats s
    INNER JOIN sys.stats_columns sc
        ON s.object_id = sc.object_id AND s.stats_id = sc.stats_id
    INNER JOIN sys.columns c
        ON sc.object_id = c.object_id AND sc.column_id = c.column_id
    WHERE OBJECTPROPERTY(s.object_id, 'IsUserTable') = 1
    GROUP BY s.object_id, s.stats_id, s.name,
             s.auto_created, s.user_created, s.has_filter, s.filter_definition
),
PairNumbered AS (
    SELECT
          a.object_id
        , a.stats_id   AS stats_id_a
        , b.stats_id   AS stats_id_b
        , a.stats_name  AS first_stats
        , a.origin       AS first_origin
        , a.column_signature AS first_signature
        , b.stats_name  AS second_stats
        , b.origin       AS second_origin
        , b.column_signature AS second_signature
        , a.filter_definition AS filter_def
        , CASE
            WHEN a.column_signature = b.column_signature
                 AND ISNULL(a.filter_definition, '') = ISNULL(b.filter_definition, '')
            THEN 'Identical coverage'
            WHEN b.column_signature LIKE a.column_signature + ',%'
            THEN 'Subset (second covers first)'
            WHEN a.column_signature LIKE b.column_signature + ',%'
            THEN 'Subset (first covers second)'
            ELSE 'Shared leading key'
          END           AS overlap_classification
        , ROW_NUMBER() OVER (
            PARTITION BY a.object_id,
                         CASE WHEN a.stats_id < b.stats_id
                              THEN a.stats_id ELSE b.stats_id END,
                         CASE WHEN a.stats_id < b.stats_id
                              THEN b.stats_id ELSE a.stats_id END
            ORDER BY a.stats_id
          )             AS pair_seq
    FROM ColumnFingerprint a
    INNER JOIN ColumnFingerprint b
        ON a.object_id = b.object_id
        AND a.stats_id <> b.stats_id
        AND ISNULL(a.filter_definition, '') = ISNULL(b.filter_definition, '')
    WHERE (
        a.column_signature = b.column_signature
        OR b.column_signature LIKE a.column_signature + ',%'
        OR a.column_signature LIKE b.column_signature + ',%'
    )
)
SELECT TOP ({{TopN}})
      QUOTENAME(DB_NAME())                                            AS database_name
    , QUOTENAME(OBJECT_SCHEMA_NAME(pn.object_id))                     AS schema_name
    , QUOTENAME(OBJECT_NAME(pn.object_id))                            AS table_name
    , QUOTENAME(pn.first_stats)                                       AS first_stats
    , pn.first_origin
    , pn.first_signature
    , QUOTENAME(pn.second_stats)                                      AS second_stats
    , pn.second_origin
    , pn.second_signature
    , pn.overlap_classification
    , CAST(0.1 * (SELECT COUNT(*) FROM ColumnFingerprint cf
                  WHERE cf.object_id = pn.object_id) AS DECIMAL(8,2)) AS wasted_compilation_ms_estimate
FROM PairNumbered pn
WHERE pn.pair_seq = 1
ORDER BY OBJECT_NAME(pn.object_id), pn.first_stats
OPTION (MAXDOP 1);
```

**What to Do:**

| Scenario | Action |
|----------|--------|
| `overlap_classification = 'Identical coverage'` | Drop the `Auto` one (if one is auto-created). If both are user-created or index-backed, keep the index statistic and drop the other using `DROP STATISTICS [schema].[table].[stats_name];` |
| `overlap_classification = 'Subset (second covers first)'` | The second statistic provides all the histogram information the first does plus more. Drop the first if it's `Auto`: its histogram on the leading column is already covered by the second's leading column histogram |
| Multiple duplicates on the same table | Clean up all duplicates at once. Focus on dropping `Auto` statistics that are redundant with `Idx` — the index statistic is always maintained automatically |
| `wasted_compilation_ms_estimate` is high | Tables with many overlapping statistics incur the most compilation overhead — prioritize cleanup there |
| No results returned | Good — no duplicate statistics found in this database |

---

### Step 14: Empty Histogram Detection

Execute with the SQL query tool. Finds statistics objects where the histogram has zero steps
despite the underlying table having rows. An empty histogram causes the optimizer to estimate
1 row for any predicate, leading to nested-loop plans on large tables and severe performance
degradation.

**Why it matters:** A statistic with an empty histogram is worse than no statistic at all — the
optimizer trusts it and produces plans based on a 1-row estimate. This commonly happens after
bulk loads with minimal logging, partition switches, or when `UPDATE STATISTICS` runs on a
table that is concurrently being modified.

```sql
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

IF @EngineEdition IN (6, 11)
BEGIN
    SELECT 'This step is not supported on SQL Data Warehouse / Synapse Analytics (EngineEdition '
           + CAST(@EngineEdition AS VARCHAR(10)) + '). Statistics DMV behavior differs significantly in DW environments.'
           AS unsupported_message;
    RETURN;
END

SELECT TOP ({{TopN}})
      QUOTENAME(DB_NAME())                                            AS database_name
    , QUOTENAME(OBJECT_SCHEMA_NAME(s.object_id))                      AS schema_name
    , QUOTENAME(OBJECT_NAME(s.object_id))                             AS table_name
    , QUOTENAME(s.name)                                               AS stats_name
    , CASE
        WHEN s.auto_created = 0 AND s.user_created = 0 THEN 'Index_Statistic'
        WHEN s.auto_created = 0 AND s.user_created = 1 THEN 'User_Created'
        WHEN s.auto_created = 1 AND s.user_created = 0 THEN 'Auto_Created'
      END                                                             AS statistic_type
    , sp.last_updated                                                 AS last_updated
    , sp.rows                                                         AS rows_at_last_update
    , ISNULL(sp.steps, 0)                                             AS histogram_steps
    , sp.modification_counter                                         AS modification_count
    , (SELECT SUM(p.rows)
       FROM sys.partitions p
       WHERE p.object_id = s.object_id AND p.index_id <= 1)           AS current_row_count
FROM sys.stats s
INNER JOIN sys.objects o ON s.object_id = o.object_id
CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) sp
WHERE o.type = 'U'
  AND ISNULL(sp.steps, 0) = 0
  AND (SELECT SUM(p.rows)
       FROM sys.partitions p
       WHERE p.object_id = s.object_id AND p.index_id <= 1) > 0
ORDER BY (SELECT SUM(p.rows)
          FROM sys.partitions p
          WHERE p.object_id = s.object_id AND p.index_id <= 1) DESC
          OPTION (MAXDOP 1);
```

**What to Do:**

| Scenario | Action |
|----------|--------|
| Any rows returned | **Urgent.** Every empty histogram causes 1-row cardinality estimates. Run `UPDATE STATISTICS [schema].[table] [stats_name] WITH FULLSCAN;` immediately |
| `current_row_count` is very large | Highest priority — empty histogram on a large table causes the optimizer to choose nested loops where hash/merge joins are needed, often resulting in query timeouts |
| `statistic_type = 'Index_Statistic'` | The index itself may have been created on an empty table and never rebuilt/updated. Run `ALTER INDEX [idx] ON [table] REBUILD;` or `UPDATE STATISTICS ... WITH FULLSCAN` |
| Problem recurs after fixing | Check for concurrent bulk operations (BCP, BULK INSERT, partition switches) that may reset the histogram. Schedule `UPDATE STATISTICS` after bulk load jobs |
| No results returned | Good — no empty histograms in this database |

---

### Step 15: Statistics Bloat Detection (More Stats Than Columns)

Execute with the SQL query tool. Identifies tables where the number of statistics objects
exceeds the number of columns. While not always wrong (multi-column and filtered stats can
legitimately exceed the column count), a high ratio often indicates accumulated auto-created
statistics that were never cleaned up, or redundant user-created statistics.

**Why it matters:** Excessive statistics increase plan compilation time (the optimizer evaluates
each one), slow down `sp_updatestats` and scheduled maintenance, and consume memory in the
statistics cache. On tables with 50+ statistics objects, compilation overhead can become
noticeable.

```sql
;WITH StatsCounts AS (
    SELECT
          s.object_id
        , COUNT(DISTINCT s.stats_id)                                  AS stats_count
        , COUNT(DISTINCT c.column_id)                                 AS column_count
    FROM sys.stats s
    INNER JOIN sys.objects o ON s.object_id = o.object_id
    INNER JOIN sys.columns c ON s.object_id = c.object_id
    WHERE o.type = 'U'
    GROUP BY s.object_id
)
SELECT TOP ({{TopN}})
      QUOTENAME(DB_NAME())                                            AS database_name
    , QUOTENAME(OBJECT_SCHEMA_NAME(sc.object_id))                     AS schema_name
    , QUOTENAME(OBJECT_NAME(sc.object_id))                            AS table_name
    , sc.stats_count
    , sc.column_count
    , sc.stats_count - sc.column_count                                AS excess_stats
    , CAST(1.0 * sc.stats_count / NULLIF(sc.column_count, 0)
           AS DECIMAL(5,2))                                           AS stats_to_column_ratio
    , (SELECT COUNT(*)
       FROM sys.stats s2
       WHERE s2.object_id = sc.object_id AND s2.auto_created = 1)    AS auto_created_count
    , (SELECT COUNT(*)
       FROM sys.stats s2
       WHERE s2.object_id = sc.object_id AND s2.user_created = 1)    AS user_created_count
    , (SELECT SUM(p.rows)
       FROM sys.partitions p
       WHERE p.object_id = sc.object_id AND p.index_id <= 1)         AS row_count
    , CASE
        WHEN sc.stats_count > sc.column_count * 2
        THEN 'HIGH - More than 2x stats vs columns, review for duplicates'
        WHEN sc.stats_count > sc.column_count
        THEN 'MODERATE - Excess stats, check for redundancy'
        ELSE 'OK'
      END                                                             AS recommendation
FROM StatsCounts sc
WHERE sc.stats_count > sc.column_count
  AND sc.stats_count > 5
ORDER BY sc.stats_count - sc.column_count DESC
OPTION (MAXDOP 1);
```

**What to Do:**

| Scenario | Action |
|----------|--------|
| `stats_to_column_ratio > 2.0` | High bloat. Run Step 13 (Duplicate Statistics) on this table specifically. Drop redundant `Auto_Created` stats that overlap with index statistics |
| `auto_created_count` is very high | Auto-created stats accumulated over time. Cross-reference with Step 4 (Plan Cache Usage) — drop auto-created stats that are not referenced by any cached plan |
| `user_created_count` is high | Someone manually created many statistics. Review whether they are still needed — workload changes may have made them obsolete |
| No results returned | Good — no tables with excessive statistics in this database |

---

### Step 16: Unused Statistics That Exceeded Auto-Update Threshold

Execute with the SQL query tool. Identifies statistics where the modification counter has
exceeded the auto-update threshold, yet the statistics have not been updated — meaning no
query compilation has triggered their refresh. These are "zombie" statistics: they consume
auto-update evaluation overhead on every compilation but provide no value because no query
uses them.

**Why it matters:** Each query compilation evaluates whether referenced statistics need
auto-update. Statistics that are never used but still tracked waste CPU during compilation.
More importantly, if these statistics are eventually used by a new query, the optimizer will
get severely outdated cardinality estimates.

```sql
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

IF @EngineEdition IN (6, 11)
BEGIN
    SELECT 'This step is not supported on SQL Data Warehouse / Synapse Analytics (EngineEdition '
           + CAST(@EngineEdition AS VARCHAR(10)) + '). Statistics DMV behavior differs significantly in DW environments.'
           AS unsupported_message;
    RETURN;
END

DECLARE @CompatLevel INT;
SELECT @CompatLevel = compatibility_level FROM sys.databases WHERE database_id = DB_ID();

SELECT TOP ({{TopN}})
      QUOTENAME(DB_NAME())                                            AS database_name
    , QUOTENAME(OBJECT_SCHEMA_NAME(s.object_id))                      AS schema_name
    , QUOTENAME(OBJECT_NAME(s.object_id))                             AS table_name
    , QUOTENAME(s.name)                                               AS stats_name
    , CASE
        WHEN s.auto_created = 0 AND s.user_created = 0 THEN 'Index_Statistic'
        WHEN s.auto_created = 0 AND s.user_created = 1 THEN 'User_Created'
        WHEN s.auto_created = 1 AND s.user_created = 0 THEN 'Auto_Created'
      END                                                             AS statistic_type
    , sp.last_updated                                                 AS last_updated
    , DATEDIFF(DAY, sp.last_updated, SYSUTCDATETIME())                AS days_since_update
    , sp.rows                                                         AS rows_at_update
    , sp.modification_counter                                         AS modification_count
    -- Auto-update threshold
    , CASE
        WHEN @CompatLevel >= 130
             AND COALESCE(sp.unfiltered_rows, 0) >= 25001
        THEN CAST(SQRT(1000.0 * COALESCE(sp.unfiltered_rows, 0)) AS BIGINT)
        ELSE CASE
               WHEN COALESCE(sp.unfiltered_rows, 0) <= 500 THEN 501
               ELSE 500 + CAST(COALESCE(sp.unfiltered_rows, 0) * 0.2 AS BIGINT)
             END
      END                                                             AS auto_update_threshold
    , CAST(100.0 * sp.modification_counter
           / NULLIF(CASE
               WHEN @CompatLevel >= 130
                    AND COALESCE(sp.unfiltered_rows, 0) >= 25001
               THEN CAST(SQRT(1000.0 * COALESCE(sp.unfiltered_rows, 0)) AS BIGINT)
               ELSE CASE
                      WHEN COALESCE(sp.unfiltered_rows, 0) <= 500 THEN 501
                      ELSE 500 + CAST(COALESCE(sp.unfiltered_rows, 0) * 0.2 AS BIGINT)
                    END
             END, 0) AS DECIMAL(10,2))                                AS percent_over_threshold
    -- Index usage: check if any query seeks/scans this stat's index
    , COALESCE(ius.last_user_seek, '1900-01-01')                      AS last_user_seek
    , COALESCE(ius.last_user_scan, '1900-01-01')                      AS last_user_scan
    , COALESCE(ius.last_user_lookup, '1900-01-01')                    AS last_user_lookup
    , CASE
        WHEN COALESCE(ius.last_user_seek, '1900-01-01') = '1900-01-01'
             AND COALESCE(ius.last_user_scan, '1900-01-01') = '1900-01-01'
             AND COALESCE(ius.last_user_lookup, '1900-01-01') = '1900-01-01'
        THEN 'Never used since restart - CANDIDATE FOR DROP'
        ELSE 'Used but auto-update not triggered - UPDATE RECOMMENDED'
      END                                                             AS recommendation
FROM sys.stats s
INNER JOIN sys.objects o ON s.object_id = o.object_id
CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) sp
LEFT JOIN sys.indexes i
    ON s.object_id = i.object_id AND s.stats_id = i.index_id
LEFT JOIN sys.dm_db_index_usage_stats ius
    ON i.object_id = ius.object_id
    AND i.index_id = ius.index_id
    AND ius.database_id = DB_ID()
WHERE o.type = 'U'
  AND s.no_recompute = 0
  AND sp.modification_counter >=
      CASE
        WHEN @CompatLevel >= 130
             AND COALESCE(sp.unfiltered_rows, 0) >= 25001
        THEN CAST(SQRT(1000.0 * COALESCE(sp.unfiltered_rows, 0)) AS BIGINT)
        ELSE CASE
               WHEN COALESCE(sp.unfiltered_rows, 0) <= 500 THEN 501
               ELSE 500 + CAST(COALESCE(sp.unfiltered_rows, 0) * 0.2 AS BIGINT)
             END
      END
  AND DATEDIFF(DAY, sp.last_updated, SYSUTCDATETIME()) > {{StaleDaysThreshold}}
ORDER BY sp.modification_counter DESC
OPTION (MAXDOP 1);
```

**What to Do:**

| Scenario | Action |
|----------|--------|
| `recommendation = 'Never used since restart'` and `statistic_type = 'Auto_Created'` | Safe to drop: `DROP STATISTICS [schema].[table].[stats_name];` This auto-created statistic is unused and wasting maintenance overhead |
| `recommendation = 'Never used since restart'` and `statistic_type = 'Index_Statistic'` | The underlying index is also unused. Consider dropping the index entirely (which removes the statistic too). Cross-reference with Step 5 for index usage analysis |
| `recommendation = 'Used but auto-update not triggered'` | The statistic is used by queries but no compilation triggered auto-update despite exceeding threshold. This can happen with plan caching — manually update: `UPDATE STATISTICS [schema].[table] [stats_name] WITH FULLSCAN;` |
| `percent_over_threshold > 200` | The modification counter is 2x+ the auto-update threshold. The statistic is severely stale — update immediately regardless of usage |
| No results returned | Good — all statistics that exceeded their auto-update threshold were refreshed automatically |

---

### Step 17: Orphaned Advisor Artifacts

Execute with the SQL query tool. Identifies hypothetical statistics and indexes left behind by
the Database Tuning Advisor. Tuning advisors create these objects to test "what-if" scenarios but
do not always clean them up. A hypothetical index (`is_hypothetical = 1`) is never used by the query
optimizer to access data. A statistics object that only has a `_dta_stat` or `_dta_index` name is
different: DTA also creates real statistics with those names when its recommendations are applied,
and the optimizer uses them.

**Why it matters:** Hypothetical indexes appear in `sys.stats` and `sys.indexes` but are never
chosen by the optimizer. They add clutter to metadata queries, can confuse maintenance
scripts (e.g., `sp_updatestats` may try to update them), and waste catalog space.

```sql
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

IF @EngineEdition IN (6, 11)
BEGIN
    SELECT 'This step is not supported on SQL Data Warehouse / Synapse Analytics (EngineEdition '
           + CAST(@EngineEdition AS VARCHAR(10)) + '). Statistics DMV behavior differs significantly in DW environments.'
           AS unsupported_message;
    RETURN;
END

SELECT TOP ({{TopN}})
      QUOTENAME(DB_NAME())                                            AS database_name
    , QUOTENAME(OBJECT_SCHEMA_NAME(s.object_id))                      AS schema_name
    , QUOTENAME(OBJECT_NAME(s.object_id))                             AS table_name
    , QUOTENAME(s.name)                                               AS stats_name
    , CASE
        WHEN s.auto_created = 0 AND s.user_created = 0 THEN 'Idx'
        WHEN s.auto_created = 0 AND s.user_created = 1 THEN 'Manual'
        WHEN s.auto_created = 1 AND s.user_created = 0 THEN 'Auto'
      END                                                             AS statistic_type
    , CASE
        WHEN ISNULL(i.is_hypothetical, 0) = 1
             AND INDEXPROPERTY(i.object_id, i.name, 'IsHypothetical') = 1
        THEN 'Phantom index with associated statistics'
        ELSE 'Phantom statistics object'
      END                                                             AS artifact_category
    , sp.last_updated                                                 AS last_updated
    , ISNULL(sp.steps, 0)                                             AS histogram_depth
    , DATEDIFF(DAY, o.create_date, SYSUTCDATETIME())                  AS days_since_creation
    , CAST(8192.0 * (1 + ISNULL(sp.steps, 0)) / 1024 AS DECIMAL(10,2)) AS catalog_bloat_bytes
FROM sys.stats s
INNER JOIN sys.objects o ON s.object_id = o.object_id
LEFT JOIN sys.indexes i
    ON s.object_id = i.object_id AND s.stats_id = i.index_id
OUTER APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) sp
WHERE o.type = 'U'
  AND (
    -- Primary detection: system-level hypothetical flag on the index
    INDEXPROPERTY(i.object_id, i.name, 'IsHypothetical') = 1
    -- Secondary fallback: stats-only objects left by tuning advisors
    OR (
        i.index_id IS NULL
        AND (s.name LIKE '%[_]dta[_]stat%' OR s.name LIKE '%[_]dta[_]index%')
    )
    -- Catch any index explicitly marked hypothetical
    OR ISNULL(i.is_hypothetical, 0) = 1
  )
ORDER BY OBJECT_NAME(s.object_id), s.name
OPTION (MAXDOP 1);
```

**What to Do:**

| Scenario | Action |
|----------|--------|
| Any rows returned | Report them; drop nothing without the user's explicit confirmation for each command. Only a hypothetical index (`is_hypothetical = 1`) is safe to drop once confirmed: `DROP INDEX [name] ON [schema].[table];`. A 'Phantom statistics object' matched only by its `_dta_stat`/`_dta_index` name may be a real statistic the optimizer uses, so review it first (`last_updated`, `histogram_depth`, whether current plans load it) before proposing `DROP STATISTICS [schema].[table].[stats_name];` |
| `artifact_category` = 'Phantom index with associated statistics' | After confirmation, drop the index (which removes the associated statistic automatically). Do **not** try to drop the statistic separately |
| `histogram_depth = 0` or `last_updated IS NULL` | Suggests a tuning advisor test object that was never fully built. Still review it and confirm with the user before dropping |
| `days_since_creation` is very large | These artifacts have been lingering for a long time; list them as cleanup candidates for the user to confirm |
| Large number of orphaned artifacts | The Database Tuning Advisor was run but recommendations were not applied or cleaned up. Propose dropping the hypothetical indexes, and review the DTA-named statistics one by one |
| No results returned | Good — no hypothetical objects in this database |

---

### Step 18: Missing Multi-Column Foreign Key Statistics

Execute with the SQL query tool. Identifies composite (multi-column) foreign keys that lack a
corresponding multi-column statistic. When a query joins on a composite FK, the optimizer
needs multi-column density information to produce accurate join cardinality estimates. Without
a matching multi-column statistic, it relies on independence assumptions that often
overestimate or underestimate join output.

**Why it matters:** Single-column auto-created statistics do not capture correlation between
columns in a composite FK. For example, if `(CountryCode, StateCode)` is a FK, the optimizer
may estimate `Country='US'` and `State='CA'` independently, missing the fact that `CA` only
appears under `US`. A multi-column statistic captures this correlation in its density vector.

```sql
;WITH FKColumns AS (
    SELECT
          fkc.parent_object_id
        , fkc.constraint_object_id
        , OBJECT_SCHEMA_NAME(fkc.parent_object_id)                    AS schema_name
        , OBJECT_NAME(fkc.parent_object_id)                           AS table_name
        , STUFF((
            SELECT ', ' + c2.name
            FROM sys.foreign_key_columns fkc2
            INNER JOIN sys.columns c2 ON fkc2.parent_object_id = c2.object_id AND fkc2.parent_column_id = c2.column_id
            WHERE fkc2.constraint_object_id = fkc.constraint_object_id
            ORDER BY fkc2.constraint_column_id
            FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, '') AS fk_columns
        , COUNT(*)                                                    AS fk_column_count
        , OBJECT_NAME(fkc.constraint_object_id)                       AS fk_name
    FROM sys.foreign_key_columns fkc
    INNER JOIN sys.columns c
        ON fkc.parent_object_id = c.object_id
        AND fkc.parent_column_id = c.column_id
    GROUP BY fkc.parent_object_id, fkc.constraint_object_id
    HAVING COUNT(*) > 1  -- Multi-column FKs only
)
, ExistingStats AS (
    SELECT
          s.object_id
        , STUFF((
            SELECT ', ' + c2.name
            FROM sys.stats_columns sc2
            INNER JOIN sys.columns c2 ON sc2.object_id = c2.object_id AND sc2.column_id = c2.column_id
            WHERE sc2.object_id = s.object_id AND sc2.stats_id = s.stats_id
            ORDER BY sc2.stats_column_id
            FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, '') AS stat_columns
    FROM sys.stats s
    INNER JOIN sys.stats_columns sc
        ON s.object_id = sc.object_id AND s.stats_id = sc.stats_id
    INNER JOIN sys.columns c
        ON sc.object_id = c.object_id AND sc.column_id = c.column_id
    WHERE OBJECTPROPERTY(s.object_id, 'IsUserTable') = 1
    GROUP BY s.object_id, s.stats_id
)
SELECT TOP ({{TopN}})
      QUOTENAME(DB_NAME())                                            AS database_name
    , QUOTENAME(fk.schema_name)                                       AS schema_name
    , QUOTENAME(fk.table_name)                                        AS table_name
    , fk.fk_name                                                      AS foreign_key_name
    , fk.fk_columns                                                   AS fk_key_columns
    , fk.fk_column_count
    , (SELECT SUM(p.rows)
       FROM sys.partitions p
       WHERE p.object_id = fk.parent_object_id AND p.index_id <= 1)  AS table_row_count
FROM FKColumns fk
WHERE NOT EXISTS (
    SELECT 1
    FROM ExistingStats es
    WHERE es.object_id = fk.parent_object_id
      AND es.stat_columns = fk.fk_columns
)
ORDER BY
    (SELECT SUM(p.rows)
     FROM sys.partitions p
     WHERE p.object_id = fk.parent_object_id AND p.index_id <= 1) DESC
     OPTION (MAXDOP 1);
```

**What to Do:**

| Scenario | Action |
|----------|--------|
| Any rows returned | Create multi-column statistics on the FK columns using `CREATE STATISTICS [stat_FK_cols] ON [schema].[table] (columns) WITH FULLSCAN;`. Prioritize tables with the highest `table_row_count` — the impact of missing density information is proportional to table size |
| `fk_column_count > 2` | Three or more columns in the FK — the independence assumption error compounds with more columns, making the multi-column statistic even more important |
| Table has both missing FK stats and stale stats (from Step 2) | Address both: first update existing stale stats, then create the missing FK stats. Stale stats compound the estimation error |
| No results returned | Good — all multi-column foreign keys have corresponding statistics |

---

### Step 19: Sample Rate Durability Assessment

Execute with the SQL query tool. Analyzes statistics that were updated with `FULLSCAN` but lack
the `PERSIST_SAMPLE_PERCENT` flag. Without this flag, a subsequent auto-update will revert to
the default low sample rate, degrading histogram quality. Available on SQL Server 2016 SP1+
and Azure SQL.

**Why it matters:** DBAs often run `UPDATE STATISTICS ... WITH FULLSCAN` during maintenance
windows for maximum histogram quality. But the next time auto-update triggers (during normal
workload), SQL Server reverts to its default sample rate (often 1–5% on large tables). The
`PERSIST_SAMPLE_PERCENT` option (SQL 2016 SP1+) preserves the chosen sample rate across
auto-updates.

**Skip this step** if `supports_persisted_sample = 0` from Step 1 (SQL Server < 2016 SP1).

```sql
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

IF @EngineEdition IN (6, 11)
BEGIN
    SELECT 'This step is not supported on SQL Data Warehouse / Synapse Analytics (EngineEdition '
           + CAST(@EngineEdition AS VARCHAR(10)) + '). Statistics DMV behavior differs significantly in DW environments.'
           AS unsupported_message;
    RETURN;
END

SELECT TOP ({{TopN}})
      QUOTENAME(DB_NAME())                                            AS database_name
    , QUOTENAME(OBJECT_SCHEMA_NAME(s.object_id))                      AS schema_name
    , QUOTENAME(OBJECT_NAME(s.object_id))                             AS table_name
    , QUOTENAME(s.name)                                               AS stats_name
    , CASE
        WHEN s.auto_created = 0 AND s.user_created = 0 THEN 'Idx'
        WHEN s.auto_created = 0 AND s.user_created = 1 THEN 'Manual'
        WHEN s.auto_created = 1 AND s.user_created = 0 THEN 'Auto'
      END                                                             AS statistic_type
    , sp.last_updated
    , sp.rows                                                         AS rows_at_update
    , sp.rows_sampled
    , CAST(100.0 * sp.rows_sampled / NULLIF(sp.rows, 0)
           AS DECIMAL(5,2))                                           AS coverage_ratio
    , TRY_CAST(s.has_persisted_sample AS BIT)                         AS rate_is_durable
    , CASE
        WHEN CAST(100.0 * sp.rows_sampled / NULLIF(sp.rows, 0) AS DECIMAL(5,2)) >= 100
             AND TRY_CAST(s.has_persisted_sample AS BIT) = 0
        THEN 'High-quality scan at risk of degradation'
        WHEN CAST(100.0 * sp.rows_sampled / NULLIF(sp.rows, 0) AS DECIMAL(5,2)) >= 50
             AND TRY_CAST(s.has_persisted_sample AS BIT) = 0
        THEN 'Elevated coverage at risk of reset'
        WHEN TRY_CAST(s.has_persisted_sample AS BIT) = 1
        THEN 'Durable'
        ELSE 'Insufficient coverage'
      END                                                             AS durability_risk
    , CAST(
        CAST(100.0 * sp.rows_sampled / NULLIF(sp.rows, 0) AS DECIMAL(5,2))
        - CASE
            WHEN sp.rows > 8000000  THEN 1.0
            WHEN sp.rows > 1000000  THEN 5.0
            ELSE 25.0
          END
        AS DECIMAL(5,2))                                              AS quality_gap_if_reset
FROM sys.stats s
INNER JOIN sys.objects o ON s.object_id = o.object_id
CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) sp
WHERE o.type = 'U'
  AND sp.rows >= {{MinRowsInTable}}
  AND CAST(100.0 * sp.rows_sampled / NULLIF(sp.rows, 0)
           AS DECIMAL(5,2)) >= 50
  AND TRY_CAST(s.has_persisted_sample AS BIT) = 0
ORDER BY sp.rows DESC
OPTION (MAXDOP 1);
```

**What to Do:**

| Scenario | Action |
|----------|--------|
| `durability_risk` = 'High-quality scan at risk of degradation' | **High value fix.** Run `UPDATE STATISTICS [schema].[table] [stats_name] WITH FULLSCAN, PERSIST_SAMPLE_PERCENT = ON;` to ensure future auto-updates maintain the FULLSCAN quality instead of reverting to a low sample |
| `durability_risk` = 'Elevated coverage at risk of reset' | Same fix — persist the high sample rate. Particularly important on tables > 10M rows where the default auto-update sample rate drops to 1–5% |
| `quality_gap_if_reset` is large | The difference between current coverage and what auto-update would use is significant — persisting is critical to avoid histogram quality regression |
| Many statistics affected | Do NOT use `sp_updatestats` — it reverts to the default low sample rate. Instead, target each statistic individually with `UPDATE STATISTICS [schema].[table] [stats] WITH FULLSCAN, PERSIST_SAMPLE_PERCENT = ON;` during a maintenance window. Prioritize by table size (largest first) |
| `skip_reason` returned | SQL Server version does not support this feature. No action possible — consider scheduling regular FULLSCAN maintenance jobs to compensate |
| No results returned | Good — all high-sample statistics already have PERSIST_SAMPLE_PERCENT enabled, or no statistics qualify |

---

### Step 20: Fullscan-to-Sample Regression Detection

Execute with the SQL query tool. Detects statistics that were previously updated with a full scan
but have since been auto-updated with a lower sample rate, potentially degrading histogram
quality. This regression typically happens silently when auto-update triggers between scheduled
maintenance windows.

**Why it matters:** A full scan produces the most accurate histogram possible (every row is
read). When auto-update later replaces it with a sampled update (often 1–5% on large tables),
the histogram quality can degrade significantly — leading to worse cardinality estimates and
plan regressions compared to when the full scan was in effect.

```sql
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

IF @EngineEdition IN (6, 11)
BEGIN
    SELECT 'This step is not supported on SQL Data Warehouse / Synapse Analytics (EngineEdition '
           + CAST(@EngineEdition AS VARCHAR(10)) + '). Statistics DMV behavior differs significantly in DW environments.'
           AS unsupported_message;
    RETURN;
END

DECLARE @MinRowsInTable BIGINT = {{MinRowsInTable}};

SELECT TOP ({{TopN}})
      QUOTENAME(DB_NAME())                                            AS database_name
    , QUOTENAME(OBJECT_SCHEMA_NAME(s.object_id))                      AS schema_name
    , QUOTENAME(OBJECT_NAME(s.object_id))                             AS table_name
    , QUOTENAME(s.name)                                               AS stats_name
    , CASE
        WHEN s.auto_created = 0 AND s.user_created = 0 THEN 'Index_Statistic'
        WHEN s.auto_created = 0 AND s.user_created = 1 THEN 'User_Created'
        WHEN s.auto_created = 1 AND s.user_created = 0 THEN 'Auto_Created'
      END                                                             AS statistic_type
    , sp.last_updated
    , sp.rows                                                         AS rows_at_update
    , sp.rows_sampled
    , CAST(100.0 * sp.rows_sampled / NULLIF(sp.rows, 0)
           AS DECIMAL(5,2))                                           AS current_sample_percent
    , sp.steps                                                        AS current_histogram_steps
    , sp.modification_counter
    -- Detect regression: if rows_sampled < rows, it was NOT a fullscan.
    -- If the table is large and sample is very low, it's likely a regression from a prior fullscan.
    , CASE
        WHEN sp.rows_sampled < sp.rows
             AND sp.rows >= 1000000
             AND CAST(100.0 * sp.rows_sampled / NULLIF(sp.rows, 0)
                      AS DECIMAL(5,2)) < 20
        THEN 'LIKELY REGRESSION - Large table with very low sample (<20%)'
        WHEN sp.rows_sampled < sp.rows
             AND sp.steps < 100
             AND sp.rows >= 100000
        THEN 'POSSIBLE REGRESSION - Few histogram steps for table size'
        WHEN sp.rows_sampled < sp.rows
             AND sp.rows >= 10000000
        THEN 'REVIEW - 10M+ row table not using fullscan'
        ELSE 'OK'
      END                                                             AS regression_risk
FROM sys.stats s
INNER JOIN sys.objects o ON s.object_id = o.object_id
CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) sp
WHERE o.type = 'U'
  AND sp.rows >= @MinRowsInTable
  AND sp.rows_sampled < sp.rows                          -- Not a fullscan
  AND (
    -- Large table with very low sample
    (sp.rows >= 1000000
     AND CAST(100.0 * sp.rows_sampled / NULLIF(sp.rows, 0) AS DECIMAL(5,2)) < 20)
    OR
    -- Medium table with poor histogram quality
    (sp.rows >= 100000
     AND sp.steps < 100)
  )
ORDER BY sp.rows DESC, current_sample_percent ASC
OPTION (MAXDOP 1);
```

**What to Do:**

| Scenario | Action |
|----------|--------|
| `regression_risk = 'LIKELY REGRESSION'` | Run `UPDATE STATISTICS [schema].[table] [stats_name] WITH FULLSCAN;` during a maintenance window to restore histogram quality. On very large tables (100M+), use `WITH SAMPLE 50 PERCENT` as a faster alternative |
| `regression_risk = 'POSSIBLE REGRESSION'` | Check if query plan quality degraded after the last auto-update. If yes, run `UPDATE STATISTICS ... WITH FULLSCAN`. If plans are fine, the current sample may be adequate |
| Many large tables affected | Schedule a maintenance job to run `UPDATE STATISTICS ... WITH FULLSCAN` on these tables regularly. Consider Step 19 (PERSIST_SAMPLE_PERCENT) to prevent future regressions |
| Same table appears here and in Step 2 (stale) | Double problem — both stale and low-quality sample. Prioritize `FULLSCAN` update immediately |
| No results returned | Good — all statistics on large tables were updated with adequate sampling |

> **Prevention:** Use `PERSIST_SAMPLE_PERCENT = ON` (Step 19) when running `UPDATE STATISTICS ... WITH FULLSCAN` to prevent auto-update from reverting to a low sample rate.

---
