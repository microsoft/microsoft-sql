# Step 5 - Backup, HA, and SQL Agent Operations

## Policy Boundary

Backup age and HA design cannot be declared compliant without workload RPO/RTO, criticality,
maintenance windows, and topology. When requirements are unknown, report observed ages and
failures as risk evidence or questions rather than inventing a universal pass/fail threshold.

## HA-OPS-001: Last Successful Backups

SQL Server only. Requires `msdb` visibility. On Managed Instance, local `backupset` is not proof
of platform-managed backup health; mark this query `NOT_APPLICABLE` unless evaluating explicit
native backups.

```sql
WITH backup_summary AS (
    SELECT
        bs.database_name,
        MAX(CASE WHEN bs.type = N'D' AND bs.is_copy_only = 0
                 THEN bs.backup_finish_date END) AS last_full_backup,
        MAX(CASE WHEN bs.type = N'I'
                 THEN bs.backup_finish_date END) AS last_diff_backup,
        MAX(CASE WHEN bs.type = N'L'
                 THEN bs.backup_finish_date END) AS last_log_backup,
        MAX(CASE WHEN bs.has_backup_checksums = 1
                 THEN bs.backup_finish_date END) AS last_checksum_backup
    FROM msdb.dbo.backupset AS bs
    WHERE bs.backup_finish_date >= DATEADD(DAY, -30, GETDATE())
    GROUP BY bs.database_name
)
SELECT
    d.name AS database_name,
    d.recovery_model_desc,
    b.last_full_backup,
    b.last_diff_backup,
    b.last_log_backup,
    b.last_checksum_backup,
    DATEDIFF(HOUR, b.last_full_backup, GETDATE()) AS full_backup_age_hours,
    DATEDIFF(MINUTE, b.last_log_backup, GETDATE()) AS log_backup_age_minutes
FROM sys.databases AS d
LEFT JOIN backup_summary AS b
  ON b.database_name = d.name
WHERE d.state_desc = N'ONLINE'
  AND d.source_database_id IS NULL
  AND ({{IncludeSystemDatabasesBit}} = 1 OR d.database_id > 4)
  AND {{DatabaseNamePredicate}}
ORDER BY d.name
OPTION (MAXDOP 1);
```

Account for copy-only backups, recovery model, AG backup preference, readable secondaries,
retention limits, and third-party tools. Missing history with incomplete visibility is `UNKNOWN`.
Delegate strategy evaluation to `backup-strategy-sqlserver`.

## HA-OPS-002: AG Operational State

Use the Step 2 AG evidence. Add this role/preference query only for an eligible SQL Server AG:

```sql
SELECT
    ag.name AS availability_group_name,
    ag.automated_backup_preference_desc,
    ar.replica_server_name,
    ar.availability_mode_desc,
    ar.failover_mode_desc,
    ar.backup_priority,
    ars.role_desc,
    ars.connected_state_desc,
    ars.synchronization_health_desc
FROM sys.availability_groups AS ag
JOIN sys.availability_replicas AS ar
  ON ar.group_id = ag.group_id
LEFT JOIN sys.dm_hadr_availability_replica_states AS ars
  ON ars.group_id = ar.group_id
 AND ars.replica_id = ar.replica_id
ORDER BY ag.name, ar.replica_server_name
OPTION (MAXDOP 1);
```

Do not report "no HA" as a failure unless HA is a supplied workload requirement. On Managed
Instance, built-in HA exists even when AG catalogs are empty.

## HA-OPS-003: Log Shipping Status

Run only when `msdb` log-shipping tables are accessible.

```sql
SELECT
    pd.primary_database AS database_name,
    pm.backup_threshold,
    pm.threshold_alert_enabled,
    pm.last_backup_date,
    pm.last_backup_file,
    DATEDIFF(MINUTE, pm.last_backup_date, GETDATE()) AS minutes_since_last_backup
FROM msdb.dbo.log_shipping_primary_databases AS pd
LEFT JOIN msdb.dbo.log_shipping_monitor_primary AS pm
  ON pm.primary_id = pd.primary_id
ORDER BY pd.primary_database
OPTION (MAXDOP 1);
```

```sql
SELECT
    sd.secondary_database AS database_name,
    sm.restore_threshold,
    sm.threshold_alert_enabled,
    sm.last_copied_date,
    sm.last_restored_date,
    DATEDIFF(MINUTE, sm.last_restored_date, GETDATE()) AS minutes_since_last_restore
FROM msdb.dbo.log_shipping_secondary_databases AS sd
LEFT JOIN msdb.dbo.log_shipping_monitor_secondary AS sm
  ON sm.secondary_id = sd.secondary_id
ORDER BY sd.secondary_database
OPTION (MAXDOP 1);
```

Compare observed delays to configured thresholds. Missing monitor history is `UNKNOWN`.

## HA-OPS-004: Recent SQL Agent Failures

Requires SQL Agent capability and `msdb` visibility.

```sql
WITH history AS (
    SELECT
        h.job_id,
        h.step_id,
        h.step_name,
        h.run_status,
        msdb.dbo.agent_datetime(h.run_date, h.run_time) AS run_datetime,
        h.sql_message_id,
        h.sql_severity,
        h.message,
        ROW_NUMBER() OVER (
            PARTITION BY h.job_id, h.step_id
            ORDER BY h.instance_id DESC
        ) AS row_num
    FROM msdb.dbo.sysjobhistory AS h
    WHERE h.run_status IN (0, 2, 3)
      AND msdb.dbo.agent_datetime(h.run_date, h.run_time)
          >= DATEADD(HOUR, -{{LookbackHours}}, GETDATE())
)
SELECT TOP ({{TopN}})
    j.name AS job_name,
    h.step_id,
    h.step_name,
    h.run_status,
    h.run_datetime,
    h.sql_message_id,
    h.sql_severity,
    h.message
FROM history AS h
JOIN msdb.dbo.sysjobs AS j
  ON j.job_id = h.job_id
WHERE h.row_num = 1
ORDER BY h.run_datetime DESC
OPTION (MAXDOP 1);
```

Redact job and step names plus messages unless sensitive output is authorized. A failed backup,
integrity, HA, or maintenance job is at least `WARN/HIGH`; recurring or currently blocking
recoverability is `FAIL/HIGH`.

## HA-OPS-005: Agent Notification Coverage

```sql
SELECT
    j.name AS job_name,
    j.enabled,
    j.notify_level_email,
    j.notify_level_page,
    j.notify_level_netsend,
    j.notify_email_operator_id
FROM msdb.dbo.sysjobs AS j
WHERE j.enabled = 1
ORDER BY j.name
OPTION (MAXDOP 1);
```

This is an observation unless a notification policy is supplied. Redact job names by default.
Do not assume email is the only valid monitoring path.

## HA-OPS-006: Managed Instance Boundary

For EngineEdition 8:

- Treat built-in local HA as platform-managed.
- Do not infer backup health from empty `msdb.dbo.backupset`.
- Report native backup/Agent evidence only when the user asked to assess those explicit controls.
- Use external Azure policy/retention/redundancy metadata when available; otherwise mark managed
  backup details `UNKNOWN`, not failed.
- MI-link or failover-group incidents should delegate to `investigate-ha-issues`.
