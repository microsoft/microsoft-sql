# Local Tool Prerequisites

Common prerequisites for any skill that runs local/on-prem operations using the Azure CLI `datamigration` extension.

## Required Tools

| Tool | Purpose | Install |
|---|---|---|
| **Azure CLI 2.75.0+** | Base CLI for all `az` commands | [Install](https://aka.ms/installazurecli) |
| **`datamigration` extension** | Assessment, perf collection, SKU recommendation | `az extension add --name datamigration` |

## Environment Discovery

**CRITICAL: Every local skill MUST run this check before doing anything else.**

**Windows (PowerShell):**
```powershell
$ErrorActionPreference = 'Stop'
$minimumCliVersion = [version]"2.75.0"
Get-Command az -ErrorAction Stop | Out-Null
$cliOutput = az version --output json
if ($LASTEXITCODE -ne 0) {
  throw "Azure CLI version command failed (exit $LASTEXITCODE)."
}
$cliVersion = [version](($cliOutput -join "`n" | ConvertFrom-Json).'azure-cli')
if ($null -eq $cliVersion) {
  throw "Azure CLI version JSON is missing azure-cli."
}
if ($cliVersion -lt $minimumCliVersion) {
  Write-Host "Azure CLI $cliVersion must be upgraded to $minimumCliVersion or later."
  return
}
az extension show --name datamigration --query version -o tsv 2>$null
if ($LASTEXITCODE -ne 0) { Write-Host "datamigration extension NOT INSTALLED" }
```

Let PowerShell report command, JSON and version-conversion errors directly.
Inspect the result before continuing; a failed check does not mean the CLI is
outdated.

### If Azure CLI is missing:

Tell the user:
> "Azure CLI is not installed. Install it from https://aka.ms/installazurecli and run `az login` to authenticate."

Do NOT proceed — the skill cannot run without it.

### If Azure CLI is older than 2.75.0:

Ask whether the user wants to upgrade it. After explicit approval, run:

```powershell
az upgrade --yes
```

Re-run the Environment Discovery check after the upgrade. If it fails, provide
https://aka.ms/installazurecli for manual installation.

### If `datamigration` extension is missing:

```bash
az extension add --name datamigration
```

Re-verify after install:
```bash
az extension show --name datamigration --query version -o tsv
```

## Native Report APIs

Use the native-tool preparation in [command execution](command-execution.md)
before running local assessment. A supported Azure CLI can still have an older
cached SqlAssessment executable without the new APIs. Do not equate these checks
or silently use an older reporting experience.
The readiness workflow owns package preparation and recovery: it verifies remote
freshness and the cached ZIP's SHA-256, then extracts a clean executable. Reuse
that prepared path during sizing and collection; never replace an active worker's
executable.

## OS Detection

Local assessment skills are Windows-only. Apply
[OS requirements](os-requirements.md) before this prerequisite check.

### Default Output Path

The default output path is:

```text
%LOCALAPPDATA%\Microsoft\SqlAssessment
```

Individual skills may ask the user to confirm this path or select a custom
folder.
