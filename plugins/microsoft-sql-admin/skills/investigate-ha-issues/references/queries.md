# HA Investigation — SQL Queries

Run each query with the SQL query tool. Replace {{parameter}} placeholders with values from the skill parameters (escape `'` as `''` in string values such as the AG name).

### Step 1: Platform Detection and HA Capability

Run with the SQL query tool. Identifies the SQL Server edition, version, and HA
support level. This determines which subsequent steps are applicable.

```sql
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
SELECT
    CAST(SERVERPROPERTY('Edition') AS NVARCHAR(128)) AS sql_edition,
    CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(128)) AS sql_version,
    @EngineEdition AS engine_edition,
    CAST(SERVERPROPERTY('IsHadrEnabled') AS INT) AS is_hadr_enabled,
    CAST(SERVERPROPERTY('HadrManagerStatus') AS INT) AS hadr_manager_status,
    CASE @EngineEdition
        WHEN 1 THEN 'Personal/Desktop - AG not supported'
        WHEN 2 THEN 'Standard - Basic AG only (SQL 2016+)'
        WHEN 3 THEN 'Enterprise - Full AG support'
        WHEN 4 THEN 'Express - AG not supported'
        WHEN 5 THEN 'Azure SQL Database'
        WHEN 6 THEN 'Azure Synapse - AG not applicable'
        WHEN 8 THEN 'Azure SQL Managed Instance'
        WHEN 9 THEN 'Azure SQL Edge'
        WHEN 11 THEN 'Azure Synapse serverless - AG not applicable'
        WHEN 12 THEN 'Fabric SQL Database'
        ELSE 'Unknown'
    END AS ha_support_level;
```

**What to do:**

| Condition | Action |
|-----------|--------|
| `engine_edition` IN (1, 4, 6, 9, 11) | AG not supported on this edition. This skill is not applicable. Inform the user and stop. |
| `engine_edition` IN (2, 3, 8) AND `is_hadr_enabled` = 0 | AG feature is disabled. Advise enabling via SQL Server Configuration Manager (on-prem) or instance configuration (MI). On Standard edition (2), only Basic AGs are supported (SQL 2016+). |
| `engine_edition` IN (2, 3, 8) AND `is_hadr_enabled` = 1 | AG is enabled. Proceed with Steps 2–11. |
| `engine_edition` = 5 (Azure SQL Database) | Built-in HA; no user-visible AG DMVs. Skip Steps 2–11. Jump to **Step 12** for geo-replication status. |
| `engine_edition` = 12 (Fabric SQL Database) | Built-in HA managed by Fabric. Skip Steps 2–11. Jump to **Step 12** for geo-replication status. |
| `hadr_manager_status` = 0 or NULL | HADR manager is not started. AG may be misconfigured. Check Windows failover cluster service. |

---

### Step 2: AG Configuration Overview

Run with the SQL query tool. Shows the configuration of all availability groups
and their replicas, including failover settings and session timeouts.

```sql
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

-- Guard: AG DMVs not available on Azure SQL DB (5) or Fabric (12)
IF @EngineEdition NOT IN (5, 12)
BEGIN
    SELECT
          ag.name                              AS ag_name
        , ag.automated_backup_preference_desc  AS backup_preference
        , ag.failure_condition_level           AS failure_condition_level
        , ag.health_check_timeout              AS health_check_timeout_ms
        , ar.replica_server_name
        , ar.availability_mode_desc            AS sync_mode
        , ar.failover_mode_desc                AS failover_mode
        , ar.session_timeout                   AS session_timeout_sec
        , ar.primary_role_allow_connections_desc AS primary_connections
        , ar.secondary_role_allow_connections_desc AS secondary_connections
        , ar.seeding_mode_desc                 AS seeding_mode
        , ar.endpoint_url
        , ar.backup_priority
    FROM sys.availability_groups AS ag
    JOIN sys.availability_replicas AS ar
        ON ag.group_id = ar.group_id
    WHERE ag.name = COALESCE(NULLIF('{{AGName}}', ''), ag.name)
    ORDER BY ag.name, ar.replica_server_name
    OPTION (MAXDOP 1);
END
```

**What to do:**

| Condition | Action |
|-----------|--------|
| `failure_condition_level` = 5 (most aggressive) | AG will fail over on any server error. Consider lowering to 3 (default) unless strict RTO is required. Level 1 = only on SQL Server service down. |
| `failure_condition_level` = 1 (least aggressive) | AG only fails over when SQL Server service is down. May miss health issues. Consider level 3 for balanced detection. |
| `session_timeout_sec` < 10 | Very aggressive timeout — may cause false failovers on busy networks. Default is 10 seconds. |
| `session_timeout_sec` > 30 | Slow detection of replica disconnection. Consider 10–20 seconds for most environments. |
| `sync_mode` = 'ASYNCHRONOUS_COMMIT' | Data loss possible on failover. Ensure this is intentional (e.g., DR replica in remote site). |
| `failover_mode` = 'AUTOMATIC' with `sync_mode` = 'ASYNCHRONOUS_COMMIT' | Invalid combination — automatic failover requires synchronous commit. |
| `seeding_mode` = 'AUTOMATIC' | Databases will be auto-seeded to new replicas. Monitor with Step 11. If seeding fails repeatedly, switch to MANUAL and use backup/restore. |
| `health_check_timeout_ms` < 30000 | Below default (30s). May cause unnecessary failovers during transient resource pressure. |

