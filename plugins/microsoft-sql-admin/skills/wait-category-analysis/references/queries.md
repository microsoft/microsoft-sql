# Wait Category Analysis — Queries

Execute each query with the SQL query tool.

### Step 1: Platform Detection and Query Store Validation

> Execute with the SQL query tool. Detects engine edition, validates platform support,
> and checks whether Query Store is enabled with wait stats collection.

```sql
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

SELECT
      CAST(SERVERPROPERTY('Edition') AS NVARCHAR(128))           AS sql_edition
    , CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(128))    AS sql_version
    , CAST(SERVERPROPERTY('ProductMajorVersion') AS INT)         AS major_version
    , CASE @EngineEdition
        WHEN 5  THEN 'Azure SQL Database'
        WHEN 8  THEN 'Azure SQL Managed Instance'
        WHEN 12 THEN 'Fabric SQL Database'
        WHEN 6  THEN 'Azure Synapse Analytics (dedicated pool — not supported by this skill)'
        WHEN 11 THEN 'Azure Synapse serverless SQL pool / Fabric Warehouse or Lakehouse endpoint (not supported by this skill)'
        ELSE         'SQL Server (on-prem / IaaS)'
      END                                                        AS engine_type
    , @EngineEdition                                             AS engine_edition
    , CASE WHEN @EngineEdition IN (6, 11) THEN 1 ELSE 0 END     AS is_unsupported_dw
    , CASE WHEN @EngineEdition IN (5, 11, 12) THEN 0 ELSE 1 END AS has_instance_wait_stats
    , DB_NAME()                                                  AS current_database;

IF @EngineEdition IN (6, 11)
BEGIN
    SELECT 'This skill is not designed for SQL Data Warehouse, Synapse serverless, or Fabric Warehouse/Lakehouse endpoints. Use Fabric SQL Database (edition 12) for wait analysis.' AS unsupported_message;
    RETURN;
END

-- Check Query Store status
SELECT
      actual_state_desc                              AS query_store_state
    , desired_state_desc                             AS query_store_desired_state
    , query_capture_mode_desc                        AS capture_mode
    , wait_stats_capture_mode_desc                   AS wait_stats_capture_mode
    , max_storage_size_mb                            AS max_storage_mb
    , current_storage_size_mb                        AS current_storage_mb
    , CASE
        WHEN actual_state_desc <> 'READ_WRITE'
            THEN 'Query Store is not active — wait analysis will not return data'
        WHEN wait_stats_capture_mode_desc = 'OFF'
            THEN 'Wait stats capture is OFF — enable it: ALTER DATABASE CURRENT SET QUERY_STORE (WAIT_STATS_CAPTURE_MODE = ON)'
        ELSE 'Query Store is active with wait stats capture enabled'
      END                                            AS qs_assessment
FROM sys.database_query_store_options
OPTION (MAXDOP 1);
```

**What to do:**
| Assessment | Action |
|------------|--------|
| `is_unsupported_dw = 1` | **Stop** — this skill does not apply to SQL DW, Synapse serverless, or Fabric Warehouse/Lakehouse endpoints |
| `has_instance_wait_stats = 0` (Azure SQL DB / Fabric SQL DB) | Skip the Instance Level Wait Overview — use Database Level Wait Overview instead |
| `query_store_state` is not `READ_WRITE` | Query Store is disabled or read-only. Enable: `ALTER DATABASE CURRENT SET QUERY_STORE = ON` |
| `wait_stats_capture_mode = OFF` | Wait stats not being collected. Enable: `ALTER DATABASE CURRENT SET QUERY_STORE (WAIT_STATS_CAPTURE_MODE = ON)` |
| `current_storage_mb` near `max_storage_mb` | Query Store is nearly full — older data may be evicted. Consider increasing: `ALTER DATABASE CURRENT SET QUERY_STORE (MAX_STORAGE_SIZE_MB = ...)` |

Save `engine_edition` and `has_instance_wait_stats` for use in conditional logic in later steps.

---

### Step 2: Instance Level Wait Snapshot

> Execute with the SQL query tool. Instead of reading cumulative wait stats (which reflect
> everything since the last server restart), this step takes **two snapshots** separated by
> `{{SnapshotDurationSeconds}}` seconds and diffs them. This shows only the waits that actually
> occurred during the measurement window, giving a far more accurate picture of current activity.

> **Platform:** SQL Server (on-prem / IaaS) and Azure SQL Managed Instance only.
> On Azure SQL Database and Fabric, skip this step — use Step 3 (Database Level) instead.

> **Note:** This query will take `{{SnapshotDurationSeconds}}` seconds to complete because it
> includes a `WAITFOR DELAY` between the two snapshots. Inform the user before executing so they
> know the query is intentionally waiting, not hung.

