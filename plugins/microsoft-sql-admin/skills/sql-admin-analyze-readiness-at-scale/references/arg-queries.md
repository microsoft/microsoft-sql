# Readiness at Scale ARG Queries

## Running Azure Resource Graph Queries

Run every query against Azure Resource Graph (ARG) with one of these public, documented options,
signed in with `az login` (Azure CLI) or `Connect-AzAccount` (Az PowerShell):

- **Azure CLI** (`resource-graph` extension; install once with `az extension add --name resource-graph`):

  ```bash
  az graph query -q "$(cat query.kql)" --subscriptions <subId1> <subId2> --first 1000 -o json
  # next page: add --skip-token "<skip_token from the previous response>"
  ```

- **Az PowerShell** (`Az.ResourceGraph` module):

  ```powershell
  Search-AzGraph -Query (Get-Content query.kql -Raw) -Subscription $subscriptionIds -First 1000
  # next page: add -SkipToken $previousResult.SkipToken
  ```

- **REST API** through `az rest` (the request body carries the KQL, which avoids shell quoting):

  ```bash
  az rest --method post \
    --url "https://management.azure.com/providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01" \
    --body @request.json
  # request.json: {"subscriptions": ["<subId1>"], "query": "<KQL>", "options": {"$top": 1000, "$skipToken": "<token or omit>"}}
  ```

Settings for every query:

- Subscriptions: Selected subscription IDs
- Query: Complete KQL text. Save it to a file and pass the file contents; the KQL contains double
  quotes that shells can mangle when passed inline.
- Page size: `1000` for aggregate queries; `12` for Query 2
- Pagination: no skip token for the first page. Complete all pages for aggregate queries. For Query 2, retain the returned token and use it only when the user requests the next grid page.
- **Assessment freshness:** `14d`
- **Displayed drill-down page size:** `12`

## Subscription Selection

Readiness at scale is Azure-only. Do not offer a local source option.

Use subscription IDs supplied by the user directly. When no scope is provided, list enabled subscriptions with `az account list --query "[?state=='Enabled'].{subscriptionId:id, displayName:name, tenantId:tenantId}" -o json` (or `Get-AzSubscription | Where-Object State -eq 'Enabled' | Select-Object Id, Name, TenantId`) and use all returned IDs without asking for confirmation. Resolve display names only when the user explicitly requests a subset; ask the user to choose only when a name is ambiguous.

Do not print the complete subscription result. Use the selector below only when the user explicitly requests selected subscriptions.

For selected subscriptions, use a text-based paginated selector:

1. Sort by display name and subscription ID, then assign stable global numbers.
2. Show 10 rows per page with number, display name, and subscription ID.
3. Accept multiple comma-separated global numbers or subscription IDs in one response.
4. Accept `next`, `previous`, `search <name-or-id>`, and `done`.
5. Preserve selected subscriptions across pages and searches.
6. After each response, show the current selected names and IDs.
7. Reject invalid entries explicitly without discarding valid selections.
8. Continue until the user enters `done`.

Do not show hundreds of subscriptions in one table. Do not force one subscription selection per prompt. Resolve the final selections to subscription IDs and use the same IDs in every dashboard and grid query.

## Scope Filters

Use the native ARG `resourceGroup` column; do not overwrite it with a case-sensitive regular-expression extraction from the resource ID.

Append this block before the final projection or summarization in each query:

```kql
| extend subscriptionId = extract(@"/subscriptions/([^/]+)", 1, id)
| where subscriptionId in ('{subscriptionId1}', '{subscriptionId2}')
    and resourceGroup in ('{resourceGroup1}', '{resourceGroup2}')
    and location in ('{location1}', '{location2}')
```

Include only conditions for filters that have values. Escape single quotes.

## Query 1: Readiness Totals

