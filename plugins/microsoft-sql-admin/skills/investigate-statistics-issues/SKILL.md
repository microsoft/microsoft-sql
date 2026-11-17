---
name: investigate-statistics-issues
description: "Use when row estimates are far from actual rows, statistics may be stale, or the user asks which to update or if auto-update keeps up. Has tested queries and rules common answers miss, e.g. the sqrt threshold needs compat level 130+. For missing indexes, use `missing-index-analysis`."
argument-hint: "[TopN] [ModificationThresholdPct] [StaleDaysThreshold] [MinRowsInTable] [MinExecutionCount] [IncludeViews] [DatabaseFilter]"
---

# Statistics Issues Investigation

> Investigates statistics health across 20 diagnostic steps: staleness, histogram quality,
> plan cache impact, index correlation, auto-update thresholds, duplicates, and more.

## Required tools

- A SQL query tool connected to the target server and database. Prefer, in order: the SQL Tools MCP
  server that ships with the `microsoft-sql-admin` plugin (`mssql_list_database_connections`,
  `mssql_connect_database`, then `mssql_execute_query`); any other SQL tool the agent host provides
  for running T-SQL and reading result sets;
  [`sqlcmd`](https://learn.microsoft.com/sql/tools/sqlcmd/sqlcmd-utility) from a terminal. The
  diagnostic queries are read-only; run `UPDATE STATISTICS`, `CREATE`/`DROP STATISTICS`, or `ALTER
  DATABASE` remediation only when the user asks for it. If the SQL Tools MCP server is not connected
  or lists no connections, follow the `sql-tools-mcp-setup` skill, which asks before installing or
  configuring anything. If no SQL tool can be made available, give the user the T-SQL to run and ask
  for the results.

## Prerequisites

- Must be connected to the target database.
- Confirm which server and database you are connected to (e.g. `SELECT @@SERVERNAME, DB_NAME(), SUSER_SNAME(), SERVERPROPERTY('EngineEdition')`).

## Clarification Required

Before starting, establish with the user:

1. **Trigger**: What prompted the investigation? Maps to starting step priority.
2. **Urgency**: Active production issue vs. proactive health check? Determines whether to run all 20 steps or focus on high-impact ones (Steps 2, 4, 6, 11).
3. **Scope**: Investigating a specific table, a set of tables, or the entire database? Maps to `MinRowsInTable` and `DatabaseFilter`.

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| TopN | 50 | Number of top results to return per step |
| ModificationThresholdPct | 10 | Percentage of rows modified to flag as stale |
| StaleDaysThreshold | 7 | Number of days since last update to flag as stale |
| MinRowsInTable | 1000 | Minimum rows in table to include in analysis |
| MinExecutionCount | 5 | Minimum plan execution count to flag plan cache issues |
| IncludeViews | 0 | Set to 1 to include indexed views in analysis |
| DatabaseFilter | NULL | Specific database name to analyze (NULL = current database). Note: This parameter is currently not implemented in the SQL queries. |

## Platform Compatibility

| EngineEdition | Platform | Key DMV Differences |
|---|---|---|
| 5 | Azure SQL Database | Single-database scope, no cross-database queries |
| 8 | Azure SQL Managed Instance | Instance-wide scope, most on-prem DMVs available |
| 12 | Fabric SQL Database | Behaves like Azure SQL Database (single-database scope) |
| 6, 11 | SQL Data Warehouse / Synapse | Not supported — statistics behavior differs significantly in DW |
| other | SQL Server on-prem / IaaS | Full DMV access including DBCC commands |

## Investigation Workflow

Execute all steps in order. Load and execute queries from [references/queries.md](references/queries.md) — run the SQL exactly as written.

The workflow covers:
1. Detecting platform and capabilities
2. Identifying stale statistics (high modification count)
3. Analyzing statistics sampling and histogram quality
4. Examining statistics usage in plan cache
5. Correlating index usage with statistics health, including identifying statistics on unused indexes
6. Detecting auto-update threshold issues
7. Analyzing statistics column details and multi-column analysis
8. Version-compatible statistics modification counter inventory
9. Incremental statistics detection
10. Statistics on computed columns
11. Correlation with missing index recommendations
12. Database-level statistics settings audit
13. Duplicate statistics detection
14. Empty histogram detection
15. Statistics bloat detection (more stats than columns)
16. Unused statistics that exceeded auto-update threshold
17. Orphaned advisor artifacts
18. Missing multi-column foreign key statistics
19. PERSIST_SAMPLE_PERCENT analysis (SQL 2016 SP1+)
20. Fullscan-to-sample regression detection

---

### Step 1: Detect Platform and Capabilities

Load [references/queries.md](references/queries.md#step-1-detect-platform-and-capabilities).
Detects engine edition, SQL version, and capability flags. Save results for routing.

- `is_unsupported_dw = 1`: **Stop** — skill does not apply to SQL DW / Synapse.
- `engine_edition = 12` (Fabric): Behaves like Azure SQL Database — proceed with all steps.

---

### Steps 2–8: Core Statistics Health Analysis

Load and execute queries from [references/queries.md](references/queries.md) for Steps 2–8.

| Step | Focus | Key Output |
|------|-------|------------|
| 2 | Stale statistics (high modification count) | `modification_percent > {{ModificationThresholdPct}}` |
| 3 | Sampling and histogram quality | Sample rate, steps used, density anomalies |
| 4 | Statistics usage in plan cache | Staleness since compile, execution count impact |
| 5 | Index usage correlation | High-use indexes with stale stats, unused indexes |
| 6 | Auto-update threshold issues | Tables near or exceeding threshold |
| 7 | Column details and multi-column analysis | Leading column type, ascending key detection |
| 8 | Modification counter inventory | Version-compatible modification tracking |

---

### Steps 9–12: Configuration and Environment Analysis

Load and execute queries from [references/queries.md](references/queries.md) for Steps 9–12.

| Step | Focus | Key Output |
|------|-------|------------|
| 9 | Incremental statistics detection | Partitioned tables without incremental stats |
| 10 | Statistics on computed columns | Computed column stats needing updates |
| 11 | Missing index correlation | Tables with stale stats AND missing indexes — high impact |
| 12 | Database-level settings audit | AUTO_CREATE/AUTO_UPDATE/ASYNC settings |

---

### Steps 13–20: Cleanup and Advanced Analysis

Load and execute queries from [references/queries.md](references/queries.md) for Steps 13–20.

| Step | Focus | Key Output |
|------|-------|------------|
| 13 | Duplicate statistics | Redundant stats sharing leading columns |
| 14 | Empty histograms | Stats with 0 rows sampled — cause 1-row estimates |
| 15 | Statistics bloat | Tables with more stats objects than columns |
| 16 | Unused stale statistics | Auto-created stats with no seeks/scans |
| 17 | Orphaned DTA artifacts | Hypothetical indexes/stats left by Database Tuning Advisor |
| 18 | Missing multi-column FK statistics | Multi-column FKs without matching statistics |
| 19 | PERSIST_SAMPLE_PERCENT (SQL 2016 SP1+) | Fullscan stats that revert to default sampling |
| 20 | Fullscan-to-sample regression | Stats that were fullscanned but reverted to sampling |

---

## Report Output

Read [references/report-template.md](references/report-template.md) before presenting the final report.

### Prioritization Guide

1. **Immediate:** Fix database settings flagged in Step 12 (auto_create/auto_update disabled)
2. **Immediate:** Update empty histograms from Step 14 — these cause 1-row estimates
3. **Critical:** Update statistics with `modification_percent > 20%`
4. **Critical:** Address tables flagged in Step 11 (stale stats + missing indexes)
5. **High:** Create missing multi-column FK statistics from Step 18
6. **High:** Enable PERSIST_SAMPLE_PERCENT for fullscan statistics (Step 19)
7. **Review:** Clean up hypothetical DTA objects from Step 17
8. **Review:** Drop duplicate statistics from Step 13

## Gotchas

- Steps 2–20 each gate on `EngineEdition NOT IN (6, 11)` — they will return an unsupported message on SQL DW / Synapse.
- `sys.dm_db_stats_properties` requires SQL 2008 R2 SP2+. On older versions, fall back to `STATS_DATE()`.
- `DBCC SHOW_STATISTICS` is not available on Azure SQL DB (5), MI (8), or Fabric (12).
- `STRING_AGG` requires SQL 2017+. All queries use the `STUFF/FOR XML PATH` pattern for compatibility.
- `sys.dm_exec_query_plan_stats` requires SQL 2019+ with lightweight query profiling enabled.
- Statistics auto-update uses the sqrt formula (dynamic threshold) only when `compatibility_level >= 130`.
- `PERSIST_SAMPLE_PERCENT` requires SQL 2016 SP1+ (major version 13).