---

### Step 3: AG and Replica Health Status

Run with the SQL query tool. Shows the current health and connectivity state of
each replica in the availability group.

```sql
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

IF @EngineEdition NOT IN (5, 12)
BEGIN
    SELECT
          ag.name                                  AS ag_name
        , ar.replica_server_name
        , ars.role_desc                            AS current_role
        , ars.operational_state_desc               AS operational_state
        , ars.connected_state_desc                 AS connected_state
        , ars.synchronization_health_desc          AS sync_health
        , ars.recovery_health_desc                 AS recovery_health
        , ars.last_connect_error_number            AS last_error_number
        , ars.last_connect_error_description       AS last_error_description
        , ars.last_connect_error_timestamp         AS last_error_time
    FROM sys.dm_hadr_availability_replica_states AS ars
    JOIN sys.availability_replicas AS ar
        ON ars.replica_id = ar.replica_id
    JOIN sys.availability_groups AS ag
        ON ar.group_id = ag.group_id
    WHERE ag.name = COALESCE(NULLIF('{{AGName}}', ''), ag.name)
    ORDER BY ag.name, ar.replica_server_name
    OPTION (MAXDOP 1);
END
```

**What to do:**

| Condition | Action |
|-----------|--------|
| `current_role` = 'RESOLVING' | Failover in progress or AG is stuck in role resolution. If persists > 5 minutes, investigate cluster health (Step 10) and failover history (Step 6). This is **critical**. |
| `connected_state` = 'DISCONNECTED' | Replica cannot communicate with primary. Check network connectivity, endpoint status (Step 7), firewall rules, and Windows Failover Cluster service. |
| `sync_health` = 'NOT_HEALTHY' | One or more databases on this replica are not synchronizing. Drill into Step 4 for per-database details. |
| `sync_health` = 'PARTIALLY_HEALTHY' | Some databases are healthy, others are not. Check Step 4 to identify which databases are lagging. |
| `operational_state` = 'PENDING_FAILOVER' | Failover is pending. Monitor closely. If stuck, check cluster quorum. |
| `operational_state` IS NULL or `recovery_health` IS NULL | Replica state information unavailable — replica may be offline or unreachable. |
| `last_error_number` IS NOT NULL | Recent connection error. Review `last_error_description` for root cause (auth failures, endpoint config, etc.). |

---

### Step 4: Database Replica States — Sync, Redo Queue, Log Send Queue

Run with the SQL query tool. This is the **most important step** — shows per-database
synchronization status, redo queue depth, log send queue depth, and estimated data loss / failover time.

```sql
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

IF @EngineEdition NOT IN (5, 12)
BEGIN
    SELECT
          ag.name                                  AS ag_name
        , ar.replica_server_name
        , DB_NAME(drs.database_id)                 AS database_name
        , drs.is_local
        , drs.is_primary_replica
        , drs.synchronization_state_desc           AS sync_state
        , drs.synchronization_health_desc          AS sync_health
        , drs.suspend_reason_desc                  AS suspend_reason
        , CAST(drs.log_send_queue_size AS BIGINT)  AS log_send_queue_size_kb
        , CAST(drs.log_send_rate AS BIGINT)        AS log_send_rate_kb_sec
        , CAST(drs.redo_queue_size AS BIGINT)      AS redo_queue_size_kb
        , CAST(drs.redo_rate AS BIGINT)            AS redo_rate_kb_sec
        , CAST(
            CAST(drs.redo_queue_size AS BIGINT) * 1.0
            / NULLIF(CAST(drs.redo_rate AS BIGINT), 0)
          AS DECIMAL(18,1))                        AS estimated_redo_completion_sec
        , CAST(
            CAST(drs.log_send_queue_size AS BIGINT) * 1.0
            / NULLIF(CAST(drs.log_send_rate AS BIGINT), 0)
          AS DECIMAL(18,1))                        AS estimated_log_drain_sec
        , CASE
            WHEN ar.availability_mode_desc = 'ASYNCHRONOUS_COMMIT'
            THEN DATEDIFF(SECOND, drs.last_commit_time, GETUTCDATE())
            ELSE NULL
          END                                      AS estimated_data_loss_sec
        , drs.last_sent_time
        , drs.last_received_time
        , drs.last_hardened_time
        , drs.last_redone_time
        , drs.last_commit_time
        , drs.filestream_send_rate
    FROM sys.dm_hadr_database_replica_states AS drs
    JOIN sys.availability_replicas AS ar
        ON drs.replica_id = ar.replica_id
    JOIN sys.availability_groups AS ag
        ON ar.group_id = ag.group_id
    WHERE ag.name = COALESCE(NULLIF('{{AGName}}', ''), ag.name)
    ORDER BY ag.name, ar.replica_server_name, DB_NAME(drs.database_id)
    OPTION (MAXDOP 1);
END
```

