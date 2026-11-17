---
name: investigate-geo-dr-issues
description: "Use when a geo-secondary lags behind the primary right now, a geo-replication link is suspended, or a failover group fails over unexpectedly. For a readiness check, use `geo-dr-assessment-health-check`."
user-invocable: true
argument-hint: "[DatabaseName]"
---
# Investigate Geo-DR Issues
Auto-detects platform via `SERVERPROPERTY('EngineEdition')`: SQL DB=5, MI=8, SQL Server=1-4, Fabric=12.

## Scope

- For a proactive geo-DR readiness or RPO/RTO assessment, use the `geo-dr-assessment-health-check` skill.
- For Always On AG replica or synchronization incidents, use the `investigate-ha-issues` skill.

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| DatabaseName | *(empty)* | Optional DB filter; empty = all databases |
| TopN | 10 | Max rows returned per query |
| LookbackHours | 24 | Recency window for restart/maintenance detection (`GetMaintenanceAndScalingEvents`) |

## Prerequisites

- Connected to the target database (or `master` for failover group queries on Azure SQL DB).
- Confirm which server and database you are connected to (e.g. `SELECT @@SERVERNAME, DB_NAME(), SUSER_SNAME(), SERVERPROPERTY('EngineEdition')`); if not connected, ask the user for the target.

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

## Remediation Safety

- All diagnostic queries in this skill are read-only.
- Ending a session (`KILL`), failing over, or changing replication settings are
  **recommendations only**.
- Never run any of them without the user's explicit confirmation for that specific command. A
  request to investigate, diagnose, or "fix" the problem is not that confirmation.
- Before asking, explain the impact: `KILL` rolls back the session's open transaction and cannot be
  undone, and a failover interrupts connections and can lose data that was not yet replicated.

## Investigation Workflow

Execute all steps in order. Load and execute queries from [references/queries.md](references/queries.md) — run the SQL exactly as written.

---

### Step 1: Split-Brain Detection