```sql
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

IF @EngineEdition IN (5, 12)
BEGIN
    SELECT 'Skipped — sys.dm_os_wait_stats is not available on Azure SQL Database / Fabric. Use the Database Level Wait Overview instead.' AS skip_reason;
    RETURN;
END

-- Cleanup any leftover temp tables from a prior run
IF OBJECT_ID('tempdb..#WaitSnap1') IS NOT NULL DROP TABLE #WaitSnap1;
IF OBJECT_ID('tempdb..#WaitSnap2') IS NOT NULL DROP TABLE #WaitSnap2;

-- Snapshot 1: capture current wait stats
SELECT [wait_type], [waiting_tasks_count], [wait_time_ms],
       [max_wait_time_ms], [signal_wait_time_ms]
INTO #WaitSnap1
FROM sys.dm_os_wait_stats
OPTION (MAXDOP 1);

-- Wait for the configured snapshot duration
DECLARE @WaitForDelay CHAR(8) = CONVERT(CHAR(8), DATEADD(SECOND, {{SnapshotDurationSeconds}}, 0), 108);
WAITFOR DELAY @WaitForDelay;

-- Snapshot 2: capture wait stats again
SELECT [wait_type], [waiting_tasks_count], [wait_time_ms],
       [max_wait_time_ms], [signal_wait_time_ms]
INTO #WaitSnap2
FROM sys.dm_os_wait_stats
OPTION (MAXDOP 1);

-- Compute the diff: only waits that occurred during the snapshot window
;WITH [DiffWaits] AS
(
    -- Waits that appeared only in the second snapshot
    SELECT
        [s2].[wait_type],
        [s2].[wait_time_ms],
        [s2].[signal_wait_time_ms],
        [s2].[waiting_tasks_count]
    FROM [#WaitSnap2] AS [s2]
    LEFT OUTER JOIN [#WaitSnap1] AS [s1]
        ON [s2].[wait_type] = [s1].[wait_type]
    WHERE [s1].[wait_type] IS NULL
      AND [s2].[wait_time_ms] > 0
    UNION ALL
    -- Diff of waits present in both snapshots
    SELECT
        [s2].[wait_type],
        [s2].[wait_time_ms] - [s1].[wait_time_ms]                     AS [wait_time_ms],
        [s2].[signal_wait_time_ms] - [s1].[signal_wait_time_ms]       AS [signal_wait_time_ms],
        [s2].[waiting_tasks_count] - [s1].[waiting_tasks_count]        AS [waiting_tasks_count]
    FROM [#WaitSnap2] AS [s2]
    INNER JOIN [#WaitSnap1] AS [s1]
        ON [s2].[wait_type] = [s1].[wait_type]
    WHERE [s2].[waiting_tasks_count] - [s1].[waiting_tasks_count] > 0
      AND [s2].[wait_time_ms] - [s1].[wait_time_ms] > 0
),
[Waits] AS
(
    SELECT
        [wait_type],
        [wait_time_ms] / 1000.0                                       AS [WaitS],
        ([wait_time_ms] - [signal_wait_time_ms]) / 1000.0             AS [ResourceS],
        [signal_wait_time_ms] / 1000.0                                 AS [SignalS],
        [waiting_tasks_count]                                          AS [WaitCount],
        100.0 * [wait_time_ms] / SUM([wait_time_ms]) OVER()           AS [Percentage],
        ROW_NUMBER() OVER (ORDER BY [wait_time_ms] DESC)               AS [RowNum]
    FROM [DiffWaits]
    WHERE [wait_type] NOT IN (
        N'BROKER_EVENTHANDLER', N'BROKER_RECEIVE_WAITFOR', N'BROKER_TASK_STOP',
        N'BROKER_TO_FLUSH', N'BROKER_TRANSMITTER', N'CHECKPOINT_QUEUE',
        N'CHKPT', N'CLR_AUTO_EVENT', N'CLR_MANUAL_EVENT', N'CLR_SEMAPHORE', N'CXCONSUMER',
        N'DBMIRROR_DBM_EVENT', N'DBMIRROR_EVENTS_QUEUE', N'DBMIRROR_WORKER_QUEUE',
        N'DBMIRRORING_CMD', N'DIRTY_PAGE_POLL', N'DISPATCHER_QUEUE_SEMAPHORE',
        N'EXECSYNC', N'FSAGENT', N'FT_IFTS_SCHEDULER_IDLE_WAIT', N'FT_IFTSHC_MUTEX',
        N'HADR_CLUSAPI_CALL', N'HADR_FABRIC_CALLBACK', N'HADR_FILESTREAM_IOMGR_IOCOMPLETION',
        N'HADR_LOGCAPTURE_WAIT', N'HADR_NOTIFICATION_DEQUEUE', N'HADR_TIMER_TASK',
        N'HADR_WORK_QUEUE',
        N'KSOURCE_WAKEUP', N'LAZYWRITER_SLEEP', N'LOGMGR_QUEUE',
        N'MEMORY_ALLOCATION_EXT', N'ONDEMAND_TASK_QUEUE',
        N'PARALLEL_REDO_DRAIN_WORKER', N'PARALLEL_REDO_LOG_CACHE', N'PARALLEL_REDO_TRAN_LIST',
        N'PARALLEL_REDO_WORKER_SYNC', N'PARALLEL_REDO_WORKER_WAIT_WORK',
        N'PREEMPTIVE_HADR_LEASE_MECHANISM', N'PREEMPTIVE_SP_SERVER_DIAGNOSTICS',
        N'PREEMPTIVE_HTTP_EVENT_WAIT',
        N'PREEMPTIVE_OS_LIBRARYOPS', N'PREEMPTIVE_OS_COMOPS', N'PREEMPTIVE_OS_CRYPTOPS',
        N'PREEMPTIVE_OS_PIPEOPS', N'PREEMPTIVE_OS_AUTHENTICATIONOPS',
        N'PREEMPTIVE_OS_GENERICOPS', N'PREEMPTIVE_OS_VERIFYTRUST',
        N'PREEMPTIVE_OS_FILEOPS', N'PREEMPTIVE_OS_DEVICEOPS', N'PREEMPTIVE_OS_QUERYREGISTRY',
        N'PREEMPTIVE_OS_WRITEFILE',
        N'PREEMPTIVE_XE_CALLBACKEXECUTE', N'PREEMPTIVE_XE_DISPATCHER',
        N'PREEMPTIVE_XE_GETTARGETSTATE', N'PREEMPTIVE_XE_SESSIONCOMMIT',
        N'PREEMPTIVE_XE_TARGETINIT', N'PREEMPTIVE_XE_TARGETFINALIZE',
        N'PWAIT_ALL_COMPONENTS_INITIALIZED', N'PWAIT_DIRECTLOGCONSUMER_GETNEXT',
        N'PWAIT_EXTENSIBILITY_CLEANUP_TASK',
        N'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP', N'QDS_ASYNC_QUEUE',
        N'QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP', N'QDS_SHUTDOWN_QUEUE',
        N'REDO_THREAD_PENDING_WORK', N'REQUEST_FOR_DEADLOCK_SEARCH',
        N'RESOURCE_QUEUE', N'SERVER_IDLE_CHECK', N'SLEEP_BPOOL_FLUSH', N'SLEEP_DBSTARTUP',
        N'SLEEP_DCOMSTARTUP', N'SLEEP_MASTERDBREADY', N'SLEEP_MASTERMDREADY',
        N'SLEEP_MASTERUPGRADED', N'SLEEP_MSDBSTARTUP', N'SLEEP_SYSTEMTASK', N'SLEEP_TASK',
        N'SLEEP_TEMPDBSTARTUP', N'SNI_HTTP_ACCEPT', N'SOS_WORK_DISPATCHER',
        N'SP_SERVER_DIAGNOSTICS_SLEEP',
        N'SQLTRACE_BUFFER_FLUSH', N'SQLTRACE_INCREMENTAL_FLUSH_SLEEP', N'SQLTRACE_WAIT_ENTRIES',
        N'STARTUP_DEPENDENCY_MANAGER',
        N'WAIT_FOR_RESULTS', N'WAITFOR', N'WAITFOR_TASKSHUTDOWN', N'WAIT_XTP_HOST_WAIT',
        N'WAIT_XTP_OFFLINE_CKPT_NEW_LOG', N'WAIT_XTP_CKPT_CLOSE', N'WAIT_XTP_RECOVERY',
        N'XE_BUFFERMGR_ALLPROCESSED_EVENT', N'XE_DISPATCHER_JOIN',
        N'XE_DISPATCHER_WAIT', N'XE_LIVE_TARGET_TVF', N'XE_TIMER_EVENT')
)
SELECT
    MAX (W1.wait_type) AS [WaitType],
    CAST (MAX (W1.Percentage) AS DECIMAL (5,2)) AS [Wait Percentage],
    CAST ((MAX (W1.WaitS) / MAX (W1.WaitCount)) AS DECIMAL (16,4)) AS [AvgWait_Sec],
    CAST ((MAX (W1.ResourceS) / MAX (W1.WaitCount)) AS DECIMAL (16,4)) AS [AvgRes_Sec],
    CAST ((MAX (W1.SignalS) / MAX (W1.WaitCount)) AS DECIMAL (16,4)) AS [AvgSig_Sec],
    CAST (MAX (W1.WaitS) AS DECIMAL (16,2)) AS [Wait_Sec],
    CAST (MAX (W1.ResourceS) AS DECIMAL (16,2)) AS [Resource_Sec],
    CAST (MAX (W1.SignalS) AS DECIMAL (16,2)) AS [Signal_Sec],
    MAX (W1.WaitCount) AS [Wait Count]
FROM Waits AS W1
INNER JOIN Waits AS W2
    ON W2.RowNum <= W1.RowNum
GROUP BY W1.RowNum, W1.wait_type
HAVING SUM (W2.Percentage) - MAX (W1.Percentage) < 99 -- percentage threshold
ORDER BY [Wait Percentage] DESC
OPTION (MAXDOP 1, RECOMPILE);

-- Cleanup
IF OBJECT_ID('tempdb..#WaitSnap1') IS NOT NULL DROP TABLE #WaitSnap1;
IF OBJECT_ID('tempdb..#WaitSnap2') IS NOT NULL DROP TABLE #WaitSnap2;
```

