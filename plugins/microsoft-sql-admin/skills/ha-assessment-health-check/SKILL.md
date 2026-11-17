---
name: ha-assessment-health-check
description: "Use when the user wants a proactive Always On availability group health check before an audit, go-live or change: sync, listeners, failover readiness. For an active incident, use `investigate-ha-issues`."
argument-hint: "[AGName]"
---

# HA Environment Assessment & Health Check

> Proactive assessment only. Do not change configuration unless the user explicitly asks.
> For active issues, use **investigate-ha-issues** instead.

## Scope

- Validates SQL Server Always On AGs (cluster, AG configuration, failover readiness, listeners, endpoints, database settings, backups) and the HA posture of Azure SQL Database, Managed Instance, and Fabric SQL Database, with pass/fail/warning findings.
- For geo-replication, failover groups, geo-secondary planned-failover readiness, or geo-DR RPO/RTO, use the `geo-dr-assessment-health-check` skill.

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

- Confirm which instance you are connected to (e.g. `SELECT @@SERVERNAME, DB_NAME(), SUSER_SNAME(), SERVERPROPERTY('EngineEdition')`).
- Connect to the **primary replica** for full AG visibility.

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| AGName | *(all AGs)* | Filter to a specific AG. Omit to assess all. |

## Remediation Safety

- All assessment queries in this skill are read-only.
- State-changing commands in the references (`ALTER AVAILABILITY GROUP` including `FAILOVER` and
  `FORCE_FAILOVER_ALLOW_DATA_LOSS`, `ALTER DATABASE`, `sp_configure` with `RECONFIGURE`, and
  `CREATE LOGIN`) are **recommendations only**.
- Never run any of them without the user's explicit confirmation for that specific command. A
  request to investigate, diagnose, or "fix" the problem is not that confirmation.
- Before asking, explain the impact and rollback. A failover interrupts every connection to the
  availability group, and `FORCE_FAILOVER_ALLOW_DATA_LOSS` can lose committed transactions.

## Workflow

Execute steps in order. Step 1 determines which steps apply per platform.

> **Note on step numbering:** There is intentionally no Step 7 — the workflow runs 1–6 then 8–13. The numbers are stable identifiers referenced by the routing matrix, report template, and remediation guide, so the gap is preserved deliberately rather than renumbered.

---

### Step 1: Platform Detection and HA Capability

> Run with the SQL query tool.

