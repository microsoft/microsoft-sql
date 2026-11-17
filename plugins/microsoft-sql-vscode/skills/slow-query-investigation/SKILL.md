---
name: slow-query-investigation
description: "Use when one specific query got slow, changed plans, or swings from seconds to minutes with the same parameters. Has tested queries and rules common answers miss, e.g. Query Store averages need execution weighting. For many slow queries, use `resource-usage-sqlserver`."
argument-hint: "[LookbackMinutes] [TopN]"
---

# Slow Query Investigation

## Scope

- Correlate Query Store, plan-cache DMVs, waits, time windows, and statistics before attributing the cause to parameter sniffing or a plan regression.
- For a broad Query Store inventory, use read-only Query Store inventory using the host SQL tools; to list cached top queries when Query Store is unavailable, use read-only top-query inspection from the plan-cache DMVs using the host SQL tools.

## Azure SQL Database specialization

For Azure SQL Database (EngineEdition 5), read [Azure-specific guidance](references/azure-sql/guidance.md) before choosing diagnostic queries. It preserves the service-specific permissions, capture limitations and error interpretation. Keep this skill's scope and authorization rules; the reference is not a second workflow to run unconditionally.

### Evidence limits and incident arithmetic

Check Query Store's actual state and capture mode. AUTO capture is not a complete execution log: an infrequent statement may be absent, and flushing cannot recover a statement never captured. A cached compiled plan with nonzero use count does not guarantee a matching execution-statistics row. Read the fallback's limitations before declaring the query absent.

Query Store duration and CPU averages are in microseconds. Aggregate execution groups with `SUM(count_executions * avg_value) / SUM(count_executions)`, not an unweighted average; compare each query with its own baseline and time window. Preserve query/plan/interval IDs and duration spread. Follow the measured wait category: blocking and resource pressure are not automatically plan regressions. Use [incident evidence rules](references/incident-evidence.md) when correlating captures. Supplied historical evidence describes that capture; current DMVs cannot replace it.


## Purpose

Primary entry point for slow, inconsistent, or intermittent query performance.
Use it to:
1. Identify volatile queries
2. Determine likely root cause via waits
3. Detect plan regressions
4. Identify parameter sniffing
5. Correlate slowness with time-of-day patterns
6. Check for stale statistics
7. Produce a unified report with next steps

## Prerequisites

- Must be connected to a database. Confirm which server and database you are connected to
  (e.g. `SELECT @@SERVERNAME, DB_NAME(), SUSER_SNAME(), SERVERPROPERTY('EngineEdition')`).
- Run every query in `references/queries.md` with the SQL query tool.
- **Step 0 is mandatory** before any other diagnostic step.

## Required tools

