---
name: evaluate-offline-migration-readiness
description: "Use when running migration readiness assessment for a local or on-premises SQL Server with az datamigration on Windows."
allowed-tools: Bash(az:*) PowerShell Grep View
---

# Evaluate Offline Migration Readiness

The bundled references define local readiness,
default configuration-based sizing, and native combined reporting.

## When to Use

Use directly or from `run-migration-assessment` for local/on-premises readiness
assessment, with configuration-based sizing by default. Invoke after the server is
confirmed Local. Route Azure identifiers and unresolved servers through
`run-migration-assessment`.

## Workflow

### Step 1: Check the Host and Tools

Before asking for connection details, apply [OS requirements](references/os-requirements.md), then
review [assessment prerequisites](references/assessment-prerequisites.md) before continuing.
Continue on a supported Windows host.

### Step 2: Confirm Inputs

Reuse the instance and output folder from context. If the folder is missing,
present selectable Default (`%LOCALAPPDATA%\Microsoft\SqlAssessment`) and Custom
choices. Wait for the answer and use the selected path.

### Step 3: Check Existing Results

When checking for prior results, use `references/command-execution.md` to find the latest result matching the exact
normalized instance name.

- Existing result -> read and render it before asking anything else. Show its
  generation time and run a fresh assessment only after explicit confirmation.
- No result -> continue.

### Step 4: Run Assessment

Reuse complete connection details already present in conversation context.
Do not ask how to connect when the server and credentials were already
provided. Collect only missing connection information using
[local server connection](references/local-server-connection.md) when details are missing, then run the matching command
from `references/command-execution.md` when starting the assessment.

### Step 5: Render

Read the output JSON, then read and render
`references/readiness-output.md` before presenting results.

This is a hard output contract:

- Use the template exactly; do not replace it with a prose summary.
- Render all three target sections and the report path.
- Render the complete assessment before asking about SKU sizing.
- A retry, successful fresh assessment, or existing result uses the same
  template.
- The user's later SKU-duration choice must not replace or shorten the
  readiness response already required by this step.

### Step 6: Choose SKU Sizing

Immediately after rendering readiness, ask:

> "How would you like to size the Azure SQL recommendations?"

Always present selectable options with the first choice preselected:

- Configuration-based sizing (Default, Recommended; no performance collection)
- Collect 2 hours of performance data
- Collect 24 hours of performance data
- I don't want a SKU recommendation

Accepting the picker without changing its selection, or submitting an empty
sizing answer, selects configuration-based sizing. Wait for the picker response;
do not treat an unanswered question as permission to collect performance data.
Allow a custom collection duration through the free-form answer. Preserve any
explicit sizing preference already in context as the selection.

Delegate to `recommend-sku-sizing` with the selected mode, instance, output folder,
native executable path, and exact readiness JSON path. For performance collection,
also pass the selected duration in seconds. If the user declines, finish with the
native readiness-only report already generated; identify unavailable SKU data
rather than inventing recommendations.

## Check it worked

- **Positive verification:** When reusing an existing report, confirm it matches the
  exact normalized instance name. When running a new assessment, additionally require
  the assessment command to succeed.
- **Cleanup verification:** Confirm the generated temporary config was deleted whether the command
  succeeded or failed; retain the user-selected output folder and reports.

## Notes

- Confirm the output folder before checking files.
- Prefer an exact instance-tagged report. If the CLI generates
  `SqlAssessmentReport-*.json` instead, use it only from the confirmed
  per-instance output folder.
- Include the generated native `AssessmentReport-*.html` path. Missing combined
  HTML is a report-generation failure, not a successful JSON-only fallback.

## Error Handling

- Cannot connect -> check server name, port, firewall, and credentials.
- Tool or extension unavailable -> follow
  [assessment prerequisites](references/assessment-prerequisites.md) when restoring prerequisites.

## References

- Open `references/command-execution.md` when checking or running an assessment.
- [Local server connection](references/local-server-connection.md)
- [OS requirements](references/os-requirements.md)
- [Assessment prerequisites](references/assessment-prerequisites.md)
- Open `references/readiness-output.md` before rendering assessment results.
