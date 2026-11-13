# SQL Server AG Queries

Run each query with the SQL query tool. SQL CASE columns produce inline PASS/FAIL/WARNING verdicts. Before running, replace `{{AGName}}` with the AG name (escape `'` as `''`), or with an empty string to assess all AGs.

---

## Step 2: Cluster Health

> **Guard:** `IsHadrEnabled = 1` AND `EngineEdition IN (2, 3)`. On-Prem/IaaS only (Windows Server Failover Cluster).
> Linux-based AG clusters (Pacemaker/Corosync) are not covered by these DMVs — advise the user to validate cluster health via `pcs status` or `crm status` on the OS.

```sql
-- Cluster configuration
SELECT
    cluster_name,
    quorum_type_desc,
    quorum_state_desc
FROM sys.dm_hadr_cluster
OPTION (MAXDOP 1);

-- Member status and vote weight
SELECT
    member_name,
    member_type_desc,
    member_state_desc,
    number_of_quorum_votes
FROM sys.dm_hadr_cluster_members
OPTION (MAXDOP 1);

-- Network connectivity between nodes
SELECT
    member_name,
    network_subnet_ip,
    network_subnet_ipv4_mask,
    is_public,
    is_ipv4
FROM sys.dm_hadr_cluster_networks
OPTION (MAXDOP 1);
```

**Interpret:** PASS if quorum type ≠ UNKNOWN, all members UP, odd total vote count, and a witness resource is configured (file share witness, cloud witness, or disk witness — best practice is to always configure a witness resource on WS2012+). WARNING if no witness resource is configured regardless of node count. FAIL if quorum is UNKNOWN or any member is not UP.

---

## Step 3: AG Configuration

> **Guard:** `IsHadrEnabled = 1` AND `EngineEdition IN (2, 3)`. For MI (8), run **only when an MI-link AG exists** — a standalone MI's platform-managed HA is not exposed via these AG DMVs, so empty results are expected (not a failure; assess via Step 10). Skip for Express (4), Azure SQL DB, Fabric.

**AG-level health rollup** (run first — `sys.dm_hadr_availability_group_states` gives the top-level synchronization verdict):

```sql
DECLARE @AGName NVARCHAR(128) = NULLIF(N'{{AGName}}', N'');

SELECT
    ag.name AS ag_name,
    ags.primary_replica,
    ags.primary_recovery_health_desc,
    ags.secondary_recovery_health_desc,
    ags.synchronization_health_desc,
    CASE WHEN ags.synchronization_health_desc = 'HEALTHY' THEN 'PASS'
         WHEN ags.synchronization_health_desc = 'PARTIALLY_HEALTHY'
              THEN 'WARNING: AG partially healthy — at least one replica is not in its target synchronization state'
         ELSE 'FAIL: AG not healthy — synchronization is broken on one or more replicas' END AS ag_health_assessment
FROM sys.dm_hadr_availability_group_states ags
JOIN sys.availability_groups ag ON ags.group_id = ag.group_id
WHERE (@AGName IS NULL OR ag.name = @AGName)
ORDER BY ag.name
OPTION (MAXDOP 1);
```

**AG and replica configuration:**

