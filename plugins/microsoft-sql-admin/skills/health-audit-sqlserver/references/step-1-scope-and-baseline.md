# Step 1 - Scope and Baseline

## Objective

Establish evidence validity before interpreting cumulative or retained data.

## HA-BASE-001: Instance Uptime

Requires server performance visibility and the Step 0 column probe.

```sql
SELECT
    sqlserver_start_time,
    SYSUTCDATETIME() AS sampled_at_utc,
    DATEDIFF(MINUTE, sqlserver_start_time, SYSUTCDATETIME()) AS uptime_minutes
FROM sys.dm_os_sys_info
OPTION (MAXDOP 1);
```

If `sqlserver_start_time` is unavailable, use tempdb creation time as lower-confidence evidence:

```sql
SELECT
    create_date AS approximate_start_time,
    SYSUTCDATETIME() AS sampled_at_utc,
    DATEDIFF(MINUTE, create_date, SYSUTCDATETIME()) AS approximate_uptime_minutes
FROM sys.databases
WHERE database_id = 2
OPTION (MAXDOP 1);
```

Recent restart lowers confidence in waits, file-stat, plan-cache, and index-usage evidence.

## HA-BASE-002: Database Scope

Replace `{{DatabaseNamePredicate}}` with `1 = 1` or an equality predicate containing a
single-quoted name whose quotes have been doubled. Never paste an unescaped name.

```sql
SELECT
    d.database_id,
    d.name AS database_name,
    d.state_desc,
    d.user_access_desc,
    d.recovery_model_desc,
    d.compatibility_level,
    d.is_read_only,
    d.source_database_id,
    HAS_DBACCESS(d.name) AS has_db_access
FROM sys.databases AS d
WHERE {{DatabaseNamePredicate}}
  AND ({{IncludeSystemDatabasesBit}} = 1 OR d.database_id > 4)
ORDER BY d.database_id
OPTION (MAXDOP 1);
```

Rules:

- A requested database that is absent or inaccessible is `UNKNOWN`; do not silently broaden scope.
- Exclude snapshots (`source_database_id IS NOT NULL`) from operational compliance conclusions.
- Preserve each database's context; never combine an inaccessible database with healthy counts.

## HA-BASE-003: Plan Cache Evidence Boundary

Run only with server performance visibility.

```sql
SELECT
    MIN(creation_time) AS oldest_visible_plan_utc,
    MAX(last_execution_time) AS newest_visible_execution_utc,
    COUNT_BIG(*) AS visible_plan_count,
    SYSUTCDATETIME() AS sampled_at_utc
FROM sys.dm_exec_query_stats
OPTION (MAXDOP 1);
```

This is coverage evidence only. It does not prove that the cache contains the complete requested
lookback.

## HA-BASE-004: Wait Statistics Boundary

```sql
SELECT
    sqlserver_start_time AS wait_stats_reset_lower_bound_utc,
    SYSUTCDATETIME() AS sampled_at_utc
FROM sys.dm_os_sys_info
OPTION (MAXDOP 1);
```

SQL Server wait statistics may have been cleared after startup. If that cannot be determined,
label the data window `since last restart or manual reset`.

## Baseline Evaluation

- Uptime shorter than `LookbackHours` is `INFO`, not a health failure.
- Missing uptime/reset data is `UNKNOWN` for reset-sensitive conclusions.
- Any inaccessible requested database remains visible in coverage.
- Capture the effective lookback as the smaller of requested history and available evidence.
