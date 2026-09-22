# Local backup and restore command execution — discovery and setup

## Contents

- [0. Gate command-line tools](#0-gate-command-line-tools)
- [1. Authenticate once and cache Azure scope](#1-authenticate-once-and-cache-azure-scope)
- [2. Discover SQL instances and enforce the target gate](#2-discover-sql-instances-and-enforce-the-target-gate)

Part of the command-execution reference set for this skill. See also: references\command-execution-backup-restore.md.

# Local backup, AzCopy upload, and managed-identity restore command execution

Use this reference only with the corresponding phase in `SKILL.md`. Validate all
identifiers, paths, URLs, resource IDs, and principal IDs before substitution.
Run one database through all phases before starting the next.

Never connect to either the source or target with SQL login/SQL authentication.
Do not request, accept, retrieve, or use SQL passwords or SQL credentials. Use
only Windows Integrated authentication or Microsoft Entra authentication supported
by the workflow.

Run storage, target-host, database, and path discovery as independent probes.
Collect every ambiguous or missing value from those probes and issue one
consolidated `Needs input` prompt after all probes finish. A `throw` in a sample
marks that probe's failure condition; it must not cause a separate user question
while other discovery probes remain unexecuted.

Treat a complete initial `Key=Value` block as the consolidated intake. Do not ask
an intake question when all required undiscoverable values are present. The
sanitized execution-plan approval remains mandatory after discovery. Minimal
Windows-authentication input is:

```text
SourceServer=<source>
SourceDatabases=All
TargetServer=<target>
StorageAccountName=<storage-account>
ContainerName=<private-container>
TrustServerCertificate=false
```

## 0. Gate command-line tools

Resolve canonical executable paths once. Require Go `sqlcmd`, AzCopy v10, Azure
CLI, and the Azure CLI `resource-graph` extension. If a prerequisite is absent,
ask the user to install it from the official link and return `Needs input`.

```powershell
function Find-CompatibleGoSqlcmd {
    param(
        [string[]]$RequiredFlags = @('-E', '-G', '-U')
    )

    foreach ($candidate in @(Get-Command sqlcmd -All -ErrorAction SilentlyContinue)) {
        $versionOutput = & $candidate.Source --version 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            continue
        }

        $modernHelpOutput = & $candidate.Source --help 2>&1 | Out-String
        $modernHelpSucceeded = $LASTEXITCODE -eq 0
        $compatibilityHelpOutput = & $candidate.Source -? 2>&1 | Out-String
        $compatibilityHelpSucceeded = $LASTEXITCODE -eq 0

        $missingFlags = @($RequiredFlags | Where-Object {
            $pattern = "(?m)(^|\s)$([regex]::Escape($_))([,\s]|$)"
            -not (
                ($modernHelpSucceeded -and $modernHelpOutput -match $pattern) -or
                ($compatibilityHelpSucceeded -and
                    $compatibilityHelpOutput -match $pattern)
            )
        })

        if (($modernHelpSucceeded -or $compatibilityHelpSucceeded) -and
            $missingFlags.Count -eq 0) {
            return [pscustomobject]@{
                Path      = $candidate.Source
                Version   = $versionOutput.Trim()
                HelpModes = @(
                    if ($modernHelpSucceeded) { '--help' }
                    if ($compatibilityHelpSucceeded) { '-?' }
                ) -join ', '
            }
        }
    }

    return $null
}

$sqlcmd = Find-CompatibleGoSqlcmd `
    -RequiredFlags @('-S', '-d', '-E', '-G', '-U', '-C', '-Q', '-b', '-r')
$azcopy = Get-Command azcopy -ErrorAction SilentlyContinue
$azureCli = Get-Command az -ErrorAction SilentlyContinue

if (-not $sqlcmd) {
    throw 'A compatible Go sqlcmd installation is required.'
}
if (-not $azcopy) {
    throw 'AzCopy v10 is required: https://aka.ms/downloadazcopy-v10-windows'
}
if (-not $azureCli) {
    throw 'Azure CLI is required: https://aka.ms/installazurecliwindows'
}

$azcopyVersion = & $azcopy.Source --version 2>&1 | Out-String
if ($LASTEXITCODE -ne 0 -or $azcopyVersion -notmatch '(?i)azcopy version 10\.') {
    throw 'AzCopy v10 is required.'
}

& $azureCli.Source version --output none
if ($LASTEXITCODE -ne 0) {
    throw 'Azure CLI validation failed.'
}

$resourceGraphExtension = & $azureCli.Source extension show `
    --name resource-graph `
    --output json 2>$null | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or -not $resourceGraphExtension.version) {
    throw 'Azure CLI resource-graph extension is required. Install it with: az extension add --name resource-graph'
}

$script:SqlcmdPath = [IO.Path]::GetFullPath($sqlcmd.Path)
$script:AzCopyPath = [IO.Path]::GetFullPath($azcopy.Source)
$script:AzureCliPath = [IO.Path]::GetFullPath($azureCli.Source)
```

Use only these cached paths for the run. SQL login authentication is unsupported:
never accept, request, read from Key Vault or Credential Manager, or use SQL
passwords or credentials, and never display a password prompt.

### SQL result transport contract

Transport SQL result sets to PowerShell as strict pipe-delimited rows. Never use
top-level `FOR JSON`, scalar-wrapped JSON, `FOR XML`, or formatted console tables
for SQL result transport. SQL Server and `sqlcmd` can split long serialized values
across result rows or insert output boundaries, producing payloads that are not
valid JSON or XML. Azure CLI `--output json` is unaffected by this rule and must
continue to be parsed with `ConvertFrom-Json`.

Every machine-read SQL result set must:

1. Start each row with a stable record type such as `INSTANCE`, `DATABASE`,
   `BACKUP`, `FILE`, `CREDENTIAL`, or `FINAL`.
2. Use `|` as the `sqlcmd` column separator with headers disabled.
3. Encode nullable text fields so embedded delimiters, percent signs, CR/LF, and
   `NULL` are unambiguous.
4. Emit invariant numeric and Boolean fields without locale formatting.
5. Define and validate one exact field count for each record type.
6. Stop on an unknown record type, malformed row, duplicate singleton row,
   missing required row, or failed type conversion.

Encode every nullable text value in T-SQL with this expression, substituting the
validated expression for `<value>`:

```sql
CASE
    WHEN <value> IS NULL THEN N'~'
    ELSE N'v:' +
        REPLACE(
            REPLACE(
                REPLACE(
                    REPLACE(CONVERT(nvarchar(max), <value>),
                        N'%', N'%25'),
                    N'|', N'%7C'),
                NCHAR(13), N'%0D'),
            NCHAR(10), N'%0A')
END
```

`~` means SQL `NULL`; every non-null string starts with `v:`. Decode replacements
in the reverse order shown below, with `%25` last, so an original literal such as
`%7C` is not decoded as a delimiter:

```powershell
function ConvertFrom-SqlcmdTextField {
    param(
        [Parameter(Mandatory)]
        [string] $Field
    )

    if ($Field -eq '~') {
        return $null
    }
    if (-not $Field.StartsWith('v:', [StringComparison]::Ordinal)) {
        throw "Malformed encoded sqlcmd text field '$Field'."
    }

    $value = $Field.Substring(2)
    $value = $value.Replace('%0A', "`n")
    $value = $value.Replace('%0D', "`r")
    $value = $value.Replace('%7C', '|')
    $value = $value.Replace('%25', '%')
    return $value
}
```

Invoke data-returning SQL batches with the cached executable and these output
options in addition to the already selected connection and authentication
arguments:

```powershell
$sqlcmdOutputArguments = @(
    '-b',
    '-r', '1',
    '-h', '-1',
    '-W',
    '-s', '|',
    '-w', '65535'
)
```

Capture the native exit code before any later command changes `$LASTEXITCODE`.
Pass only one of the separately constructed, validated source or target argument
arrays described below; there is no generic or optional connection splat. Split
nonempty output into rows, split every row on every delimiter, and then validate
the exact schema. Never use a split limit because it can hide an unexpected extra
delimiter. This source example must be repeated with
`$targetConnectionArguments` for target discovery queries:

```powershell
$output = & $script:SqlcmdPath @sourceConnectionArguments `
    @sqlcmdOutputArguments '-Q' $query 2>&1 | Out-String
$exitCode = $LASTEXITCODE
if ($exitCode -ne 0) {
    throw "sqlcmd failed with exit code $exitCode. $($output.Trim())"
}

$rows = @(
    $output -split '\r?\n' |
        Where-Object { $_.Length -gt 0 } |
        ForEach-Object {
            $fields = $_.Split([char]'|')
            $recordType = $fields[0]
            $expectedFieldCount = switch ($recordType) {
                'INSTANCE' { 15 }
                'DATABASE' { 12 }
                'PLATFORM' { 2 }
                'BACKUP_FALLBACK' { 2 }
                'EXCLUDED' { 5 }
                'FINAL' { 5 }
                default {
                    throw "Unknown sqlcmd record type '$recordType'."
                }
            }
            if ($fields.Count -ne $expectedFieldCount) {
                throw "Malformed $recordType row: expected $expectedFieldCount fields, found $($fields.Count)."
            }
            ,$fields
        }
)
```

Use a distinct output batch for heterogeneous command output when informational
messages such as backup progress are expected. Do not feed `BACKUP`, `RESTORE`,
or database-context messages into a structured-row parser. Run the operation with
error-on-failure behavior, then run a separate `SET NOCOUNT ON` metadata query
that emits only the defined delimited record types.

Do not issue `USE <database>` in a structured-output batch because `sqlcmd` can
emit a database-context message that is not a defined record type. Select the
database with `sqlcmd -d <database>`, or query database-scoped permissions from
the current database with a fully validated database name, for example:

```sql
SELECT HAS_PERMS_BY_NAME(N'<validated-database>', 'DATABASE', 'BACKUP DATABASE');
```

## 1. Authenticate once and cache Azure scope

Reuse an Azure CLI user session. If none exists, ask the user to complete one
interactive sign-in. Read all enabled subscriptions once so storage and target
resources can be resolved without asking for Azure metadata separately. AzCopy
then consumes the selected Azure CLI user token.

```powershell
$azureAccount = & $script:AzureCliPath account show --output json 2>$null |
    ConvertFrom-Json

if (-not $azureAccount -or $azureAccount.user.type -ne 'user') {
    & $script:AzureCliPath login --output none
    if ($LASTEXITCODE -ne 0) {
        throw 'Interactive Microsoft Entra user authentication failed.'
    }
    $azureAccount = & $script:AzureCliPath account show --output json |
        ConvertFrom-Json
}

$originalAccount = & $script:AzureCliPath account show --output json |
    ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or -not $originalAccount) {
    throw 'Unable to capture the original Azure CLI context before discovery.'
}
$originalSubscriptionId = [string] $originalAccount.id
$originalTenantId = [string] $originalAccount.tenantId
if ([string]::IsNullOrWhiteSpace($originalSubscriptionId) -or
    [string]::IsNullOrWhiteSpace($originalTenantId)) {
    throw 'The original Azure CLI context did not include a subscription and tenant.'
}

function Restore-OriginalAzureCliContext {
    & $script:AzureCliPath account set `
        --subscription $originalSubscriptionId `
        --output none
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to restore the original Azure CLI subscription context.'
    }

    $restoredAccount = & $script:AzureCliPath account show `
        --output json |
        ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or
        [string] $restoredAccount.id -ine $originalSubscriptionId -or
        [string] $restoredAccount.tenantId -ine $originalTenantId) {
        throw 'Azure CLI did not restore the original subscription and tenant context.'
    }
}

