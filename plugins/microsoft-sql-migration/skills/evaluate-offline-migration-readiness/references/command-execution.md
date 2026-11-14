# Offline Readiness Command Execution

## Inputs

- `$instanceName`: selected SQL Server instance
- `$OUTPUT_FOLDER`: confirmed per-instance output folder
- `$connectionString` or `$configFilePath`: connection details resolved locally
- `$SqlAssessmentPath`: optional explicit prepared native executable

Keep credentials inside the local PowerShell process. Do not print connection
configuration, place it in command arguments, or return it to the model.
Inspect each step's result before continuing. Use PowerShell's terminating errors
for command, file and JSON failures; explicit checks below cover native exit codes
and report validity. Keep `try/finally` for temporary-file cleanup, not to replace
the original error.

## Step 0: Prepare the Native Tool

Use the supplied executable when explicit; never replace it automatically.
Otherwise follow Modernize's archive-cache approach: check the official package's
current strong ETag and the cached ZIP's recorded SHA-256 before reuse, then
extract a fresh private executable. Previously extracted executables are never
reused, so missing or corrupted files in an older extraction cannot affect a new
assessment. A changed ETag, bad checksum, or missing/malformed cache metadata
requires a fresh download. Without a strong ETag, download rather than assume
freshness.

An invalid archive, missing executable or unsupported APIs triggers one clean
re-download and extraction attempt. Fail explicitly if recovery fails; never
fall back to an older executable. Do not overwrite Azure CLI's cache or an active
worker's files. Keep the selected private package folder until its assessment
and any detached worker have finished; reuse its exact executable for that run.

