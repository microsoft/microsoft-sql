# SQL Server Agent Job Failures - Root Cause Guide

Use the first failed step, its history message, current Agent state, and step configuration together.
Do not classify from keyword matching alone when evidence conflicts.

Use **High** confidence only when direct, timestamped evidence identifies the failed component and
condition. Use **Medium** when multiple independent observations support the cause but direct proof
is unavailable. Use **Low** for a plausible hypothesis with material evidence gaps. Never convert
missing evidence into a confident classification.

## Agent Service Unavailable

Evidence: supported platform, Agent service is stopped or absent, and expected executions have no
corresponding history.

Assessment: **SQL Server Agent availability failure.** Scheduled jobs could not start.

Next steps:

1. Confirm the Agent service startup type and service account outside SQL Server.
2. Review Windows/service or Managed Instance platform events around the outage.
3. Restore Agent service availability before rerunning missed jobs.
4. Determine which schedules were missed; do not assume they will backfill automatically.

## Authentication or Authorization Failure

Evidence often includes "login failed", "access denied", "permission was denied", "could not obtain
information about Windows NT group/user", or a proxy/credential error.

Assessment: **The execution identity lacks access or cannot authenticate.**

Next steps:

1. Identify the effective identity: job owner for T-SQL steps, or configured proxy/subsystem context.
2. Confirm that the job owner login exists and is enabled.
3. Validate least-privilege access to the target database, file share, executable, or external service.
4. For non-T-SQL steps, verify proxy assignment and subsystem authorization without exposing secrets.
5. Avoid changing the owner to `sa` as a default fix; choose an intentional service identity.

## Database Unavailable, Wrong Replica, or Object Failure

Evidence includes error 4060, "cannot open database", "database does not exist", "invalid object
name", database offline/restoring states, an AG role mismatch, or a renamed/dropped object.

Assessment: **The step's target database or referenced object is unavailable or mismatched.**

Next steps:

1. Compare the configured `database_name` with the intended database.
2. Verify database state and object existence using the same execution identity.
3. Check recent deployments, restores, failovers, and renames.
4. Verify that the local AG replica role matches the job's intended execution policy.
5. Correct the dependency or configuration before rerunning the failed step.

## T-SQL Runtime Failure

Evidence includes a nonzero SQL message ID/severity, conversion or constraint errors, deadlock 1205,
timeout/attention messages, arithmetic errors, or explicit `THROW`/`RAISERROR` output.

Assessment: **The T-SQL step executed but failed at runtime.**

Next steps:

1. Preserve the exact message ID, severity, failed step, and occurrence time.
2. Correlate deadlocks, blocking, resource pressure, or data-quality failures with specialized skills.
3. Validate transaction rollback and idempotency before any rerun.
4. Fix the underlying query, data, or concurrency condition rather than increasing retries blindly.

## Timeout, Blocking, or Deadlock

Evidence includes error 1205, a captured deadlock graph, a command timeout, an attention event,
blocking-chain telemetry, or waits that overlap the failed execution.

Assessment: **Concurrency or timeout conditions prevented the step from completing.**

Next steps:

1. Preserve the deadlock graph, blocker identities, wait types, duration, and failure timestamps.
2. Identify the transaction and access-order pattern rather than treating the victim as the cause.
3. Confirm whether a timeout came from SQL Server, the client, the subsystem, or an external call.
4. Validate query, index, batching, and transaction changes before considering retry changes.

## Disk, Log, Tempdb, or Resource Exhaustion

Evidence includes errors 1101, 1105, 9002, operating-system disk errors, failed autogrowth, tempdb
allocation failures, out-of-memory messages, scheduler pressure, or timestamped CPU/I/O telemetry.

Assessment: **A capacity or resource limit interrupted the workload.**

Next steps:

1. Identify the exhausted resource and the exact database, file, volume, or host involved.
2. Correlate file growth, free capacity, workload demand, and platform monitoring at failure time.
3. Restore safe capacity or reduce demand before rerunning; do not rely on current free space alone.
4. Add threshold monitoring and capacity planning appropriate to the affected resource.

