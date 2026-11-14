## Step 1: Detect Platform and Confirm Data IO Pressure

```sql
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

SELECT
      CAST(SERVERPROPERTY('Edition') AS NVARCHAR(128))           AS sql_edition
    , CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(128))    AS sql_version
    , CASE @EngineEdition
        WHEN 5  THEN 'Azure SQL Database'
        WHEN 8  THEN 'Azure SQL Managed Instance'
        WHEN 12 THEN 'Fabric SQL Database'
        WHEN 6  THEN 'Azure Synapse Analytics - Dedicated SQL pool (not supported by this skill)'
        WHEN 11 THEN 'Azure Synapse serverless SQL pool / Fabric Warehouse (not supported by this skill)'
        ELSE         'SQL Server (on-prem / IaaS)'
      END                                                        AS engine_type
    , @EngineEdition                                             AS engine_edition
    , CASE WHEN @EngineEdition IN (6, 11) THEN 1 ELSE 0 END     AS is_unsupported_dw;

IF @EngineEdition IN (6, 11)
BEGIN
    SELECT 'This skill is not designed for Azure Synapse Analytics or Fabric Warehouse/Lakehouse endpoints (EngineEdition 6 or 11). Data IO metrics and DMVs differ significantly in these environments. Note: Fabric SQL Database (EngineEdition 12) is supported.' AS unsupported_message;
    RETURN;
END

IF @EngineEdition IN (5, 12)
BEGIN
    -- Azure SQL DB / Fabric: dm_db_resource_stats (~15s intervals, ~1h history)
    ;WITH CteDataIO AS (
        SELECT
              MIN(end_time)                AS window_start_utc
            , MAX(end_time)                AS window_end_utc
            , AVG(avg_data_io_percent)     AS avg_data_io_percent
            , MAX(avg_data_io_percent)     AS max_data_io_percent
            , COUNT(*)                     AS sample_count
            , CASE
                WHEN AVG(avg_data_io_percent) >= {{DataIoThreshold}}
                    THEN 'Data IO pressure confirmed'
                WHEN MAX(avg_data_io_percent) >= {{DataIoThreshold}}
                    THEN 'Intermittent data IO spikes detected'
                ELSE 'No sustained data IO pressure in last ' + CAST({{ConfirmLookbackMinutes}} AS VARCHAR(10)) + 'm'
              END                          AS data_io_assessment
        FROM sys.dm_db_resource_stats
        WHERE end_time >= DATEADD(MINUTE, -{{ConfirmLookbackMinutes}}, SYSUTCDATETIME())
    )
    SELECT * FROM CteDataIO
    OPTION (MAXDOP 1);
END
ELSE IF @EngineEdition = 8
BEGIN
    -- Azure SQL Managed Instance: dm_db_resource_stats (available on MI since recent versions)
    -- Falls back to wait-based if the DMV is unavailable on older MI builds
    IF OBJECT_ID('sys.dm_db_resource_stats') IS NOT NULL
    BEGIN
        ;WITH CteDataIO AS (
            SELECT
                  MIN(end_time)                AS window_start_utc
                , MAX(end_time)                AS window_end_utc
                , AVG(avg_data_io_percent)     AS avg_data_io_percent
                , MAX(avg_data_io_percent)     AS max_data_io_percent
                , COUNT(*)                     AS sample_count
                , CASE
                    WHEN AVG(avg_data_io_percent) >= {{DataIoThreshold}}
                        THEN 'Data IO pressure confirmed'
                    WHEN MAX(avg_data_io_percent) >= {{DataIoThreshold}}
                        THEN 'Intermittent data IO spikes detected'
                    ELSE 'No sustained data IO pressure in last ' + CAST({{ConfirmLookbackMinutes}} AS VARCHAR(10)) + 'm'
                  END                          AS data_io_assessment
            FROM sys.dm_db_resource_stats
            WHERE end_time >= DATEADD(MINUTE, -{{ConfirmLookbackMinutes}}, SYSUTCDATETIME())
        )
        SELECT * FROM CteDataIO
        OPTION (MAXDOP 1);
    END
    ELSE
    BEGIN
        SELECT 'Azure SQL MI: dm_db_resource_stats not available on this build. Proceeding with wait-based analysis in subsequent steps.' AS mi_note;
    END
END
ELSE
BEGIN
    -- SQL Server on-premises: cumulative wait stats + pending IO as proxy
    ;WITH IoWaits AS (
        SELECT
              SUM(CASE WHEN wait_type LIKE 'PAGEIOLATCH_%'
                       THEN wait_time_ms ELSE 0 END)           AS data_io_wait_ms
            , SUM(CASE WHEN wait_type LIKE 'PAGEIOLATCH_%'
                       THEN waiting_tasks_count ELSE 0 END)    AS data_io_wait_count
            , SUM(wait_time_ms)                                 AS total_wait_ms
        FROM sys.dm_os_wait_stats
        WHERE wait_type NOT IN (
            'WAITFOR','LAZYWRITER_SLEEP','SQLTRACE_BUFFER_FLUSH',
            'REQUEST_FOR_DEADLOCK_SEARCH','XE_TIMER_EVENT','BROKER_TO_FLUSH',
            'BROKER_TASK_STOP','CLR_MANUAL_EVENT','CLR_AUTO_EVENT',
            'DISPATCHER_QUEUE_SEMAPHORE','FT_IFTS_SCHEDULER_IDLE_WAIT',
            'XE_DISPATCHER_WAIT','XE_DISPATCHER_JOIN','SLEEP_TASK',
            'SLEEP_SYSTEMTASK','SQLTRACE_INCREMENTAL_FLUSH_SLEEP',
            'SP_SERVER_DIAGNOSTICS_SLEEP','HADR_FILESTREAM_IOMGR_IOCOMPLETION',
            'DIRTY_PAGE_POLL','BROKER_EVENTHANDLER',
            'CHECKPOINT_QUEUE','LOGMGR_QUEUE')
    )
    SELECT
          GETUTCDATE()                                          AS check_time_utc
        , CAST(iw.data_io_wait_ms * 100.0
            / NULLIF(iw.total_wait_ms, 0) AS DECIMAL(5,2))     AS data_io_wait_pct
        , iw.data_io_wait_ms
        , iw.data_io_wait_count
        , pending.pending_io_count
        , CASE
            WHEN iw.data_io_wait_ms * 100.0
                 / NULLIF(iw.total_wait_ms, 0) >= {{DataIoThreshold}}
                THEN 'Data IO dominant in cumulative waits since restart'
            WHEN pending.pending_io_count > 50
                THEN 'Active IO pressure (' + CAST(pending.pending_io_count AS VARCHAR(10)) + ' pending IOs — includes all file types)'
            ELSE 'PAGEIOLATCH waits not dominant in cumulative wait stats'
          END                                                   AS data_io_assessment
    FROM IoWaits iw
    CROSS JOIN (
        SELECT COUNT(*) AS pending_io_count
        FROM sys.dm_io_pending_io_requests
    ) pending
    OPTION (MAXDOP 1);
END
```

