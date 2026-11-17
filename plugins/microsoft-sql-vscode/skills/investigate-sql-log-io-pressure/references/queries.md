## Step 1: Detect Platform and Confirm Log IO Pressure

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
    SELECT 'This skill is not designed for Azure Synapse Analytics or Fabric Warehouse/Lakehouse endpoints (EngineEdition 6 or 11). Transaction log IO metrics and DMVs differ significantly in these environments. Note: Fabric SQL Database (EngineEdition 12) is supported.' AS unsupported_message;
    RETURN;
END

IF @EngineEdition IN (5, 12)
BEGIN
    -- Azure SQL DB / Fabric: dm_db_resource_stats
    ;WITH CteLogIO AS (
        SELECT
              MIN(end_time)                  AS window_start_utc
            , MAX(end_time)                  AS window_end_utc
            , AVG(avg_log_write_percent)     AS avg_log_write_percent
            , MAX(avg_log_write_percent)     AS max_log_write_percent
            , COUNT(*)                       AS sample_count
            , CASE
                WHEN AVG(avg_log_write_percent) >= {{LogIoThreshold}}
                    THEN 'Log IO pressure confirmed'
                WHEN MAX(avg_log_write_percent) >= {{LogIoThreshold}}
                    THEN 'Intermittent log IO spikes detected'
                ELSE 'No sustained log IO pressure in last ' + CAST({{ConfirmLookbackMinutes}} AS VARCHAR(10)) + 'm'
              END                            AS log_io_assessment
        FROM sys.dm_db_resource_stats
        WHERE end_time >= DATEADD(MINUTE, -{{ConfirmLookbackMinutes}}, SYSUTCDATETIME())
    )
    SELECT * FROM CteLogIO
    OPTION (MAXDOP 1);
END
ELSE IF @EngineEdition = 8
BEGIN
    -- Azure SQL Managed Instance: dm_db_resource_stats (available on recent MI builds)
    IF OBJECT_ID('sys.dm_db_resource_stats') IS NOT NULL
    BEGIN
        ;WITH CteLogIO AS (
            SELECT
                  MIN(end_time)                  AS window_start_utc
                , MAX(end_time)                  AS window_end_utc
                , AVG(avg_log_write_percent)     AS avg_log_write_percent
                , MAX(avg_log_write_percent)     AS max_log_write_percent
                , COUNT(*)                       AS sample_count
                , CASE
                    WHEN AVG(avg_log_write_percent) >= {{LogIoThreshold}}
                        THEN 'Log IO pressure confirmed'
                    WHEN MAX(avg_log_write_percent) >= {{LogIoThreshold}}
                        THEN 'Intermittent log IO spikes detected'
                    ELSE 'No sustained log IO pressure in last ' + CAST({{ConfirmLookbackMinutes}} AS VARCHAR(10)) + 'm'
                  END                            AS log_io_assessment
            FROM sys.dm_db_resource_stats
            WHERE end_time >= DATEADD(MINUTE, -{{ConfirmLookbackMinutes}}, SYSUTCDATETIME())
        )
        SELECT * FROM CteLogIO
        OPTION (MAXDOP 1);
    END
    ELSE
    BEGIN
        SELECT 'Azure SQL MI: dm_db_resource_stats not available on this build. Proceeding with wait-based analysis in subsequent steps.' AS mi_note;
    END
