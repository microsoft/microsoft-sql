# Windows LRS managed identity automation — SQL MI identity, blob validation, and source discovery

## Contents

- [2. Resolve SQL MI identity and assign container RBAC](#2-resolve-sql-mi-identity-and-assign-container-rbac)
- [3. Validate Blob access from SQL MI](#3-validate-blob-access-from-sql-mi)
- [4. Source discovery and prerequisite automation](#4-source-discovery-and-prerequisite-automation)

Part of the command-execution reference set for this skill. See SKILL.md for the workflow phases. See also: references\command-execution-setup.md, references\command-execution-identity-setup.md, references\command-execution-backup-job.md, references\command-execution-lrs.md, references\command-execution-cleanup.md.

Never connect to either the source or target with SQL login/SQL authentication.
Do not request, accept, retrieve, or use SQL passwords or SQL credentials. Use
only Windows Integrated authentication or Microsoft Entra authentication supported
by the workflow: the source supports Windows Integrated or Entra interactive
authentication, and the target supports Entra authentication only.

## 2. Resolve SQL MI identity and assign container RBAC

Resolve the SQL MI identity first. When `PrimaryUserAssignedIdentityId` is set,
require that exact resource ID in `Identity.UserAssignedIdentities` and use its
principal ID for RBAC. Treat that primary UAMI as the approved LRS identity shown
in the preparation summary; never silently substitute the system identity. Only
when no primary UAMI is configured may the workflow use an existing system identity
or include system-assigned identity enablement in the preparation summary and run
`Set-AzSqlInstance -AssignIdentity` after preparation consent. Re-read the instance
after enablement and require the selected identity's principal ID before assigning
RBAC:

Before running this block, resolve the checked-in
[migration-error.ps1](migration-error.ps1) path and dot-source it. The block
fails before any identity or RBAC mutation if the helper is unavailable, so an
RBAC exception cannot be hidden by a secondary missing-command failure.

```powershell
$migrationErrorHelperPath = '<absolute-path-to-references>/migration-error.ps1'
if (-not (Test-Path -LiteralPath $migrationErrorHelperPath -PathType Leaf)) {
    throw "Required migration error helper not found: '$migrationErrorHelperPath'."
}
. $migrationErrorHelperPath
if (-not (Get-Command Write-MigrationError -CommandType Function `
        -ErrorAction SilentlyContinue)) {
    throw 'Required Write-MigrationError helper did not load.'
}

$managedInstance = Get-AzSqlInstance `
    -ResourceGroupName $config.ResourceGroup `
    -Name $config.ManagedInstance

$primaryUserAssignedIdentityIdValue =
    $managedInstance.PrimaryUserAssignedIdentityId
$hasPrimaryUserAssignedIdentity =
    $null -ne $primaryUserAssignedIdentityIdValue
$primaryUserAssignedIdentityId =
    [string]$primaryUserAssignedIdentityIdValue
$principalId = $null
$identityType = $null
$identityResourceId = $null

if ($hasPrimaryUserAssignedIdentity) {
    if ([string]::IsNullOrWhiteSpace($primaryUserAssignedIdentityId) -or
        $primaryUserAssignedIdentityId -notmatch
            '^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.ManagedIdentity/userAssignedIdentities/[^/]+$') {
        throw 'SQL MI PrimaryUserAssignedIdentityId is present but blank or malformed. Stop without enabling or granting RBAC to a system identity.'
    }

    $primaryIdentity = $null
    $userAssignedIdentities = $managedInstance.Identity.UserAssignedIdentities
    if ($null -ne $userAssignedIdentities) {
        foreach ($entry in $userAssignedIdentities.GetEnumerator()) {
            if ([string]$entry.Key -ieq $primaryUserAssignedIdentityId) {
                $primaryIdentity = $entry.Value
                break
            }
        }
    }

    if ($null -eq $primaryIdentity) {
        throw "SQL MI primary user-assigned identity '$primaryUserAssignedIdentityId' is not present in Identity.UserAssignedIdentities. Stop without enabling or granting RBAC to a system identity."
    }

    $principalId = [string]$primaryIdentity.PrincipalId
    if ([string]::IsNullOrWhiteSpace($principalId)) {
        throw "SQL MI primary user-assigned identity '$primaryUserAssignedIdentityId' has no principal ID. Stop without enabling or granting RBAC to a system identity."
    }
    $identityType = 'UserAssigned'
    $identityResourceId = $primaryUserAssignedIdentityId
} else {
    $principalId = [string]$managedInstance.Identity.PrincipalId
    if ([string]::IsNullOrWhiteSpace($principalId)) {
        Set-AzSqlInstance `
            -ResourceGroupName $config.ResourceGroup `
            -Name $config.ManagedInstance `
            -AssignIdentity | Out-Null
        $managedInstance = Get-AzSqlInstance `
            -ResourceGroupName $config.ResourceGroup `
            -Name $config.ManagedInstance
        $principalId = [string]$managedInstance.Identity.PrincipalId
    }
    if ([string]::IsNullOrWhiteSpace($principalId)) {
        throw 'SQL MI system-assigned identity enablement completed without a principal ID.'
    }
    $identityType = 'SystemAssigned'
    $identityResourceId = [string]$managedInstance.Id
}

$storage = Get-AzStorageAccount `
    -ResourceGroupName $config.StorageResourceGroup `
    -Name $config.StorageAccount
$resolvedPrimaryBlobEndpoint = ([uri]$storage.PrimaryEndpoints.Blob).
    GetLeftPart([System.UriPartial]::Path).TrimEnd('/')
if ($resolvedPrimaryBlobEndpoint -cne $config.StorageBlobEndpoint) {
    throw 'The current storage primaryEndpoints.blob URI does not match the immutable migration configuration.'
}
$expectedCredentialName =
    "$resolvedPrimaryBlobEndpoint/$($config.ContainerBlobSegment)"
if ($expectedCredentialName -cne $config.StorageCredentialName -or
    "$expectedCredentialName/$($config.DatabaseFolderBlobSegment)" -cne
        $config.StorageContainerUri) {
    throw 'The persisted storage credential or container URI is inconsistent with primaryEndpoints.blob.'
}
$containerScope = "$($storage.Id)/blobServices/default/containers/$($config.Container)"

$existingAssignment = Get-AzRoleAssignment `
    -ObjectId $principalId `
    -RoleDefinitionName 'Storage Blob Data Reader' `
    -Scope $containerScope `
    -AtScope `
    -ErrorAction SilentlyContinue

if (-not $existingAssignment) {
    # A managed identity can take several minutes to replicate through
    # Microsoft Entra. Check once per minute for up to five attempts; never
    # broaden the role or scope to bypass propagation.
    $maximumAssignmentAttempts = 5
    for ($assignmentAttempt = 1;
         $assignmentAttempt -le $maximumAssignmentAttempts;
         $assignmentAttempt++) {
        $existingAssignment = Get-AzRoleAssignment `
            -ObjectId $principalId `
            -RoleDefinitionName 'Storage Blob Data Reader' `
            -Scope $containerScope `
            -AtScope `
            -ErrorAction SilentlyContinue
        if ($existingAssignment) {
            break
        }

        try {
            $existingAssignment = New-AzRoleAssignment `
                -ObjectId $principalId `
                -ObjectType ServicePrincipal `
                -RoleDefinitionName 'Storage Blob Data Reader' `
                -Scope $containerScope `
                -ErrorAction Stop
            break
        }
        catch {
            $failureRecord = $_
            $failureClassifierText = @(
                $failureRecord.Exception.Message
                $failureRecord.ErrorDetails.Message
                $failureRecord.FullyQualifiedErrorId
            ) -join ' '
            $isTransient = $failureClassifierText -match `
                '(?i)(PrincipalNotFound|principal[^\r\n]*not found|does not exist in the directory|timeout|temporar|\b408\b|\b429\b|\b5\d\d\b)'
            Write-MigrationError `
                -Phase 'Phase 2' `
                -Operation "Assign Storage Blob Data Reader (attempt $assignmentAttempt/$maximumAssignmentAttempts)" `
                -DatabaseOrResource $containerScope `
                -ErrorRecord $failureRecord `
                -NextAction $(if ($isTransient -and $assignmentAttempt -lt $maximumAssignmentAttempts) {
                    'Retry the exact assignment after bounded backoff.'
                } else {
                    'Save the Phase 2 checkpoint and provide exact manual RBAC assignment steps.'
                })

            if (-not $isTransient -or
                $assignmentAttempt -eq $maximumAssignmentAttempts) {
                break
            }
            Write-Host "The SQL MI service principal or role assignment may still be replicating. Waiting 60 seconds before verification attempt $($assignmentAttempt + 1)/$maximumAssignmentAttempts."
            Start-Sleep -Seconds 60
        }
    }

    $existingAssignment = Get-AzRoleAssignment `
        -ObjectId $principalId `
        -RoleDefinitionName 'Storage Blob Data Reader' `
        -Scope $containerScope `
        -AtScope `
        -ErrorAction SilentlyContinue
}

if (-not $existingAssignment) {
    throw "Automatic RBAC assignment did not succeed after the bounded replication checks. Save a Phase 2 AwaitingManualRBAC checkpoint for SQL MI principal '$principalId', exact container scope '$containerScope', and role 'Storage Blob Data Reader'; display the manual handoff below, ask the user to verify Microsoft Entra replication and the exact assignment, and return with 'RBAC assignment complete' to retry verification without recreating resources."
}
```

When the final automatic assignment attempt fails, immediately show this manual
handoff with the real nonsecret values substituted. Do not ask the user to widen
the scope or select another role:

1. **Azure portal:** Open the resolved storage account, select **Data storage >
   Containers > `<container>` > Access control (IAM) > Add role assignment**.
2. Select **Storage Blob Data Reader**. Under **Assign access to**, select
    **Managed identity**. For `SystemAssigned`, choose **SQL managed instance** and
    select `<managed-instance>`. For `UserAssigned`, choose **User assigned managed
    identity** and select the exact displayed primary UAMI resource ID. Complete
    the assignment only after its object ID matches the displayed principal ID.
3. Confirm that the assignment scope shown by the portal is the target container,
   not the storage account, resource group, or subscription.
4. Alternatively, an administrator with role-assignment permission can run the
   following in PowerShell using the displayed principal ID and scope:

```powershell
$manualPrincipalId = '<sql-mi-principal-id>'
$manualContainerScope = '<exact-container-resource-id>'

New-AzRoleAssignment `
    -ObjectId $manualPrincipalId `
    -ObjectType ServicePrincipal `
    -RoleDefinitionName 'Storage Blob Data Reader' `
    -Scope $manualContainerScope `
    -ErrorAction Stop

Get-AzRoleAssignment `
    -ObjectId $manualPrincipalId `
    -RoleDefinitionName 'Storage Blob Data Reader' `
    -Scope $manualContainerScope `
    -AtScope `
    -ErrorAction Stop |
    Select-Object ObjectId, RoleDefinitionName, Scope
```

Save the queue position, database, SQL MI resource ID, selected identity type,
selected identity resource ID and principal ID, storage container scope, completed
phases, and existing LRS operation identity when one exists. Report
`Blocked — awaiting manual RBAC` and ask the user to return with
“RBAC assignment complete.” Do not continue in the same turn by assuming the
manual action happened.

When the user returns, reload that checkpoint and reuse the cached authentication.
Run `Get-AzRoleAssignment` with the exact object ID, role, and scope. A role inherited
from a broader scope does not satisfy this workflow. If the exact assignment is
present, rerun the SQL MI `RESTORE HEADERONLY` Blob access test. If LRS already
exists, query that operation and continue monitoring it; never start a duplicate
LRS operation. Resume at the next incomplete action only after the assignment and
data-plane access test both pass. Otherwise remain blocked and show the precise
missing or mismatched value.

For a user-assigned identity, the approved identity is SQL MI's configured
`PrimaryUserAssignedIdentityId`. Require that exact resource ID and its principal
ID from `Identity.UserAssignedIdentities`, and use that principal ID in the same
container-scoped assignment. Do not silently fall back to the system identity.

RBAC can take time to propagate. Retry the access test with bounded exponential
backoff; never broaden the role to make propagation faster.

## 3. Validate Blob access from SQL MI

Upload one valid, non-sensitive test backup to the database folder first. Execute
the following on SQL MI using an approved Entra-authenticated query tool. Quote and
validate identifiers in the automation layer; never concatenate untrusted input.

The credential name must be `$config.StorageCredentialName`: the exact container
URL derived from the resolved storage account's `PrimaryEndpoints.Blob`, without
a trailing slash, database folder, or backup file. Render the scalar placeholder
below from that immutable value; never reconstruct the hostname or endpoint
suffix. Never create a generic name such as `AzureBlobCredential`. Reconcile and
verify the credential under preparation consent:

```sql
USE master;
GO
DECLARE @CredentialName nvarchar(4000) =
    N'<storage-credential-name-from-config>';
DECLARE @ExistingName sysname;
DECLARE @ExistingIdentity nvarchar(4000);
DECLARE @EquivalentCandidateCount int;
DECLARE @CredentialState varchar(16);
DECLARE @CreateCredentialSql nvarchar(max);

IF LEN(@CredentialName) > 128
BEGIN
    RAISERROR('The URL-scoped credential name exceeds the sysname limit.', 16, 1);
    RETURN;
END

SELECT @EquivalentCandidateCount = COUNT(*)
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
    WHEN @EquivalentCandidateCount = 0 THEN 'Absent'
    WHEN @EquivalentCandidateCount = 1
         AND @ExistingName COLLATE Latin1_General_100_BIN2 =
            @CredentialName COLLATE Latin1_General_100_BIN2
         AND @ExistingIdentity COLLATE Latin1_General_100_BIN2 =
            N'MANAGED IDENTITY' COLLATE Latin1_General_100_BIN2
        THEN 'Matching'
    ELSE 'Conflicting'
END;

SELECT
    @CredentialState AS credential_state,
    @CredentialName AS expected_name,
    @ExistingName AS existing_name,
    @ExistingIdentity AS existing_identity,
    @EquivalentCandidateCount AS equivalent_candidate_count;

IF @CredentialState = 'Conflicting'
BEGIN
    SELECT
        name AS conflicting_name,
        credential_identity AS conflicting_identity
    FROM sys.credentials
    WHERE name COLLATE Latin1_General_100_CI_AS =
        @CredentialName COLLATE Latin1_General_100_CI_AS
    ORDER BY name;

    RAISERROR('A conflicting URL-scoped credential exists. No change was made.', 16, 1);
    RETURN;
END;

IF @CredentialState = 'Absent'
BEGIN
    SET @CreateCredentialSql =
        N'CREATE CREDENTIAL ' + QUOTENAME(@CredentialName) +
        N' WITH IDENTITY = ''MANAGED IDENTITY'';';
    EXEC sys.sp_executesql @CreateCredentialSql;
END;

-- Reclassify from authoritative state after the possible create. This detects
-- a concurrent case-variant or wrong-identity credential before Blob access.
SET @ExistingName = NULL;
SET @ExistingIdentity = NULL;

SELECT @EquivalentCandidateCount = COUNT(*)
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
    WHEN @EquivalentCandidateCount = 1
         AND @ExistingName COLLATE Latin1_General_100_BIN2 =
            @CredentialName COLLATE Latin1_General_100_BIN2
         AND @ExistingIdentity COLLATE Latin1_General_100_BIN2 =
            N'MANAGED IDENTITY' COLLATE Latin1_General_100_BIN2
        THEN 'Matching'
    ELSE 'Conflicting'
END;

IF @CredentialState <> 'Matching'
BEGIN
    SELECT
        @CredentialState AS credential_state,
        name AS conflicting_name,
        credential_identity AS conflicting_identity,
        @EquivalentCandidateCount AS equivalent_candidate_count
    FROM sys.credentials
    WHERE name COLLATE Latin1_General_100_CI_AS =
        @CredentialName COLLATE Latin1_General_100_CI_AS;

    RAISERROR('The exact URL-scoped managed-identity credential could not be verified. No further change was made.', 16, 1);
    RETURN;
END;
GO

RESTORE HEADERONLY
    FROM URL = '<storage-container-uri-from-config>/<test-file>.bak';
GO
```

Treat `Absent`, `Matching`, and `Conflicting` as the only valid credential states.
Create only for `Absent`, reuse only for `Matching`, and for `Conflicting` report
the exact existing credential name and identity and stop without altering or
dropping it. Credential repair is a separate mutation that must be defined and
explicitly approved before execution.

The credential has no secret. If `RESTORE HEADERONLY` reports a missing or invalid
credential, show the sanitized SQL error and rerun the non-mutating classification
above. Retry `RESTORE HEADERONLY` once only when the resulting state is `Matching`;
an `Absent` or `Conflicting` state requires a separate explicitly approved action.
On success report `Recovered`. On a second failure, show the final SQL error and
stop as `Blocked`. Do not ask the user to execute corrected SQL manually. For
noncredential failures, diagnose role scope, identity selection, firewall/service
endpoint configuration, URI spelling, and RBAC propagation rather than recreating
the credential.

## 4. Source discovery and prerequisite automation

Capture source prerequisites:

```sql
SELECT
    SERVERPROPERTY('ProductVersion') AS product_version,
    SERVERPROPERTY('Edition') AS edition;

SELECT
    name,
    state_desc,
    recovery_model_desc,
    collation_name,
    is_broker_enabled
FROM sys.databases
WHERE name = N'<source-database>';

DECLARE @ProductVersion varchar(32) =
    CONVERT(varchar(32), SERVERPROPERTY('ProductVersion'));
DECLARE @ProductMajor int =
    CONVERT(int, LEFT(@ProductVersion, CHARINDEX('.', @ProductVersion + '.') - 1));

IF @ProductMajor >= 15
BEGIN
    EXEC sys.sp_executesql N'
        SELECT
            name,
            is_accelerated_database_recovery_on
        FROM sys.databases
        WHERE name = N''<source-database>'';';
END;
GO
```

For both modes, collect Database Engine service-account and backup-permission
evidence. Collect SQL Server Agent service state only for `Continuous`; render
`<continuous-mode-bit>` as `1` only for that mode and `0` for `Autocomplete`.
`sys.dm_server_services` is unavailable on SQL Server 2008 (10.0), so bind it only
inside dynamic SQL on supported versions. For 10.0, call `xp_servicecontrol` only
when the continuous-mode bit is `1`; use the instance-aware registry reader to
resolve the Database Engine service account in both modes. Failure or lack of
permission for an applicable probe is a blocker to automated validation, not
evidence that Agent is running or that the backup root is writable. Autocomplete
must not query Agent service state, jobs, or history.

```sql
DECLARE @ProductVersion varchar(32) =
    CONVERT(varchar(32), SERVERPROPERTY('ProductVersion'));
DECLARE @ProductMajor int =
    CONVERT(int, LEFT(@ProductVersion, CHARINDEX('.', @ProductVersion + '.') - 1));
DECLARE @CollectAgentState bit = <continuous-mode-bit>;

IF @ProductMajor >= 11
BEGIN
    EXEC sys.sp_executesql N'
        SELECT
            servicename,
            startup_type_desc,
            status_desc,
            service_account
        FROM sys.dm_server_services
        WHERE servicename LIKE N''SQL Server (%''
           OR (@CollectAgentState = 1
               AND servicename LIKE N''SQL Server Agent%'');',
        N'@CollectAgentState bit',
        @CollectAgentState;
END;
ELSE
BEGIN
    IF @CollectAgentState = 1
    BEGIN
        CREATE TABLE #AgentServiceState
        (
            status_desc nvarchar(128) NOT NULL
        );

        INSERT #AgentServiceState (status_desc)
            EXEC master.dbo.xp_servicecontrol N'QUERYSTATE', N'SQLServerAgent';

        SELECT
            N'SQLServerAgent' AS servicename,
            CAST(NULL AS nvarchar(60)) AS startup_type_desc,
            status_desc,
            CAST(NULL AS nvarchar(256)) AS service_account
        FROM #AgentServiceState;
    END;

    DECLARE @DatabaseEngineServiceAccount nvarchar(256);
    EXEC master.dbo.xp_instance_regread
        N'HKEY_LOCAL_MACHINE',
        N'SYSTEM\CurrentControlSet\Services\MSSQLSERVER',
        N'ObjectName',
        @DatabaseEngineServiceAccount OUTPUT;

    SELECT
        N'SQL Server Database Engine' AS servicename,
        CAST(NULL AS nvarchar(60)) AS startup_type_desc,
        CAST(NULL AS nvarchar(60)) AS status_desc,
        @DatabaseEngineServiceAccount AS service_account;
END;

SELECT
    HAS_PERMS_BY_NAME(N'<source-database>', N'DATABASE', N'BACKUP DATABASE')
        AS can_backup_database,
    IS_SRVROLEMEMBER(N'sysadmin') AS is_sysadmin;
GO
```

Include expected recovery-model and ADR/Service Broker changes in
the preparation summary. Prompt separately only when discovery reveals remediation
outside that summary. After changing from `SIMPLE` to `FULL`,
establish a new full backup before taking log backups.

Resolve the database's local folder canonically beneath the approved local backup
root. Reject traversal, rooted database-folder values, and any resolved path that
is not contained by that root. Run one uniquely named local test backup, verify
it locally, and upload it with AzCopy. In `Continuous`, complete this before job
creation; Autocomplete never creates a job.

Create and preserve this exact one-level layout for every backup type:

```text
<LocalBackupRoot>\<DatabaseName>\<backup-file>
<primaryEndpoints.blob><container>/<DatabaseName>/<backup-file>
```

The Blob database folder is supported and required by this workflow. Set LRS
`StorageContainerUri` to that folder URI derived from the persisted
`StorageCredentialName`. Use that same immutable URI for AzCopy destinations and
Blob validation. Do not flatten files into the container root and do not introduce
child folders below the database folder.

```sql
BACKUP DATABASE [<source-database>]
    TO DISK = N'<approved-local-root>\<database-folder>\<database>_full_<utc>.bak'
    WITH COMPRESSION, CHECKSUM, STATS = 5;
GO

BACKUP DATABASE [<source-database>]
    TO DISK = N'<approved-local-root>\<database-folder>\<database>_diff_<utc>.diff'
    WITH DIFFERENTIAL, COMPRESSION, CHECKSUM, STATS = 5;
GO

BACKUP LOG [<source-database>]
    TO DISK = N'<approved-local-root>\<database-folder>\<database>_log_<utc>.trn'
    WITH COMPRESSION, CHECKSUM, STATS = 5;
GO

RESTORE VERIFYONLY
    FROM DISK = N'<approved-local-root>\<database-folder>\<backup-file>'
    WITH CHECKSUM;
GO
```

Use unique UTC-based immutable names. A log backup must have one destination file.
At scale, stripe full and differential backups across a controlled number of files,
but avoid thousands of files.

Build the manifest from `RESTORE HEADERONLY` output and `msdb` backup history. The
technical chain validator must ensure:

- one database and recovery fork;
- a full base before each differential/log sequence;
- each differential references the selected full database backup LSN;
- transaction log `FirstLSN`/`LastLSN` coverage has no gap;
- every file passed `RESTORE VERIFYONLY WITH CHECKSUM`;
- file names are unique and map one-to-one to uploaded blobs.

Do not sort the restore chain by file name alone. Use backup metadata and finish
time, with LSN continuity as the authority.
