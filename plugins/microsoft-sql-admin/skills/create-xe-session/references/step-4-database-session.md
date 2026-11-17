# Step 4 - Azure SQL and Fabric SQL Database Session

## Existing Session Check

```sql
SELECT
    des.name AS session_name,
    CONVERT(bit, CASE WHEN xes.name IS NULL THEN 0 ELSE 1 END) AS is_running
FROM sys.database_event_sessions AS des
LEFT JOIN sys.dm_xe_database_sessions AS xes
  ON xes.name = des.name
WHERE des.name = N'{{EscapedSessionName}}'
OPTION (MAXDOP 1);
```

If a row exists, do not replace it without explicit approval.

## Ring-Buffer Template

```sql
CREATE EVENT SESSION [{{SessionName}}] ON DATABASE
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

Ring buffers are circular and volatile. Use bounded, selective predicates.

## Replacement

Execute only after explicit approval:

```sql
IF EXISTS (
    SELECT 1
    FROM sys.dm_xe_database_sessions
    WHERE name = N'{{EscapedSessionName}}'
)
    ALTER EVENT SESSION [{{SessionName}}] ON DATABASE STATE = STOP;

IF EXISTS (
    SELECT 1
    FROM sys.database_event_sessions
    WHERE name = N'{{EscapedSessionName}}'
)
    DROP EVENT SESSION [{{SessionName}}] ON DATABASE;
```

## Start

```sql
ALTER EVENT SESSION [{{SessionName}}] ON DATABASE STATE = START;
```

## Verify

Re-run the existing-session check and report catalog existence plus actual runtime state.
