# Windows LRS managed identity automation

## Contents

- [1. Configuration and fail-fast checks](#1-configuration-and-fail-fast-checks)

Use this reference with the technical checks in `SKILL.md`. Run read-only discovery
first, then request one preparation consent for the displayed expected mutations;
do not confirm each covered command separately or collect a process-readiness form.
Run the complete migration lifecycle for exactly one
database at a time. Do not expand concurrency. Examples require Windows,
PowerShell 7, and the Az modules. LRS examples
deliberately contain no SAS, account key, connection string, or password
parameters. Source SQL Server backups are written only to an approved local folder
and uploaded with an Entra-authenticated AzCopy identity. Do not create a source
storage credential.


Part of the command-execution reference set for this skill. See SKILL.md for the workflow phases. See also: references\command-execution-identity-setup.md, references\command-execution-backup.md, references\command-execution-backup-job.md, references\command-execution-lrs.md, references\command-execution-cleanup.md.

Never connect to either the source or target with SQL login/SQL authentication.
Do not request, accept, retrieve, or use SQL passwords or SQL credentials. Use
only Windows Integrated authentication or Microsoft Entra authentication supported
by the workflow: the source supports Windows Integrated or Entra interactive
authentication, and the target supports Entra authentication only.

## 1. Configuration and fail-fast checks

Keep user-defined nonsecret configuration in a reviewed data file or CI/CD
variables. Discover Azure identifiers and resource properties from the signed-in
context instead of asking the user to type them. During an attended run, offer
individual fields or one pasted JSON or `Key=Value` block only for values that
cannot be discovered. Parse pasted input strictly as data; never invoke it with
`Invoke-Expression`, dot-source it, or accept arbitrary command fragments as
values. Reject unknown and duplicate keys, then include only missing or invalid
values in the initial configuration form. Never read the clipboard automatically
or accept secrets in the pasted
block.

Before discovery, require a Windows host and run Phase 0 as a strict state machine:
`SourceCaptured` -> `SourceAuthenticated` -> `DatabasesSelected` ->
`TargetCaptured`. If the request already contains a source instance, reuse it and
ask only for missing source authentication and trust choices. Do not render the
target form or ask for database names before source authentication succeeds.
Source authentication must be either Windows Integrated or Microsoft Entra ID
interactive. Target SQL MI query access may use Entra interactive authentication
or a user-supplied Entra access token.
Open each required interactive sign-in once and reuse its connection. When source
Entra interactive authentication and the target username identify the same
account, silently request and reuse the cached Windows-broker SQL-audience token
for the target connection before opening browser authentication. A Windows
Integrated source login provides no Entra token to reuse. Reuse the
existing MSSQL connection for SQL operations. For Azure operations, test cached
ARM contexts for the same username first, then allow Windows Web Account Manager
to reuse the signed-in Windows Entra session, and open browser authentication only
as the final fallback. Do not reuse a SQL Database token for ARM because Entra
access tokens are audience-bound. Do not offer
SQL authentication, collect a password, or silently fall back to another method.
The SQL MI managed identity—not the interactive query identity—authenticates LRS
to Blob Storage.

Establish and cache two SQL connections before running discovery:

1. Connect to the source with the chosen `WindowsIntegrated` or
   `EntraInteractive` method and the selected `TrustServerCertificate` value.
    Never switch methods after a failure. After connection, enumerate online user
    databases and populate a scalar single-select dropdown containing `All` and the
    query results. If one database is selected, ask whether to add another and show
    another single-select dropdown containing the remaining names plus `Done`.
    Accumulate the ordered queue internally. Never use a multi-select/array field or
    a free-text database prompt.
2. Immediately after source database selection, request
    `TargetConnectionString` and `TargetEntraUsername`. Keep the connection string
    only in memory; never echo, log, or persist it. Parse it as connection-string
    data, allow Entra interactive authentication or an embedded Entra access
    token, and reject `Password`, `PWD`, and SQL-authentication values. Connect to
    the specified target SQL MI and never infer or silently reuse another target.
    Require an Entra administrator to be configured on SQL MI, verify the signed-in
    account matches `TargetEntraUsername`, and reuse this connection for target
    checks and validation. Discover the tenant from the authenticated context; do
    not request it as user input.

The attended Azure identity used by Az PowerShell and AzCopy needs `Storage Blob
Data Contributor` only at the selected container. The SQL MI identity separately
needs `Storage Blob Data Reader` at that container. Never exchange these roles or
use the attended identity as the LRS storage identity.

The stage-specific `Key=Value` templates and equivalent JSON property names are
defined in `SKILL.md`. Do not combine source, database, and target fields into one
initial question, and never display the target template as the default UI. Accept
target paste input only when the user explicitly requests advanced paste. Do not
execute pasted PowerShell hashtables. Inventory
prerequisites first. Reuse a valid authenticated session; invoke
`Connect-AzAccount` only when authentication is required. Read-only discovery
needs no approval. The reviewed
preparation consent covers expected CurrentUser installs, SQL MI identity/RBAC/
credential setup, storage folder creation when authorized, local backups, AzCopy
uploads, and LRS start. For `Continuous` only, it also covers Agent job setup;
Autocomplete preparation explicitly includes no SQL Agent action. Prompt again only for changed scope, unexpected remediation,
cutover, or destructive stop.

Every catch boundary must immediately show the actionable sanitized error. The
previous pattern that printed only the exception type followed by “See sanitized
diagnostics” hid the actual failure and is not allowed. Remember that PowerShell
does not use a backslash to escape `$`. Never generate `\$_` or place
`-ForegroundColor` inside the message string.

The error reporter is the checked-in executable
[migration-error.ps1](migration-error.ps1). Dot-source that file before any
phase that calls `Write-MigrationError`; do not copy its implementation into a
Markdown block.

# Orchestration pseudocode — `Invoke-MigrationOperation` is an implementation
# boundary and must be implemented and wired to the validated phase functions
# before this block can execute.

The following call site is orchestration pseudocode:

```powershell-pseudocode
try {
    Invoke-MigrationOperation
}
catch {
    $failureRecord = $_
    Write-MigrationError `
        -Phase $currentPhase `
        -Operation $currentOperation `
        -DatabaseOrResource $currentDatabaseOrResource `
        -ErrorRecord $failureRecord `
        -DiagnosticsPath $sanitizedDiagnosticsPath `
        -NextAction $nextAction `
        -KnownSecrets $knownSecrets
    throw
}
```

Use the format operator as shown rather than interpolating `$_` in a quoted
string. Initialize the context variables and `$knownSecrets` before entering the
`try` block so strict mode cannot mask the original failure. Never print a
connection string, access token, password, SAS, or key from an exception. For a
bounded retry, report the first failure, the remediation being attempted, and
then either `Recovered` with verification evidence or the final `Blocked`/`Failed`
error. Never say “let me fix it” without reporting the underlying safe error and
the recovery outcome.

```powershell
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $IsWindows) {
    throw 'This migration skill supports Windows hosts only.'
}

