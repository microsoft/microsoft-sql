---
name: sql-server-to-sql-mi-lrs-migration
description: "Migrate SQL Server databases to Azure SQL Managed Instance with Log Replay Service (LRS) using managed identity for Blob access. Use for SQL Server to SQL MI, LRS, log replay, continuous restore, or low-downtime backup-chain migrations."
---

# SQL Server to Azure SQL Managed Instance with LRS

## When to Use

- Migrate SQL Server databases to Azure SQL Managed Instance with Log Replay Service.
- Run a managed-identity, backup-chain migration that supports low-downtime cutover.

Migrate one or more SQL Server databases to Azure SQL Managed Instance by using
Log Replay Service (LRS). Process the complete lifecycle of one database before
starting the next database. This skill runs only from Windows and follows the
Microsoft Learn managed-identity procedure in the order defined here.

Use the SQL managed instance identity for LRS read/list access to Azure Blob
Storage. Take every source backup to an approved local folder, verify it locally,
and then copy the completed file to the database's Azure Blob folder with AzCopy.
The source does not use a storage credential, storage key, or SAS token. LRS reads
the uploaded files by using only the SQL managed instance identity.

Read [references/command-execution-setup.md](references/command-execution-setup.md),
[references/command-execution-identity-setup.md](references/command-execution-identity-setup.md),
[references/command-execution-backup.md](references/command-execution-backup.md),
[references/command-execution-backup-job.md](references/command-execution-backup-job.md),
[references/command-execution-lrs.md](references/command-execution-lrs.md), and
[references/command-execution-cleanup.md](references/command-execution-cleanup.md) before
generating or running commands.

## Supported platform and authentication

| Boundary | Supported authentication |
| --- | --- |
| Host | Windows only with PowerShell 7 |
| Source SQL Server | Windows Integrated authentication or Microsoft Entra ID interactive authentication |
| Target SQL MI queries | Microsoft Entra ID interactive authentication or a user-supplied Entra access token |
| Azure management | Reuse a valid cached ARM token or Windows broker session first; open attended browser authentication only as fallback |
| AzCopy | Reuse a verified Azure CLI Storage token with `AZCLI`; never start device-code or browser authentication from a copy operation |
| LRS access to Blob Storage | SQL managed instance managed identity only |

Never connect to either the source or target with SQL login/SQL authentication.
Do not request, accept, retrieve, or use SQL passwords or SQL credentials. Use
only Windows Integrated authentication or Microsoft Entra authentication
supported by the workflow: the source supports Windows Integrated or Entra
interactive authentication, and the target supports Entra authentication only.
Do not offer service principals, workload identities, storage keys, or SAS
tokens. Accept the target SQL MI connection string only as transient input. It
may use Entra interactive authentication or contain a user-supplied Entra access
token. Reject passwords, SQL credentials, and other secrets; never read SQL
credentials from Key Vault or Credential Manager, echo or persist the connection
string or access token, or display a password prompt. SQL login ownership for
the SQL Agent job is also unsupported.
Phase 0 is strictly
progressive: obtain the source SQL Server instance first, then source authentication
and trust choices, connect immediately, and only then discover and offer databases.
Do not ask for database names or target details before that connection succeeds.
For source authentication, accept only
`WindowsIntegrated` or `EntraInteractive`. Target SQL access uses
`EntraInteractive` or an Entra access token detected in the supplied connection
string; do not ask the user to choose another target authentication
type. LRS is always started with `-StorageContainerIdentity ManagedIdentity`.

## Operating contract

- Start with read-only discovery and technical prerequisite checks. After showing
  one sanitized configuration and action summary, show the strong mutation
  disclaimer defined in Phase 1 and require its explicit acceptance. Immediately
  before creating a new SQL Agent log-backup job, require the separate manually
  typed job-creation confirmation defined in Phase 3. Do not infer either
  acceptance from preparation consent or a selected button.
- For multiple databases, use a deterministic queue and complete technical checks,
  backup/replay, mode-specific completion, and validation for one database before starting the
  next. Do not run LRS or source backup jobs for two migration databases at once.
- Reuse known inputs and discover values available from the authenticated Azure
  context or source SQL metadata. Ask only for a choice when discovery returns
  multiple valid resources, or for a genuinely user-defined value that cannot be
  discovered.
- Before the first source read-only SQL query, establish only the selected source
  connection, then request one session-level acceptance that
  covers every catalog, metadata, discovery, polling, and validation `SELECT` in
  this migration. After acceptance, record `ReadOnlySqlConsentGranted = true` in
  the in-memory migration state and never prompt again for a read-only SQL query,
  including across databases, retries, reconnects, resumed phases, cutover, or
  delegated validation.
- Reuse cached MSSQL connection IDs and execute these
  queries with `mssql_run_query`; do not wrap them in PowerShell, `sqlcmd`, or a
  terminal command when the direct query tool is available. A query or connection
  failure does not clear this consent or authorize another consent prompt.
- Create one migration-scoped interactive Entra authentication context and reuse
  it for every Azure operation, AzCopy transfer, SQL MI connection, and delegated
  validation call.
  Reuse the established MSSQL connection for SQL work; never open a second SQL
  sign-in. Because Entra tokens are audience-bound, do not pass a SQL Database
  token to Azure Resource Manager. Before prompting, enumerate cached Az contexts
  for the same Entra username and validate each with a silent ARM token request;
  normal access-token expiry must use silent refresh. If no Az context works, let
  the Windows Web Account Manager broker reuse the signed-in Windows Entra session
  for the named account. Open attended browser authentication only when neither
  cached-token nor broker reuse succeeds. Allow at most one attended Azure sign-in.
  Pin the account, tenant,
  environment, and selected subscription after discovery; never prompt separately
  per command, database, phase, resource provider, or token expiry.
