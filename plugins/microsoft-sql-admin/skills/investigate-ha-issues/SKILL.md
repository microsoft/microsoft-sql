---
name: investigate-ha-issues
description: "Use when an availability group has sync or failover problems: replica suspended, NOT SYNCHRONIZING or RESOLVING, growing redo queue, lease timeout, failed seeding. For a readiness check, use `ha-assessment-health-check`."
user-invocable: true
argument-hint: "[AGName] [LookbackMinutes] [RedoQueueThresholdKB] [LogSendQueueThresholdKB] [SnapshotDurationSeconds]"
---

# High Availability Investigation

## Purpose

Primary entry point for HA investigations across SQL Server, Azure SQL, and Fabric. Use when users report AG sync issues, unhealthy replicas, failovers, large redo/log send queues, seeding failures, lease timeout symptoms, or geo-replication lag.

This skill follows a 12-step workflow:
1. Detect platform, edition, and HA capability
2. Review AG configuration and replica settings
3. Check replica health, roles, and connectivity
4. Analyze per-database sync state, redo queue, and log send queue
5. Capture HADR wait statistics over a short snapshot
6. Review failover history and AG-related errors
7. Validate AG endpoint and transport configuration
8. Measure log send and transport performance
9. Inspect redo thread activity on the secondary
10. Check WSFC cluster health (on-premises/IaaS only)
11. Monitor automatic seeding progress (SQL 2016+/MI)
12. Review Azure SQL DB / Fabric geo-replication status

## Scope

- For Azure SQL geo-secondary lag, geo-replication link, or failover group incidents, use the `investigate-geo-dr-issues` skill.
- For a proactive HA posture assessment with no active incident, use the `ha-assessment-health-check` skill.

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

- Before running queries, confirm which server and database you are connected to (e.g. `SELECT @@SERVERNAME, DB_NAME(), SUSER_SNAME(), SERVERPROPERTY('EngineEdition')`).
- Run each step's query from `references/queries.md` with the SQL query tool.
- Run Steps 3–9 while the issue is active; connect directly to a secondary for Step 9.
- Run Step 10 only on on-premises or IaaS SQL Server with WSFC.

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| AGName | *(optional)* | Filter to a specific availability group name. If omitted, shows all AGs |
| LookbackMinutes | `60` | How far back to look for failover events and state changes |
| RedoQueueThresholdKB | `100000` | Redo queue size (KB) threshold for warnings (~100 MB) |
| LogSendQueueThresholdKB | `50000` | Log send queue size (KB) threshold for warnings (~50 MB) |
| SnapshotDurationSeconds | `30` | Duration for HADR wait statistics snapshot |

## Remediation Safety

- All diagnostic queries in this skill are read-only.
- State-changing commands in the references (`ALTER DATABASE ... SET HADR RESUME` and
  `ALTER EVENT SESSION ... STATE = START`) are **recommendations only**.
- Never run any of them without the user's explicit confirmation for that specific command. A
  request to investigate, diagnose, or "fix" the problem is not that confirmation.
- Before asking, explain the impact: resuming data movement on a replica restarts log send and
  redo, which adds load on both replicas.

## Investigation Workflow

### Step 1: Platform Detection and HA Capability
Load and execute the Step 1 query from `references/queries.md`. It determines edition, version, `EngineEdition`, and whether HADR is enabled.
**Routing:** editions 1/4/6/9/11 stop; edition 5 or 12 skips to Step 12; editions 2/3/8 with HADR enabled proceed to Steps 2–11.

### Step 2: AG Configuration Overview
Load and execute the Step 2 query from `references/queries.md` to review AG topology, sync mode, failover mode, session timeout, health timeout, seeding mode, and endpoint URL.
Key signals: aggressive `failure_condition_level`, invalid automatic failover + async combinations, risky timeouts, and automatic seeding choices.

