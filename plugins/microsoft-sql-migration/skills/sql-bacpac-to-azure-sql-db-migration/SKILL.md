---
name: sql-bacpac-to-azure-sql-db-migration
description: "Migrate one or all user databases from SQL Server to Azure SQL Database with an offline BACPAC workflow. Use for BACPAC, SqlPackage export/import, bulk database migration, or offline Azure SQL Database migration requests."
---

# SQL Server to Azure SQL Database using BACPAC

## When to Use

- Migrate one or more SQL Server user databases to Azure SQL Database using BACPAC export and import.
- Perform an offline Azure SQL Database migration with `SqlPackage`.

Help a user migrate one or all user databases from **SQL Server** to **Azure SQL
Database** using an offline **BACPAC** workflow. A BACPAC contains the database schema and data. It
does not preserve instance-level objects, server configuration, SQL Agent jobs,
or a transactionally consistent online migration.

Use this skill when the user asks to migrate a SQL Server database to Azure SQL
Database with BACPAC, `SqlPackage`, import/export, or an offline database move.

Read [references/command-execution-setup.md](references/command-execution-setup.md) and
[references/command-execution-export-import.md](references/command-execution-export-import.md)
before generating or running commands.
Resolve the absolute installed directory containing those reference files and
pass it to the command blocks as `$skillReferenceRoot`. Do not derive that path
from the current directory or `$PSScriptRoot`; the orchestration runs inline,
not from a script file.

The `Invoke-SqlPackageWithProgress` implementation in
[references/bacpac-command-helpers.ps1](references/bacpac-command-helpers.ps1)
is the only permitted process boundary for `SqlPackage` export and import. Do
not replace it with `Start-Process`, a shell command string, an alternate script,
or an executor-built wrapper. It uses
`ProcessStartInfo.ArgumentList` so every complete `/Name:<value>` element remains
one operating-system process argument and rejects empty or detached
connection-string and BACPAC-path fragments before launch.
Use only the manifest, checkpoint, and per-database folder layout defined by the
reference blocks; do not introduce aggregate `exports`, `manifest`, `evidence`,
or `checkpoint` folders.

Validate modern Go `sqlcmd` capabilities from the combined output of every
successful supported help mode (`--help` and `-?`). A required flag may appear
in either output. Report the successful help modes and exact missing flags before
offering installation; do not treat a reduced `--help` view as proof that an
installed client lacks flags exposed by `-?`. Quote the compatibility argument as
`'-?'`, and name wrapper parameters `$ArgumentList`, never `$Args`, so PowerShell's
automatic `$args` variable cannot consume the intended arguments. After an
approved `winget install sqlcmd`, rerun capability validation regardless of the
winget exit code; an already-installed/no-upgrade result is successful when the
refreshed client passes validation.


## Operating contract

- Collect all missing nonsecret migration inputs in one grouped request whenever
  possible, except database selection must follow authoritative source discovery
  when the user has not already supplied an exact database name or `All`. Reuse
  values already supplied by the user or discovered safely.
- Treat this as an **offline migration**. State that downtime will occur, but do
  not request a separate downtime acknowledgment. Include that acknowledgment in
  the single target-database creation approval. Do not ask when downtime should
  start, how long it may last, or what duration is acceptable.
- Require the user to select one online user database or all selectable online
  user databases. Never interpret `all` as including system databases.
- Do not run source migration readiness, compatibility, feature, dependency,
  performance, or sizing assessments. Even if the database is online and in read-write mode, allow the export to continue. However, inform the user that they must ensure there is no DML  and DDL activity on the database during the export.Consume prior skill outputs when supplied;
  otherwise use the source and target decisions provided by the user.
- For target details, require the existing Azure SQL logical server name and an
  explicit target configuration after export: service type (`GeneralPurpose`,
  `BusinessCritical`, or `Hyperscale`), service objective, and vCore count. Apply
  the catalog's documented maximum size automatically. Before export, collect only the existing logical server
  name. After every export is attempted and at least one succeeds, track each
  user input separately. Never infer a representative objective or vCore count
  from the service type. Validate the resolved configuration with
  `Resolve-ApprovedTargetSkuSelection`; do not accept an arbitrary objective or
  size outside the catalog. Do not ask for subscription, resource group, region, or target
  authentication before export.
- Never connect to either the source or target with SQL login/SQL authentication.
  Do not request, accept, retrieve, or use SQL passwords or SQL credentials. Use
  only Windows Integrated authentication or Microsoft Entra authentication
  supported by the workflow. Never read SQL credentials from Key Vault or
  Credential Manager, or expose, print, commit, or persist them.
