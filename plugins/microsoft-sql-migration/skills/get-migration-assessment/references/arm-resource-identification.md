# Azure SQL Server Instance Identification

Use this reference to identify SQL Server instances stored in Azure.

## Accepted Input Formats

Parse the values already provided by the user.

| User provides | Action |
|---|---|
| Full resource URI | Parse subscription, resource group, and instance name from `/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.AzureArcData/SqlServerInstances/{name}` |
| Subscription + resource group + instance name | Use directly |
| Subscription or subscription + resource group | Run discovery and present the returned instances |
| Instance name only | Use the current subscription and run discovery |

Proceed with subscription, resource group, and instance name. Resolve missing
values through discovery or ask for the specific value.

## Discovery Query

```bash
az graph query -q "
  resources
  | where type =~ 'microsoft.azurearcdata/sqlserverinstances'
  | where resourceGroup =~ '$RG'
  | project name, resourceGroup, subscriptionId, location,
      version = tostring(properties.version),
      edition = tostring(properties.edition),
      status = tostring(properties.status)
  | order by resourceGroup, name
" --subscriptions "$SUB" --query data -o table
```

Include the resource-group filter only when the resource group is known. Present
multiple matches for selection. After selection, use
`get-migration-assessment` for assessment data.

## Authentication

Use the active Azure CLI session. Run `az login` when authentication is required.
Acquire short-lived ARM tokens only inside the execution block that uses them.
Keep tokens in memory, never print, echo, log, or persist them, and clear them in
a `finally` block. Pipe JSON request bodies to silent `curl` calls through
standard input.

## Common Variables

```bash
SUB="{subscriptionId}"
RG="{resourceGroupName}"
INSTANCE="{instanceName}"
```

## Required Permissions

| Permission | Operation |
|---|---|
| `Microsoft.AzureArcData/sqlServerInstances/read` | Read instance properties and assessment status |
| `Microsoft.AzureArcData/sqlServerInstances/write` | Enable assessment |
| `Microsoft.AzureArcData/sqlServerInstances/runMigrationAssessment/action` | Trigger assessment |
| `Microsoft.ResourceGraph/resources/read` | Query ARG instance and database data |

Reader supports read-only assessment access. Contributor includes the required
write and action permissions. A custom role can grant only the listed operations.