```kql
resources
| where type == 'microsoft.azurearcdata/sqlserverinstances'
| where properties.migration.assessment.assessmentUploadTime > ago(14d)
    and (
        properties.migration.assessment.enabled == true
        or isnull(properties.migration.assessment.enabled))
    and isnotnull(parse_json(properties.migration.assessment.skuRecommendationResults))
| extend azureSqlDatabaseRecommendationStatus =
    tostring(properties.migration.assessment.skuRecommendationResults.azureSqlDatabase.recommendationStatus)
| extend azureSqlManagedInstanceRecommendationStatus =
    tostring(properties.migration.assessment.skuRecommendationResults.azureSqlManagedInstance.recommendationStatus)
| extend azureSqlVirtualMachineRecommendationStatus =
    tostring(properties.migration.assessment.skuRecommendationResults.azureSqlVirtualMachine.recommendationStatus)
| extend serverAssessments = tostring(properties.migration.assessment.serverAssessments)
| extend subscriptionId = extract(@"/subscriptions/([^/]+)", 1, id)
// Insert requested subscription, resource-group, and location conditions here.
| mv-expand platformStatus = pack_array(
    pack(
        "platform",
        "Azure SQL Database",
        "status",
        azureSqlDatabaseRecommendationStatus),
    pack(
        "platform",
        "Azure SQL Managed Instance",
        "status",
        azureSqlManagedInstanceRecommendationStatus),
    pack(
        "platform",
        "Azure SQL Virtual Machine",
        "status",
        azureSqlVirtualMachineRecommendationStatus))
| extend platformToken =
    replace(" ", "", tolower(tostring(platformStatus["platform"])))
| extend platformHasIssues =
    tolower(serverAssessments) has platformToken
| project
    Platform = tostring(platformStatus["platform"]),
    status = tostring(platformStatus["status"]),
    tostring(serverAssessments),
    id,
    platformHasIssues
| extend finalStatus = case(
    status == "Ready" and platformHasIssues, "Ready with Conditions",
    status == "Ready", "Ready",
    status == "NotReady", "NotReady",
    isnull(status)
        or status !in ("Ready", "NotReady", "Ready with Conditions"), "Unknown",
    "Unknown")
| summarize
    TotalAssessed = count(),
    Ready = countif(finalStatus == "Ready"),
    NotReady = countif(finalStatus == "NotReady"),
    ReadyWithConditions = countif(finalStatus == "Ready with Conditions"),
    Unknown = countif(finalStatus == "Unknown")
    by Platform
```

All target rows must have the same `TotalAssessed`. Report inconsistent data instead of rendering totals when they differ.

## Query 2: Instance Readiness

Run without an edition or version condition for the default readiness grid.

```kql
resources
| where type == 'microsoft.azurearcdata/sqlserverinstances'
| extend
    alwaysOnRole = properties.alwaysOnRole,
    version = properties.version,
    edition = properties.edition,
    sqlInstance = properties.instanceName,
    serviceType = properties.serviceType
| where alwaysOnRole != 'FailoverClusterNode'
| where properties.containerResourceId !contains 'Microsoft.Compute/virtualMachines'
| extend assessmentEnabled = coalesce(tobool(properties.migration.assessment.enabled), true)
| extend assessmentUploadTime =
    todatetime(properties.migration.assessment.assessmentUploadTime)
| extend azureSqlDatabaseRecommendationStatus =
    tostring(properties.migration.assessment.skuRecommendationResults.azureSqlDatabase.recommendationStatus)
| extend azureSqlManagedInstanceRecommendationStatus =
    tostring(properties.migration.assessment.skuRecommendationResults.azureSqlManagedInstance.recommendationStatus)
| extend azureSqlVirtualMachineRecommendationStatus =
    tostring(properties.migration.assessment.skuRecommendationResults.azureSqlVirtualMachine.recommendationStatus)
| extend serverAssessments = tostring(properties.migration.assessment.serverAssessments)
| extend sqlDBInWarnings =
    tolower(serverAssessments) has "azuresqldatabase"
| extend sqlMIInWarnings =
    tolower(serverAssessments) has "azuresqlmanagedinstance"
| extend sqlVMInWarnings =
    tolower(serverAssessments) has "azuresqlvirtualmachine"
| extend migrationAssessed = case(
    assessmentUploadTime > ago(14d)
        and assessmentEnabled == true
        and isnotnull(parse_json(properties.migration.assessment.skuRecommendationResults)),
    "Assessed",
    "Not Assessed")
| where migrationAssessed == "Assessed"
| extend miReadiness = case(
    assessmentEnabled == false, "Disabled",
    assessmentUploadTime < ago(14d), "Unknown",
    azureSqlManagedInstanceRecommendationStatus == "Ready" and sqlMIInWarnings,
        "Ready with Conditions",
    azureSqlManagedInstanceRecommendationStatus == "Ready", "Ready",
    azureSqlManagedInstanceRecommendationStatus == "NotReady", "NotReady",
    isnull(azureSqlManagedInstanceRecommendationStatus)
        or azureSqlManagedInstanceRecommendationStatus
            !in ("Ready", "NotReady", "Ready with Conditions"), "Unknown",
    "Unknown")
| extend dbReadiness = case(
    assessmentEnabled == false, "Disabled",
    assessmentUploadTime < ago(14d), "Unknown",
    azureSqlDatabaseRecommendationStatus == "Ready" and sqlDBInWarnings,
        "Ready with Conditions",
    azureSqlDatabaseRecommendationStatus == "Ready", "Ready",
    azureSqlDatabaseRecommendationStatus == "NotReady", "NotReady",
    isnull(azureSqlDatabaseRecommendationStatus)
        or azureSqlDatabaseRecommendationStatus
            !in ("Ready", "NotReady", "Ready with Conditions"), "Unknown",
    "Unknown")
| extend vmReadiness = case(
    assessmentEnabled == false, "Disabled",
    assessmentUploadTime < ago(14d), "Unknown",
    azureSqlVirtualMachineRecommendationStatus == "Ready" and sqlVMInWarnings,
        "Ready with Conditions",
    azureSqlVirtualMachineRecommendationStatus == "Ready", "Ready",
    azureSqlVirtualMachineRecommendationStatus == "NotReady", "NotReady",
    isnull(azureSqlVirtualMachineRecommendationStatus)
        or azureSqlVirtualMachineRecommendationStatus
            !in ("Ready", "NotReady", "Ready with Conditions"), "Unknown",
    "Unknown")
| extend subscriptionId = extract(@"/subscriptions/([^/]+)", 1, id)
// Insert requested scope and category conditions here.
| extend sortInstance = tolower(tostring(sqlInstance))
| order by sortInstance asc, subscriptionId asc, id asc
| project
    id,
    subscriptionId,
    sqlInstance,
    version,
    edition,
    dbReadiness,
    miReadiness,
    vmReadiness
```

