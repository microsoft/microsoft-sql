---
name: health-audit-sqlserver
user-invocable: true
description: "Use when the user asks for a health audit of a SQL Server or Managed Instance (not Azure SQL Database): what is failing or risky now: availability, integrity, resources, storage, backups, HA, jobs, security."
argument-hint: "[DatabaseName] [LookbackHours] [CriticalOnly]"
---

# SQL Server Health Audit

## Purpose

Use this skill to answer: **What is unhealthy, failing, anomalous, or operationally risky now
or within the requested lookback window?**

This skill is an orchestration layer. It collects bounded health evidence and routes confirmed
signals to specialist skills. It does not replace configuration governance, workload tuning, or
specialist incident investigations.

Supported targets:

- SQL Server 2012-2022, including virtualized and Azure VM deployments
- Azure SQL Managed Instance, with managed-service limitations called out explicitly

Not supported:

- Azure SQL Database: use a database-scoped Azure SQL health workflow
- EngineEdition 6 or 11: use Synapse/Fabric warehouse-specific tooling
- Fabric SQL Database and Azure SQL Edge: future capability-gated extensions

## Safety Contract

- Execute read-only SQL only.
- Never create, alter, drop, kill, fail over, shrink, rebuild, reconfigure, clear caches, reset
  waits, or change Query Store.
- Run Step 0 before any feature-specific query.
- Never execute a query unless its platform, version, object, column, permission, cost, and
  sensitivity gates are satisfied.
- Permission denial, inaccessible data, empty retained history, or missing visibility is
  `UNKNOWN`, never `PASS`.
- Redact SQL text, plans, paths, identities, addresses, job commands, and log text unless
  `IncludeSensitiveText = true`.
- Expensive checks require `IncludeExpensiveChecks = true`. Error-log, dump, registry, and other
  privileged checks require `IncludePrivilegedChecks = true`.
- On query failure, capture the error, mark that check `ERROR`, and continue only with independent
  checks. Do not retry with broader permissions or an unbounded alternative.

## Required tools

