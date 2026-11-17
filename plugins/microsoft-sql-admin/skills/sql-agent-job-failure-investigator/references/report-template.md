# SQL Server Agent Job Failure Investigation - Report Template

Replace placeholders with observed values. Omit empty sections only when the corresponding step was
not applicable, and state why it was skipped.

```text
## SQL Server Agent Job Failure Investigation

Server:          {{server_name}}
Platform:        {{platform and version}}
Job:             {{job_name or "recent unsuccessful jobs inventory"}}
Investigation:   {{current timestamp and time zone}}
Lookback:        {{LookbackHours}} hours
Agent state:     {{Running / Stopped / Unknown due to permissions}}
Environment:     {{on-premises / Azure VM / Managed Instance / not independently verified}}

### Executive Summary

Outcome:         {{Failed / Canceled / Retry exhausted / Still running / No retained failure}}
Failed step:     {{step_id and step_name, or unknown}}
Failure time:    {{timestamp and time zone}}
Last success:    {{timestamp and time zone, no retained success, or unknown}}
Root cause:      {{supported root-cause classification}}
Confidence:      {{High / Medium / Low}}
Impact:          {{missed data, delayed process, downstream jobs, or unknown}}
Operational risk: {{business and operational consequences, severity, and affected owners}}

### Failure Evidence

| Evidence | Observed value |
|---|---|
| Job-level outcome | {{status and message}} |
| First actionable failed step | {{step and status}} |
| SQL message | {{message ID, severity, bounded history message}} |
| Retries | {{attempted and configured}} |
| Duration | {{reported HHMMSS value and interpreted duration}} |
| Current activity | {{running/completed/not started; elapsed time}} |
| Timeline | {{ordered execution, retry, step, outcome, and correlated event timestamps}} |
| Correlated logs | {{Agent, engine, subsystem, and monitoring evidence with sensitive values redacted}} |

### Execution Context

| Setting | Observed value | Assessment |
|---|---|---|
| Job owner | {{owner}} | {{expected / disabled / missing / needs validation}} |
| Subsystem | {{subsystem}} | {{T-SQL / CmdExec / PowerShell / other}} |
| Target database | {{database_name}} | {{available / unavailable / unknown}} |
| Proxy | {{proxy name or none}} | {{appropriate / missing / needs validation}} |
| Credential dependency | {{configured / missing / not applicable; never include identity or secret}} | {{assessment}} |
| Failure flow | {{on_fail_action and target}} | {{expected / masks failure / unexpected}} |
| Output logging | {{output_file_name and flags}} | {{available / absent / inaccessible}} |
| Local AG role | {{primary / secondary / resolving / not applicable / unknown}} | {{appropriate for workload / unsafe / unverified}} |

### Dependency and Resource Evidence

| Area | Observed value | Assessment |
|---|---|---|
| Database state and access | {{state, access result, replica health}} | {{assessment}} |
| Blocking/deadlocks/timeouts | {{timestamped evidence or unavailable}} | {{assessment}} |
| Disk/log/tempdb/resources | {{timestamped evidence or unavailable}} | {{assessment}} |
| Files/shares/linked servers/mail | {{bounded, redacted dependency indicators}} | {{assessment}} |
| Package/executable/endpoint | {{subsystem evidence and exit/error status}} | {{assessment}} |

### Schedule and Detection Controls

| Control | Observed value | Assessment |
|---|---|---|
| Job enabled | {{yes/no}} | {{assessment}} |
| Schedule | {{name, enabled state, active window}} | {{assessment}} |
| Next run | {{date/time or none}} | {{assessment}} |
| Failure notification | {{level and operator}} | {{configured / missing / delivery unverified}} |

### Root Cause Assessment

{{State the dominant classification and cite the evidence that supports it. Separate the technical
cause from contributing scheduling, retry, ownership, or notification gaps.}}

### Business and Operational Risk

{{Describe affected business process, data freshness or integrity, downstream dependencies,
recovery urgency, and the risk of duplicate or partial work. Call out financial transactions, ETL
loads, notifications, file delivery, and other non-idempotent effects explicitly when applicable.}}

### Evidence Gaps

{{List purged history, missing permissions, wrapper-only messages, unavailable output files, or
uncertain execution identity. Use "None identified" only when appropriate.}}

### Safe Remediation Options

1. {{Read-only verification or immediate containment}}
2. {{Root-cause correction option and its risk; do not generate a change script without approval}}
3. {{Alternative correction option and tradeoff, when applicable}}
4. {{Monitoring, history retention, capacity, or notification improvement}}

### Validation Query

```sql
{{Read-only query that verifies the diagnosed condition or proposed correction. Do not include
secrets, corrective DDL/DML, or the failed job command.}}
```

### Escalation Evidence Package

- {{Failure and last-success timestamps with time zone}}
- {{Job/step identifiers, bounded history messages, SQL error IDs, and retry timeline}}
- {{Redacted Agent, engine, subsystem, Extended Events, and monitoring excerpts}}
- {{Owner team for database, platform, security, or external dependency}}
- {{Correlation IDs, incident IDs, package execution IDs, or output-log locations when available}}

### Items That Could Not Be Verified

{{List unavailable permissions, purged history, unknown Azure VM placement, unresolved execution
identity, inaccessible logs, absent historical telemetry, unknown replica intent, or dependencies
that could not be tested. Use "None identified" only when every required area was verified.}}

### Rerun Safety

{{State whether idempotency, transaction rollback, partial output, and downstream effects have been
validated. Explicitly warn about duplicate financial transactions, ETL loads, notifications, or
other side effects. Confirm the local replica is appropriate. Do not recommend or execute a rerun
until these are understood and the user separately approves it.}}
```