- For nonsecret inputs, offer individual fields and one multiline paste option
  within the current Phase 0 stage only. Never combine source connection,
  discovered database selection, and target fields in the initial form. Accept a
  pasted JSON object or `Key=Value` block, validate every key and value, show the
  same sanitized confirmation table, and ask only for missing or invalid values.
  Individual text fields must accept pasted text as well as keyboard entry. Never
  read the clipboard automatically.
- Require Windows. Stop as `Blocked` on any other operating system. Use
  PowerShell 7 and `Az.Sql` 4.1.0 or later as the canonical automation path.
- Require `SQL Managed Instance Contributor` or a custom role containing
  `Microsoft.Sql/managedInstances/databases/*`, scoped as narrowly as possible.
- Grant the SQL managed instance identity `Storage Blob Data Reader` at the
  database folder's container scope. Do not grant Contributor, Owner, Storage
  Account Contributor, or write/delete Blob data permissions for LRS.
- LRS must use managed identity only. Upload local backup files with the attended
  Entra-authenticated AzCopy identity with `Storage Blob Data Contributor` scoped
  to the container. Before each upload phase, require an already authenticated
  Azure CLI context for the same account and tenant and silently obtain a token
  for `https://storage.azure.com/`. Run AzCopy with
  `AZCOPY_AUTO_LOGIN_TYPE=AZCLI`; do not use `PSCRED`, `DEVICE`, or `azcopy login`,
  and never allow a copy command to open an interactive sign-in. If the cached CLI
  session cannot supply the Storage token, stop before AzCopy, report `Blocked —
  AzCopy authentication required`, and ask the user to authenticate Azure CLI in
  the attended terminal before resuming. Never supply that upload identity or a
  token to an LRS command.
- Classify the exact URL-scoped SQL credential as `Absent`, `Matching`, or
  `Conflicting`. Create it only when `Absent`, reuse it only when `Matching`, and
  when `Conflicting` report the exact existing name and identity and stop without
  altering or dropping it. Credential repair is a separate mutation requiring
  explicit definition and approval.
- Never set the source database to `READ_ONLY` before a tail-log backup: SQL
  Server doesn't allow `BACKUP` while the database is read-only. During explicitly
  confirmed cutover, use `BACKUP LOG ... WITH NORECOVERY` to capture the tail and
  atomically prevent later source writes by leaving the database in `RESTORING`.
  If the user rejects the tail-log backup, take, verify, upload, and replay a
  normal `BACKUP LOG ... WITH COMPRESSION, CHECKSUM` without `NORECOVERY`. Report
  that this is not a migration cutoff: the source remains in write mode and new
  changes can occur after that backup.
  Never pause or stop source writes before cutover, alter source recovery model,
  enable ADR or Service Broker, initiate cutover, stop LRS, delete files, or
  remove the source without explicit approval for that action.
- Stop on failed validation. Never skip a missing backup, reorder files, or report
  an accepted asynchronous request as a completed migration.
- Never hide an error behind a generic message such as “an error occurred,” “let
  me fix it,” or “see diagnostics.” Immediately report every SQL, PowerShell,
  native-command, Azure, AzCopy, SQL Agent, LRS, or validation failure before any
  retry or remediation. Include the phase, database/resource, failed operation,
  sanitized error message, SQL/HTTP/error number or exit code when available,
  diagnostics location, resulting status, and exact next action. Redact passwords,
  connection strings, access tokens, SAS values, and keys, but preserve the useful
  failure reason. Report both the original error and the outcome of any bounded
  recovery attempt. A caught exception must be reported and then rethrown unless
  a documented recovery succeeds.
- Preserve the source and backup chain until validation passes. Cleanup is
  non-destructive and outside the normal migration flow. When cleanup is
  requested in `Continuous` mode, automation may only disable the migration SQL
  Agent job. In `Autocomplete`, cleanup must not inspect or mutate SQL Agent. If the user
  separately and explicitly approves stopping an active LRS restore, automation
  may also call `Stop-AzSqlInstanceDatabaseLogReplay`, after warning that it
  deletes the restoring target database. Do not automatically delete jobs,
  schedules, local files, Blob files/containers, credentials, identities, role
  assignments, databases, manifests, diagnostics, or installed tools. Instead,
  produce the required manual-reversion table and ask the user to perform only
  the rows they approve.
- Preparation consent covers CurrentUser tool installation, migration folder and
  private-container creation when authorized, local backup-folder use, SQL MI
  identity/RBAC/credential setup, initial backups, immutable AzCopy uploads, and
  managed-identity LRS start for the displayed resources. For `Continuous` only,
  it also covers scheduled backups and SQL Agent job enablement after separately
  confirmed creation. SQL Agent job creation
  requires one dedicated confirmation immediately before the first `sp_add_job`
  call for that database.
  Request separate confirmation only for a resource or scope change, unexpected
  remediation outside that summary, cutover, or destructive LRS stop.
- Every mutable resource must use an executable idempotent reconciler with this
  sequence: classify authoritative state, converge only workflow-owned state,
  reclassify, and require the documented postcondition. This applies to SQL Agent
  jobs, steps, schedules, server bindings and enablement; backup files and Blob
  uploads; RBAC and managed-identity credentials; and LRS operations. A prose
  assertion that an operation is idempotent is not evidence. If the applicable
  canonical reference lacks a classifier, bounded reconciler, postcondition, and
  re-entry test case, stop before that mutation and report `Blocked — no tested
  idempotent reconciler`.
- Do not run or request a process-readiness preflight. Never ask for a cutover
  window, rollback deadline, go/no-go owner, validation owner, deletion owner,
  application owner sign-off, rehearsal, RPO/RTO, or retention policy. Missing or
  empty process metadata must not block discovery or technical checks. If a
  process form is accepted with no values, ignore it and continue read-only
  discovery rather than returning `Blocked`.

