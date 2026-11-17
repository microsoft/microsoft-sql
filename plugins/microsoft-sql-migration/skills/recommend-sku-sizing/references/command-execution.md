# SKU Recommendation Command Execution

## Inputs and Optional Readiness

- `$instanceName`, `$OUTPUT_FOLDER`: selected local instance and confirmed output folder
- `$sizingCriterion`: `ConfigBased` or `PerformanceBased`, resolved from an explicit user preference or an answered sizing picker
- `$SqlAssessmentPath`: compatible native executable
- `$readinessJsonPath`: optional existing matching native readiness JSON; leave empty for sizing-only requests
- `$configFilePath` or `$connectionString`: resolved locally for configuration-based sizing
- `$performanceDataPath`: optional explicitly supplied completed performance data
- `$duration`: explicitly selected collection duration in seconds, only for new collection
- `$perfQueryInterval`: collection sampling interval (30 seconds by default for new collection)

For existing performance data, recover the original sampling interval from its
recorded collection settings or ask for it; do not assume an interval or ask for
a new collection duration.

For a direct request without a sizing preference, show the sizing picker and
wait before executing these blocks. Set `ConfigBased` only after the user selects
it or accepts/submits the picker default, not because the request omitted a mode.

If the compatible tool is missing, run only
[native-tool preparation](native-tool.md).
Do not invoke the readiness assessment or run `Assess` for a direct sizing request.
Use readiness only when matching results are already available. Without readiness,
return validated SKU results without requiring or linking an HTML report: the
combined-report API requires a suitability report.

Inspect each tool result before the next step. Let PowerShell surface command,
file and JSON errors directly; retain explicit checks for native failures,
background-worker sequencing and completed-report validity.

## Step 1: Find Existing Results

Read `sku-complete.json` in the selected per-instance output folder's run
directories. Reuse only a completed manifest whose `instance` and
`sizingCriterion` match the selected request. Its three SKU files must still
exist and match the manifest's instance and each other's database inventory,
as well as the readiness JSON when one is available.
Do not treat arbitrary `*SKU*.html`, counter files, or a worker PID as success.
Refresh only when explicitly requested.

## Step 2: Prepare an Isolated Run

```powershell
$ErrorActionPreference = 'Stop'
if ($sizingCriterion -notin @('ConfigBased', 'PerformanceBased')) {
  throw "A sizing selection is required. Show the sizing picker and wait for its response."
}
if ($sizingCriterion -eq 'ConfigBased' -and $performanceDataPath) {
  throw "Performance data cannot be silently ignored in a configuration-based request."
}
$recordedInstance = [string]$instanceName
if ($readinessJsonPath) {
  $readiness = Get-Content -LiteralPath $readinessJsonPath -Raw | ConvertFrom-Json -ErrorAction Stop
  if ($null -eq $readiness.Servers -or @($readiness.Servers).Count -ne 1 -or
      -not $readiness.Servers[0].Properties.ServerName) {
    throw "Readiness must identify exactly one assessed instance."
  }
  $recordedInstance = [string]$readiness.Servers[0].Properties.ServerName
}
if (-not $recordedInstance) { throw "A selected SQL instance is required." }
$runId = [Guid]::NewGuid().ToString('N')
$runStartedUtc = [DateTime]::UtcNow
$runOutputFolder = Join-Path $OUTPUT_FOLDER ('run-' + $runId)
[void][IO.Directory]::CreateDirectory($runOutputFolder)
if ($readinessJsonPath) {
  Copy-Item -LiteralPath $readinessJsonPath -Destination $runOutputFolder -ErrorAction Stop
}
```

For explicitly supplied completed performance data, require the exact canonical
instance's nonempty aggregated counter CSV, reject filesystem links, then copy
only that instance's CSVs and `Common_*.csv` into this isolated run folder. Invalid
input must fail without collection or configuration-based fallback.

```powershell
if ($performanceDataPath) {
  $files = @(Get-ChildItem -LiteralPath $performanceDataPath -File -ErrorAction Stop)
  $prefix = $recordedInstance.Replace('\', '_')
  $counters = @($files | Where-Object Name -IEQ ($prefix + '_PerformanceAggregated_Counters.csv'))
  if ($counters.Count -ne 1 -or
      ($counters[0].Attributes -band [IO.FileAttributes]::ReparsePoint) -or
      -not (Import-Csv -LiteralPath $counters[0].FullName -ErrorAction Stop | Select-Object -First 1)) {
    throw "Completed regular instance-specific aggregated counters with performance samples are required."
  }
  foreach ($file in $files | Where-Object {
    $_.Extension -ieq '.csv' -and (
      $_.Name.StartsWith($prefix + '_', [StringComparison]::OrdinalIgnoreCase) -or
      $_.Name.StartsWith('Common_', [StringComparison]::OrdinalIgnoreCase))
  }) {
    if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) {
      throw "Performance inputs must not be filesystem links."
    }
    Copy-Item -LiteralPath $file.FullName -Destination $runOutputFolder -ErrorAction Stop
  }
}
```