**What to do:**

| Condition | Action |
|-----------|--------|
| `redo_queue_size_kb` > {{RedoQueueThresholdKB}} | Redo is falling behind — the secondary cannot keep up with primary changes. Check CPU, I/O, and blocking on the secondary. Consider enabling parallel redo (trace flag 3459 on SQL 2016+). |
| `log_send_queue_size_kb` > {{LogSendQueueThresholdKB}} | Network bottleneck or flow control throttling. Check network bandwidth between replicas, AG flow control counters, and whether the secondary endpoint is healthy (Step 7). |
| `sync_state` = 'NOT SYNCHRONIZING' | Database is not syncing. Check if data movement is suspended (`suspend_reason`), the replica is disconnected, or the database is in a recovery state. |
| `sync_state` = 'REVERTING' | Database is in rollback phase — typically after a failover. Monitor until it transitions to SYNCHRONIZED or SYNCHRONIZING. |
| `last_redone_time` older than {{LookbackMinutes}} minutes | Redo thread may be stuck or blocked. Query `sys.dm_exec_requests` for redo thread waits (Step 9). |
| `estimated_redo_completion_sec` > 300 | Failover would take > 5 minutes — exceeds typical RTO. Reduce redo queue by addressing secondary bottlenecks. |
| `estimated_data_loss_sec` > 30 (async replicas) | Potential data loss on failover exceeds 30 seconds. If this is a DR replica, ensure this RPO is acceptable. |
| `suspend_reason` IS NOT NULL | Data movement was explicitly suspended. Common reasons: user action, role change, or redo error. Resume with `ALTER DATABASE ... SET HADR RESUME`. |
| `estimated_log_drain_sec` > 60 | Log send queue will take > 1 minute to drain. Network may be saturated — see Step 8. |

---

### Step 5: HADR Wait Statistics Analysis

Run with the SQL query tool. Takes a snapshot of HADR-related waits over
{{SnapshotDurationSeconds}} seconds to identify HA-specific performance bottlenecks.

