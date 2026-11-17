# SQL Server Agent Job Failure Investigator - Queries

Before execution, bind `{{JobNameSqlLiteral}}` as an escaped Unicode T-SQL literal: reject NUL and
control characters, double every apostrophe, and preserve the `N'...'` wrapper shown below. Parse
`{{LookbackHoursInteger}}` and `{{TopNInteger}}` as integers outside SQL, then enforce ranges of
1-168 hours and 1-200 rows. Never insert unvalidated user text into these batches. All queries are
read-only and fully qualify SQL Server Agent metadata in `msdb`.

## Step 1 - Platform and SQL Server Agent Service

```sql
DECLARE @EngineEdition int = CONVERT(int, SERVERPROPERTY('EngineEdition'));

SELECT
    @@SERVERNAME AS server_name,
    CONVERT(nvarchar(128), SERVERPROPERTY('Edition')) AS edition,
    CONVERT(nvarchar(128), SERVERPROPERTY('ProductVersion')) AS product_version,
    LEFT(CONVERT(nvarchar(4000), @@VERSION), 4000) AS version_description,
    @EngineEdition AS engine_edition,
    CASE @EngineEdition
        WHEN 5 THEN 'Azure SQL Database'
        WHEN 6 THEN 'Azure Synapse dedicated SQL pool'
        WHEN 8 THEN 'Azure SQL Managed Instance'
        WHEN 9 THEN 'Azure SQL Edge'
        WHEN 11 THEN 'Azure Synapse serverless SQL pool / Fabric Warehouse'
        WHEN 12 THEN 'Fabric SQL Database'
        WHEN 2 THEN 'SQL Server Standard on-premises / Azure VM'
        WHEN 3 THEN 'SQL Server Enterprise on-premises / Azure VM'
        WHEN 4 THEN 'SQL Server Express on-premises / Azure VM (no SQL Server Agent)'
        ELSE 'Unknown or unsupported engine edition'
    END AS platform,
    CASE WHEN @EngineEdition IN (2, 3, 8) THEN 1 ELSE 0 END AS is_supported;

-- sys.dm_server_services exists only on the box product. Referencing it on Azure SQL Managed
-- Instance raises "Invalid object name", which TRY/CATCH cannot suppress for a compile-time
-- name resolution error, so the read is gated to engine editions 2 and 3.
IF @EngineEdition IN (2, 3)
BEGIN
    SELECT
        servicename,
        startup_type_desc,
        status_desc,
        service_account,
        last_startup_time,
        is_clustered
    FROM sys.dm_server_services
    WHERE filename LIKE '%SQLAGENT%'
       OR servicename LIKE 'SQL Server Agent%';
END;
```

Interpretation:

- Stop this skill when `is_supported = 0`.
- The service-state batch runs only on SQL Server (`engine_edition` 2 or 3). No service row there
  may indicate insufficient `VIEW SERVER STATE` permission or an installation without the Agent
  service.
- On Azure SQL Managed Instance (`engine_edition = 8`) the Agent service is platform-managed and
  always running, and `sys.dm_server_services` does not exist. No service row is returned and its
  absence is not a finding; continue to Step 2.
- `status_desc <> 'Running'` is a server-wide scheduling risk, not an individual step failure.
- SQL Server does not expose a reliable engine property that distinguishes every on-premises host
    from SQL Server on an Azure VM. Record that distinction from trusted deployment metadata or the
    user; do not infer it from a machine name or IP address.
- On Azure SQL Database, route Azure SQL Elastic Jobs workloads to Elastic Job agent and execution
    history diagnostics. Fabric SQL surfaces support neither SQL Server Agent nor Elastic Jobs.

## Step 2 - Recent Unsuccessful Job Outcomes

```sql
DECLARE @LookbackHours int = {{LookbackHoursInteger}};
DECLARE @TopN int = {{TopNInteger}};

SELECT TOP (@TopN)
    j.name AS job_name,
    h.instance_id,
    msdb.dbo.agent_datetime(h.run_date, h.run_time) AS outcome_time,
    CASE h.run_status
        WHEN 0 THEN 'Failed'
        WHEN 1 THEN 'Succeeded'
        WHEN 2 THEN 'Retry'
        WHEN 3 THEN 'Canceled'
        WHEN 4 THEN 'In progress'
        ELSE 'Unknown'
    END AS run_status,
    h.run_duration,
    h.retries_attempted,
    LEFT(h.message, 4000) AS outcome_message,
    j.enabled AS job_enabled,
    SUSER_SNAME(j.owner_sid) AS job_owner
FROM msdb.dbo.sysjobhistory AS h
INNER JOIN msdb.dbo.sysjobs AS j
    ON j.job_id = h.job_id
WHERE h.step_id = 0
  AND h.run_status IN (0, 2, 3, 4)
  AND h.run_date > 0
  AND msdb.dbo.agent_datetime(h.run_date, h.run_time)
      >= DATEADD(HOUR, -@LookbackHours, SYSDATETIME())
ORDER BY h.instance_id DESC;
```

