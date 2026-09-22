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
$minimumCliVersion = [version]"2.75.0"
$cliVersionText = az version --query '"azure-cli"' -o tsv 2>$null
if ($LASTEXITCODE -ne 0 -or -not $cliVersionText) {
  throw "Azure CLI is not installed."
}
$cliVersion = [version]$cliVersionText
if ($cliVersion -lt $minimumCliVersion) {
  Write-Host "Azure CLI $cliVersion must be upgraded to $minimumCliVersion or later."
  return
}
az extension show --name datamigration --query version -o tsv 2>$null
if ($LASTEXITCODE -ne 0) { Write-Host "datamigration extension NOT INSTALLED" }
```

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