**What to do:**
| Finding | Recommendation |
|---------|----------------|
| `SOS_SCHEDULER_YIELD` dominant | CPU pressure — queries are CPU-bound. Check for plan regressions, missing indexes, or outdated statistics |
| `LCK_M_*` waits dominant | Blocking — sessions waiting on locks. Run `check-live-blocking` to identify the head blocker |
| `PAGEIOLATCH_*` dominant | IO pressure — pages being read from disk. Check for missing indexes, large table scans, or insufficient memory |
| `CXPACKET` / `CXCONSUMER` dominant | Parallelism overhead — consider reviewing MAXDOP settings or query plans with excessive parallelism |
| `WRITELOG` / `LOG_RATE_GOVERNOR` dominant | Transaction log bottleneck — high write workload or log IO latency. Check disk performance and batch transaction sizes |
| `ASYNC_NETWORK_IO` dominant | Client is not consuming results fast enough — reduce result set sizes or investigate client-side processing |
| `RESOURCE_SEMAPHORE` dominant | Memory grant pressure — queries waiting for memory to execute. Check for large sorts/hashes and outdated statistics |
| `THREADPOOL` dominant | Worker thread exhaustion — too many concurrent requests. Review query durations and connection pool sizes |
| High `AvgSig_Sec` relative to `AvgWait_Sec` | CPU scheduling pressure — threads are runnable but waiting for CPU time. May need more CPU capacity |

