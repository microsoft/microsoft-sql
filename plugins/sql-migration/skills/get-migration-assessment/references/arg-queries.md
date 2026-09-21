# Migration Assessment ARG Queries

## Shared API

- **Method:** `POST`
- **Endpoint:** `https://management.azure.com/providers/Microsoft.ResourceGraph/resources`
- **API version:** `2022-10-01`
- **Subscriptions:** Target subscription ID
- **Page size:** `1000`
- **Pagination:** Continue with each returned `$skipToken`

## Instance Assessment Query

### Instance Query Purpose

Retrieve assessment settings, server readiness, SKU recommendations, and
instance-level cost data.

### Instance Query Inputs

- Subscription ID
- Resource group when the scope is narrower than a subscription
- One or more instance names when the scope is narrower than a resource group

### Instance Scope Filters

**Single instance:**

```kql
| where resourceGroup =~ '{resourceGroupName}'
| where name =~ '{instanceName}'
```

**Multiple instances:**

```kql
| where resourceGroup =~ '{resourceGroupName}'
| where name in~ ('{instanceName1}', '{instanceName2}', '{instanceName3}')
```

**Resource group:**

```kql
| where resourceGroup =~ '{resourceGroupName}'
```

**Subscription:** Add no scope filter.

### Instance KQL

Insert the selected scope filter before `project`.

```kql
resources
| where type =~ 'microsoft.azurearcdata/sqlserverinstances'
| project
    id,
    name,
    resourceGroup,
    location,
    subscriptionId,
    version = tostring(properties.version),
    edition = tostring(properties.edition),
    status = tostring(properties.status),
    assessmentEnabled = coalesce(tobool(properties.migration.assessment.enabled), true),
    assessmentEnabledConfigured = isnotnull(properties.migration.assessment.enabled),
    assessmentUploadTime = tostring(properties.migration.assessment.assessmentUploadTime),
    assessmentViewedTime = tostring(properties.migration.assessment.assessmentViewedTime),
    targetRecommendationGenerationTime = tostring(properties.migration.assessment.targetRecommendationGenerationTime),
    assessmentVersion = tostring(properties.migration.assessment.version),
    settings = properties.migration.assessment.settings,
    serverAssessments = properties.migration.assessment.serverAssessments,
    skuRecommendationResults = properties.migration.assessment.skuRecommendationResults,
    impactedObjectsSummary = properties.migration.assessment.impactedObjectsSummary
```

### Instance Query Output

One row per SQL Server instance with persisted assessment settings, readiness,
SKU recommendation, and instance-level cost properties.

## Database Assessment Query

### Database Query Purpose

Retrieve readiness, blockers, and cost data for every user database belonging to
an instance returned by the instance assessment query.

### Database Query Inputs

- Subscription ID
- Full SQL Server instance resource ID

### Database Scope Filter

```kql
| where tolower(id) startswith tolower('{instanceResourceId}/databases/')
```

For resource-group execution across multiple instances, use:

```kql
| where resourceGroup =~ '{resourceGroupName}'
```

### Database KQL

Insert the selected scope filter before the system-database filter.

```kql
resources
| where type =~ 'microsoft.azurearcdata/sqlserverinstances/databases'
| where name !in~ ('master', 'model', 'msdb', 'tempdb')
| extend databaseSegmentIndex = indexof(tolower(id), '/databases/')
| project
    id,
    name,
    instanceId = substring(id, 0, databaseSegmentIndex),
    state = tostring(properties.state),
    compatibilityLevel = properties.compatibilityLevel,
    sizeMB = properties.sizeMB,
    spaceAvailableMB = properties.spaceAvailableMB,
    isEncrypted = properties.databaseOptions.isEncrypted,
    assessmentUploadTime = tostring(properties.migration.assessment.assessmentUploadTime),
    databaseAssessments = properties.migration.assessment.databaseAssessments,
    sqlDbStatus = tostring(properties.migration.assessment.targetReadiness.azureSqlDatabase.recommendationStatus),
    sqlDbBlockers = properties.migration.assessment.targetReadiness.azureSqlDatabase.numOfBlockerIssues,
    sqlDbMonthlyCost = properties.migration.assessment.targetReadiness.azureSqlDatabase.monthlyCost,
    sqlDbCostOptions = properties.migration.assessment.targetReadiness.azureSqlDatabase.monthlyCostOptions,
    sqlMiStatus = tostring(properties.migration.assessment.targetReadiness.azureSqlManagedInstance.recommendationStatus),
    sqlMiBlockers = properties.migration.assessment.targetReadiness.azureSqlManagedInstance.numOfBlockerIssues
```