## Required inputs and discovery

Collect these migration choices in this exact order, advancing only when the
current stage succeeds:

1. Source SQL Server instance. Reuse it when present in the user's request.
2. Source authentication and certificate trust choice; connect immediately.
3. From the live source connection, discover online user databases and offer
  specific databases or `All`. Never ask for an undiscovered database name.
4. Target SQL MI connection string and Entra username; connect with Entra
  interactive authentication, then resolve its Azure resource details with Azure
  Resource Graph (ARG).
5. Storage account name; resolve it with ARG, authenticate to its Blob data plane,
  and select a discovered private container.
6. LRS mode: `Continuous` or `Autocomplete`.

Reuse and silently validate the cached Az context; call `Connect-AzAccount` only if
that validation fails and no attended sign-in has occurred in this run. Never ask
the user for a subscription ID or resource group. After the Entra-interactive SQL
MI connection succeeds, derive the target server/FQDN from the validated
connection without displaying or persisting its connection string. Query ARG across
all accessible subscriptions to resolve the SQL MI by exact resource name and
FQDN, then obtain its resource ID, subscription, resource group, region, tier/SKU,
and identity. If ARG cannot resolve one resource uniquely, ask for the full Azure
resource ID as the only fallback and validate its type and
endpoint; do not ask for separate subscription or resource-group fields.

Ask only for the storage account name. Query ARG across accessible subscriptions,
prefer the account in the resolved SQL MI subscription and compatible region, and
resolve its resource ID and properties. If the name remains ambiguous, present a
structured picker; if ARG returns no match, ask for the full storage-account Azure
resource ID. Authenticate to the resolved storage account with the existing Entra
context, list existing private Blob containers, and let the user select one. Do
not ask the user to type a container name when listing succeeds.

Discover source version, database state, recovery model, collation, SQL Server
local backup-folder access and capacity, backup baseline, and observed log-backup
cadence through direct `mssql_run_query` calls after the source server/database
is known. For `Continuous` only, also discover SQL Server Agent state. Autocomplete
must not query Agent service state, jobs, or history. Run every query under the accepted session-level
read-only SQL consent without reconfirmation. Default the target database to the
source database name
after proving that name is available, default the database folder to that validated
database name, and default LRS mode to `Continuous`. Reuse overrides from the
handoff; ask only for missing technical values that have no safe default.

Display one sanitized configuration and preparation-consent table containing
discovered, defaulted, and supplied values:

| Input | Required value |
| --- | --- |
| Source | Supplied server/database; discovered version and recovery metadata |
| Source authentication | `WindowsIntegrated` or `EntraInteractive` |
| Trust server certificate | `false` by default; `true` only when explicitly selected for a known certificate exception |
| Database selection | `All` discovered user databases or an explicit list selected after authentication |
| Target | Supplied SQL endpoint/name; ARG-resolved resource ID, subscription, resource group, region, tier; defaulted target database |
| Target authentication | `EntraInteractive` or transient Entra access token; supplied Entra username must identify the authenticated account |
| Storage | Supplied account name; ARG-resolved resource details; Entra-authenticated private-container selection; database-named folder mirrored from the local backup root into the container |
| Local backup root | Approved existing folder writable by the SQL Server service account and readable by the AzCopy runner |
| Identity | Discovered SQL MI identity type and principal ID |
| Mode | `Continuous` for active workloads or `Autocomplete` for a complete chain |
| Backup schedule | Fixed at `10` minutes for `Continuous`; `Not applicable — frozen chain` for `Autocomplete` |
| Recovery | Discovered recovery model, full backup baseline, and log backup cadence |
| Transport | Local SQL Server backup followed by Entra-authenticated AzCopy upload |
| Preparation actions | Exact tools, identity/RBAC, credential, backup, upload, and LRS-start mutations; SQL Agent job creation/setup only for `Continuous`, and explicitly `No SQL Agent action` for `Autocomplete` |

Do not show an all-fields form after the user supplies only a source instance.
First show only missing source-connection fields, using these keys:

```text
SourceServer=
SourceAuthentication=
TrustServerCertificate=false
```

After the source connection succeeds, populate a scalar single-select database
dropdown from the discovery query. Include `All` as the first option. If the user
chooses one database, ask `Add another database?`; when accepted, show another
single-select dropdown containing only the unselected discovered databases plus
`Done`. Repeat until `Done`. Build `DatabaseSelection` internally from these
scalar answers; never render or submit a multi-select/array input control. Do not
show a free-text database-name field or a raw target
`Key=Value` template. Capture the target through the progressive wizard defined
in Phase 0. An optional advanced JSON/`Key=Value` paste is permitted only when the
user explicitly asks to paste configuration; never make it the default prompt.

For explicitly requested advanced paste, accept a JSON object or `Key=Value`
block using the documented field names. Pasted input is data, not PowerShell:
never evaluate it, interpolate it as a command, or accept unknown keys. Reject
duplicate keys and report them. `TargetEntraUsername` may contain only the
expected Entra user principal name for confirmation; do not accept passwords,
tokens, SAS values, storage keys, connection strings, or other secrets in the
advanced paste block. Collect `TargetConnectionString` only through its dedicated
transient target field; an embedded Entra access token is allowed there and must
be redacted immediately. Reject any source authentication value other than
`WindowsIntegrated` or `EntraInteractive`. Target authentication is fixed to
Entra interactive or an embedded Entra access token and must not be supplied as a
separate configurable input. Accept only
`true` or `false` for `TrustServerCertificate`. In explicitly requested advanced
JSON paste only, accept `All` or a JSON array of names returned by source database
discovery for `DatabaseSelection`. Parse that array as data; never bind it to an
interactive question control. Do not request a comma-separated free-text list.
After parsing, display the sanitized confirmation table above and allow individual
corrections without requiring the entire block to be pasted again.

