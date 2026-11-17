---
name: plan-cache-analysis
description: "Use when the user asks about plan cache bloat, single-use or ad hoc plans, poor plan reuse, SET option pollution or parameter sniffing suspects. For one query's plans, use `plan-cache-qds-bridge`."
user-invocable: true
argument-hint: "[TopN] [DatabaseName] [MinExecutionCount]"
---

# Plan Cache Analysis

## Purpose

Use this skill when the user asks about plan cache bloat,
cached plan efficiency, parameter sniffing suspects,
or single-use ad hoc query patterns.

It provides a staged workflow for cache composition,
top offenders, parameterization health, SET option
pollution, and `optimize for ad hoc workloads` guidance.

## Prerequisites

- Must be connected to the target database.
- Confirm which server and database you are connected to
  (e.g. `SELECT @@SERVERNAME, DB_NAME(), SUSER_SNAME(), SERVERPROPERTY('EngineEdition')`).
- Run every diagnostic step in this skill with the
  SQL query tool.
- Plan cache data is cumulative since last server restart
  or manual cache clear.

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

With the SQL Tools MCP server, run these DMV queries through `mssql_execute_query`. To inspect a
cached plan, pass its `plan_handle` as `planHandle` to `SummarizePlan`, `GetPlanWarnings` or
`PlanBottleneckAnalysis` instead of selecting the plan XML. One plan-tool call per plan; do not
re-run the statement to compare variants.

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| TopN | 50 | Number of top plans to return in ranked results |
| DatabaseName | NULL | Optional database name filter. NULL = all databases (SQL Server/MI) or current database (Azure SQL DB). |
| MinExecutionCount | 10 | Minimum executions for a plan to appear in parameter sniffing analysis |

## Platform Support

| EngineEdition | Platform | Supported | Notes |
|---|---|---|---|
| 1 | Personal / Desktop Engine | Yes | Legacy; not available in SQL Server 2005+ |
| 2 | Standard | Yes | Standard, Developer, Web, BI editions |
| 3 | Enterprise | Yes | Enterprise, Developer, Evaluation editions |
| 4 | Express | Yes | Express editions |
| 5 | Azure SQL Database | Yes | Single-database scope, no cross-database queries |
| 6 | Azure Synapse Analytics (Dedicated SQL Pool) | **No** | Plan cache DMVs behave differently — stop here |
| 8 | Azure SQL Managed Instance | Yes | Instance-wide scope, most on-prem DMVs available |
| 9 | Azure SQL Edge | Yes | DMV behavior similar to SQL Server on-prem |
| 11 | Azure Synapse Serverless SQL Pool / Microsoft Fabric (non-SQL DB) | **No** | Plan cache DMVs not available — stop here |
| 12 | Fabric SQL Database | Yes | Behaves like Azure SQL Database (single-database scope) |
| other | SQL Server on-prem / IaaS | Yes | Full DMV access |

## Remediation Safety

- All diagnostic queries in this skill are read-only.
- State-changing commands in the references (`sp_configure` with `RECONFIGURE`, and
  `ALTER DATABASE SCOPED CONFIGURATION`) are **recommendations only**.
- Never run any of them without the user's explicit confirmation for that specific command. A
  request to investigate, diagnose, or "fix" the problem is not that confirmation.
- Before asking, explain the impact and rollback: `sp_configure` changes apply to the whole instance,
  and each change is reverted by setting the previous value.

## Investigation Workflow

Run the steps in order.
Load each query from `references/queries.md`, replace the
placeholders with the skill parameters, and execute it with
the SQL query tool.

### Step 0: Detect Platform and Capabilities
Load and execute the Step 0 query from `references/queries.md`.
This determines the SQL Server engine edition and routes the skill to the correct platform path.
If `is_unsupported_platform = 1` (editions 6, 11), stop — this skill does not support Azure Synapse Dedicated SQL Pool or Azure Synapse Serverless SQL Pool / Microsoft Fabric non-SQL DB endpoints.

