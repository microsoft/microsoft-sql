# Local BACPAC automation — export and import

## Contents

- [3. Export each database](#3-export-each-database)
- [4. Import each local BACPAC](#4-import-each-local-bacpac)

Part of the command-execution reference set for this skill. See also: references\command-execution-setup.md.

  Save-SanitizedMigrationCheckpoint `
    -Databases $manifest -Path $manifestCheckpointPath
## 3. Export each database

Never connect to either the source or target with SQL login/SQL authentication.
Do not request, accept, retrieve, or use SQL passwords or SQL credentials. Use
only Windows Integrated authentication or Microsoft Entra authentication supported
by the workflow.

For Windows integrated authentication, the session's `sourceConnectionString`
variable (populated during the earlier authentication step, never fabricated
inline) must contain `Integrated Security=True` or `Trusted_Connection=True`. Do
not add `/SourceIntegratedSecurity`; `SqlPackage` 170.4 does not support that
argument. Validate the shared argument pattern before starting the batch and
retain the defensive check in the process wrapper.

```powershell
$sourceConnectionVariable = Get-Variable -Name sourceConnectionString `
  -ErrorAction SilentlyContinue
if (-not $sourceConnectionVariable -or -not $sourceConnectionVariable.Value) {
  throw 'Authenticate to the source first (Windows Integrated or Microsoft Entra) and provide a secure source connection string; SQL login is not supported.'
}
# This value is immutable for the batch. A fresh builder below derives each
# database-specific connection so one iteration cannot affect another.
$sourceBaseConnectionString = [string] $sourceConnectionVariable.Value

foreach ($database in @($manifest | Where-Object {
    $_.ExportStatus -eq 'Pending' -and $_.ResumeState -eq 'None'
  })) {
  if (Test-Path -LiteralPath $database.BacpacPath -PathType Leaf) {
    $database.ExportStatus = 'Failed'
    $database.ExportFailureReason =
      "A BACPAC file with the same name already exists: '$($database.BacpacPath)'."
    $database.ExportLastUpdatedUtc = [DateTime]::UtcNow
    $database.ResumeState = 'AwaitingManualRemediation'
    $database.FailureCategory = 'LocalArtifactConflict'
    $database.ManualNextAction =
      'Preserve or move the existing BACPAC outside this workflow, or restart with a new export root; then return with source remediation complete. The workflow will resume only after the intended destination path no longer exists.'
    Save-SanitizedMigrationCheckpoint `
      -Databases $manifest -Path $manifestCheckpointPath
    Write-Warning $database.ExportFailureReason
    Write-Warning "The existing file was not overwritten, renamed, deleted, or reused. Manual next action: $($database.ManualNextAction) Checkpoint: '$manifestCheckpointPath'."

    if ($databaseSelection -ne 'All') {
      throw "Export paused for '$($database.SourceDatabase)' because its BACPAC destination already exists."
    }

    Write-Warning "Skipping export '$($database.SourceDatabase)' and continuing only destinations without an existing BACPAC file."
    continue
  }

  $sourceConnectionBuilder = [System.Data.Common.DbConnectionStringBuilder]::new()
  $sourceConnectionBuilder.set_ConnectionString($sourceBaseConnectionString)
  # Replace either catalog alias unconditionally. This also prevents a base
  # connection that names master or another database from overriding the row.
  if ($sourceConnectionBuilder.ContainsKey('Database')) {
    [void] $sourceConnectionBuilder.Remove('Database')
  }
  if ($sourceConnectionBuilder.ContainsKey('Initial Catalog')) {
    [void] $sourceConnectionBuilder.Remove('Initial Catalog')
  }
  $sourceConnectionBuilder.set_Item(
    'Initial Catalog', [string] $database.SourceDatabase
  )
  $databaseSourceConnectionString =
    $sourceConnectionBuilder.get_ConnectionString()
  $database.ExportStatus = 'InProgress'
  $database.ExportLastUpdatedUtc = [DateTime]::UtcNow
  Save-SanitizedMigrationCheckpoint `
    -Databases $manifest -Path $manifestCheckpointPath
  $exportAttemptId = [Guid]::NewGuid().ToString('N')
  $temporaryBacpacPath = Join-Path -Path $database.FolderPath -ChildPath (
    '.{0}.{1}.{2}.exporting.bacpac' -f
      $database.SourceDatabase,
      $script:MigrationRunId.ToString('N'),
      $exportAttemptId
  )
  $exportArguments = @(
    '/Action:Export'
    "/SourceConnectionString:$databaseSourceConnectionString"
    "/TargetFile:$temporaryBacpacPath"
    '/OverwriteFiles:False'
    '/p:VerifyExtraction=True'
    '/p:CommandTimeout=1800'
  )
  $exportResult = Invoke-SqlPackageWithProgress `
    -DatabaseName $database.SourceDatabase -Operation Export `
    -ArgumentList $exportArguments -EvidenceRootPath $database.FolderPath `
    -ProgressFilePath $temporaryBacpacPath `
    -StatusCallback {
      $database.ExportLastUpdatedUtc = [DateTime]::UtcNow
    }
  $database.ExportAttempts = @($database.ExportAttempts) + @($exportResult)
  $database.ExportLastUpdatedUtc = [DateTime]::UtcNow
  $exportFailed = $exportResult.ExitCode -ne 0 -or
    -not (Test-Path -LiteralPath $temporaryBacpacPath -PathType Leaf)

  if ($exportFailed) {
    $database.ExportStatus = 'Failed'
    $database.ExportFailureReason = $exportResult.FailureReason
    $database.ResumeState = 'AwaitingManualRemediation'
    if (Test-AuthenticationFailure -FailureReason $exportResult.FailureReason) {
      $database.FailureCategory = 'Authentication'
      $database.ManualNextAction =
        'Verify the selected identity, source login/user permission, network/firewall route, MFA or approved secure-store entry outside this workflow; then return with authentication remediation complete.'
    } elseif (Test-UnsupportedSqlPackageArgumentFailure `
        -FailureReason $exportResult.FailureReason) {
      $database.FailureCategory = 'SqlPackageConfiguration'
      $database.ManualNextAction =
        'Review the installed SqlPackage version and correct the unsupported shared argument in the external command template; then return with source remediation complete.'
    } elseif (Test-UnsupportedSourceFailure `
        -FailureReason $exportResult.FailureReason) {
      $database.FailureCategory = 'UnsupportedSourceObject'
      $database.ManualNextAction =
        'Review the identified unsupported object in diagnostics, assess and approve the required source change, back up the source, apply and test the change outside this workflow; then return with source remediation complete.'
    } else {
      $database.FailureCategory = 'ExportFailure'
      $database.ManualNextAction =
        'Review and correct the reported failure outside this workflow; then return with source remediation complete or restart with the same export root.'
    }
    Save-SanitizedMigrationCheckpoint `
      -Databases $manifest -Path $manifestCheckpointPath
    Write-Warning "Export '$($database.SourceDatabase)' failed: $($database.ExportFailureReason) Diagnostics: '$($exportResult.DiagnosticsPath)'."
    Write-Warning "No authentication fallback, source change, substitute database restore, or other remediation was attempted. Manual next action: $($database.ManualNextAction) Checkpoint: '$manifestCheckpointPath'."

    if ($database.FailureCategory -eq 'SqlPackageConfiguration') {
      throw "Export batch stopped because the shared SqlPackage argument template is invalid. Correct it externally and resume failed/pending databases."
    }

    if ($databaseSelection -ne 'All') {
      throw "Export paused for '$($database.SourceDatabase)' pending manual remediation."
    }

    Write-Warning "Pausing failed export '$($database.SourceDatabase)' and continuing unaffected databases."
    continue
  }

  try {
    Set-BacpacExportCheckpointMetadata `
      -Database $database `
      -SourceServerIdentity $script:SourceServerIdentity `
      -TargetServerIdentity $script:TargetServerIdentity `
      -RunId $script:MigrationRunId `
      -ArtifactPath $temporaryBacpacPath
    Publish-BacpacArtifact `
      -TemporaryPath $temporaryBacpacPath `
      -DestinationPath $database.BacpacPath `
      -ExportRootPath $exportRoot
  } catch {
    $database.ExportStatus = 'Failed'
    $database.ExportFailureReason = $_.Exception.Message
    $database.ExportLastUpdatedUtc = [DateTime]::UtcNow
    $database.ResumeState = 'AwaitingManualRemediation'
    $database.FailureCategory = 'LocalArtifactConflict'
    $database.ManualNextAction =
      'Preserve the attempt BACPAC and any existing final BACPAC without modifying either, then restart with a new export root.'
    Save-SanitizedMigrationCheckpoint `
      -Databases $manifest -Path $manifestCheckpointPath
    Write-Warning "Export '$($database.SourceDatabase)' could not publish its verified attempt BACPAC: $($database.ExportFailureReason)"

    if ($databaseSelection -ne 'All') {
      throw "Export paused for '$($database.SourceDatabase)' because its verified BACPAC could not be published to a new destination."
    }

    Write-Warning "Pausing export '$($database.SourceDatabase)' and continuing unaffected databases."
    continue
  }
  $database.ExportStatus = 'Succeeded'
  $database.ResumeState = 'None'
  $database.FailureCategory = $null
  $database.ManualNextAction = $null
  Save-SanitizedMigrationCheckpoint `
    -Databases $manifest -Path $manifestCheckpointPath
  Write-Host "Export '$($database.SourceDatabase)' succeeded. BACPAC: '$($database.BacpacPath)'."
}