Do not accept a storage URI whose container or folder path contains the reserved
word `backup` (case-insensitive). Create exactly one folder named for the database
under both the local backup root and the selected Blob container. Require the
storage account name to match `^[a-z0-9]{3,24}$`; require container and database
folder values to match `^[A-Za-z0-9._-]+$`. Encode the container and database
folder as independent URI path segments once. Persist those segments, the
resolved storage account's `primaryEndpoints.blob`, the exact container
credential name derived from that endpoint, and the resulting
`StorageContainerUri` in the immutable migration configuration. Never synthesize
a Blob hostname or assume an endpoint suffix. Reuse the persisted credential name
for SQL MI and the exact folder URI for Blob validation, AzCopy, and LRS. Place that
database's full, differential, and log backups in the local folder and preserve
the same database-folder prefix during upload. Do not add child folders beneath
it. Each database needs its own folder; only a database in `Continuous` mode
needs an LRS SQL Agent backup job.

## Workflow

```text
Phase 0  Discover Azure/source context and build the ordered database queue
Phase 1  Enforce Windows/authentication prerequisites and request one preparation consent
For each database, one at a time:
  Phase 2  Prepare SQL MI managed identity and validate Blob read access
  Phase 3  Create and verify local backups, then upload them with AzCopy
  Phase 4  Prove the database-folder Blob chain and start managed-identity LRS
  If Continuous:
    Phase 5  Every 10 minutes, reconcile local/Blob logs, upload pending files, and offer monitor or cutover
    Phase 6  When the user types cutover, require two typed gates, quiesce the job, finalize LRS, and validate
  If Autocomplete:
    Poll the existing replay to completion; verify the approved final file and target availability; validate
Phase 7  Produce the final all-database summary
```

## Phase 0 - Collect scope, authenticate, and select LRS mode

Require Windows before collecting credentials or running discovery. Connect to
the source with the selected supported method. If the request already contains a
source instance such as `neel-win1`, record it as `SourceServer`, do not ask for it
again, and do not ask for databases yet. Ask only for the missing source
authentication and trust choices, then connect immediately. Windows Integrated authentication
uses the current Windows identity; Entra interactive authentication opens one
attended sign-in and reuses that connection. If that Entra account is also the
target account, silently request and reuse its cached Windows-broker SQL-audience
token for the target connection before opening target browser authentication.
Windows Integrated authentication creates no Entra token to reuse. Once connected, query and present the
eligible database choices. Collect and authenticate target details only after the
database selection is complete. Do not silently fall back between authentication
types.

### Phase 0 capture matrix

Capture and validate the following matrix progressively before migration
preparation. Present only the fields for the current stage, not one combined form.
Do not start backup or Azure mutations in this phase.

| Stage | Field | Allowed value or behavior |
| --- | --- | --- |
| Source | SQL Server instance | Required server or `server\\instance` name |
| Source | Authentication | `WindowsIntegrated` or `EntraInteractive` |
| Source | SQL Agent job owner | For `Continuous`, an explicitly approved enabled direct Windows login; independent of source authentication. Not applicable to `Autocomplete` |
| Source | Trust server certificate | `false` by default; allow `true` only after warning that certificate-chain validation is bypassed |
| Source | Database scope | Authenticate first and list online user databases; use a single-select dropdown with `All`, then optionally add databases one at a time through follow-up dropdowns |
| Target | SQL MI connection string | Ask immediately after database selection; require Entra interactive authentication, keep it only in memory, and never display or persist it |
| Target | Entra username | Required user principal name; confirm the interactive sign-in matches |
| Storage | Storage account name | Resolve through ARG across accessible subscriptions; request full resource ID only if unresolved |
| Storage | Blob container | Authenticate to resolved storage, list private containers, and use a structured picker |
| Restore | LRS mode | `Continuous` or `Autocomplete` |

### Target capture wizard

After database selection, use concise structured questions and discovered choices
instead of one large free-text form:

1. Immediately ask for `TargetConnectionString` and `TargetEntraUsername` as two
  target fields. Treat the connection string as transient sensitive input: keep
  it only in memory and never echo, log, include it in evidence, or persist it.
  Allow Entra interactive authentication or an embedded Entra access token;
  reject `Password`, `PWD`, and SQL-authentication values.
2. Connect to the specified target SQL MI with Entra interactive authentication
  or the supplied Entra access token.
  Reuse a valid SQL-audience token from the earlier Windows-broker Entra session
  for the same username before opening browser authentication; do not copy or
  display the raw token. Do not infer or reuse another target. Verify that the authenticated account
  matches `TargetEntraUsername`. Derive the server FQDN from the successful
  connection and query ARG by exact name/FQDN to resolve the Azure resource. Do
  not ask for subscription or resource group. If no unique ARG match exists, ask
  only for the full SQL MI Azure resource ID and validate it against the connected
  endpoint.
3. Ask for `LocalBackupRoot` as a single source-stage path field. Validate that it
  is an absolute local Windows path and that SQL Server can write to it.
4. Ask for `Mode` as a fixed-choice selector (`Continuous` default, or
  `Autocomplete`).
5. Ask for the storage account name and query ARG across accessible subscriptions.
  Prefer a compatible match in the SQL MI subscription/region. If multiple valid
  matches remain, show a single-select picker. If none exists, ask only for the
  full storage-account Azure resource ID. Never ask for subscription separately.
6. Create an Entra-authenticated storage data-plane context for the resolved account, list
  existing private containers, and present them in a structured single-select
  picker. Auto-select a sole result. Ask for a container name only if data-plane
  listing is unavailable and explain the access blocker. Never ask for a
  container name before attempting the authenticated list.
7. Default each `TargetDatabase` and `DatabaseFolder` to its selected source
  database name. Do not prompt for either unless validation finds a collision or
  invalid name; then ask only for the affected override.