$subscriptions = @(& $script:AzureCliPath account list --all --output json |
    ConvertFrom-Json | Where-Object { $_.state -eq 'Enabled' })
if ($LASTEXITCODE -ne 0 -or $subscriptions.Count -eq 0) {
    throw 'No enabled Azure subscriptions are visible to the signed-in user.'
}

$assertedTenantId = '<optional-tenant-guid>'
if ($assertedTenantId) {
    $subscriptions = @($subscriptions | Where-Object {
        $_.tenantId -eq $assertedTenantId
    })
    if ($subscriptions.Count -eq 0) {
        throw 'No enabled subscription matches the asserted Azure tenant.'
    }
}

$tenantId = $azureAccount.tenantId
$env:AZCOPY_AUTO_LOGIN_TYPE = 'AZCLI'
$env:AZCOPY_TENANT_ID = $tenantId
```

Do not append query parameters to a storage URL. The signed-in user must have
`Storage Blob Data Contributor` on the destination container or account.

### Resolve storage name, endpoint, resource ID, and container together

Accept either a container URI or a storage account name plus container name. A
user's phrase "Blob storage name" means the Azure storage account name. Use Azure
Resource Graph to match that exact name in the current/default tenant first. If
there is no unique match, scan the other tenants represented by the cached
subscriptions. Do not enumerate storage accounts subscription by subscription.

```powershell
$containerUrlInput = '<optional-container-url>'.Trim()
$storageAccountNameInput = '<optional-storage-account-name>'.Trim()
$containerNameInput = '<optional-container-name>'.Trim()
$containerUri = if ($containerUrlInput) { [uri]$containerUrlInput } else { $null }

