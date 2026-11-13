---
name: top-queries-noqds
description: "Use when the user wants top CPU or most expensive queries, or queries with several cached plans, and Query Store is off or unavailable (DMVs only). With Query Store on, use `query-store-investigation`."
user-invocable: true
---

# Top Queries (Without Query Store)

## Purpose

Use this skill when the user asks about top queries, resource-consuming queries, or query performance
and **Query Store is not enabled** on the connected database.

> **Feature Gate**: Use this skill only when Query Store is disabled. If Query Store is enabled,
> prefer `query-store-volatile-historical-slow-queries-comparison` (Steps 1 and 7),
> `query-store-investigation`, or `wait-category-analysis` instead.

This skill orchestrates a three-step investigation:
1. Platform detection and edition validation
2. Active top CPU consumers (live requests) and historical top CPU consumers (plan cache)
3. Queries with multiple execution plans (plan instability detection)

## Scope

- For the root cause of confirmed CPU pressure, use the `investigate-sql-cpu-pressure` skill.
- For intermittent slow-query diagnosis, use the `slow-query-investigation` skill.

## Prerequisites

- Must be connected to the target database.
- **Permissions:**
  - Azure SQL Database / Fabric SQL Database: Requires `VIEW DATABASE STATE`
  - SQL Server / Managed Instance: Requires `VIEW SERVER STATE`
- Confirm which server and database you are connected to
  (e.g. `SELECT @@SERVERNAME, DB_NAME(), SUSER_SNAME(), SERVERPROPERTY('EngineEdition')`).
- Step 2a queries live DMVs; run while the workload is active.

## Required tools

