# Step 2 - Critical Health

Run critical checks before resource or configuration checks.

## HA-CRIT-001: Unavailable Databases

```sql
SELECT
    d.database_id,
    d.name AS database_name,
    d.state_desc,
    d.user_access_desc,
    d.recovery_model_desc,
    d.is_read_only
FROM sys.databases AS d
WHERE d.state_desc <> N'ONLINE'
  AND ({{IncludeSystemDatabasesBit}} = 1 OR d.database_id > 4)
  AND {{DatabaseNamePredicate}}
ORDER BY
    CASE d.state_desc
        WHEN N'SUSPECT' THEN 0
        WHEN N'RECOVERY_PENDING' THEN 1
        WHEN N'EMERGENCY' THEN 2
        WHEN N'RECOVERING' THEN 3
        ELSE 4
    END,
    d.name
OPTION (MAXDOP 1);
```

Evaluation:

- `SUSPECT`, `RECOVERY_PENDING`, or unexpected `EMERGENCY`: `FAIL/CRITICAL`.
- Unexpected `OFFLINE`: `FAIL/HIGH`; planned state must be confirmed by the user.
- `RESTORING`, `RECOVERING`, or `STANDBY`: `WARN` or `INFO` according to the declared topology.
- No rows with complete visibility: `PASS`.

## HA-CRIT-002: Suspect Pages

Requires `msdb` visibility. Empty history with no permission proof is `UNKNOWN`.

```sql
SELECT TOP ({{TopN}})
    sp.database_id,
    DB_NAME(sp.database_id) AS database_name,
    sp.file_id,
    sp.page_id,
    sp.event_type,
    sp.error_count,
    sp.last_update_date
FROM msdb.dbo.suspect_pages AS sp
WHERE sp.last_update_date >= DATEADD(HOUR, -{{LookbackHours}}, GETDATE())
  AND ({{IncludeSystemDatabasesBit}} = 1 OR sp.database_id > 4)
ORDER BY sp.last_update_date DESC
OPTION (MAXDOP 1);
```

Any recent 824-class or deallocated/restored-page evidence is at least `WARN/HIGH`; active
corruption evidence or recurring counts is `FAIL/CRITICAL`. Recommend immediate integrity and
restore-path validation, but do not run repair or `DBCC CHECKDB` automatically.

## HA-CRIT-003: AG Replica and Database Health

Run only for SQL Server with `IsHadrEnabled = 1`, eligible AG objects, and HADR visibility.

```sql
SELECT
    ag.name AS availability_group_name,
    ar.replica_server_name,
    ars.role_desc,
    ars.connected_state_desc,
    ars.operational_state_desc,
    ars.synchronization_health_desc,
    ars.recovery_health_desc
FROM sys.availability_groups AS ag
JOIN sys.availability_replicas AS ar
  ON ar.group_id = ag.group_id
LEFT JOIN sys.dm_hadr_availability_replica_states AS ars
  ON ars.replica_id = ar.replica_id
 AND ars.group_id = ar.group_id
ORDER BY ag.name, ar.replica_server_name
OPTION (MAXDOP 1);
```

```sql
SELECT
    ag.name AS availability_group_name,
    ar.replica_server_name,
    DB_NAME(drs.database_id) AS database_name,
    ars.role_desc,
    drs.synchronization_state_desc,
    drs.synchronization_health_desc,
    drs.is_suspended,
    drs.suspend_reason_desc,
    drs.database_state_desc
FROM sys.dm_hadr_database_replica_states AS drs
JOIN sys.availability_replicas AS ar
  ON ar.replica_id = drs.replica_id
JOIN sys.availability_groups AS ag
  ON ag.group_id = drs.group_id
LEFT JOIN sys.dm_hadr_availability_replica_states AS ars
  ON ars.replica_id = drs.replica_id
 AND ars.group_id = drs.group_id
WHERE {{DatabaseNamePredicateQualified}}
ORDER BY ag.name, database_name, ar.replica_server_name
OPTION (MAXDOP 1);
```

Replace `{{DatabaseNamePredicateQualified}}` with `1 = 1` or an escaped predicate against
`DB_NAME(drs.database_id)`.

Disconnected replicas, suspended movement, `NOT_HEALTHY`, or unavailable databases are
`FAIL/CRITICAL` when active. `NOT_SYNCHRONIZING` is evaluated against replica role and availability
mode. Delegate full diagnosis to `investigate-ha-issues`.

On Managed Instance without an MI-link AG, mark this check `NOT_APPLICABLE`; built-in HA is
platform-managed.

## HA-CRIT-004: Recent Dumps

Run only when `IncludePrivilegedChecks = true`, the object exists, and permission is proven.

```sql
SELECT TOP ({{TopN}})
    creation_time,
    filename,
    size_in_bytes
FROM sys.dm_server_memory_dumps
WHERE creation_time >= DATEADD(HOUR, -{{LookbackHours}}, GETDATE())
ORDER BY creation_time DESC
OPTION (MAXDOP 1);
```

Redact `filename` unless sensitive output is allowed. Any recent dump is `WARN/HIGH`; repeated
dumps associated with service interruption are `FAIL/CRITICAL`.

## HA-CRIT-005: Recent Severe Error-Log Evidence

Run only when `IncludePrivilegedChecks = true`, error-log access is proven, and the user accepts
that log text can contain sensitive data.

Execute separate bounded searches with `sp_readerrorlog` for:

- severity 20-25
- error 823, 824, 825
- stack dump
- failed recovery
- I/O requests taking longer than 15 seconds

Use `LookbackHours` to discard older rows after retrieval and retain at most `TopN` rows per
pattern. Do not return raw log text unless `IncludeSensitiveText = true`; otherwise report counts,
timestamps, error numbers, and redacted categories.

Missing access is `UNKNOWN`. No matching rows is `PASS` only when access and time coverage are
confirmed.