if ($containerUri -and ($containerUri.Scheme -ne 'https' -or $containerUri.Query)) {
    throw 'ContainerUrl must be HTTPS and must not contain a query string.'
}

if ($containerUri) {
    $uriSegments = @($containerUri.AbsolutePath.Trim('/') -split '/' |
        Where-Object { $_ })
    if ($uriSegments.Count -ne 1) {
        throw 'ContainerUrl must identify one container, not a Blob object.'
    }
    if ($containerNameInput -and $containerNameInput -ne $uriSegments[0]) {
        throw 'ContainerName conflicts with ContainerUrl.'
    }
    $containerNameInput = $uriSegments[0]
    if (-not $storageAccountNameInput) {
        $storageAccountNameInput = $containerUri.Host.Split('.')[0]
    }
}

if (-not $storageAccountNameInput) {
    throw 'A storage account name or ContainerUrl is required for Azure Resource Graph discovery.'
}

$escapedStorageName = $storageAccountNameInput.Replace("'", "''")
$storageQuery = @"
resources
| where type =~ 'microsoft.storage/storageaccounts'
| where name =~ '$escapedStorageName'
| project
    id,
    subscriptionId,
    resourceGroup,
    storageAccount = name,
    location,
    sku = tostring(sku.name),
    kind
"@

