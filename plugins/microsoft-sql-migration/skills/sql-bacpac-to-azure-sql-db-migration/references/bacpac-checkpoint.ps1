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
