# Local backup and restore command execution — backup and restore

## Contents

- [3. Discover target hosting, then prove its SQL primary identity](#3-discover-target-hosting-then-prove-its-sql-primary-identity)
- [4. Build the database manifest and check the local path](#4-build-the-database-manifest-and-check-the-local-path)
- [5. Create and verify the local full backup](#5-create-and-verify-the-local-full-backup)
- [6. Upload the backup with AzCopy](#6-upload-the-backup-with-azcopy)
- [7. Create the target managed-identity credential](#7-create-the-target-managed-identity-credential)
- [8. Inspect paths and restore from URL](#8-inspect-paths-and-restore-from-url)
- [References](#references)

Part of the command-execution reference set for this skill. See also: references\command-execution-discovery.md.

Never connect to either the source or target with SQL login/SQL authentication.
Do not request, accept, retrieve, or use SQL passwords or SQL credentials. Use
only Windows Integrated authentication or Microsoft Entra authentication supported
by the workflow.

## 3. Discover target hosting, then prove its SQL primary identity

The target managed identity is the primary identity of the SQL Server instance or
host. It is not an identity attached to Blob Storage. Search Azure VM and
Arc-enabled server resources for the normalized host portion of `TargetServer`,
unless an exact target resource ID was supplied. This classification is
discovery, never a user-supplied platform enum.

```powershell
$targetServerHost = '<normalized-target-server-host>'
$targetHostResourceId = '<optional-target-host-resource-id>'
$targetHostTenantId = $null

if (-not $targetHostResourceId) {
    $escapedTargetHost = $targetServerHost.Replace("'", "''")
    $targetQuery = @"
resources
| where type in~ (
    'microsoft.compute/virtualmachines',
    'microsoft.hybridcompute/machines'
)
| where name =~ '$escapedTargetHost'
    or '$escapedTargetHost' startswith strcat(name, '.')
| project id, subscriptionId, resourceGroup, name, type, location
"@

    $targetCandidates = @(Invoke-TenantGraphQuery `
        -TenantId $defaultTenantId `
        -TenantSubscriptions $defaultTenantGroup[0].Group `
        -GraphQuery $targetQuery)

    if ($targetCandidates.Count -ne 1 -and -not $requestedTenantId) {
        $otherTenantGroups = @($tenantGroups | Where-Object {
            $_.Name -ne $defaultTenantId
        })
        foreach ($tenantGroup in $otherTenantGroups) {
            $targetCandidates += @(Invoke-TenantGraphQuery `
            -TenantId $tenantGroup.Name `
            -TenantSubscriptions $tenantGroup.Group `
            -GraphQuery $targetQuery)
        }
    }

    if ($targetCandidates.Count -ne 1) {
        throw 'Target discovery did not resolve exactly one Azure VM or Arc machine; include the remaining target choice or Arc prerequisite in the consolidated prompt.'
    }
    $targetHostResourceId = $targetCandidates[0].id
    $targetHostTenantId = $targetCandidates[0].tenantId
}

$targetResourceIdParts = $targetHostResourceId.Trim('/') -split '/'
if ($targetResourceIdParts.Count -lt 8 -or
        $targetResourceIdParts[0] -ine 'subscriptions' -or
        [string]::IsNullOrWhiteSpace($targetResourceIdParts[1]) -or
        $targetResourceIdParts[2] -ine 'resourceGroups' -or
        [string]::IsNullOrWhiteSpace($targetResourceIdParts[3]) -or
        $targetResourceIdParts[4] -ine 'providers' -or
        [string]::IsNullOrWhiteSpace($targetResourceIdParts[5]) -or
        [string]::IsNullOrWhiteSpace($targetResourceIdParts[6]) -or
        [string]::IsNullOrWhiteSpace($targetResourceIdParts[7])) {
    throw "Invalid Azure resource ID: '$targetHostResourceId'."
}
$targetSubscriptionId = $targetResourceIdParts[1]

try {
    & $script:AzureCliPath account set `
        --subscription $targetSubscriptionId `
        --output none
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to select the discovered target host subscription.'
    }

    $activeTargetAccount = & $script:AzureCliPath account show `
        --output json |
        ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or
        ($targetHostTenantId -and
            $activeTargetAccount.tenantId -ne $targetHostTenantId)) {
        throw 'Azure CLI did not switch to the discovered target host tenant.'
    }

    $targetHost = & $script:AzureCliPath resource show `
        --ids $targetHostResourceId `
        --subscription $targetSubscriptionId `
        --output json | ConvertFrom-Json

    if ($LASTEXITCODE -ne 0) {
        throw 'The discovered target host could not be read.'
    }

$targetSubscription = @($subscriptions | Where-Object {
    $_.id -eq $targetSubscriptionId
})
if ($targetSubscription.Count -ne 1 -or
        $targetSubscription[0].tenantId -ne $storageAccount.TenantId) {
    throw 'The target host and storage account must resolve in the same Microsoft Entra tenant.'
}

$targetHosting = switch -Regex ($targetHost.type) {
    '^Microsoft\.Compute/virtualMachines$' { 'AzureVm'; break }
    '^Microsoft\.HybridCompute/machines$' { 'Arc'; break }
    default { throw "Unsupported target resource type '$($targetHost.type)'." }
}

if ($targetHosting -eq 'AzureVm') {
    $sqlVm = & $script:AzureCliPath sql vm show `
        --name $targetHost.name `
        --resource-group $targetHost.resourceGroup `
        --subscription $targetSubscriptionId `
        --expand '*' `
        --output json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) {
        throw 'The Azure VM target is not registered with the SQL IaaS Agent extension.'
    }
    $sqlVmAzureAdAuthenticationSettings =
        $sqlVm.serverConfigurationsManagementSettings.azureAdAuthenticationSettings
    if (-not $sqlVmAzureAdAuthenticationSettings) {
        throw 'Microsoft Entra authentication is not enabled for the SQL VM target.'
    }

    $vmIdentity = & $script:AzureCliPath vm identity show `
        --name $targetHost.name `
        --resource-group $targetHost.resourceGroup `
        --subscription $targetSubscriptionId `
        --output json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) {
        throw 'The Azure VM managed identities could not be resolved.'
    }

    $primaryIdentityClientId = $sqlVmAzureAdAuthenticationSettings.clientId
    if ($primaryIdentityClientId) {
        $userAssignedIdentity = @(
            $vmIdentity.userAssignedIdentities.PSObject.Properties.Value |
                Where-Object { $_.clientId -eq $primaryIdentityClientId }
        )
        if ($userAssignedIdentity.Count -ne 1) {
            throw 'The SQL VM user-assigned primary identity is not attached to the VM.'
        }
        $principalId = $userAssignedIdentity[0].principalId
    } else {
        $principalId = $vmIdentity.principalId
    }
} else {
    $principalId = $targetHost.identity.principalId
}

    if (-not $principalId) {
        throw 'The target SQL Server primary managed identity is not enabled.'
    }

$assertedPrincipalId = '<optional-expected-primary-identity-object-id>'
    if ($assertedPrincipalId -and $principalId -ne $assertedPrincipalId) {
        throw 'The discovered target identity does not match the asserted object ID.'
    }
} finally {
    Restore-OriginalAzureCliContext
}
```

For Azure VM, also prove Microsoft Entra authentication is enabled for the SQL VM
resource. For Arc, prove SQL Server 2025 is Arc-enabled,
`msdb.dbo.SQLServerAzureArcProperties` is populated, and the Azure Extension for
SQL Server is current. A target on-premises or in another cloud is valid when it
passes the Arc checks. If it is not Arc-enabled, report Arc enrollment and SQL
primary identity enablement together as one prerequisite result. Do not edit the
registry to enable identity.

Verify or create the storage role assignment for the exact principal and scope:

```powershell
$roleName = 'Storage Blob Data Contributor'

$assignment = & $script:AzureCliPath role assignment list `
    --assignee-object-id $principalId `
    --scope $storageAccountResourceId `
    --role $roleName `
    --subscription $storageAccount.SubscriptionId `
    --output json | ConvertFrom-Json

if ($LASTEXITCODE -ne 0) {
    throw 'Unable to read the target managed identity storage role assignment.'
}

if (@($assignment).Count -eq 0) {
    & $script:AzureCliPath role assignment create `
        --assignee-object-id $principalId `
        --assignee-principal-type ServicePrincipal `
        --scope $storageAccountResourceId `
        --role $roleName `
        --subscription $storageAccount.SubscriptionId `
        --output none
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to assign Storage Blob Data Contributor to the target managed identity.'
    }
}
```

Do not broaden the role scope beyond the supplied storage account resource ID.
Role propagation can take several minutes. Retry the target's SQL metadata read
after a propagation-related authorization failure; do not issue duplicate role
assignments.

## 4. Build the database manifest and check the local path

Use one deterministic local file and one immutable Blob path:

```powershell
$databaseName = '<validated-database-name>'
$backupRoot = '<validated-local-backup-root>'
$migrationUtc = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')

# A legal SQL identifier is not necessarily a safe Windows filename or URI
# segment. Derive a separate deterministic ASCII artifact name and retain the
# database-to-artifact mapping in the manifest.
$databaseNameHash = [Convert]::ToHexString(
    [Security.Cryptography.SHA256]::HashData(
        [Text.Encoding]::UTF8.GetBytes($databaseName)
    )
).ToLowerInvariant()
$databaseArtifactName = "db-$databaseNameHash"
if ($databaseArtifactName -cnotmatch '^db-[0-9a-f]{64}$') {
    throw 'The derived database artifact name is invalid.'
}

$backupFileName = "${databaseArtifactName}_migration.bak"
$validatedBackupRoot = [IO.DirectoryInfo]::new(
    [IO.Path]::GetFullPath($backupRoot)
).FullName
$localBackupPath = [IO.Path]::GetFullPath(
    (Join-Path $validatedBackupRoot $backupFileName)
)
if (-not [string]::Equals(
        [IO.Path]::GetDirectoryName($localBackupPath),
        $validatedBackupRoot,
        [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The local backup artifact escaped the validated backup root.'
}

$encodedBlobSegments = @(
    $databaseArtifactName
    $migrationUtc
    $backupFileName
) | ForEach-Object { [Uri]::EscapeDataString($_) }
$blobUrl = "$($containerUrl.TrimEnd('/'))/$($encodedBlobSegments -join '/')"
$blobUri = [Uri]$blobUrl
if ($blobUri.Scheme -ne 'https' -or $blobUri.Query -or $blobUri.Fragment) {
    throw 'The generated Blob URL is not a safe HTTPS object URL.'
}

$manifest = [pscustomobject][ordered]@{
    SourceDatabase = $databaseName
    TargetDatabase = '<validated-target-database-name>'
    ArtifactName = $databaseArtifactName
    LocalBackupPath = $localBackupPath
    BlobUrl = $blobUrl
    OverwriteLocalBackup = [bool]::Parse('<true-or-false>')
    OverwriteExistingTarget = [bool]::Parse('<true-or-false>')
    LocalLength = $null
    LocalSha256 = $null
    AzCopyJobId = $null
    Status = 'Pending'
}

if (Test-Path -LiteralPath $localBackupPath -PathType Leaf) {
    if (-not $manifest.OverwriteLocalBackup) {
        throw "Local backup already exists: '$localBackupPath'."
    }
} elseif (-not (Test-Path -LiteralPath $validatedBackupRoot -PathType Container)) {
    throw "Local backup root does not exist: '$validatedBackupRoot'."
}
```

When collecting manifests, add this same object to the collection and mutate it
directly. Do not cast or copy an ordered dictionary while adding it, because later
status updates would affect the dictionary but leave the collected manifest
stale:

```powershell
$manifests = @()
$manifests += $manifest
$manifest.Status = 'Running'
```

Run AzCopy on this host only if it can read `$localBackupPath`. The SQL Server
service identity needs write permission to `$backupRoot`; the AzCopy user needs
read permission to the completed file. Confirm free space before backup.

## 5. Create and verify the local full backup

Materialize escaped identifiers and literals before creating the expandable SQL
batch. Do not put nested `.Replace()` expressions inside the here-string. For a
path proven absent, `$overwriteMediaOption` is empty; only an accepted
`OverwriteLocalBackup=true` adds `SKIP`:

```powershell
$escapedDatabase = $databaseName.Replace(']', ']]')
$escapedBackupPath = $localBackupPath.Replace("'", "''")
$databaseIdentifier = "[$escapedDatabase]"
$backupPathLiteral = "N'$escapedBackupPath'"

$overwriteMediaOption = if ($manifest.OverwriteLocalBackup) {
    ', SKIP'
} else {
    ''
}

$backupQuery = @"
SET NOCOUNT ON;
DECLARE @BackupPath nvarchar(4000) = $backupPathLiteral;

BACKUP DATABASE $databaseIdentifier
    TO DISK = @BackupPath
    WITH COPY_ONLY, INIT$overwriteMediaOption,
         CHECKSUM, COMPRESSION, STATS = 10;

RESTORE VERIFYONLY
    FROM DISK = @BackupPath
    WITH CHECKSUM;

RESTORE HEADERONLY
    FROM DISK = @BackupPath;
"@
```

If compression is unsupported or prohibited by an accepted policy, omit only
`COMPRESSION`. Execute `$backupQuery` through the already validated source SQL
connection with error-on-failure behavior.

Require one full database backup set for the selected database. Capture the
backup set GUID, SQL database version, LSNs, dates, and sizes with a separate
strict `BACKUP` delimited metadata row; do not serialize the row with `FOR JSON`.
Then record local file evidence on the transfer host:

```powershell
$backupFile = Get-Item -LiteralPath $localBackupPath
$manifest.LocalLength = $backupFile.Length
$manifest.LocalSha256 = (Get-FileHash -LiteralPath $localBackupPath -Algorithm SHA256).Hash
```

## 6. Upload the backup with AzCopy

The Blob URL must be HTTPS, end in the expected `.bak` name, and have no query
string. Check that the immutable destination does not already exist:

```powershell
try {
    & $script:AzureCliPath account set `
        --subscription $storageAccount.SubscriptionId `
        --output none
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to select the resolved storage subscription for upload.'
    }
    $uploadAccount = & $script:AzureCliPath account show `
        --output json |
        ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or
        [string] $uploadAccount.id -ine $storageAccount.SubscriptionId -or
        [string] $uploadAccount.tenantId -ine $storageAccount.TenantId) {
        throw 'Azure CLI did not select the resolved storage subscription and tenant for upload.'
    }

    $existingBlob = & $script:AzCopyPath list `
        $blobUrl `
        '--machine-readable' 2>&1 | Out-String
    $existingBlobExitCode = $LASTEXITCODE

    if ($existingBlobExitCode -ne 0) {
        throw "Unable to prove that the exact Blob destination is absent: '$blobUrl'."
    }
    if ($existingBlob -match 'Content Length:\s*\d+(\D|$)') {
        throw "Blob already exists: '$blobUrl'."
    }

    $copyOutput = & $script:AzCopyPath copy `
        $localBackupPath `
        $blobUrl `
        '--from-to=LocalBlob' `
        '--overwrite=false' `
        '--check-length=true' `
        '--put-md5' 2>&1 | Out-String
    $copyExitCode = $LASTEXITCODE

    $finalStatusMatches = [regex]::Matches(
    $copyOutput,
    '(?im)^[ \t]*Final Job Status:[ \t]*(?<Status>[^\r\n]+?)[ \t]*$'
)
    $fileTransferMatches = [regex]::Matches(
    $copyOutput,
    '(?im)^[ \t]*Number of File Transfers:[ \t]*(?<Count>\d+)[ \t]*$'
)
    $completedFileTransferMatches = [regex]::Matches(
    $copyOutput,
    '(?im)^[ \t]*Number of File Transfers Completed:[ \t]*(?<Count>\d+)[ \t]*$'
)
    $skippedFileTransferMatches = [regex]::Matches(
    $copyOutput,
    '(?im)^[ \t]*Number of File Transfers Skipped:[ \t]*(?<Count>\d+)[ \t]*$'
)
    $skippedTransferMatches = [regex]::Matches(
    $copyOutput,
    '(?im)^[ \t]*Number of .*Transfers Skipped:[ \t]*(?<Count>\d+)[ \t]*$'
)

    $hasExactCompletedStatus = $finalStatusMatches.Count -eq 1 -and
    $finalStatusMatches[0].Groups['Status'].Value.Trim() -ceq 'Completed'
    $hasOneCompletedFileTransfer = $fileTransferMatches.Count -eq 1 -and
    [int64] $fileTransferMatches[0].Groups['Count'].Value -eq 1 -and
    $completedFileTransferMatches.Count -eq 1 -and
    [int64] $completedFileTransferMatches[0].Groups['Count'].Value -eq 1
    $hasZeroSkippedTransfers = $skippedFileTransferMatches.Count -eq 1 -and
    [int64] $skippedFileTransferMatches[0].Groups['Count'].Value -eq 0 -and
    @($skippedTransferMatches | Where-Object {
      [int64] $_.Groups['Count'].Value -ne 0
    }).Count -eq 0

    if ($copyExitCode -ne 0 -or
    -not $hasExactCompletedStatus -or
    -not $hasOneCompletedFileTransfer -or
    -not $hasZeroSkippedTransfers) {
        throw "AzCopy upload failed. $copyOutput"
    }

    $jobMatch = [regex]::Match($copyOutput, 'Job\s+([0-9a-fA-F-]{36})')
    if ($jobMatch.Success) {
        $manifest.AzCopyJobId = $jobMatch.Groups[1].Value
    }

    $uploadedBlob = & $script:AzCopyPath list `
        $blobUrl `
        '--machine-readable' 2>&1 | Out-String
    $uploadedBlobExitCode = $LASTEXITCODE

    if ($uploadedBlobExitCode -ne 0 -or
        $uploadedBlob -notmatch "Content Length:\s*$($manifest.LocalLength)(\D|$)") {
        throw 'Uploaded Blob was not found or its content length differs from the local backup.'
    }
} finally {
    Restore-OriginalAzureCliContext
}
```

Keep AzCopy logs free of credentials and signed URLs. Record only the job ID,
sanitized URL, byte count, and final status. If the copy completed but this
verification fails, never rerun `azcopy copy`; rerun only the exact-URL
`azcopy list --machine-readable` check.

## 7. Create the target managed-identity credential

Classify and reconcile the exact URL-scoped credential in one target batch. The
credential name must be the validated lowercase container URL and fit in
`sysname`. Create it only when absent, reuse it only when both name and identity
match exactly, and stop without mutation when either value conflicts:

```sql
SET NOCOUNT ON;

DECLARE @CredentialName nvarchar(4000) =
    N'https://<account>.blob.core.windows.net/<container>';
DECLARE @ExistingName sysname;
DECLARE @ExistingIdentity nvarchar(4000);
DECLARE @CredentialState varchar(16);
DECLARE @CandidateCount int;

IF LEN(@CredentialName) > 128
BEGIN
    RAISERROR('The URL-scoped credential name exceeds the sysname limit.', 16, 1);
    RETURN;
END;

SELECT @CandidateCount = COUNT(*)
FROM sys.credentials
WHERE name COLLATE Latin1_General_100_CI_AS =
    @CredentialName COLLATE Latin1_General_100_CI_AS;

SELECT TOP (1)
    @ExistingName = name,
    @ExistingIdentity = credential_identity
FROM sys.credentials
WHERE name COLLATE Latin1_General_100_CI_AS =
    @CredentialName COLLATE Latin1_General_100_CI_AS
ORDER BY CASE
    WHEN name COLLATE Latin1_General_100_BIN2 =
        @CredentialName COLLATE Latin1_General_100_BIN2 THEN 0
    ELSE 1
END,
name;

SET @CredentialState = CASE
    WHEN @CandidateCount = 0 THEN 'Absent'
    WHEN @CandidateCount = 1
         AND @ExistingName COLLATE Latin1_General_100_BIN2 =
            @CredentialName COLLATE Latin1_General_100_BIN2
         AND @ExistingIdentity COLLATE Latin1_General_100_BIN2 =
            N'Managed Identity' COLLATE Latin1_General_100_BIN2
        THEN 'Matching'
    ELSE 'Conflicting'
END;

SELECT
    @CredentialState AS credential_state,
    @CredentialName AS expected_name,
    @ExistingName AS existing_name,
    @ExistingIdentity AS existing_identity,
    @CandidateCount AS equivalent_candidate_count;

IF @CredentialState = 'Conflicting'
BEGIN
    SELECT
        name AS conflicting_name,
        credential_identity AS conflicting_identity
    FROM sys.credentials
    WHERE name COLLATE Latin1_General_100_CI_AS =
        @CredentialName COLLATE Latin1_General_100_CI_AS
    ORDER BY name;
END;

IF @CredentialState = 'Conflicting'
BEGIN
    RAISERROR(
        'Conflicting credential. Name: %s; identity: %s. No change was made.',
        16,
        1,
        @ExistingName,
        @ExistingIdentity
    );
    RETURN;
END;

IF @CredentialState = 'Absent'
BEGIN
    -- Trace flag 4675 makes a missing primary identity visible during creation.
    DBCC TRACEON(4675);
    EXEC (
        N'CREATE CREDENTIAL ' + QUOTENAME(@CredentialName) +
        N' WITH IDENTITY = ''Managed Identity'';'
    );
END;

IF NOT EXISTS (
    SELECT 1
    FROM sys.credentials
    WHERE name COLLATE Latin1_General_100_BIN2 =
            @CredentialName COLLATE Latin1_General_100_BIN2
      AND credential_identity COLLATE Latin1_General_100_BIN2 =
            N'Managed Identity' COLLATE Latin1_General_100_BIN2
)
BEGIN
    RAISERROR('The exact managed-identity credential could not be verified.', 16, 1);
    RETURN;
END;

SELECT
    N'Matching' AS credential_state,
    name,
    credential_identity
FROM sys.credentials
WHERE name COLLATE Latin1_General_100_BIN2 =
        @CredentialName COLLATE Latin1_General_100_BIN2
  AND credential_identity COLLATE Latin1_General_100_BIN2 =
        N'Managed Identity' COLLATE Latin1_General_100_BIN2;
GO
```

Treat `Absent`, `Matching`, and `Conflicting` as the only valid classifications.
Report the exact existing name and identity for `Conflicting`, stop, and define a
separate explicitly approved repair operation before any `ALTER CREDENTIAL` or
drop. Never generate a `SECRET` clause. A missing primary identity, error 37563,
or Blob authorization error blocks this workflow.

## 8. Inspect paths and restore from URL

Build each query in PowerShell, then execute it through the already validated
target SQL connection.

Use the target managed identity for all URL reads. Materialize the escaped Blob
literal and target database forms before building any executable batch:

```powershell
$escapedBlobUrl = $blobUrl.Replace("'", "''")
$escapedTargetDatabase = $targetDatabaseName.Replace(']', ']]')
$escapedTargetDatabaseLiteral = $targetDatabaseName.Replace("'", "''")
$blobUrlLiteral = "N'$escapedBlobUrl'"
$targetDatabaseIdentifier = "[$escapedTargetDatabase]"
$targetDatabaseLiteral = "N'$escapedTargetDatabaseLiteral'"

$headerQuery = @"
RESTORE HEADERONLY FROM URL = $blobUrlLiteral;
"@

$fileListQuery = @"
RESTORE FILELISTONLY FROM URL = $blobUrlLiteral;
"@
```

Execute `$headerQuery` and then `$fileListQuery` before constructing the
mappings below.

Map every returned logical file to a complete target path. Verify each parent
directory is visible to SQL Server, each volume has sufficient free space, and no
physical file belongs to another database. Check the target database collision:

```powershell
$moveClauses = @()
$targetPathLiterals = @()
foreach ($mapping in $fileMappings) {
    $escapedLogicalName = ([string] $mapping.LogicalName).Replace("'", "''")
    $escapedTargetPath = ([string] $mapping.TargetPath).Replace("'", "''")
    $logicalNameLiteral = "N'$escapedLogicalName'"
    $targetPathLiteral = "N'$escapedTargetPath'"
    $moveClauses += "MOVE $logicalNameLiteral TO $targetPathLiteral"
    $targetPathLiterals += $targetPathLiteral
}
$moveClauseList = $moveClauses -join ",`r`n         "
$targetPathLiteralList = $targetPathLiterals -join ', '

$collisionQuery = @"
SELECT name, state_desc
FROM sys.databases
WHERE name = $targetDatabaseLiteral;

SELECT DB_NAME(database_id) AS database_name, name, physical_name
FROM sys.master_files
WHERE physical_name IN ($targetPathLiteralList);
"@
```

Run verification with the final mapping:

```powershell
$verifyQuery = @"
RESTORE VERIFYONLY
    FROM URL = $blobUrlLiteral
    WITH $moveClauseList,
         CHECKSUM;
"@
```

Add one `MOVE` for every data, log, FILESTREAM, or memory-optimized file. For a
new target database, restore without `REPLACE`:

```powershell
$restoreQuery = @"
RESTORE DATABASE $targetDatabaseIdentifier
    FROM URL = $blobUrlLiteral
    WITH $moveClauseList,
         RECOVERY, CHECKSUM, STATS = 10;
"@
```

Only when `OverwriteExistingTarget=true` was explicitly accepted may the same
statement include `REPLACE`. Show the target database and complete file mapping
immediately before execution. Do not drop the target database automatically.

Require the final state to be online. Emit this query as a strict `FINAL`
delimited row using the text-field encoding contract, then require exactly one
row and decode and type-check every field:

```powershell
$finalStateQuery = @"
SET NOCOUNT ON;

SELECT
    N'FINAL' AS record_type,
    N'v:' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(nvarchar(max), name),
        N'%', N'%25'), N'|', N'%7C'), NCHAR(13), N'%0D'), NCHAR(10), N'%0A') AS name,
    N'v:' + REPLACE(REPLACE(REPLACE(REPLACE(CONVERT(nvarchar(max), state_desc),
        N'%', N'%25'), N'|', N'%7C'), NCHAR(13), N'%0D'), NCHAR(10), N'%0A') AS state_desc,
    is_read_only,
    compatibility_level