```sql
DECLARE @AGName NVARCHAR(128) = NULLIF(N'{{AGName}}', N'');

SELECT
    ag.name AS ag_name,
    ag.failure_condition_level,
    ag.health_check_timeout,
    ag.automated_backup_preference_desc,
    ar.replica_server_name,
    ar.availability_mode_desc,
    ar.failover_mode_desc,
    ar.session_timeout,
    ar.primary_role_allow_connections_desc,
    ar.secondary_role_allow_connections_desc,
    ar.backup_priority,
    -- Assessment verdicts
    CASE WHEN ag.failure_condition_level > 3
         THEN 'WARNING: Aggressive failure detection (level '
              + CAST(ag.failure_condition_level AS VARCHAR) + ') may cause unnecessary failovers'
         WHEN ag.failure_condition_level = 1
         THEN 'WARNING: Minimal failure detection — only detects SQL Server process down'
         ELSE 'PASS' END AS failure_level_assessment,
    CASE WHEN ag.health_check_timeout < 30000
         THEN 'WARNING: Health check timeout < 30s may cause false failovers'
         WHEN ag.health_check_timeout > 120000
         THEN 'INFO: High timeout — slow failure detection'
         ELSE 'PASS' END AS health_timeout_assessment,
    CASE WHEN ar.session_timeout < 10
         THEN 'WARNING: Session timeout < 10s — risk of false disconnects'
         WHEN ar.session_timeout > 30
         THEN 'INFO: High session timeout — slow disconnect detection'
         ELSE 'PASS' END AS session_timeout_assessment,
    CASE WHEN ar.availability_mode_desc = 'SYNCHRONOUS_COMMIT'
              AND ar.failover_mode_desc = 'MANUAL'
         THEN 'INFO: Synchronous replica with manual failover — automatic failover not enabled'
         WHEN ar.availability_mode_desc = 'ASYNCHRONOUS_COMMIT'
              AND ar.failover_mode_desc = 'AUTOMATIC'
         THEN 'FAIL: Cannot have automatic failover with asynchronous commit'
         ELSE 'PASS' END AS failover_mode_assessment
FROM sys.availability_groups ag
JOIN sys.availability_replicas ar ON ag.group_id = ar.group_id
WHERE (@AGName IS NULL OR ag.name = @AGName)
ORDER BY ag.name, ar.replica_server_name
OPTION (MAXDOP 1);

-- SQL Server 2016+ (v13) only: db_failover, seeding_mode
-- required_synchronized_secondaries_to_commit is SQL Server 2017+ (v14) only — guarded separately below
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS INT) >= 13
BEGIN
    DECLARE @AGName2 NVARCHAR(128) = NULLIF(N'{{AGName}}', N'');

    -- Column exists only on v14+; project NULL on v13 so the query stays valid there.
    DECLARE @rsstcColumn NVARCHAR(200) =
        CASE WHEN CAST(SERVERPROPERTY('ProductMajorVersion') AS INT) >= 14
             THEN N'ag.required_synchronized_secondaries_to_commit'
             ELSE N'CAST(NULL AS INT) AS required_synchronized_secondaries_to_commit'
        END;

    DECLARE @sql NVARCHAR(MAX) = N'
    SELECT
        ag.name AS ag_name,
        ag.db_failover,
        ' + @rsstcColumn + N',
        ar.replica_server_name,
        ar.seeding_mode_desc,
        CASE WHEN ag.db_failover = 0
             THEN ''WARNING: DB_FAILOVER not enabled — database-level health detection disabled''
             ELSE ''PASS'' END AS db_failover_assessment
    FROM sys.availability_groups ag
    JOIN sys.availability_replicas ar ON ag.group_id = ar.group_id
    WHERE (@AGName IS NULL OR ag.name = @AGName)
    ORDER BY ag.name, ar.replica_server_name
    OPTION (MAXDOP 1);';

    EXEC sp_executesql @sql, N'@AGName NVARCHAR(128)', @AGName2;
END
```

---

## Step 4: Failover Readiness

> **Guard:** `IsHadrEnabled = 1` AND `EngineEdition IN (2, 3)`. For MI (8), run **only when an MI-link AG exists** — a standalone MI's platform-managed HA is not exposed via these AG DMVs, so empty results are expected (not a failure; assess via Step 10). Skip for Express (4), Azure SQL DB, Fabric.

