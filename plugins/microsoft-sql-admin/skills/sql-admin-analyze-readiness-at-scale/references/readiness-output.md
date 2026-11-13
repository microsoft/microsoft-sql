# Readiness at Scale Fixed Output

Render only the sections in this file and keep their order. Do not add an estate-summary table, costs, SKU recommendations, target configuration, database coverage, warning details, recommended actions, or next steps.

```text
SQL Server Migration Assessment at Scale
Scope: <All accessible enabled subscriptions | selected subscription ID[, ...]>
Generated: <UTC timestamp>
Assessment freshness: uploaded within the last 14 days
```

## 1. Readiness Totals

```text
READINESS TOTALS
```

| Status | SQL DB | SQL MI | SQL VM |
|---|---:|---:|---:|
| ✅ Ready | `<count> (<percent>)` | `<count> (<percent>)` | `<count> (<percent>)` |
| 🟤❕ Ready with Conditions | `<count> (<percent>)` | `<count> (<percent>)` | `<count> (<percent>)` |
| ❌ Not Ready | `<count> (<percent>)` | `<count> (<percent>)` | `<count> (<percent>)` |
| ❔ Unknown | `<count> (<percent>)` | `<count> (<percent>)` | `<count> (<percent>)` |
| **Total Assessed** | `<count>` | `<count>` | `<count>` |

Use each target's `Total Assessed` as its percentage denominator. The four status counts must equal `Total Assessed` for that target. Do not rename `Ready with Conditions` to `Remediable` or `Ready with Warning`.

## 2. Assessed Instance Readiness

Show the first 12 fresh assessed instances by default. Do not include unassessed, stale, or disabled inventory rows in the default grid.

```text
READINESS GRID — <Total Assessed> ASSESSED INSTANCES × 3 TARGETS
Page: <current> of <total> | Showing <first row>-<last row> of <Total Assessed>
```

| SQL Server instance | SQL DB | SQL MI | SQL VM |
|---|---|---|---|
| `<name>` | `<status>` | `<status>` | `<status>` |

Use only these visual labels:

- `✅ Ready`
- `🟤❕ Ready with Conditions`
- `❌ Not Ready`
- `❔ Unknown`
- `⏸️ Disabled`

Never display `1 blocker`, `2 blockers`, or another blocker count in place of a readiness status. Do not add version, assessed date, target SKU, blockers, warnings, database readiness, or a separate status column to this grid.

The number of distinct rows across all pages must equal `Total Assessed`. For duplicate instance names, append the subscription ID. When more than 12 assessed instances match, end with:

```text
Showing <first row>-<last row> of <Total Assessed>. Ask for the next page or narrow the scope.
```

Rows are ordered by instance name and subscription for stable paging.

## 3. Top Five Recorded Blockers

Render three tables for each target type: Example -

```text
TOP 5 RECORDED BLOCKERS ACROSS ESTATE — SQL DB
```

| Rank | Blocker | Instances |
|---:|---|---:|
| `1` | `<featureId>` | `<distinct affected instance count> / <Total Assessed>` |

Count each SQL Server instance once per blocker, even when the finding appears in multiple databases or at both server and database level. Count only current `Issue` findings for the table's target.

If no named blockers are returned and both `Ready with Conditions` and
`Not Ready` are zero, write:

```text
No current named Issue blockers were returned for <target>.
```

If no named blockers are returned, `Ready with Conditions` is greater than
zero, and `Not Ready` is zero, do not imply that the target has no assessment
findings. Write:

```text
No current named Issue blockers were returned for <target>. The <count> Ready with Conditions instances have conditional assessment findings; Warning findings are not included in the blocker ranking.
```

If the target has Not Ready instances but no named blockers, report a data gap.

## Filter Prompt

End the report with exactly:

```text
You can filter the assessed instances by a subset of subscriptions, SQL Server version, or edition, or ask for remediation guidance for a listed top blocker.
```
