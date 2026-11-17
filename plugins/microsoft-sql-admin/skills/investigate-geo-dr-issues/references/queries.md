
# Investigate Geo-DR Issues — Queries

Before running each query, replace the placeholders `{{DatabaseName}}` (escape `'` as `''`), `{{TopN}}`, and `{{LookbackHours}}` (integers) with the parameter values. Each query auto-detects platform via `EngineEdition`.

---

### GetWaitstats

> Captures long-running transactions, log space/rate, and HADR/log waits that gate failover readiness.
```sql
SET NOCOUNT ON;
DECLARE @E INT=CAST(SERVERPROPERTY('EngineEdition') AS INT),
        @N DATETIME2(3)=SYSDATETIME(),
        @DB NVARCHAR(128)=NULLIF(N'{{DatabaseName}}','');
IF @E IN(6,9,11)
BEGIN
 SELECT 'UNSUPPORTED' AS [P],'EngineEdition '+CAST(@E AS VARCHAR)+' not supported' AS [Note],@N AS [AsOf];
 RETURN;
END;
/* @bw=benign HADR bg waits (excluded); @lw=log-IO waits (flagged) */
DECLARE @bw TABLE(wt SYSNAME);
INSERT INTO @bw(wt) VALUES('HADR_WORK_QUEUE'),('HADR_TIMER_TASK'),('HADR_CLUSAPI_CALL'),('HADR_FILESTREAM_IOMGR_IOCOMPLETION'),('HADR_LOGCAPTURE_WAIT'),('HADR_NOTIFICATION_DEQUEUE'),('HADR_FABRIC_CALLBACK'),('HADR_DATABASE_WAIT_FOR_RECOVERY'),('HADR_DATABASE_WAIT_FOR_TRANSITION_TO_VERSIONING'),('HADR_RECOVERY_WAIT_FOR_CONNECTION'),('HADR_RECOVERY_WAIT_FOR_UNDO'),('PARALLEL_REDO_WORKER_WAIT_WORK'),('PARALLEL_REDO_DRAIN_WORKER'),('PARALLEL_REDO_LOG_CACHE'),('PARALLEL_REDO_TRAN_LIST'),('PARALLEL_REDO_WORKER_SYNC'),('PARALLEL_REDO_TRAN_TURN'),('LOGMGR_QUEUE');
DECLARE @lw TABLE(wt SYSNAME);
INSERT INTO @lw(wt) VALUES('WRITELOG'),('LOGBUFFER'),('LOGMGR'),('LOGMGR_RESERVE_APPEND'),('LOG_RATE_GOVERNOR'),('LOG_RATE_GOVERNOR_V2'),('LOG_POOL_SCAN'),('IO_COMPLETION'),('ASYNC_IO_COMPLETION');
/* 1) Long-running txns - block failover */
SELECT TOP({{TopN}})
 'LONG_TXN' AS [C],
 st.session_id AS [SPID],
 s.login_name AS [Login],
 s.program_name AS [App],
 DB_NAME(dt.database_id) AS [DB],
 dt.database_transaction_begin_time AS [TxnStart],
 DATEDIFF(SECOND,dt.database_transaction_begin_time,@N) AS [TxnDurSec],
 dt.database_transaction_log_bytes_used/1024 AS [LogUsedKB],
 dt.database_transaction_log_bytes_reserved/1024 AS [LogResvKB],
 r.status AS [ReqStatus],
 r.wait_type AS [Wait],
 r.blocking_session_id AS [BlockBy],
 CASE
  WHEN dt.database_transaction_log_bytes_used>=1073741824
    OR DATEDIFF(SECOND,dt.database_transaction_begin_time,@N)>=300 THEN 'CRITICAL'
  WHEN dt.database_transaction_log_bytes_used>=104857600
    OR DATEDIFF(SECOND,dt.database_transaction_begin_time,@N)>=60 THEN 'WARNING'
  ELSE 'OK'
 END AS [Sev]
FROM sys.dm_tran_database_transactions dt
INNER JOIN sys.dm_tran_session_transactions st ON dt.transaction_id=st.transaction_id
INNER JOIN sys.dm_exec_sessions s ON st.session_id=s.session_id
LEFT JOIN sys.dm_exec_requests r ON r.session_id=s.session_id
WHERE DATEDIFF(SECOND,dt.database_transaction_begin_time,@N)>=30
 AND DB_NAME(dt.database_id) NOT IN('master','model','msdb','tempdb')
 AND (@DB IS NULL OR DB_NAME(dt.database_id)=@DB)
ORDER BY dt.database_transaction_log_bytes_used DESC,
         DATEDIFF(SECOND,dt.database_transaction_begin_time,@N) DESC
 OPTION (MAXDOP 1);
/* 2a) Log space + reuse holdup */
;WITH LT AS
(
 SELECT dt.database_id,
        COUNT(*) AS active_txn,
        SUM(dt.database_transaction_log_bytes_used) AS txn_log_bytes
 FROM sys.dm_tran_database_transactions dt
 GROUP BY dt.database_id
)
SELECT 'LOG_SPACE' AS [C],
 DB_NAME() AS [DB],
 CAST(lsu.used_log_space_in_bytes/1048576.0 AS DECIMAL(18,1)) AS [LogUsedMB],
 CAST(lsu.used_log_space_in_percent AS DECIMAL(5,2)) AS [LogUsedPct],
 d.log_reuse_wait_desc AS [LogReuseWait],
 ISNULL(lt.active_txn,0) AS [ActiveTxn],
 CAST(ISNULL(lt.txn_log_bytes,0)/1048576.0 AS DECIMAL(18,1)) AS [ActiveTxnLogMB],
 CASE
  WHEN lsu.used_log_space_in_percent>=85 THEN 'CRITICAL'
  WHEN lsu.used_log_space_in_percent>=70
    OR d.log_reuse_wait_desc NOT IN('NOTHING','CHECKPOINT') THEN 'WARNING'
  ELSE 'OK'
 END AS [Sev]
FROM sys.dm_db_log_space_usage lsu
INNER JOIN sys.databases d ON d.database_id=DB_ID()
LEFT JOIN LT lt ON lt.database_id=DB_ID()
 OPTION (MAXDOP 1);
/* 2b) Log flush rate - 1s delta */
BEGIN TRY
 DECLARE @lb1 BIGINT,@lf1 BIGINT,@lb2 BIGINT,@lf2 BIGINT;
 SELECT @lb1=MAX(CASE WHEN counter_name LIKE N'Log Bytes Flushed/sec%' THEN cntr_value END),
        @lf1=MAX(CASE WHEN counter_name LIKE N'Log Flushes/sec%' THEN cntr_value END)
 FROM sys.dm_os_performance_counters
 WHERE object_name LIKE N'%Databases%' AND instance_name=DB_NAME();
 WAITFOR DELAY '00:00:01';
 SELECT @lb2=MAX(CASE WHEN counter_name LIKE N'Log Bytes Flushed/sec%' THEN cntr_value END),
        @lf2=MAX(CASE WHEN counter_name LIKE N'Log Flushes/sec%' THEN cntr_value END)
 FROM sys.dm_os_performance_counters
 WHERE object_name LIKE N'%Databases%' AND instance_name=DB_NAME();
 SELECT 'LOG_RATE' AS [C],
  DB_NAME() AS [DB],
  ISNULL(@lb2-@lb1,0) AS [LogBytesPerSec],
  CAST(ISNULL(@lb2-@lb1,0)/1048576.0 AS DECIMAL(18,2)) AS [LogMBPerSec],
  ISNULL(@lf2-@lf1,0) AS [LogFlushesPerSec],
  CASE
   WHEN ISNULL(@lb2-@lb1,0)>=52428800 THEN 'CRITICAL'
   WHEN ISNULL(@lb2-@lb1,0)>=10485760 THEN 'WARNING'
   ELSE 'OK'
  END AS [Sev];
END TRY
BEGIN CATCH
 SELECT 'LOG_RATE' AS [C],DB_NAME() AS [DB],
        'N/A' AS [LogBytesPerSec],ERROR_MESSAGE() AS [Note],@N AS [AsOf];
END CATCH;
/* 3a) Active HADR/log waits on in-flight requests */
SELECT TOP({{TopN}})
 'ACTIVE_HA_LOG_WAIT' AS [C],
 r.session_id AS [SPID],
 DB_NAME(r.database_id) AS [DB],
 r.wait_type AS [WaitType],
 r.wait_time AS [WaitMs],
 r.blocking_session_id AS [BlockBy],
 r.total_elapsed_time/1000 AS [DurSec],
 CASE
  WHEN r.wait_type LIKE 'HADR%' THEN 'HADR'
  WHEN r.wait_type LIKE 'PARALLEL_REDO%' THEN 'HADR_REDO'
  ELSE 'LOG_IO'
 END AS [WaitClass]
FROM sys.dm_exec_requests r
WHERE r.session_id<>@@SPID
 AND r.wait_type IS NOT NULL
 AND (r.wait_type LIKE 'HADR%' OR r.wait_type LIKE 'PARALLEL_REDO%' OR r.wait_type IN(SELECT wt FROM @lw))
 AND r.wait_type NOT IN(SELECT wt FROM @bw)
 AND (@DB IS NULL OR DB_NAME(r.database_id)=@DB)
ORDER BY r.wait_time DESC
 OPTION (MAXDOP 1);
/* 3b) Cumulative HADR/log wait stats */
BEGIN TRY
 ;WITH W AS
 (
  SELECT wait_type,waiting_tasks_count,wait_time_ms,signal_wait_time_ms,
         wait_time_ms-signal_wait_time_ms AS resource_wait_ms
  FROM sys.dm_os_wait_stats
  WHERE (wait_type LIKE 'HADR%' OR wait_type LIKE 'PARALLEL_REDO%' OR wait_type IN(SELECT wt FROM @lw))
     AND wait_type NOT IN(SELECT wt FROM @bw)
 ),
 T AS (SELECT SUM(wait_time_ms) AS total_wait_ms FROM W)
 SELECT TOP({{TopN}})
  'WAIT_STATS_HA_LOG' AS [C],
  w.wait_type AS [WaitType],
  w.waiting_tasks_count AS [Tasks],
  w.wait_time_ms AS [WaitMs],
  w.resource_wait_ms AS [ResourceWaitMs],
  w.signal_wait_time_ms AS [SignalWaitMs],
  CASE WHEN w.waiting_tasks_count>0
       THEN CAST(w.wait_time_ms*1.0/w.waiting_tasks_count AS DECIMAL(18,1)) ELSE 0 END AS [AvgWaitMs],
  CAST(100.0*w.wait_time_ms/NULLIF(t.total_wait_ms,0) AS DECIMAL(6,2)) AS [PctInHaLogWaits],
  CASE
   WHEN w.wait_type LIKE 'HADR%' AND w.waiting_tasks_count>0 AND (w.wait_time_ms*1.0/w.waiting_tasks_count)>=5000 THEN 'CRITICAL'
   WHEN w.waiting_tasks_count>0 AND (w.wait_time_ms*1.0/w.waiting_tasks_count)>=1000 THEN 'WARNING'
   ELSE 'INFO'
  END AS [Sev]
 FROM W w CROSS JOIN T t
 WHERE w.waiting_tasks_count>0
 ORDER BY w.wait_time_ms DESC
  OPTION (MAXDOP 1);
END TRY
BEGIN CATCH
 SELECT 'WAIT_STATS_HA_LOG' AS [C],'N/A' AS [WaitType],
        ERROR_NUMBER() AS [ErrNo],ERROR_MESSAGE() AS [ErrMsg],
        'VIEW SERVER STATE or VIEW SERVER PERFORMANCE STATE may be required' AS [Note],@N AS [AsOf];
END CATCH;
/* Roll-up readiness signal */
;WITH F AS
(
 SELECT
  (SELECT COUNT(*) FROM sys.dm_tran_database_transactions dt
   WHERE DATEDIFF(SECOND,dt.database_transaction_begin_time,@N)>=30
     AND DB_NAME(dt.database_id) NOT IN('master','model','msdb','tempdb')
     AND (@DB IS NULL OR DB_NAME(dt.database_id)=@DB)) AS LongTxn,
  (SELECT CAST(MAX(dt.database_transaction_log_bytes_used)/1048576.0 AS DECIMAL(18,1))
   FROM sys.dm_tran_database_transactions dt
   WHERE (@DB IS NULL OR DB_NAME(dt.database_id)=@DB)) AS MaxTxnLogMB,
  (SELECT COUNT(*) FROM sys.dm_exec_requests r
   WHERE r.session_id<>@@SPID AND r.wait_type IS NOT NULL
     AND (r.wait_type LIKE 'HADR%' OR r.wait_type LIKE 'PARALLEL_REDO%' OR r.wait_type IN(SELECT wt FROM @lw))
     AND r.wait_type NOT IN(SELECT wt FROM @bw)
     AND (@DB IS NULL OR DB_NAME(r.database_id)=@DB)) AS ActiveHaLogWaiters,
  (SELECT CAST(used_log_space_in_percent AS DECIMAL(5,2)) FROM sys.dm_db_log_space_usage) AS LogUsedPct
)
SELECT 'SUMMARY' AS [C],LongTxn,MaxTxnLogMB,ActiveHaLogWaiters,LogUsedPct,
 CASE
  WHEN LongTxn>0 AND ActiveHaLogWaiters>0 THEN 'NOT_READY'
  WHEN LogUsedPct>=85 OR ISNULL(MaxTxnLogMB,0)>=1024 THEN 'CAUTION'
  ELSE 'READY'
 END AS [Readiness]
FROM F
 OPTION (MAXDOP 1);
```
---