The default query must retain `where migrationAssessed == "Assessed"`. Replace that condition only when the user explicitly requests a Not Assessed or Disabled drill-down.

Invoke Query 2 with a page size of 12. Keep `id` in the projection because Azure Resource Graph uses it to provide stable continuation tokens, but do not display it. Render only the returned page. Do not follow its skip token until the user requests the next page.

## Query 3: Top Five Recorded Blockers

Run this query once. It returns the top five blockers for each target:

| Display target | `TargetPlatform` |
|---|---|
| Azure SQL Database | `AzureSqlDatabase` |
| Azure SQL Managed Instance | `AzureSqlManagedInstance` |
| SQL Server on Azure VM | `AzureSqlVirtualMachine` |

```kql
resources
| where type in (
    'microsoft.azurearcdata/sqlserverinstances',
    'microsoft.azurearcdata/sqlserverinstances/databases')
| where todatetime(properties.migration.assessment.assessmentUploadTime) > ago(14d)
| where type == 'microsoft.azurearcdata/sqlserverinstances/databases'
    or (
        (
            properties.migration.assessment.enabled == true
            or isnull(properties.migration.assessment.enabled))
        and isnotnull(
            parse_json(properties.migration.assessment.skuRecommendationResults)))
| extend subscriptionId = extract(@"/subscriptions/([^/]+)", 1, id)
// Insert requested subscription, resource-group, and location conditions here.
| extend instanceId = case(
    type == 'microsoft.azurearcdata/sqlserverinstances/databases',
        tostring(split(tolower(id), '/databases/')[0]),
    tolower(id))
| extend assessments = case(
    type == 'microsoft.azurearcdata/sqlserverinstances/databases',
        parse_json(tostring(properties.migration.assessment.databaseAssessments)),
    parse_json(tostring(properties.migration.assessment.serverAssessments)))
| mv-expand finding = assessments
| extend targetPlatform = case(
    isnotempty(tostring(finding.AppliesToMigrationTargetPlatform)),
        tostring(finding.AppliesToMigrationTargetPlatform),
    tostring(finding.appliesToMigrationTargetPlatform))
| extend blockerType = case(
    isnotempty(tostring(finding.FeatureId)),
        tostring(finding.FeatureId),
    tostring(finding.featureId))
| extend issueCategory = case(
    isnotempty(tostring(finding.IssueCategory)),
        tostring(finding.IssueCategory),
    tostring(finding.issueCategory))
| extend moreInformation = case(
    isnotempty(tostring(finding.MoreInformation)),
        tostring(finding.MoreInformation),
    tostring(finding.moreInformation))
| where targetPlatform in~ (
        'AzureSqlDatabase',
        'AzureSqlManagedInstance',
        'AzureSqlVirtualMachine')
    and issueCategory =~ 'Issue'
    and isnotempty(blockerType)
| summarize MoreInformation = max(moreInformation)
    by TargetPlatform = targetPlatform, instanceId, blockerType
| summarize
    AffectedInstances = count(),
    MoreInformation = make_set_if(
        MoreInformation,
        isnotempty(MoreInformation),
        10)
    by TargetPlatform, FeatureId = blockerType
| order by TargetPlatform asc, AffectedInstances desc, FeatureId asc
| summarize Blockers = make_list(
    pack(
        "FeatureId", FeatureId,
        "AffectedInstances", AffectedInstances,
        "MoreInformation", MoreInformation),
    5)
    by TargetPlatform
| order by TargetPlatform asc
```

