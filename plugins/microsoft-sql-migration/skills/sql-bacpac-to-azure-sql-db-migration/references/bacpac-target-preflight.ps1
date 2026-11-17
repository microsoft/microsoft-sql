# Copyright (c) Microsoft Corporation.
# Licensed under the MIT license.

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

# SIG # Begin signature block
# MIInKwYJKoZIhvcNAQcCoIInHDCCJxgCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBwV6IEA/XraI6B
# QczmfU2gIPe9D5NHqHvXb9PUafo9VqCCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# 1cY2L4A7GTQG1h32HHAvfQESWP0xghnHMIIZwwIBATBuMFcxCzAJBgNVBAYTAlVT
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jv
# c29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIdTRnITtcPV0gAAAAAAh0w
# DQYJYIZIAWUDBAIBBQCggZAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwLwYJ
# KoZIhvcNAQkEMSIEIM5msh/oo1q3JrzxdjqZjAXyKd9hV3+xYB09E8QKQMJEMEIG
# CisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8v
# d3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEAxBiX5/twXfGVb2oL
# hXKeBgznuxjlW2zmkZZmXREj89DKfIAvH+i7/NyV8WdWqGcVZGmjNU15HNHt1dKx
# FO5tyR7EM1PjaJh1mHLZk1x+Pd7ls5n5m1wsoo2Fiv6SfMYgH7OKwgFFbdRssmse
# rR2c0zg4gITueYB5+Mn9pUiihUcPnY9e6qbl8O8t2xPWYKO1NX9YxQa+2fGQr1AE
# TdAWpI3752Ds69ISJWtkiMu7jtluLnvLeYj8X85swDRT8ROZ2LPJQdp1xlMDxEVc
# 1l7NRyErB9hhyCiq8IFpQxNJ82aP8+/dpt0dsWwvAYhA5ecbqQgm0lbU4wi9hyDi
# fiuVvaGCF5cwgheTBgorBgEEAYI3AwMBMYIXgzCCF38GCSqGSIb3DQEHAqCCF3Aw
# ghdsAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFSBgsqhkiG9w0BCRABBKCCAUEEggE9
# MIIBOQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCCHe7HedAfkepb1
# DRBsvEepnuPcEKn4yVE7Czv7MJHC+wIGavNuvHR1GBMyMDI2MTExMzIyMTAyNS4x
# MDNaMASAAgH0oIHRpIHOMIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScw
# JQYDVQQLEx5uU2hpZWxkIFRTUyBFU046RTAwMi0wNUUwLUQ5NDcxJTAjBgNVBAMT
# HE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2WgghHtMIIHIDCCBQigAwIBAgIT
# MwAAAikO1WQqtJfyGgABAAACKTANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJV
# UzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UE
# ChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGlt
# ZS1TdGFtcCBQQ0EgMjAxMDAeFw0yNjAyMTkxOTQwMDdaFw0yNzA1MTcxOTQwMDda
# MIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQL
# ExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxk
# IFRTUyBFU046RTAwMi0wNUUwLUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1l
# LVN0YW1wIFNlcnZpY2UwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQCe
# ItFq4z1oCYSmUZmpYDsbJWEu++1bbc/Mz7Pa3I0ZX5EON+WirB0FvnGlyFRUylzO
# 5TJXZfU8QFPOU95P1Y1OZ8J+quA5G+AWSBOr/48scl0s9RBpqgTMq/lbyqBz4CMm
# vVR2QevAgVp4a1hbmOm9G7YWey68N5F5rSDYV0wMlg4Iy8YRuFgRN2eBpVXt9IvF
# aFmBnQLZfo22KZ3L8PWEHUhXU5dLOSZoTfqqQ/B+deW56ACMnnHjPxZu+szHhZML
# UrMWTgs9J7Cn8DtelcKj9aM+0Zq7tkSDHCrwo6eCSfw3clktXRRrdmsccal8RCDi
# NFFgZsypwF2aGAF6kg41+Ql+thXpnOMUH4mPCAJZWp0zDWowsK/Yo5jHL1pT/Agb
# L3FoAy4cbhOI4Pb1eQFG+jT7skS2F/b+ZACUA1EDZ830K+Bu0yw+FpSGy8tpd1sz
# k3cUYjIpzIG4z3oFNmiSJN8YdNd4SHsER5Dks5bxiKbpvmfrOA39jTb7EW2TT7yS
# WgJISfvTezuLmQsTVSzNsvapVlHhE2zBqDw409nvOtitCFbnhhXNfatzb2+Gf2tX
# 2s6YBa151CC/8+emJvvegXbWNudzYt8cFRom0PZ+fJRhhBfdSqCqr8QeOGJ8VYlm
# xFXqx1SdDSkTCSgpsskGqZwh/6umA1g4L7zeGBNngQIDAQABo4IBSTCCAUUwHQYD
# VR0OBBYEFCdNRaSL9AW8QvaQ21WjRAXKN4M7MB8GA1UdIwQYMBaAFJ+nFV0AXmJd
# g/Tl0mWnG1M1GelyMF8GA1UdHwRYMFYwVKBSoFCGTmh0dHA6Ly93d3cubWljcm9z
# b2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0El
# MjAyMDEwKDEpLmNybDBsBggrBgEFBQcBAQRgMF4wXAYIKwYBBQUHMAKGUGh0dHA6
# Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwVGlt
# ZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3J0MAwGA1UdEwEB/wQCMAAwFgYDVR0l
# AQH/BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeAMA0GCSqGSIb3DQEBCwUA
# A4ICAQA9wc72lf/czDhp09T3PGAMOQhxl/x04jpE7t39FeqQSn2Up6DVzhgwnzCq
# Y3NIhLtUaWrd7NxvrhZDca+J4xzvrRQNPHeRQpnJVeHsyTu53gTBlUB1TRI6OnZt
# /AVmR9oMJ/NBOqB+d+SOb8Px6zRgRwk62sFkOkB5lig/DMnYEeR/amW9Hdo8vXcK
# maa/DbSOAHSdfZFt+iqMZfNlkEOn71/RAKTNv4Qpq/2FhcjMMmSkIhshBdBVB0Vj
# mkwFfhVUf5TTuLJ9sDR4EyCvOZJ3B6g7Iw6WjQxycjwkfzsVMTpfusJ5SwdOHL8y
# GPWZOePjwa8ISXWs6kiVK/6S0/JVb1LpxpyYKREQjnU/5OecKt2OXlHdwFWZrwAi
# 98RPZa6EExcb/LGLf10tNHju1eTlohY0jzNZQ0BDgSuMZgMU+8EEjtMQMIDnlPGE
# UON7LHXHH0KL0FA01PEWVZKrr/LUOuuDTNFzw543FPMp4gkCIFlKdRuciR1IXOk+
# Xse6rj9tJFYgVn+44BHou2XQe5RX30ef3AQWa0mxyGDqJzGsV3X5+bNQeMV88iWu
# lJPq5sgnGG9O/H1/HH4HsO9ZKGX/WrJpQmFuQrTOR49XjveaC0xaFmGsNg+RhbtD
# 5qTkn+ISDvw0IJ/E/VXNdz/yWgol6r507hT8sAMupnhkF2uw1DCCB3EwggVZoAMC
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
# cGNTTY3ugm2lBRDBcQZqELQdVTNYs6FwZvKhggNQMIICOAIBATCB+aGB0aSBzjCB
# yzELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1Jl
# ZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjElMCMGA1UECxMc
# TWljcm9zb2Z0IEFtZXJpY2EgT3BlcmF0aW9uczEnMCUGA1UECxMeblNoaWVsZCBU
# U1MgRVNOOkUwMDItMDVFMC1EOTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1T
# dGFtcCBTZXJ2aWNloiMKAQEwBwYFKw4DAhoDFQC3v9iSO22xob7ZxN5dXCEq+9Iv
# /6CBgzCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# JjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMA0GCSqGSIb3
# DQEBCwUAAgUA7qHhGTAiGA8yMDI2MTExMzE5MTg0OVoYDzIwMjYxMTE0MTkxODQ5
# WjB3MD0GCisGAQQBhFkKBAExLzAtMAoCBQDuoeEZAgEAMAoCAQACAgL4AgH/MAcC
# AQACAhJkMAoCBQDuozKZAgEAMDYGCisGAQQBhFkKBAIxKDAmMAwGCisGAQQBhFkK
# AwKgCjAIAgEAAgMHoSChCjAIAgEAAgMBhqAwDQYJKoZIhvcNAQELBQADggEBAGAF
# WkWxWomUEeuqc9aITdkeHfTk8pxTdv/k1qPFMfG/Cg0t5C01W/Y9lUpHA6wQfgj4
# lsFUOM/Ot4XIyWvKF25gfVGLjrxcXAMFT8H88EICnm7rTojM1I92j3Q9+BJryITL
# XG0vEkHMhVJundK8WTcGoiKxpmQK8d1yVVMK5Z9B2vR6+cPCy18M6F6uAu1o5mOE
# 0bEQBH/VOvR6yaIxF/DxKlIA+GeaG8+d6fTpL/Hq6kpscPqAzWC30UaAUuYlo1BK
# tA76OMr4EnEPsvOdSRlYrXgrTojIrumby4wc+bd+mqD0kD2RJtkawC7ZWMbiK3z1
# eBxhZl0AKDFRyT7uU7wxggQNMIIECQIBATCBkzB8MQswCQYDVQQGEwJVUzETMBEG
# A1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWlj
# cm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFt
# cCBQQ0EgMjAxMAITMwAAAikO1WQqtJfyGgABAAACKTANBglghkgBZQMEAgEFAKCC
# AUowGgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCAv
# UO5c6BSKpgAFanjVaG1aLb7pDolWapolJrQW4Hu0hjCB+gYLKoZIhvcNAQkQAi8x
# geowgecwgeQwgb0EILfKPfEitvD/lSvEumxqPkkeOEtgkmKFEVMuel9oOrqSMIGY
# MIGApH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNV
# BAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQG
# A1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAIpDtVkKrSX
# 8hoAAQAAAikwIgQgSx1zA5dJoEiyk9Cdr3L93Uyj0DzT5vnSNFYpqnl6AQcwDQYJ
# KoZIhvcNAQELBQAEggIALuHWB0urHxqgPXvlRJvdquNqs45XvfxKHcxNv7seR8Nb
# Lftdgx4v0ahKYIhh202wvfWmo0tYG9znpuIEvIox7HdU1ddFTxVrkG6paCCkKgKW
# Vd9JKYMqV68wSVo/7GtyC6nq7lF3cB73Rlh83guNEryYEZqE2sJ8NTrUFe6mg2rD
# 9/kIF0iL4S6m7bfHXCBf5ShW+rd0qA/AdGo1bEoPZDTbRm1nKdll8dHgogruQEAq
# zTJzve0WvU8+V1NBOpT5kJ2F2AR9gSAgBshG3rT74mSMl0Ut5vWy7DmCdGpTKQgT
# +wchTesHUL+xM6gnpOtF3niJgL0YMvqr9r0tvbur5rUC87VPuQAMp1kKhMZISgil
# w3Ul6N74t82RuwCLygoh7U6ylQ5Z3mhMLMd6/PhhExBHfIszyPKjZwf2WMMLXIw7
# DatzxdS30DvEINuH28eail1MupjEx4cHbXcL1+hlW6YcvKAzhtJhf7IQihLvjfgm
# c34NcLHMczPIGhHmxldldOdUOMIdFUSAdj2q2V0R60E+9ZnA8zL+g4SSBBWutGeH
# SHhSYavRTwQyqIsIERzvcjOBiW8Dk9rQMjudNqqCOHY0eE5nvJpgaR9do06makN/
# OC2kUQSg7NlTYWfvK8FdzSAvOZ4gWIRx6AWh9AsX6v6S2G+CPmp4dZXbQk44Sqg=
# SIG # End signature block
