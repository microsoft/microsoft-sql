---
name: query-store-volatile-historical-slow-queries-comparison
description: "Use when queries have erratic durations in Query Store, the user wants one query_id's timeline, or suspects parameter sniffing or failing forced plans. For baseline regressions, use `query-store-investigation`."
argument-hint: "[QueryId] [LookbackMinutes] [TopN]"
---

# Volatile Query Investigation via Query Store

## Purpose

Use this skill to investigate intermittent or persistent slow queries with Query Store:
- **Step 0 — Query Store Health Check**: Verify Query Store is enabled, writable, and capturing data.
- **Step 1 — Identify Volatile Queries**: Find queries with the highest duration variability (CV%).
- **Step 2 — Interval Comparison**: Examine one `QueryId` across time intervals to see when regressions occurred.
- **Step 3 — Wait Category Breakdown**: Attribute slowness to CPU, locks, I/O, memory, network, or parallelism.
- **Step 4 — Aborted/Failed Executions**: Surface timeouts, cancellations, deadlocks, and runtime errors.
- **Step 5 — Forced Plan Failure Detection**: Detect forced plans that are failing and falling back.
- **Step 6 — Top Queries by Memory Grant**: Rank memory-heavy queries and `RESOURCE_SEMAPHORE` risk.
- **Step 7 — Parameter Sensitivity Detection**: Compare multiple plans for the same query to confirm parameter sniffing.

## Prerequisites

- Confirm which server and database you are connected to before running any step
  (e.g. `SELECT @@SERVERNAME, DB_NAME(), SUSER_SNAME(), SERVERPROPERTY('EngineEdition')`).
- Run every query in this skill with the SQL query tool.
- Requires Query Store on SQL Server 2016+ or Azure SQL; Fabric SQL Database is engine edition 12 and is supported.
- Not applicable to engine editions 6 and 11 (Azure Synapse dedicated/serverless).
- Step 2 needs a `QueryId` from Step 1 or the user.

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
| QueryId | *(optional)* | Query Store `query_id` to drill into. If omitted, Step 1 runs first to surface candidates. |
| LookbackMinutes | 120 | How far back to look in Query Store data (in minutes). Used for both steps. |
| TopN | 20 | Number of top volatile queries to return in Step 1. |

**LookbackMinutes guidance:**
- "last hour" / "this morning" → 60
- "today" → minutes since start of day
- "this week" → 10080 (7 days)
- No volatile queries found at default → suggest expanding to 1440 (24 hours)

## Platform Detection

Run the Platform Detection query from `references/queries.md` before Step 0.
Stop on engine editions 6 or 11; treat edition 12 as Fabric SQL Database and proceed normally.

## Remediation Safety

- All diagnostic queries in this skill are read-only.
- State-changing commands in the references (`ALTER DATABASE ... SET QUERY_STORE`, including
  `QUERY_STORE CLEAR`, plus `sp_query_store_force_plan` and `sp_query_store_unforce_plan`) are
  **recommendations only**.
- Never run any of them without the user's explicit confirmation for that specific command. A
  request to investigate, diagnose, or "fix" the problem is not that confirmation.
- Before asking, explain the impact and rollback: `QUERY_STORE CLEAR` permanently deletes the
  Query Store history, and a forced plan is reverted with `sp_query_store_unforce_plan`.

## Investigation Workflow

### Step 0: Query Store Health Check
Load and execute the Step 0 query from `references/queries.md`.
Key signals: `QDS State` should be `READ_WRITE`; if `OFF` or `READ_ONLY`, proceed cautiously and note capture limitations in the report.

### Step 1: Identify Volatile Queries
If no `QueryId` is provided, run Step 1 from `references/queries.md` to find candidates.
Key signals: high `Coefficient of Variation %` marks instability, and `Plan Count > 1` points to plan regression or parameter sensitivity.

### Step 2: Query Interval Comparison
Run the Step 2 query from `references/queries.md` for the selected `QueryId`.
Key signals: high duration with low CPU suggests blocking, high duration with high CPU suggests plan regression, and stable plan with rising reads suggests data growth.

### Step 3: Wait Category Breakdown per Query
Run the Step 3 query from `references/queries.md` when wait stats are available.
Key signals: dominant `Lock`, `IO`, `Memory`, `CPU`, or `Parallelism` waits explain why the query is slow; skip on SQL Server 2016 or when wait stats capture is off.

> **Step 3 vs. the standalone `wait-category-analysis` skill:** Use Step 3 for a lightweight, inline wait-category breakdown of the specific `QueryId` already in scope here — it keeps the investigation in one flow and is enough to point at the dominant wait type. Hand off to the dedicated `wait-category-analysis` skill when you need the deeper treatment it owns: the prescriptive root-cause decision tree, recommended next-step skills per wait category, and the standalone report. Do not duplicate or expand the wait analysis here; the `wait-category-analysis` skill remains the source of truth for that logic.

### Step 4: Aborted and Failed Executions
Run the Step 4 query from `references/queries.md` to catch failures Step 1 can miss.
Key signals: `Aborted` points to timeouts or cancellations, `Exception` points to runtime failures, and high failure count with high duration suggests blocking or starvation.

### Step 5: Forced Plan Failure Detection
Run the Step 5 query from `references/queries.md` if forced plans may be involved.
Key signals: `Force Failure Count > 0` means the forced plan is not sticking; use `Last Failure Reason` to decide whether schema change, compilation, or general failure is responsible.

### Step 6: Top Queries by Memory Grant
Run the Step 6 query from `references/queries.md` to rank high-memory queries.
Key signals: large average memory grants, volatile max-vs-avg memory, and overlap with Step 3 `Memory` waits indicate `RESOURCE_SEMAPHORE` pressure.

### Step 7: Parameter Sensitivity Detection
Run the Step 7 query from `references/queries.md` for multi-plan analysis.
Key signals: the same `Query ID` with multiple `Plan ID` values and large duration gaps is strong evidence of parameter sniffing; compare forced and non-forced plans.

## Gotchas

- Query Store `OFF` or `READ_ONLY` does not automatically mean no historical data; later steps may still return useful evidence.
- If Step 1 returns no rows, widen `LookbackMinutes` before concluding there is no volatility.
- If Step 2 returns no rows, verify `QueryId` and check whether the query executed inside the lookback window.
- Step 3 requires SQL Server 2017+ or Azure SQL with wait stats capture enabled.
- Step 4 execution type semantics differ on SQL Server 2016; use the guidance in `references/queries.md`.
- Cross-reference steps: volatile queries with multiple plans usually point to regression or parameter sniffing, and memory-heavy queries with `Memory` waits are high-priority tuning targets.

## Report Reference

Use the per-step report templates and interpretation guidance in `references/queries.md`.
See `references/report-template.md` for a minimal wrapper when you need a single combined report.