> **Query:** See [references/queries.md#step-1-platform-detection-and-ha-capability](references/queries.md#step-1-platform-detection-and-ha-capability)

**Platform routing — use this matrix for all subsequent steps:**

| Engine Edition | Steps to Execute | Query Reference |
|----------------|------------------|-----------------|
| 3 (Enterprise) | Steps 1–6, 8, 9, 11, 12, 13 — requires `IsHadrEnabled = 1` for steps 2–6, 8, 9, 12–13 | Step 1: [queries.md](references/queries.md), Steps 2–6, 8, 9, 12–13: [queries-sqlserver.md](references/queries-sqlserver.md), Step 11: [queries-azure.md](references/queries-azure.md) |
| 2 (Standard) | 1, 2, 3, 4, 5, 6, 8, 9, 11, 12 — requires `IsHadrEnabled = 1` for AG steps | Step 1: [queries.md](references/queries.md), Steps 2–6, 8, 9, 12: [queries-sqlserver.md](references/queries-sqlserver.md), Step 11: [queries-azure.md](references/queries-azure.md) |
| 5 (Azure SQL DB) | 1, 10, 11 only | Step 1: [queries.md](references/queries.md), Steps 10–11: [queries-azure.md](references/queries-azure.md) |
| 8 (Azure SQL MI) | 1, 10, 11, 12 always. Run AG steps 3, 4, 5, 8 **only when an MI-link AG exists** (`ag_count > 0`) — a standalone MI's HA is platform-managed and is **not** exposed via the AG catalog views/DMVs, so empty AG/listener results are expected and must **not** be reported as FAIL; assess MI HA via Step 10 instead (no cluster/endpoint/backup — `msdb.dbo.backupset` does not record managed backups) | Step 1: [queries.md](references/queries.md), AG steps: [queries-sqlserver.md](references/queries-sqlserver.md), Steps 10–11: [queries-azure.md](references/queries-azure.md) |
| 12 (Fabric SQL DB) | 1, 10, 11 only | Step 1: [queries.md](references/queries.md), Steps 10–11: [queries-azure.md](references/queries-azure.md) |
| 9 (Azure SQL Edge) | 1, 11 only (no AG/cluster — Always On is not supported on SQL Edge) | Step 1: [queries.md](references/queries.md), Step 11: [queries-azure.md](references/queries-azure.md) |
| 6 (Synapse Dedicated), 11 (Synapse serverless / Fabric Warehouse) | Stop — HA assessment not applicable. Report N/A. | — |
| 1, 4 (Personal/Express) | Stop — HA not supported. Report FAIL. | — |

> AG steps (2–9, 12–13) require `IsHadrEnabled = 1`. If HADR is not enabled on Enterprise/Standard, skip AG steps and report as finding.

#### HA Posture Decision Tree (Engine Edition 2/3 — on-prem or Azure IaaS)

Run the **HA Posture Classification** query (second query in [references/queries.md#step-1-platform-detection-and-ha-capability](references/queries.md#step-1-platform-detection-and-ha-capability)) and branch on the `ha_posture` column. The classification uses DMVs only.

- **Branch A — No HA enabled** (`is_hadr_enabled = 0`, or HADR enabled with `ag_count = 0`): **Stop the AG steps (2–9, 12–13).** The instance is a single point of failure. Report this as the primary finding and deliver the enablement guidance in [references/remediation-guide.md#branch-a--no-ha-enabled](references/remediation-guide.md#branch-a--no-ha-enabled).
- **Branch B — Basic Availability Group** (`basic_ag_count > 0`, Standard Edition): Run the applicable AG steps, then evaluate the Basic AG limitations and best practices in [references/remediation-guide.md#branch-b--basic-availability-group](references/remediation-guide.md#branch-b--basic-availability-group).
- **Branch C — Advanced (full) Availability Group** (`advanced_ag_count > 0`): Run the full AG steps, then apply the best-practice review in [references/remediation-guide.md#branch-c--advanced-full-availability-group](references/remediation-guide.md#branch-c--advanced-full-availability-group).

> Azure platforms (Engine Edition 5, 8, 12) have platform-managed HA that cannot be disabled. Skip this decision tree and use Steps 10–11.

---

### Steps 2–6, 8, 9, 12–13: SQL Server AG Assessment

Load and execute queries from [references/queries-sqlserver.md](references/queries-sqlserver.md) for each applicable step per the routing matrix above. Execute the SQL exactly as written — do not invent replacement queries.

Each query includes guard conditions and inline PASS/FAIL/WARNING verdicts via SQL CASE columns.

**For each step with FAIL or WARNING verdicts:** read the corresponding section in [references/remediation-guide.md](references/remediation-guide.md) for remediation guidance:
- [Step 2 — Cluster Health](references/remediation-guide.md#step-2--windows-server-failover-cluster-health)
- [Step 3 — AG Configuration](references/remediation-guide.md#step-3--ag-configuration)
- [Step 4 — Failover Readiness](references/remediation-guide.md#step-4--failover-readiness)
- [Step 5 — Listener & Connectivity](references/remediation-guide.md#step-5--listener--connectivity)
- [Step 6 — Endpoint Security](references/remediation-guide.md#step-6--endpoint-security)
- [Step 8 — Database-Level Configuration](references/remediation-guide.md#step-8--database-level-configuration)
- [Step 9 — Backup Configuration](references/remediation-guide.md#step-9--backup-configuration)
- [Step 13 — Distributed & Contained AG](references/remediation-guide.md#step-13--distributed--contained-ag)

---

### Step 10: Azure Platform HA

Load and execute queries from [references/queries-azure.md](references/queries-azure.md#step-10-platform-ha-assessment).
Run the service tier query for all Azure platforms. Then run the geo-replication query (DB only) or failover group query (MI only) as applicable.

If FAIL/WARNING: read [references/remediation-guide.md](references/remediation-guide.md#step-10--azure-platform-ha).

---

### Step 11: Connection Resiliency

Load and execute the connection resiliency query from [references/queries-azure.md](references/queries-azure.md#step-11-connection-resiliency-all-platforms). Applies to all platforms.

If FAIL/WARNING: read [references/remediation-guide.md](references/remediation-guide.md#step-11--connection-resiliency).

---

### Step 12: Overall HA Health Scorecard

For SQL Server (and MI **only when an MI-link AG exists**): load and execute the scorecard query from [references/queries-sqlserver.md](references/queries-sqlserver.md#step-12-overall-ha-health-scorecard).
For Azure SQL DB, Fabric, and standalone MI (platform-managed HA): produce scorecard from Step 10 results only (no scorecard query).

---

### Step 13: Distributed & Contained AG Assessment

> Enterprise only (Engine Edition 3), SQL Server 2016+ (v13+). Requires `IsHadrEnabled = 1`.
> Skip if no distributed or contained AGs are detected.

Load and execute the distributed/contained AG query from [references/queries-sqlserver.md](references/queries-sqlserver.md#step-13-distributed--contained-ag-assessment).

This step detects:
- **Distributed AGs** — validates listener presence on both underlying AGs, checks forwarder sync lag (`last_hardened_lsn` vs `last_commit_lsn`), and flags availability mode mismatches between underlying AGs.
- **Contained AGs** (SQL 2022+) — validates system database synchronization within the contained AG.

If FAIL/WARNING: read [references/remediation-guide.md](references/remediation-guide.md#step-13--distributed--contained-ag).

---

## Report Output

Read [references/report-template.md](references/report-template.md) before presenting the final assessment report.

Apply final status:
- **Any FAIL:** Critical — immediate remediation required. Prioritize: data movement suspension > recovery model > endpoint state > cluster members.
- **Only WARNINGs:** Functional but has resilience gaps. Schedule remediation during next maintenance window.
- **All PASS:** Meets best-practice baseline. Document for audit trail; re-assess quarterly or after topology changes.

## Gotchas

- `sys.dm_hadr_*` and `sys.availability_*` DMVs do not exist on Azure SQL DB (5), Fabric SQL DW (11), or Fabric SQL DB (12). Never run AG queries on those platforms.
- On any SQL Server where HADR is not enabled (even Enterprise), AG DMVs return errors. Always check `IsHadrEnabled = 1` first.
- Azure SQL MI monitors auto-failover groups via `sys.dm_geo_replication_link_status` — NOT `sys.dm_hadr_fabric_replica_states`.
- Empty result from listener queries means no listener is configured — a FAIL for production **SQL Server AGs (Engine Edition 2/3)** only. On Azure SQL MI (8), empty AG/listener results are expected because HA is platform-managed (failover handled by the gateway) and not exposed via `sys.availability_group_listeners` — unless an MI link is configured. Never report empty listeners as FAIL on MI; assess MI HA via Step 10 (`sys.dm_geo_replication_link_status`).
- Connect to the **primary** replica. Secondaries have limited visibility into AG-wide configuration.
- `msdb.dbo.backupset` history may be truncated or empty on secondaries — backup assessment is most reliable on the primary.
- Backups may be routed to a secondary via `automated_backup_preference` (`SECONDARY`/`SECONDARY_ONLY`). In that case the primary's `msdb.dbo.backupset` will not contain those records — Step 9 downgrades a missing full backup to WARNING (not FAIL) when the preference targets a secondary. Verify backups on the preferred backup replica.
- **Distributed AGs** (`is_distributed = 1`) only support manual failover. Do not report missing automatic failover as an issue for distributed AGs.
- **Contained AGs** (`is_contained = 1`, SQL 2022+) replicate `master`/`msdb` within the AG. The `is_contained` column does not exist on SQL Server versions prior to 2022 — guard with version check.
- Distributed AGs require listeners on **both** underlying AGs. A distributed AG with no listener on the underlying AG will fail to synchronize.