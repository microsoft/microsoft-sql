# Output Format: Full Assessment (Recommended Target + SKU + Readiness)

## Contents

- [When to Use](#when-to-use)
- [Required Inputs](#required-inputs)
- [Skill Response Template](#skill-response-template)
- [Async Collection Flow (Local SKU only)](#async-collection-flow-local-sku-only)


Use this template when assessment data includes a **recommended target with SKU
sizing**, from either Azure assessment telemetry or a local SKU report.

Use the template below exactly.

---

## When to Use

| Source | Condition |
|--------|-----------|
| Azure | Fresh Suitability and SKU telemetry or existing ARG assessment data is available |
| Local SKU results | Three validated target SKU JSONs exist; native combined HTML is required only when readiness is available |

### Local native report scenarios

| Scenario | Inputs to `GenerateAssessmentReport` |
|----------|--------------------------------------|
| Performance-based sizing + readiness | Matching readiness JSON and all three performance-based target SKU JSONs |
| Configuration-based sizing + readiness | Matching readiness JSON and all three configuration-based target SKU JSONs |
| Readiness only, including an explicit sizing opt-out | Readiness JSON only; use the readiness response template and identify unavailable SKU data |
| Direct sizing without readiness | Return SKU results only; do not call `GenerateAssessmentReport` or require/link HTML |

Use the same native report experience for fresh results, explicitly refreshed
results, reused results and existing completed performance data when readiness is
available. A direct sizing request must not run readiness. Regenerating HTML does
not authorize fresh assessment or performance collection.

---

## Required Inputs

Before using this template, the calling skill must provide the recommended
target, SKU, and cost values to render, plus readiness when already available.
Always use **Azure SQL Database** as the recommended target, even when it has
compatibility findings. Use only its returned service tier, hardware, sizing,
cost and applicable findings. Do not hardcode Hyperscale, select MI or VM instead,
or substitute their values when SQL Database data is missing; show `--` with a
reason. Continue generating all three native target results and leave native JSON
and HTML unchanged. This policy applies to the chat summary.
Show the portal link for Azure or the generated report path for Local with
readiness. For local sizing-only results, show the SKU JSON paths instead.
For Local, disclose `Configuration-based` or `Performance-based` sizing using the
recorded run mode. Configuration-based sizing has no collection window.

### Counting databases and readiness

- Use **🟢 Ready** only for explicit Ready with confirmed zero blocking issues
  and warnings for SQL Database. Use **🟤 Ready with conditions** for blockers,
  warnings, or source `NotReady`; retain counts, affected objects and required
  remediation. Conditions must be addressed before migration; the display label
  does not remove compatibility barriers.
- Copy 🟢 (U+1F7E2) and 🟤 (U+1F7E4) exactly. Never display raw `NotReady` or
  `Not Ready` as a status. Missing, unknown or in-progress readiness is `--`
  with a reason, not Ready.
- Derive the target status from its recorded recommendation status, not from
  combined instance/database counts. Apply findings to the corresponding scope:
  server findings to Instance, each database's findings to that database. Never
  pair names and findings by array position across separate arrays.
- When both finding counts are confirmed zero, use exactly
  "No blocking issues or warnings found."
- Include user databases only. Exclude `master`, `model`, `msdb`, and `tempdb`
  from counts, readiness summaries, issue lists, and displayed database names.
- For Local JSON, set `{assessed}` to the online user-database count in
  `Servers[0].Databases[]`. List offline user databases separately. Treat an
  online database with no findings as assessed and Ready.
- For Azure, count user databases represented by the selected Suitability report
  and corresponding user-database resources.
- For Azure, classify database readiness only when assessment data
  explicitly reports that status. Do not treat missing assessment data as
  `NotReady`, and report `offline` only when the database state explicitly
  reports it.

---

## Skill Response Template

### Assessment Summary

- **SQL Server instance:** {instanceName}
- **Databases assessed:** {assessed} ({offline} offline and not assessed; omit when zero)

### Recommended Target

- **Target:** Azure SQL Database
- **Status:** {🟢 Ready | 🟤 Ready with conditions | -- with reason; omit for direct sizing without readiness}
- **Compute:** {SQL Database service tier, hardware generation and vCores | -- with reason}
- **Storage:** {SQL Database storage size and IOPS | -- with reason}
- **Estimated cost:** {<currency> <monthly total> | -- with reason}

### Migration Readiness

#### Instance

- **Status:** {🟢 Ready | 🟤 Ready with conditions | -- with reason}
- **Findings:** {No blocking issues or warnings found. | blocker and warning counts with details | -- with reason}

#### Databases

- **🟢 Ready:** {x} of {assessed} [{DB names list}]
- **🟤 Ready with conditions:** {y} of {assessed} [{For each DB: name, blockers, warnings and required changes}]
- **Not assessed:** {names and reasons for missing/unknown/in-progress data; omit when none}

Show readiness only for SQL Database. If a database list has more than 20
entries, truncate it with "...". For a direct local SKU request with no readiness
results already available, omit this entire Migration Readiness section and show
the SKU data only.

### Report

(Azure source):
[Open the assessment report](https://portal.azure.com/#resource/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.AzureArcData/SqlServerInstances/{instance}/migrationAssessment)

(Local SKU source):
- **Sizing basis:** {Configuration-based | Performance-based}
- With readiness: link the actual native `AssessmentReport-*.html` path.
- Without readiness: show actual validated SKU JSON paths and
  "Combined HTML: Not generated — readiness results were not provided."

### Suggested Follow-up Questions

- {Question based on SQL Database's actual assessment findings}
- {Question based on SQL Database's actual assessment findings}
- {Question based on SQL Database's actual assessment findings}

Keep the response within the template. Generate follow-up questions only from
SQL Database data already fetched; do not offer comparisons with other targets.

---

## Async Collection Flow (Local SKU only)

Show these templates during perf data collection lifecycle:

### Collection Started
```
SKILL: recommend-sku-sizing  |  {instanceName}
══════════════════════════════════════════════════

DATA COLLECTION STARTED
────────────────────────
  Instance:    {instanceName}
  Window:      {duration}  (started: {startTime} UTC)
  Output:      {outputFolder}

  Once collection completes, sizing for all three targets will be generated
  automatically in:

    {actual isolated run output folder}

  If readiness results are available, the combined report will also be generated;
  its exact AssessmentReport-*.html path will be available afterward.
  Otherwise, SKU results will be shown without an HTML report.

CHECK STATUS
────────────
  To check the progress of data collection at any time, say:

    "Check assessment status"
```

### Status — In Progress
```
COLLECTION STATUS  |  {instanceName}
══════════════════════════════════════════════════

COLLECTION IN PROGRESS
───────────────────────
  Elapsed:      {elapsed} of {total}
  Progress:     {percent}%
  Samples collected:  {count}
  Output folder:      {outputFolder}

  Estimated completion:  {estimatedTime} UTC

  ℹ️  Check again later or wait for the completion notification.
```

### Status — Complete
```
COLLECTION STATUS  |  {instanceName}
══════════════════════════════════════════════════

COLLECTION COMPLETE — SKU READY
────────────────────────────────
  Collection window:    {duration} (completed: {endTime} UTC)
  Samples collected:    {count}
  Combined report:      {actual native AssessmentReport-*.html path; include only when readiness is available}
  SKU results:          {actual validated SKU JSON paths; include when readiness is absent}

NEXT STEP
─────────
  Review the SKU recommendation:
    "Show SKU recommendation for {instanceName}"
```

Show Complete only after collection and three-target sizing have succeeded,
plus native combined report generation when readiness is available. Exit zero, static counter files, or a
predicted HTML filename alone do not establish success. Configuration-based
sizing does not use any of these collection templates.