```powershell
$ErrorActionPreference = 'Stop'
function Invoke-SqlAssessmentPackageRequest {
  param($Method, $Destination)
  $arguments = @{
    Uri = 'https://aka.ms/sqlassessmentpackage'
    Method = $Method
    Headers = @{ 'Cache-Control' = 'no-cache' }
    TimeoutSec = 120
  }
  if ($Destination) {
    $arguments.OutFile = $Destination
    $arguments.PassThru = $true
  }
  $response = Invoke-WebRequest @arguments
  $origin = $response.BaseResponse.RequestMessage.RequestUri
  if ($origin.Scheme -ne 'https' -or $origin.Host -ne 'download.microsoft.com') {
    throw "Unexpected SqlAssessment download origin."
  }
  $response
}
function Test-SqlAssessmentApis {
  param($Path)
  foreach ($probe in @(
    @{ Verb = 'LoadFromJson'; Option = '--configFile' },
    @{ Verb = 'GetSkuRecommendation'; Option = '--sizingCriterion' },
    @{ Verb = 'GenerateAssessmentReport'; Option = '--reportFolder' }
  )) {
    $helpText = (& $Path $probe.Verb --help 2>&1 | Out-String)
    if (-not $helpText.Contains($probe.Option)) { return $false }
  }
  return $true
}
if ($SqlAssessmentPath) {
  if (-not (Test-SqlAssessmentApis $SqlAssessmentPath)) {
    throw "The supplied SqlAssessment executable lacks required APIs. Supply a compatible package."
  }
} else {
  $remote = Invoke-SqlAssessmentPackageRequest 'Head'
  $remoteETag = [string]($remote.Headers.ETag -join '')
  $cache = Join-Path $env:LOCALAPPDATA 'Microsoft\SqlAssessment\AgentSkills\PackageCache'
  [void][IO.Directory]::CreateDirectory($cache)
  $cachedArchive = Join-Path $cache 'SqlAssessment.zip'
  $metadataPath = Join-Path $cache 'package.json'
  $metadata = $null
  if (Test-Path -LiteralPath $metadataPath) {
    try {
      $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
    } catch [ArgumentException] {
      Write-Warning "SqlAssessment cache metadata is invalid; downloading a fresh package."
    }
  }
  for ($attempt = 0; $attempt -lt 2; $attempt++) {
    $packageFolder = Join-Path (Split-Path $cache) ('package-' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($packageFolder)
    $archive = Join-Path $packageFolder 'SqlAssessment.zip'
    $metadataTemporary = Join-Path $packageFolder 'package.json'
    $prepared = $false
    try {
      $reused = $false
      if ($attempt -eq 0 -and $remoteETag -match '^"[^"]+"$' -and
          $metadata.Source -eq 'https://aka.ms/sqlassessmentpackage' -and
          $metadata.ETag -ceq $remoteETag -and (Test-Path -LiteralPath $cachedArchive)) {
        Copy-Item -LiteralPath $cachedArchive -Destination $archive
        $reused = $metadata.Sha256 -ceq (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
      }
      if (-not $reused) {
        Write-Host "Downloading the current SqlAssessment package; no verified cache is available."
        $download = Invoke-SqlAssessmentPackageRequest 'Get' $archive
      }
      $hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
      $extracted = Join-Path $packageFolder 'tool'
      [IO.Compression.ZipFile]::ExtractToDirectory($archive, $extracted)
      $executables = @(Get-ChildItem -LiteralPath $extracted -Recurse -File -Filter 'SqlAssessment.exe')
      if ($executables.Count -ne 1 -or $executables[0].Length -eq 0 -or
          -not (Test-SqlAssessmentApis $executables[0].FullName)) {
        throw [IO.InvalidDataException]::new("SqlAssessment package is incomplete or lacks required APIs.")
      }
      if (-not $reused) {
        @{
          Source = 'https://aka.ms/sqlassessmentpackage'
          ETag = [string]($download.Headers.ETag -join '')
          Sha256 = $hash
        } | ConvertTo-Json | Set-Content -LiteralPath $metadataTemporary -Encoding utf8
        [IO.File]::Move($archive, $cachedArchive, $true)
        [IO.File]::Move($metadataTemporary, $metadataPath, $true)
      }
      $SqlAssessmentPath = $executables[0].FullName
      $prepared = $true
      break
    } catch [IO.InvalidDataException], [System.Management.Automation.ApplicationFailedException] {
      if ($attempt -eq 1) { throw }
      Write-Warning "SqlAssessment package validation failed; retrying once with a fresh download. $($_.Exception.Message)"
    } finally {
      foreach ($temporaryFile in @($archive, $metadataTemporary)) {
        if (Test-Path -LiteralPath $temporaryFile) { Remove-Item -LiteralPath $temporaryFile -Force }
      }
      if (-not $prepared) {
        Remove-Item -LiteralPath $packageFolder -Recurse -Force
      }
    }
  }
}
```

Help may be written to stderr; inspect both streams. No client-attribution
argument is required for these checks. The two typed catches are recovery points
for corrupt cache metadata or an unusable package, not wrappers around every
command. Other command, permission and network errors propagate unchanged.

## Step 1: Find Existing Results

