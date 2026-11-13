---
name: investigate-sql-memory-issues
description: "Use when queries wait on memory grants (RESOURCE_SEMAPHORE), spill to tempdb, hit out-of-memory errors (701, 802, 8645), or PLE drops. For a broad resource snapshot, use `resource-usage-sqlserver`."
argument-hint: "[TopN] [MemoryThreshold] [ConfirmLookbackMinutes] [HistoryLookbackHours] [MinGrantKB]"
---

# Memory Pressure Investigation

## Purpose

This is the **primary entry point** for investigating memory pressure and memory-related issues in
SQL Server and Azure SQL. Use when a user reports:
- Out-of-memory errors (701, 802, 8645, 8651, 17890)
- `RESOURCE_SEMAPHORE` or `RESOURCE_SEMAPHORE_QUERY_COMPILE` waits
- High memory usage percentage in Azure SQL or Azure SQL Managed Instance
- Queries waiting for memory grants or timing out on grants
- Large or wasteful memory grants causing memory pressure for other queries
- Memory clerk growth (lock manager, query grants, CLR, third-party DLLs)
- Low Page Life Expectancy (PLE) or high Lazy Writes on SQL Server on-premises

This skill orchestrates a layered investigation:
1. Confirming sustained memory pressure via resource stats or process memory DMVs
2. Checking resource semaphore health (grant pool status and waiters)
3. Identifying active sessions consuming or waiting for memory grants
4. Breaking down memory consumption by clerk type
5. Checking for recent out-of-memory events
6. Reviewing historical plan-cache data for top memory grant consumers
7. Querying Query Store for historical memory grant patterns (when enabled)

## Scope

- Queries spilling to tempdb under memory pressure are a memory problem first: do not treat a tempdb spill under memory pressure as only a tempdb-capacity or generic slow-query issue.
- For a broad CPU, memory and IO report, use the `resource-usage-sqlserver` skill; for a broad instance health audit, use read-only SQL Server health inspection using the host SQL tools.

## Required tools

