# Offline Readiness Command Execution

## Inputs

- `{instanceName}`: SQL Server instance name
- `$OUTPUT_FOLDER`: Confirmed per-instance output folder
- One of `{connectionString}` or `{configFilePath}` for a new assessment

## Step 1: Find Existing Results

```powershell
# Normalize backslash (named instances) to underscore to match the file naming, then require an EXACT instance segment.
$target = "{instanceName}" -replace '\\','_'
$result = Get-ChildItem "$OUTPUT_FOLDER\SqlAssessment-*.json", "$OUTPUT_FOLDER\SqlAssessment-*.html" -ErrorAction SilentlyContinue |
  Where-Object { $_.BaseName -match '^SqlAssessment-(.+)-\d{8,}$' -and $Matches[1] -ieq $target } |
  Sort-Object LastWriteTime -Descending | Select-Object Name, LastWriteTime, FullName -First 1

if (-not $result) {
  $legacyReports = Get-ChildItem "$OUTPUT_FOLDER\SqlAssessmentReport-*.json" -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending
  foreach ($candidate in $legacyReports) {
    $report = Get-Content $candidate.FullName -Raw | ConvertFrom-Json
    $serverNames = @($report.Servers | ForEach-Object { $_.Properties.ServerName })
    if ($serverNames.Count -eq 1 -and
        (($serverNames[0] -replace '\\','_') -ieq $target)) {
      $result = $candidate
      break
    }
  }
}

$result
```

For a legacy generic JSON report, require its embedded server name to match.

## Step 2: Run Assessment

**If connection string:**

```powershell
$configFilePath = Join-Path ([IO.Path]::GetTempPath()) (
  'sql-migration-assessment-' + [Guid]::NewGuid().ToString('N') + '.json')
@{
  action = 'Assess'
  outputFolder = $OUTPUT_FOLDER
  overwrite = 'true'
  sqlConnectionStrings = @($connectionString)
} | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $configFilePath -Encoding utf8

try {
  az datamigration get-assessment --config-file-path $configFilePath
}
finally {
  Remove-Item -LiteralPath $configFilePath -Force -ErrorAction SilentlyContinue
}
```

**If config file path:**

```bash
az datamigration get-assessment \
  --config-file-path "{configFilePath}"
```

Never pass a connection string through `--connection-string`. Create the
temporary config under the current user's `%TEMP%`, never print it, and delete
it after the command succeeds or fails. Do not delete a user-provided config.
