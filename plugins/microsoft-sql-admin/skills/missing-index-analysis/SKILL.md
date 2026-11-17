---
name: missing-index-analysis
description: "Use when the user asks which indexes are missing, whether a table needs one, or whether index suggestions are worth creating. Has tested queries and rules common answers miss, e.g. rank suggestions by seeks x cost x impact. Not for Synapse dedicated pools."
user-invocable: true
argument-hint: "[IndexAdvantage] [UserSeekCount] [SchemaName] [TableName] [IsQueryRelatedTriage] [AggregatedQuery] [DetailedQuery] [QueryCountExecutions] [QueryAvgCpuTime] [StartTime] [QDSLookbackHours] [QDSMinExecutionCount] [QDSMinImpact]"
---

# Missing Index Analysis

Use this skill when the user asks about missing indexes, whether tables need indexes, or index recommendations.

## Parameters

Parameters are listed in the same order as the `argument-hint`. The `IndexAdvantage`, `UserSeekCount`, `IsQueryRelatedTriage`, `AggregatedQuery`, `DetailedQuery`, `QueryCountExecutions`, `QueryAvgCpuTime`, and `StartTime` parameters apply to the **Advanced Missing Index Analysis with Query Correlation** step (Modes 1–3).

| Parameter | Default | Description |
|-----------|---------|-------------|
| IndexAdvantage | `5000` | Minimum computed index advantage score — `(seeks + scans) × avg_cost × impact%`. Higher = more impactful index. Lower this for low-volume databases or shortly after a service restart. (Advanced modes) |
| UserSeekCount | `100` | Minimum user seek count for a missing index to be included. (Advanced modes) |
| SchemaName | `dbo` | Schema of the table to filter missing index recommendations. Used for single-table triage and query correlation modes. |
| TableName | *(optional)* | Table name to filter missing index recommendations. If omitted, returns recommendations for all tables in the current database. |
| IsQueryRelatedTriage | `0` | Set to `1` to also find queries in the plan cache / Query Store that reference the missing index (Advanced Mode 2/3). Requires `SchemaName` + `TableName`. |
| AggregatedQuery | `1` | When `IsQueryRelatedTriage=1`: return queries aggregated by `query_hash` (no SQL text). Mutually exclusive with `DetailedQuery`. (Advanced Mode 2) |
| DetailedQuery | `0` | When `IsQueryRelatedTriage=1`: return full SQL text per query. Mutually exclusive with `AggregatedQuery`. (Advanced Mode 3) |
| QueryCountExecutions | `500` | Minimum execution count for a query to appear in the query-triage results. (Advanced modes) |
| QueryAvgCpuTime | `1000` | Minimum average CPU time (µs) for a query to appear in the query-triage results. (Advanced modes) |
| StartTime | *(last 7 days)* | Lookback window for Query Store data in the Advanced modes. Defaults to 7 days back (`DATEADD(DAY, -7, GETUTCDATE())`) when not specified. |
| QDSLookbackHours | `3` | How many hours back to look in Query Store plans for the "Missing Indexes from Query Store Plans" query. Increase for broader analysis, decrease for faster execution. |
| QDSMinExecutionCount | `2` | Minimum number of executions a query must have to be included in Query Store missing index results. Filters out one-off queries. |
| QDSMinImpact | `50` | Minimum optimizer-estimated impact (0–100) for a missing index to be included from Query Store plans. Higher values focus on the most impactful recommendations. |

## Prerequisites

- Must be connected to the target database.
- Confirm which server and database you are connected to
  (e.g. `SELECT @@SERVERNAME, DB_NAME(), SUSER_SNAME(), SERVERPROPERTY('EngineEdition')`).

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

With the SQL Tools MCP server, run the DMV queries below through `mssql_execute_query`. For one
statement, `getEstimatedShowplanForQuery` plus `GetPlanWarnings` show its missing-index hints.
One plan-tool call per plan: do not loop re-running the statement through `mssql_execute_query`
to compare variants.