$exportSummary = $manifest | ForEach-Object {
  $bacpacSize = if (Test-Path -LiteralPath $_.BacpacPath -PathType Leaf) {
    $length = (Get-Item -LiteralPath $_.BacpacPath).Length
    if ($length -ge 1GB) {
      '{0:N2} GB' -f ($length / 1GB)
    } elseif ($length -ge 1MB) {
      '{0:N2} MB' -f ($length / 1MB)
    } elseif ($length -ge 1KB) {
      '{0:N2} KB' -f ($length / 1KB)
    } else {
      "$length bytes"
    }
  } else {
    'Not created'
  }

  $displayStatus = switch ($_.ExportStatus) {
    'Succeeded' { 'Success' }
    'Failed' { 'Fail' }
    'InProgress' { 'InProgress' }
    default { $_.ExportStatus }
  }

  [pscustomobject]@{
    DatabaseName = $_.SourceDatabase
    Status       = $displayStatus
    BacpacSize   = $bacpacSize
  }
}

Write-Host 'BACPAC export summary:'
$exportSummary | Format-Table -AutoSize
```

For an `All` selection, preserve the diagnostics, record the failure, and continue
with the next database. For a single-database selection, stop on failure. Include
every skipped database and its failure reason in the final report.

## 4. Import each local BACPAC

Wait until all export attempts finish, then require at least one successful export.
After authentication, set the three SKU values from the SSMS-style database
settings choice. Use the same SKU for every database in the batch. Before approval,
display the eligible database names and BACPAC paths in one table and the target
server, authentication method, service tier, service objective, maximum size, and
no-overwrite behavior in a second table. Do not repeat those values in prose.
Before starting SqlPackage, tell the user that the terminal will show a status line
every 30 seconds and a batch table after each database completes.

Validate each BACPAC only immediately before its import, not as an export gate.
Require the exact manifest path, a plausible nonzero size, and a successful result
from the BACPAC verification/checksum process configured by the operator. If any
artifact check fails, do not launch SqlPackage for that database. Mark its import
`Failed` and `AwaitingManualRemediation`, preserve the artifact and evidence, and
continue only when `SelectionMode` is `All`.

Run the wrapper in a terminal channel that streams output while the process is
active. Do not hide the entire import inside one opaque blocking command whose
output is returned only after completion. If the execution host buffers terminal
output, display or tail the current attempt's
`<database-folder>\attempts\import\<attempt-id>\status.log` at least every 30
seconds and relay its newest line. The status file is deliberately separate from
SqlPackage diagnostics, contains no command arguments or connection strings, and
is updated even when SqlPackage has not written new diagnostics.

Before displaying that approval, execute the injection-safe read-only
[target-database-preflight.sql](target-database-preflight.sql) template against
`master` through the validated Go `sqlcmd` route with the approved target
identity. Render its single `{{DATABASE_NAMES_BASE64}}` placeholder only through
[bacpac-target-preflight.ps1](bacpac-target-preflight.ps1); do not construct an
alternate inline query.

Serialize the target names as a JSON array, encode it as UTF-16LE Base64, and
insert only that restricted Base64 alphabet into the temporary SQL script. Never
concatenate raw names into SQL. Delete the script in a `finally` block. This check
must not universally require `VIEW ANY DATABASE`: an identity that can import a
database is not required to hold server-wide catalog visibility. Use the two
fields in the structured JSON result together to
distinguish exactly three states per requested name:

- **Database exists** — the name is present in the second result set. This is
  authoritative regardless of `can_view_all_databases`, because an identity
  that already has some relationship to that database (for example prior
  ownership) can see its own row even without `VIEW ANY DATABASE`.
- **Database absent** — the name is not present in the second result set and
  `can_view_all_databases = 1`. Absence is only trustworthy when the identity
  can see the full catalog; treat this only as a point-in-time preflight result.
  It does not reserve the name or prove which actor creates the target later.
- **Catalog visibility unavailable** — the name is not present and
  `can_view_all_databases = 0`. Do not treat this as absence. Pause that
  database with `FailureCategory = TargetPreflight` and require the user to
  either grant the approved identity read-only `VIEW ANY DATABASE` (or an
  equivalent least-privileged catalog-visibility grant) or independently
  confirm the name is unused, then resume.

If the query itself fails (connectivity, authentication), stop before approval
rather than assuming absence. Run the same preflight again immediately before
starting the import batch so a stale approval-time result is not reused. The
second call returns a scoped, single-use `FinalImport` receipt. Consume that
receipt directly when constructing the import candidate list; generated import
scripts must not call the preflight a third time. This query is the only basis
for classifying a target as pre-existing and skipped.

Because this workflow permits only `SqlPackage /Action:Import` to mutate the
target, the final preflight cannot reserve a database name. Another actor can
create the target after the receipt is issued and before or during import. A
successful import therefore proves only that SqlPackage completed against the
named target; it does not prove that this workflow created or owns the Azure
resource. Record success as `ImportedSuccessfully`, never as a creation or
ownership assertion.

Every `sqlcmd` preflight is bounded by `SqlcmdTimeoutSeconds`. Use 600 seconds
by default for interactive Entra browser/MFA authentication and 180 seconds for
`ActiveDirectoryDefault`; an explicit positive value overrides either default.
Keep interactive `sqlcmd` attached to the current console and capture the
structured query result with `sqlcmd -o`. Do not redirect its standard handles,
because that can prevent or hide the attended authentication flow. On timeout,
stop the exact process, pause the affected imports, save the checkpoint, and
report the timeout as a target-preflight failure.

If target authentication or this preflight fails, set each otherwise eligible
database to `ResumeState = AwaitingManualRemediation` with
`FailureCategory = Authentication` or `TargetPreflight`, save the sanitized
checkpoint, and report the selected method, sanitized error, diagnostics, and
manual identity/permission/network/MFA or catalog-visibility checks. Do not prompt
for another authentication method, refresh credentials, create a target, restore
an alternate database, or retry in the current execution. Resume only after the
user returns with `authentication remediation complete` or `target remediation
complete` and the same preflight succeeds.

The target preflight implementation is executable source, not embedded
documentation. Dot-source
[bacpac-target-preflight.ps1](bacpac-target-preflight.ps1); it renders and runs
[target-database-preflight.sql](target-database-preflight.sql). Tests execute
those files directly. The following block is orchestration that consumes those
functions:

```powershell
$nonTerminalExports = @($manifest | Where-Object {
  @('Succeeded', 'Failed') -notcontains $_.ExportStatus
})
if ($nonTerminalExports.Count -gt 0) {
  throw 'Target connectivity is blocked until every selected export has a terminal Succeeded or Failed state.'
}

