# Step 4 - Storage, Files, Tempdb, and Log Health

## HA-STO-001: Database File State and Growth

```sql
SELECT
    mf.database_id,
    DB_NAME(mf.database_id) AS database_name,
    mf.file_id,
    mf.type_desc,
    mf.state_desc,
    mf.size * 8.0 / 1024 AS size_mb,
    CASE WHEN mf.max_size = -1 THEN NULL ELSE mf.max_size * 8.0 / 1024 END AS max_size_mb,
    mf.growth,
    mf.is_percent_growth,
    mf.is_read_only,
    mf.is_sparse
FROM sys.master_files AS mf
WHERE ({{IncludeSystemDatabasesBit}} = 1 OR mf.database_id > 4)
  AND {{DatabaseNamePredicateQualified}}
ORDER BY mf.database_id, mf.file_id
OPTION (MAXDOP 1);
```

Replace `{{DatabaseNamePredicateQualified}}` with `1 = 1` or an escaped predicate against
`DB_NAME(mf.database_id)`.

Offline/defunct files are `FAIL` unless expected. Percent growth is a review signal, not an
automatic failure. Paths are intentionally omitted from this default query.

## HA-STO-002: Volume Capacity

Run only when `sys.dm_os_volume_stats` exists and server performance visibility is proven.

```sql
SELECT
    vs.volume_mount_point,
    MAX(vs.logical_volume_name) AS logical_volume_name,
    MAX(vs.file_system_type) AS file_system_type,
    MAX(vs.total_bytes) AS total_bytes,
    MIN(vs.available_bytes) AS available_bytes,
    CAST(100.0 * MIN(vs.available_bytes) / NULLIF(MAX(vs.total_bytes), 0)
        AS decimal(9,2)) AS available_percent,
    COUNT(*) AS sql_file_count
FROM sys.master_files AS mf
CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) AS vs
WHERE ({{IncludeSystemDatabasesBit}} = 1 OR mf.database_id > 4)
  AND {{DatabaseNamePredicateQualified}}
GROUP BY vs.volume_mount_point
ORDER BY available_percent, vs.volume_mount_point
OPTION (MAXDOP 1);
```

Redact mount points unless sensitive output is authorized. Capacity urgency must consider both
percentage and absolute free bytes plus observed growth. Do not infer Azure disk SKU or caching
from T-SQL.

## HA-STO-003: File IO Snapshot

Collect twice using the Step 3 sampling interval and calculate deltas. Requires server performance
visibility.

```sql
SELECT
    SYSUTCDATETIME() AS sampled_at_utc,
    vfs.database_id,
    DB_NAME(vfs.database_id) AS database_name,
    vfs.file_id,
    mf.type_desc,
    vfs.num_of_reads,
    vfs.num_of_bytes_read,
    vfs.io_stall_read_ms,
    vfs.num_of_writes,
    vfs.num_of_bytes_written,
    vfs.io_stall_write_ms
FROM sys.dm_io_virtual_file_stats(NULL, NULL) AS vfs
JOIN sys.master_files AS mf
  ON mf.database_id = vfs.database_id
 AND mf.file_id = vfs.file_id
WHERE ({{IncludeSystemDatabasesBit}} = 1 OR vfs.database_id > 4)
  AND {{DatabaseNamePredicateQualified}}
OPTION (MAXDOP 1);
```

Only calculate average latency when delta operations are greater than zero, using `NULLIF`.
Repeated high latency is a routing signal:

- data files -> `investigate-sql-data-io-pressure`
- log files -> `investigate-sql-log-io-pressure`

Do not apply one universal latency threshold to every storage tier and workload.

## HA-STO-004: Current Database Log Usage

Run once in each eligible target database.

```sql
SELECT
    DB_NAME() AS database_name,
    total_log_size_in_bytes,
    used_log_space_in_bytes,
    used_log_space_in_percent,
    log_space_in_bytes_since_last_backup
FROM sys.dm_db_log_space_usage
OPTION (MAXDOP 1);
```

High utilization is `WARN` when growth headroom exists and `FAIL/HIGH` when paired with exhausted
capacity, failed growth, or an active log reuse blocker.

## HA-STO-005: Log Reuse Wait

```sql
SELECT
    d.name AS database_name,
    d.recovery_model_desc,
    d.log_reuse_wait_desc
FROM sys.databases AS d
WHERE ({{IncludeSystemDatabasesBit}} = 1 OR d.database_id > 4)
  AND {{DatabaseNamePredicate}}
ORDER BY d.name
OPTION (MAXDOP 1);
```

Interpret `LOG_BACKUP`, `ACTIVE_TRANSACTION`, `AVAILABILITY_REPLICA`, and replication waits with
the corresponding backup, blocking, or HA evidence. A reuse wait alone is not proof of an
incident.

## HA-STO-006: VLF State

Run only when `IncludeExpensiveChecks = true`.

Preferred variant when `sys.dm_db_log_info` exists; execute once in each target database:

```sql
SELECT
    DB_NAME() AS database_name,
    COUNT(*) AS vlf_count,
    SUM(CASE WHEN vlf_active = 1 THEN 1 ELSE 0 END) AS active_vlf_count,
    MIN(vlf_size_mb) AS min_vlf_size_mb,
    MAX(vlf_size_mb) AS max_vlf_size_mb,
    SUM(vlf_size_mb) AS total_vlf_size_mb
FROM sys.dm_db_log_info(DB_ID())
OPTION (MAXDOP 1);
```

For versions without that DMV, `DBCC LOGINFO WITH NO_INFOMSGS` may be used only as a separate,
bounded fallback in the target database. Record the fallback and do not run it across an
unbounded database list.

VLF count is contextual evidence. Do not use a universal count as an automatic failure.

## HA-STO-007: Tempdb File Layout

```sql
SELECT
    df.file_id,
    df.name,
    df.type_desc,
    df.state_desc,
    df.size * 8.0 / 1024 AS size_mb,
    df.growth,
    df.is_percent_growth
FROM tempdb.sys.database_files AS df
ORDER BY df.type, df.file_id
OPTION (MAXDOP 1);
```

Flag offline files and material data-file size/growth asymmetry. File count recommendations must
consider logical processor count, observed allocation contention, and workload; do not prescribe
one file per core.
