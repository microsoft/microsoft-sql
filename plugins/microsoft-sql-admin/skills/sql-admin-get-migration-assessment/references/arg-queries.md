# Migration Assessment ARG Queries

## Running Azure Resource Graph Queries

Run every query against Azure Resource Graph (ARG) with one of these public, documented options,
signed in with `az login` (Azure CLI) or `Connect-AzAccount` (Az PowerShell):

- **Azure CLI** (`resource-graph` extension; install once with `az extension add --name resource-graph`):

  ```bash
  az graph query -q "$(cat query.kql)" --subscriptions <subscriptionId> --first 1000 -o json
  # next page: add --skip-token "<skip_token from the previous response>"
  ```

- **Az PowerShell** (`Az.ResourceGraph` module):

  ```powershell
  Search-AzGraph -Query (Get-Content query.kql -Raw) -Subscription $subscriptionId -First 1000
  # next page: add -SkipToken $previousResult.SkipToken
  ```

- **REST API** through `az rest` (the request body carries the KQL, which avoids shell quoting):

  ```bash
  az rest --method post \
    --url "https://management.azure.com/providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01" \
    --body @request.json
  # request.json: {"subscriptions": ["<subscriptionId>"], "query": "<KQL>", "options": {"$top": 1000, "$skipToken": "<token or omit>"}}
  ```

Settings for every query:

- Subscriptions: Target subscription ID
- Query: Complete KQL text. Save it to a file and pass the file contents to avoid shell-quoting problems.
- Page size: `1000`
- Pagination: no skip token for the first page; continue with each returned skip token
  (`skip_token` in Azure CLI output, `SkipToken` in PowerShell, `$skipToken` in the REST response)
  until none is returned

These queries are read-only. Authenticate only through `az login` or `Connect-AzAccount`; never
acquire, print, or pass access tokens manually.

## Instance Assessment Query

### Instance Query Purpose

Retrieve assessment settings, server readiness, SKU recommendations, and instance-level cost data.

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
    sqlDbStatus = tostring(properties.migration.assessment.skuRecommendationResults.azureSqlDatabase.recommendationStatus),
    sqlDbBlockers = properties.migration.assessment.skuRecommendationResults.azureSqlDatabase.numberOfServerBlockerIssues,
    sqlMiStatus = tostring(properties.migration.assessment.skuRecommendationResults.azureSqlManagedInstance.recommendationStatus),
    sqlMiBlockers = properties.migration.assessment.skuRecommendationResults.azureSqlManagedInstance.numberOfServerBlockerIssues,
    sqlVmStatus = tostring(properties.migration.assessment.skuRecommendationResults.azureSqlVirtualMachine.recommendationStatus),
    sqlVmBlockers = properties.migration.assessment.skuRecommendationResults.azureSqlVirtualMachine.numberOfServerBlockerIssues,
    impactedObjectsSummary = properties.migration.assessment.impactedObjectsSummary
```

### Instance Query Output

One row per SQL Server instance with persisted assessment settings, explicit per-target instance readiness and blocker counts, SKU recommendation, and instance-level cost properties.

## Database Assessment Query

### Database Query Purpose

Retrieve readiness, blockers, and cost data for every user database belonging to an instance returned by the instance assessment query.

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
    sqlDbTargetSku = properties.migration.assessment.targetReadiness.azureSqlDatabase.targetSku,
    sqlDbMonthlyCost = properties.migration.assessment.targetReadiness.azureSqlDatabase.monthlyCost,
    sqlDbCostOptions = properties.migration.assessment.targetReadiness.azureSqlDatabase.monthlyCostOptions,
    sqlMiStatus = tostring(properties.migration.assessment.targetReadiness.azureSqlManagedInstance.recommendationStatus),
    sqlMiBlockers = properties.migration.assessment.targetReadiness.azureSqlManagedInstance.numOfBlockerIssues,
    sqlVmStatus = tostring(properties.migration.assessment.targetReadiness.azureSqlVirtualMachine.recommendationStatus),
    sqlVmBlockers = properties.migration.assessment.targetReadiness.azureSqlVirtualMachine.numOfBlockerIssues
```

### Database Query Output

One row per user database with database properties, target readiness, blockers, and Azure SQL Database cost options.

## Query Rules

- Use case-insensitive comparisons for resource type, resource group, and instance name.
- Escape single quotes in values inserted into KQL.
- Run the database assessment query for every instance returned by the instance assessment query.
- Exclude `master`, `model`, `msdb`, and `tempdb`.

## Execution

1. Build the complete instance KQL and run it against Azure Resource Graph.
2. Follow every returned skip token before interpreting the instance rows.
3. For every instance row, build the database KQL using its complete resource ID and run it against Azure Resource Graph.
4. Follow every returned skip token, combine the database rows, and associate them with `instanceId`.