- Run each `SqlPackage` operation with bounded status polling. Emit a progress
  update every 30 seconds with the database, batch position, operation, elapsed time, process
  state, diagnostics/BACPAC file growth, and latest sanitized diagnostic status
  so the user can distinguish movement from a potentially stalled operation.
  Write each static heartbeat to both the live terminal and a sanitized
  operation-status file beside the diagnostics, and flush host output after each
  line. If the command runner buffers terminal output until completion, tail the
  status file and relay its latest line at least every 30 seconds; do not rely on
  the transient `Write-Progress` display as the only visible progress channel.
  Print an immediate `Started` message before the first poll and tell the user
  that live status appears in the terminal. After five minutes without diagnostic
  or BACPAC growth, report `Possibly stalled` while making clear that the process
  is still active. Do not invent a percentage when `SqlPackage` does not provide one.
- Pass complete `/SourceConnectionString:<value>`,
  `/TargetConnectionString:<value>`, `/SourceFile:<value>`, and
  `/TargetFile:<value>` forms as individual string-array elements to the
  checked-in progress wrapper. Never split a switch name from its value or
  flatten the argument array into a command string.
- Do not execute destructive operations against the source database.
- After all exports and target authentication, run one injection-safe, read-only
  target `sys.databases` preflight through validated Go `sqlcmd` for the selected
  names. Mark databases observed
  before import as skipped. Never infer this condition from localized SqlPackage
  diagnostics.
  - Do not perform any write or edit or perform any DDL opertion in the source databases
- Surface errors and record the failed phase. For an `All` export or import, skip
  the failed database and continue the remaining databases. Do not report success
  based on a command that was not confirmed successful.
- Use Windows PowerShell syntax when running local commands on Windows.

## Assessment boundary

This skill assumes a separate assessment or user decision has already selected
Azure SQL Database, BACPAC, and any required source remediation.
Do not inspect the source for migration blockers or reevaluate the selected target
and method. If a prerequisite is missing, route to the appropriate assessment or
planning skill rather than adding assessment prompts to this workflow.

An export error may identify an unsupported object or feature. Record the error
and skip that database when processing an `All` selection; do not broaden the
migration run into a source assessment.


## Workflow

```text
Phase 0: Validate tooling, then collect source connection and safety inputs
Phase 1: Discover databases, resolve source scope, and prepare the complete execution manifest
Phase 2: Prepare local folders without an approval prompt
Phase 3: Export each selected database to its BACPAC subfolder
Phase 4: Select target SKU and size, authenticate, approve, then import with SqlPackage
Phase 5: Hand every successfully imported database to post-migration validation
```

## Phase 0 — Collect inputs and safety gates

Treat modern Go-based `gosqlcmd` or `sqlcmd` as a mandatory prerequisite for the
BACPAC workflow. Before discovery, folder creation, or export, prefer `gosqlcmd`,
then inspect every `sqlcmd` executable on `PATH`; do not assume the first result
is modern because ODBC and Go-based versions can coexist. Confirm only the
default interactive route's `-G` and `-U` flags. If a Go client launches but its
help does not expose those flags, retain it with unknown capability and use the
attended Phase 4 preflight as the authoritative check. Never select legacy ODBC
`sqlcmd`. If no Go candidate launches, ask once for approval to install modern `sqlcmd` with the official
`winget install sqlcmd` command. Do not install silently. If approved, install it,
refresh the current process `PATH`, and repeat discovery. If installation is
declined or validation still fails, stop before starting the migration and provide
the official manual-download link. Cache the resolved full path for Phase 4,
then reselect against the actual Phase 4 authentication route before preflight.

Do not ask for target service type, objective, vCore, or maximum size in Phase 0.
After Phase 3 has attempted every selected export and at least one succeeds, load
the checked-in catalog
`references/azure-sql-db-vcore-sku-limits.json` with
`Get-ApprovedTargetSkuCatalog` from `references/target-sku-validation.ps1`.
The catalog is derived from Microsoft Learn's *Single database vCore resource
limits* page, source-dated March 9, 2026 and updated April 10, 2026. Use the
staged input tracker and make collection interactive:

1. Present exactly `General Purpose`, `Business Critical`, and `Hyperscale` as
  service-type selections.
2. After that selection, filter the approved catalog and present only its exact
  provisioned/serverless hardware objective labels for the chosen type. Do not
  present a DTU `Standard`/`Premium` tier as a vCore objective.
3. After the objective selection, load its approved vCore values and require an
  explicit integer selection/input.
4. Then display the documented maximum data size for that exact vCore and apply
  it automatically without a separate confirmation prompt. Catalog entries must provide a
  `DocumentedMaxDataSizeGBByVCore` map. It records the resource-limit ceiling,
  not every configurable storage increment.