END
ELSE
BEGIN
    -- SQL Server on-premises: cumulative WRITELOG wait stats
    ;WITH LogWaits AS (
        SELECT
              SUM(CASE WHEN wait_type = 'WRITELOG'
                       THEN wait_time_ms ELSE 0 END)           AS writelog_wait_ms
            , SUM(CASE WHEN wait_type = 'WRITELOG'
                       THEN waiting_tasks_count ELSE 0 END)    AS writelog_wait_count
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
        , CAST(lw.writelog_wait_ms * 100.0
            / NULLIF(lw.total_wait_ms, 0) AS DECIMAL(5,2))     AS writelog_wait_pct
        , lw.writelog_wait_ms
        , lw.writelog_wait_count
        , CASE
            WHEN lw.writelog_wait_ms * 100.0
                 / NULLIF(lw.total_wait_ms, 0) >= {{LogIoThreshold}}
                THEN 'WRITELOG dominant in cumulative waits since restart'
            ELSE 'WRITELOG waits not dominant in cumulative wait stats'
          END                                                   AS log_io_assessment
    FROM LogWaits lw
    OPTION (MAXDOP 1);
END
```

## Step 2: Real-Time Log IO Consumers — Sessions with WRITELOG Waits and Log Bytes

```sql
SELECT TOP ({{TopN}})
      req.session_id
    , req.status
    , req.start_time
    , req.cpu_time                                          AS cpu_time_ms
    , req.total_elapsed_time                                AS elapsed_time_ms
    , req.writes                                            AS physical_writes
    , req.logical_reads
    , req.wait_type
    , req.wait_time                                         AS wait_time_ms
    , dt.database_transaction_log_bytes_used                AS log_bytes_used
    , dt.database_transaction_log_bytes_reserved            AS log_bytes_reserved
    , CAST(dt.database_transaction_log_bytes_used / 1048576.0
        AS DECIMAL(18,2))                                   AS log_mb_used
    , dt.database_transaction_begin_time                    AS txn_begin_time
    , DATEDIFF(SECOND, dt.database_transaction_begin_time, GETDATE()) AS txn_duration_sec
    , OBJECT_NAME(st.objectid, st.dbid)                     AS object_name
    , req.query_hash
    , req.query_plan_hash
FROM sys.dm_exec_requests              AS req
JOIN sys.dm_exec_sessions              AS s
  ON req.session_id = s.session_id
LEFT JOIN sys.dm_tran_session_transactions   AS st2
  ON req.session_id = st2.session_id
LEFT JOIN sys.dm_tran_database_transactions  AS dt
  ON st2.transaction_id = dt.transaction_id
  AND dt.database_id = DB_ID()
CROSS APPLY sys.dm_exec_sql_text(req.sql_handle)             AS st
WHERE req.session_id <> @@SPID
  AND req.group_id   >  1
  AND (
        req.wait_type = 'WRITELOG'
     OR dt.database_transaction_log_bytes_used > 0
  )
ORDER BY ISNULL(dt.database_transaction_log_bytes_used, 0) DESC, req.writes DESC
OPTION (MAXDOP 1);
```

## Step 3: Log File Latency

```sql
SELECT
      DB_NAME()                                                 AS database_name
    , df.name                                                   AS file_name
    , df.type_desc                                              AS file_type
    , vfs.num_of_reads                                          AS log_reads
    , vfs.num_of_writes                                         AS log_writes
    , CAST(vfs.num_of_bytes_read * 1.0 / 1048576.0 AS DECIMAL(18,2))   AS total_mb_read
    , CAST(vfs.num_of_bytes_written * 1.0 / 1048576.0 AS DECIMAL(18,2)) AS total_mb_written
    , CASE WHEN vfs.num_of_reads > 0
        THEN CAST(vfs.io_stall_read_ms * 1.0
             / vfs.num_of_reads AS DECIMAL(10,2))
        ELSE 0 END                                              AS avg_log_read_latency_ms
    , CASE WHEN vfs.num_of_writes > 0
        THEN CAST(vfs.io_stall_write_ms * 1.0
             / vfs.num_of_writes AS DECIMAL(10,2))
        ELSE 0 END                                              AS avg_log_write_latency_ms
    , vfs.io_stall_write_ms                                     AS total_log_write_stall_ms
    , vfs.io_stall                                              AS total_io_stall_ms
    , CASE WHEN vfs.num_of_writes > 0
        THEN CAST(vfs.num_of_bytes_written * 1.0
             / vfs.num_of_writes AS DECIMAL(10,0))
        ELSE 0 END                                              AS avg_bytes_per_write
FROM sys.dm_io_virtual_file_stats(DB_ID(), NULL) AS vfs
JOIN sys.database_files AS df
  ON vfs.file_id = df.file_id
WHERE df.type = 1   -- LOG files only
ORDER BY vfs.io_stall_write_ms DESC
OPTION (MAXDOP 1);
```

## Step 4: Transaction Log Space, VLF Health, and Reuse Blockers

### Step 4a: Log Space Usage

```sql
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @SqlMajorVersion INT = CAST(SERVERPROPERTY('ProductMajorVersion') AS INT);

IF @EngineEdition IN (5, 8, 12) OR @SqlMajorVersion >= 12
BEGIN
    SELECT
          DB_NAME()                         AS database_name
        , total_log_size_in_bytes / 1048576 AS total_log_size_mb
        , used_log_space_in_bytes / 1048576 AS used_log_space_mb
        , used_log_space_in_percent         AS used_log_space_pct
        , log_space_in_bytes_since_last_backup / 1048576 AS log_since_last_backup_mb
    FROM sys.dm_db_log_space_usage
    OPTION (MAXDOP 1);
END
ELSE
BEGIN
    SELECT
          DB_NAME()                         AS database_name
        , total_log_size_in_bytes / 1048576 AS total_log_size_mb
        , used_log_space_in_bytes / 1048576 AS used_log_space_mb
        , used_log_space_in_percent         AS used_log_space_pct
    FROM sys.dm_db_log_space_usage
    OPTION (MAXDOP 1);
END
```

### Step 4b: VLF Count and Log Stats

```sql
IF OBJECT_ID('sys.dm_db_log_stats') IS NOT NULL
BEGIN
    SELECT
          DB_NAME()                         AS database_name
        , total_vlf_count
        , active_vlf_count
        , active_log_size_mb
        , log_truncation_holdup_reason
        , log_since_last_checkpoint_mb
        , log_recovery_size_mb
        , CASE
            WHEN total_vlf_count > 1000 THEN 'Critical — excessive VLFs cause log IO overhead'
            WHEN total_vlf_count > 200  THEN 'Warning — consider shrinking and regrowing with fixed increments'
            ELSE 'Healthy'
          END                               AS vlf_assessment
    FROM sys.dm_db_log_stats(DB_ID())
    OPTION (MAXDOP 1);
END
ELSE
BEGIN
    SELECT
        'sys.dm_db_log_stats not available on this build (requires SQL Server 2016 SP2+ or Azure SQL). Current version: '
        + CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(128))
        AS skip_reason;
