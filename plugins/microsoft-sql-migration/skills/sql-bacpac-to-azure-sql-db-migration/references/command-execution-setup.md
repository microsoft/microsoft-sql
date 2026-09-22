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
- Modern Go-based `sqlcmd` for the attended target-authentication check. Detect
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

During the initial prerequisite gate, find a modern `sqlcmd` candidate. Older ODBC
`sqlcmd` executables can appear earlier on `PATH`, so inspect all candidates:

```powershell
function Find-CompatibleGoSqlcmd {
  param(
    [string[]]$RequiredFlags = @('-E', '-G', '-U')
  )

  foreach ($candidate in @(Get-Command sqlcmd -All -ErrorAction SilentlyContinue)) {
    $versionOutput = & $candidate.Source --version 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
      continue
    }

    $modernHelpOutput = & $candidate.Source --help 2>&1 | Out-String
    $modernHelpSucceeded = $LASTEXITCODE -eq 0
    $compatibilityHelpOutput = & $candidate.Source -? 2>&1 | Out-String
    $compatibilityHelpSucceeded = $LASTEXITCODE -eq 0

    $missingFlags = @($RequiredFlags | Where-Object {
      $pattern = "(?m)(^|\s)$([regex]::Escape($_))([,\s]|$)"
      -not (
        ($modernHelpSucceeded -and $modernHelpOutput -match $pattern) -or
        ($compatibilityHelpSucceeded -and
          $compatibilityHelpOutput -match $pattern)
      )
    })

    if (($modernHelpSucceeded -or $compatibilityHelpSucceeded) -and
        $missingFlags.Count -eq 0) {
      return [pscustomobject]@{
        Path      = $candidate.Source
        Version   = $versionOutput.Trim()
        HelpModes = @(
          if ($modernHelpSucceeded) { '--help' }
          if ($compatibilityHelpSucceeded) { '-?' }
        ) -join ', '
      }
    }
  }

  return $null
}

$modernSqlcmd = Find-CompatibleGoSqlcmd `
  -RequiredFlags @('-G', '-U', '--authentication-method')
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
  -RequiredFlags @('-G', '-U', '--authentication-method')