## Step 2: Real-Time Data IO Consumers — Active Requests with SQL Text and Plans

```sql
SELECT TOP ({{TopN}})
      req.session_id
    , req.status
    , req.start_time
    , req.cpu_time                                          AS cpu_time_ms
    , req.total_elapsed_time                                AS elapsed_time_ms
    , req.logical_reads
    , req.reads                                             AS physical_reads
    , req.writes                                            AS physical_writes
    , CAST(
        req.reads * 1.0
        / NULLIF(DATEDIFF(SECOND, req.start_time, GETDATE()), 0)
      AS DECIMAL(18,2))                                     AS physical_reads_per_sec
    , req.wait_type
    , req.wait_time                                         AS wait_time_ms
    , req.wait_resource
    , OBJECT_NAME(st.objectid, st.dbid)                     AS object_name
    , req.query_hash
    , req.query_plan_hash
    , req.plan_handle     -- use dm_exec_query_plan(plan_handle) on individual top offenders
FROM sys.dm_exec_requests  AS req
JOIN sys.dm_exec_sessions  AS s
  ON req.session_id = s.session_id
CROSS APPLY sys.dm_exec_sql_text(req.sql_handle)             AS st
WHERE req.session_id <> @@SPID
  AND req.group_id   >  1
  AND (
        req.wait_type IN ('PAGEIOLATCH_SH', 'PAGEIOLATCH_EX', 'PAGEIOLATCH_UP',
                          'IO_COMPLETION', 'ASYNC_IO_COMPLETION')
     OR (req.wait_type IS NULL AND req.reads > 100)
  )
ORDER BY req.reads DESC, req.wait_time DESC
OPTION (MAXDOP 1);
```

