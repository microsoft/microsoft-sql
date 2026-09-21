# Windows LRS managed identity automation — AzCopy upload, LRS start, monitoring, and cutover

## Contents

- [6. Upload local backups with AzCopy](#6-upload-local-backups-with-azcopy)
- [7. Start managed-identity LRS](#7-start-managed-identity-lrs)
- [8. Monitor with bounded retry](#8-monitor-with-bounded-retry)
- [9. Continuous cutover](#9-continuous-cutover)

Part of the command-execution reference set for this skill. See SKILL.md for the workflow phases. See also: references\command-execution-setup.md, references\command-execution-identity-setup.md, references\command-execution-backup.md, references\command-execution-backup-job.md, references\command-execution-cleanup.md.

Never connect to either the source or target with SQL login/SQL authentication.
Do not request, accept, retrieve, or use SQL passwords or SQL credentials. Use
only Windows Integrated authentication or Microsoft Entra authentication supported
by the workflow: the source supports Windows Integrated or Entra interactive
authentication, and the target supports Entra authentication only.

## 6. Upload local backups with AzCopy

Prefer the already authenticated Azure CLI session because AzCopy runs as a child
process and can reliably reuse its cached Storage token. `PSCRED` can invoke a
separate Azure PowerShell authentication path and wait for interactive login when
that child process cannot reuse the expected context. Do not use `PSCRED`,
`DEVICE`, or `azcopy login`.

Before invoking AzCopy, verify that Azure CLI is signed in as the expected account
and tenant and can silently issue a Storage-audience token. This preflight must
finish before starting the copy. If it fails, immediately report `Blocked —
AzCopy authentication required`, ask the user to run attended `az login` in the
terminal, and resume from this preflight afterward. Never let AzCopy initiate the
interactive login itself:

```powershell
$previousAutoLoginType = $Env:AZCOPY_AUTO_LOGIN_TYPE
$previousTenantId = $Env:AZCOPY_TENANT_ID
$azCopyExitCode = $null

$cliAccountJson = az account show --output json 2>$null
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($cliAccountJson)) {
    throw 'Blocked — AzCopy authentication required. Azure CLI has no reusable signed-in context; authenticate Azure CLI in the attended terminal, then resume.'
}
$cliAccount = $cliAccountJson | ConvertFrom-Json
if ($cliAccount.user.name -ine $migrationAzContext.Account.Id -or
    $cliAccount.tenantId -ine $migrationAzContext.Tenant.Id) {
    throw "Blocked — AzCopy Azure CLI identity '$($cliAccount.user.name)' or tenant '$($cliAccount.tenantId)' does not match the approved migration identity and tenant. Select/authenticate the approved Azure CLI context, then resume."
}

$storageTokenExpiry = az account get-access-token `
    --resource https://storage.azure.com/ `
    --tenant $migrationAzContext.Tenant.Id `
    --query expiresOn `
    --output tsv 2>$null
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($storageTokenExpiry)) {
    throw 'Blocked — AzCopy authentication required. The cached Azure CLI context could not silently obtain a Storage token; authenticate Azure CLI in the attended terminal, then resume.'
}

$approvedRoot = [System.IO.Path]::GetFullPath($config.LocalBackupRoot).TrimEnd(
    [System.IO.Path]::DirectorySeparatorChar,
    [System.IO.Path]::AltDirectorySeparatorChar
) + [System.IO.Path]::DirectorySeparatorChar
$approvedDatabaseFolder = [System.IO.Path]::GetFullPath(
    (Join-Path $approvedRoot ([string] $config.DatabaseFolder))
).TrimEnd(
    [System.IO.Path]::DirectorySeparatorChar,
    [System.IO.Path]::AltDirectorySeparatorChar
)
$sourceFile = [System.IO.Path]::GetFullPath($completedBackup.FullName)
if (-not $sourceFile.StartsWith($approvedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'The completed backup file resolves outside the approved local backup root.'
}
if ([System.IO.Path]::GetDirectoryName($sourceFile) -ine
    $approvedDatabaseFolder) {
    throw 'The completed backup file is not directly inside the configured immutable database folder.'
}
if ([System.IO.Path]::GetExtension($sourceFile) -notin @('.bak', '.diff', '.trn')) {
    throw 'Only completed .bak, .diff, and .trn files may be uploaded.'
}
if (-not (Test-Path -LiteralPath $sourceFile -PathType Leaf)) {
    throw 'The completed local backup file does not exist.'
}
$sourceFileLength = (Get-Item -LiteralPath $sourceFile).Length
if ($sourceFileLength -le 0) {
    throw 'The completed local backup file is empty.'
}

$encodedFileName = [Uri]::EscapeDataString(
    [System.IO.Path]::GetFileName($sourceFile)
)
$destination = "$($config.StorageContainerUri)/$encodedFileName"
$copyWasInvoked = $false
try {
    $Env:AZCOPY_AUTO_LOGIN_TYPE = 'AZCLI'
    $Env:AZCOPY_TENANT_ID = $migrationAzContext.Tenant.Id

    $existingBlobOutput = & azcopy list $destination `
        --machine-readable 2>&1 | Out-String
    $existingBlobExitCode = $LASTEXITCODE
    if ($existingBlobExitCode -ne 0) {
        throw "Could not prove that the exact immutable Blob destination is absent: '$destination'."
    }
    if ($existingBlobOutput -match
        '(?im)(?:^|;[ \t]*)Content Length:[ \t]*\d+[ \t]*$') {
        throw "The immutable Blob destination already exists: '$destination'."
    }

    $copyWasInvoked = $true
    $copyOutputLines = @(& azcopy copy $sourceFile $destination `
        --overwrite=false `
        --from-to=LocalBlob `
        --output-type=json 2>&1 | ForEach-Object { $_.ToString() })
    $azCopyExitCode = $LASTEXITCODE

    $endOfJobRecords = @($copyOutputLines | ForEach-Object {
        if ([string]::IsNullOrWhiteSpace($_)) {
            return
        }
        try {
            $record = $_ | ConvertFrom-Json -ErrorAction Stop
        } catch {
            throw 'AzCopy returned output that was not valid structured JSON.'
        }
        if ($record.MessageType -ceq 'EndOfJob') {
            $record
        }
    })
    if ($azCopyExitCode -ne 0 -or $endOfJobRecords.Count -ne 1) {
        throw "AzCopy failed or returned an ambiguous final job result. Exit code: $azCopyExitCode."
    }

    $jobSummary = $endOfJobRecords[0].MessageContent
    if ($jobSummary -is [string]) {
        try {
            $jobSummary = $jobSummary | ConvertFrom-Json -ErrorAction Stop
        } catch {
            throw 'AzCopy EndOfJob output did not contain a valid structured summary.'
        }
    }
    $requiredSummaryProperties = @(
        'JobStatus', 'TotalTransfers', 'TransfersCompleted',
        'TransfersFailed', 'TransfersSkipped'
    )
    foreach ($propertyName in $requiredSummaryProperties) {
        if (-not $jobSummary.PSObject.Properties[$propertyName]) {
            throw "AzCopy EndOfJob output omitted '$propertyName'."
        }
    }
    if ([string] $jobSummary.JobStatus -cne 'Completed' -or
        [int64] $jobSummary.TotalTransfers -ne 1 -or
        [int64] $jobSummary.TransfersCompleted -ne 1 -or
        [int64] $jobSummary.TransfersFailed -ne 0 -or
        [int64] $jobSummary.TransfersSkipped -ne 0) {
        throw 'AzCopy did not complete exactly one transfer with zero failed or skipped transfers.'
    }

    $uploadedBlobOutput = & azcopy list $destination `
        --machine-readable 2>&1 | Out-String
    $uploadedBlobExitCode = $LASTEXITCODE
    $uploadedLengthMatches = [regex]::Matches(
        $uploadedBlobOutput,
        '(?im)(?:^|;[ \t]*)Content Length:[ \t]*(?<Length>\d+)[ \t]*$'
    )
    if ($uploadedBlobExitCode -ne 0 -or
        $uploadedLengthMatches.Count -ne 1 -or
        [int64] $uploadedLengthMatches[0].Groups['Length'].Value -ne
            $sourceFileLength) {
        throw 'The upload completed, but exact-Blob verification was ambiguous or its content length differed. Preserve the AzCopy job evidence and do not retry the upload.'
    }
} catch {
    if ($copyWasInvoked) {
        throw "The AzCopy upload outcome must be reconciled against the exact destination object before any further action. Preserve the captured structured output and AzCopy job log; do not retry the upload. $($_.Exception.Message)"
    }
    throw
} finally {
    $Env:AZCOPY_AUTO_LOGIN_TYPE = $previousAutoLoginType
    $Env:AZCOPY_TENANT_ID = $previousTenantId
}
```

Never fall back from `AZCLI` to `PSCRED` or `DEVICE` after copy failure. Preserve
the AzCopy job log and report the actual authorization, network, or transfer
error. A 403 after successful token preflight is an RBAC or storage-network issue,
not a reason to launch interactive authentication.

This workflow does not support an Azure-hosted runner identity, service principal,
or unattended AzCopy login. The attended upload identity is separate from the SQL
MI identity. Do not automatically remove temporary uploader access after upload;
include that exact role assignment in the manual reversion report.
Never append a SAS query string to `$destination`.

The destination intentionally mirrors the local database folder. Copy each
completed file from `<LocalBackupRoot>\<DatabaseFolder>\` to its exact encoded
Blob URL without changing its filename. Before every upload, prove that exact URL
is absent. Require structured AzCopy output showing exactly one completed
transfer and zero failed or skipped transfers, then list that exact URL and match
its content length to the nonempty local file. Compare the manifest with that
Blob prefix and reject files outside the expected database folder, child folders
below it, missing/extra blobs, zero-length files, size mismatches, and overwritten
names. If post-upload verification is unavailable or ambiguous, preserve the job
evidence and reconcile the exact object; never retry the upload.

## 7. Start managed-identity LRS

LRS restores the target backup chain with `NORECOVERY` semantics. The target must
remain in `RESTORING` while more backups can arrive; do not recover it between
files. In `Continuous` mode, only
`Complete-AzSqlInstanceDatabaseLogReplay -LastBackupName <final-file>` recovers
and brings the target online after confirmed cutover. Preallocate and display the
exact final file name in that confirmation, then manually pass the same value
after consent. In `Autocomplete` mode, first require the user to manually supply
the exact `LastBackupName`; display it together with `AutoCompleteRestore = $true`
and obtain affirmative preparation consent. Set neither parameter before consent.

Fail fast against the command exported by the loaded `Az.Sql` module. Version
4.1.0 is the minimum because it made `StorageContainerSasToken` optional. Merely
finding `StorageContainerUri` is insufficient: the resource-name parameter set
must accept `StorageContainerIdentity` with no mandatory SAS token. `StorageUri`
is invalid and must never be generated, passed, or retried:

```powershell
$lrsStartCommand = Get-Command `
    -Name Start-AzSqlInstanceDatabaseLogReplay `
    -CommandType Cmdlet `
    -ErrorAction Stop

$azSqlVersion = $lrsStartCommand.Module.Version
if (-not $azSqlVersion -or $azSqlVersion -lt [version]'4.1.0') {
    throw "The loaded Start-AzSqlInstanceDatabaseLogReplay command is from Az.Sql '$azSqlVersion'; managed-identity LRS requires Az.Sql 4.1.0 or later."
}

$requiredManagedIdentityParameters = @(
    'ResourceGroupName', 'InstanceName', 'Name',
    'StorageContainerUri', 'StorageContainerIdentity'
)
$managedIdentityParameterSets = @($lrsStartCommand.ParameterSets | Where-Object {
    $parameterSet = $_
    @($requiredManagedIdentityParameters | Where-Object {
        $_ -notin $parameterSet.Parameters.Name
    }).Count -eq 0 -and
    -not ($parameterSet.Parameters | Where-Object {
        $_.Name -eq 'StorageContainerSasToken' -and $_.IsMandatory
    })
})
if ($managedIdentityParameterSets.Count -eq 0) {
    throw "Az.Sql '$azSqlVersion' does not expose a SAS-free managed-identity resource-name parameter set for Start-AzSqlInstanceDatabaseLogReplay."
}
```

First reconcile both the Azure LRS operation and target database. A saved local
operation ID is not proof that replay exists. Start only when both authoritative
queries classify the state as `Absent`; reuse a matching active replay, advance a
completed replay to validation, and block a failed, blocked, or conflicting state:

```powershell
function Test-AzureNotFoundFailure {
    param([Parameter(Mandatory)] [System.Management.Automation.ErrorRecord] $ErrorRecord)

    $errorText = $ErrorRecord.Exception.Message + ' ' +
        $ErrorRecord.FullyQualifiedErrorId
    $errorText -match '(?i)(ResourceNotFound|HttpStatusCode[^\r\n]*NotFound|\b404\b)'
}

$storageUri = $config.StorageContainerUri

try {
    $existingReplay = Get-AzSqlInstanceDatabaseLogReplay `
        -ResourceGroupName $config.ResourceGroup `
        -InstanceName $config.ManagedInstance `
        -Name $config.TargetDatabase `
        -ErrorAction Stop
} catch {
    if (-not (Test-AzureNotFoundFailure -ErrorRecord $_)) {
        throw
    }
    $existingReplay = $null
}

try {
    $existingTarget = Get-AzSqlInstanceDatabase `
        -ResourceGroupName $config.ResourceGroup `
        -InstanceName $config.ManagedInstance `
        -Name $config.TargetDatabase `
        -ErrorAction Stop
} catch {
    if (-not (Test-AzureNotFoundFailure -ErrorRecord $_)) {
        throw
    }
    $existingTarget = $null
}

$startLrs = $false
if ($existingReplay) {
    if (-not $existingTarget) {
        throw 'Conflicting LRS state: replay exists but the target database was not found.'
    }

    $contextMismatches = [System.Collections.Generic.List[string]]::new()
    foreach ($propertyName in @(
        'ResourceGroupName', 'InstanceName', 'Name', 'StorageContainerUri',
        'StorageContainerIdentity', 'AutoCompleteRestore'
    )) {
        $property = $existingReplay.PSObject.Properties[$propertyName]
        if (-not $property) {
            continue
        }
        $expectedValue = switch ($propertyName) {
            'ResourceGroupName' { $config.ResourceGroup }
            'InstanceName' { $config.ManagedInstance }
            'Name' { $config.TargetDatabase }
            'StorageContainerUri' { $storageUri }
            'StorageContainerIdentity' { 'ManagedIdentity' }
            'AutoCompleteRestore' { $config.Mode -eq 'Autocomplete' }
        }
        if ([string]$property.Value -cne [string]$expectedValue) {
            [void]$contextMismatches.Add(
                "$propertyName is '$($property.Value)', expected '$expectedValue'."
            )
        }
    }
    if ($contextMismatches.Count -gt 0) {
        throw "Conflicting LRS operation context: $($contextMismatches -join ' ')"
    }

    switch ([string]$existingReplay.Status) {
        { $_ -in @('Waiting', 'Restoring', 'Uploading') } {
            Write-Host "Matching active LRS operation found in state '$($_)'; resume monitoring without starting another operation."
        }
        'Completed' {
            Write-Host 'LRS is already completed; advance to target validation without restarting replay.'
        }
        'Blocked' {
            throw 'The existing LRS operation is Blocked. Reconcile its authoritative operation error before retrying; do not restart it.'
        }
        'Failed' {
            throw 'The existing LRS operation is Failed. Capture its authoritative operation error and stop; do not start a duplicate.'
        }
        default {
            throw "The existing LRS operation has unexpected state '$($_)'. Stop for reconciliation."
        }
    }
} elseif ($existingTarget) {
    throw "Conflicting state: target database '$($config.TargetDatabase)' exists without a matching LRS operation."
} else {
    $startLrs = $true
}

$startParameters = @{
    ResourceGroupName        = $config.ResourceGroup
    InstanceName             = $config.ManagedInstance
    Name                     = $config.TargetDatabase
    Collation                = $config.Collation
    StorageContainerUri      = $storageUri
    StorageContainerIdentity = 'ManagedIdentity'
}

if ($startParameters.ContainsKey('StorageUri') -or
    -not $startParameters.ContainsKey('StorageContainerUri')) {
    throw 'Invalid LRS start parameter set: use StorageContainerUri, never StorageUri.'
}

if ($startLrs -and $config.Mode -eq 'Autocomplete') {
    if (-not $autocompleteConsentGranted) {
        throw 'Autocomplete parameters were not approved; LRS was not started.'
    }
    # These values are assigned manually only after the user approved the review
    # showing AutoCompleteRestore=true and this exact LastBackupName.
    $startParameters.AutoCompleteRestore = $true
    $startParameters.LastBackupName = $config.LastBackupName
    Start-AzSqlInstanceDatabaseLogReplay @startParameters
} elseif ($startLrs) {
    $lrsStartJob = Start-AzSqlInstanceDatabaseLogReplay @startParameters -AsJob
    $lrsStartJob.Id
}
```

Immediately query `Get-AzSqlInstanceDatabaseLogReplay` after a start request and
persist its observed status and immutable target identifiers. If the process ends
between the start and checkpoint write, the same reconciliation block discovers
and reuses the operation on restart. Before classifying an existing operation as
`Matching`, compare every context property returned by the API with the approved
resource group, SQL MI, target database, storage URI, identity mode, and replay
mode. Some API versions do not return every start parameter; an omitted property
is not supplied from the checkpoint as if it were authoritative. In that case,
require the API-addressed target identity plus the reported
`LastRestoredFileName` to match exactly one entry in the currently observed
approved `msdb`/local/Blob chain. If that chain proof is unavailable or ambiguous,
classify the operation as `Conflicting` and stop rather than reuse or restart it.

Before invocation, inspect the parameter dictionary and fail if it contains
`StorageUri`, omits `StorageContainerUri`, or has any key containing `Sas`, `Key`,
`Secret`, or `ConnectionString`. Do not catch a parameter-binding failure and retry
with guessed names; report the exact binding error and stop.

## 8. Monitor with bounded retry

Poll the Azure resource, not only the local background job. Use a finite interval,
an overall deadline below 30 days, and exponential backoff only for transient API
errors. Persist sanitized JSON snapshots to the approved evidence location.

```powershell
$status = Get-AzSqlInstanceDatabaseLogReplay `
    -ResourceGroupName $config.ResourceGroup `
    -InstanceName $config.ManagedInstance `
    -Name $config.TargetDatabase

$status | Select-Object Status, CreationDate, LastRestoredFileName,
    LastRestoredFileTime, FullBackupSets, DiffBackupSets, LogBackupSets,
    NumberOfFilesDetected, NumberOfFilesQueued, NumberOfFilesRestored,
    NumberOfFilesRestoring, NumberOfFilesSkipped, NumberOfFilesUnrestorable |
    Format-List
```

The state-machine adapter normalizes the Az.Sql result by setting its
`LastRestoredFile` field from `$status.LastRestoredFileName`. Preserve
`LastRestoredFileTime`, `FullBackupSets`, `DiffBackupSets`, `LogBackupSets`, and
the file counts in the sanitized observation evidence.

If the initial status is `Blocked` and the sanitized operation error indicates
Blob `AccessDenied` or an equivalent authorization failure, first verify that the
resolved SQL MI principal still has `Storage Blob Data Reader` at the exact
container scope. When that assignment is correct, treat the condition as possible
RBAC propagation delay. Report the original error immediately, then poll once per
minute for at most five retry checks. Do not poll more frequently, perform a sixth
retry, restart LRS, or change/broaden RBAC during this wait:

```powershell
$startedWaitingAt = [DateTimeOffset]::UtcNow
$recoveredFromPropagation = $false
$maximumRbacPolls = 5

for ($rbacPoll = 1; $rbacPoll -le $maximumRbacPolls; $rbacPoll++) {
    Start-Sleep -Seconds 60

    $status = Get-AzSqlInstanceDatabaseLogReplay `
        -ResourceGroupName $config.ResourceGroup `
        -InstanceName $config.ManagedInstance `
        -Name $config.TargetDatabase

    Write-Host ('RBAC propagation check {0}/{1}: LRS status is {2}.' -f `
        $rbacPoll, $maximumRbacPolls, $status.Status)

    if ($status.Status -in @('Waiting', 'Restoring', 'Uploading', 'Completed')) {
        $elapsed = [DateTimeOffset]::UtcNow - $startedWaitingAt
        Write-Host ('Recovered: LRS changed from Blocked to {0} after {1:n0} seconds of RBAC propagation.' -f `
            $status.Status, $elapsed.TotalSeconds) -ForegroundColor Green
        $recoveredFromPropagation = $true
        break
    }

    if ($status.Status -eq 'Failed') {
        throw 'LRS changed to Failed while waiting for managed-identity RBAC propagation. Report the current sanitized LRS operation error and stop.'
    }

    if ($status.Status -ne 'Blocked') {
        throw "LRS changed to unexpected status '$($status.Status)' while waiting for managed-identity RBAC propagation. Report the current sanitized LRS operation error and stop."
    }
}

if (-not $recoveredFromPropagation) {
    throw "Managed-identity RBAC propagation did not complete after 5 one-minute checks. LRS remains '$($status.Status)'. Save an AwaitingManualRBAC checkpoint for SQL MI principal '$principalId', role 'Storage Blob Data Reader', and exact container scope '$containerScope'. Show the manual portal and PowerShell handoff, then pause without restarting LRS."
}
```

Use this remediation only for a verified correct role assignment plus an
authorization-related initial block. A chain, URI, firewall, identity mismatch,
or other error is not an RBAC propagation wait. Persist the initial error, each
one-minute status observation, elapsed time, and either the `Recovered` result or
final `Blocked` RBAC error in sanitized evidence. After the fifth unsuccessful
check, save the current LRS operation in the `AwaitingManualRBAC` checkpoint,
display the same exact manual handoff, and pause; do not continue to backup replay,
cutover, or the next queued database. When the user returns, verify the exact
assignment and query the existing LRS operation. Continue monitoring if it is
healthy; never restart or duplicate it.

For a failed operation:

```powershell
Get-AzSqlInstanceOperation `
    -ResourceGroupName $config.ResourceGroup `
    -ManagedInstanceName $config.ManagedInstance
```

Redact resource IDs or error details if the evidence leaves the approved boundary.

## 9. Continuous cutover

After each new successful periodic log backup, publish and verify that exact file,
wait for LRS to report it restored, and report the latest restored file and replay
status. Do not issue a Yes/No prompt after each log. Continue processing logs until
the user explicitly types `cutover`. Use
[lrs-monitor-cutover-state-machine.ps1](lrs-monitor-cutover-state-machine.ps1)
as the executable implementation. After each cycle, `monitor` sleeps until the
next configured interval (10 minutes) and `cutover` enters the two context-bound
typed gates defined in the monitoring/cutover policy. Rejection, no response, or
`monitor` performs no cutover mutation.

Initialize `New-LrsWorkflowState` with the immutable configuration's exact
source database identity (database GUID plus recovery-fork identity),
`StorageBlobEndpoint`, `StorageCredentialName`, and `StorageContainerUri` values.
The atomic checkpoint persists all three. On resume, compare them with the current
resolved storage account's `PrimaryEndpoints.Blob` and stop on any mismatch; never
reconstruct a public-cloud hostname or silently replace the frozen endpoint.

The state-machine adapters must query authoritative SQL Agent, backup-set, Blob,
SQL MI target, and LRS state; they must not infer completion from elapsed time.
The normalized observation must expose the exact `TailBackupName`, a
`TailBackupVerified` Boolean derived from authoritative `RESTORE VERIFYONLY WITH
CHECKSUM` and matching source backup metadata, and a `TargetContextMatches`
Boolean derived by comparing the observed SQL MI resource, database
name/identity, and LRS operation to the immutable approved target context. A
missing value is not a match. If the target is `ONLINE` before the
source is `RESTORING`, the exact tail and Blob are verified, that exact filename
is restored, LRS is `Completed`, and the target context matches, classify the
observation as `Conflicting` and stop:

Before entering the loop on either a first run or resume, reconstruct the cursor
instead of trusting `Get-LastProcessedBackupSetId`. The implementation must perform
these concrete observations in this order:

1. Query `msdb.dbo.sysjobhistory` for successful job-level executions and
    `msdb.dbo.backupset`, `backupmediafamily`, and `backupfile` for the current
    database's log backups, backup-set IDs, physical filenames, first/last LSNs,
    database backup LSNs, recovery forks, sizes, and finish times.
2. Enumerate the approved local database folder and require every candidate file
    to pass `RESTORE VERIFYONLY WITH CHECKSUM` and match one source backup-set row.
3. Enumerate the exact Blob database prefix using the already validated uploader
    identity. Reject child prefixes, files outside the source chain, duplicate
    names, and size mismatches; `--overwrite=false` remains mandatory for missing
    uploads. A valid ordered suffix may be local-only or present in Blob but not
    yet restored after a crash; it is pending work, not a conflict.
4. Query `Get-AzSqlInstanceDatabaseLogReplay` and read its authoritative `Status`,
    `CreationDate`, `LastRestoredFileName`, `LastRestoredFileTime`,
    `FullBackupSets`, `DiffBackupSets`, `LogBackupSets`, and file counts. Stop on
    `Failed`, reconcile `Blocked`, advance on `Completed`, and continue only for a
    documented active state.
5. Select the restored cursor as the highest backup-set ID whose immutable
    filename and chain identity agree across source `msdb`, local verification,
    Blob, and LRS `LastRestoredFileName`. Use `LastRestoredFileTime` as observation
    evidence, not as a substitute for the immutable filename/chain match. Return the later contiguous source-chain
    entries as an ordered pending suffix, marking each as `NeedsUpload` or
    `AwaitingRestore` from its observed local/Blob state. Compare the restored
    cursor with the saved cursor. A saved cursor ahead of or outside the observed
    restored chain is `Conflicting`; an observed restored cursor ahead of the saved
    cursor replaces the checkpoint without another upload or replay.

Record observation timestamps and immutable identifiers. Do not enter monitoring
or cutover if any authoritative source is unavailable or disagrees. Atomically
write intent before each mutation and write the observed postcondition afterward.
On restart, authoritative reconciliation advances past an already-completed
mutation without repeating it.

Tell the user that SQL Server doesn't allow `BACKUP` while a database is
`READ_ONLY`; therefore this workflow does not set read-only before the final log
backup. Disable only the current database's LRS backup job and wait until no
execution is active. Then inspect active user transactions through the cached
source connection. Run this read-only check under the existing session consent,
with the validated database name safely escaped as a Unicode literal:

```sql
DECLARE @DatabaseName sysname = N'<source-database>';
DECLARE @DatabaseId int = DB_ID(@DatabaseName);

SELECT
    dt.transaction_id,
    dt.database_transaction_begin_time,
    dt.database_transaction_state,
    st.session_id,
    s.login_name,
    s.host_name,
    s.program_name
FROM sys.dm_tran_database_transactions AS dt
INNER JOIN sys.dm_tran_session_transactions AS st
    ON st.transaction_id = dt.transaction_id
INNER JOIN sys.dm_exec_sessions AS s
    ON s.session_id = st.session_id
WHERE dt.database_id = @DatabaseId
    AND s.is_user_process = 1
    AND s.session_id <> @@SPID;
GO
```

These DMVs require sufficient server-state visibility. If the query is denied,
do not claim there are no active transactions; report that the check is
unavailable and offer `Proceed with final log backup` or `Cancel cutover`. If the
result is empty, proceed automatically. If rows are returned, show sanitized
session and transaction start-time details and offer `Wait and retry`, `Proceed
with final log backup`, or `Cancel cutover`. Never run `KILL`, switch to
`SINGLE_USER`, or use `ROLLBACK IMMEDIATE`. A cancel decision takes and replays
one normal log backup without `NORECOVERY` while the recurring job is disabled,
persists that backup-set identity, and then re-enables the job and leaves LRS
running. Verify and report that the source is `ONLINE` and `READ_WRITE`, and warn
that new changes can occur after that backup. Do not record that normal backup as
a migration cutoff or complete LRS from it.

Do not attempt `READ_ONLY`. Take the tail-log backup with `WITH NORECOVERY`; this
atomically captures the remaining log and leaves the source in `RESTORING`, which
prevents later writes. Include `COMPRESSION` and `CHECKSUM`, verify the backup, and
verify `sys.databases.state_desc = 'RESTORING'` before completing LRS. Active
transactions that aren't committed at the migration cutoff are rolled back when
the target is recovered and aren't migrated as committed data.

Take and verify one uniquely named final log backup in the approved local folder,
upload it to the same Blob folder, record its completion time and LSN as the
migration cutoff, record the active-transaction check and decision, and wait until
LRS reports that exact file as restored. Before taking the final backup, invoke
[canonical-sql-agent-job-reconciler.sql](canonical-sql-agent-job-reconciler.sql)
with `RequestedAction = StopAndDisable`; do not derive a job name or issue an
independent job update here. Persist the prior enabled/running state, use the
validated job ID returned by the reconciler, and require `enabled = 0` plus no
active execution. Recheck immediately before backup creation. A timeout or denied
stop/disable enters the documented manual SSMS/sqlcmd remediation state. Do not
take the final log while the recurring job can run. Then complete:

```powershell-pseudocode
$finalLog = New-VerifiedFinalLogBackup `
    -DatabaseItem $databaseItem `
    -FileName $approvedFinalBackupName `
    -NoRecovery

if ($finalLog.FileName -cne $approvedFinalBackupName) {
    throw 'The produced tail-log file does not match the final backup name approved for cutover.'
}

$sourceState = Get-SourceDatabaseState -DatabaseItem $databaseItem
if ($sourceState.StateDesc -ne 'RESTORING') {
    throw 'The tail-log backup did not leave the source database in RESTORING. Do not complete LRS.'
}

Copy-CompletedLogToBlob `
    -DatabaseItem $databaseItem `
    -Backup $finalLog `
    -Overwrite:$false
Confirm-ExactBlobPublished `
    -DatabaseItem $databaseItem `
    -Backup $finalLog
Wait-UntilLrsRestoresFile `
    -DatabaseItem $databaseItem `
    -BackupName $finalLog.FileName

Complete-AzSqlInstanceDatabaseLogReplay `
    -ResourceGroupName $config.ResourceGroup `
    -InstanceName $config.ManagedInstance `
    -Name $config.TargetDatabase `
    -LastBackupName $approvedFinalBackupName
```

Continue polling until LRS reports completion and SQL MI reports the database
online. The cutover decision already authorizes
`Complete-AzSqlInstanceDatabaseLogReplay`; prompt again only if the target, final
file, identity, or LRS state unexpectedly differs from the frozen context. Request
acceptance is not completion.

Do not treat Blob presence as LRS readability, an earlier restored file as the
final file, an accepted completion request as completion, or completed LRS as
target availability. Require all four independent authoritative postconditions:
the exact final Blob is readable, `LastRestoredFileName` names that exact file,
LRS is completed, and the target database is `ONLINE` and connectable. Leave the
migration job disabled after success.