```sql
DECLARE @AGName NVARCHAR(128) = NULLIF(N'{{AGName}}', N'');

SELECT
    ag.name AS ag_name,
    ar.replica_server_name,
    ars.role_desc,
    ar.failover_mode_desc,
    ar.availability_mode_desc,
    ars.synchronization_health_desc,
    ars.connected_state_desc,
    ars.operational_state_desc,
    -- Count databases in expected sync state (sync replicas expect SYNCHRONIZED, async expect SYNCHRONIZING)
    (SELECT COUNT(*)
     FROM sys.dm_hadr_database_replica_states drs
     WHERE drs.replica_id = ar.replica_id
       AND (
           (ar.availability_mode_desc = 'SYNCHRONOUS_COMMIT' AND drs.synchronization_state_desc = 'SYNCHRONIZED')
           OR (ar.availability_mode_desc = 'ASYNCHRONOUS_COMMIT' AND drs.synchronization_state_desc = 'SYNCHRONIZING')
       )) AS dbs_synchronized,
    (SELECT COUNT(*)
     FROM sys.dm_hadr_database_replica_states drs
     WHERE drs.replica_id = ar.replica_id
       AND (
           (ar.availability_mode_desc = 'SYNCHRONOUS_COMMIT' AND drs.synchronization_state_desc != 'SYNCHRONIZED')
           OR (ar.availability_mode_desc = 'ASYNCHRONOUS_COMMIT' AND drs.synchronization_state_desc NOT IN ('SYNCHRONIZING', 'SYNCHRONIZED'))
       )) AS dbs_not_synchronized,
    -- Redo queue check (max across all DBs for this replica)
    (SELECT MAX(drs.redo_queue_size)
     FROM sys.dm_hadr_database_replica_states drs
     WHERE drs.replica_id = ar.replica_id) AS max_redo_queue_kb,
    -- Estimated failover time (worst case redo)
    (SELECT MAX(CAST(drs.redo_queue_size AS BIGINT) / NULLIF(drs.redo_rate, 0))
     FROM sys.dm_hadr_database_replica_states drs
     WHERE drs.replica_id = ar.replica_id) AS max_estimated_redo_sec,
    -- Log send queue (un-sent log from primary = RPO / potential data-loss exposure)
    (SELECT MAX(drs.log_send_queue_size)
     FROM sys.dm_hadr_database_replica_states drs
     WHERE drs.replica_id = ar.replica_id) AS max_log_send_queue_kb,
    -- Authoritative count of databases NOT failover-ready (from WSFC cluster state)
    (SELECT COUNT(*)
     FROM sys.dm_hadr_database_replica_cluster_states drcs
     WHERE drcs.replica_id = ar.replica_id AND drcs.is_failover_ready = 0) AS dbs_not_failover_ready,
    -- Assessment
    CASE
        WHEN ars.role_desc = 'PRIMARY' THEN 'N/A (primary)'
        WHEN ars.connected_state_desc != 'CONNECTED'
            THEN 'FAIL: Replica not connected — cannot failover'
        WHEN ars.synchronization_health_desc = 'NOT_HEALTHY'
            THEN 'FAIL: Replica not healthy — failover would lose data'
        WHEN ars.role_desc <> 'PRIMARY'
             AND (SELECT COUNT(*) FROM sys.dm_hadr_database_replica_cluster_states drcs
                  WHERE drcs.replica_id = ar.replica_id AND drcs.is_failover_ready = 0) > 0
            THEN 'FAIL: One or more databases are NOT failover-ready (is_failover_ready = 0) on this replica'
        WHEN ar.availability_mode_desc = 'SYNCHRONOUS_COMMIT'
             AND (SELECT MAX(drs.log_send_queue_size) FROM sys.dm_hadr_database_replica_states drs
                  WHERE drs.replica_id = ar.replica_id) > 1024
            THEN 'WARNING: Log send queue backlog (> 1 MB) on a synchronous replica — secondary is falling behind; RPO/data-loss exposure on failover'
        WHEN ar.failover_mode_desc = 'MANUAL'
             AND ar.availability_mode_desc = 'ASYNCHRONOUS_COMMIT'
            THEN 'WARNING: Async + Manual — failover requires forced (potential data loss)'
        WHEN (SELECT COUNT(*)
              FROM sys.dm_hadr_database_replica_states drs
              WHERE drs.replica_id = ar.replica_id
                AND (
                    (ar.availability_mode_desc = 'SYNCHRONOUS_COMMIT' AND drs.synchronization_state_desc != 'SYNCHRONIZED')
                    OR (ar.availability_mode_desc = 'ASYNCHRONOUS_COMMIT' AND drs.synchronization_state_desc NOT IN ('SYNCHRONIZING', 'SYNCHRONIZED'))
                )) > 0
            THEN 'WARNING: Not all databases in expected sync state — failover may have data loss or extended RTO'
        WHEN (SELECT MAX(CAST(drs.redo_queue_size AS BIGINT) / NULLIF(drs.redo_rate, 0))
              FROM sys.dm_hadr_database_replica_states drs
              WHERE drs.replica_id = ar.replica_id) > 300
            THEN 'WARNING: Estimated redo time > 5 min — failover will exceed typical RTO'
        ELSE 'PASS: Ready for failover'
    END AS failover_readiness
FROM sys.availability_groups ag
JOIN sys.availability_replicas ar ON ag.group_id = ar.group_id
JOIN sys.dm_hadr_availability_replica_states ars ON ar.replica_id = ars.replica_id
WHERE (@AGName IS NULL OR ag.name = @AGName)
ORDER BY ag.name, ars.role_desc DESC, ar.replica_server_name
OPTION (MAXDOP 1);
```

**Automatic seeding status** (SQL Server 2016+ — run on the primary to track in-progress or failed seeding of AG databases; empty result means automatic seeding was not used, which is normal for backup/restore-initialized replicas):

```sql
DECLARE @AGName NVARCHAR(128) = NULLIF(N'{{AGName}}', N'');

SELECT
    ag.name AS ag_name,
    adc.database_name,
    seed.start_time,
    seed.completion_time,
    seed.current_state,
    seed.performed_seeding,
    seed.failure_state_desc,
    seed.number_of_attempts,
    CASE
        WHEN seed.current_state = 'FAILED'
            THEN 'FAIL: Automatic seeding failed (' + ISNULL(seed.failure_state_desc, 'unknown') + ') — secondary is not seeded'
        WHEN seed.completion_time IS NULL
            THEN 'INFO: Seeding in progress or incomplete — secondary not yet fully synchronized'
        ELSE 'PASS: Seeding completed' END AS seeding_assessment
FROM sys.dm_hadr_automatic_seeding seed
JOIN sys.availability_groups ag ON seed.ag_id = ag.group_id
JOIN sys.availability_databases_cluster adc ON seed.ag_db_id = adc.group_database_id
WHERE (@AGName IS NULL OR ag.name = @AGName)
ORDER BY seed.start_time DESC
OPTION (MAXDOP 1);
```