8. For `Continuous`, set `BackupFrequencyMinutes` to `10`; do not ask for or
  accept a frequency override. For `Autocomplete`, request
  the exact final backup name as manual user input. Do not infer it from Blob
  ordering, file timestamps, or the manifest.
9. Show one read-only sanitized review table and ask for preparation consent.
  For `Autocomplete`, the review must explicitly show
  `AutoCompleteRestore = true` and the manually supplied `LastBackupName`.
  Construct those two LRS parameters only after affirmative consent; rejection or
  no answer leaves them unset and LRS must not start.

Never display the raw list of target field names shown in the advanced paste
format as the normal interaction. Never ask the user to enter all target details
into one text box.

Authenticate to the source immediately after validating the first three source
fields. Query `sys.databases` and show only online user databases
(`database_id > 4`) for selection. Offer `All` and each discovered database in a
single-select dropdown. If one database is selected, offer a scalar `Add another
database?` choice and repeat a single-select dropdown with remaining names plus
`Done`; never use a multi-select/array field. Do not interpret
`All` as including system, offline, restoring, suspect, snapshot, or inaccessible
databases. Resolve every selected name against the displayed result and preserve
the displayed order in the migration queue. If no eligible database is found,
return `Blocked`.

The database dropdowns must be populated exclusively from this query. Store each
scalar choice in the ordered in-memory queue and reject duplicates. Never ask
`Which database(s) ...?` with a free-text answer before connecting. If the source
connection fails, report the authentication or connectivity error and allow the
user to correct only source-stage fields; do not proceed to target capture.

Then reuse the authenticated target SQL connection. For Azure, first try every
cached ARM context for the supplied Entra username, then Windows broker SSO, and
only then an attended browser sign-in. A SQL Database access token cannot be used
as an ARM token because its audience differs. Discover the tenant internally; do
not ask for tenant, subscription, or
resource group. Resolve SQL MI and storage resource details through ARG, then use
Entra data-plane authentication to list containers for selection. A username or
endpoint/resource mismatch blocks the workflow instead of opening another
authentication route. Do not accept a storage key or SAS.

Use **continuous mode** when the source remains active and more log or differential
backups will arrive after LRS starts. This is the default for low-downtime work.
Cutover is manual.

Use **autocomplete mode** only when the complete backup chain is already present
and no files will be added. Require the user to manually supply the exact final
backup file name before start. Display that name with `AutoCompleteRestore = true`
and obtain affirmative consent before setting either LRS parameter. Do not infer,
default, or silently change the final file. If LRS finds files after the declared
final file, the migration fails.

Block LRS when read-only target access is required during synchronization, the job
could exceed 30 days, or Business Critical cutover seeding cannot meet the outage
window. Evaluate Managed Instance link for those cases.

## Phase 1 - Technical prerequisite checks

Run every check before the first database and recheck database-specific gates when
each queue item starts. Do not collect or validate process metadata. Automate
read-only checks under `ReadOnlySqlConsentGranted` without further approval. Do
not reset or request that consent again when a check is retried or a connection is
renewed. Before proposing resource creation, verify that
the operator can perform it; never offer an action known to be unauthorized.
Present one preparation summary and request one consent for all expected setup and
synchronization actions. Additional prompts are allowed only for scope changes,
unexpected remediation, cutover, or destructive stop.

Before requesting preparation consent, display this strong disclaimer prominently:

> **LRS mutation disclaimer:** This workflow can create or change SQL Agent jobs,
> schedules, job steps, local-server bindings, job ownership metadata, local backup
> files, Blob uploads, Azure RBAC assignments, managed-identity credentials, and
> LRS operations. These changes can run repeatedly, consume local and Azure storage,
> affect the source backup chain and I/O, grant cloud access, and create or remove a
> restoring target during separately approved stop/cutover actions. Only canonical,
> tested idempotent reconcilers may mutate these resources; cleanup is not automatic.

Require the user to manually type the exact phrase
`I ACCEPT THE LRS MUTATION DISCLAIMER`. Do not prefill, generate, suggest as a
selectable answer, or accept a button click, `yes`, a partial phrase, or an agent-
supplied value. Record `LrsMutationDisclaimerAccepted = true` only for an exact
case-sensitive match tied to the displayed server, databases, Azure resources,
local root, and action summary. Rejection or any other input stops before the
first mutation. This acceptance does not authorize SQL Agent job creation,
cutover, destructive LRS stop, or a later scope change.

### Tooling

- The host operating system is Windows. Other operating systems are unsupported.
- PowerShell 7 is available.
- `Az.Accounts`, `Az.ResourceGraph`, `Az.Resources`, `Az.Storage`, and `Az.Sql`
  are installed; `Az.Sql` is version 4.1.0 or later. Version 4.0.0 is unsupported
  because its LRS cmdlet still requires `StorageContainerSasToken` even when
  `StorageContainerIdentity` is `ManagedIdentity`.
- Before constructing the LRS start request, inspect
  `Start-AzSqlInstanceDatabaseLogReplay` with `Get-Command`. Require the loaded
  command to come from Az.Sql 4.1.0 or later and verify that its resource-name
  parameter set contains `StorageContainerUri` and `StorageContainerIdentity`
  without making `StorageContainerSasToken` mandatory. Never generate or pass
  `StorageUri`. If that exact managed-identity parameter set is unavailable,
  report the loaded `Az.Sql` version and stop as `Blocked` rather than attempting
  the call.
- Reuse cached source and target MSSQL connection IDs with `mssql_run_query` for
  read-only SQL. Source connections use only the selected Windows Integrated or
  Entra interactive method. Target SQL MI connections use Entra interactive
  authentication or the transient user-supplied Entra access token. A token-based
  target connection must use the existing MSSQL connection and must not place the
  token on a command line. When an interactive reusable connection is unavailable,
  allow only a validated modern Go `sqlcmd` fallback: `-E` for source Windows
  Integrated or `-G` for Entra. Detect all `sqlcmd` candidates, validate version/help and the
  required `-E`, `-G`, `-Q`, `-b`, and `-r` capabilities as applicable, cache the
  canonical executable path, and never use `-U`, `-P`, SQL authentication, or an
  unqualified executable.
