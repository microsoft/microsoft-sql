---
name: sql-agent-job-failure-investigator
description: "Use when a SQL Server Agent job failed, was canceled, keeps retrying, is stuck running or missed its schedule, and the user wants the failing step and error. SQL Server and Managed Instance only."
argument-hint: "[JobName] [LookbackHours] [TopN]"
---

# SQL Server Agent Job Failure Investigator

## Purpose

Use this skill to identify why a SQL Server Agent job failed and produce an evidence-based
investigation report. The workflow answers:

1. Is SQL Server Agent available and running on this platform?
2. Which jobs recently failed, were canceled, or exhausted retries?
3. Which step first failed, and what error did it report?
4. Is the job still running or blocked by overlapping execution?
5. Do job ownership, step execution context, database, schedule, retry, or notification settings
   contribute to the failure or delayed detection?
6. Did database availability, replica role, resource pressure, or an external dependency contribute?

This is a diagnostic skill. Do not start, stop, alter, enable, disable, or rerun a job unless the
user explicitly requests that action after reviewing the findings.

## Required tools

- A read-only SQL query tool connected to the target server. Prefer, in order: the SQL Tools MCP
  server that ships with the `microsoft-sql-admin` plugin (`mssql_list_database_connections`,
  `mssql_connect_database`, then `mssql_execute_query`); any other SQL tool the agent host provides
  for running T-SQL and reading result sets;
  [`sqlcmd`](https://learn.microsoft.com/sql/tools/sqlcmd/sqlcmd-utility) from a terminal. If the
  SQL Tools MCP server is not connected or lists no connections, follow the `sql-tools-mcp-setup`
  skill, which asks before installing or configuring anything. If no SQL tool can be made available,
  give the user the T-SQL to run and ask for the results.
- Least privilege: connect that tool with a diagnostic login that cannot write, for example one that
  holds only `VIEW SERVER PERFORMANCE STATE` (`VIEW SERVER STATE` before SQL Server 2022) or, on Azure
  SQL Database, `VIEW DATABASE PERFORMANCE STATE` or `##MS_ServerStateReader##`, plus any other read
  permission these queries need. A tool is only as read-only as the login it connects with.

## Prerequisites

- Must be connected to the target SQL Server instance or Azure SQL Managed Instance. Confirm which
  server and database you are connected to (e.g. `SELECT @@SERVERNAME, DB_NAME(), SUSER_SNAME(),
  SERVERPROPERTY('EngineEdition')`); if not connected, ask the user for the target.
- Prefer a connection to `master` or the affected job-step database; all SQL Server Agent metadata
  is queried with fully qualified `msdb` object names.
- SQL Server Agent fixed database roles may limit history visibility. `sysadmin` can inspect all
  jobs; members of `SQLAgentReaderRole` can inspect all jobs but may not have access to every
  target database or subsystem.
- `VIEW SERVER STATE` is required to inspect SQL Server Agent service state on SQL Server. Managed
  Instance does not expose service state.

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| JobName | empty | Exact job name for drill-down. Leave empty to inventory recent failures first. |
| LookbackHours | 24 | Number of hours of job outcome and step history to inspect. |
| TopN | 20 | Maximum number of jobs or history rows returned per query. |

## Platform Support

| EngineEdition | Platform | Support |
|---:|---|---|
| 2, 3 | SQL Server Standard or Enterprise on-premises / Azure VM | Supported |
| 4 | SQL Server Express on-premises / Azure VM | Not supported; Express does not include SQL Server Agent |
| 8 | Azure SQL Managed Instance | Supported |
| 5 | Azure SQL Database | SQL Server Agent is not supported; if the workload uses Azure SQL Elastic Jobs, investigate the Elastic Job agent and job execution history instead |
| 9 | Azure SQL Edge | Not supported |
| 11, 12 | Fabric Warehouse / Fabric SQL Database | SQL Server Agent and Elastic Jobs are not supported; use the configured scheduler, such as Data Factory or Airflow, for diagnostics |
| 6 | Azure Synapse dedicated SQL pool | Not supported |
| any other value | Unknown engine edition | Stop and report the platform as unverified; do not query `msdb` |

Do not run the `msdb` queries against unsupported platforms. The Azure SQL Elastic Jobs alternative
is a separate diagnostic path and must not be represented as SQL Server Agent history.

For the full platform, edition, and version matrix — including `EngineEdition` values, Express and
Managed Instance feature limitations, `msdb` metadata tables, and status/schedule code tables — read
[references/platform-and-edition-reference.md](references/platform-and-edition-reference.md).

## Investigation Workflow

Read [references/queries.md](references/queries.md) and execute each applicable step with
the SQL query tool. Escape job names and validate numeric bounds exactly as required at the top
of the query reference. Never substitute unvalidated user text into a SQL batch.

### Step 1: Validate Platform and Agent Service

Run Step 1 before querying `msdb`. Stop when `is_supported = 0`. Agent service state is returned
only on SQL Server (`engine_edition` 2 or 3); on Azure SQL Managed Instance the Agent is
platform-managed and always running, so no service row is expected. If the platform is supported
and the Agent service is stopped, report that as a likely systemic cause and continue with
historical steps when permissions allow. Use
[references/platform-and-edition-reference.md](references/platform-and-edition-reference.md) to
map the `EngineEdition` result to the correct platform, confirm the edition supports SQL Server
Agent, and route Azure SQL Database, Synapse, and Fabric to their non-Agent alternatives.

### Step 2: Inventory Recent Unsuccessful Jobs

Run Step 2 when `JobName` is empty or when the user does not know which job failed. It returns the
latest job-level outcome (`step_id = 0`) for jobs that failed, were canceled, retried, or remained
in progress during the lookback window.

If no rows are returned, state that no unsuccessful job outcomes were retained in the selected
window. Increase `LookbackHours` only with the user's agreement because SQL Agent history may be
purged or capped.

### Step 3: Drill Into the Selected Job History

Set `JobName` to the exact job name and run Step 3. Use `instance_id` ordering to reconstruct the
execution. The job-level row has `step_id = 0`; step rows identify the actionable failure.

Do not infer success from a successful final step alone. Use the job-level outcome and account for
step flow actions such as quit-with-success, retries, or branching to another step.

### Step 4: Check Current Execution State

Run Step 4 to determine whether the selected job is currently running and which step last completed.
An unfinished row can indicate a genuinely long execution, a blocked step, or stale activity after
an Agent restart. Correlate `agent_start_date` and `run_requested_date` before classifying it. Do
not claim that the inferred next sequential step is active when branching, retries, or restart-step
configuration could alter execution flow.

### Step 5: Review Job, Schedule, and Notification Configuration

Run Step 5. Check disabled jobs/schedules, unexpected owners, missing schedules, schedule windows,
and notification levels. A job can fail correctly but remain unnoticed when no failure notification
is configured. Cached next-run data and missing history do not prove that a schedule occurrence was
missed; correlate Agent uptime, schedule definition, activity, and external monitoring, and report an
evidence gap when the expected occurrence cannot be reconstructed reliably.

### Step 6: Review Step Execution Context and Failure Flow

Run Step 6. Check each step's subsystem, target database, proxy, retries, output logging, and
on-failure action. Command text is intentionally omitted. Never retrieve or display step commands
unless the user explicitly approves that sensitive evidence collection because even a short prefix
can contain credentials, tokens, or connection-string values.

### Step 7: Validate Last Success, Owner, Database, and Replica

Run Step 7 to find the last retained successful job outcome, verify that the owner resolves to an
enabled login, inspect the target database state and accessibility, and determine the local
Availability Group replica role when applicable. Do not recommend execution on a secondary or an
unknown replica unless the job is intentionally designed for that role.

### Step 8: Correlate SQL Agent and SQL Server Logs

Run the applicable Step 8 queries for the narrow failure window. Correlate by timestamp, job name,
step name, message ID, database, and subsystem. Redact secrets and connection-string values from
all excerpts. A log match is supporting evidence; do not attribute unrelated messages solely
because they occurred nearby. Obtain explicit approval before retrieving raw error-log rows.

### Step 9: Check Runtime and Resource Evidence

Use Step 9 to inspect current blocking and resource state, then use retained Query Store, Extended
Events, monitoring, or platform telemetry for historical evidence. Current DMVs do not prove what
happened during a past failure. Classify deadlock, timeout, disk, log, tempdb, CPU, memory, or I/O
pressure only when timestamped evidence overlaps the failure window.

### Step 10: Identify External Dependencies

Use Step 10's non-revealing indicators to identify likely files, shares, linked servers,
Database Mail, packages, executables, replication components, or external endpoints. Validate each
dependency under the effective execution identity through an approved, non-destructive check.
Never reveal credential values or retrieve command text merely to discover dependencies.

## Safety and Interpretation Rules

- Keep the investigation read-only unless the user separately authorizes remediation.
- Never run a failed step's command as part of diagnosis.
- Obtain explicit approval before retrieving message-bearing history, raw error logs, deadlock XML,
  output files, or command text because collection itself can expose sensitive values.
- Do not expose proxy credentials, passwords, secrets, tokens, connection strings, credential
  identities, or full command text. Redact sensitive values found in history, logs, and output files.
- Do not change a job owner, proxy, credential, schedule, command, retry policy, or notification
  configuration automatically.
- Require explicit user approval before generating a corrective change script, and separate approval
  before executing it. Approval to investigate is not approval to change or rerun anything.
- Never start, stop, or rerun a job automatically.
- Warn before any proposed rerun when a job may duplicate financial transactions, ETL loads,
  notifications, file delivery, replication work, or other non-idempotent side effects.
- Validate that the local Availability Group replica is appropriate for the workload before
  recommending execution.
- Treat job history messages as evidence, not proof. A wrapper step may replace the original error;
  correlate the first failed step, retries, output file, and subsystem logs.
- Distinguish an Agent service outage from an individual job failure. Missing history during an
  outage does not mean the job succeeded.
- If history has already been purged, report the evidence gap and recommend retaining more history
  or enabling step output logging before the next occurrence.

## Root Cause Assessment

Read [references/root-cause-guide.md](references/root-cause-guide.md) and classify the dominant
failure category only when the collected evidence supports it. List unresolved evidence gaps.

## Report

Read [references/report-template.md](references/report-template.md) and use it for the final answer.
