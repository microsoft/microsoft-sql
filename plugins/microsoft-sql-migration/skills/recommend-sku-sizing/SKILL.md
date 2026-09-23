---
name: recommend-sku-sizing
description: Collect performance data and calculate Azure SQL SKU recommendations only after the source is explicitly confirmed local/on-premises. Never use for a generic SKU request or bare server name; route unresolved requests through run-migration-assessment.
allowed-tools: PowerShell Grep View
---

# Recommend SKU Sizing

These claims were checked on 2026-09-15 against the bundled `skill-contract.yml`, Azure CLI
`datamigration` command contract, and SKU assessment output contract.

## When to Use

Use directly or from `run-migration-assessment` when a local/on-premises server
needs performance-based Azure SQL sizing. Invoke after the server is confirmed
Local. Route Azure identifiers and unresolved servers through
`run-migration-assessment`.

## Workflow

### Step 0: Enforce Source Routing

Proceed only when the current conversation explicitly identifies the source as
Local or on-premises, or already provides local evidence such as an IP address,
connection string, or config file. The words `SQL Server`, `server`, or `SKU
recommendation` alone do not establish that the source is Local.

If the source is not explicit, do not ask for an instance name, output folder,
credentials, collection duration, or target platform. Invoke
`run-migration-assessment` so it can ask whether the source is Azure or Local.

### Step 1: Check the Host and Confirm Inputs

Before collecting local inputs, apply [OS requirements](references/os-requirements.md), then
review [assessment prerequisites](references/assessment-prerequisites.md) before continuing.
Confirm the output folder with selectable Default
(`%LOCALAPPDATA%\Microsoft\SqlAssessment`) and Custom choices. Wait for the
answer and use the selected path.

### Step 2: Check Existing Results

When checking for prior results, run the host-specific lookup from `references/command-execution.md`.

- Existing result -> render it with its generation time and refresh only if
  explicitly requested.
- No result -> explain that performance collection is required and ask whether to
  continue.

SKU filenames are not instance-specific. Use a per-instance output folder to
associate results with the selected server.

### Step 3: Collect Parameters

Use [local server connection](references/local-server-connection.md) when connection
details are missing. Ask for collection duration with selectable 2-hour and 24-hour
(Recommended) options, plus "I don't want a SKU recommendation". Allow a custom
duration. Stop if the user declines. Convert the duration to seconds.
Before starting collection, use the parameter-alignment rule in `references/command-execution.md`. Do not start
a collection that cannot complete one persistence cycle.

### Step 4: Start Collection

Run the exact detached collection and SKU command from
`references/command-execution.md` when starting collection. Show the collection-started output from
[assessment output](references/assessment-output.md) after the worker starts.

### Step 5: Check and Render Results

When results are requested, run the completion check from `references/command-execution.md`.

- Complete -> read the newest SKU JSON report when available. Extract only the
  recommended target's compute and storage configuration and populate those
  fields in the Skill Response Template in [assessment output](references/assessment-output.md) when rendering.
  Include readiness if readiness results are already available in the
  current conversation context. Otherwise omit the Migration Readiness section
  and show the SKU data only.
- Running -> show collection status.
- Stopped without time-series data -> report failure and show the log path.

## Check it worked

- **Positive verification:** Require the tracked worker to finish successfully, then confirm a
  fresh instance-prefixed counter file and SKU report exist in the recorded run output folder.
- **Cleanup verification:** Confirm the temporary performance config was deleted whether collection
  succeeded or failed; retain the selected output folder and reports.

## Notes

- Confirm the output folder before checking files.
- Always ask for collection duration.
- Reuse existing performance data when the user returns.
- Static common counter files alone do not mean collection completed.

## Error Handling

- Collection stops -> check connectivity and restart with the same folder.
- Output permission denied -> confirm write access or select another folder.
- Tool or extension unavailable -> follow
  [assessment prerequisites](references/assessment-prerequisites.md) when restoring prerequisites.

## References

- Open `references/command-execution.md` when checking, starting, or completing collection.
- [Local server connection](references/local-server-connection.md)
- [OS requirements](references/os-requirements.md)
- [Assessment prerequisites](references/assessment-prerequisites.md)
- [Assessment output](references/assessment-output.md)