- A read-only SQL query tool connected to the target server and database. Prefer, in order: the SQL
  Tools MCP server that ships with the `microsoft-sql-admin` plugin (`mssql_list_database_connections`,
  `mssql_connect_database`, then `mssql_execute_query`); any other SQL tool the agent host provides for
  running T-SQL and reading result sets;
  [`sqlcmd`](https://learn.microsoft.com/sql/tools/sqlcmd/sqlcmd-utility) from a terminal. If the SQL
  Tools MCP server is not connected or lists no connections, follow the SQL tools of the Visual Studio Code MSSQL extension; this plugin does not ship the standalone SQL Tools MCP server,
  which asks before installing or configuring anything. If no SQL tool can be made available, give the
  user the T-SQL to run and ask for the results.
- Least privilege: connect that tool with a diagnostic login that cannot write, for example one that
  holds only `VIEW SERVER PERFORMANCE STATE` (`VIEW SERVER STATE` before SQL Server 2022) or, on Azure
  SQL Database, `VIEW DATABASE PERFORMANCE STATE` or `##MS_ServerStateReader##`, plus any other read
  permission these queries need. A tool is only as read-only as the login it connects with.

With the SQL Tools MCP server, run the Query Store and DMV queries below through
`mssql_execute_query`. To read a plan they return, pass its `plan_id` as `queryStorePlanId` (or a
plan-cache `plan_handle` as `planHandle`) to `SummarizePlan`, `GetPlanWarnings` or
`PlanBottleneckAnalysis` instead of fetching the plan XML; `getEstimatedShowplanForQuery` gives the
current estimated plan of the suspect statement. One plan-tool call per plan: do not loop re-running
the statement through `mssql_execute_query`.

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| LookbackMinutes | 60 | How far back to look in Query Store data (in minutes) |
| TopN | 20 | Number of top queries to return |
| RegressionFactor | 2.0 | Minimum ratio of recent-to-historical avg duration to flag a regression |

## Investigation Workflow

Run Step 0 first. It determines whether to use the Query Store path (Steps 1–6) or the DMV fallback path (Step 6 + Step 7). Load the full query text, interpretation tables, and remediation guidance from `references/queries.md`.

### Step 0: Environment Detection

Load and execute the Step 0 query from `references/queries.md`. This identifies SQL Server version, engine edition, Query Store state, and wait-stats availability. **Routing**: if Query Store is `READ_WRITE` or `READ_ONLY`, continue with Steps 1–6; if it is `OFF`, `ERROR`, or `NOT AVAILABLE`, skip to Step 6 (statistics staleness — valid without Query Store) then Step 7 (DMV fallback).

### Step 1: Find Volatile Queries

Run the Step 1 query from `references/queries.md` to rank queries by coefficient of variation, plan count, duration spread, reads, and CPU. High CV% plus multiple plans points toward plan instability or parameter sniffing; high CV% with a single plan points toward blocking or resource contention.

### Step 2: Analyze Wait Categories

If Step 0 reports `Wait Stats Available = Yes`, execute Step 2 from `references/queries.md`. Use dominant wait categories and wait percentages to separate blocking, CPU, IO, memory, network, and parallelism issues. If wait stats are unavailable, skip this step and rely on Steps 3–6.

### Step 3: Detect Plan Regressions

Run Step 3 from `references/queries.md` to compare recent performance against the historical baseline. Focus on regression factor, CPU/read deltas, and plan count. Large recent-vs-historical degradation with multiple plans is a strong regression signal and includes plan-forcing guidance (recommendation only — see Remediation Safety).

### Step 4: Identify Parameter Sniffing Candidates

Run Step 4 from `references/queries.md` to compare per-plan duration, CPU, reads, executions, and rowcount for multi-plan queries. Fast-vs-slow plan gaps, forced-plan state, and rowcount skew are the key signals. The reference includes remediation SQL for plan forcing, Query Store hints, unforcing bad plans, and recompile guidance — present it as recommendations only (see Remediation Safety).

### Step 5: Time-of-Day Performance Correlation

Run Step 5 from `references/queries.md` using its built-in 24-hour lookback. Use hourly duration, CPU, reads, and execution patterns to find contention windows, batch overlap, or throttling periods. If the pattern is flat, deprioritize scheduling as the primary cause.

### Step 6: Statistics Staleness Check

Run Step 6 from `references/queries.md` to find stale or weakly sampled statistics. Use modification percentage, age, and sample percentage to judge whether outdated cardinality estimates may be driving bad plans. Treat this as valid on both Query Store and DMV paths.

### Step 7: DMV Fallback

If Query Store is unavailable, use the Step 7 material in `references/queries.md`. It contains sub-steps **7a** (top CPU queries from plan cache), **7b** (multi-plan queries from plan cache), and **7c** (currently running long queries). Use these to approximate volatility, plan instability, and live blockers while still pairing with Step 6 for statistics health.

## Remediation Safety

- All diagnostic queries in Steps 0–7 are read-only.
- State-changing commands in the references — `KILL <session_id>`, `sp_query_store_force_plan`,
  `sp_query_store_unforce_plan`, `sp_query_store_set_hints`, `sp_create_plan_guide`,
  `UPDATE STATISTICS`, and `ALTER DATABASE ... SET ...` — are **recommendations only**.
- Never run any of them without the user's explicit confirmation for that specific command. A
  request to investigate, diagnose, or "fix" slowness is not that confirmation.
- Before asking, explain the impact and the rollback: `KILL` rolls back the session's open
  transaction and cannot be undone; a forced plan is reverted with `sp_query_store_unforce_plan`;
  Query Store hints are removed with `sp_query_store_clear_hints`; database option changes are
  reverted with the opposite `ALTER DATABASE` setting.
- Before recommending a forced plan, run the forcing check at the end of Step 4 in
  `references/queries.md`. A plan that uses an index which has since been dropped, renamed or
  disabled cannot be forced (`NO_INDEX`): the query keeps getting the optimizer's own plan, so
  forcing is not a fix until the index is back.

## Report & Decision Tree

Use `references/report-template.md` for the full report format, root-cause decision tree, and prescriptive next steps. Include environment details from Step 0, summarize only sections backed by evidence, and rank multiple root causes by impact.

## Related Skills

Use the related-skills table in `references/report-template.md` to choose the next drill-down skill after the root cause is identified.