$successfulExports = @($manifest | Where-Object {
  $_.ExportStatus -eq 'Succeeded'
})
if ($successfulExports.Count -eq 0) {
  throw 'No BACPAC exports succeeded; there is nothing to import.'
}

# Select target compute and size only after export. The setup reference already
# loaded the helper from the explicit installed skill reference directory. On
# resume, reuse an existing immutable selection; otherwise walk the operator
# through each dependent input.
$approvedTargetSkuCatalog = @(Get-ApprovedTargetSkuCatalog)
$checkpointVariable = Get-Variable -Name checkpoint -ErrorAction SilentlyContinue
$savedTargetConfiguration = if (
  $checkpointVariable -and
  $checkpointVariable.Value.PSObject.Properties['TargetConfiguration']
) { $checkpointVariable.Value.TargetConfiguration } else { $null }
if ($savedTargetConfiguration) {
  $approvedTargetSku = Resolve-ApprovedTargetSkuSelection `
    -ApprovedCatalog $approvedTargetSkuCatalog `
    -ServiceType $savedTargetConfiguration.ServiceType `
    -ServiceObjective $savedTargetConfiguration.ServiceObjective `
    -VCore $savedTargetConfiguration.VCore `
    -MaximumSizeGB $savedTargetConfiguration.MaximumSizeGB
  if ($approvedTargetSku.DatabaseEdition -cne
        $savedTargetConfiguration.DatabaseEdition -or
      $approvedTargetSku.DatabaseServiceObjective -cne
        $savedTargetConfiguration.DatabaseServiceObjective) {
    throw 'Checkpoint target configuration no longer resolves to its immutable approved values.'
  }
} else {
  $targetConfigurationTracker = New-TargetConfigurationInputTracker

  # Step 1: show the three friendly service-type labels and collect one value.
  $targetConfigurationTracker.ServiceType.DisplayOptions | Format-Table -AutoSize
  Set-TargetConfigurationServiceType `
    -Tracker $targetConfigurationTracker `
    -ApprovedCatalog $approvedTargetSkuCatalog `
    -ServiceType $selectedServiceType | Out-Null

  # Step 2: show only objectives valid for the selected service type.
  $targetConfigurationTracker.ServiceObjective.Options
  Set-TargetConfigurationServiceObjective `
    -Tracker $targetConfigurationTracker `
    -ApprovedCatalog $approvedTargetSkuCatalog `
    -ServiceObjective $selectedServiceObjective | Out-Null

  # Step 3: show the published vCore choices and collect an integer.
  $targetConfigurationTracker.VCore.Options
  Set-TargetConfigurationVCore `
    -Tracker $targetConfigurationTracker `
    -ApprovedCatalog $approvedTargetSkuCatalog `
    -VCore $selectedVCore | Out-Null

  # Step 4: resolve the exact SqlPackage values. MaximumSizeGB is populated
  # automatically from the catalog ceiling for the selected objective/vCore.
  $approvedTargetSku = Complete-TargetConfiguration `
    -Tracker $targetConfigurationTracker `
    -ApprovedCatalog $approvedTargetSkuCatalog
}
$script:ApprovedTargetSku = $approvedTargetSku
$databaseEdition = $approvedTargetSku.DatabaseEdition
$databaseServiceObjective = $approvedTargetSku.DatabaseServiceObjective
$databaseVCore = $approvedTargetSku.VCore
$databaseMaximumSizeGB = $approvedTargetSku.MaximumSizeGB
Save-SanitizedMigrationCheckpoint `
  -Databases $manifest -Path $manifestCheckpointPath `
  -ApprovedTargetSku $approvedTargetSku