---

## Step 5: Listener and Connectivity

> **Guard:** `IsHadrEnabled = 1` AND `EngineEdition IN (2, 3)`. For MI (8), run **only when an MI-link AG exists** — a standalone MI has no user-queryable AG listener (failover is handled by the gateway), so `sys.availability_group_listeners` is empty by design; empty results are expected and must **not** be treated as FAIL — assess MI HA via Step 10. Skip for Express (4), Azure SQL DB, Fabric.

```sql
DECLARE @AGName NVARCHAR(128) = NULLIF(N'{{AGName}}', N'');

SELECT
    agl.dns_name AS listener_name,
    agl.port AS listener_port,
    ag.name AS ag_name,
    agl.is_distributed_network_name,
    aglip.ip_address,
    aglip.ip_subnet_mask,
    aglip.is_dhcp,
    aglip.state_desc AS ip_state,
    -- Assessments
    CASE WHEN agl.is_distributed_network_name = 1
         THEN 'PASS: DNN listener — no IP resource (resolves to node IPs directly)'
         WHEN aglip.state_desc != 'ONLINE'
         THEN 'FAIL: Listener IP not ONLINE'
         ELSE 'PASS' END AS ip_state_assessment,
    CASE WHEN agl.is_distributed_network_name = 1
         THEN 'PASS: DNN listener — DHCP not applicable'
         WHEN aglip.is_dhcp = 1
         THEN 'WARNING: Using DHCP — static IP recommended for production'
         ELSE 'PASS' END AS dhcp_assessment,
    CASE WHEN agl.port = 1433
         THEN 'PASS: Standard SQL port'
         ELSE 'INFO: Non-standard port '
              + CAST(agl.port AS VARCHAR)
              + ' — ensure applications configured'
         END AS port_assessment
FROM sys.availability_group_listeners agl
JOIN sys.availability_groups ag ON agl.group_id = ag.group_id
LEFT JOIN sys.availability_group_listener_ip_addresses aglip
    ON agl.listener_id = aglip.listener_id
WHERE (@AGName IS NULL OR ag.name = @AGName)
ORDER BY ag.name, agl.dns_name
OPTION (MAXDOP 1);
```

**Note:** Empty result = FAIL (no listener configured) — for SQL Server AGs (Engine Edition 2, 3) only. On MI (8), an empty result is expected for platform-managed HA (no MI link) and must **not** be reported as FAIL — assess MI HA via Step 10.

---

## Step 6: Endpoint Security

> **Guard:** `EngineEdition IN (2, 3)`. On-Prem/IaaS only. Skip for Azure SQL DB, MI, Fabric.

```sql
SELECT
    e.name AS endpoint_name,
    e.state_desc AS endpoint_state,
    e.type_desc,
    te.port,
    e.is_admin_endpoint,
    te.ip_address,
    dme.connection_auth_desc,
    dme.role_desc AS endpoint_role,
    dme.certificate_id,
    -- Assessments
    CASE WHEN e.state_desc != 'STARTED'
         THEN 'FAIL: Endpoint not started — AG communication blocked'
         ELSE 'PASS' END AS state_assessment,
    CASE WHEN dme.connection_auth_desc LIKE '%NTLM%'
              AND dme.connection_auth_desc NOT LIKE '%NEGOTIATE%'
         THEN 'WARNING: NTLM-only auth — consider NEGOTIATE or CERTIFICATE for cross-domain'
         ELSE 'PASS' END AS auth_assessment,
    CASE WHEN te.port = 5022
         THEN 'PASS: Standard mirroring port'
         ELSE 'INFO: Non-standard port ' + CAST(te.port AS VARCHAR)
         END AS port_assessment
FROM sys.endpoints e
JOIN sys.tcp_endpoints te ON e.endpoint_id = te.endpoint_id
JOIN sys.database_mirroring_endpoints dme ON e.endpoint_id = dme.endpoint_id
WHERE e.type_desc = 'DATABASE_MIRRORING'
OPTION (MAXDOP 1);
```

---

## Step 8: Database-Level HA Configuration

> **Guard:** `IsHadrEnabled = 1` AND `EngineEdition IN (2, 3)`. For MI (8), run **only when an MI-link AG exists** — a standalone MI's platform-managed HA is not exposed via these AG DMVs, so empty results are expected (not a failure; assess via Step 10). Skip for Express (4), Azure SQL DB, Fabric.

