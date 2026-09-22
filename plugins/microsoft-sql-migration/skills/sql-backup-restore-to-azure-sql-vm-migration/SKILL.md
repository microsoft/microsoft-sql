---
name: sql-backup-restore-to-azure-sql-vm-migration
description: "Migrate a SQL Server 2008 through SQL Server 2025 source to a SQL Server 2025 target wherever it runs, including SQL Server on Azure VM, by creating a local full backup, uploading it to Azure Blob Storage with AzCopy and the operator's Microsoft Entra identity, and restoring from URL with the target SQL Server managed identity. Sources newer than SQL Server 2025 are blocked because target restore compatibility has not been validated. Use for SQL-to-SQL, local-backup, AzCopy, managed-identity, Azure SQL VM, or SQL Server 2025 restore migrations."
---

# Local backup and AzCopy migration to SQL Server 2025

## When to Use

- Migrate SQL Server 2008 through SQL Server 2025 to a SQL Server 2025 target using backup and restore.
- Move a local full backup through Azure Blob Storage with AzCopy and restore it with the target managed identity.
- Do not use for a generic SQL Server backup migration to Azure when the destination platform or migration method is unspecified; ask the user to clarify.

Migrate one database or an ordered set of user databases from SQL Server 2008
through SQL Server 2025 to a SQL Server 2025 target running in Azure,
on-premises, or in another cloud. Sources newer than SQL Server 2025 are blocked
because target restore compatibility has not been validated.
Create each full backup on a local source volume, upload the file to a private
Azure Blob container with AzCopy v10 and the signed-in operator's Microsoft Entra
identity, then restore it from URL with the target SQL Server primary managed
identity.

Read [references/command-execution-discovery.md](references/command-execution-discovery.md) and
[references/command-execution-backup-restore.md](references/command-execution-backup-restore.md)
before generating or running commands.

## Operating contract

- Process one database completely before starting the next. `All` never includes
  `master`, `model`, `msdb`, or `tempdb`.
- Build the migration queue only from source user databases whose state is
  `ONLINE`. Exclude `OFFLINE`, `SUSPECT`, `RESTORING`, `RECOVERING`,
  `RECOVERY_PENDING`, `EMERGENCY`, and every other non-online state. Never change
  a database's state to make it eligible.
- Use exactly one backup artifact per database: a `COPY_ONLY` full database
  backup. This workflow does not alter source availability or recovery state.
- Back up only to a local disk path visible to the source SQL Server service.
  Never use `BACKUP TO URL` on the source.
- Run AzCopy on the source host, or on an approved transfer host that can read the
  exact backup path without copying the file through the chat host.
- Use only the operator's Microsoft Entra identity for AzCopy. Never use storage
  account keys, connection strings, signed URL query parameters, or embedded
  secrets.
- Require a pre-created private HTTPS Blob container. Do not create or make a
  container public.
- Gate the target on SQL Server 2025: `ProductMajorVersion` must equal `17`.
  Newer or older major versions do not satisfy this explicit gate.
- Supported source versions are SQL Server 2008 through SQL Server 2025,
  represented by major versions `10` through `17`. Block older sources and
  sources newer than SQL Server 2025 because target restore compatibility has
  not been validated outside that range.
- Support the target in any physical or cloud location, but require Windows
  because SQL Server server-level managed identity is not supported on Linux.
  Failover cluster instances remain unsupported.
- Determine target hosting from SQL and Azure discovery; do not ask the user to
  classify the target. For SQL Server on Azure VM, use its SQL IaaS Agent and
  Microsoft Entra configuration. For SQL Server elsewhere, use SQL Server 2025
  enabled by Azure Arc with the latest Azure Extension for SQL Server. The SQL
  version gate is identical in every location.
- Require a primary managed identity configured for the target SQL Server
  instance. A target outside Azure that is not enabled by Azure Arc is a single
  prerequisite blocker, not a different migration route.
