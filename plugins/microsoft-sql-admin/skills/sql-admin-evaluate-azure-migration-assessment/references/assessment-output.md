# Output Format: Full Assessment (Recommended Target + SKU + Readiness)

Use this template when Azure assessment data includes a **recommended target with SKU sizing**.

Use the template below exactly.

---

## When to Use

| Source | Condition |
|--------|-----------|
| Azure | Fresh Suitability and SKU telemetry or existing ARG assessment data is available |

---

## Required Inputs

Before using this template, the calling skill must provide the readiness, recommended target, SKU, and cost values to render. Show the Azure portal link.

### Counting databases and readiness

- Include user databases only. Exclude `master`, `model`, `msdb`, and `tempdb` from counts, readiness summaries, issue lists, and displayed database names.
- For Azure, count user databases represented by the selected Suitability report and corresponding user-database resources.
- For Azure, count a database as ready or not ready only when assessment data explicitly reports that status. Do not treat missing assessment data as `NotReady`, and report `offline` only when the database state explicitly reports it.

---

## Skill Response Template

```
**SKILL:** {skill-name} | **Instance:** {instanceName}

## Assessment Summary

- **SQL Server instance:** {instanceName}
- **Databases assessed:** {assessed} ({offline} offline and not assessed; omit when {offline} = 0)

## Recommended Target

- **Target:** {Azure SQL DB Hyperscale | Azure SQL MI | SQL Server on VM}
- **Compute:** {service tier, hardware generation, and vCores or VM SKU}
- **Storage:** {storage size and IOPS}
- **Estimated cost:** {~${x}/month ({selected cost option}; {currency}) for existing ARG data | ~${x}/month (fresh default estimate; for the current {preferred cost option}/AHB-adjusted cost, open the portal report) for fresh telemetry | --}

## Migration Readiness

### Instance

- **Status:** {Ready | Not Ready}
- **Blocking issues:** {count}
- **Warnings:** {count}

### Databases

- **Ready:** {x} of {assessed} [{DB names list}]
- **Not ready:** {z} of {assessed} [{DB names list}]

Show readiness only for the recommended target. For SQL Server on Azure VM,
show instance readiness as Ready. If a database list has more than 20 entries,
truncate it with "...".

## Report

[Open the assessment report](https://portal.azure.com/#resource/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.AzureArcData/SqlServerInstances/{instance}/migrationAssessment)

## Suggested Follow-up Questions

- {Question based on the actual assessment data}
- {Question based on the actual assessment data}
- {Question based on the actual assessment data}
```

Keep the response within the template. Generate FAQ questions only from the assessment data already fetched.