function Invoke-TenantGraphQuery {
    param(
        [Parameter(Mandatory)]
        [string] $TenantId,

        [Parameter(Mandatory)]
        [object[]] $TenantSubscriptions,

        [Parameter(Mandatory)]
        [string] $GraphQuery
    )

    $subscriptionIds = @(
        $TenantSubscriptions |
            Where-Object { $_.tenantId -eq $TenantId } |
            ForEach-Object { $_.id }
    )

    if ($subscriptionIds.Count -eq 0) {
        return @()
    }

    try {
        & $script:AzureCliPath account set `
            --subscription $subscriptionIds[0] `
            --output none

        if ($LASTEXITCODE -ne 0) {
            throw "Unable to select a subscription in tenant '$TenantId'."
        }

        $activeAccount = & $script:AzureCliPath account show `
            --output json |
            ConvertFrom-Json

        if ($LASTEXITCODE -ne 0 -or $activeAccount.tenantId -ne $TenantId) {
            throw "Azure CLI did not switch to tenant '$TenantId'."
        }

        $response = & $script:AzureCliPath graph query `
            --graph-query $GraphQuery `
            --first 1000 `
            --output json |
            ConvertFrom-Json

        if ($LASTEXITCODE -ne 0) {
            throw "Azure Resource Graph query failed in tenant '$TenantId'."
        }

        $tenantResults = @($response.data) |
            Where-Object {
                $subscriptionIds -contains [string]$_.subscriptionId
            } |
            ForEach-Object {
                $_ | Add-Member `
                    -NotePropertyName tenantId `
                    -NotePropertyValue $TenantId `
                    -Force `
                    -PassThru
            }
    } finally {
        Restore-OriginalAzureCliContext
    }

    @($tenantResults)
}

$tenantGroups = @($subscriptions | Group-Object tenantId)
$requestedTenantId = '<optional-tenant-guid>'.Trim()
$defaultTenantId = if ($requestedTenantId) {
    $requestedTenantId
} else {
    $azureAccount.tenantId
}