- Blob Storage does not receive a managed identity. Assign the target SQL
  instance's primary managed-identity principal `Storage Blob Data Contributor`
  on the storage account, then create the URL-scoped SQL credential with
  `IDENTITY = 'Managed Identity'` on the target.
- Do not provide an alternate Blob authentication route. If user upload access,
  target identity configuration, target RBAC, network access, credential
  creation, or URL restore fails, stop with the exact failure.
- Never overwrite a local backup file unless `OverwriteLocalBackup=true` was
  explicitly included in the accepted plan. Never append a migration backup to
  an existing media set.
- Never overwrite a target database or physical database file unless
  `OverwriteExistingTarget=true` was explicitly accepted after displaying the
  target database and affected files.
- Always use `CHECKSUM`, `COPY_ONLY`, and `STATS = 10`; use `COMPRESSION` when
  supported and not prohibited by policy.
- Verify the local backup before upload. After upload, use target
  `RESTORE HEADERONLY`, `RESTORE FILELISTONLY`, and `RESTORE VERIFYONLY` before
  `RESTORE DATABASE`.
- Preserve local and Blob backup files after migration. Do not delete either
  automatically.
- If upload succeeds but post-upload verification fails, never retry the upload.
  Rerun only the non-destructive exact-Blob listing and stop if it cannot prove
  the expected content length.
- Stop on the first failed gate or operation. Never describe a submitted command
  as complete until its exit status or SQL result proves completion.

## Consolidated intake

The source discovered from `SourceServer` must be SQL Server 2008 through SQL
Server 2025 (major version `10` through `17`). Do not offer this workflow for a
source outside that range.

Accept natural language, one `Key=Value` block, or a JSON object with these exact
keys. Accumulate everything the user provides, run discovery for omitted values,
and ask at most one consolidated follow-up listing all fields that remain
ambiguous or undiscoverable. Never ask for source, target, storage, identity, or
overwrite values as separate questions. Parse pasted structured input strictly
as data, reject duplicate keys, and reject unknown keys as likely typos.

Treat a complete initial `Key=Value` block as the consolidated intake. When all
required undiscoverable values are present, do not ask an intake question; run
discovery and proceed to the mandatory sanitized execution-plan approval.
Resolve `TrustServerCertificate` to an explicit Boolean before attempting either
SQL connection. Use one consolidated intake block containing the source, target,
storage, database-scope, and overwrite fields. Source and target authentication
must be `Windows` or `Entra` interactive authentication; no other login type is
supported. For Entra interactive authentication, use the approved interactive
sign-in flow and do not place an access token in command arguments. Validate both
connections with the resolved authentication method and certificate setting
before proceeding to backup or restore operations.

```text
SourceServer=<source>
SourceDatabases=All
TargetServer=<target>
StorageAccountName=<storage-account>
ContainerName=<private-container>
TrustServerCertificate=false
```

```text
SourceServer=
SourceAuthentication=Windows|Entra
SourceUser=
SourceDatabases=All
TargetServer=
TargetAuthentication=Windows|Entra
TargetUser=
TargetDatabase=
LocalBackupRoot=
OverwriteLocalBackup=false
ContainerUrl=
StorageAccountName=
ContainerName=
StorageAccountResourceId=
AzureTenantId=
TargetHostResourceId=
TargetManagedIdentityPrincipalId=
TargetDataPath=
TargetLogPath=
OverwriteExistingTarget=false
TrustServerCertificate=false
```

Apply these defaults and requirements:

| Key | Handling |
| --- | --- |
| `SourceServer`, `TargetServer` | Required after the single consolidated intake |
| `SourceAuthentication`, `TargetAuthentication` | Default to `Windows` |
| `SourceUser`, `TargetUser` | Required only for `Entra` |
| `SourceDatabases` | Discover only online user databases; accept one, a comma-separated list, or `All`; report explicitly named non-online databases as excluded |
| `TargetDatabase` | Optional for one database; preserve source names for multiple databases |
| `LocalBackupRoot` | Default to the discovered source `InstanceDefaultBackupPath` |
| `OverwriteLocalBackup` | Default to `false` |
| `ContainerUrl` | Preferred; when absent, derive it from `StorageAccountName` and `ContainerName` |
| `StorageAccountName` | Optional when `ContainerUrl` is supplied; treat a user-supplied "Blob storage name" as this Azure storage account name |
| `ContainerName` | Required after discovery; treat an existing user-supplied Blob container name as this value and search accessible storage accounts for its unique owner |
| `StorageAccountResourceId` | Optional; use Azure Resource Graph to discover it by storage account name, querying the default tenant first |
| `AzureTenantId` | Optional; derive from the selected Azure CLI subscription/account |
| `TargetHostResourceId` | Optional; discover the Azure VM or Arc-enabled server from `TargetServer` across accessible subscriptions |
| `TargetManagedIdentityPrincipalId` | Optional assertion; discover the target primary identity object ID and require an exact match when supplied |
| `TargetDataPath`, `TargetLogPath` | Optional; use validated target defaults |
| `OverwriteExistingTarget` | Default to `false` |
| `TrustServerCertificate` | Default to `false` |

Discover SQL versions, editions, defaults, and database metadata instead of
asking for them. Never connect to either the source or target with SQL login/SQL
authentication. Do not request, accept, retrieve, or use SQL passwords or SQL
credentials. Use only Windows Integrated authentication or Microsoft Entra
authentication supported by the workflow. Never read SQL credentials from Key
Vault or Credential Manager, or display a password prompt.

Normalize a supplied `ContainerUrl` by extracting its storage account and
container names. Group enabled subscriptions by tenant. For each tenant query,
select one subscription with `az account set`, confirm the active tenant with
`az account show`, and run `az graph query` without `--tenant` or
`--subscriptions`. Parse results from `response.data` and filter them against the
known enabled subscription IDs for that tenant. Query the current/default tenant
first and query other signed-in tenants only if the account is not uniquely found
there or the user supplied a different tenant. Reuse the same tenant-scoped ARG
helper for storage-account and target-host discovery. Use
`az storage account show` only for the one matched resource
to read its `primaryEndpoints.blob` URI, then combine that URI with the validated
container name. When only a container name is supplied,
search accessible storage accounts with the user's Entra data-plane access and
select its owner only if the match is unique. The destination backup Blob object
name is generated later; do not confuse it with the container name. Never
construct an endpoint suffix by assumption; this preserves sovereign-cloud
endpoints.

After discovery, display one sanitized execution plan containing endpoint names,
database scope, local and Blob paths, overwrite choices, discovered target hosting
and identity, target host and storage resource IDs, and authentication methods.
Ask once for migration execution acceptance. If discovery leaves multiple
storage accounts, containers, subscriptions, or target hosts, present all
remaining choices together in that same prompt.
Changing an overwrite value from `false` to `true` requires a new explicit
acceptance.

Validate execution-plan responses as typed data before acting. Never coerce a
free-form string in `OverwriteLocalBackup`, `OverwriteExistingTarget`, or an
approval field to Boolean. If an overwrite response contains a path, treat it as
a proposed `LocalBackupRoot` change, rerun path and collision discovery, and
display a revised plan for acceptance. Likewise, a requested database exclusion
changes the migration scope and requires revised plan acceptance.

## Tool prerequisites

Require all of the following on the host where each command runs:

- Go `sqlcmd`, selected from every PATH candidate by a successful `--version`
  check and the required flags across modern (`--help`) and SQLCMD-compatible
  (`-?`) help for Windows Integrated and Microsoft Entra authentication.
- AzCopy v10 on the transfer host, validated with `azcopy --version`.
- Azure CLI on the transfer/administration host, validated with `az version`.
- Azure CLI `resource-graph` extension, validated with
  `az extension show --name resource-graph`. Install it with
  `az extension add --name resource-graph` before Azure discovery.

