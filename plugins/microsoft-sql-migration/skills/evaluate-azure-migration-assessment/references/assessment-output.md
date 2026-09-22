# Output Format: Full Assessment (Recommended Target + SKU + Readiness)

Use this template when assessment data includes a **recommended target with SKU
sizing**, from either Azure assessment telemetry or a local SKU report.

Use the template below exactly.

---

## When to Use

| Source | Condition |
|--------|-----------|
| Azure | Fresh Suitability and SKU telemetry or existing ARG assessment data is available |
| Local SKU report | SkuRecommendationReport exists |

---

## Required Inputs

Before using this template, the calling skill must provide the readiness,
recommended target, SKU, and cost values to render. Show the portal link for
Azure or the generated report path for Local.

### Counting databases and readiness

- Include user databases only. Exclude `master`, `model`, `msdb`, and `tempdb`
  from counts, readiness summaries, issue lists, and displayed database names.
- For Local JSON, set `{assessed}` to the online user-database count in
  `Servers[0].Databases[]`. List offline user databases separately. Treat an
  online database with no findings as assessed and Ready.
- For Azure, count user databases represented by the selected Suitability report
  and corresponding user-database resources.
- For Azure, count a database as ready or not ready only when assessment data
  explicitly reports that status. Do not treat missing assessment data as
  `NotReady`, and report `offline` only when the database state explicitly
  reports it.

---

## Skill Response Template

```
SKILL: {skill-name}  |  {instanceName}
══════════════════════════════════════════════════════════════════════

Assessment Summary
──────────────────
  SQL Server Instance:   {instanceName}
  Databases assessed:    {assessed}   ({offline} offline — not assessed, omit this note if {offline} = 0)

Recommended Target
──────────────────
  {Azure SQL DB Hyperscale | Azure SQL MI | SQL Server on VM} — {vCores} vCores
  Compute configuration:  {service tier, hardware generation, and vCores or VM SKU}
  Storage configuration:  {storage size and IOPS}
  Cost:     {~${x}/month | --} ({selected cost option})

Migration Readiness (recommended target only)
───────────────────
  Instance Readiness — {Ready | Not Ready}
    Blocking issues:  {count}
    Warnings:         {count}

  Database Readiness
    {x} of {assessed} databases ready [{DB names list}]
    {z} of {assessed} databases not ready [{DB names list}]

    (If list has more than 20 databases, truncate with "...")

    Show readiness only for the recommended target above.

    For SQL Server on Azure VM, show readiness as Ready.

    For a direct local SKU request with no readiness results already in the
    conversation context, omit this Migration Readiness section.

REPORT
──────
  (Azure source):
  🔗 https://portal.azure.com/#resource/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.AzureArcData/SqlServerInstances/{instance}/migrationAssessment

  (Local SKU source):
  📄 {actual generated SKU report path}

FAQ
───
  {Generate 3-4 questions based on the actual assessment data that the user can ask as follow-ups}
```

Keep the response within the template. Generate FAQ questions only from the
assessment data already fetched.

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

  Once collection completes, SKU recommendation will be generated automatically at:

    {outputFolder}\SkuRecommendationReport-{YYYYMMDD}.html

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
  SKU report:           {outputFolder}\SkuRecommendationReport-{YYYYMMDD}.html

NEXT STEP
─────────
  Review the SKU recommendation:
    "Show SKU recommendation for {instanceName}"
```