### Blocker Aggregation Rules

- Use the same scope conditions as Query 1 and Query 2.
- Treat a missing target row as an empty `Blockers` list and render that target's required no-result text.
- Query 3 may return zero rows when no target has a named `Issue` blocker; this
  is a valid result, not a query failure.
- Count each blocker once per distinct SQL Server instance.
- Count only `Issue` findings; do not rank warnings.
- Use `FeatureId` as the blocker name.
- Preserve non-empty `MoreInformation` values for on-demand remediation
  guidance. Do not display them in the default blocker table.
- Use `TotalAssessed` from Query 1 as the denominator.
- When conditional instances exist but no blocker rows are returned, explain
  that warnings are excluded from the Issue-blocker ranking.
- When Not Ready instances exist but no blocker rows are returned, report a
  blocker-data gap.
- Do not infer remediation, effort, scripts, or post-remediation readiness.

## Query 4: Optional Edition Values

Run only when the user asks to filter assessed instances by edition.

```kql
resources
| where type == 'microsoft.azurearcdata/sqlserverinstances'
| where properties.alwaysOnRole != 'FailoverClusterNode'
| where properties.serviceType !in~ ('SSIS', 'SSAS', 'SSRS', 'PBIRS')
| where properties.containerResourceId !contains 'Microsoft.Compute/virtualMachines'
| where todatetime(properties.migration.assessment.assessmentUploadTime) > ago(14d)
| where properties.migration.assessment.enabled == true
    or isnull(properties.migration.assessment.enabled)
| where isnotnull(
    parse_json(properties.migration.assessment.skuRecommendationResults))
| extend Edition = tostring(properties.edition)
| extend subscriptionId = extract(@"/subscriptions/([^/]+)", 1, id)
// Insert requested subscription, resource-group, and location conditions here.
| summarize Instances = count() by Edition
| order by Edition asc
```

## Query 5: Optional Version Values

Run only when the user asks to filter assessed instances by version.

```kql
resources
| where type == 'microsoft.azurearcdata/sqlserverinstances'
| where properties.alwaysOnRole != 'FailoverClusterNode'
| where properties.serviceType !in~ ('SSIS', 'SSAS', 'SSRS', 'PBIRS')
| where properties.containerResourceId !contains 'Microsoft.Compute/virtualMachines'
| where todatetime(properties.migration.assessment.assessmentUploadTime) > ago(14d)
| where properties.migration.assessment.enabled == true
    or isnull(properties.migration.assessment.enabled)
| where isnotnull(
    parse_json(properties.migration.assessment.skuRecommendationResults))
| extend Version = tostring(properties.version)
| extend subscriptionId = extract(@"/subscriptions/([^/]+)", 1, id)
// Insert requested subscription, resource-group, and location conditions here.
| summarize Instances = count() by Version
| order by Version asc
```

## Execution Rules

- Run Query 1, Query 2, and Query 3 once for the default report.
- Run Query 4 or Query 5 only when the corresponding filter is requested.
- Apply identical subscription, resource-group, and location filters to every executed query.
- Pass the complete KQL and selected subscription IDs to Azure Resource Graph
  (see **Running Azure Resource Graph Queries**).
- Use a page size of 1000 and complete pagination for Query 1 and Query 3 before rendering results.
- Use a page size of 12 for Query 2. Render the first returned page immediately and preserve its skip token for an explicit next-page request. Do not fetch later grid pages in the default report.
- Query 1 and Query 2 contain fresh-assessment filters. An empty result means no fresh assessed instances are visible to the current identity.
- Never infer candidate subscriptions from unrelated Azure resource types.
- Authenticate only through `az login` or `Connect-AzAccount`. Never acquire,
  print, or pass access tokens manually, and never send tokens to curl or other
  tools.
- These queries are read-only. Do not run commands that create, change, or
  delete Azure resources.
