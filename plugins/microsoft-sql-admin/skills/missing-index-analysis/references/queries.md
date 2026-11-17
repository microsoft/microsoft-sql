# Missing Index Query Reference

### PlatformDetection

```sql
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

SELECT
      @EngineEdition AS engine_edition
    , CASE @EngineEdition
        WHEN 1 THEN 'Personal / Desktop'
        WHEN 2 THEN 'Standard'
        WHEN 3 THEN 'Enterprise'
        WHEN 4 THEN 'Express'
        WHEN 5 THEN 'Azure SQL Database'
        WHEN 6 THEN 'Azure Synapse Analytics - Dedicated SQL pool'
        WHEN 8 THEN 'Azure SQL Managed Instance'
        WHEN 9 THEN 'Azure SQL Edge'
        WHEN 11 THEN 'Azure Synapse serverless SQL pool / Fabric Warehouse'
        WHEN 12 THEN 'Fabric SQL Database'
        ELSE 'Unknown (' + CAST(@EngineEdition AS VARCHAR(10)) + ')'
      END AS edition_name
    , CASE
        WHEN @EngineEdition IN (6, 11) THEN 1
        ELSE 0
      END AS is_unsupported_dw
    , SERVERPROPERTY('ProductVersion') AS product_version;
```

### FindMissingIndexRecommendationsForCurrentDatabase
```sql
SELECT TOP 20
    CONVERT(decimal(18,2), migs.user_seeks * migs.avg_total_user_cost * (migs.avg_user_impact * 0.01)) AS [Index Advantage],
    migs.last_user_seek AS [Last User Seek],
    DB_NAME(mid.database_id) AS [Database],
    mid.[statement] AS [Table],
    mid.equality_columns AS [Equality Columns],
    mid.inequality_columns AS [Inequality Columns],
    mid.included_columns AS [Included Columns],
    migs.unique_compiles,
    migs.user_seeks,
    migs.avg_total_user_cost
FROM sys.dm_db_missing_index_group_stats AS migs
INNER JOIN sys.dm_db_missing_index_groups AS mig
    ON migs.group_handle = mig.index_group_handle
INNER JOIN sys.dm_db_missing_index_details AS mid
    ON mig.index_handle = mid.index_handle
WHERE mid.database_id = DB_ID()
ORDER BY [Index Advantage] DESC
OPTION (MAXDOP 1);
```

### FindMissingIndexRecommendationsForASingleTableOnTheCurrentDatabase
```sql
SELECT TOP 20
    CONVERT(decimal(18,2), migs.user_seeks * migs.avg_total_user_cost * (migs.avg_user_impact * 0.01)) AS [Index Advantage],
    migs.last_user_seek AS [Last User Seek],
    DB_NAME(mid.database_id) AS [Database],
    mid.[statement] AS [Table],
    mid.equality_columns AS [Equality Columns],
    mid.inequality_columns AS [Inequality Columns],
    mid.included_columns AS [Included Columns],
    migs.unique_compiles,
    migs.user_seeks
FROM sys.dm_db_missing_index_group_stats AS migs
INNER JOIN sys.dm_db_missing_index_groups AS mig
    ON migs.group_handle = mig.index_group_handle
INNER JOIN sys.dm_db_missing_index_details AS mid
    ON mig.index_handle = mid.index_handle
WHERE mid.database_id = DB_ID()
    AND mid.object_id = OBJECT_ID(QUOTENAME(N'{{SchemaName}}') + N'.' + QUOTENAME(N'{{TableName}}'))
ORDER BY [Index Advantage] DESC
OPTION (MAXDOP 1);
```

Limit to the top 10 by default.

---

### Advanced Missing Index Analysis with Query Correlation

Use this deeper analysis when the user wants to go beyond DMV recommendations and also see **which queries in the plan cache / Query Store are affected** by the missing index. It has three modes controlled by parameters.

#### Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| IndexAdvantage | 5000 | Minimum computed index advantage score — `(seeks + scans) × avg_cost × impact%`. Higher = more impactful index. Lower this for low-volume databases or shortly after a service restart |
| UserSeekCount | 100 | Minimum user seek count for the missing index to be included |
| SchemaName | *(required for query triage)* | Schema of the table to scope query cache lookups |
| TableName | *(required for query triage)* | Table name to scope query cache lookups |
| IsQueryRelatedTriage | 0 | Set to `1` to also find queries in plan cache / Query Store that reference the missing index. Requires `SchemaName` + `TableName` |
| AggregatedQuery | 1 | When `IsQueryRelatedTriage=1`: return queries aggregated by `query_hash` (no SQL text). Mutually exclusive with `DetailedQuery` |
| DetailedQuery | 0 | When `IsQueryRelatedTriage=1`: return full SQL text per query. Mutually exclusive with `AggregatedQuery` |
| QueryCountExecutions | 500 | Minimum execution count for a query to appear in the query triage results |
| QueryAvgCpuTime | 1000 | Minimum avg CPU time (µs) for a query to appear in the query triage results |
| StartTime | last 7 days | Lookback window for Query Store data. Defaults to 7 days back when not specified |