Keep separate status/value/options entries for `ServiceType`,
`ServiceObjective`, `VCore`, and `MaximumSizeGB`. Changing service type clears
the objective, vCore, and size; changing objective clears vCore and size. Never
select the first option or infer `1024 GB` for Hyperscale. The approved catalog
must map the friendly objective and vCore to an exact
`DatabaseServiceObjectiveTemplate` used to derive the SqlPackage objective
(for example `HS_Gen5_{0}` plus vCore `4` becomes `HS_Gen5_4`). Validate the
complete selection through `Resolve-ApprovedTargetSkuSelection`. Do not use
SqlPackage import to discover that a SKU is unavailable for the target server,
region, subscription, quota, or capacity.

The checked-in stable SKU list is:

| Service type | Compute/hardware objective | Published vCore choices | Published max data size |
| --- | --- | --- | --- |
| General Purpose | Provisioned standard-series (Gen5) | 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 24, 32, 40, 80, 128 | 1–4 TB, depending on vCore |
| General Purpose | Serverless standard-series (Gen5) | 1, 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 24, 32, 40, 80 max vCores | 512 GB–4 TB, depending on max vCore |
| General Purpose | Provisioned DC-series | 2, 4, 6, 8 | 1–3 TB, depending on vCore |
| Business Critical | Provisioned standard-series (Gen5) | 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 24, 32, 40, 80, 128 | 1–4 TB, depending on vCore |
| Business Critical | Provisioned DC-series | 2, 4, 6, 8 | 768 GB |
| Hyperscale | Provisioned standard-series (Gen5) | 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 24, 32, 40, 80 | 128 TB |
| Hyperscale | Serverless standard-series (Gen5) | 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 24, 32, 40, 80 max vCores | 128 TB |
| Hyperscale | Provisioned DC-series | 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 32, 40 | 128 TB |
| Hyperscale | Provisioned premium-series | 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 24, 32, 40, 64, 80, 128 | 128 TB |
| Hyperscale | Provisioned premium-series memory optimized | 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 24, 32, 40, 64, 80 | 128 TB |

Exclude Fsv2-series because it is unavailable for new creation and scheduled for
retirement on October 1, 2026. Exclude preview choices, including General Purpose
and Business Critical DC-series 10–40 vCores and Hyperscale premium-series 160
and 192 vCores. Treat every availability note as a guardrail: the catalog does
not prove regional availability, quota, subscription eligibility, or capacity.

Produce a concise migration plan before execution:

| Item | Value |
| --- | --- |
| Source Server | `<existing SQL Server instance name>` |
| Target server | `<existing Azure SQL logical server name>` |
| Target configuration | `Selected after export` |
| Method | Local BACPAC export/import with `SqlPackage` |
| Downtime | Offline; acknowledged in the target-database creation approval |
| Overwrite behavior | Create new database; never overwrite by default |
| Local root | `<user-provided path or default path>` |

Collect the missing source authentication, existing target logical server, and
export root in one grouped request. Source authentication is never inferred from
the host or silently defaulted: require an explicit selection of `Windows
Integrated` or `Microsoft Entra Interactive MFA`. For the export root, show
`$env:USERPROFILE\SqlMigration\Bacpac` as the recommended default and require the
user either to accept it or provide another absolute path; never append a
timestamp or create a run directory before this choice is resolved. Reuse a value
only when the user supplied it explicitly in the current request or earlier in
the conversation.

Before discovery or any filesystem write, create an in-memory input-resolution
record containing `SourceServer`, `SourceAuthentication`, `TargetServer`, and
`ExportRoot`. If any field is unresolved, stop and ask the grouped question. Do
not run discovery, create directories or checkpoints, or invoke `SqlPackage`
until all four fields are resolved. Echo the resolved nonsecret values to the
user before proceeding.

If the user's original request already names one exact source database or says
`All`, retain that value as the requested selection and do not ask for it again
before discovery. Otherwise, defer the database-selection field until Phase 1 so
it can contain the discovered database names. Input collection is not execution
approval. Do not request approval in Phases 0-3, and do not collect a downtime
start time, window, maximum duration, RPO, or RTO.

## Phase 1 — Discover databases and build the manifest

Connect to the source database using the following authentication methods:
a. Windows Authentication
b. Entra Authentication using Interactive MFA sign-in

After source authentication is established, always discover all online user
databases from the source instance before presenting a database-selection form.
Exclude `master`, `model`, `msdb`, `tempdb`, snapshots, and offline databases.
This is scope discovery, not migration assessment.

Resolve the database scope as follows:

1. If the user's original request or prior answer already supplied one exact
   database name, match it against the discovered selectable list. When it
   matches, reuse it without asking again. When it does not match, show the
   discovered list and ask for a corrected selection.
2. If the user already supplied `All`, reuse it without asking again; `All`
   means every database in the discovered selectable list.
3. Otherwise, display a single-choice form whose options are `All` followed by
   every exact discovered database name. Never display `All` as the only preset
   when one or more selectable databases were discovered, and do not require the
   user to type a discovered database name as free text.

If no selectable online user databases are discovered, stop with a clear error
instead of showing an empty or `All`-only selection form.


