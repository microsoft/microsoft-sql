---
name: sql-admin-evaluate-azure-migration-assessment
description: "Use when the user wants to run, rerun or refresh an Azure Arc SQL Server migration assessment for fresh readiness and SKU results. To read existing results, use `sql-admin-get-migration-assessment`."
user-invocable: true
---

# Evaluate Azure Migration Assessment

## When to Use

Use for a general request to run/refresh a migration assessment for an Azure SQL Server instance.

## Required tools

- An authenticated Azure Resource Manager client for the requests in `references/api-contracts.md`: Az PowerShell [`Invoke-AzRestMethod`](https://learn.microsoft.com/powershell/module/az.accounts/invoke-azrestmethod) (needed for the telemetry step, which reads a response header) or Azure CLI [`az rest`](https://learn.microsoft.com/cli/azure/reference-index#az-rest), signed in with `Connect-AzAccount` or `az login` as an identity with the permissions listed in `references/arm-resource-identification.md`.
- Azure Resource Graph access (`az graph query` or `Search-AzGraph`) for resource discovery and the existing-assessment check.
- A shell or scripting runtime that can decode base64 and gzip for telemetry decoding.

If these are not available, give the user the requests to run and ask for the results.

## Workflow

### Step 1: Resolve the Resource

Collect subscription, resource group, and instance name using `references/arm-resource-identification.md` if not in context. Load the ARM request definitions from `references/api-contracts.md`.

When a subscription ID is available, use it directly. For an instance name without a subscription, search all accessible subscriptions with a page size of 1000 and `name =~ '{instanceName}'`; do not ask for a subscription first or add `| top` to the KQL. Continue for one match, ask for multiple matches, and report no match when none is found.

### Step 2: Check Existing Assessment

Always check for an existing assessment first for a general request such as "run migration assessment".

Use the `sql-admin-get-migration-assessment` skill with the resolved identifiers.

- Existing data and no explicit refresh request -> render it as `sql-admin-get-migration-assessment` describes for existing ARG data, then stop. Use the saved preferred option and matching `monthlyCostOptions` entry for the cost; do not label an existing-ARG amount as a fresh default estimate. State that the user can request **refresh** or **rerun** to generate a new assessment; do not ask for confirmation.
- Explicit **refresh**, **rerun**, **replace**, **new/fresh**, or ignore-existing request -> retain the returned strategy and cost-option settings, then continue to Step 3 without rendering the existing result or asking for confirmation.
- Enabled with no data -> continue to Step 3.
- Explicitly disabled -> offer ARM or portal enablement.

The word **run** by itself is not an explicit refresh request.

### Step 3: Trigger and Monitor Assessment

Retain the accepted trigger response's `backgroundJob.startTime`; use it as the freshness bound only if the actual UTC request time is unavailable. The response's `lastExecutionTime` can belong to a previous assessment and is not the new start.

Record the trigger request time and execute the trigger and job-monitoring contracts from `references/api-contracts.md`.

- 2xx or 409 -> continue.
- Other 4xx/5xx -> report the error and stop.
- `InProgress` -> you MUST continue the defined wait-and-poll loop in the same turn; NEVER ask the user whether to continue polling.
- `Succeeded` with `lastExecutionTime` later than the trigger request time -> continue to Step 4.
- `Succeeded` with an older `lastExecutionTime` -> continue polling.
- `Failed` -> show `jobException` and stop.
- Still running after the polling window -> show the portal link and stop; the user can return later to refresh.

### Step 4: Retrieve Telemetry

Execute the telemetry retrieval contract from `references/api-contracts.md` and poll the returned signed `Azure-AsyncOperation` URL as defined there.

- `Succeeded` -> decode the response.
- `Failed` or `Canceled` -> report the error.
- Timeout -> show the portal link and stop.

### Step 5: Confirm Fresh Results

Decode the portal's four telemetry report families:

- `Suitability` / `Suitability_V2`.
- `SKURecommendation_AzureSQLVM` / `_V2`.
- `SKURecommendation_AzureSQLMI` / `_V2`.
- `SKURecommendation_AzureSQLDB` / `_V2`.

Keep each Suitability `Databases[]` entry's `Properties.Name` and its own `DatabaseAssessments` together. Never join names and findings by array position or independently sorted names.

For each family, select the report with the newer telemetry `ObservedTimestampUTC`. Use Suitability for readiness and blockers, and the three SKU reports for sizing and recommendation details.

Compare the selected Suitability `EndedOn` with the trigger request time after converting both to UTC. Also require each available selected SKU report's `ObservedTimestampUTC` to be later than the trigger request time. If any selected report is stale, wait 10 seconds and POST a new getTelemetry request, then decode its new operation result, up to three retries. GET polling a completed operation only rereads the same snapshot. If freshness is still unresolved, report pending propagation without showing old sizing or cost as fresh. Use the job only for running, fresh success, and failure state.

Use the selected fresh telemetry reports as the source for readiness, blockers, target SKU, requirements, recommendation details, and available monetary cost fields. Reuse retained cost-option settings only to name the preferred option; never pair a fresh SKU with a pre-trigger cost amount.

### Step 6: Render

Use the recommended target and available default cost from the fresh telemetry selected in Step 5. Label that amount as the fresh default estimate and direct the user to the portal report for the current preferred-option and AHB-adjusted cost. This step applies only after Steps 3-5 complete a fresh assessment.

Use `references/assessment-output.md` to render the combined readiness and SKU recommendation. Include the portal report link.

## Notes

- Follow the API definitions in `references/api-contracts.md`.
- The telemetry operation URL comes from `getTelemetry`.
- Treat a successful telemetry LRO as report-read completion. Use `MigrationJobOnDemand` for assessment-job completion.
- Use `EndedOn` as the generated time.
- Use only the recommended target and user databases in output.

## References

- `references/api-contracts.md`
- `references/arm-resource-identification.md`
- `references/assessment-output.md`