$preflightCandidates = @($successfulExports | Where-Object {
  $_.ImportStatus -eq 'Pending' -and $_.ResumeState -eq 'None'
})
if ($preflightCandidates.Count -eq 0) {
  throw 'No pending, remediation-confirmed imports remain. Completed imports are preserved and paused imports require their stated confirmation.'
}

# Interactive Microsoft Entra is the default target-import authentication.
# An explicitly supplied ActiveDirectoryDefault value remains supported.
$targetAuthenticationVariable = Get-Variable -Name targetAuthenticationMethod `
  -ErrorAction SilentlyContinue
$targetAuthenticationMethod = if (
  -not $targetAuthenticationVariable -or
  [string]::IsNullOrWhiteSpace([string]$targetAuthenticationVariable.Value)
) { 'InteractiveEntra' } else { [string]$targetAuthenticationVariable.Value }
if ($targetAuthenticationMethod -notin @(
    'InteractiveEntra', 'ActiveDirectoryDefault')) {
  throw "Unsupported target authentication method '$targetAuthenticationMethod'."
}
$modernSqlcmd = Find-CompatibleGoSqlcmd `
  -AuthenticationMethod $targetAuthenticationMethod
if (-not $modernSqlcmd) {
  throw "No modern Go sqlcmd executable is available for '$targetAuthenticationMethod'."
}
$targetUpnVariable = Get-Variable -Name targetEntraUserPrincipalName `
  -ErrorAction SilentlyContinue
$targetEntraUserPrincipalName = if ($targetUpnVariable) {
  [string] $targetUpnVariable.Value
} else { $null }
if ($targetAuthenticationMethod -eq 'InteractiveEntra' -and
    [string]::IsNullOrWhiteSpace($targetEntraUserPrincipalName)) {
  throw 'Interactive Microsoft Entra target authentication requires the user principal name.'
}

# Run once before displaying the approval tables. After approval, execute this
# exact call again immediately before constructing the import candidate list.
$approvalPreflightReceipt =
  Invoke-TargetPreflightOrPause `
    -SqlcmdPath $modernSqlcmd.Path -ServerName $targetServerName `
    -AuthenticationMethod $targetAuthenticationMethod `
    -UserPrincipalName $targetEntraUserPrincipalName `
    -Databases $preflightCandidates -Manifest $manifest `
    -CheckpointPath $manifestCheckpointPath -Purpose Approval
