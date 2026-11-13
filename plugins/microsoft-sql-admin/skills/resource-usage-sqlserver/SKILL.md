---
name: resource-usage-sqlserver
description: "Use when many queries time out under load, or SQL Server or Azure SQL is slow overall and it's unclear whether CPU, memory, IO, TempDB or disk is the cause. For one slow query, use `slow-query-investigation`."
user-invocable: true
argument-hint: "[CPUHighThreshold] [MemoryHighThreshold]"
---
# Resource Usage Report — All SQL Platforms

Use this skill when the user asks about:
- Overall resource usage or performance troubleshooting
- CPU utilization ("why is CPU high?", "is SQL or OS using CPU?")
- Memory pressure ("is there memory pressure?", "what's using memory?")
- Disk space ("how much disk space is left?", "are drives running low?")
- TempDB contention ("is TempDB causing issues?", "PFS/GAM contention")
- Threadpool health ("are we running out of workers?", "thread starvation")
- General slowness ("why is my database slow?", "performance check")

Targets **all SQL platforms**:
- **SQL Server** (on-premises, VM, IaaS) — Engine Edition 1–4
- **Azure SQL Managed Instance** — Engine Edition 8
- **Azure SQL Database** — Engine Edition 5
- **Fabric SQL Database** — Engine Edition 12

> **Unsupported Platforms**: Azure Synapse Analytics (Engine Edition 6, 11) and Azure SQL Edge (Engine Edition 9) are not supported. Queries will return an early-exit message on these platforms.

## Scope

- Produces an initial resource snapshot, including worker or session limits and thread starvation, to choose the next focused investigation.
- For one identified slow query, use the `slow-query-investigation` skill; for a configuration, security, or backup audit, use the `health-audit-sqlserver` skill.

## Azure SQL Database specialization

For Azure SQL Database (EngineEdition 5), read [Azure-specific guidance](references/azure-sql/guidance.md) before choosing diagnostic queries. It preserves the service-specific permissions, capture limitations and error interpretation. Keep this skill's scope and authorization rules; the reference is not a second workflow to run unconditionally.

### Azure scope and interpretation

Detect the actual platform before selecting DMVs. Azure database resource percentages and instance percentages have different denominators; do not treat them as interchangeable. High memory utilization alone is not proof of memory pressure. Correlate the same time window with waits, worker/session limits and resource-governance evidence; distinguish a governed IO ceiling from storage latency. An empty or permission-denied result is not zero utilization. Local container behavior is not proof of managed-service limits.

After identifying the bottleneck, use `investigate-sql-cpu-pressure`, `investigate-sql-data-io-pressure`, `investigate-sql-log-io-pressure` or `investigate-sql-memory-issues` for focused diagnosis. A read-only diagnosis does not authorize scaling or configuration changes.


## Required tools