Require the source authentication selection made in the Phase 0 grouped request.
If Microsoft Entra authentication is selected, use the supported `SqlPackage`
authentication options for the installed version.
Reject SQL login authentication and do not request or use a password from any
source, including Key Vault, Credential Manager, masked controls, or `sqlcmd`.

Resolve the export root from the grouped input request. The recommended default is
`$env:USERPROFILE\SqlMigration\Bacpac`, but it is not selected until the user
accepts it. Use the accepted path exactly as the export root; do not silently add
a timestamped child folder. Build the complete in-memory manifest and database
mappings without creating folders, databases, or BACPAC files.


## Phase 2 — Prepare without prompting

Display the final source scope, target server name, database mappings, local root,
and overwrite behavior. State clearly that the workflow is offline and will cause
downtime.
Do not request execution confirmation here. Prepare local folders and run every
selected export from the displayed manifest. Do not prompt between databases,
for authentication retry routing, after failures, or between export and import.
An authentication or unsupported-object failure is not remediated inline: save
the database as awaiting manual remediation, give concrete external next steps,
and continue only with unaffected databases when `All` was selected.

Stop with a clear error when required nonsecret input is missing or inconsistent.
Changing application connection strings remains a separate cutover action.

This skill does not discover, create, or configure Azure resources. The target
logical server must already exist. Do not open a target SQL data-plane connection,
request target credentials, or test target database authentication before every
selected export has been attempted. The import phase creates one database for each
successfully exported source database after confirming that the name is not in use.

### Prepare local folders

For every selected database, use this exact layout:

```text
<export-root>\
  <database-name>\
  <database-name>.bacpac
  attempts\
    export\<UTC-GUID-attempt-id>\
      diagnostics.log
      console.log
      status.log
    import\<UTC-GUID-attempt-id>\
      diagnostics.log
      console.log
      status.log
```

The database name must be valid as a Windows folder name. If it contains an
invalid path character, is a reserved Windows name, would resolve outside the
export root, or maps to an existing symbolic link or junction, exclude that
database and display a warning that names the database and the reason it was
skipped. Do not silently sanitize it because the subfolder name controls the
target database name. If no eligible databases remain, stop before creating
folders.

Persist the user's original database selection as `SelectionMode`, with the
value `All` or `Explicit`; never infer this mode from the number of manifest
entries after discovery or path filtering. The migration manifest contains
`SourceDatabase`, `FolderPath`, `BacpacPath`,
`TargetDatabase`, `ExportStatus`, `ExportFailureReason`, `ExportLastUpdatedUtc`,
`ImportStatus`, `ImportFailureReason`, `ImportLastUpdatedUtc`,
`ImportStartedUtc`, `ImportCompletedUtc`, `ImportDuration`,
`ImportLastActivityUtc`, `TargetStateAfterImport`, `ResumeState`,
`FailureCategory`, `ManualNextAction`, and
`ValidationReportStatus`. Set `TargetDatabase` to the subfolder name. Use this
same manifest through export, import, and the validation handoff; do not rediscover
or broaden the selection later.

Use section 2 of [references/command-execution-setup.md](references/command-execution-setup.md) after the
manifest is displayed; no approval is required to create local folders.

## Phase 3 — Export with SqlPackage

Use the latest supported `SqlPackage` installed on the operator machine.
Validate the executable and version before running the export.

Use the export loop in section 3 of
[references/command-execution-export-import.md](references/command-execution-export-import.md) and obtain connection
details from an approved secure provider.

Treat the authenticated source connection as an immutable batch-level base. For
every manifest row, create a fresh connection-string builder, remove both
`Database` and `Initial Catalog` aliases, and set `Initial Catalog` to that row's
`SourceDatabase` unconditionally. A catalog supplied by the base connection,
including `master`, must never determine which database is exported.

Set the manifest status to `InProgress` before starting `SqlPackage`. Poll the
process every 30 seconds, update `ExportLastUpdatedUtc`, and display a console
heartbeat without exposing arguments or credentials. Include whether diagnostic
or BACPAC bytes increased since the previous poll and the latest sanitized
diagnostic status line. File growth is evidence of movement, not a completion
percentage; if neither file grows, state that the process is still running rather
than claiming it is stuck.

When the process exits, display `Succeeded` or `Failed`
immediately. On failure, include the database, exit code, sanitized reason, and
diagnostics path in the user-facing update.

For Microsoft Entra authentication, use the supported `SqlPackage`
authentication options for the installed version. Do not put an access token in
the command line.

