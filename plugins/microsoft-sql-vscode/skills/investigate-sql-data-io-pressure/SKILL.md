---
name: investigate-sql-data-io-pressure
description: "Use when data-file reads are slow or heavy: PAGEIOLATCH waits, high read latency, many physical reads, Azure SQL data IO throttling. For WRITELOG or log latency, use `investigate-sql-log-io-pressure`."
argument-hint: "[TopN] [DataIoThreshold] [ConfirmLookbackMinutes] [HistoryLookbackHours] [MinExecutionCount] [MinTotalPhysicalReads]"
---

# Data IO Pressure Investigation

> For **log IO pressure** (WRITELOG waits, log throughput), use the **`investigate-sql-log-io-pressure`** skill instead.

## Scope

- Confirms sustained data IO pressure, then identifies real-time and historical physical-read consumers and checks data file latency and buffer pool health.
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
- Steps 2 and 6 query live DMVs; run them while data IO pressure is active.

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| TopN | 10 | Number of top queries/sessions to return in each step |
| DataIoThreshold | 80 | Data IO percentage threshold for confirming pressure (Azure SQL) |
| ConfirmLookbackMinutes | 10 | Window (minutes) for the resource stats confirmation check |
| HistoryLookbackHours | 12 | Lookback window (hours) for the cached plan-history query |
| MinExecutionCount | 10 | Minimum execution count for a plan to appear in Step 3 |
| MinTotalPhysicalReads | 50000 | Minimum cumulative `total_physical_reads` for Step 3 |

## Investigation Workflow

Execute all steps in order. Steps 2 and 6 target live sessions — run them while data IO
pressure is active. Steps 3–5 cover historical or cumulative data and can be run at any time.

---

### Step 1: Detect Platform and Confirm Data IO Pressure

> Execute with the SQL query tool. Detects the SQL Server engine edition at runtime and routes to
the appropriate DMV to confirm sustained **data IO** pressure.

| EngineEdition | Platform | DMV | Notes |
|---|---|---|---|
| 5 | Azure SQL Database | `sys.dm_db_resource_stats` | `avg_data_io_percent` — ~15s intervals, ~1h history |
| 8 | Azure SQL Managed Instance | `sys.dm_db_resource_stats` | Same as Azure SQL DB |
| 12 | Fabric SQL Database | `sys.dm_db_resource_stats` | Behaves like Azure SQL Database |
| 6 | Azure Synapse Analytics (Dedicated SQL pool) | N/A | Not supported — IO metrics differ significantly in DW |
| 11 | Azure Synapse serverless SQL pool / Fabric Warehouse | N/A | Not supported — IO metrics differ significantly in DW/Warehouse environments |
| other | SQL Server on-prem / IaaS | `sys.dm_os_wait_stats` + `sys.dm_io_pending_io_requests` | Cumulative since restart |

