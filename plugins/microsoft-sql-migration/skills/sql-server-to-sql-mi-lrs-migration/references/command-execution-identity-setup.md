# Windows LRS managed identity automation — configuration and fail-fast checks (continued)

## Contents

- [SQL MI and storage identity resolution](#sql-mi-and-storage-identity-resolution)

Part of the command-execution reference set for this skill. See SKILL.md for the workflow phases. See also: references\command-execution-setup.md, references\command-execution-backup.md, references\command-execution-backup-job.md, references\command-execution-lrs.md, references\command-execution-cleanup.md.

Never connect to either the source or target with SQL login/SQL authentication.
Do not request, accept, retrieve, or use SQL passwords or SQL credentials. Use
only Windows Integrated authentication or Microsoft Entra authentication supported
by the workflow: the source supports Windows Integrated or Entra interactive
authentication, and the target supports Entra authentication only.


## SQL MI and storage identity resolution

Require the ARG result's FQDN to match the connected target endpoint. If there is
one match, use it. If there are zero or multiple matches, request only the full
Azure resource ID, validate it against the connected endpoint, and use
that result. Never ask for subscription or resource group. Then set its context
and resolve the user-supplied storage account name through ARG:

```powershell
$selectedInstance = $managedInstanceCandidates[0]
$migrationAzContext = Set-AzContext `
    -SubscriptionId $selectedInstance.subscriptionId `
    -Tenant $migrationAzContext.Tenant.Id

$null = Get-AzAccessToken `
    -ResourceTypeName Arm `
    -TenantId $migrationAzContext.Tenant.Id `
    -DefaultProfile $migrationAzContext

$resolvedMiDetails = Get-AzSqlInstance `
    -ResourceGroupName $selectedInstance.resourceGroup `
    -Name $selectedInstance.name
if ($resolvedMiDetails.FullyQualifiedDomainName -ine $targetServerFqdn) {
    throw 'The ARG/resource-ID SQL MI does not match the authenticated target SQL endpoint.'
}

$escapedStorageName = $storageAccountName.Replace("'", "''")
$storageQuery = @"
resources
| where type =~ 'microsoft.storage/storageaccounts'
| where name =~ '$escapedStorageName'
| project id, subscriptionId, resourceGroup, name, location, kind, sku,
    enableHttpsTrafficOnly=tobool(properties.supportsHttpsTrafficOnly),
    allowBlobPublicAccess=tobool(properties.allowBlobPublicAccess)
"@
$storageCandidates = @(Search-AzGraph -Query $storageQuery -UseTenantScope -First 100 | Where-Object {
    $_.subscriptionId -eq $selectedInstance.subscriptionId -and
    $_.enableHttpsTrafficOnly -eq $true -and
    $_.kind -in @('Storage', 'StorageV2')
} | Sort-Object `
    @{ Expression = { $_.subscriptionId -eq $selectedInstance.subscriptionId }; Descending = $true },
    @{ Expression = { $_.location -eq $selectedInstance.location }; Descending = $true },
    name)
if ($storageCandidates.Count -eq 0) {
    if ([string]::IsNullOrWhiteSpace($storageAccountResourceId)) {
        throw "ARG could not resolve storage account '$storageAccountName'. Request its full Azure resource ID."
    }
    $resolvedStorage = Get-AzResource -ResourceId $storageAccountResourceId
    if ($resolvedStorage.ResourceType -ine 'Microsoft.Storage/storageAccounts') {
        throw 'The supplied storage resource ID is not a storage account.'
    }
    $resolvedStorageSubscriptionId = ($resolvedStorage.ResourceId -split '/')[2]
    if ($resolvedStorageSubscriptionId -ine $selectedInstance.subscriptionId) {
        throw 'The storage account must be in the resolved SQL MI subscription.'
    }
    if ($resolvedStorage.Name -ine $storageAccountName) {
        throw 'The supplied storage resource ID does not match the requested storage account name.'
    }
    $storageCandidates = @([pscustomobject]@{
        id             = $resolvedStorage.ResourceId
        subscriptionId = $resolvedStorageSubscriptionId
        resourceGroup  = $resolvedStorage.ResourceGroupName
        name           = $resolvedStorage.Name
        location       = $resolvedStorage.Location
        kind           = $resolvedStorage.Kind
        enableHttpsTrafficOnly = [bool]$resolvedStorage.Properties.supportsHttpsTrafficOnly
        allowBlobPublicAccess  = [bool]$resolvedStorage.Properties.allowBlobPublicAccess
    })
}

if ($storageCandidates[0].kind -notin @('Storage', 'StorageV2') -or
    $storageCandidates[0].enableHttpsTrafficOnly -ne $true) {
    throw 'The storage account must support Blob storage and HTTPS-only traffic.'
}

if ($storageCandidates.Count -eq 1) {
    $selectedStorage = $storageCandidates[0]
} else {
    $storageCandidates |
        Select-Object name, subscriptionId, resourceGroup, location, kind,
            enableHttpsTrafficOnly, allowBlobPublicAccess |
        Format-Table -AutoSize
    $selectedStorage = $storageCandidates[$selectedStorageRowIndex]
}

$storageContext = New-AzStorageContext `
    -StorageAccountName $selectedStorage.name `
    -UseConnectedAccount
$containerCandidates = @(Get-AzStorageContainer -Context $storageContext | Where-Object {
        -not $_.PublicAccess -or $_.PublicAccess -eq 'Off'
    })
if ($containerCandidates.Count -eq 0) {
    throw "Storage account '$($selectedStorage.name)' has no accessible private Blob container."
}
if ($containerCandidates.Count -eq 1) {
    $selectedContainer = $containerCandidates[0]
} else {
    $containerCandidates | Select-Object Name, PublicAccess | Format-Table -AutoSize
    $selectedContainer = $containerCandidates[$selectedContainerRowIndex]
}
if ($selectedContainer.PublicAccess -and $selectedContainer.PublicAccess -ne 'Off') {
    throw "Blob container '$($selectedContainer.Name)' must not allow public access."
}

$resolvedStorageAccount = Get-AzStorageAccount `
    -ResourceGroupName $selectedStorage.resourceGroup `
    -Name $selectedStorage.name
if ($resolvedStorageAccount.Id -ine $selectedStorage.id) {
    throw 'The resolved storage account does not match the selected ARG resource.'
}
$primaryBlobEndpoint = [uri]$resolvedStorageAccount.PrimaryEndpoints.Blob
if (-not $primaryBlobEndpoint.IsAbsoluteUri -or
    $primaryBlobEndpoint.Scheme -ine 'https' -or
    -not [string]::IsNullOrEmpty($primaryBlobEndpoint.Query) -or
    -not [string]::IsNullOrEmpty($primaryBlobEndpoint.Fragment) -or
    -not [string]::IsNullOrEmpty($primaryBlobEndpoint.UserInfo)) {
    throw 'The resolved storage account did not return a safe HTTPS primaryEndpoints.blob URI.'
}
$storageBlobEndpoint =
    $primaryBlobEndpoint.GetLeftPart([System.UriPartial]::Path).TrimEnd('/')

$selectedStorage |
    Select-Object name, subscriptionId, resourceGroup, location, kind
$storageBlobEndpoint
$selectedContainer | Select-Object Name, PublicAccess

# Set this boolean while securely parsing the target connection string by key
# presence. Never read, print, or persist the access-token value.
$targetAuthentication = if ($targetConnectionUsesAccessToken) {
    'EntraAccessToken'
} else {
    'EntraInteractive'
}

if ($mode -eq 'Continuous') {
    $backupFrequencyMinutes = 10
    if ($null -eq $selectedSqlAgentOwner -or
        [string]::IsNullOrWhiteSpace([string]$selectedSqlAgentOwner.name) -or
        [string]$selectedSqlAgentOwner.type_desc -cne 'WINDOWS_LOGIN' -or
        [bool]$selectedSqlAgentOwner.is_disabled) {
        throw 'Continuous mode requires one explicitly selected enabled direct Windows SQL Agent job owner.'
    }
    $approvedSqlAgentJobOwner = [string]$selectedSqlAgentOwner.name
} else {
    $backupFrequencyMinutes = $null
    $approvedSqlAgentJobOwner = $null
}

function ConvertTo-BlobPathSegment {
    param([Parameter(Mandatory)] [string] $Value)

    if ([string]::IsNullOrWhiteSpace($Value) -or
        $Value -in @('.', '..') -or
        $Value -notmatch '^[A-Za-z0-9._-]+$') {
        throw "Unsafe Blob path segment: '$Value'."
    }

    [Uri]::EscapeDataString($Value)
}

$storageAccountName = [string] $selectedStorage.name
if ($storageAccountName -notmatch '^[a-z0-9]{3,24}$') {
    throw "Unsafe Azure Storage account name: '$storageAccountName'."
}
$containerSegment = ConvertTo-BlobPathSegment `
    -Value ([string] $selectedContainer.Name)
$databaseFolderSegment = ConvertTo-BlobPathSegment `
    -Value ([string] $databaseFolder)
$storageCredentialName = "$storageBlobEndpoint/$containerSegment"
$storageContainerUri = "$storageCredentialName/$databaseFolderSegment"

$config = [ordered]@{
    SourceServer          = $sourceServer
    SourceAuthentication  = $sourceAuthentication
    TrustServerCertificate = $trustServerCertificate
    DatabaseSelection     = $databaseSelection
    SubscriptionId       = $selectedInstance.subscriptionId
    ResourceGroup        = $selectedInstance.resourceGroup
    ManagedInstance      = $selectedInstance.name
    TargetAuthentication = $targetAuthentication
    TargetEntraUsername   = $targetEntraUsername
    AuthenticatedTenantId = $migrationAzContext.Tenant.Id
    AuthenticatedAccount  = $migrationAzContext.Account.Id
    TargetDatabase       = $targetDatabase
    Collation            = $approvedCollation
    StorageResourceGroup = $selectedStorage.resourceGroup
    StorageSubscriptionId = $selectedStorage.subscriptionId
    StorageAccount       = $storageAccountName
    Container            = $selectedContainer.Name
    DatabaseFolder       = $databaseFolder
    ContainerBlobSegment = $containerSegment
    DatabaseFolderBlobSegment = $databaseFolderSegment
    StorageBlobEndpoint  = $storageBlobEndpoint
    StorageCredentialName = $storageCredentialName
    StorageContainerUri  = $storageContainerUri
    LocalBackupRoot      = $localBackupRoot
    SqlAgentJobOwner     = $(if ($mode -eq 'Continuous') {
        $approvedSqlAgentJobOwner
    } else {
        $null
    })
    Mode                 = $mode
    LastBackupName       = $lastBackupName
    BackupFrequencyMinutes = $backupFrequencyMinutes
}

if ($config.SourceAuthentication -notin @('WindowsIntegrated', 'EntraInteractive')) {
    throw 'SourceAuthentication must be WindowsIntegrated or EntraInteractive.'
}
if ($config.TrustServerCertificate -isnot [bool]) {
    throw 'TrustServerCertificate must be true or false.'
}
if ($config.TargetAuthentication -notin @('EntraInteractive', 'EntraAccessToken')) {
    throw 'Target SQL MI authentication must be EntraInteractive or EntraAccessToken.'
}
if ([string]::IsNullOrWhiteSpace($config.TargetEntraUsername)) {
    throw 'TargetEntraUsername is required.'
}
if ($config.AuthenticatedAccount -ine $config.TargetEntraUsername) {
    throw 'The authenticated Entra account does not match TargetEntraUsername.'
}
if ($config.Mode -notin @('Continuous', 'Autocomplete')) {
    throw 'Mode must be Continuous or Autocomplete.'
}
if ($config.Mode -eq 'Continuous' -and
    [string]::IsNullOrWhiteSpace($config.SqlAgentJobOwner)) {
    throw 'Continuous mode requires an explicitly approved Windows SqlAgentJobOwner.'
}
if ($config.Mode -eq 'Autocomplete' -and
    $null -ne $config.SqlAgentJobOwner) {
    throw 'Autocomplete mode must not configure a SQL Agent job owner.'
}
if ($config.Mode -eq 'Autocomplete' -and
    [string]::IsNullOrWhiteSpace($config.LastBackupName)) {
    throw 'LastBackupName is required for Autocomplete mode.'
}
if ($config.Container -match '(?i)backup' -or
    $config.DatabaseFolder -match '(?i)backup') {
    throw "Container and database folder names can't contain the reserved word 'backup'."
}
if ($config.DatabaseFolder -match '[/\\]') {
    throw 'DatabaseFolder must be one database-name path segment without child folders.'
}
if ([string]::IsNullOrWhiteSpace($config.LocalBackupRoot) -or
    -not [System.IO.Path]::IsPathFullyQualified($config.LocalBackupRoot)) {
    throw 'LocalBackupRoot must be an approved absolute local path.'
}
if ($config.Mode -eq 'Continuous' -and
    $config.BackupFrequencyMinutes -ne 10) {
    throw 'BackupFrequencyMinutes must be exactly 10 for Continuous mode.'
}

```

After source authentication, enumerate the eligible database set through the
cached source connection. Use this query before constructing the queue:

```sql
SELECT name
FROM sys.databases
WHERE database_id > 4
    AND state_desc = N'ONLINE'
    AND source_database_id IS NULL
    AND HAS_DBACCESS(name) = 1
ORDER BY name;
GO
```

Display a scalar single-select dropdown with `All` first, followed by the returned
names. `All` means every name in this exact result, not every row in
`sys.databases`. If the user selects a database, ask `Add another database?` as a
separate scalar choice. On `Yes`, show a new single-select dropdown containing
only unselected returned names and `Done`; repeat until `Done` or no names remain.
Append each choice to the ordered in-memory queue. Never send an array value to a
question control and never retry the same failing multi-select field. Reject
unknown, duplicate, system, inaccessible, or no-longer-online names. Requery
immediately before queue creation and block if the selected set changed. Preserve
the displayed order for `All`; otherwise preserve selection order. Do not ask for
a comma-separated list or accept a name not returned by this source connection.

After selection, pass `-DefaultProfile $migrationAzContext` to every Az cmdlet
that supports it. Revalidate with `Get-AzAccessToken` before a long-running phase;
it uses the cached credential and silently refreshes ordinary access-token expiry.
Do not call `Connect-AzAccount` inside database loops, polling loops, retry handlers,
AzCopy setup, cutover, or validation. Do not serialize, inspect, or log the token.

Ask for the storage account name after SQL MI resolution, use ARG to resolve
`$selectedStorage`, then authenticate to its Blob data plane and discover
`$selectedContainer` from existing private containers. Use a structured
single-select picker when multiple containers exist; do not ask for a container
name before attempting discovery. Reject an absent resource, a public container,
or a resource outside the selected target subscription. Enforce the
one-database-folder and reserved-name rules before assigning `$config`. Never request
storage keys or connection strings.

Do not filter out an otherwise compatible account merely because Shared Key is
disabled; LRS managed identity and Entra-authenticated AzCopy do not require it.
Require the local-backup-plus-AzCopy route after validating local capacity,
SQL Server service-account write access, uploader read access, and container-scoped
Blob write permission. This is the only supported source-backup transport.

Before offering storage or container creation, test the operator's effective
permission for the exact resource-group or storage-account scope, including group
assignments. The implementation boundary `Test-AzureActionAllowed` must evaluate
the required `Microsoft.Storage/storageAccounts/write` or
`Microsoft.Storage/storageAccounts/blobServices/containers/write` action. If the
action is denied, show only compatible existing resources and explain the blocker;
do not request approval for an operation that will fail.

If no compatible account/container exists and the permission check passes, include
this proposed remediation in the preparation summary and run it after consent and
validation of globally unique lowercase names. The
account does not need Shared Key because upload uses Microsoft Entra authentication.
Keep Shared Key and public Blob access disabled. Re-run discovery after creation instead of assigning
objects optimistically.

```powershell
$newStorage = New-AzStorageAccount `
    -ResourceGroupName $approvedStorageResourceGroup `
    -Name $approvedStorageAccountName `
    -Location $selectedInstance.Location `
    -SkuName Standard_LRS `
    -Kind StorageV2 `
    -EnableHttpsTrafficOnly $true `
    -MinimumTlsVersion TLS1_2 `
    -AllowBlobPublicAccess $false `
    -AllowSharedKeyAccess $false

New-AzRmStorageContainer `
    -StorageAccount $newStorage `
    -Name $approvedContainerName `
    -PublicAccess None | Out-Null
```

Set `$targetDatabase` to the validated source database name when no override is
provided, then prove it does not already exist on SQL MI. Set `$databaseFolder` to
that validated target name and `$mode` to `Continuous` when they are not provided.
An override remains a migration decision, not a discovered Azure property.

The reusable interactive Entra context authenticates the operator to the Azure
control plane and AzCopy; it is not the LRS storage credential. `Connect-AzAccount`
is the one-time attended fallback when its cached credential cannot refresh
silently. Unattended, service-principal, and workload-identity execution are not
supported. Scope the operator permissions independently from the SQL MI identity.