- Install only missing tools covered by preparation consent, verify their versions,
  and stop if installation requires elevation or violates host policy.

### Source

- SQL Server is version 2008 through 2025 and the database is online.
- `WindowsIntegrated` uses the current Windows identity. `EntraInteractive`
  requires the source SQL Server endpoint to be configured for Microsoft Entra
  authentication and opens one attended sign-in. If the selected method is not
  supported or authorized on the source, stop; do not fall back to SQL
  authentication or the other method.
- Database uses `FULL` recovery. Include any change from `SIMPLE` in preparation
  consent and take a new full backup to establish the log chain before any log backup.
- For `Continuous` only, SQL Server Agent is installed and running, and the
  separately approved direct Windows `SqlAgentJobOwner` can run the recurring
  `BACKUP LOG` job. The Database Engine service account can write to the approved
  local backup root. Source authentication may remain `WindowsIntegrated` or
  `EntraInteractive`; an Entra login is never used as the job owner.
  Autocomplete has no Agent or job-owner prerequisite.
- For `Continuous` only, version-gate SQL Server service discovery: use dynamically bound
  `sys.dm_server_services` only where available, and use the documented 10.0
  compatibility probe for SQL Server Agent state and the Database Engine service
  account on SQL Server 2008. A missing DMV on 10.0 is not a reason to reject an
  otherwise supported source.
- The SQL Server service account can write to the local backup root, the AzCopy
  runner can read it, and free local capacity is sufficient for the full chain.
- Source backups must use `BACKUP ... TO DISK` in the approved local backup root.
- Full, optional differential, and transaction log backups form one unbroken chain.
  A transaction log backup must not be split across multiple files.
- In `Continuous`, every SQL Agent step attempt, including a configured retry, must allocate a new
  immutable `.trn` filename inside the step by combining UTC with a GUID and must
  use `WITH INIT`. Job-start tokens alone are insufficient because retries share
  them; never append another backup set to an existing media file.
- Backups use `COMPRESSION, CHECKSUM`; run `RESTORE VERIFYONLY WITH CHECKSUM`.
- SQL Server 2019 or later has accelerated database recovery enabled and its
  persistent version store on `PRIMARY` before migration.
- Enable Service Broker before migration only when the target workload requires it.
- Inventory TDE and backup encryption certificates/keys and prove restore custody.

### Azure and network

- SQL MI exists, target database name does not already exist, capacity and database
  limits are sufficient, and the target collation is approved.
- SQL MI has a Microsoft Entra administrator and the attended Entra identity can
  connect for discovery and validation. Do not request a SQL login.
- Storage and SQL MI networking is reachable. For firewalled storage, the SQL MI
  subnet is delegated to `Microsoft.Sql/managedInstances`, has the
  `Microsoft.Storage` service endpoint, and is allowed by the storage firewall.
  Storage and SQL MI must be in the same region or paired regions.
- Maintenance events will not conflict with replay or cutover, especially for
  large databases and Business Critical targets.
- For `Continuous` only, inspect SQL Agent jobs, history, and maintenance-plan
  backup jobs and block conflicting automation. Autocomplete does not inspect
  Agent jobs or job history; it validates only the already frozen chain through
  source `msdb` backup metadata, local files, the manifest, and Blob objects.
- Tool and RBAC versions/permissions satisfy the operating contract.
- The target tier has capacity for every queued database. This skill intentionally
  runs only one LRS restore at a time, below the documented concurrency limits.
- The storage account/container is private, uses HTTPS, supports the selected Blob
  backup type, and has no container/folder segment containing reserved `backup` or
  `Backup`. Each database has a separate one-level folder whose name and backup
  files mirror the folder under `LocalBackupRoot`; no child folders are allowed.

## Phase 2 - Managed identity and storage access

1. Resolve the intended identity assigned to SQL MI and record its object ID. If
  `PrimaryUserAssignedIdentityId` is configured, resolve that exact entry in
  `Identity.UserAssignedIdentities` and use its principal ID. Stop on a missing
  entry or principal ID; do not enable or grant RBAC to the system identity as a
  fallback. Use or enable the system identity only when no primary UAMI is
  configured, and require preparation consent before enablement.
2. Assign only `Storage Blob Data Reader` at container scope. Retry only transient
  assignment failures (`PrincipalNotFound` for a newly created SQL MI service
  principal, timeout, HTTP 408/429, or 5xx) with bounded one-minute waits, for a
  maximum of five total attempts spanning about four minutes. Pass
  `-ObjectType ServicePrincipal` to `New-AzRoleAssignment`, and verify the exact
  assignment before every retry so an assignment that became visible is reused.
  Report every failed attempt immediately. Do not retry an authorization failure
  such as HTTP 403.
3. If automatic assignment still fails, save a resumable Phase 2 checkpoint and
  report `Blocked — awaiting manual RBAC`. Show the SQL MI name and principal ID,
  storage account/container, exact container scope, exact role name, and sanitized
  failure. Provide both Azure portal and PowerShell manual assignment steps. The
  manual assignment must use the SQL MI managed identity, `Storage Blob Data
  Reader`, and the exact container scope; never recommend a broader role or scope.
  Ask the user to verify that the SQL MI service principal has replicated and
  return with `RBAC assignment complete`; then retry the exact assignment check.
  Do not discard the migration state or restart completed phases.
