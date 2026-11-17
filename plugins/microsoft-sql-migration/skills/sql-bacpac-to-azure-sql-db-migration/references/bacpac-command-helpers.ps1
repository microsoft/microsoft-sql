# Copyright (c) Microsoft Corporation.
# Licensed under the MIT license.

Set-StrictMode -Version Latest

function Invoke-SqlcmdCapture {
  param(
    [Parameter(Mandatory)] [string] $Path,
    [Parameter(Mandatory)] [string[]] $ArgumentList
  )

  $output = & $Path @ArgumentList 2>&1 | Out-String
  [pscustomobject]@{
    Output    = $output
    Succeeded = $LASTEXITCODE -eq 0
  }
}

function Find-CompatibleGoSqlcmd {
  param(
    [ValidateSet('InteractiveEntra', 'ActiveDirectoryDefault')]
    [string] $AuthenticationMethod = 'InteractiveEntra'
  )

  $requiredFlags = if ($AuthenticationMethod -eq 'InteractiveEntra') {
    @('-G', '-U')
  } else {
    @('--authentication-method')
  }
  $compatibleCandidates = @()
  $commands = @(Get-Command -Name @('gosqlcmd', 'sqlcmd') -All `
    -ErrorAction SilentlyContinue | Where-Object {
      -not [string]::IsNullOrWhiteSpace([string] $_.Source) -and
      (Test-Path -LiteralPath $_.Source -PathType Leaf)
    } | Sort-Object Source -Unique)

  foreach ($candidate in $commands) {
    $path = $candidate.Source
    $versionResult = Invoke-SqlcmdCapture `
      -Path $path -ArgumentList @('--version')
    $modernHelpResult = Invoke-SqlcmdCapture `
      -Path $path -ArgumentList @('--help')
    $compatibilityHelpOutput = & $path '-?' 2>&1 | Out-String
    $compatibilityHelpSucceeded = $LASTEXITCODE -eq 0
    $isExplicitGoCommand = $candidate.Name -match '^(?i:gosqlcmd)(\.exe)?$'
    $isGoSqlcmd = $isExplicitGoCommand -or $versionResult.Succeeded -or
      $modernHelpResult.Succeeded
    if (-not $isGoSqlcmd) {
      Write-Warning "Skipped legacy or incompatible sqlcmd '$path'."
      continue
    }

    $successfulHelpOutput = @(
      if ($modernHelpResult.Succeeded) { $modernHelpResult.Output }
      if ($compatibilityHelpSucceeded) { $compatibilityHelpOutput }
    ) -join "`n"
    $missingFlags = @($requiredFlags | Where-Object {
      $pattern = '(?m)(?<!\S){0}(?=$|[\s,=])' -f
        [regex]::Escape($_)
      $successfulHelpOutput -notmatch $pattern
    })
    $availableHelpModes = @(
      if ($modernHelpResult.Succeeded) { '--help' }
      if ($compatibilityHelpSucceeded) { '-?' }
    ) -join ', '
    $capabilityStatus = if ($missingFlags.Count -eq 0 -and
        -not [string]::IsNullOrWhiteSpace($availableHelpModes)) {
      'Confirmed'
    } else { 'Unknown' }
    if ($capabilityStatus -eq 'Unknown') {
      Write-Warning "Go sqlcmd '$path' launched, but help did not confirm the $AuthenticationMethod flags: $($missingFlags -join ', '). The attended target preflight is authoritative."
    }
    $compatibleCandidates += [pscustomobject]@{
      Path = $path
      CommandName = $candidate.Name
      Version = $versionResult.Output.Trim()
      HelpModes = $availableHelpModes
      AuthenticationMethod = $AuthenticationMethod
      CapabilityStatus = $capabilityStatus
      MissingFlags = $missingFlags
      CommandPriority = if ($isExplicitGoCommand) { 0 } else { 1 }
    }
  }

  $selectedCandidate = $compatibleCandidates | Sort-Object `
    CommandPriority, `
    @{ Expression = { if ($_.CapabilityStatus -eq 'Confirmed') { 0 } else { 1 } } }, `
    Path | Select-Object -First 1
  return $selectedCandidate
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

  $actionArguments = @($sqlPackageArguments | Where-Object {
    $_ -match '(?i)^/Action:(Export|Import)$'
  })
  if ($actionArguments.Count -ne 1 -or
      $actionArguments[0] -ine "/Action:$Operation") {
    return New-SqlPackageAttemptResult -ExitCode -2 -TimedOut $false `
      -FailureReason "SqlPackage requires exactly one /Action:$Operation argument."
  }
  $requiredArgumentPrefixes = if ($Operation -eq 'Export') {
    @('/SourceConnectionString:', '/TargetFile:')
  } else {
    @('/SourceFile:', '/TargetConnectionString:')
  }
  foreach ($requiredPrefix in $requiredArgumentPrefixes) {
    $matchingArguments = @($sqlPackageArguments | Where-Object {
      $_.StartsWith($requiredPrefix, [StringComparison]::OrdinalIgnoreCase)
    })
    if ($matchingArguments.Count -ne 1 -or
        $matchingArguments[0].Length -eq $requiredPrefix.Length) {
      return New-SqlPackageAttemptResult -ExitCode -2 -TimedOut $false `
        -FailureReason "SqlPackage requires exactly one nonempty '$requiredPrefix<value>' argument passed as a single process argument."
    }
  }
  $detachedArgumentFragments = @($sqlPackageArguments | Where-Object {
    $_ -notmatch '^/' -and (
      $_ -match '(?i)^(Server|Data Source|Integrated Security|Trusted_Connection|Initial Catalog|Database)=' -or
      $_ -match '(?i)\.bacpac$'
    )
  })
  if ($detachedArgumentFragments.Count -gt 0) {
    return New-SqlPackageAttemptResult -ExitCode -2 -TimedOut $false `
      -FailureReason 'SqlPackage arguments contain a detached connection-string or BACPAC-path fragment. Preserve each /Name:<value> pair as one process argument.'
  }

  $startInfo = [Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $sqlPackage.Source
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  foreach ($argument in $sqlPackageArguments) {
    [void] $startInfo.ArgumentList.Add($argument)
  }

  $process = [Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  $processStarted = $false
  $standardOutputReader = $null
  $standardErrorReader = $null
  $consoleOutputWriter = $null
  $consoleReadState = $null

  function Receive-SqlPackageConsoleOutput {
    param([switch] $WaitForCompletion)

    foreach ($streamName in @('Output', 'Error')) {
      $readerProperty = "${streamName}Reader"
      $taskProperty = "${streamName}Task"
      while ($null -ne $consoleReadState.$taskProperty -and
          ($WaitForCompletion -or $consoleReadState.$taskProperty.IsCompleted)) {
        $line = $consoleReadState.$taskProperty.GetAwaiter().GetResult()
        if ($null -eq $line) {
          $consoleReadState.$taskProperty = $null
          break
        }
        $consoleOutputWriter.WriteLine($line)
        $consoleReadState.$taskProperty =
          $consoleReadState.$readerProperty.ReadLineAsync()
      }
    }
  }

  try {
    $consoleOutputStream = [IO.File]::Open(
      $consoleOutputPath,
      [IO.FileMode]::CreateNew,
      [IO.FileAccess]::Write,
      [IO.FileShare]::Read
    )
    $streamWriter = [IO.StreamWriter]::new(
      $consoleOutputStream,
      [Text.UTF8Encoding]::new($false)
    )
    $streamWriter.AutoFlush = $true
    $consoleOutputWriter = [IO.TextWriter]::Synchronized($streamWriter)
    try {
      $processStarted = $process.Start()
    } catch {
      $launchFailureReason = Protect-SensitiveText -Text (
        "Failed to start SqlPackage for '$DatabaseName': $($_.Exception.Message)"
      )
      return New-SqlPackageAttemptResult -ExitCode -1 -TimedOut $false `
        -FailureReason $launchFailureReason
    }
    if (-not $processStarted) {
      return New-SqlPackageAttemptResult -ExitCode -1 -TimedOut $false `
        -FailureReason "Failed to start SqlPackage for '$DatabaseName'."
    }
    $standardOutputReader = $process.StandardOutput
    $standardErrorReader = $process.StandardError
    $consoleReadState = [pscustomobject]@{
      OutputReader = $standardOutputReader
      OutputTask = $standardOutputReader.ReadLineAsync()
      ErrorReader = $standardErrorReader
      ErrorTask = $standardErrorReader.ReadLineAsync()
    }
  $lastActivityUtc = $startedUtc
  $previousDiagnosticsBytes = 0L
  $previousProgressBytes = 0L
  $nextStatusUtc = $startedUtc.AddSeconds($PollSeconds)
  $timeoutUtc = $startedUtc.AddSeconds($TimeoutSeconds)
  Write-SqlPackageStatus "[$($startedUtc.ToString('u'))] $Operation started: '$DatabaseName' ($BatchIndex of $BatchCount). Next status update in $PollSeconds seconds. Status file: '$StatusPath'."

  while (-not $process.HasExited) {
    $nowUtc = [DateTime]::UtcNow
    $millisecondsUntilStatus = [Math]::Max(
      0,
      [Math]::Ceiling(($nextStatusUtc - $nowUtc).TotalMilliseconds)
    )
    $millisecondsUntilTimeout = [Math]::Max(
      0,
      [Math]::Ceiling(($timeoutUtc - $nowUtc).TotalMilliseconds)
    )
    $outputPumpMilliseconds = [Math]::Min(
      100,
      [Math]::Min($millisecondsUntilStatus, $millisecondsUntilTimeout)
    )
    [void] $process.WaitForExit($outputPumpMilliseconds)
    Receive-SqlPackageConsoleOutput

    if ($process.HasExited) { break }

    $nowUtc = [DateTime]::UtcNow
    if ($nowUtc -ge $timeoutUtc) {
      try {
        $process.Kill($true)
      } catch [InvalidOperationException] {
        if (-not $process.HasExited) { throw }
      }
      if (-not $process.WaitForExit(30000) -or -not $process.HasExited) {
        throw "SqlPackage $Operation timed out and process tree $($process.Id) could not be terminated. Stop it before retrying."
      }
      $process.WaitForExit()
      Receive-SqlPackageConsoleOutput -WaitForCompletion
      Write-SqlPackageStatus "[$([DateTime]::UtcNow.ToString('u'))] $Operation '$DatabaseName' timed out after $TimeoutSeconds seconds."
      return New-SqlPackageAttemptResult -ExitCode -1 -TimedOut $true `
        -FailureReason "SqlPackage $Operation timed out after $TimeoutSeconds seconds."
    }

    if ($nowUtc -lt $nextStatusUtc) { continue }

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
    $nextStatusUtc = [DateTime]::UtcNow.AddSeconds($PollSeconds)
  }

  Write-Progress -Activity "SqlPackage $Operation" -Completed
  $process.WaitForExit()
  Receive-SqlPackageConsoleOutput -WaitForCompletion
  $exitCode = $process.ExitCode
  $failureReason = if ($exitCode -eq 0) {
    $null
  } elseif (Test-Path -LiteralPath $DiagnosticsPath -PathType Leaf) {
    (Get-Content -LiteralPath $DiagnosticsPath -Tail 20) -join ' '
  } elseif (Test-Path -LiteralPath $consoleOutputPath -PathType Leaf) {
    (Get-Content -LiteralPath $consoleOutputPath -Tail 20) -join ' '
  } else {
    "SqlPackage $Operation exited with code $exitCode without diagnostics."
  }
  $failureReason = Protect-SensitiveText -Text $failureReason

  $terminalStatus = if ($exitCode -eq 0) { 'Succeeded' } else { 'Failed' }
  Write-SqlPackageStatus "[$([DateTime]::UtcNow.ToString('u'))] $Operation '$DatabaseName' $terminalStatus with exit code $exitCode."

  New-SqlPackageAttemptResult -ExitCode $exitCode -TimedOut $false `
    -FailureReason $failureReason
  } finally {
    try {
      if ($processStarted -and -not $process.HasExited) {
        try {
          $process.Kill($true)
        } catch [InvalidOperationException] {
          if (-not $process.HasExited) { throw }
        }
        if (-not $process.WaitForExit(30000) -or -not $process.HasExited) {
          throw "SqlPackage $Operation process tree $($process.Id) could not be terminated. Stop it before retrying."
        }
      }
      if ($processStarted) {
        $process.WaitForExit()
        if ($null -ne $consoleReadState) {
          Receive-SqlPackageConsoleOutput -WaitForCompletion
        }
      }
    } finally {
      if ($null -ne $standardOutputReader) {
        $standardOutputReader.Dispose()
      }
      if ($null -ne $standardErrorReader) {
        $standardErrorReader.Dispose()
      }
      if ($null -ne $consoleOutputWriter) {
        $consoleOutputWriter.Dispose()
      }
      $process.Dispose()
    }
  }
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

      @($Attempts | Where-Object { $null -ne $_ } | ForEach-Object {
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
# SIG # Begin signature block
# MIInKAYJKoZIhvcNAQcCoIInGTCCJxUCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCArGo6u92qvNUnQ
# BDPk6NoCDgr2x+KrDHEx6UgE2EzRCaCCDLowggX1MIID3aADAgECAhMzAAACHU0Z
# yE7XD1dIAAAAAAIdMA0GCSqGSIb3DQEBCwUAMFcxCzAJBgNVBAYTAlVTMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jvc29mdCBD
# b2RlIFNpZ25pbmcgUENBIDIwMjQwHhcNMjYwNDE2MTg1OTQzWhcNMjcwNDE1MTg1
# OTQzWjB0MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UE
# BxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMR4wHAYD
# VQQDExVNaWNyb3NvZnQgQ29ycG9yYXRpb24wggEiMA0GCSqGSIb3DQEBAQUAA4IB
# DwAwggEKAoIBAQDQvewXxx9gZZFC6Ys1WBay8BJ8kGA4JQnH5CMafqOASlTpK9H8
# o5ZXTXt0caVQTNMUPt445wXYD+dFtaKWTwDn1I52oUSrC9vJin1Gsqt+zyKJL5Dg
# 3eQXbQNR61DmMy20GLTIO3SFed9Rfi/ophgCLGFLDR3r0KvHjwMb/jYWS0celV/4
# Lz27LfAekm8v9E5IXaeiXbAUYZKK090n4CVl3JBtbN+9DtI9SNu/yjvozW52/u7R
# X/Ttpa/KDlpuokZ+Zcbvmtd9ur9gFLvZzh41o9MsE/clQtdaFWGvuo6Jua/ntpgk
# ey3E5/vBFe+MJPG6phdnuo6r57ZudCudiI1bAgMBAAGjggGbMIIBlzAOBgNVHQ8B
# Af8EBAMCB4AwHwYDVR0lBBgwFgYKKwYBBAGCN0wIAQYIKwYBBQUHAwMwHQYDVR0O
# BBYEFH6QuMwqcPG0hQlQ6c5jCtTTLrVeMEUGA1UdEQQ+MDykOjA4MR4wHAYDVQQL
# ExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xFjAUBgNVBAUTDTIzMDAxMis1MDc1NTkw
# HwYDVR0jBBgwFoAUf1k/VCHarU/vBeXmo9ctBpQSCDEwYAYDVR0fBFkwVzBVoFOg
# UYZPaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0
# JTIwQ29kZSUyMFNpZ25pbmclMjBQQ0ElMjAyMDI0LmNybDBtBggrBgEFBQcBAQRh
# MF8wXQYIKwYBBQUHMAKGUWh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMv
# Y2VydHMvTWljcm9zb2Z0JTIwQ29kZSUyMFNpZ25pbmclMjBQQ0ElMjAyMDI0LmNy
# dDAMBgNVHRMBAf8EAjAAMA0GCSqGSIb3DQEBCwUAA4ICAQBKTbYOjzwTG/DXGaz9
# s6+fQeaTtDcFmMY+5UyVFCyj7Pv+5i37qfX8lSL/tBIfYQfWsMuBQlfZurJD6r4H
# VJ2CeH+1fgiq8dcHdVKoZ3Sa2qXoX3cq9iS8cVb06B7+5/XJ7I0OxHH9fDsvJ3T3
# w5V/ZtAIFmLrl+P0CtG+92uzRsn0nTbdFjOkLMLWPLAU3THohKRlSEMgFJpPkm5n
# 5UAZ35xX6FWCrDLsSKb555bTifwa8mJBwdlof0bmfYidH+dxZ1FdDxvLnNl9zeKs
# A4kejaaIqqIPguhwAti5Ql7BlTNoJNwxCvBmqW2MQLnCkYN/VVUsR3V2x/rcTNzo
# Bf/Z/SpROvdaA2ZOOd1uioXJt3tdLQ7vHpqpib0KfWr/FWXW10q38VxfCnRQBqzb
# SuztR7nEMuzX7Ck+B/XaPDXd1qh72+QYyB0Z2VzWmO9zsnb9Uq/dwu8LGeQqnyu6
# 7SDGACvnXii2fb9+US492VTnXSnFKyqwgzUyFMtZK1/sHYTv6bG4TtQUygQxTN+Z
# V+aJIlKO2MqZ7bKrAnOzS9m6NgoTdWOq11bTOZwKlIEV/EhV9SWkDmdpR/hPPT2v
# 6TEj4F8PT/zHjRezIU5c/DGlt/VhY/pK0XkJtEyMmmS1BMtjU/rqBZVMIm3dnxQs
# /TBByr+Cf8Z1r7aifQVQ+WSqzjCCBr0wggSloAMCAQICEzMAAAA5O7Y3Gb8GHWcA
# AAAAADkwDQYJKoZIhvcNAQEMBQAwgYgxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpX
# YXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQg
# Q29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBSb290IENlcnRpZmljYXRl
# IEF1dGhvcml0eSAyMDExMB4XDTI0MDgwODIwNTQxOFoXDTM2MDMyMjIyMTMwNFow
# VzELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEo
# MCYGA1UEAxMfTWljcm9zb2Z0IENvZGUgU2lnbmluZyBQQ0EgMjAyNDCCAiIwDQYJ
# KoZIhvcNAQEBBQADggIPADCCAgoCggIBANgBnB7jOMeqlRYHNa265v4IY9fH8TKh
# emHfPINe1gpLaV3dhg324WwH06LcHbpnsBukCDNitryo0dtS/EW6I/yEL/bLSY8h
# KpbfQuWusBPr9qazYcDxCW/qnjb5JsI1s8bNOg3bVATvQVL4tcf03aTycsz8QeCd
# M0l/yHRObJ9QqazM1r6VPEOJ7LL+uEEb73w6QCuhs89a1uv1zerOYMnsneRRwCbp
# yW11IcggU0cRKDDq1pjVJzIbIF6+oiXXbReOsgeI8zu1FyQfK0fVkaya8SmVHQ/t
# Of23mZ4W9k0Ri22QW9p3UgSC5OUDktKxxcCmGL6tXLfOGSWHIIV4YrTJTT6PNty5
# REojHJuZHArkF9VnHTERWoTjAzfI3kP+5b4alUdhgAZ7ttOu1bVnXfHaqPYl2rPs
# 20ji03LOVWsh/radgE17es5hL+t6lV0eVHrVhsssROWJuz2MXMCt7iw7lFPG9LXK
# Gjsmonn2gotGdHIuEg5JnJMJVmixd5LRlkmgYRZKzhxSCwyoGIq0PhaA7Y+VPct5
# pCHkijcIIDm0nlkK+0KyepolcqGm0T/GYQRMhHJlGOOmVQop36wUVUYklUy++vDW
# eEgEo4s7hxN6mIbf2MSIQ/iIfMZgJxC69oukMUXCrOC3SkE/xIkgpfl22MM1itkZ
# 35nNXkMolU1lAgMBAAGjggFOMIIBSjAOBgNVHQ8BAf8EBAMCAYYwEAYJKwYBBAGC
# NxUBBAMCAQAwHQYDVR0OBBYEFH9ZP1Qh2q1P7wXl5qPXLQaUEggxMBkGCSsGAQQB
# gjcUAgQMHgoAUwB1AGIAQwBBMA8GA1UdEwEB/wQFMAMBAf8wHwYDVR0jBBgwFoAU
# ci06AjGQQ7kUBU7h6qfHMdEjiTQwWgYDVR0fBFMwUTBPoE2gS4ZJaHR0cDovL2Ny
# bC5taWNyb3NvZnQuY29tL3BraS9jcmwvcHJvZHVjdHMvTWljUm9vQ2VyQXV0MjAx
# MV8yMDExXzAzXzIyLmNybDBeBggrBgEFBQcBAQRSMFAwTgYIKwYBBQUHMAKGQmh0
# dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2kvY2VydHMvTWljUm9vQ2VyQXV0MjAx
# MV8yMDExXzAzXzIyLmNydDANBgkqhkiG9w0BAQwFAAOCAgEAFJQfOChP7onn6fLI
# MKrSlN1WYKwDFgAddymOUO3FrM8d7B/W/iQ6DxXsDn7D5W4wMwYeLystcEqfkjz4
# NURRgazyMu5yRzQh4LqjA4tStTcJh1opExo7nn5PuPBYnbu0+THSuVHTe0VTTPVh
# ily/piFrDo3axQ9P4C+Ol5yet+2gTfekICS5xS+cYfSIvgn0JksVBVMYVI5QFu/q
# hnLhsEFEUzG8fvv0hjgkO+lkpV9ty6GkN4vdnd7ya6Q6aR9y34aiM1qmxaxBi6OU
# nyNl6fkuun/diTFnYDLTppOkr/mg5WSfCiDVMNCxtj4wPKC5OmHm1DQIt/MNokbb
# H3UGsFP1QbzsLocuSqLCvH09Io3fDPTmscR9Y75G4qX7RTX8AdBPo0I6OEojf39z
# uFZt0qOHm65YWQE69cZM2ueE1MB05dNNgHK9gTE7zKvK/fg8B2qjW88MT/WF5V5u
# vZGtqa9FSL2RazArA+rDPuf6JGYz4HpgMZHB4S6szWSKYBv0VisCzfxgeU+dquXW
# 9bd0auYlOB58DPcOYKdc3Se94g+xL4pcEhbB54JOgAkwYTu/9dLeH2pDqeJZAABV
# DWRQCaXfO5LgyKwKCLYXpigrZYCjUSBcr+Ve8PFWMhVTQl0v4q8J/AUmQN5W4n10
# 1cY2L4A7GTQG1h32HHAvfQESWP0xghnEMIIZwAIBATBuMFcxCzAJBgNVBAYTAlVT
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jv
# c29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIdTRnITtcPV0gAAAAAAh0w
# DQYJYIZIAWUDBAIBBQCggZAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwLwYJ
# KoZIhvcNAQkEMSIEIGKEP44GrKbKDHZecwF8L57ryiJwH4A0TNztC6gafePRMEIG
# CisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8v
# d3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEADT7Gs/092BE2OgSw
# 8S1tu/F5v0XXlRm0Bt7gWaNKqFpkdOKgZKKFW+x2CD38Fr4kWtYlreqN0OeyQdZ6
# osVRcFiIbHDZpftLhjMrb+Y8dGkbB4iVOke8Lk8EFwFGcRsDdCgLkHz87ku0+jFr
# z35amZg1evAw4o3yXRgmGtQqgC4nsBnFD2l3W79bM/POlgjyMHuucVEuLswApl11
# 6Rjf+SzVkpaGhxFZycSZ+Ap4ovkMSUiQDQyyKGaDN72aqhKR/MvN/RqPtgsS8BbD
# BkXbOG1PCwS477Trj5xsrJdCO/F5s0vucBWcanUeCmePjcMVyKLMSafHyHLNqi9m
# CC/PQKGCF5QwgheQBgorBgEEAYI3AwMBMYIXgDCCF3wGCSqGSIb3DQEHAqCCF20w
# ghdpAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFSBgsqhkiG9w0BCRABBKCCAUEEggE9
# MIIBOQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCA5bo33+pCZ1AJb
# /noTyU6WlQxgyzgEkqdve68GHDZQFgIGavNLjCggGBMyMDI2MTExMzIyMTAzMC4z
# ODhaMASAAgH0oIHRpIHOMIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScw
# JQYDVQQLEx5uU2hpZWxkIFRTUyBFU046QTAwMC0wNUUwLUQ5NDcxJTAjBgNVBAMT
# HE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2WgghHqMIIHIDCCBQigAwIBAgIT
# MwAAAiu7AFD/TTuaoQABAAACKzANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJV
# UzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UE
# ChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGlt
# ZS1TdGFtcCBQQ0EgMjAxMDAeFw0yNjAyMTkxOTQwMTFaFw0yNzA1MTcxOTQwMTFa
# MIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQL
# ExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxk
# IFRTUyBFU046QTAwMC0wNUUwLUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1l
# LVN0YW1wIFNlcnZpY2UwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQCX
# 3mi6OD3syUqQm4QqgkrKPbcsK/Qx3fYctL8+VM1uOY3booi5GxwauTgQf6JFHITT
# oxS7gjqKlK8OFLzL6UTl0jxEK5t6DuOcgJXdvutimoTlOS0C3kyITXBAXoj/gp6h
# RR9z6WRip1Ktkilb3dJXCjQqT9P2Cuujr+Vz8r+Z+jDl09ji/ic/4G34r3mVwjs/
# /Gnx9Pu31V8rXFicNiAzxpubawpbd8pqfzlWT2vnG3kF9l6MiREbvJ3XHLUwHQsh
# 0t/TrSFx/s/yCqpJWYJ6oClG70tvsFH0aRP8wB4cP/CFa2ILvk26i3OcJBl+pqKj
# HTSBy9mvwTPEDlnzco0Nt8R6pSPTXZgBsscHhoKfC0WQmOzY2keXbAmRTcZMyXz5
# v/AJbmoI0y07Bazvt5NkXddG9TErQWwtsFyIKrElDgWfHeCoTu1wu2ciD3dK72z3
# ca2gzoEDxT2j9BXIUKaiTzTdQPRsAMaO3dU0zaGwMMlwtSJyDh14YEgZoUu5vS8M
# ugMqdrNjphyL65yKhjpAWbhYkIHO/0uZju95tP8zZNqXIRh4tdfWHJPATn9r+cxk
# yuh2x0VLdfx1lmK9X3NjH0NtgAs5JB/wOlkyuudxmFTfWVyRrL37ispOZ8aPAFgv
# yR6cNTkGpkFo35JRjciNmZiU4qT9Uty+V5gudFk1jwIDAQABo4IBSTCCAUUwHQYD
# VR0OBBYEFD4WjuQTUJbtbd3jmvZku0FZ2eU2MB8GA1UdIwQYMBaAFJ+nFV0AXmJd
# g/Tl0mWnG1M1GelyMF8GA1UdHwRYMFYwVKBSoFCGTmh0dHA6Ly93d3cubWljcm9z
# b2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0El
# MjAyMDEwKDEpLmNybDBsBggrBgEFBQcBAQRgMF4wXAYIKwYBBQUHMAKGUGh0dHA6
# Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwVGlt
# ZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3J0MAwGA1UdEwEB/wQCMAAwFgYDVR0l
# AQH/BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeAMA0GCSqGSIb3DQEBCwUA
# A4ICAQDO/CKsciEM8kr1fqH4TlfT66ENoTjxXw810pyEq0PdrgLwfgT3x+1gz7CQ
# HtUdevqMQ5qHyDLhm6pT911CYkGN+6g+MU7fMYTr6d3SxieJwBIoWkfR4g7SitGz
# MKU465KEYejfddoUgovC/xcRpaALO5p3/A248ByhJiMttBQNDtsT/HaCFwRFCURb
# y/f8c1kky8F8xkCXFz+/MtZ5d1lWFjwOI2geZHWq9XihDOgee5nS2koo5V6n8XG2
# 20UTevVf+pgmpIH71XKDVIYTGGZJs6yPlfJ2aXqw1ME4NR6okNsY3P1M31H6DMYR
# fJGNBNep595kXGh3YzA3cCiyg+jmJ58h/fTvjngIpuUFfODpDjFx0ic1YoLANxhC
# F3RhS9qYM7K40NEhKshYuaAkIG2XBKYig3r/0/b0sjvjBws55AYonMm3A8qcX/6k
# 9Vfc0mv9dtonHuWGfA2b+qE2qpCnhzGbdDHq7iOSZEw01nNupAMf1c41k9IoTQ2z
# 3iw6w4ZZoLOyg4TKMbp1krpT4trip/y30Cv5khyqCDNqaXQpBkOYON8LgtoQ3amV
# OX7ix5jdrnx/vUxTUSigXvrWdL7Uk8kpmS0zto2Toy7aT5oBzCTvfj9iJ/BN/E1v
# hFBkhJCvZ7PVvsMSnTTmkx2Fal2lVkztuAI44fD/uyLJdaMQSzCCB3EwggVZoAMC
# AQICEzMAAAAVxedrngKbSZkAAAAAABUwDQYJKoZIhvcNAQELBQAwgYgxCzAJBgNV
# BAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4w
# HAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29m
# dCBSb290IENlcnRpZmljYXRlIEF1dGhvcml0eSAyMDEwMB4XDTIxMDkzMDE4MjIy
# NVoXDTMwMDkzMDE4MzIyNVowfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hp
# bmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jw
# b3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAw
# ggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDk4aZM57RyIQt5osvXJHm9
# DtWC0/3unAcH0qlsTnXIyjVX9gF/bErg4r25PhdgM/9cT8dm95VTcVrifkpa/rg2
# Z4VGIwy1jRPPdzLAEBjoYH1qUoNEt6aORmsHFPPFdvWGUNzBRMhxXFExN6AKOG6N
# 7dcP2CZTfDlhAnrEqv1yaa8dq6z2Nr41JmTamDu6GnszrYBbfowQHJ1S/rboYiXc
# ag/PXfT+jlPP1uyFVk3v3byNpOORj7I5LFGc6XBpDco2LXCOMcg1KL3jtIckw+DJ
# j361VI/c+gVVmG1oO5pGve2krnopN6zL64NF50ZuyjLVwIYwXE8s4mKyzbnijYjk
# lqwBSru+cakXW2dg3viSkR4dPf0gz3N9QZpGdc3EXzTdEonW/aUgfX782Z5F37Zy
# L9t9X4C626p+Nuw2TPYrbqgSUei/BQOj0XOmTTd0lBw0gg/wEPK3Rxjtp+iZfD9M
# 269ewvPV2HM9Q07BMzlMjgK8QmguEOqEUUbi0b1qGFphAXPKZ6Je1yh2AuIzGHLX
# pyDwwvoSCtdjbwzJNmSLW6CmgyFdXzB0kZSU2LlQ+QuJYfM2BjUYhEfb3BvR/bLU
# HMVr9lxSUV0S2yW6r1AFemzFER1y7435UsSFF5PAPBXbGjfHCBUYP3irRbb1Hode
# 2o+eFnJpxq57t7c+auIurQIDAQABo4IB3TCCAdkwEgYJKwYBBAGCNxUBBAUCAwEA
# ATAjBgkrBgEEAYI3FQIEFgQUKqdS/mTEmr6CkTxGNSnPEP8vBO4wHQYDVR0OBBYE
# FJ+nFV0AXmJdg/Tl0mWnG1M1GelyMFwGA1UdIARVMFMwUQYMKwYBBAGCN0yDfQEB
# MEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMv
# RG9jcy9SZXBvc2l0b3J5Lmh0bTATBgNVHSUEDDAKBggrBgEFBQcDCDAZBgkrBgEE
# AYI3FAIEDB4KAFMAdQBiAEMAQTALBgNVHQ8EBAMCAYYwDwYDVR0TAQH/BAUwAwEB
# /zAfBgNVHSMEGDAWgBTV9lbLj+iiXGJo0T2UkFvXzpoYxDBWBgNVHR8ETzBNMEug
# SaBHhkVodHRwOi8vY3JsLm1pY3Jvc29mdC5jb20vcGtpL2NybC9wcm9kdWN0cy9N
# aWNSb29DZXJBdXRfMjAxMC0wNi0yMy5jcmwwWgYIKwYBBQUHAQEETjBMMEoGCCsG
# AQUFBzAChj5odHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpL2NlcnRzL01pY1Jv
# b0NlckF1dF8yMDEwLTA2LTIzLmNydDANBgkqhkiG9w0BAQsFAAOCAgEAnVV9/Cqt
# 4SwfZwExJFvhnnJL/Klv6lwUtj5OR2R4sQaTlz0xM7U518JxNj/aZGx80HU5bbsP
# MeTCj/ts0aGUGCLu6WZnOlNN3Zi6th542DYunKmCVgADsAW+iehp4LoJ7nvfam++
# Kctu2D9IdQHZGN5tggz1bSNU5HhTdSRXud2f8449xvNo32X2pFaq95W2KFUn0CS9
# QKC/GbYSEhFdPSfgQJY4rPf5KYnDvBewVIVCs/wMnosZiefwC2qBwoEZQhlSdYo2
# wh3DYXMuLGt7bj8sCXgU6ZGyqVvfSaN0DLzskYDSPeZKPmY7T7uG+jIa2Zb0j/aR
# AfbOxnT99kxybxCrdTDFNLB62FD+CljdQDzHVG2dY3RILLFORy3BFARxv2T5JL5z
# bcqOCb2zAVdJVGTZc9d/HltEAY5aGZFrDZ+kKNxnGSgkujhLmm77IVRrakURR6nx
# t67I6IleT53S0Ex2tVdUCbFpAUR+fKFhbHP+CrvsQWY9af3LwUFJfn6Tvsv4O+S3
# Fb+0zj6lMVGEvL8CwYKiexcdFYmNcP7ntdAoGokLjzbaukz5m/8K6TT4JDVnK+AN
# uOaMmdbhIurwJ0I9JZTmdHRbatGePu1+oDEzfbzL6Xu/OHBE0ZDxyKs6ijoIYn/Z
# cGNTTY3ugm2lBRDBcQZqELQdVTNYs6FwZvKhggNNMIICNQIBATCB+aGB0aSBzjCB
# yzELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1Jl
# ZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjElMCMGA1UECxMc
# TWljcm9zb2Z0IEFtZXJpY2EgT3BlcmF0aW9uczEnMCUGA1UECxMeblNoaWVsZCBU
# U1MgRVNOOkEwMDAtMDVFMC1EOTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1T
# dGFtcCBTZXJ2aWNloiMKAQEwBwYFKw4DAhoDFQAJrD90ykHpo/0AGb7lmwvsCtqR
# OaCBgzCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# JjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMA0GCSqGSIb3
# DQEBCwUAAgUA7qG94jAiGA8yMDI2MTExMzE2NDgzNFoYDzIwMjYxMTE0MTY0ODM0
# WjB0MDoGCisGAQQBhFkKBAExLDAqMAoCBQDuob3iAgEAMAcCAQACAg+xMAcCAQAC
# AhMlMAoCBQDuow9iAgEAMDYGCisGAQQBhFkKBAIxKDAmMAwGCisGAQQBhFkKAwKg
# CjAIAgEAAgMHoSChCjAIAgEAAgMBhqAwDQYJKoZIhvcNAQELBQADggEBAHwO2bIq
# uGIVYAXQmY2pBuidXcA//dm+SmC6LQwrw+aDMWSXFVaPPSdAnNsWz+FPlqgYVm+F
# y+ztjd/jAlLq6uCN24WDabwOdBi+m1KONsXQoS4W7ZmaQDSo/m9URLBK8JzQhX0L
# NLM2IvRlWifN0WQH+dr+QEG0wJBDfwbHbIzKqEGSNU8cLWibIXFQHxP16eY8IfnM
# imHujLtFnlJpI3QXYoLIOUkZ1yiKu/0AjwtMqXy3XgNFX6/nzLh20tX94SGhRzwg
# AQCUQJQZZpgOd9WO0wwXldnJzLThX4dvaM8mHrQepHNL0602XiZv3kJJiKoniZPn
# 2n01F8pmFKJtZnsxggQNMIIECQIBATCBkzB8MQswCQYDVQQGEwJVUzETMBEGA1UE
# CBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9z
# b2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQ
# Q0EgMjAxMAITMwAAAiu7AFD/TTuaoQABAAACKzANBglghkgBZQMEAgEFAKCCAUow
# GgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCBpYXY6
# +ytMUlJJ00AKV+FC95U231PbvOGPQtNYFJzEBjCB+gYLKoZIhvcNAQkQAi8xgeow
# gecwgeQwgb0EIHIOI/Q/kFftYA+M2OY+1Bx3ajBD6/WDAtPT2vFkv25SMIGYMIGA
# pH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcT
# B1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UE
# AxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAIruwBQ/007mqEA
# AQAAAiswIgQgi7sLt5BDcNi/mcFqV3r+o48JYyUFh2ph+fT9Bzss2XEwDQYJKoZI
# hvcNAQELBQAEggIAZhngtDu5RdjjtDjjuIdY9U/tdvlBkowzUi3QUPVtb+cDGp6C
# vYvSJ6nVLONdfJwqg5wnCmoGEZy2TKH+2gW4dJuvSp3hA231QUKlDHEuMPfds1QE
# Q7Q9MjaWWbrUoOnxY3MqLF113xZd4VDSqXdEky+f0aamtNFmhdc+XMwGXyIEJ7iY
# TnWm06oS5w0NIFRQTOwR+Dzz2JeSJ91ZRItRDqynJV8GJ2jOjluMjF6dIXRGjDJS
# H3ndovB8ZuQGnUx8THa0uP1NhF5fDWsTccFeSmbZUT5Lc6o41YDxykagv1foE9s7
# nz3odmHr7MlGG0pDGjbtzx+/TFYoDFauCE4LMyp61LinsEuAnoc8rsnO7kVQozAM
# b/U8nnypR7n32rv2vu3DfXokc01ZWIIKBxqgzLIVrX/vymou4XUGosnwz9RJXRJk
# q7tGRCd3am7UXu/0fXSk1Ubzarub2358wB81Gnoq8rlAZR4tcGl7Oozfr24gfrAO
# xufdMiEf7E5nkaLWnopsRuALS3CxObFHLBvQLSt5bA90Lhwa6XO7Rysbgp2yap6A
# 58ZQLNqJQVmeaFJYfClLrJDa/IeoUazIKEkHWVVzWwJeUXMqNDacYeNd8OH+hcQ3
# wVeJ6B7jkE9LW1/QLUE1QWE2DMfuzklSExRZcaJwQaG0zcRwmqK/gc0s+dE=
# SIG # End signature block
