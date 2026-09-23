# Command-Based Azure Migration Assessment API Execution

## Contents

- [Inputs](#inputs)
- [Execution Rules](#execution-rules)
- [Step 1: Trigger and Monitor Assessment](#step-1-trigger-and-monitor-assessment)
- [Step 2: Retrieve and Poll Telemetry](#step-2-retrieve-and-poll-telemetry)
- [Step 3: Decode Portal Telemetry Reports](#step-3-decode-portal-telemetry-reports)
- [Artifacts](#artifacts)
- [Cleanup](#cleanup)


## Inputs

Initialize these values in each terminal call:

```powershell
$ASSESSMENT_API = "2024-05-01-preview"
$JOBS_API = "2025-09-01-preview"
$JOB_POLL_MAX_ATTEMPTS = 5
$JOB_POLL_INTERVAL_SECONDS = 30
$BASE = "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.AzureArcData/SqlServerInstances/$INSTANCE"
```

Step 1 creates a unique assessment run directory. Retain the exact path shown by that command and use it as `{ASSESSMENT_RUN_DIRECTORY}` in Steps 2, 3, and Cleanup.

## Execution Rules

- Execute each block with PowerShell 7 (`pwsh`) as one terminal command.
- Execute without `.ps1` wrapper or fallback scripts.
- Acquire the short-lived ARM token through Azure CLI and keep it in memory.
- Never print, echo, log, or persist the token.
- Execute `curl` without `--verbose`, `--trace`, or shell tracing.
- Pipe JSON request bodies to `curl` through standard input.
- Poll the signed telemetry URL unchanged with `Invoke-RestMethod` and a
  short-lived ARM token.

## Step 1: Trigger and Monitor Assessment

### Trigger Assessment API Contract

- **Method:** `POST`
- **Endpoint:** `{BASE}/runMigrationAssessment`
- **API version variable:** `$ASSESSMENT_API`
- **Request body:** None
- **Content length:** `0`
- **Response:** HTTP 2xx when accepted or HTTP 409 when an assessment is already
  running

### Monitor Job API Contract

- **Method:** `POST`
- **Endpoint:** `{BASE}/getJobsStatus`
- **API version variable:** `$JOBS_API`
- **Request body:** `{"featureName":"MigrationAssessment"}`
- **Response:** Current `MigrationJobOnDemand` state and execution timestamps

### Trigger and Monitor Execution

Run all configured status attempts without returning to the user between
attempts.

```powershell
$runDirectory = Join-Path $env:TEMP (
  "migration-assessment-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $runDirectory -ErrorAction Stop | Out-Null
$triggerTimePath = Join-Path $runDirectory "trigger-time.txt"
$triggerRequestedAt = [DateTimeOffset]::UtcNow
$triggerRequestedAt.ToString("o") | Set-Content $triggerTimePath
Write-Host "Assessment run directory: $runDirectory"
$assessmentJobStatus = $null
$freshJobSucceeded = $false

$armToken = az account get-access-token --resource "https://management.azure.com/" --query accessToken -o tsv
if ($LASTEXITCODE -ne 0 -or -not $armToken) { throw "Unable to acquire an ARM access token." }

try {
  $triggerLines = @(
    curl --silent --show-error `
      --request POST `
      --url "${BASE}/runMigrationAssessment?api-version=${ASSESSMENT_API}" `
      --header "Authorization: Bearer $armToken" `
      --header "Content-Length: 0" `
      --write-out "`n%{http_code}"
  )
  if ($LASTEXITCODE -ne 0) { throw "Unable to trigger migration assessment." }

  $httpStatus = [int]$triggerLines[-1]
  if (($httpStatus -lt 200 -or $httpStatus -ge 300) -and $httpStatus -ne 409) {
    throw "Migration assessment trigger returned HTTP $httpStatus."
  }
  if ($httpStatus -eq 409) {
    Write-Host "Assessment is already running; continuing to job monitoring."
  }

  for ($i = 1; $i -le $JOB_POLL_MAX_ATTEMPTS; $i++) {
    Start-Sleep $JOB_POLL_INTERVAL_SECONDS
    $jobsLines = @(
      '{"featureName":"MigrationAssessment"}' |
        curl --silent --show-error --fail-with-body `
          --request POST `
          --url "${BASE}/getJobsStatus?api-version=${JOBS_API}" `
          --header "Authorization: Bearer $armToken" `
          --header "Content-Type: application/json" `
          --data-binary "@-"
    )
    if ($LASTEXITCODE -ne 0) { throw "Unable to read migration assessment job status." }
    $jobsResponse = ($jobsLines -join [Environment]::NewLine) | ConvertFrom-Json
    $job = $jobsResponse.jobsStatus | Where-Object { $_.id -match "MigrationJobOnDemand" } | Select-Object -First 1

    if (-not $job) {
      Write-Host "Assessment status $i/${JOB_POLL_MAX_ATTEMPTS}: waiting for MigrationJobOnDemand"
      continue
    }
    $assessmentJobStatus = $job.jobStatus
    Write-Host "Assessment status $i/${JOB_POLL_MAX_ATTEMPTS}: $assessmentJobStatus"

    if ($assessmentJobStatus -eq "Succeeded") {
      $lastExecutionTime = $job.backgroundJob.lastExecutionTime
      if ($lastExecutionTime -and
          ([DateTimeOffset]$lastExecutionTime).UtcDateTime -gt $triggerRequestedAt.UtcDateTime) {
        $freshJobSucceeded = $true
        break
      }
      Write-Host "Assessment status $i/${JOB_POLL_MAX_ATTEMPTS}: waiting for the triggered execution"
      continue
    }
    if ($assessmentJobStatus -eq "Failed") {
      $failureDetail = if ($job.jobException) {
        [string]$job.jobException
      } else {
        "The assessment job returned no failure details."
      }
      throw "Assessment failed: $failureDetail"
    }
  }
} finally {
  $armToken = $null
}

if (-not $freshJobSucceeded) {
  throw "Assessment is still running. Latest status: $assessmentJobStatus"
}
```

### Trigger and Monitor Output

- The unique assessment run directory path to retain for the remaining steps.
- `trigger-time.txt` in that directory containing the UTC freshness baseline

## Step 2: Retrieve and Poll Telemetry

Call `getTelemetry` through `curl`. Capture its operation header and poll
the returned signed URL unchanged with the same short-lived ARM token.

### Retrieve Telemetry API Contract

- **Method:** `POST`
- **Endpoint:** `{BASE}/getTelemetry`
- **API version variable:** `$ASSESSMENT_API`
- **Request body:** `{"datasetName":"MigrationAssessments"}`
- **Response:** `Azure-AsyncOperation` URL for report retrieval

### Poll Telemetry API Contract

- **Method:** `GET`
- **Endpoint:** `Azure-AsyncOperation` URL returned by `getTelemetry`
- **API version:** Included in the returned operation URL
- **Request body:** None
- **Response:** Retrieval status and telemetry rows when status reaches
  `Succeeded`

### Telemetry Execution

```powershell
$runDirectory = "{ASSESSMENT_RUN_DIRECTORY}"
if (-not (Test-Path -LiteralPath $runDirectory -PathType Container)) {
  throw "Assessment run directory not found: $runDirectory"
}
$lroResponsePath = Join-Path $runDirectory "telemetry-lro.json"

$armToken = az account get-access-token --resource "https://management.azure.com/" --query accessToken -o tsv
if ($LASTEXITCODE -ne 0 -or -not $armToken) { throw "Unable to acquire an ARM access token." }

try {
  $telemetryOutput = @(
    '{"datasetName":"MigrationAssessments"}' |
      curl --silent --show-error --fail-with-body --include `
        --request POST `
        --url "${BASE}/getTelemetry?api-version=${ASSESSMENT_API}" `
        --header "Authorization: Bearer $armToken" `
        --header "Content-Type: application/json" `
        --data-binary "@-"
  )
  if ($LASTEXITCODE -ne 0) { throw "Unable to start telemetry retrieval." }
  $telemetryText = $telemetryOutput -join [Environment]::NewLine
  $operationMatch = [regex]::Match($telemetryText, "(?i)Azure-AsyncOperation:\s*(\S+)")
  if (-not $operationMatch.Success) { throw "getTelemetry did not return an Azure-AsyncOperation URL." }
  $telemetryOperationUrl = $operationMatch.Groups[1].Value
  $telemetryOutput = $null
  $telemetryText = $null
  $headers = @{ Authorization = "Bearer $armToken" }
  for ($i = 1; $i -le 10; $i++) {
    Start-Sleep 2
    $response = Invoke-RestMethod -Method GET -Uri $telemetryOperationUrl -Headers $headers
    [IO.File]::WriteAllText($lroResponsePath, ($response | ConvertTo-Json -Depth 100), (New-Object Text.UTF8Encoding($false)))
    $status = $response.status
    Write-Host "Telemetry status $i/10: $status"
    if ($status -eq "Succeeded") { break }
    if ($status -in @("Failed", "Canceled")) { throw "getTelemetry operation ended with status $status." }
  }
} finally {
  $armToken = $null
  $headers = $null
  $telemetryOperationUrl = $null
}

if ($status -ne "Succeeded") { throw "getTelemetry operation did not complete after 10 attempts." }
```

### Telemetry Output

- `telemetry-lro.json` in the assessment run directory containing the completed telemetry response

## Step 3: Decode Portal Telemetry Reports

### Decode Reports Execution

```powershell
$runDirectory = "{ASSESSMENT_RUN_DIRECTORY}"
if (-not (Test-Path -LiteralPath $runDirectory -PathType Container)) {
  throw "Assessment run directory not found: $runDirectory"
}
$lroResponsePath = Join-Path $runDirectory "telemetry-lro.json"
$suitabilityPath = Join-Path $runDirectory "suitability.json"
$skuVmPath = Join-Path $runDirectory "sku-vm.json"
$skuMiPath = Join-Path $runDirectory "sku-mi.json"
$skuDbPath = Join-Path $runDirectory "sku-db.json"
$triggerTimePath = Join-Path $runDirectory "trigger-time.txt"
$resp = Get-Content $lroResponsePath -Raw | ConvertFrom-Json

$columnIndex = @{}
for ($i = 0; $i -lt $resp.properties.columns.Count; $i++) {
  $columnIndex[[string]$resp.properties.columns[$i].name] = $i
}
if (-not $columnIndex.ContainsKey("Type") -or -not $columnIndex.ContainsKey("ObservedTimestampUTC")) {
  throw "Telemetry response is missing Type or ObservedTimestampUTC columns."
}

$bodyColumnName = if ($columnIndex.ContainsKey("CompressedBody")) { "CompressedBody" } else { "Body" }
if (-not $columnIndex.ContainsKey($bodyColumnName)) {
  throw "Telemetry response is missing Body and CompressedBody columns."
}

$typeIndex = $columnIndex["Type"]
$bodyIndex = $columnIndex[$bodyColumnName]
$timestampIndex = $columnIndex["ObservedTimestampUTC"]
$compressedAtResourceProvider = $bodyColumnName -eq "CompressedBody"

function Expand-GzipBase64String {
  param([Parameter(Mandatory = $true)][string]$Value)

  $bytes = [Convert]::FromBase64String(($Value -replace "\s", ""))
  $memoryStream = New-Object IO.MemoryStream(,$bytes)
  $gzipStream = New-Object IO.Compression.GZipStream($memoryStream, [IO.Compression.CompressionMode]::Decompress)
  $reader = New-Object IO.StreamReader($gzipStream)
  try {
    return $reader.ReadToEnd()
  } finally {
    $reader.Dispose()
    $gzipStream.Dispose()
    $memoryStream.Dispose()
  }
}

function Convert-TelemetryReport {
  param(
    [Parameter(Mandatory = $true)]$Row,
    [Parameter(Mandatory = $true)][string]$ReportType,
    [Parameter(Mandatory = $true)][bool]$CompressedAtResourceProvider,
    [Parameter(Mandatory = $true)][bool]$CompressedAtExtension
  )

  try {
    $reportJson = [string]$Row[$bodyIndex]
    if ($CompressedAtResourceProvider) {
      $reportJson = Expand-GzipBase64String $reportJson
    }
    if ($CompressedAtExtension) {
      $reportJson = Expand-GzipBase64String $reportJson
    }
    return $reportJson -replace "\bNaN\b", "null" | ConvertFrom-Json
  } catch {
    Write-Warning "Unable to parse telemetry report type $ReportType`: $($_.Exception.Message)"
    return $null
  }
}

function Get-LatestTelemetryReport {
  param([Parameter(Mandatory = $true)][string]$BaseType)

  $v1Row = $resp.properties.rows | Where-Object { $_[$typeIndex] -eq $BaseType } | Select-Object -First 1
  $v2Type = "${BaseType}_V2"
  $v2Row = $resp.properties.rows | Where-Object { $_[$typeIndex] -eq $v2Type } | Select-Object -First 1
  $v1Report = if ($v1Row) {
    Convert-TelemetryReport $v1Row $BaseType $compressedAtResourceProvider $false
  } else { $null }
  $v2Report = if ($v2Row) {
    Convert-TelemetryReport $v2Row $v2Type $compressedAtResourceProvider $true
  } else { $null }

  if ($v1Report -and $v2Report) {
    $v1Observed = $v1Row[$timestampIndex]
    $v2Observed = $v2Row[$timestampIndex]
    if ($v1Observed -and $v2Observed -and
        ([DateTimeOffset]$v2Observed).UtcDateTime -gt ([DateTimeOffset]$v1Observed).UtcDateTime) {
      return [PSCustomObject]@{ Report = $v2Report; Type = $v2Type; ObservedTimestampUTC = $v2Observed }
    }
    return [PSCustomObject]@{ Report = $v1Report; Type = $BaseType; ObservedTimestampUTC = $v1Observed }
  }
  if ($v2Report) {
    return [PSCustomObject]@{ Report = $v2Report; Type = $v2Type; ObservedTimestampUTC = $v2Row[$timestampIndex] }
  }
  if ($v1Report) {
    return [PSCustomObject]@{ Report = $v1Report; Type = $BaseType; ObservedTimestampUTC = $v1Row[$timestampIndex] }
  }
  return $null
}

$suitabilitySelection = Get-LatestTelemetryReport "Suitability"
$skuVmSelection = Get-LatestTelemetryReport "SKURecommendation_AzureSQLVM"
$skuMiSelection = Get-LatestTelemetryReport "SKURecommendation_AzureSQLMI"
$skuDbSelection = Get-LatestTelemetryReport "SKURecommendation_AzureSQLDB"

if (-not $suitabilitySelection) {
  throw "Telemetry response does not contain a valid Suitability or Suitability_V2 report."
}

$suitability = $suitabilitySelection.Report
$suitabilityJson = $suitability | ConvertTo-Json -Depth 100
[IO.File]::WriteAllText($suitabilityPath, $suitabilityJson, (New-Object Text.UTF8Encoding($false)))

$skuSelections = @(
  [PSCustomObject]@{ Platform = "Azure SQL VM"; Selection = $skuVmSelection; Path = $skuVmPath },
  [PSCustomObject]@{ Platform = "Azure SQL MI"; Selection = $skuMiSelection; Path = $skuMiPath },
  [PSCustomObject]@{ Platform = "Azure SQL DB"; Selection = $skuDbSelection; Path = $skuDbPath }
)
foreach ($item in $skuSelections) {
  if ($item.Selection) {
    $json = $item.Selection.Report | ConvertTo-Json -Depth 100
    [IO.File]::WriteAllText($item.Path, $json, (New-Object Text.UTF8Encoding($false)))
    Write-Host "Selected $($item.Platform) report: $($item.Selection.Type) (ObservedTimestampUTC: $($item.Selection.ObservedTimestampUTC))"
  } else {
    Write-Warning "No valid $($item.Platform) SKU telemetry report is available."
  }
}

$triggerRequestedAt = [DateTimeOffset](Get-Content $triggerTimePath -Raw)
$endedOn = [DateTimeOffset]$suitability.EndedOn

if ($endedOn.UtcDateTime -le $triggerRequestedAt.UtcDateTime) {
  throw "Telemetry is stale. Repeat job monitoring, telemetry retrieval, and decoding."
}

$staleSkuTypes = @(
  $skuSelections |
  Where-Object {
    $_.Selection -and (
      -not $_.Selection.ObservedTimestampUTC -or
      ([DateTimeOffset]$_.Selection.ObservedTimestampUTC).UtcDateTime -le $triggerRequestedAt.UtcDateTime
    )
  } |
  ForEach-Object { $_.Selection.Type }
)
if ($staleSkuTypes.Count -gt 0) {
  throw "SKU telemetry is stale for: $($staleSkuTypes -join ', '). Repeat job monitoring, telemetry retrieval, and decoding."
}

Write-Host "Selected readiness report: $($suitabilitySelection.Type) (ObservedTimestampUTC: $($suitabilitySelection.ObservedTimestampUTC))"
Write-Host "Fresh Suitability EndedOn (UTC): $($endedOn.UtcDateTime.ToString('o'))"
```

### Decode Reports Output

- `suitability.json`
- `sku-vm.json`
- `sku-mi.json`
- `sku-db.json`

## Artifacts

All files are isolated in the unique assessment run directory.

| File | Contents |
|---|---|
| `trigger-time.txt` | UTC assessment trigger request time |
| `telemetry-lro.json` | Completed telemetry retrieval response |
| `suitability.json` | Selected fresh Suitability report |
| `sku-vm.json` | Selected Azure SQL VM SKU report |
| `sku-mi.json` | Selected Azure SQL MI SKU report |
| `sku-db.json` | Selected Azure SQL DB SKU report |

## Cleanup

After rendering the result, remove the temporary execution files:

```powershell
$runDirectory = "{ASSESSMENT_RUN_DIRECTORY}"
@(
  "trigger-time.txt",
  "telemetry-lro.json",
  "suitability.json",
  "sku-vm.json",
  "sku-mi.json",
  "sku-db.json"
) | ForEach-Object {
  Remove-Item -LiteralPath (Join-Path $runDirectory $_) -Force `
    -ErrorAction SilentlyContinue
}
Remove-Item -LiteralPath $runDirectory -Force -ErrorAction SilentlyContinue
```