## Step 3: Size All Targets and Generate the Native Combined Report

Execute this literal block in the PowerShell tool session, not by extracting
Markdown at runtime. It is also the body used by the detached worker below.
For reuse, set `$existingSkuPaths` to the matching manifest's three files; otherwise
leave it empty. Never put credentials into the worker command or logs.

```powershell
$generateRecommendations = {
  param(
    $tool, $folder,
    [ValidateSet('ConfigBased', 'PerformanceBased')]$criterion,
    $sourceConfig, $connection, $interval, $existingSkuPaths, $sourceInstance
  )
  $ErrorActionPreference = 'Stop'
  $readinessFiles = @(Get-ChildItem -LiteralPath $folder -File -Filter 'SqlAssessment-*.json')
  if ($readinessFiles.Count -gt 1) { throw "At most one native readiness JSON is allowed." }
  $readinessPath = $null
  $instance = $null
  $expectedDatabases = $null
  if ($readinessFiles.Count -eq 1) {
    $readinessPath = $readinessFiles[0].FullName
    $readiness = Get-Content -LiteralPath $readinessPath -Raw | ConvertFrom-Json
    if ($null -eq $readiness.Servers -or @($readiness.Servers).Count -ne 1 -or
        -not $readiness.Servers[0].Properties.ServerName) {
      throw "Readiness must identify exactly one assessed instance."
    }
    $instance = [string]$readiness.Servers[0].Properties.ServerName
    $expectedDatabases = @($readiness.Servers[0].Databases | ForEach-Object { [string]$_.Properties.Name } | Sort-Object)
  } elseif ($existingSkuPaths) {
    if (-not $sourceInstance) { throw "The matching manifest's instance is required for SKU reuse." }
    $instance = $sourceInstance
  }
  $sizingInstance = if ($instance) { $instance } else { $sourceInstance }
  if ($criterion -eq 'PerformanceBased' -and -not $existingSkuPaths -and -not $sizingInstance) {
    throw "Performance-based sizing requires the selected instance from the collection settings."
  }
  if ($criterion -eq 'PerformanceBased' -and -not $existingSkuPaths -and $interval -le 0) {
    throw "Performance-based sizing requires the original positive sampling interval."
  }
  $privateConfig = Join-Path ([IO.Path]::GetTempPath()) (
    'sql-migration-sizing-' + [Guid]::NewGuid().ToString('N') + '.json')
  $skuPaths = @()
  try {
    if ($existingSkuPaths) {
      foreach ($path in $existingSkuPaths) { Copy-Item -LiteralPath $path -Destination $folder }
    } elseif ($criterion -eq 'ConfigBased') {
      $configuration = if ($sourceConfig) {
        Get-Content -LiteralPath $sourceConfig -Raw | ConvertFrom-Json -AsHashtable
      } else {
        @{ sqlConnectionStrings = @($connection) }
      }
      if (@($configuration.sqlConnectionStrings).Count -ne 1) {
        throw "One locally resolved SQL connection is required for configuration-based sizing."
      }
      New-Item -ItemType File -Path $privateConfig | Out-Null
      $identity = [Security.Principal.WindowsIdentity]::GetCurrent().User
      $acl = Get-Acl -LiteralPath $privateConfig
      $acl.SetAccessRuleProtection($true, $false)
      $acl.SetAccessRule([Security.AccessControl.FileSystemAccessRule]::new($identity, 'FullControl', 'Allow'))
      Set-Acl -LiteralPath $privateConfig -AclObject $acl
    }
    foreach ($target in @('AzureSqlDatabase', 'AzureSqlManagedInstance', 'AzureSqlVirtualMachine')) {
      if (-not $existingSkuPaths) {
        if ($criterion -eq 'ConfigBased') {
          $sizing = @{
            action = 'GetSkuRecommendation'
            sizingCriterion = 'ConfigBased'
            targetPlatform = $target
            sqlConnectionStrings = @($configuration.sqlConnectionStrings)
            outputFolder = $folder
            overwrite = $false
          }
          $sizing | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $privateConfig -Encoding utf8
          $nativeOutput = & $tool LoadFromJson --configFile $privateConfig 2>&1
        } else {
          $nativeOutput = & $tool GetSkuRecommendation --sizingCriterion PerformanceBased `
            --targetPlatform $target --targetSqlInstance $sizingInstance --outputFolder $folder `
            --perfQueryIntervalInSec $interval --overwrite false 2>&1
        }
        if ($LASTEXITCODE -ne 0) {
          throw "Native sizing failed for $target (exit $LASTEXITCODE)."
        }
      }
      $matching = @()
      $matchedServer = $null
      foreach ($file in Get-ChildItem -LiteralPath $folder -File -Filter 'SkuRecommendationReport-*.json') {
        $sku = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
        $servers = @($sku.Servers)
        if ($servers.Count -eq 1 -and $servers[0].ServerName -and
            (-not $instance -or $servers[0].ServerName -ieq $instance) -and
            $servers[0].TargetPlatform -eq $target) {
          $databases = @($servers[0].Requirements.DatabaseLevelRequirements |
            ForEach-Object { [string]$_.DatabaseName } | Sort-Object)
          if ($null -eq $servers[0].Recommendations -or
              ($null -ne $expectedDatabases -and (
                $databases.Count -ne $expectedDatabases.Count -or
                (Compare-Object $expectedDatabases $databases -CaseSensitive)))) {
            throw "SKU database inventory does not match readiness or other SKU targets for $target."
          }
          $matching += $file.FullName
          $matchedServer = $servers[0]
        }
      }
      if ($matching.Count -ne 1) { throw "Expected one instance-specific SKU JSON for $target." }
      if (-not $instance) { $instance = [string]$matchedServer.ServerName }
      if ($null -eq $expectedDatabases) {
        $expectedDatabases = @($matchedServer.Requirements.DatabaseLevelRequirements |
          ForEach-Object { [string]$_.DatabaseName } | Sort-Object)
      }
      $skuPaths += $matching[0]
    }
    $reportPath = $null
    if ($readinessPath) {
      $nativeOutput = & $tool GenerateAssessmentReport --reportFolder $folder --serverInstance $instance 2>&1
      if ($LASTEXITCODE -ne 0) { throw "Native combined-report generation failed (exit $LASTEXITCODE)." }
      $html = @(Get-ChildItem -LiteralPath $folder -File -Filter 'AssessmentReport-*.html')
      if ($html.Count -ne 1 -or $html[0].Length -eq 0) {
        throw "Native combined-report generation did not produce one nonempty HTML report."
      }
      $reportPath = $html[0].FullName
    }
    @{
      instance = $instance
      sizingCriterion = $criterion
      readinessJsonPath = $readinessPath
      skuJsonPaths = $skuPaths
      reportPath = $reportPath
      completedUtc = [DateTime]::UtcNow.ToString('O')
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $folder 'sku-complete.json') -Encoding utf8
    if ($reportPath) { $reportPath } else { Join-Path $folder 'sku-complete.json' }
  } finally {
    if (Test-Path -LiteralPath $privateConfig) { Remove-Item -LiteralPath $privateConfig -Force -ErrorAction Stop }
  }
}
```