> **Query:** See [references/queries.md#getsplitbraindetection](references/queries.md#getsplitbraindetection)

Checks replica roles, sync health, suspended state, quorum, and forced failover history.

| Finding | Action |
|---------|--------|
| `Risk` = `HIGH_RISK` (primary NOT SYNCHRONIZING + NOT_HEALTHY) | Possible split-brain — escalate immediately |
| `Risk` = `WARNING` (suspended replication) | Data movement suspended — check `GetReplicationBottleneckAnalysis` |
| `QuorumState` = `FORCED_QUORUM` | Cluster running on forced quorum — risk of data loss on failover |
| DB state = `SUSPECT` or `EMERGENCY` | Database corruption — do not failover, engage recovery |
| `UNSUPPORTED` platform | Expected for Synapse/Fabric Warehouse — skip |

---

### Step 2: Replication Bottleneck Analysis

> **Query:** See [references/queries.md#getreplicationbottleneckanalysis](references/queries.md#getreplicationbottleneckanalysis)

Identifies geo-rep lag, send/redo queue bottlenecks, and synchronization issues.

| Finding | Action |
|---------|--------|
| `Bottleneck` = `LINK_DOWN` | Geo-rep link suspended — check network, partner server health |
| `Bottleneck` = `STALLED` (SecSinceRepl > 120) | No replication progress — investigate partner availability |
| `Bottleneck` = `SEND_BOTTLENECK` (SendQKB > 100MB) | Network/throughput issue — check bandwidth, log rate |
| `Bottleneck` = `REDO_BOTTLENECK` (RedoQKB > 100MB) | Secondary can't keep up — check IO/CPU on secondary |
| `Bottleneck` = `BOTH_BOTTLENECK` | Both send and redo backed up — systematic issue |
| `Bottleneck` = `HEALTHY` | Replication healthy — proceed to Step 3 |

---

### Step 3: Wait Stats Analysis

> **Query:** See [references/queries.md#getwaitstats](references/queries.md#getwaitstats)

Captures long-running transactions, log space/rate, and HADR/log waits gating failover.

| Finding | Action |
|---------|--------|
| `Readiness` = `NOT_READY` (long txns + active HADR waits) | Do not failover — resolve blocking transactions first |
| `Readiness` = `CAUTION` (log > 85% or txn log > 1GB) | High log usage — check `LogReuseWait` for holdup reason |
| `LogReuseWait` not `NOTHING`/`CHECKPOINT` | Log truncation blocked — investigate replication, active backup, etc. |
| `CRITICAL` severity on `LONG_TXN` | Kill or wait for long transaction before failover |
| High HADR wait types (avg > 5s) | Replication transport under pressure — check network |

---

### Step 4: Failover History

> **Query:** See [references/queries.md#getfailoverhistory](references/queries.md#getfailoverhistory)

Shows recent role changes, failover events, and forced failover entries.

| Finding | Action |
|---------|--------|
| `FORCED_FAILOVER` or `FORCE_FAILOVER_ALLOW_DATA_LOSS` in log | Data loss may have occurred — verify data integrity |
| `LOST_PRIMARY` event | Node lost primary role — correlate with `GetMaintenanceAndScalingEvents` |
| `REPL_SUSPENDED` event | Data movement was suspended — check if intentional |
| Frequent role transitions (> 2 in 24h) | Flapping — check resource pressure and maintenance events |
| `MinAgo` very large on geo-rep link | Link may be stale — verify with `GetReplicationBottleneckAnalysis` |

---

### Step 5: Maintenance and Scaling Events

> **Query:** See [references/queries.md#getmaintenanceandscalingevents](references/queries.md#getmaintenanceandscalingevents)

Detects recent restarts, scaling/SLO operations, and configuration changes. Tune `{{LookbackHours}}` to adjust the detection window.

| Finding | Action |
|---------|--------|
| `RestartedInWindow` = `YES` | Recent restart — correlate timing with failover/lag events |
| `SCALING_OP` state = `FAILED` or `CANCELLED` | Failed SLO change — retry or investigate error |
| `SCALING_OP` state = `IN_PROGRESS` or `PENDING` | Scaling in progress — wait for completion before failover |
| `CONFIG_CHANGE` event | Configuration changed — verify if intentional |
| No events in window | No maintenance activity — issue is likely workload-driven |

---

### Step 6: Resource Pressure

> **Query:** See [references/queries.md#getresourcepressure](references/queries.md#getresourcepressure)
> **Note:** This query contains two 1-second `WAITFOR DELAY` snapshots — inform the user before executing.

Measures CPU, IO, memory, scheduler, and signal-wait pressure.

| Finding | Action |
|---------|--------|
| `CPUPct` >= 90 or `SQLCPUPct` >= 90 | CPU saturation — check for runaway queries, missing indexes |
| `DataIOPct` >= 90 or `AvgReadMs` >= 50 | IO bottleneck — check for table scans, storage throttling |
| `LogWritePct` >= 90 | Log IO pressure — use the `investigate-sql-log-io-pressure` skill |
| `GrantsPending` > 0 | Memory grant waits — queries queuing for memory |
| `AvgRunnable` >= 5 | Scheduler pressure — CPU oversubscription |
| `MemState` contains `low` | System-wide memory pressure — check for memory-intensive queries |

---

### Step 7: Drill by Severity

Prioritize findings: **OK** < **WARNING** < **CRITICAL**. Address CRITICAL items first.

## Queries

All diagnostic T-SQL lives in [references/queries.md](references/queries.md). Each query is platform-aware (auto-detects `EngineEdition`) and is run with the SQL query tool.

## Gotchas

- Azure SQL DB geo-rep DMVs (`sys.dm_geo_replication_link_status`) are **not available in `master`** — connect to a user database.
- `gl.last_replication` is `datetimeoffset` (UTC) — queries use `SYSUTCDATETIME()` (not `SYSDATETIME()`) for DATEDIFF comparisons.
- `GetResourcePressure` contains two 1-second `WAITFOR DELAY` snapshots. Warn the user before executing.
- `sys.dm_db_resource_stats` is not supported on MI (`@E=8`) — MI uses `sys.server_resource_stats` instead.
- `secondary_lag_seconds` column requires SQL 2016 SP2 / 2017+; the query gracefully emits NULL on older builds.

## Guidance
- SQL DB: db-level geo-rep vs FG; MI: instance-level (all DBs); SQL Server: check quorum before AG failover
- Related: the `health-audit-sqlserver`, `check-live-blocking`, and `wait-category-analysis` skills