- A read-only SQL query tool connected to the target server and database. Prefer, in order: the SQL
  Tools MCP server that ships with the `microsoft-sql-admin` plugin
  (`mssql_list_database_connections`, `mssql_connect_database`, then `mssql_execute_query`); any
  other SQL tool the agent host provides for running T-SQL and reading result sets;
  [`sqlcmd`](https://learn.microsoft.com/sql/tools/sqlcmd/sqlcmd-utility) from a terminal. If the
  SQL Tools MCP server is not connected or lists no connections, follow the the SQL tools of the Visual Studio Code MSSQL extension; this plugin does not ship the standalone SQL Tools MCP server
  skill, which asks before installing or configuring anything. If no SQL tool can be made available,
  give the user the T-SQL to run and ask for the results.
- Least privilege: connect that tool with a diagnostic login that cannot write, for example one that
  holds only `VIEW SERVER PERFORMANCE STATE` (`VIEW SERVER STATE` before SQL Server 2022) or, on Azure
  SQL Database, `VIEW DATABASE PERFORMANCE STATE` or `##MS_ServerStateReader##`, plus any other read
  permission these queries need. A tool is only as read-only as the login it connects with.

## Prerequisites

- Must be connected to the target database.
- Confirm which server and database you are connected to (e.g. `SELECT @@SERVERNAME, DB_NAME(), SUSER_SNAME(), SERVERPROPERTY('EngineEdition')`).
- Steps 2–4 query live DMVs; run them quickly in sequence while memory pressure is active.
- Step 7 requires Query Store to be enabled on the target database.

**Permissions:**
- **SQL Server on-prem / IaaS**: Requires `VIEW SERVER STATE` for server-level DMVs (Steps 1c, 2, 3, 4, 6).
- **Azure SQL Managed Instance**: Requires `VIEW SERVER STATE` or `VIEW SERVER PERFORMANCE STATE`.
- **Azure SQL Database / Fabric SQL DB**: Requires `VIEW DATABASE STATE` for database-scoped DMVs (Steps 1b, 5, 7). Steps 2 and 4 use server-scoped DMVs (`sys.dm_exec_query_resource_semaphores`, `sys.dm_os_memory_clerks`) that require `VIEW SERVER STATE` — on Azure SQL DB these may require membership in the `##MS_ServerStateReader##` server role.
- If a step fails with a permission error, the agent should report the missing permission and skip to the next step rather than stopping the entire investigation.

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| TopN | 10 | Number of top queries/sessions to return in each step |
| MemoryThreshold | 90 | Memory usage percentage threshold for confirming pressure |
| ConfirmLookbackMinutes | 30 | Window (minutes) for the `sys.dm_db_resource_stats` memory confirmation check |
| HistoryLookbackHours | 24 | Lookback window (hours) for plan-cache and Query Store queries |
| MinGrantKB | 5120 | Minimum memory grant size (KB) to include in historical analysis (default = 5 MB) |

## Platform Support

Step 1 detects the engine edition first, then routes to the correct query:

| EngineEdition | Platform | DMV |
|---|---|---|
| 5 | Azure SQL Database | `sys.dm_db_resource_stats` |
| 8 | Azure SQL Managed Instance | `sys.dm_os_sys_memory` + `sys.dm_os_process_memory` + perf counters (same as on-prem; `sys.dm_db_resource_stats` not available on MI) |
| 12 | Fabric SQL Database | `sys.dm_db_resource_stats` |
| 6 | Azure Synapse Analytics (Dedicated SQL pool) | Not supported — memory management differs significantly |
| 11 | Azure Synapse serverless SQL pool / Fabric Warehouse | Not supported — memory management differs significantly |
| other | SQL Server on-prem / IaaS | `sys.dm_os_sys_memory` + `sys.dm_os_process_memory` + perf counters |

## Investigation Workflow

Read [references/queries.md](references/queries.md) for all SQL queries and execute each step
with the SQL query tool. Steps 2, 3, and 4 target live DMV state — run them while memory
pressure is active. Steps 6 and 7 cover historical data and can be run at any time.

### Step 1: Confirm Memory Pressure
Load Step 1 from `references/queries.md`. First run the **Step 1a** platform-detection query to
get `engine_edition`. Then run **Step 1b** (Azure SQL DB / Fabric, editions 5/12) or **Step 1c** (MI / on-prem, edition 8 or other) —
never both. If no rows returned (Azure) or no pressure signals (on-prem), skip Steps 2–4 and
proceed to Steps 5–7 for historical analysis.

### Step 2: Resource Semaphore Health (Grant Pool Status)
Load and execute the Step 2 query. Key signal: `waiter_count > 0` means queries are actively
blocked waiting for memory grants — this is the most acute form of memory pressure.

### Step 3: Active and Waiting Memory Grant Consumers
Load and execute the Step 3 query. Shows sessions holding or waiting for grants. Sessions with
`grant_time IS NULL` are waiting. Look for over-granted sessions (using < 20% of grant).

### Step 4: Top Memory Clerks
Load and execute the Step 4 query. Identifies which internal components consume the most memory.
Buffer pool dominance is normal — only concerning when paired with low available memory or IO waits.

### Step 5: Recent Out-of-Memory Events
Load and execute the Step 5 query. Available only on Azure SQL DB / MI / Fabric (editions 5, 8, 12).
On SQL Server on-prem, returns informational message — skip and rely on Steps 2–4.

### Step 6: Historical Top Memory Grant Consumers (Plan Cache)
Load and execute the Step 6 query. Version-gated: full grant columns (`max_grant_kb`, `total_spills`,
etc.) on SQL 2017+ / Azure SQL; fallback query on older versions. Identifies queries that
historically request the largest memory grants.

### Step 7: Historical Top Memory Grant Consumers (Query Store)
Load and execute the Step 7 queries (two versions: by query hash for pattern analysis, by
query ID/plan ID for drill-down). Requires Query Store enabled — skip if not available.

## Gotchas

- **Fabric edition:** EngineEdition 12 = Fabric SQL Database (supported), EngineEdition 11 = Synapse serverless / Fabric Warehouse (not supported). All edition gates use `IN (5, 8, 12)`.
- **Step 5 DMV:** `sys.dm_os_out_of_memory_events` exists only on Azure SQL / MI / Fabric — query has runtime guard.
- **Step 6 columns:** `total_spills`, `max_grant_kb`, etc. are SQL 2017+ only — query uses `sp_executesql` with version gate.
- **Buffer pool dominance:** `MEMORYCLERK_SQLBUFFERPOOL` being the largest clerk is **normal**. Only flag when paired with low available memory, high `PAGEIOLATCH_*` waits, or low PLE.
- **Query Store memory units:** `avg_query_max_used_memory` is in 8KB pages — multiply by 8/1024 for MB.

## Report

Read [references/report-template.md](references/report-template.md) to format the final report.

## Root Cause Assessment

Read [references/remediation-guide.md](references/remediation-guide.md) to determine the dominant
root cause based on memory clerk patterns, grant status, and OOM events, then prescribe next steps.
