---
name: sql-admin-analyze-readiness-at-scale
description: "Use only when the user asks for estate-wide migration readiness across many Azure Arc SQL Server instances: dashboards, totals, coverage. For one instance or generic results, use `sql-admin-get-migration-assessment`."
user-invocable: true
---

# Analyze Readiness at Scale

## When to Use

Use for Azure Arc SQL Server estate assessment coverage, target readiness totals, and side-by-side instance-level readiness for SQL DB, SQL MI, and SQL VM. Version and edition are optional instance filters, not default sections.

This capability is Azure-only and reads existing data through Azure Resource Graph. Do not offer a local mode or run assessments.

## Required tools

- Azure Resource Graph access through [Azure CLI](https://learn.microsoft.com/cli/azure/graph) (`az graph query`, `resource-graph` extension), [Az PowerShell](https://learn.microsoft.com/powershell/module/az.resourcegraph/search-azgraph) (`Search-AzGraph`), or the Resource Graph REST API via `az rest`, signed in with `az login` or `Connect-AzAccount` as an identity with Reader access to the target subscriptions. If none is available, give the user the commands and KQL to run and ask for the results.
- A web fetch tool, only when the user asks for remediation guidance (to read the Microsoft Learn rule catalog).

## Workflow

### Step 1: Resolve Dashboard Scope

Use subscription IDs supplied by the user or already present in the host context. If none are available, default to all accessible enabled subscriptions. Follow **Subscription Selection** in `references/arg-queries.md`. Do not ask for individual instances.

### Step 2: Run the Queries

Read `references/arg-queries.md` and `references/readiness-output.md` completely before executing queries or rendering output. If either reference cannot be read, stop instead of improvising.

For the default report, run Query 1, Query 2, and Query 3 exactly once as defined in `references/arg-queries.md`. Do not run Query 4 or Query 5 unless the user requests an edition or version filter. Do not add, remove, or normalize query conditions. Render all three fixed-output sections in the same turn.

Define the complete KQL and run it against Azure Resource Graph with the selected subscription IDs, as described in **Running Azure Resource Graph Queries** in `references/arg-queries.md`. Complete pagination for the totals and blocker queries before rendering. For the assessed-instance grid, retrieve only the requested 12-row page and retain its skip token for the next-page request.

The default instance grid must include only fresh assessed instances. Show `min(12, TotalAssessed)` rows on the first page; the distinct rows across all grid pages must equal `TotalAssessed`.

### Step 3: Render the Fixed Output

Render only the fixed output defined in `references/readiness-output.md`, in this exact order:

1. Readiness totals
2. Instance × SQL DB/SQL MI/SQL VM readiness grid
3. Top five recorded blockers for SQL DB, SQL MI, and SQL VM

End with the optional version/edition filter prompt defined in the output reference, including the option to request remediation guidance for a listed top blocker. Do not render version or edition distributions by default.

Do not add costs, target SKUs, blocker-count status cells, warning actions, database coverage, or recommended next steps.

The instance table columns must be exactly:

```text
SQL Server instance | SQL DB | SQL MI | SQL VM
```

The totals table columns must be exactly:

```text
Status | SQL DB | SQL MI | SQL VM
```

### Step 4: Drill Down

Use Query 4 to offer edition values and Query 5 to offer version values. Apply the selected value to Query 2 and rerender the assessed-instance grid. For one instance's detailed assessment, use the `sql-admin-get-migration-assessment` skill.

When the user asks for remediation for a top blocker, read `references/remediation-sources.md` completely. Map the Query 3 `FeatureId` to the rule title in the Microsoft Learn catalog for that target. Return only the published description, recommendation, and supporting links. Use Query 3 `MoreInformation` as an additional source when it is populated. Do not invent steps or imply that remediation is automated or guaranteed.

## Completion Check

- Query execution followed `references/arg-queries.md` without modification.
- Output followed `references/readiness-output.md`.
- Totals and blocker-query pagination completed before results were presented.
- Top blocker counts use distinct affected SQL Server instances.
- The default readiness grid contains exactly `min(12, TotalAssessed)` instances, with later pages retrieved only when requested.
- Every ARG request contained the intended complete KQL.

## Error Handling

- 401/403 -> verify Azure authentication and Resource Graph read permission.
- 429 -> honor `Retry-After`; report persistent throttling.
- Empty Query 1/Query 2 result -> say that no fresh assessed instances are visible to the current Azure identity in the selected scope. These queries do not prove that the subscriptions contain zero Arc SQL Server instances.
- Partial result -> identify incomplete scope; do not present it as complete.

## References

- `references/arg-queries.md`
- `references/readiness-output.md`
- `references/remediation-sources.md`