> **Performance note on `IsQueryRelatedTriage=1`:** Modes 2 and 3 use `sys.dm_db_missing_index_group_stats_query` (SQL Server 2019+ / Azure SQL DB / MI / Fabric) to directly link missing indexes to the queries that need them via Query Store. No plan cache scanning or XML parsing is needed. On SQL Server 2016–2017, these modes are not available — use Mode 1 instead.
>
> **Query Store requirement:** Modes 2 and 3 require Query Store to be enabled and in `READ_WRITE` state. If Query Store is off or read-only, use Mode 1 which works with DMV data only.

#### Mode 1 — Missing Index Triage Only (`IsQueryRelatedTriage = 0`)

Returns all missing indexes above the advantage threshold, deduplicated by index key so you don't see the same index suggested multiple times.

```sql
-- Parameters
DECLARE @IndexAdvantage BIGINT = {{IndexAdvantage}};
DECLARE @UserSeekCount  INT    = {{UserSeekCount}};

;WITH MissingIndexes AS (
    SELECT
        id.[statement]                                                                AS FullObjectName,
        gs.unique_compiles                                                            AS UniqueCompiles,
        gs.user_seeks                                                                 AS UserSeeks,
        gs.user_scans                                                                 AS UserScans,
        CONVERT(BIGINT, gs.avg_total_user_cost)                                       AS AvgTotalUserCost,
        gs.avg_user_impact                                                            AS AvgUserImpact,
        CONVERT(BIGINT, (gs.user_seeks + gs.user_scans) * gs.avg_total_user_cost)    AS BaseLineCost,
        CONVERT(BIGINT, (gs.user_seeks + gs.user_scans) * gs.avg_total_user_cost
            * (gs.avg_user_impact * 0.01))                                            AS IndexAdvantage,
        ISNULL(id.equality_columns,   '')                                             AS EqualityColumns,
        ISNULL(id.inequality_columns, '')                                             AS InEqualityColumns,
        ISNULL(id.included_columns,   '')                                             AS IncludedColumns,
        gs.last_user_seek                                                             AS LastUserSeekTime,
        gs.last_user_scan                                                             AS LastUserScanTime,
        OBJECT_NAME(id.object_id)                                                     AS TableName,
        REPLACE(REPLACE(REPLACE(ISNULL(id.equality_columns,   ''), ' ', '_'), '[', ''), ']', '')
            + '_'
            + REPLACE(REPLACE(REPLACE(ISNULL(id.inequality_columns, ''), ' ', '_'), '[', ''), ']', '')
            AS IndexKey
    FROM sys.dm_db_missing_index_group_stats  gs WITH (NOLOCK)
    INNER JOIN sys.dm_db_missing_index_groups ig WITH (NOLOCK) ON gs.group_handle  = ig.index_group_handle
    INNER JOIN sys.dm_db_missing_index_details id WITH (NOLOCK) ON ig.index_handle = id.index_handle
    WHERE id.database_id = DB_ID()
)
SELECT *
FROM (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY IndexKey ORDER BY IndexAdvantage DESC) AS rn
    FROM MissingIndexes
) AS Grouped
WHERE rn = 1
  AND IndexAdvantage >= @IndexAdvantage
ORDER BY IndexAdvantage DESC
OPTION (MAXDOP 1);
```

**Generating the CREATE INDEX statement:**

Use the returned columns to build the index DDL:

```sql
CREATE NONCLUSTERED INDEX [IX_<TableName>_<EqualityColumns>]
ON <FullObjectName> (<EqualityColumns>, <InEqualityColumns>)
INCLUDE (<IncludedColumns>)
WITH (ONLINE = ON);  -- Enterprise / Azure SQL DB only
```

#### Mode 2 — Query Triage: Aggregated by Query Hash (`IsQueryRelatedTriage = 1`, `AggregatedQuery = 1`)

Use when the user wants to know **which query patterns** are driving the missing index, without seeing individual SQL text. Returns metrics aggregated by `query_hash`.

Uses `sys.dm_db_missing_index_group_stats_query` to directly link missing index groups → query hashes → Query Store execution metrics. No plan cache scanning or XML parsing — fast and accurate.

> **Requires:** SQL Server 2019+ or Azure SQL DB / MI / Fabric. Query Store must be enabled.


**Version: By Query Hash** — Use this version when analyzing query patterns or when the user asks to identify queries by hash.