For Windows integrated authentication, place `Integrated Security=True` (or
`Trusted_Connection=True`) inside `/SourceConnectionString`. Never generate
`/SourceIntegratedSecurity`; it is not a supported `SqlPackage` 170.4 argument.
Validate the complete argument template before the first database export so an
unsupported switch cannot fail multiple databases. If an already-running batch
reports an unrecognized argument, stop that batch, report the configuration
failure immediately, save the checkpoint, and provide the installed SqlPackage
version plus the unsupported argument as manual correction guidance. Do not edit
or rerun the command inline. Resume only failed/pending databases after the user
confirms the external configuration correction; do not re-export successful ones.
Treat configuration correction as manual remediation; the confirmation phrase is
`source remediation complete` because it unblocks the export stage, even though
no source database change is authorized.

Export gates:

- Immediately before each export, check the exact manifest `BacpacPath` with a
  literal-path file test. If a file already exists at that path, do not start
  SqlPackage and never overwrite, rename, delete, or reuse the file. Mark that
  export `Failed` and `AwaitingManualRemediation`, report the full path and
  `A BACPAC file with the same name already exists`, save the checkpoint, and
  instruct the user to preserve/move the existing evidence or choose a new export
  root outside this workflow. Resume only after `source remediation complete`
  and after confirming that the intended path no longer exists. For `All`,
  continue only with databases whose BACPAC destination does not already exist.
- Confirm the export exit code is successful.
- Confirm the export produced the expected BACPAC file. Artifact validation is
  deferred until immediately before import.
- Confirm the source was not modified by the export workflow.
- Record the export timestamp and source database state.

If export fails, preserve the diagnostics and record the database and failure
reason. Never silently omit a failed database or failed object from the report.

If diagnostics identify an authentication failure, do not refresh credentials,
retry, prompt for another authentication method, or switch to an Entra/SQL/managed
identity fallback in the current execution. Mark the export `Failed`, set
`ResumeState = AwaitingManualRemediation`, save a sanitized checkpoint, and show:

1. the selected authentication method and sanitized SqlPackage error;
2. the diagnostics and checkpoint locations;
3. instructions to verify the same identity can connect to and read the source
  database, correct its login/user permissions, firewall/network route, MFA or
  approved secure-store entry outside this workflow as applicable; and
4. instructions to return with `authentication remediation complete` to resume
  the failed database, or restart with the same export root.

Never request, print, or persist a password or token while reporting the failure.
Do not retry until the user confirms that external remediation is complete; then
revalidate the connection and retry only the failed/pending database. A different
authentication method is a restarted/revised run, not inline remediation.

If diagnostics identify unsupported source schema, code, or objects, do not alter
DDL, drop/disable an object, restore or clone another database, export from a
substitute database, or invoke an automated remediation. Record the exact
unsupported item when diagnostics provide it, set the same awaiting-remediation
state, and direct the user to review the diagnostics, assess and approve the
required source change outside this skill, back up the source, apply and test that
change manually, and return with `source remediation complete`. Do not invent a
generic schema change when SqlPackage does not identify one.

For an `All` selection, mark that database `Failed`, skip it, and continue exporting
the remaining databases. After every selected export has been attempted, proceed
with only manifest items whose `ExportStatus` is `Succeeded`. If no exports
succeeded, stop before target connectivity. For a single-database selection, stop
when its export fails. After the export loop, display a summary of succeeded and
failed databases as a table with `DatabaseName`, `Status` (`Success`, `Fail`, or
`InProgress`), and human-readable `BacpacSize`. Show `Not created` when no BACPAC
file exists. Include each failed database's sanitized reason and diagnostics path
before starting target connectivity.

## Phase 4 — Initiate target connectivity and import

After every selected export has reached `Succeeded` or `Failed` and at least one
BACPAC succeeded, reuse the modern Go-based `sqlcmd` executable validated in
Phase 0 and invoke it by its resolved full path. If that exact executable is no
longer available, stop before target connectivity and report that the prerequisite
changed during the run; do not substitute an unvalidated executable.

Before target authentication or connectivity, select and freeze the target SKU
and size using these steps:

1. Load the checked-in catalog with `Get-ApprovedTargetSkuCatalog`.
2. Display `General Purpose`, `Business Critical`, and `Hyperscale`; require one
  service type.
3. Filter and display only the compute/hardware objectives for that service type;
  require one objective.
4. Display only the published vCore values for that objective; require one integer.
5. Apply the Microsoft Learn documented maximum data size for that vCore
  automatically; do not present a separate Yes/No acceptance flow.
6. Call `Complete-TargetConfiguration`, display the resolved service type,
  objective, vCore, maximum size, `DatabaseEdition`, and
  `DatabaseServiceObjective`, then persist them in the sanitized checkpoint.

If a Phase 4 checkpoint already contains a target configuration, revalidate and
reuse it rather than asking again. If the checkpoint predates target selection,
run the six steps above. Changing an upstream selection resets all downstream
tracker values.

