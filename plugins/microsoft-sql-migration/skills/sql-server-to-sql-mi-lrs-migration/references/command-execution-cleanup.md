# Windows LRS managed identity automation — cleanup, orchestration, and implementation pattern

## Contents

- [10. Explicit LRS stop and non-destructive cleanup](#10-explicit-lrs-stop-and-non-destructive-cleanup)
- [11. Sequential multi-database orchestration](#11-sequential-multi-database-orchestration)
- [12. Implementation pattern](#12-implementation-pattern)
- [References](#references)

Part of the command-execution reference set for this skill. See SKILL.md for the workflow phases. See also: references\command-execution-setup.md, references\command-execution-identity-setup.md, references\command-execution-backup.md, references\command-execution-backup-job.md, references\command-execution-lrs.md.

Never connect to either the source or target with SQL login/SQL authentication.
Do not request, accept, retrieve, or use SQL passwords or SQL credentials. Use
only Windows Integrated authentication or Microsoft Entra authentication supported
by the workflow: the source supports Windows Integrated or Entra interactive
authentication, and the target supports Entra authentication only.

## 10. Explicit LRS stop and non-destructive cleanup

This command deletes the restoring target database. It is intentionally excluded
from unattended scripts. Display its effect and request one direct confirmation
that includes the managed-instance and database names immediately before running
it. A general cleanup request is not sufficient approval:

```powershell
Stop-AzSqlInstanceDatabaseLogReplay `
    -ResourceGroupName $config.ResourceGroup `
    -InstanceName $config.ManagedInstance `
    -Name $config.TargetDatabase
```

Capture LRS and SQL MI operation diagnostics first. Restart requires replay from the
full backup. In `Continuous` mode only, after an approved stop, disable the
corresponding SQL Agent job using the existing canonical disable block. Do not
detach/delete the schedule or job and do not remove any other resource. If stop
is rejected, leave LRS untouched; a continuous-mode user may still explicitly
request that the migration job be disabled. `Autocomplete` must not inspect or
mutate a SQL Agent job during stop or cleanup.

For continuous-mode cleanup, the only automatic mutation is disabling the
migration SQL Agent job. Autocomplete cleanup performs no automatic SQL Agent
mutation.
Do not automatically delete the job/schedule, local or Blob backups, container,
SQL MI credential, identity, role assignments, database, state/evidence, or tools;
do not revert source configuration. Discover the migration's actual changes and
return this populated Markdown table, one row per concrete change:

| Change | Current resource/value | Suggested manual reversion | Impact | Prerequisite/check | Status |
| --- | --- | --- | --- | --- | --- |
| LRS restore | `<mi>/<database>` | Stop only after explicit named confirmation | Deletes the restoring target database; restart requires the full chain | Preserve source and verified full chain | `Stopped automatically` or `Manual — not changed` |
| SQL Agent job (`Continuous` only) | `<server>/<job>` | Keep disabled; optionally delete job and its dedicated schedule manually | Deletion removes job history and recurring backups | Confirm no migration/recovery dependency | `Disabled automatically` |
| Local backups | `<exact-local-database-folder>` | Delete manually only after retention and recovery review | Permanent loss of local restore chain | Confirm verified independent copy and retention approval | `Manual — not changed` |
| Blob backups | `<exact-container/database-folder>` | Delete files/folder manually only after retention review | Permanent loss of LRS/recovery chain | Confirm LRS is complete/stopped and backups are no longer required | `Manual — not changed` |
| SQL MI credential | `<exact-container-URL credential>` | Drop manually only when no restore uses it | Other managed-identity URL restores may fail | Check credential consumers | `Manual — not changed` |
| SQL MI reader RBAC | `<principal, role, exact container scope>` | Remove the exact assignment manually if dedicated to this migration | SQL MI loses Blob read access | Check other restores at the same container | `Manual — not changed` |
| Uploader RBAC | `<principal, role, exact container scope>` | Remove the exact assignment manually if temporary | Operator loses Blob upload access | Check other upload workloads | `Manual — not changed` |
| Source configuration | `<recovery model/ADR/Service Broker changes>` | Revert each setting manually only after workload review | May break backup chain or application behavior | DBA approval and current-state capture | `Manual — not changed` |
| Tools and evidence | `<installed tools/modules and evidence paths>` | Uninstall/delete manually if no longer needed | Removes diagnostics or affects other automation | Archive required evidence first | `Manual — not changed` |

Omit rows that provably do not apply and add rows for any other observed mutation.
After the table, ask the user to perform the desired manual reversions. Never turn
their table selections or a broad cleanup response into automated destructive
commands.

## 11. Sequential multi-database orchestration

Create an ordered queue from `SourceDatabases`. Each item owns a distinct target
name, mirrored one-level local/Blob database folder, manifest, SQL Agent job, and evidence path. Process one
item through completion before advancing:

# Orchestration pseudocode — the named functions below are implementation
# boundaries and must be implemented before this workflow can execute.
```powershell-pseudocode
foreach ($databaseItem in $databaseQueue) {
    if ($databaseItem.State -ne 'Pending') {
        throw "Queue item '$($databaseItem.SourceDatabase)' is not pending."
    }

    Test-DatabaseTechnicalPrerequisites -DatabaseItem $databaseItem
    New-InitialBackupChain -DatabaseItem $databaseItem
    Copy-InitialBackupChainToBlob `
        -DatabaseItem $databaseItem `
        -Overwrite:$false
    if ($config.Mode -eq 'Autocomplete') {
        Confirm-UploadedBackupChain `
            -DatabaseItem $databaseItem `
            -FreezeManifest `
            -ExpectedLastBackupName $config.LastBackupName
    } else {
        Confirm-UploadedBackupChain -DatabaseItem $databaseItem
        New-LrsLogBackupJob -DatabaseItem $databaseItem `
            -FrequencyMinutes $config.BackupFrequencyMinutes
    }

    Start-ManagedIdentityLogReplay -DatabaseItem $databaseItem
    if ($config.Mode -eq 'Continuous') {
        Invoke-PerLogCutoverDecisionLoop -DatabaseItem $databaseItem
    } else {
        Wait-ManagedIdentityLogReplayCompletion `
            -DatabaseItem $databaseItem `
            -ExpectedLastBackupName $config.LastBackupName
    }

    $validation = Invoke-PostMigrationValidation `
        -DatabaseItem $databaseItem `
        -CutoffReference $databaseItem.CutoffReference `
        -Profile RowCount

    if ($config.Mode -eq 'Autocomplete') {
        Assert-AutocompleteCompletionEvidence `
            -DatabaseItem $databaseItem `
            -ExpectedLastBackupName $config.LastBackupName `
            -RequireSourceQuiescenceOrCutoffReference `
            -RequireExactFinalBackupValidation `
            -RequireNoLaterSourceWrites
        if ($validation.Status -cne 'Pass') {
            $databaseItem.State = 'Blocked'
            Save-MigrationState
            throw "Autocomplete validation did not pass for '$($databaseItem.SourceDatabase)'; queue stopped."
        }
        $databaseItem.State = 'Completed'
        Save-MigrationState
    } else {
        if ($validation.Status -notin @('Pass', 'Ready with conditions')) {
            throw "Validation failed for '$($databaseItem.SourceDatabase)'; queue stopped."
        }
        Disable-LrsLogBackupJob -DatabaseItem $databaseItem
        $databaseItem.State = 'Completed'
        Save-MigrationState
    }
}
```

`Autocomplete` must enter this block with `BackupFrequencyMinutes = $null`, a
complete locally verified and uploaded chain, and a manually approved
`LastBackupName` that resolves to exactly one final manifest entry. Freezing the
manifest prohibits later backup creation or upload for that database. The
autocomplete completion monitor only queries the existing LRS operation until it
reports `Completed`, verifies `LastRestoredFileName` equals the approved final
name, proves the exact final backup name, completion time, and LSN against the
frozen manifest and verified Blob, and proves the target is online before
validation. Before completion it must also prove either source quiescence or a
cutoff-consistent validation reference and prove that no source write occurred
after the approved final backup. Missing or conflicting evidence leaves the item
`Blocked`; it must not be persisted as `Completed` or advance the queue. A
`Ready with conditions` validation result is insufficient for Autocomplete. It never creates,
repairs, enables, starts, stops, or disables a SQL Agent job and never enters the
continuous cutover state machine.

These function names are implementation boundaries, not permission to hide checks.
Each function must implement the technical checks and consent boundaries in
`SKILL.md`, persist state, and throw on failure. It must not request process
metadata or named owners. On restart, reconcile SQL, Blob, and Azure state before
resuming the current item; reconcile SQL Agent only for `Continuous`. Never mark
an item complete or advance solely from local state.

## 12. Implementation pattern

Implement production automation as an idempotent state machine rather than one
unbounded script. A persisted state is never reusable by itself. On every entry,
acquire the database lock and replace the saved claim with an observed
classification of `Absent`, `Matching`, `Partial`, `Conflicting`, or `Completed`
before selecting an action:

| State | Automated action | Required check or confirmation | Authoritative revalidation on entry |
| --- | --- | --- | --- |
| `Discovered` | Resolve immutable resource IDs and source facts | None; read-only discovery | Requery source, SQL MI, storage, and immutable IDs |
| `PrerequisitesPassed` | Validate versions, permissions, network, capacity, transport, chain compatibility, and—only for `Continuous`—SQL Agent and job owner | Technical blockers pass; one preparation consent recorded | Requery source prerequisites and current approved context; do not query Agent for `Autocomplete` |
| `IdentityReady` | Reconcile container reader role and test from SQL MI | Access test passes | Requery exact ARM role assignment and SQL MI credential; rerun Blob access test |
| `ChainReady` | Produce and locally verify the complete frozen autocomplete chain or the continuous baseline and scheduled log files | Local backup verification passes; autocomplete final name is unique and frozen | For continuous mode, requery SQL Agent catalogs; for both modes, requery source `msdb` and reverify local files |
| `Uploaded` | AzCopy each completed file into the mirrored Blob database folder and reconcile that prefix | No misplaced, missing, extra, or size-mismatched files | Relist the exact Blob prefix and compare it with `msdb`, local files, and manifest |
| `Replaying` | Start LRS and persist operation ID/state | Covered by preparation consent; approved context unchanged | Query LRS and target database; start only when both are absent |
| `PeriodicLogRestored` (`Continuous` only) | Detect, publish, verify, and observe each scheduled log restore | Report latest restore status and continue synchronization | Rebuild the cursor from SQL Agent, `msdb`, local files, Blob, and LRS |
| `WaitingForCutover` (`Continuous` only) | Keep the job and LRS running | Explicit `cutover` request not yet confirmed | Require matching active LRS plus a healthy, enabled, correctly bound SQL Agent job |
| `CutoffSelected` (`Continuous` only) | Create the approved final tail-log backup with `NORECOVERY`, verify it, and wait for LRS to restore it while the source remains `RESTORING` | Explicit request and one confirmation recorded; approved final file, LSN, and source state verified | Requery source state, final local/Blob file, manifest, and exact LRS last-restored backup |
| `Completed` | Complete LRS and wait for online state | No second confirmation; frozen cutover context unchanged | Requery LRS completion and target online state; never complete twice |
| `ValidationHandedOff` | Invoke `validate-post-migration-data` with target session, verified cutoff reference, and `RowCount` profile; never query a `RESTORING` source | For `Continuous`, `Pass` or `Ready with conditions` with no failed checks; for `Autocomplete`, only `Pass` after proven quiescence or cutoff consistency, exact final-backup validation, and proof of no later source writes | Requery target availability, cutoff-reference readiness, persisted validation evidence, and every mode-specific completion gate |

Store state, timestamps, immutable resource IDs, operation IDs, manifest hashes, and
operation confirmations in an access-controlled evidence store. Never store credentials.
Use a lock per target database to prevent duplicate runners. On restart, query Azure
and Blob state and reconcile before taking action; do not trust local state alone.
Write the checkpoint only after the authoritative postcondition succeeds. A create,
update, upload, start, or completion request returning successfully is not itself a
postcondition. If a saved state disagrees with observed state, retain both values in
sanitized evidence and follow the observed classification; never label stale state
as reusable.

## References

- [Migrate SQL Server databases by using Log Replay Service](https://learn.microsoft.com/en-us/azure/azure-sql/managed-instance/log-replay-service-migrate?view=azuresql&tabs=managed-identity)
- [Start-AzSqlInstanceDatabaseLogReplay](https://learn.microsoft.com/en-us/powershell/module/az.sql/start-azsqlinstancedatabaselogreplay)
- [Get-AzSqlInstanceDatabaseLogReplay](https://learn.microsoft.com/en-us/powershell/module/az.sql/get-azsqlinstancedatabaselogreplay)
- [Complete-AzSqlInstanceDatabaseLogReplay](https://learn.microsoft.com/en-us/powershell/module/az.sql/complete-azsqlinstancedatabaselogreplay)
- [SQL Server backup overview](https://learn.microsoft.com/en-us/sql/relational-databases/backup-restore/back-up-and-restore-of-sql-server-databases)
- [Create a SQL Server Agent job](https://learn.microsoft.com/en-us/sql/ssms/agent/create-a-job)
- [AzCopy authorization with Microsoft Entra ID](https://learn.microsoft.com/en-us/azure/storage/common/storage-use-azcopy-authorize-azure-active-directory)
