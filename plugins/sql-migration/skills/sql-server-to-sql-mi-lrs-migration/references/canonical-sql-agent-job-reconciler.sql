/*
Single canonical implementation for the LRS SQL Agent log-backup job.
Render only the scalar placeholders below. Do not copy any implementation from
this file into documentation or another script.

RequestedAction:
  Inspect - inventory and classify only
  Create  - create only from Absent after both external confirmation gates
  Repair  - reconcile only a workflow-owned Partial job
  EnableAndStart - enable and start only a Matching job
  StopAndDisable - request stop when running, then disable only a Matching job
  Disable - disable only a Matching job (cleanup compatibility)
*/
USE msdb;
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @DatabaseName sysname = N'<source-database>';
DECLARE @LocalBackupRoot nvarchar(2048) = N'<approved-local-root>';
DECLARE @DatabaseFolder nvarchar(128) = N'<database-folder>';
DECLARE @ExpectedOwner sysname = N'<validated-job-owner>';
DECLARE @RequestedAction varchar(20) = '<requested-action>';
DECLARE @DisclaimerAccepted bit = <disclaimer-accepted-bit>;
DECLARE @TypedCreationConfirmed bit = <typed-creation-confirmed-bit>;

/* These are the only implementations of canonical job metadata. */
DECLARE @SourceServerIdentity sysname = COALESCE(
    NULLIF(CONVERT(nvarchar(128), SERVERPROPERTY('ServerName')), N''),
    @@SERVERNAME
);
DECLARE @JobIdentityDigest varchar(40) = CONVERT(varchar(40), HASHBYTES(
    'SHA1',
    CONVERT(varbinary(max), @SourceServerIdentity + NCHAR(0) + @DatabaseName)
), 2);
DECLARE @JobName sysname = N'LRS log backup - '
    + LEFT(@DatabaseName, 94) + N'-' + RIGHT(@JobIdentityDigest, 16);
DECLARE @ExpectedDescription nvarchar(512) =
    N'LRS migration log backup to a unique local file for AzCopy upload. '
    + N'Identity SHA1: ' + @JobIdentityDigest + N'.';