## Step 3: Historical Data IO Consumers — Plan Cache (Cumulative)

```sql
SELECT TOP ({{TopN}})
      qs.execution_count
    , qs.total_physical_reads
    , qs.total_physical_reads / NULLIF(qs.execution_count, 0)   AS physical_reads_per_exec
    , qs.total_logical_reads
    , qs.total_logical_reads  / NULLIF(qs.execution_count, 0)   AS logical_reads_per_exec
    , qs.total_logical_writes
    , qs.total_worker_time / 1000                               AS total_cpu_ms
    , qs.total_elapsed_time / 1000                              AS total_elapsed_ms
    , qs.max_physical_reads
    , qs.last_physical_reads
    , qs.last_execution_time
    , DB_NAME(st.dbid)                                          AS database_name
    , OBJECT_NAME(st.objectid, st.dbid)                         AS object_name
    , qs.query_hash
    , qs.query_plan_hash
    , qs.plan_handle     -- use dm_exec_query_plan(plan_handle) on individual top offenders
FROM sys.dm_exec_query_stats      AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle)    AS st
WHERE qs.execution_count    >= {{MinExecutionCount}}
  AND qs.total_physical_reads >= {{MinTotalPhysicalReads}}
  AND qs.last_execution_time >= DATEADD(HOUR, -{{HistoryLookbackHours}}, GETDATE())
  AND st.dbid = DB_ID()
ORDER BY qs.total_physical_reads DESC
OPTION (MAXDOP 1);
```

## Step 4: Data File Latency

```sql
SELECT
      DB_NAME()                                                 AS database_name
    , df.name                                                   AS file_name
    , df.type_desc                                              AS file_type
    , vfs.num_of_reads
    , vfs.num_of_writes
    , CAST(vfs.num_of_bytes_read    / 1048576.0 AS DECIMAL(18,2)) AS total_mb_read
    , CAST(vfs.num_of_bytes_written / 1048576.0 AS DECIMAL(18,2)) AS total_mb_written
    , CASE WHEN vfs.num_of_reads > 0
        THEN CAST(vfs.io_stall_read_ms * 1.0
             / vfs.num_of_reads AS DECIMAL(10,2))
        ELSE 0 END                                              AS avg_read_latency_ms
    , CASE WHEN vfs.num_of_writes > 0
        THEN CAST(vfs.io_stall_write_ms * 1.0
             / vfs.num_of_writes AS DECIMAL(10,2))
        ELSE 0 END                                              AS avg_write_latency_ms
    , CASE WHEN (vfs.num_of_reads + vfs.num_of_writes) > 0
        THEN CAST(vfs.io_stall * 1.0
             / (vfs.num_of_reads + vfs.num_of_writes) AS DECIMAL(10,2))
        ELSE 0 END                                              AS avg_total_latency_ms
    , vfs.io_stall_read_ms
    , vfs.io_stall_write_ms
    , vfs.io_stall                                              AS total_io_stall_ms
FROM sys.dm_io_virtual_file_stats(DB_ID(), NULL) AS vfs
JOIN sys.database_files AS df
  ON vfs.file_id = df.file_id
WHERE df.type = 0   -- ROWS files only (data IO)
ORDER BY vfs.io_stall_read_ms DESC
OPTION (MAXDOP 1);
```

## Step 5: Buffer Pool Health

### Step 5a: Page Life Expectancy (NUMA-Aware)

