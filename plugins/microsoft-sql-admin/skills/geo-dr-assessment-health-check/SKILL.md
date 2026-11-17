---
name: geo-dr-assessment-health-check
description: "Use when the user asks whether geo-replication or a failover group is healthy and ready for a planned failover (GO/NO_GO), or what the geo-DR RPO/RTO is. For lag happening now, use `investigate-geo-dr-issues`."
user-invocable: true
argument-hint: "[DatabaseName]"
---
# Geo-DR Assessment Health Check

## Scope

- Read-only assessment of geo-replication link state and lag, failover group and AG secondary health, planned-failover readiness (GO/NO_GO), RPO/RTO posture, and replication configuration on Azure SQL Database, Azure SQL Managed Instance, and SQL Server availability groups.
- For an active incident (geo-secondary lagging now, failover group problems), use the `investigate-geo-dr-issues` skill.
- For local high-availability posture (Always On AG, listeners, endpoints, cluster), use the `ha-assessment-health-check` skill.

## Evidence and decision rules

- When the user supplies a fixture, monitoring extract, or other bounded evidence and says to use only it, do not run the queries below and do not invent missing state. Report the observed facts first, identify unknowns, and base the decision only on the criteria the user supplied.
- The numeric limits embedded in these queries (for example 60 and 300 seconds of lag, 100/500 MB of redo, CPU over 80%, and blocking counts) are **operational defaults**, not universal product guarantees or the user's RPO/RTO policy. Label them as this skill's heuristics when they affect severity or readiness.
- Never turn an internal heuristic alone into an unconditional `NO_GO`. Reserve `NO_GO` for an observed hard blocker such as suspended replication, disconnected/unhealthy replicas, a stopped endpoint, or a user-provided policy violation. Otherwise report the observation and a qualified `CAUTION`, `GO_WITH_RISK`, or "cannot determine from supplied evidence" as appropriate.
- Keep observation and inference separate. For example: "observed lag = 360 seconds" is evidence; "this exceeds the skill's 300-second default" is an inference; whether that violates the required RPO depends on the user's stated policy.

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| DatabaseName | *(empty)* | Optional database name filter. Empty=all databases. |
| TopN | 50 | Max rows to return |
 
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

Replace `{{DatabaseName}}` and `{{TopN}}` in each query with the parameter values before running it (escape `'` as `''` in the database name).