$existingTargetDatabaseNames = @($approvalPreflightReceipt.ExistingNames)
# The successful preflight already proved the selected identity and route.
# Construct the equivalent secretless SqlPackage connection without launching
# a redundant standalone sqlcmd authentication process.
$targetConnectionString =
  New-TargetConnectionStringForApprovedAuthentication `
    -ServerName $targetServerName `
    -AuthenticationMethod $targetAuthenticationMethod `
    -UserPrincipalName $targetEntraUserPrincipalName
$targetConnectionBuilder = [System.Data.Common.DbConnectionStringBuilder]::new()
$targetConnectionBuilder.set_ConnectionString($targetConnectionString)
if ($targetConnectionBuilder.ContainsKey('Initial Catalog') -or
    $targetConnectionBuilder.ContainsKey('Database')) {
  throw 'The batch target connection string must not select a database.'
}
$approvalPreflightSet = [System.Collections.Generic.HashSet[string]]::new(
  [StringComparer]::OrdinalIgnoreCase
)
foreach ($name in $existingTargetDatabaseNames) {
  [void] $approvalPreflightSet.Add($name)
}
foreach ($database in $preflightCandidates) {
  if ($approvalPreflightSet.Contains($database.TargetDatabase)) {
    if ($database.TargetStateAfterImport -eq
        'PresentAfterFailureRequiresInspection') {
      $database.ImportStatus = 'Failed'
      $database.ResumeState = 'AwaitingManualRemediation'
      $database.FailureCategory = 'PartialTargetStillPresent'
      $database.ImportFailureReason =
        'The target observed after the prior failed import is still present; it is not a pre-existing skip.'
      $database.ManualNextAction =
        'Inspect and resolve the partial target outside this workflow, then return with target remediation complete.'
      Write-Warning "Import '$($database.TargetDatabase)' remains failed because its prior partial target is still present."
    } else {
      $database.ImportStatus = 'Skipped'
      $database.ImportFailureReason =
        'Target database existed before import according to the approval-time sys.databases preflight.'
      $database.TargetStateAfterImport = 'PreExisting'
      Write-Warning "Import '$($database.TargetDatabase)' is excluded from approval because the target already exists."
    }
  }
}
Save-SanitizedMigrationCheckpoint `
  -Databases $manifest -Path $manifestCheckpointPath
$preflightCandidates = @($preflightCandidates | Where-Object {
  $_.ImportStatus -eq 'Pending' -and $_.ResumeState -eq 'None'
})
if ($preflightCandidates.Count -eq 0) {
  throw 'Every pending target existed at approval-time preflight; no database remains for import approval.'
}
$revalidatedTargetSku = Resolve-ApprovedTargetSkuSelection `
  -ApprovedCatalog $approvedTargetSkuCatalog `
  -ServiceType $approvedTargetSku.ServiceType `
  -ServiceObjective $approvedTargetSku.ServiceObjective `
  -VCore $approvedTargetSku.VCore `
  -MaximumSizeGB $approvedTargetSku.MaximumSizeGB
if ($revalidatedTargetSku.ServiceType -cne $approvedTargetSku.ServiceType -or
    $revalidatedTargetSku.ServiceObjective -cne
      $approvedTargetSku.ServiceObjective -or
    $revalidatedTargetSku.VCore -ne $approvedTargetSku.VCore -or
    $revalidatedTargetSku.DatabaseEdition -cne
      $approvedTargetSku.DatabaseEdition -or
    $revalidatedTargetSku.DatabaseServiceObjective -cne
      $approvedTargetSku.DatabaseServiceObjective -or
    $revalidatedTargetSku.MaximumSizeGB -ne
      $approvedTargetSku.MaximumSizeGB) {
  throw 'The target configuration no longer matches the immutable Phase 4 approved selection.'
}
# ...display approval tables and obtain the grouped import approval here...
$finalPreflightReceipt =
  Invoke-TargetPreflightOrPause `
    -SqlcmdPath $modernSqlcmd.Path -ServerName $targetServerName `
    -AuthenticationMethod $targetAuthenticationMethod `
    -UserPrincipalName $targetEntraUserPrincipalName `
    -Databases $preflightCandidates -Manifest $manifest `
    -CheckpointPath $manifestCheckpointPath -Purpose FinalImport
