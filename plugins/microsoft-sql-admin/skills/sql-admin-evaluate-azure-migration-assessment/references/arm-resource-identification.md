# Azure SQL Server Instance Identification

Use this reference to identify SQL Server instances stored in Azure.

## Accepted Input Formats

Parse the values already provided by the user.

| User provides | Action |
|---|---|
| Full resource URI | Parse subscription, resource group, and instance name from `/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.AzureArcData/SqlServerInstances/{name}` |
| Subscription + resource group + instance name | Use directly |
| Subscription or subscription + resource group | Run discovery and present the returned instances |
| Instance name only | Use the current subscription when available; otherwise search all accessible subscriptions |

Proceed with subscription, resource group, and instance name. Resolve missing values through discovery or ask for the specific value.

## Discovery Query

Run this query against Azure Resource Graph (`az graph query`, `Search-AzGraph`, or the Resource Graph REST API; see the `sql-admin-get-migration-assessment` skill's `references/arg-queries.md` for the commands):

```kql
resources
| where type =~ 'microsoft.azurearcdata/sqlserverinstances'
| where resourceGroup =~ '{resourceGroupName}'
| project name, resourceGroup, subscriptionId, location,
    version = tostring(properties.version),
    edition = tostring(properties.edition),
    status = tostring(properties.status)
| order by resourceGroup, name
```

Use the current subscription from context when available (for example `az account show --query "{subscriptionId:id, displayName:name}"` or `Get-AzContext`). For an instance name without one, list all accessible subscription IDs and search them without first asking the user to choose a subscription.

Use the resolved subscription IDs, a page size of 1000, and no skip token for the first request. Pass the page size through the client option, not as `| top` KQL. Filter a known instance with `name =~ '{instanceName}'`. Follow every returned skip token; continue for one match, ask for multiple matches, and report no match when none is found.

## Required Permissions

| Permission | Operation |
|---|---|
| `Microsoft.AzureArcData/sqlServerInstances/read` | Read instance properties and assessment status |
| `Microsoft.AzureArcData/sqlServerInstances/write` | Enable assessment |
| `Microsoft.AzureArcData/sqlServerInstances/runMigrationAssessment/action` | Trigger assessment |
| `Microsoft.ResourceGraph/resources/read` | Query ARG instance and database data |

Reader supports read-only assessment access. Contributor includes the required write and action permissions. A custom role can grant only the listed operations.


### Disambiguating resource matches

When several resources match, show numbered choices with subscription display
name, resource group and instance name. Retain resource IDs behind each choice;
include the subscription ID when names collide or cannot be resolved. Reuse names
already in context. Resolve a missing name through the subscription resource
container only if needed. Ask for a selection before reading the assessment or
triggering a new one; never silently select the first result.
