# Copyright (c) Microsoft Corporation.
# Licensed under the MIT license.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Save-LrsCheckpointAtomic {
    param([Parameter(Mandatory)] [hashtable] $State,
          [Parameter(Mandatory)] [string] $Path)

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $State.UpdatedUtc = [DateTimeOffset]::UtcNow.ToString('o')
    $temporary = "$Path.$([Guid]::NewGuid().ToString('N')).tmp"
    $State | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $temporary -Encoding utf8NoBOM
    [System.IO.File]::Move($temporary, $Path, $true)
}

function New-LrsWorkflowState {
    param([Parameter(Mandatory)] [string] $SourceServer,
          [Parameter(Mandatory)] [string] $SourceDatabase,
            [Parameter(Mandatory)] [string] $SourceDatabaseIdentity,
          [Parameter(Mandatory)] [string] $ManagedInstance,
          [Parameter(Mandatory)] [string] $TargetDatabase,
          [Parameter(Mandatory)] [string] $FinalBackupName,
          [Parameter(Mandatory)] [string] $StorageBlobEndpoint,
          [Parameter(Mandatory)] [string] $StorageCredentialName,
          [Parameter(Mandatory)] [string] $StorageContainerUri,
          [int] $PollMinutes = 10)

    if ($PollMinutes -lt 1) { throw 'PollMinutes must be at least 1.' }
    if (-not $StorageCredentialName.StartsWith(
            "$($StorageBlobEndpoint.TrimEnd('/'))/",
            [StringComparison]::Ordinal
        ) -or
        -not $StorageContainerUri.StartsWith(
            "$($StorageCredentialName.TrimEnd('/'))/",
            [StringComparison]::Ordinal
        )) {
        throw 'Checkpoint storage URIs are inconsistent with primaryEndpoints.blob.'
    }
    @{
        SchemaVersion = 2
        Phase = 'Monitoring'
        SourceServer = $SourceServer
        SourceDatabase = $SourceDatabase
        SourceDatabaseIdentity = $SourceDatabaseIdentity
        ManagedInstance = $ManagedInstance
        TargetDatabase = $TargetDatabase
        FinalBackupName = $FinalBackupName
        StorageBlobEndpoint = $StorageBlobEndpoint
        StorageCredentialName = $StorageCredentialName
        StorageContainerUri = $StorageContainerUri
        PollMinutes = $PollMinutes
        DisclaimerAccepted = $false
        CutoverConfirmed = $false
        JobWasEnabled = $null
        LastRestoredFile = $null
        CutoffReferenceType = $null
        CutoffReferenceLocation = $null
        CutoffReferenceHash = $null
        CutoffReferenceReady = $false
        SourceTrafficDrained = $false
        ActiveTransactionCheckAuthorized = $false
        ActiveTransactionCount = $null
        ExplicitProceedDecision = $null
        FinalBackupCompletionUtc = $null
        FinalBackupLastLsn = $null
        OnlinePostconditionsReconciled = $false
        PendingMutation = $null
        ManualReason = $null
        ManualSteps = @()
        Evidence = @()
    }
}

function Add-LrsEvidence {
    param([hashtable] $State, [string] $Event, [hashtable] $Data = @{})
    $State.Evidence += @(@{
        TimestampUtc = [DateTimeOffset]::UtcNow.ToString('o')
        Event = $Event
        Data = $Data
    })
}

function Assert-LrsCheckpointStorageBinding {
    param([Parameter(Mandatory)] [hashtable] $State,
          [Parameter(Mandatory)] [string] $CurrentStorageBlobEndpoint,
          [Parameter(Mandatory)] [string] $CurrentStorageCredentialName,
          [Parameter(Mandatory)] [string] $CurrentStorageContainerUri)

    $endpoint = $CurrentStorageBlobEndpoint.TrimEnd('/')
    if (-not $CurrentStorageCredentialName.StartsWith(
            "$endpoint/", [StringComparison]::Ordinal
        ) -or
        -not $CurrentStorageContainerUri.StartsWith(
            "$($CurrentStorageCredentialName.TrimEnd('/'))/",
            [StringComparison]::Ordinal
        )) {
        throw 'Current storage URIs are inconsistent with primaryEndpoints.blob.'
    }

    $schemaVersion = if ($State.ContainsKey('SchemaVersion')) {
        [int]$State.SchemaVersion
    } else { 1 }
    if ($schemaVersion -eq 1) {
        if ($State.ContainsKey('StorageBlobEndpoint') -or
            $State.ContainsKey('StorageCredentialName') -or
            $State.ContainsKey('StorageContainerUri')) {
            throw 'Legacy checkpoint contains unexpected storage bindings and may have been downgrade-tampered.'
        }
        $State.StorageBlobEndpoint = $endpoint
        $State.StorageCredentialName = $CurrentStorageCredentialName
        $State.StorageContainerUri = $CurrentStorageContainerUri
        $State.SchemaVersion = 2
        Add-LrsEvidence $State 'CheckpointStorageBindingUpgraded' @{
            FromSchemaVersion = 1
        }
        return
    }
    if ($schemaVersion -ne 2) {
        throw "Unsupported LRS checkpoint schema version '$schemaVersion'."
    }
    if ($State.StorageBlobEndpoint -cne $endpoint -or
        $State.StorageCredentialName -cne $CurrentStorageCredentialName -or
        $State.StorageContainerUri -cne $CurrentStorageContainerUri) {
        throw 'Checkpoint storage URIs do not match the current resolved primaryEndpoints.blob configuration.'
    }
}

function Get-CutoverDisclaimerPhrase {
    param([hashtable] $State)
    "I ACCEPT CUTOVER $($State.SourceServer)/$($State.SourceDatabase) TO $($State.ManagedInstance)/$($State.TargetDatabase) WITH TAIL BACKUP NORECOVERY"
}

function Get-CutoverConfirmationPhrase {
    param([hashtable] $State)
    "CUTOVER $($State.SourceServer)/$($State.SourceDatabase) TO $($State.ManagedInstance)/$($State.TargetDatabase) FINAL $($State.FinalBackupName)"
}

function Set-LrsManualIntervention {
    param([hashtable] $State, [string] $Reason, [string[]] $Steps)
    $State.Phase = 'AwaitingManualIntervention'
    $State.ManualReason = $Reason
    $State.ManualSteps = $Steps
    $State.PendingMutation = $null
    Add-LrsEvidence $State 'ManualInterventionRequired' @{ Reason = $Reason }
}

function Get-LrsManualRemediationSteps {
    param([hashtable] $State, [string] $Failure)
    @(
        "In SSMS or sqlcmd, connect to '$($State.SourceServer)' using the same approved Windows or Microsoft Entra identity; never use SQL authentication.",
        "Review SQL Agent activity and backup history for '$($State.SourceDatabase)'. Stop/disable only the validated migration job through the canonical reconciler; do not alter unrelated jobs.",
        "Drain application traffic and close connections through the application or DBA change process. Do not issue KILL, SINGLE_USER, or ROLLBACK IMMEDIATE from this workflow.",
        "Verify the operator has BACKUP DATABASE/BACKUP LOG permission and that the SQL Server service account can write the approved local folder. Failure: $Failure",
        "Do not manually complete LRS. Preserve the source, final backup, Blob files, manifest, and checkpoint.",
        "After remediation, type exactly: CUTOVER REMEDIATION COMPLETE $($State.SourceDatabase)"
    )
}