$moduleRequirements = [ordered]@{
    'Az.Accounts'  = [version]'2.0.0'
    'Az.ResourceGraph' = [version]'0.13.0'
    'Az.Resources' = [version]'6.0.0'
    'Az.Storage'   = [version]'5.0.0'
    # Az.Sql 4.1.0 made StorageContainerSasToken optional for managed-identity LRS.
    'Az.Sql'       = [version]'4.1.0'
}

function Find-CompatibleGoSqlcmd {
    param(
        [Parameter(Mandatory)]
        [string[]]$RequiredFlags
    )

    foreach ($candidate in @(Get-Command sqlcmd -All -ErrorAction SilentlyContinue)) {
        $versionOutput = & $candidate.Source --version 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($versionOutput)) {
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
                Path          = [System.IO.Path]::GetFullPath($candidate.Source)
                Version       = $versionOutput.Trim()
                RequiredFlags = $RequiredFlags -join ', '
                HelpModes     = @(
                    if ($modernHelpSucceeded) { '--help' }
                    if ($compatibilityHelpSucceeded) { '-?' }
                ) -join ', '
            }
        }
    }
    return $null
}

$moduleStatus = foreach ($requirement in $moduleRequirements.GetEnumerator()) {
    $installed = Get-Module -ListAvailable $requirement.Key |
        Sort-Object Version -Descending |
        Select-Object -First 1
    [pscustomobject]@{
        Prerequisite = $requirement.Key
        Required     = $requirement.Value
        Installed    = if ($installed) { $installed.Version } else { $null }
        Ready        = [bool]($installed -and $installed.Version -ge $requirement.Value)
    }
}

