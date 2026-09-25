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