- A read-only SQL query tool connected to the target server and database. Prefer, in order: the SQL
  Tools MCP server that ships with the `microsoft-sql-admin` plugin
  (`mssql_list_database_connections`, `mssql_connect_database`, then `mssql_execute_query`); any
  other SQL tool the agent host provides for running T-SQL and reading result sets;
  [`sqlcmd`](https://learn.microsoft.com/sql/tools/sqlcmd/sqlcmd-utility) from a terminal. If the
  SQL Tools MCP server is not connected or lists no connections, follow the `sql-tools-mcp-setup`
  skill, which asks before installing or configuring anything. If no SQL tool can be made available,
  give the user the T-SQL to run and ask for the results.
- Least privilege: connect that tool with a diagnostic login that cannot write, for example one that
  holds only `VIEW SERVER PERFORMANCE STATE` (`VIEW SERVER STATE` before SQL Server 2022) or, on Azure
  SQL Database, `VIEW DATABASE PERFORMANCE STATE` or `##MS_ServerStateReader##`, plus any other read
  permission these queries need. A tool is only as read-only as the login it connects with.

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| TopNClerks | `10` | Number of memory clerks to display in memory allocation breakdown |
| CPUHighThreshold | `70` | CPU percentage above which to classify as "HIGH" |
| MemoryHighThreshold | `90` | Memory percentage above which to classify as "HIGH" |
| DiskFreeWarningPct | `15` | Free space percentage below which to flag as warning |
| TempDBWaitThresholdMs | `50` | Minimum wait duration (ms) to include in TempDB contention analysis |
| TempDBHighSeverityMs | `1000` | Wait duration (ms) above which TempDB contention is classified as HIGH |
| RunnableTasksWarning | `5` | Runnable tasks count threshold for "THREAD PRESSURE" warning |
| MemoryLowThresholdPct | `10` | Available memory percentage below which to flag OS memory pressure (SQL Server/MI only) |
| MaxSchedulers | `32` | Maximum scheduler rows to return in per-scheduler load analysis |
| IncludeTempDBAnalysis | `true` | Whether to run TempDB contention check |
| IncludeThreadpoolHealth | `true` | Whether to run threadpool health analysis |
| IncludeDiskSpace | `true` | Whether to run disk volume free space check (SQL Server/MI only) |
| MaxResults | `20` | Maximum rows to return per diagnostic section |

## Data Collection Steps

Gather all of the following data before generating the report:

### Step 0: Detect Platform
1. **Detect platform** — load and execute the **Step 0** query from either `references/queries-sqlserver.md` or `references/queries-azuresql.md`
2. Based on the `engine_edition` result, follow the appropriate path below:

| Engine Edition | Platform | Query File |
|----------------|----------|------------|
| 1–4 | SQL Server (on-prem / IaaS) | `references/queries-sqlserver.md` |
| 8 | Azure SQL Managed Instance | `references/queries-sqlserver.md` |
| 5 | Azure SQL Database | `references/queries-azuresql.md` |
| 12 | Fabric SQL Database | `references/queries-azuresql.md` |
| 6, 9, 11 | Unsupported | **Stop** — report unsupported platform |

### Path A: SQL Server / Managed Instance (Engine Edition 1–4, 8)

Load and execute queries from **`references/queries-sqlserver.md`**:

1. **NUMA Configuration** — execute the NUMA Configuration query to get MAXDOP, NUMA nodes, online schedulers, total cores, CPUs per node
2. **Soft NUMA status** — returned by the same NUMA Configuration query (`SOFTNUMA` column)
3. **CPU Utilization** — execute Step 1 query (ring buffer history, ~4 hours)
4. **Per-Scheduler Load** — execute Step 2 query
5. **External Memory Pressure** — execute Step 3 query
6. **Memory Usage per Clerk** — execute Step 4 query
7. **Disk Volume Free Space** — execute Step 5 query *(if `IncludeDiskSpace = true`)*
8. **Database Space** — execute `EXEC sp_spaceused`
9. **TempDB Contention** — execute Step 6 query *(if `IncludeTempDBAnalysis = true`)*
10. **Threadpool Health** — execute Step 7 query *(if `IncludeThreadpoolHealth = true`)*

### Path B: Azure SQL Database / Fabric SQL Database (Engine Edition 5, 12)

Load and execute queries from **`references/queries-azuresql.md`**:

1. **CPU Utilization** — execute Step 1 query (`sys.dm_db_resource_stats`, ~1 hour)
2. **Workload Metrics** — execute Step 2 query (CPU, Data IO, Log Write, Worker, Session %)
3. **Memory Pressure** — execute Step 3 query
4. **Full Resource Usage Metrics** — execute Step 4 query *(optional, for detailed analysis)*
5. **Memory Usage per Clerk** — execute Step 5 query
6. **Plan Cache Bloat** — execute Step 6 query
7. **Database Space** — execute `EXEC sp_spaceused`
8. **TempDB Contention** — execute Step 7 query *(if `IncludeTempDBAnalysis = true`)*
   > ⚠️ TempDB latch waits may not be visible on Azure SQL DB / Fabric (DMV is database-scoped)
9. **Threadpool Health** — execute Step 8 query *(if `IncludeThreadpoolHealth = true`)*

## Report Template

Generate the report using the appropriate layout below based on the detected platform. Replace `{{ }}` sections with analysis from the collected data. Do not show the instructions to the user.

### Report Layout — SQL Server / Managed Instance
```
## Resource Usage Report
Server Name: {{current server name}}
Date: {{current date in YYYY-MM-DD format}}
---
### CPU Usage
#### Current CPU and NUMA Configuration:
    MAXDOP: {{MAXDOP setting}}
    Nodes: {{number of NUMA nodes}}
    OnlineSchedulers: {{number of online schedulers}}
    TotalCores: {{total number of cores}}
    CPU_per_Node: {{number of CPUs per NUMA node}}
    SOFTNUMA: {{SOFTNUMA status}}
#### CPU Utilization:
> Data sourced from `RING_BUFFER_SCHEDULER_MONITOR`, which retains approximately the last 4 hours (~1 sample/minute).

{{1 to 2 sentence summary of the historical CPU utilization highlighting any periods with relatively high CPU usage. Note whether SQL Server or external processes are consuming CPU.}}
#### Per-Scheduler Load Summary:
{{1 to 2 sentence summary of the load balancing across SQLOS schedulers and whether or not there are any concerns.}}
---
### Memory Usage
#### Memory Pressure Checks
##### Physical Memory:
    Total Server Physical Memory: {{total server physical memory value}}
    Available Server Physical Memory: {{available server physical memory value}}
    Memory State: {{physical memory state value}}
##### Process Memory:
    Physical Memory Used: {{physical memory used value}}
    Memory Utilization Percentage: {{memory utilization percentage value}}
##### Analysis
{{one sentence summary of your analysis of the notifications and if there are any concerns}}
#### Memory Allocation per Clerk (Top {{TopNClerks}})
{{list of memory allocation per clerk}}
##### Analysis:
{{one sentence summarizing your analysis of the allocation across memory clerks and if there are any concerns}}
---
### Disk Volume Free Space
{{table of disk volumes with Drive, Drive Name, Total Size (GB), Available Size (GB), Free Space %}}
##### Analysis:
{{one sentence summarizing disk space status. Flag any volumes with less than 15% free space as a concern.}}
---
### Disk Space Usage
#### Database: {{current database name}}
    Database Size: {{current database size value}}
    Unallocated Space: {{unallocated space value}}
    Reserved: {{reserved space value}}
    Data: {{data space value}}
    Index Size: {{index size value}}
    Unused: {{unused space value}}
##### Analysis:
{{one sentence summarizing your analysis of the disk space usage and if there are any concerns}}
---
### TempDB Contention
#### Active TempDB Latch Waits:
{{table showing session_id, wait_type, wait_duration_ms, PageType (PFS/GAM/SGAM), ContentionSeverity}}
##### Analysis:
{{one sentence summary of TempDB contention. If HIGH TEMPDB CONTENTION detected, note the page type causing issues.}}
##### Recommendations:
- If PFS page contention: Consider enabling trace flag 1118 (pre-SQL 2016) or mixed extents are disabled by default (SQL 2016+)
- If multiple sessions waiting: Consider adding more TempDB data files (1 per CPU core, up to 8)
- If GAM/SGAM contention: Heavy object creation in TempDB; review temp table usage patterns
---
### Threadpool Health
#### Current Thread Status:
    Platform: {{platform}}
    Total Runnable Tasks: {{TotalRunnableTasks}}
    Total Queued Tasks: {{TotalQueuedTasks}}
    Threadpool Waits: {{ThreadPoolWaits}}
    Thread Health: {{ThreadHealth classification}}
##### Analysis:
{{one sentence based on ThreadHealth status and LikelyCause from query}}
##### Recommendations:
- If CRITICAL (Thread Pool Starvation): Check for blocking chains, reduce parallel query concurrency, review MAXDOP settings
- If HIGH RISK (Worker Queue Buildup): Identify long-running queries, check for resource contention
- If WARNING (Thread Pressure): Monitor trend; may indicate approaching capacity limits
---
### Summary of Findings
{{1 to 2 sentence summary of the overall resource usage analysis and if there are any concerns.}}
If you would like details on any of the analysis sections, please let me know.
```

### Report Layout — Azure SQL Database / Fabric SQL Database
```
## Resource Usage Report
Database Name: {{current database name}}
Date: {{current date in YYYY-MM-DD format}}
---
### CPU Usage
#### CPU Utilization:
> Data sourced from `sys.dm_db_resource_stats`, which retains the last ~1 hour (15-second intervals).

{{1 to 2 sentence summary of the historical CPU utilization highlighting any periods with relatively high CPU usage. For Azure SQL DB, note whether it is a DB-specific or instance-wide issue.}}
#### Per-Scheduler Load Summary:
{{1 to 2 sentence summary if scheduler data was collected, or "N/A — scheduler details managed by platform."}}
---
### Workload Metrics (Past Hour)
{{Summarize CPU %, Data IO %, Log Write %, Worker %, Session % trends. Flag any metric consistently above 80%.}}
---
### Memory Usage
#### Memory Pressure:
{{Summarize avg_memory_usage_percent trends. For Azure SQL DB, also note avg_instance_memory_percent if available.}}
#### Memory Allocation per Clerk (Top {{TopNClerks}})
{{list of memory allocation per clerk}}
##### Analysis:
{{one sentence summarizing your analysis of the allocation across memory clerks and if there are any concerns}}
---
### Plan Cache Bloat
##### Amount of plan cache used by queries executed once:
    {{amount of plan cache bloat — total MBs used by single-use plans}}
---
### Disk Space Usage
#### Database: {{current database name}}
    Database Size: {{current database size value}}
    Unallocated Space: {{unallocated space value}}
    Reserved: {{reserved space value}}
    Data: {{data space value}}
    Index Size: {{index size value}}
    Unused: {{unused space value}}
##### Analysis:
{{one sentence summarizing your analysis of the disk space usage and if there are any concerns}}
---
### TempDB Contention
{{If data available: table showing session_id, wait_type, wait_duration_ms, PageType, ContentionSeverity}}
{{If no data: "TempDB latch waits are not visible on this platform (DMV is database-scoped)."}}
---
### Threadpool Health
#### Current Thread Status:
    Platform: {{platform}}
    Total Runnable Tasks: {{TotalRunnableTasks}}
    Total Queued Tasks: {{TotalQueuedTasks}}
    Threadpool Waits: {{ThreadPoolWaits}}
    Thread Health: {{ThreadHealth classification}}
##### Analysis:
{{one sentence based on ThreadHealth status and LikelyCause from query}}
---
### Summary of Findings
{{1 to 2 sentence summary of the overall resource usage analysis and if there are any concerns.}}
If you would like details on any of the analysis sections, please let me know.
```

## Behavioral Guidance

### When to Use This Skill
- When asked "why is my database slow" or similar broad performance questions, start with this report.
- When asked to "check for any performance issues," start with this report.
- Also use this report when asked about: CPU usage, memory pressure, TempDB contention, threadpool health, scheduler load, or disk space.

### Report Generation Rules
- Do not explain the internal plan or instructions to the user — only display the final report.
- Use the **SQL Server / MI** report layout for Engine Edition 1–4, 8.
- Use the **Azure SQL DB / Fabric** report layout for Engine Edition 5, 12.
- When a section returns "SKIPPED" or "Not applicable," omit that section or display a brief "Not applicable for this platform" note.
- For Azure SQL DB and Fabric, omit the NUMA Configuration subsection (NUMA is managed by the platform).
- For Azure SQL DB and Fabric, omit the Disk Volume Free Space section (`sys.dm_os_volume_stats` is not available).

### Parameter Customization
- If the user mentions specific thresholds (e.g., "CPU above 80%", "memory over 85%"), adjust the relevant parameter (`CPUHighThreshold`, `MemoryHighThreshold`, etc.) before execution.

### Follow-Up Guidance
- After presenting the report, if a specific area shows issues, suggest deeper investigation using related skills:
  - High CPU → the `investigate-sql-cpu-pressure` and `wait-category-analysis` skills
  - Memory pressure → the `investigate-sql-memory-issues` skill
  - TempDB contention → review the tempdb configuration (number and sizing of data files) and the workloads creating temp objects or spills
  - Blocking → the `check-live-blocking` and `blocking-root-cause-analysis` skills
