---
name: sql-admin-get-migration-assessment
description: "Use when the user asks about existing Azure Arc SQL Server migration assessment results (readiness, SKUs, costs), including supplied JSON. For a new run, use `sql-admin-evaluate-azure-migration-assessment`."
user-invocable: true
---

# Get Migration Assessment

## When to Use

Use for existing Azure SQL Server assessment, readiness, blocker, SKU, and cost data. This includes generic requests such as "show my existing migration assessment results." This skill does not trigger a new assessment.

## Scope

- Reads or interprets existing results only, including saved-option pricing and AHB/dev-test cost arithmetic. Do not refresh or rerun an assessment unless the user asks; that is `sql-admin-evaluate-azure-migration-assessment`.
- For estate-wide totals across many instances, use `sql-admin-analyze-readiness-at-scale`.

## Supplied results versus retrieval

When assessment JSON or saved pricing fields are already supplied, interpret that
evidence directly. For saved-option cost arithmetic, read
`references/response-schema.md`: the selected compute/storage/IOPS option and
the SQL license component are separate, and AHB/dev-test settings determine
whether to include the license. Do not require an instance identifier, sign in,
query Azure, or refresh an assessment just to interpret supplied data. Report
missing inputs explicitly; an incomplete estimate is not a zero-cost component.
Preserve the requested target and response format. The retrieval steps below
apply only when the requested evidence is not already provided.

## Required tools (retrieval only)

- Azure Resource Graph access through [Azure CLI](https://learn.microsoft.com/cli/azure/graph) (`az graph query`, `resource-graph` extension), [Az PowerShell](https://learn.microsoft.com/powershell/module/az.resourcegraph/search-azgraph) (`Search-AzGraph`), or the Resource Graph REST API via `az rest`, signed in with `az login` or `Connect-AzAccount` as an identity with read access to the target scope. If none is available, give the user the commands and KQL to run and ask for the results.

## Workflow

### Step 1: Resolve Inputs

Use `references/arm-resource-identification.md`. Reuse identifiers already in context.

Before running any command, require an instance name, full instance resource ID, or context that resolves one specific instance. If none is available, ask which SQL Server instance the user wants and stop. Do not query all assessments or return an estate-wide summary.

For an instance name without a subscription, search all accessible subscriptions with `name =~ '{instanceName}'` and a page size of 1000; do not ask for a subscription first. Continue for one match, ask for multiple matches, and report no match when none is found.

### Step 2: Query Instance Data

Build and execute the instance query from `references/arg-queries.md`.

### Step 3: Query Database Data

Build and execute the database query from `references/arg-queries.md` for every returned instance.

### Step 4: Interpret Results

Use `references/response-schema.md`. For every `NotReady` target, identify the server or database blocker. If blocker details are unavailable, report a data gap.

If assessment data or `assessmentUploadTime` is missing, state that no migration assessment data is available and identify likely causes: it has not been enabled or run, results have not uploaded, the agent is not configured, or permissions are insufficient.

For SQL DB pricing, use the database-level saved-option calculation in `references/response-schema.md`; do not substitute default totals or require instance-level SQL DB pricing fields. Preserve the user's requested target and identify missing data before presenting a total.

### Step 5: Render Results

Use `references/assessment-output.md` to render the combined readiness and SKU recommendation.

- Multiple instances -> show a summary table, then render each instance.

For multiple instances, include aggregate readiness, cost, and common blocker insights when the returned data supports them.

## Completion Check

- Supplied-only mode: interpretation uses the provided evidence; no retrieval or refresh was performed.
- Retrieval mode: both query phases completed for every instance.
- Pagination completed.
- Every `NotReady` result has a cause or data-gap note.
- Missing settings or readiness are stated explicitly.

## Notes

- Use Azure Resource Graph (see `references/arg-queries.md`) as the only assessment read transport.
- Do not list subscriptions when a subscription ID is already available.
- For instance-name-only requests, search all accessible subscription IDs through the selected public client; never pass a literal pseudo-ID such as `all` to Azure Resource Graph.
- Exclude `master`, `model`, `msdb`, and `tempdb`.
- Show the subscription ID. Include its display name only when it is already available in context.
- Follow the output template exactly.

## Error Handling

- 401/403 -> verify the signed-in identity has read permission on the target scope.
- 429 -> honor `Retry-After`; report persistent throttling.
- Invalid resource URI -> show the expected Azure SQL Server instance resource-ID format.
- Empty result -> show the subscription ID and resource group that were searched.

## References

- `references/arg-queries.md`
- `references/response-schema.md`
- `references/arm-resource-identification.md`
- `references/assessment-output.md`