DECLARE @ExpectedStepName sysname = N'BACKUP LOG TO DISK';
DECLARE @ExpectedBackupPathDeclaration nvarchar(4000) =
    N'DECLARE @BackupPath nvarchar(4000) = N'''
    + REPLACE(@LocalBackupRoot, '''', '''''')
    + N'\' + REPLACE(@DatabaseFolder, '''', '''''') + N'\';
DECLARE @ExpectedCommand nvarchar(max) =
    N'SET NOCOUNT ON; '
    + N'DECLARE @AttemptUtc datetime2(3) = SYSUTCDATETIME(); '
    + @ExpectedBackupPathDeclaration
    + N'log_'' + CONVERT(char(8), @AttemptUtc, 112) + N''T'' '
    + N'+ REPLACE(CONVERT(char(12), @AttemptUtc, 114), '':'', '''') '
    + N'+ N''Z_'' + REPLACE(CONVERT(char(36), NEWID()), ''-'', '''') '
    + N'+ N''.trn''; '
    + N'BACKUP LOG ' + QUOTENAME(@DatabaseName)
    + N' TO DISK = @BackupPath '
    + N'WITH INIT, COMPRESSION, CHECKSUM, STATS = 5;';
DECLARE @FrequencyMinutes int = 10;
DECLARE @ScheduleFreqType int = 4;
DECLARE @ScheduleFreqInterval int = 1;
DECLARE @ScheduleFreqSubdayType int = 4;
DECLARE @ScheduleFreqRecurrenceFactor int = 1;
DECLARE @ScheduleStartDate int = 19900101;
DECLARE @ScheduleEndDate int = 99991231;
DECLARE @ScheduleStartTime int = 0;
DECLARE @ScheduleEndTime int = 235959;

IF @RequestedAction NOT IN ('Inspect', 'Create', 'Repair', 'EnableAndStart', 'StopAndDisable', 'Disable')
    THROW 51000, 'Unsupported SQL Agent reconciler action.', 1;
IF DB_ID(@DatabaseName) IS NULL
    THROW 51001, 'Source database does not exist.', 1;
IF NULLIF(LTRIM(RTRIM(@LocalBackupRoot)), N'') IS NULL
    THROW 51002, 'An approved local backup root is required.', 1;
IF NULLIF(LTRIM(RTRIM(@SourceServerIdentity)), N'') IS NULL
    THROW 51003, 'Source server identity is required.', 1;
IF @DatabaseFolder LIKE N'%/%' OR @DatabaseFolder LIKE N'%\%'
    THROW 51004, 'Database folder must be one path segment.', 1;
IF @ExpectedCommand LIKE N'%DECLARE @sql%'
    OR @ExpectedCommand NOT LIKE N'%DECLARE @AttemptUtc datetime2(3) = SYSUTCDATETIME()%'
    OR @ExpectedCommand NOT LIKE N'%NEWID()%'
    OR @ExpectedCommand NOT LIKE N'% TO DISK = @BackupPath WITH INIT, COMPRESSION, CHECKSUM, STATS = 5;%'
    THROW 51005, 'Canonical backup command validation failed.', 1;

DECLARE @AgentSessionId int = (SELECT MAX(session_id) FROM dbo.syssessions);

/* Safety inventory. Every result set is required; unavailable evidence fails the batch. */
SELECT j.job_id, j.name, j.enabled, j.description,
       SUSER_SNAME(j.owner_sid) AS owner_login,
       CASE WHEN ja.start_execution_date IS NOT NULL
                  AND ja.stop_execution_date IS NULL THEN 1 ELSE 0 END AS is_running
FROM dbo.sysjobs AS j
LEFT JOIN dbo.sysjobactivity AS ja
  ON ja.job_id = j.job_id AND ja.session_id = @AgentSessionId
WHERE j.name = @JobName;

SELECT r.session_id, r.command, DB_NAME(r.database_id) AS database_name,
       r.start_time, r.percent_complete,
       CASE WHEN r.database_id = DB_ID(@DatabaseName) THEN 1 ELSE 0 END
         AS targets_selected_database
FROM sys.dm_exec_requests AS r
WHERE r.command IN (N'BACKUP DATABASE', N'BACKUP LOG');

SELECT DISTINCT j.job_id, j.name, j.enabled, ja.start_execution_date,
       s.step_id, s.step_name, s.database_name, s.command,
       CASE WHEN s.database_name = @DatabaseName
                  OR CHARINDEX(QUOTENAME(@DatabaseName), s.command) > 0
                  OR CHARINDEX(@DatabaseName, s.command) > 0
            THEN 1 ELSE 0 END AS targets_selected_database
FROM dbo.sysjobs AS j
JOIN dbo.sysjobactivity AS ja
  ON ja.job_id = j.job_id AND ja.session_id = @AgentSessionId
JOIN dbo.sysjobsteps AS s ON s.job_id = j.job_id
WHERE ja.start_execution_date IS NOT NULL
  AND ja.stop_execution_date IS NULL
  AND (CHARINDEX(N'BACKUP DATABASE', UPPER(s.command)) > 0
       OR CHARINDEX(N'BACKUP LOG', UPPER(s.command)) > 0);

SELECT j.job_id, j.name, j.enabled, s.step_id, s.step_name, s.database_name,
       s.command, sch.schedule_id, sch.name AS schedule_name,
       sch.enabled AS schedule_enabled, sch.freq_type, sch.freq_interval,
       sch.freq_subday_type, sch.freq_subday_interval,
       sch.active_start_time, sch.active_end_time
FROM dbo.sysjobs AS j
JOIN dbo.sysjobsteps AS s ON s.job_id = j.job_id
LEFT JOIN dbo.sysjobschedules AS js ON js.job_id = j.job_id
LEFT JOIN dbo.sysschedules AS sch ON sch.schedule_id = js.schedule_id
WHERE j.enabled = 1
  AND (CHARINDEX(N'BACKUP DATABASE', UPPER(s.command)) > 0
       OR CHARINDEX(N'BACKUP LOG', UPPER(s.command)) > 0)
  AND (s.database_name = @DatabaseName
       OR CHARINDEX(QUOTENAME(@DatabaseName), s.command) > 0
       OR CHARINDEX(@DatabaseName, s.command) > 0)
ORDER BY j.name, s.step_id, sch.schedule_id;

SELECT TOP (100) bs.backup_set_id, bs.database_name, bs.type,
       bs.backup_start_date, bs.backup_finish_date, bs.is_copy_only,
       bs.first_lsn, bs.last_lsn, bmf.physical_device_name
FROM dbo.backupset AS bs
LEFT JOIN dbo.backupmediafamily AS bmf ON bmf.media_set_id = bs.media_set_id
WHERE bs.database_name = @DatabaseName AND bs.type IN ('D', 'I', 'L')
ORDER BY bs.backup_finish_date DESC, bs.backup_set_id DESC;

SELECT bs.type, COUNT_BIG(*) AS completed_backup_count,
       MIN(bs.backup_finish_date) AS first_finish_time,
       MAX(bs.backup_finish_date) AS latest_finish_time
FROM dbo.backupset AS bs
WHERE bs.database_name = @DatabaseName
  AND bs.type IN ('D', 'I', 'L')
  AND bs.backup_finish_date >= DATEADD(hour, -24, GETDATE())
GROUP BY bs.type;

DECLARE @JobId uniqueidentifier;
DECLARE @ActualDescription nvarchar(512);
DECLARE @ActualOwner sysname;
DECLARE @ObservedState varchar(20);
DECLARE @Reason nvarchar(512);
DECLARE @MutationApplied bit = 0;
DECLARE @ScheduleName sysname;
DECLARE @CanonicalScheduleId int;
DECLARE @AttachedScheduleId int;
DECLARE @ExistingStepId int;
DECLARE @LockedScheduleBindingCount bigint;

Reclassify:
SELECT @JobId = NULL, @ActualDescription = NULL, @ActualOwner = NULL,
       @ObservedState = NULL, @Reason = NULL, @ScheduleName = NULL;
SELECT @JobId = job_id, @ActualDescription = description,
       @ActualOwner = SUSER_SNAME(owner_sid)
FROM dbo.sysjobs
WHERE name = @JobName;
IF @JobId IS NOT NULL
    SET @ScheduleName = LEFT(
        N'LRS every 10 minutes - ' + CONVERT(nvarchar(36), @JobId), 128);

IF @JobId IS NULL
    SET @ObservedState = 'Absent';
ELSE IF @ActualDescription IS NULL
      OR @ActualDescription <> @ExpectedDescription
      OR @ActualOwner IS NULL
      OR @ActualOwner <> @ExpectedOwner
      OR (SELECT COUNT_BIG(*) FROM dbo.sysjobsteps WHERE job_id = @JobId) > 1
      OR ((SELECT COUNT_BIG(*) FROM dbo.sysjobsteps
           WHERE job_id = @JobId) = 1
          AND NOT EXISTS (
              SELECT 1
              FROM dbo.sysjobsteps
              WHERE job_id = @JobId
                AND step_name = @ExpectedStepName
                AND subsystem = N'TSQL'
          ))
      OR EXISTS (
          SELECT 1
          FROM dbo.sysjobsteps
          WHERE job_id = @JobId
            AND step_name = @ExpectedStepName
            AND subsystem = N'TSQL'
            AND (
                (CHARINDEX(N'BACKUP LOG ', UPPER(command)) > 0
                 AND CHARINDEX(UPPER(N'BACKUP LOG ' + QUOTENAME(@DatabaseName)), UPPER(command)) = 0)
                OR
                (CHARINDEX(N'DECLARE @BACKUPPATH NVARCHAR(4000) = N''', UPPER(command)) > 0
                 AND CHARINDEX(@ExpectedBackupPathDeclaration, command) = 0)
            )
      )
      OR EXISTS (SELECT 1 FROM dbo.sysjobservers
                 WHERE job_id = @JobId AND server_id <> 0)