```sql
-- Parameters
DECLARE @StartTime            DATETIME     = DATEADD(DAY, -7, GETUTCDATE()); -- override: {{StartTime}}
DECLARE @IndexAdvantage       BIGINT       = {{IndexAdvantage}};
DECLARE @UserSeekCount        INT          = {{UserSeekCount}};
DECLARE @QueryCountExecutions INT          = {{QueryCountExecutions}};
DECLARE @QueryAvgCpuTime      BIGINT       = {{QueryAvgCpuTime}};
DECLARE @SchemaName           SYSNAME      = N'{{SchemaName}}';
DECLARE @TableName            SYSNAME      = N'{{TableName}}';

-- Guard: dm_db_missing_index_group_stats_query requires SQL Server 2019+ / Azure SQL
IF OBJECT_ID('sys.dm_db_missing_index_group_stats_query') IS NULL
BEGIN
    SELECT
        'Mode 2 requires SQL Server 2019+ or Azure SQL Database.' AS [Message],
        'sys.dm_db_missing_index_group_stats_query is not available on this instance.' AS [Detail],
        'Use Mode 1 (missing index triage only) which works on all SQL Server versions.' AS [Recommendation];
END
ELSE IF NOT EXISTS (
    SELECT 1 FROM sys.database_query_store_options WHERE actual_state_desc = 'READ_WRITE'
)
BEGIN
    SELECT
        'Query Store is not enabled or not in READ_WRITE state.' AS [Message],
        'Mode 2 requires Query Store to correlate missing indexes with query execution data.' AS [Detail],
        'Enable Query Store: ALTER DATABASE CURRENT SET QUERY_STORE = ON' AS [Recommendation]
        OPTION (MAXDOP 1);
END
ELSE
BEGIN
    DECLARE @sql NVARCHAR(MAX) = N'
    ;WITH TargetMissingIndexes AS (
        -- Step 1: Missing indexes for the target table above the advantage threshold
        SELECT
              mid.index_handle
            , mid.[statement]                                                AS table_name
            , mid.equality_columns
            , mid.inequality_columns
            , mid.included_columns
            , CONVERT(BIGINT, (migs.user_seeks + migs.user_scans)
                * migs.avg_total_user_cost
                * (migs.avg_user_impact * 0.01))                             AS index_advantage
            , migs.user_seeks                                                AS total_index_seeks
            , migs.avg_user_impact                                           AS estimated_improvement_pct
            , mig.index_group_handle
        FROM sys.dm_db_missing_index_details      AS mid
        JOIN sys.dm_db_missing_index_groups        AS mig  ON mid.index_handle       = mig.index_handle
        JOIN sys.dm_db_missing_index_group_stats   AS migs ON mig.index_group_handle = migs.group_handle
        WHERE mid.database_id = DB_ID()
          AND mid.object_id   = OBJECT_ID(QUOTENAME(@SchemaName) + N''.'' + QUOTENAME(@TableName))
          AND CONVERT(BIGINT, (migs.user_seeks + migs.user_scans)
              * migs.avg_total_user_cost * (migs.avg_user_impact * 0.01)) >= @IndexAdvantage
    ),
    QueryHashLinks AS (
        -- Step 2: Direct link — which query hashes need each missing index
        SELECT DISTINCT
              tmi.index_handle
            , migsq.query_hash
        FROM TargetMissingIndexes AS tmi
        JOIN sys.dm_db_missing_index_group_stats_query AS migsq
          ON tmi.index_group_handle = migsq.group_handle
        WHERE migsq.user_seeks >= @UserSeekCount
    ),
    QueryStoreAgg AS (
        -- Step 3: Pre-aggregate Query Store metrics per query_hash (weighted averages)
        SELECT
              qsq.query_hash
            , qsp.query_plan_hash
            , COUNT(DISTINCT qsq.query_id)                                   AS query_id_count
            , COUNT(DISTINCT qsp.plan_id)                                    AS plan_count
            , SUM(qsrs.count_executions)                                     AS total_executions
            , CAST(SUM(qsrs.count_executions * qsrs.avg_cpu_time)
                / NULLIF(SUM(qsrs.count_executions), 0) / 1000.0
                AS DECIMAL(18,1))                                            AS weighted_avg_cpu_ms
            , CAST(SUM(qsrs.count_executions * qsrs.avg_cpu_time) / 1000.0
                AS DECIMAL(18,1))                                            AS total_cpu_time_ms
            , CAST(SUM(qsrs.count_executions * qsrs.avg_logical_io_reads)
                / NULLIF(SUM(qsrs.count_executions), 0)
                AS BIGINT)                                                   AS weighted_avg_logical_reads
            , CAST(SUM(qsrs.count_executions * qsrs.avg_duration)
                / NULLIF(SUM(qsrs.count_executions), 0) / 1000.0
                AS DECIMAL(18,1))                                            AS weighted_avg_duration_ms
        FROM QueryHashLinks                          AS qhl
        JOIN sys.query_store_query                   AS qsq  ON qhl.query_hash = qsq.query_hash
        JOIN sys.query_store_plan                    AS qsp  ON qsq.query_id   = qsp.query_id
        JOIN sys.query_store_runtime_stats           AS qsrs ON qsp.plan_id    = qsrs.plan_id
        JOIN sys.query_store_runtime_stats_interval  AS qsri
          ON qsrs.runtime_stats_interval_id = qsri.runtime_stats_interval_id
        WHERE qsri.start_time >= @StartTime
          AND qsrs.execution_type = 0   -- regular executions only (exclude aborted/exception)
          AND qsq.is_internal_query = 0
        GROUP BY qsq.query_hash, qsp.query_plan_hash
        HAVING SUM(qsrs.count_executions) >= @QueryCountExecutions
           AND SUM(qsrs.count_executions * qsrs.avg_cpu_time)
               / NULLIF(SUM(qsrs.count_executions), 0) >= @QueryAvgCpuTime
    )
    -- Final output: missing indexes correlated with the queries that need them
    SELECT TOP (20)
          tmi.table_name
        , tmi.equality_columns
        , tmi.inequality_columns
        , tmi.included_columns
        , tmi.index_advantage
        , tmi.total_index_seeks
        , tmi.estimated_improvement_pct
        , qhl.query_hash
        , qsa.query_plan_hash
        , qsa.query_id_count
        , qsa.plan_count
        , qsa.total_executions
        , qsa.weighted_avg_cpu_ms
        , qsa.total_cpu_time_ms
        , qsa.weighted_avg_logical_reads
        , qsa.weighted_avg_duration_ms
    FROM TargetMissingIndexes   AS tmi
    JOIN QueryHashLinks         AS qhl ON tmi.index_handle = qhl.index_handle
    JOIN QueryStoreAgg          AS qsa ON qhl.query_hash   = qsa.query_hash
    ORDER BY tmi.index_advantage DESC, qsa.total_cpu_time_ms DESC
    OPTION (MAXDOP 1);
    '

    EXEC sp_executesql @sql,
        N'@IndexAdvantage BIGINT, @UserSeekCount INT, @QueryCountExecutions INT,
          @QueryAvgCpuTime BIGINT, @SchemaName SYSNAME, @TableName SYSNAME, @StartTime DATETIME',
        @IndexAdvantage, @UserSeekCount, @QueryCountExecutions,
        @QueryAvgCpuTime, @SchemaName, @TableName, @StartTime;
END
```

