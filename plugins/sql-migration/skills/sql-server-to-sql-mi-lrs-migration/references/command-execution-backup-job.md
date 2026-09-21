# Windows LRS managed identity automation — SQL Agent orchestration

## Contents

- [5. Single canonical SQL Agent job reconciler](#5-single-canonical-sql-agent-job-reconciler)
- [Test run and continuous monitoring](#test-run-and-continuous-monitoring)

Part of the command-execution reference set for this skill. See SKILL.md for the
workflow phases.

## 5. Single canonical SQL Agent job reconciler

This entire reference applies only when `Mode = Continuous`. Before rendering or
executing the reconciler, require `BackupFrequencyMinutes = 10`. When
`Mode = Autocomplete`, do not inspect for adoption, create, repair, enable, start,
stop, or disable an LRS migration job; the complete approved backup chain is
frozen before replay starts and no later backup may be produced by this workflow.

[canonical-sql-agent-job-reconciler.sql](canonical-sql-agent-job-reconciler.sql)
is the single source of truth and the **only implementation** of all SQL Agent job
metadata and lifecycle logic:

- deterministic job name;
- job description;
- job-step name and command;
- ten-minute schedule and schedule name;
- a fresh filename generated inside every step attempt from UTC plus a GUID, with
   `WITH INIT` so a retry cannot append another backup set to prior media;
- authoritative `Absent` / `Matching` / `Partial` / `Conflicting` classifier;
- create, bounded repair, enable/start, stop-and-disable, and disable operations.

A uniquely identified workflow-owned job is `Partial` when it has no step or one
step with the canonical step name and `TSQL` subsystem but repairable drift such
as a malformed command, wrong execution database, retry settings, schedule, or
local binding. This includes the known command variants that fail with SQL errors
102, 137, or 319. A job with an unrelated step or multiple steps is
`Conflicting` and must not be mutated. Command equality alone is not the ownership
or uniqueness boundary.

Do not copy, paraphrase, reconstruct, or independently derive any of those values
in this file, SKILL.md, another reference, PowerShell, or an ad-hoc SQL block.
Always render and execute the canonical file in full, substituting only its declared
scalar placeholders after validation and SQL-literal escaping. Keep the rendered
script in memory and save only a sanitized copy in diagnostics.

Never use SQL login authentication or a SQL login as job owner. Treat source
authentication and SQL Agent job ownership as separate decisions. For
`WindowsIntegrated`, the direct current Windows login may be offered as the
default only when it is an enabled `WINDOWS_LOGIN`. For `EntraInteractive`, or
when the Windows user connects through a group, discover enabled direct Windows
login candidates and require the user to approve one distinct `SqlAgentJobOwner`.
Never use `ORIGINAL_LOGIN()` as the only owner source, never use a Windows group
or an external `E`/`X` principal as the owner, and never select or change an owner
silently.

Run this read-only candidate query through the authenticated source connection.
Require a successful complete result set, display the returned names in a
structured single-select picker, and set `$approvedSqlAgentJobOwner` to the exact
selected `name` only after the user confirms it. An empty result blocks Continuous
mode. Do not infer a candidate from group membership or accept free text when the
query succeeds:

```sql
SELECT name, type_desc, is_disabled
FROM sys.server_principals
WHERE type = 'U'
   AND type_desc = N'WINDOWS_LOGIN'
   AND is_disabled = 0
   AND name NOT LIKE N'##%'
ORDER BY name;
```

Before rendering the canonical reconciler, validate the approved owner and the
caller's ability to assign it. Render only the two scalar placeholders below as
escaped SQL literals. This query is inventory only and must return exactly one
eligible row; denied metadata or impersonation is a blocker, not evidence of
eligibility:

```sql
DECLARE @ApprovedJobOwner sysname = N'<approved-windows-job-owner>';
DECLARE @DatabaseName sysname = N'<source-database>';
DECLARE @OwnerCanBackup bit = 0;
DECLARE @Impersonating bit = 0;

IF NOT EXISTS (
   SELECT 1
   FROM sys.server_principals
   WHERE name = @ApprovedJobOwner
     AND type = 'U'
     AND type_desc = N'WINDOWS_LOGIN'
     AND is_disabled = 0
)
   THROW 51100, 'Approved SQL Agent owner is not an enabled direct Windows login.', 1;

IF ISNULL(IS_SRVROLEMEMBER(N'sysadmin'), 0) <> 1
   THROW 51101, 'The current caller cannot assign the approved SQL Agent owner.', 1;

BEGIN TRY
   EXECUTE AS LOGIN = @ApprovedJobOwner;
   SET @Impersonating = 1;
   SET @OwnerCanBackup = HAS_PERMS_BY_NAME(@DatabaseName, N'DATABASE', N'BACKUP DATABASE');
   REVERT;
   SET @Impersonating = 0;
END TRY
BEGIN CATCH
   IF @Impersonating = 1
      REVERT;
   THROW;
END CATCH;

IF @OwnerCanBackup <> 1
   THROW 51102, 'Approved SQL Agent owner cannot back up the selected database.', 1;

SELECT @ApprovedJobOwner AS approved_job_owner,
      N'WINDOWS_LOGIN' AS owner_type,
      @OwnerCanBackup AS can_backup_database;
```

The Database Engine service account—not the interactive login or job owner—must
separately have write access to the approved local backup root. Pass the validated
`SqlAgentJobOwner` as the canonical file's `ExpectedOwner`.

### Required invocation sequence

1. Render the canonical reconciler with `RequestedAction = Inspect`, both consent
   bits set to `0`, and the validated scalar context.
2. Consume every required inventory result set. If execution fails, metadata is
   denied, a result is missing, or evidence is ambiguous, fail closed as
   `Blocked — backup automation inventory incomplete`.
3. Apply these gates:
   - An exact-name job must be classified; never create another job or rename it.
   - `Matching` is reused.
    - Only a workflow-owned `Partial` job with zero steps or exactly one canonical-
       name `TSQL` step may use `RequestedAction = Repair`; its command may be the
       malformed 102/137/319 variant that repair is intended to replace.
   - `Conflicting`, including owner or description mismatch, is never mutated.
   - An active native or Agent backup for the selected database blocks mutation
     until it completes and `Inspect` is rerun.
   - Another enabled job definition targeting the database, or recurring backup
     history not explained by reviewed definitions, blocks creation for manual
     review. Do not disable, edit, adopt, or schedule around it.
   - Other server-wide active backups are displayed as capacity warnings.
4. For `Absent`, display the sanitized review table and obtain the two independent
   gates below. Then rerun `Inspect`; any state or context change invalidates the
   creation confirmation.
5. Invoke the same canonical file with `RequestedAction = Create`. Creation is
   transactional and must return `Matching` after its internal reclassification.
6. For a workflow-owned `Partial`, invoke the same file with `RequestedAction =
   Repair`. It may converge only the canonical step, private schedule, and local
   server binding, and must return `Matching`.
7. Invoke `EnableAndStart` only from `Matching`. A successful start request is not
   completion evidence.
8. At cutover, invoke `StopAndDisable`, wait for its returned `is_running = 0` and
   `enabled = 0`, and recheck immediately before tail backup. Invoke `Disable` for
   cleanup compatibility only. Do not implement separate stop/disable commands in
   cutover or cleanup references.

### Review and independent confirmations

For an `Absent` job, display:

| Field | Required value |
| --- | --- |
| Source | SQL Server instance and source database |
| Job | Name returned by the canonical `Inspect` result |
| Owner | Separately approved and validated direct Windows `SqlAgentJobOwner` |
| Initial state | Disabled |
| Step | Sanitized canonical command returned by the rendered reconciler |
| Local destination | Approved database backup folder |
| Schedule | Enabled, all day, every 10 minutes |
| Job server | Local SQL Server |

First require the strong disclaimer acceptance from SKILL.md. Then require the
user to manually type `CREATE LRS JOB <displayed-job-name>` exactly. Do not prefill
it, make it selectable, generate it on the user's behalf, or accept `yes`, a button
click, partial text, or case-insensitive text. Set
`SqlAgentJobCreationConsentGranted = true` only for an exact match tied to every
reviewed value. Pass `DisclaimerAccepted = 1` and `TypedCreationConfirmed = 1` to
`Create` only after both gates pass.

A rejection or mismatch performs no mutation and sets `Blocked — SQL Agent job
creation not approved`. Confirmation is never needed for `Matching`; bounded
repair remains covered by preparation consent and the accepted disclaimer unless
its context changes.

### Re-entry evidence

The canonical reconciler must be validated in a disposable nonproduction SQL Agent
environment before use. Record executable test evidence for every row; prose is
not evidence:

| Initial state | Action | Required authoritative result |
| --- | --- | --- |
| `Absent` | `Create` after both gates | `Matching`, same returned job ID, initially disabled |
| `Matching` | `Inspect` | No mutation; same job ID and `Matching` |
| `Partial` with missing step | `Repair` | One canonical step and `Matching` |
| `Partial` with malformed step | `Repair` | One canonical step and `Matching` |
| `Partial` with missing/conflicting schedule | `Repair` | One private enabled all-day ten-minute schedule and `Matching` |
| `Partial` with missing binding | `Repair` | One local binding and `Matching` |
| `Conflicting` or owner mismatch | `Repair` | Rejected with no mutation |
| Injected failure during `Create` | `Create` | Transaction rollback; `Inspect` returns `Absent` |
| Repeated `Repair` | `Repair`, then `Repair` again | Second call rejected because state is already `Matching`; no drift |

If this evidence is unavailable for the deployed canonical file version, stop as
`Blocked — no tested idempotent reconciler`.

## Test run and continuous monitoring

After `EnableAndStart`, require all of the following before reporting success:

- a successful completed job-level history row;
- a new log-backup row in `msdb.dbo.backupset` for the selected database;
- the expected immutable local `.trn` file;
- successful local backup verification and checksum evidence;
- successful immutable AzCopy upload and Blob listing evidence.

SQL Agent's `STRTDT` and `STRTTM` tokens identify the job execution, not an
individual step retry. Do not use them as the uniqueness boundary. The canonical
step generates its UTC-and-GUID filename when each attempt begins and uses
`WITH INIT`; UTC provides readable ordering context, while the GUID distinguishes
retries that share the same job start time. A retry must never append a second
backup set to an existing `.trn` file.

Use the job ID returned by the canonical reconciler for all history and activity
queries. Never reimplement or derive the job name in monitoring code.

Query the three most recent completed job-level outcomes (`step_id = 0`) by that
validated job ID. Three rows whose `run_status = 0` are three consecutive failures.
On that condition, immediately report `Blocked` with the database, frequency,
timestamps, sanitized messages, last successful run, and exact next action. Stop
waiting for files, uploading, and advancing LRS for that database. Do not disable
or delete the job automatically.

`Wait-NewSuccessfulLogBackup` must inspect every new completed job-level outcome;
it must not filter only for successful runs. Any intervening success resets the
consecutive-failure count. Return a backup only after the completed job, backup
metadata, local artifact, checksum, and immutable-name evidence agree.

At cutover, stop and disable through `RequestedAction = StopAndDisable`, retain the
returned job ID, and require `enabled = 0` plus `is_running = 0` before taking the
final log backup. Cleanup may use `Disable`. Both use the same canonical file; no
other file may contain another job-name, command, schedule, classifier, or repair
implementation.