1. `GetGeoDRHealthSummary` 2. `GetReplicationConfigReview` 3. `GetFailoverReadinessAssessment` 4. `GetRPORTOPosture` 5. `GetSecondaryReplicaHealth`. Empty results=no geo-DR.
---
### GetGeoDRHealthSummary
```sql
SET NOCOUNT ON;
DECLARE @EE INT=CAST(SERVERPROPERTY('EngineEdition') AS INT),@Now DATETIME2(3)=SYSUTCDATETIME(),@DB NVARCHAR(128)=NULLIF(N'{{DatabaseName}}','');
IF @EE IN(6,9,11) BEGIN SELECT 'UNSUPPORTED' AS [Platform],'EngineEdition '+CAST(@EE AS VARCHAR)+' not supported' AS [Action],@Now AS [AsOf]; RETURN; END;
IF @EE=5 BEGIN
SELECT 'AZURE_SQL_DB' AS [Platform],DB_NAME() AS [DatabaseName],
CASE WHEN v.st IS NULL THEN 'CRITICAL' WHEN v.st='SUSPENDED' THEN 'CRITICAL' WHEN v.st IN('PENDING','SEEDING') THEN 'DEGRADED' WHEN v.st='CATCH_UP' AND v.lag IS NULL AND gl.role_desc='SECONDARY' THEN 'HEALTHY' WHEN v.st='CATCH_UP' AND v.lag IS NULL THEN 'DEGRADED' WHEN v.lag>300 THEN 'CRITICAL' WHEN v.lag>60 THEN 'DEGRADED' ELSE 'HEALTHY' END AS [Grade],
CASE WHEN v.st IS NULL THEN 'Check connectivity primary<->secondary' WHEN v.st='SUSPENDED' THEN 'Suspended' WHEN v.st IN('PENDING','SEEDING') THEN 'Seeding-not ready' WHEN v.st='CATCH_UP' AND v.lag IS NULL AND gl.role_desc='SECONDARY' THEN 'OK-lag on primary' WHEN v.st='CATCH_UP' AND v.lag IS NULL THEN 'Lag unknown-check link' WHEN v.lag>300 THEN 'Lag>5m' WHEN v.lag>60 THEN 'Lag>1m-monitor' ELSE 'OK' END AS [Action],
gl.partner_server AS [Partner],gl.role_desc AS [Role],'ASYNC' AS [Mode],v.st AS [State],v.lag AS [LagSec],gl.last_replication AS [LastRepl],gl.secondary_allow_connections_desc AS [SecReadable],@Now AS [AsOf]
FROM sys.dm_geo_replication_link_status gl CROSS APPLY(VALUES(gl.replication_state_desc,gl.replication_lag_sec))v(st,lag) OPTION (MAXDOP 1);
RETURN; END;
IF @EE=8 BEGIN
SELECT TOP({{TopN}}) 'SQL_MI' AS [Platform],DB_NAME(drs.database_id) AS [DatabaseName],
CASE WHEN v.su=1 THEN 'CRITICAL' WHEN v.sh='NOT_HEALTHY' THEN 'CRITICAL' WHEN v.sh='PARTIALLY_HEALTHY' THEN 'DEGRADED' WHEN v.lag>300 THEN 'CRITICAL' WHEN v.lag>60 THEN 'DEGRADED' ELSE 'HEALTHY' END AS [Grade],
CASE WHEN v.su=1 THEN 'Suspended' WHEN v.sh='NOT_HEALTHY' THEN 'Unhealthy' WHEN v.lag>300 THEN 'Lag>5m' WHEN v.lag>60 THEN 'Lag>1m' ELSE 'OK' END AS [Action],
'SECONDARY' AS [Role],
drs.synchronization_state_desc AS [SyncState],v.sh AS [SyncHealth],v.su AS [Suspended],drs.suspend_reason_desc AS [SusReason],drs.secondary_lag_seconds AS [LagSec],drs.log_send_queue_size AS [SendQueueKB],drs.redo_queue_size AS [RedoQueueKB],drs.last_commit_time AS [LastCommit],@Now AS [AsOf]
FROM sys.dm_hadr_database_replica_states drs CROSS APPLY(VALUES(ISNULL(drs.secondary_lag_seconds,0),drs.synchronization_health_desc,drs.is_suspended))v(lag,sh,su)
WHERE drs.is_primary_replica=0 AND DB_NAME(drs.database_id) NOT IN('master','model','msdb','tempdb') AND (@DB IS NULL OR DB_NAME(drs.database_id)=@DB)
ORDER BY CASE WHEN v.su=1 OR v.sh='NOT_HEALTHY' THEN 0 WHEN v.sh='PARTIALLY_HEALTHY' OR v.lag>60 THEN 1 ELSE 2 END,DB_NAME(drs.database_id) OPTION (MAXDOP 1);
RETURN; END;
IF @EE IN(1,2,3,4) BEGIN
IF EXISTS(SELECT 1 FROM sys.dm_hadr_database_replica_states) BEGIN
SELECT TOP({{TopN}}) 'SQL_SERVER_AG' AS [Platform],ag.name AS [AG],d.name AS [DatabaseName],
CASE WHEN v.su=1 THEN 'CRITICAL' WHEN ars.connected_state_desc='DISCONNECTED' THEN 'CRITICAL' WHEN v.sh='NOT_HEALTHY' THEN 'CRITICAL' WHEN v.sh='PARTIALLY_HEALTHY' THEN 'DEGRADED' WHEN v.am='SYNCHRONOUS_COMMIT' AND v.ss!='SYNCHRONIZED' THEN 'DEGRADED' WHEN v.am='ASYNCHRONOUS_COMMIT' AND v.lag>300 THEN 'CRITICAL' WHEN v.lag>60 THEN 'DEGRADED' ELSE 'HEALTHY' END AS [Grade],
CASE WHEN v.su=1 THEN 'Suspended' WHEN ars.connected_state_desc='DISCONNECTED' THEN 'Disconnected' WHEN v.sh='NOT_HEALTHY' THEN 'Unhealthy' WHEN v.am='SYNCHRONOUS_COMMIT' AND v.ss!='SYNCHRONIZED' THEN 'NotSyncd' WHEN v.lag>300 THEN 'Lag>5m' WHEN v.lag>60 THEN 'Lag>1m' ELSE 'OK' END AS [Action],
ar.replica_server_name AS [Replica],ars.role_desc AS [Role],v.am AS [AvMode],ar.failover_mode_desc AS [FoMode],ars.connected_state_desc AS [ConnState],v.ss AS [SyncState],v.sh AS [SyncHealth],v.su AS [Suspended],drs.suspend_reason_desc AS [SusReason],drs.secondary_lag_seconds AS [LagSec],drs.log_send_queue_size AS [SendQueueKB],drs.log_send_rate AS [SendRateKBps],drs.redo_queue_size AS [RedoQueueKB],drs.redo_rate AS [RedoRateKBps],drs.last_commit_time AS [LastCommit],@Now AS [AsOf]
FROM sys.dm_hadr_database_replica_states drs INNER JOIN sys.databases d ON d.database_id=drs.database_id INNER JOIN sys.availability_replicas ar ON drs.replica_id=ar.replica_id INNER JOIN sys.availability_groups ag ON drs.group_id=ag.group_id INNER JOIN sys.dm_hadr_availability_replica_states ars ON ars.group_id=drs.group_id AND ars.replica_id=drs.replica_id CROSS APPLY(VALUES(ISNULL(drs.secondary_lag_seconds,0),drs.synchronization_health_desc,drs.is_suspended,ar.availability_mode_desc,drs.synchronization_state_desc))v(lag,sh,su,am,ss)
WHERE d.database_id>4 AND (@DB IS NULL OR d.name=@DB)
ORDER BY CASE WHEN v.su=1 OR ars.connected_state_desc='DISCONNECTED' OR v.sh='NOT_HEALTHY' THEN 0 WHEN v.sh='PARTIALLY_HEALTHY' OR v.lag>60 THEN 1 ELSE 2 END,ag.name,d.name,ar.replica_server_name OPTION (MAXDOP 1);
END
ELSE SELECT 'SQL_SERVER' AS [Platform],'NOT_CONFIGURED' AS [Grade],'No AG-enable HADR' AS [Action],@Now AS [AsOf];
RETURN; END;
SELECT CASE @EE WHEN 12 THEN 'FABRIC' ELSE 'UNKNOWN' END AS [Platform],'MANAGED' AS [Grade],'Managed' AS [Action],@Now AS [AsOf];
```
---
### GetReplicationConfigReview
```sql
SET NOCOUNT ON;
DECLARE @EE INT=CAST(SERVERPROPERTY('EngineEdition') AS INT),@Now DATETIME2(3)=SYSUTCDATETIME(),@DB NVARCHAR(128)=NULLIF(N'{{DatabaseName}}','');
IF @EE IN(6,9,11) BEGIN SELECT 'UNSUPPORTED' AS [Platform],'EngineEdition '+CAST(@EE AS VARCHAR)+' not supported' AS [Action],@Now AS [AsOf]; RETURN; END;
IF @EE=5 BEGIN
SELECT 'AZURE_SQL_DB' AS [Platform],DB_NAME() AS [DatabaseName],gl.partner_server AS [Partner],gl.role_desc AS [Role],v.st AS [State],gl.secondary_allow_connections_desc AS [SecReadable],
CASE WHEN v.st IS NULL THEN 'NO-check connectivity' WHEN v.st='CATCH_UP' THEN 'YES-planned(0 loss)' WHEN v.st IN('SEEDING','PENDING') THEN 'YES-forced(data loss)' WHEN v.st='SUSPENDED' THEN 'YES-forced(data loss)' ELSE 'CONDITIONAL' END AS [CanFailover],
CASE WHEN v.st IS NULL OR v.st='SUSPENDED' THEN 'CRITICAL' WHEN v.st IN('SEEDING','PENDING') THEN 'WARNING' ELSE 'OK' END AS [Severity],
CASE WHEN v.st IS NULL THEN 'Check connectivity primary<->secondary' WHEN v.st='CATCH_UP' THEN 'Planned FG failover-0 loss' WHEN v.st IN('SEEDING','PENDING','SUSPENDED') THEN 'Forced failover only-data loss' ELSE 'Use FG' END AS [Action],@Now AS [AsOf]
FROM sys.dm_geo_replication_link_status gl CROSS APPLY(VALUES(gl.replication_state_desc))v(st) OPTION (MAXDOP 1);
RETURN; END;
IF @EE=8 BEGIN
SELECT TOP({{TopN}}) 'SQL_MI' AS [Platform],CAST(drs.group_id AS NVARCHAR(50)) AS [FGId],DB_NAME(drs.database_id) AS [DatabaseName],
'SECONDARY' AS [Role],
drs.synchronization_state_desc AS [SyncState],v.sh AS [SyncHealth],v.su AS [Suspended],drs.secondary_lag_seconds AS [LagSec],drs.log_send_queue_size AS [SendQueueKB],drs.redo_queue_size AS [RedoQueueKB],
CASE WHEN v.su=1 THEN 'NO-suspended' WHEN v.sh='NOT_HEALTHY' THEN 'NO-unhealthy' WHEN v.sh='HEALTHY' THEN 'YES-ready(async)' ELSE 'CONDITIONAL' END AS [CanFailover],
CASE WHEN v.sh='NOT_HEALTHY' OR v.su=1 THEN 'CRITICAL' WHEN v.sh='PARTIALLY_HEALTHY' OR v.lag>60 THEN 'WARNING' ELSE 'OK' END AS [Severity],
CASE WHEN v.su=1 THEN 'Suspended' WHEN v.sh='NOT_HEALTHY' THEN 'Unhealthy' WHEN v.lag>60 THEN 'Lag>60s' ELSE 'OK' END AS [Action],@Now AS [AsOf]
FROM sys.dm_hadr_database_replica_states drs CROSS APPLY(VALUES(ISNULL(drs.secondary_lag_seconds,0),drs.synchronization_health_desc,drs.is_suspended))v(lag,sh,su)
WHERE drs.is_primary_replica=0 AND DB_NAME(drs.database_id) NOT IN('master','model','msdb','tempdb') AND (@DB IS NULL OR DB_NAME(drs.database_id)=@DB)
ORDER BY DB_NAME(drs.database_id) OPTION (MAXDOP 1);
RETURN; END;
IF @EE IN(1,2,3,4) BEGIN
IF EXISTS(SELECT 1 FROM sys.availability_groups) BEGIN
DECLARE @EpSt NVARCHAR(60)=NULL,@EpEnc BIT=0;
SELECT TOP(1) @EpSt=state_desc,@EpEnc=is_encryption_enabled FROM sys.database_mirroring_endpoints ORDER BY endpoint_id OPTION (MAXDOP 1);
SELECT TOP({{TopN}}) 'SQL_SERVER_AG' AS [Platform],ag.name AS [AG],ar.replica_server_name AS [Replica],ars.role_desc AS [Role],v.am AS [AvMode],v.fm AS [FoMode],ar.session_timeout AS [SessTimeout],ar.secondary_role_allow_connections_desc AS [SecReadable],ar.endpoint_url AS [EndpointUrl],ISNULL(@EpSt,'MISSING') AS [EpState],
CASE WHEN @EpSt IS NULL THEN 'NO-endpoint MISSING' WHEN @EpSt!='STARTED' THEN 'NO-endpoint '+@EpSt WHEN v.fm='AUTOMATIC' AND v.am='SYNCHRONOUS_COMMIT' AND v.cs='CONNECTED' AND v.csh='HEALTHY' THEN 'YES-auto' WHEN v.fm='AUTOMATIC' AND v.am!='SYNCHRONOUS_COMMIT' THEN 'NO-auto needs SYNC' WHEN v.fm='AUTOMATIC' AND v.cs='DISCONNECTED' THEN 'NO-disconnected' WHEN v.fm='AUTOMATIC' AND v.csh!='HEALTHY' THEN 'NO-unhealthy' WHEN v.fm='MANUAL' AND v.am='SYNCHRONOUS_COMMIT' AND v.cs='CONNECTED' THEN 'YES-manual(no loss)' WHEN v.fm='MANUAL' AND v.am='ASYNCHRONOUS_COMMIT' AND v.cs='CONNECTED' THEN 'YES-forced(data loss)' WHEN v.cs='DISCONNECTED' THEN 'NO-disconnected' ELSE 'CONDITIONAL' END AS [CanFailover],
CASE WHEN ars.role_desc IS NULL THEN 'WARNING' WHEN @EpSt IS NULL OR @EpSt!='STARTED' THEN 'CRITICAL' WHEN v.fm='AUTOMATIC' AND v.am!='SYNCHRONOUS_COMMIT' THEN 'CRITICAL' WHEN v.cs='DISCONNECTED' THEN 'CRITICAL' WHEN ar.session_timeout<10 OR @EpEnc=0 THEN 'WARNING' WHEN ar.session_timeout<20 THEN 'WARNING' ELSE 'OK' END AS [Severity],
CASE WHEN ars.role_desc IS NULL THEN 'NoReplicaState' WHEN @EpSt IS NULL THEN 'NoEndpoint' WHEN @EpSt!='STARTED' THEN 'EpStopped' WHEN v.fm='AUTOMATIC' AND v.am!='SYNCHRONOUS_COMMIT' THEN 'AutoNeedsSYNC' WHEN v.cs='DISCONNECTED' THEN 'CheckNetwork' WHEN ar.session_timeout<20 THEN 'Timeout '+CAST(ar.session_timeout AS VARCHAR(5))+'s<20s' WHEN @EpEnc=0 THEN 'NoEncryption' ELSE 'OK' END AS [Action],@Now AS [AsOf]
FROM sys.availability_groups ag INNER JOIN sys.availability_replicas ar ON ag.group_id=ar.group_id LEFT JOIN sys.dm_hadr_availability_replica_states ars ON ar.group_id=ars.group_id AND ar.replica_id=ars.replica_id CROSS APPLY(VALUES(ar.availability_mode_desc,ar.failover_mode_desc,ars.connected_state_desc,ars.synchronization_health_desc))v(am,fm,cs,csh)
ORDER BY ag.name,ar.replica_server_name OPTION (MAXDOP 1);
END
ELSE SELECT 'SQL_SERVER' AS [Platform],'No AG' AS [Action],'NO' AS [CanFailover],'WARNING' AS [Severity],@Now AS [AsOf];
RETURN; END;
SELECT CASE @EE WHEN 12 THEN 'FABRIC' ELSE 'UNKNOWN' END AS [Platform],'Managed' AS [Action],'INFO' AS [Severity],@Now AS [AsOf];
```
---
### GetFailoverReadinessAssessment
```sql
SET NOCOUNT ON;
DECLARE @EE INT=CAST(SERVERPROPERTY('EngineEdition') AS INT),@Now DATETIME2(3)=SYSUTCDATETIME(),@DB NVARCHAR(128)=NULLIF(N'{{DatabaseName}}','');
IF @EE IN(6,9,11) BEGIN SELECT 'UNSUPPORTED' AS [Platform],'EngineEdition '+CAST(@EE AS VARCHAR)+' not supported' AS [Decision],'N/A' AS [Action],'INFO' AS [Severity],@Now AS [AsOf]; RETURN; END;
DECLARE @Blk INT=0,@CPU BIT=0,@IO BIT=0,@BlkS INT=0;
SELECT @Blk=COUNT(*),@BlkS=ISNULL(MAX(wait_time/1000),0) FROM sys.dm_exec_requests WHERE blocking_session_id<>0 OPTION (MAXDOP 1);
IF @EE IN(1,2,3,4,8)
BEGIN
  IF EXISTS(SELECT 1 FROM sys.dm_os_schedulers WHERE status='VISIBLE ONLINE' AND scheduler_id<255 AND runnable_tasks_count>1) SET @CPU=1;
  IF @CPU=0 BEGIN TRY
    SELECT TOP(1) @CPU=1
    FROM (SELECT CAST(record AS XML) AS x FROM sys.dm_os_ring_buffers WHERE ring_buffer_type=N'RING_BUFFER_SCHEDULER_MONITOR' AND record LIKE N'%<SystemHealth>%') r
    CROSS JOIN sys.dm_os_sys_info si
    WHERE r.x.value('(./Record/@time)[1]','bigint')>si.ms_ticks-120000
      AND r.x.value('(./Record/SchedulerMonitorEvent/SystemHealth/ProcessUtilization)[1]','int')>80;
  END TRY BEGIN CATCH END CATCH;
END
ELSE IF @EE=5
BEGIN
  BEGIN TRY
    DECLARE @cs NVARCHAR(250)=N'SELECT @c=1 FROM sys.dm_db_resource_stats WHERE end_time>DATEADD(minute,-2,SYSUTCDATETIME()) AND avg_cpu_percent>80 ORDER BY end_time DESC OFFSET 0 ROWS FETCH NEXT 1 ROWS ONLY OPTION (MAXDOP 1)';
    EXEC sp_executesql @cs,N'@c BIT OUTPUT',@c=@CPU OUTPUT;
  END TRY BEGIN CATCH SET @CPU=0; END CATCH;
END;
IF (SELECT COUNT(*) FROM sys.dm_os_waiting_tasks WHERE wait_type IN('PAGEIOLATCH_SH','PAGEIOLATCH_EX','PAGEIOLATCH_UP','WRITELOG','IO_COMPLETION'))>5 SET @IO=1;
IF @EE=5 BEGIN
SELECT 'AZURE_SQL_DB' AS [Platform],DB_NAME() AS [DatabaseName],
CASE WHEN v.st IS NULL THEN 'NO_GO' WHEN v.st='CATCH_UP' THEN 'GO' WHEN v.st IN('SEEDING','PENDING','SUSPENDED') THEN 'GO_WITH_DATA_LOSS' ELSE 'CAUTION' END AS [Decision],
CASE WHEN v.st IS NULL OR v.st='SUSPENDED' THEN 'CRITICAL' WHEN v.st IN('SEEDING','PENDING') THEN 'WARNING' WHEN v.st='CATCH_UP' AND ((v.lag IS NULL AND gl.role_desc<>'SECONDARY') OR v.lag>300 OR @Blk>5 OR @IO=1 OR @CPU=1) THEN 'WARNING' ELSE 'OK' END AS [Severity],
CASE WHEN v.st IS NULL THEN 'Check connectivity primary<->secondary' WHEN v.st='SUSPENDED' THEN 'Forced failover-data loss(resume link)' WHEN v.st IN('SEEDING','PENDING') THEN 'Forced failover-data loss(seeding)' WHEN v.st='CATCH_UP' AND v.lag IS NULL AND gl.role_desc='SECONDARY' THEN 'Planned failover-0 loss(lag on primary)' WHEN v.st='CATCH_UP' AND v.lag IS NULL THEN 'Planned failover-0 loss(verify lag)' WHEN v.st='CATCH_UP' AND v.lag>300 THEN 'Planned failover-0 loss(slow drain)' WHEN v.st='CATCH_UP' AND @Blk>5 THEN 'Planned-0 loss(blocking:'+CAST(@Blk AS VARCHAR(5))+')' WHEN v.st='CATCH_UP' AND (@CPU=1 OR @IO=1) THEN 'Planned-0 loss(perf)' WHEN v.st='CATCH_UP' THEN 'Planned failover-0 loss' ELSE 'Review' END AS [Action],
gl.partner_server AS [Partner],gl.role_desc AS [Role],v.st AS [State],v.lag AS [LagSec],gl.last_replication AS [LastRepl],@Now AS [AsOf]
FROM sys.dm_geo_replication_link_status gl CROSS APPLY(VALUES(gl.replication_state_desc,gl.replication_lag_sec))v(st,lag) OPTION (MAXDOP 1);
RETURN; END;
IF @EE=8 BEGIN
SELECT TOP({{TopN}}) 'SQL_MI' AS [Platform],DB_NAME(drs.database_id) AS [DatabaseName],
CASE WHEN v.su=1 OR v.sh='NOT_HEALTHY' THEN 'NO_GO' WHEN v.lag>300 THEN 'GO_WITH_DATA_LOSS' WHEN @Blk>10 THEN 'CAUTION' WHEN v.lag>60 OR v.redo>512000 THEN 'GO_WITH_RISK' WHEN v.lag<=5 AND v.sh='HEALTHY' THEN 'GO' WHEN v.lag<=60 AND v.sh='HEALTHY' THEN 'GO_MANUAL' ELSE 'CAUTION' END AS [Decision],
CASE WHEN v.su=1 OR v.sh='NOT_HEALTHY' OR v.redo>512000 OR v.lag>300 THEN 'CRITICAL' WHEN v.lag>60 OR v.redo>102400 OR @Blk>5 OR @CPU=1 OR @IO=1 THEN 'WARNING' ELSE 'OK' END AS [Severity],
CASE WHEN v.su=1 THEN 'NOGO:suspended' WHEN v.sh='NOT_HEALTHY' THEN 'NOGO:unhealthy' WHEN v.redo>512000 THEN 'Redo>500MB' WHEN @Blk>5 THEN 'Blocking:'+CAST(@Blk AS VARCHAR(5)) WHEN v.lag>300 THEN 'Lag>5m' WHEN v.lag>60 THEN 'Lag~'+CAST(drs.secondary_lag_seconds AS VARCHAR(10))+'s' WHEN @CPU=1 OR @IO=1 THEN 'Perf' WHEN v.lag<=5 THEN 'READY' ELSE 'Review' END AS [Action],
'SECONDARY' AS [Role],
drs.synchronization_state_desc AS [SyncState],v.sh AS [SyncHealth],v.su AS [Suspended],drs.suspend_reason_desc AS [SusReason],drs.secondary_lag_seconds AS [LagSec],drs.log_send_queue_size AS [SendQueueKB],drs.redo_queue_size AS [RedoQueueKB],drs.last_commit_time AS [LastCommit],@Now AS [AsOf]
FROM sys.dm_hadr_database_replica_states drs CROSS APPLY(VALUES(ISNULL(drs.secondary_lag_seconds,0),drs.synchronization_health_desc,drs.is_suspended,ISNULL(drs.redo_queue_size,0)))v(lag,sh,su,redo)
WHERE drs.is_primary_replica=0 AND DB_NAME(drs.database_id) NOT IN('master','model','msdb','tempdb') AND (@DB IS NULL OR DB_NAME(drs.database_id)=@DB)
ORDER BY CASE WHEN v.su=1 OR v.sh='NOT_HEALTHY' THEN 0 WHEN v.redo>102400 THEN 1 WHEN v.lag>60 THEN 2 ELSE 3 END,DB_NAME(drs.database_id) OPTION (MAXDOP 1);
RETURN; END;
IF @EE IN(1,2,3,4) BEGIN
DECLARE @EpP INT=NULL,@EpS NVARCHAR(60)=NULL;
SELECT TOP(1) @EpP=port,@EpS=e.state_desc FROM sys.tcp_endpoints t INNER JOIN sys.database_mirroring_endpoints e ON t.endpoint_id=e.endpoint_id ORDER BY e.endpoint_id OPTION (MAXDOP 1);
IF @EpP IS NULL SELECT TOP(1) @EpS=state_desc FROM sys.database_mirroring_endpoints ORDER BY endpoint_id OPTION (MAXDOP 1);
DECLARE @DiscR INT=0;
SELECT @DiscR=COUNT(*) FROM sys.dm_hadr_availability_replica_states WHERE connected_state_desc='DISCONNECTED' OPTION (MAXDOP 1);
IF EXISTS(SELECT 1 FROM sys.dm_hadr_database_replica_states) BEGIN
SELECT TOP({{TopN}}) 'SQL_SERVER_AG' AS [Platform],ag.name AS [AG],d.name AS [DatabaseName],ar.replica_server_name AS [Replica],
CASE WHEN v.su=1 OR v.cs='DISCONNECTED' OR v.sh='NOT_HEALTHY' THEN 'NO_GO' WHEN @EpS IS NULL OR @EpS!='STARTED' THEN 'NO_GO' WHEN @DiscR>0 AND ars.role_desc='PRIMARY' THEN 'NO_GO' WHEN @Blk>10 AND @BlkS>120 THEN 'CAUTION' WHEN v.am='SYNCHRONOUS_COMMIT' AND v.ss='SYNCHRONIZED' AND ar.failover_mode_desc='AUTOMATIC' AND v.sh='HEALTHY' THEN 'GO' WHEN v.am='SYNCHRONOUS_COMMIT' AND v.ss='SYNCHRONIZED' AND ar.failover_mode_desc='MANUAL' THEN 'GO_MANUAL' WHEN v.am='SYNCHRONOUS_COMMIT' AND v.ss!='SYNCHRONIZED' THEN 'GO_WITH_RISK' WHEN v.am='ASYNCHRONOUS_COMMIT' AND v.lag<=5 THEN 'GO_MANUAL' WHEN v.am='ASYNCHRONOUS_COMMIT' AND v.lag<=60 THEN 'GO_WITH_RISK' WHEN v.am='ASYNCHRONOUS_COMMIT' AND v.lag>60 THEN 'GO_WITH_DATA_LOSS' WHEN v.redo>512000 THEN 'GO_WITH_RISK' ELSE 'CAUTION' END AS [Decision],
CASE WHEN v.su=1 OR v.cs='DISCONNECTED' OR v.sh='NOT_HEALTHY' OR @EpS IS NULL OR @EpS!='STARTED' OR (@DiscR>0 AND ars.role_desc='PRIMARY') THEN 'CRITICAL' WHEN v.redo>512000 OR v.lag>300 OR (@Blk>5 AND @BlkS>60) THEN 'CRITICAL' WHEN v.am='SYNCHRONOUS_COMMIT' AND v.ss!='SYNCHRONIZED' THEN 'WARNING' WHEN v.lag>60 OR v.redo>102400 OR @CPU=1 OR @IO=1 OR @Blk>5 THEN 'WARNING' ELSE 'OK' END AS [Severity],
CASE WHEN v.su=1 THEN 'NOGO:suspended' WHEN @EpS IS NULL THEN 'NOGO:ep' WHEN @EpS!='STARTED' THEN 'NOGO:ep' WHEN v.cs='DISCONNECTED' THEN 'NOGO:disc,p '+ISNULL(CAST(@EpP AS VARCHAR(5)),'5022') WHEN @DiscR>0 AND ars.role_desc='PRIMARY' THEN 'NOGO:'+CAST(@DiscR AS VARCHAR(3))+' disconnected' WHEN v.sh='NOT_HEALTHY' THEN 'NOGO:unhealthy' WHEN @Blk>5 AND @BlkS>60 THEN 'Blocking:'+CAST(@Blk AS VARCHAR(5))+'/'+CAST(@BlkS AS VARCHAR(10))+'s' WHEN v.redo>512000 THEN 'Redo>500MB' WHEN v.am='SYNCHRONOUS_COMMIT' AND v.ss='SYNCHRONIZED' THEN 'READY:sync' WHEN v.am='SYNCHRONOUS_COMMIT' THEN 'NotSyncd' WHEN v.lag>300 THEN 'Lag>5m' WHEN v.lag>60 THEN 'Lag~'+CAST(drs.secondary_lag_seconds AS VARCHAR(10))+'s' WHEN @CPU=1 OR @IO=1 THEN 'Perf' WHEN v.lag<=5 THEN 'READY' ELSE 'Review' END AS [Action],
ars.role_desc AS [Role],v.am AS [AvMode],ar.failover_mode_desc AS [FoMode],v.cs AS [ConnState],v.ss AS [SyncState],v.sh AS [SyncHealth],v.su AS [Suspended],drs.suspend_reason_desc AS [SusReason],drs.secondary_lag_seconds AS [LagSec],drs.log_send_queue_size AS [SendQueueKB],drs.log_send_rate AS [SendRateKBps],drs.redo_queue_size AS [RedoQueueKB],drs.redo_rate AS [RedoRateKBps],drs.last_commit_time AS [LastCommit],@Now AS [AsOf]
FROM sys.dm_hadr_database_replica_states drs INNER JOIN sys.databases d ON d.database_id=drs.database_id INNER JOIN sys.availability_replicas ar ON drs.replica_id=ar.replica_id INNER JOIN sys.availability_groups ag ON drs.group_id=ag.group_id INNER JOIN sys.dm_hadr_availability_replica_states ars ON ars.group_id=drs.group_id AND ars.replica_id=drs.replica_id CROSS APPLY(VALUES(ISNULL(drs.secondary_lag_seconds,0),drs.synchronization_health_desc,drs.is_suspended,ISNULL(drs.redo_queue_size,0),ar.availability_mode_desc,drs.synchronization_state_desc,ars.connected_state_desc))v(lag,sh,su,redo,am,ss,cs)
WHERE d.database_id>4 AND (@DB IS NULL OR d.name=@DB)
ORDER BY CASE WHEN v.su=1 OR v.cs='DISCONNECTED' OR v.sh='NOT_HEALTHY' THEN 0 WHEN v.redo>102400 THEN 1 WHEN v.lag>60 THEN 2 ELSE 3 END,ag.name,d.name,ar.replica_server_name OPTION (MAXDOP 1);
END
ELSE SELECT 'SQL_SERVER' AS [Platform],'NO_GO' AS [Decision],'No AG' AS [Action],'INFO' AS [Severity],@Now AS [AsOf];
RETURN; END;
SELECT CASE @EE WHEN 12 THEN 'FABRIC' ELSE 'UNKNOWN' END AS [Platform],'MANAGED' AS [Decision],'Managed' AS [Action],'INFO' AS [Severity],@Now AS [AsOf];
```
---
### GetRPORTOPosture
```sql
SET NOCOUNT ON;
DECLARE @EE INT=CAST(SERVERPROPERTY('EngineEdition') AS INT),@Now DATETIME2(3)=SYSUTCDATETIME(),@DB NVARCHAR(128)=NULLIF(N'{{DatabaseName}}','');
IF @EE IN(6,9,11) BEGIN SELECT 'UNSUPPORTED' AS [Platform],'EngineEdition '+CAST(@EE AS VARCHAR)+' not supported' AS [RPO],'INFO' AS [Severity],@Now AS [AsOf]; RETURN; END;
IF @EE=5 BEGIN
SELECT 'AZURE_SQL_DB' AS [Platform],DB_NAME() AS [DatabaseName],gl.partner_server AS [Partner],gl.role_desc AS [Role],v.lag AS [RPOSec],
CASE WHEN v.st IS NULL THEN 'unknown(check link)' WHEN v.st='SUSPENDED' THEN 'unknown(suspended)' WHEN v.st IN('SEEDING','PENDING') THEN 'unknown(not ready)' WHEN v.st='CATCH_UP' AND v.lag IS NULL AND gl.role_desc='SECONDARY' THEN 'lag on primary' WHEN v.st='CATCH_UP' AND v.lag IS NULL THEN 'unknown(check link)' WHEN v.lag<5 THEN '<5s' WHEN v.lag<30 THEN '<30s' WHEN v.lag<300 THEN '<5m' ELSE '>5m(risk)' END AS [RPO],
'30-60s' AS [RTO],
CASE WHEN v.st IS NULL OR v.st='SUSPENDED' OR v.lag>300 THEN 'CRITICAL' WHEN v.st IN('SEEDING','PENDING') OR (v.st='CATCH_UP' AND v.lag IS NULL AND gl.role_desc<>'SECONDARY') OR v.lag>60 THEN 'WARNING' ELSE 'OK' END AS [Severity],
CASE WHEN v.st IS NULL THEN 'Check connectivity primary<->secondary' WHEN v.st='SUSPENDED' THEN 'Suspended-resume link' WHEN v.st IN('SEEDING','PENDING') THEN 'Not ready-seeding' WHEN v.st='CATCH_UP' AND v.lag IS NULL AND gl.role_desc='SECONDARY' THEN 'RPO on primary' WHEN v.st='CATCH_UP' AND v.lag IS NULL THEN 'RPO unknown-check link' WHEN v.lag>300 THEN 'RPO>5m' WHEN v.lag>60 THEN 'RPO>1m-monitor' ELSE 'Within SLA' END AS [Action],@Now AS [AsOf]
FROM sys.dm_geo_replication_link_status gl CROSS APPLY(VALUES(gl.replication_state_desc,gl.replication_lag_sec))v(st,lag) OPTION (MAXDOP 1);
RETURN; END;
IF @EE=8 BEGIN
SELECT TOP({{TopN}}) 'SQL_MI' AS [Platform],DB_NAME(drs.database_id) AS [DatabaseName],
'SECONDARY' AS [Role],
v.lag AS [RPOSec],
CASE WHEN v.lag<5 THEN '<5s' WHEN v.lag<30 THEN '<30s' WHEN v.lag<300 THEN '<5m' ELSE '>5m(risk)' END AS [RPO],
v.redo AS [RedoQueueKB],drs.log_send_queue_size AS [SendQueueKB],'60-120s' AS [RTO],
CASE WHEN v.su=1 THEN 'CRITICAL' WHEN v.lag>300 THEN 'CRITICAL' WHEN v.lag>60 OR v.redo>512000 THEN 'WARNING' ELSE 'OK' END AS [Severity],
CASE WHEN v.su=1 THEN 'RPO?' WHEN v.lag>300 THEN 'RPO>5m' WHEN v.redo>512000 THEN 'Redo>500MB' ELSE 'OK' END AS [Action],@Now AS [AsOf]
FROM sys.dm_hadr_database_replica_states drs CROSS APPLY(VALUES(ISNULL(drs.secondary_lag_seconds,0),drs.is_suspended,drs.redo_queue_size))v(lag,su,redo)
WHERE drs.is_primary_replica=0 AND DB_NAME(drs.database_id) NOT IN('master','model','msdb','tempdb') AND (@DB IS NULL OR DB_NAME(drs.database_id)=@DB)
ORDER BY drs.secondary_lag_seconds DESC OPTION (MAXDOP 1);
RETURN; END;
IF @EE IN(1,2,3,4) BEGIN
IF EXISTS(SELECT 1 FROM sys.dm_hadr_database_replica_states) BEGIN
SELECT TOP({{TopN}}) 'SQL_SERVER_AG' AS [Platform],ag.name AS [AG],d.name AS [DatabaseName],ar.replica_server_name AS [Replica],ars.role_desc AS [Role],v.am AS [AvMode],
CASE WHEN v.am='SYNCHRONOUS_COMMIT' AND v.ss='SYNCHRONIZED' THEN 0 ELSE v.lag END AS [RPOSec],
CASE WHEN v.am='SYNCHRONOUS_COMMIT' AND v.ss='SYNCHRONIZED' THEN '0s(zero loss)' WHEN v.lag<5 THEN '<5s' WHEN v.lag<30 THEN '<30s' WHEN v.lag<300 THEN '<5m' ELSE '>5m(risk)' END AS [RPO],
v.redo AS [RedoQueueKB],drs.redo_rate AS [RedoRateKBps],drs.log_send_queue_size AS [SendQueueKB],
CASE WHEN ar.failover_mode_desc='AUTOMATIC' THEN 'Seconds(auto)' ELSE 'Manual' END AS [RTO],
CASE WHEN v.su=1 OR v.cs='DISCONNECTED' THEN 'CRITICAL' WHEN v.am='ASYNCHRONOUS_COMMIT' AND v.lag>300 THEN 'CRITICAL' WHEN v.lag>60 OR v.redo>512000 THEN 'WARNING' ELSE 'OK' END AS [Severity],
CASE WHEN v.su=1 THEN 'RPO?' WHEN v.am='SYNCHRONOUS_COMMIT' AND v.ss='SYNCHRONIZED' THEN 'ZeroRPO' WHEN v.lag>300 THEN 'RPO>5m' WHEN v.redo>512000 THEN 'Redo>500MB' ELSE 'OK' END AS [Action],@Now AS [AsOf]
FROM sys.dm_hadr_database_replica_states drs INNER JOIN sys.databases d ON d.database_id=drs.database_id INNER JOIN sys.availability_replicas ar ON drs.replica_id=ar.replica_id INNER JOIN sys.availability_groups ag ON drs.group_id=ag.group_id INNER JOIN sys.dm_hadr_availability_replica_states ars ON ars.group_id=drs.group_id AND ars.replica_id=drs.replica_id CROSS APPLY(VALUES(ISNULL(drs.secondary_lag_seconds,0),drs.is_suspended,drs.redo_queue_size,ar.availability_mode_desc,drs.synchronization_state_desc,ars.connected_state_desc))v(lag,su,redo,am,ss,cs)
WHERE d.database_id>4 AND (@DB IS NULL OR d.name=@DB)
ORDER BY CASE WHEN v.am='ASYNCHRONOUS_COMMIT' AND v.lag>300 THEN 0 ELSE 1 END,ag.name,d.name,ar.replica_server_name OPTION (MAXDOP 1);
END
ELSE SELECT 'SQL_SERVER' AS [Platform],'N/A' AS [RPO],'No AG' AS [Action],'INFO' AS [Severity],@Now AS [AsOf];
RETURN; END;
SELECT CASE @EE WHEN 12 THEN 'FABRIC' ELSE 'UNKNOWN' END AS [Platform],'Platform SLA' AS [RPO],'INFO' AS [Severity],@Now AS [AsOf];
```
---
### GetSecondaryReplicaHealth
```sql
SET NOCOUNT ON;
DECLARE @EE INT=CAST(SERVERPROPERTY('EngineEdition') AS INT),@Now DATETIME2(3)=SYSUTCDATETIME(),@DB NVARCHAR(128)=NULLIF(N'{{DatabaseName}}','');
IF @EE IN(6,9,11) BEGIN SELECT 'UNSUPPORTED' AS [Platform],'EngineEdition '+CAST(@EE AS VARCHAR)+' not supported' AS [Action],'INFO' AS [Severity],@Now AS [AsOf]; RETURN; END;
IF @EE=5 BEGIN
SELECT 'AZURE_SQL_DB' AS [Platform],DB_NAME() AS [DatabaseName],gl.partner_server AS [Secondary],gl.role_desc AS [Role],v.st AS [State],v.lag AS [LagSec],gl.last_replication AS [LastRepl],gl.secondary_allow_connections_desc AS [SecReadable],
CASE WHEN v.st IS NULL THEN 'UNKNOWN' WHEN v.st='CATCH_UP' AND v.lag IS NULL AND gl.role_desc='SECONDARY' THEN 'HEALTHY' WHEN v.st='CATCH_UP' AND v.lag IS NULL THEN 'DEGRADED' WHEN v.st='CATCH_UP' AND v.lag<60 THEN 'HEALTHY' WHEN v.st='CATCH_UP' THEN 'DEGRADED' WHEN v.st='SUSPENDED' THEN 'CRITICAL' WHEN v.st IN('SEEDING','PENDING') THEN 'DEGRADED' ELSE 'UNKNOWN' END AS [Health],
CASE WHEN v.st IS NULL OR v.st='SUSPENDED' THEN 'CRITICAL' WHEN v.lag>300 THEN 'CRITICAL' WHEN v.st IN('SEEDING','PENDING') OR (v.st='CATCH_UP' AND v.lag IS NULL AND gl.role_desc<>'SECONDARY') OR v.lag>60 THEN 'WARNING' ELSE 'OK' END AS [Severity],
CASE WHEN v.st IS NULL THEN 'Check connectivity primary<->secondary' WHEN v.st='SUSPENDED' THEN 'Resume' WHEN v.st IN('SEEDING','PENDING') THEN 'Not ready-seeding' WHEN v.st='CATCH_UP' AND v.lag IS NULL AND gl.role_desc='SECONDARY' THEN 'Healthy-lag on primary' WHEN v.st='CATCH_UP' AND v.lag IS NULL THEN 'Lag unknown-check link' WHEN v.lag>300 THEN 'Lag>5m' WHEN v.lag>60 THEN 'Lag>1m' ELSE 'Healthy' END AS [Action],@Now AS [AsOf]
FROM sys.dm_geo_replication_link_status gl CROSS APPLY(VALUES(gl.replication_state_desc,gl.replication_lag_sec))v(st,lag) OPTION (MAXDOP 1);
RETURN; END;
IF @EE=8 BEGIN
SELECT TOP({{TopN}}) 'SQL_MI' AS [Platform],DB_NAME(drs.database_id) AS [DatabaseName],
'SECONDARY' AS [Role],
drs.synchronization_state_desc AS [SyncState],v.sh AS [SyncHealth],v.su AS [Suspended],drs.suspend_reason_desc AS [SusReason],drs.secondary_lag_seconds AS [LagSec],v.sendq AS [SendQueueKB],v.redo AS [RedoQueueKB],drs.last_commit_time AS [LastCommit],
CASE WHEN v.su=1 OR v.sh='NOT_HEALTHY' THEN 'CRITICAL' WHEN v.sh='PARTIALLY_HEALTHY' OR v.lag>60 OR v.redo>102400 THEN 'WARNING' ELSE 'OK' END AS [Severity],
CASE WHEN v.su=1 THEN 'Suspended' WHEN v.sh='NOT_HEALTHY' THEN 'Unhealthy' WHEN v.redo>102400 THEN 'Redo>100MB' WHEN v.sendq>102400 THEN 'SendQ>100MB' ELSE 'Healthy' END AS [Action],@Now AS [AsOf]
FROM sys.dm_hadr_database_replica_states drs CROSS APPLY(VALUES(ISNULL(drs.secondary_lag_seconds,0),drs.synchronization_health_desc,drs.is_suspended,drs.redo_queue_size,drs.log_send_queue_size))v(lag,sh,su,redo,sendq)
WHERE drs.is_primary_replica=0 AND DB_NAME(drs.database_id) NOT IN('master','model','msdb','tempdb') AND (@DB IS NULL OR DB_NAME(drs.database_id)=@DB)
ORDER BY CASE WHEN v.su=1 OR v.sh='NOT_HEALTHY' THEN 0 WHEN v.sh='PARTIALLY_HEALTHY' THEN 1 ELSE 2 END,DB_NAME(drs.database_id) OPTION (MAXDOP 1);
RETURN; END;
IF @EE IN(1,2,3,4) BEGIN
IF EXISTS(SELECT 1 FROM sys.dm_hadr_database_replica_states) BEGIN
SELECT TOP({{TopN}}) 'SQL_SERVER_AG' AS [Platform],ag.name AS [AG],d.name AS [DatabaseName],ar.replica_server_name AS [Replica],ars.role_desc AS [Role],v.am AS [AvMode],v.cs AS [ConnState],drs.synchronization_state_desc AS [SyncState],v.sh AS [SyncHealth],v.su AS [Suspended],drs.suspend_reason_desc AS [SusReason],drs.secondary_lag_seconds AS [LagSec],v.sendq AS [SendQueueKB],drs.log_send_rate AS [SendRateKBps],v.redo AS [RedoQueueKB],drs.redo_rate AS [RedoRateKBps],ar.secondary_role_allow_connections_desc AS [SecReadable],drs.last_commit_time AS [LastCommit],
CASE WHEN v.su=1 OR v.cs='DISCONNECTED' OR v.sh='NOT_HEALTHY' THEN 'CRITICAL' WHEN v.sh='PARTIALLY_HEALTHY' OR v.redo>512000 OR v.sendq>512000 OR v.lag>60 THEN 'WARNING' ELSE 'OK' END AS [Severity],
CASE WHEN v.su=1 THEN 'Suspended' WHEN v.cs='DISCONNECTED' THEN 'Disconnected' WHEN v.redo>512000 THEN 'Redo>500MB' WHEN v.sendq>512000 THEN 'SendQ>500MB' ELSE 'OK' END AS [Action],@Now AS [AsOf]
FROM sys.dm_hadr_database_replica_states drs INNER JOIN sys.databases d ON d.database_id=drs.database_id INNER JOIN sys.availability_replicas ar ON drs.replica_id=ar.replica_id INNER JOIN sys.availability_groups ag ON drs.group_id=ag.group_id INNER JOIN sys.dm_hadr_availability_replica_states ars ON ars.group_id=drs.group_id AND ars.replica_id=drs.replica_id CROSS APPLY(VALUES(ISNULL(drs.secondary_lag_seconds,0),drs.synchronization_health_desc,drs.is_suspended,drs.redo_queue_size,drs.log_send_queue_size,ars.connected_state_desc,ar.availability_mode_desc))v(lag,sh,su,redo,sendq,cs,am)
WHERE ars.role_desc='SECONDARY' AND d.database_id>4 AND (@DB IS NULL OR d.name=@DB)
ORDER BY CASE WHEN v.su=1 OR v.cs='DISCONNECTED' THEN 0 WHEN v.sh IN('NOT_HEALTHY','PARTIALLY_HEALTHY') THEN 1 ELSE 2 END,ag.name,d.name,ar.replica_server_name OPTION (MAXDOP 1);
END
ELSE SELECT 'SQL_SERVER' AS [Platform],'No AG' AS [Action],'INFO' AS [Severity],@Now AS [AsOf];
RETURN; END;
SELECT CASE @EE WHEN 12 THEN 'FABRIC' ELSE 'UNKNOWN' END AS [Platform],'Managed' AS [Action],'INFO' AS [Severity],@Now AS [AsOf];
```
Grade: HEALTHY/DEGRADED/CRITICAL. Decision: GO/GO_MANUAL/GO_WITH_RISK/GO_WITH_DATA_LOSS/NO_GO/CAUTION. RPO=0 only with sync-commit SYNCHRONIZED.