**Version: By Query ID and Plan ID** — Use this version when the user wants to investigate specific queries or plans in Query Store, or wants to drill down into individual plan performance.

```sql
-- Parameters
DECLARE @StartTime            DATETIME     = DATEADD(DAY, -7, GETUTCDATE()); -- override: {{StartTime}}
DECLARE @IndexAdvantage       BIGINT       = {{IndexAdvantage}};
DECLARE @UserSeekCount        INT          = {{UserSeekCount}};
DECLARE @QueryCountExecutions INT          = {{QueryCountExecutions}};
DECLARE @QueryAvgCpuTime      BIGINT       = {{QueryAvgCpuTime}};
DECLARE @SchemaName           SYSNAME      = N'{{SchemaName}}';
DECLARE @TableName            SYSNAME      = N'{{TableName}}';

-- Guard: dm_db_missing_index_group_stats_query requires SQL Server 2019+ / Azure SQL
IF OBJECT_ID('sys.dm_db_missing_index_group_stats_query') IS NULL
BEGIN
    SELECT
        'Mode 2 requires SQL Server 2019+ or Azure SQL Database.' AS [Message],
        'sys.dm_db_missing_index_group_stats_query is not available on this instance.' AS [Detail],
        'Use Mode 1 (missing index triage only) which works on all SQL Server versions.' AS [Recommendation];
END
ELSE IF NOT EXISTS (
    SELECT 1 FROM sys.database_query_store_options WHERE actual_state_desc = 'READ_WRITE'
)
BEGIN
    SELECT
        'Query Store is not enabled or not in READ_WRITE state.' AS [Message],
        'Mode 2 requires Query Store to correlate missing indexes with query execution data.' AS [Detail],
        'Enable Query Store: ALTER DATABASE CURRENT SET QUERY_STORE = ON' AS [Recommendation]
        OPTION (MAXDOP 1);
END
ELSE
BEGIN
    DECLARE @sql NVARCHAR(MAX) = N'
    ;WITH TargetMissingIndexes AS (
        -- Step 1: Missing indexes for the target table above the advantage threshold
        SELECT
              mid.index_handle
            , mid.[statement]                                                AS table_name
            , mid.equality_columns
            , mid.inequality_columns
            , mid.included_columns
            , CONVERT(BIGINT, (migs.user_seeks + migs.user_scans)
                * migs.avg_total_user_cost
                * (migs.avg_user_impact * 0.01))                             AS index_advantage
            , migs.user_seeks                                                AS total_index_seeks
            , migs.avg_user_impact                                           AS estimated_improvement_pct
            , mig.index_group_handle
        FROM sys.dm_db_missing_index_details      AS mid
        JOIN sys.dm_db_missing_index_groups        AS mig  ON mid.index_handle       = mig.index_handle
        JOIN sys.dm_db_missing_index_group_stats   AS migs ON mig.index_group_handle = migs.group_handle
        WHERE mid.database_id = DB_ID()
          AND mid.object_id   = OBJECT_ID(QUOTENAME(@SchemaName) + N''.'' + QUOTENAME(@TableName))
          AND CONVERT(BIGINT, (migs.user_seeks + migs.user_scans)
              * migs.avg_total_user_cost * (migs.avg_user_impact * 0.01)) >= @IndexAdvantage
    ),
    QueryHashLinks AS (
        -- Step 2: Direct link — which query hashes need each missing index
        SELECT DISTINCT
              tmi.index_handle
            , migsq.query_hash
        FROM TargetMissingIndexes AS tmi
        JOIN sys.dm_db_missing_index_group_stats_query AS migsq
          ON tmi.index_group_handle = migsq.group_handle
        WHERE migsq.user_seeks >= @UserSeekCount
    ),
    QueryStoreAgg AS (
        -- Step 3: Pre-aggregate Query Store metrics per query_hash (weighted averages)
        SELECT
              qsq.query_hash
            , qsq.query_id
            , qsp.plan_id
            , SUM(qsrs.count_executions)                                     AS total_executions
            , CAST(SUM(qsrs.count_executions * qsrs.avg_cpu_time)
                / NULLIF(SUM(qsrs.count_executions), 0) / 1000.0
                AS DECIMAL(18,1))                                            AS weighted_avg_cpu_ms
            , CAST(SUM(qsrs.count_executions * qsrs.avg_cpu_time) / 1000.0
                AS DECIMAL(18,1))                                            AS total_cpu_time_ms
            , CAST(SUM(qsrs.count_executions * qsrs.avg_logical_io_reads)
                / NULLIF(SUM(qsrs.count_executions), 0)
                AS BIGINT)                                                   AS weighted_avg_logical_reads
            , CAST(SUM(qsrs.count_executions * qsrs.avg_duration)
                / NULLIF(SUM(qsrs.count_executions), 0) / 1000.0
                AS DECIMAL(18,1))                                            AS weighted_avg_duration_ms
        FROM QueryHashLinks                          AS qhl
        JOIN sys.query_store_query                   AS qsq  ON qhl.query_hash = qsq.query_hash
        JOIN sys.query_store_plan                    AS qsp  ON qsq.query_id   = qsp.query_id
        JOIN sys.query_store_runtime_stats           AS qsrs ON qsp.plan_id    = qsrs.plan_id
        JOIN sys.query_store_runtime_stats_interval  AS qsri
          ON qsrs.runtime_stats_interval_id = qsri.runtime_stats_interval_id
        WHERE qsri.start_time >= @StartTime
          AND qsrs.execution_type = 0   -- regular executions only (exclude aborted/exception)
          AND qsq.is_internal_query = 0
        GROUP BY qsq.query_hash, qsq.query_id, qsp.plan_id
        HAVING SUM(qsrs.count_executions) >= @QueryCountExecutions
           AND SUM(qsrs.count_executions * qsrs.avg_cpu_time)
               / NULLIF(SUM(qsrs.count_executions), 0) >= @QueryAvgCpuTime
    )
    -- Final output: missing indexes correlated with the queries that need them
    SELECT TOP (20)
          tmi.table_name
        , tmi.equality_columns
        , tmi.inequality_columns
        , tmi.included_columns
        , tmi.index_advantage
        , tmi.total_index_seeks
        , tmi.estimated_improvement_pct
        , qsa.query_id
        , qsa.plan_id
        , qsa.total_executions
        , qsa.weighted_avg_cpu_ms
        , qsa.total_cpu_time_ms
        , qsa.weighted_avg_logical_reads
        , qsa.weighted_avg_duration_ms
    FROM TargetMissingIndexes   AS tmi
    JOIN QueryHashLinks         AS qhl ON tmi.index_handle = qhl.index_handle
    JOIN QueryStoreAgg          AS qsa ON qhl.query_hash   = qsa.query_hash
    ORDER BY tmi.index_advantage DESC, qsa.total_cpu_time_ms DESC
    OPTION (MAXDOP 1);
    '

    EXEC sp_executesql @sql,
        N'@IndexAdvantage BIGINT, @UserSeekCount INT, @QueryCountExecutions INT,
          @QueryAvgCpuTime BIGINT, @SchemaName SYSNAME, @TableName SYSNAME, @StartTime DATETIME',
        @IndexAdvantage, @UserSeekCount, @QueryCountExecutions,
        @QueryAvgCpuTime, @SchemaName, @TableName, @StartTime;
END
```