$existingTargetDatabaseNames = @(
  Use-FinalTargetPreflightReceipt `
    -Receipt $finalPreflightReceipt -ServerName $targetServerName `
    -AuthenticationMethod $targetAuthenticationMethod `
    -UserPrincipalName $targetEntraUserPrincipalName `
    -DatabaseNames @($preflightCandidates.TargetDatabase)
)
# The final receipt is now consumed. Continue directly into target-state
# classification and the import loop. Do not invoke target preflight again.
$existingTargetDatabaseSet = [System.Collections.Generic.HashSet[string]]::new(
  [StringComparer]::OrdinalIgnoreCase
)
foreach ($existingTargetDatabaseName in $existingTargetDatabaseNames) {
  [void] $existingTargetDatabaseSet.Add($existingTargetDatabaseName)
}
foreach ($database in $preflightCandidates) {
  if ($existingTargetDatabaseSet.Contains($database.TargetDatabase)) {
    if ($database.TargetStateAfterImport -eq
        'PresentAfterFailureRequiresInspection') {
      $database.ImportStatus = 'Failed'
      $database.ResumeState = 'AwaitingManualRemediation'
      $database.FailureCategory = 'PartialTargetStillPresent'
      $database.ImportFailureReason =
        'The target observed after the prior failed import is still present; it is not a pre-existing skip.'
      $database.ManualNextAction =
        'Inspect and resolve the partial target outside this workflow, then return with target remediation complete.'
      Write-Warning "Import '$($database.TargetDatabase)' remains failed because its prior partial target is still present."
    } else {
      $database.ImportStatus = 'Skipped'
      $database.ImportFailureReason =
        'Target database existed before import according to sys.databases preflight.'
      $database.TargetStateAfterImport = 'PreExisting'
      Write-Warning "Import '$($database.TargetDatabase)' will be skipped: the target database existed before import."
    }
  }
}
Save-SanitizedMigrationCheckpoint `
  -Databases $manifest -Path $manifestCheckpointPath
$importCandidates = @($successfulExports | Where-Object {
  $_.ImportStatus -eq 'Pending' -and $_.ResumeState -eq 'None'
})
if ($importCandidates.Count -eq 0) {
  throw 'Every successfully exported database already exists on the target; no import was approved or attempted.'
}

$selectionMode = [string]$script:SelectionMode
if ($selectionMode -notin @('All', 'Explicit')) {
  throw 'SelectionMode must be established as All or Explicit before import.'
}
$isAllSelection = $selectionMode -ceq 'All'

function Show-ImportBatchStatus {
  param([Parameter(Mandatory)] [object[]] $Databases)

  Write-Host 'BACPAC import batch status:'
  $Databases | ForEach-Object {
    $elapsed = if ($_.ImportStartedUtc) {
      $endedUtc = if ($_.ImportCompletedUtc) {
        $_.ImportCompletedUtc
      } else {
        [DateTime]::UtcNow
      }
      ($endedUtc - $_.ImportStartedUtc).ToString('hh\:mm\:ss')
    } else {
      '-'
    }
    $detail = switch ($_.ImportStatus) {
      'Pending' { 'Waiting' }
      'InProgress' { 'SqlPackage active' }
      'Succeeded' { 'Import completed' }
      'Skipped' { 'Database exists' }
      'Failed' { 'See failure details below' }
      default { $_.ImportStatus }
    }
    $status = switch ($_.ImportStatus) {
      'Succeeded' { 'Success' }
      'Failed' { 'Fail' }
      'InProgress' { 'InProgress' }
      'Pending' { 'Pending' }
      'Skipped' { 'Skipped' }
      default { 'Unknown' }
    }

    [pscustomobject]@{
      DatabaseName = $_.TargetDatabase
      Status = $status
      Elapsed = $elapsed
      Detail = $detail
    }
  } | Format-Table -AutoSize
}

Write-Host 'Live import status will appear in this terminal every 30 seconds.'
Show-ImportBatchStatus -Databases $successfulExports

for ($importIndex = 0; $importIndex -lt $importCandidates.Count; $importIndex++) {
  $database = $importCandidates[$importIndex]
  $databaseName = $database.TargetDatabase
  $expectedBacpac = Join-Path $database.FolderPath "$databaseName.bacpac"
  $artifactValidation = Get-BacpacExportResumeValidation `
    -Database $database `
    -SourceServerIdentity $script:SourceServerIdentity `
    -SourceDatabaseName $database.SourceDatabase `
    -TargetServerIdentity $script:TargetServerIdentity `
    -TargetDatabaseName $database.TargetDatabase `
    -RunId $script:MigrationRunId `
    -CheckpointSchemaVersion $script:BacpacCheckpointSchemaVersion
  if (-not $artifactValidation.IsValid) {
    $database.ImportStatus = 'Failed'
    $database.ImportFailureReason =
      "BACPAC checkpoint validation failed: $($artifactValidation.Reasons -join '; ')."
    $database.ResumeState = 'AwaitingManualRemediation'
    $database.FailureCategory = 'LocalArtifactInvalid'
    $database.ManualNextAction =
      'Preserve the checkpoint and artifact, investigate the identity or fingerprint mismatch, and restart Fresh with a new export root.'
    Save-SanitizedMigrationCheckpoint `
      -Databases $manifest -Path $manifestCheckpointPath
    Write-Warning "Import '$databaseName' was not started: $($database.ImportFailureReason)"
    Show-ImportBatchStatus -Databases $successfulExports
    if ($isAllSelection) {
      continue
    }
    throw $database.ImportFailureReason
  }
  if (-not (Test-Path -LiteralPath $expectedBacpac -PathType Leaf)) {
    $database.ImportStatus = 'Failed'
    $database.ImportFailureReason = "BACPAC not found: '$expectedBacpac'."
    $database.ResumeState = 'AwaitingManualRemediation'
    $database.FailureCategory = 'LocalArtifactMissing'
    $database.ManualNextAction =
      'Restore the exact verified BACPAC to its validated manifest path, or restart with a new export root; then return with target remediation complete.'
    Save-SanitizedMigrationCheckpoint `
      -Databases $manifest -Path $manifestCheckpointPath
    Write-Warning "Import '$databaseName' failed: $($database.ImportFailureReason)"
    Write-Warning "Manual next action: $($database.ManualNextAction) Checkpoint: '$manifestCheckpointPath'."
    Show-ImportBatchStatus -Databases $successfulExports
    if ($isAllSelection) {
      continue
    }
    throw $database.ImportFailureReason
  }

  $bacpacLength = (Get-Item -LiteralPath $expectedBacpac).Length
  if ($bacpacLength -le 0) {
    $database.ImportStatus = 'Failed'
    $database.ImportFailureReason =
      "BACPAC validation failed because the file is empty: '$expectedBacpac'."
    $database.ResumeState = 'AwaitingManualRemediation'
    $database.FailureCategory = 'LocalArtifactInvalid'
    $database.ManualNextAction =
      'Preserve and inspect the BACPAC outside this workflow, restore a verified artifact at the exact manifest path or restart with a new export root, then return with target remediation complete.'
    Save-SanitizedMigrationCheckpoint `
      -Databases $manifest -Path $manifestCheckpointPath
    Write-Warning "Import '$databaseName' was not started: $($database.ImportFailureReason)"
    Show-ImportBatchStatus -Databases $successfulExports
    if ($isAllSelection) {
      continue
    }
    throw $database.ImportFailureReason
  }

  # Run the operator-configured BACPAC verification/checksum process here and
  # apply the same LocalArtifactInvalid failure handling if it does not succeed.
  # This is an import prerequisite, not an export completion gate.

  $connectionBuilder = [System.Data.Common.DbConnectionStringBuilder]::new()
  $connectionBuilder.set_ConnectionString(
    $targetConnectionBuilder.get_ConnectionString()
  )
  $connectionBuilder['Initial Catalog'] = $databaseName
  $database.ImportStatus = 'InProgress'
  $database.ImportStartedUtc = [DateTime]::UtcNow
  $database.ImportLastUpdatedUtc = $database.ImportStartedUtc
  $database.ImportLastActivityUtc = $database.ImportStartedUtc
  Save-SanitizedMigrationCheckpoint `
    -Databases $manifest -Path $manifestCheckpointPath `
    -ApprovedTargetSku $revalidatedTargetSku
  $importArguments = @(
    '/Action:Import'
    "/SourceFile:$expectedBacpac"
    "/TargetConnectionString:$($connectionBuilder.get_ConnectionString())"
    "/p:DatabaseEdition=$($revalidatedTargetSku.DatabaseEdition)"
    "/p:DatabaseServiceObjective=$($revalidatedTargetSku.DatabaseServiceObjective)"
    "/p:DatabaseMaximumSize=$($revalidatedTargetSku.MaximumSizeGB)"
    '/p:CommandTimeout=1800'
  )
  $importResult = Invoke-SqlPackageWithProgress `
    -DatabaseName $databaseName -Operation Import `
    -ArgumentList $importArguments -EvidenceRootPath $database.FolderPath `
    -BatchIndex ($importIndex + 1) -BatchCount $importCandidates.Count `
    -StatusCallback { param($status)
      $database.ImportLastUpdatedUtc = [DateTime]::UtcNow
      $database.ImportLastActivityUtc = $status.LastActivityUtc
    }
  $database.ImportAttempts = @($database.ImportAttempts) + @($importResult)
  $database.ImportCompletedUtc = [DateTime]::UtcNow
  $database.ImportLastUpdatedUtc = $database.ImportCompletedUtc
  $database.ImportDuration = $database.ImportCompletedUtc - $database.ImportStartedUtc

  if ($importResult.ExitCode -ne 0) {
    $database.ImportStatus = 'Failed'
    $database.ImportFailureReason =
      "$($importResult.FailureReason) The target may have been partially created; inspect its current state before retrying."
    $database.ResumeState = 'AwaitingManualRemediation'
    $database.FailureCategory = if (Test-AuthenticationFailure `
        -FailureReason $importResult.FailureReason) {
      'Authentication'
    } else {
      'ImportFailure'
    }
    $database.TargetStateAfterImport = 'UnknownAfterFailure'
    $database.ManualNextAction =
      'Inspect the target and diagnostics outside this workflow; correct any partial target or target-side issue, then return with target remediation complete.'
    Save-SanitizedMigrationCheckpoint `
      -Databases $manifest -Path $manifestCheckpointPath

    # Execute the same injection-safe sys.databases query through the approved
    # sqlcmd route and fail closed when catalog visibility cannot be proved. Do
    # not classify state from SqlPackage diagnostics.
    try {
      $postFailureResult =
        Get-ExistingTargetDatabaseNamesFromApprovedSqlcmdRoute `
          -SqlcmdPath $modernSqlcmd.Path -ServerName $targetServerName `
          -AuthenticationMethod $targetAuthenticationMethod `
          -UserPrincipalName $targetEntraUserPrincipalName `
          -DatabaseNames @($databaseName)
      if ($postFailureResult.AmbiguousNames.Count -gt 0) {
        throw 'Catalog visibility is insufficient to determine whether the target is present after the failed import.'
      }
      $postFailureTargetNames = @($postFailureResult.ExistingNames)
    } catch {
      $database.ImportFailureReason =
        "$($database.ImportFailureReason) Read-only post-failure target inspection also failed: $(Protect-SensitiveText -Text $_.Exception.Message)"
      Save-SanitizedMigrationCheckpoint `
        -Databases $manifest -Path $manifestCheckpointPath
      Write-Warning "Import '$databaseName' failed and target state is unknown. $($database.ImportFailureReason)"
      Write-Warning "Stop the batch, inspect the target manually, and return with 'target remediation complete'. Checkpoint: '$manifestCheckpointPath'."
      throw "Target inspection failed after import failure for '$databaseName'."
    }
    $targetPresentAfterFailure = $postFailureTargetNames.Where({
      [string]::Equals(
        $_,
        $databaseName,
        [StringComparison]::OrdinalIgnoreCase
      )
    }).Count -gt 0
    $database.TargetStateAfterImport = if ($targetPresentAfterFailure) {
      'PresentAfterFailureRequiresInspection'
    } else {
      'AbsentAfterFailure'
    }
    $database.ManualNextAction = if ($database.FailureCategory -eq
        'Authentication') {
      'Verify the selected target identity, login/user permissions, network/firewall route, MFA or approved secure-store entry outside this workflow; then return with authentication remediation complete.'
    } elseif ($targetPresentAfterFailure) {
      'Inspect the partially created target and the diagnostics, decide and perform the required target cleanup or correction outside this workflow, then return with target remediation complete.'
    } else {
      'Correct the reported target, capacity, connectivity, or compatibility issue outside this workflow, then return with target remediation complete.'
    }
    Save-SanitizedMigrationCheckpoint `
      -Databases $manifest -Path $manifestCheckpointPath

    Write-Warning "Import '$databaseName' failed: $($database.ImportFailureReason) Diagnostics: '$($importResult.DiagnosticsPath)'."
    Write-Warning "Observed target state after failure: $($database.TargetStateAfterImport)."
    Write-Warning "No authentication switch, target cleanup, source/schema change, alternate database restore, or retry was attempted. Manual next action: $($database.ManualNextAction) Checkpoint: '$manifestCheckpointPath'."
    Show-ImportBatchStatus -Databases $successfulExports
    if ($isAllSelection) {
      continue
    }
    throw "Import failed for '$databaseName'."
  }

  $database.ImportStatus = 'Succeeded'
  $database.TargetStateAfterImport = 'ImportedSuccessfully'
  $database.ResumeState = 'None'
  $database.FailureCategory = $null
  $database.ManualNextAction = $null
  Save-SanitizedMigrationCheckpoint `
    -Databases $manifest -Path $manifestCheckpointPath
  Write-Host "Import '$databaseName' succeeded."
  Show-ImportBatchStatus -Databases $successfulExports
}