$defaultTenantGroup = @($tenantGroups | Where-Object { $_.Name -eq $defaultTenantId })
if ($defaultTenantGroup.Count -ne 1) {
    throw 'The requested/default tenant has no enabled signed-in subscriptions.'
}

$storageMatches = @(Invoke-TenantGraphQuery `
    -TenantId $defaultTenantId `
    -TenantSubscriptions $defaultTenantGroup[0].Group `
    -GraphQuery $storageQuery)

if ($storageMatches.Count -ne 1 -and -not $requestedTenantId) {
    $otherTenantGroups = @($tenantGroups | Where-Object { $_.Name -ne $defaultTenantId })
    foreach ($tenantGroup in $otherTenantGroups) {
        $storageMatches += @(Invoke-TenantGraphQuery `
            -TenantId $tenantGroup.Name `
            -TenantSubscriptions $tenantGroup.Group `
            -GraphQuery $storageQuery)
    }
}

if ($storageMatches.Count -ne 1) {
    throw 'Storage discovery did not resolve exactly one account; include the remaining storage choice in the consolidated prompt.'
}

$storageMatch = $storageMatches[0]
if ([string]::IsNullOrWhiteSpace([string]$storageMatch.id)) {
    throw 'The Azure Resource Graph storage account match did not include a resource ID.'
}

$storageAccount = & $script:AzureCliPath storage account show `
    --ids $storageMatch.id `
    --subscription $storageMatch.subscriptionId `
    --output json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $null -eq $storageAccount) {
    throw 'The Azure Resource Graph storage account match could not be read.'
}

if ([string]::IsNullOrWhiteSpace([string]$storageAccount.primaryEndpoints.blob)) {
    throw 'The resolved storage account did not return primaryEndpoints.blob.'
}
if ([string]::IsNullOrWhiteSpace([string]$storageAccount.id)) {
    throw 'The resolved storage account did not return id.'
}

$storageAccount | Add-Member `
    -NotePropertyName TenantId `
    -NotePropertyValue $storageMatch.tenantId
$storageAccount | Add-Member `
    -NotePropertyName SubscriptionId `
    -NotePropertyValue $storageMatch.subscriptionId

$tenantId = $storageAccount.TenantId
$env:AZCOPY_TENANT_ID = $tenantId
try {
    & $script:AzureCliPath account set `
        --subscription $storageAccount.SubscriptionId `
        --output none
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to select the resolved storage account subscription.'
    }

    if (-not $containerNameInput) {
        $containers = @(& $script:AzureCliPath storage container list `
            --account-name $storageAccount.Name `
            --subscription $storageAccount.SubscriptionId `
            --auth-mode login `
            --output json | ConvertFrom-Json | Where-Object {
                -not $_.properties.publicAccess
            })
        if ($LASTEXITCODE -ne 0 -or $containers.Count -ne 1) {
            throw 'Container discovery did not resolve exactly one private container; include all accessible container choices in the consolidated prompt.'
        }
        $containerNameInput = $containers[0].name
    }

    if ($containerNameInput -cnotmatch '^[a-z0-9](?:[a-z0-9-]{1,61}[a-z0-9])?$') {
        throw 'ContainerName is not a valid Azure Blob container name.'
    }

    $containerUrl = [uri]::new(
        [uri]$storageAccount.primaryEndpoints.blob,
        $containerNameInput
    ).AbsoluteUri.TrimEnd('/')
    $storageAccountResourceId = [string]$storageAccount.id
    if ([string]::IsNullOrWhiteSpace($containerUrl) -or
        [string]::IsNullOrWhiteSpace($storageAccountResourceId)) {
        throw 'The resolved Blob endpoint or storage account resource ID is empty.'
    }
    $selectedContainer = & $script:AzureCliPath storage container show `
        --account-name $storageAccount.Name `
        --name $containerNameInput `
        --subscription $storageAccount.SubscriptionId `
        --auth-mode login `
        --output json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $selectedContainer.properties.publicAccess) {
        throw 'The resolved container must exist, be private, and be accessible with the signed-in user identity.'
    }
} finally {
    Restore-OriginalAzureCliContext
}
```

When neither a URI nor a storage account name was supplied, or discovery returns
multiple matches, add that unresolved choice to the same consolidated prompt as
any unresolved SQL target or database input. Do not begin a question sequence.

## 2. Discover SQL instances and enforce the target gate

Resolve certificate trust before constructing either source or target connection:

```powershell
$trustServerCertificate = [bool]::Parse('<true-or-false>')
```

Use that resolved Boolean consistently for both connections. Do not attempt a
connection first and then ask whether to trust its certificate.

Construct separate connection arguments only after the source endpoint, target
endpoint, authentication selections, conditional Entra user names, and database
contexts have been validated. Reject blank endpoints, control characters, and
unsupported authentication rather than allowing `sqlcmd` defaults. Use `master`
for instance discovery and replace it with an exact validated database name for
database-scoped checks. Build each array once and never append to or reuse it for
the other endpoint:

```powershell
function New-ValidatedSqlcmdConnectionArguments {
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Server,

        [Parameter(Mandatory)]
        [ValidateSet('Windows', 'Entra')]
        [string] $Authentication,

        [AllowNull()]
        [string] $User,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Database,

        [Parameter(Mandatory)]
        [bool] $TrustServerCertificate
    )

    if ($Server -ne $Server.Trim() -or
        $Server -match '[\x00-\x1F\x7F]' -or
        $Server.StartsWith('-', [StringComparison]::Ordinal)) {
        throw 'The validated SQL Server endpoint is malformed.'
    }
    if ($Database -ne $Database.Trim() -or
        $Database -match '[\x00-\x1F\x7F]') {
        throw 'The validated SQL database context is malformed.'
    }

    $arguments = @('-S', $Server, '-d', $Database)
    switch ($Authentication) {
        'Windows' {
            if (-not [string]::IsNullOrWhiteSpace($User)) {
                throw 'SourceUser or TargetUser must be empty for Windows authentication.'
            }
            $arguments += '-E'
        }
        'Entra' {
            if ([string]::IsNullOrWhiteSpace($User) -or
                $User -ne $User.Trim() -or
                $User -match '[\x00-\x1F\x7F]') {
                throw 'An exact validated user is required for Entra interactive authentication.'
            }
            $arguments += @('-G', '-U', $User)
        }
    }
    if ($TrustServerCertificate) {
        $arguments += '-C'
    }
    $argumentList =
        [System.Collections.Generic.List[string]]::new(
            [string[]]$arguments
        )
    return ,(
        [System.Collections.ObjectModel.ReadOnlyCollection[string]]::new(
            $argumentList
        )
    )
}