#### Mode 3 — Query Triage: Detailed with SQL Text (`IsQueryRelatedTriage = 1`, `DetailedQuery = 1`)

Use when the user needs to see the **actual SQL text** of the queries driving the missing index. Returns one row per unique query with full text, execution metrics, and the missing index columns.

Uses `sys.dm_db_missing_index_group_stats_query` to directly link missing indexes → queries, then resolves SQL text via `last_statement_sql_handle` for precise query identification.

> **Requires:** SQL Server 2019+ or Azure SQL DB / MI / Fabric. Query Store must be enabled.

```sql
-- Parameters
DECLARE @StartTime            DATETIME     = DATEADD(DAY, -7, GETUTCDATE()); -- override: {{StartTime}}
DECLARE @IndexAdvantage       BIGINT       = {{IndexAdvantage}};
DECLARE @UserSeekCount        INT          = {{UserSeekCount}};
DECLARE @QueryCountExecutions INT          = {{QueryCountExecutions}};
DECLARE @QueryAvgCpuTime      BIGINT       = {{QueryAvgCpuTime}};
DECLARE @SchemaName           SYSNAME      = N'{{SchemaName}}';
DECLARE @TableName            SYSNAME      = N'{{TableName}}';

-- Guard: dm_db_missing_index_group_stats_query requires SQL Server 2019+ / Azure SQL
IF OBJECT_ID('sys.dm_db_missing_index_group_stats_query') IS NULL
BEGIN
    SELECT
        'Mode 3 requires SQL Server 2019+ or Azure SQL Database.' AS [Message],
        'sys.dm_db_missing_index_group_stats_query is not available on this instance.' AS [Detail],
        'Use Mode 1 (missing index triage only) which works on all SQL Server versions.' AS [Recommendation];
END
ELSE IF NOT EXISTS (
    SELECT 1 FROM sys.database_query_store_options WHERE actual_state_desc = 'READ_WRITE'
)
BEGIN
    SELECT
        'Query Store is not enabled or not in READ_WRITE state.' AS [Message],
        'Mode 3 requires Query Store to correlate missing indexes with query text.' AS [Detail],
        'Enable Query Store: ALTER DATABASE CURRENT SET QUERY_STORE = ON' AS [Recommendation]
        OPTION (MAXDOP 1);
END
ELSE
BEGIN
    DECLARE @sql NVARCHAR(MAX) = N'
    ;WITH TargetMissingIndexes AS (
        -- Step 1: Missing indexes for the target table above the advantage threshold
        SELECT
              mid.index_handle
            , mid.[statement]                                                AS table_name
            , mid.equality_columns
            , mid.inequality_columns
            , mid.included_columns
            , CONVERT(BIGINT, (migs.user_seeks + migs.user_scans)
                * migs.avg_total_user_cost
                * (migs.avg_user_impact * 0.01))                             AS index_advantage
            , migs.user_seeks                                                AS total_index_seeks
            , migs.avg_user_impact                                           AS estimated_improvement_pct
            , mig.index_group_handle
        FROM sys.dm_db_missing_index_details      AS mid
        JOIN sys.dm_db_missing_index_groups        AS mig  ON mid.index_handle       = mig.index_handle
        JOIN sys.dm_db_missing_index_group_stats   AS migs ON mig.index_group_handle = migs.group_handle
        WHERE mid.database_id = DB_ID()
          AND mid.object_id   = OBJECT_ID(QUOTENAME(@SchemaName) + N''.'' + QUOTENAME(@TableName))
          AND CONVERT(BIGINT, (migs.user_seeks + migs.user_scans)
              * migs.avg_total_user_cost * (migs.avg_user_impact * 0.01)) >= @IndexAdvantage
    ),
    QueryLinks AS (
        -- Step 2: Direct link — which queries need each missing index
        -- Uses last_statement_sql_handle for precise query identification
        SELECT
              tmi.index_handle
            , migsq.query_hash
            , migsq.last_statement_sql_handle
        FROM TargetMissingIndexes AS tmi
        JOIN sys.dm_db_missing_index_group_stats_query AS migsq
          ON tmi.index_group_handle = migsq.group_handle
        WHERE migsq.user_seeks >= @UserSeekCount
    ),
    QueryStoreDetail AS (
        -- Step 3: Query Store execution metrics per query_id
        SELECT
              qsq.query_id
            , qsq.query_hash
            , qsq.query_text_id
            , COUNT(DISTINCT qsp.plan_id)                                    AS plan_count
            , SUM(qsrs.count_executions)                                     AS total_executions
            , CAST(SUM(qsrs.count_executions * qsrs.avg_cpu_time)
                / NULLIF(SUM(qsrs.count_executions), 0) / 1000.0
                AS DECIMAL(18,1))                                            AS weighted_avg_cpu_ms
            , CAST(SUM(qsrs.count_executions * qsrs.avg_cpu_time) / 1000.0
                AS DECIMAL(18,1))                                            AS total_cpu_time_ms
            , CAST(SUM(qsrs.count_executions * qsrs.avg_logical_io_reads)
                / NULLIF(SUM(qsrs.count_executions), 0)
                AS BIGINT)                                                   AS weighted_avg_logical_reads
            , CAST(SUM(qsrs.count_executions * qsrs.avg_duration)
                / NULLIF(SUM(qsrs.count_executions), 0) / 1000.0
                AS DECIMAL(18,1))                                            AS weighted_avg_duration_ms
        FROM QueryLinks                              AS ql
        JOIN sys.query_store_query                   AS qsq  ON ql.query_hash = qsq.query_hash
        JOIN sys.query_store_plan                    AS qsp  ON qsq.query_id   = qsp.query_id
        JOIN sys.query_store_runtime_stats           AS qsrs ON qsp.plan_id    = qsrs.plan_id
        JOIN sys.query_store_runtime_stats_interval  AS qsri
          ON qsrs.runtime_stats_interval_id = qsri.runtime_stats_interval_id
        WHERE qsri.start_time >= @StartTime
          AND qsrs.execution_type = 0   -- regular executions only
          AND qsq.is_internal_query = 0
        GROUP BY qsq.query_id, qsq.query_hash, qsq.query_text_id
        HAVING SUM(qsrs.count_executions) >= @QueryCountExecutions
           AND SUM(qsrs.count_executions * qsrs.avg_cpu_time)
               / NULLIF(SUM(qsrs.count_executions), 0) >= @QueryAvgCpuTime
    )
    -- Final output: missing indexes + execution metrics + query text (joined separately)
    SELECT TOP (20)
          tmi.table_name
        , tmi.equality_columns
        , tmi.inequality_columns
        , tmi.included_columns
        , tmi.index_advantage
        , tmi.total_index_seeks
        , tmi.estimated_improvement_pct
        , qsd.query_id
        , qsd.query_hash
        , qsqt.query_sql_text
        , qsd.plan_count
        , qsd.total_executions
        , qsd.weighted_avg_cpu_ms
        , qsd.total_cpu_time_ms
        , qsd.weighted_avg_logical_reads
        , qsd.weighted_avg_duration_ms
    FROM TargetMissingIndexes   AS tmi
    JOIN QueryLinks             AS ql   ON tmi.index_handle    = ql.index_handle
    JOIN QueryStoreDetail       AS qsd  ON ql.query_hash       = qsd.query_hash
    JOIN sys.query_store_query_text AS qsqt ON qsd.query_text_id = qsqt.query_text_id
    ORDER BY tmi.index_advantage DESC, qsd.total_cpu_time_ms DESC
    OPTION (MAXDOP 1);
    '

    EXEC sp_executesql @sql,
        N'@IndexAdvantage BIGINT, @UserSeekCount INT, @QueryCountExecutions INT,
          @QueryAvgCpuTime BIGINT, @SchemaName SYSNAME, @TableName SYSNAME, @StartTime DATETIME',
        @IndexAdvantage, @UserSeekCount, @QueryCountExecutions,
        @QueryAvgCpuTime, @SchemaName, @TableName, @StartTime;
END
```



