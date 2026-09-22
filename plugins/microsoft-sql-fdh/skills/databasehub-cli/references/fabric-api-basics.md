# Fabric API and CLI basics

Use this reference for the small set of shared Fabric behaviors required by
`databasehub-cli`.

## Authentication

Database Hub currently requires a delegated Microsoft Entra user identity for
the Fabric API audience. Sign in interactively and verify the active tenant:

```powershell
az login --allow-no-subscriptions
az account show
```

Use `--tenant <tenant-id>` when the active tenant is not the one containing the
Fabric estate. Device-code login is appropriate for a terminal without a
browser:

```powershell
az login --use-device-code --allow-no-subscriptions --tenant <tenant-id>
```

Do not assume that service-principal, managed-identity, or workload-token login
is compatible with Database Hub. A 401 or 403 from the allowlisted route is an
authentication or authorization result to report, not a reason to change hosts
or token audiences.

## Fabric REST calls

Use both the Fabric resource audience and the skill-attribution header:

```powershell
$skillName = "databasehub-cli"
$fabricResource = "https://api.fabric.microsoft.com"

az rest --method get `
  --resource $fabricResource `
  --url "$fabricResource/v1/databasehub/__private/databases/count" `
  --headers "x-ms-fabric-skill=$skillName"
```

`x-ms-fabric-skill` contains only the skill name. Never place tokens, tenant
data, resource names, or other user information in it.

Never print or persist the bearer token. If `Invoke-RestMethod` is required for
a complex Windows query string, acquire the token in memory and pass it only in
the request header.

## Workspace and item resolution

Most Database Hub routes are tenant-scoped. Resolve a workspace or item only
for Fabric SQL catalog disambiguation or a handoff to an item-specific skill.

When a workspace name is supplied, list workspaces and filter on
`displayName`; the API has no get-by-name route:

```powershell
$workspaceName = "Sales"
$workspaces = az rest --method get `
  --resource "https://api.fabric.microsoft.com" `
  --url "https://api.fabric.microsoft.com/v1/workspaces" `
  --headers "x-ms-fabric-skill=databasehub-cli" `
  --output json | ConvertFrom-Json

$workspaceMatches = @(
  $workspaces.value |
    Where-Object { $_.displayName -eq $workspaceName }
)

if ($workspaceMatches.Count -eq 1) {
  $workspaceMatches[0].id
} else {
  $workspaceMatches | Select-Object id, displayName
}
```

When the workspace ID is known, list the required item type in that workspace
and filter on `displayName`. If a list response carries a continuation token,
page it before concluding that a named workspace or item does not exist.
If exact-name filtering returns zero or multiple rows, show the matches and ask
the user to disambiguate rather than selecting one silently.

Do not guess workspace IDs, item IDs, subscriptions, resource groups, servers,
resource IDs, or database names.