---

### Step 3: Database Level Wait Snapshot

> Execute with the SQL query tool. Same snapshot approach as Step 2 but using
> `sys.dm_db_wait_stats` which is scoped to the current database.

> **Platform:** Azure SQL Database and Fabric. On SQL Server (on-prem / IaaS) and Azure SQL MI,
> `sys.dm_db_wait_stats` is not available — use Step 2 (Instance Level) instead.

> **Note:** This query will take `{{SnapshotDurationSeconds}}` seconds to complete because it
> includes a `WAITFOR DELAY` between the two snapshots. Inform the user before executing so they
> know the query is intentionally waiting, not hung.

```sql
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

IF @EngineEdition NOT IN (5, 12)
BEGIN
    SELECT 'Skipped — sys.dm_db_wait_stats is only available on Azure SQL Database / Fabric. Use the Instance Level Wait Overview instead.' AS skip_reason;
    RETURN;
END

-- Cleanup any leftover temp tables from a prior run
IF OBJECT_ID('tempdb..#DbWaitSnap1') IS NOT NULL DROP TABLE #DbWaitSnap1;
IF OBJECT_ID('tempdb..#DbWaitSnap2') IS NOT NULL DROP TABLE #DbWaitSnap2;

-- Snapshot 1: capture current database-level wait stats
SELECT [wait_type], [waiting_tasks_count], [wait_time_ms],
       [max_wait_time_ms], [signal_wait_time_ms]
INTO #DbWaitSnap1
FROM sys.dm_db_wait_stats
OPTION (MAXDOP 1);

-- Wait for the configured snapshot duration
DECLARE @WaitForDelay CHAR(8) = CONVERT(CHAR(8), DATEADD(SECOND, {{SnapshotDurationSeconds}}, 0), 108);
WAITFOR DELAY @WaitForDelay;

-- Snapshot 2: capture database-level wait stats again
SELECT [wait_type], [waiting_tasks_count], [wait_time_ms],
       [max_wait_time_ms], [signal_wait_time_ms]
INTO #DbWaitSnap2
FROM sys.dm_db_wait_stats
OPTION (MAXDOP 1);

-- Compute the diff: only waits that occurred during the snapshot window
;WITH [DiffWaits] AS
(
    -- Waits that appeared only in the second snapshot
    SELECT
        [s2].[wait_type],
        [s2].[wait_time_ms],
        [s2].[signal_wait_time_ms],
        [s2].[waiting_tasks_count]
    FROM [#DbWaitSnap2] AS [s2]
    LEFT OUTER JOIN [#DbWaitSnap1] AS [s1]
        ON [s2].[wait_type] = [s1].[wait_type]
    WHERE [s1].[wait_type] IS NULL
      AND [s2].[wait_time_ms] > 0
    UNION ALL
    -- Diff of waits present in both snapshots
    SELECT
        [s2].[wait_type],
        [s2].[wait_time_ms] - [s1].[wait_time_ms]                     AS [wait_time_ms],
        [s2].[signal_wait_time_ms] - [s1].[signal_wait_time_ms]       AS [signal_wait_time_ms],
        [s2].[waiting_tasks_count] - [s1].[waiting_tasks_count]        AS [waiting_tasks_count]
    FROM [#DbWaitSnap2] AS [s2]
    INNER JOIN [#DbWaitSnap1] AS [s1]
        ON [s2].[wait_type] = [s1].[wait_type]
    WHERE [s2].[waiting_tasks_count] - [s1].[waiting_tasks_count] > 0
      AND [s2].[wait_time_ms] - [s1].[wait_time_ms] > 0
),
[Waits] AS
(
    SELECT
        [wait_type],
        [wait_time_ms] / 1000.0                                       AS [WaitS],
        ([wait_time_ms] - [signal_wait_time_ms]) / 1000.0             AS [ResourceS],
        [signal_wait_time_ms] / 1000.0                                 AS [SignalS],
        [waiting_tasks_count]                                          AS [WaitCount],
        100.0 * [wait_time_ms] / SUM([wait_time_ms]) OVER()           AS [Percentage],
        ROW_NUMBER() OVER (ORDER BY [wait_time_ms] DESC)               AS [RowNum]
    FROM [DiffWaits]
    WHERE [wait_type] NOT IN (
        N'BROKER_EVENTHANDLER', N'BROKER_RECEIVE_WAITFOR', N'BROKER_TASK_STOP',
        N'BROKER_TO_FLUSH', N'BROKER_TRANSMITTER', N'CHECKPOINT_QUEUE',
        N'CHKPT', N'CLR_AUTO_EVENT', N'CLR_MANUAL_EVENT', N'CLR_SEMAPHORE', N'CXCONSUMER',
        N'DBMIRROR_DBM_EVENT', N'DBMIRROR_EVENTS_QUEUE', N'DBMIRROR_WORKER_QUEUE',
        N'DBMIRRORING_CMD', N'DIRTY_PAGE_POLL', N'DISPATCHER_QUEUE_SEMAPHORE',
        N'EXECSYNC', N'FSAGENT', N'FT_IFTS_SCHEDULER_IDLE_WAIT', N'FT_IFTSHC_MUTEX',
        N'HADR_CLUSAPI_CALL', N'HADR_FABRIC_CALLBACK', N'HADR_FILESTREAM_IOMGR_IOCOMPLETION',
        N'HADR_LOGCAPTURE_WAIT', N'HADR_NOTIFICATION_DEQUEUE', N'HADR_TIMER_TASK',
        N'HADR_WORK_QUEUE',
        N'KSOURCE_WAKEUP', N'LAZYWRITER_SLEEP', N'LOGMGR_QUEUE',
        N'MEMORY_ALLOCATION_EXT', N'ONDEMAND_TASK_QUEUE',
        N'PARALLEL_REDO_DRAIN_WORKER', N'PARALLEL_REDO_LOG_CACHE', N'PARALLEL_REDO_TRAN_LIST',
        N'PARALLEL_REDO_WORKER_SYNC', N'PARALLEL_REDO_WORKER_WAIT_WORK',
        N'PREEMPTIVE_HADR_LEASE_MECHANISM', N'PREEMPTIVE_SP_SERVER_DIAGNOSTICS',
        N'PREEMPTIVE_HTTP_EVENT_WAIT',
        N'PREEMPTIVE_OS_LIBRARYOPS', N'PREEMPTIVE_OS_COMOPS', N'PREEMPTIVE_OS_CRYPTOPS',
        N'PREEMPTIVE_OS_PIPEOPS', N'PREEMPTIVE_OS_AUTHENTICATIONOPS',
        N'PREEMPTIVE_OS_GENERICOPS', N'PREEMPTIVE_OS_VERIFYTRUST',
        N'PREEMPTIVE_OS_FILEOPS', N'PREEMPTIVE_OS_DEVICEOPS', N'PREEMPTIVE_OS_QUERYREGISTRY',
        N'PREEMPTIVE_OS_WRITEFILE',
        N'PREEMPTIVE_XE_CALLBACKEXECUTE', N'PREEMPTIVE_XE_DISPATCHER',
        N'PREEMPTIVE_XE_GETTARGETSTATE', N'PREEMPTIVE_XE_SESSIONCOMMIT',
        N'PREEMPTIVE_XE_TARGETINIT', N'PREEMPTIVE_XE_TARGETFINALIZE',
        N'PWAIT_ALL_COMPONENTS_INITIALIZED', N'PWAIT_DIRECTLOGCONSUMER_GETNEXT',
        N'PWAIT_EXTENSIBILITY_CLEANUP_TASK',
        N'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP', N'QDS_ASYNC_QUEUE',
        N'QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP', N'QDS_SHUTDOWN_QUEUE',
        N'REDO_THREAD_PENDING_WORK', N'REQUEST_FOR_DEADLOCK_SEARCH',
        N'RESOURCE_QUEUE', N'SERVER_IDLE_CHECK', N'SLEEP_BPOOL_FLUSH', N'SLEEP_DBSTARTUP',
        N'SLEEP_DCOMSTARTUP', N'SLEEP_MASTERDBREADY', N'SLEEP_MASTERMDREADY',
        N'SLEEP_MASTERUPGRADED', N'SLEEP_MSDBSTARTUP', N'SLEEP_SYSTEMTASK', N'SLEEP_TASK',
        N'SLEEP_TEMPDBSTARTUP', N'SNI_HTTP_ACCEPT', N'SOS_WORK_DISPATCHER',
        N'SP_SERVER_DIAGNOSTICS_SLEEP',
        N'SQLTRACE_BUFFER_FLUSH', N'SQLTRACE_INCREMENTAL_FLUSH_SLEEP', N'SQLTRACE_WAIT_ENTRIES',
        N'STARTUP_DEPENDENCY_MANAGER',
        N'WAIT_FOR_RESULTS', N'WAITFOR', N'WAITFOR_TASKSHUTDOWN', N'WAIT_XTP_HOST_WAIT',
        N'WAIT_XTP_OFFLINE_CKPT_NEW_LOG', N'WAIT_XTP_CKPT_CLOSE', N'WAIT_XTP_RECOVERY',
        N'XE_BUFFERMGR_ALLPROCESSED_EVENT', N'XE_DISPATCHER_JOIN',
        N'XE_DISPATCHER_WAIT', N'XE_LIVE_TARGET_TVF', N'XE_TIMER_EVENT')
)
SELECT
    MAX (W1.wait_type) AS [WaitType],
    CAST (MAX (W1.Percentage) AS DECIMAL (5,2)) AS [Wait Percentage],
    CAST ((MAX (W1.WaitS) / MAX (W1.WaitCount)) AS DECIMAL (16,4)) AS [AvgWait_Sec],
    CAST ((MAX (W1.ResourceS) / MAX (W1.WaitCount)) AS DECIMAL (16,4)) AS [AvgRes_Sec],
    CAST ((MAX (W1.SignalS) / MAX (W1.WaitCount)) AS DECIMAL (16,4)) AS [AvgSig_Sec],
    CAST (MAX (W1.WaitS) AS DECIMAL (16,2)) AS [Wait_Sec],
    CAST (MAX (W1.ResourceS) AS DECIMAL (16,2)) AS [Resource_Sec],
    CAST (MAX (W1.SignalS) AS DECIMAL (16,2)) AS [Signal_Sec],
    MAX (W1.WaitCount) AS [Wait Count]
FROM Waits AS W1
INNER JOIN Waits AS W2
    ON W2.RowNum <= W1.RowNum
GROUP BY W1.RowNum, W1.wait_type
HAVING SUM (W2.Percentage) - MAX (W1.Percentage) < 99 -- percentage threshold
ORDER BY [Wait Percentage] DESC
OPTION (MAXDOP 1, RECOMPILE);

-- Cleanup
IF OBJECT_ID('tempdb..#DbWaitSnap1') IS NOT NULL DROP TABLE #DbWaitSnap1;
IF OBJECT_ID('tempdb..#DbWaitSnap2') IS NOT NULL DROP TABLE #DbWaitSnap2;
```