BEGIN
    SET @ObservedState = 'Conflicting';
    SET @Reason = N'Identity, owner, command target, unrelated or multiple steps, or server bindings conflict with the canonical job.';
END
ELSE IF (SELECT COUNT_BIG(*) FROM dbo.sysjobsteps
         WHERE job_id = @JobId AND step_name = @ExpectedStepName
           AND subsystem = N'TSQL' AND database_name = N'master'
                     AND command = @ExpectedCommand
                       AND database_user_name IS NULL
                     AND retry_attempts = 3 AND retry_interval = 1
                       AND on_success_action = 1 AND on_success_step_id = 0
                       AND on_fail_action = 2 AND on_fail_step_id = 0
                       AND output_file_name IS NULL AND flags = 0
                       AND proxy_id IS NULL AND os_run_priority = 0
                       AND cmdexec_success_code = 0
                       AND additional_parameters IS NULL) = 1
     AND (SELECT COUNT_BIG(*) FROM dbo.sysjobschedules WHERE job_id = @JobId) = 1
     AND (SELECT COUNT_BIG(*)
          FROM dbo.sysjobschedules AS js
          JOIN dbo.sysschedules AS s ON s.schedule_id = js.schedule_id
          WHERE js.job_id = @JobId AND s.enabled = 1
                                                AND s.name = @ScheduleName
                        AND s.freq_type = @ScheduleFreqType
                        AND s.freq_interval = @ScheduleFreqInterval
                        AND s.freq_subday_type = @ScheduleFreqSubdayType
            AND s.freq_subday_interval = @FrequencyMinutes
                        AND s.freq_recurrence_factor = @ScheduleFreqRecurrenceFactor
                        AND s.active_start_date = @ScheduleStartDate
                        AND s.active_end_date = @ScheduleEndDate
                        AND s.active_start_time = @ScheduleStartTime
                                                AND s.active_end_time = @ScheduleEndTime
                                                AND NOT EXISTS (
                                                        SELECT 1
                                                        FROM dbo.sysjobschedules AS other_js
                                                        WHERE other_js.schedule_id = js.schedule_id
                                                            AND other_js.job_id <> @JobId
                                                )) = 1
     AND (SELECT COUNT_BIG(*) FROM dbo.sysjobservers
          WHERE job_id = @JobId AND server_id = 0) = 1
    SET @ObservedState = 'Matching';