```sql
DECLARE @AGName NVARCHAR(128) = NULLIF(N'{{AGName}}', N'');

SELECT
    ag.name AS ag_name,
    DB_NAME(drs.database_id) AS database_name,
    drs.is_primary_replica,
    drs.synchronization_state_desc,
    drs.synchronization_health_desc,
    drs.is_suspended,
    drs.suspend_reason_desc,
    d.recovery_model_desc,
    d.is_auto_close_on,
    d.is_auto_shrink_on,
    d.page_verify_option_desc,
    -- Assessments
    CASE WHEN drs.is_suspended = 1
         THEN 'FAIL: Data movement suspended — '
              + ISNULL(drs.suspend_reason_desc, 'unknown reason')
         ELSE 'PASS' END AS suspension_assessment,
    CASE WHEN d.recovery_model_desc != 'FULL'
         THEN 'FAIL: AG databases MUST use FULL recovery model'
         ELSE 'PASS' END AS recovery_model_assessment,
    CASE WHEN d.is_auto_close_on = 1
         THEN 'WARNING: AUTO_CLOSE should be OFF for AG databases'
         ELSE 'PASS' END AS auto_close_assessment,
    CASE WHEN d.is_auto_shrink_on = 1
         THEN 'WARNING: AUTO_SHRINK should be OFF — causes fragmentation and log growth'
         ELSE 'PASS' END AS auto_shrink_assessment,
    CASE WHEN d.page_verify_option_desc != 'CHECKSUM'
         THEN 'WARNING: PAGE_VERIFY should be CHECKSUM for data integrity'
         ELSE 'PASS' END AS page_verify_assessment
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_groups ag ON drs.group_id = ag.group_id
JOIN sys.databases d ON drs.database_id = d.database_id
WHERE drs.is_local = 1
  AND (@AGName IS NULL OR ag.name = @AGName)
ORDER BY ag.name, d.name
OPTION (MAXDOP 1);
```

**Automatic page repair history** (run after the configuration query — any rows mean corrupt pages were detected and repaired from a replica, signaling a storage problem on this node):

```sql
-- Empty result = PASS (no page-corruption/repair events recorded)
SELECT
    DB_NAME(apr.database_id) AS database_name,
    apr.file_id,
    apr.page_id,
    apr.error_type,
    apr.page_status,
    apr.modification_time,
    CASE WHEN apr.page_status = 4
         THEN 'WARNING: A corrupt page was auto-repaired from a replica — investigate underlying storage on this node'
         ELSE 'INFO: Page repair entry (status ' + CAST(apr.page_status AS VARCHAR(11)) + ') — review page status' END AS page_repair_assessment
FROM sys.dm_hadr_auto_page_repair apr
ORDER BY apr.modification_time DESC
OPTION (MAXDOP 1);
```

---

## Step 9: Backup Configuration

> **Guard:** `IsHadrEnabled = 1` AND `EngineEdition IN (2, 3)`. Skip for Express (4), MI (8), Azure SQL DB, Fabric. MI is excluded because `msdb.dbo.backupset` does not record platform-managed automatic backups — only user-initiated COPY_ONLY backups, which would cause false FAIL verdicts.

