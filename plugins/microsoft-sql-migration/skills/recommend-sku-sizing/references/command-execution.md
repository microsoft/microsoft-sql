# SKU Recommendation Command Execution

## Inputs

- One of:
  - `$connectionString`: SQL Server connection string resolved locally using
    [local server connection](local-server-connection.md)
  - `$configFilePath`: User-provided assessment config file path
- `$OUTPUT_FOLDER`: Confirmed per-instance output folder
- `{duration}`, `{perfQueryInterval}`, and `{numberOfIteration}`: Selected
  collection settings

Before execution, verify:

```text
numberOfIteration = min(20, floor(duration / perfQueryInterval))
numberOfIteration >= 2
duration >= perfQueryInterval * numberOfIteration
```

The collector writes an instance-prefixed file whose name ends in
`_PerformanceAggregated_Counters.csv` only after a complete persistence cycle.
For example, use 10 iterations with a 30-second interval for a 300-second
collection; using 20 iterations would require at least 600 seconds.

## Step 1: Find Existing Results

**Windows (PowerShell):**

```powershell
Get-ChildItem "$OUTPUT_FOLDER\*SKU*.json", "$OUTPUT_FOLDER\*SKU*.html" -Recurse -ErrorAction SilentlyContinue |
  Sort-Object LastWriteTime -Descending |
  Select-Object Name, LastWriteTime, FullName
```

## Step 2: Collect Performance Data and Generate SKU

Run the exact detached wrapper command below. Keep the
`Start-Sleep | az datamigration ...` pipe and run SKU generation only after
successful collection. Never put a connection string in `$workerCommand`,
`Start-Process -ArgumentList`, or an `az` command line. When a connection string
is used, place it in a uniquely named temporary performance config under the
current user's `%TEMP%` and pass only that file's path to the detached worker.

**Windows:**

```powershell
New-Item -ItemType Directory -Force $OUTPUT_FOLDER | Out-Null
$runId = [Guid]::NewGuid().ToString('N')
$runStartedUtc = [DateTime]::UtcNow
$runOutputFolder = Join-Path $OUTPUT_FOLDER ("run-" + $runId)
New-Item -ItemType Directory -Force $runOutputFolder | Out-Null
$stdoutLog = Join-Path $runOutputFolder 'perf-sku-output.log'
$stderrLog = Join-Path $runOutputFolder 'perf-sku-error.log'
$runFile = Join-Path $runOutputFolder 'perf-sku-run.json'

if ($configFilePath) {
  $performanceConfig = Get-Content -LiteralPath $configFilePath -Raw |
    ConvertFrom-Json
  $performanceConfig | Add-Member -NotePropertyName action `
    -NotePropertyValue 'PerfDataCollection' -Force
  $performanceConfig | Add-Member -NotePropertyName outputFolder `
    -NotePropertyValue $runOutputFolder -Force
} else {
  $performanceConfig = @{
    action = 'PerfDataCollection'
    outputFolder = $runOutputFolder
    perfQueryIntervalInSec = {perfQueryInterval}
    staticQueryIntervalInSec = 60
    numberOfIterations = {numberOfIteration}
    sqlConnectionStrings = @($connectionString)
  }
}

$performanceConfigPath = Join-Path ([IO.Path]::GetTempPath()) (
  'sql-migration-performance-' + $runId + '.json')
$performanceConfig | ConvertTo-Json -Depth 10 |
  Set-Content -LiteralPath $performanceConfigPath -Encoding utf8

$escapedPerformanceConfigPath = $performanceConfigPath -replace "'", "''"
$escapedRunOutputFolder = $runOutputFolder -replace "'", "''"
$workerCommand = @"
try {
  Start-Sleep -Seconds {duration+30} | az datamigration performance-data-collection --config-file-path '$escapedPerformanceConfigPath' --time {duration}
  if (`$LASTEXITCODE -ne 0) { exit `$LASTEXITCODE }
  az datamigration get-sku-recommendation --output-folder '$escapedRunOutputFolder' --target-platform Any --display-result
  exit `$LASTEXITCODE
}
finally {
  Remove-Item -LiteralPath '$escapedPerformanceConfigPath' -Force -ErrorAction SilentlyContinue
}
"@
$worker = Start-Process pwsh -WindowStyle Hidden -PassThru `
  -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog `
  -ArgumentList "-NoProfile","-Command",$workerCommand
@{
  runId = $runId
  startedUtc = $runStartedUtc.ToString('O')
  workerPid = $worker.Id
  outputFolder = $runOutputFolder
} | ConvertTo-Json | Set-Content -LiteralPath $runFile -Encoding utf8
Write-Host "Performance collection output folder: $runOutputFolder"
```

The generated performance config exists only for the detached collection. It
is created under the current user's `%TEMP%` and deleted whether collection or
SKU generation succeeds or fails. Never print it or delete a user-provided
config. SKU generation reads the isolated run output folder and does not
require credentials.

## Step 3: Check Completion

When the user returns or asks for results, check the worker, required
time-series file, and SKU report.

**Windows (PowerShell):**

```powershell
$runOutputFolder = "{RUN_OUTPUT_FOLDER}"
$runFile = Join-Path $runOutputFolder 'perf-sku-run.json'
$run = if (Test-Path $runFile) { Get-Content $runFile -Raw | ConvertFrom-Json }
$runStartedUtc = if ($run) { [DateTime]::Parse($run.startedUtc).ToUniversalTime() }
$worker = if ($run) { Get-Process -Id ([int]$run.workerPid) -ErrorAction SilentlyContinue }
$counterFile = if ($run) {
  Get-ChildItem -LiteralPath $run.outputFolder -Filter '*_PerformanceAggregated_Counters.csv' -ErrorAction SilentlyContinue |
    Where-Object LastWriteTimeUtc -ge $runStartedUtc
}
$skuReport = if ($run) {
  Get-ChildItem "$($run.outputFolder)\*SKU*.json", "$($run.outputFolder)\*SKU*.html" -ErrorAction SilentlyContinue |
    Where-Object LastWriteTimeUtc -ge $runStartedUtc |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
}

if ($skuReport -and $counterFile) {
  $skuReport | Select-Object Name, LastWriteTime, FullName
} elseif ($worker) {
  Write-Host "Performance collection is still running."
} elseif (-not $run) {
  Write-Host "No tracked performance collection was found for this output folder."
} else {
  Write-Host "Performance collection stopped before SKU generation. Review $($run.outputFolder)\perf-sku-error.log."
}
```
