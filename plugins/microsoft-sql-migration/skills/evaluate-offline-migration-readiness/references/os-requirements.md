# Guide: Host-OS Requirement (Local assessment is Windows-only)

Local assessment — readiness (`evaluate-offline-migration-readiness`) and SKU sizing (`recommend-sku-sizing`) — shells out to `az datamigration` / `SqlAssessment.exe`, which has Windows-only dependencies and **cannot run on Linux or macOS**.

> Azure assessments are cross-platform and are **not** subject to this check. Apply this guard **only** to the local path.

## The check (run BEFORE asking for connection details, output folder, or credentials)

```powershell
if ($IsWindows -or $env:OS -eq 'Windows_NT') { 'Windows' } else { 'NotWindows' }
```

- If the result is `Windows` → continue.
- If the result is `NotWindows` (Linux or macOS) → **STOP immediately.** Do NOT ask for any inputs and do NOT run `az datamigration`. Tell the user:

  > ⚠️ Local assessment is only supported on Windows. Please run this from a Windows machine that can reach your SQL Server.
