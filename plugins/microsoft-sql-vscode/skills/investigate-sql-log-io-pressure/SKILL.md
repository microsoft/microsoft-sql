---
name: investigate-sql-log-io-pressure
description: "Use when commits are slow or log writes lag: WRITELOG waits, high log write percent, log throughput throttling, too many VLFs. For PAGEIOLATCH or data-file reads, use `investigate-sql-data-io-pressure`."
argument-hint: "[TopN] [LogIoThreshold] [ConfirmLookbackMinutes] [HistoryLookbackHours] [MinExecutionCount] [MinTotalLogicalWrites]"
---

# Log IO Pressure Investigation

> For **data IO pressure** (PAGEIOLATCH waits, physical reads, buffer pool issues),
> use the **`investigate-sql-data-io-pressure`** skill instead.

## Scope

- Confirms sustained log IO pressure, then identifies log-generating sessions and checks log file latency, VLF health, and transaction patterns.
- For a broad CPU, memory and IO resource usage report, use the `resource-usage-sqlserver` skill.

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
- Step 2 queries live DMVs; run while log IO pressure is active.

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| TopN | 10 | Number of top sessions/queries to return in each step |
| LogIoThreshold | 80 | Log write percentage threshold for confirming pressure (Azure SQL) |
| ConfirmLookbackMinutes | 10 | Window (minutes) for the resource stats confirmation check |
| HistoryLookbackHours | 12 | Lookback window (hours) for the plan-cache history query |
| MinExecutionCount | 10 | Minimum execution count for a plan to appear in Step 5 |
| MinTotalLogicalWrites | 50000 | Minimum cumulative `total_logical_writes` for Step 5 |

## Remediation Safety

- All diagnostic queries in this skill are read-only.
- State-changing commands in the references (`DBCC SHRINKFILE` and `ALTER DATABASE ... MODIFY FILE`)
  are **recommendations only**.
- Never run any of them without the user's explicit confirmation for that specific command. A
  request to investigate, diagnose, or "fix" the problem is not that confirmation.
- Before asking, explain the impact: shrinking a log file causes regrowth, and growth events stall
  writes. Recommend a maintenance window and a fixed target size rather than shrinking to a minimum.

## Investigation Workflow

Execute all steps in order. Step 2 targets live sessions — run while log IO pressure is active.
Steps 3–5 cover cumulative or historical data and can be run at any time.

---

### Step 1: Detect Platform and Confirm Log IO Pressure

> Execute with the SQL query tool. Detects the SQL Server engine edition at runtime and routes to
the appropriate DMV to confirm sustained **log IO** pressure.

| EngineEdition | Platform | DMV | Notes |
|---|---|---|---|
| 5 | Azure SQL Database | `sys.dm_db_resource_stats` | `avg_log_write_percent` — ~15s intervals, ~1h history |
| 8 | Azure SQL Managed Instance | `sys.dm_db_resource_stats` | Same as Azure SQL DB |
| 12 | Fabric SQL Database | `sys.dm_db_resource_stats` | Behaves like Azure SQL Database |
| 6 | Azure Synapse Analytics (Dedicated SQL pool) | N/A | Not supported — log IO metrics differ significantly in DW |
| 11 | Azure Synapse serverless SQL pool / Fabric Warehouse | N/A | Not supported — log IO metrics differ significantly in DW/Warehouse environments |
| other | SQL Server on-prem / IaaS | `sys.dm_os_wait_stats` | Cumulative WRITELOG waits since restart |

