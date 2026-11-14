# Native Tool Preparation

Prepare only the native executable; do not run readiness or `Assess`.
Reuse the exact prepared path for sizing and any detached worker.

An explicit `$SqlAssessmentPath` is validated but never replaced. Otherwise check
the official strong ETag and cached archive SHA-256, extract a fresh private copy,
and retry an invalid package once with a fresh download. Never fall back to an
older executable or overwrite Azure CLI's cache or an active worker's files.
Retain the selected package directory while its assessment or worker uses it.

This block matches readiness's tool preparation. Each skill ships its own copy
because references cannot leave a standalone skill's package.

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

Help can be written to stderr; inspect both streams. Other command, permission
and network errors propagate unchanged. Execute the literal block, not by
extracting Markdown at runtime.