`run_duration` uses `HHMMSS` encoding and can exceed six digits for runs longer than 24 hours.

## Step 3 - Selected Job Execution and Step History

```sql
DECLARE @JobName sysname = N'{{JobNameSqlLiteral}}';
DECLARE @LookbackHours int = {{LookbackHoursInteger}};
DECLARE @TopN int = {{TopNInteger}};

SELECT TOP (@TopN)
    j.name AS job_name,
    h.instance_id,
    h.step_id,
    CASE WHEN h.step_id = 0 THEN '(Job outcome)' ELSE h.step_name END AS step_name,
    msdb.dbo.agent_datetime(h.run_date, h.run_time) AS event_time,
    CASE h.run_status
        WHEN 0 THEN 'Failed'
        WHEN 1 THEN 'Succeeded'
        WHEN 2 THEN 'Retry'
        WHEN 3 THEN 'Canceled'
        WHEN 4 THEN 'In progress'
        ELSE 'Unknown'
    END AS run_status,
    h.sql_message_id,
    h.sql_severity,
    h.run_duration,
    h.retries_attempted,
    h.operator_id_emailed,
    h.operator_id_netsent,
    h.operator_id_paged,
    LEFT(h.message, 4000) AS history_message
FROM msdb.dbo.sysjobhistory AS h
INNER JOIN msdb.dbo.sysjobs AS j
    ON j.job_id = h.job_id
WHERE j.name = @JobName
  AND h.run_date > 0
  AND msdb.dbo.agent_datetime(h.run_date, h.run_time)
      >= DATEADD(HOUR, -@LookbackHours, SYSDATETIME())
ORDER BY h.instance_id DESC;
```

The highest failed step row before a failed job-outcome row usually contains the actionable error,
but account for retries and explicit step branching. History messages can contain secrets copied
from commands or providers. Obtain approval before retrieving this message-bearing result, keep the
bounded projection, and redact sensitive values before returning or retaining it.

## Step 4 - Current Execution State

```sql
DECLARE @JobName sysname = N'{{JobNameSqlLiteral}}';

;WITH LatestAgentSession AS
(
    SELECT MAX(session_id) AS session_id
    FROM msdb.dbo.syssessions
)
SELECT
    j.name AS job_name,
    s.agent_start_date,
    a.run_requested_date,
    a.queued_date,
    a.start_execution_date,
    a.stop_execution_date,
    a.last_executed_step_id,
    js.step_name AS last_executed_step_name,
    CASE
        WHEN a.start_execution_date IS NOT NULL AND a.stop_execution_date IS NULL
            THEN a.last_executed_step_id + 1
    END AS inferred_next_sequential_step_id,
    CASE
        WHEN a.start_execution_date IS NOT NULL AND a.stop_execution_date IS NULL THEN 'Running'
        WHEN a.start_execution_date IS NULL THEN 'Not started in current Agent session'
        ELSE 'Completed'
    END AS activity_status,
    CASE
        WHEN a.start_execution_date IS NOT NULL AND a.stop_execution_date IS NULL
        THEN DATEDIFF(SECOND, a.start_execution_date, SYSDATETIME())
    END AS elapsed_seconds
FROM msdb.dbo.sysjobs AS j
CROSS JOIN LatestAgentSession AS latest
INNER JOIN msdb.dbo.syssessions AS s
    ON s.session_id = latest.session_id
LEFT JOIN msdb.dbo.sysjobactivity AS a
    ON a.job_id = j.job_id
   AND a.session_id = latest.session_id
LEFT JOIN msdb.dbo.sysjobsteps AS js
    ON js.job_id = j.job_id
   AND js.step_id = a.last_executed_step_id
WHERE j.name = @JobName;
```

For a running job, `last_executed_step_id` is the last completed step. The inferred next sequential
step is only a hint: branching, retries, and restart-step configuration can make it incorrect. Do
not label it as the current step without corroborating evidence.