if (-not $modernSqlcmd) {
  $wingetSummary = Protect-SensitiveText -Text ($wingetOutput -join ' ')
  throw "Modern sqlcmd could not be validated after winget exited with code $wingetExitCode. $wingetSummary Open a new terminal and retry."
}
```

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

function Invoke-SqlPackageWithProgress {
  param(
    [Parameter(Mandatory)] [string] $DatabaseName,
    [Parameter(Mandatory)] [ValidateSet('Export', 'Import')] [string] $Operation,
    [Parameter(Mandatory)] [string[]] $ArgumentList,
    [Parameter(Mandatory)] [string] $EvidenceRootPath,
    [string] $ProgressFilePath,
    [scriptblock] $StatusCallback = {},
    [int] $PollSeconds = 30,
    [int] $TimeoutSeconds = 7200,
    [int] $StalledAfterSeconds = 300,
    [int] $BatchIndex = 1,
    [int] $BatchCount = 1
  )

  $operationName = $Operation.ToLowerInvariant()
  $attemptId = '{0}-{1}' -f [DateTime]::UtcNow.ToString(
    'yyyyMMddTHHmmss.fffffffZ'
  ), [Guid]::NewGuid().ToString('N')
  $attemptDirectory = Join-Path $EvidenceRootPath `
    (Join-Path 'attempts' (Join-Path $operationName $attemptId))
  if (Test-Path -LiteralPath $attemptDirectory) {
    throw "SqlPackage attempt evidence path already exists: '$attemptDirectory'."
  }
  [void] [IO.Directory]::CreateDirectory($attemptDirectory)
  $DiagnosticsPath = Join-Path $attemptDirectory 'diagnostics.log'
  $consoleOutputPath = Join-Path $attemptDirectory 'console.log'
  $StatusPath = Join-Path $attemptDirectory 'status.log'
  $statusStream = [IO.File]::Open(
    $StatusPath,
    [IO.FileMode]::CreateNew,
    [IO.FileAccess]::Write,
    [IO.FileShare]::Read
  )
  $statusStream.Dispose()

  $sqlPackageArguments = @($ArgumentList | Where-Object {
    $_ -notmatch '(?i)^/DiagnosticsFile:'
  })
  $sqlPackageArguments += "/DiagnosticsFile:$DiagnosticsPath"

  $startedUtc = [DateTime]::UtcNow

  function New-SqlPackageAttemptResult {
    param(
      [Parameter(Mandatory)] [int] $ExitCode,
      [Parameter(Mandatory)] [bool] $TimedOut,
      [AllowNull()] [string] $FailureReason
    )

    [pscustomobject]@{
      ExitCode = $ExitCode
      TimedOut = $TimedOut
      FailureReason = $FailureReason
      AttemptId = $attemptId
      StartedUtc = $startedUtc
      CompletedUtc = [DateTime]::UtcNow
      DiagnosticsPath = $DiagnosticsPath
      ConsoleOutputPath = $consoleOutputPath
      StatusPath = $StatusPath
    }
  }

  function Write-SqlPackageStatus {
    param([Parameter(Mandatory)] [string] $Message)

    Write-Host $Message
    try {
      Add-Content -LiteralPath $StatusPath -Value $Message -Encoding utf8
    } catch {
      Write-Warning "Could not update status file '$StatusPath': $($_.Exception.Message)"
    }
    [Console]::Out.Flush()
  }

  $sourceIntegratedSecurityArguments = @($sqlPackageArguments | Where-Object {
    $_ -match '(?i)^/SourceIntegratedSecurity(?::|$)'
  })
  if ($sourceIntegratedSecurityArguments.Count -gt 0) {
    $sourceConnectionArgument = $sqlPackageArguments | Where-Object {
      $_ -match '(?i)^/SourceConnectionString:'
    } | Select-Object -First 1
    $usesIntegratedConnectionString = $sourceConnectionArgument -match
      '(?i)(Integrated Security\s*=\s*(True|SSPI)|Trusted_Connection\s*=\s*True)'

    if (-not $usesIntegratedConnectionString) {
      return New-SqlPackageAttemptResult -ExitCode -2 -TimedOut $false `
        -FailureReason 'Unsupported /SourceIntegratedSecurity argument. Put Integrated Security=True in /SourceConnectionString.'
    }

    return New-SqlPackageAttemptResult -ExitCode -2 -TimedOut $false `
      -FailureReason 'Unsupported /SourceIntegratedSecurity argument. Remove it from the shared template outside this execution; Integrated Security=True is already present in /SourceConnectionString.'
  }

  $job = Start-Job -ScriptBlock {
    param(
      [Parameter(Mandatory)] [string] $SqlPackagePath,
      [Parameter(Mandatory)] [string[]] $SqlPackageArguments,
      [Parameter(Mandatory)] [string] $ConsoleOutputPath
    )

    & $SqlPackagePath @SqlPackageArguments *> $ConsoleOutputPath
    [pscustomobject]@{ ExitCode = $LASTEXITCODE }
  } -ArgumentList $sqlPackage.Source, $sqlPackageArguments, $consoleOutputPath

  if (-not $job) {
    throw "Failed to start SqlPackage for '$DatabaseName'."
  }
  $lastActivityUtc = $startedUtc
  $previousDiagnosticsBytes = 0L
  $previousProgressBytes = 0L
  Write-SqlPackageStatus "[$($startedUtc.ToString('u'))] $Operation started: '$DatabaseName' ($BatchIndex of $BatchCount). Next status update in $PollSeconds seconds. Status file: '$StatusPath'."

  while ($job.State -eq 'Running') {
    $pollMilliseconds = [Math]::Min($PollSeconds * 1000, [int]::MaxValue)
    Wait-Job -Id $job.Id -Timeout ([Math]::Max(1, [int]($pollMilliseconds / 1000))) | Out-Null

    if ([DateTime]::UtcNow -ge $startedUtc.AddSeconds($TimeoutSeconds)) {
      Stop-Job -Id $job.Id -ErrorAction SilentlyContinue
      Wait-Job -Id $job.Id | Out-Null
      Remove-Job -Id $job.Id -Force
      Write-SqlPackageStatus "[$([DateTime]::UtcNow.ToString('u'))] $Operation '$DatabaseName' timed out after $TimeoutSeconds seconds."
      return New-SqlPackageAttemptResult -ExitCode -1 -TimedOut $true `
        -FailureReason "SqlPackage $Operation timed out after $TimeoutSeconds seconds."
    }

    $elapsed = [DateTime]::UtcNow - $startedUtc
    $diagnosticsBytes = if (Test-Path -LiteralPath $DiagnosticsPath -PathType Leaf) {
      (Get-Item -LiteralPath $DiagnosticsPath).Length
    } else {
      0L
    }
    $consoleOutputBytes = if (Test-Path -LiteralPath $consoleOutputPath -PathType Leaf) {
      (Get-Item -LiteralPath $consoleOutputPath).Length
    } else {
      0L
    }
    $progressBytes = if ($ProgressFilePath -and
        (Test-Path -LiteralPath $ProgressFilePath -PathType Leaf)) {
      (Get-Item -LiteralPath $ProgressFilePath).Length
    } else {
      0L
    }
    $diagnosticsDelta = $diagnosticsBytes - $previousDiagnosticsBytes
    $progressDelta = ($progressBytes + $consoleOutputBytes) - $previousProgressBytes
    if ($diagnosticsDelta -gt 0 -or $progressDelta -gt 0) {
      $lastActivityUtc = [DateTime]::UtcNow
    }
    $activity = if ($diagnosticsDelta -gt 0 -or $progressDelta -gt 0) {
      'Running'
    } elseif (([DateTime]::UtcNow - $lastActivityUtc).TotalSeconds -ge
        $StalledAfterSeconds) {
      'Possibly stalled - process is active but diagnostics have not changed'
    } else {
      'Running - no new diagnostics yet'
    }
    $latestStatus = if ($diagnosticsBytes -gt 0) {
      $line = Get-Content -LiteralPath $DiagnosticsPath -Tail 1
      Protect-SensitiveText -Text $line
    } elseif ($consoleOutputBytes -gt 0) {
      $line = Get-Content -LiteralPath $consoleOutputPath -Tail 1
      Protect-SensitiveText -Text $line
    } else {
      'No diagnostic status written yet.'
    }
    if ($Operation -eq 'Import' -and
        (Test-NonTerminalImportDiagnostic -StatusText $latestStatus)) {
      $activity = 'Running - nonterminal SqlPackage diagnostic observed; continue polling until process exits'
    }
    & $StatusCallback ([pscustomobject]@{
      Status = $activity
      Elapsed = $elapsed
      LastActivityUtc = $lastActivityUtc
      LatestStatus = $latestStatus
    })
    Write-Progress -Activity "SqlPackage $Operation" `
      -Status "${DatabaseName}: $activity; elapsed $($elapsed.ToString('hh\:mm\:ss'))" `
      -PercentComplete -1
    Write-SqlPackageStatus "[$([DateTime]::UtcNow.ToString('u'))] $Operation '$DatabaseName' ($BatchIndex of $BatchCount) | $activity | Elapsed $($elapsed.ToString('hh\:mm\:ss')) | Diagnostics $diagnosticsBytes bytes (+$diagnosticsDelta) | $latestStatus"
    $previousDiagnosticsBytes = $diagnosticsBytes
    $previousProgressBytes = $progressBytes + $consoleOutputBytes
  }

  Write-Progress -Activity "SqlPackage $Operation" -Completed
  $jobResult = Receive-Job -Id $job.Id -ErrorAction SilentlyContinue
  $jobFailure = $job.ChildJobs[0].JobStateInfo.Reason
  Remove-Job -Id $job.Id -Force
  $exitCode = if ($jobResult -and $null -ne $jobResult.ExitCode) {
    [int] $jobResult.ExitCode
  } elseif ($jobFailure) {
    -3
  } else {
    -4
  }
  $failureReason = if ($exitCode -eq 0) {
    $null
  } elseif (Test-Path -LiteralPath $DiagnosticsPath -PathType Leaf) {
    (Get-Content -LiteralPath $DiagnosticsPath -Tail 20) -join ' '
  } elseif (Test-Path -LiteralPath $consoleOutputPath -PathType Leaf) {
    (Get-Content -LiteralPath $consoleOutputPath -Tail 20) -join ' '
  } elseif ($jobFailure) {
    $jobFailure.Message
  } else {
    "SqlPackage $Operation exited without returning an exit code."
  }
  $failureReason = Protect-SensitiveText -Text $failureReason

  $terminalStatus = if ($exitCode -eq 0) { 'Succeeded' } else { 'Failed' }
  Write-SqlPackageStatus "[$([DateTime]::UtcNow.ToString('u'))] $Operation '$DatabaseName' $terminalStatus with exit code $exitCode."

  New-SqlPackageAttemptResult -ExitCode $exitCode -TimedOut $false `
    -FailureReason $failureReason
}

function Protect-SensitiveText {
  param([AllowNull()] [string] $Text)

  if ($null -eq $Text) { return $null }
  $sanitized = $Text `
    -replace '(?i)\b(Authorization\s*:\s*Bearer|Bearer)\s+[A-Za-z0-9._~+/-]+=*', '$1 <redacted>' `
    -replace '\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b', '<redacted-jwt>' `
    -replace '(?i)\b(sig|se|sp|sv|srt|ss|spr|skoid|sktid|skv)=[^&;\s"\r\n]+', '$1=<redacted>' `
    -replace '(?i)\b(AccountKey|SharedAccessKey|SharedAccessSignature|Password|Pwd|AccessToken|ClientSecret)\s*=\s*[^;"\r\n]*', '$1=<redacted>' `
    -replace '(?i)\b(password|pwd|access[ _-]?token|client[ _-]?secret|api[ _-]?key|account[ _-]?key)\s*[=:]\s*[^;\s"\r\n]+', '$1=<redacted>'
  return $sanitized
}

function Test-NonTerminalImportDiagnostic {
  param([AllowNull()] [string] $StatusText)

  $StatusText -match "(?i)Incorrect syntax near 'EDITION'"
}

function Test-AuthenticationFailure {
  param([AllowNull()] [string] $FailureReason)

  $FailureReason -match '(?i)(login failed|authentication (failed|error|denied|required)|token.*(expired|invalid|denied)|principal.*(not found|denied)|unauthorized)'
}

function Test-UnsupportedSourceFailure {
  param([AllowNull()] [string] $FailureReason)

  $FailureReason -match '(?i)(object|feature|schema|type|property).{0,160}(not supported|unsupported|incompatible|cannot be exported|not available in the target platform)'
}

function Test-UnsupportedSqlPackageArgumentFailure {
  param([AllowNull()] [string] $FailureReason)

  $FailureReason -match '(?i)(unsupported|unrecognized|unknown|invalid).{0,80}(argument|parameter|switch)|/SourceIntegratedSecurity'
}

function Save-SanitizedMigrationCheckpoint {
  param(
    [Parameter(Mandatory)] [object[]] $Databases,
    [Parameter(Mandatory)] [string] $Path,
    [AllowNull()] [object] $ApprovedTargetSku,
    [ValidateSet('All', 'Explicit')]
    [string] $SelectionMode = $script:SelectionMode
  )

  if ($SelectionMode -notin @('All', 'Explicit')) {
    throw 'SelectionMode must be All or Explicit before saving a migration checkpoint.'
  }
  if ([string]::IsNullOrWhiteSpace($script:SourceServerIdentity) -or
      [string]::IsNullOrWhiteSpace($script:TargetServerIdentity) -or
      $script:MigrationRunId -eq [Guid]::Empty) {
    throw 'Canonical source, target, and migration run identities must be established before saving a checkpoint.'
  }
  if (-not $PSBoundParameters.ContainsKey('ApprovedTargetSku')) {
    $approvedSkuVariable = Get-Variable -Name ApprovedTargetSku `
      -Scope Script -ErrorAction SilentlyContinue
    $ApprovedTargetSku = if ($approvedSkuVariable) {
      $approvedSkuVariable.Value
    } else { $null }
  }
  $targetConfiguration = if ($ApprovedTargetSku) {
    [pscustomobject]@{
      ServiceType = [string]$ApprovedTargetSku.ServiceType
      ServiceObjective = [string]$ApprovedTargetSku.ServiceObjective
      VCore = [int]$ApprovedTargetSku.VCore
      MaximumSizeGB = [int]$ApprovedTargetSku.MaximumSizeGB
      DatabaseEdition = [string]$ApprovedTargetSku.DatabaseEdition
      DatabaseServiceObjective =
        [string]$ApprovedTargetSku.DatabaseServiceObjective
    }
  } else { $null }

  $sanitizedDatabases = @($Databases | ForEach-Object {
    $sanitizeAttempts = {
      param([object[]] $Attempts)

      @($Attempts | ForEach-Object {
        [pscustomobject]@{
          AttemptId = $_.AttemptId
          StartedUtc = $_.StartedUtc
          CompletedUtc = $_.CompletedUtc
          ExitCode = $_.ExitCode
          TimedOut = $_.TimedOut
          FailureReason = Protect-SensitiveText -Text $_.FailureReason
          DiagnosticsPath = $_.DiagnosticsPath
          ConsoleOutputPath = $_.ConsoleOutputPath
          StatusPath = $_.StatusPath
        }
      })
    }
    [pscustomobject]@{
      CheckpointSchemaVersion = $_.CheckpointSchemaVersion
      SourceServerIdentity = $_.SourceServerIdentity
      SourceDatabase = $_.SourceDatabase
      TargetServerIdentity = $_.TargetServerIdentity
      RunId = $_.RunId
      FolderPath = $_.FolderPath
      BacpacPath = $_.BacpacPath
      BacpacLengthBytes = $_.BacpacLengthBytes
      BacpacSha256 = $_.BacpacSha256
      ExportCompletedAtUtc = $_.ExportCompletedAtUtc
      TargetDatabase = $_.TargetDatabase
      ExportStatus = $_.ExportStatus
      ExportFailureReason = Protect-SensitiveText -Text $_.ExportFailureReason
      ExportLastUpdatedUtc = $_.ExportLastUpdatedUtc
      ExportAttempts = & $sanitizeAttempts -Attempts @($_.ExportAttempts)
      ImportStatus = $_.ImportStatus
      ImportFailureReason = Protect-SensitiveText -Text $_.ImportFailureReason
      ImportLastUpdatedUtc = $_.ImportLastUpdatedUtc
      ImportStartedUtc = $_.ImportStartedUtc
      ImportCompletedUtc = $_.ImportCompletedUtc
      ImportDuration = $_.ImportDuration
      ImportLastActivityUtc = $_.ImportLastActivityUtc
      ImportAttempts = & $sanitizeAttempts -Attempts @($_.ImportAttempts)
      TargetStateAfterImport = $_.TargetStateAfterImport
      ResumeState = $_.ResumeState
      FailureCategory = $_.FailureCategory
      ManualNextAction = Protect-SensitiveText -Text $_.ManualNextAction
      ValidationReportStatus = $_.ValidationReportStatus
    }
  })
  $checkpoint = [pscustomobject]@{
    SchemaVersion = $script:BacpacCheckpointSchemaVersion
    SourceServerIdentity = $script:SourceServerIdentity
    TargetServerIdentity = $script:TargetServerIdentity
    RunId = $script:MigrationRunId.ToString('D')
    LastUpdatedUtc = [DateTime]::UtcNow
    SelectionMode = $SelectionMode
    TargetConfiguration = $targetConfiguration
    Databases = $sanitizedDatabases
  }
  $json = $checkpoint | ConvertTo-Json -Depth 10
  $temporaryPath = "$Path.tmp"
  Set-Content -LiteralPath $temporaryPath -Value $json -Encoding utf8
  Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
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
if (-not $sourceIdentityVariable -or -not $sourceIdentityVariable.Value -or
    -not $targetIdentityVariable -or -not $targetIdentityVariable.Value) {
  throw 'Source and target server identities must be resolved before creating or resuming a manifest.'
}
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
of selected databases. Set `$userProvidedExportRoot` to the collected path or
`$null` to use `$env:USERPROFILE\SqlMigration\Bacpac`.

```powershell
$requestedExportRoot = if ($userProvidedExportRoot) {
  $userProvidedExportRoot
} else {
  Join-Path $env:USERPROFILE 'SqlMigration\Bacpac'
}
$exportRoot = [IO.Path]::GetFullPath($requestedExportRoot)

$selectedDatabases = if ($databaseSelection -eq 'All') {
  @($sourceDatabases)
} else {
  @($sourceDatabases | Where-Object { $_ -ceq $databaseSelection })
}
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
