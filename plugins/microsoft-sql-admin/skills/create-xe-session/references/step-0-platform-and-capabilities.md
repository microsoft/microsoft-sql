# Step 0 - Platform and Capabilities

## Platform Detection

Execute first:

```sql
SELECT
    CAST(SERVERPROPERTY(N'EngineEdition') AS int) AS engine_edition,
    DB_ID() AS database_id,
    DB_NAME() AS database_name
OPTION (MAXDOP 1);
```

| EngineEdition | Platform | XE scope | Default target |
|---:|---|---|---|
| 1, 2, 3, 4 | SQL Server | `ON SERVER` | `event_file` |
| 8 | Azure SQL Managed Instance | `ON SERVER` | `event_file` |
| 5 | Azure SQL Database | `ON DATABASE` | `ring_buffer` |
| 12 | Fabric SQL Database | `ON DATABASE` | `ring_buffer` |
| 6, 11 | Synapse/Fabric warehouse endpoint | Unsupported | Stop |
| other | Unknown | Unsupported | Stop |

EngineEdition 11 is not Fabric SQL Database.

## Permission Probe

SQL Server or Managed Instance:

```sql
SELECT
    HAS_PERMS_BY_NAME(NULL, NULL, N'CREATE ANY EVENT SESSION')
        AS can_create_any_event_session,
    HAS_PERMS_BY_NAME(NULL, NULL, N'ALTER ANY EVENT SESSION')
        AS can_alter_any_event_session,
    HAS_PERMS_BY_NAME(NULL, NULL, N'VIEW SERVER STATE')
        AS can_view_server_state
OPTION (MAXDOP 1);
```

Azure SQL Database or Fabric SQL Database:

```sql
SELECT
    HAS_PERMS_BY_NAME(DB_NAME(), N'DATABASE', N'CREATE ANY DATABASE EVENT SESSION')
        AS can_create_any_database_event_session,
    HAS_PERMS_BY_NAME(DB_NAME(), N'DATABASE', N'ALTER ANY DATABASE EVENT SESSION')
        AS can_alter_any_database_event_session,
    HAS_PERMS_BY_NAME(DB_NAME(), N'DATABASE', N'VIEW DATABASE STATE')
        AS can_view_database_state
OPTION (MAXDOP 1);
```

On SQL Server versions before `CREATE ANY EVENT SESSION` exists, version-gate that individual
probe and use the documented `ALTER ANY EVENT SESSION` creation requirement. Permission denial
must be reported before attempting DDL. Do not retry with elevated credentials.

## Action Inventory

Use when actions are required:

```sql
SELECT
    name,
    description
FROM sys.dm_xe_objects
WHERE object_type = N'action'
ORDER BY name
OPTION (MAXDOP 1);
```

Use only returned actions.

## Session Options

Default values unless the user or an inspected template provides a justified alternative:

| Option | Default |
|---|---:|
| MaxMemoryKB | 16384 |
| EventRetentionMode | `ALLOW_SINGLE_EVENT_LOSS` |
| MaxDispatchLatency | 5 seconds |
| MaxEventSizeKB | 0 |
| MemoryPartitionMode | `NONE` |
| TrackCausality | `OFF` |
| StartupState | `OFF` |
| StartNow | true |

Validate numeric bounds and explain any deviation from these defaults.
