# Query Store and Automatic Tuning

## Query Store

```sql
IF OBJECT_ID(N'sys.database_query_store_options') IS NULL
BEGIN
    SELECT N'Unavailable - Query Store metadata is not exposed' AS availability;
END
ELSE
BEGIN
    SELECT
          actual_state_desc
        , desired_state_desc
        , readonly_reason
        , current_storage_size_mb
        , max_storage_size_mb
        , CASE
              WHEN max_storage_size_mb > 0
              THEN CONVERT(decimal(9,2),
                   current_storage_size_mb * 100.0 / max_storage_size_mb)
              ELSE NULL
          END AS storage_used_percent
        , flush_interval_seconds
        , interval_length_minutes
        , stale_query_threshold_days
        , size_based_cleanup_mode_desc
        , query_capture_mode_desc
    FROM sys.database_query_store_options
    OPTION (MAXDOP 1);
END;
```

Classify:

- `actual_state_desc = ERROR`: **High**.
- `storage_used_percent > 90`: **Medium**.
- `READ_ONLY`: report the `readonly_reason`; do not assume storage pressure is the cause.
- `OFF`: fact unless the user requires Query Store-dependent troubleshooting or features.

Explain that increasing storage improves retention but consumes database space. More aggressive
capture improves diagnostic coverage but adds storage and runtime overhead. Cleanup and retention
changes affect historical depth.

## Automatic tuning

```sql
IF OBJECT_ID(N'sys.database_automatic_tuning_options') IS NULL
BEGIN
    SELECT N'Unavailable - automatic tuning metadata is not exposed' AS availability;
END
ELSE
BEGIN
    SELECT
          name
        , desired_state_desc
        , actual_state_desc
        , reason_desc
    FROM sys.database_automatic_tuning_options
    ORDER BY name
    OPTION (MAXDOP 1);
END;
```

Automatic tuning is informational. Distinguish desired state from actual state. On platform-managed
services, `DEFAULT` or inherited behavior is not equivalent to disabled. Explain that automated
plan correction can reduce regressions but still requires monitoring and governance.