FROM sys.databases
WHERE name = $targetDatabaseLiteral;
"@
```

Do not delete the local backup, Blob, or managed-identity credential. Report the
manifest evidence and continue to the next database only after this database is
online.

## References

- [Managed identity support for backup and restore](https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2022/microsoft-entra-managed-identity-support-for-backup-restore-database-ekm-akv)
- [SQL Server 2025 Arc backup to URL](https://learn.microsoft.com/en-us/sql/sql-server/azure-arc/backup-to-url)
- [Managed identity setup for SQL Server 2025 enabled by Azure Arc](https://learn.microsoft.com/en-us/sql/sql-server/azure-arc/microsoft-entra-authentication-with-managed-identity)
- [Microsoft Entra authentication for SQL Server on Azure VM](https://learn.microsoft.com/en-us/azure/azure-sql/virtual-machines/windows/configure-azure-ad-authentication-for-sql-vm)
- [Get AzCopy v10](https://learn.microsoft.com/en-us/azure/storage/common/storage-use-azcopy-v10)
- [Authorize AzCopy with a user identity](https://learn.microsoft.com/en-us/azure/storage/common/storage-use-azcopy-authorize-user-identity)
- [Upload files with AzCopy](https://learn.microsoft.com/en-us/azure/storage/common/storage-use-azcopy-blobs-upload)
- [Run an Azure Resource Graph query with Azure CLI](https://learn.microsoft.com/en-us/azure/governance/resource-graph/first-query-azurecli)
- [BACKUP](https://learn.microsoft.com/en-us/sql/t-sql/statements/backup-transact-sql?view=sql-server-ver17)
- [RESTORE](https://learn.microsoft.com/en-us/sql/t-sql/statements/restore-statements-transact-sql?view=sql-server-ver17)
