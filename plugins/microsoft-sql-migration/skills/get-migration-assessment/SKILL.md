---
name: get-migration-assessment
description: Use when retrieving existing SQL Server migration assessment data from Azure Resource Graph with the required instance-level and database-level queries.
allowed-tools: Bash(az:*, curl:*) PowerShell Grep View
---

# Get Migration Assessment

These claims were checked on 2026-09-15 against the bundled `skill-contract.yml`, Azure Resource
Graph query contract, response schema, and assessment output contract.

## When to Use

Use for existing Azure SQL Server assessment, readiness, blocker, SKU, and
cost data. This skill does not trigger a new assessment.

## Workflow

### Step 1: Resolve Inputs

Use [ARM resource identification](references/arm-resource-identification.md) when inputs are missing. Reuse identifiers
already in context. Confirm a defaulted subscription by display name and ID.

### Step 2: Query Instance Data

Build and execute the instance query from `references/arg-queries.md` when retrieving server-level data.

### Step 3: Query Database Data

When retrieving database-level data, build and execute the database query from `references/arg-queries.md` for every
returned instance.

### Step 4: Interpret Results

Use `references/response-schema.md` when interpreting results. For every `NotReady` target, identify the
server or database blocker. If blocker details are unavailable, report a data gap.

If assessment data or `assessmentUploadTime` is missing, state that no migration
assessment data is available and identify likely causes: it has not been enabled
or run, results have not uploaded, the agent is not configured, or permissions are
insufficient.

### Step 5: Render Results

Use [assessment output](references/assessment-output.md) when rendering the combined
readiness and SKU recommendation.
- Multiple instances -> show a summary table, then render each instance.

For multiple instances, include aggregate readiness, cost, and common blocker
insights when the returned data supports them.

## Check it worked

- Both query phases completed for every instance.
- Pagination completed.
- Every `NotReady` result has a cause or data-gap note.
- Missing settings or readiness are stated explicitly.
- **Cleanup verification:** Clear the in-memory ARM token and confirm no temporary request body or
  response file remains unless the user asked to retain it.

## Notes

- Use ARG as the assessment read transport.
- Execute queries through the `curl` adapter in
  `references/arg-queries.md` whenever requesting ARG data.
- Exclude `master`, `model`, `msdb`, and `tempdb`.
- Show subscription display name with its ID.
- Follow the output template exactly.

## Error Handling

- 401/403 -> verify Azure CLI login and read permission on the target scope.
- 429 -> honor `Retry-After`; report persistent throttling.
- Invalid resource URI -> show the expected Azure SQL Server instance
  resource-ID format.
- Empty result -> show the subscription display name/ID and resource group that
  were searched.

## References

- Open `references/arg-queries.md` before executing instance or database queries.
- Open `references/response-schema.md` when interpreting ARG results.
- [ARM resource identification](references/arm-resource-identification.md)
- [Assessment output](references/assessment-output.md)
