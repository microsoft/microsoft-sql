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