```sql
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

IF @EngineEdition NOT IN (5, 12)
BEGIN
    -- Snapshot 1: Capture baseline HADR wait stats
    IF OBJECT_ID('tempdb..#HADRWaitSnap1') IS NOT NULL
        DROP TABLE #HADRWaitSnap1;

    SELECT
          wait_type
        , CAST(waiting_tasks_count AS BIGINT) AS waiting_tasks_count
        , CAST(wait_time_ms AS BIGINT)        AS wait_time_ms
        , CAST(signal_wait_time_ms AS BIGINT) AS signal_wait_time_ms
    INTO #HADRWaitSnap1
    FROM sys.dm_os_wait_stats
    WHERE wait_type IN (
        'HADR_SYNC_COMMIT',
        'HADR_FILESTREAM_IOMGR_IOCOMPLETION',
        'HADR_WORK_QUEUE',
        'HADR_TIMER_TASK',
        'HADR_CLUSAPI_CALL',
        'HADR_LOGCAPTURE_WAIT',
        'HADR_NOTIFICATION_DEQUEUE',
        'HADR_TRANSPORT_DBRLIST',
        'HADR_LOG_BLOCK_FLUSH',
        'HADR_TRANSPORT_SESSION',
        'HADR_DB_COMMAND',
        'PARALLEL_REDO_TRAN_TURN',
        'PARALLEL_REDO_DRAIN_WORKER',
        'PARALLEL_REDO_WORKER_SYNC',
        'DIRTY_PAGE_TABLE_LOCK',
        'REDO_THREAD_PENDING_WORK'
    )
    OPTION (MAXDOP 1);

    -- Wait for snapshot duration (ensure a valid TIME value regardless of parameter formatting)
    DECLARE @SnapshotSeconds INT = TRY_CONVERT(INT, '{{SnapshotDurationSeconds}}');
    DECLARE @Delay TIME(0) = DATEADD(SECOND, ISNULL(@SnapshotSeconds, 30), CONVERT(TIME(0), '00:00:00'));
    WAITFOR DELAY @Delay;

    -- Snapshot 2: Capture delta
    IF OBJECT_ID('tempdb..#HADRWaitSnap2') IS NOT NULL
        DROP TABLE #HADRWaitSnap2;

    SELECT
          wait_type
        , CAST(waiting_tasks_count AS BIGINT) AS waiting_tasks_count
        , CAST(wait_time_ms AS BIGINT)        AS wait_time_ms
        , CAST(signal_wait_time_ms AS BIGINT) AS signal_wait_time_ms
    INTO #HADRWaitSnap2
    FROM sys.dm_os_wait_stats
    WHERE wait_type IN (
        'HADR_SYNC_COMMIT',
        'HADR_FILESTREAM_IOMGR_IOCOMPLETION',
        'HADR_WORK_QUEUE',
        'HADR_TIMER_TASK',
        'HADR_CLUSAPI_CALL',
        'HADR_LOGCAPTURE_WAIT',
        'HADR_NOTIFICATION_DEQUEUE',
        'HADR_TRANSPORT_DBRLIST',
        'HADR_LOG_BLOCK_FLUSH',
        'HADR_TRANSPORT_SESSION',
        'HADR_DB_COMMAND',
        'PARALLEL_REDO_TRAN_TURN',
        'PARALLEL_REDO_DRAIN_WORKER',
        'PARALLEL_REDO_WORKER_SYNC',
        'DIRTY_PAGE_TABLE_LOCK',
        'REDO_THREAD_PENDING_WORK'
    )
    OPTION (MAXDOP 1);

    -- Calculate delta
    SELECT
          s2.wait_type
        , (s2.waiting_tasks_count - ISNULL(s1.waiting_tasks_count, 0))   AS delta_waiting_tasks
        , (s2.wait_time_ms - ISNULL(s1.wait_time_ms, 0))                AS delta_wait_time_ms
        , (s2.signal_wait_time_ms - ISNULL(s1.signal_wait_time_ms, 0))  AS delta_signal_wait_ms
        , (s2.wait_time_ms - ISNULL(s1.wait_time_ms, 0))
          - (s2.signal_wait_time_ms - ISNULL(s1.signal_wait_time_ms, 0)) AS delta_resource_wait_ms
        , CAST(
            (s2.wait_time_ms - ISNULL(s1.wait_time_ms, 0)) * 1.0
            / NULLIF((s2.waiting_tasks_count - ISNULL(s1.waiting_tasks_count, 0)), 0)
          AS DECIMAL(18,2))                                               AS avg_wait_ms_per_task
    FROM #HADRWaitSnap2 AS s2
    LEFT JOIN #HADRWaitSnap1 AS s1
        ON s2.wait_type = s1.wait_type
    WHERE (s2.wait_time_ms - ISNULL(s1.wait_time_ms, 0)) > 0
    ORDER BY delta_wait_time_ms DESC
    OPTION (MAXDOP 1);

    -- Cleanup
    IF OBJECT_ID('tempdb..#HADRWaitSnap1') IS NOT NULL
        DROP TABLE #HADRWaitSnap1;

    IF OBJECT_ID('tempdb..#HADRWaitSnap2') IS NOT NULL
        DROP TABLE #HADRWaitSnap2;
END
```

**What to do:**