Transport SQL query results as strict pipe-delimited rows produced by `sqlcmd`
with headers disabled. Do not use `FOR JSON`, `FOR XML`, or formatted console
tables as a SQL-to-PowerShell serialization format. Prefix each row with a stable
record type, encode nullable text fields as specified in
`references/command-execution-discovery.md`, require the exact field count for that record
type, and convert numeric and Boolean fields explicitly. This restriction applies
to SQL result sets only; Azure CLI JSON output remains the required format for
Azure control-plane responses.

Detect the tools before collecting execution acceptance. If AzCopy v10 or Azure
CLI is missing, return `Needs input`, give the official Microsoft Learn install
link, and ask the user to install it. If the `resource-graph` extension is
missing, return `Needs input` with the exact extension install command and the
Microsoft Learn Azure Resource Graph CLI link. Do not install tools, extensions,
portable binaries, or package managers silently. Cache each validated canonical
executable path for the run.

Use one interactive Azure CLI user sign-in only when no usable session exists.
Derive the tenant from the selected subscription unless the user supplied an
assertion. Configure AzCopy to reuse that user session with
`AZCOPY_AUTO_LOGIN_TYPE=AZCLI` and `AZCOPY_TENANT_ID`. Do not run a separate
service-principal or managed-identity AzCopy login.

The signed-in user needs `Storage Blob Data Contributor` on the destination
container or storage account to upload. The user also needs permission to read
and, when absent, create the target identity's storage role assignment. If the
role assignment cannot be created, report the required principal, role, scope,
and exact Azure error; do not elevate or substitute credentials.

## Workflow

```text
Phase 0  Parse one intake; gate tools and sign-in; resolve storage and target host
Phase 1  Connect; require source ProductMajorVersion = 10..17 and target = 17
Phase 2  Prove target primary managed identity and storage role assignment
Phase 3  Build one database manifest and resolve local overwrite behavior
Phase 4  Create and verify one COPY_ONLY full backup on local disk
Phase 5  Upload the backup with AzCopy under the operator's Entra identity
Phase 6  Create and verify the target managed-identity URL credential
Phase 7  Inspect, verify, map, and restore the backup from URL
Phase 8  Report completion and continue with the next database
```

## Phase requirements

### Phase 0 - Tools and authentication

Validate and cache tool paths once. Connect independently to source and target
using Windows Integrated or direct Microsoft Entra SQL authentication. Require
encrypted SQL transport and certificate validation unless the accepted plan sets
`TrustServerCertificate=true`.

Resolve `TrustServerCertificate` before constructing or attempting either SQL
connection. Do not use a failed connection as a prompt to decide certificate
trust.

Authenticate the user to Azure CLI once and make AzCopy reuse that session.
Use Azure Resource Graph name filters for storage account and target-resource
discovery instead of enumerating each subscription. Search the current/default
tenant first and widen to other signed-in tenants only when needed. Cache
discovery for the complete multi-database run. Before any cross-subscription or
cross-tenant discovery, capture the original Azure CLI subscription and tenant.
Restore that subscription in a `finally` block after every temporary context
switch and use `az account show` to prove both the original subscription and
tenant were restored. Later operations must either pass their resolved
subscription explicitly or use the same temporary-switch-and-restore pattern;
never inherit whichever context a discovery probe happened to select.

### Phase 1 - SQL discovery and target gate

Discover both instances and online source user databases. `All` expands only to
the online result set. Omit every non-online database from the migration queue;
if the user explicitly named one, report its current state as `Excluded` without
blocking the remaining online databases. Block unless the target is
SQL Server 2025 major version `17`, is not Azure SQL Managed Instance, and is not
a failover cluster instance. On the target, read `host_platform` from
`sys.dm_os_host_info` and require its value to equal `Windows`; do not use
`SERVERPROPERTY('HostPlatform')` as the authoritative gate because it can return
`NULL`. Location does not otherwise affect eligibility. A source backup from a
newer SQL major version also blocks restore.

