Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-TargetPreflightTimeoutSeconds {
  param(
    [Parameter(Mandatory)]
    [ValidateSet('InteractiveEntra', 'ActiveDirectoryDefault')]
    [string] $AuthenticationMethod,
    [ValidateRange(0, 3600)]
    [int] $RequestedTimeoutSeconds = 0
  )

  if ($RequestedTimeoutSeconds -gt 0) {
    return $RequestedTimeoutSeconds
  }
  if ($AuthenticationMethod -eq 'InteractiveEntra') {
    return 600
  }
  return 180
}

function Get-ExistingTargetDatabaseNamesFromApprovedSqlcmdRoute {
  param(
    [Parameter(Mandatory)] [string] $SqlcmdPath,
    [Parameter(Mandatory)] [string] $ServerName,
    [Parameter(Mandatory)]
    [ValidateSet('InteractiveEntra', 'ActiveDirectoryDefault')]
    [string] $AuthenticationMethod,
    [string] $UserPrincipalName,
    [Parameter(Mandatory)] [string[]] $DatabaseNames,
    [ValidateSet('Discovery', 'Approval', 'FinalImport')]
    [string] $Purpose = 'Discovery',
    [ValidateRange(0, 3600)]
    [int] $SqlcmdTimeoutSeconds = 0,
    [string] $QueryTemplatePath = (Join-Path $PSScriptRoot 'target-database-preflight.sql')
  )

  if ($AuthenticationMethod -eq 'InteractiveEntra' -and
      [string]::IsNullOrWhiteSpace($UserPrincipalName)) {
    throw 'Interactive Microsoft Entra authentication requires a user principal name.'
  }
  if (-not (Test-Path -LiteralPath $QueryTemplatePath -PathType Leaf)) {
    throw "Target preflight SQL template not found: '$QueryTemplatePath'."
  }
  $effectiveSqlcmdTimeoutSeconds =
    Resolve-TargetPreflightTimeoutSeconds `
      -AuthenticationMethod $AuthenticationMethod `
      -RequestedTimeoutSeconds $SqlcmdTimeoutSeconds

  $databaseNamesJson = ConvertTo-Json -InputObject @($DatabaseNames) -Compress
  $databaseNamesBase64 = [Convert]::ToBase64String(
    [Text.Encoding]::Unicode.GetBytes($databaseNamesJson)
  )
  if ($databaseNamesBase64 -notmatch '\A[A-Za-z0-9+/]*={0,2}\z') {
    throw 'The encoded target database request contains an invalid character.'
  }

  $beginMarker = '__BACPAC_PREFLIGHT_JSON_BEGIN__'
  $endMarker = '__BACPAC_PREFLIGHT_JSON_END__'
  $template = Get-Content -LiteralPath $QueryTemplatePath -Raw
  $placeholder = '{{DATABASE_NAMES_BASE64}}'
  if (($template.Split($placeholder).Count - 1) -ne 1) {
    throw "Target preflight SQL template must contain exactly one $placeholder placeholder."
  }
  $preflightScript = $template.Replace($placeholder, $databaseNamesBase64)

  $scriptPath = Join-Path ([IO.Path]::GetTempPath()) `
    "bacpac-target-preflight-$([Guid]::NewGuid().ToString('N')).sql"
  $outputPath = Join-Path ([IO.Path]::GetTempPath()) `
    "bacpac-target-preflight-$([Guid]::NewGuid().ToString('N')).output.log"
  try {
    Set-Content -LiteralPath $scriptPath -Value $preflightScript `
      -Encoding utf8NoBOM -NoNewline
    $sqlcmdArguments = @(
      '-S', $ServerName, '-d', 'master',
      '--authentication-method', 'ActiveDirectoryDefault', '-b',
      '-h', '-1', '-W', '-w', '65535', '-i', $scriptPath, '-o', $outputPath
    )
    if ($AuthenticationMethod -eq 'InteractiveEntra') {
      $sqlcmdArguments = @('-S', $ServerName, '-d', 'master', '-G',
        '-U', $UserPrincipalName, '-b', '-h', '-1', '-W',
        '-w', '65535', '-i', $scriptPath, '-o', $outputPath)
    }

    # Keep sqlcmd attached to the current console so interactive Entra can
    # launch and complete its browser/MFA flow. Sqlcmd's own -o switch captures
    # the structured query result without redirecting the authentication
    # process's standard handles.
    $process = Start-Process -FilePath $SqlcmdPath `
      -ArgumentList $sqlcmdArguments -NoNewWindow -PassThru
    $completed = $process.WaitForExit($effectiveSqlcmdTimeoutSeconds * 1000)
    if (-not $completed) {
      Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
      $process.WaitForExit()
      throw "The target preflight sqlcmd process timed out after $effectiveSqlcmdTimeoutSeconds seconds and was stopped."
    }
    $process.WaitForExit()
    $outputLines = if (Test-Path -LiteralPath $outputPath -PathType Leaf) {
      @(Get-Content -LiteralPath $outputPath | ForEach-Object {
        ([string] $_).Trim()
      })
    } else { @() }
    if ($process.ExitCode -ne 0) {
      throw "The target preflight sqlcmd process failed with exit code $($process.ExitCode). $($outputLines -join ' ')"
    }

    $beginIndex = [Array]::IndexOf($outputLines, $beginMarker)
    $endIndex = [Array]::IndexOf($outputLines, $endMarker)
    if ($beginIndex -lt 0 -or $endIndex -le ($beginIndex + 1)) {
      throw 'The target preflight did not return a complete structured result.'
    }
    $resultJson = @(
      $outputLines[($beginIndex + 1)..($endIndex - 1)] |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    ) -join ''
    if ([string]::IsNullOrWhiteSpace($resultJson)) {
      throw 'The target preflight returned an empty structured result.'
    }
    $result = $resultJson | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    $canViewAllDatabases = if ($result.ContainsKey('canViewAllDatabases')) {
      [bool] $result['canViewAllDatabases']
    } else {
      $false
    }
    $existingNames = [System.Collections.Generic.List[string]]::new()
    $existingDatabases = if ($result.ContainsKey('existingDatabases')) {
      @($result['existingDatabases'])
    } else {
      @()
    }
    foreach ($entry in $existingDatabases) {
      if ($null -ne $entry -and $entry.ContainsKey('name') -and
          -not [string]::IsNullOrWhiteSpace($entry['name'])) {
        [void] $existingNames.Add([string] $entry['name'])
      }
    }
    $existingSet = [System.Collections.Generic.HashSet[string]]::new(
      $existingNames, [StringComparer]::OrdinalIgnoreCase
    )
    $ambiguousNames = @(
      if (-not $canViewAllDatabases) {
        $DatabaseNames | Where-Object { -not $existingSet.Contains($_) }
      }
    )
    [pscustomobject]@{
      ReceiptId     = [Guid]::NewGuid().ToString('N')
      Purpose       = $Purpose
      ServerName    = $ServerName
      AuthenticationMethod = $AuthenticationMethod
      UserPrincipalName = $UserPrincipalName
      DatabaseNames = @($DatabaseNames)
      CompletedUtc  = [DateTime]::UtcNow
      TimeoutSeconds = $effectiveSqlcmdTimeoutSeconds
      ConsumedUtc   = $null
      ExistingNames  = $existingNames.ToArray()
      AmbiguousNames = $ambiguousNames
    }
  } finally {
    Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $outputPath -Force -ErrorAction SilentlyContinue
  }
}