ELSE
    SET @ObservedState = 'Partial';

IF @MutationApplied = 1 OR @RequestedAction = 'Inspect'
BEGIN
    SELECT @ObservedState AS observed_state, @Reason AS reason,
           @JobName AS job_name, @JobId AS job_id,
           @SourceServerIdentity AS source_server_identity,
           @JobIdentityDigest AS job_identity_digest;
    IF @MutationApplied = 1 AND @ObservedState <> 'Matching'
        THROW 51006, 'SQL Agent reconciliation postcondition failed.', 1;
    RETURN;
END;

IF @RequestedAction = 'Create'
BEGIN
    IF @ObservedState <> 'Absent'
        THROW 51007, 'Create requires authoritative Absent state.', 1;
    IF @DisclaimerAccepted <> 1 OR @TypedCreationConfirmed <> 1
        THROW 51008, 'Disclaimer acceptance and typed creation confirmation are required.', 1;

    BEGIN TRANSACTION;
    EXEC dbo.sp_add_job @job_name = @JobName, @enabled = 0,
         @owner_login_name = @ExpectedOwner,
         @description = @ExpectedDescription, @job_id = @JobId OUTPUT;
    GOTO ConvergeOwnedJob;
END;

IF @RequestedAction = 'Repair'
BEGIN
    IF @ObservedState <> 'Partial'
        THROW 51009, 'Repair requires authoritative Partial state.', 1;

    BEGIN TRANSACTION;
    GOTO ConvergeOwnedJob;
END;

GOTO AfterConvergence;

ConvergeOwnedJob:
/* Revalidate ownership and repair shape under transaction locks immediately
   before mutation. A stale Partial observation never authorizes mutation. */
IF NOT EXISTS (
    SELECT 1
    FROM dbo.sysjobs WITH (UPDLOCK, HOLDLOCK)
    WHERE job_id = @JobId
      AND description = @ExpectedDescription
      AND SUSER_SNAME(owner_sid) = @ExpectedOwner
)
    THROW 51011, 'Job ownership changed before reconciliation.', 1;
IF (SELECT COUNT_BIG(*)
    FROM dbo.sysjobsteps WITH (UPDLOCK, HOLDLOCK)
    WHERE job_id = @JobId) > 1
    THROW 51012, 'Multiple job steps block reconciliation.', 1;
IF (SELECT COUNT_BIG(*)
    FROM dbo.sysjobsteps WITH (UPDLOCK, HOLDLOCK)
    WHERE job_id = @JobId) = 1
   AND NOT EXISTS (
       SELECT 1
       FROM dbo.sysjobsteps WITH (UPDLOCK, HOLDLOCK)
       WHERE job_id = @JobId
         AND step_name = @ExpectedStepName
         AND subsystem = N'TSQL'
   )
    THROW 51013, 'An unrelated job step blocks reconciliation.', 1;