### Step 3: AG and Replica Health Status
Load and execute the Step 3 query from `references/queries.md` to inspect replica role, operational state, connectivity, sync health, recovery health, and last connection errors.
Key signals: `RESOLVING`, `DISCONNECTED`, `NOT_HEALTHY`, `PENDING_FAILOVER`, or populated `last_error_number` / `last_error_description`.

### Step 4: Database Replica States — Sync, Redo Queue, Log Send Queue
Load and execute the Step 4 query from `references/queries.md`. This is the primary per-database view for `sync_state`, `sync_health`, redo queue, log send queue, redo/log send rates, and estimated RPO/RTO impact.
Key signals: queue sizes above thresholds, `NOT SYNCHRONIZING`, old `last_redone_time`, long estimated redo/log drain times, and non-null `suspend_reason`.

### Step 5: HADR Wait Statistics Analysis
Load and execute the Step 5 query from `references/queries.md` to capture a `SnapshotDurationSeconds` delta for HADR-related waits.
Key signals: dominant `HADR_SYNC_COMMIT`, `HADR_CLUSAPI_CALL`, `HADR_LOG_BLOCK_FLUSH`, `PARALLEL_REDO_*`, `DIRTY_PAGE_TABLE_LOCK`, or `REDO_THREAD_PENDING_WORK` waits.

### Step 6: Failover History from Ring Buffers
Load and execute the Step 6 query from `references/queries.md` to pull recent AlwaysOn_health ring buffer transitions and AG-related error-log entries.
Key signals: repeated state changes, `RESOLVING -> PRIMARY` transitions, lease timeout 19407, connection timeout 35206, join error 35201, or a missing AlwaysOn_health session.

### Step 7: AG Endpoint and Transport Health
Load and execute the Step 7 query from `references/queries.md` to validate the database mirroring endpoint used by AG transport.
Key signals: stopped or disabled endpoints, missing endpoints, auth mismatches, disabled encryption, and endpoint-port firewall issues.

### Step 8: Log Send and Transport Performance
Load and execute the Step 8 query from `references/queries.md` for an outbound transport view by database.
Key signals: growing `log_send_queue_size_kb`, `time_to_drain_sec` > 60, high send/receive latency, high receive/harden latency, or zero send rate with a non-zero queue.

### Step 9: Redo Thread Analysis on Secondary
Load and execute the Step 9 query from `references/queries.md` while connected to the secondary replica.
Key signals: redo blocked by `DIRTY_PAGE_TABLE_LOCK`, storage waits such as `PAGEIOLATCH_*` or `WRITELOG`, `PARALLEL_REDO_TRAN_TURN`, `REDO_THREAD_PENDING_WORK`, or a blocking session.

### Step 10: Cluster Health — On-Premises / IaaS Only
Load and execute the Step 10 query from `references/queries.md` only for box-product SQL Server on-premises or IaaS VMs.
Key signals: non-normal quorum, down members, missing witness, missing cluster metadata, single-node membership, or no public cluster network.

### Step 11: Seeding Progress Monitoring
Load and execute the Step 11 query from `references/queries.md` only on SQL Server 2016+ or Azure SQL Managed Instance.
Key signals: failed or stalled automatic seeding, low transfer rate, `pct_complete` not moving, or seeding completed without the database reaching `SYNCHRONIZED`.

### Step 12: Azure SQL DB and Fabric Geo-Replication Status
Load and execute the Step 12 query from `references/queries.md` only for Azure SQL Database (`EngineEdition` 5) and Fabric SQL Database (`EngineEdition` 12).
Key signals: `replication_lag_sec` > 30, prolonged `CATCH_UP`, `SEEDING`, `SUSPENDED`, missing geo-replication rows, or being connected to the secondary role.

## Report & Decision Tree

Use `references/report-template.md` to assemble findings into the final report. It contains the report template plus the root-cause decision tree for resolving RESOLVING replicas, large redo/log send queues, dominant HADR waits, seeding failures, geo-replication lag, and frequent failovers.