Treat unresolved target configuration as a blocking interactive state, not a
successful stopping point. After the export summary, immediately ask for the
service type; after each answer, ask for the dependent objective and vCore value
until `Complete-TargetConfiguration` succeeds. Do not end the run, report the
migration as complete, or leave imports merely `Pending` while
`TargetConfiguration` is null unless the user explicitly pauses or cancels.

After the modern `sqlcmd` gate passes, default target import authentication to
interactive Microsoft Entra ID. Do not ask the user to choose an authentication
method unless they explicitly request the default credential chain. When choices
must be shown, present them in this order:

| Target authentication | Command | Recommendation |
| --- | --- | --- |
| Interactive Microsoft Entra ID | `sqlcmd -S <server> -G -U <user>` | **Default**; attended and supports MFA |
| Microsoft Entra default credential chain (`ActiveDirectoryDefault`) | `sqlcmd -S <server> --authentication-method ActiveDirectoryDefault` | Optional explicit override when an Azure CLI, developer credential, or managed identity should be reused |

For interactive Entra ID, require the user's UPN and never place a password or
token on the command line. Reject SQL login authentication; never invoke a password
prompt or read credentials from Key Vault, Credential Manager, or a masked control.
Use the approval-time target preflight as the authentication/connectivity check;
do not launch a separate preliminary `sqlcmd` probe. After that preflight succeeds,
call `New-TargetConnectionStringForApprovedAuthentication` to build the equivalent
secretless, `SqlPackage`-supported target connection in memory without another
browser prompt. Do not read an ambient `$targetConnectionString` variable, and do
not display or persist the generated value. `SqlPackage` authenticates independently
with the selected method; no `sqlcmd` token is handed off. Use
`InteractiveEntra` unless the user explicitly selects `ActiveDirectoryDefault`.
Separate `sqlcmd` and `SqlPackage` processes can each display an interactive
sign-in prompt.
Then show the exact Phase 4 approved Azure SQL Database settings for the batch:

- service type (`GeneralPurpose`, `BusinessCritical`, or `Hyperscale`);
- approved catalog service objective;
- explicitly selected vCore count;
- derived SqlPackage database service objective;
- automatically applied catalog maximum database size in GB.

Do not change SKU settings after the Phase 4 selection is checkpointed. Revalidate
the immutable selection against the same approved catalog before displaying it.
The single
grouped approval must be tabular;
do not describe the eligible databases, BACPAC paths, or target settings in a prose
paragraph. Render these two tables before requesting approval:

| DatabaseName | ExportStatus | BacpacPath |
| --- | --- | --- |
| `<target database>` | `Success` | `<full local BACPAC path>` |

| TargetServer | Authentication | ServiceType | ServiceObjective | VCore | DatabaseServiceObjective | MaximumSizeGB | Overwrite |
| --- | --- | --- | --- | ---: | --- | ---: | --- |
| `<logical server>` | `<method>` | `<GeneralPurpose / BusinessCritical / Hyperscale>` | `<catalog objective>` | `<vCore>` | `<derived objective>` | `<size>` | `No` |

After authentication, use that same approved identity and validated Go `sqlcmd`
route for one injection-safe, read-only `sys.databases` query covering every
successfully exported target name. Run this preflight before displaying the
approval tables.
Mark every name observed by this query as `Skipped - database existed before
import`, exclude it from the approval table, and retain the observation as
evidence. If the preflight cannot complete, stop before approval and do not import;
do not fall back to diagnostic-text matching.

After approval, run exactly one final pre-import preflight and consume its
scoped `FinalImport` receipt directly in the import loop. There are exactly two
target preflight calls in a successful run: the approval-time call and the final
pre-import call. Never add a third preflight inside a generated import script.
Each preflight must have a bounded timeout; stop the exact `sqlcmd` process and
pause the migration if it does not return within the configured limit.
Use a 600-second default for interactive Entra browser/MFA authentication and
180 seconds for `ActiveDirectoryDefault`. Keep interactive `sqlcmd` attached to
the current console and use its `-o` option for structured result capture; do
not redirect standard input, output, or error while the attended login runs.

The final preflight is a point-in-time collision check, not a reservation or
ownership guarantee. With SqlPackage-only target mutation, another actor can
create the name after preflight and before or during import. On success, report
`TargetStateAfterImport = ImportedSuccessfully`; do not claim that the workflow
created or owns the Azure resource.

After the tables, ask one short approval question that states the import is offline
and authorizes `SqlPackage.exe /Action:Import` against the listed target database
names with this residual race disclosed. Do not repeat the table contents in
prose. After approval, use only
`SqlPackage.exe /Action:Import` for target mutation and do not call an Azure API.

Import only entries whose `ExportStatus` is `Succeeded`; for each, require its
selected folder and a file named `<subfolder-name>.bacpac`. Do not treat a failed
export's folder as an import error.

Immediately before each import, validate the BACPAC at the exact manifest path:

- Confirm the expected BACPAC exists and has a plausible nonzero size.
- Run the BACPAC verification/checksum process used by the operator.
- Do not import when either check fails. Mark that import `Failed` and
  `AwaitingManualRemediation`, preserve the artifact and diagnostics, and continue
  only with unaffected databases when `SelectionMode` is `All`.

Use the local import loop in section 4 of
[references/command-execution-export-import.md](references/command-execution-export-import.md).

Use one `/TargetConnectionString` containing the selected supported authentication
method, server, and database name. Never print that argument. Pass the SKU with
`/p:DatabaseEdition`, `/p:DatabaseServiceObjective`, and
`/p:DatabaseMaximumSize`. Do not mix `/TargetConnectionString` with other target
connection parameters, including `/TargetDatabaseName`. When constructing the
per-database connection string with `DbConnectionStringBuilder`, invoke its
`set_ConnectionString()` and `get_ConnectionString()` methods explicitly;
PowerShell property assignment can be routed through the builder's dictionary
interface and create an invalid nested `ConnectionString` key.

Before launching the first import, state that live progress will appear in the
terminal every 30 seconds. Print `Started` immediately for every import, including
its position in the batch, then poll every 30 seconds and report the database,
elapsed time, process state, diagnostics-file size and growth, and latest sanitized
diagnostic status. Use `Running` when diagnostics changed, `Running - no new
diagnostics yet` while the process remains active, and `Possibly stalled` after
five minutes without diagnostic activity. The latter is informational and must not
stop the process before the configured timeout. Import has no growing local output
file equivalent to the export BACPAC, so use process state and diagnostics growth
as movement indicators without claiming a percentage. If an active import reports
`Incorrect syntax near 'EDITION'` while the target database is already visible as
`ONLINE`, treat it as a nonterminal SqlPackage diagnostic-masking/parser message:
report it as still running and continue polling until the SqlPackage process exits.
Do not classify that text alone as a failure, do not restart the import, and do not
switch authentication or SKU settings because of it. Do not leave a failed
operation in `InProgress` or continue polling an exited process. Persist the same
sanitized lines to the current attempt's
`<database-folder>\attempts\import\<attempt-id>\status.log`; when an agent or
command runner cannot stream a blocking command's output, it must tail this file
and relay the latest heartbeat rather than leaving the user without an update.

Import gates:

- Record the `SqlPackage` exit result for every attempted database; only mark an
  individual import `Succeeded` when its exit code confirms success.
- Record import duration and any warnings.
- Stop if the import targets an unexpected server or database.

For an `All` selection, process only the folders recorded in the manifest. A
database may be marked `Skipped` only by the successful pre-import
`sys.databases` observation. For every nonzero SqlPackage exit, record its
sanitized reason and diagnostics path, mark it `Failed`, and state that the target
may have been partially created and requires explicit inspection before retry.
Never convert an attempted import failure to `Skipped` by matching diagnostic
text, regardless of wording or localization. Re-run the same authoritative
database-existence query after a failed import and record whether the target is
present or absent; if that inspection fails, stop the batch rather than continuing
with unknown target state. Continue importing the remaining BACPACs when `All` is
selected only after that inspection succeeds. After all import attempts, display one tabular row per
attempted database with `DatabaseName`, `Status` (`Success`, `Skipped`, `Fail`, or
`InProgress`), `ServiceType`, `ServiceObjective`, `VCore`,
`DatabaseServiceObjective`, and `MaximumSizeGB`. Keep failure
reasons and diagnostics paths below the table. Invoke validation only for entries
whose `ImportStatus` is `Succeeded`.

After each database reaches a terminal state, also display the current batch as a
table with `DatabaseName`, `Status`, `Elapsed`, and `Detail`. Rows not yet attempted
must remain `Pending`; the active row is `InProgress`; completed rows are `Success`,
`Skipped`, or `Fail`. This intermediate table supplements rather than replaces the
30-second heartbeat and final import summary.

## Phase 5 — Hand off post-migration validation

For each manifest entry whose `ImportStatus` is `Succeeded`, invoke
`validate-post-migration-data` with the existing source connection, target
connection details and authentication route, database mapping, source write-freeze
evidence, approved Azure SQL Database adaptations, and evidence location. Do not
invoke validation for skipped exports or imports. Do not request credentials again
or run data/schema reconciliation in this migration skill.

Store only the returned validation report status and location in the migration
manifest. Do not mark the overall migration complete when any selected database
report is `Fail` or `In progress`. This workflow does not delete the source
database, BACPAC files, diagnostics, manifest, or validation evidence. Cleanup is
a separate, explicitly requested process.




## Operational failures and routing

Do not proactively scan the source for these conditions. Use this table only when
an export or import command reports the corresponding failure.