### Missing Indexes from Query Store Plans

> Run with the SQL query tool. Extracts missing index recommendations directly from cached Query Store execution plans by parsing the XML showplan. This captures missing indexes that the optimizer embedded in actual plans — even for queries that have already been evicted from the DMV-based missing index stats. Filters by lookback window, minimum execution count, and minimum impact to avoid scanning the entire plan cache.

```sql
-- Parameters: adjust these to control scope and performance
DECLARE @LookbackHours     INT   = {{QDSLookbackHours}};      -- How far back to look (default: 3 hours)
DECLARE @MinExecutionCount INT   = {{QDSMinExecutionCount}};   -- Min executions to include (default: 2)
DECLARE @MinImpact         FLOAT = {{QDSMinImpact}};           -- Min optimizer impact 0-100 (default: 50)
DECLARE @StartTime         DATETIME = DATEADD(HOUR, -@LookbackHours, GETUTCDATE());

;WITH XMLNAMESPACES
    (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan'),
filtered_plans AS
(
    -- Pre-filter: only plans for queries executed recently and frequently enough
    SELECT 
        qsp.plan_id,
        TRY_CONVERT(XML, qsp.query_plan) AS query_plan
    FROM sys.query_store_plan qsp
    INNER JOIN sys.query_store_query qsq
        ON qsp.query_id = qsq.query_id
    INNER JOIN sys.query_store_runtime_stats qrs
        ON qsp.plan_id = qrs.plan_id
    INNER JOIN sys.query_store_runtime_stats_interval qrsi
        ON qrs.runtime_stats_interval_id = qrsi.runtime_stats_interval_id
    WHERE qrsi.start_time >= @StartTime
    GROUP BY qsp.plan_id, qsp.query_plan
    HAVING SUM(qrs.count_executions) >= @MinExecutionCount
),
plans_with_missing AS
(
    SELECT query_plan
    FROM filtered_plans
    WHERE query_plan IS NOT NULL
      AND query_plan.exist('//MissingIndex') = 1
)
SELECT
    p.query_plan,
    n.value('(@StatementText)[1]', 'VARCHAR(4000)') AS sql_text,
    n.value('(//MissingIndexGroup/@Impact)[1]', 'FLOAT') AS impact,
    DB_ID(REPLACE(REPLACE(n.value('(//MissingIndex/@Database)[1]', 'VARCHAR(128)'),'[',''),']','')) AS database_id,
    OBJECT_ID(n.value('(//MissingIndex/@Database)[1]', 'VARCHAR(128)') + '.' +
        n.value('(//MissingIndex/@Schema)[1]', 'VARCHAR(128)') + '.' +
        n.value('(//MissingIndex/@Table)[1]', 'VARCHAR(128)')) AS [object_id],
    n.value('(//MissingIndex/@Database)[1]', 'VARCHAR(128)') + '.' +
        n.value('(//MissingIndex/@Schema)[1]', 'VARCHAR(128)') + '.' +
        n.value('(//MissingIndex/@Table)[1]', 'VARCHAR(128)')
        AS [object],
    (   SELECT DISTINCT c.value('(@Name)[1]', 'VARCHAR(128)') + ', '
        FROM n.nodes('//ColumnGroup') AS t(cg)
        CROSS APPLY cg.nodes('Column') AS r(c)
        WHERE cg.value('(@Usage)[1]', 'VARCHAR(128)') = 'EQUALITY'
        FOR XML PATH('')
    ) AS equality_columns,
    (   SELECT DISTINCT c.value('(@Name)[1]', 'VARCHAR(128)') + ', '
        FROM n.nodes('//ColumnGroup') AS t(cg)
        CROSS APPLY cg.nodes('Column') AS r(c)
        WHERE cg.value('(@Usage)[1]', 'VARCHAR(128)') = 'INEQUALITY'
        FOR XML PATH('')
    ) AS inequality_columns,
    (   SELECT DISTINCT c.value('(@Name)[1]', 'VARCHAR(128)') + ', '
        FROM n.nodes('//ColumnGroup') AS t(cg)
        CROSS APPLY cg.nodes('Column') AS r(c)
        WHERE cg.value('(@Usage)[1]', 'VARCHAR(128)') = 'INCLUDE'
        FOR XML PATH('')
    ) AS include_columns
FROM plans_with_missing p
CROSS APPLY p.query_plan.nodes('//StmtSimple') AS q(n)
WHERE n.exist('QueryPlan/MissingIndexes') = 1
  AND n.value('(//MissingIndexGroup/@Impact)[1]', 'FLOAT') >= @MinImpact
ORDER BY impact DESC
OPTION (MAXDOP 1);
```



### Finding Unused Indexes

If the user asks about **unused** indexes, use this query:

```sql
SELECT TOP 10 OBJECT_NAME(i.object_id) AS TableName, i.name AS IndexName
FROM sys.indexes AS i
LEFT JOIN sys.dm_db_index_usage_stats AS s
    ON i.object_id = s.object_id AND i.index_id = s.index_id AND s.database_id = DB_ID()
WHERE i.is_primary_key = 0
    AND i.is_unique = 0
    AND s.object_id IS NULL
    AND i.object_id > 100
ORDER BY OBJECT_NAME(i.object_id), i.name
OPTION (MAXDOP 1);
```

Limit to the top 10 by default.