For ConfigBased, completed performance inputs, or matching reused SKU results,
run synchronously:

```powershell
& $generateRecommendations $SqlAssessmentPath $runOutputFolder $sizingCriterion `
  $configFilePath $connectionString $perfQueryInterval $existingSkuPaths $recordedInstance
```

The generated config is private, ephemeral, and never replaces the user-provided
file. Do not use `--connection-string`, print captured native output, rewrite
native JSON, or modify the native HTML.
Use captured native output for local diagnosis only; report relevant errors with
connection strings and secrets removed, rather than dumping raw output.

## Step 4: Collect Performance Data Only When Selected

Skip this step for ConfigBased, completed performance inputs, and reused results.
Before starting collection, verify:

```text
numberOfIteration = min(20, floor(duration / perfQueryInterval))
numberOfIteration >= 2
duration >= perfQueryInterval * numberOfIteration
```

A 300-second collection with a 30-second interval uses 10 iterations, not 20.
Only a completed persistence cycle produces aggregated time-series counters.

```powershell
if ($null -eq $perfQueryInterval) { $perfQueryInterval = 30 }
if ($duration -le 0 -or $perfQueryInterval -le 0) {
  throw "Collection duration and sampling interval must be positive."
}
$numberOfIteration = [int][Math]::Min(20, [Math]::Floor($duration / $perfQueryInterval))
if ($numberOfIteration -lt 2) {
  throw "Collection settings cannot complete a persistence cycle."
}
$performanceConfigPath = Join-Path ([IO.Path]::GetTempPath()) (
  'sql-migration-performance-' + $runId + '.json')
