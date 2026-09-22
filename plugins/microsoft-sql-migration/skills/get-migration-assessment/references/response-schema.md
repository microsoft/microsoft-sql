# Migration Assessment Response Schema

## Assessment Data Structure

The migration assessment data is located at `properties.migration.assessment` in
the API response. Here is the full structure:

### Assessment Metadata

| Field | Description |
|---|---|
| `enabled` | Stored assessment setting. A missing/null value means enabled by default; only explicit `false` means disabled. |
| `assessmentEnabled` | Effective value projected by the ARG query (`null` is normalized to `true`). |
| `assessmentEnabledConfigured` | Whether the resource explicitly stores the `enabled` property. |
| `assessmentUploadTime` | When assessment results were last uploaded (ISO 8601) |
| `assessmentViewedTime` | When assessment results were last viewed |
| `targetRecommendationGenerationTime` | When target SKU recommendations were last generated |
| `version` | Assessment version |

### Assessment Settings (`settings`)

| Field | Description |
|---|---|
| `targetLocation` | Target Azure region for the migration |
| `percentile` | Percentile used for performance data (e.g., 95) |
| `lookbackPeriodInDays` | How many days of performance data are considered |
| `comfortFactor` | Comfort factor multiplier for sizing |
| `strategy` | Migration strategy: `"MigrateToPaaS"`, `"MigrateToIaaS"`, etc. |
| `currency` | Currency for cost estimates (e.g., `"USD"`) |
| `discountPercentage` | Applied discount percentage |
| `costOptions.computeAndStorageCostOption` | Cost option for compute/storage (e.g., `"PaaS:With3YearRIAndProd;IaaS:With3YearRIAndProd"`) |
| `costOptions.sqlLicenseCostOption` | SQL license cost option (e.g., `"WithSQLAHB"`) |
| `costOptions.windowsLicenseCostOption` | Windows license cost option (e.g., `"WithWindowsAHB"`) |

### Server Assessments (`serverAssessments`)

An array of server-level compatibility issues. Each entry has:

| Field | Description |
|---|---|
| `appliesToMigrationTargetPlatform` | Target platform: `"AzureSqlDatabase"`, `"AzureSqlManagedInstance"`, `"AzureSqlVirtualMachine"` |
| `featureId` | The feature or capability causing the issue (e.g., `"TraceFlags"`) |
| `impactedObjects` | Array of specific objects affected |
| `issueCategory` | `"Warning"` or `"Issue"` (blockers) |
| `moreInformation` | Additional details or documentation link |

### SKU Recommendation Results (`skuRecommendationResults`)

Contains recommendation details for each target platform.

For an existing-assessment read, all fields may be used.

#### Per-platform object (`azureSqlDatabase`, `azureSqlManagedInstance`, `azureSqlVirtualMachine`)

| Field | Description |
|---|---|
| `recommendationStatus` | `"Ready"`, `"NotReady"`, `"Unknown"`, `"InProgress"` |
| `numberOfServerBlockerIssues` | Count of blocking issues preventing migration to this target |
| `monthlyCost.computeCost` | Monthly compute cost estimate |
| `monthlyCost.storageCost` | Monthly storage cost estimate |
| `monthlyCost.iopsCost` | Monthly IOPS cost estimate |
| `monthlyCost.sqlLicenseCost` | Monthly SQL license cost (if applicable) |
| `monthlyCost.windowsLicenseCost` | Monthly Windows license cost (if applicable) |
| `monthlyCost.totalCost` | Total monthly cost estimate |
| `monthlyCostOptions` | Array of alternative pricing scenarios (e.g., 1-year RI, 3-year RI, dev/test) |
| `targetSku` | Recommended SKU details (tier, hardware, compute size, storage) |

### Impacted Objects Summary (`impactedObjectsSummary`)

Grouped by target platform, summarizing the count of impacted objects per feature
and issue category.

## Portal-Aligned Cost Calculation