IF EXISTS (
    SELECT 1
    FROM dbo.sysjobsteps WITH (UPDLOCK, HOLDLOCK)
    WHERE job_id = @JobId
      AND step_name = @ExpectedStepName
      AND subsystem = N'TSQL'
      AND (
          (CHARINDEX(N'BACKUP LOG ', UPPER(command)) > 0
           AND CHARINDEX(UPPER(N'BACKUP LOG ' + QUOTENAME(@DatabaseName)), UPPER(command)) = 0)
          OR
          (CHARINDEX(N'DECLARE @BACKUPPATH NVARCHAR(4000) = N''', UPPER(command)) > 0
           AND CHARINDEX(@ExpectedBackupPathDeclaration, command) = 0)
      )
)
    THROW 51015, 'A canonical-named step targets another database or backup folder.', 1;
IF EXISTS (
    SELECT 1
    FROM dbo.sysjobservers WITH (UPDLOCK, HOLDLOCK)
    WHERE job_id = @JobId AND server_id <> 0
)
    THROW 51014, 'A nonlocal job-server binding blocks reconciliation.', 1;

/* Lock and validate schedule identity and bindings before the first mutation. */
SET @ScheduleName = LEFT(
    N'LRS every 10 minutes - ' + CONVERT(nvarchar(36), @JobId), 128);
SET @CanonicalScheduleId = NULL;
SELECT @CanonicalScheduleId = schedule_id
FROM dbo.sysschedules WITH (UPDLOCK, HOLDLOCK)
WHERE name = @ScheduleName;
SELECT @LockedScheduleBindingCount = COUNT_BIG(*)
FROM dbo.sysjobschedules WITH (UPDLOCK, HOLDLOCK)
WHERE job_id = @JobId
   OR (@CanonicalScheduleId IS NOT NULL
       AND schedule_id = @CanonicalScheduleId);
IF @CanonicalScheduleId IS NOT NULL
   AND EXISTS (SELECT 1 FROM dbo.sysjobschedules
               WHERE schedule_id = @CanonicalScheduleId
                 AND job_id <> @JobId)
    THROW 51010, 'Canonical migration schedule is shared by another job.', 1;

IF NOT EXISTS (SELECT 1 FROM dbo.sysjobsteps WHERE job_id = @JobId)
    EXEC dbo.sp_add_jobstep @job_id = @JobId,
         @step_name = @ExpectedStepName, @subsystem = N'TSQL',
         @database_name = N'master', @database_user_name = NULL,
         @command = @ExpectedCommand,
         @retry_attempts = 3, @retry_interval = 1,
         @on_success_action = 1, @on_success_step_id = 0,
         @on_fail_action = 2, @on_fail_step_id = 0,
         @output_file_name = NULL, @flags = 0, @proxy_id = NULL,
         @os_run_priority = 0, @cmdexec_success_code = 0,
         @additional_parameters = NULL;
ELSE IF NOT EXISTS (SELECT 1 FROM dbo.sysjobsteps
                    WHERE job_id = @JobId
                      AND step_name = @ExpectedStepName
                      AND subsystem = N'TSQL'
                      AND database_name = N'master'
                      AND command = @ExpectedCommand
                      AND database_user_name IS NULL
                      AND retry_attempts = 3
                      AND retry_interval = 1
                      AND on_success_action = 1
                      AND on_success_step_id = 0
                      AND on_fail_action = 2
                      AND on_fail_step_id = 0
                      AND output_file_name IS NULL
                      AND flags = 0
                      AND proxy_id IS NULL
                      AND os_run_priority = 0
                      AND cmdexec_success_code = 0
                      AND additional_parameters IS NULL)
BEGIN
    SELECT @ExistingStepId = step_id
    FROM dbo.sysjobsteps
    WHERE job_id = @JobId;
    /* sp_update_jobstep treats NULL parameters as unchanged. Delete and add the
       sole proven-canonical step inside this transaction to clear nullable drift. */
    EXEC dbo.sp_delete_jobstep @job_id = @JobId,
         @step_id = @ExistingStepId;
    EXEC dbo.sp_add_jobstep @job_id = @JobId,
         @step_name = @ExpectedStepName, @subsystem = N'TSQL',
         @database_name = N'master', @database_user_name = NULL,
         @command = @ExpectedCommand,
         @retry_attempts = 3, @retry_interval = 1,
         @on_success_action = 1, @on_success_step_id = 0,
         @on_fail_action = 2, @on_fail_step_id = 0,
         @output_file_name = NULL, @flags = 0, @proxy_id = NULL,
         @os_run_priority = 0, @cmdexec_success_code = 0,
         @additional_parameters = NULL;
