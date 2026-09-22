# Database Hub operations mode

Use this mode for performance, health, issues/suggestions, and security posture.
Before issuing calls, apply the lifecycle, identity, transport, pagination,
partial-result, and read-only rules in the API contract linked directly from
`SKILL.md`.

## Contents

- [Cross-engine health workflow](#cross-engine-health-workflow)
- [Mandatory completion gates](#mandatory-completion-gates)
- [Interpret health responses](#interpret-health-responses)
- [Microsoft SQL drill-down routes](#microsoft-sql-drill-down-routes)
- [PostgreSQL drill-down routes](#postgresql-drill-down-routes)
- [Filtered health](#filtered-health)
- [Security posture workflow](#security-posture-workflow)
- [Answer the frozen request shapes](#answer-the-frozen-request-shapes)
- [Reporting contract](#reporting-contract)

## Mandatory completion gates

Broad requests must finish the required reads in the current response. Do not
offer any required route as an optional next step.

For every security-posture answer, preserve the denominator labels in the
final response, even when summarizing only percentages:

- authentication - **Azure SQL databases + Arc SQL Server**;
- auditing - **Azure SQL databases only**; and
- CMK - **Azure SQL databases only**.

Do not shorten these to unlabeled "estate" percentages.

| Request shape | Calls required before answering |
| --- | --- |
| performance or health "across my estate" | SQL health, PostgreSQL health, and fully paged Cosmos health |
| security fixes across databases | security issues + suggestions summaries, then auth + auditing + CMK counts |
| CPU across databases | SQL health + PostgreSQL health; state that Cosmos CPU is unavailable |
| **all** issues and suggestions | SQL + PostgreSQL + fully paged Cosmos health, security issues + suggestions summaries, and auth + auditing + CMK counts |

For every fully paged Cosmos workflow:

- use filtered POST with `pageSize: 300`;
- pin one `startTime` and `endTime` across every page;
- continue until `continuationToken` is absent;
- compare summed `processedAccounts` with `totalAccounts`; and
- emit the across-page minimum availability and maximum normalized RU in the
  tool result before using either value in the answer.

If processed and total counts differ, label Cosmos coverage partial or
inconsistent. Never report complete coverage from a non-null continuation token
or mismatched counts. The final answer must state both the processed and total
account counts; reporting only the page count or `resourcesWithData` is
insufficient.

Do not answer a broad performance or all-findings request until the compact
Cosmos tool result contains `minimumServiceAvailability`,
`maximumNormalizedRu`, `processedAccounts`, and `totalAccounts`. If an
asynchronous command has not emitted all four fields, read its completion result
or rerun the bounded read. Counts alone do not prove Cosmos health.

Choose one completed compact aggregate as the source of truth for the final
coverage pair. Report that aggregate's exact `processedAccounts` and
`totalAccounts`; do not combine counts from earlier retries or page snapshots
into a range such as "depending on pass." If earlier calls drifted, disclose
that separately from the selected aggregate.

## Cross-engine health workflow

For an estate-wide performance question, call all three engine families. These
contracts are intentionally different; do not merge them into a fabricated
common metric.

| Family | Method and route | Current metrics |
| --- | --- | --- |
| Microsoft SQL | GET `/health/v2/summary` | CPU, storage, memory |
| PostgreSQL Flexible Server | GET `/postgreSql/health/v2/summary` | CPU, storage, memory |
| Cosmos DB | GET or filtered POST `/cosmosDb/health/summary` | minimum service availability, maximum normalized RU consumption |

The health defaults are the previous 24 hours, hourly granularity, and maximum
aggregation. Prefer explicit UTC `StartTime`, `EndTime`, `Granularity`, and
`AggregationType` when the user supplies a timeframe or comparison intent.
Health windows must be 31 days or less.

```powershell
$dbhBase = "https://api.fabric.microsoft.com/v1/databasehub/__private"
$sqlRaw = az rest --method get --resource "https://api.fabric.microsoft.com" `
  --url "$dbhBase/health/v2/summary" `
  --headers "x-ms-fabric-skill=databasehub-cli" | ConvertFrom-Json
$postgresRaw = az rest --method get --resource "https://api.fabric.microsoft.com" `
  --url "$dbhBase/postgreSql/health/v2/summary" `
  --headers "x-ms-fabric-skill=databasehub-cli" | ConvertFrom-Json
@{
  sql = $sqlRaw | Select-Object startTime,endTime,granularity,totalDatabases,
    usageCounts,performanceIssueSummary,performanceEnhancementSummary,coverage,errors
  postgresql = $postgresRaw | Select-Object startTime,endTime,granularity,totalDatabases,
    usageCounts,performanceIssueSummary,performanceEnhancementSummary,coverage,errors
} | ConvertTo-Json -Depth 12
```

For an estate-wide Cosmos query, use the file-based POST pattern with
`overviewFilters: {}` and `pageSize: 300`. Repeat the POST with the same body
plus each returned `continuationToken` until the token is absent. Never answer a
cross-estate question from the first account page alone; the GET form is only
suitable for an explicitly requested first-page sample. Keep all page responses
and emit a compact JSON summary from the tool call so the final answer remains
grounded in `totalAccounts`, `processedAccounts`, `resourcesWithData`,
availability, RU, and errors. A normalized RU peak can indicate saturation, but
does not prove that requests were throttled.

```powershell
$cosmosPages = @()
$continuationToken = $null
$endTime = (Get-Date).ToUniversalTime()
$startTime = $endTime.AddHours(-24)
$bodyPath = Join-Path $env:TEMP (
  "databasehub-cosmos-health-{0}.json" -f [guid]::NewGuid().ToString("N"))
try {
  do {
    $body = @{
      startTime = $startTime.ToString("o")
      endTime = $endTime.ToString("o")
      granularity = "PT1H"
      overviewFilters = @{}
      pageSize = 300
    }
    if ($continuationToken) { $body.continuationToken = $continuationToken }
    [IO.File]::WriteAllText($bodyPath, ($body | ConvertTo-Json -Depth 20),
      [Text.UTF8Encoding]::new($false))
    $page = az rest --method post --resource "https://api.fabric.microsoft.com" `
      --url "$dbhBase/cosmosDb/health/summary" `
      --headers "x-ms-fabric-skill=databasehub-cli" "Content-Type=application/json" `
      --body "@$bodyPath" | ConvertFrom-Json
    $cosmosPages += $page
    $continuationToken = $page.continuationToken
  } while ($continuationToken)
} finally {
  Remove-Item -LiteralPath $bodyPath -ErrorAction SilentlyContinue
}
$availabilityPoints = @($cosmosPages | ForEach-Object { $_.serviceAvailability })
$ruPoints = @($cosmosPages | ForEach-Object { $_.normalizedRuConsumption })
$minimumAvailability = if ($availabilityPoints.Count -gt 0) {
  ($availabilityPoints | Measure-Object value -Minimum).Minimum
} else {
  $null
}
$maximumNormalizedRu = if ($ruPoints.Count -gt 0) {
  ($ruPoints | Measure-Object value -Maximum).Maximum
} else {
  $null
}
Write-Output "=== COSMOS SUMMARY ==="
@{
  pageCount = $cosmosPages.Count
  finalContinuationToken = $continuationToken
  totalAccounts = $cosmosPages[0].totalAccounts
  processedAccounts = ($cosmosPages | Measure-Object processedAccounts -Sum).Sum
  resourcesWithData = ($cosmosPages | Measure-Object resourcesWithData -Sum).Sum
  minimumServiceAvailability = $minimumAvailability
  maximumNormalizedRu = $maximumNormalizedRu
  errors = @($cosmosPages | ForEach-Object { $_.errors } | Where-Object { $_ })
} | ConvertTo-Json -Depth 10
```

Do not state an availability or RU value unless that compact aggregate appeared
in the tool result. If `resourcesWithData` is `0` and both aggregate values are
`null`, report that no Cosmos metric points were available; do not substitute
zero-percent availability or RU. Aggregate across **all** pages, not only the
last page. `finalContinuationToken` must be `null`; otherwise paging did not
reach a terminal response and the result is incomplete. Do not replace the
compact aggregate with a raw-page sample. It must retain all seven keys:
`pageCount`, `finalContinuationToken`, `totalAccounts`, `processedAccounts`,
`resourcesWithData`, `minimumServiceAvailability`, and `maximumNormalizedRu`.

## Interpret health responses

### Microsoft SQL and PostgreSQL

Both response shapes include:

- `startTime`, `endTime`, and `granularity`;
- `totalDatabases`;
- `series[]` keyed by `metricType`, with peak usage data over time;
- `usageCounts[]`;
- optional `coverage`;
- optional `continuationToken` for filtered calls; and
- `errors[]`.

For these health responses, CLI JSON can serialize `metricType` numerically.
Map the value explicitly: `0` = CPU, `1` = storage, and `2` = memory. Do not
infer metric identity from array position, and do not swap storage and memory.

Microsoft SQL populates both `highCount` and `lowCount`, plus
`performanceIssueSummary` and `performanceEnhancementSummary`. Its high bucket
is 90% or above. The summary `lowCount` includes 10% (`<= 10%`), while
`UsageLevel=Low` usage details use `< 10%`; the two counts can therefore differ
for resources whose peak is exactly 10%.

PostgreSQL summary semantics differ: only `highCount` is populated;
`lowCount` is always `0`, and both performance summary objects remain `null`.
Do not report `lowCount: 0` as evidence that no PostgreSQL server is
underutilized. A PostgreSQL `UsageLevel=Low` usage-details request performs the
actual low-usage selection at 10% or below. Prefer returned classifications
over recalculating them; usage-detail routes return named resources and
`dailyMaxUsagePercentage`.

PostgreSQL metrics come through Azure Monitor. Missing Monitoring Reader access
can produce partial coverage. Report `permissionDeniedResources`,
`resourcesWithData`, `partitionsFailed`, `metricsFailed`, and `errors` rather
than describing missing data as healthy.

### Cosmos DB

The response includes `totalAccounts`, `processedAccounts`,
`resourcesWithData`, `serviceAvailability[]`,
`normalizedRuConsumption[]`, `continuationToken`, and `errors`.

State explicitly:

- availability is the minimum service availability signal;
- RU is maximum normalized RU consumption; and
- this contract does not expose CPU, memory, storage, latency,
  throttled-request counts, or arbitrary metric history.

Do not describe a 100% normalized RU value as evidence of throttling. State only
that provisioned throughput was fully consumed at the reported peak; proving
throttling requires a separate throttled-request metric that this contract does
not return.

## Microsoft SQL drill-down routes

| Method | Relative route | Key request fields | Use |
| --- | --- | --- | --- |
| GET | `/health/v2/usage-details` | `MetricType`, `UsageLevel`, time range, `Granularity`, `DatabaseType?`, `AggregationType` | named high/low usage resources |
| GET | `/health/critical` | time range, `Granularity`, `DatabaseType?`, `AggregationType` | resources classified as critical |
| GET | `/health/monitored` | time range, repeated `DatabaseTypes?`, `Top?`, `ContinuationToken?`, `CheckPermission?` | SQL/Arc resources sending telemetry |
| GET | `/health/database/metrics/{encodedResourceId}` | `MetricType`, time range, `Granularity`, optional `ResourceName` | one SQL/Arc resource time series |

For SQL health, omit `DatabaseType` to cover Azure SQL and Arc SQL Server, or
use `AzureSql` / `ArcSqlServer` to narrow. Do not pass PostgreSQL to this route;
use the PostgreSQL route family. Do not label these health metrics as covering
Azure SQL Managed Instance, SQL Server on Azure VM, logical servers, or elastic
pools; those resource types can appear in inventory/security findings but are
outside this health route's default metric population.

Valid `MetricType` values for drill-down are `Cpu`, `Storage`, and `Memory`.
Valid `UsageLevel` values are `High` and `Low`.

URL-encode the full resource ID for the per-resource route. For Arc machines
with multiple instances, preserve the returned `ResourceName` when supplied.

## PostgreSQL drill-down routes

| Method | Relative route | Key request fields | Use |
| --- | --- | --- | --- |
| GET | `/postgreSql/health/v2/usage-details` | `MetricType`, `UsageLevel`, time range, `Granularity`, `AggregationType` | named high/low PostgreSQL servers |

The PostgreSQL route has no `DatabaseType` parameter. Do not copy a SQL request
body or query string onto it.

## Filtered health

Use filtered POST routes when the user supplies a saved-view/filter scope.
Estate-wide Cosmos health is the explicit exception: use its filtered POST with
`overviewFilters: {}` and `pageSize: 300` even when the user supplied no filter.

- `/health/v2/filtered-summary`
- `/health/v2/filtered-usage-details`
- `/postgreSql/health/v2/summary`
- `/postgreSql/health/v2/usage-details`
- `/cosmosDb/health/summary`

Filtered bodies require the same immutable `overviewFilters` snapshot used by
inventory, `pageSize` 1-300, and a matching `continuationToken`.

When comparing a plain SQL summary, filtered usage details, and a filtered SQL
summary, pin the same `StartTime`, `EndTime`, `Granularity`, and
`AggregationType` on all three. If `overviewFilters.databaseTypes` is
`AzureSql`, also set `DatabaseType=AzureSql` on the plain summary. Send the same
`overviewFilters` snapshot to both filtered POSTs and apply the requested row
bound with `pageSize` on `/health/v2/filtered-usage-details` (for example,
`pageSize: 20`). GET `/health/v2/usage-details` has no `Top` parameter; if you
use that unfiltered route elsewhere, any presentation limit is a disclosed
client-side truncation. Never compare an unfiltered SQL/Arc denominator with an
Azure-SQL-only filtered population.

When the three requests use separate shell tool calls, compute the window once
and copy the exact UTC `StartTime` and `EndTime` strings into every later call.
Do not run `Get-Date` again in each shell call; even a few seconds of drift means
the responses are not the same snapshot.

Prefer three separate shell tool calls and emit a typed result for each. If two
or more requests share one shell call, label every included output section
`SQL SUMMARY`, `USAGE DETAILS`, or `FILTERED SUMMARY`, echo the pinned window,
and preserve response `startTime`, `endTime`, and `granularity` so each result
remains correlated.

- SQL/PostgreSQL/Cosmos filtered **summary** bodies can include `category`
  (`security` or `performance`) and `relevance` (`issues` or `suggestions`).
- PostgreSQL filtered **usage-details** can also include `category` and
  `relevance`.
- SQL `/health/v2/filtered-usage-details` does **not** define those two fields;
  send only metric, usage level, time, aggregation, filters, paging, and token.

Use the file-based POST pattern from the shared API reference.

## Security posture workflow

1. Read both overview summaries:
   - `/overviewFindings/security/issues/summaries`
   - `/overviewFindings/security/suggestions/summaries`
2. Read the three posture counts:
   - `/auth/counts` - Azure SQL databases plus Arc SQL Server;
   - `/auditing/counts` - Azure SQL databases only;
   - `/cmk/counts` - Azure SQL databases only.
3. If a count is non-zero and named resources are needed, page the matching
   warning route with `top` and `continuationToken`:
   - `/auth/warnings`
   - `/auditing/warnings`
   - `/cmk/warnings`
4. Rank actual `issues` before `suggestions`; within each, use affected-resource
   count, blast radius, returned reason, and the user's stated priorities.
5. Recommend actions only. Do not remediate.

```powershell
foreach ($route in "auth/counts", "auditing/counts", "cmk/counts") {
  az rest --method get `
    --resource "https://api.fabric.microsoft.com" `
    --url "$dbhBase/$route" `
    --headers "x-ms-fabric-skill=databasehub-cli"
}
```

Do not print the full overview `targetSummaries` for a posture overview. Project
each family to `databaseFamily`, `totalFindingCount`,
`totalAffectedResourceCount`, `postureAffectedResourceCount`,
`affectedResourceCounts`, and `errors`; then emit the three posture count
objects separately so `entraIdOnlyCount`, `auditingEnabledCount`, and
`cmkEnabledCount` remain visible in the tool result.

Count response fields and denominators:

| Area | Scope | Fields |
| --- | --- | --- |
| Authentication | Azure SQL databases + Arc SQL Server | `totalDatabases`, `entraIdOnlyCount`, `entraIdWithSqlAuthCount`, `sqlAuthOnlyCount`, `unknownCount`, `percentageEntraIdEnabled` |
| Auditing | Azure SQL databases only | `totalDatabases`, `auditingEnabledCount`, `auditingDisabledCount`, `percentageAuditingEnabled` |
| CMK | Azure SQL databases only | `totalDatabases`, `cmkEnabledCount`, `cmkDisabledCount`, `percentageCmkEnabled` |

Warning pages return `items[]`, `totalWarningCount`, `hasMore`, and
`continuationToken`. Items include `name`, `type`, `serverName`, `resourceId`,
the posture state, and an optional `reason`. Their scopes match the
corresponding count route; do not label these warning totals as PostgreSQL,
Cosmos DB, managed-instance, SQL VM, or whole-estate coverage.

## Answer the frozen request shapes

| Request shape | Required evidence |
| --- | --- |
| performance issues across the estate | three health summaries, finding counts, high-usage drill-down where material, timeframe, and partial coverage |
| how databases are performing | separate Microsoft SQL, PostgreSQL, and Cosmos sections; do not substitute Cosmos RU for CPU |
| what to fix first for security | security issue/suggestion summaries plus auth/auditing/CMK counts and warning resources |
| recent CPU consumption | Microsoft SQL and PostgreSQL CPU evidence plus an explicit Cosmos CPU limitation |
| all issues and suggestions | health issue/enhancement summaries plus security issue/suggestion summaries; use performance usage-details, posture warning routes, and specialized inventory flags for named resources |

## Reporting contract

- Lead with material findings, not raw JSON.
- State scope, timeframe, aggregation, and pagination completeness.
- Separate **issue instances**, **affected resources**, and **inventory totals**.
- Label auth, auditing, and CMK denominators with their exact SQL/Arc scopes;
  cross-family overview summaries provide the broader PostgreSQL/Cosmos view.
- For each family, say whether data is complete, partial, unavailable, or empty.
- For Cosmos, report both `processedAccounts` and `totalAccounts`. Call coverage
  complete only when the token is absent and the processed total matches.
- Preserve returned resource names/types and include resource IDs only when
  needed for disambiguation or requested export.
- If every call succeeds but no resources are returned, report "no matching
  resources in the authorized scope," not "the estate is healthy."
- If a write is requested, state that this skill is read-only and identify the
  owning item skill or product workflow; do not execute the change.
