# Step 2 - Derive from an Existing Session

Use these queries only when `TemplateSessionName` is supplied.

## SQL Server or Managed Instance

### Persisted session options

```sql
SELECT
    ses.name AS session_name,
    ses.event_retention_mode_desc,
    ses.max_dispatch_latency,
    ses.max_memory,
    ses.max_event_size,
    ses.memory_partition_mode_desc,
    ses.track_causality,
    ses.startup_state
FROM sys.server_event_sessions AS ses
WHERE ses.name = N'{{EscapedTemplateSessionName}}'
OPTION (MAXDOP 1);
```

### Running events and predicates

```sql
SELECT
    xes.name AS session_name,
    xee.event_name,
    xee.event_predicate
FROM sys.dm_xe_sessions AS xes
JOIN sys.dm_xe_session_events AS xee
  ON xee.event_session_address = xes.address
WHERE xes.name = N'{{EscapedTemplateSessionName}}'
ORDER BY xee.event_name
OPTION (MAXDOP 1);
```

### Running actions

```sql
SELECT
    xes.name AS session_name,
    xea.event_name,
    xea.action_name
FROM sys.dm_xe_sessions AS xes
JOIN sys.dm_xe_session_event_actions AS xea
  ON xea.event_session_address = xes.address
WHERE xes.name = N'{{EscapedTemplateSessionName}}'
ORDER BY xea.event_name, xea.action_name
OPTION (MAXDOP 1);
```

### Running targets

```sql
SELECT
    xes.name AS session_name,
    xet.target_name,
    xet.execution_count,
    xet.execution_duration_ms
FROM sys.dm_xe_sessions AS xes
JOIN sys.dm_xe_session_targets AS xet
  ON xet.event_session_address = xes.address
WHERE xes.name = N'{{EscapedTemplateSessionName}}'
ORDER BY xet.target_name
OPTION (MAXDOP 1);
```

Do not select `target_data` merely to create a template.

## Azure SQL Database or Fabric SQL Database

Use the same query shapes with database-scoped views:

- `sys.database_event_sessions`
- `sys.dm_xe_database_sessions`
- `sys.dm_xe_database_session_events`
- `sys.dm_xe_database_session_event_actions`
- `sys.dm_xe_database_session_targets`

Join runtime views through `event_session_address`.

## Stopped Template Sessions

Runtime DMVs contain running sessions only. For stopped sessions, inspect:

- SQL Server/MI: `sys.server_event_session_events`, `sys.server_event_session_actions`,
  `sys.server_event_session_fields`, and `sys.server_event_session_targets`.
- Azure/Fabric SQL Database: corresponding `sys.database_event_session_*` views.

Use catalog metadata to reconstruct the definition, then revalidate all events and predicates
through the XE discovery tools.

## Template Transformation Rules

- Create a new destination session name.
- Do not reuse an event-file path.
- Remove actions not required by the new purpose.
- Reconsider every predicate and threshold.
- Preserve target/session settings only when safe for the new workload.
- Never copy captured target data.
- Never assume a stopped session has no definition because runtime DMVs are empty.