## External Dependency Failure

Evidence includes DNS, TLS, HTTP, linked-server, Database Mail, file/share, network, remote service,
or dependency-specific errors that align with the failed step and execution identity.

Assessment: **A service or resource outside the local SQL execution path was unavailable or denied.**

Next steps:

1. Identify the dependency owner, endpoint type, effective identity, and failure window.
2. Use an approved non-destructive health check; do not replay the job command.
3. Correlate dependency incidents, certificate changes, throttling, firewall, DNS, and network events.
4. Confirm timeout, retry, idempotency, and partial-delivery behavior before recovery.

## Proxy, Credential, or Subsystem Configuration Failure

Evidence includes CmdExec, PowerShell, SSIS, replication, or Analysis Services subsystem errors;
missing executables; invalid paths; inaccessible shares; or proxy authorization failures.

Assessment: **The non-T-SQL execution environment or dependency failed.**

Next steps:

1. Confirm the subsystem and proxy shown in Step 6.
2. Validate executable/module/package availability and path access under the effective identity.
3. Check output files and subsystem-specific logs without exposing credentials.
4. Prefer stable absolute paths and managed secret stores; do not embed secrets in job commands.

## Package or Executable Failure

Evidence includes a missing executable or module, nonzero process exit code, SSIS package failure,
PowerShell exception, CmdExec error, version mismatch, or invalid package/environment reference.

Assessment: **The configured package or executable started incorrectly or failed internally.**

Next steps:

1. Preserve the exit code, subsystem output, package execution ID, and protected output-log location.
2. Verify installation, architecture, version, package environment, and path under the proxy identity.
3. Redact arguments and environment values that contain secrets or connection strings.
4. Test the smallest non-destructive component check before proposing a controlled job rerun.

## Retry Exhaustion or Transient Dependency Failure

Evidence: `retries_attempted > 0`, repeated failure/retry rows, followed by a failed job outcome.

Assessment: **A transient-looking failure persisted beyond the configured retry policy.**

Next steps:

1. Compare the retry interval with the dependency's expected recovery time.
2. Determine whether retries are safe and idempotent.
3. Investigate the dependency outage or throttling before increasing retry counts.
4. Add bounded exponential retry logic in the workload when SQL Agent's fixed interval is inadequate.

## Schedule, Concurrency, Cancellation, or Long-Running Conflict

Evidence includes canceled status, a current activity row without `stop_execution_date`, elapsed time
well beyond baseline, or a new run that cannot start because an earlier execution remains active.

Assessment: **Schedule or concurrency behavior canceled, overlapped, blocked, or delayed execution.**

Next steps:

1. Identify who or what requested cancellation when audit evidence is available.
2. Inspect blocking, waits, external calls, and resource pressure for the active step.
3. Verify whether Agent restarted after the activity row began before calling it stale.
4. Do not stop the job until rollback and downstream impact are understood.

## Scheduling or Notification Gap

Evidence: disabled job/schedule, missing schedule, unexpected next run, or no operator configured for
failure notification.

Assessment: **Configuration delayed execution or detection; it may not be the step's technical cause.**

Next steps:

1. Verify the intended schedule, time zone, active window, and enabled state.
2. Confirm the next-run cache after schedule changes.
3. Configure failure notification and test Database Mail/operator delivery separately.
4. Report this as a contributing control gap when another root cause explains the failed step.

## Insufficient Retained Evidence

Evidence: no relevant rows in `sysjobhistory`, history was purged/capped, or the failure message only
contains a wrapper error.

Assessment: **The retained evidence is insufficient to determine root cause.**

Next steps:

1. Report the gap instead of guessing.
2. Increase per-job and total Agent history retention appropriately.
3. Enable step output logging to a protected location or table for the affected step.
4. Capture subsystem logs and retry the investigation after the next occurrence.