```sql
DECLARE @AGName NVARCHAR(128) = NULLIF(N'{{AGName}}', N'');

SELECT
    ag.name AS ag_name,
    ag.automated_backup_preference_desc,
    ar.replica_server_name,
    ar.backup_priority,
    ars.role_desc,
    d.name AS database_name,
    (SELECT MAX(bs.backup_finish_date)
     FROM msdb.dbo.backupset bs
     WHERE bs.database_name = d.name AND bs.type = 'D') AS last_full_backup,
    (SELECT MAX(bs.backup_finish_date)
     FROM msdb.dbo.backupset bs
     WHERE bs.database_name = d.name AND bs.type = 'L') AS last_log_backup,
    -- Assessments
    CASE WHEN (SELECT MAX(bs.backup_finish_date)
               FROM msdb.dbo.backupset bs
               WHERE bs.database_name = d.name AND bs.type = 'D') IS NULL
         THEN CASE WHEN ag.automated_backup_preference_desc IN ('SECONDARY', 'SECONDARY_ONLY')
                   THEN 'WARNING: No full backup in this instance''s msdb history — automated_backup_preference is '
                        + ag.automated_backup_preference_desc
                        + '; backups likely run on a secondary. Verify on the preferred backup replica.'
                   ELSE 'FAIL: No full backup found in msdb history' END
         WHEN DATEDIFF(DAY,
              (SELECT MAX(bs.backup_finish_date)
               FROM msdb.dbo.backupset bs
               WHERE bs.database_name = d.name AND bs.type = 'D'),
              GETDATE()) > 7
         THEN 'WARNING: Last full backup > 7 days ago'
         ELSE 'PASS' END AS full_backup_assessment,
    CASE WHEN (SELECT MAX(bs.backup_finish_date)
               FROM msdb.dbo.backupset bs
               WHERE bs.database_name = d.name AND bs.type = 'L') IS NULL
         THEN CASE WHEN ag.automated_backup_preference_desc IN ('SECONDARY', 'SECONDARY_ONLY')
                   THEN 'WARNING: No log backup in this instance''s msdb history — automated_backup_preference is '
                        + ag.automated_backup_preference_desc
                        + '; log backups likely run on a secondary. Verify on the preferred backup replica.'
                   ELSE 'WARNING: No log backup found — potential log growth issue' END
         WHEN DATEDIFF(MINUTE,
              (SELECT MAX(bs.backup_finish_date)
               FROM msdb.dbo.backupset bs
               WHERE bs.database_name = d.name AND bs.type = 'L'),
              GETDATE()) > 60
         THEN 'WARNING: Last log backup > 60 min ago'
         ELSE 'PASS' END AS log_backup_assessment
FROM sys.availability_groups ag
JOIN sys.availability_replicas ar ON ag.group_id = ar.group_id
JOIN sys.dm_hadr_availability_replica_states ars ON ar.replica_id = ars.replica_id
JOIN sys.dm_hadr_database_replica_states drs
    ON ar.replica_id = drs.replica_id AND drs.is_local = 1
JOIN sys.databases d ON drs.database_id = d.database_id
WHERE (@AGName IS NULL OR ag.name = @AGName)
ORDER BY ag.name, d.name
OPTION (MAXDOP 1);
```

---

## Step 12: Overall HA Health Scorecard

> **Guard:** `IsHadrEnabled = 1` AND `EngineEdition IN (2, 3)`. For MI (8), this scorecard reflects **MI-link AG** state only — a standalone MI's platform-managed HA is assessed via Step 10, so run this for MI only when an MI-link AG exists.
> For Express (4), Azure SQL DB (5) and Fabric (12), skip this query — produce scorecard from Step 10 results only.

```sql
-- Summary scorecard that checks key health indicators
-- Each check is independent and TRY/CATCH-safe for editions that may not support all DMVs

BEGIN TRY
    SELECT
        'AG Replica Health' AS check_category,
        CASE WHEN EXISTS (SELECT 1 FROM sys.dm_hadr_availability_replica_states
                          WHERE synchronization_health_desc = 'NOT_HEALTHY')
             THEN 'FAIL'
             WHEN EXISTS (SELECT 1 FROM sys.dm_hadr_availability_replica_states
                          WHERE synchronization_health_desc = 'PARTIALLY_HEALTHY')
             THEN 'WARNING'
             ELSE 'PASS' END AS result,
        (SELECT COUNT(*) FROM sys.dm_hadr_availability_replica_states
         WHERE synchronization_health_desc != 'HEALTHY') AS issues_found;
END TRY
BEGIN CATCH
    SELECT 'AG Replica Health' AS check_category, 'N/A' AS result, 0 AS issues_found;
END CATCH

BEGIN TRY
    SELECT
        'Database Sync State' AS check_category,
        CASE WHEN EXISTS (SELECT 1 FROM sys.dm_hadr_database_replica_states
                          WHERE synchronization_state_desc = 'NOT SYNCHRONIZING')
             THEN 'FAIL'
             WHEN EXISTS (SELECT 1 FROM sys.dm_hadr_database_replica_states
                          WHERE is_suspended = 1)
             THEN 'FAIL'
             ELSE 'PASS' END AS result,
        (SELECT COUNT(*) FROM sys.dm_hadr_database_replica_states
         WHERE synchronization_state_desc = 'NOT SYNCHRONIZING' OR is_suspended = 1) AS issues_found;
END TRY
BEGIN CATCH
    SELECT 'Database Sync State' AS check_category, 'N/A' AS result, 0 AS issues_found;
END CATCH

BEGIN TRY
    SELECT
        'Endpoint State' AS check_category,
        CASE WHEN EXISTS (SELECT 1 FROM sys.database_mirroring_endpoints
                          WHERE state_desc != 'STARTED')
             THEN 'FAIL'
             ELSE 'PASS' END AS result,
        (SELECT COUNT(*) FROM sys.database_mirroring_endpoints
         WHERE state_desc != 'STARTED') AS issues_found;
END TRY
BEGIN CATCH
    SELECT 'Endpoint State' AS check_category, 'N/A' AS result, 0 AS issues_found;
END CATCH

BEGIN TRY
    SELECT
        'Listener Configured' AS check_category,
        CASE WHEN NOT EXISTS (SELECT 1 FROM sys.availability_group_listeners)
             THEN 'WARNING'
             ELSE 'PASS' END AS result,
        0 AS issues_found;
END TRY
BEGIN CATCH
    SELECT 'Listener Configured' AS check_category, 'N/A' AS result, 0 AS issues_found;
END CATCH

BEGIN TRY
    SELECT
        'Recovery Model' AS check_category,
        CASE WHEN EXISTS (
            SELECT 1 FROM sys.dm_hadr_database_replica_states drs
            JOIN sys.databases d ON drs.database_id = d.database_id
            WHERE drs.is_local = 1 AND d.recovery_model_desc != 'FULL')
             THEN 'FAIL'
             ELSE 'PASS' END AS result,
        (SELECT COUNT(*)
         FROM sys.dm_hadr_database_replica_states drs
         JOIN sys.databases d ON drs.database_id = d.database_id
         WHERE drs.is_local = 1 AND d.recovery_model_desc != 'FULL') AS issues_found;
END TRY
BEGIN CATCH
    SELECT 'Recovery Model' AS check_category, 'N/A' AS result, 0 AS issues_found;
END CATCH

BEGIN TRY
    SELECT
        'Automatic Failover' AS check_category,
        CASE WHEN NOT EXISTS (SELECT 1 FROM sys.availability_replicas
                               WHERE failover_mode_desc = 'AUTOMATIC')
             THEN 'WARNING'
             ELSE 'PASS' END AS result,
        0 AS issues_found;
END TRY
BEGIN CATCH
    SELECT 'Automatic Failover' AS check_category, 'N/A' AS result, 0 AS issues_found;
END CATCH

BEGIN TRY
    SELECT
        'Cluster Members' AS check_category,
        CASE WHEN EXISTS (SELECT 1 FROM sys.dm_hadr_cluster_members
                          WHERE member_state_desc != 'UP')
             THEN 'FAIL'
             ELSE 'PASS' END AS result,
        (SELECT COUNT(*) FROM sys.dm_hadr_cluster_members
         WHERE member_state_desc != 'UP') AS issues_found;
END TRY
BEGIN CATCH
    SELECT 'Cluster Members' AS check_category, 'N/A' AS result, 0 AS issues_found;
END CATCH
```

