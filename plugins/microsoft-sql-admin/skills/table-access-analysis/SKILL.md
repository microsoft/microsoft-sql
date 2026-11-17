---
name: table-access-analysis
description: "Use when the user asks which tables are most read, written or scanned, which are unused, or whether anything still touches a table. Has tested queries and rules common answers miss, e.g. index rebuilds no longer reset usage counters. For table health, use `table-health-check`."
user-invocable: true
argument-hint: "[TopN]"
---

# Table Access Analysis

## Purpose

Use this skill when the user asks about the most active, most accessed, or most used tables in the database.
It ranks tables by read, write, or combined activity using DMV statistics, identifies unused tables,
detects hot-spot tables, and highlights scan-only access patterns that indicate missing indexes.

## Scope

- Counts are per table and index since the last restart; they do not attribute access to individual sessions, logins, or applications.
- For table structural health, use the `table-health-check` skill.

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

## Prerequisites

- Must be connected to the target database. Confirm which server and database you are connected to (e.g. with
  `SELECT @@SERVERNAME, DB_NAME(), SUSER_SNAME(), SERVERPROPERTY('EngineEdition')`); connect first if not already connected.
- Use the SQL query tool for every diagnostic step in this skill.
- Usage counters (`sys.dm_db_index_usage_stats`) are cleared when SQL Server restarts and when the database goes offline, is detached or auto-closes. Index rebuild and reorganize do not clear them (only a rebuild on unpatched SQL Server 2012 or 2014 did). Results reflect activity since the last reset only.

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| TopN | 20 | Number of top tables to return in ranked results |

## Investigation Workflow

Run the steps in order.
Load each query from `references/queries.md`, replace the
placeholders with the skill parameters, and execute it with
the SQL query tool.

### Step 1: Detect Platform and Capabilities
Load and execute the Step 1 query from `references/queries.md`.
This determines the SQL Server engine edition and routes the skill to the correct platform path.

| EngineEdition | Platform | Supported | Notes |
|---|---|---|---|
| 1 | Personal / Desktop Engine | Yes | Legacy; not available in SQL Server 2005+ |
| 2 | Standard | Yes | Standard, Developer, Web, BI editions |
| 3 | Enterprise | Yes | Enterprise, Developer, Evaluation editions |
| 4 | Express | Yes | Express editions |
| 5 | Azure SQL Database | Yes | Single-database scope, no cross-database queries |
| 6 | Azure Synapse Analytics (Dedicated SQL Pool) | **No** | Index usage DMVs behave differently — stop here |
| 8 | Azure SQL Managed Instance | Yes | Instance-wide scope, most on-prem DMVs available |
| 9 | Azure SQL Edge | Yes | DMV behavior similar to SQL Server on-prem |
| 11 | Azure Synapse Serverless SQL Pool / Microsoft Fabric (non-SQL DB) | **No** | Index usage DMVs not available — stop here |
| 12 | Fabric SQL Database | Yes | Behaves like Azure SQL Database (single-database scope) |
| other | SQL Server on-prem / IaaS | Yes | Full DMV access |

| Finding | Recommendation |
|---------|----------------|
| `is_unsupported_platform = 1` (engine edition 6 or 11) | **Stop here** — this skill is not designed for Azure Synapse Dedicated SQL Pool (edition 6) or Azure Synapse Serverless SQL Pool / Microsoft Fabric Warehouse (edition 11). Index usage DMVs and table access patterns differ significantly in these environments. |
| `engine_edition = 12` (Fabric SQL Database) | Behaves like Azure SQL Database — proceed with all steps. |
| `engine_edition = 9` (Azure SQL Edge) | Proceed — DMV behavior is similar to SQL Server on-prem. |

### Step 2: Most Active Tables — Consolidated Ranking
Load and execute the Step 2 query from `references/queries.md`.
Returns the top {{TopN}} most active tables ranked by combined read+write activity.
Focus on `Activity Class` = HOT (Read+Write) and tables with `Scan%` > 80.

### Step 3: Index Usage Per Table
Load and execute the Step 3 query from `references/queries.md`.
Focus on drop candidates (unused indexes with maintenance overhead),
scan-only indexes (no seeks), and high key lookups indicating
missing covering indexes.

### Step 4: Unaccessed Tables Since Last Restart
Load and execute the Step 4 query from `references/queries.md`.
Returns tables with zero access since the last SQL Server restart.
Large unused tables (> 10K rows) should be verified against
ETL/batch jobs that may not be captured by DMVs.

### Step 5: Hot-Spot Tables (High Reads and Writes)
Load and execute the Step 5 query from `references/queries.md`.
Focus on `ReadWriteRatio` to identify balanced, read-dominated,
or write-dominated workloads and recommend appropriate
isolation level and indexing strategies.

### Step 6: Scan-Only Tables (Zero Seeks)
Load and execute the Step 6 query from `references/queries.md`.
Heaps with heavy scans are the strongest signal for missing indexes.
Non-heap tables with only scans indicate query predicates may not
match index key columns.

### Step 7: Last Access Timestamps Per Table
Load and execute the Step 7 query from `references/queries.md`.
Indexes stale for > 90 days are strong drop candidates.
Indexes stale for > 30 days may be used by monthly/quarterly processes.

## Supplementary Queries

The following queries are available in `references/queries.md` for
on-demand deep-dive into specific tables when the user requests details:

- **Rowcount Details** — row count for a specific table
- **Table Definition** — column definitions for a specific table
- **Compression Details** — compression settings per partition
- **Partition Details** — partition layout with index type and row distribution

## Gotchas

- Use only the SQL query tool (read-only queries from
  `references/queries.md`) in this skill flow.
- Do not modify the SQL in `references/queries.md`;
  only replace the documented placeholders.
- Usage counters are cleared when SQL Server restarts and when
  the database goes offline, is detached or auto-closes. Index
  rebuild and reorganize do not clear them (only a rebuild on
  unpatched SQL Server 2012 or 2014 did). Results reflect
  activity since the last reset only.
- Engine edition 11 can be Azure Synapse Serverless SQL Pool
  or Microsoft Fabric (non-SQL DB endpoints). Both are unsupported
  because index usage DMVs are not available. Only Fabric SQL
  Database (edition 12) is supported.

## Report Template

Present results in this exact format:

```
## Table Access Analysis Report
Server: {{server name}}
Database: {{database name}}
Date: {{current date in YYYY-MM-DD format}}
Parameters: TopN={{TopN}}
DMV counters valid since: {{sqlserver_start_time}}

---

### Platform
{{engine_type}} (Edition: {{sql_edition}}, Version: {{sql_version}})

---

### Most Active Tables (Top {{TopN}})

| Rank | Schema | Table | Total Activity | Reads | Writes | Structure | Rows | Scan% | Activity Class | Recommendation |
|------|--------|-------|---------------|-------|--------|-----------|------|-------|----------------|----------------|
{{one row per table, sorted by TotalActivity descending}}

---

### Index Usage Summary

{{Summarize key findings: total indexes analyzed, drop candidates count, scan-only indexes count}}

---

### Unaccessed Tables

{{Count of unaccessed tables. List top 10 by row count with recommendations.}}

---

### Hot-Spot Tables

{{Tables with high reads AND writes. Include ReadWriteRatio and isolation level recommendation.}}

---

### Scan-Only Tables

{{Tables where all access is via scans (zero seeks). Prioritize heaps.}}

---

### Recommended Actions

{{Prioritized list of actions based on findings:}}
1. {{Highest priority finding and action}}
2. {{Next priority}}
...
```