[System.Collections.ObjectModel.ReadOnlyCollection[string]] `
    $sourceConnectionArguments =
    New-ValidatedSqlcmdConnectionArguments `
        -Server $validatedSourceServer `
        -Authentication $validatedSourceAuthentication `
        -User $validatedSourceUser `
        -Database 'master' `
        -TrustServerCertificate $trustServerCertificate

[System.Collections.ObjectModel.ReadOnlyCollection[string]] `
    $targetConnectionArguments =
    New-ValidatedSqlcmdConnectionArguments `
        -Server $validatedTargetServer `
        -Authentication $validatedTargetAuthentication `
        -User $validatedTargetUser `
        -Database 'master' `
        -TrustServerCertificate $trustServerCertificate
```

Do not invoke the SQL result wrapper unless the chosen read-only collection
contains exactly one
`-S` with the approved endpoint, exactly one `-d` with the approved context, and
exactly one supported authentication form (`-E` or `-G` with `-U`). Never use an
undefined, empty, shared, or caller-supplied argument array.

Run on source and target:

```sql
SET NOCOUNT ON;

SELECT
    N'INSTANCE' AS record_type,
    CASE WHEN @@SERVERNAME IS NULL THEN N'~' ELSE N'v:' +
        REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(nvarchar(max), @@SERVERNAME),
            N'%', N'%25'), N'|', N'%7C'), NCHAR(13), N'%0D'), NCHAR(10), N'%0A')
    END AS server_name,
    CASE WHEN SERVERPROPERTY('ProductVersion') IS NULL THEN N'~' ELSE N'v:' +
        REPLACE(REPLACE(REPLACE(REPLACE(
            CONVERT(nvarchar(max), SERVERPROPERTY('ProductVersion')),
            N'%', N'%25'), N'|', N'%7C'), NCHAR(13), N'%0D'), NCHAR(10), N'%0A')
    END AS product_version,
    CONVERT(int, LEFT(
        CONVERT(varchar(128), SERVERPROPERTY('ProductVersion')),
        CHARINDEX('.', CONVERT(varchar(128),
            SERVERPROPERTY('ProductVersion')) + '.') - 1
    )) AS product_major_version,
    CASE WHEN SERVERPROPERTY('ProductLevel') IS NULL THEN N'~' ELSE N'v:' +
        REPLACE(REPLACE(REPLACE(REPLACE(
            CONVERT(nvarchar(max), SERVERPROPERTY('ProductLevel')),
            N'%', N'%25'), N'|', N'%7C'), NCHAR(13), N'%0D'), NCHAR(10), N'%0A')
    END AS product_level,
    CASE WHEN SERVERPROPERTY('Edition') IS NULL THEN N'~' ELSE N'v:' +
        REPLACE(REPLACE(REPLACE(REPLACE(
            CONVERT(nvarchar(max), SERVERPROPERTY('Edition')),
            N'%', N'%25'), N'|', N'%7C'), NCHAR(13), N'%0D'), NCHAR(10), N'%0A')
    END AS edition,
    SERVERPROPERTY('EngineEdition') AS engine_edition,
    SERVERPROPERTY('IsClustered') AS is_clustered,
    CASE WHEN SERVERPROPERTY('InstanceDefaultBackupPath') IS NULL THEN N'~' ELSE N'v:' +
        REPLACE(REPLACE(REPLACE(REPLACE(
            CONVERT(nvarchar(max), SERVERPROPERTY('InstanceDefaultBackupPath')),
            N'%', N'%25'), N'|', N'%7C'), NCHAR(13), N'%0D'), NCHAR(10), N'%0A')
    END AS default_backup_path,
    CASE WHEN SERVERPROPERTY('InstanceDefaultDataPath') IS NULL THEN N'~' ELSE N'v:' +
        REPLACE(REPLACE(REPLACE(REPLACE(
            CONVERT(nvarchar(max), SERVERPROPERTY('InstanceDefaultDataPath')),
            N'%', N'%25'), N'|', N'%7C'), NCHAR(13), N'%0D'), NCHAR(10), N'%0A')
    END AS default_data_path,
    CASE WHEN SERVERPROPERTY('InstanceDefaultLogPath') IS NULL THEN N'~' ELSE N'v:' +
        REPLACE(REPLACE(REPLACE(REPLACE(
            CONVERT(nvarchar(max), SERVERPROPERTY('InstanceDefaultLogPath')),
            N'%', N'%25'), N'|', N'%7C'), NCHAR(13), N'%0D'), NCHAR(10), N'%0A')
    END AS default_log_path,
    IS_SRVROLEMEMBER(N'sysadmin') AS is_sysadmin,
    IS_SRVROLEMEMBER(N'dbcreator') AS is_dbcreator,
    HAS_PERMS_BY_NAME(NULL, NULL, N'ALTER ANY CREDENTIAL') AS can_alter_credential,
    HAS_PERMS_BY_NAME(NULL, NULL, N'CREATE ANY DATABASE') AS can_create_database;