4. When the user returns, reuse authentication, reload the checkpoint, and verify
  the exact assignment with `Get-AzRoleAssignment`. Then rerun the SQL MI Blob
  access test. Continue from the next incomplete Phase 2 action only after both
  checks pass. If verification fails, show the current sanitized error and the
  same corrected manual values; remain blocked without recreating resources.
5. Wait for RBAC propagation; do not add broader permissions to bypass a delay.
6. On SQL MI, create a URL-scoped credential with
  `IDENTITY = 'MANAGED IDENTITY'`. Its name must exactly equal
  the persisted container URI derived from the resolved storage account's
  `primaryEndpoints.blob`, with no trailing slash, folder, or file name. Never
  synthesize the hostname, assume an endpoint suffix, use a generic credential
  name, or include `SECRET`. Classify URL-equivalent candidates before mutation. Create only when
  the state is `Absent`, reuse only when it is `Matching`, and stop without
  mutation when it is `Conflicting`. A repair requires a separately defined and
  explicitly approved operation; preparation consent does not authorize it.
7. Run `RESTORE HEADERONLY` against a harmless uploaded backup URL from SQL MI.
  If it reports a missing or invalid credential, immediately report the
  sanitized SQL error and rerun the credential classification. Retry `RESTORE
  HEADERONLY` once only when the state is `Matching`. For `Absent` or
  `Conflicting`, stop pending the separately approved action. Report `Recovered`
  when the retry succeeds. If it fails, report the final SQL error and stop as
  `Blocked`; do not ask the user to run replacement SQL manually.
8. Record successful access evidence without tokens, keys, or sensitive metadata.

Failure of `RESTORE HEADERONLY` blocks backup production and LRS start.

## Phase 3 - Produce the backup chain and, for continuous mode, schedule log backups

Use only local SQL Server backups followed by AzCopy upload. Validate the approved
local backup root, SQL Server service-account write access, AzCopy runner read
access, available capacity, AzCopy authentication, and container-scoped Blob write
permission. The AzCopy upload identity is separate from the SQL MI identity; LRS
still uses managed identity. Validate the cached Azure CLI account, tenant, and
Storage-audience token before invoking AzCopy. Authentication failure must occur
in this preflight; the copy process must never wait for an interactive login.

For each database, create `<LocalBackupRoot>\<DatabaseName>`, write every full,
differential, and log backup for that database there, and upload those files to
the persisted `StorageContainerUri` derived from `primaryEndpoints.blob`. Preserve
the database folder name exactly and append only the encoded backup filename for
AzCopy and validation. Point LRS `StorageContainerUri` at that database folder,
not at the container root. Do not flatten files into the container root.

1. Capture source database state and backup history.
2. Validate the canonical local path remains under the approved backup root and
  SQL Server service access by taking a uniquely named local test backup. Copy the
  completed test file to Blob with AzCopy and validate HTTPS reachability and the
  private container.
3. Take a striped, compressed, checksummed full backup where scale warrants it.
4. Optionally take a differential backup to reduce replay time.
5. For `Autocomplete`, require `BackupFrequencyMinutes = $null`; verify the
  complete local and Blob chain ends at exactly the manually approved
  `LastBackupName`, freeze its manifest, and prohibit any later backup creation or
  upload for that database. Skip every SQL Agent reconciler and job mutation
  below. After LRS starts, poll the existing operation to `Completed`, require
  `LastRestoredFileName` to equal the approved final name, and prove the target is
  online before post-migration validation. Do not enter the continuous monitor or
  cutover loop.
6. For `Continuous` only, immediately before any SQL Agent job mutation, run the authoritative
  pre-creation inventory in
  [references/command-execution-backup-job.md](references/command-execution-backup-job.md).
  It must check the deterministic job name and enabled state, currently executing
  `BACKUP DATABASE` and `BACKUP LOG` requests, active SQL Agent backup jobs, all
  enabled job-step definitions and schedules that back up the selected database,
  and recent `msdb.dbo.backupset` history. Display the findings. A matching job is
  reconciled and reused, never created again. An enabled same-name conflicting job
  blocks creation. Any active backup for the selected database blocks all job
  mutation until it finishes and the inventory is rerun. Existing unrelated backup
  automation or unexplained recurring backup history blocks creation until the user
  resolves it outside this workflow; do not disable, edit, or adopt it. If any
  inventory query fails, metadata access is denied, a required result is missing,
  or the evidence is ambiguous, fail closed as `Blocked — backup automation
  inventory incomplete`; absence must be proved rather than assumed.
  Resolve a valid enabled direct Windows SQL Agent job owner before job creation.
  Treat it as distinct from the authenticated source principal. For
  `WindowsIntegrated`, offer the current login as a default only when it resolves
  directly to `sys.server_principals.type = 'U'`; a group-only login has no owner
  default. For `EntraInteractive`, discover Windows-login candidates and require
  explicit `SqlAgentJobOwner` approval. Reject Windows groups, SQL logins, and
  external `E`/`X` principals. Verify the approved login can own and run the
  backup job and the caller can assign it. Do not silently select another login.
  If no owner is approved or validation fails, stop as `Blocked`; do not fall
  back to SQL authentication or disable `EntraInteractive` source support.
  Verify that the current caller has permission to assign the selected owner.
  Before creating a new job, display the source SQL Server, source database,
  deterministic job name, validated owner, disabled initial state, canonical
  command template, local backup folder, recurring ten-minute schedule, and local
  server attachment. After confirming the mutation disclaimer was accepted for
  the unchanged scope, require the user to manually type the exact phrase
  `CREATE LRS JOB <deterministic-job-name>`, with the displayed job name substituted
  exactly. Do not prefill it, offer it as a selectable answer, generate it on the
  user's behalf, or accept `yes`, a button click, or a partial/case-insensitive
  match. If the user rejects or does not enter the exact phrase,
  do not call `sp_add_job`, create a schedule, attach a server, enable a job, or
  start a job; leave that database `Blocked — SQL Agent job creation not approved`.
  Record the confirmation for this exact job context. Do not reuse it if the
  server, database, job name, owner, command, folder, or schedule changes. Do not
  request this creation confirmation when authoritative `msdb` reconciliation
  finds a matching existing job; bounded repair and reuse remain covered by the
  preparation consent and accepted mutation disclaimer unless they change the
  approved job context. Rerun the inventory and exact-name classifier immediately
  before `sp_add_job`; consent is invalid if state or context changed.
  Create one disabled SQL Server Agent log-backup job, attach it to the local SQL
  Server with `sp_add_jobserver`, and verify the job has a row in
  `msdb.dbo.sysjobservers` before enabling or starting it. Create and attach one
  enabled recurring minute-based schedule using the approved
  `BackupFrequencyMinutes`; verify the job-to-schedule binding and exact frequency
  in `msdb.dbo.sysjobschedules` and `msdb.dbo.sysschedules`. A job with no schedule,
  a disabled schedule, or a different frequency is not ready and must not run.
  Its schedule frequency is fixed at `BackupFrequencyMinutes = 10`. The exact
  schedule metadata is implemented only in the canonical SQL Agent reconciler;
  verify its postcondition so SSMS displays **Occurs every 10 minutes**, not
  **Occurs once at**.
  Automatically repair a missing, disabled, once-daily, or otherwise conflicting
  schedule under preparation consent before enabling the job. Never modify a
  schedule shared by another job; detach it and create a migration-specific
  ten-minute schedule instead. Generate a unique UTC local `.trn` file on every run and use
  `COMPRESSION, CHECKSUM, STATS = 5`. A log backup has exactly one local file.
  Do not author, infer, paraphrase, or regenerate the SQL Agent creation or step
  command from this prose. Execute only
  [references/canonical-sql-agent-job-reconciler.sql](references/canonical-sql-agent-job-reconciler.sql)
  according to
  [references/command-execution-backup-job.md](references/command-execution-backup-job.md).
  That SQL asset is the only implementation of job naming, description, command,
  schedule, classification, creation, and repair. Substitute only its declared
  scalar placeholders after validation and SQL-literal escaping.