### GetMaintenanceAndScalingEvents

> Detects instance restarts, scaling/SLO operations, and maintenance events within the `{{LookbackHours}}` window.

```sql
SET NOCOUNT ON;
DECLARE @E INT=CAST(SERVERPROPERTY('EngineEdition')AS INT),@N DATETIME2(3)=SYSDATETIME(),@DB NVARCHAR(128)=NULLIF(N'{{DatabaseName}}',''),@LB INT={{LookbackHours}};
IF @E IN(6,9,11) BEGIN SELECT 'UNSUPPORTED' AS [P],'EngineEdition '+CAST(@E AS VARCHAR)+' not supported' AS [Note],@N AS [AsOf]; RETURN; END;
/* Engine start time; on MI/DB also changes on transparent failovers */
IF @E IN(1,2,3,4,5,8)
 SELECT 'INSTANCE_RESTART' AS [C],
  CASE @E WHEN 5 THEN 'AZURE_SQL_DB' WHEN 8 THEN 'SQL_MI' ELSE 'SQL_SERVER' END AS [P],
  si.sqlserver_start_time AS [LastStart],
  DATEDIFF(MINUTE,si.sqlserver_start_time,SYSDATETIME()) AS [UptimeMin],
  CASE WHEN DATEDIFF(HOUR,si.sqlserver_start_time,SYSDATETIME())<=@LB THEN 'YES' ELSE 'NO' END AS [RestartedInWindow],
  CASE WHEN DATEDIFF(HOUR,si.sqlserver_start_time,SYSDATETIME())<=@LB THEN 'WARNING' ELSE 'OK' END AS [Sev]
 FROM sys.dm_os_sys_info si
  OPTION (MAXDOP 1);
/* Azure SQL DB: scaling/SLO ops (master only) + current SLO */
IF @E=5
BEGIN
 IF OBJECT_ID('sys.dm_operation_status','V') IS NOT NULL
  EXEC sp_executesql N'SELECT TOP({{TopN}}) ''SCALING_OP'' AS [C],os.major_resource_id AS [DB],os.operation AS [Op],
    os.state_desc AS [State],os.percent_complete AS [Pct],os.start_time AS [Start],os.last_modify_time AS [Modified],
    CASE WHEN os.error_code<>0 THEN os.error_desc ELSE ''OK'' END AS [Detail],
    CASE WHEN os.state_desc IN(''FAILED'',''CANCELLED'') THEN ''CRITICAL''
         WHEN os.state_desc IN(''IN_PROGRESS'',''PENDING'') THEN ''WARNING'' ELSE ''OK'' END AS [Sev]
   FROM sys.dm_operation_status os
   WHERE os.resource_type=0 AND os.operation LIKE ''ALTER%''
   ORDER BY os.start_time DESC OPTION (MAXDOP 1)';
 SELECT TOP({{TopN}}) 'CURRENT_SLO' AS [C],d.name AS [DB],dso.edition AS [Edition],
  dso.service_objective AS [SLO],dso.elastic_pool_name AS [Pool]
 FROM sys.database_service_objectives dso
 JOIN sys.databases d ON d.database_id=dso.database_id
 WHERE d.name NOT IN('master','model','msdb','tempdb') AND (@DB IS NULL OR d.name=@DB)
 ORDER BY d.name
  OPTION (MAXDOP 1);
 RETURN;
END;
/* SQL Server/MI: error-log maintenance signals */
IF @E IN(1,2,3,4,8)
BEGIN
 CREATE TABLE #ML(LogDate DATETIME,ProcessInfo NVARCHAR(100),[Text] NVARCHAR(MAX));
 DECLARE @rdproc NVARCHAR(128);
 IF @E=8
 BEGIN
  SET @rdproc=N'sys.sp_readerrorlog';
  BEGIN TRY
   CREATE TABLE #probe(LogDate DATETIME,ProcessInfo NVARCHAR(100),[Text] NVARCHAR(MAX));
   INSERT INTO #probe EXEC sys.sp_readmierrorlog 0,1,N'__probe__',NULL;
   SET @rdproc=N'sys.sp_readmierrorlog';
   DROP TABLE #probe;
  END TRY BEGIN CATCH IF OBJECT_ID('tempdb..#probe') IS NOT NULL DROP TABLE #probe; END CATCH;
 END
 ELSE SET @rdproc=N'sys.xp_readerrorlog';
 BEGIN TRY
  INSERT INTO #ML EXEC @rdproc 0,1,N'starting',NULL;
  INSERT INTO #ML EXEC @rdproc 0,1,N'Recovery is complete',NULL;
  INSERT INTO #ML EXEC @rdproc 0,1,N'reconfigure',NULL;
  INSERT INTO #ML EXEC @rdproc 0,1,N'configuration option',NULL;
 END TRY BEGIN CATCH INSERT INTO #ML VALUES(@N,'ERR',ERROR_MESSAGE()); END CATCH;
 /* Events within LookbackHours; startup banner excluded */
 SELECT DISTINCT TOP({{TopN}}) 'MAINT_EVENT' AS [C],ml.LogDate AS [EventTime],ml.[Text] AS [Detail],
  CASE WHEN ml.[Text] LIKE '%is starting%' THEN 'RESTART'
   WHEN ml.[Text] LIKE '%Recovery is complete%' THEN 'RECOVERY_DONE'
   WHEN ml.[Text] LIKE '%reconfigure%' OR ml.[Text] LIKE '%configuration option%' THEN 'CONFIG_CHANGE'
   ELSE 'OTHER' END AS [EventType]
 FROM #ML ml
 WHERE ml.[Text] IS NOT NULL AND LEN(ml.[Text])>0
   AND ml.LogDate >= DATEADD(HOUR,-@LB,SYSDATETIME())
   AND ml.[Text] NOT LIKE '%show advanced options%'
   AND ml.[Text] NOT LIKE '%Agent XPs%'
 ORDER BY ml.LogDate DESC;
 DROP TABLE #ML;
 RETURN;
END;
SELECT CASE @E WHEN 12 THEN 'FABRIC' ELSE 'UNKNOWN' END AS [P],'MANAGED' AS [C],
 'Platform-managed; maintenance/scaling not exposed via T-SQL' AS [Note],@N AS [AsOf];
```
---

