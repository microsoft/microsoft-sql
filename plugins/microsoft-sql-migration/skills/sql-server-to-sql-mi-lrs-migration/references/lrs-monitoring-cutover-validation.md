# LRS monitoring, cutover, validation, and completion

## Contents

- [Phase 4 - Validate Blob chain and start LRS](#phase-4---validate-blob-chain-and-start-lrs)
- [Phase 5 - Monitor continuous replay](#phase-5---monitor-continuous-replay)
- [Phase 6 - Continuous-mode cutover and validation](#phase-6---continuous-mode-cutover-and-validation)
- [Destructive stop guardrail](#destructive-stop-guardrail)
- [Phase 7 - Final summary and switch](#phase-7---final-summary-and-switch)
- [Result format](#result-format)
- [References](#references)

Part of the workflow reference set for this skill. See SKILL.md for Phase 0 through Phase 3 and the overall workflow entry point.

Never connect to either the source or target with SQL login/SQL authentication.
Do not request, accept, retrieve, or use SQL passwords or SQL credentials. Use
only Windows Integrated authentication or Microsoft Entra authentication supported
by the workflow: the source supports Windows Integrated or Entra interactive
authentication, and the target supports Entra authentication only.

## Phase 4 - Validate Blob chain and start LRS

LRS applies the target backup chain in `NORECOVERY` semantics: while replay is in
progress, the target database remains in `RESTORING` and is unavailable for user
access. In `Continuous` mode, recover it only at confirmed cutover by calling
`Complete-AzSqlInstanceDatabaseLogReplay` with the exact final backup name shown
in and approved by the cutover confirmation. Set that value manually only after
consent. In `Autocomplete` mode, manually set `AutoCompleteRestore = true` and the
user-supplied `LastBackupName` only after the preparation review receives
affirmative consent. It recovers the target only after LRS restores that exact
file. Never recover the target between backup files.

- Upload every completed local backup with `AzCopy` using the attended Microsoft
  Entra session and `--overwrite=false`.
- Use one database-named folder per database and mirror the local folder name in
  Blob Storage. Never flatten files into the container root or reuse another
  database's folder.
- Compare local and Blob file sizes and the manifest. For integrity evidence, use
  a downloaded sample/full verification process approved by the DBA; Blob ETags
  are not general-purpose file checksums.
- URL-encode reserved characters. Prefer names containing only letters, numbers,
  hyphens, underscores, and periods.
- Freeze the manifest used to start autocomplete. For continuous mode, append new
  entries without altering or deleting prior files.

Start LRS only after preparation consent and after a verified full baseline and
the first required log chain are visible in Blob Storage. For `Autocomplete`, do
not construct or submit `AutoCompleteRestore` or `LastBackupName` before that
consent. Use the exact `-StorageContainerUri` parameter; never use `-StorageUri`.
Validate the parameter against the installed cmdlet before invocation. Also use
`-StorageContainerIdentity ManagedIdentity`. A SAS/key/secret parameter is a hard
failure.

Before every retry or resumed phase, treat the saved checkpoint only as a claim
about the previous run. Acquire the target-database lock, then classify each
relevant resource from its authoritative source as `Absent`, `Matching`,
`Partial`, `Conflicting`, or `Completed`. Query SQL Agent catalogs for the job,
step, schedule, owner, enabled state, and server binding only in `Continuous`
mode; Azure Resource Manager for exact RBAC; SQL MI `sys.credentials` for the URL-scoped credential; source
`msdb` plus local and Blob listings for the backup chain; and the Azure LRS API
for replay state. Create only `Absent` resources, reuse only verified `Matching`
resources, repair only an approved `Partial` resource, advance a `Completed`
resource, and stop on `Conflicting` state. Verify every mutation from the same
authoritative source before updating the checkpoint. Never infer reusable state
from a local operation ID, manifest cursor, PowerShell job, elapsed time, or a
successful create/start request alone.

### Autocomplete completion path

Autocomplete does not enter Phase 5 or Phase 6. It has no recurring migration
job and no per-log cutover decision. Before start, require
`BackupFrequencyMinutes = $null`, freeze the verified manifest, and prove that
the manually approved `LastBackupName` is its unique final entry and is already
present at the exact Blob URL. After start, perform read-only polling of the
existing LRS operation until `Completed` or a bounded timeout/error. Success
requires `LastRestoredFileName` to equal that approved name and the target
database to be online and connectable. Any local or Blob addition after the
manifest was frozen is a conflict and blocks completion; do not create another
backup, start another replay, or fall back to continuous mode.

## Phase 5 - Monitor continuous replay

Use the executable state machine in
[lrs-monitor-cutover-state-machine.ps1](lrs-monitor-cutover-state-machine.ps1);
the prose in this file is policy, not a substitute implementation. Run a cycle
immediately after LRS starts and then every `BackupFrequencyMinutes` (10 minutes).
Each cycle inventories stable verified source files and the exact Blob prefix,
rejects duplicates, changed/partial files, and unexplained Blob files, uploads
only missing files with AzCopy `--overwrite=false`, verifies exact name and size,
queries LRS, and atomically checkpoints. After each cycle offer only `monitor`
(sleep until the next interval) or `cutover` (enter Phase 6). Never default to
cutover because of elapsed time or inactivity.

Immediately before start, repeat target-name, identity-access, folder-layout, and
backup-chain checks. Display the exact resource group, SQL MI, target database,
mode, storage URI, collation, and final file when applicable. If these values still
match the preparation summary, start LRS without another prompt. A changed target,
storage scope, mode, or identity requires a revised summary and consent.

Use `-AsJob` for continuous-mode automation, then poll Azure LRS state with
`Get-AzSqlInstanceDatabaseLogReplay`; do not infer state from the local PowerShell
job alone.

Monitor and record:

- LRS state and API operation state.
- `CreationDate`, `LastRestoredFileName`, `LastRestoredFileTime`,
  `FullBackupSets`, `DiffBackupSets`, `LogBackupSets`, and file counts returned by
  the LRS API. Map `LastRestoredFileName` to the state-machine adapter's normalized
  `LastRestoredFile` field.
- Backup/upload/replay lag against the cutover threshold.
- SQL MI storage/capacity health and maintenance events.
- Errors from `Get-AzSqlInstanceOperation` without exposing sensitive values.

Treat an immediate LRS `Blocked` status accompanied by Blob `AccessDenied`,
authorization failure, or equivalent managed-identity read denial as possible
RBAC propagation delay only when the expected SQL MI principal and exact
container-scoped `Storage Blob Data Reader` assignment were already verified.
Immediately report the `Blocked` status and sanitized access error. Then wait and
re-query `Get-AzSqlInstanceDatabaseLogReplay` once per minute, at most five times.
Do not poll more frequently and do not perform a sixth retry. Do not restart LRS,
reassign the role repeatedly, broaden its scope, grant a broader role, or request
manual intervention during these five checks. If LRS transitions to `Waiting` or
another documented healthy active state, report `Recovered`, elapsed time, and
the new state, then continue. If it remains `Blocked` after the fifth check,
report that managed-identity RBAC propagation did not complete, including the SQL
MI principal ID, exact container scope, role name, final LRS status, and sanitized
Blob authorization error. Save the current database/LRS checkpoint, provide the
exact manual RBAC verification/assignment steps, and pause as `Blocked — awaiting
manual RBAC`. When the user returns, verify the exact assignment and query the
existing LRS operation; do not restart LRS. Continue monitoring when it becomes
healthy. If it changes to `Failed` or shows a nonauthorization error before the
fifth check, report that actual error immediately and exit without waiting for the
remaining checks.

Pause and investigate a stalled or failed replay. Never manufacture a missing log
backup or continue from an invalid chain.

For continuous mode, run this decision loop for every successful execution of the
current database's LRS log-backup job:

1. Detect a new successful SQL Agent job execution and resolve the exact log file
  from backup metadata; do not treat `sp_start_job` success as backup completion.
2. Verify the log backup with checksum and append its LSNs, completion time, size,
  and immutable file name to the manifest.
3. Copy only that completed local file with AzCopy using `--overwrite=false`, then
  verify its Blob size and presence.
4. Observe LRS until it reports that exact log file restored. A failed or stalled
  copy/replay blocks progress and is retried or remediated first.
5. Report the latest restored file, completion time, LSN, and replay lag in the
  current output, then continue processing log backups.

Do not open or refresh a cutover prompt after each log. Persist the last processed
SQL Agent execution and backup-set identity so polling or restart cannot process
one log file twice. Continue synchronization until the user explicitly types
`cutover`.

On entry or re-entry to continuous monitoring, rebuild the observed cursor before
waiting for another backup. Join successful SQL Agent job-level history to source
`msdb` backup-set/media metadata, enumerate the exact local database folder and
Blob database prefix, and query the existing LRS operation. Require one-to-one
immutable filenames, matching sizes, a valid database/fork and LSN chain, and no
unexpected Blob files. Set the next cursor only to the highest backup-set ID whose
file is locally verified, present in Blob, and reported restored by LRS. If the
saved cursor is ahead of observed state, points to another chain, or cannot be
reconstructed, classify it as `Conflicting` and stop. If observed state is ahead,
update the checkpoint from observed state without uploading or replaying the file
again.

## Phase 6 - Continuous-mode cutover and validation

An explicit `cutover` request opens two separate manually typed gates. First show
a strong disclaimer that cutover stops and disables the migration backup job,
takes a tail-log backup with `NORECOVERY`, leaves the source in `RESTORING`, uploads
the final file, completes LRS, and makes the target writable; rollback is separate.
Require exactly `I ACCEPT CUTOVER <source-server>/<source-database> TO
<managed-instance>/<target-database> WITH TAIL BACKUP NORECOVERY`. Then display
the source, target, latest restored log, and preallocated final backup name, and
require exactly `CUTOVER <source-server>/<source-database> TO
<managed-instance>/<target-database> FINAL <final-file>`. Do not prefill, offer as
a selectable answer, generate, or accept `yes`, buttons, partial text, or different
case. `monitor`, rejection, or no response performs no cutover mutation and leaves
the job and LRS running. No third completion confirmation is requested.

1. Enter this flow only after the explicit `cutover` request and both typed gates.
2. Invoke the canonical SQL Agent reconciler with `StopAndDisable` for only the
  current database's migration job. Persist its prior state, verify it is disabled,
  and wait until no execution remains. Recheck immediately before the tail backup
  so no new scheduled log backup can overlap cutover.
3. Query active user transactions for the current source database. If none exist,
  proceed. If inspection is unauthorized, say that active transactions could not
  be checked. If active transactions exist, show sanitized session/start-time
  details and offer `Wait and retry`, `Proceed with final log backup`, or `Cancel
  cutover`. Never kill or roll back transactions. Cancellation re-enables the
  recurring backup schedule after taking and replaying one normal log backup
  without `NORECOVERY`, and leaves LRS running. Verify and report that the source
  remains in write mode and can receive new changes.
4. Before the source becomes unavailable, establish the cutoff validation
  reference. When application traffic is authoritatively drained and no active
  transaction remains, capture two stable, complete, profile-compatible source
  inventory and `COUNT_BIG` passes, schema fingerprints, database identity, and
  timestamps into an immutable evidence package. Keep traffic drained through the
  tail backup and bind that package to the produced final file, completion time,
  and LSN. If quiescence cannot be proven—including an explicit proceed while an
  active transaction remains—require an already approved destination for a
  separate validation copy restored through the final tail-log LSN. Record that
  plan before `NORECOVERY`; without either reference, block cutover.
5. Take a new, uniquely named tail-log backup with `COMPRESSION, CHECKSUM,
  NORECOVERY` using the exact final file name approved in the confirmation, and
  append its metadata to the manifest. An explicit `Proceed`
  permits the backup while transactions remain active; uncommitted work is rolled
  back when the target is recovered and is not migrated as committed data. Verify
  that the source enters `RESTORING`; failure to do so blocks LRS completion.
6. AzCopy only that final local file with `--overwrite=false` and verify the
  uploaded Blob. Never complete LRS before this succeeds.
7. Record the final backup completion time and LSN as the migration cutoff, plus
  the active-transaction check result and any explicit proceed decision.
8. Wait until LRS reports that exact final file restored.
9. Verify the target still matches the approved cutover context, display the final
  file and cutoff as progress, require the produced file name to equal the
  approved final name, then manually set that exact value in
  `Complete-AzSqlInstanceDatabaseLogReplay -LastBackupName <approved-file>`.
  Never infer or substitute another backup name after consent.
10. Poll until completion and database availability. Do not add later backups to
  the LRS folder. The source remains in `RESTORING`; bringing it back online is a
  separate, explicitly approved rollback operation.
  An `ONLINE` target is `Conflicting` unless the source is `RESTORING`, the exact
  frozen tail backup and uploaded Blob are verified, LRS names that exact file as
  restored and reports `Completed`, and the observed SQL MI target and LRS
  operation still match the immutable approved context. Stop rather than
  advancing or authorizing application switching on any mismatch.
11. If the recorded reference type is `RestoredCutoffCopy`, restore the immutable
  chain through the exact final file to the preapproved isolated validation
  database, verify its database identity and final LSN, and mark the reference
  ready. Never query the original `RESTORING` source for validation. Invoke
  `validate-post-migration-data` only with the immutable source evidence package
  or this queryable cutoff copy.

After completion, LRS cannot resume with more differential or log backups.
Leave the migration job disabled after successful cutover. Restore its prior state
only during an explicitly approved rollback while the source is authoritatively
verified `ONLINE` and `READ_WRITE`.

### Recoverable cutover failures and resume

On a database-in-use, active-job timeout, missing permission, inaccessible backup
folder, or unexpected source-state failure, atomically checkpoint
`AwaitingManualIntervention`, preserve evidence, and provide these context-filled
steps for the user to perform outside the workflow in SSMS or sqlcmd:

1. Connect to the named source with the same approved Windows or Entra identity;
  never use SQL authentication.
2. Review Agent activity and backup history. Stop and disable only the validated
  migration job through the canonical reconciler.
3. Drain application traffic and close connections through the application or DBA
  change process. Do not have this workflow issue `KILL`, `SINGLE_USER`, or
  `ROLLBACK IMMEDIATE`.
4. Correct the reported backup permission or SQL Server service-account folder
  access. Preserve the source, final file, Blob chain, manifest, and checkpoint;
  do not complete LRS manually.
5. Type exactly `CUTOVER REMEDIATION COMPLETE <source-database>` to resume.

After that phrase, requery every authoritative postcondition and resume from the
first unmet state. Never blindly repeat tail backup, upload, or LRS completion.

### Validate and advance the queue

After the database is online and the cutoff reference is ready, invoke
`validate-post-migration-data` with profile
`RowCount`; do not ask which validation profile to use. For `Continuous`, keep the
SQL Agent backup job disabled. For `Autocomplete`, do not inspect or mutate Agent.
For a Continuous cutover whose original source is `RESTORING`, pass the immutable
cutoff evidence package or separately restored cutoff-copy connection and mark the
original source connection unavailable. The validator must not open the restoring
source database.
Advance to the next queue item only when LRS completion and target availability
are proven and validation returns a mode-permitted status. `Continuous` permits
`Pass` or `Ready with conditions` with no failed checks. `Autocomplete` permits
only `Pass`, and additionally requires proven source quiescence or a
cutoff-consistent reference, exact validation of the approved final backup name,
completion time, and LSN, verified final Blob and exact LRS restore evidence, and
proof that no source write occurred after that backup. If any Autocomplete gate
is missing or conflicting, persist the item as `Blocked`, never `Completed`, and
do not advance the queue.
On failure,
stop the queue and preserve source, job history, Blob files, manifest, and LRS
diagnostics. Never skip ahead automatically.

## Destructive stop guardrail

`Stop-AzSqlInstanceDatabaseLogReplay` deletes the restoring database and cannot be
resumed. Never use it as pause or retry. Before stop, require typed approval that
includes the SQL MI and database names, explain that replay restarts from the full
backup, capture diagnostics and current state, and verify the source and complete
backup chain remain available. If approved, stop only that LRS restore and then
disable only its source SQL Agent backup job when the mode is `Continuous`. For
`Autocomplete`, stopping LRS performs no SQL Agent inspection or mutation.
Perform no other cleanup mutation.

After a stop or any cleanup request, return a **Manual reversion report** as a
Markdown table with these columns: `Change`, `Current resource/value`, `Suggested
manual reversion`, `Impact`, `Prerequisite/check`, and `Status`. Include every
migration-created or migration-modified item, including as applicable the SQL
Agent job and schedule, local backup folder/files, Blob database folder/files or
container, SQL MI URL-scoped credential, SQL MI identity assignment, container
RBAC assignments for SQL MI and uploader, source recovery-model/ADR/Service Broker
changes, installed modules/tools, and evidence/checkpoint files. Mark the SQL
Agent job `Disabled automatically`; mark the explicitly approved LRS stop `Stopped
automatically`; mark every other row `Manual — not changed`. Use exact nonsecret
resource names and scopes, explain dependencies and data-loss consequences, and
never include secrets. Ask the user to review and perform desired rows manually;
do not execute any row in response to a general confirmation such as “cleanup.”
Each destructive manual action requires the user to perform it outside this skill.

## Phase 7 - Final summary and switch

For every queue item, invoke `validate-post-migration-data` with the target
connection/session handle and either a queryable source handle or the verified
cutoff reference, authentication routes, database
mapping, final backup cutoff/LSN, approved SQL MI adaptations, and evidence
location. Include `ReadOnlySqlConsentGranted = true` in the handoff so validation
runs all read-only queries without another prompt. Use a cutoff-consistent reference when the handoff contains one;
otherwise the validator must distinguish current writable-source observations
from the migration cutoff. For `Continuous`, later source transactions are
expected divergence, not migration failures. When exact cutoff equality cannot
be proven because source writes continued, return `Ready with conditions`, not
`Fail`, unless there is a proven cutoff, chain, target, inventory, or query
failure. For `Autocomplete`, any later source write blocks completion and queue
advancement regardless of the validator's conditional status. Do not request
credentials again or run data/schema reconciliation in this migration skill.
Record each returned validation report status and location.

Keep a supported source connection alive only while the source remains queryable;
never attempt to reuse it after Continuous cutover leaves the source `RESTORING`.
Keep the Entra-interactive target SQL connection handle alive through validation.
If target reconnection is unavoidable, reuse
the cached Entra session or open one attended Entra login. Never fall back to SQL
authentication, request a password, invoke `Connect-AzAccount` per query, or open
one login per validation pass.

Switch connection strings only through a mode-specific gate. For `Continuous`,
require the dedicated validation report to return `Pass` or `Ready with
conditions` with no failed checks, and reverify that the source remains in
`RESTORING` at the accepted tail-log cutoff and cannot accept writes. Recovering
that source is a separate rollback decision and must never happen automatically.
For `Autocomplete`, require proven source quiescence or a cutoff-consistent source
reference through the approved final backup, plus a validation result of `Pass`,
before switching. `Ready with conditions` is not sufficient for `Autocomplete`.
If the source remained writable or accepted writes after the final backup, do not
switch connection strings; report that the target may be stale and require a new
quiesced final backup/replay and successful validation first.

## Result format

Report `Ready`, `Ready with conditions`, `Blocked`, `Running`, `Completed`, or
`Failed`, plus:

| Field | Required evidence |
| --- | --- |
| Scope | Sanitized source, target, database count, mode |
| Queue | Ordered databases, current item, and per-database final status |
| Backup job | For `Continuous`, job name, local folder, Blob folder, frequency, last run, and disabled state; for `Autocomplete`, `Not applicable — frozen chain` |
| Identity | Identity type/object ID and container-scoped reader assignment |
| Chain | Manifest location, first/full and final backup, verification status |
| Replay | LRS state, last restored file, lag, operation ID |
| Cutover | For `Continuous`, read-only restriction notice, active-transaction check/decision, accepted tail-log cutoff/LSN and `NORECOVERY` source state; or rejected-cutover normal log file/LSN plus explicit source-write-mode and possible-new-changes notice. For `Autocomplete`, `Not applicable` plus frozen-manifest and approved-final-file evidence |
| Read-only SQL consent | Accepted once and reused for all queries; no secrets or tokens |
| Validation | Dedicated report status and evidence location |
| Error | Every failure's phase, database/resource, operation, sanitized message and code, diagnostics location, recovery outcome, and exact next action |
| Next action | Exact technical remediation or operation required |

Never report `Completed` until LRS completion, target availability, and a
mode-permitted post-migration validation report are confirmed. For `Continuous`, also require the
source backup job to be disabled. For `Autocomplete`, require the frozen manifest
to remain unchanged, `LastRestoredFileName` to equal the approved final file,
exact final backup and Blob evidence to match, source quiescence or a
cutoff-consistent reference to be proven, no later source writes, and validation
status `Pass`; no backup-job evidence is permitted or required.

## References

- [Migrate SQL Server databases by using Log Replay Service](https://learn.microsoft.com/en-us/azure/azure-sql/managed-instance/log-replay-service-migrate?view=azuresql&tabs=managed-identity)
- [Log Replay Service overview](https://learn.microsoft.com/en-us/azure/azure-sql/managed-instance/log-replay-service-overview)
- [BACKUP (Transact-SQL)](https://learn.microsoft.com/en-us/sql/t-sql/statements/backup-transact-sql)
- [Tail-log backups (SQL Server)](https://learn.microsoft.com/en-us/sql/relational-databases/backup-restore/tail-log-backups-sql-server)
- [Azure RBAC best practices](https://learn.microsoft.com/en-us/azure/role-based-access-control/best-practices)
- [Authorize access to blobs using Microsoft Entra ID](https://learn.microsoft.com/en-us/azure/storage/blobs/authorize-access-azure-active-directory)
