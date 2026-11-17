---
name: partitioned-tables
description: "Use when the user asks about partitioned tables: skew or hot partitions, boundaries or missing future partitions, per-partition fragmentation, index alignment, or partition elimination."
user-invocable: true
argument-hint: "[SchemaName] [TableName] [FutureMonths] [ScanMode] [MinPageCount]"
---

# Partitioned Tables Analysis

## Purpose

Use this skill when the user asks about partitioned tables, partition health, partition skew,
partition elimination, or table partitioning diagnostics. It covers:
1. Platform detection and capabilities check
2. Partitioned table discovery in the current database
3. Single-table partition check
4. Partition metadata, distribution, and skew analysis
5. Index fragmentation per partition with maintenance recommendations
6. Partition boundary health diagnostic
7. Missing partition fix script generation
8. Partition skew and hot partition detection
9. Missing index diagnostic with partition alignment analysis
10. Live partition elimination verification
11. Storage details per partition
12. Hot partition/index identification

## Prerequisites

- Must be connected to the target database.
- Confirm which server and database you are connected to
  (e.g. `SELECT @@SERVERNAME, DB_NAME(), SUSER_SNAME(), SERVERPROPERTY('EngineEdition')`).
- Steps 2–3 discover partitioned tables; Steps 4+ require a specific table name.
- For fragmentation analysis (Step 5), `sys.dm_db_index_physical_stats` may take time on large tables.

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
| SchemaName | dbo | Schema of the target partitioned table |
| TableName | *(required)* | Name of the target partitioned table. Steps 2–3 help discover candidates. |
| FutureMonths | 6 | How many months ahead to check for missing partitions in boundary health analysis |
| ScanMode | LIMITED | Fragmentation scan mode: LIMITED (fastest), SAMPLED, or DETAILED (most accurate but slowest) |
| MinPageCount | 1000 | Minimum page count for a partition to receive fragmentation maintenance recommendations |

## Platform Support

| EngineEdition | Platform | Supported | Notes |
|---|---|---|---|
| 1 | Personal / Desktop Engine | Yes | Legacy; not available in SQL Server 2005+ |
| 2 | Standard | Yes | Standard, Developer, Web, BI editions |
| 3 | Enterprise | Yes | Enterprise, Developer, Evaluation editions |
| 4 | Express | Yes | Express editions |
| 5 | Azure SQL Database | Yes | Single-database scope, no cross-database queries |
| 6 | Azure Synapse Analytics (Dedicated SQL Pool) | **No** | Partitioning behavior differs significantly — stop here |
| 8 | Azure SQL Managed Instance | Yes | Instance-wide scope, most on-prem DMVs available |
| 9 | Azure SQL Edge | Yes | DMV behavior similar to SQL Server on-prem |
| 11 | Azure Synapse Serverless SQL Pool / Microsoft Fabric (non-SQL DB) | **No** | Partitioning DMVs not available — stop here |
| 12 | Fabric SQL Database | Yes | Behaves like Azure SQL Database (single-database scope) |
| other | SQL Server on-prem / IaaS | Yes | Full DMV access |

## Investigation Workflow

Execute Step 1 first, then Step 2. Once a target table is identified, run Steps 3+ with
`{{SchemaName}}` and `{{TableName}}` from the skill parameters.

### Step 1: Detect Platform and Capabilities
Load and execute the Step 1 query from `references/queries.md`. If `is_unsupported_platform = 1` (editions 6, 11), stop — this skill does not support Azure Synapse Dedicated SQL Pool (edition 6) or Azure Synapse Serverless SQL Pool / Microsoft Fabric non-SQL DB endpoints (edition 11).

| Finding | Recommendation |
|---------|----------------|
| `is_unsupported_platform = 1` (engine edition 6 or 11) | **Stop here** — this skill is not designed for Azure Synapse Dedicated SQL Pool (edition 6) or Azure Synapse Serverless SQL Pool / Microsoft Fabric Warehouse (edition 11). Partitioning behavior differs significantly in these environments. |
| `engine_edition = 12` (Fabric SQL Database) | Behaves like Azure SQL Database — proceed with all steps. |
| `engine_edition = 9` (Azure SQL Edge) | Proceed — DMV behavior is similar to SQL Server on-prem. |