```sql
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

IF @EngineEdition NOT IN (5, 12)
BEGIN
    -- SQL Server / MI: NUMA-aware PLE
    SELECT
          RTRIM(instance_name)       AS numa_node
        , cntr_value                 AS page_life_expectancy_sec
        , CASE
            WHEN cntr_value < 300  THEN 'Critical — severe buffer pool pressure on this NUMA node'
            WHEN cntr_value < 1000 THEN 'Warning — moderate buffer pool pressure on this NUMA node'
            ELSE 'Healthy'
          END                        AS assessment
    FROM sys.dm_os_performance_counters
    WHERE counter_name = 'Page life expectancy'
      AND object_name LIKE '%:Buffer Node%'
    ORDER BY RTRIM(instance_name)
    OPTION (MAXDOP 1);
END
ELSE
BEGIN
    -- Azure SQL DB / Fabric: aggregate PLE (informational)
    SELECT
          'Aggregate' AS numa_node
        , cntr_value  AS page_life_expectancy_sec
        , 'Informational on Azure SQL — platform manages memory automatically' AS assessment
    FROM sys.dm_os_performance_counters
    WHERE counter_name = 'Page life expectancy'
      AND object_name LIKE '%:Buffer Manager%'
      OPTION (MAXDOP 1);
END
```

### Step 5b: Buffer Cache Hit Ratio and Write Activity

```sql
SELECT
      GETUTCDATE() AS check_time_utc

    , 100.0 *
      MAX(CASE
            WHEN counter_name = 'Buffer cache hit ratio'
            THEN cntr_value
          END)
      /
      NULLIF(
        MAX(CASE
              WHEN counter_name = 'Buffer cache hit ratio base'
              THEN cntr_value
            END),
        0
      ) AS buffer_cache_hit_ratio_pct

    , MAX(CASE
            WHEN counter_name = 'Page reads/sec'
            THEN cntr_value
          END) AS page_reads_per_sec_cumulative

    , MAX(CASE
            WHEN counter_name = 'Page writes/sec'
            THEN cntr_value
          END) AS page_writes_per_sec_cumulative

    , MAX(CASE
            WHEN counter_name = 'Checkpoint pages/sec'
            THEN cntr_value
          END) AS checkpoint_pages_per_sec_cumulative

    , MAX(CASE
            WHEN counter_name = 'Lazy writes/sec'
            THEN cntr_value
          END) AS lazy_writes_per_sec_cumulative
FROM sys.dm_os_performance_counters
WHERE object_name LIKE '%:Buffer Manager%'
OPTION (MAXDOP 1);
```

## Step 6: Data IO Anti-Pattern Detection — Scan-Heavy Queries

```sql
;WITH TopIORequests AS (
    SELECT TOP (5)
          req.session_id
        , req.logical_reads
        , req.reads                                             AS physical_reads
        , OBJECT_NAME(st.objectid, st.dbid)                     AS object_name
        , req.query_hash
        , req.query_plan_hash
        , qp.query_plan                                         AS plan_xml
    FROM sys.dm_exec_requests  AS req
    JOIN sys.dm_exec_sessions  AS s
      ON req.session_id = s.session_id
    CROSS APPLY sys.dm_exec_sql_text(req.sql_handle)             AS st
    CROSS APPLY sys.dm_exec_query_plan(req.plan_handle)          AS qp
    WHERE req.session_id <> @@SPID
      AND req.group_id   >  1
      AND req.reads       >  0
    ORDER BY req.reads DESC
)
SELECT
      r.session_id
    , r.physical_reads
    , r.logical_reads
    , r.object_name
    , r.query_hash
    , CASE WHEN r.plan_xml.exist('//*[local-name()="RelOp"][@PhysicalOp="Table Scan"]') = 1
           THEN 1 ELSE 0 END                                   AS has_table_scan
    , CASE WHEN r.plan_xml.exist('//*[local-name()="RelOp"][@PhysicalOp="Clustered Index Scan"]') = 1
           THEN 1 ELSE 0 END                                   AS has_clustered_index_scan
FROM TopIORequests r
WHERE r.plan_xml.exist('//*[local-name()="RelOp"][@PhysicalOp="Table Scan"]') = 1
   OR r.plan_xml.exist('//*[local-name()="RelOp"][@PhysicalOp="Clustered Index Scan"]') = 1
OPTION (MAXDOP 1);
```
