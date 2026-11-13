# Step 0 - Platform and Capability Detection

## Objective

Build an `EnvironmentProfile` and prove eligibility before loading any later query.

## Required Output

Capture identity, platform, hosting certainty, version/build, edition, current database,
compatibility, feature/object availability, permissions, HADR state, safety limits, and lists of:

```text
eligible_checks[]
not_applicable_checks[] with reason
blocked_checks[] with missing permission or visibility
deferred_checks[] requiring opt-in or external metadata
```

## HA-ENV-001: Universal Identity

Always execute first.

```sql
SELECT
    CAST(SERVERPROPERTY('ServerName') AS nvarchar(128)) AS server_name,
    CAST(SERVERPROPERTY('EngineEdition') AS int) AS engine_edition,
    CAST(SERVERPROPERTY('Edition') AS nvarchar(128)) AS edition,
    CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(128)) AS product_version,
    TRY_CONVERT(int, PARSENAME(CONVERT(varchar(32), SERVERPROPERTY('ProductVersion')), 4))
        AS product_major_version,
    CAST(SERVERPROPERTY('ProductLevel') AS nvarchar(128)) AS product_level,
    CAST(SERVERPROPERTY('ProductUpdateLevel') AS nvarchar(128)) AS product_update_level,
    CAST(SERVERPROPERTY('ProductUpdateReference') AS nvarchar(128)) AS product_update_reference,
    CAST(SERVERPROPERTY('ProductUpdateType') AS nvarchar(128)) AS product_update_type,
    CAST(SERVERPROPERTY('IsHadrEnabled') AS int) AS is_hadr_enabled,
    CAST(SERVERPROPERTY('IsClustered') AS int) AS is_clustered,
    SYSUTCDATETIME() AS detected_at_utc
OPTION (MAXDOP 1);
```

Null update properties are valid evidence. Report the installed build only; do not infer current
patch compliance.

### Platform Routing

| EngineEdition | Route |
|---:|---|
| 2, 3, 4 | `sqlserver`; hosting is `unknown` unless the user supplied `onprem` or `azure-vm` |
| 8 | `azuremi`; platform-managed HA and backup semantics apply |
| 5 | Stop and direct to a database-scoped Azure SQL audit |
| 6, 11 | Stop and direct to warehouse/Synapse-specific tooling |
| 12 | Stop; Fabric SQL Database is not implemented by this skill |
| 9 | Stop; Azure SQL Edge is not implemented by this skill |
| null/other | `UNKNOWN_PLATFORM`; run no feature checks |

For editions 2-4, `HYPERVISOR` confirms virtualization only. It does not prove Azure VM hosting.
Use `DeploymentHint = azure-vm` only when supplied by the user or confirmed through external Azure
metadata.

## HA-ENV-002: Current Database

```sql
SELECT
    d.name AS database_name,
    d.database_id,
    d.state_desc,
    d.user_access_desc,
    d.recovery_model_desc,
    d.compatibility_level,
    d.is_read_only,
    d.is_auto_close_on,
    d.is_auto_shrink_on,
    d.page_verify_option_desc,
    d.is_auto_create_stats_on,
    d.is_auto_update_stats_on,
    d.is_read_committed_snapshot_on,
    d.containment_desc
FROM sys.databases AS d
WHERE d.database_id = DB_ID()
OPTION (MAXDOP 1);
```

If the current database is inaccessible, ask the host to connect to a valid target before
continuing.

## HA-ENV-003: Object Capabilities

```sql
SELECT
    v.capability_name,
    v.object_name,
    OBJECT_ID(v.object_name) AS object_id,
    CONVERT(bit, CASE WHEN OBJECT_ID(v.object_name) IS NULL THEN 0 ELSE 1 END) AS object_exists
FROM (VALUES
    (N'query_store_options', N'sys.database_query_store_options'),
    (N'query_store_waits', N'sys.query_store_wait_stats'),
    (N'query_store_hints', N'sys.query_store_query_hints'),
    (N'database_scoped_configurations', N'sys.database_scoped_configurations'),
    (N'automatic_tuning', N'sys.database_automatic_tuning_options'),
    (N'resumable_indexes', N'sys.index_resumable_operations'),
    (N'log_info', N'sys.dm_db_log_info'),
    (N'volume_stats', N'sys.dm_os_volume_stats'),
    (N'server_memory_dumps', N'sys.dm_server_memory_dumps'),
    (N'ag_replica_states', N'sys.dm_hadr_availability_replica_states'),
    (N'ag_database_states', N'sys.dm_hadr_database_replica_states')
) AS v(capability_name, object_name)
OPTION (MAXDOP 1);
```