GO
```

On the SQL Server 2025 target, read the authoritative host platform separately:

```sql
SET NOCOUNT ON;

SELECT
    N'PLATFORM' AS record_type,
    CASE WHEN host_platform IS NULL THEN N'~' ELSE N'v:' +
        REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(nvarchar(max), host_platform),
            N'%', N'%25'), N'|', N'%7C'), NCHAR(13), N'%0D'), NCHAR(10), N'%0A')
    END AS host_platform
FROM sys.dm_os_host_info;
GO
```

Block unless the target returns `product_major_version = 17`,
`engine_edition <> 8`, `is_clustered = 0`, and `host_platform = N'Windows'` from
`sys.dm_os_host_info`.
Managed-identity restore supports the SQL Server 2025 target in any physical or
cloud location, but server-level managed identity is not supported on Linux.
Supported source versions are SQL Server 2008 through SQL Server 2025, major
versions `10` through `17`. Block when the source major version is less than
`10` or greater than `17`; sources newer than SQL Server 2025 are blocked because
target restore compatibility has not been validated.

When the source `default_backup_path` is `NULL`, including on SQL Server 2016,
run this fallback on the source:

```sql
SET NOCOUNT ON;

DECLARE @BackupDirectory nvarchar(4000);

EXEC master.dbo.xp_instance_regread
    N'HKEY_LOCAL_MACHINE',
    N'Software\Microsoft\MSSQLServer\MSSQLServer',
    N'BackupDirectory',
    @BackupDirectory OUTPUT;