## Step 5 - Job, Schedule, and Notification Configuration

```sql
DECLARE @JobName sysname = N'{{JobNameSqlLiteral}}';

SELECT
    j.name AS job_name,
    j.enabled AS job_enabled,
    SUSER_SNAME(j.owner_sid) AS job_owner,
    c.name AS category_name,
    j.date_created,
    j.date_modified,
    j.notify_level_email,
    j.notify_level_eventlog,
    j.notify_level_netsend,
    j.notify_level_page,
    op.name AS email_operator,
    net_op.name AS netsend_operator,
    page_op.name AS pager_operator,
    j.delete_level,
    sch.name AS schedule_name,
    sch.enabled AS schedule_enabled,
    sch.freq_type,
    sch.freq_interval,
    sch.freq_subday_type,
    sch.freq_subday_interval,
    sch.active_start_date,
    sch.active_start_time,
    sch.active_end_date,
    sch.active_end_time,
    js.next_run_date,
    js.next_run_time
FROM msdb.dbo.sysjobs AS j
LEFT JOIN msdb.dbo.syscategories AS c
    ON c.category_id = j.category_id
LEFT JOIN msdb.dbo.sysoperators AS op
    ON op.id = j.notify_email_operator_id
LEFT JOIN msdb.dbo.sysoperators AS net_op
    ON net_op.id = j.notify_netsend_operator_id
LEFT JOIN msdb.dbo.sysoperators AS page_op
    ON page_op.id = j.notify_page_operator_id
LEFT JOIN msdb.dbo.sysjobschedules AS js
    ON js.job_id = j.job_id
LEFT JOIN msdb.dbo.sysschedules AS sch
    ON sch.schedule_id = js.schedule_id
WHERE j.name = @JobName
ORDER BY sch.name;
```

`next_run_date` and `next_run_time` are cached values and can lag briefly after schedule changes.

## Step 6 - Step Execution Context and Failure Flow

```sql
DECLARE @JobName sysname = N'{{JobNameSqlLiteral}}';

SELECT
    j.name AS job_name,
    s.step_id,
    s.step_name,
    s.subsystem,
    s.database_name,
    p.name AS proxy_name,
        p.enabled AS proxy_enabled,
        CASE WHEN p.proxy_id IS NULL THEN NULL
            WHEN cr.credential_id IS NULL THEN 0 ELSE 1 END AS credential_configured,
    s.retry_attempts,
    s.retry_interval,
    s.on_success_action,
    s.on_success_step_id,
    s.on_fail_action,
    s.on_fail_step_id,
    s.output_file_name,
    s.flags,
    LEN(s.command) AS command_length,
    CASE WHEN s.command IS NULL OR s.command = N'' THEN 0 ELSE 1 END AS has_command
FROM msdb.dbo.sysjobs AS j
INNER JOIN msdb.dbo.sysjobsteps AS s
    ON s.job_id = j.job_id
LEFT JOIN msdb.dbo.sysproxies AS p
    ON p.proxy_id = s.proxy_id
LEFT JOIN sys.credentials AS cr
    ON cr.credential_id = p.credential_id
WHERE j.name = @JobName
ORDER BY s.step_id;
```

Command text is deliberately omitted because even a short prefix can expose a secret. Retrieve it
only after explicit approval, then redact sensitive values before returning or retaining it. The
proxy fields disclose configuration state without returning the credential identity or secret.

## Step 7 - Last Success, Owner, Database, and Replica

### 7a - Last Successful Outcome and Owner Validity

```sql
DECLARE @JobName sysname = N'{{JobNameSqlLiteral}}';

SELECT
    j.name AS job_name,
    SUSER_SNAME(j.owner_sid) AS job_owner,
    CASE WHEN owner_principal.sid IS NULL THEN 0 ELSE 1 END AS owner_resolves,
    owner_principal.type_desc AS owner_type,
    owner_principal.is_disabled AS owner_is_disabled,
    IS_SRVROLEMEMBER(N'sysadmin', SUSER_SNAME(j.owner_sid)) AS owner_is_sysadmin,
    last_success.instance_id AS last_success_instance_id,
    last_success.success_time,
    last_success.run_duration AS last_success_run_duration
FROM msdb.dbo.sysjobs AS j
LEFT JOIN sys.server_principals AS owner_principal
    ON owner_principal.sid = j.owner_sid
OUTER APPLY
(
    SELECT TOP (1)
        h.instance_id,
        msdb.dbo.agent_datetime(h.run_date, h.run_time) AS success_time,
        h.run_duration
    FROM msdb.dbo.sysjobhistory AS h
    WHERE h.job_id = j.job_id
      AND h.step_id = 0
      AND h.run_status = 1
      AND h.run_date > 0
    ORDER BY h.instance_id DESC
) AS last_success
WHERE j.name = @JobName;
```

