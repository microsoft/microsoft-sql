---
name: recommend-sku-sizing
description: Calculate configuration-based or performance-based Azure SQL SKU recommendations after the source is explicitly confirmed local/on-premises. Ask for the sizing mode unless already selected; configuration-based is the preselected picker choice. Route unresolved sources and bare server names through run-migration-assessment.
allowed-tools: PowerShell Grep View
---

# Recommend SKU Sizing

The bundled references define configuration-based and
performance-based sizing with native combined reports.

## When to Use

Use directly or from `run-migration-assessment` when a local/on-premises server
needs Azure SQL sizing. Invoke after the server is confirmed
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

- Existing result -> retain its generation time; after confirming the sizing mode,
  validate its matching inputs and regenerate the native combined report only
  when readiness is already available. Otherwise show SKU results without HTML.
  Refresh sizing only if explicitly requested.
- No matching result -> continue with the selected sizing mode.

Reuse results only when their embedded instance and recorded sizing mode match.
Generate the native combined report for reused results with readiness too, using the recorded
SKU JSON paths and readiness when available; never mix different database inventories.

### Step 3: Choose Sizing and Collect Parameters

Honor an explicit configuration-based or performance-based request, or reuse the
user's sizing selection from readiness, without asking again. Otherwise, a direct
sizing request must show the same picker as readiness and wait for the response:

> "How would you like to size the Azure SQL recommendations?"

- Configuration-based sizing (Default, Recommended; preselected; no performance collection)
- Collect 2 hours of performance data
- Collect 24 hours of performance data
- I don't want a SKU recommendation

Do not infer a sizing choice from missing performance data, an existing result,
or a supplied connection/config file. A preselected default is not permission
to start sizing. Wait for the picker response before preparing a run or executing
sizing. Accepting the default or submitting an empty sizing answer sets
`$sizingCriterion = 'ConfigBased'`; an unanswered picker does not. Stop if the
user opts out.

Use [local server connection](references/local-server-connection.md) when connection
details are missing.

Configuration-based sizing needs no performance data, collection duration, or
collection process. Performance collection starts only after an explicit selection.
Allow a custom duration and convert it to seconds; enforce the persistence-cycle
alignment in `references/command-execution.md`. Reuse explicitly supplied completed
performance data instead of starting another collection. Invalid performance data
is an error, not permission to fall back to configuration-based sizing.

### Step 4: Run Sizing and Generate the Native Report

Use `references/command-execution.md` to prepare the native tool, then run
ConfigBased sizing synchronously or the selected performance flow. Do not run
readiness for a direct sizing request. Generate all three targets; call
`GenerateAssessmentReport` only when matching readiness is already available.
Otherwise return the SKU results without requiring or linking an HTML report.
For collection, retain the detached worker and show the collection-started
output only after verifying that it started. The worker generates sizing and
combined HTML automatically after successful collection when readiness is available.

### Step 5: Check and Render Results

When results are requested, run the completion check from `references/command-execution.md`.

- Complete -> require all three valid SKU JSON files, plus nonempty native combined
  HTML when readiness is available, not merely an exit code of zero. Always use
  Azure SQL Database as the recommended target, even when it has compatibility
  findings. Extract only its compute, storage and cost values and populate those
  fields in the Skill Response Template in [assessment output](references/assessment-output.md) when rendering.
  Use the returned SQL Database service tier, not a hardcoded Hyperscale tier.
  Never substitute Managed Instance or VM values for missing SQL Database data.
  Apply the response template's readiness labels without hiding blockers or
  modifying native JSON or HTML; all three target results remain available.
  Include readiness if readiness results are already available in the
  current conversation context. Otherwise omit the Migration Readiness section
  and show the SKU data only, without an HTML report.
- Running -> show collection status.
- Stopped without time-series data -> report failure and show the log path.

## Check it worked

- **Positive verification:** Require a successful sizing run with all three SKU
  targets for the correct instance/database inventory. Require native combined
  HTML only when matching readiness is available.
  For performance collection also require a completed tracked worker and fresh
  instance-prefixed aggregated counters.
- **Cleanup verification:** Confirm the temporary performance config was deleted whether collection
  succeeded or failed; retain the selected output folder and reports.

## Notes

- Confirm the output folder before checking files.
- Ask for duration only when performance collection was explicitly selected.
- Reuse existing performance data when the user returns.
- Static common counter files alone do not mean collection completed.

## Error Handling

- Collection stops -> report the failure and check connectivity; start another
  isolated run only after an explicit retry.
- Output permission denied -> confirm write access or select another folder.
- Tool or extension unavailable -> follow
  [assessment prerequisites](references/assessment-prerequisites.md) when restoring prerequisites.

## References

- Open `references/command-execution.md` when checking, starting, or completing collection.
- [Local server connection](references/local-server-connection.md)
- [OS requirements](references/os-requirements.md)
- [Assessment prerequisites](references/assessment-prerequisites.md)
- [Assessment output](references/assessment-output.md)