### Database Query Output

One row per user database with database properties, target readiness, blockers,
and Azure SQL Database cost options.

## Query Rules

- Use case-insensitive comparisons for resource type, resource group, and
  instance name.
- Escape single quotes in values inserted into KQL.
- Run the database assessment query for every instance returned by the instance
  assessment query.
- Exclude `master`, `model`, `msdb`, and `tempdb`.

## ARM Execution

### Execution Inputs

- `$SUB`: Target subscription ID
- `$instanceQuery`: Instance KQL with the selected scope filter
- `$databaseQuery`: Database KQL with the full instance resource-ID filter

Build each query from quoted lines joined with `-join " "`. Substitute escaped
input values before execution.

### ARG Adapter

Use this adapter for every query in this file. It acquires a short-lived ARM
token through Azure CLI, pipes JSON directly to `curl`, and returns all pages.

```powershell
function Invoke-AssessmentArgQuery {
  param(
    [Parameter(Mandatory)] [string] $SubscriptionId,
    [Parameter(Mandatory)] [string] $Query
  )

  $url = "https://management.azure.com/providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01"
  $rows = @()
  $skipToken = $null
  $armToken = az account get-access-token --resource "https://management.azure.com/" --query accessToken -o tsv
  if ($LASTEXITCODE -ne 0 -or -not $armToken) { throw "Unable to acquire an ARM access token." }

  try {
    do {
      # The first request has only $top; later requests include the token returned by ARG.
      $options = @{ '$top' = 1000 }
      if ($skipToken) { $options['$skipToken'] = $skipToken }

      $body = @{
        subscriptions = @($SubscriptionId)
        query = $Query
        options = $options
      } | ConvertTo-Json -Depth 10

      # Pipe JSON through standard input so PowerShell does not rewrite it as a native argument.
      $responseLines = @(
        $body |
          curl --silent --show-error --fail-with-body `
            --request POST `
            --url $url `
            --header "Authorization: Bearer $armToken" `
            --header "Content-Type: application/json" `
            --data-binary "@-"
      )
      if ($LASTEXITCODE -ne 0) { throw "Azure Resource Graph request failed." }

      $responseJson = $responseLines -join [Environment]::NewLine
      $response = $responseJson | ConvertFrom-Json
      # Accumulate this page and continue only when ARG returns another page token.
      $rows += @($response.data)
      $skipToken = $response.'$skipToken'
    } while ($skipToken)

    return $rows
  } finally {
    $armToken = $null
  }
}
```

### Token Rules

- Never print, echo, log, or persist `$armToken`.
- Do not use `curl --verbose`, `--trace`, or shell tracing.
- Clear `$armToken` in a `finally` block.

### Execution Order

1. Build `$instanceQuery` from **Instance Assessment Query** and execute:

```powershell
$instanceRows = Invoke-AssessmentArgQuery -SubscriptionId $SUB -Query $instanceQuery
```

2. For every row in `$instanceRows`, build `$databaseQuery` from **Database
   Assessment Query** using the complete instance resource ID and execute:

```powershell
$databaseRows = Invoke-AssessmentArgQuery -SubscriptionId $SUB -Query $databaseQuery
```

3. Combine all returned database rows and associate them with `instanceId`.