### GetReplicationBottleneckAnalysis

> Identifies geo-rep lag, send/redo queue bottlenecks, and HADR sync issues. Uses `SYSUTCDATETIME()` for UTC `last_replication` comparisons.

```sql
SET NOCOUNT ON;
DECLARE @E INT=CAST(SERVERPROPERTY('EngineEdition')AS INT),@N DATETIME2(3)=SYSDATETIME(),@DB NVARCHAR(128)=NULLIF(N'{{DatabaseName}}','');
IF @E IN(6,9,11) BEGIN SELECT 'UNSUPPORTED' AS [P],'EngineEdition '+CAST(@E AS VARCHAR)+' not supported' AS [Note],@N AS [AsOf]; RETURN; END;
IF @E=5
BEGIN
 IF DB_NAME()='master'
  SELECT 'AZURE_SQL_DB' AS [P],'master' AS [DB],'Run this query in a user database; sys.dm_geo_replication_link_status is not available in master' AS [Bottleneck],@N AS [AsOf];
 ELSE
  SELECT 'AZURE_SQL_DB' AS [P],DB_NAME() AS [DB],gl.partner_server AS [Partner],
   gl.replication_lag_sec AS [LagSec],gl.last_replication AS [LastRepl],
   DATEDIFF(SECOND,gl.last_replication,SYSUTCDATETIME()) AS [SecSinceRepl],
   CASE WHEN gl.replication_state_desc='SUSPENDED' THEN 'LINK_DOWN'
    WHEN DATEDIFF(SECOND,gl.last_replication,SYSUTCDATETIME())>120 THEN 'STALLED'
    WHEN ISNULL(gl.replication_lag_sec,0)>60 THEN 'HIGH_WORKLOAD' ELSE 'HEALTHY' END AS [Bottleneck]
  FROM sys.dm_geo_replication_link_status gl
   OPTION (MAXDOP 1);
 RETURN;
END;
IF @E IN(1,2,3,4,8) AND EXISTS(SELECT 1 FROM sys.dm_hadr_database_replica_states)
BEGIN
 /* secondary_lag_seconds: SQL 2016 SP2+; NULL on older builds */
 DECLARE @lag NVARCHAR(64)=CASE WHEN COL_LENGTH('sys.dm_hadr_database_replica_states','secondary_lag_seconds') IS NOT NULL THEN N'drs.secondary_lag_seconds' ELSE N'CAST(NULL AS BIGINT)' END;
 /* do NOT filter is_local=1: send/redo populate on is_local=0 rows */
 DECLARE @sql NVARCHAR(MAX)=N'
 SELECT TOP({{TopN}}) CASE @E WHEN 8 THEN ''SQL_MI'' ELSE ''SQL_SERVER'' END AS [P],
  DB_NAME(drs.database_id) AS [DB],
  CASE WHEN drs.is_primary_replica=1 THEN ''PRIMARY'' ELSE ''SECONDARY'' END AS [ReplicaRole],
  drs.is_local AS [IsLocal],drs.synchronization_state_desc AS [SyncState],
  drs.log_send_queue_size AS [SendQKB],drs.log_send_rate AS [SendRate],
  drs.redo_queue_size AS [RedoQKB],drs.redo_rate AS [RedoRate],'+@lag+N' AS [LagSec],
  CASE WHEN drs.log_send_rate>0 THEN CAST(CAST(drs.log_send_queue_size AS DECIMAL(18,1))/drs.log_send_rate AS DECIMAL(18,1)) ELSE NULL END AS [SendDrainSec],
  CASE WHEN drs.redo_rate>0 THEN CAST(CAST(drs.redo_queue_size AS DECIMAL(18,1))/drs.redo_rate AS DECIMAL(18,1)) ELSE NULL END AS [RedoDrainSec],
  CASE WHEN drs.synchronization_state_desc=''NOT SYNCHRONIZING'' THEN ''TRANSPORT_DOWN''
   WHEN drs.log_send_queue_size>102400 AND drs.redo_queue_size<=10240 THEN ''SEND_BOTTLENECK''
   WHEN drs.redo_queue_size>102400 AND drs.log_send_queue_size<=10240 THEN ''REDO_BOTTLENECK''
   WHEN drs.log_send_queue_size>102400 AND drs.redo_queue_size>102400 THEN ''BOTH_BOTTLENECK''
   WHEN ISNULL(drs.log_send_rate,0)=0 AND drs.log_send_queue_size>0 THEN ''SEND_STALLED''
   WHEN ISNULL(drs.redo_rate,0)=0 AND drs.redo_queue_size>0 THEN ''REDO_STALLED''
   WHEN ISNULL('+@lag+N',0)>30 THEN ''LOG_BURST'' ELSE ''HEALTHY'' END AS [Bottleneck]
 FROM sys.dm_hadr_database_replica_states drs
 WHERE DB_NAME(drs.database_id) NOT IN(''master'',''model'',''msdb'',''tempdb'') AND (@DB IS NULL OR DB_NAME(drs.database_id)=@DB)
 ORDER BY ISNULL('+@lag+N',0) DESC,drs.is_primary_replica
  OPTION (MAXDOP 1);';
 EXEC sp_executesql @sql,N'@E INT,@DB NVARCHAR(128)',@E=@E,@DB=@DB;
END;
ELSE IF @E IN(1,2,3,4,8)
 SELECT CASE @E WHEN 8 THEN 'SQL_MI' ELSE 'SQL_SERVER' END AS [P],'NOT_CONFIGURED' AS [Bottleneck],'No AG/HADR data' AS [Note],@N AS [AsOf];
IF @E NOT IN(5,1,2,3,4,8)
 SELECT CASE @E WHEN 12 THEN 'FABRIC' ELSE 'UNKNOWN' END AS [P],'MANAGED' AS [Bottleneck],'Platform-managed' AS [Note],@N AS [AsOf];
```
---