function Sync-LrsObservedCutoverState {
    param([hashtable] $State, [Parameter(Mandatory)] [hashtable] $Adapter)

    if (-not $State.CutoverConfirmed) { return }
    $observed = & $Adapter.Observe $State
    if (-not $observed) { throw 'Authoritative cutover observation returned no result.' }

    # Advance only from authoritative postconditions. This closes every
    # mutation/checkpoint crash window without repeating a completed mutation.
    $rank = @{
        CutoverConfirmed=1; JobStoppedAndDisabled=2; SourceRestoring=3
        FinalFileUploaded=4; FinalFileReadable=5; FinalFileRestored=6
        CompletionAccepted=7; TargetOnline=8
    }
    $candidate = $null
    $jobStopped = $observed.JobEnabled -eq $false -and
        $observed.JobRunning -eq $false
    if ($jobStopped) { $candidate='JobStoppedAndDisabled' }
    $tailReady = $jobStopped -and
        $observed.TailBackupExists -eq $true -and
        $observed.TailBackupVerified -eq $true -and
        $observed.TailBackupName -ceq $State.FinalBackupName -and
        $observed.SourceState -eq 'RESTORING'
    $rawOnlinePostconditions = $tailReady -and
        -not [string]::IsNullOrWhiteSpace(
            [string]$State.FinalBackupCompletionUtc
        ) -and
        -not [string]::IsNullOrWhiteSpace(
            [string]$State.FinalBackupLastLsn
        ) -and
        [string]$observed.TailBackupCompletionUtc -ceq
            $State.FinalBackupCompletionUtc -and
        [string]$observed.TailBackupLastLsn -ceq
            $State.FinalBackupLastLsn -and
        $observed.FinalBlobPresent -eq $true -and
        $observed.FinalBlobVerified -eq $true -and
        $observed.FinalFileReadableByLrs -eq $true -and
        $observed.LastRestoredFile -ceq $State.FinalBackupName -and
        $observed.CompletionStatus -ceq 'Completed' -and
        $observed.TargetContextMatches -eq $true -and
        $State.CutoffReferenceReady -eq $true
    $State.OnlinePostconditionsReconciled =
        $observed.TargetOnline -eq $true -and
        $rawOnlinePostconditions
    if ($observed.TargetOnline -eq $true -and
        -not $rawOnlinePostconditions) {
        throw 'Conflicting observed state: the target is ONLINE before every frozen cutover postcondition is satisfied.'
    }
    if ($State.Phase -eq 'TargetOnline' -and
        $State.OnlinePostconditionsReconciled -ne $true) {
        throw 'Conflicting observed state: a completed TargetOnline checkpoint regressed or no longer satisfies every frozen cutover postcondition.'
    }
    if ($tailReady) {
        if ([string]::IsNullOrWhiteSpace(
                [string]$observed.TailBackupCompletionUtc
            ) -or
            [string]::IsNullOrWhiteSpace(
                [string]$observed.TailBackupLastLsn
            )) {
            throw 'Source is RESTORING but authoritative final backup completion time or LSN is unavailable.'
        }
        if ((-not [string]::IsNullOrWhiteSpace(
                    [string]$State.FinalBackupCompletionUtc
                ) -and
                [string]$observed.TailBackupCompletionUtc -cne
                    $State.FinalBackupCompletionUtc) -or
            (-not [string]::IsNullOrWhiteSpace(
                    [string]$State.FinalBackupLastLsn
                ) -and
                [string]$observed.TailBackupLastLsn -cne
                    $State.FinalBackupLastLsn)) {
            throw 'Conflicting observed state: the final tail backup completion time or LSN differs from the frozen cutoff.'
        }
        $State.FinalBackupCompletionUtc =
            [string]$observed.TailBackupCompletionUtc
        $State.FinalBackupLastLsn =
            [string]$observed.TailBackupLastLsn
        if (-not $State.ContainsKey('CutoffReferenceType') -or
            [string]::IsNullOrWhiteSpace(
                [string]$State.CutoffReferenceType
            )) {
            throw 'Source is RESTORING but no pre-tail cutoff validation reference was recorded.'
        }
        $resumeReference = & $Adapter.ValidateCutoffReference $State
        $resumeActiveTransactionCount = 0L
        $resumeCountIsValid = $null -ne $resumeReference -and
            $null -ne $resumeReference.PSObject.Properties[
                'ActiveTransactionCount'
            ] -and
            [long]::TryParse(
                [string]$resumeReference.ActiveTransactionCount,
                [ref]$resumeActiveTransactionCount
            )
        if ($null -eq $resumeReference -or
            $resumeReference.Ready -ne $true -or
            [string]$resumeReference.Type -cne
                $State.CutoffReferenceType -or
            [string]$resumeReference.Location -cne
                $State.CutoffReferenceLocation -or
            [string]$resumeReference.Hash -cne
                $State.CutoffReferenceHash -or
            [string]$resumeReference.DatabaseIdentity -cne
                $State.SourceDatabaseIdentity -or
            [string]$resumeReference.DatabaseName -cne
                $State.SourceDatabase -or
            [string]$resumeReference.FinalBackupName -cne
                $State.FinalBackupName -or
            [string]$resumeReference.FinalBackupCompletionUtc -cne
                $State.FinalBackupCompletionUtc -or
            [string]$resumeReference.FinalBackupLastLsn -cne
                $State.FinalBackupLastLsn -or
            ($State.CutoffReferenceType -eq 'QuiescedSourceCapture' -and
                ($resumeReference.Ready -ne $true -or
                 $resumeReference.SourceTrafficDrained -ne $true -or
                 $resumeReference.TransactionCheckAuthorized -ne $true -or
                 -not $resumeCountIsValid -or
                 $resumeActiveTransactionCount -ne 0))) {
            throw 'Conflicting observed state: the recorded pre-tail cutoff validation reference failed authoritative resume validation.'
        }
        $candidate='SourceRestoring'
    }
    $blobReady = $tailReady -and
        $observed.FinalBlobPresent -eq $true -and
        $observed.FinalBlobVerified -eq $true
    if ($blobReady) { $candidate='FinalFileUploaded' }
    $readable = $blobReady -and
        $observed.FinalFileReadableByLrs -eq $true
    if ($readable) { $candidate='FinalFileReadable' }
    $finalRestored = $readable -and
        $observed.LastRestoredFile -ceq $State.FinalBackupName
    if ($finalRestored) {
        $State.LastRestoredFile = $observed.LastRestoredFile; $candidate='FinalFileRestored'
    }
    $completionAccepted = $finalRestored -and
        $observed.CompletionStatus -in @('Accepted','Completed')
    if ($completionAccepted) { $candidate='CompletionAccepted' }
    $phasePrerequisiteSatisfied = @{
        JobStoppedAndDisabled = $jobStopped
        SourceRestoring = $tailReady
        FinalFileUploaded = $blobReady
        FinalFileReadable = $readable
        FinalFileRestored = $finalRestored
        CompletionAccepted = $completionAccepted
        TargetOnline = $State.OnlinePostconditionsReconciled -eq $true
    }
    if ($phasePrerequisiteSatisfied.ContainsKey($State.Phase) -and
        $phasePrerequisiteSatisfied[$State.Phase] -ne $true) {
        throw "Conflicting observed state: persisted phase '$($State.Phase)' no longer satisfies its cumulative authoritative postconditions."
    }
    # TargetOnline is assigned only by the CompletionAccepted handler after an
    # authoritative Completed status and cutoff-reference validation.
    if ($candidate -and $rank.ContainsKey($State.Phase) -and
        $rank[$candidate] -gt $rank[$State.Phase]) { $State.Phase=$candidate }
}