$requiredSqlcmdFlags = @('-G', '-Q', '-b', '-r')
if ($sourceAuthentication -eq 'WindowsIntegrated') {
    $requiredSqlcmdFlags += '-E'
}
if ($trustServerCertificate) {
    $requiredSqlcmdFlags += '-C'
}
$goSqlcmd = Find-CompatibleGoSqlcmd -RequiredFlags $requiredSqlcmdFlags

$toolStatus = @(
    [pscustomobject]@{
        Prerequisite = 'PowerShell on Windows'
        Required     = [version]'7.0.0'
        Installed    = $PSVersionTable.PSVersion
        Ready        = $IsWindows -and $PSVersionTable.PSVersion -ge [version]'7.0.0'
    }
    [pscustomobject]@{
        Prerequisite = 'Go sqlcmd'
        Required     = $requiredSqlcmdFlags -join ', '
        Installed    = if ($goSqlcmd) { $goSqlcmd.Version } else { $null }
        Ready        = [bool]$goSqlcmd
    }
)

$moduleStatus + $toolStatus | Format-Table -AutoSize
if (@($moduleStatus + $toolStatus | Where-Object Ready -eq $false).Count -gt 0) {
    Write-Warning 'Prerequisites are missing. Include installation in the preparation summary.'
}
```

After preparation consent, install only missing/old Az modules and
re-run the report. Do not continue merely because installation returned exit code
zero:

```powershell
foreach ($requirement in $moduleRequirements.GetEnumerator()) {
    $installed = Get-Module -ListAvailable $requirement.Key |
        Sort-Object Version -Descending |
        Select-Object -First 1
    if (-not $installed -or $installed.Version -lt $requirement.Value) {
        Install-Module -Name $requirement.Key `
            -MinimumVersion $requirement.Value `
            -Repository PSGallery `
            -Scope CurrentUser `
            -Force
    }
}

if (-not $goSqlcmd) {
    winget install sqlcmd `
        --accept-package-agreements `
        --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        throw "Go sqlcmd installation failed with exit code $LASTEXITCODE."
    }

    $refreshedPathSegments = @(
        $env:Path
        [Environment]::GetEnvironmentVariable('Path', 'Machine')
        [Environment]::GetEnvironmentVariable('Path', 'User')
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    $env:Path = $refreshedPathSegments -join ';'
    $goSqlcmd = Find-CompatibleGoSqlcmd -RequiredFlags $requiredSqlcmdFlags
    if (-not $goSqlcmd) {
        throw 'Go sqlcmd was installed but its required capabilities could not be validated. Open a new terminal and retry.'
    }
}

$script:SqlcmdPath = $goSqlcmd.Path
```

Prefer reusable MSSQL connections for SQL execution. The validated Go `sqlcmd`
path is the fallback when a reusable connection is unavailable. Use only `-E` for
source Windows Integrated authentication or `-G` for Entra authentication. Add
`-C` only when `TrustServerCertificate=true`; omit it otherwise. Never use `-U`,
`-P`, SQL authentication, or password arguments. If `$goSqlcmd` is null,
include `winget install sqlcmd` in the preparation summary, run it only after
consent, refresh `$env:Path` from the machine and user environment because the
current process does not inherit `winget` PATH changes, then rerun
`Find-CompatibleGoSqlcmd` and stop if validation still fails.
Cache `$goSqlcmd.Path` and never invoke an unqualified `sqlcmd`. Include any Az
module install or upgrade in the same preparation summary. Authenticate
interactively only if needed. Never ask for subscription or resource group.
Resolve the connected SQL MI and named storage account through Azure Resource
Graph across all accessible subscriptions:

```powershell
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:AzureInteractiveLoginAttempted = $false