Probe required columns separately before referencing them:

```sql
SELECT
    OBJECT_SCHEMA_NAME(c.object_id) AS schema_name,
    OBJECT_NAME(c.object_id) AS object_name,
    c.name AS column_name
FROM sys.all_columns AS c
WHERE c.object_id IN (
    OBJECT_ID(N'sys.dm_os_sys_info'),
    OBJECT_ID(N'sys.databases'),
    OBJECT_ID(N'sys.dm_io_virtual_file_stats')
)
  AND c.name IN (
    N'sqlserver_start_time',
    N'virtual_machine_type',
    N'virtual_machine_type_desc',
    N'softnuma_configuration_desc',
    N'is_accelerated_database_recovery_on',
    N'is_optimized_locking_on'
  )
ORDER BY object_name, column_name
OPTION (MAXDOP 1);
```

Never reference an absent candidate column inside a static outer `IF`; SQL compilation may fail
before the branch runs. Use a separate query variant or guarded dynamic SQL.

## HA-ENV-004: Base Permissions

```sql
SELECT
    HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW SERVER STATE') AS can_view_server_state,
    HAS_PERMS_BY_NAME(DB_NAME(), 'DATABASE', 'VIEW DATABASE STATE')
        AS can_view_database_state,
    HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW ANY DEFINITION') AS can_view_any_definition,
    HAS_PERMS_BY_NAME(N'msdb', 'DATABASE', 'CONNECT') AS can_connect_msdb,
    IS_SRVROLEMEMBER('sysadmin') AS is_sysadmin,
    IS_MEMBER('db_owner') AS is_current_db_owner
OPTION (MAXDOP 1);
```

For SQL Server 2022+ only, execute this as a separate query:

```sql
SELECT
    HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW SERVER PERFORMANCE STATE')
        AS can_view_server_performance_state
OPTION (MAXDOP 1);
```

On SQL Server 2012-2019, do not issue the newer permission-name probe. A null permission result is
`UNKNOWN`, not denied and not granted.

## HA-ENV-005: Runtime and Virtualization Capability

Run only on the SQL Server/MI route when server performance visibility is proven.

```sql
SELECT
    virtual_machine_type,
    virtual_machine_type_desc,
    cpu_count,
    scheduler_count,
    hyperthread_ratio,
    numa_node_count,
    sqlserver_start_time
FROM sys.dm_os_sys_info
OPTION (MAXDOP 1);
```

If a column probe showed that `virtual_machine_type_desc` or `sqlserver_start_time` is absent,
load a projection that omits only the absent column.

## HA-ENV-006: HADR Capability

```sql
SELECT
    CAST(SERVERPROPERTY('IsHadrEnabled') AS int) AS is_hadr_enabled,
    CASE
        WHEN CAST(SERVERPROPERTY('EngineEdition') AS int) = 8 THEN N'platform-managed'
        WHEN CAST(SERVERPROPERTY('IsHadrEnabled') AS int) = 1 THEN N'ag-capable-enabled'
        WHEN CAST(SERVERPROPERTY('IsHadrEnabled') AS int) = 0 THEN N'ag-disabled'
        ELSE N'unknown'
    END AS hadr_capability
OPTION (MAXDOP 1);
```

Do not query AG DMVs unless `IsHadrEnabled = 1` and the relevant objects and permissions are
available. Empty AG metadata on a standalone Managed Instance is expected and is not a failure.

## Eligibility Rules

- Required platform/object/column absent: `NOT_APPLICABLE`.
- Required permission denied or metadata filtered: `UNKNOWN` and add to `blocked_checks`.
- Cost or privilege opt-in missing: add to `deferred_checks`.
- Positive probe followed by query failure: `ERROR`; quarantine that check.
- Stop only when connection/platform identity is unavailable or the platform is unsupported.