function Invoke-LrsMonitoringCycle {
    param([hashtable] $State, [string] $UserCommand,
          [Parameter(Mandatory)] [scriptblock] $GetLocalBackups,
          [Parameter(Mandatory)] [scriptblock] $GetBlobBackups,
          [Parameter(Mandatory)] [scriptblock] $CopyBackup,
          [Parameter(Mandatory)] [scriptblock] $GetLrsStatus,
            [Parameter(Mandatory)] [string] $CheckpointPath,
            [Parameter(Mandatory)] [string] $CurrentStorageBlobEndpoint,
            [Parameter(Mandatory)] [string] $CurrentStorageCredentialName,
            [Parameter(Mandatory)] [string] $CurrentStorageContainerUri)

        Assert-LrsCheckpointStorageBinding $State $CurrentStorageBlobEndpoint `
          $CurrentStorageCredentialName $CurrentStorageContainerUri
    if ($State.Phase -ne 'Monitoring') { throw "Monitoring requires phase Monitoring; observed '$($State.Phase)'." }
    $local = @(& $GetLocalBackups $State | Where-Object Stable)
    $blob = @(& $GetBlobBackups $State)
    $duplicateLocal = @($local | Group-Object Name -CaseSensitive | Where-Object Count -gt 1)
    $duplicateBlob = @($blob | Group-Object Name -CaseSensitive | Where-Object Count -gt 1)
    if ($duplicateLocal -or $duplicateBlob) { throw 'Duplicate immutable backup names were observed in the local or Blob inventory.' }
    $localByName = @{}; foreach ($item in $local) { $localByName[$item.Name] = $item }
    $blobByName = @{}; foreach ($item in $blob) { $blobByName[$item.Name] = $item }
    $unexpectedBlob = @($blob | Where-Object { -not $localByName.ContainsKey($_.Name) })
    if ($unexpectedBlob) { throw "Unexpected Blob backup '$($unexpectedBlob[0].Name)' has no exact verified local-chain entry." }

    foreach ($backup in ($local | Sort-Object BackupSetId)) {
        if ($blobByName.ContainsKey($backup.Name)) {
            if ([long]$blobByName[$backup.Name].Length -ne [long]$backup.Length) {
                throw "Blob '$($backup.Name)' is partial or differs from the immutable local file."
            }
            continue
        }
        $State.PendingMutation = "Upload:$($backup.Name)"
        Save-LrsCheckpointAtomic $State $CheckpointPath
        & $CopyBackup $State $backup
        $verifiedBlob = @(& $GetBlobBackups $State | Where-Object Name -CEQ $backup.Name)
        if ($verifiedBlob.Count -ne 1 -or [long]$verifiedBlob[0].Length -ne [long]$backup.Length) {
            throw "AzCopy completed but exact Blob verification failed for '$($backup.Name)'."
        }
        $State.PendingMutation = $null
        Add-LrsEvidence $State 'BackupUploaded' @{ Name = $backup.Name; Length = $backup.Length }
        Save-LrsCheckpointAtomic $State $CheckpointPath
    }

    $lrs = & $GetLrsStatus $State
    if ($lrs.Status -in @('Failed', 'Blocked')) { throw "LRS is '$($lrs.Status)': $($lrs.Error)" }
    $State.LastRestoredFile = $lrs.LastRestoredFile
    Add-LrsEvidence $State 'MonitoringCycleCompleted' @{ LastRestoredFile = $lrs.LastRestoredFile }

    if ($UserCommand -ceq 'cutover') {
        $State.Phase = 'CutoverDisclaimerPending'
    } elseif ($UserCommand -notin @('', 'monitor')) {
        throw "Expected exact command 'monitor' or 'cutover'."
    }
    Save-LrsCheckpointAtomic $State $CheckpointPath
    [pscustomobject]@{ Phase = $State.Phase; NextPollMinutes = $State.PollMinutes; Options = @('monitor', 'cutover') }
}

function Invoke-LrsCutoverStep {
    param([hashtable] $State, [string] $UserInput,
          [Parameter(Mandatory)] [hashtable] $Adapter,
        [Parameter(Mandatory)] [string] $CheckpointPath,
        [Parameter(Mandatory)] [string] $CurrentStorageBlobEndpoint,
        [Parameter(Mandatory)] [string] $CurrentStorageCredentialName,
        [Parameter(Mandatory)] [string] $CurrentStorageContainerUri)

    Assert-LrsCheckpointStorageBinding $State $CurrentStorageBlobEndpoint `
      $CurrentStorageCredentialName $CurrentStorageContainerUri
    try {
        Sync-LrsObservedCutoverState $State $Adapter
        Save-LrsCheckpointAtomic $State $CheckpointPath

        switch ($State.Phase) {
            'CutoverDisclaimerPending' {
                $expected = Get-CutoverDisclaimerPhrase $State
                if ($UserInput -cne $expected) { return [pscustomobject]@{ Phase=$State.Phase; RequiredPhrase=$expected } }
                $State.DisclaimerAccepted = $true
                $State.Phase = 'CutoverConfirmationPending'
                Add-LrsEvidence $State 'CutoverDisclaimerAccepted'
            }
            'CutoverConfirmationPending' {
                $expected = Get-CutoverConfirmationPhrase $State
                if ($UserInput -cne $expected) { return [pscustomobject]@{ Phase=$State.Phase; RequiredPhrase=$expected } }
                if (-not $State.DisclaimerAccepted) { throw 'Cutover disclaimer was not accepted.' }
                $State.CutoverConfirmed = $true
                $State.Phase = 'CutoverConfirmed'
                Add-LrsEvidence $State 'CutoverConfirmed' @{ FinalBackupName=$State.FinalBackupName }
            }
            'AwaitingManualIntervention' {
                $expected = "CUTOVER REMEDIATION COMPLETE $($State.SourceDatabase)"
                if ($UserInput -cne $expected) { return [pscustomobject]@{ Phase=$State.Phase; RequiredPhrase=$expected; Steps=$State.ManualSteps } }
                $State.ManualReason = $null; $State.ManualSteps = @(); $State.Phase = 'CutoverConfirmed'
                Add-LrsEvidence $State 'ManualRemediationClaimedComplete'
            }
            'CutoverConfirmed' {
                $observed = & $Adapter.Observe $State
                $State.JobWasEnabled = $observed.JobEnabled
                $State.PendingMutation = 'StopAndDisableJob'; Save-LrsCheckpointAtomic $State $CheckpointPath
                & $Adapter.StopAndDisableJob $State
                $observed = & $Adapter.Observe $State
                if ($observed.JobEnabled -ne $false -or $observed.JobRunning -ne $false) {
                    throw 'SQL Agent migration job is still enabled or running after stop-and-disable.'
                }
                $State.PendingMutation = $null; $State.Phase = 'JobStoppedAndDisabled'
            }
            'JobStoppedAndDisabled' {
                $observed = & $Adapter.Observe $State
                if ($observed.JobEnabled -ne $false -or $observed.JobRunning -ne $false) {
                    throw 'SQL Agent migration job is still enabled or still running before the tail backup.'
                }
                $hadRecordedReference = -not [string]::IsNullOrWhiteSpace(
                    [string]$State.CutoffReferenceType
                )
                if (-not $hadRecordedReference) {
                    $sourceEvidence = & $Adapter.CaptureCutoffSourceEvidence $State
                } else {
                    $sourceEvidence = & $Adapter.ValidateCutoffReference $State
                }
                if ($null -eq $sourceEvidence -or
                    $sourceEvidence.Type -notin @(
                        'QuiescedSourceCapture',
                        'RestoredCutoffCopy'
                    ) -or
                    [string]::IsNullOrWhiteSpace(
                        [string]$sourceEvidence.Location
                    ) -or
                    [string]::IsNullOrWhiteSpace(
                        [string]$sourceEvidence.Hash
                    ) -or
                    [string]$sourceEvidence.DatabaseIdentity -cne
                        $State.SourceDatabaseIdentity -or
                    [string]$sourceEvidence.DatabaseName -cne
                        $State.SourceDatabase -or
                    [string]$sourceEvidence.FinalBackupName -cne
                        $State.FinalBackupName) {
                    throw 'A cutoff-consistent source evidence package or approved restored-copy plan is required before the tail backup.'
                }
                if ($hadRecordedReference -and
                    ([string]$sourceEvidence.Type -cne
                        $State.CutoffReferenceType -or
                     [string]$sourceEvidence.Location -cne
                        $State.CutoffReferenceLocation -or
                     [string]$sourceEvidence.Hash -cne
                        $State.CutoffReferenceHash)) {
                    throw 'Conflicting observed state: the recorded pre-tail cutoff validation reference changed during authoritative revalidation.'
                }
                $activeTransactionCount = 0L
                $hasValidActiveTransactionCount =
                    $null -ne $sourceEvidence.PSObject.Properties[
                        'ActiveTransactionCount'
                    ] -and
                    [long]::TryParse(
                        [string]$sourceEvidence.ActiveTransactionCount,
                        [ref]$activeTransactionCount
                    )
                $hasTransactionCheckResult =
                    $null -ne $sourceEvidence.PSObject.Properties[
                        'TransactionCheckAuthorized'
                    ] -and
                    $sourceEvidence.TransactionCheckAuthorized -in @(
                        $true,
                        $false
                    )
                $transactionCheckAuthorized =
                    $hasTransactionCheckResult -and
                    $sourceEvidence.TransactionCheckAuthorized -eq $true
                $explicitProceedDecision = $null
                if ($null -ne $sourceEvidence.PSObject.Properties[
                        'ExplicitProceedDecision'
                    ] -and
                    -not [string]::IsNullOrWhiteSpace(
                        [string]$sourceEvidence.ExplicitProceedDecision
                    )) {
                    $explicitProceedDecision =
                        [string]$sourceEvidence.ExplicitProceedDecision
                }
                if ($null -ne $explicitProceedDecision -and
                    $explicitProceedDecision -cne
                        'ProceedWithFinalLogBackup') {
                    throw 'The recorded explicit cutover decision is not recognized.'
                }
                if ($sourceEvidence.Type -eq 'QuiescedSourceCapture' -and
                    ($sourceEvidence.Ready -ne $true -or
                     $sourceEvidence.SourceTrafficDrained -ne $true -or
                     -not $hasTransactionCheckResult -or
                     -not $transactionCheckAuthorized -or
                     -not $hasValidActiveTransactionCount -or
                     $activeTransactionCount -ne 0 -or
                     $null -ne $explicitProceedDecision -or
                     [string]::IsNullOrWhiteSpace(
                         [string]$sourceEvidence.Hash
                     ))) {
                    throw 'The quiesced source evidence package is incomplete or not immutable.'
                }
                if ($sourceEvidence.Type -eq 'RestoredCutoffCopy' -and
                    (-not $hasTransactionCheckResult -or
                     ($transactionCheckAuthorized -and
                        (-not $hasValidActiveTransactionCount -or
                         $activeTransactionCount -lt 0)) -or
                     ((-not $transactionCheckAuthorized -or
                        $activeTransactionCount -gt 0) -and
                        $explicitProceedDecision -cne
                            'ProceedWithFinalLogBackup'))) {
                    throw 'The restored-copy plan does not record the active-transaction check result and required explicit proceed decision.'
                }
                $State.CutoffReferenceType = $sourceEvidence.Type
                $State.CutoffReferenceLocation = $sourceEvidence.Location
                $State.CutoffReferenceHash = $sourceEvidence.Hash
                $State.CutoffReferenceReady =
                    $sourceEvidence.Type -eq 'QuiescedSourceCapture'
                $State.SourceTrafficDrained =
                    $sourceEvidence.SourceTrafficDrained -eq $true
                $State.ActiveTransactionCheckAuthorized =
                    $transactionCheckAuthorized
                $State.ActiveTransactionCount = if (
                    $hasValidActiveTransactionCount
                ) { $activeTransactionCount } else { $null }
                $State.ExplicitProceedDecision = $explicitProceedDecision
                if (-not ($State.Evidence | Where-Object {
                            $_.Event -ceq 'CutoffSourceEvidenceCaptured'
                        })) {
                    Add-LrsEvidence $State 'CutoffSourceEvidenceCaptured' @{
                        Type = $State.CutoffReferenceType
                        Location = $State.CutoffReferenceLocation
                        Hash = $State.CutoffReferenceHash
                        SourceTrafficDrained = $State.SourceTrafficDrained
                        TransactionCheckAuthorized =
                            $State.ActiveTransactionCheckAuthorized
                        ActiveTransactionCount =
                            $State.ActiveTransactionCount
                        ExplicitProceedDecision =
                            $State.ExplicitProceedDecision
                    }
                }
                Save-LrsCheckpointAtomic $State $CheckpointPath
                $State.PendingMutation = 'TailBackupNoRecovery'; Save-LrsCheckpointAtomic $State $CheckpointPath
                $tail = & $Adapter.TakeTailBackup $State
                if ($tail.Name -cne $State.FinalBackupName -or $tail.Stable -ne $true) {
                    throw 'Tail-log backup did not produce the exact stable approved final file.'
                }
                if ([string]::IsNullOrWhiteSpace(
                        [string]$tail.CompletionUtc
                    ) -or
                    [string]::IsNullOrWhiteSpace([string]$tail.LastLsn)) {
                    throw 'Tail-log backup did not return its completion time and final LSN.'
                }
                $State.FinalBackupCompletionUtc =
                    [string]$tail.CompletionUtc
                $State.FinalBackupLastLsn = [string]$tail.LastLsn
                $State.PendingMutation = $null
                $observed = & $Adapter.Observe $State
                if ($observed.SourceState -ne 'RESTORING') { throw "Unexpected source state '$($observed.SourceState)' after tail-log backup." }
                $State.Phase = 'SourceRestoring'
            }
            'SourceRestoring' {
                $State.PendingMutation = 'UploadAllRemaining'; Save-LrsCheckpointAtomic $State $CheckpointPath
                & $Adapter.UploadAllRemaining $State
                $observed = & $Adapter.Observe $State
                if ($observed.FinalBlobPresent -ne $true -or $observed.FinalBlobVerified -ne $true) {
                    throw 'Final Blob is absent, partial, or not verified after upload.'
                }
                $State.PendingMutation = $null; $State.Phase = 'FinalFileUploaded'
            }
            'FinalFileUploaded' {
                $observed = & $Adapter.Observe $State
                if ($observed.FinalFileReadableByLrs -ne $true) { throw 'LRS cannot read the exact final backup file.' }
                $State.Phase = 'FinalFileReadable'
            }
            'FinalFileReadable' {
                $observed = & $Adapter.Observe $State
                if ($observed.LastRestoredFile -cne $State.FinalBackupName) {
                    throw "LRS restored '$($observed.LastRestoredFile)' but not exact final file '$($State.FinalBackupName)'."
                }
                $State.LastRestoredFile = $observed.LastRestoredFile; $State.Phase = 'FinalFileRestored'
            }
            'FinalFileRestored' {
                $State.PendingMutation = 'CompleteLrs'; Save-LrsCheckpointAtomic $State $CheckpointPath
                & $Adapter.CompleteLrs $State
                $State.PendingMutation = $null
                $observed = & $Adapter.Observe $State
                if ($observed.CompletionStatus -notin @('Accepted','Completed')) { throw 'LRS completion request was not accepted.' }
                $State.Phase = 'CompletionAccepted'
            }
            'CompletionAccepted' {
                $observed = & $Adapter.Observe $State
                if ($observed.SourceState -cne 'RESTORING' -or
                    $observed.TailBackupExists -ne $true -or
                    $observed.TailBackupVerified -ne $true -or
                    $observed.TailBackupName -cne
                        $State.FinalBackupName -or
                    [string]$observed.TailBackupCompletionUtc -cne
                        $State.FinalBackupCompletionUtc -or
                    [string]$observed.TailBackupLastLsn -cne
                        $State.FinalBackupLastLsn -or
                    $observed.FinalBlobPresent -ne $true -or
                    $observed.FinalBlobVerified -ne $true -or
                    $observed.FinalFileReadableByLrs -ne $true -or
                    $observed.LastRestoredFile -cne
                        $State.FinalBackupName -or
                    $observed.TargetContextMatches -ne $true) {
                    throw 'Conflicting observed state: cumulative cutover postconditions or the immutable target context no longer match.'
                }
                if ($observed.CompletionStatus -cne 'Completed') {
                    if ($State.OnlinePostconditionsReconciled -eq $true) {
                        throw 'Conflicting observed state: LRS regressed from Completed during final reconciliation.'
                    }
                    throw 'Conflicting observed state: LRS has not reached authoritative Completed status during final reconciliation.'
                }
                if ($observed.TargetOnline -ne $true) {
                    if ($State.OnlinePostconditionsReconciled -eq $true) {
                        throw 'Conflicting observed state: the target became unavailable during final reconciliation.'
                    }
                    throw 'Conflicting observed state: LRS completion was accepted but the target database remains unavailable.'
                }
                $validationState = $State
                $expectedReferenceLocation =
                    $State.CutoffReferenceLocation
                $expectedReferenceHash = $State.CutoffReferenceHash
                if ($State.CutoffReferenceType -eq 'RestoredCutoffCopy' -and
                    $State.CutoffReferenceReady -ne $true) {
                    $preparedReference =
                        & $Adapter.PrepareCutoffReference $State
                    if ($null -eq $preparedReference -or
                        [string]::IsNullOrWhiteSpace(
                            [string]$preparedReference.Location
                        ) -or
                        [string]::IsNullOrWhiteSpace(
                            [string]$preparedReference.Hash
                        )) {
                        throw 'The restored cutoff validation copy could not be prepared.'
                    }
                    $expectedReferenceLocation =
                        [string]$preparedReference.Location
                    $expectedReferenceHash =
                        [string]$preparedReference.Hash
                    $validationState = [hashtable]$State.Clone()
                    $validationState.CutoffReferenceLocation =
                        $expectedReferenceLocation
                    $validationState.CutoffReferenceHash =
                        $expectedReferenceHash
                }
                $reference =
                    & $Adapter.ValidateCutoffReference $validationState
                if ($null -eq $reference -or
                    $reference.Ready -ne $true -or
                    [string]::IsNullOrWhiteSpace(
                        [string]$reference.Location
                    ) -or
                    [string]::IsNullOrWhiteSpace(
                        [string]$reference.Hash
                    ) -or
                    [string]$reference.Location -cne
                        $expectedReferenceLocation -or
                    [string]$reference.Hash -cne
                        $expectedReferenceHash -or
                    [string]$reference.Type -cne
                        $State.CutoffReferenceType -or
                    [string]$reference.DatabaseIdentity -cne
                        $State.SourceDatabaseIdentity -or
                    [string]$reference.DatabaseName -cne
                        $State.SourceDatabase -or
                    [string]$reference.FinalBackupName -cne
                        $State.FinalBackupName -or
                    [string]$reference.FinalBackupCompletionUtc -cne
                        $State.FinalBackupCompletionUtc -or
                    [string]$reference.FinalBackupLastLsn -cne
                        $State.FinalBackupLastLsn) {
                    throw 'Conflicting observed state: cutoff-consistent validation evidence is unavailable or differs from the frozen reference.'
                }
                $State.CutoffReferenceLocation = $reference.Location
                $State.CutoffReferenceHash = $reference.Hash
                $State.CutoffReferenceReady = $true
                $finalObserved = & $Adapter.Observe $State
                if ($finalObserved.JobEnabled -ne $false -or
                    $finalObserved.JobRunning -ne $false -or
                    $finalObserved.SourceState -cne 'RESTORING' -or
                    $finalObserved.TailBackupExists -ne $true -or
                    $finalObserved.TailBackupVerified -ne $true -or
                    $finalObserved.TailBackupName -cne
                        $State.FinalBackupName -or
                    [string]$finalObserved.TailBackupCompletionUtc -cne
                        $State.FinalBackupCompletionUtc -or
                    [string]$finalObserved.TailBackupLastLsn -cne
                        $State.FinalBackupLastLsn -or
                    $finalObserved.FinalBlobPresent -ne $true -or
                    $finalObserved.FinalBlobVerified -ne $true -or
                    $finalObserved.FinalFileReadableByLrs -ne $true -or
                    $finalObserved.LastRestoredFile -cne
                        $State.FinalBackupName -or
                    $finalObserved.CompletionStatus -cne 'Completed' -or
                    $finalObserved.TargetOnline -ne $true -or
                    $finalObserved.TargetContextMatches -ne $true) {
                    $State.CutoffReferenceReady = $false
                    throw 'Conflicting observed state: authoritative cutover postconditions changed before TargetOnline could be committed.'
                }
                Add-LrsEvidence $State 'CutoffReferenceValidated' @{
                    Type = $State.CutoffReferenceType
                    Location = $State.CutoffReferenceLocation
                    Hash = $State.CutoffReferenceHash
                    LastLsn = $State.FinalBackupLastLsn
                }
                $State.Phase = 'TargetOnline'; Add-LrsEvidence $State 'CutoverCompleted'
            }
            'TargetOnline' { }
            default { throw "Unsupported cutover phase '$($State.Phase)'." }
        }
    } catch {
        $message = $_.Exception.Message
        $manual = $message -match '(?i)(permission|denied|in use|exclusive|connection|still enabled|still running|unexpected source state|tail-log)'
        if ($manual) {
            Set-LrsManualIntervention $State $message (Get-LrsManualRemediationSteps $State $message)
        } else {
            Add-LrsEvidence $State 'CutoverBlocked' @{ Reason=$message }
        }
        Save-LrsCheckpointAtomic $State $CheckpointPath
        if (-not $manual) { throw }
    }

    Save-LrsCheckpointAtomic $State $CheckpointPath
    [pscustomobject]@{ Phase=$State.Phase; ManualReason=$State.ManualReason; Steps=$State.ManualSteps }
}