**What to do:**
| Finding | Recommendation |
|---------|----------------|
| `SOS_SCHEDULER_YIELD` dominant | CPU pressure — queries are CPU-bound. Check for plan regressions, missing indexes, or outdated statistics |
| `LCK_M_*` waits dominant | Blocking — sessions waiting on locks. Run `check-live-blocking` to identify the head blocker |
| `PAGEIOLATCH_*` dominant | IO pressure — pages being read from disk. Check for missing indexes, large table scans, or insufficient memory |
| `WRITELOG` / `LOG_RATE_GOVERNOR` dominant | Transaction log bottleneck — high write workload or log IO latency |
| `ASYNC_NETWORK_IO` dominant | Client is not consuming results fast enough — reduce result set sizes or investigate client-side processing |
| `RESOURCE_SEMAPHORE` dominant | Memory grant pressure — queries waiting for memory to execute. Check for large sorts/hashes and outdated statistics |

---

### Step 4: Query Level Wait Analysis

> Execute with the SQL query tool. Returns the top N queries with the highest total wait time,
> with a breakdown of their wait categories.

> **Platform:** All platforms that support Query Store (SQL Server 2016+, Azure SQL Database,
> Azure SQL Managed Instance). Requires Query Store to be enabled with wait stats capture ON
> (validated in Step 1).


