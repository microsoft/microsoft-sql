---
name: evaluate-azure-migration-assessment
description: "Use when running or refreshing migration assessment for an Azure SQL Server instance and retrieving readiness and SKU results."
allowed-tools: Bash(az:*, curl:*) PowerShell Grep View
---

# Evaluate Azure Migration Assessment

These claims were checked on 2026-09-15 against the bundled `skill-contract.yml`, ARM API
contracts, and assessment output contract.

## When to Use

Use directly or from `run-migration-assessment` for Azure SQL Server
instances.

## Workflow

### Step 1: Resolve the Resource

Collect subscription, resource group, and instance name using
[ARM resource identification](references/arm-resource-identification.md) if not in context.
Before calling ARM, initialize the API versions and instance endpoint from `references/command-execution.md`.

### Step 2: Check Existing Assessment

Always check for an existing assessment first for a general request such as
"run migration assessment".

Skip this check only when the user explicitly asks to **refresh**, **rerun**,
**replace**, or generate a **new/fresh** assessment, or explicitly says to
ignore existing results.

Invoke `get-migration-assessment` with the resolved identifiers.

- Existing data -> render it before asking anything else. Trigger a fresh
  assessment only after the user explicitly confirms.
- Enabled with no data -> continue to Step 3.
- Explicitly disabled -> offer ARM enablement, portal enablement, or Local assessment if the host tool allows.

### Step 3: Trigger and Monitor Assessment

Record the trigger request time and run the assessment trigger from
`references/command-execution.md` when starting a fresh assessment. Continue in the same command by polling
`MigrationJobOnDemand` using the configurable attempt count and interval from
that reference.

- 2xx or 409 -> continue.
- Other 4xx/5xx -> report the error and stop.
- `InProgress` -> continue polling in the same turn without asking the user.
- `Succeeded` with `lastExecutionTime` later than the trigger request time ->
  continue to Step 4.
- `Succeeded` with an older `lastExecutionTime` -> continue polling.
- `Failed` -> show `jobException` and stop.
- Still running after the polling window -> show the portal link and stop; the
  user can return later to refresh.

### Step 4: Retrieve Telemetry

Run `getTelemetry`, capture its `Azure-AsyncOperation` URL, and poll it using
`references/command-execution.md` when retrieving a completed report. Save the full response to a temporary file.

- `Succeeded` -> decode the response.
- `Failed` or `Canceled` -> report the error.
- Timeout -> show the portal link and stop.

### Step 5: Confirm Fresh Results

Decode the portal's four telemetry report families:

- `Suitability` / `Suitability_V2`.
- `SKURecommendation_AzureSQLVM` / `_V2`.
- `SKURecommendation_AzureSQLMI` / `_V2`.
- `SKURecommendation_AzureSQLDB` / `_V2`.

For each family, select the report with the newer telemetry
`ObservedTimestampUTC`. Use Suitability for readiness and blockers, and the
three SKU reports for sizing and recommendation details.

Compare the selected Suitability `EndedOn` with the trigger request time after
converting both to UTC. Also require each available
selected SKU report's `ObservedTimestampUTC` to be later than the trigger
request time. If any selected report is stale, repeat telemetry retrieval and
decoding up to three times for report propagation. Use the job only for running,
fresh success, and failure state.

Use the selected fresh telemetry reports as the source for readiness, blockers,
target SKU, requirements, recommendation details, and available monetary cost
fields.

### Step 6: Render

Use the recommended target and available cost from the fresh telemetry selected
in Step 5.

Use [assessment output](references/assessment-output.md) when rendering the combined
readiness and SKU recommendation. Include the portal report link.

## Check it worked

- **Positive verification:** When reusing existing assessment data, confirm it was
  retrieved and rendered without triggering a refresh. When a fresh assessment was
  requested, require a successful assessment job, completed report retrieval, and
  selected report timestamps later than the recorded trigger time.
- **Cleanup verification:** Clear the ARM token and signed operation URL, then remove the temporary
  run directory only after any requested report has been saved elsewhere.

## Notes

- Follow the transport rules in `references/command-execution.md` whenever calling ARM.
- Run its PowerShell sections in order and execute each fenced block as one
  terminal command.
- The telemetry operation URL comes from `getTelemetry`.
- Treat a successful telemetry LRO as report-read completion. Use
  `MigrationJobOnDemand` for assessment-job completion.
- Use `EndedOn` as the generated time.
- Use only the recommended target and user databases in output.

## References

- Open `references/command-execution.md` before triggering, polling, or retrieving an assessment.
- [ARM resource identification](references/arm-resource-identification.md)
- [Assessment output](references/assessment-output.md)