1. Parse `settings.costOptions.computeAndStorageCostOption` into `PaaS`,
   `IaaS`, and `IsDevTestEnabled` selections.
2. For SQL MI and SQL DB, select the `monthlyCostOptions` entry whose `keyName`
   matches `PaaS`.
3. For SQL VM, select the `monthlyCostOptions` entry whose `keyName` matches
   `IaaS`.
4. Set storage cost to `storageCost + iopsCost`.
5. Set the base total to `computeCost + storageCost + iopsCost`.
6. When Dev/Test is not enabled:
   - Add `sqlLicenseCost` when `sqlLicenseCostOption` is `WithoutSQLAHB`.
   - For SQL VM, add `windowsLicenseCost` when
     `windowsLicenseCostOption` is `WithoutWindowsAHB`.
7. For Azure SQL Database, sum compute, storage, IOPS, and applicable SQL
   license costs across user-database resources.
8. Report monetary cost as unavailable when a required selected cost component
   is missing.

## Portal-Aligned Recommended Target

Calculate readiness from Suitability plus the corresponding VM, MI, or DB SKU
telemetry report. Calculate cost using the rule above.

- Default missing strategy to `MigrateToPaaS`.
- For `MigrateToPaaS`, compare ready SQL MI and SQL DB targets with complete
  cost data. Select the lower monthly cost; select SQL MI on a tie. Select SQL
  VM when neither PaaS target is eligible.
- For other strategies, compare eligible SQL MI, SQL DB, and SQL VM targets and
  select the lowest monthly cost. Select SQL VM when neither PaaS target is
  eligible.

#### Database-Level Assessment Data Structure

The database migration assessment data is located at
`properties.migration.assessment` on each database sub-resource:

The database ARG query excludes the system databases `master`, `model`, `msdb`,
and `tempdb`. Counts and displayed database names therefore represent user
databases only.

| Field | Description |
|---|---|
| `assessmentUploadTime` | When database assessment data was last uploaded (ISO 8601) |
| `databaseAssessments` | Array of database-level compatibility issues (see below) |
| `targetReadiness.azureSqlDatabase.recommendationStatus` | `"Ready"`, `"NotReady"`, `"Unknown"` |
| `targetReadiness.azureSqlDatabase.numOfBlockerIssues` | Count of blocker issues for SQL DB target |
| `targetReadiness.azureSqlDatabase.monthlyCost` | Selected monthly monetary cost components for this database |
| `targetReadiness.azureSqlDatabase.monthlyCostOptions` | Array of pricing scenarios for this database on SQL DB |
| `targetReadiness.azureSqlManagedInstance.recommendationStatus` | `"Ready"`, `"NotReady"`, `"Unknown"` |
| `targetReadiness.azureSqlManagedInstance.numOfBlockerIssues` | Count of blocker issues for SQL MI target |

Each entry in `databaseAssessments` has:

| Field | Description |
|---|---|
| `appliesToMigrationTargetPlatform` | `"AzureSqlDatabase"`, `"AzureSqlManagedInstance"` |
| `featureId` | The feature causing the issue (e.g., `"ServiceBroker"`, `"CLRAssemblies"`, `"LinkedServer"`) |
| `impactedObjects` | Array of affected objects, each with `objectName` and `objectType` |
| `issueCategory` | `"Issue"` (blocker) or `"Warning"` |
| `moreInformation` | Additional details or documentation link |

## Reference: Example Assessment Data