> **Query:** See [references/queries.md#step-1-detect-platform-and-confirm-data-io-pressure](references/queries.md#step-1-detect-platform-and-confirm-data-io-pressure)

**Interpret:** Azure SQL: `avg_data_io_percent >= threshold` = confirmed. On-prem: wait stats are **cumulative since restart** — combine with Step 4 file latency. `pending_io_count > 50` = active IO queued now.

| Assessment | Action |
|------------|--------|
| Data IO pressure confirmed | Proceed to Step 2 — identify active offenders |
| Intermittent spikes | Steps 2–3 to catch offenders; Step 4 for persistent latency |
| No sustained pressure | Skip Steps 2/6. Step 3 for history, Step 4 for baseline |
| `is_unsupported_dw = 1` | **Stop** — this skill does not apply to Azure Synapse (edition 6) or Synapse serverless / Fabric Warehouse (edition 11). Fabric SQL Database (edition 12) is supported. |

---

### Step 2: Real-Time Data IO Consumers — Active Requests with SQL Text and Plans

> Execute with the SQL query tool. Shows active requests that are currently experiencing data IO waits
or generating high physical reads, along with their SQL text and execution plans.

> **Query:** See [references/queries.md#step-2-real-time-data-io-consumers--active-requests-with-sql-text-and-plans](references/queries.md#step-2-real-time-data-io-consumers--active-requests-with-sql-text-and-plans)

**Interpret:** `PAGEIOLATCH_SH/EX` = waiting for data pages from disk. `physical_reads_per_sec` = sustained storage pressure rate. `wait_resource` (e.g., `5:1:12345`) shows the specific page. No rows = no active pressure — proceed to Step 3.

| Finding | Recommendation |
|---------|----------------|
| `PAGEIOLATCH_SH` + high physical reads | Check plans for table/index scans |
| `PAGEIOLATCH_EX` | Concurrent access on same page — check for hot-page contention |
| High `physical_reads_per_sec` | Working set exceeds buffer pool — consider indexing or scaling memory |
| Same file in `wait_resource` repeatedly | Hot object/index — optimize query or redistribute filegroups |

---

### Step 3: Historical Data IO Consumers — Plan Cache (Cumulative)

> Execute with the SQL query tool. Identifies the most IO-intensive queries from the plan cache based
on cumulative physical reads. `total_physical_reads` measures actual disk reads; `total_logical_reads`
is included as context (buffer pool reads indicating workload size).

> **Query:** See [references/queries.md#step-3-historical-data-io-consumers--plan-cache-cumulative](references/queries.md#step-3-historical-data-io-consumers--plan-cache-cumulative)

> **Performance note:** This query does **not** retrieve execution plan XML to avoid high memory and CPU cost
on instances with large plan caches. After identifying the top offenders, use
`sys.dm_exec_query_plan(plan_handle)` on individual plans for detailed analysis.

**Interpret:** `physical_reads_per_exec > 1000` = working set misses buffer pool consistently. `max_physical_reads >> avg` = parameter sensitivity or cold cache. High `logical_reads` with low `physical_reads` = scan-heavy but fits in memory.

| Finding | Recommendation |
|---------|----------------|
| `physical_reads_per_exec` > 1000 | Add covering indexes, reduce scan width, or scale memory |
| `logical_reads_per_exec` > 100K | Scan-heavy — review for missing indexes or non-sargable predicates |
| `max_physical_reads` >> average | Parameter sensitivity — investigate plan regression |
| No rows returned | Lower `MinTotalPhysicalReads` or expand `HistoryLookbackHours` |

---

### Step 4: Data File Latency

> Execute with the SQL query tool. Measures data file IO latency from `sys.dm_io_virtual_file_stats`,
filtered to **ROWS** files only (data IO). This separates data file performance from log file performance.

> **Azure SQL context:** In Azure SQL Database, these metrics reflect how the workload behaves within
the service tier's IOPS and throughput limits — not raw storage performance. High latency values
typically indicate the database is approaching or hitting its data IO governance limits.

> **Query:** See [references/queries.md#step-4-data-file-latency](references/queries.md#step-4-data-file-latency)

**Interpret:** `avg_read_latency_ms > 20` = slow data reads (on-prem: disk bottleneck; Azure: approaching IOPS limit). Values are **cumulative since restart** — focus on ratios, not absolutes.

| Finding | Recommendation |
|---------|----------------|
| `avg_read_latency_ms > 20` (on-prem) | Check storage subsystem — SAN queue depth, RAID config |
| `avg_read_latency_ms > 20` (Azure SQL) | Hitting tier's data IO limit — scale up or optimize queries |
| `avg_write_latency_ms > 15` on ROWS | Heavy dirty-page writes — check checkpoint frequency |
| Uneven `total_mb_read` across files | Hot filegroup — redistribute data or add files |

---

### Step 5: Buffer Pool Health

> Execute with the SQL query tool. Assesses buffer pool pressure to determine whether data IO pressure
is caused by insufficient memory (pages being evicted and re-read from disk) or actual storage bottlenecks.

> **Platform note:** Page Life Expectancy and Buffer Cache Hit Ratio are most meaningful on **SQL Server**
and **Azure SQL Managed Instance** where the buffer pool is directly managed. On **Azure SQL Database**
and **Fabric**, these values are informational — the platform manages memory automatically and PLE/BCHR
may not reflect the same pressure patterns as on-premises.

#### Step 5a: Page Life Expectancy (NUMA-Aware)

> **Query:** See [references/queries.md#step-5a-page-life-expectancy-numa-aware](references/queries.md#step-5a-page-life-expectancy-numa-aware)

#### Step 5b: Buffer Cache Hit Ratio and Write Activity

> **Query:** See [references/queries.md#step-5b-buffer-cache-hit-ratio-and-write-activity](references/queries.md#step-5b-buffer-cache-hit-ratio-and-write-activity)

**Interpret:**

> `Buffer cache hit ratio` is a fraction counter (cntr_type 537003264) — the query divides by its base. The `/sec` counters are **cumulative** totals, not rates — sample twice for actual per-second rates.

- **PLE:** On-prem guideline ~1000s per NUMA node; < 300 = severe. Azure SQL DB: informational only.
- **BCHR < 99%** = more than 1% of page requests hit disk.
- **High lazy writes** = memory pressure evicting dirty pages.

| Finding | Recommendation |
|---------|----------------|
| PLE < 300 (on-prem) | Check `max server memory`, reduce memory-intensive queries, or add RAM |
| BCHR < 99% | Working set exceeds buffer pool — scale memory or optimize scans |
| High lazy writes | Same root cause as low PLE — buffer pool eviction |
| Azure SQL with low PLE | Consider scaling to a higher service tier |

---

### Step 6: Data IO Anti-Pattern Detection — Scan-Heavy Queries

> Execute with the SQL query tool. Inspects execution plan XML of the **top active data IO consumers**
for table scans and clustered index scans — the two patterns that most directly amplify data IO
by reading entire tables from disk.

> This step targets only the top offenders from Step 2 to minimize overhead.

> **Query:** See [references/queries.md#step-6-data-io-anti-pattern-detection--scan-heavy-queries](references/queries.md#step-6-data-io-anti-pattern-detection--scan-heavy-queries)

**Interpret:** `has_table_scan = 1` = full heap scan. `has_clustered_index_scan = 1` = full CI scan. Both with high physical reads = primary optimization targets.

| Pattern | Recommendation |
|---------|----------------|
| Table scan on large table | Create clustered index or nonclustered index on filter/join columns |
| Clustered index scan | Add covering nonclustered index with INCLUDE columns |
| Scan with low selectivity predicate | Functions on columns or implicit conversions prevent seeks |
| No anti-patterns detected | Data IO may be legitimate — focus on buffer pool and storage tier |

---

## Report Output

After completing all steps, read [references/report-template.md](references/report-template.md) and present the investigation results using that template.

## Root Cause Assessment

Use [references/root-cause-guide.md](references/root-cause-guide.md) to determine the root cause and recommended next steps based on findings from all steps.
