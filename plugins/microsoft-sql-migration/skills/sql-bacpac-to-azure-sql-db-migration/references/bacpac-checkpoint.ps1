# Copyright (c) Microsoft Corporation.
# Licensed under the MIT license.

Set-StrictMode -Version Latest

$script:BacpacCheckpointSchemaVersion = 2

function Get-CanonicalSqlServerIdentity {
  param([Parameter(Mandatory)] [string] $ServerName)

  $identity = $ServerName.Trim()
  if ([string]::IsNullOrWhiteSpace($identity)) {
    throw 'SQL Server identity cannot be empty.'
  }

  ($identity -replace '^(?i)tcp:', '').Trim().TrimEnd('.').ToLowerInvariant()
}

function Set-BacpacExportCheckpointMetadata {
  param(
    [Parameter(Mandatory)] [object] $Database,
    [Parameter(Mandatory)] [string] $SourceServerIdentity,
    [Parameter(Mandatory)] [string] $TargetServerIdentity,
    [Parameter(Mandatory)] [Guid] $RunId,
    [string] $ArtifactPath = $Database.BacpacPath
  )

  $artifact = Get-Item -LiteralPath $ArtifactPath -ErrorAction Stop
  if ($artifact.PSIsContainer -or $artifact.Length -le 0) {
    throw "Exported BACPAC is missing or empty: '$ArtifactPath'."
  }

  $Database.CheckpointSchemaVersion = $script:BacpacCheckpointSchemaVersion
  $Database.SourceServerIdentity =
    Get-CanonicalSqlServerIdentity -ServerName $SourceServerIdentity
  $Database.TargetServerIdentity =
    Get-CanonicalSqlServerIdentity -ServerName $TargetServerIdentity
  $Database.RunId = $RunId.ToString('D')
  $Database.BacpacLengthBytes = [long] $artifact.Length
  $Database.BacpacSha256 =
    (Get-FileHash -LiteralPath $artifact.FullName -Algorithm SHA256).Hash
  $Database.ExportCompletedAtUtc = [DateTime]::UtcNow
}

function Publish-BacpacArtifact {
  param(
    [Parameter(Mandatory)] [string] $TemporaryPath,
    [Parameter(Mandatory)] [string] $DestinationPath,
    [Parameter(Mandatory)] [string] $ExportRootPath,
    [int] $LockTimeoutSeconds = 30
  )

  $lockPath = Join-Path -Path $ExportRootPath -ChildPath '.bacpac-export.lock'
  $lockDeadline = [DateTime]::UtcNow.AddSeconds($LockTimeoutSeconds)
  $lockStream = $null
  while ($null -eq $lockStream) {
    try {
      $lockStream = [IO.File]::Open(
        $lockPath,
        [IO.FileMode]::OpenOrCreate,
        [IO.FileAccess]::ReadWrite,
        [IO.FileShare]::None
      )
    } catch [IO.IOException] {
      if ([DateTime]::UtcNow -ge $lockDeadline) {
        throw "Timed out waiting for the BACPAC export-root lock '$lockPath'."
      }
      Start-Sleep -Milliseconds 200
    }
  }

  try {
    [IO.File]::Move($TemporaryPath, $DestinationPath, $false)
  } finally {
    $lockStream.Dispose()
  }
}