$successfulImports = @($manifest | Where-Object {
  $_.ImportStatus -eq 'Succeeded'
})
$skippedImports = @($manifest | Where-Object {
  $_.ImportStatus -eq 'Skipped'
})
$failedImports = @($manifest | Where-Object {
  $_.ImportStatus -eq 'Failed'
})

$importSummary = $successfulExports | ForEach-Object {
  $displayStatus = switch ($_.ImportStatus) {
    'Succeeded' { 'Success' }
    'Skipped' { 'Skipped' }
    'Failed' { 'Fail' }
    'InProgress' { 'InProgress' }
    default { $_.ImportStatus }
  }

  [pscustomobject]@{
    DatabaseName    = $_.TargetDatabase
    Status          = $displayStatus
    ServiceType     = $revalidatedTargetSku.ServiceType
    ServiceObjective = $revalidatedTargetSku.ServiceObjective
    VCore           = $revalidatedTargetSku.VCore
    DatabaseServiceObjective =
      $revalidatedTargetSku.DatabaseServiceObjective
    MaximumSizeGB   = $revalidatedTargetSku.MaximumSizeGB
  }
}

Write-Host 'BACPAC import summary:'
$importSummary | Format-Table -AutoSize

foreach ($failedImport in $failedImports) {
  $failedDiagnostics = @($failedImport.ImportAttempts)[-1].DiagnosticsPath
  Write-Warning "Import '$($failedImport.TargetDatabase)' failed: $($failedImport.ImportFailureReason) Diagnostics: '$failedDiagnostics'."
}
```

`$targetConnectionString` is supplied after authentication and must not contain an
`Initial Catalog`; the loop adds the database name safely. Use the explicit
`set_ConnectionString()` and `get_ConnectionString()` methods because PowerShell
can otherwise dispatch `ConnectionString` through the builder's dictionary
interface and create a nested `ConnectionString` key. Do not add
`/TargetDatabaseName`: `SqlPackage` requires `/TargetConnectionString` to be used
exclusively, and the connection string already contains the target database. Set
`$databaseEdition`, `$databaseServiceObjective`, `$databaseVCore`, and
`$databaseMaximumSizeGB` only from the immutable Phase 4 selection returned by
`Resolve-ApprovedTargetSkuSelection`. Do not use representative objectives or a
default vCore or maximum size. Availability still depends on the target region,
subscription, quota, and capacity, which must be represented by the approved
catalog rather than discovered through a failed import.

During an active import, do not treat `Incorrect syntax near 'EDITION'` in the
latest diagnostics as a terminal error by itself. When the SqlPackage process is
still running and an authoritative target query shows the database is `ONLINE`,
report the message as nonterminal diagnostic-masking/parser output and continue
polling. Terminal classification still depends on the SqlPackage exit code and,
after a nonzero exit, the authoritative target-state inspection below.

For an `All` selection, continue after a failed import and validate only databases
whose import succeeded. A database is `Skipped` only when the pre-import
`sys.databases` query observed it. Every attempted import with a nonzero exit code
remains `Failed`; preserve its diagnostics and inspect whether SqlPackage partially
created the target before retrying.
