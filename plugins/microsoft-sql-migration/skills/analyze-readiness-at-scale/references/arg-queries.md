# Readiness at Scale ARG Queries

## Shared API

- **Method:** `POST`
- **Endpoint:** `https://management.azure.com/providers/Microsoft.ResourceGraph/resources`
- **API version:** `2021-03-01`
- **Assessment freshness:** `14d`
- **Displayed drill-down page size:** `12`

## Subscription Selection

Readiness at scale is Azure-only. Do not offer a local source option.

Resolve enabled subscriptions before asking for scope when the user did not
already provide subscription names or IDs:

```powershell
$currentTenantId = az account show --query tenantId --output tsv
az account list --all `
  --query "[?state=='Enabled' && tenantId=='$currentTenantId'].{Name:name, SubscriptionId:id}" `
  --output json
```

Do not print the complete result. Ask the user to use all accessible
subscriptions in the current tenant by default or select one or more
subscriptions.
Resolve provided subscription names or IDs against this same list and retain
the returned display name and canonical subscription ID.

For selected subscriptions, use a text-based paginated selector:

1. Sort by display name and subscription ID, then assign stable global numbers.
2. Show 10 rows per page with number, display name, and subscription ID.
3. Accept multiple comma-separated global numbers or subscription IDs in one
   response.
4. Accept `next`, `previous`, `search <name-or-id>`, and `done`.
5. Preserve selected subscriptions across pages and searches.
6. After each response, show the current selected names and IDs.
7. Reject invalid entries explicitly without discarding valid selections.
8. Continue until the user enters `done`.

Do not show hundreds of subscriptions in one table. Do not force one
subscription selection per prompt.
Resolve the final selections to subscription IDs and use the same IDs in every
dashboard and grid query.

## Scope Filters

Append this block before the final projection or summarization in each query:

```kql
| extend subscriptionId = extract(@"/subscriptions/([^/]+)", 1, id)
| extend resourceGroup = extract(@"/resource[g/G]roups/([^/]+)", 1, id)
| where subscriptionId in ('{subscriptionId1}', '{subscriptionId2}')
    and resourceGroup in ('{resourceGroup1}', '{resourceGroup2}')
    and location in ('{location1}', '{location2}')
```

Include only conditions for filters that have values. Escape single quotes.

For Query 2, insert only the requested category condition at the marked
location:

```kql
| where edition == '{escapedEdition}'
| where version == '{escapedVersion}'
```

Escape single quotes and use only the applicable condition.

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
| extend resourceGroup = extract(@"/resource[g/G]roups/([^/]+)", 1, id)
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

All target rows must have the same `TotalAssessed`. Report inconsistent data
instead of rendering totals when they differ.

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
| extend assessmentEnabled = properties.migration.assessment.enabled == true
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
| extend resourceGroup = extract(@"/resource[g/G]roups/([^/]+)", 1, id)
// Insert requested scope and category conditions here.
| extend instanceDisplayName = strcat(name, ' (', resourceGroup, ', ', subscriptionId, ')')
| order by instanceDisplayName asc, id asc
| project
    instanceDisplayName,
    resourceGroup,
    location,
    id,
    subscriptionId,
    sqlInstance,
    version,
    edition,
    serviceType,
    dbReadiness,
    miReadiness,
    vmReadiness,
    migrationAssessed
```

The query must retain `where migrationAssessed == "Assessed"`. This skill does
not provide a Not Assessed or Disabled drill-down.

## Query 3: Top Five Recorded Blockers

Run this query once for SQL DB and once for SQL MI. SQL VM readiness does not
have compatibility blockers.

| Display target | `{targetPlatform}` |
|---|---|
| Azure SQL Database | `AzureSqlDatabase` |
| Azure SQL Managed Instance | `AzureSqlManagedInstance` |

```kql
resources
| where type in (
    'microsoft.azurearcdata/sqlserverinstances',
    'microsoft.azurearcdata/sqlserverinstances/databases')
| where type == 'microsoft.azurearcdata/sqlserverinstances'
    or name !in~ ('master', 'model', 'msdb', 'tempdb')
| where type == 'microsoft.azurearcdata/sqlserverinstances/databases'
    or todatetime(
        properties.migration.assessment.assessmentUploadTime) > ago(14d)
| where type == 'microsoft.azurearcdata/sqlserverinstances/databases'
    or (
        (
            properties.migration.assessment.enabled == true
            or isnull(properties.migration.assessment.enabled))
        and isnotnull(
            parse_json(properties.migration.assessment.skuRecommendationResults)))
| extend subscriptionId = extract(@"/subscriptions/([^/]+)", 1, id)
| extend resourceGroup = extract(@"/resource[g/G]roups/([^/]+)", 1, id)
// Insert requested subscription, resource-group, and location conditions here.
| extend instanceId = case(
    type == 'microsoft.azurearcdata/sqlserverinstances/databases',
        tostring(split(tolower(id), '/databases/')[0]),
    tolower(id))
| join kind=inner (
    resources
    | where type == 'microsoft.azurearcdata/sqlserverinstances'
    | where properties.migration.assessment.assessmentUploadTime > ago(14d)
        and (
            properties.migration.assessment.enabled == true
            or isnull(properties.migration.assessment.enabled))
        and isnotnull(
            parse_json(
                properties.migration.assessment.skuRecommendationResults))
    | project
        instanceId = tolower(id),
        parentAssessmentUploadTime =
            todatetime(
                properties.migration.assessment.assessmentUploadTime)
  ) on instanceId