function Get-BacpacExportResumeValidation {
  param(
    [Parameter(Mandatory)] [object] $Database,
    [Parameter(Mandatory)] [string] $SourceServerIdentity,
    [Parameter(Mandatory)] [string] $SourceDatabaseName,
    [Parameter(Mandatory)] [string] $TargetServerIdentity,
    [Parameter(Mandatory)] [string] $TargetDatabaseName,
    [Parameter(Mandatory)] [Guid] $RunId,
    [Parameter(Mandatory)] [int] $CheckpointSchemaVersion
  )

  $reasons = [System.Collections.Generic.List[string]]::new()
  $requiredProperties = @(
    'CheckpointSchemaVersion', 'SourceServerIdentity', 'SourceDatabase',
    'TargetServerIdentity', 'TargetDatabase', 'RunId', 'BacpacPath',
    'BacpacLengthBytes', 'BacpacSha256', 'ExportCompletedAtUtc'
  )
  $missingProperties = @($requiredProperties | Where-Object {
    $property = $Database.PSObject.Properties[$_]
    $null -eq $property -or $null -eq $property.Value -or
      ($property.Value -is [string] -and
        [string]::IsNullOrWhiteSpace([string] $property.Value))
  })

  $savedSchemaProperty =
    $Database.PSObject.Properties['CheckpointSchemaVersion']
  if ($CheckpointSchemaVersion -ne $script:BacpacCheckpointSchemaVersion -or
      ($savedSchemaProperty -and
        $savedSchemaProperty.Value -ne
          $script:BacpacCheckpointSchemaVersion)) {
    [void] $reasons.Add(
      "legacy schema: expected version $script:BacpacCheckpointSchemaVersion, found checkpoint version $CheckpointSchemaVersion"
    )
  }
  if ($missingProperties.Count -gt 0) {
    [void] $reasons.Add(
      "missing metadata: $($missingProperties -join ', ')"
    )
  }

  if ($missingProperties.Count -eq 0) {
    $completedAtUtc = [DateTime]::MinValue
    $completionValue = $Database.ExportCompletedAtUtc
    $validCompletionTime = if ($completionValue -is [DateTime]) {
      $completedAtUtc = [DateTime] $completionValue
      $true
    } else {
      [DateTime]::TryParse(
        [string] $completionValue,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind,
        [ref] $completedAtUtc
      )
    }
    if (-not $validCompletionTime -or
        $completedAtUtc.Kind -ne [DateTimeKind]::Utc) {
      [void] $reasons.Add('invalid export completion UTC metadata')
    }

    $expectedSource = Get-CanonicalSqlServerIdentity `
      -ServerName $SourceServerIdentity
    $expectedTarget = Get-CanonicalSqlServerIdentity `
      -ServerName $TargetServerIdentity
    if ([string] $Database.SourceServerIdentity -cne $expectedSource -or
        [string] $Database.SourceDatabase -cne $SourceDatabaseName) {
      [void] $reasons.Add('source identity mismatch')
    }
    if ([string] $Database.TargetServerIdentity -cne $expectedTarget -or
        [string] $Database.TargetDatabase -cne $TargetDatabaseName) {
      [void] $reasons.Add('target identity mismatch')
    }
    if ([string] $Database.RunId -cne $RunId.ToString('D')) {
      [void] $reasons.Add('run identity mismatch')
    }

    $storedLength = 0L
    if (-not [long]::TryParse(
        [string] $Database.BacpacLengthBytes, [ref] $storedLength)) {
      [void] $reasons.Add('invalid BACPAC length metadata')
    } elseif ($storedLength -le 0) {
      [void] $reasons.Add(
        'invalid BACPAC length metadata: expected a positive byte count'
      )
    } elseif (-not (Test-Path -LiteralPath $Database.BacpacPath `
        -PathType Leaf -ErrorAction SilentlyContinue)) {
      [void] $reasons.Add('BACPAC file is missing')
    } else {
      try {
        $artifact = Get-Item -LiteralPath $Database.BacpacPath `
          -ErrorAction Stop
      } catch {
        [void] $reasons.Add(
          "BACPAC file could not be inspected: $($_.Exception.Message)"
        )
        $artifact = $null
      }
      if ($artifact -and $storedLength -ne [long] $artifact.Length) {
        [void] $reasons.Add(
          "BACPAC length mismatch: expected $($Database.BacpacLengthBytes), found $($artifact.Length)"
        )
      } elseif ($artifact) {
        try {
          $actualHash =
            (Get-FileHash -LiteralPath $artifact.FullName -Algorithm SHA256 `
              -ErrorAction Stop).Hash
        } catch {
          [void] $reasons.Add(
            "BACPAC SHA-256 could not be computed: $($_.Exception.Message)"
          )
          $actualHash = $null
        }
        if ($actualHash -and
            [string] $Database.BacpacSha256 -cne $actualHash) {
          [void] $reasons.Add('BACPAC SHA-256 mismatch')
        }
      }
    }
  }

  [pscustomobject]@{
    IsValid = $reasons.Count -eq 0
    Reasons = @($reasons)
  }
}

# SIG # Begin signature block
# MIInRAYJKoZIhvcNAQcCoIInNTCCJzECAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCC9ypIZzHPQgoVB
# cFLEnB+0+jkejLj1BivTXPQrwPYVs6CCDLowggX1MIID3aADAgECAhMzAAACHU0Z
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
# 1cY2L4A7GTQG1h32HHAvfQESWP0xghngMIIZ3AIBATBuMFcxCzAJBgNVBAYTAlVT
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jv
# c29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIdTRnITtcPV0gAAAAAAh0w
# DQYJYIZIAWUDBAIBBQCggZAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwLwYJ
# KoZIhvcNAQkEMSIEIMEY1XBwvFkWThVgzmk1x/X4Ruw9ZKDS6W8SqQPvVZUJMEIG
# CisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8v
# d3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEAMKUwfYq57cNBb+vF
# WweWY+hJtYbipxfQwUEXGSHGfVCN6735nROOe3lmqAhg8XPHz9fYpnCLeSYAEI70
# GCS70Xe839tBxSatm0ZEdHC33zHnoZyjIUERfZ98o5bEoQlxeWQlEXNByDYjnuWW
# 7dKT6Uze4kv6O30BXPMMqpThAhlUz/63OUk+wtxx66cW3/DqYWp13jRZX8Pf9FYS
# G7cdVM7R2uK8AuDN7qy+5xOnde5RenpHDnZksJXhq2Ed++9TmOpgi3n7xxB+wzfB
# una+tHCeTDldQm5u8cIl9Tz54FAQ7P+TQEW2M2F2Y9JZT250stajxM/a1sCg2xRn
# hVSSo6GCF7AwghesBgorBgEEAYI3AwMBMYIXnDCCF5gGCSqGSIb3DQEHAqCCF4kw
# gheFAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFaBgsqhkiG9w0BCRABBKCCAUkEggFF
# MIIBQQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCCFyYmP9Lxsp/lI
# L13SQUUVVgM4dgghc9/JERAgNwemSgIGavNrjKYOGBMyMDI2MTExMzIyMTAyMS4y
# MTdaMASAAgH0oIHZpIHWMIHTMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFuZCBPcGVyYXRpb25zIExp
# bWl0ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo2RjFBLTA1RTAtRDk0NzEl
# MCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaCCEf4wggcoMIIF
# EKADAgECAhMzAAACMxBftzbaqEBSAAEAAAIzMA0GCSqGSIb3DQEBCwUAMHwxCzAJ
# BgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25k
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jv
# c29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMB4XDTI2MTAxNTE4Mzc0MFoXDTI4MDEx
# MTE4Mzc0MFowgdMxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# LTArBgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJhdGlvbnMgTGltaXRlZDEn
# MCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjZGMUEtMDVFMC1EOTQ3MSUwIwYDVQQD
# ExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNlMIICIjANBgkqhkiG9w0BAQEF
# AAOCAg8AMIICCgKCAgEAvJeYUpkXCzUl9TgLYm5Z20zo1Yt1XXD87sEzAs5mcGBr
# 6rM3uo4i5fMAfljkijJfwY3ypfnBuPX8IYS/SKq5k3q0Z2BzrVzMLMLTA81OPNgU
# /HspMj9wd/AxEuz7A0wH5vivLQWOribIaX5Efp4OFt3vS1FS2bDNL8ojhv1v+yVK
# RX0WAmcN1j1lGKl/7qgPd2fJnQJAbMVS6NjAW16l7gLJYrFET/D9glQNAt0ZoNvt
# NhWQH3TxoOvtHl3VVFZpbpdbotXMdLb031/DTXBVcVwcKE+z29ZzKul/ZQf1xyBQ
# FbvqEbsjeBplOoYwlIfnZsnExCvpza3mGK9F49UIjR4Fg98DkOAy145xkiTG/lO1
# AWcBo5k6IgniKePSeus4TROMEFDh9/TrK7Shx4PFvLQYTsN088WtIBd1nM/Ab0XW
# PlBpoKJN2tVCJs/t7L7t7r0WnHdhiqNcM7CdUAgWwrcIyRHhNfHFoR8tZmXG+D1X
# DcVD832wLqTxfhEZDZf6MOWyFM/p75pVdpUjMK6L7BRtLqmq7+3sltGgVTuCy23O
# TvKMzZ0MgzzSIQ57/XIZyyUl6VpaEBR8vjxIjVfPCgSWUISK9jNatLFHQeZJmQ0Y
# ZbEmhBNFGbcHI+lSXrTXiVJQ65U9VdpK5Q+iD4GWvzToNN3bsjiqRGZ1cn0z0gUC
# AwEAAaOCAUkwggFFMB0GA1UdDgQWBBQ03ANXWvlTdHvR/foC/vNWzgmesjAfBgNV
# HSMEGDAWgBSfpxVdAF5iXYP05dJlpxtTNRnpcjBfBgNVHR8EWDBWMFSgUqBQhk5o
# dHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBU
# aW1lLVN0YW1wJTIwUENBJTIwMjAxMCgxKS5jcmwwbAYIKwYBBQUHAQEEYDBeMFwG
# CCsGAQUFBzAChlBodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRz
# L01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNydDAMBgNV
# HRMBAf8EAjAAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMIMA4GA1UdDwEB/wQEAwIH
# gDANBgkqhkiG9w0BAQsFAAOCAgEAVBdJbvLNhLsdPPzEhg+/bkLJeRDxAcsUg/np
# uOGDq8SCzm7jXTCjm8ZTENfAxH/2guw/nrBZLOe5kLbPj3gPLgYm9k9GOsBhswMi
# 48rtl6V0gb1OOckVQQkCSQXyjyOsjIzIgpIexnufffawOeDC5t2rrMpOvx1mtqVn
# fNZIGMpygpoGh5qbF/P74uhNuaM52UEA3+VxXUf9dSUP9LgYzY4kLHrnJulkSQ6Q
# HixMa2ImGNYiGP7ftpe8k8dkvjbGzTouoljlqCqHiJmYrjPl68x9rPr3+kilKuem
# vawyLtQ6zb0WzvSKLSv6LvE8DbmuAecnbR8CjDNyeKiVqnyY7YVKh8xcKXGv20MW
# FViRNrJwD662RmKjOrrpfEi+LzTVffR7FB9ITRnflMCboRiPIm4unHv7zKGFDP2e
# 7QoW17dAy0QGGBeR40Ux/zDFU2YCRMB80OxUYEgmp6jH06dIWeR65b/wAm2yb2h0
# ka4bgSe77B5L/eZFRi2WwY7f7BFC36Hp/fXkMMo5Q8XHEDQfQtUHWY3xRD1sCiRU
# T0g9JvA9U2+tRh/UXr+rnHW91EIW2xqrEwLCnwrR6YqmH4VK4LSQJ85/mtrDzE0w
# KOhBcZCPgKSFYxYTXDIXg5q1xeE32Y8i1BYYq3GdG7uXU7tTnNE3WcLtI2idcLTd
# yBtXoZowggdxMIIFWaADAgECAhMzAAAAFcXna54Cm0mZAAAAAAAVMA0GCSqGSIb3
# DQEBCwUAMIGIMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4G
# A1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMTIw
# MAYDVQQDEylNaWNyb3NvZnQgUm9vdCBDZXJ0aWZpY2F0ZSBBdXRob3JpdHkgMjAx
# MDAeFw0yMTA5MzAxODIyMjVaFw0zMDA5MzAxODMyMjVaMHwxCzAJBgNVBAYTAlVT
# MRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQK
# ExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1l
# LVN0YW1wIFBDQSAyMDEwMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEA
# 5OGmTOe0ciELeaLL1yR5vQ7VgtP97pwHB9KpbE51yMo1V/YBf2xK4OK9uT4XYDP/
# XE/HZveVU3Fa4n5KWv64NmeFRiMMtY0Tz3cywBAY6GB9alKDRLemjkZrBxTzxXb1
# hlDcwUTIcVxRMTegCjhuje3XD9gmU3w5YQJ6xKr9cmmvHaus9ja+NSZk2pg7uhp7
# M62AW36MEBydUv626GIl3GoPz130/o5Tz9bshVZN7928jaTjkY+yOSxRnOlwaQ3K
# Ni1wjjHINSi947SHJMPgyY9+tVSP3PoFVZhtaDuaRr3tpK56KTesy+uDRedGbsoy
# 1cCGMFxPLOJiss254o2I5JasAUq7vnGpF1tnYN74kpEeHT39IM9zfUGaRnXNxF80
# 3RKJ1v2lIH1+/NmeRd+2ci/bfV+AutuqfjbsNkz2K26oElHovwUDo9Fzpk03dJQc
# NIIP8BDyt0cY7afomXw/TNuvXsLz1dhzPUNOwTM5TI4CvEJoLhDqhFFG4tG9ahha
# YQFzymeiXtcodgLiMxhy16cg8ML6EgrXY28MyTZki1ugpoMhXV8wdJGUlNi5UPkL
# iWHzNgY1GIRH29wb0f2y1BzFa/ZcUlFdEtsluq9QBXpsxREdcu+N+VLEhReTwDwV
# 2xo3xwgVGD94q0W29R6HXtqPnhZyacaue7e3PmriLq0CAwEAAaOCAd0wggHZMBIG
# CSsGAQQBgjcVAQQFAgMBAAEwIwYJKwYBBAGCNxUCBBYEFCqnUv5kxJq+gpE8RjUp
# zxD/LwTuMB0GA1UdDgQWBBSfpxVdAF5iXYP05dJlpxtTNRnpcjBcBgNVHSAEVTBT
# MFEGDCsGAQQBgjdMg30BATBBMD8GCCsGAQUFBwIBFjNodHRwOi8vd3d3Lm1pY3Jv
# c29mdC5jb20vcGtpb3BzL0RvY3MvUmVwb3NpdG9yeS5odG0wEwYDVR0lBAwwCgYI
# KwYBBQUHAwgwGQYJKwYBBAGCNxQCBAweCgBTAHUAYgBDAEEwCwYDVR0PBAQDAgGG
# MA8GA1UdEwEB/wQFMAMBAf8wHwYDVR0jBBgwFoAU1fZWy4/oolxiaNE9lJBb186a
# GMQwVgYDVR0fBE8wTTBLoEmgR4ZFaHR0cDovL2NybC5taWNyb3NvZnQuY29tL3Br
# aS9jcmwvcHJvZHVjdHMvTWljUm9vQ2VyQXV0XzIwMTAtMDYtMjMuY3JsMFoGCCsG
# AQUFBwEBBE4wTDBKBggrBgEFBQcwAoY+aHR0cDovL3d3dy5taWNyb3NvZnQuY29t
# L3BraS9jZXJ0cy9NaWNSb29DZXJBdXRfMjAxMC0wNi0yMy5jcnQwDQYJKoZIhvcN
# AQELBQADggIBAJ1VffwqreEsH2cBMSRb4Z5yS/ypb+pcFLY+TkdkeLEGk5c9MTO1
# OdfCcTY/2mRsfNB1OW27DzHkwo/7bNGhlBgi7ulmZzpTTd2YurYeeNg2LpypglYA
# A7AFvonoaeC6Ce5732pvvinLbtg/SHUB2RjebYIM9W0jVOR4U3UkV7ndn/OOPcbz
# aN9l9qRWqveVtihVJ9AkvUCgvxm2EhIRXT0n4ECWOKz3+SmJw7wXsFSFQrP8DJ6L
# GYnn8AtqgcKBGUIZUnWKNsIdw2FzLixre24/LAl4FOmRsqlb30mjdAy87JGA0j3m
# Sj5mO0+7hvoyGtmW9I/2kQH2zsZ0/fZMcm8Qq3UwxTSwethQ/gpY3UA8x1RtnWN0
# SCyxTkctwRQEcb9k+SS+c23Kjgm9swFXSVRk2XPXfx5bRAGOWhmRaw2fpCjcZxko
# JLo4S5pu+yFUa2pFEUep8beuyOiJXk+d0tBMdrVXVAmxaQFEfnyhYWxz/gq77EFm
# PWn9y8FBSX5+k77L+DvktxW/tM4+pTFRhLy/AsGConsXHRWJjXD+57XQKBqJC482
# 2rpM+Zv/Cuk0+CQ1ZyvgDbjmjJnW4SLq8CdCPSWU5nR0W2rRnj7tfqAxM328y+l7
# vzhwRNGQ8cirOoo6CGJ/2XBjU02N7oJtpQUQwXEGahC0HVUzWLOhcGbyoYIDWTCC
# AkECAQEwggEBoYHZpIHWMIHTMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFuZCBPcGVyYXRpb25zIExp
# bWl0ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo2RjFBLTA1RTAtRDk0NzEl
# MCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaIjCgEBMAcGBSsO
# AwIaAxUAWxPKLDixcu4ygj3RSJig/nteDBSggYMwgYCkfjB8MQswCQYDVQQGEwJV
# UzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UE
# ChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGlt
# ZS1TdGFtcCBQQ0EgMjAxMDANBgkqhkiG9w0BAQsFAAIFAO6h3g4wIhgPMjAyNjEx
# MTMxOTA1NTBaGA8yMDI2MTExNDE5MDU1MFowdzA9BgorBgEEAYRZCgQBMS8wLTAK
# AgUA7qHeDgIBADAKAgEAAgIwbQIB/zAHAgEAAgIUADAKAgUA7qMvjgIBADA2Bgor
# BgEEAYRZCgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQowCAIBAAID
# AYagMA0GCSqGSIb3DQEBCwUAA4IBAQAYQI90GTcFxtKuSAhhJGBjfaR1IKvdllkF
# ICekTlxPgzAZI615QX1oXmd6yINIfSBkcPkUcRVn9TKb/hQ1wLq4k5qWq9o9xF1s
# CxwJXXA05KktRTbwOj4k6dJV5l+Vt+6MtIWEKum+Q7sSY/6P3sb69p3SnxPKbqn1
# pPwZpfl9ABsaxOBKnS4GosvHkXPPC1qOamvBvnMS/UlYh8XENXqsf/+ofU/9mSBw
# +E3LxtDqmDRJG5N/6s2cpmGjDiuOltvChZmCSxv3VmsSyGQoVZXmufASrAsveONT
# 4UU623K4WSY8SysAMHFStJFeB6ga/fwa8hK3I7/9HU+5djHLpowfMYIEDTCCBAkC
# AQEwgZMwfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNV
# BAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQG
# A1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAIzEF+3Ntqo
# QFIAAQAAAjMwDQYJYIZIAWUDBAIBBQCgggFKMBoGCSqGSIb3DQEJAzENBgsqhkiG
# 9w0BCRABBDAvBgkqhkiG9w0BCQQxIgQgXAOMhu79a6a9hmXWgmVbaOqwbcLoS6pB
# Y/rSWb5FflAwgfoGCyqGSIb3DQEJEAIvMYHqMIHnMIHkMIG9BCCWue5iC0tIXWaU
# 0QT/Up3MULZUb5U9e96q40RB0g45lzCBmDCBgKR+MHwxCzAJBgNVBAYTAlVTMRMw
# EQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVN
# aWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0
# YW1wIFBDQSAyMDEwAhMzAAACMxBftzbaqEBSAAEAAAIzMCIEIDW3sWZdgP4ml/+1
# ngYFaVtmdPIyhJMkexUBeFxViGk6MA0GCSqGSIb3DQEBCwUABIICALmcCi8IXh8p
# 7sFxv8lkiHtMwN19H774dSEDpqE+UVa4QQDBIEsYxI0eJdGKdpQxDDPk9pMTBKAs
# 0eaOmk+ScY444N+t2zj1vhmzvqrJ+oY3EnkYBuISnr+TYy1T9LHH6bc/uwsWbbU0
# vWU8X6hunCrUWisrn2hDjkjLVMRJqd1r+VlQ21QlI3JehcIxO/DKhcfECDZaC4Q+
# ucIyEcp7gY/9HwTRfmciS465SMga1s/uPc05rhdjj8vyALwbpT0GX41Om744NI8Y
# gTboa9SAhWH2fZzt19sX75UU6K6IDKtArdLEO2mNCy97cQbaKDvOvCAYCm9ze1YC
# rC0fZD193I/r3d7fcjgxXa8ooLHfUg/43yThruS1UG8IC1VMo6/ZTWWwLgmtl8Rt
# dgnX9lk/R/qutNtgT7tY4iU8GWVkDaLDJ0vzNhynRAZcMfusvJYTpu8Rp6MnjZky
# fYAzd7p264CMyUCsQTDGwng7l4FGMtWceFT1yX1tEBaH7x/I+aQtq30Qxq6o2eR/
# cX2QYaE06970Sk9ype05aVmlsD42IG6aQgkuUXg4DUyX2hPBTnNJgDXlDQCXkjSe
# az/NbHIBMAJd+J5AzMRukRrQc8zXFzEoMjtpZsBaEqXyDz2lheHN1kAkkCjerd82
# 0Wb3676k9inWnquVD/bmz3oscsmqoQ7T
# SIG # End signature block