**Version: By Query Hash** — Use this version when analyzing query patterns or when the user asks to identify queries by hash.

```sql
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
DECLARE @TopN INT = {{TopN}};  -- default: 20

;WITH RankedQueries AS (
    SELECT TOP (@TopN)
          q.query_id
        , q.query_hash
        , SUM(ws.total_query_wait_time_ms)                       AS total_wait_ms
    FROM sys.query_store_query q
    INNER JOIN sys.query_store_plan p
        ON q.query_id = p.query_id
    INNER JOIN sys.query_store_wait_stats ws
        ON p.plan_id = ws.plan_id
    INNER JOIN sys.query_store_runtime_stats_interval rsi
        ON ws.runtime_stats_interval_id = rsi.runtime_stats_interval_id
    WHERE rsi.start_time >= DATEADD(MINUTE, -{{LookbackMinutes}}, GETUTCDATE())
      AND q.is_internal_query = 0
    GROUP BY q.query_id, q.query_hash
    ORDER BY total_wait_ms DESC
),
TopWaiters AS (
    SELECT
          rq.query_hash
        , p.query_plan_hash
        , ws.wait_category_desc
        , SUM(ws.total_query_wait_time_ms)                       AS total_wait_ms
        , SUM(ws.avg_query_wait_time_ms * ws.total_query_wait_time_ms)
            / NULLIF(SUM(ws.total_query_wait_time_ms), 0)        AS weighted_avg_wait_ms
        , COUNT(DISTINCT p.plan_id)                               AS plan_count
    FROM RankedQueries rq
    INNER JOIN sys.query_store_plan p
        ON rq.query_id = p.query_id
    INNER JOIN sys.query_store_wait_stats ws
        ON p.plan_id = ws.plan_id
    INNER JOIN sys.query_store_runtime_stats_interval rsi
        ON ws.runtime_stats_interval_id = rsi.runtime_stats_interval_id
    WHERE rsi.start_time >= DATEADD(MINUTE, -{{LookbackMinutes}}, GETUTCDATE())
    GROUP BY rq.query_hash, p.query_plan_hash, ws.wait_category_desc
)
SELECT
      CONVERT(VARCHAR(20), tw.query_hash, 1)                      AS [Query Hash]
    , CONVERT(VARCHAR(20), tw.query_plan_hash, 1)                 AS [Query Plan Hash]
    , tw.wait_category_desc                                       AS [Wait Category]
    , tw.total_wait_ms                                            AS [Total Wait Time (ms)]
    , tw.weighted_avg_wait_ms                                     AS [Weighted Avg Wait (ms)]
    , tw.total_wait_ms * 100.0
        / NULLIF(SUM(tw.total_wait_ms) OVER (PARTITION BY tw.query_hash, tw.query_plan_hash), 0)
                                                                  AS [Wait Category pct of Query Total]
    , tw.plan_count                                               AS [Plan Count]
FROM TopWaiters tw
ORDER BY tw.total_wait_ms DESC
OPTION (MAXDOP 1, RECOMPILE);
```