SELECT
    N'BACKUP_FALLBACK' AS record_type,
    CASE WHEN @BackupDirectory IS NULL THEN N'~' ELSE N'v:' +
        REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(nvarchar(max), @BackupDirectory),
            N'%', N'%25'), N'|', N'%7C'), NCHAR(13), N'%0D'), NCHAR(10), N'%0A')
    END AS default_backup_path;
GO
```

Require one nonempty path. Validate that the directory exists, is visible to the
SQL Server service identity, and has sufficient free space before backup.

Discover eligible source databases:

```sql
SET NOCOUNT ON;

SELECT
    N'DATABASE' AS record_type,
    N'v:' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(nvarchar(max), d.name),
        N'%', N'%25'), N'|', N'%7C'), NCHAR(13), N'%0D'), NCHAR(10), N'%0A') AS name,
    N'v:' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(nvarchar(max), d.state_desc),
        N'%', N'%25'), N'|', N'%7C'), NCHAR(13), N'%0D'), NCHAR(10), N'%0A') AS state_desc,
    N'v:' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(nvarchar(max), d.recovery_model_desc),
        N'%', N'%25'), N'|', N'%7C'), NCHAR(13), N'%0D'), NCHAR(10), N'%0A') AS recovery_model_desc,
    N'v:' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(nvarchar(max), d.user_access_desc),
        N'%', N'%25'), N'|', N'%7C'), NCHAR(13), N'%0D'), NCHAR(10), N'%0A') AS user_access_desc,
    d.is_read_only,
    COALESCE(CONVERT(nvarchar(20), d.source_database_id), N'~') AS source_database_id,
    d.is_encrypted,
    d.is_published,
    d.is_subscribed,
    d.is_merge_published,
    d.is_cdc_enabled
FROM sys.databases AS d
WHERE d.database_id > 4
    AND d.state = 0
ORDER BY d.name;
GO
```

`state = 0` is the authoritative `ONLINE` filter. Use this result to expand
`SourceDatabases=All` and build the migration queue. Never enqueue a database in
any other state and never run `ALTER DATABASE` to change its state.

When the user supplied explicit database names, report requested databases that
were excluded by the online filter:

```sql
SET NOCOUNT ON;

SELECT
        N'EXCLUDED' AS record_type,
        N'v:' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(nvarchar(max), d.name),
            N'%', N'%25'), N'|', N'%7C'), NCHAR(13), N'%0D'), NCHAR(10), N'%0A') AS name,
        N'v:' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(nvarchar(max), d.state_desc),
            N'%', N'%25'), N'|', N'%7C'), NCHAR(13), N'%0D'), NCHAR(10), N'%0A') AS state_desc,
        N'v:Excluded' AS migration_status,
        N'v:Source database is not ONLINE' AS reason
FROM sys.databases AS d
WHERE d.database_id > 4
    AND d.name IN (N'<requested-database-1>', N'<requested-database-2>')
    AND d.state <> 0
ORDER BY d.name;
GO
```

Continue with remaining online databases. If no requested database is online,
return `Blocked` with the excluded names and states and do not create a backup.
Each queued database must also not be a snapshot and must be available for
backup. Check `HAS_PERMS_BY_NAME(DB_NAME(), 'DATABASE', 'BACKUP DATABASE')` in
its context. Identify TDE or backup encryption certificates that must exist on
the target before restore.
