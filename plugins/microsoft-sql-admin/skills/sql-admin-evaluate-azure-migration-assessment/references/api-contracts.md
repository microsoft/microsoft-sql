# Azure Migration Assessment API Contracts

These contracts define the ARM requests, response fields, and result-processing rules. Send the requests with a public, documented, authenticated ARM client, signed in with `az login` or `Connect-AzAccount`:

- **Az PowerShell** `Invoke-AzRestMethod` (preferred: its result exposes `StatusCode`, `Headers`, and `Content`, which the telemetry step needs):

  ```powershell
  $r = Invoke-AzRestMethod -Method POST -Path "{RESOURCE_PATH}/getTelemetry?api-version=2024-05-01-preview" -Payload '{"datasetName":"MigrationAssessments"}'
  $r.StatusCode; $r.Headers; $r.Content
  Invoke-AzRestMethod -Method GET -Uri "<Azure-AsyncOperation URL>"
  ```

- **Azure CLI** `az rest` (returns only the response body and exits non-zero on HTTP errors, reporting the status in the error text; it does not show response headers):

  ```bash
  az rest --method post --url "https://management.azure.com{RESOURCE_PATH}/getJobsStatus?api-version=2025-09-01-preview" --body @body.json
  ```

  For `getTelemetry`, which returns the `Azure-AsyncOperation` URL in a response header, use `Invoke-AzRestMethod`. If Az PowerShell is not available, report that fresh telemetry cannot be retrieved with the available tools and provide the portal link.

Never acquire, print, or pass access tokens manually. Put JSON bodies in a file (`--body @body.json`) to avoid shell-quoting problems.

## Resource Path

```text
/subscriptions/{subscriptionId}/resourceGroups/{resourceGroup}/providers/Microsoft.AzureArcData/SqlServerInstances/{instanceName}
```

Construct this path once and reuse it unchanged.

## Trigger Assessment

Record `triggerRequestedAt` in UTC immediately before this call:

| Field | Value |
|---|---|
| Method | `POST` |
| Path | `{RESOURCE_PATH}/runMigrationAssessment` |
| API version | `2024-05-01-preview` |
| Body | None |
| `Content-Length` | `0` |

Treat HTTP 2xx or 409 as accepted. Report any other status and stop.

## Monitor Assessment

Request status immediately after the trigger. For a nonterminal response, wait 10 seconds before each later status request:

| Field | Value |
|---|---|
| Method | `POST` |
| Path | `{RESOURCE_PATH}/getJobsStatus` |
| API version | `2025-09-01-preview` |
| Body | `{"featureName":"MigrationAssessment"}` |

Poll up to ten times without returning to the user between attempts. In the response body `jobsStatus` array, find an entry whose `id` contains `MigrationJobOnDemand`, then read its `jobStatus`, `backgroundJob.lastExecutionTime`, and `jobException`:

- Missing, `InProgress`, or stale `Succeeded` -> continue polling.
- `Succeeded` with `backgroundJob.lastExecutionTime` later than `triggerRequestedAt` -> continue to telemetry.
- `Failed` -> report `jobException` and stop. If it is absent, state that Azure returned no failure details.
- Any other status -> treat it as nonterminal and continue polling.
- No fresh success after ten attempts -> report that assessment is still running and provide the portal link.

## Retrieve Telemetry

Start telemetry retrieval:

| Field | Value |
|---|---|
| Method | `POST` |
| Path | `{RESOURCE_PATH}/getTelemetry` |
| API version | `2024-05-01-preview` |
| Body | `{"datasetName":"MigrationAssessments"}` |

The response supplies a signed `Azure-AsyncOperation` URL. Poll that URL unchanged with `GET` and no request body until it reaches a terminal state or the execution mechanism's polling limit.

- `Failed`, `Canceled`, or `Cancelled` -> report the failure and stop.
- `Succeeded` -> decode the telemetry rows immediately.
- Polling limit reached -> report timeout and provide the portal link.

## Decode Telemetry

Read column metadata and telemetry rows from the successful terminal response's `properties.columns` and `properties.rows`.

1. Map column indexes by name and require `Type`, `ObservedTimestampUTC`, and either `Body` or `CompressedBody`.
2. Decode a resource-provider `CompressedBody` value from base64 and gzip before processing the report.
3. Parse V1 and V2 independently. Parse a non-`_V2` body as report JSON.
4. Decode the additional base64 and gzip layer in an `_V2` body, then parse the returned JSON.
5. Replace JSON `NaN` values with `null` before parsing.
6. A decode or JSON failure invalidates only that candidate. Report the diagnostic and use the other version when it is valid.
7. When both versions are valid, parse `ObservedTimestampUTC` as a date/time value. Select V2 only when it is strictly newer; otherwise select V1. Never compare timestamps as strings.

If the ARM response includes top-level `decodeErrors`, each entry's zero-based `rowIndex` identifies a row in `body.properties.rows` whose `Body` is null. Report its `message`, exclude only that candidate, and continue with valid rows. Payload-size-limit failures still stop the request rather than returning partial data.

Process these families:

- `Suitability` / `Suitability_V2`
- `SKURecommendation_AzureSQLVM` / `_V2`
- `SKURecommendation_AzureSQLMI` / `_V2`
- `SKURecommendation_AzureSQLDB` / `_V2`

A valid Suitability report is required. If neither `Suitability` nor `Suitability_V2` is valid, report the error and stop. Treat a missing or invalid individual SKU family as unavailable without stopping the other report processing.

Require Suitability `EndedOn` and each available selected SKU report's `ObservedTimestampUTC` to be later than `triggerRequestedAt`. If a selected report is stale, repeat telemetry retrieval and decoding up to three times. If any selected report remains stale, identify the stale report families and stop without combining or rendering them with ARG cost or settings data.


### Freshness and database identity

Retain the accepted trigger response's `backgroundJob.startTime` as the fallback
freshness bound when no actual UTC request timestamp is available. Do not use an
old `lastExecutionTime` as the start of a new assessment. A stale telemetry result
requires a new POST `getTelemetry` request after 10 seconds, not another GET of a
completed snapshot. Bound propagation retries to three; report unresolved
families as pending and do not render their old sizing or costs as fresh.

Each Suitability `Databases[]` record owns its `Properties.Name` and its own
`DatabaseAssessments`. Keep them together; never zip unrelated arrays or sort
names independently of their findings. Preserve the requested migration target.
