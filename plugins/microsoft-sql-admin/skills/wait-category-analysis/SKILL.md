---
name: wait-category-analysis
description: "Use when the user asks why queries are slow in terms of waits: which wait categories (lock, CPU, IO, memory, network) dominate now or recently. Requires Query Store with wait stats capture."
argument-hint: "[LookbackMinutes] [TopN] [SnapshotDurationSeconds]"
---

# Wait Category Analysis

> Determines **why** queries are slow by categorizing waits into Lock, CPU, IO, Memory, or Network.
> Use after running `query-store-volatile-historical-slow-queries-comparison` (Step 1) to diagnose root cause.

## Required tools

- A SQL query tool connected to the target server and database. Prefer, in order: the SQL Tools MCP
  server that ships with the `microsoft-sql-admin` plugin (`mssql_list_database_connections`,
  `mssql_connect_database`, then `mssql_execute_query`); any other SQL tool the agent host provides
  for running T-SQL and reading result sets;
  [`sqlcmd`](https://learn.microsoft.com/sql/tools/sqlcmd/sqlcmd-utility) from a terminal. The
  queries only read diagnostics (the snapshot steps use session temp tables and `WAITFOR DELAY`, so
  the tool must allow a multi-statement batch that runs for `{{SnapshotDurationSeconds}}` seconds).
  If the SQL Tools MCP server is not connected or lists no connections, follow the
  `sql-tools-mcp-setup` skill, which asks before installing or configuring anything. If no SQL tool
  can be made available, give the user the T-SQL to run and ask for the results.

## Prerequisites

- Connected to a database with Query Store enabled and wait stats capture ON.

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| LookbackMinutes | 60 | How far back to look in Query Store wait stats (minutes) |
| TopN | 20 | Number of top queries to return, ranked by total wait time |
| SnapshotDurationSeconds | 30 | Duration in seconds for the wait stats snapshot window (10–300). The SQL uses a T-SQL `CONVERT` expression to format as HH:MM:SS — substitute the integer directly. |

## Remediation Safety

- All diagnostic queries in this skill are read-only.
- State-changing commands in the references (`ALTER DATABASE ... SET QUERY_STORE`,
  `sp_query_store_force_plan`, and `UPDATE STATISTICS`) are **recommendations only**.
- Never run any of them without the user's explicit confirmation for that specific command. A
  request to investigate, diagnose, or "fix" the problem is not that confirmation.
- Before asking, explain the impact and rollback. A forced plan is reverted with
  `sp_query_store_unforce_plan`, and Query Store option changes with the opposite setting.

## Workflow

Execute all steps in order. Load and execute queries from [references/queries.md](references/queries.md) — run the SQL exactly as written.

---

### Step 1: Platform Detection and Query Store Validation

Load [references/queries.md](references/queries.md#step-1-platform-detection-and-query-store-validation).
Detects engine edition and validates Query Store is enabled with wait stats capture.

| Assessment | Action |
|------------|--------|
| `is_unsupported_dw = 1` | **Stop** — skill does not apply to SQL DW, Synapse serverless, or Fabric Warehouse/Lakehouse endpoints |
| `has_instance_wait_stats = 0` (Azure SQL DB / Fabric SQL DB) | Skip Step 2 — use Step 3 instead |
| Query Store not `READ_WRITE` | Enable: `ALTER DATABASE CURRENT SET QUERY_STORE = ON` |
| `wait_stats_capture_mode = OFF` | Enable: `ALTER DATABASE CURRENT SET QUERY_STORE (WAIT_STATS_CAPTURE_MODE = ON)` |

Save `engine_edition` and `has_instance_wait_stats` for routing.

---

### Step 2: Instance Level Wait Snapshot

> SQL Server / MI only. Skip for Azure SQL DB and Fabric — use Step 3.
> **This query takes `{{SnapshotDurationSeconds}}` seconds** — inform the user before executing.

Load and execute from [references/queries.md](references/queries.md#step-2-instance-level-wait-snapshot).
Takes two snapshots of `sys.dm_os_wait_stats` separated by `{{SnapshotDurationSeconds}}` seconds and diffs them for accurate current-window waits.

---

### Step 3: Database Level Wait Snapshot

> Azure SQL DB and Fabric only. Skip for SQL Server / MI — use Step 2.
> **This query takes `{{SnapshotDurationSeconds}}` seconds** — inform the user before executing.

Load and execute from [references/queries.md](references/queries.md#step-3-database-level-wait-snapshot).
Same snapshot approach as Step 2 but uses `sys.dm_db_wait_stats` (database-scoped).

---

### Step 4: Query Level Wait Analysis

> All platforms with Query Store. Two query versions available — by Query Hash (default) or by Query ID/Plan ID.

Load and execute from [references/queries.md](references/queries.md#step-4-query-level-wait-analysis).

| Finding | Recommendation |
|---------|----------------|
| High wait with Lock category | Run `check-live-blocking` to find head blocker |
| High wait with CPU category | Check plan for missing indexes, outdated stats, or plan regression |
| `Plan Count` > 1 | Possible plan regression or parameter sniffing — run `query-store-volatile-historical-slow-queries-comparison` (Step 1) |
| High wait with IO category | Check for table scans or missing covering indexes |

---

### Step 5: PAGELATCH Contention Diagnostic

> SQL Server / MI only. Run only when PAGELATCH_XX waits detected in Steps 2–4.

Load and execute from [references/queries.md](references/queries.md#step-5-pagelatch-contention-diagnostic).
Identifies whether contention is on tempdb PFS/GAM/SGAM pages.

---

## Report Output

Read [references/report-template.md](references/report-template.md) before presenting results.

## Root Cause Assessment

Read [references/root-cause-guide.md](references/root-cause-guide.md) to determine the primary root cause based on the dominant wait category and identify recommended next steps.

The [Wait Stats Auxiliary Mapping Table](references/root-cause-guide.md#wait-stats-auxiliary-mapping-table) maps individual wait types to categories with explanations — use it when interpreting results in the report.

## Gotchas

- `sys.dm_os_wait_stats` is not available on Azure SQL DB (edition 5) or Fabric (edition 12). Use `sys.dm_db_wait_stats` instead.
- `sys.dm_db_wait_stats` is only available on Azure SQL DB and Fabric — not on SQL Server or MI.
- Query Store wait stats require `WAIT_STATS_CAPTURE_MODE = ON` — disabled by default on older versions.
- The snapshot queries use `WAITFOR DELAY` and will take `{{SnapshotDurationSeconds}}` seconds. Always warn the user.
- Wait exclusion lists filter benign system waits. Do not remove entries without understanding their purpose.