Discover the source default backup path with
`SERVERPROPERTY('InstanceDefaultBackupPath')`. When it returns `NULL`, including
on SQL Server 2016, read `BackupDirectory` with
`master.dbo.xp_instance_regread`. Validate that the resolved directory exists,
is visible to the SQL Server service, and has sufficient free space.

Check source backup permission, local path visibility and free space, target
restore permission, target paths and free space, encryption dependencies, and
target database/file collisions.

Resolve every known local-file, target-database, and target-physical-file
collision before starting the first database. For an `All` plan, do not migrate
earlier databases while a later database has an unresolved collision. Obtain
explicit overwrite acceptance, accept an explicitly revised scope that excludes
the colliding database, or return `Blocked`.

### Phase 2 - Identity and storage

Infer target hosting from the uniquely discovered Azure resource. For an Azure
VM, prove SQL IaaS Agent registration and a configured SQL primary managed
identity. Otherwise require a SQL Server 2025 enabled by Azure Arc resource, the
latest Azure Extension for SQL Server, and its primary managed identity. A
physical server or VM in any other environment is supported through Arc; do not
reject it merely because it is not an Azure VM.

When `TargetManagedIdentityPrincipalId` was supplied, require an exact object-ID
match. If Arc enrollment or the SQL primary identity is missing, return one
`Needs input` result containing every missing prerequisite and the Microsoft
Learn portal steps. Do not automate the documented registry route.

Verify or create `Storage Blob Data Contributor` for that principal at
`StorageAccountResourceId`. Wait for role propagation by retrying the
non-destructive target metadata read only after credential creation; do not use
arbitrary sleep loops.

### Phase 3 - Manifest and overwrite decision

Use one deterministic file per database:

```text
<LocalBackupRoot>\<validated-database-artifact-name>_migration.bak
<ResolvedContainerUrl>/<encoded-artifact-name>/<encoded-migration-utc>/<encoded-backup-file-name>
```

Never interpolate a SQL database name directly into a filesystem path or Blob
URL. Derive a separate deterministic ASCII artifact name, validate it against a
strict allowlist, retain its mapping to the source and target database names in
the manifest, and verify the resolved local file remains directly beneath
`LocalBackupRoot`. Percent-encode each Blob object path segment independently;
do not encode the complete URL as one string and do not allow a database name to
introduce `/`, `\`, `#`, `%`, a query, or a fragment.

If the local file exists and `OverwriteLocalBackup=false`, stop before backup and
ask for a different root or explicit overwrite acceptance. If overwrite is
accepted, use `INIT, SKIP`; otherwise use `INIT` only for a path proven absent.
Never append with `NOINIT`.

### Phase 4 - Local backup

Run `BACKUP DATABASE ... TO DISK`, followed by local `RESTORE VERIFYONLY` and
`RESTORE HEADERONLY`. Record the database name, backup type, backup start/finish,
backup set GUID, database version, first/last LSN, size, local path, and file hash.
Materialize escaped SQL identifiers and literals in PowerShell before creating an
expandable here-string. Do not put nested `.Replace()` expressions inside the
here-string, and pass the backup path through a T-SQL variable.

### Phase 5 - AzCopy upload

Use `azcopy copy` for the single file with an HTTPS destination that contains no
query string. Set `--from-to=LocalBlob`, `--overwrite=false`, and
`--check-length=true`. Require exit code zero, exactly one
`Final Job Status: Completed` line, exactly one completed file transfer, and zero
for every reported skipped-transfer count. Reject prefix statuses such as
`CompletedWithSkipped`. Then use
Entra-authenticated `azcopy list` to prove the exact Blob exists and its content
length equals the local file length. Use `--machine-readable` for exact-URL
listings; do not use a valueless `--properties` option. Treat a successful exact
listing containing the expected `Content Length` as proof even when AzCopy omits
the filename. A pre-existing Blob path blocks the run. If post-upload listing
cannot prove the expected length, never rerun `azcopy copy`; rerun only the
non-destructive listing.