function Get-ReusableAzContext {
    param(
        [Parameter(Mandatory)]
        [string]$ExpectedAccountId
    )

    $contexts = @(
        Get-AzContext -ErrorAction SilentlyContinue
        Get-AzContext -ListAvailable -ErrorAction SilentlyContinue
    ) | Where-Object {
        $_ -and $_.Account -and $_.Tenant -and
        $_.Account.Id -ieq $ExpectedAccountId
    }

    $tested = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($context in $contexts) {
        $contextKey = '{0}|{1}|{2}|{3}' -f `
            $context.Account.Id,
            $context.Tenant.Id,
            $context.Subscription.Id,
            $context.Environment.Name
        if (-not $tested.Add($contextKey)) {
            continue
        }

        try {
            $null = Get-AzAccessToken `
                -ResourceTypeName Arm `
                -TenantId $context.Tenant.Id `
                -DefaultProfile $context `
                -ErrorAction Stop
            return Set-AzContext -Context $context -ErrorAction Stop
        } catch {
            continue
        }
    }

    if ($script:AzureInteractiveLoginAttempted) {
        throw 'The cached Azure credential cannot be refreshed; another interactive sign-in is not allowed in this run.'
    }

    $script:AzureInteractiveLoginAttempted = $true
    # On Windows, Az.Accounts asks WAM to reuse the named signed-in Entra account
    # before opening attended browser UI. This is the sole interactive fallback.
    Connect-AzAccount -AccountId $ExpectedAccountId | Out-Null
    $context = Get-AzContext -ErrorAction Stop
    if ($context.Account.Id -ine $ExpectedAccountId) {
        throw 'The authenticated Azure account does not match TargetEntraUsername.'
    }
    $null = Get-AzAccessToken `
        -ResourceTypeName Arm `
        -TenantId $context.Tenant.Id `
        -DefaultProfile $context `
        -ErrorAction Stop
    return $context
}

$migrationAzContext = Get-ReusableAzContext -ExpectedAccountId $targetEntraUsername
if ($migrationAzContext.Account.Id -ine $targetEntraUsername) {
    throw 'The authenticated Entra account does not match TargetEntraUsername.'
}

# Derive these from the successful target SQL connection.
# Never print or persist the connection string.
$targetServerFqdn = $targetSqlConnection.ServerName
$targetManagedInstanceName = ($targetServerFqdn -split '\.')[0]
if ([string]::IsNullOrWhiteSpace($targetManagedInstanceName)) {
    throw 'The connected target SQL endpoint did not yield a managed-instance name.'
}

$escapedMiName = $targetManagedInstanceName.Replace("'", "''")
$escapedMiFqdn = $targetServerFqdn.Replace("'", "''")
$miQuery = @"
resources
| where type =~ 'microsoft.sql/managedinstances'
| where name =~ '$escapedMiName'
    or tostring(properties.fullyQualifiedDomainName) =~ '$escapedMiFqdn'
| project id, subscriptionId, resourceGroup, name, location, sku,
    identity, fullyQualifiedDomainName=tostring(properties.fullyQualifiedDomainName)
"@
$managedInstanceCandidates = @(Search-AzGraph -Query $miQuery -UseTenantScope -First 100)

if ($managedInstanceCandidates.Count -ne 1) {
    # Ask now for one fallback value: the full Azure resource ID,
    # not subscription and resource group as separate inputs.
    if ([string]::IsNullOrWhiteSpace($targetManagedInstanceResourceId)) {
        throw 'ARG could not uniquely resolve the connected SQL MI. Request its full Azure resource ID.'
    }
    $resolvedMi = Get-AzResource -ResourceId $targetManagedInstanceResourceId
    if ($resolvedMi.ResourceType -ine 'Microsoft.Sql/managedInstances') {
        throw 'The supplied target resource ID is not a SQL managed instance.'
    }
    $managedInstanceCandidates = @([pscustomobject]@{
        id                       = $resolvedMi.ResourceId
        subscriptionId           = ($resolvedMi.ResourceId -split '/')[2]
        resourceGroup            = $resolvedMi.ResourceGroupName
        name                     = $resolvedMi.Name
        location                 = $resolvedMi.Location
        fullyQualifiedDomainName = $targetServerFqdn
    })
}

$managedInstanceCandidates |
    Select-Object name, subscriptionId, resourceGroup, location,
        fullyQualifiedDomainName |
    Format-Table -AutoSize
```