| Wait Type | Action |
|-----------|--------|
| `HADR_SYNC_COMMIT` high | Synchronous commit latency — the primary is waiting for the secondary to harden the log. Check network latency between replicas, secondary disk I/O performance, and redo rate. See [Troubleshooting high HADR_SYNC_COMMIT](https://docs.microsoft.com/en-us/archive/blogs/sql_server_team/troubleshooting-high-hadr_sync_commit-wait-type-with-always-on-availability-groups). |
| `HADR_LOGCAPTURE_WAIT` high | Log capture thread is waiting for new log records. Typically benign (idle), but high values during active workload may indicate log scan bottleneck. |
| `HADR_CLUSAPI_CALL` high | Cluster API calls are slow. Check Windows Failover Cluster health, cluster network latency, and quorum configuration. |
| `HADR_LOG_BLOCK_FLUSH` high | Log block flush delays. Check primary's log disk I/O performance and log write latency. |
| `PARALLEL_REDO_TRAN_TURN` high | Parallel redo contention (SQL 2016+). Consider switching to serial redo with trace flag 3459 for insert-heavy or single-threaded transaction workloads. |
| `PARALLEL_REDO_DRAIN_WORKER` or `PARALLEL_REDO_WORKER_SYNC` high | Parallel redo worker synchronization overhead. If redo rate is low despite available CPU, try serial redo (TF 3459). |
| `DIRTY_PAGE_TABLE_LOCK` high | Redo thread contention with reader queries on a readable secondary. Apply the latest cumulative update for fixes, or reduce read workload during heavy redo periods. |
| `REDO_THREAD_PENDING_WORK` high | Redo thread is starved for work. May indicate log transport delays — check log send queue (Step 4). |
| `HADR_TRANSPORT_SESSION` high | Transport session overhead. Check network stability and endpoint configuration (Step 7). |

---

### Step 6: Failover History from Ring Buffers

Run with the SQL query tool. Queries the AlwaysOn_health Extended Events session
ring buffer for recent replica state changes and failover events.

```sql
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

IF @EngineEdition NOT IN (5, 12)
BEGIN
    -- Replica state change events from AlwaysOn_health XE session
    SELECT
        xel.value('(@timestamp)[1]', 'DATETIME2')                                   AS event_time_utc,
        xel.value('(data[@name="availability_group_name"]/value)[1]', 'VARCHAR(128)')  AS ag_name,
        xel.value('(data[@name="availability_replica_name"]/value)[1]', 'VARCHAR(128)') AS replica_name,
        xel.value('(data[@name="previous_state"]/text)[1]', 'VARCHAR(50)')             AS previous_state,
        xel.value('(data[@name="current_state"]/text)[1]', 'VARCHAR(50)')              AS current_state
    FROM (
        SELECT CAST(target_data AS XML) AS target_data
        FROM sys.dm_xe_sessions AS s
        JOIN sys.dm_xe_session_targets AS t
            ON s.address = t.event_session_address
        WHERE s.name = 'AlwaysOn_health'
          AND t.target_name = 'ring_buffer'
    ) AS rb
    CROSS APPLY target_data.nodes('RingBufferTarget/event[@name="availability_replica_state_change"]') AS xevents(xel)
    WHERE xel.value('(@timestamp)[1]', 'DATETIME2') >= DATEADD(MINUTE, -{{LookbackMinutes}}, GETUTCDATE())
    ORDER BY event_time_utc DESC
    OPTION (MAXDOP 1);

    -- Also check SQL Server error log for AG-related errors (requires elevated permissions)
    -- Error 19407: lease timeout
    -- Error 35206: connection timeout
    -- Error 35201: AG join error
    -- Error 41050: waiting for local WSFC to start
    IF IS_SRVROLEMEMBER('sysadmin') = 1
    BEGIN
        -- EXEC arguments must be constants or variables, so compute the start time first.
        DECLARE @ErrorLogSince datetime = DATEADD(MINUTE, -{{LookbackMinutes}}, GETDATE());
        EXEC sys.xp_readerrorlog 0, 1, N'Availability', NULL, @ErrorLogSince, NULL, N'DESC';
    END
    ELSE
    BEGIN
        SELECT
            'Skipping sys.xp_readerrorlog due to insufficient permissions (requires sysadmin). Review SQL Server error log via SSMS/portal, or ask a sysadmin to run this step.' AS info_message;
    END
END
```

**What to do:**

| Condition | Action |
|-----------|--------|
| Frequent state changes (> 3 in {{LookbackMinutes}} min) | AG is unstable. Investigate root cause: lease timeouts, cluster issues, resource pressure, or network instability. |
| RESOLVING → PRIMARY transitions | Failovers occurred. Correlate timestamps with workload events, maintenance windows, or infrastructure changes. |
| Error 19407 in error log | **Lease timeout** — the AG lease between SQL Server and WSFC expired. Common causes: CPU starvation, VM live migration, clock skew, or aggressive `health_check_timeout`. |
| Error 35206 in error log | **Connection timeout** — a replica connection timed out. Check network connectivity and `session_timeout` setting (Step 2). |
| Error 35201 in error log | **AG join error** — a database failed to join the AG. Check database state, log chain, and seeding (Step 11). |
| No AlwaysOn_health session running | The `AlwaysOn_health` XE session is not active. Enable it with `ALTER EVENT SESSION AlwaysOn_health ON SERVER STATE = START;` — it is critical for AG diagnostics. |

---

### Step 7: AG Endpoint and Transport Health

Run with the SQL query tool. Checks the database mirroring endpoint configuration
and status, which is used for AG replica communication.

```sql
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

IF @EngineEdition NOT IN (5, 12)
BEGIN
    SELECT
          e.name                     AS endpoint_name
        , e.endpoint_id
        , e.state_desc              AS endpoint_state
        , e.protocol_desc
        , te.port
        , e.type_desc
        , te.ip_address
        , me.connection_auth_desc   AS authentication
        , me.encryption_algorithm_desc AS encryption
        , me.role_desc              AS endpoint_role
        , me.is_encryption_enabled
    FROM sys.database_mirroring_endpoints AS me
    JOIN sys.endpoints AS e
        ON me.endpoint_id = e.endpoint_id
    JOIN sys.tcp_endpoints AS te
        ON e.endpoint_id = te.endpoint_id
        OPTION (MAXDOP 1);
END
```

**What to do:**

| Condition | Action |
|-----------|--------|
| `endpoint_state` = 'STOPPED' | AG endpoint is not running — all replica communication is blocked. Start with `ALTER ENDPOINT [name] STATE = STARTED;`. |
| `endpoint_state` = 'DISABLED' | Endpoint is disabled. Enable and start it. |
| No rows returned | No database mirroring endpoint exists. Create one — AG requires a mirroring endpoint. |
| `authentication` mismatch between replicas | All replicas must use compatible authentication (CERTIFICATE or WINDOWS). Mismatches cause connection failures. |
| `encryption` = 'DISABLED' | Communication is unencrypted. Enable encryption (AES recommended) for security and compliance. |
| Port blocked by firewall | If replicas are DISCONNECTED (Step 3) but endpoint is STARTED, check firewall rules for the endpoint port (default 5022). |

---

### Step 8: Log Send and Transport Performance

Run with the SQL query tool. Provides a focused view of log send performance
per database, including queue depth and estimated time to drain.

```sql
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

IF @EngineEdition NOT IN (5, 12)
BEGIN
    SELECT
          ag.name                                  AS ag_name
        , ar.replica_server_name
        , DB_NAME(drs.database_id)                 AS database_name
        , ar.availability_mode_desc                AS sync_mode
        , CAST(drs.log_send_queue_size AS BIGINT)  AS log_send_queue_size_kb
        , CAST(drs.log_send_rate AS BIGINT)        AS log_send_rate_kb_sec
        , CAST(
            CAST(drs.log_send_queue_size AS BIGINT) * 1.0
            / NULLIF(CAST(drs.log_send_rate AS BIGINT), 0)
          AS DECIMAL(18,1))                        AS time_to_drain_sec
        , drs.last_sent_time
        , drs.last_received_time
        , drs.last_hardened_time
        , DATEDIFF(MILLISECOND, drs.last_sent_time, drs.last_received_time) AS send_to_receive_latency_ms
        , DATEDIFF(MILLISECOND, drs.last_received_time, drs.last_hardened_time) AS receive_to_harden_latency_ms
    FROM sys.dm_hadr_database_replica_states AS drs
    JOIN sys.availability_replicas AS ar
        ON drs.replica_id = ar.replica_id
    JOIN sys.availability_groups AS ag
        ON ar.group_id = ag.group_id
    WHERE drs.is_local = 0  -- Remote replicas only (log send is outbound)
      AND ag.name = COALESCE(NULLIF('{{AGName}}', ''), ag.name)
    ORDER BY log_send_queue_size_kb DESC
    OPTION (MAXDOP 1);
END
```

**What to do:**

| Condition | Action |
|-----------|--------|
| `time_to_drain_sec` > 60 | Network is the bottleneck. Check network bandwidth between replicas, NIC configuration, and whether other traffic is saturating the link. |
| `log_send_queue_size_kb` trending up across snapshots | Log generation rate exceeds send rate. Consider: increasing network bandwidth, enabling log compression (SQL 2016+), or reducing write workload on primary. |
| `send_to_receive_latency_ms` consistently > 5 ms | Network latency between replicas is high. For synchronous commit, this directly impacts commit latency. Consider switching to async mode for remote replicas. |
| `receive_to_harden_latency_ms` consistently > 10 ms | Secondary disk I/O is slow for log hardening. Check secondary log disk performance (IOPS, latency). |
| `log_send_rate_kb_sec` = 0 with non-zero queue | Log transport is stalled. Check endpoint health (Step 7) and network connectivity. |

---

### Step 9: Redo Thread Analysis on Secondary

Run with the SQL query tool. Inspects what the redo thread is currently doing,
including any waits or blocking. **Best run when connected to the secondary replica.**

```sql
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

IF @EngineEdition NOT IN (5, 12)
BEGIN
    SELECT
          r.session_id
        , r.command
        , r.status
        , r.wait_type
        , r.wait_time                              AS wait_time_ms
        , r.wait_resource
        , r.blocking_session_id
        , DB_NAME(r.database_id)                   AS database_name
        , ar.secondary_role_allow_connections_desc  AS readable_secondary
        , r.total_elapsed_time / 1000              AS elapsed_sec
        , r.cpu_time                               AS cpu_time_ms
        , r.reads                                  AS physical_reads
        , r.writes                                 AS physical_writes
    FROM sys.dm_exec_requests AS r
    LEFT JOIN sys.dm_hadr_database_replica_states AS drs
        ON r.database_id = drs.database_id AND drs.is_local = 1
    LEFT JOIN sys.availability_replicas AS ar
        ON drs.replica_id = ar.replica_id
    WHERE r.command IN ('DB STARTUP', 'PARALLEL REDO HELP TASK', 'UNKNOWN TOKEN')
       OR r.wait_type LIKE 'HADR%'
       OR r.wait_type LIKE 'PARALLEL_REDO%'
       OR r.wait_type = 'REDO_THREAD_PENDING_WORK'
       OR r.wait_type = 'DIRTY_PAGE_TABLE_LOCK'
    ORDER BY r.wait_time DESC
    OPTION (MAXDOP 1);
END
```

**What to do:**

| Condition | Action |
|-----------|--------|
| Redo thread waiting on `DIRTY_PAGE_TABLE_LOCK` | Reader queries on the readable secondary are blocking the redo thread. Check `readable_secondary` column — if `ALL` or `READ_ONLY`, user queries are the likely cause. Reduce read workload during heavy redo periods, or apply latest CU which includes fixes for this contention. |
| Redo thread waiting on I/O waits (`PAGEIOLATCH_*`, `WRITELOG`) | Secondary disk performance is insufficient. Check disk latency, IOPS capacity, and consider faster storage. |
| `PARALLEL_REDO_TRAN_TURN` wait | Parallel redo contention — typically for insert-heavy serial transaction patterns. Try serial redo with trace flag 3459: `DBCC TRACEON(3459, -1);` |
| `REDO_THREAD_PENDING_WORK` | Redo thread is idle waiting for work. If redo queue is large (Step 4), check log transport (Step 8) — log blocks may not be arriving. |
| `blocking_session_id` IS NOT NULL and > 0 | A user query is blocking the redo thread. Identify the blocking session and consider terminating it if redo queue is critical. |
| No redo thread rows returned | Either this is the primary replica (redo runs on secondaries only) or the AG database is suspended. Verify connection target. |

---

### Step 10: Cluster Health (On-Premises / IaaS Only)

Run with the SQL query tool. Queries WSFC cluster health information.
**Only applicable for on-premises SQL Server and IaaS VMs — not Azure SQL MI, Azure SQL DB, or Fabric.**

```sql
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

-- Only run on box-product SQL Server (editions 2, 3)
IF @EngineEdition IN (2, 3)
BEGIN
    -- Cluster overview
    SELECT
          cluster_name
        , quorum_type_desc
        , quorum_state_desc
    FROM sys.dm_hadr_cluster
    OPTION (MAXDOP 1);

    -- Cluster member health
    SELECT
          member_name
        , member_type_desc
        , member_state_desc
        , number_of_quorum_votes
    FROM sys.dm_hadr_cluster_members
    OPTION (MAXDOP 1);

    -- Cluster network configuration
    SELECT
          member_name
        , network_subnet_ip
        , network_subnet_ipv4_mask
        , is_public
        , is_ipv4
    FROM sys.dm_hadr_cluster_networks
    OPTION (MAXDOP 1);
END
```

**What to do:**

| Condition | Action |
|-----------|--------|
| `quorum_state_desc` != 'NORMAL_QUORUM' | Cluster does not have quorum. AG will not function correctly. Restore cluster quorum immediately. |
| `member_state_desc` = 'DOWN' for any member | A cluster node is offline. Investigate node health, network connectivity, and Windows Failover Cluster service. |
| `quorum_type_desc` = 'NODE_MAJORITY' without witness | No witness configured. For even-numbered node clusters, add a disk or cloud witness for better fault tolerance. |
| `cluster_name` is NULL or empty | Cluster information unavailable. Verify WSFC is properly configured and SQL Server has permissions to access it. |
| Only one node in `dm_hadr_cluster_members` | Single-node cluster — no redundancy. AG requires at least two nodes for HA. |
| `is_public` = 0 for all cluster networks | No public cluster network — may impact client connectivity to AG listener. |

---

### Step 11: Seeding Progress Monitoring

Run with the SQL query tool. Monitors automatic seeding status for databases
being added to the availability group. **Available on SQL Server 2016+ and Azure SQL MI.**

```sql
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @Version INT = CAST(PARSENAME(CAST(SERVERPROPERTY('ProductVersion') AS VARCHAR(20)), 4) AS INT);

-- dm_hadr_automatic_seeding + dm_hadr_physical_seeding_stats available on SQL 2016+ (version 13+) and MI (edition 8)
IF @EngineEdition NOT IN (5, 12)
   AND (@EngineEdition = 8 OR @Version >= 13)
BEGIN
    SELECT
          ag.name                                      AS ag_name
        , DB_NAME(drs.database_id)                     AS database_name
        , drs.is_primary_replica
        , drs.synchronization_state_desc               AS sync_state
        , drs.synchronization_health_desc              AS sync_health
        , das.current_state                            AS seeding_state
        , das.start_time                               AS seeding_start_time
        , das.completion_time                          AS seeding_completion_time
        , das.failure_state_desc
        , pss.internal_state_desc                      AS physical_seeding_state
        , CAST(pss.transfer_rate_bytes_per_second / 1024 / 1024 AS DECIMAL(10,1)) AS transfer_rate_mb_sec
        , CAST(pss.transferred_size_bytes / 1048576 AS BIGINT)   AS transferred_mb
        , CAST(pss.database_size_bytes / 1048576 AS BIGINT)      AS database_size_mb
        , CAST(
            100.0 * pss.transferred_size_bytes
            / NULLIF(pss.database_size_bytes, 0)
          AS DECIMAL(5,1))                             AS pct_complete
        , pss.start_time_utc                           AS physical_start_time_utc
        , pss.end_time_utc                             AS physical_end_time_utc
        , pss.error_code
    FROM sys.dm_hadr_automatic_seeding AS das
    LEFT JOIN sys.dm_hadr_physical_seeding_stats AS pss
        ON das.ag_id = pss.ag_id
       AND das.ag_db_id = pss.ag_db_id
    JOIN sys.dm_hadr_database_replica_states AS drs
        ON das.ag_db_id = drs.group_database_id
    JOIN sys.availability_groups AS ag
        ON drs.group_id = ag.group_id
    WHERE das.start_time IS NOT NULL
      AND ag.name = COALESCE(NULLIF('{{AGName}}', ''), ag.name)
    ORDER BY das.start_time DESC
    OPTION (MAXDOP 1);
END
```

**What to do:**

| Condition | Action |
|-----------|--------|
| `failure_state_desc` IS NOT NULL | Seeding failed. Common error codes: 3257 (disk full — free space on secondary), 33111 (certificate missing — configure endpoint certificates), 17 (timeout — check network). |
| `transfer_rate_mb_sec` < 10 on fast network | Network bottleneck during seeding. Check if other AG traffic is competing, or if network bandwidth is limited between replicas. |
| `pct_complete` stuck at same value | Seeding may be stalled. Check `error_code` for details. Cancel and retry, or switch to manual seeding via backup/restore. |
| `seeding_state` = 'completed' but `sync_state` != 'SYNCHRONIZED' | Seeding finished but database hasn't caught up. Allow time for redo to process, or check redo thread (Step 9). |
| `transfer_rate_mb_sec` / `pct_complete` are NULL | Physical seeding stats not available — seeding may have completed and stats expired, or `sys.dm_hadr_physical_seeding_stats` is not populated on this replica. Use `seeding_state` and `seeding_completion_time` for status. |
| No rows returned | No automatic seeding in progress or history. If expecting seeding, verify `seeding_mode` = 'AUTOMATIC' in Step 2 and check AG error log. |

---

### Step 12: Azure SQL DB and Fabric Geo-Replication Status

Run with the SQL query tool. For Azure SQL Database (engine_edition = 5) and
Fabric SQL Database (engine_edition = 12), AG DMVs are not available. Use geo-replication
DMVs instead.

```sql
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

IF @EngineEdition IN (5, 12)
BEGIN
    -- Active geo-replication link status (DMV may not exist on Fabric)
    IF OBJECT_ID('sys.dm_geo_replication_link_status') IS NOT NULL
    BEGIN
        SELECT
              link_guid
            , partner_server
            , partner_database
            , last_replication
            , replication_lag_sec
            , replication_state_desc
            , role_desc
            , secondary_allow_connections_desc
        FROM sys.dm_geo_replication_link_status
        OPTION (MAXDOP 1);
    END
    ELSE
    BEGIN
        SELECT 'sys.dm_geo_replication_link_status is not available on this platform. Geo-replication status cannot be queried.' AS info_message;
    END

    -- Geo-replication link configuration (DMV may not exist on Fabric)
    IF OBJECT_ID('sys.geo_replication_links') IS NOT NULL
    BEGIN
        SELECT
              database_id
            , start_date
            , modify_date
            , partner_server
            , partner_database
            , replication_state_desc
        FROM sys.geo_replication_links
        OPTION (MAXDOP 1);
    END
END
```

**What to do:**

| Condition | Action |
|-----------|--------|
| `replication_lag_sec` > 30 | Geo-replication is lagging significantly. Check primary workload intensity — high transaction rates can cause the secondary to fall behind. Consider scaling up the secondary tier. |
| `replication_state_desc` = 'CATCH_UP' for extended period | Secondary is catching up but not yet synchronized. Monitor `replication_lag_sec` trend. If not decreasing, secondary may need a higher service tier. |
| `replication_state_desc` = 'SEEDING' | Initial seeding is in progress. Wait for completion — this is normal for newly added geo-replicas. |
| `replication_state_desc` = 'SUSPENDED' | Replication is suspended. This may indicate a connectivity issue or an intentional pause. Resume via Azure portal or T-SQL. |
| No rows returned | No geo-replication configured on this database. If HA is expected, configure active geo-replication or use auto-failover groups. |
| `role_desc` = 'SECONDARY' | Connected to the secondary database. For full status, also query from the primary. |

---