```powershell
$target = $instanceName -replace '\\', '_'
$result = $null
$candidates = if (Test-Path -LiteralPath $OUTPUT_FOLDER) {
  Get-ChildItem -LiteralPath $OUTPUT_FOLDER -Recurse -File `
    -Filter 'SqlAssessment*.json' -ErrorAction Stop |
    Sort-Object LastWriteTime -Descending
}
foreach ($candidate in $candidates) {
  $report = Get-Content -LiteralPath $candidate.FullName -Raw |
    ConvertFrom-Json -ErrorAction Stop
  $servers = @($report.Servers)
  if ($servers.Count -eq 1 -and
      (($servers[0].Properties.ServerName -replace '\\', '_') -ieq $target)) {
    $result = $candidate
    break
  }
}
$result | Select-Object Name, LastWriteTime, FullName
```

Reuse only an exact embedded instance match. Existing results require no new SQL
connection. Do not refresh without explicit confirmation. Legacy JSON that the
new API cannot consume requires an explicit fresh assessment, not JSON rewriting.

## Step 2: Run a New Assessment

Skip this step when reusing the matching JSON. Use a new isolated folder; never
change or delete a user-provided configuration.

```powershell
$ErrorActionPreference = 'Stop'
$runOutputFolder = Join-Path $OUTPUT_FOLDER ('readiness-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($runOutputFolder)
$privateConfigPath = Join-Path ([IO.Path]::GetTempPath()) (
  'sql-migration-assessment-' + [Guid]::NewGuid().ToString('N') + '.json')
try {
  $configuration = if ($configFilePath) {
    Get-Content -LiteralPath $configFilePath -Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
  } else {
    @{ sqlConnectionStrings = @($connectionString) }
  }
  if (@($configuration.sqlConnectionStrings).Count -ne 1) {
    throw "One locally resolved SQL connection is required per instance."
  }
  $configuration.action = 'Assess'
  $configuration.outputFolder = $runOutputFolder
  $configuration.overwrite = $false
  New-Item -ItemType File -Path $privateConfigPath -ErrorAction Stop | Out-Null
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent().User
  $acl = Get-Acl -LiteralPath $privateConfigPath
  $acl.SetAccessRuleProtection($true, $false)
  $acl.SetAccessRule([Security.AccessControl.FileSystemAccessRule]::new($identity, 'FullControl', 'Allow'))
  Set-Acl -LiteralPath $privateConfigPath -AclObject $acl
  $configuration | ConvertTo-Json -Depth 10 |
    Set-Content -LiteralPath $privateConfigPath -Encoding utf8 -ErrorAction Stop
  $nativeOutput = & $SqlAssessmentPath LoadFromJson --configFile $privateConfigPath 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "Native readiness assessment failed (exit $LASTEXITCODE)."
  }
  $result = Get-ChildItem -LiteralPath $runOutputFolder -File -Filter 'SqlAssessment-*.json'
} finally {
  if (Test-Path -LiteralPath $privateConfigPath) {
    Remove-Item -LiteralPath $privateConfigPath -Force -ErrorAction Stop
  }
}
```

## Step 3: Generate the Native Readiness Report

Use this step for fresh and reused results, including an explicit SKU opt-out.
The native API supports suitability-only inputs and identifies unavailable SKU
or pricing data; do not describe that report as completed SKU sizing.

```powershell
$ErrorActionPreference = 'Stop'
$readinessJsonPath = $result.FullName
$readiness = Get-Content -LiteralPath $readinessJsonPath -Raw | ConvertFrom-Json -ErrorAction Stop
$servers = @($readiness.Servers)
if ($servers.Count -ne 1 -or -not $servers[0].Properties.ServerName) {
  throw "Readiness JSON must identify exactly one assessed instance."
}
$recordedInstance = [string]$servers[0].Properties.ServerName
$reportFolder = Join-Path $OUTPUT_FOLDER ('report-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($reportFolder)
Copy-Item -LiteralPath $readinessJsonPath -Destination $reportFolder -ErrorAction Stop
$nativeOutput = & $SqlAssessmentPath GenerateAssessmentReport `
  --reportFolder $reportFolder --serverInstance $recordedInstance 2>&1
if ($LASTEXITCODE -ne 0) {
  throw "Native combined-report generation failed (exit $LASTEXITCODE). No HTML report was published."
}
$html = @(Get-ChildItem -LiteralPath $reportFolder -File -Filter 'AssessmentReport-*.html')
if ($html.Count -ne 1 -or $html[0].Length -eq 0) {
  throw "Native combined-report generation did not produce one nonempty HTML report."
}
$combinedReportPath = $html[0].FullName
$combinedReportPath
```

Native output remains in `$nativeOutput` for local diagnosis. Do not print it
unfiltered; share only relevant diagnostics with connection strings and secrets
removed.

Render the readiness JSON with the unchanged native HTML path. Pass only
`$SqlAssessmentPath`, `$readinessJsonPath`, `$recordedInstance` and the confirmed
output folder to the sizing skill; resolve credentials locally again if needed.