END;

DECLARE attached_schedules CURSOR LOCAL STATIC FORWARD_ONLY READ_ONLY FOR
    SELECT schedule_id FROM dbo.sysjobschedules WHERE job_id = @JobId;
OPEN attached_schedules;
FETCH NEXT FROM attached_schedules INTO @AttachedScheduleId;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC dbo.sp_detach_schedule @job_id = @JobId,
         @schedule_id = @AttachedScheduleId, @delete_unused_schedule = 0;
    FETCH NEXT FROM attached_schedules INTO @AttachedScheduleId;
END;
CLOSE attached_schedules;
DEALLOCATE attached_schedules;

IF @CanonicalScheduleId IS NULL
    EXEC dbo.sp_add_schedule @schedule_name = @ScheduleName,
         @enabled = 1, @freq_type = @ScheduleFreqType,
         @freq_interval = @ScheduleFreqInterval,
         @freq_subday_type = @ScheduleFreqSubdayType,
         @freq_subday_interval = @FrequencyMinutes,
         @freq_recurrence_factor = @ScheduleFreqRecurrenceFactor,
         @active_start_date = @ScheduleStartDate,
         @active_end_date = @ScheduleEndDate,
         @active_start_time = @ScheduleStartTime,
         @active_end_time = @ScheduleEndTime,
         @schedule_id = @CanonicalScheduleId OUTPUT;
ELSE
    EXEC dbo.sp_update_schedule @schedule_id = @CanonicalScheduleId,
         @enabled = 1, @freq_type = @ScheduleFreqType,
         @freq_interval = @ScheduleFreqInterval,
         @freq_subday_type = @ScheduleFreqSubdayType,
         @freq_subday_interval = @FrequencyMinutes,
         @freq_recurrence_factor = @ScheduleFreqRecurrenceFactor,
         @active_start_date = @ScheduleStartDate,
         @active_end_date = @ScheduleEndDate,
         @active_start_time = @ScheduleStartTime,
         @active_end_time = @ScheduleEndTime;
EXEC dbo.sp_attach_schedule @job_id = @JobId,
     @schedule_id = @CanonicalScheduleId;

IF NOT EXISTS (SELECT 1 FROM dbo.sysjobservers WHERE job_id = @JobId)
    EXEC dbo.sp_add_jobserver @job_id = @JobId;
COMMIT TRANSACTION;
SET @MutationApplied = 1;
GOTO Reclassify;

AfterConvergence:

IF @ObservedState <> 'Matching'
    THROW 51016, 'Enable/start/disable requires authoritative Matching state.', 1;
IF @RequestedAction = 'EnableAndStart'
BEGIN
    EXEC dbo.sp_update_job @job_id = @JobId, @enabled = 1;
    EXEC dbo.sp_start_job @job_id = @JobId;
END
ELSE IF @RequestedAction = 'StopAndDisable'
BEGIN
    IF EXISTS (
        SELECT 1
        FROM dbo.sysjobactivity
        WHERE session_id = @AgentSessionId
          AND job_id = @JobId
          AND start_execution_date IS NOT NULL
          AND stop_execution_date IS NULL
    )
        EXEC dbo.sp_stop_job @job_id = @JobId;
    EXEC dbo.sp_update_job @job_id = @JobId, @enabled = 0;
END
ELSE IF @RequestedAction = 'Disable'
    EXEC dbo.sp_update_job @job_id = @JobId, @enabled = 0;

SELECT @ObservedState AS observed_state, @JobName AS job_name, @JobId AS job_id,
       @SourceServerIdentity AS source_server_identity,
       @JobIdentityDigest AS job_identity_digest,
       j.enabled,
       CASE WHEN ja.start_execution_date IS NOT NULL
                  AND ja.stop_execution_date IS NULL THEN 1 ELSE 0 END AS is_running
FROM dbo.sysjobs AS j
LEFT JOIN dbo.sysjobactivity AS ja
  ON ja.job_id = j.job_id AND ja.session_id = @AgentSessionId
WHERE j.job_id = @JobId;