6. Show the job owner, command template, local folder, Blob folder, and frequency in the single
  preparation summary; after preparation consent and the dedicated job-creation
  confirmation when the job is absent, enable it, run it once, and prove success
  in `msdb` and the local folder, then upload and prove the file in Blob Storage
  without another prompt. If job creation or the test run fails, inspect the
  sanitized SQL Agent error. If the job exists but has no job server, report the
  error, attach that validated job to the local server once with
  `sp_add_jobserver`, verify `sysjobservers`, and retry the test run once under the
  existing preparation consent. Do not ask the user to execute corrective SQL.
  If history reports error 102 near `+`, error 137 for undeclared `@path`, or
  error 319 near `WITH`, treat it as the known malformed job-step command, not an
  owner failure. Reinspect and invoke only the canonical reconciler's bounded
  `Repair` action under the existing preparation consent. Require its `Matching`
  postcondition before retrying once, then require successful history, backup
  metadata, and local-file evidence. Do not ask for or change the owner while
  repairing errors 102, 137, or 319. An ownership-specific error blocks rather
  than authorizing a separate owner-repair implementation.
  The exact-name classifier must treat a workflow-owned job with no step, or with
  exactly one canonical-name `TSQL` step whose command is malformed, as `Partial`
  so bounded repair can replace it. An unrelated step or multiple steps is
  `Conflicting` and must never be repaired. Do not use exact command equality,
  `STRTDT`, or `STRTTM` as the step-retry uniqueness boundary.
  When the validated Windows owner causes creation or execution to fail, stop as
  `Blocked` before any owner mutation. Do not request a replacement login or
  credentials; SQL login owners are unsupported.
  During continuous synchronization, inspect each completed job outcome. If the
  three most recent completed job executions all failed, immediately tell the
  user that the log-backup job has failed three consecutive times. Include the
  job/database, approved frequency, three run timestamps, sanitized job-history
  messages, last successful run, and exact next action; then stop uploading and
  advancing that database as `Blocked`. Do not wait for another scheduled run or
  claim the log chain is current.
  Execute continuous synchronization and cutover through
  [references/lrs-monitor-cutover-state-machine.ps1](references/lrs-monitor-cutover-state-machine.ps1).
  After LRS starts, run one authoritative local/Blob inventory immediately and
  then once every `BackupFrequencyMinutes` (fixed at 10). Upload every stable,
  verified local-chain file missing from Blob with AzCopy `--overwrite=false`.
  Before each upload, prove the exact encoded Blob URL is absent. Require
  structured output with one completed transfer and zero failed or skipped
  transfers, then list that exact object and match its content length to the
  local file. If post-upload verification is ambiguous, do not retry the upload;
  preserve the job evidence and reconcile the exact object. After verifying its
  exact name and size, wait for LRS progress, atomically checkpoint, and
  offer only the exact commands `monitor` and `cutover`. `monitor` waits for the
  next interval; `cutover` enters the safety gates. Restart reconciles observed
  SQL Agent, source, local, Blob, LRS, and target state before repeating a mutation.
7. Verify every backup and record size, checksum result, first/last LSN, database
   backup LSN, finish time, and immutable file name in a manifest.
8. Reject duplicate names, gaps, forks, overwritten files, split log backups, and
   files belonging to another database.

Only `.bak`, `.trn`, and `.diff` files are supported. Use `.trn` for every
transaction-log backup, including scheduled, rejected-cutover, and final tail-log
backups. Consolidate excessive file counts; thousands of files can make migration
slow or fail.

See [references/lrs-monitoring-cutover-validation.md](references/lrs-monitoring-cutover-validation.md) for Phase 4 through the final result format and reference links.