### Step 2: Discover Partitioned Tables
Load and execute the Step 2 query from `references/queries.md`. Use it to identify candidate tables, shared partition functions, and very large tables with too few partitions.
If no rows return, stop — the current database has no partitioned tables for this skill to analyze.

### Step 3: Check If Table Is Partitioned
Load and execute the Step 3 query from `references/queries.md` for the chosen table. The key signal is `IsPartitioned`.
If the result is `NO`, stop the deeper workflow and report that the table is not partitioned.

### Step 4: Partition Metadata and Distribution Analysis
Load and execute the Step 4 query from `references/queries.md`. Focus on `PctOfTotal`, `SkewPct`, `SkewStatus`, and `EmptyFlag`.
High skew, a dominant partition, or empty partitions indicate boundary design or merge opportunities.

### Step 5: Index Fragmentation Per Partition
Load and execute the Step 5 query from `references/queries.md`. Review `avg_fragmentation_in_percent`, `page_count`, and `MaintenanceRecommendation` per partition.
Escalate partitions marked `REBUILD`, `REORGANIZE`, or `DISABLED INDEX`; ignore tiny partitions below `MinPageCount`.

### Step 6: Partition Boundary Health Diagnostic
Load and execute the Step 6 query from `references/queries.md`. Look for missing future boundaries, uneven intervals, duplicate/off-by-one patterns, and a last boundary already in the past.
These are the main signals that the sliding-window design is drifting or about to fail on incoming data.

### Step 7: Generate Missing Partition Fix Script
Load and execute the Step 7 query from `references/queries.md` only after confirming boundary gaps. The key outputs are `GeneratedScript`, `BoundariesGenerated`, and `NewTotalPartitions`.
If no script is returned, the table may already be covered or the partition function may not be date-based.

### Step 8: Partition Skew and Hot Partition Diagnostic
Load and execute the Step 8 query from `references/queries.md`. Focus on `HeatStatus`, `Action`, `SkewVerdict`, `CoefficientOfVariation`, and the top hot partitions.
`HOT`, `EXTREME HOT`, `CRITICAL SKEW`, and many empty partitions are strong signals to rebalance or merge.

### Step 9: Missing Index with Partition Alignment Analysis
Load and execute the Step 9 query from `references/queries.md`. Look for missing index recommendations, non-aligned indexes, and indexes that omit the partition column.
Misalignment or missing partition-column coverage can block partition switching and reduce partition elimination.

### Step 10: Live Partition Elimination Check
Load and execute the Step 10 query from `references/queries.md`. The key signals are `HasPartitionedOperator`, `HasPartitionIdSeek`, and `Recommendation`.
Flag active queries that scan partitioned objects without `PartitionID` seeks; that usually means partition elimination is not happening.

### Step 11: Storage Details Per Partition
Load and execute the Step 11 query from `references/queries.md`. Review `ReservedMB`, `UsedMB`, `CompressionType`, and `Recommendation` per partition.
Large uncompressed partitions, empty partitions, or uneven storage growth usually point to compression or merge work.

### Step 12: Hot Partitions and Indexes
Load and execute the Step 12 query from `references/queries.md`. Focus on `read_ops`, `write_ops`, and wait-driven recommendations for the hottest partition/index combinations.
Remember these DMV counters are cumulative since last restart, so use them as current pressure signals, not long-term history.

## Gotchas

- Run only the diagnostic queries from `references/queries.md` in this skill flow.
- Fabric SQL Database is engine edition 12; editions 6 (Synapse Dedicated SQL Pool) and 11 (Synapse Serverless SQL Pool / Microsoft Fabric non-SQL DB) remain unsupported.
- Engine edition 11 can be Azure Synapse Serverless SQL Pool or Microsoft Fabric (non-SQL DB endpoints). Both are unsupported because partitioning DMVs are not available. Only Fabric SQL Database (edition 12) is supported.
- Step 5 can be expensive on large tables because `sys.dm_db_index_physical_stats` must inspect each partition.
- Step 7 generates scripts only for date-like partition functions and does not execute them.
- Step 10 only inspects currently running requests and may return no useful plans without sufficient permissions.
- Step 12 reflects activity since the last SQL Server restart; correlate with monitoring if you need trends.
- Empty partitions are not always bad in sliding-window designs; confirm retention and load patterns before merging.

## Report Reference

Format the final answer with the template in `references/report-template.md`.
Load the supporting SQL from `references/queries.md` and cite the step outputs that justify each recommendation.