---

## Step 13: Distributed & Contained AG Assessment

> **Guard:** `IsHadrEnabled = 1` AND `EngineEdition = 3` (Enterprise) AND `ProductMajorVersion >= 13` (SQL 2016+).
> Skip entirely if no distributed or contained AGs exist on the instance.

```sql
-- Part 1: Detect and assess Distributed Availability Groups (SQL 2016+)
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS INT) >= 13
BEGIN
    -- Distributed AG detection and configuration assessment
    SELECT
        ag.name                          AS ag_name,
        ag.is_distributed,
        ar.replica_server_name,
        ar.endpoint_url,
        ar.availability_mode_desc,
        ar.failover_mode_desc,
        ar.seeding_mode_desc,
        ars.role_desc,
        ars.connected_state_desc,
        ars.synchronization_health_desc,
        -- Forwarder lag: difference between last_commit_lsn (primary) and last_hardened_lsn (forwarder)
        drs.last_commit_lsn,
        drs.last_hardened_lsn,
        drs.last_commit_time,
        drs.last_hardened_time,
        drs.lag_seconds,
        -- Assessment verdicts
        CASE WHEN ag.is_distributed = 0 THEN 'N/A — not a distributed AG'
             WHEN ar.endpoint_url IS NULL OR ar.endpoint_url = ''
             THEN 'FAIL: Distributed AG replica has no ENDPOINT_URL — listener required on underlying AG'
             WHEN ars.connected_state_desc != 'CONNECTED'
             THEN 'FAIL: Distributed AG forwarder is disconnected'
             WHEN ars.synchronization_health_desc = 'NOT_HEALTHY'
             THEN 'FAIL: Distributed AG replica not healthy — failover will lose data'
             WHEN drs.lag_seconds > 300
             THEN 'WARNING: Forwarder lag > 5 minutes — failover RPO is high'
             WHEN drs.lag_seconds > 60
             THEN 'WARNING: Forwarder lag > 1 minute — monitor for growing lag'
             ELSE 'PASS' END AS distributed_ag_assessment,
        CASE WHEN ag.is_distributed = 1
                  AND ar.failover_mode_desc != 'MANUAL'
             THEN 'WARNING: Distributed AGs only support manual failover — automatic failover setting is invalid'
             ELSE 'PASS' END AS failover_mode_check
    FROM sys.availability_groups ag
    JOIN sys.availability_replicas ar ON ag.group_id = ar.group_id
    LEFT JOIN sys.dm_hadr_availability_replica_states ars ON ar.replica_id = ars.replica_id
    LEFT JOIN (
        -- Compute lag per database first, then take the worst (MAX) across databases for the replica,
        -- so the two timestamp maxima can never be mixed across different databases.
        SELECT replica_id,
               MAX(last_commit_lsn) AS last_commit_lsn,
               MAX(last_hardened_lsn) AS last_hardened_lsn,
               MAX(last_commit_time) AS last_commit_time,
               MAX(last_hardened_time) AS last_hardened_time,
               MAX(DATEDIFF(SECOND, last_hardened_time, last_commit_time)) AS lag_seconds
        FROM sys.dm_hadr_database_replica_states
        GROUP BY replica_id
    ) drs ON ar.replica_id = drs.replica_id
    WHERE ag.is_distributed = 1
    ORDER BY ag.name, ars.role_desc DESC, ar.replica_server_name
    OPTION (MAXDOP 1);

    -- Check availability mode mismatch across distributed AG replicas
    -- Microsoft recommends matching modes on both underlying AGs (SQL 2025 improvement docs)
    -- NOTE: FOR XML PATH string aggregation is used instead of STRING_AGG so this runs on
    -- SQL 2016 (v13); STRING_AGG was only introduced in SQL 2017 (v14), and distributed AGs exist on 2016.
    SELECT
        ag.name AS ag_name,
        STUFF((SELECT ', ' + ar2.replica_server_name + '=' + ar2.availability_mode_desc
               FROM sys.availability_replicas ar2
               WHERE ar2.group_id = ag.group_id
               ORDER BY ar2.replica_server_name
               FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, '') AS replica_modes,
        CASE WHEN COUNT(DISTINCT ar.availability_mode_desc) > 1
             THEN 'WARNING: Availability mode mismatch between underlying AGs — can introduce synchronization latency'
             ELSE 'PASS' END AS mode_mismatch_assessment
    FROM sys.availability_groups ag
    JOIN sys.availability_replicas ar ON ag.group_id = ar.group_id
    WHERE ag.is_distributed = 1
    GROUP BY ag.name, ag.group_id
    OPTION (MAXDOP 1);
END

-- Part 2: Detect and assess Contained Availability Groups (SQL 2022+ / v16+)
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS INT) >= 16
BEGIN
    EXEC sp_executesql N'
    SELECT
        ag.name                          AS ag_name,
        ag.is_contained,
        ar.replica_server_name,
        ars.role_desc,
        -- Check system database sync state within contained AG
        (SELECT COUNT(*)
         FROM sys.dm_hadr_database_replica_states drs
         JOIN sys.databases d ON drs.database_id = d.database_id
         WHERE drs.replica_id = ar.replica_id
           AND d.name IN (ag.name + ''_master'', ag.name + ''_msdb'')
           AND drs.synchronization_state_desc = ''SYNCHRONIZED'') AS system_dbs_synchronized,
        (SELECT COUNT(*)
         FROM sys.dm_hadr_database_replica_states drs
         JOIN sys.databases d ON drs.database_id = d.database_id
         WHERE drs.replica_id = ar.replica_id
           AND d.name IN (ag.name + ''_master'', ag.name + ''_msdb'')
           AND drs.synchronization_state_desc != ''SYNCHRONIZED'') AS system_dbs_not_synchronized,
        -- Assessment
        CASE WHEN ag.is_contained = 0 THEN ''N/A — not a contained AG''
             WHEN ars.role_desc = ''PRIMARY'' THEN ''N/A (primary)''
             WHEN (SELECT COUNT(*)
                   FROM sys.dm_hadr_database_replica_states drs
                   JOIN sys.databases d ON drs.database_id = d.database_id
                   WHERE drs.replica_id = ar.replica_id
                     AND d.name IN (ag.name + ''_master'', ag.name + ''_msdb'')
                     AND drs.synchronization_state_desc != ''SYNCHRONIZED'') > 0
             THEN ''FAIL: Contained AG system databases (master/msdb) not synchronized — logins, jobs, linked servers will be inconsistent after failover''
             ELSE ''PASS: System databases synchronized'' END AS contained_ag_assessment
    FROM sys.availability_groups ag
    JOIN sys.availability_replicas ar ON ag.group_id = ar.group_id
    LEFT JOIN sys.dm_hadr_availability_replica_states ars ON ar.replica_id = ars.replica_id
    WHERE ag.is_contained = 1
    ORDER BY ag.name, ars.role_desc DESC, ar.replica_server_name
    OPTION (MAXDOP 1);';
END
```