### GetFailoverHistory

> Shows recent failover events, role transitions, and forced failover entries from error log and geo-rep link status.

```sql
SET NOCOUNT ON;
DECLARE @E INT=CAST(SERVERPROPERTY('EngineEdition')AS INT),@N DATETIME2(3)=SYSDATETIME();
IF @E IN(6,9,11) BEGIN SELECT 'UNSUPPORTED' AS [P],'EngineEdition '+CAST(@E AS VARCHAR)+' not supported' AS [Note],@N AS [AsOf]; RETURN; END;
IF @E=5
BEGIN
 IF DB_NAME()='master'
  SELECT TOP({{TopN}}) DB_NAME() AS [DB],gl.partner_server AS [Partner],
   gl.role_desc+' ('+gl.replication_state_desc+')' AS [State],
   gl.modify_date AS [LastChanged],DATEDIFF(MINUTE,gl.modify_date,@N) AS [MinAgo]
  FROM sys.geo_replication_links gl
   OPTION (MAXDOP 1);
 ELSE
  SELECT TOP({{TopN}}) DB_NAME() AS [DB],gl.partner_server AS [Partner],
   gl.role_desc+' ('+gl.replication_state_desc+')' AS [State],
   gl.last_replication AS [LastChanged],DATEDIFF(MINUTE,gl.last_replication,SYSUTCDATETIME()) AS [MinAgo]
  FROM sys.dm_geo_replication_link_status gl
   OPTION (MAXDOP 1);
 IF OBJECT_ID('sys.dm_operation_status','V') IS NOT NULL
  EXEC sp_executesql N'SELECT TOP 10 os.operation AS [Op],os.state_desc AS [Result],os.start_time AS [Time],
   CASE WHEN os.error_code!=0 THEN os.error_desc ELSE ''OK'' END AS [Detail]
  FROM sys.dm_operation_status os
  WHERE os.resource_type=0 AND os.operation IN(''FAILOVER'',''FORCE_FAILOVER_ALLOW_DATA_LOSS'')
  ORDER BY os.start_time DESC OPTION (MAXDOP 1)';
 RETURN;
END;
IF @E IN(1,2,3,4,8)
BEGIN
 CREATE TABLE #EL(LogDate DATETIME,ProcessInfo NVARCHAR(100),[Text] NVARCHAR(MAX));
 DECLARE @rdproc NVARCHAR(128);
 IF @E=8
 BEGIN
  SET @rdproc=N'sys.sp_readerrorlog';
  BEGIN TRY
   CREATE TABLE #probe(LogDate DATETIME,ProcessInfo NVARCHAR(100),[Text] NVARCHAR(MAX));
   INSERT INTO #probe EXEC sys.sp_readmierrorlog 0,1,N'__probe__',NULL;
   SET @rdproc=N'sys.sp_readmierrorlog';
   DROP TABLE #probe;
  END TRY BEGIN CATCH IF OBJECT_ID('tempdb..#probe') IS NOT NULL DROP TABLE #probe; END CATCH;
 END
 ELSE SET @rdproc=N'sys.xp_readerrorlog';
 BEGIN TRY
  INSERT INTO #EL EXEC @rdproc 0,1,N'availability',N'changed';
  INSERT INTO #EL EXEC @rdproc 0,1,N'failover',NULL;
  INSERT INTO #EL EXEC @rdproc 0,1,N'HADR',NULL;
  INSERT INTO #EL EXEC @rdproc 0,1,N'data movement',NULL;
 END TRY BEGIN CATCH INSERT INTO #EL VALUES(@N,'ERR',ERROR_MESSAGE()); END CATCH;
 SELECT DISTINCT TOP({{TopN}}) LogDate,[Text],
  CASE WHEN [Text] LIKE '%PRIMARY%to%SECONDARY%' THEN 'LOST_PRIMARY'
   WHEN [Text] LIKE '%SECONDARY%to%PRIMARY%' THEN 'BECAME_PRIMARY'
   WHEN [Text] LIKE '%RESOLVING%to%PRIMARY%' THEN 'FORCED_FAILOVER'
   WHEN [Text] LIKE '%data movement%started%' THEN 'REPL_RESUMED'
   WHEN [Text] LIKE '%data movement%suspended%' THEN 'REPL_SUSPENDED'
   WHEN [Text] LIKE '%failover%' THEN 'FAILOVER_EVENT' ELSE 'STATE_CHANGE' END AS [EventType]
 FROM #EL WHERE [Text] IS NOT NULL AND LEN([Text])>0 ORDER BY LogDate DESC;
 DROP TABLE #EL;
 RETURN;
END;
SELECT CASE @E WHEN 12 THEN 'FABRIC' ELSE 'UNKNOWN' END AS [P],'Platform-managed' AS [Note],@N AS [AsOf];
```