A missing owner principal is actionable evidence. A missing last-success row means no successful
outcome is retained; it does not prove that the job has never succeeded. For T-SQL steps, a
sysadmin owner generally causes execution under the SQL Server Agent service context; a
non-sysadmin owner uses impersonation. Treat an unknown membership result as an evidence gap.

### 7b - Target Database State, Access, and Local AG Role

```sql
DECLARE @JobName sysname = N'{{JobNameSqlLiteral}}';

SELECT DISTINCT
    s.database_name,
    d.state_desc AS database_state,
    d.user_access_desc,
    HAS_DBACCESS(d.name) AS has_database_access,
    ag.name AS availability_group_name,
    ars.role_desc AS local_replica_role,
    drs.synchronization_health_desc,
    drs.database_state_desc AS replica_database_state
FROM msdb.dbo.sysjobs AS j
INNER JOIN msdb.dbo.sysjobsteps AS s
    ON s.job_id = j.job_id
LEFT JOIN sys.databases AS d
    ON d.name = NULLIF(s.database_name, N'')
LEFT JOIN sys.dm_hadr_database_replica_states AS drs
    ON drs.database_id = d.database_id
   AND drs.is_local = 1
LEFT JOIN sys.availability_replicas AS ar
    ON ar.replica_id = drs.replica_id
LEFT JOIN sys.availability_groups AS ag
    ON ag.group_id = ar.group_id
LEFT JOIN sys.dm_hadr_availability_replica_states AS ars
    ON ars.replica_id = ar.replica_id
   AND ars.is_local = 1
WHERE j.name = @JobName
  AND NULLIF(s.database_name, N'') IS NOT NULL
ORDER BY s.database_name;
```

No AG row means the database is not in an AG or the caller cannot view AG metadata. Treat an
unknown role as an evidence gap. Verify the step's intended replica policy before recommending a
rerun.

## Step 8 - SQL Agent and SQL Server Error-Log Correlation

Use the smallest practical failure window. The example derives it from `LookbackHours`; replace
the bounds with the observed execution start and end when known.

```sql
DECLARE @LookbackHours int = {{LookbackHoursInteger}};
DECLARE @StartTime datetime = DATEADD(HOUR, -@LookbackHours, GETDATE());
DECLARE @EndTime datetime = GETDATE();

-- SQL Server Database Engine error log.
EXEC master.dbo.xp_readerrorlog 0, 1, NULL, NULL, @StartTime, @EndTime, N'asc';

-- SQL Server Agent error log.
BEGIN TRY
    EXEC master.dbo.xp_readerrorlog 0, 2, NULL, NULL, @StartTime, @EndTime, N'asc';
END TRY
BEGIN CATCH
    SELECT
        CAST(1 AS bit) AS agent_log_unavailable,
        ERROR_NUMBER() AS error_number,
        N'Agent log unavailable; treat Agent-log evidence as an evidence gap.' AS evidence_note;
END CATCH;
```

Error-log access may require elevated permissions and availability differs by platform. If the
Agent has never started, the Agent log may not exist; the catch result is an evidence gap, not a
job failure. Log rows can contain sensitive values, so obtain explicit approval before running
this section. Do not broaden the time range automatically. Redact passwords, tokens,
connection-string values, and credential identities before returning or retaining log text.

## Step 9 - Runtime and Resource Correlation

### 9a - Current Blocking and Long-Running Requests

```sql
SELECT
    r.session_id,
    r.blocking_session_id,
    r.status,
    r.command,
    DB_NAME(r.database_id) AS database_name,
    r.start_time,
    r.total_elapsed_time,
    r.wait_type,
    r.wait_time,
    r.last_wait_type,
    r.wait_resource,
    r.cpu_time,
    r.reads,
    r.writes,
    r.logical_reads
FROM sys.dm_exec_requests AS r
WHERE r.session_id <> @@SPID
  AND (r.blocking_session_id <> 0 OR r.total_elapsed_time >= 60000)
ORDER BY r.blocking_session_id DESC, r.total_elapsed_time DESC;
```

This is current state only. Do not claim it explains a completed failure unless the request remains
active or timestamped monitoring evidence ties the same blocker or wait to the failure window.