**Version: By Query ID and Plan ID** — Use this version when the user wants to investigate specific queries or plans in Query Store, or wants to drill down into individual plan performance.

```sql
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
DECLARE @TopN INT = {{TopN}};  -- default: 20

;WITH RankedQueries AS (
    SELECT TOP (@TopN)
          q.query_id
        , SUM(ws.total_query_wait_time_ms)                       AS total_wait_ms
    FROM sys.query_store_query q
    INNER JOIN sys.query_store_plan p
        ON q.query_id = p.query_id
    INNER JOIN sys.query_store_wait_stats ws
        ON p.plan_id = ws.plan_id
    INNER JOIN sys.query_store_runtime_stats_interval rsi
        ON ws.runtime_stats_interval_id = rsi.runtime_stats_interval_id
    WHERE rsi.start_time >= DATEADD(MINUTE, -{{LookbackMinutes}}, GETUTCDATE())
      AND q.is_internal_query = 0
    GROUP BY q.query_id
    ORDER BY total_wait_ms DESC
),
TopWaiters AS (
    SELECT
          rq.query_id
        , p.plan_id
        , ws.wait_category_desc
        , SUM(ws.total_query_wait_time_ms)                       AS total_wait_ms
        , SUM(ws.avg_query_wait_time_ms * ws.total_query_wait_time_ms)
            / NULLIF(SUM(ws.total_query_wait_time_ms), 0)        AS weighted_avg_wait_ms
    FROM RankedQueries rq
    INNER JOIN sys.query_store_plan p
        ON rq.query_id = p.query_id
    INNER JOIN sys.query_store_wait_stats ws
        ON p.plan_id = ws.plan_id
    INNER JOIN sys.query_store_runtime_stats_interval rsi
        ON ws.runtime_stats_interval_id = rsi.runtime_stats_interval_id
    WHERE rsi.start_time >= DATEADD(MINUTE, -{{LookbackMinutes}}, GETUTCDATE())
    GROUP BY rq.query_id, p.plan_id, ws.wait_category_desc
)
SELECT
      tw.query_id                                                 AS [Query ID]
    , tw.plan_id                                                  AS [Plan ID]
    , tw.wait_category_desc                                       AS [Wait Category]
    , tw.total_wait_ms                                            AS [Total Wait Time (ms)]
    , tw.weighted_avg_wait_ms                                     AS [Weighted Avg Wait (ms)]
    , tw.total_wait_ms * 100.0
        / NULLIF(SUM(tw.total_wait_ms) OVER (PARTITION BY tw.query_id, tw.plan_id), 0)
                                                                  AS [Wait Category pct of Query Total]
FROM TopWaiters tw
ORDER BY tw.total_wait_ms DESC
OPTION (MAXDOP 1, RECOMPILE);
```