---

### GetSplitBrainDetection

> Checks replica roles, sync health, suspended state, quorum status, and forced failover history to detect split-brain or suspect databases.

```sql
SET NOCOUNT ON;
DECLARE @E INT=CAST(SERVERPROPERTY('EngineEdition')AS INT),@N DATETIME2(3)=SYSDATETIME(),@DB NVARCHAR(128)=NULLIF(N'{{DatabaseName}}','');
IF @E IN(6,9,11) BEGIN SELECT 'UNSUPPORTED' AS [P],'EngineEdition '+CAST(@E AS VARCHAR)+' not supported' AS [Note],@N AS [AsOf]; RETURN; END;
IF @E=5
BEGIN
 IF DB_NAME()='master'
  SELECT 'AZURE_SQL_DB' AS [P],'master' AS [DB],'Run this query in a user database; sys.dm_geo_replication_link_status is not available in master' AS [Risk],@N AS [AsOf];
 ELSE
  SELECT 'AZURE_SQL_DB' AS [P],DB_NAME() AS [DB],gl.role_desc AS [Role],gl.partner_server AS [Partner],
   gl.replication_state_desc AS [ReplState],
   CASE WHEN gl.role_desc='PRIMARY' AND gl.replication_state_desc='SUSPENDED' THEN 'WARNING' ELSE 'OK' END AS [Risk]
  FROM sys.dm_geo_replication_link_status gl
   OPTION (MAXDOP 1);
 RETURN;
END;
IF @E IN(1,2,3,4,8)
BEGIN
 IF EXISTS(SELECT 1 FROM sys.dm_hadr_database_replica_states)
  SELECT TOP({{TopN}}) CASE @E WHEN 8 THEN 'SQL_MI' ELSE 'SQL_SERVER' END AS [P],
   DB_NAME(drs.database_id) AS [DB],
   CASE WHEN drs.is_primary_replica=1 THEN 'PRIMARY' ELSE 'SECONDARY' END AS [Role],
   drs.is_local AS [IsLocal],
   drs.synchronization_state_desc AS [SyncState],drs.synchronization_health_desc AS [SyncHealth],
   drs.is_suspended AS [IsSuspended],
   CASE WHEN drs.is_primary_replica=1 AND drs.synchronization_state_desc='NOT SYNCHRONIZING'
     AND drs.synchronization_health_desc='NOT_HEALTHY' THEN 'HIGH_RISK'
    WHEN drs.is_suspended=1 THEN 'WARNING' ELSE 'OK' END AS [Risk]
  FROM sys.dm_hadr_database_replica_states drs
  WHERE DB_NAME(drs.database_id) NOT IN('master','model','msdb','tempdb') AND (@DB IS NULL OR DB_NAME(drs.database_id)=@DB)
  ORDER BY CASE WHEN drs.synchronization_health_desc='NOT_HEALTHY' THEN 0 ELSE 1 END,drs.is_primary_replica DESC
   OPTION (MAXDOP 1);
 SELECT TOP({{TopN}}) d.name AS [DB],d.state_desc AS [State],
  CASE d.state_desc WHEN 'SUSPECT' THEN 'CRITICAL' WHEN 'EMERGENCY' THEN 'CRITICAL'
   WHEN 'RECOVERY_PENDING' THEN 'WARNING' ELSE 'INFO' END AS [Sev]
 FROM sys.databases d WHERE d.state_desc IN('SUSPECT','RECOVERY_PENDING','EMERGENCY') AND d.database_id>4
  OPTION (MAXDOP 1);
 IF @E IN(1,2,3,4) AND OBJECT_ID('sys.dm_hadr_cluster','V') IS NOT NULL
  SELECT c.cluster_name AS [Cluster],c.quorum_state_desc AS [QuorumState],
   CASE c.quorum_state_desc WHEN 'FORCED_QUORUM' THEN 'HIGH_RISK' ELSE 'OK' END AS [Risk]
  FROM sys.dm_hadr_cluster c
   OPTION (MAXDOP 1);
 IF @E IN(1,2,3,4)
 BEGIN
  CREATE TABLE #SB(LogDate DATETIME,ProcessInfo NVARCHAR(100),[Text] NVARCHAR(MAX));
  BEGIN TRY
   INSERT INTO #SB EXEC xp_readerrorlog 0,1,N'FORCE_FAILOVER_ALLOW_DATA_LOSS',NULL;
   INSERT INTO #SB EXEC xp_readerrorlog 0,1,N'forced quorum',NULL;
  END TRY BEGIN CATCH INSERT INTO #SB VALUES(@N,'ERR',ERROR_MESSAGE()); END CATCH;
  SELECT DISTINCT TOP({{TopN}}) LogDate,[Text] FROM #SB WHERE [Text] IS NOT NULL ORDER BY LogDate DESC;
  DROP TABLE #SB;
 END;
END;
IF @E NOT IN(5,1,2,3,4,8)
 SELECT CASE @E WHEN 12 THEN 'FABRIC' ELSE 'UNKNOWN' END AS [P],'Platform-managed' AS [Note],@N AS [AsOf];
```
---