### Phase 6 - Target credential

Run the executable credential reconciler in the command reference. Only its
`Absent` branch may create the URL-scoped server credential, using exactly:

```sql
CREATE CREDENTIAL [https://<account>.blob.core.windows.net/<container>]
    WITH IDENTITY = 'Managed Identity';
```

Enable trace flag 4675 for the credential-creation session so a missing primary
identity is surfaced. If an exact URL credential already exists, reuse it only
when `credential_identity = 'Managed Identity'`. Classify credential state as
`Absent`, `Matching`, or `Conflicting`; create only for `Absent`, reuse only for
`Matching`, and for `Conflicting` report the exact existing name and identity and
stop without altering or dropping it. Any repair is a separate mutation requiring
explicit definition and approval. Never include a
`SECRET` clause.

### Phase 7 - Restore

Run `RESTORE HEADERONLY`, `RESTORE FILELISTONLY`, and `RESTORE VERIFYONLY` from
the Blob URL. Map every logical file to a validated target path. Restore with
`RECOVERY`, `CHECKSUM`, `STATS = 10`, and `MOVE` for every file.

If `OverwriteExistingTarget=false`, any target database or physical-file
collision blocks restore. If overwrite was explicitly accepted, show the final
database and file mapping immediately before using `REPLACE`; do not drop the
target database automatically.

### Phase 8 - Complete

Require the target database to be `ONLINE`. Report the source backup metadata,
local file path and hash, AzCopy job ID, Blob URL and size, target identity
principal ID, credential identity, restore timestamps, target paths, and final
database state. Do not delete the local backup, Blob, or managed-identity
credential. Do not switch application connections automatically.

Preserve `TargetAuthentication` in the immutable post-migration validation
handoff. Include `TargetUser` only when that mode is `Entra`, identify the target
type as `SQL VM`, and pass the verified reusable target connection handle when
available. If that handle later becomes unavailable, validation must retain a
`Windows` handoff with `-E` instead of changing the target identity to Entra.

## Result format

Report `Needs input`, `Ready`, `Blocked`, `Running`, `Completed`, or `Failed`.
Reserve `Blocked` for a technical gate that was executed and failed. Include one
row per database with local backup, AzCopy upload, target credential, restore,
and final-state status, plus the exact next technical action for failures.

## References

- [Command execution reference — discovery and setup](references/command-execution-discovery.md)
- [Command execution reference — backup and restore](references/command-execution-backup-restore.md)
- [Managed identity support for backup and restore](https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2022/microsoft-entra-managed-identity-support-for-backup-restore-database-ekm-akv)
- [SQL Server 2025 Arc backup to URL with managed identity](https://learn.microsoft.com/en-us/sql/sql-server/azure-arc/backup-to-url)
- [Set up managed identity for SQL Server 2025 enabled by Azure Arc](https://learn.microsoft.com/en-us/sql/sql-server/azure-arc/microsoft-entra-authentication-with-managed-identity)
- [Authorize AzCopy with a user identity](https://learn.microsoft.com/en-us/azure/storage/common/storage-use-azcopy-authorize-user-identity)
- [Upload files with AzCopy](https://learn.microsoft.com/en-us/azure/storage/common/storage-use-azcopy-blobs-upload)
- [Run an Azure Resource Graph query with Azure CLI](https://learn.microsoft.com/en-us/azure/governance/resource-graph/first-query-azurecli)
- [BACKUP](https://learn.microsoft.com/en-us/sql/t-sql/statements/backup-transact-sql?view=sql-server-ver17)
- [RESTORE](https://learn.microsoft.com/en-us/sql/t-sql/statements/restore-statements-transact-sql?view=sql-server-ver17)