| extend effectiveAssessmentUploadTime = case(
    type == 'microsoft.azurearcdata/sqlserverinstances/databases',
        coalesce(
            todatetime(properties.migration.assessment.assessmentUploadTime),
            parentAssessmentUploadTime),
    parentAssessmentUploadTime)
| where effectiveAssessmentUploadTime > ago(14d)
| extend assessments = case(
    type == 'microsoft.azurearcdata/sqlserverinstances/databases',
        parse_json(tostring(properties.migration.assessment.databaseAssessments)),
    parse_json(tostring(properties.migration.assessment.serverAssessments)))
| mv-expand finding = assessments limit 2000
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
| where targetPlatform =~ '{targetPlatform}'
    and issueCategory =~ 'Issue'
    and isnotempty(blockerType)
| summarize MoreInformation = max(moreInformation) by instanceId, blockerType
| summarize
    AffectedInstances = count(),
    MoreInformation = make_set_if(
        MoreInformation,
        isnotempty(MoreInformation),
        10)
    by FeatureId = blockerType
| order by AffectedInstances desc, FeatureId asc
| take 5
```

### Blocker Aggregation Rules

- Use the same scope conditions as Query 1 and Query 2.
- Count each blocker once per distinct SQL Server instance.
- Each resource contributes at most 2,000 expanded assessment findings because
  Azure Resource Graph caps `mv-expand` at that value. Report this ceiling when
  describing blocker completeness.
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
| where properties.containerResourceId !contains 'Microsoft.Compute/virtualMachines'
| where todatetime(properties.migration.assessment.assessmentUploadTime) > ago(14d)
| where properties.migration.assessment.enabled == true
| where isnotnull(
    parse_json(properties.migration.assessment.skuRecommendationResults))
| extend Edition = tostring(properties.edition)
| extend subscriptionId = extract(@"/subscriptions/([^/]+)", 1, id)
| extend resourceGroup = extract(@"/resource[g/G]roups/([^/]+)", 1, id)
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
| where properties.containerResourceId !contains 'Microsoft.Compute/virtualMachines'
| where todatetime(properties.migration.assessment.assessmentUploadTime) > ago(14d)
| where properties.migration.assessment.enabled == true
| where isnotnull(
    parse_json(properties.migration.assessment.skuRecommendationResults))
| extend Version = tostring(properties.version)
| extend subscriptionId = extract(@"/subscriptions/([^/]+)", 1, id)
| extend resourceGroup = extract(@"/resource[g/G]roups/([^/]+)", 1, id)
// Insert requested subscription, resource-group, and location conditions here.
| summarize Instances = count() by Version
| order by Version asc
```

## ARG Adapter

```powershell
function Invoke-ReadinessAtScaleArgQuery {
  param(
    [Parameter(Mandatory)] [string] $Query,
    [Parameter(Mandatory)] [string[]] $SubscriptionIds
  )

  $url = "https://management.azure.com/providers/Microsoft.ResourceGraph/resources?api-version=2021-03-01"
  $rows = @()
  $skipToken = $null
  $curlCommand = (Get-Command curl.exe -ErrorAction SilentlyContinue).Source
  if (-not $curlCommand) {
    $curlCommand = (Get-Command curl -ErrorAction SilentlyContinue).Source
  }
  if (-not $curlCommand) {
    throw "curl is required to query Azure Resource Graph."
  }

  $armToken = az account get-access-token --resource "https://management.azure.com/" --query accessToken -o tsv
  if ($LASTEXITCODE -ne 0 -or -not $armToken) {
    throw "Unable to acquire an ARM access token."
  }

  try {
    do {
      $bodyData = @{
        subscriptions = $SubscriptionIds
        query = $Query
        options = @{
          '$top' = 1000
          resultFormat = 'objectArray'
        }
      }
      if ($skipToken) {
        $bodyData.options['$skipToken'] = $skipToken
      }
      $body = $bodyData | ConvertTo-Json -Depth 10

      $responseLines = @(
        $body |
          & $curlCommand --silent --show-error --fail-with-body `
            --request POST `
            --url $url `
            --header "Authorization: Bearer $armToken" `
            --header "Content-Type: application/json" `
            --data-binary "@-"
      )
      if ($LASTEXITCODE -ne 0) {
        throw "Azure Resource Graph request failed."
      }

      $response = ($responseLines -join [Environment]::NewLine) | ConvertFrom-Json
      if ($response.resultTruncated -eq $true -and
          -not $response.'$skipToken') {
        throw "Azure Resource Graph returned an incomplete result without a continuation token."
      }
      $rows += @($response.data)
      $skipToken = $response.'$skipToken'
    } while ($skipToken)

    return $rows
  }
  finally {
    $armToken = $null
  }
}
```

## Execution Rules

- Run Query 1 and Query 2 once for the default report.
- Run Query 3 once for SQL DB and once for SQL MI.
- Run Query 4 or Query 5 only when the corresponding filter is requested.
- Apply identical subscription, resource-group, and location filters to every  executed query.
- Put the complete KQL text, adapter definition, and adapter invocation in the   same PowerShell tool call.
- Follow `$skipToken` and fetch all pages before rendering results.
- Query 1 and Query 2 contain fresh-assessment filters. An empty result means no fresh assessed instances are visible to the current identity.
- Never infer candidate subscriptions from unrelated Azure resource types.
- Never print, echo, log, or persist the ARM token.