### GetResourcePressure

> Measures CPU, IO, memory, scheduler, and signal-wait pressure. **Contains two 1-second `WAITFOR DELAY` snapshots**.

```sql
SET NOCOUNT ON;
DECLARE @E INT=CAST(SERVERPROPERTY('EngineEdition')AS INT),@N DATETIME2(3)=SYSDATETIME();
IF @E IN(6,9,11) BEGIN SELECT 'UNSUPPORTED' AS [P],'EngineEdition '+CAST(@E AS VARCHAR)+' not supported' AS [Note],@N AS [AsOf]; RETURN; END;
/* 1) Azure SQL DB only: governed CPU+IO+memory util (~5 min, 15s samples) */
IF @E=5
 SELECT TOP({{TopN}}) 'RESOURCE_UTIL' AS [C],
  'AZURE_SQL_DB' AS [P],
  rs.end_time AS [Sample],
  rs.avg_cpu_percent AS [CPUPct],
  rs.avg_data_io_percent AS [DataIOPct],
  rs.avg_log_write_percent AS [LogWritePct],
  rs.avg_memory_usage_percent AS [MemPct],
  CASE WHEN rs.avg_cpu_percent>=90 OR rs.avg_data_io_percent>=90 OR rs.avg_log_write_percent>=90 OR rs.avg_memory_usage_percent>=95 THEN 'CRITICAL'
   WHEN rs.avg_cpu_percent>=75 OR rs.avg_data_io_percent>=75 OR rs.avg_log_write_percent>=75 OR rs.avg_memory_usage_percent>=85 THEN 'WARNING' ELSE 'OK' END AS [Sev]
 FROM sys.dm_db_resource_stats rs
 ORDER BY rs.end_time DESC
  OPTION (MAXDOP 1);
/* 1b) MI only: instance-level (all DBs) CPU/IO/storage util, ~14-day history */
IF @E=8
 SELECT TOP({{TopN}}) 'INSTANCE_UTIL' AS [C],'SQL_MI' AS [P],
  srs.end_time AS [Sample],
  srs.avg_cpu_percent AS [CPUPct],
  srs.virtual_core_count AS [vCores],
  srs.io_requests AS [IORequests],
  srs.storage_space_used_mb AS [StorageUsedMB],
  srs.reserved_storage_mb AS [StorageReservedMB],
  srs.sku AS [SKU],
  CASE WHEN srs.avg_cpu_percent>=90 THEN 'CRITICAL' WHEN srs.avg_cpu_percent>=80 THEN 'WARNING' ELSE 'OK' END AS [Sev]
 FROM sys.server_resource_stats srs
 ORDER BY srs.end_time DESC
  OPTION (MAXDOP 1);
/* 2) SQL Server: host CPU from scheduler-monitor ring buffer + system memory */
IF @E IN(1,2,3,4)
BEGIN
 DECLARE @ms BIGINT=(SELECT ms_ticks FROM sys.dm_os_sys_info);
 SELECT TOP(1) 'CPU_RINGBUFFER' AS [C],'SQL_SERVER' AS [P],
  DATEADD(ms,-1*(@ms-rb.[timestamp]),@N) AS [Sample],
  rb.SQLProcessUtilization AS [SQLCPUPct],
  rb.SystemIdle AS [IdlePct],
  100-rb.SystemIdle-rb.SQLProcessUtilization AS [OtherCPUPct],
  CASE WHEN rb.SQLProcessUtilization>=90 OR (100-rb.SystemIdle)>=95 THEN 'CRITICAL'
   WHEN rb.SQLProcessUtilization>=75 OR (100-rb.SystemIdle)>=85 THEN 'WARNING' ELSE 'OK' END AS [Sev]
 FROM (
  SELECT x.[timestamp],
   x.record.value('(./Record/SchedulerMonitorEvent/SystemHealth/SystemIdle)[1]','int') AS SystemIdle,
   x.record.value('(./Record/SchedulerMonitorEvent/SystemHealth/ProcessUtilization)[1]','int') AS SQLProcessUtilization
  FROM (SELECT rb2.[timestamp],CONVERT(XML,rb2.record) AS record
        FROM sys.dm_os_ring_buffers rb2
        WHERE rb2.ring_buffer_type=N'RING_BUFFER_SCHEDULER_MONITOR' AND rb2.record LIKE '%<SystemHealth>%') x
 ) rb
 ORDER BY rb.[timestamp] DESC
  OPTION (MAXDOP 1);
 SELECT 'SYS_MEMORY' AS [C],'SQL_SERVER' AS [P],
  sm.total_physical_memory_kb/1024 AS [PhysMemMB],
  sm.available_physical_memory_kb/1024 AS [AvailMemMB],
  sm.system_memory_state_desc AS [MemState],
  CASE WHEN sm.system_memory_state_desc LIKE '%low%' THEN 'CRITICAL' ELSE 'OK' END AS [Sev]
 FROM sys.dm_os_sys_memory sm
  OPTION (MAXDOP 1);
END;
/* 3) Memory pressure: PLE, pending grants, RESOURCE_SEMAPHORE wait */
IF @E IN(1,2,3,4,5,8)
BEGIN
 DECLARE @ple BIGINT=(SELECT MAX(cntr_value) FROM sys.dm_os_performance_counters WHERE counter_name LIKE N'Page life expectancy%' AND object_name LIKE N'%Buffer Manager%');
 DECLARE @gp BIGINT=(SELECT MAX(cntr_value) FROM sys.dm_os_performance_counters WHERE counter_name LIKE N'Memory Grants Pending%');
 /* RESOURCE_SEMAPHORE: 1s delta for current pressure */
 DECLARE @rsw0 BIGINT=(SELECT ISNULL(SUM(w.wait_time_ms),0) FROM sys.dm_os_wait_stats w WHERE w.wait_type IN(N'RESOURCE_SEMAPHORE',N'RESOURCE_SEMAPHORE_QUERY_COMPILE'));
 WAITFOR DELAY '00:00:01';
 DECLARE @rsw BIGINT=(SELECT ISNULL(SUM(w.wait_time_ms),0) FROM sys.dm_os_wait_stats w WHERE w.wait_type IN(N'RESOURCE_SEMAPHORE',N'RESOURCE_SEMAPHORE_QUERY_COMPILE'))-@rsw0;
 SELECT 'MEMORY_PRESSURE' AS [C],
  @ple AS [PLE_Sec],
  @gp AS [GrantsPending],
  (SELECT COUNT(*) FROM sys.dm_exec_query_memory_grants WHERE grant_time IS NULL) AS [WaitingForGrant],
  @rsw AS [ResSemWaitMsPerSec],
  CASE WHEN ISNULL(@gp,0)>0 OR (SELECT COUNT(*) FROM sys.dm_exec_query_memory_grants WHERE grant_time IS NULL)>0 THEN 'CRITICAL'
   WHEN ISNULL(@ple,999999)<300 OR ISNULL(@rsw,0)>0 THEN 'WARNING' ELSE 'OK' END AS [Sev]
  OPTION (MAXDOP 1);
 /* 4) IO latency by file - 1s delta so AvgRead/Write reflect CURRENT IO */
 DECLARE @io0 TABLE(database_id INT,file_id INT,num_reads BIGINT,io_stall_read BIGINT,num_writes BIGINT,io_stall_write BIGINT);
 INSERT INTO @io0(database_id,file_id,num_reads,io_stall_read,num_writes,io_stall_write)
  SELECT database_id,file_id,num_of_reads,io_stall_read_ms,num_of_writes,io_stall_write_ms FROM sys.dm_io_virtual_file_stats(NULL,NULL);
 WAITFOR DELAY '00:00:01';
 SELECT TOP({{TopN}}) 'IO_LATENCY' AS [C],
  DB_NAME(vfs.database_id) AS [DB],
  mf.type_desc AS [FileType],
  CASE WHEN vfs.num_of_reads-i.num_reads=0 THEN 0 ELSE (vfs.io_stall_read_ms-i.io_stall_read)/(vfs.num_of_reads-i.num_reads) END AS [AvgReadMs],
  CASE WHEN vfs.num_of_writes-i.num_writes=0 THEN 0 ELSE (vfs.io_stall_write_ms-i.io_stall_write)/(vfs.num_of_writes-i.num_writes) END AS [AvgWriteMs],
  vfs.num_of_reads-i.num_reads AS [Reads],vfs.num_of_writes-i.num_writes AS [Writes],
  CASE WHEN (CASE WHEN vfs.num_of_reads-i.num_reads=0 THEN 0 ELSE (vfs.io_stall_read_ms-i.io_stall_read)/(vfs.num_of_reads-i.num_reads) END)>=50
        OR (CASE WHEN vfs.num_of_writes-i.num_writes=0 THEN 0 ELSE (vfs.io_stall_write_ms-i.io_stall_write)/(vfs.num_of_writes-i.num_writes) END)>=50 THEN 'CRITICAL'
   WHEN (CASE WHEN vfs.num_of_reads-i.num_reads=0 THEN 0 ELSE (vfs.io_stall_read_ms-i.io_stall_read)/(vfs.num_of_reads-i.num_reads) END)>=20
        OR (CASE WHEN vfs.num_of_writes-i.num_writes=0 THEN 0 ELSE (vfs.io_stall_write_ms-i.io_stall_write)/(vfs.num_of_writes-i.num_writes) END)>=20 THEN 'WARNING' ELSE 'OK' END AS [Sev]
 FROM sys.dm_io_virtual_file_stats(NULL,NULL) vfs
 JOIN @io0 i ON i.database_id=vfs.database_id AND i.file_id=vfs.file_id
 LEFT JOIN sys.master_files mf ON mf.database_id=vfs.database_id AND mf.file_id=vfs.file_id
 WHERE (vfs.num_of_reads-i.num_reads)+(vfs.num_of_writes-i.num_writes)>0
 ORDER BY ((vfs.io_stall_read_ms-i.io_stall_read)+(vfs.io_stall_write_ms-i.io_stall_write)) DESC
  OPTION (MAXDOP 1);
 /* 5) Scheduler/worker pressure + signal-wait CPU ratio */
 SELECT 'SCHEDULER_PRESSURE' AS [C],
  (SELECT AVG(CAST(s.runnable_tasks_count AS DECIMAL(10,2))) FROM sys.dm_os_schedulers s WHERE s.scheduler_id<255 AND s.status='VISIBLE ONLINE') AS [AvgRunnable],
  (SELECT SUM(s.work_queue_count) FROM sys.dm_os_schedulers s WHERE s.scheduler_id<255 AND s.status='VISIBLE ONLINE') AS [WorkQueue],
  (SELECT MAX(s.active_workers_count) FROM sys.dm_os_schedulers s WHERE s.scheduler_id<255 AND s.status='VISIBLE ONLINE') AS [MaxActiveWorkers],
  CAST(100.0*(SELECT SUM(w.signal_wait_time_ms) FROM sys.dm_os_wait_stats w)/NULLIF((SELECT SUM(w.wait_time_ms) FROM sys.dm_os_wait_stats w),0) AS DECIMAL(5,2)) AS [SignalWaitPct],
  CASE WHEN (SELECT AVG(CAST(s.runnable_tasks_count AS DECIMAL(10,2))) FROM sys.dm_os_schedulers s WHERE s.scheduler_id<255 AND s.status='VISIBLE ONLINE')>=5 THEN 'CRITICAL'
   WHEN (SELECT AVG(CAST(s.runnable_tasks_count AS DECIMAL(10,2))) FROM sys.dm_os_schedulers s WHERE s.scheduler_id<255 AND s.status='VISIBLE ONLINE')>=2 THEN 'WARNING' ELSE 'OK' END AS [Sev]
  OPTION (MAXDOP 1);
END;
IF @E NOT IN(1,2,3,4,5,8)
 SELECT CASE @E WHEN 12 THEN 'FABRIC' ELSE 'UNKNOWN' END AS [P],'MANAGED' AS [C],'Platform-managed' AS [Note],@N AS [AsOf];
```