END
```

### Step 4c: Active Transactions Holding Log Space

```sql
SELECT TOP ({{TopN}})
      s.session_id
    , s.login_name
    , s.host_name
    , s.program_name
    , at.transaction_begin_time
    , DATEDIFF(SECOND, at.transaction_begin_time, GETDATE()) AS txn_duration_sec
    , dt.database_transaction_log_bytes_used                 AS log_bytes_used
    , CAST(dt.database_transaction_log_bytes_used / 1048576.0
        AS DECIMAL(18,2))                                    AS log_mb_used
    , dt.database_transaction_log_bytes_reserved             AS log_bytes_reserved
    , at.transaction_type
    , CASE at.transaction_state
        WHEN 0 THEN 'Initializing'
        WHEN 1 THEN 'Initialized'
        WHEN 2 THEN 'Active'
        WHEN 3 THEN 'Ended (read-only)'
        WHEN 4 THEN 'Commit started'
        WHEN 5 THEN 'Prepared'
        WHEN 6 THEN 'Committed'
        WHEN 7 THEN 'Rolling back'
        WHEN 8 THEN 'Rolled back'
      END                                                    AS transaction_state
    , r.query_hash
FROM sys.dm_tran_active_transactions         AS at
JOIN sys.dm_tran_session_transactions        AS st2
  ON at.transaction_id = st2.transaction_id
JOIN sys.dm_exec_sessions                    AS s
  ON st2.session_id = s.session_id
LEFT JOIN sys.dm_tran_database_transactions  AS dt
  ON at.transaction_id = dt.transaction_id
  AND dt.database_id = DB_ID()
LEFT JOIN sys.dm_exec_requests               AS r
  ON s.session_id = r.session_id
WHERE s.session_id <> @@SPID
  AND s.is_user_process = 1    -- group_id not available without dm_exec_requests join guarantee; is_user_process is correct here
ORDER BY ISNULL(dt.database_transaction_log_bytes_used, 0) DESC
OPTION (MAXDOP 1);
```

## Step 5: Log-Intensive Patterns — Historical Write-Heavy Queries

```sql
SELECT TOP ({{TopN}})
      qs.execution_count
    , qs.total_logical_writes
    , qs.total_logical_writes / NULLIF(qs.execution_count, 0)   AS logical_writes_per_exec
    , qs.total_logical_reads
    , qs.total_worker_time / 1000                               AS total_cpu_ms
    , qs.total_elapsed_time / 1000                              AS total_elapsed_ms
    , qs.max_logical_writes
    , qs.last_logical_writes
    , qs.last_execution_time
    , DB_NAME(st.dbid)                                          AS database_name
    , OBJECT_NAME(st.objectid, st.dbid)                         AS object_name
    , qs.query_hash
    , qs.query_plan_hash
FROM sys.dm_exec_query_stats      AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle)    AS st
WHERE qs.execution_count       >= {{MinExecutionCount}}
  AND qs.total_logical_writes  >= {{MinTotalLogicalWrites}}
  AND qs.last_execution_time   >= DATEADD(HOUR, -{{HistoryLookbackHours}}, GETDATE())
  AND st.dbid = DB_ID()
ORDER BY qs.total_logical_writes DESC
OPTION (MAXDOP 1);
```