# SIG # Begin signature block
# MIInUwYJKoZIhvcNAQcCoIInRDCCJ0ACAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAJKPG4dkfGedaU
# OlC2ZBn8PTpmEanNZRRh8yAd0X62iqCCDMkwggYEMIID7KADAgECAhMzAAACHPrN
# xZvoL37EAAAAAAIcMA0GCSqGSIb3DQEBCwUAMFcxCzAJBgNVBAYTAlVTMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jvc29mdCBD
# b2RlIFNpZ25pbmcgUENBIDIwMjQwHhcNMjYwNDE2MTg1OTQxWhcNMjcwNDE1MTg1
# OTQxWjB0MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UE
# BxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMR4wHAYD
# VQQDExVNaWNyb3NvZnQgQ29ycG9yYXRpb24wggEiMA0GCSqGSIb3DQEBAQUAA4IB
# DwAwggEKAoIBAQDVsZfgOKmM31HPfoWOoNEiw0SlCiIxUMC0I9NMWbucKOw/e9lP
# oAoehQVu6SG65V4EPzrYsnBnFPNoi4/HoOdjhz1qkrEt4I6tEcxXU6oOeY9zGveC
# /3iBeuhLYxM3M/PkcUoebF+Nednm8OkdSPoDu8imViHPQq/8CQUu0WRR4rE+dMRf
# rpVqfmNi2qWCX94T4MsepijGVkwE//tJg0ryAiYdHT34LSnlG/RSBZmQRGWZ5g8j
# qnKjRParSqMft1gvjuUTVgtWNZfgcLFSK5Wa0myrq8OPcgTGGsRgun+tnSS+IxDT
# xVsAPH1OzvPjwomguByhUe/OcvUN0D5Wmp7xAgMBAAGjggGqMIIBpjAOBgNVHQ8B
# Af8EBAMCB4AwHwYDVR0lBBgwFgYKKwYBBAGCN0wIAQYIKwYBBQUHAwMwHQYDVR0O
# BBYEFNoH7a2YDjOSwpkp6DHcmUS7J+0yMFQGA1UdEQRNMEukSTBHMS0wKwYDVQQL
# EyRNaWNyb3NvZnQgSXJlbGFuZCBPcGVyYXRpb25zIExpbWl0ZWQxFjAUBgNVBAUT
# DTIzMDAxMis1MDc1NjkwHwYDVR0jBBgwFoAUf1k/VCHarU/vBeXmo9ctBpQSCDEw
# YAYDVR0fBFkwVzBVoFOgUYZPaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9w
# cy9jcmwvTWljcm9zb2Z0JTIwQ29kZSUyMFNpZ25pbmclMjBQQ0ElMjAyMDI0LmNy
# bDBtBggrBgEFBQcBAQRhMF8wXQYIKwYBBQUHMAKGUWh0dHA6Ly93d3cubWljcm9z
# b2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwQ29kZSUyMFNpZ25pbmcl
# MjBQQ0ElMjAyMDI0LmNydDAMBgNVHRMBAf8EAjAAMA0GCSqGSIb3DQEBCwUAA4IC
# AQAUnEqhaRXe0T3hIJjvdQErEkrA/7bByjn6t5IArODkkRjzkYwtKMc2yYj2quaN
# rLutWw2YZcngKPy1b71YyDJQTy4NDRwaSh9Tw5thrk3NmcPrAHia5vtcBJ1CgtKK
# 7mQbIcQ22d/N3813ayCDDFewu1+jsZmX+r/aTEqaOM4TVxVtRSkuCy8nAXKuChOK
# Li/zA4XuH8iEYqIsj2YoNaeSxVmeGiERXpKdo3dDmYi0kO5w2D8VS4c3+9h6gElY
# BaAAg/dYErBg27qT3vv0zRDJhJufvCNylA8S7/+8H5E/PV5cng6na9VV/w9OV3qu
# uND6zdGa2EX38Glp50F9AIQk3p2xXmcvorDeM4XJ7UlWYBi6g80J1SSOQnInCYFE
# msfUNn3+1AaTJKSJL83quKArTac2pKhu0Yzzzrzo6HrsRiQKzpnRBb1/dMa6P3hz
# 75XbMRBctNsFhZC07WCmjExdLg2eHW5uV0TY8D5+6wozJf7vF3+WHkYPO85Z+BC6
# U4FkNbYNycZ9cE4j1tXRdyDCfml6c0HWPHjNVDObrv9lKt3qUqFpX38VCqVCyNOO
# 1UcXfQiVjJw32U2WUKZjt/neJKHEBsm9kFsLuWzkQ53+qcaSaytmsCnk2gOglrlD
# 5d3kKyvvAw+rzm0lT8K38P6PLxfZQHhu4W8dV7Av8N2ZmDCCBr0wggSloAMCAQIC
# EzMAAAA5O7Y3Gb8GHWcAAAAAADkwDQYJKoZIhvcNAQEMBQAwgYgxCzAJBgNVBAYT
# AlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBS
# b290IENlcnRpZmljYXRlIEF1dGhvcml0eSAyMDExMB4XDTI0MDgwODIwNTQxOFoX
# DTM2MDMyMjIyMTMwNFowVzELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29m
# dCBDb3Jwb3JhdGlvbjEoMCYGA1UEAxMfTWljcm9zb2Z0IENvZGUgU2lnbmluZyBQ
# Q0EgMjAyNDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBANgBnB7jOMeq
# lRYHNa265v4IY9fH8TKhemHfPINe1gpLaV3dhg324WwH06LcHbpnsBukCDNitryo
# 0dtS/EW6I/yEL/bLSY8hKpbfQuWusBPr9qazYcDxCW/qnjb5JsI1s8bNOg3bVATv
# QVL4tcf03aTycsz8QeCdM0l/yHRObJ9QqazM1r6VPEOJ7LL+uEEb73w6QCuhs89a
# 1uv1zerOYMnsneRRwCbpyW11IcggU0cRKDDq1pjVJzIbIF6+oiXXbReOsgeI8zu1
# FyQfK0fVkaya8SmVHQ/tOf23mZ4W9k0Ri22QW9p3UgSC5OUDktKxxcCmGL6tXLfO
# GSWHIIV4YrTJTT6PNty5REojHJuZHArkF9VnHTERWoTjAzfI3kP+5b4alUdhgAZ7
# ttOu1bVnXfHaqPYl2rPs20ji03LOVWsh/radgE17es5hL+t6lV0eVHrVhsssROWJ
# uz2MXMCt7iw7lFPG9LXKGjsmonn2gotGdHIuEg5JnJMJVmixd5LRlkmgYRZKzhxS
# CwyoGIq0PhaA7Y+VPct5pCHkijcIIDm0nlkK+0KyepolcqGm0T/GYQRMhHJlGOOm
# VQop36wUVUYklUy++vDWeEgEo4s7hxN6mIbf2MSIQ/iIfMZgJxC69oukMUXCrOC3
# SkE/xIkgpfl22MM1itkZ35nNXkMolU1lAgMBAAGjggFOMIIBSjAOBgNVHQ8BAf8E
# BAMCAYYwEAYJKwYBBAGCNxUBBAMCAQAwHQYDVR0OBBYEFH9ZP1Qh2q1P7wXl5qPX
# LQaUEggxMBkGCSsGAQQBgjcUAgQMHgoAUwB1AGIAQwBBMA8GA1UdEwEB/wQFMAMB
# Af8wHwYDVR0jBBgwFoAUci06AjGQQ7kUBU7h6qfHMdEjiTQwWgYDVR0fBFMwUTBP
# oE2gS4ZJaHR0cDovL2NybC5taWNyb3NvZnQuY29tL3BraS9jcmwvcHJvZHVjdHMv
# TWljUm9vQ2VyQXV0MjAxMV8yMDExXzAzXzIyLmNybDBeBggrBgEFBQcBAQRSMFAw
# TgYIKwYBBQUHMAKGQmh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2kvY2VydHMv
# TWljUm9vQ2VyQXV0MjAxMV8yMDExXzAzXzIyLmNydDANBgkqhkiG9w0BAQwFAAOC
# AgEAFJQfOChP7onn6fLIMKrSlN1WYKwDFgAddymOUO3FrM8d7B/W/iQ6DxXsDn7D
# 5W4wMwYeLystcEqfkjz4NURRgazyMu5yRzQh4LqjA4tStTcJh1opExo7nn5PuPBY
# nbu0+THSuVHTe0VTTPVhily/piFrDo3axQ9P4C+Ol5yet+2gTfekICS5xS+cYfSI
# vgn0JksVBVMYVI5QFu/qhnLhsEFEUzG8fvv0hjgkO+lkpV9ty6GkN4vdnd7ya6Q6
# aR9y34aiM1qmxaxBi6OUnyNl6fkuun/diTFnYDLTppOkr/mg5WSfCiDVMNCxtj4w
# PKC5OmHm1DQIt/MNokbbH3UGsFP1QbzsLocuSqLCvH09Io3fDPTmscR9Y75G4qX7
# RTX8AdBPo0I6OEojf39zuFZt0qOHm65YWQE69cZM2ueE1MB05dNNgHK9gTE7zKvK
# /fg8B2qjW88MT/WF5V5uvZGtqa9FSL2RazArA+rDPuf6JGYz4HpgMZHB4S6szWSK
# YBv0VisCzfxgeU+dquXW9bd0auYlOB58DPcOYKdc3Se94g+xL4pcEhbB54JOgAkw
# YTu/9dLeH2pDqeJZAABVDWRQCaXfO5LgyKwKCLYXpigrZYCjUSBcr+Ve8PFWMhVT
# Ql0v4q8J/AUmQN5W4n101cY2L4A7GTQG1h32HHAvfQESWP0xghngMIIZ3AIBATBu
# MFcxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# KDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIc
# +s3Fm+gvfsQAAAAAAhwwDQYJYIZIAWUDBAIBBQCggZAwGQYJKoZIhvcNAQkDMQwG
# CisGAQQBgjcCAQQwLwYJKoZIhvcNAQkEMSIEINYn8ObMqLuS+MvpoSvE0/Ik/51f
# +B1Y06SsWYiGsKb2MEIGCisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBv
# AGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAE
# ggEAkTZtCbBoZwOaFRVtOyQr8lHOBEv9hjC9XpPmz65ExN1ULCA5oOgli16mq+1I
# VzcYetB20YrbgzcMOr5WNEfFfA8xAzO9v9m1htwVu4y9vRkCM3XqBC57hJ3x3caz
# GPGQ7VbRy3ME92kRC2DPGRWugF6tui742oKy/60G/J3Isow6wlvwLxmJ/rupBSng
# 6l6H+PJMkRMKXLpUbaKCusXi+WkCj9KJTWKQR+mlMTpIuHfDmPetvquxIR86hVCv
# hVqlyulE8LQ5Z1A39lyLXKK45gfyugPUHX3+3FddFhLQCEJBbomQWzlevCCV5Owy
# bYDHhFu9vCbmRf64AW6EWyw/s6GCF7AwghesBgorBgEEAYI3AwMBMYIXnDCCF5gG
# CSqGSIb3DQEHAqCCF4kwgheFAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFaBgsqhkiG
# 9w0BCRABBKCCAUkEggFFMIIBQQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQC
# AQUABCA4l1kDBgSNI1sAeni1Y3UbzdtiJEirGCyqzJiet3eZOQIGavNNGbD9GBMy
# MDI2MTExMzIyMTAwNS45NjhaMASAAgH0oIHZpIHWMIHTMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFu
# ZCBPcGVyYXRpb25zIExpbWl0ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo0
# QzFBLTA1RTAtRDk0NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2Vy
# dmljZaCCEf4wggcoMIIFEKADAgECAhMzAAACNFOhZ5ThvBhHAAEAAAI0MA0GCSqG
# SIb3DQEBCwUAMHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# JjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMB4XDTI2MTAx
# NTE4Mzc0MVoXDTI4MDExMTE4Mzc0MVowgdMxCzAJBgNVBAYTAlVTMRMwEQYDVQQI
# EwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xLTArBgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJh
# dGlvbnMgTGltaXRlZDEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjRDMUEtMDVF
# MC1EOTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNlMIIC
# IjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAv1DlGvKZ5zYjHEFIq54AmeMU
# 93V3X2VTcxZ/BySJkMeKI8A9cHBMguy13bQX0VOzrw0R+GACXfqJ/C1Dnpxel0w8
# WZXI5oUKBA1raFhDUSranmSJsskUdJOGz2t+kZujCSYVqOSmJusZWFgOgrR3kG1n
# T9TO0EtYboO5CAPFPsqxeTe7M6oEZ84I/YRHW0al878rKouB1L+QOyTw9NOBjVqg
# nsd3kikvb6Md8eLc5VW2gs7sSkjQkhMz6JAA1K7lOQH9zBzRJeyspelEPvIDr/Hq
# Kf3ix/2Iu6bU69r0AgfSElK48scRLppB+4owC3+QeQHoa4Zb6bXy8ypGbRotszgH
# A1Ye8/X4OAAzTiAEilwh9feW4Sgl0Be95TCf5KqCfmb2rx+R/swujTRWBrDdcXTr
# p+P8gdPRueTTgrTvdGibOQteP0baOYOYLE1fG1MQaH8Qea+h5rf7XuTmTRp2LD//
# ufdTRLwa8znQTSzVTVoQsBmeEAriPYdMUTErc4gr6b5t9jcEjFNsDbZvXjqwxOal
# eW6rIZo8+a0MXGrd2IxZTIdnmcctt7c/BVk25br29mAxazFs2hWGc1Wird/XWl7r
# ghV1iUjPav9MVSc08AcVVeowpSvEUB/NsxAowa3Dy2EEOdASK/HkL5Pyi/EfT5Nx
# zdi19bgcVhHW6tCHpEcCAwEAAaOCAUkwggFFMB0GA1UdDgQWBBQExeMDLdFhgBUU
# I0xj7MaM+LlVAjAfBgNVHSMEGDAWgBSfpxVdAF5iXYP05dJlpxtTNRnpcjBfBgNV
# HR8EWDBWMFSgUqBQhk5odHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2Ny
# bC9NaWNyb3NvZnQlMjBUaW1lLVN0YW1wJTIwUENBJTIwMjAxMCgxKS5jcmwwbAYI
# KwYBBQUHAQEEYDBeMFwGCCsGAQUFBzAChlBodHRwOi8vd3d3Lm1pY3Jvc29mdC5j
# b20vcGtpb3BzL2NlcnRzL01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAy
# MDEwKDEpLmNydDAMBgNVHRMBAf8EAjAAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMI
# MA4GA1UdDwEB/wQEAwIHgDANBgkqhkiG9w0BAQsFAAOCAgEAknSqLDWke2i0f9l0
# YZ/VZUIQwMHqHGx+/oqKh6sjR5oMibSwrIgth02kGQv2pnpKuF3nDxPM1XR3+MjE
# tgO9WUIr25rvPZM93FPnLtbevOkqkBNvcp3dUBEDmzx3FuKgJoeCay6OXL1bgP0B
# qfYlIbWyKmqez6z8o5UvjPUYI8K1jyr42d7OqyPThBPJUsTOKG8ggT9mWj46YxKX
# xmUt4BujofSh0XKQEnrtiDRMzrGzkYV8JniewBsyWgoYqcUJOqtLyBu0EsIbHejM
# rlPVb8o2XyD8wb271tjId8PzvLVrhrfFt7MZtgSVQ3oxDYqsg41j/D8qmHJg5NLs
# 9Zlj6Z/7o1WYkZuqvLpsd6kwan7MxX729J15uE6A2ErbeuEitTaXmxtQRujS2DR6
# YSm5GIlPsGU6So8hBlrcnCFm5cfbwAHEWxLxNaGhwJjF+leTjyDbna3QHrq+p7z8
# yIsCw/ae4+LwUE8wbX8nSKnHg8536pWa0ovRZMPl/iu4H35e/MurwgXxquXnaYIW
# 9JxUOz6Db0KPGzzZAIcTFdppllplQ5ZMhvS+r6sMoQWqNpmZW4ziu6l7bcr1qFyL
# JdQzjBFvsmS95/ii13++kUhBbzyZrw8M98C3HQ9wtyNVlfmTEZKMsGqW1IlzwHzV
# YQFF5GWxBT1TckeNoyz7JfeP8z8wggdxMIIFWaADAgECAhMzAAAAFcXna54Cm0mZ
# AAAAAAAVMA0GCSqGSIb3DQEBCwUAMIGIMQswCQYDVQQGEwJVUzETMBEGA1UECBMK
# V2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0
# IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUm9vdCBDZXJ0aWZpY2F0
# ZSBBdXRob3JpdHkgMjAxMDAeFw0yMTA5MzAxODIyMjVaFw0zMDA5MzAxODMyMjVa
# MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdS
# ZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMT
# HU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMIICIjANBgkqhkiG9w0BAQEF
# AAOCAg8AMIICCgKCAgEA5OGmTOe0ciELeaLL1yR5vQ7VgtP97pwHB9KpbE51yMo1
# V/YBf2xK4OK9uT4XYDP/XE/HZveVU3Fa4n5KWv64NmeFRiMMtY0Tz3cywBAY6GB9
# alKDRLemjkZrBxTzxXb1hlDcwUTIcVxRMTegCjhuje3XD9gmU3w5YQJ6xKr9cmmv
# Haus9ja+NSZk2pg7uhp7M62AW36MEBydUv626GIl3GoPz130/o5Tz9bshVZN7928
# jaTjkY+yOSxRnOlwaQ3KNi1wjjHINSi947SHJMPgyY9+tVSP3PoFVZhtaDuaRr3t
# pK56KTesy+uDRedGbsoy1cCGMFxPLOJiss254o2I5JasAUq7vnGpF1tnYN74kpEe
# HT39IM9zfUGaRnXNxF803RKJ1v2lIH1+/NmeRd+2ci/bfV+AutuqfjbsNkz2K26o
# ElHovwUDo9Fzpk03dJQcNIIP8BDyt0cY7afomXw/TNuvXsLz1dhzPUNOwTM5TI4C
# vEJoLhDqhFFG4tG9ahhaYQFzymeiXtcodgLiMxhy16cg8ML6EgrXY28MyTZki1ug
# poMhXV8wdJGUlNi5UPkLiWHzNgY1GIRH29wb0f2y1BzFa/ZcUlFdEtsluq9QBXps
# xREdcu+N+VLEhReTwDwV2xo3xwgVGD94q0W29R6HXtqPnhZyacaue7e3PmriLq0C
# AwEAAaOCAd0wggHZMBIGCSsGAQQBgjcVAQQFAgMBAAEwIwYJKwYBBAGCNxUCBBYE
# FCqnUv5kxJq+gpE8RjUpzxD/LwTuMB0GA1UdDgQWBBSfpxVdAF5iXYP05dJlpxtT
# NRnpcjBcBgNVHSAEVTBTMFEGDCsGAQQBgjdMg30BATBBMD8GCCsGAQUFBwIBFjNo
# dHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL0RvY3MvUmVwb3NpdG9yeS5o
# dG0wEwYDVR0lBAwwCgYIKwYBBQUHAwgwGQYJKwYBBAGCNxQCBAweCgBTAHUAYgBD
# AEEwCwYDVR0PBAQDAgGGMA8GA1UdEwEB/wQFMAMBAf8wHwYDVR0jBBgwFoAU1fZW
# y4/oolxiaNE9lJBb186aGMQwVgYDVR0fBE8wTTBLoEmgR4ZFaHR0cDovL2NybC5t
# aWNyb3NvZnQuY29tL3BraS9jcmwvcHJvZHVjdHMvTWljUm9vQ2VyQXV0XzIwMTAt
# MDYtMjMuY3JsMFoGCCsGAQUFBwEBBE4wTDBKBggrBgEFBQcwAoY+aHR0cDovL3d3
# dy5taWNyb3NvZnQuY29tL3BraS9jZXJ0cy9NaWNSb29DZXJBdXRfMjAxMC0wNi0y
# My5jcnQwDQYJKoZIhvcNAQELBQADggIBAJ1VffwqreEsH2cBMSRb4Z5yS/ypb+pc
# FLY+TkdkeLEGk5c9MTO1OdfCcTY/2mRsfNB1OW27DzHkwo/7bNGhlBgi7ulmZzpT
# Td2YurYeeNg2LpypglYAA7AFvonoaeC6Ce5732pvvinLbtg/SHUB2RjebYIM9W0j
# VOR4U3UkV7ndn/OOPcbzaN9l9qRWqveVtihVJ9AkvUCgvxm2EhIRXT0n4ECWOKz3
# +SmJw7wXsFSFQrP8DJ6LGYnn8AtqgcKBGUIZUnWKNsIdw2FzLixre24/LAl4FOmR
# sqlb30mjdAy87JGA0j3mSj5mO0+7hvoyGtmW9I/2kQH2zsZ0/fZMcm8Qq3UwxTSw
# ethQ/gpY3UA8x1RtnWN0SCyxTkctwRQEcb9k+SS+c23Kjgm9swFXSVRk2XPXfx5b
# RAGOWhmRaw2fpCjcZxkoJLo4S5pu+yFUa2pFEUep8beuyOiJXk+d0tBMdrVXVAmx
# aQFEfnyhYWxz/gq77EFmPWn9y8FBSX5+k77L+DvktxW/tM4+pTFRhLy/AsGConsX
# HRWJjXD+57XQKBqJC4822rpM+Zv/Cuk0+CQ1ZyvgDbjmjJnW4SLq8CdCPSWU5nR0
# W2rRnj7tfqAxM328y+l7vzhwRNGQ8cirOoo6CGJ/2XBjU02N7oJtpQUQwXEGahC0
# HVUzWLOhcGbyoYIDWTCCAkECAQEwggEBoYHZpIHWMIHTMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFu
# ZCBPcGVyYXRpb25zIExpbWl0ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo0
# QzFBLTA1RTAtRDk0NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2Vy
# dmljZaIjCgEBMAcGBSsOAwIaAxUAVSn9cWqexOj7PU+4ciWVvBEIvEqggYMwgYCk
# fjB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQD
# Ex1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDANBgkqhkiG9w0BAQsFAAIF
# AO6hv5YwIhgPMjAyNjExMTMxNjU1NTBaGA8yMDI2MTExNDE2NTU1MFowdzA9Bgor
# BgEEAYRZCgQBMS8wLTAKAgUA7qG/lgIBADAKAgEAAgIPJAIB/zAHAgEAAgIR5jAK
# AgUA7qMRFgIBADA2BgorBgEEAYRZCgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIB
# AAIDB6EgoQowCAIBAAIDAYagMA0GCSqGSIb3DQEBCwUAA4IBAQCLmZ1hM9IxYP7i
# xEa/5uyBu9iAg/0D9KWVaYhTo7k5yBMmZ/ql6vFZgFg/UrB3wI/7LfvPe6qxTLzH
# EuhmoLoVtYkS/0MYW9jOm23HkEhkV3dcTVncbljzgHzMm9GWrUqRKVWe3fmS7T06
# P3lilRJiAM64JkNkmrVenp4jduyvNHCmW461h6VacuyFKQRxTGCtIRz3QVxvqG2q
# NowKXynD9TolqqgpTZ/665gzfqHykFIjna/HoalWvQ8wne7SrVG0u2Ax7bJatu5X
# IMdhGDkIbv/qE+APP3IT5OB7MYKVqxNpa59riqVIhdVy6Z+AN8/gKXrqX4QiOkO+
# QTzg/0d/MYIEDTCCBAkCAQEwgZMwfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldh
# c2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBD
# b3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIw
# MTACEzMAAAI0U6FnlOG8GEcAAQAAAjQwDQYJYIZIAWUDBAIBBQCgggFKMBoGCSqG
# SIb3DQEJAzENBgsqhkiG9w0BCRABBDAvBgkqhkiG9w0BCQQxIgQgU5nphxt2BMwl
# 8KziHFDqVymbWlk9le5DENRBe2Cs9ZMwgfoGCyqGSIb3DQEJEAIvMYHqMIHnMIHk
# MIG9BCBD/L2hU62ee5OvACW8VmVRbCSSWkdjwLJ5Kd3ZeyhRZDCBmDCBgKR+MHwx
# CzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRt
# b25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1p
# Y3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwAhMzAAACNFOhZ5ThvBhHAAEAAAI0
# MCIEIFCE8lLhuAuxaBEwb/dLnmOJaBwuV80RPOnpf/1ZeQhuMA0GCSqGSIb3DQEB
# CwUABIICAL9AWa9qseOiWHZ+PIhs4BWFs+KS2e9Lv7/7PPe97LT4zj8slAONySkp
# udzQrEIAM8tYSe0Zu3Bu0CUpbfY0O8l8Kxsd1FFkXJMYbbGURYvp8U6hbvDtxeAD
# uYmnXp0NM8PcQga/A35wBlXi2Z+EuxC0DZwxQLUVO3jg3V3mXdjeKZdK6Wnb4L42
# BDf1c43JdD8jJMa0KK4YxOGFsg1KYcP6y6kifZhND5kcEzGo74lt5vO8XIsEGt+W
# F7VCN6nH/JqY0XNvPPgxq+Jzd+rvYwkM7FzqU/FpJnyT68FuHiEsO/zhDyNGPesi
# phHnIxAH104TehmZlUFLbCKq33HyP0uJrNSINwtiFd0BqFsBs+cUbZLBaM0gY48i
# aX6t8GLHN2w0s7CH6ot7SQFr09xoiiSyNGh1iYQC7sCPX8YKL0U6vEZ8kUPKkFtQ
# BbytroG9CUgXvApRX++PLQO2N8OCiF8/bEQVFMv0aQWxltd1VqgRXvHEaFjf31m/
# UhbxIaZAjlPkR+8HR26YeboTAg2Zhf/v5vvQbI90PQLNoEUWECuE8PpomDu+2bUU
# R5SWECPB17z+tqC8t4kOj2lpQ2/Z4ql7h6rtKHNBAp1qaTE4s9stdzeLtnnU/60b
# v4MlmHdvuT9X/uZqCNctph14L8r+rt5yy2rjKkzLe7wpbyA6jCRP
# SIG # End signature block