```json
{
  "enabled": true,
  "assessmentUploadTime": "2026-05-10T21:00:33.168Z",
  "assessmentViewedTime": null,
  "targetRecommendationGenerationTime": null,
  "version": null,
  "settings": {
    "targetLocation": "West US",
    "percentile": 95,
    "lookbackPeriodInDays": 30,
    "comfortFactor": null,
    "strategy": "MigrateToPaaS",
    "currency": "USD",
    "discountPercentage": 0,
    "costOptions": {
      "computeAndStorageCostOption": "PaaS:With3YearRIAndProd;IaaS:With3YearRIAndProd",
      "sqlLicenseCostOption": "WithSQLAHB",
      "windowsLicenseCostOption": "WithWindowsAHB"
    }
  },
  "serverAssessments": [
    {
      "appliesToMigrationTargetPlatform": "AzureSqlDatabase",
      "featureId": "TraceFlags",
      "impactedObjects": [],
      "issueCategory": "Warning",
      "moreInformation": null
    },
    {
      "appliesToMigrationTargetPlatform": "AzureSqlManagedInstance",
      "featureId": "TraceFlags",
      "impactedObjects": [],
      "issueCategory": "Warning",
      "moreInformation": null
    }
  ],
  "skuRecommendationResults": {
    "azureSqlDatabase": {
      "recommendationStatus": "NotReady",
      "numberOfServerBlockerIssues": 0,
      "monthlyCost": {
        "computeCost": 245.13,
        "storageCost": 0.18,
        "iopsCost": null,
        "sqlLicenseCost": null,
        "windowsLicenseCost": null,
        "totalCost": 245.31
      },
      "targetSku": {
        "category": {
          "computeTier": "Provisioned",
          "hardwareType": "Gen5",
          "sqlPurchasingModel": "vCore",
          "sqlServiceTier": "General Purpose",
          "zoneRedundancyAvailable": false
        }
      }
    },
    "azureSqlManagedInstance": {
      "recommendationStatus": "Ready",
      "numberOfServerBlockerIssues": 0,
      "monthlyCost": {
        "computeCost": 490.26,
        "storageCost": 0,
        "iopsCost": 0,
        "sqlLicenseCost": 292.7,
        "windowsLicenseCost": null,
        "totalCost": 490.26
      },
      "targetSku": {
        "category": {
          "computeTier": "Provisioned",
          "hardwareType": "Gen5",
          "sqlPurchasingModel": "vCore",
          "sqlServiceTier": "Next-Gen General Purpose",
          "zoneRedundancyAvailable": false
        },
        "computeSize": 4,
        "storageMaxSizeInMb": 32768,
        "predictedDataSizeInMb": 688,
        "predictedLogSizeInMb": 560
      }
    },
    "azureSqlVirtualMachine": {
      "recommendationStatus": "Ready",
      "numberOfServerBlockerIssues": 0,
      "monthlyCost": {
        "computeCost": 81.98,
        "storageCost": 2.4,
        "iopsCost": 0,
        "sqlLicenseCost": 0,
        "windowsLicenseCost": 67.34,
        "totalCost": 84.38
      },
      "targetSku": {
        "category": {
          "availableVmSkus": [
            "Standard_D2as_v4",
            "Standard_D4as_v4",
            "Standard_D8as_v4"
          ],
          "virtualMachineFamily": "standardDASv4Family"
        },
        "computeSize": 2,
        "virtualMachineSize": {
          "sizeName": "D2as_v4",
          "azureSkuName": "Standard_D2as_v4",
          "vCPUsAvailable": 2
        },
        "dataDiskSizes": [
          {
            "redundancy": "LocallyRedundant",
            "size": "P2",
            "caching": "ReadOnly",
            "maxSizeInGib": 8,
            "maxThroughputInMbps": 25,
            "maxIops": 120
          }
        ],
        "logDiskSizes": [
          {
            "redundancy": "LocallyRedundant",
            "size": "P2",
            "caching": "None",
            "maxSizeInGib": 8,
            "maxThroughputInMbps": 25,
            "maxIops": 120
          }
        ]
      }
    }
  },
  "impactedObjectsSummary": {
    "azureSqlDatabase": [
      {
        "featureId": "TraceFlags",
        "numberImpacted": 2,
        "issueCategory": "Warning"
      }
    ],
    "azureSqlManagedInstance": [
      {
        "featureId": "TraceFlags",
        "numberImpacted": 2,
        "issueCategory": "Warning"
      }
    ]
  }
}
```