**What to do:**
| Finding | Recommendation |
|---------|----------------|
| High `Total Wait Time` with Lock category | Query is blocked frequently — run `check-live-blocking` to find head blocker |
| High `Total Wait Time` with CPU category | CPU-bound query — check execution plan for missing indexes, outdated statistics, or plan regression |
| `Plan Count` > 1 | Multiple plans detected — possible plan regression or parameter sniffing. Run `query-store-volatile-historical-slow-queries-comparison` (Step 1) |
| High `Total Wait Time` with IO category | Query reading too many pages from disk — check for table scans or missing covering indexes |
| High `Weighted Avg Wait` relative to total | Consistently slow per execution — not just volume-driven |

---

### Step 5: PAGELATCH Contention Diagnostic

> Execute with the SQL query tool. When PAGELATCH_XX waits are detected in prior steps,
> run this query to determine whether contention is on tempdb allocation pages (PFS/GAM/SGAM).

> **Platform:** All SQL Server platforms except Azure SQL Database and Fabric.

```sql
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

IF @EngineEdition IN (5, 12)
BEGIN
    SELECT 'Skipped — sys.dm_os_waiting_tasks PAGELATCH analysis is not applicable on Azure SQL Database / Fabric.' AS skip_reason;
    RETURN;
END

SELECT TOP 50
      session_id
    , wait_type
    , wait_duration_ms
    , blocking_session_id
    , resource_description
    , CASE
        WHEN (CAST(RIGHT(resource_description, LEN(resource_description) - CHARINDEX(':', resource_description, 3)) AS INT) - 1) % 8088 = 0
            THEN 'PFS Page'
        WHEN (CAST(RIGHT(resource_description, LEN(resource_description) - CHARINDEX(':', resource_description, 3)) AS INT) - 2) % 511232 = 0
            THEN 'GAM Page'
        WHEN (CAST(RIGHT(resource_description, LEN(resource_description) - CHARINDEX(':', resource_description, 3)) AS INT) - 3) % 511232 = 0
            THEN 'SGAM Page'
        ELSE 'Not PFS, GAM, or SGAM page'
      END AS resource_type
FROM sys.dm_os_waiting_tasks
WHERE wait_type LIKE 'PAGE%LATCH_%'
  AND resource_description LIKE '2:%'
ORDER BY wait_duration_ms DESC
OPTION (MAXDOP 1);
```

**What to do:**
| Finding | Recommendation |
|---------|----------------|
| Multiple rows with `PFS Page` | tempdb PFS contention — add more tempdb data files (one per logical CPU core, up to 8) |
| Multiple rows with `GAM Page` | tempdb GAM contention — add more tempdb data files and ensure uniform file sizes |
| Multiple rows with `SGAM Page` | tempdb SGAM contention — add more tempdb data files; enable trace flag 1118 (pre-2016) or mixed extents are already disabled (2016+) |
| `Not PFS, GAM, or SGAM page` | User data page contention — investigate the specific object. May need table/index redesign or partitioning |
| All rows show `resource_description LIKE '2:%'` | File ID 2 = tempdb — confirms this is tempdb-specific contention |