- A read-only SQL query tool connected to the target server and database. Prefer, in order: the SQL
  Tools MCP server that ships with the `microsoft-sql-admin` plugin (`mssql_list_database_connections`,
  `mssql_connect_database`, then `mssql_execute_query`); any other SQL tool the agent host provides for
  running T-SQL and reading result sets;
  [`sqlcmd`](https://learn.microsoft.com/sql/tools/sqlcmd/sqlcmd-utility) from a terminal. If the SQL
  Tools MCP server is not connected or lists no connections, follow the `sql-tools-mcp-setup` skill,
  which asks before installing or configuring anything. If no SQL tool can be made available, give the
  user the T-SQL to run and ask for the results.
- Least privilege: connect that tool with a diagnostic login that cannot write, for example one that
  holds only `VIEW SERVER PERFORMANCE STATE` (`VIEW SERVER STATE` before SQL Server 2022) or, on Azure
  SQL Database, `VIEW DATABASE PERFORMANCE STATE` or `##MS_ServerStateReader##`, plus any other read
  permission these queries need. A tool is only as read-only as the login it connects with.

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| TopN | 10 | Number of top queries to return in each step |
| HistoryLookbackHours | 12 | Lookback window (hours) for plan cache history queries |
| MinExecutionCount | 10 | Minimum execution count for a plan to appear in historical results |
| MinTotalWorkerTimeUs | 1000000 | Minimum cumulative `total_worker_time` (microseconds) for Step 2b (default = 1 second) |
| MinPlanCount | 2 | Minimum distinct plan count for multi-plan detection in Step 3 |

## Investigation Workflow

Execute all steps in order. Step 2a targets live sessions — run while the workload is active.
Steps 2b and 3 cover historical/cumulative data and can be run at any time.

---

### Step 1: Platform Detection

> Run with the SQL query tool. Detects engine edition and validates platform support.

> **Query:** See [references/queries.md#step-1-platform-detection](references/queries.md#step-1-platform-detection)

**What to do:**
| Assessment | Action |
|------------|--------|
| `is_unsupported_dw = 1` | **Stop** — this skill does not apply to Azure Synapse Analytics or Fabric Warehouse (EngineEdition 6 or 11). Fabric SQL Database (EngineEdition 12) is supported |
| `is_query_store_enabled = 1` | Query Store is active — prefer `query-store-volatile-historical-slow-queries-comparison` (Steps 1 and 7), `query-store-investigation`, or `wait-category-analysis` for richer analysis. Proceed with this skill only if DMV-based analysis is specifically needed |
| Any other edition | Proceed to Step 2 |

---

### Step 2a: Active Top CPU Consumers — Live Requests

> Run with the SQL query tool. Shows currently executing requests sorted by CPU consumption.
This captures what is running **right now** — if the expensive query already finished, it won't appear here.

> **Query:** See [references/queries.md#step-2a-active-top-cpu-consumers--live-requests](references/queries.md#step-2a-active-top-cpu-consumers--live-requests)

**Interpreting results:**
- `cpu_time_ms` → total CPU consumed by this request so far. The primary sort metric.
- `dop > 1` → query is using parallelism. Check if DOP is appropriate for the workload.
- `logical_reads` → pages touched in memory. Very high values indicate scan-heavy queries.
- `physical_reads > 0` → data being read from disk, not just CPU-bound.
- `wait_type` → if set, the session is currently waiting (e.g., `CXPACKET` = parallel wait, `PAGEIOLATCH` = IO wait).
- `query_hash` → unique identifier for the query pattern. Use to correlate with Step 2b and Step 3.

**What to do:**
| Finding | Recommendation |
|---------|----------------|
| High `cpu_time_ms` + `dop = 1` | Serial execution on a CPU-heavy query — check if parallelism is being suppressed by MAXDOP or cost threshold settings |
| High `cpu_time_ms` + `dop > 4` | Excessive parallelism — review MAXDOP settings and check for parallel plan skew (one thread doing most work) |
| High `logical_reads` + high CPU | Scan-heavy query — look for missing indexes or non-sargable predicates |
| `wait_type = CXPACKET` or `CXCONSUMER` | Parallel wait — check for skewed parallelism or inappropriate DOP |
| No rows returned | No active CPU-intensive requests right now — proceed to Step 2b for historical analysis |

---

### Step 2b: Historical Top CPU Consumers — Plan Cache

> Run with the SQL query tool. Identifies the most CPU-intensive queries from the plan cache
based on cumulative `total_worker_time`. This captures queries that have already completed.

> **Query:** See [references/queries.md#step-2b-historical-top-cpu-consumers--plan-cache](references/queries.md#step-2b-historical-top-cpu-consumers--plan-cache)

> **Drill-down:** See [references/queries.md#drill-down-retrieve-plans-for-a-specific-query-hash](references/queries.md#drill-down-retrieve-plans-for-a-specific-query-hash)

**Interpreting results:**
- `total_cpu_ms` → cumulative CPU time across all executions. The primary ranking metric.
- `avg_cpu_ms_per_exec` → average CPU per execution. High values indicate intrinsically expensive queries.
- `max_cpu_ms` >> `avg_cpu_ms_per_exec` → variable CPU cost, possibly parameter-sensitive.
- `logical_reads_per_exec` → pages touched per execution. Very high values (> 100K) suggest table/index scans.
- High `execution_count` + moderate `avg_cpu_ms_per_exec` → frequent query with aggregate CPU impact.

**What to do:**
| Finding | Recommendation |
|---------|----------------|
| High `avg_cpu_ms_per_exec` (> 1000 ms) | Intrinsically expensive query — review execution plan for scans, sorts, hash joins |
| High `execution_count` + moderate CPU per exec | Frequent execution driving aggregate CPU — consider caching, reducing call frequency, or optimizing the query |
| `max_cpu_ms` >> `avg_cpu_ms_per_exec` | Parameter sensitivity — compare plans for different parameter values; consider `OPTIMIZE FOR` or plan guides |
| High `logical_reads_per_exec` (> 100K) | Scan-heavy pattern — add covering indexes or narrow the scan with better predicates |
| High `total_logical_writes` | Write-heavy query — check for large INSERT/UPDATE/DELETE batches |
| No rows returned | Plan cache may be cold (recently cleared) or thresholds too high — lower `MinExecutionCount` or `MinTotalWorkerTimeUs` |

---

### Step 3: Queries with Multiple Execution Plans (Plan Instability)

> Run with the SQL query tool. Identifies queries that have accumulated multiple distinct
execution plans in the plan cache. Multiple plans for the same `query_hash` often indicate
parameter sniffing, statistics staleness, or SET option differences.

> **Query:** See [references/queries.md#step-3-queries-with-multiple-execution-plans-plan-instability](references/queries.md#step-3-queries-with-multiple-execution-plans-plan-instability)

**Interpreting results:**
- `plan_count > 2` → multiple plans accumulated. The higher the count, the more unstable the plan choice.
- `worst_avg_cpu_ms` vs `best_avg_cpu_ms` → large gaps indicate plan regression. One plan may be orders of magnitude worse.
- `total_executions` → impact scope. High execution count with plan instability affects more users.
- `object_name` → if it's a stored procedure, parameter sniffing is the most likely cause.

**What to do:**
| Finding | Recommendation |
|---------|----------------|
| `plan_count >= 2` with large `worst/best` gap | Parameter sniffing — compare plans for different parameter values. Check if `OPTION (RECOMPILE)` or `OPTIMIZE FOR UNKNOWN` helps |
| `plan_count >= 2` on a stored procedure | Classic parameter sniffing scenario — consider adding `WITH RECOMPILE`, plan guides, or splitting the proc by parameter patterns |
| `plan_count >= 2` with similar `worst/best` | SET option differences (e.g., `ANSI_NULLS`, `QUOTED_IDENTIFIER`) across connections — check application connection strings |
| Many queries with multiple plans | Systemic issue — check if statistics are stale (`DBCC SHOW_STATISTICS`), auto-stats is enabled, or CE model changed |
| No rows returned | No plan instability detected — if performance is still poor, focus on Step 2b results |

---

## Report Template

Combine results from all steps into this unified report:

```
## Top Queries Report (Without Query Store)
Database:   {{database name}}
Date:       {{current date in YYYY-MM-DD format}}
Data Source: sys.dm_exec_requests, sys.dm_exec_query_stats
Parameters: TopN={{TopN}}, HistoryLookback={{HistoryLookbackHours}}h,
            MinExecCount={{MinExecutionCount}}, MinCPU={{MinTotalWorkerTimeUs}}µs

---

### Step 1 — Platform Detection

{{Include engine_type and edition. Stop if DW/Synapse.}}

---

### Step 2a — Active Top CPU Consumers

| Session | Status | CPU (ms) | Elapsed (ms) | Logical Reads | Phys Reads | DOP | Wait Type | Query Hash | Object |
|---------|--------|----------|--------------|---------------|------------|-----|-----------|------------|--------|
{{Top rows. Flag cpu_time_ms > 5000 as ⚠ significant.}}

---

### Step 2b — Historical Top CPU Consumers (Plan Cache)

| Query Hash | Plans | Executions | Total CPU (ms) | Avg CPU/Exec (ms) | Max CPU (ms) | Logical Reads/Exec | Last Exec | Object |
|------------|------------|----------------|--------------------|--------------|--------------------|-----------|--------|
{{Top rows. Flag avg_cpu_ms_per_exec > 1000 as ⚠ expensive.}}

---

### Step 3 — Multi-Plan Queries (Plan Instability)

| Query Hash | Plan Count | Total Executions | Total CPU (ms) | Worst Avg CPU (ms) | Best Avg CPU (ms) | Object |
|------------|------------|------------------|----------------|---------------------|--------------------|--------|
{{Top rows. Flag plan_count > 2 as ⚠. Flag large worst/best gap as ⚠⚠.}}

---

### Root Cause Assessment

{{Use the decision tree below.}}

---

### Recommended Next Steps

{{Based on root cause, provide specific actions.}}
```

---

## Root Cause Decision Tree and Next Steps

### High CPU from a single query (Step 2a or 2b dominant)

**Root cause: Intrinsically expensive query consuming excessive CPU.**

Next steps:
1. Retrieve the execution plan: `SELECT * FROM sys.dm_exec_query_plan(<plan_handle>)`
2. Look for table/index scans, hash joins, sort operators with high row counts
3. Add covering indexes on filter/join columns to convert scans to seeks
4. Check for implicit conversions or non-sargable predicates preventing index usage
5. Consider query rewrite to reduce the working set

### High aggregate CPU from frequent queries (Step 2b: high execution_count)

**Root cause: Moderate-cost query called very frequently — aggregate CPU impact.**

Next steps:
1. Review application call patterns — is the query being called more often than necessary?
2. Consider result caching at the application layer
3. Optimize the query to reduce per-execution cost even slightly (high frequency amplifies savings)
4. Check if the same query runs from multiple application threads redundantly

### Plan instability detected (Step 3: plan_count > 1)

**Root cause: Query gets different execution plans, some much worse than others.**

Next steps:
1. Compare the plans: retrieve each with `sys.dm_exec_query_plan(plan_handle)` and look for differences (scan vs seek, hash vs nested loop)
2. Check if statistics are current: `DBCC SHOW_STATISTICS` on the tables involved
3. For stored procedures: test with `OPTION (RECOMPILE)` to confirm parameter sniffing
4. Consider `OPTIMIZE FOR UNKNOWN`, plan guides, or splitting the procedure by parameter patterns
5. Check for SET option differences across connections (`ANSI_NULLS`, `QUOTED_IDENTIFIER`)

### No active pressure but historical high CPU (Step 2a empty, Step 2b has results)

**Root cause: Periodic CPU-intensive workload — not currently active but recurring.**

Next steps:
1. Identify the schedule of the high-CPU queries (ETL, reporting, maintenance)
2. Move CPU-intensive jobs to off-peak hours
3. Optimize the top historical consumers to reduce per-execution CPU
4. Consider Read Scale-Out (Azure SQL) or readable secondary replicas for reporting