### 9b - Current Volume Capacity

```sql
SELECT
    vs.volume_mount_point,
    MAX(vs.file_system_type) AS file_system_type,
    MAX(vs.total_bytes) AS total_bytes,
    MIN(vs.available_bytes) AS available_bytes,
    CONVERT(decimal(6,2), 100.0 * MIN(vs.available_bytes) / NULLIF(MAX(vs.total_bytes), 0))
        AS available_percent
FROM sys.master_files AS mf
CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) AS vs
GROUP BY vs.volume_mount_point
ORDER BY vs.volume_mount_point;
```

Correlate low capacity with file-growth failures, error-log messages, and monitoring data. A low
current value alone does not establish historical disk, transaction log, or tempdb exhaustion.

### 9c - Retained Deadlocks from the Current `system_health` Event File

```sql
DECLARE @SystemHealthPath nvarchar(260);
DECLARE @LookbackHours int = {{LookbackHoursInteger}};
DECLARE @TopN int = {{TopNInteger}};
DECLARE @StartTimeUtc datetime2 = DATEADD(HOUR, -@LookbackHours, SYSUTCDATETIME());

SELECT @SystemHealthPath = CONVERT(xml, t.target_data)
    .value('(EventFileTarget/File/@name)[1]', 'nvarchar(260)')
FROM sys.dm_xe_sessions AS s
INNER JOIN sys.dm_xe_session_targets AS t
    ON t.event_session_address = s.address
WHERE s.name = N'system_health'
  AND t.target_name = N'event_file';

SELECT TOP (@TopN)
    event_xml.value('(event/@timestamp)[1]', 'datetime2') AS event_time_utc,
    event_xml.query('(event/data/value/deadlock)[1]') AS deadlock_xml
FROM
(
    SELECT CONVERT(xml, event_data) AS event_xml
    FROM sys.fn_xe_file_target_read_file(@SystemHealthPath, NULL, NULL, NULL)
    WHERE object_name = N'xml_deadlock_report'
) AS deadlocks
WHERE event_xml.value('(event/@timestamp)[1]', 'datetime2') >= @StartTimeUtc
ORDER BY event_time_utc DESC;
```

Deadlock XML can include statement text and security context. Obtain explicit approval before
running this section, retain only the bounded failure window, and redact it before returning or
retaining it.

Use retained Query Store, Extended Events, Azure Monitor, or other timestamped telemetry for past
timeouts, blocking, CPU, memory, I/O, log, or tempdb pressure. Report unavailable telemetry as an
evidence gap rather than substituting current DMV values.

## Step 10 - External Dependency Indicators

This query classifies likely dependencies without returning full commands or credential values.

```sql
DECLARE @JobName sysname = N'{{JobNameSqlLiteral}}';

SELECT
    s.step_id,
    s.step_name,
    s.subsystem,
    CASE WHEN s.output_file_name IS NULL OR s.output_file_name = N'' THEN 0 ELSE 1 END
        AS has_output_file,
    CASE WHEN s.command LIKE N'%\\%' THEN 1 ELSE 0 END AS may_use_unc_path,
    CASE WHEN s.command LIKE N'%http://%' OR s.command LIKE N'%https://%' THEN 1 ELSE 0 END
        AS may_use_external_endpoint,
    CASE WHEN s.command LIKE N'%sp_send_dbmail%' THEN 1 ELSE 0 END AS may_use_database_mail,
    CASE WHEN s.command LIKE N'%OPENQUERY%' OR s.command LIKE N'%EXEC% AT %'
         THEN 1 ELSE 0 END AS may_use_linked_server,
        CASE WHEN s.command LIKE N'%Password=%' OR s.command LIKE N'%Pwd=%'
              OR s.command LIKE N'%Token=%' OR s.command LIKE N'%Secret=%'
            THEN 1 ELSE 0 END AS contains_sensitive_value_marker
FROM msdb.dbo.sysjobs AS j
INNER JOIN msdb.dbo.sysjobsteps AS s
    ON s.job_id = j.job_id
WHERE j.name = @JobName
ORDER BY s.step_id;
```

The flags are indicators, not proof. The subsystem itself can imply SSIS, replication, PowerShell,
CmdExec, or executable/package dependencies. Command text remains omitted regardless of the marker
result because marker detection cannot prove that text is safe. Validate files, shares, linked
servers, mail, packages, executables, and endpoints only through approved non-destructive checks
under the effective execution identity.
