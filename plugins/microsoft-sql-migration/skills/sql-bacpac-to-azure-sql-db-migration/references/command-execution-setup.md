# Local BACPAC automation — manifest setup

## Contents

- [1. Prerequisites](#1-prerequisites)
- [Target authentication options](#target-authentication-options)
- [2. Create the local manifest](#2-create-the-local-manifest)

Part of the command-execution reference set for this skill. See also: references\command-execution-export-import.md.

# Local BACPAC automation

Use this reference after collecting the required nonsecret inputs. Do not request
approval before local folder creation or export. The only workflow approval is one
grouped confirmation immediately before creating the new target databases. Do not
request additional confirmation between databases, retries, or later phases.

Never connect to either the source or target with SQL login/SQL authentication.
Do not request, accept, retrieve, or use SQL passwords or SQL credentials. Use
only Windows Integrated authentication or Microsoft Entra authentication supported
by the workflow.

Source and target connection strings represent environment-specific secure
retrieval. Never display either connection string. Target import uses only
`SqlPackage.exe`; it does not open a separate SQL session or call an Azure API.
An attended `sqlcmd` connection may be used after exports complete to establish
the selected target authentication route and run the single injection-safe,
read-only target database-existence preflight. It is never used to import a
BACPAC or create a database.

Do not call a target connection helper, test target SQL authentication, or query
the target data plane until every manifest item has completed its export attempt.
Collect only the existing target logical server name before export. Select the
catalog-validated target SKU and size only after every selected export has been
attempted and at least one export succeeded. Do not query or authenticate to the
target data plane before then. Do not request subscription, resource group,
region, target SKU, size, or target authentication during initial input collection.

## 1. Prerequisites

- PowerShell 7.
- The latest supported `SqlPackage` available on `PATH`.
- Modern Go-based `gosqlcmd` or `sqlcmd` for the attended target-authentication check. Detect
  and validate it before any discovery, folder creation, or export. Request
  installation approval if it is absent, and stop the migration if the
  prerequisite remains unavailable.
- An approved secure provider for source connection details. Target
  authentication is obtained only in the post-export import phase.
- Enough local capacity for every selected BACPAC and diagnostics file.
- Network access from the operator machine to the source SQL Server and target
  Azure SQL logical server.
- The absolute installed `references` directory for this skill, resolved from
  the reference files linked by `SKILL.md` and passed as `$skillReferenceRoot`.
  Do not infer it from the current directory, `$PSScriptRoot`, or a directory
  where a generated command block happens to be saved.

Validate that explicit directory and load the executable helpers once before
running any other command block:

```powershell
$referenceRootVariable = Get-Variable -Name skillReferenceRoot `
  -ErrorAction SilentlyContinue
if (-not $referenceRootVariable -or
    [string]::IsNullOrWhiteSpace([string] $referenceRootVariable.Value)) {
  throw 'Pass the absolute installed skill references directory as $skillReferenceRoot.'
}
$skillReferenceRoot = [IO.Path]::GetFullPath(
  [string] $referenceRootVariable.Value
)
if (-not (Test-Path -LiteralPath $skillReferenceRoot -PathType Container)) {
  throw "The installed skill references directory does not exist: '$skillReferenceRoot'."
}
$requiredHelperNames = @(
  'bacpac-checkpoint.ps1',
  'bacpac-command-helpers.ps1',
  'bacpac-target-preflight.ps1',
  'target-sku-validation.ps1'
)
foreach ($helperName in $requiredHelperNames) {
  $helperPath = Join-Path $skillReferenceRoot $helperName
  if (-not (Test-Path -LiteralPath $helperPath -PathType Leaf)) {
    throw "Required installed skill helper is missing: '$helperPath'."
  }
  . $helperPath
}
```

## Target authentication options

Use interactive Microsoft Entra ID by default without an authentication-choice
prompt. Show the alternatives only when the user explicitly requests a different
route. Substitute the actual server and user values without printing secrets:

| Target authentication | Command | Recommendation |
| --- | --- | --- |
| Interactive Microsoft Entra ID | `sqlcmd -S <server> -G -U <user>` | **Default**; attended and supports MFA |
| Microsoft Entra default credential chain (`ActiveDirectoryDefault`) | `sqlcmd -S <server> --authentication-method ActiveDirectoryDefault` | Optional explicit override for Azure CLI, developer, environment, or managed identity credentials |

Do not pass `-P` for interactive Entra ID. SQL login authentication is unsupported:
never request or use a password, display a password prompt, or read credentials
from Key Vault, Credential Manager, or a masked control. The `-G` command without
`-U` in Go `sqlcmd` selects `DefaultAzureCredential`; it does not promise the
current Windows identity. Use the explicit `ActiveDirectoryDefault` command above
and describe that route as potentially selecting an Azure CLI account, managed
identity, or configured environment credential. Use the approval-time target
preflight as the authentication/connectivity check after all exports are attempted;
do not launch a redundant preliminary `sqlcmd` probe. After it succeeds, construct
the matching secretless authentication-mode connection string with
`New-TargetConnectionStringForApprovedAuthentication` in the export/import
reference and retain it only in memory for the current batch.
`SqlPackage` performs its own authentication by using that connection string; do
not imply that a token or credential is transferred from `sqlcmd`. Never display
or persist the connection string.

During the initial prerequisite gate, prefer `gosqlcmd`, then inspect every
`sqlcmd` candidate because older ODBC executables can appear earlier on `PATH`.
Require only the default interactive route's `-G` and `-U` flags. Missing flags
in help output make capability unknown, not unsupported; the attended target
preflight is authoritative. Legacy ODBC candidates remain unsupported:

The command helpers are loaded from
[bacpac-command-helpers.ps1](bacpac-command-helpers.ps1).

```powershell
$modernSqlcmd = Find-CompatibleGoSqlcmd `
  -AuthenticationMethod InteractiveEntra
```

If `$modernSqlcmd` is `$null`, stop before discovery or export and ask one explicit
question: `Modern sqlcmd is required for the BACPAC migration workflow. Install it
now using winget?` Only after approval, run:

```powershell
$wingetOutput = winget install sqlcmd `
  --accept-package-agreements --accept-source-agreements 2>&1
$wingetExitCode = $LASTEXITCODE

$refreshedPathSegments = @(
  $env:Path
  [Environment]::GetEnvironmentVariable('Path', 'Machine')
  [Environment]::GetEnvironmentVariable('Path', 'User')
) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
$env:Path = $refreshedPathSegments -join ';'
$modernSqlcmd = Find-CompatibleGoSqlcmd `
  -AuthenticationMethod InteractiveEntra
if (-not $modernSqlcmd) {
  $wingetSummary = Protect-SensitiveText -Text ($wingetOutput -join ' ')
  throw "Modern sqlcmd could not be validated after winget exited with code $wingetExitCode. $wingetSummary Open a new terminal and retry."
}
```

The post-install capability check is authoritative. `winget install sqlcmd` can
return a nonzero exit code when the package is already installed and no upgrade
is available; if `Find-CompatibleGoSqlcmd` succeeds after `PATH` is refreshed,
treat that idempotent winget result as success and continue. Only stop when the
capability check still fails. Never name a wrapper parameter `$Args` because
PowerShell reserves `$args` as an automatic variable; use `$ArgumentList`.

If approval is declined, provide
`https://learn.microsoft.com/sql/tools/sqlcmd/sqlcmd-download-install` and stop.
Use `$modernSqlcmd.Path`, rather than the unqualified `sqlcmd` command, for the
selected authentication check. Never attempt `-S <server> -G -U <user>` until this
gate succeeds.

Fail before creating folders if `SqlPackage` is unavailable:

```powershell
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$sqlPackage = Get-Command SqlPackage -ErrorAction Stop
& $sqlPackage.Source /Version
if ($LASTEXITCODE -ne 0) {
  throw 'SqlPackage version validation failed.'
}
```

## 2. Create the local manifest

Before creating the manifest, establish the execution mode. Do not collect a
target SKU or maximum size here; Phase 4 performs that interaction after export:

```powershell
$modeVariable = Get-Variable -Name executionMode -ErrorAction SilentlyContinue
$requestedExecutionMode = if ($modeVariable) {
  [string] $modeVariable.Value
} else { 'Fresh' }
if ($requestedExecutionMode -notin @('Resume', 'Fresh')) {
  throw 'executionMode must be Fresh or Resume.'
}

$sourceIdentityVariable = Get-Variable -Name sourceServerName `
  -ErrorAction SilentlyContinue
$targetIdentityVariable = Get-Variable -Name targetServerName `
  -ErrorAction SilentlyContinue
$sourceAuthenticationVariable = Get-Variable -Name sourceAuthentication `
  -ErrorAction SilentlyContinue
$exportRootVariable = Get-Variable -Name userProvidedExportRoot `
  -ErrorAction SilentlyContinue
if (-not $sourceIdentityVariable -or -not $sourceIdentityVariable.Value -or
    -not $targetIdentityVariable -or -not $targetIdentityVariable.Value) {
  throw 'Source and target server identities must be resolved before creating or resuming a manifest.'
}
$allowedSourceAuthentication = @(
  'Windows Integrated'
  'Microsoft Entra Interactive MFA'
)
if (-not $sourceAuthenticationVariable -or
    $sourceAuthenticationVariable.Value -notin $allowedSourceAuthentication) {
  throw 'Source authentication must be explicitly selected as Windows Integrated or Microsoft Entra Interactive MFA before discovery or filesystem writes.'
}
if (-not $exportRootVariable -or
    [string]::IsNullOrWhiteSpace([string] $exportRootVariable.Value)) {
  throw 'The BACPAC export root must be explicitly accepted or supplied before discovery or filesystem writes. Present the recommended default instead of selecting it silently.'
}
$resolvedInitialInputs = [pscustomobject]@{
  SourceServer = [string] $sourceIdentityVariable.Value
  SourceAuthentication = [string] $sourceAuthenticationVariable.Value
  TargetServer = [string] $targetIdentityVariable.Value
  ExportRoot = [IO.Path]::GetFullPath(
    [string] $exportRootVariable.Value
  )
}
$resolvedInitialInputs | Format-List
$script:SourceServerIdentity = Get-CanonicalSqlServerIdentity `
  -ServerName ([string] $sourceIdentityVariable.Value)
$script:TargetServerIdentity = Get-CanonicalSqlServerIdentity `
  -ServerName ([string] $targetIdentityVariable.Value)
$script:MigrationRunId = if ($requestedExecutionMode -eq 'Fresh') {
  [Guid]::NewGuid()
} else {
  [Guid]::Empty
}
```

Checkpoint saves before Phase 4 intentionally use a null `TargetConfiguration`.
After Phase 4 selection, persist the complete resolved target configuration so a
later resume can revalidate it without asking the user to reselect it.

Set `$sourceDatabases` from the authoritative list of selectable online user
databases discovered before database selection. This list is operational scope
discovery only; do not run a migration assessment here. If the user already
supplied an exact database name or `All`, validate and reuse that value without
asking again. Otherwise, present `All` plus every value in `$sourceDatabases` as
the selection options; never present an `All`-only picker when the discovered
list is nonempty or require a discovered name as free text. Set
`$databaseSelection` to the exact selected database name or `All`. Persist the
resulting `$selectionMode` as `All` or `Explicit`; never infer it from the number
of selected databases. Set `$userProvidedExportRoot` to the path explicitly
accepted or supplied in the grouped request. To use the recommended default, the
user must explicitly accept `$env:USERPROFILE\SqlMigration\Bacpac`; never encode
acceptance as `$null` and never append a timestamped child directory silently.

```powershell
$requestedExportRoot = [string] $userProvidedExportRoot
$exportRoot = [IO.Path]::GetFullPath($requestedExportRoot)

$selectedDatabases = @(if ($databaseSelection -eq 'All') {
  @($sourceDatabases)
} else {
  @($sourceDatabases | Where-Object { $_ -ceq $databaseSelection })
})
$selectionMode = if ($databaseSelection -ceq 'All') { 'All' } else { 'Explicit' }
$script:SelectionMode = $selectionMode

if ($selectedDatabases.Count -eq 0) {
  throw 'The database selection did not match a selectable online user database.'
}

$invalidNameChars = [IO.Path]::GetInvalidFileNameChars()
$reservedWindowsNames =
  '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?$'
$skippedLocalDatabases = [System.Collections.Generic.List[object]]::new()
$manifest = @(foreach ($databaseName in $selectedDatabases) {
  $invalidWindowsName =
    [string]::IsNullOrWhiteSpace($databaseName) -or
    $databaseName.IndexOfAny($invalidNameChars) -ge 0 -or
    $databaseName.EndsWith('.') -or
    $databaseName.EndsWith(' ') -or
    $databaseName -match $reservedWindowsNames

  if ($invalidWindowsName) {
    $reason = 'The database name is not a valid Windows folder name.'
    [void] $skippedLocalDatabases.Add([pscustomobject]@{
      DatabaseName = $databaseName
      Reason = $reason
    })
    Write-Warning "Database '$databaseName' will be skipped. $reason"
    continue
  }

  try {
    $folderPath = [IO.Path]::GetFullPath(
      (Join-Path -Path $exportRoot -ChildPath $databaseName)
    )
  } catch {
    $reason = "The export folder path is invalid: $($_.Exception.Message)"
    [void] $skippedLocalDatabases.Add([pscustomobject]@{
      DatabaseName = $databaseName
      Reason = $reason
    })
    Write-Warning "Database '$databaseName' will be skipped. $reason"
    continue
  }

  $relativeFolderPath = [IO.Path]::GetRelativePath(
    $exportRoot,
    $folderPath
  )
  $isOutsideExportRoot =
    $relativeFolderPath -eq '.' -or
    [IO.Path]::IsPathRooted($relativeFolderPath) -or
    $relativeFolderPath -match '^\.\.([\\/]|$)'

  if ($isOutsideExportRoot) {
    $reason = "The folder path resolves outside the export root '$exportRoot'."
    [void] $skippedLocalDatabases.Add([pscustomobject]@{
      DatabaseName = $databaseName
      Reason = $reason
    })
    Write-Warning "Database '$databaseName' will be skipped. $reason"
    continue
  }

  if (Test-Path -LiteralPath $folderPath) {
    $existingFolder = Get-Item -LiteralPath $folderPath -Force
    $unsafeExistingFolder = -not $existingFolder.PSIsContainer -or
      ($existingFolder.Attributes -band [IO.FileAttributes]::ReparsePoint)
    if ($unsafeExistingFolder) {
      $reason = 'The export path exists but is not a regular directory.'
      [void] $skippedLocalDatabases.Add([pscustomobject]@{
        DatabaseName = $databaseName
        Reason = $reason
      })
      Write-Warning "Database '$databaseName' will be skipped. $reason"
      continue
    }
  }

  $bacpacPath = [IO.Path]::GetFullPath(
    (Join-Path -Path $folderPath -ChildPath "$databaseName.bacpac")
  )
  [pscustomobject]@{
    CheckpointSchemaVersion = $null
    SourceServerIdentity = $null
    SourceDatabase   = $databaseName
    TargetServerIdentity = $null
    RunId = $null
    FolderPath       = $folderPath
    BacpacPath       = $bacpacPath
    BacpacLengthBytes = $null
    BacpacSha256 = $null
    ExportCompletedAtUtc = $null
    TargetDatabase   = $databaseName
    ExportStatus     = 'Pending'
    ExportFailureReason = $null
    ExportLastUpdatedUtc = $null
    ExportAttempts    = @()
    ImportStatus     = 'Pending'
    ImportFailureReason = $null
    ImportLastUpdatedUtc = $null
    ImportStartedUtc = $null
    ImportCompletedUtc = $null
    ImportDuration   = $null
    ImportLastActivityUtc = $null
    ImportAttempts    = @()
    TargetStateAfterImport = 'NotChecked'
    ResumeState = 'None'
    FailureCategory = $null
    ManualNextAction = $null
    ValidationReportStatus = 'NotStarted'
  }
})

if ($skippedLocalDatabases.Count -gt 0) {
  Write-Host 'Databases skipped during local path validation:'
  $skippedLocalDatabases | Format-Table -AutoSize
}

if ($manifest.Count -eq 0) {
  throw 'No databases have safe local export paths; no folders were created.'
}

$manifestCheckpointPath = Join-Path $exportRoot '.migration-checkpoint.json'
if ($requestedExecutionMode -eq 'Fresh' -and
    (Test-Path -LiteralPath $exportRoot -PathType Container)) {
  $existingEvidence = Get-ChildItem -LiteralPath $exportRoot -Force -Recurse |
    Select-Object -First 1
  if ($existingEvidence) {
    throw "Fresh execution requires an evidence-free export root. '$exportRoot' already contains '$($existingEvidence.FullName)'. Choose a new root; do not overwrite prior evidence."
  }
}
if ($requestedExecutionMode -eq 'Fresh') {
  $existingBacpacDestinations = @($manifest | Where-Object {
    Test-Path -LiteralPath $_.BacpacPath -PathType Leaf
  })
  if ($existingBacpacDestinations.Count -gt 0) {
    if ($databaseSelection -ne 'All') {
      $collisionPaths = $existingBacpacDestinations.BacpacPath -join "'; '"
      throw "BACPAC export was not started. A BACPAC file with the same name already exists: '$collisionPaths'. Existing files were not overwritten, renamed, deleted, or reused. Preserve/move them externally or choose a new export root."
    }

    # For an `All` selection, mark only the colliding databases as failed so
    # unaffected exports can still proceed; never overwrite, rename, delete,
    # or reuse the existing files.
    foreach ($collidingDatabase in $existingBacpacDestinations) {
      $collidingDatabase.ExportStatus = 'Failed'
      $collidingDatabase.ExportFailureReason =
        "A BACPAC file with the same name already exists: '$($collidingDatabase.BacpacPath)'."
      $collidingDatabase.ExportLastUpdatedUtc = [DateTime]::UtcNow
      $collidingDatabase.ResumeState = 'AwaitingManualRemediation'
      $collidingDatabase.FailureCategory = 'LocalArtifactConflict'
      $collidingDatabase.ManualNextAction =
        'Preserve or move the existing BACPAC outside this workflow, or restart with a new export root; then return with source remediation complete. The workflow will resume only after the intended destination path no longer exists.'
      Write-Warning $collidingDatabase.ExportFailureReason
      Write-Warning "The existing file was not overwritten, renamed, deleted, or reused. Manual next action: $($collidingDatabase.ManualNextAction)"
    }
    Save-SanitizedMigrationCheckpoint `
      -Databases $manifest -Path $manifestCheckpointPath

    $eligibleAfterCollisionCheck = @($manifest | Where-Object {
      $_.ExportStatus -eq 'Pending' -and $_.ResumeState -eq 'None'
    })
    if ($eligibleAfterCollisionCheck.Count -eq 0) {
      throw "BACPAC export was not started for any database. Every selected database already has an existing destination BACPAC. Existing files were not overwritten, renamed, deleted, or reused. Preserve/move them externally or choose a new export root. Checkpoint: '$manifestCheckpointPath'."
    }
  }
}
if ($requestedExecutionMode -eq 'Resume' -and
    -not (Test-Path -LiteralPath $manifestCheckpointPath -PathType Leaf)) {
  throw "Resume requires checkpoint '$manifestCheckpointPath'. Preserve existing evidence and choose Fresh with a new root if no checkpoint is available."
}

$manifest | ForEach-Object {
  [void] [IO.Directory]::CreateDirectory($_.FolderPath)
}

if (Test-Path -LiteralPath $manifestCheckpointPath -PathType Leaf) {
  if ($requestedExecutionMode -eq 'Fresh') {
    throw "Fresh execution cannot reuse export root '$exportRoot' because it contains a checkpoint. Choose a new export root to preserve prior BACPACs, diagnostics, status files, and checkpoint evidence."
  }

  $checkpoint = Get-Content -LiteralPath $manifestCheckpointPath -Raw |
    ConvertFrom-Json
  if ($checkpoint.SchemaVersion -ne $script:BacpacCheckpointSchemaVersion -or
      -not $checkpoint.Databases) {
    throw "Checkpoint '$manifestCheckpointPath' has an unsupported or incomplete schema."
  }
  $checkpointRunId = [Guid]::Empty
  if ([string] $checkpoint.SourceServerIdentity -cne
        $script:SourceServerIdentity -or
      [string] $checkpoint.TargetServerIdentity -cne
        $script:TargetServerIdentity -or
      -not [Guid]::TryParse([string] $checkpoint.RunId,
        [ref] $checkpointRunId) -or
      $checkpointRunId -eq [Guid]::Empty) {
    throw 'Checkpoint source, target, or run identity does not match the current migration context.'
  }
  $script:MigrationRunId = $checkpointRunId
  if ($checkpoint.SelectionMode -notin @('All', 'Explicit')) {
    throw "Checkpoint '$manifestCheckpointPath' has no valid SelectionMode."
  }
  if ($checkpoint.SelectionMode -cne $selectionMode) {
    throw "Checkpoint selection mode '$($checkpoint.SelectionMode)' does not match the current selection mode '$selectionMode'. Resume with the original selection or start Fresh with a new export root."
  }
  $checkpointDatabases = @($checkpoint.Databases)
  if ($checkpointDatabases.Count -ne $manifest.Count) {
    throw 'Checkpoint database scope does not match current authoritative discovery and selection.'
  }

  $remediationConfirmationVariable = Get-Variable `
    -Name manualRemediationConfirmation -ErrorAction SilentlyContinue
  $remediationConfirmation = if ($remediationConfirmationVariable) {
    [string] $remediationConfirmationVariable.Value
  } else { '' }

  foreach ($database in $manifest) {
    $saved = @($checkpointDatabases | Where-Object {
      $_.SourceDatabase -ceq $database.SourceDatabase -and
      $_.TargetDatabase -ceq $database.TargetDatabase
    })
    if ($saved.Count -ne 1) {
      throw "Checkpoint mapping for '$($database.SourceDatabase)' is missing or ambiguous."
    }
    $savedFolder = [IO.Path]::GetFullPath([string] $saved[0].FolderPath)
    $savedBacpac = [IO.Path]::GetFullPath([string] $saved[0].BacpacPath)
    if ($savedFolder -cne $database.FolderPath -or
        $savedBacpac -cne $database.BacpacPath) {
      throw "Checkpoint paths for '$($database.SourceDatabase)' do not match the validated export root."
    }

    foreach ($metadataProperty in @(
        'CheckpointSchemaVersion', 'SourceServerIdentity',
        'TargetServerIdentity', 'RunId', 'BacpacLengthBytes',
        'BacpacSha256', 'ExportCompletedAtUtc')) {
      $database.$metadataProperty = $saved[0].$metadataProperty
    }
    if ($saved[0].ExportStatus -eq 'Succeeded') {
      $resumeValidation = Get-BacpacExportResumeValidation `
        -Database $saved[0] `
        -SourceServerIdentity $script:SourceServerIdentity `
        -SourceDatabaseName $database.SourceDatabase `
        -TargetServerIdentity $script:TargetServerIdentity `
        -TargetDatabaseName $database.TargetDatabase `
        -RunId $script:MigrationRunId `
        -CheckpointSchemaVersion ([int] $checkpoint.SchemaVersion)
      if (-not $resumeValidation.IsValid) {
        throw "Checkpoint export '$($database.SourceDatabase)' cannot be resumed: $($resumeValidation.Reasons -join '; '). Preserve the checkpoint and start Fresh with a new export root."
      }
    }

    foreach ($propertyName in @(
        'ExportStatus', 'ExportFailureReason', 'ExportLastUpdatedUtc',
        'ImportStatus', 'ImportFailureReason', 'ImportLastUpdatedUtc',
        'ImportStartedUtc', 'ImportCompletedUtc', 'ImportDuration',
        'ImportLastActivityUtc', 'TargetStateAfterImport', 'ResumeState',
        'FailureCategory', 'ManualNextAction', 'ValidationReportStatus')) {
      $database.$propertyName = $saved[0].$propertyName
    }
    foreach ($attemptProperty in @('ExportAttempts', 'ImportAttempts')) {
      $savedProperty = $saved[0].PSObject.Properties[$attemptProperty]
      $database.$attemptProperty = if ($savedProperty) {
        @($savedProperty.Value)
      } else {
        @()
      }
    }
    foreach ($dateProperty in @(
        'ExportLastUpdatedUtc', 'ImportLastUpdatedUtc', 'ImportStartedUtc',
        'ImportCompletedUtc', 'ImportLastActivityUtc')) {
      if ($database.$dateProperty) {
        $database.$dateProperty = [DateTime] $database.$dateProperty
      }
    }

    if ($database.ExportStatus -eq 'InProgress') {
      $database.ExportStatus = 'Failed'
      $database.ExportFailureReason =
        'The prior export ended without a terminal checkpoint state.'
      $database.ResumeState = 'AwaitingManualRemediation'
      $database.FailureCategory = 'InterruptedExport'
      $database.ManualNextAction =
        'Preserve the diagnostics and any partial BACPAC, verify that no prior SqlPackage process is active, move the partial BACPAC outside the workflow if present, then return with source remediation complete.'
      $database.ExportLastUpdatedUtc = [DateTime]::UtcNow
    }
    if ($database.ImportStatus -eq 'InProgress') {
      $database.ImportStatus = 'Failed'
      $database.ImportFailureReason =
        'The prior import ended without a terminal checkpoint state; target state is not authoritative.'
      $database.ResumeState = 'AwaitingManualRemediation'
      $database.FailureCategory = 'InterruptedImport'
      $database.TargetStateAfterImport =
        'PresentAfterFailureRequiresInspection'
      $database.ManualNextAction =
        'Inspect the target database and prior diagnostics without changing the source. If a partial or completed target exists, preserve evidence and explicitly resolve it outside this workflow; then return with target remediation complete.'
      $database.ImportLastUpdatedUtc = [DateTime]::UtcNow
    }

    if ($database.ExportStatus -eq 'Succeeded' -and
        -not (Test-Path -LiteralPath $database.BacpacPath -PathType Leaf)) {
      throw "Checkpoint says export '$($database.SourceDatabase)' succeeded, but its validated BACPAC is missing. Preserve the checkpoint and repair or restart with a new export root."
    }
    if ($database.ResumeState -eq 'AwaitingManualRemediation') {
      $requiredConfirmation = if ($database.FailureCategory -eq
          'Authentication') {
        'authentication remediation complete'
      } elseif ($database.ExportStatus -eq 'Failed') {
        'source remediation complete'
      } else {
        'target remediation complete'
      }
      if ($remediationConfirmation -ceq $requiredConfirmation) {
        $priorReason = Protect-SensitiveText -Text (
          $database.ExportFailureReason ?? $database.ImportFailureReason
        )
        $intendedRetry = if ($database.ExportStatus -eq 'Failed') {
          'export'
        } else { 'import' }
        Write-Host "Manual remediation confirmed for '$($database.SourceDatabase)'. Prior reason: $priorReason. Intended retry: $intendedRetry."
        $database.ResumeState = 'None'
        if ($database.ExportStatus -eq 'Failed') {
          $database.ExportStatus = 'Pending'
          $database.ExportFailureReason = $null
        } elseif ($database.ImportStatus -eq 'Failed') {
          $database.ImportStatus = 'Pending'
          $database.ImportFailureReason = $null
          # Preserve PresentAfterFailureRequiresInspection. The authoritative
          # target preflight must prove absence before another import can run.
        }
      } else {
        Write-Warning "'$($database.SourceDatabase)' remains paused. Required confirmation: '$requiredConfirmation'. Manual next action: $($database.ManualNextAction)"
      }
    }
  }
}
$checkpointTargetConfiguration = if (
  (Get-Variable -Name checkpoint -ErrorAction SilentlyContinue) -and
  $checkpoint.PSObject.Properties['TargetConfiguration']
) { $checkpoint.TargetConfiguration } else { $null }
Save-SanitizedMigrationCheckpoint `
  -Databases $manifest -Path $manifestCheckpointPath `
  -ApprovedTargetSku $checkpointTargetConfiguration
```

Path validation covers the complete selected scope before creating any folder.
The checkpoint persists `SelectionMode` separately from the database count so an
`All` selection that resolves to one eligible database retains batch semantics
when it is resumed.
Keep `$skippedLocalDatabases` for the final report so every excluded database and
its reason remain visible. The checkpoint contains no connection strings or
credentials. On restart, load it only after validating that its canonical export
root and database mappings match the current discovery. Before retrying an item
whose `ResumeState` is `AwaitingManualRemediation`, require the corresponding user
statement (`authentication remediation complete`, `source remediation complete`,
or `target remediation complete`) and revalidate the failed prerequisite. Never
repeat an item already marked `Succeeded`.
