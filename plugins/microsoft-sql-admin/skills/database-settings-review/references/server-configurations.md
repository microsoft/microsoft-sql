# SQL Server and Managed Instance Configurations

Run only for SQL Server (`EngineEdition` 1-4) or Azure SQL Managed Instance (`EngineEdition` 8).
On Azure SQL Database, report this reference as `Unavailable - server configuration is
platform-managed/not exposed`.

## Configuration values

```sql
SELECT
      name
    , value AS configured_value
    , value_in_use
    , minimum
    , maximum
    , is_dynamic
    , is_advanced
FROM sys.configurations
WHERE name IN
(
      N'max degree of parallelism'
    , N'cost threshold for parallelism'
    , N'max server memory (MB)'
    , N'optimize for ad hoc workloads'
    , N'backup compression default'
)
ORDER BY name
OPTION (MAXDOP 1);
```

If access fails, report `Unavailable - insufficient permission`.

## CPU context for MAXDOP

```sql
SELECT
      cpu_count
    , scheduler_count
    , socket_count
    , numa_node_count
    , softnuma_configuration_desc
FROM sys.dm_os_sys_info
OPTION (MAXDOP 1);
```

If the DMV is inaccessible, keep the MAXDOP value as a fact and do not make a topology-specific
recommendation.

## Interpretation

- **MAXDOP:** Analyze the server value together with any database-scoped override, NUMA topology,
  workload concurrency, and query-level hints. Do not apply a universal "cores up to 8" rule.
- **Cost threshold for parallelism:** Low values can create excessive small parallel plans; high
  values can suppress useful parallelism. Validate with representative plans and concurrency.
- **Max server memory:** The value must leave memory for the operating system, agents, drivers,
  backups, and other co-located services. On MI, platform memory management limits direct tuning.
- **Optimize for ad hoc workloads:** Can reduce single-use plan cache memory, with the tradeoff of
  an extra compilation phase for statements executed again.
- **Backup compression default:** Saves storage and I/O but consumes CPU. On MI, managed backups
  are a separate platform behavior.

Report configured and in-use values separately when they differ.