function Invoke-TargetPreflightOrPause {
  param(
    [Parameter(Mandatory)] [string] $SqlcmdPath,
    [Parameter(Mandatory)] [string] $ServerName,
    [Parameter(Mandatory)] [string] $AuthenticationMethod,
    [string] $UserPrincipalName,
    [Parameter(Mandatory)] [object[]] $Databases,
    [Parameter(Mandatory)] [object[]] $Manifest,
    [Parameter(Mandatory)] [string] $CheckpointPath,
    [Parameter(Mandatory)]
    [ValidateSet('Approval', 'FinalImport')]
    [string] $Purpose,
    [ValidateRange(0, 3600)]
    [int] $SqlcmdTimeoutSeconds = 0
  )

  try {
    $preflightResult = Get-ExistingTargetDatabaseNamesFromApprovedSqlcmdRoute `
      -SqlcmdPath $SqlcmdPath -ServerName $ServerName `
      -AuthenticationMethod $AuthenticationMethod `
      -UserPrincipalName $UserPrincipalName `
      -DatabaseNames @($Databases.TargetDatabase) `
      -Purpose $Purpose -SqlcmdTimeoutSeconds $SqlcmdTimeoutSeconds
  } catch {
    $reason = Protect-SensitiveText -Text $_.Exception.Message
    $category = if (Test-AuthenticationFailure -FailureReason $reason) {
      'Authentication'
    } else { 'TargetPreflight' }
    foreach ($database in $Databases) {
      if ($database.ImportStatus -eq 'Pending') {
        $database.ResumeState = 'AwaitingManualRemediation'
        $database.FailureCategory = $category
        $database.ImportFailureReason = $reason
        $database.ManualNextAction = if ($category -eq 'Authentication') {
          'Verify the same target identity, login/user permissions, network/firewall route, MFA or approved secure-store entry outside this workflow; then return with authentication remediation complete.'
        } else {
          'Verify target connectivity outside this workflow; then return with target remediation complete.'
        }
      }
    }
    Save-SanitizedMigrationCheckpoint `
      -Databases $Manifest -Path $CheckpointPath
    throw "Target preflight paused before import: $reason Checkpoint: '$CheckpointPath'."
  }

  if ($preflightResult.AmbiguousNames.Count -gt 0) {
    $ambiguousSet = [System.Collections.Generic.HashSet[string]]::new(
      [string[]] $preflightResult.AmbiguousNames, [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($database in $Databases) {
      if ($database.ImportStatus -eq 'Pending' -and
          $ambiguousSet.Contains($database.TargetDatabase)) {
        $database.ResumeState = 'AwaitingManualRemediation'
        $database.FailureCategory = 'TargetPreflight'
        $database.ImportFailureReason =
          "The approved target identity cannot confirm '$($database.TargetDatabase)' is absent because it lacks catalog-wide visibility (VIEW ANY DATABASE); the name was not visible to a filtered lookup either."
        $database.ManualNextAction =
          'Grant the same approved identity read-only catalog visibility (for example VIEW ANY DATABASE) or independently confirm the target name is unused outside this workflow; then return with target remediation complete.'
        Write-Warning "Import '$($database.TargetDatabase)' paused: catalog visibility unavailable, absence cannot be confirmed."
      }
    }
    Save-SanitizedMigrationCheckpoint `
      -Databases $Manifest -Path $CheckpointPath
  }

  $preflightResult
}

function Use-FinalTargetPreflightReceipt {
  param(
    [Parameter(Mandatory)] [object] $Receipt,
    [Parameter(Mandatory)] [string] $ServerName,
    [Parameter(Mandatory)]
    [ValidateSet('InteractiveEntra', 'ActiveDirectoryDefault')]
    [string] $AuthenticationMethod,
    [string] $UserPrincipalName,
    [Parameter(Mandatory)] [string[]] $DatabaseNames,
    [ValidateRange(1, 600)]
    [int] $MaximumAgeSeconds = 120
  )

  if ($Receipt.Purpose -cne 'FinalImport') {
    throw 'Only a FinalImport target preflight receipt can authorize an import.'
  }
  if ($Receipt.ConsumedUtc) {
    throw "Target preflight receipt '$($Receipt.ReceiptId)' has already been consumed."
  }
  if (-not [string]::Equals(
      [string] $Receipt.ServerName,
      $ServerName,
      [StringComparison]::OrdinalIgnoreCase
    )) {
    throw 'The target preflight receipt server does not match the import server.'
  }
  if ($Receipt.AuthenticationMethod -cne $AuthenticationMethod -or
      [string] $Receipt.UserPrincipalName -cne [string] $UserPrincipalName) {
    throw 'The target preflight receipt authentication route does not match the import route.'
  }

  $expectedNames = @($DatabaseNames | Sort-Object -Unique)
  $receiptNames = @($Receipt.DatabaseNames | Sort-Object -Unique)
  if ($expectedNames.Count -ne $receiptNames.Count -or
      @(Compare-Object -ReferenceObject $expectedNames `
        -DifferenceObject $receiptNames -CaseSensitive).Count -gt 0) {
    throw 'The target preflight receipt database scope does not match the import scope.'
  }

  $completedUtc = [DateTime] $Receipt.CompletedUtc
  $age = [DateTime]::UtcNow - $completedUtc
  if ($age.TotalSeconds -lt 0 -or
      $age.TotalSeconds -gt $MaximumAgeSeconds) {
    throw "The target preflight receipt is stale; it must be no more than $MaximumAgeSeconds seconds old."
  }
  if (@($Receipt.AmbiguousNames).Count -gt 0) {
    throw 'The target preflight receipt contains database names whose absence is not authoritative.'
  }

  $Receipt.ConsumedUtc = [DateTime]::UtcNow
  @($Receipt.ExistingNames)
}

function New-TargetConnectionStringForApprovedAuthentication {
  param(
    [Parameter(Mandatory)] [string] $ServerName,
    [Parameter(Mandatory)]
    [ValidateSet('InteractiveEntra', 'ActiveDirectoryDefault')]
    [string] $AuthenticationMethod,
    [string] $UserPrincipalName
  )

  if ($AuthenticationMethod -eq 'InteractiveEntra' -and
      [string]::IsNullOrWhiteSpace($UserPrincipalName)) {
    throw 'Interactive Microsoft Entra authentication requires a user principal name.'
  }

  $builder = [System.Data.Common.DbConnectionStringBuilder]::new()
  $builder['Data Source'] = $ServerName
  $builder['Encrypt'] = $true
  $builder['TrustServerCertificate'] = $false
  $builder['Connect Timeout'] = 30
  if ($AuthenticationMethod -eq 'InteractiveEntra') {
    $builder['Authentication'] = 'Active Directory Interactive'
    $builder['User ID'] = $UserPrincipalName
  } else {
    $builder['Authentication'] = 'Active Directory Default'
  }
  $builder.get_ConnectionString()
}

function New-TargetConnectionStringAfterAttendedAuthentication {
  param(
    [Parameter(Mandatory)] [string] $SqlcmdPath,
    [Parameter(Mandatory)] [string] $ServerName,
    [Parameter(Mandatory)]
    [ValidateSet('InteractiveEntra', 'ActiveDirectoryDefault')]
    [string] $AuthenticationMethod,
    [string] $UserPrincipalName
  )

  if ($AuthenticationMethod -eq 'InteractiveEntra' -and
      [string]::IsNullOrWhiteSpace($UserPrincipalName)) {
    throw 'Interactive Microsoft Entra authentication requires a user principal name.'
  }

  $authenticationArguments = @(
    '-S', $ServerName,
    '--authentication-method', 'ActiveDirectoryDefault'
  )
  if ($AuthenticationMethod -eq 'InteractiveEntra') {
    $authenticationArguments = @(
      '-S', $ServerName, '-G', '-U', $UserPrincipalName
    )
  }
  $authenticationArguments += @('-Q', 'SET NOCOUNT ON; SELECT CAST(1 AS int);')

  & $SqlcmdPath @authenticationArguments | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "The attended target authentication check failed with exit code $LASTEXITCODE."
  }

  New-TargetConnectionStringForApprovedAuthentication `
    -ServerName $ServerName -AuthenticationMethod $AuthenticationMethod `
    -UserPrincipalName $UserPrincipalName
}