> **Query:** See [references/queries.md#step-1-detect-platform-and-confirm-log-io-pressure](references/queries.md#step-1-detect-platform-and-confirm-log-io-pressure)

**Interpret:** Azure SQL: `avg_log_write_percent >= threshold` = confirmed (near 100% = hitting log rate limit). On-prem: WRITELOG waits are **cumulative since restart**. High `writelog_wait_count` = frequent small commits.

| Assessment | Action |
|------------|--------|
| Log IO pressure confirmed | Proceed to Step 2 — identify active log generators |
| Intermittent spikes | Steps 2–3 to catch offenders; Step 4 for log space/VLF issues |
| No sustained pressure | Skip Step 2. Steps 3–5 for historical and structural analysis |
| `is_unsupported_dw = 1` | **Stop** — this skill does not apply to Azure Synapse (edition 6) or Synapse serverless / Fabric Warehouse (edition 11). Fabric SQL Database (edition 12) is supported. |

---

### Step 2: Real-Time Log IO Consumers — Sessions with WRITELOG Waits and Log Bytes

> Execute with the SQL query tool. Shows active sessions generating transaction log IO. Joins
`sys.dm_tran_session_transactions` and `sys.dm_tran_database_transactions` to show actual
**log bytes used** per session — a direct measure of log generation, not just write counts.

> **Query:** See [references/queries.md#step-2-real-time-log-io-consumers--sessions-with-writelog-waits-and-log-bytes](references/queries.md#step-2-real-time-log-io-consumers--sessions-with-writelog-waits-and-log-bytes)

**Interpret:** `log_bytes_used` = actual log generated by session's transaction. `log_mb_used > 10` = significant. `txn_duration_sec` = how long transaction has been open (holds log space). `log_bytes_reserved` = space reserved for rollback.

| Finding | Recommendation |
|---------|----------------|
| `WRITELOG` wait + high `log_bytes_used` | Active log generator hitting flush latency — check Step 3 |
| `log_mb_used` > 100 MB | Large transaction — batch into smaller transactions |
| Long `txn_duration_sec` (> 300s) | Long-running transaction preventing log truncation — review design |
| Many small `log_bytes_used` all on WRITELOG | Frequent small commits — batch them |

---

### Step 3: Log File Latency

> Execute with the SQL query tool. Measures log file IO latency from `sys.dm_io_virtual_file_stats`,
filtered to **LOG** files only. This isolates log write performance from data file performance.

> **Azure SQL context:** In Azure SQL Database, log write metrics reflect the workload behavior within
the service tier's **log rate governance** limits. High write latency typically indicates the database is
approaching or hitting its maximum log throughput — not that the underlying storage is slow.

> **Query:** See [references/queries.md#step-3-log-file-latency](references/queries.md#step-3-log-file-latency)

**Interpret:** `avg_log_write_latency_ms > 5` = slow log flushes (healthy OLTP < 2ms). `avg_bytes_per_write < 4KB` = many tiny commits. Values are **cumulative since restart**.

| Finding | Recommendation |
|---------|----------------|
| `avg_log_write_latency_ms > 5` (on-prem) | Dedicate a fast drive (SSD/NVMe) for transaction log |
| `avg_log_write_latency_ms > 5` (Azure SQL) | Hitting log throughput limit — scale up tier |
| Small `avg_bytes_per_write` (< 4KB) | Too many small commits — batch DML operations |
| High `log_reads` | Frequent rollbacks or replication reads — investigate aborted transactions |

---

### Step 4: Transaction Log Space, VLF Health, and Reuse Blockers

> Execute with the SQL query tool. Analyzes transaction log space usage, Virtual Log File (VLF) count,
and identifies what is preventing log truncation. Excessive VLFs cause log IO overhead; log reuse
blockers cause log growth.

#### Step 4a: Log Space Usage

> **Note:** `log_space_in_bytes_since_last_backup` requires SQL Server 2014+ or Azure SQL.
On older versions (SQL 2012), this column is omitted.

> **Query:** See [references/queries.md#step-4a-log-space-usage](references/queries.md#step-4a-log-space-usage)

#### Step 4b: VLF Count and Log Stats

> **Note:** `sys.dm_db_log_stats` requires SQL Server 2016 SP2+ or Azure SQL. On older versions,
this step returns a compatibility message.

> **Query:** See [references/queries.md#step-4b-vlf-count-and-log-stats](references/queries.md#step-4b-vlf-count-and-log-stats)

#### Step 4c: Active Transactions Holding Log Space

> **Query:** See [references/queries.md#step-4c-active-transactions-holding-log-space](references/queries.md#step-4c-active-transactions-holding-log-space)

**Interpret:**

- **4a:** `used_log_space_pct > 80%` = log mostly full. `log_since_last_backup_mb` high = infrequent log backups.
- **4b:** `total_vlf_count > 1000` = excessive VLFs causing IO overhead. `log_truncation_holdup_reason`: `LOG_BACKUP` = need log backup; `ACTIVE_TRANSACTION` = long-running txn; `REPLICATION`/`AVAILABILITY_REPLICA` = secondary lagging; `NOTHING` = healthy.
- **4c:** High `txn_duration_sec` + `log_mb_used` = holding log space, preventing truncation.

| Finding | Recommendation |
|---------|----------------|
| `used_log_space_pct > 80%` | **On-prem/MI:** Log backup or check truncation blockers. **Azure SQL DB/Fabric:** Check for long-running txns or replication lag |
| `total_vlf_count > 1000` | Shrink log, regrow with fixed increments (e.g., 1GB FILEGROWTH) |
| `LOG_BACKUP` holdup | **On-prem/MI:** Schedule more frequent log backups. **Azure SQL DB/Fabric:** Service-managed — contact support if persistent |
| `ACTIVE_TRANSACTION` holdup | Resolve the long-running transaction from Step 4c |
| Long-running transactions (> 5 min) | Review application code for missing COMMIT/ROLLBACK |

---

### Step 5: Log-Intensive Patterns — Historical Write-Heavy Queries

> Execute with the SQL query tool. Identifies queries from the plan cache with the highest cumulative
`total_logical_writes`, which generate the most transaction log. These are the primary candidates for
batching or rewriting to reduce log IO pressure.

> **Query:** See [references/queries.md#step-5-log-intensive-patterns--historical-write-heavy-queries](references/queries.md#step-5-log-intensive-patterns--historical-write-heavy-queries)

**Interpret:** `logical_writes_per_exec > 1000` = write-heavy query. High `execution_count` + moderate writes = massive aggregate log generation. `max_logical_writes >> avg` = variable, possibly parameter-sensitive.

| Finding | Recommendation |
|---------|----------------|
| `logical_writes_per_exec` > 10K | Batch into smaller chunks (5K–10K rows per batch with COMMIT between) |
| High execution count + moderate writes | Wrap related operations in explicit transactions to reduce flush frequency |
| INSERT-heavy workloads | Consider minimal logging (BULK INSERT with TABLOCK in SIMPLE/BULK_LOGGED) |

---

## Report Output

After completing all steps, read [references/report-template.md](references/report-template.md) and present the investigation results using that template.

## Root Cause Assessment

Use [references/root-cause-guide.md](references/root-cause-guide.md) to determine the root cause and recommended next steps based on findings from all steps.
