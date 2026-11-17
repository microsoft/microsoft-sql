# Step 3 - SQL Server and Managed Instance Session

## Existing Session Check

```sql
SELECT
    ses.name AS session_name,
    CONVERT(bit, CASE WHEN xes.name IS NULL THEN 0 ELSE 1 END) AS is_running
FROM sys.server_event_sessions AS ses
LEFT JOIN sys.dm_xe_sessions AS xes
  ON xes.name = ses.name
WHERE ses.name = N'{{EscapedSessionName}}'
OPTION (MAXDOP 1);
```

If a row exists, do not replace it without explicit approval.

## Target

Use `event_file` by default:

1. Run the read-only query below to discover the instance log directory.
2. Use the directory portion of `ErrorLogFileName`; if it is NULL, use `InstanceDefaultLogPath`.
3. If both values are NULL, ask for a directory the SQL Server service account can write to.
4. Create a unique `.xel` filename.
5. Default to `max_file_size = 256` and `max_rollover_files = 10`.

```sql
SELECT
    SERVERPROPERTY(N'ErrorLogFileName') AS ErrorLogFileName,
    SERVERPROPERTY(N'InstanceDefaultLogPath') AS InstanceDefaultLogPath
OPTION (MAXDOP 1);
```

Use `ring_buffer` only for bounded short-term capture, explicit user choice, unavailable file
targets, or downstream compatibility.

## Event-File Template

```sql
CREATE EVENT SESSION [{{SessionName}}] ON SERVER
{{AddEventClauses}}
ADD TARGET package0.event_file(
    SET filename = N'{{ValidatedLogDirectory}}\{{UniqueFileName}}.xel',
        max_file_size = ({{MaxFileSizeMB}}),
        max_rollover_files = ({{MaxRolloverFiles}})
)
WITH (
    MAX_MEMORY = {{MaxMemoryKB}} KB,
    EVENT_RETENTION_MODE = ALLOW_SINGLE_EVENT_LOSS,
    MAX_DISPATCH_LATENCY = 5 SECONDS,
    MAX_EVENT_SIZE = 0 KB,
    MEMORY_PARTITION_MODE = NONE,
    TRACK_CAUSALITY = OFF,
    STARTUP_STATE = OFF
);
```

`max_file_size` is measured in MB. Do not append `MB` to its numeric value.

## Ring-Buffer Template

```sql
CREATE EVENT SESSION [{{SessionName}}] ON SERVER
{{AddEventClauses}}
ADD TARGET package0.ring_buffer(
    SET max_memory = ({{MaxMemoryKB}})
)
WITH (
    MAX_MEMORY = {{MaxMemoryKB}} KB,
    EVENT_RETENTION_MODE = ALLOW_SINGLE_EVENT_LOSS,
    MAX_DISPATCH_LATENCY = 5 SECONDS,
    MAX_EVENT_SIZE = 0 KB,
    MEMORY_PARTITION_MODE = NONE,
    TRACK_CAUSALITY = OFF,
    STARTUP_STATE = OFF
);
```

## Replacement

Execute only after explicit approval:

```sql
IF EXISTS (
    SELECT 1
    FROM sys.dm_xe_sessions
    WHERE name = N'{{EscapedSessionName}}'
)
    ALTER EVENT SESSION [{{SessionName}}] ON SERVER STATE = STOP;

IF EXISTS (
    SELECT 1
    FROM sys.server_event_sessions
    WHERE name = N'{{EscapedSessionName}}'
)
    DROP EVENT SESSION [{{SessionName}}] ON SERVER;
```

## Start

```sql
ALTER EVENT SESSION [{{SessionName}}] ON SERVER STATE = START;
```

## Verify

Re-run the existing-session check and report catalog existence plus actual runtime state.