$started = $false
try {
  $performanceConfig = if ($configFilePath) {
    Get-Content -LiteralPath $configFilePath -Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
  } else { @{ sqlConnectionStrings = @($connectionString) } }
  if ($null -eq $performanceConfig.sqlConnectionStrings -or
      @($performanceConfig.sqlConnectionStrings).Count -ne 1 -or
      [string]::IsNullOrWhiteSpace($performanceConfig.sqlConnectionStrings[0])) {
    throw "Performance collection requires exactly one nonempty sqlConnectionStrings entry; multi-instance configs are not supported."
  }
  $performanceConfig.action = 'PerfDataCollection'
  $performanceConfig.outputFolder = $runOutputFolder
  $performanceConfig.perfQueryIntervalInSec = $perfQueryInterval
  $performanceConfig.staticQueryIntervalInSec = 60
  $performanceConfig.numberOfIterations = $numberOfIteration
  New-Item -ItemType File -Path $performanceConfigPath -ErrorAction Stop | Out-Null
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent().User
  $acl = Get-Acl -LiteralPath $performanceConfigPath
  $acl.SetAccessRuleProtection($true, $false)
  $acl.SetAccessRule([Security.AccessControl.FileSystemAccessRule]::new($identity, 'FullControl', 'Allow'))
  Set-Acl -LiteralPath $performanceConfigPath -AclObject $acl
  $performanceConfig | ConvertTo-Json -Depth 10 |
    Set-Content -LiteralPath $performanceConfigPath -Encoding utf8 -ErrorAction Stop
  $workerInputs = @{
    tool = $SqlAssessmentPath
    folder = $runOutputFolder
    instance = $recordedInstance
    config = $performanceConfigPath
    duration = [int]$duration
    interval = [int]$perfQueryInterval
  } | ConvertTo-Json -Compress
  $encodedInputs = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($workerInputs))
  $workerCommand = @"
`$ErrorActionPreference = 'Stop'
`$inputData = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$encodedInputs')) | ConvertFrom-Json
try {
  `$output = Start-Sleep -Seconds (`$inputData.duration + 30) | az datamigration performance-data-collection --config-file-path `$inputData.config --time `$inputData.duration 2>&1
  if (`$LASTEXITCODE -ne 0) { throw "Performance collection failed (exit `$LASTEXITCODE)." }
  `$prefix = `$inputData.instance.Replace('\', '_')
  `$counter = Join-Path `$inputData.folder (`$prefix + '_PerformanceAggregated_Counters.csv')
  if (-not (Test-Path -LiteralPath `$counter) -or
      -not (Import-Csv -LiteralPath `$counter | Select-Object -First 1)) {
    throw "Collection finished without completed instance-specific aggregated counters."
  }
  & {
$generateRecommendations
  } `$inputData.tool `$inputData.folder 'PerformanceBased' `$null `$null `$inputData.interval `$null `$inputData.instance
} finally {
  if (Test-Path -LiteralPath `$inputData.config) {
    Remove-Item -LiteralPath `$inputData.config -Force -ErrorAction Stop
  }
}
"@
  $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($workerCommand))
  $worker = Start-Process pwsh -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput (Join-Path $runOutputFolder 'perf-sku-output.log') `
    -RedirectStandardError (Join-Path $runOutputFolder 'perf-sku-error.log') `
    -ArgumentList '-NoProfile', '-NonInteractive', '-EncodedCommand', $encodedCommand
  $workerStart = $worker.StartTime.ToUniversalTime().ToString('O')
  if ($worker.HasExited -and $worker.ExitCode -ne 0) { throw "Performance worker failed to start successfully." }
  @{
    runId = $runId
    startedUtc = $runStartedUtc.ToString('O')
    workerPid = $worker.Id
    workerStartedUtc = $workerStart
    outputFolder = $runOutputFolder
  } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $runOutputFolder 'perf-sku-run.json') -Encoding utf8
  $started = $true
  Write-Host "Performance collection output folder: $runOutputFolder"
} finally {
  if (-not $started -and (Test-Path -LiteralPath $performanceConfigPath)) {
    Remove-Item -LiteralPath $performanceConfigPath -Force -ErrorAction Stop
  }
}
```

The encoded worker contains only nonsecret paths/settings, never credentials.
It preserves automatic sizing/report generation after collection. Do not run
another assessment to check progress.

## Step 5: Check Completion

Read `perf-sku-run.json` from the exact recorded run folder. A PID is live only
when its process start time also matches `workerStartedUtc` (avoid PID reuse).
While that worker is alive, show collection/report-generation status, not success.
After it exits, require `sku-complete.json`, its three SKU JSONs, its nonempty
fresh instance-prefixed aggregated counters, and combined HTML only when
`readinessJsonPath` is present. For sizing-only runs, `readinessJsonPath` and
`reportPath` must both be null; do not require HTML or show a Migration Readiness
section. If a required artifact is missing, report failure and the safe
`perf-sku-error.log` path. Never display raw
logs or private configs. Re-read and validate the instance, target and database
metadata from Step 3 before rendering a saved result.