| Failure | Action |
| --- | --- |
| BACPAC destination file already exists | Do not start or continue that export and do not overwrite, rename, delete, or reuse the file. Mark the item `Failed` and `AwaitingManualRemediation`, save the checkpoint, report the exact path and name collision, and direct the user to preserve/move the existing evidence or choose a new export root externally. Resume after `source remediation complete` only when the intended destination no longer exists. |
| Unsupported `SqlPackage` argument | Stop the batch, mark affected items `AwaitingManualRemediation`, save the checkpoint, and report the argument, installed SqlPackage version, diagnostics, and manual template/configuration correction required. Do not edit or rerun the command inline. Resume failed/pending databases only after user confirmation. |
| Unsupported source object or feature | Mark the database `Failed` and `AwaitingManualRemediation`, save the sanitized checkpoint, and provide diagnostics plus external assessment/change/test/resume steps. Do not change source code/schema, restore a substitute database, or invoke remediation inline. Stop for a single database; for `All`, continue only unaffected databases. |
| Authentication failure during export or import | Mark the database `Failed` and `AwaitingManualRemediation`, save the sanitized checkpoint, and provide identity, permission, network/firewall, secure-store or MFA verification steps appropriate to the selected method. Do not retry, refresh, or switch authentication inline. |
| Target database exists before import | Observe it with the injection-safe, read-only `sys.databases` preflight through validated Go `sqlcmd`, mark it `Skipped - database existed before import`, and exclude it from import approval/execution. A SqlPackage failure never proves this condition. |
| Target may have been created by a failed import | Keep the attempted import `Failed`, preserve diagnostics, and require explicit target inspection before retry. Do not relabel it `Skipped` merely because a database now exists. |
| `Incorrect syntax near 'EDITION'` appears while import is still running and target database is `ONLINE` | Treat as nonterminal SqlPackage diagnostic-masking/parser output. Continue polling the active process and use only process exit code plus authoritative target inspection after exit for terminal classification. |
| Import timeout or throttling | Mark the import `Failed` and `AwaitingManualRemediation`, save the checkpoint, and instruct the user to address target sizing, throttling, or connectivity externally. Retry the same verified BACPAC only after `target remediation complete`. |
| Missing target user or permission | Route identity remediation to the target security workflow. |
| Target capacity is insufficient | Stop and route to the sizing/planning skill before retrying import. |

## Manual-remediation resume gate

Persist a sanitized checkpoint after every terminal export/import result. It may
contain nonsecret mappings, statuses, timestamps, diagnostics paths, failure
categories, and manual next actions, but never connection strings, passwords,
tokens, or command lines containing them. On resume, treat the checkpoint only as
a cursor: revalidate the source/target identity, selected database mapping, local
BACPAC state, and target preflight from authoritative sources.

Retry an `AwaitingManualRemediation` item only after the user explicitly states
`authentication remediation complete`, `source remediation complete`, or `target
remediation complete` as applicable. Display the failed database, prior sanitized
reason, and intended retry before proceeding. Preserve successful exports/imports
and do not repeat them. If the user instead requests a fresh execution, rebuild
the manifest after discovery in a new export root. Never overwrite an existing
checkpoint, BACPAC, diagnostics file, or status file during a fresh execution;
retain the old export root as immutable evidence.

Every export or import invocation, including an approved retry, must create a new
UTC-and-GUID attempt directory. Record each attempt ID, timestamps, result, and
its diagnostics, console, and status paths in the sanitized checkpoint. Never
reuse or truncate an earlier attempt's evidence files.

## Result format

After planning, report:

> **Migration plan — `<source database or all selectable user databases>`**
> **Azure SQL Database** via **BACPAC** · downtime **offline**

| | Decision |
| --- | --- |
| Target | Azure SQL Database — `<logical server name>` |
| Method | BACPAC export/import with `SqlPackage` |
| Import execution | `SqlPackage.exe /Action:Import` only |
| Completion | `<Complete / Failed / In progress>` |

Include:

- Selected database scope and resolved export root.
- One local BACPAC path per database.
- Per-database export/import operation status.
- Last status-update time, sanitized failure reason, and diagnostics location for
  every failed or long-running operation.
- Per-database validation handoff/report status and report location.

For a failed operation, state the failed phase, error category, evidence
location, and the remediation required. Never present a partial migration as
complete.

## References

- [Local BACPAC command execution — manifest setup](references/command-execution-setup.md)
- [Local BACPAC command execution — export and import](references/command-execution-export-import.md)
- [SqlPackage export action](https://learn.microsoft.com/en-us/sql/tools/sqlpackage/sqlpackage-export)
- [SqlPackage import action](https://learn.microsoft.com/en-us/sql/tools/sqlpackage/sqlpackage-import)
- [Azure SQL Database migration overview](https://learn.microsoft.com/en-us/data-migration/sql-server/database/overview)
- [Azure SQL Database elastic jobs](https://learn.microsoft.com/en-us/azure/azure-sql/database/elastic-jobs-overview)
