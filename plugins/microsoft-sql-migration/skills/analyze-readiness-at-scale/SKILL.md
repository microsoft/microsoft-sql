---
name: analyze-readiness-at-scale
description: Use when analyzing migration assessment readiness at scale or showing an estate-wide migration assessment dashboard for Azure Arc SQL Server instances.
allowed-tools: Bash(az:*, curl:*) PowerShell Grep View
---

# Analyze Readiness at Scale

These claims were checked on 2026-09-15 against the bundled `skill-contract.yml` and referenced
Azure Resource Graph query and output contracts.

## When to Use

Use for Azure Arc SQL Server estate assessment coverage, target readiness totals, and side-by-side instance-level readiness for SQL DB, SQL MI, and SQL VM. Version and edition are optional instance filters, not default sections.

This capability is Azure-only and reads existing data through Azure Resource Graph. Do not offer a local mode or run assessments.

## Workflow

### Step 1: Resolve Dashboard Scope

Use provided subscriptions. Otherwise ask for all accessible subscriptions in
the current tenant (default) or a selected subset. Follow **Subscription Selection** in
`references/arg-queries.md` before presenting choices. Do not ask for individual instances.

When the user explicitly refers to a current Estate view and the host provides
current-view context, use its subscription scope and applicable filters. If
current-view context is unavailable, use the normal subscription-selection flow
above.

### Step 2: Run the Queries

Read `references/arg-queries.md` and `references/readiness-output.md` completely before executing queries or rendering output. If either reference cannot be read, stop instead of improvising.

For the default report, run Query 1, Query 2, and Query 3 exactly as defined in
`references/arg-queries.md`; run Query 3 once for SQL DB and once for SQL MI.
Do not run Query 4 or Query 5 unless the user requests an edition or version
filter. Do not add, remove, or normalize query conditions. Render all three
fixed-output sections in the same turn.

Define the complete KQL and invoke the provided ARG adapter in the same
PowerShell tool call because terminal state does not persist. Do not use
`az graph query` in place of the provided ARG adapter.

The default instance grid must include only fresh assessed instances. Use its
fully paginated Query 2 row count for the grid heading and pagination.

### Step 3: Render the Fixed Output

Before rendering, read the fixed output in `references/readiness-output.md` and use this exact order:

1. Readiness totals
2. Instance × SQL DB/SQL MI/SQL VM readiness grid
3. Top five recorded blockers for SQL DB and SQL MI, followed by the fixed SQL VM no-compatibility-blockers message

End with the optional version/edition filter prompt defined in the output
reference, including the option to request remediation guidance for a listed
top blocker. Do not render version or edition distributions by default.

Do not add costs, target SKUs, blocker-count status cells, warning actions,
database coverage, or recommended next steps.

The instance table columns must be exactly:

```text
SQL Server instance | SQL DB | SQL MI | SQL VM
```

The totals table columns must be exactly:

```text
Status | SQL DB | SQL MI | SQL VM
```

### Step 4: Drill Down

Use Query 4 to offer edition values and Query 5 to offer version values. Apply the selected value to Query 2 and rerender the assessed-instance grid. For one instance's detailed assessment, use `get-migration-assessment`.

When the user asks for remediation for a top blocker, read
`references/remediation-sources.md` completely before proposing guidance. Map the Query 3 `FeatureId` to
the rule title in the Microsoft Learn catalog for SQL DB or SQL MI. Return only published description, recommendation, and supporting links. Do not invent steps or imply that remediation is automated or guaranteed.

## Check it worked

- When verifying query execution, confirm the queries were executed exactly as defined in `references/arg-queries.md`.
- When verifying output, confirm the dashboard matches `references/readiness-output.md`.
- ARG pagination completed before totals were presented.
- Top blocker counts use distinct affected SQL Server instances.
- The totals use Query 1 and the readiness grid count uses Query 2.
- Every ARG request contained the intended complete KQL in the same terminal
  invocation; no state was reused from a previous invocation.
- **Cleanup verification:** Clear the in-memory ARM token and confirm no temporary request body or
  response file remains unless the user asked to retain it.

## Error Handling

- 401/403 -> verify Azure authentication and Resource Graph read permission.
- 429 -> honor `Retry-After`; report persistent throttling.
- Empty Query 1 result -> say that no fresh assessment totals are visible to
  the current Azure identity in the selected scope.
- Empty Query 2 with a non-empty Query 1 -> say that fresh assessment totals
  exist, but no instances qualify for the assessed-instance grid because that
  grid also excludes failover-cluster nodes and VM-contained resources.
- Empty results do not prove that the subscriptions contain zero Arc SQL Server
  instances.
- Partial result -> identify incomplete scope; do not present it as complete.

## References

- Open `references/arg-queries.md` before selecting subscriptions or executing ARG queries.
- Open `references/readiness-output.md` before rendering the dashboard.
- Open `references/remediation-sources.md` when the user requests blocker remediation.