For separately authorized what-if tuning, `GetPlanUsingHypotheticalIndexes` estimates the
plan-cost change by creating and then dropping hypothetical indexes (statistics-only catalog
objects). It does not build a usable data index or execute the workload, but it does change
database metadata and requires `db_owner` plus explicit user consent. Do not call it during a
read-only investigation or elevate the diagnostic login to try it. Explain the candidate
indexes and target database before requesting authorization, and verify cleanup afterward.

## Platform Detection

**Run this check first** to identify the SQL platform and block unsupported environments.

Execute this query:

> **Query:** See [references/queries.md#platformdetection](references/queries.md#platformdetection)

> **If `is_unsupported_dw = 1`:** Stop and inform the user that this skill is not applicable to Azure Synapse Analytics (edition 6) or Azure Synapse serverless SQL pool / Fabric Warehouse (edition 11). The missing index DMVs (`sys.dm_db_missing_index_*`) behave differently on columnstore-oriented DW engines and may return misleading results.
>
> **Fabric SQL DB (edition 12):** Treat the same as Azure SQL Database — all DMVs and Query Store features used in this skill are fully supported.

## Remediation Safety

- All diagnostic queries in this skill are read-only.
- Generated `CREATE INDEX` scripts and the `ALTER INDEX ... DISABLE`, `DROP INDEX`, and
  `ALTER DATABASE ... SET QUERY_STORE` commands in the references are **recommendations only**.
  Present them as scripts to review.
- Never run any of them without the user's explicit confirmation for that specific command. A
  request to investigate, diagnose, or "fix" the problem is not that confirmation.
- Before asking, explain the impact: building an index reads the table, takes locks, and uses log and
  tempdb space; dropping or disabling an index can slow the queries that use it.

## Investigation Workflow

1. **Current database triage** — Use the broad DMV query to identify the highest-impact missing index recommendations for the current database.
   > See `references/queries.md` — `FindMissingIndexRecommendationsForCurrentDatabase`

2. **Single-table triage** — Use the table-scoped DMV query when the user asks whether a specific table needs an index.
   > See `references/queries.md` — `FindMissingIndexRecommendationsForASingleTableOnTheCurrentDatabase`

3. **Advanced Missing Index Analysis with Query Correlation** — Use this deeper analysis to connect missing index recommendations to the queries that need them.
   - **Mode 1**: missing index triage only
   - **Mode 2 by Query Hash**: aggregated query-pattern analysis
   - **Mode 2 by Query ID / Plan ID**: Query Store drill-down by specific query and plan
   - **Mode 3**: detailed query triage with SQL text
   > See `references/queries.md` — `Advanced Missing Index Analysis with Query Correlation`
   >
   > See `references/report-template.md` — `What to Do with Mode 1 Results`, `What to Do with Mode 2 Results`, `What to Do with Mode 3 Results`

4. **Missing Indexes from Query Store Plans** — Use plan-based analysis to extract missing index recommendations embedded in actual Query Store plans.
   > See `references/queries.md` — `Missing Indexes from Query Store Plans`
   >
   > See `references/report-template.md` — `What to Do with Query Store Plan Missing Index Results`

5. **Finding Unused Indexes** — Use this when the user asks about unused indexes or possible index removal candidates.
   > See `references/queries.md` — `Finding Unused Indexes`
   >
   > See `references/report-template.md` — `What to Do with Unused Index Results`

## Behavioral Guidance

- If the user asks about adding indexes or whether tables need indexes, focus on **missing index recommendations**.
- If there are recommendations:
  - State that the response is scoped to the current database
  - List the tables that would benefit and explain why
  - Offer to generate CREATE INDEX scripts based on the recommendations
- If there are no recommendations:
  - Report that no missing-index recommendations were found; this does not prove that no additional indexes would help. Consider restart/reset time and whether a representative workload has been observed.

For interpretation tables, cautions, tuning tips, and follow-up actions, use `references/report-template.md`.