| Finding | Recommendation |
|---------|----------------|
| `is_unsupported_platform = 1` (engine edition 6 or 11) | **Stop here** — this skill is not designed for Azure Synapse Dedicated SQL Pool (edition 6) or Azure Synapse Serverless SQL Pool / Microsoft Fabric Warehouse (edition 11). Plan cache DMVs behave differently in these environments. |
| `engine_edition = 12` (Fabric SQL Database) | Behaves like Azure SQL Database — proceed with all steps. |
| `engine_edition = 9` (Azure SQL Edge) | Proceed — DMV behavior is similar to SQL Server on-prem. |

### Step 1: Plan Cache Bloat Overview
Load and execute the Step 1 query from `references/queries.md`.
Key signals: `Plans Used Once` > 50% of total plans or
`MBs Used Once` > 25% of total MBs indicates plan cache bloat.
If ad hoc plans dominate by count or memory, use later steps
to isolate the worst offenders and the best remediation path.

### Step 2: Plan Cache Contents Detail
Load and execute the Step 2 query from `references/queries.md`.
Focus on large cached plans, single-use ad hoc plans,
low-reuse ad hoc plans, and single-use prepared plans.
The strongest signals are `objtype = 'Adhoc'` with
`usecounts = 1`, `usecounts <= 3`, or plans larger than 1 MB.

### Step 3: Platform-Aware Bloat Summary
Load and execute the Step 3 query from `references/queries.md`.
Key signals: Adhoc `single_use_pct >= 70`,
`single_use_mb >= 128`, or an overall verdict that calls out
classic plan cache bloat.
Use this step to decide whether the issue is instance-wide or
current-database scoped.

### Step 4: Top Single-Use Ad Hoc Plans
Load and execute the Step 4 query from `references/queries.md`.
Focus on top single-use Adhoc plans by memory, especially
string concatenation patterns, weak `sp_executesql` usage,
and very large plans.
These rows usually identify the highest-value queries to
parameterize or convert to stored procedures first.

### Step 5: Parameter Sniffing Detection
Load and execute the Step 5 query from `references/queries.md`.
Key signals are `HIGH suspicion`, very large
`max_to_min_ratio`, and supporting CPU or logical-read variance.
Treat this as a heuristic screen only; confirm true
parameter-sensitive behavior with Query Store or plan comparison.

### Step 6: SET Option Analysis
Load and execute the Step 6 query from `references/queries.md`.
Look for inconsistent `ARITHABORT`, `ANSI_NULLS`,
`QUOTED_IDENTIFIER`, or multiple `set_options` combinations.
These differences are strong indicators of plan cache pollution
caused by inconsistent connection settings.

### Step 7: Ad Hoc vs Prepared Summary
Load and execute the Step 7 query from `references/queries.md`.
Key signals: Adhoc `single_use_pct >= 50` suggests bloat,
while Prepared dominance usually indicates healthier reuse.
Use this step to summarize whether the workload is mostly
unparameterized or already trending toward reusable plans.

### Step 8: Optimize for Ad Hoc Workloads Check
Load and execute the Step 8 query from `references/queries.md`.
The key signal is whether `optimize for ad hoc workloads` is OFF
when earlier steps already show meaningful single-use bloat.
Report the platform-specific enable command, but do not execute
configuration changes unless the user explicitly asks.

## Gotchas

- Run only the diagnostic queries from `references/queries.md`
  in this skill flow.
- Do not modify the SQL in `references/queries.md`;
  only replace the documented placeholders.
- Engine edition 11 can be Azure Synapse Serverless SQL Pool
  or Microsoft Fabric (non-SQL DB endpoints). Both are unsupported
  because plan cache DMVs are not available. Only Fabric SQL
  Database (edition 12) is supported.
- `DatabaseName` is optional. On Azure SQL Database,
  the effective scope is the current database even if
  `DatabaseName` is supplied.
- Step 5 is heuristic only; blocking, spills, or memory pressure
  can mimic parameter sniffing.
- Step 6 inspects the top 200 compiled plans by size,
  so it is a targeted sample rather than a full-cache census.
- Step 8 returns recommended commands only;
  it does not change server or database settings.

## Report Reference

Format the final answer with the template in
`references/report-template.md`.
Cite the outputs from `references/queries.md` that justify
each recommendation in the final report.