- A read-only SQL query tool connected to the intended SQL instance and database. Prefer, in order:
  the SQL Tools MCP server that ships with the `microsoft-sql-admin` plugin
  (`mssql_list_database_connections`, `mssql_connect_database`, then `mssql_execute_query`); any
  other SQL tool the agent host provides for running T-SQL and reading result sets;
  [`sqlcmd`](https://learn.microsoft.com/sql/tools/sqlcmd/sqlcmd-utility) from a terminal. If the
  SQL Tools MCP server is not connected or lists no connections, follow the `sql-tools-mcp-setup`
  skill, which asks before installing or configuring anything. If no SQL tool can be made available,
  provide the T-SQL for the user to run and ask for the results.
- Least privilege: connect that tool with a diagnostic login that cannot write, for example one that
  holds only `VIEW SERVER PERFORMANCE STATE` (`VIEW SERVER STATE` before SQL Server 2022) or, on Azure
  SQL Database, `VIEW DATABASE PERFORMANCE STATE` or `##MS_ServerStateReader##`, plus any other read
  permission these queries need. A tool is only as read-only as the login it connects with.

## Parameters

| Parameter | Default | Description |
|---|---:|---|
| LookbackHours | 24 | Recent evidence window |
| DatabaseName | null | Optional single-database scope |
| IncludeSystemDatabases | false | Include master, model, msdb, and tempdb where applicable |
| IncludeExpensiveChecks | false | Allow bounded medium/high-cost checks |
| IncludePrivilegedChecks | false | Allow error-log and dump evidence |
| IncludeSensitiveText | false | Allow sensitive values in evidence and output |
| SampleCount | 3 | Number of resource snapshots; minimum 2, maximum 10 |
| SampleIntervalSeconds | 5 | Delay between snapshots; minimum 2, maximum 60 |
| TopN | 20 | Maximum rows per ranked query; maximum 100 |
| TimeoutSeconds | 30 | Per-query timeout |
| CriticalOnly | false | Run only Step 0, baseline, and critical checks |
| DeploymentHint | auto | `auto`, `onprem`, or `azure-vm` |

Clamp out-of-range values to the documented limits and disclose that in the report.

## Loading References

When a step names a file, read it from `references/` relative to this `SKILL.md` before
executing the step.

## Finding Contract

Normalize each check to:

```text
check_id
status: PASS | FAIL | WARN | INFO | UNKNOWN | NOT_APPLICABLE | ERROR
severity: CRITICAL | HIGH | MEDIUM | LOW | INFORMATIONAL
scope_type
scope_name
observed_value
expected_condition
evidence
evidence_time_utc
data_window
permission_state
capability_state
confidence
recommendation
verification_action
```

## Workflow

Execute in order. Do not skip Step 0 and do not run extra queries.

### Step 0: Detect Platform and Capabilities

Load [references/step-0-platform-capabilities.md](references/step-0-platform-capabilities.md).
Build the complete `EnvironmentProfile` and eligibility plan before continuing.

- EngineEdition 2, 3, or 4: SQL Server path. Virtualization does not prove Azure hosting.
- EngineEdition 8: Azure SQL Managed Instance path.
- EngineEdition 5, 6, 11, 12, 9, or unknown: follow the stop/limited-routing rules in the
  reference.
- If platform identity cannot be established, stop.
- If a capability or permission cannot be established, block only its dependent checks.

### Step 1: Scope and Baseline

Load [references/step-1-scope-and-baseline.md](references/step-1-scope-and-baseline.md).
Establish UTC time, uptime, reset boundaries, database scope, and evidence windows. Missing
baseline evidence lowers confidence for cumulative DMV findings.

### Step 2: Critical Health

Load [references/step-2-critical-health.md](references/step-2-critical-health.md).
Run critical availability and integrity checks first. Promote active outage, recovery, suspect
page, severe HA, or dump/error evidence to the top of the report.

If `CriticalOnly = true`, skip Steps 3-6 after Step 2, evaluate eligible Step 7 routing, and
continue to synthesis.

### Step 3: Resource Health

Load [references/step-3-resource-health.md](references/step-3-resource-health.md).
Collect `SampleCount` bounded snapshots at `SampleIntervalSeconds`. Compare samples; do not infer
sustained pressure from one point. Return dominant signals and routing candidates, not speculative
root cause.

### Step 4: Storage and Tempdb Health

Load
[references/step-4-storage-and-tempdb-health.md](references/step-4-storage-and-tempdb-health.md).
Assess capacity, file state, log usage, VLF state, tempdb layout, and bounded IO evidence using
only eligible variants.

### Step 5: Backup, HA, and Jobs

Load [references/step-5-backup-ha-jobs.md](references/step-5-backup-ha-jobs.md).
Assess backup freshness, current HA/log-shipping state, recent Agent failures, and notification
coverage. Do not claim backup or HA compliance without workload RPO/RTO requirements. Treat
Managed Instance built-in HA and managed backups as platform-managed controls.

### Step 6: Security Exposure

Load [references/step-6-security-exposure.md](references/step-6-security-exposure.md).
Report immediate exposure with minimum disclosure. Redact principal names by default and separate
confirmed dangerous state from policy questions.

### Step 7: Targeted Drill-down

Load [references/step-7-targeted-drilldowns.md](references/step-7-targeted-drilldowns.md).
Invoke only specialists justified by captured evidence. Pass identifiers, database names, time
windows, and dominant signals. Do not repeat specialist query sets.

### Step 8: Synthesis

Load [references/decision-tree.md](references/decision-tree.md), classify each finding and the
overall health state, then load [references/report-template.md](references/report-template.md)
and produce the report.

## Completion Rules

- Cite a stable `HA-*` check ID for every finding.
- Distinguish active incidents from durable risk and optional follow-up.
- Show `UNKNOWN`, `ERROR`, `NOT_APPLICABLE`, and skipped coverage explicitly.
- Overall status cannot be `HEALTHY` if any mandatory check is `UNKNOWN` or `ERROR`.
- Report the installed SQL build, but do not claim it is current unless an authoritative,
  maintained servicing source was consulted.
