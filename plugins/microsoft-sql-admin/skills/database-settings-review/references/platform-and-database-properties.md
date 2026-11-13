# Platform and Database Properties

## Step 1: Detect the platform

Execute first:

```sql
SELECT
      CAST(SERVERPROPERTY(N'EngineEdition') AS int) AS engine_edition
    , CONVERT(nvarchar(128), SERVERPROPERTY(N'Edition')) AS edition
    , CONVERT(nvarchar(128), SERVERPROPERTY(N'ProductVersion')) AS product_version
    , CONVERT(nvarchar(128), SERVERPROPERTY(N'ProductLevel')) AS product_level
    , DB_ID() AS database_id
    , DB_NAME() AS database_name
OPTION (MAXDOP 1);
```

Route by `engine_edition`:

| Value | Platform | Continue |
|---:|---|---|
| 1, 2, 3, 4 | SQL Server | Yes |
| 5 | Azure SQL Database | Yes |
| 8 | Azure SQL Managed Instance | Yes |
| other | Unsupported by this skill | Stop and report `Unavailable` |

Do not classify EngineEdition 11 as Azure SQL Database.

## Step 2: Collect database properties

```sql
SELECT
      d.name AS database_name
    , d.database_id
    , d.state_desc
    , d.user_access_desc
    , d.containment_desc
    , d.compatibility_level
    , d.collation_name
    , d.recovery_model_desc
    , d.page_verify_option_desc
    , d.is_auto_close_on
    , d.is_auto_shrink_on
    , d.is_auto_create_stats_on
    , d.is_auto_update_stats_on
    , d.is_auto_update_stats_async_on
    , d.is_parameterization_forced
    , d.is_read_committed_snapshot_on
    , d.snapshot_isolation_state_desc
    , d.is_query_store_on
    , d.is_cdc_enabled
    , d.is_broker_enabled
    , d.is_honor_broker_priority_on
    , d.is_trustworthy_on
    , d.is_encrypted
    , d.delayed_durability_desc
    , d.target_recovery_time_in_seconds
FROM sys.databases AS d
WHERE d.database_id = DB_ID()
OPTION (MAXDOP 1);
```

Record these as facts. Recovery model, delayed durability, RCSI, snapshot isolation, containment,
and forced parameterization require workload and recovery-objective context; they are not defects
by themselves.

## Step 3: Collect ADR state

Guard the versioned column:

```sql
IF COL_LENGTH(N'sys.databases', N'is_accelerated_database_recovery_on') IS NOT NULL
BEGIN
    EXEC sys.sp_executesql N'
        SELECT is_accelerated_database_recovery_on
        FROM sys.databases
        WHERE database_id = DB_ID()
        OPTION (MAXDOP 1);';
END
ELSE
BEGIN
    SELECT
          CAST(NULL AS bit) AS is_accelerated_database_recovery_on
        , N'Unavailable - catalog column is not exposed' AS availability;
END;
```

ADR is informational. Explain its faster rollback/recovery benefits and persistent version-store
space tradeoff; do not recommend enabling it from this probe alone.
