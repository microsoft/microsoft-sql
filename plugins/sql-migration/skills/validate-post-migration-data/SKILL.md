---
name: validate-post-migration-data
description: "Validate data and schema after migrating SQL Server to Azure SQL Database, Azure SQL Managed Instance, or SQL Server on Azure VM. Use after migration, restore, BACPAC import, LRS completion, cutover validation, row-count comparison, or source-target reconciliation."
---

# Validate data after SQL migration

## When to Use

- Validate schema or data after a SQL Server migration target is online.
- Compare source and target table inventories, row counts, schemas, or content.

Validate a completed SQL Server database migration against its source without
changing data, schema, configuration, security, or database state on either side.
This skill supports Azure SQL Database, Azure SQL Managed Instance, and SQL Server
on Azure VM targets.

Use this skill only after the migration skill reports that the target database is
online. Migration completion and validation completion are separate states.

## Operating contract

- Default to the `RowCount` profile. It compares the user-table inventory and exact
  row counts for every mapped table. Run it automatically after migration without
  a separate validation consent or per-table prompts. Run the broader `Full`
  profile only when the user explicitly requested schema and content validation.
- Reuse the source and target server names, database mappings, preserved source
  and target authentication modes, user principal names for Entra fallback, and
  secure connection or token-capable routes established by the migration
  workflow. Execute validation queries through a verified modern Go-based
  `sqlcmd` executable selected by its full path only when an inherited reusable
  connection route is unavailable.
- Reuse the migration workflow's verified target SQL connection handle. If it is
  unavailable and the handoff specifies `TargetAuthentication=Windows` for a
  `SQL VM`, use Windows Integrated authentication with `-E`. If the handoff
  specifies `TargetAuthentication=Entra`, use the cached Microsoft Entra token
  context through a token-capable in-memory connection adapter. Only as the final
  Entra fallback, open one attended Microsoft Entra `sqlcmd` login with
  `-G -U <user-principal-name>` and run every target check in that process. Reuse
  the verified source connection or token-capable route first. If it is
  unavailable, retain the handoff's `SourceAuthentication` mode: use `-E` for
  `Windows` or the approved `-G -U <source-user-principal-name>` route for
  `Entra`. Permit at most one attended source sign-in for the entire validation
  run and reuse its authenticated context for both source passes. Never change
  either endpoint's authentication mode during validation. Never connect to either
  endpoint with SQL login/SQL authentication. Do not request, accept, retrieve, or
  use SQL passwords or SQL credentials. Use only Windows Integrated authentication
  or Microsoft Entra authentication supported by the workflow. Never read SQL credentials from Key
  Vault or Credential Manager, or display a password prompt. Do not invoke
  `Connect-AzAccount`, switch identities, or prompt once per pass/table.
  Never echo, print, log, or persist passwords, tokens, connection strings, or
  access keys, and never place them in command-line arguments or environment
  variables.
- Execute only read-only catalog and data queries. Do not issue DDL, DML, `MERGE`,
  `TRUNCATE`, repair options, configuration changes, statistics updates, or source
  and target state changes.
- Never run `DBCC CHECKDB` or another DBCC command against the source as part of
  post-migration validation.
- Never enable snapshot isolation, create database snapshots, add helper objects,
  or change a database to read-only for validation. Use quiesced comparison when
  the migration handoff provides it. For a writable-source LRS migration, consume
  the final backup completion time and LSN as the migration cutoff and do not ask
  for source writes to be paused.
- Validate one approved source-target database pair at a time. Do not discover or
  add databases outside the migration manifest.
- Stop and report `Failed` when the target or required comparison reference is
  unavailable, the target is not online, permissions are insufficient, or a
  required query fails. The original source endpoint may be unavailable only for
  a Continuous LRS handoff that proves it is `RESTORING` and supplies either an
  immutable cutoff evidence package or a queryable copy restored through the
  exact final LSN. Never query that restoring source or turn a skipped or
  incomplete check into a pass.
- Treat expected target adaptations as explicit, approved exceptions. Do not hide
  them from the report or count an unapproved difference as a pass.
- Do not ask for validation scope, table selections, exceptions, output format,
  evidence retention, timeouts, hash columns, or smoke queries during the default
  flow. Derive scope and existing exceptions from the immutable migration handoff,
  use bounded defaults, and record unavailable optional evidence as a limitation.
  Ask only when a required source/target endpoint is absent or every cached
  authentication route fails silent renewal. Permit at most one attended target
  authentication attempt for the complete validation run. A query failure is
  reported in the result; it is not a prompt.

## Required context

Consume these values from the migration handoff:

| Value | Requirement |
| --- | --- |
| Source | Server/instance and database; preserved authentication mode (`Windows` or `Entra`); reusable connection or token-capable route; Entra user principal name only for attended fallback; plus a queryable source, an immutable profile-complete cutoff evidence package, or a separately restored queryable copy through the final LSN. A Continuous LRS source in `RESTORING` must use one of the latter two references |
| Target | Target type (`SQL DB`, `SQL MI`, or `SQL VM`), server/instance, database, preserved authentication mode (`Windows` or `Entra`), reusable connection, Microsoft Entra token route when applicable, and Entra user principal name only for Entra fallback login |
| Scope | Immutable source-target database mappings from the migration manifest |
| Consistency | Comparison mode (`Quiesced` or `Writable source with cutoff`), cutover timestamp, and final backup LSN/file when applicable |
| Profile | Default `RowCount`; `Full` only when explicitly requested before validation starts |
| Exceptions | Inherit approved object exclusions and intentional target adaptations; default to none |
| Evidence | Reuse the migration evidence location and retention; otherwise return the report in memory/chat without prompting |

Do not redisplay or reconfirm a complete immutable handoff. Ask once for all
missing required nonsecret endpoint values. Test the inherited target connection
first. For an Entra handoff, test the cached Microsoft Entra token context silently
before showing authentication UI and permit one attended Microsoft Entra sign-in
only when both Entra routes are unusable. For a Windows-authenticated SQL VM
handoff, use `-E` if the inherited handle is unavailable; do not show Entra
authentication UI. Apply the same rules independently to the source: never infer
its mode from its hosting location, never substitute the target identity, and
never silently switch between Windows and Entra. Reject SQL login authentication;
do not request a password in
chat, a masked control, or a native `sqlcmd` prompt.

## sqlcmd prerequisite and connection contract

Before connecting to either endpoint, inspect every `sqlcmd` executable on `PATH`.
Do not accept the first result merely because it is named `sqlcmd`; older ODBC and
modern Go-based clients can coexist. Select a candidate only when `--version`
succeeds. Inspect both modern help (`--help`) and SQLCMD-compatible help (`-?`),
then require the successful help outputs to collectively expose `-E`, `-G`, and
`-U`. Current Go `sqlcmd` builds differ in where they list compatibility flags,
so always try both before rejecting a candidate:

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

$modernSqlcmd = Find-CompatibleGoSqlcmd -RequiredFlags @('-E', '-G', '-U')
```

If no candidate passes and the migration workflow's preparation consent covers a
CurrentUser tool install, run the official Windows package command without another
prompt. Otherwise ask once for approval. Refresh the current process `PATH`, and
validate again:

```powershell
winget install sqlcmd --accept-package-agreements --accept-source-agreements
if ($LASTEXITCODE -ne 0) {
  throw 'Modern sqlcmd installation failed.'
}

$refreshedPathSegments = @(
  $env:Path
  [Environment]::GetEnvironmentVariable('Path', 'Machine')
  [Environment]::GetEnvironmentVariable('Path', 'User')
) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
$env:Path = $refreshedPathSegments -join ';'
$modernSqlcmd = Find-CompatibleGoSqlcmd -RequiredFlags @('-E', '-G', '-U')
if (-not $modernSqlcmd) {
  throw 'Modern sqlcmd was installed but could not be validated. Open a new terminal and retry.'
}
```

If installation is declined, `winget` is unavailable, or validation still fails,
stop before connecting and provide
`https://learn.microsoft.com/sql/tools/sqlcmd/sqlcmd-download-install`. Never run
an unqualified `sqlcmd`; invoke `$modernSqlcmd.Path` so an older executable earlier
on `PATH` cannot be selected accidentally.

Create access-controlled local `.sql` files for the read-only query batches and
separate source and target output files. Query files must not contain credentials,
tokens, connection strings, DDL, DML, DBCC, or `:!!` shell commands. Put both
target passes in one query file and one `sqlcmd` process so attended Entra
authentication occurs at most once when the reusable target connection and cached
token adapter are unavailable. Bracket that target process with the two
noninteractive Windows-authenticated source passes:

The following direct-source process applies only while the original source is
queryable. If the handoff marks it `RESTORING`, do not execute either source
process. Instead, validate the evidence package hash and cutoff binding and use
its normalized inventory/count records as source passes, or run both source
passes against the separately restored cutoff copy. Before using these fallback
processes, try the handoff's reusable source connection and token-capable route.
For an Entra fallback, silently reuse the cached authentication context and allow
at most one attended sign-in across both source passes.

```powershell
$sourceAuthenticationArguments = @(switch ($sourceAuthentication) {
  'Windows' {
    @('-E')
    break
  }
  'Entra' {
    if ([string]::IsNullOrWhiteSpace($sourceUserPrincipalName)) {
      throw 'The Entra source handoff does not contain a user principal name for attended fallback.'
    }
    @('-G', '-U', $sourceUserPrincipalName)
    break
  }
  default {
    throw "Unsupported source authentication mode '$sourceAuthentication'."
  }
})

& $modernSqlcmd.Path -S $sourceServer -d $sourceDatabase `
  @sourceAuthenticationArguments -b -r1 -h -1 -W -s '|' -w 65535 `
  -i $sourcePassAQueryPath -o $sourcePassAOutputPath
if ($LASTEXITCODE -ne 0) {
  throw "Source validation pass A failed with exit code $LASTEXITCODE."
}

$targetAuthenticationArguments = @(switch ($targetAuthentication) {
  'Windows' {
    if ($targetType -ne 'SQL VM') {
      throw 'Windows target authentication is supported only for a SQL VM handoff.'
    }
    @('-E')
    break
  }
  'Entra' {
    if ([string]::IsNullOrWhiteSpace($targetUserPrincipalName)) {
      throw 'The Entra target handoff does not contain a user principal name for attended fallback.'
    }
    @('-G', '-U', $targetUserPrincipalName)
    break
  }
  default {
    throw "Unsupported target authentication mode '$targetAuthentication'."
  }
})

& $modernSqlcmd.Path -S $targetServer -d $targetDatabase `
  @targetAuthenticationArguments -b -r1 -h -1 -W -s '|' -w 65535 `
  -i $targetPassesQueryPath -o $targetPassesOutputPath
if ($LASTEXITCODE -ne 0) {
  throw "Target validation passes failed with exit code $LASTEXITCODE."
}

& $modernSqlcmd.Path -S $sourceServer -d $sourceDatabase `
  @sourceAuthenticationArguments -b -r1 -h -1 -W -s '|' -w 65535 `
  -i $sourcePassBQueryPath -o $sourcePassBOutputPath
if ($LASTEXITCODE -ne 0) {
  throw "Source validation pass B failed with exit code $LASTEXITCODE."
}
```

Use `-C` only when trusting the presented server certificate is an explicitly
accepted environment policy. Otherwise configure a verifiable certificate and
omit `-C`. Treat a nonzero `sqlcmd` exit code, missing output, malformed result, or
interactive-login cancellation as `Fail`. Normalize and compare the structured
source and target result sets in memory; never infer a match from console text or
a zero exit code alone.

Use strict pipe-delimited rows for every validation result. Do not use `FOR JSON`,
`FOR XML`, formatted tables, or a split limit. Prefix each row with one of the
declared record types (`META`, `INVENTORY`, `COUNT`, `ERROR`, or `CUTOFF`), run
`SET NOCOUNT ON`, split on every `|`, and require the exact field count for that
record type. Encode nullable text as `~` for `NULL`, otherwise prefix it with
`v:` and replace `%`, `|`, CR, and LF with `%25`, `%7C`, `%0D`, and `%0A`
respectively. Decode in reverse replacement order with `%25` last. Convert
`COUNT_BIG`, compatibility levels, isolation levels, and Boolean values to their
declared PowerShell types; malformed, duplicate, missing, or unknown rows fail
validation.

Select the database only with the `sqlcmd -d` argument. Do not put `USE` in a
machine-read query batch because its context message can contaminate delimited
output. Capture `$LASTEXITCODE` immediately after each `sqlcmd` process, before
ACL updates, output parsing, or any other native command.

When constructing the one target file containing passes A and B, terminate each
pass and place `GO` on its own line. Join generated fragments with an explicit
newline; never concatenate strings in a way that can produce `GOSET`:

```powershell-pseudocode
$targetPassesSql = @(
  (New-ValidationPass -Pass 'A').TrimEnd()
  'GO'
  (New-ValidationPass -Pass 'B').TrimEnd()
  'GO'
) -join [Environment]::NewLine
```

## Status model

Every validation scenario has one of these statuses:

- `In progress`: started but not yet conclusively completed.
- `Pass`: completed and matched, or an approved exception matched its expectation.
- `Inconclusive`: the check completed, but a writable source changed or differs
  from the target and no cutoff-consistent source reference exists to distinguish
  expected post-cutoff activity from a migration difference.
- `Fail`: proven mismatch, query failure, source change in `Quiesced` mode,
  unexpected target change, unsupported required check, or missing required
  evidence.

The database result is `Pass` only when every required scenario passes and the
comparison boundary is proven. It is `Ready with conditions` when every measured
scenario is `Pass` or `Inconclusive`, no scenario failed, and a writable source
prevents exact point-in-time equality from being proven. It remains `In progress`
while a required scenario is running and is `Fail` when any required scenario
fails. Do not turn a proven cutoff mismatch, missing target table, or query failure
into `Ready with conditions`.

## Workflow

```text
Phase 0  Accept the handoff and prove read-only access without reconfirmation
Phase 1  Compare the complete user-table inventory
Phase 2  Capture exact source and target row-count pass A
Phase 3  Recapture exact target and source row-count pass B
Phase 4  Run schema/content checks only for the explicit Full profile
Phase 5  Classify stability and cutoff evidence, then publish one report
```

The `RowCount` profile runs Phases 0-3 and 5. It does not ask whether to run Phase
4. The `Full` profile runs all phases. Prefer the inherited target connection for
all target-side checks. On fallback, use one target `sqlcmd` process for both
target passes so interactive authentication is not repeated per table or phase.

## Phase 0 - Handoff and safety gates

1. Load the source-target mapping and target type from the immutable migration
  manifest without asking the user to confirm them again.
2. Resolve and validate modern `sqlcmd`, reusing the migration workflow's tool
  installation consent when it is absent; otherwise ask once.
3. Test and reuse the inherited source and target connections independently. For
  an Entra source, try its inherited token-capable route silently before using
  the approved `-G -U <source-user-principal-name>` fallback, with at most one
  attended source sign-in for the run. For a Windows source, use `-E` only when
  its inherited handle is unavailable. If the target connection is unavailable, try the
  cached Microsoft Entra token context silently for an Entra handoff. Use
  `-G -U <user-principal-name>` once only when both Entra routes fail. For a
  Windows-authenticated SQL VM handoff, retain that mode and use `-E` when the
  inherited target handle is unavailable. Do not infer source authentication
  from an on-premises location or silently switch either endpoint's identity.
  Verify the actual server and database identity returned by each endpoint.
4. Verify the target database is online and queryable.
5. Determine the comparison mode from the migration handoff. For `Quiesced`,
  confirm the source remains quiesced. For `Writable source with cutoff`, verify
  the final backup file, completion time, and LSN from the immutable manifest;
  use a hash-verified immutable source evidence package captured while quiesced or
  a separately restored copy at that exact LSN. When the original source is
  `RESTORING`, do not connect to it. Reject a missing, mismatched, or incomplete
  cutoff reference rather than degrading to current-source observation.
6. Verify the principal can read catalog metadata and `SELECT` every in-scope user
   table. Insufficient visibility is a failure, not a zero count.
7. Create the in-memory scenario manifest with all checks set to `In progress` and
  proceed automatically. Do not ask for permission to execute read-only queries.

Do not impersonate a broader principal or grant permissions as part of validation.

## Phase 1 - Inventory and baseline fingerprints

On both endpoints, capture before-values without changing either database:

- Actual server, database, engine edition, database state, collation, and
  compatibility level where exposed by the target.
- Maximum `modify_date` for user objects and the count of user objects.
- A deterministic hash of the normalized user-object inventory and schema metadata
  collected in Phase 2.
- Per-table row counts collected in Phase 3, timestamped in UTC.
- Source quiescence evidence or writable-source cutoff file/time/LSN from the
  migration handoff.

For `RowCount`, compare the complete normalized `(schema, table)` inventory before
counting. A source table missing on target or an unexpected target table is a
`Fail`, unless it exactly matches an inherited approved exception. This inventory
gate prevents a row-count run from silently skipping a missing table. Full column,
constraint, module, and permission comparison belongs to the `Full` profile.

A catalog `modify_date` does not detect data changes, so row counts and optional
content signatures must also be recaptured in Phase 5. Record isolation level and
whether source quiescence was independently confirmed. Do not change isolation or
database options to improve consistency.

## Phase 2 - Object and schema comparison

For `RowCount`, execute only the user-table inventory subset described in Phase 1
and continue directly to Phase 3. Do not ask whether to run the remaining checks.
For `Full`, compare the complete schema below.

Compare source and target counts and detailed inventories by schema and object
name for all supported user objects:

- schemas, tables, views, stored procedures, scalar/table functions, synonyms,
  sequences, and user-defined types;
- columns, data types, lengths, precision, scale, nullability, collation, identity,
  computed-column definitions, and defaults;
- primary keys, unique/check/default constraints, foreign keys and referential
  actions;
- indexes and indexed columns, including uniqueness, filters, and disabled state;
- triggers, temporal-table metadata, and partition metadata;
- database users, roles, role membership, and explicit database permissions when
  they are in migration scope.

Ignore Microsoft-shipped objects. Compare normalized module definitions when the
principal has metadata visibility. If a definition is encrypted or unavailable,
report that object as failed unless it is an approved exception. Account for
platform differences only through the approved exception list, especially SQL
Agent and server-scoped objects that do not exist in Azure SQL Database.

For every mismatch, record the scenario, source object name, target object name,
source value, target value, and a concise reason such as `Missing on target`,
`Unexpected on target`, or `Column precision differs`.

## Phase 3 - Exact row-count comparison

Compare an exact `COUNT_BIG(*)` for every in-scope user table on source and target.
Catalog partition row estimates may be used to plan the run, but never as pass
evidence. Generate table-specific statements only from catalog values returned by
the approved database and quote every identifier with `QUOTENAME`; never
interpolate an unvalidated identifier into a local query file.

Process tables in deterministic schema/name order. Generate one read-only batch per
endpoint pass and return structured rows containing database, schema, table,
`COUNT_BIG`, pass identifier, and UTC query timestamps. Never parse formatted table
output. A timeout, permission error, unsupported object, duplicate/missing output
row, or interrupted query is a `Fail` for that table, not `0` and not `Pass`. Retry
one transient connection failure with the same authenticated session; do not prompt
per table or silently reduce scope.

Use `QUOTENAME` for every catalog-derived identifier and isolate each dynamic
`COUNT_BIG(*)` in `TRY/CATCH` so one table error is recorded and later tables still
run. Do not use `NOLOCK`, `READ UNCOMMITTED`, partition metadata, or approximate
counts as equality evidence. Do not introduce stronger isolation that blocks source
writes. Record that two equal count passes cannot detect same-count row updates.

When the original source is queryable, run the passes in this order:

1. Source pass A.
2. Target pass A.
3. Target pass B.
4. Source pass B.

When it is `RESTORING`, substitute the verified immutable evidence package's two
source passes, or execute source passes A and B against the separately restored
cutoff copy. Validate that the reference names the same database, final file,
completion time, and final LSN as the handoff before comparing any target count.

This brackets the target observations with source observations and detects changes
during the validation window. Use a cutoff reference automatically when the
migration handoff contains either a queryable validation copy restored through the
final backup LSN or table counts captured from a transactionally consistent source
snapshot at that cutoff. Do not ask the user to create such a reference during
post-migration validation.

Classify each mapped table as follows:

| Evidence | Result |
| --- | --- |
| Target A differs from target B | `Fail`: target changed during validation |
| Quiesced or cutoff reference is stable and differs from target | `Fail`: proven mismatch |
| Quiesced or cutoff reference is stable and equals target | `Pass` |
| Writable source, no cutoff reference, source A equals source B and target equals that value | `Pass` observed; database remains `Ready with conditions` |
| Writable source, no cutoff reference, source changed or its stable current count differs from target | `Inconclusive`: possible post-cutoff divergence |
| Any required count is unavailable or malformed | `Fail`: validation did not complete |

Never infer cutoff equality from current writable-source counts. Current source
counts are evidence of observed state only. A row-count match proves quantity, not
row content; state that limitation instead of upgrading it to full data equality.

For each table report:

| Field | Value |
| --- | --- |
| Scenario | `Exact row count` |
| Object | `<schema>.<table>` |
| Source pass A / B | `<COUNT_BIG result>` / `<COUNT_BIG result>` |
| Target pass A / B | `<COUNT_BIG result>` / `<COUNT_BIG result>` |
| Cutoff reference | `<COUNT_BIG result>`, `Not available`, or `Not applicable` |
| Status | `Pass`, `Inconclusive`, `Fail`, or `In progress` |
| Reason | Empty on pass; concise instability, limitation, mismatch, or error otherwise |

A matching row count proves quantity, not content. Continue with Phase 4.

## Phase 4 - Full-profile read-only checks

Skip this phase automatically for `RowCount`. For an explicitly requested `Full`
profile, run these additional read-only checks without asking for individual
approval:

- Compare identity current values, sequence current values, temporal-table row
  counts, and min/max temporal periods where applicable.
- Compare null counts, minimum, maximum, and deterministic aggregates for approved
  critical columns where data types support them.
- For critical tables with a stable primary/unique key, compare deterministic
  key-range chunks using an approved content-hash implementation. Canonicalize
  nulls, binary values, date/time precision, collation-sensitive text, and numeric
  representation identically on both sides. Record the algorithm and chunk ranges.
- Run approved read-only application smoke queries. Writes and transaction tests
  belong to cutover testing and are outside this read-only skill.

Do not use `CHECKSUM_AGG(BINARY_CHECKSUM(*))` as sole proof of equality because
collisions and unsupported types can hide differences. Content checks supplement,
but do not replace, exact row counts and schema comparison.

## Phase 5 - Change detection and report

Use the A/B results already captured in Phases 2 and 3. For `Full`, also compare
the content signatures captured by that profile:

- If this workflow issued any mutating statement, stop and report a safety failure.
- In `Quiesced` mode, if source schema, source row counts, or source content
  signatures changed, fail affected consistency scenarios with reason
  `Source changed during validation`.
- In `Writable source with cutoff` mode, compare the target with a valid cutoff
  reference when one exists. Without one, classify changed or differing current
  source counts as `Inconclusive`, not `Fail`, because current source state is not
  the migration boundary. Return `Ready with conditions` when there are no failures.
  An invalid cutoff manifest/chain or a proven cutoff mismatch is `Fail`.
- If target schema, target row counts, or target content signatures changed, fail
  affected scenarios with reason `Target changed during validation`.
- A metadata timestamp change without a normalized schema difference is still
  reported for review but does not by itself prove a schema change.

This skill guarantees that its own workflow is read-only. It detects covered
external changes during the validation window; it cannot guarantee that unmeasured
content did not change when full content signatures were not approved.

## Result presentation

Keep the complete failure list in the in-memory validation result and approved
evidence report. In chat, display at most 10 failed objects at a time in stable
scenario, database, schema, and object-name order.

When more than 10 failures exist:

- Show `Failures 1-10 of <total>` and the report location.
- Do not open a `Next` prompt. The complete stable result set remains in the report.
- Include `Inconclusive` tables in a separate summary and report section; do not
  present them as migration failures.

## Result format

Produce a sanitized Markdown report and, when requested, a machine-readable JSON
report. Never include credentials or secret-bearing connection properties.

```markdown
# Post-migration data validation report

- Source: <sanitized server/database>
- Target: <target type and sanitized server/database>
- Validation profile: <RowCount | Full>
- Validation window: <UTC start> to <UTC finish>
- Overall status: <Pass | Ready with conditions | Fail | In progress>
- Comparison mode: <Quiesced | Writable source with cutoff>
- Migration cutoff: <final backup UTC completion time, LSN, and file | Not applicable>
- Source unchanged during validation: <Yes | No | Not fully proven>
- Target unchanged during validation: <Yes | No | Not fully proven>

| Validation scenario | Status | Passed | Inconclusive | Failed | In progress | Notes |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| Object inventory | <status> | <n> | <n> | <n> | <n> | <summary> |
| Schema definitions | <status or Not run> | <n> | <n> | <n> | <n> | <summary> |
| Exact row counts | <status> | <n> | <n> | <n> | <n> | <summary> |
| Critical data content | <status or Not run> | <n> | <n> | <n> | <n> | <summary> |
| Change detection | <status> | <n> | <n> | <n> | <n> | <summary> |

## Failed objects

| # | Scenario | Object | Status | Reason |
| ---: | --- | --- | --- | --- |
| 1 | <scenario> | <database.schema.object> | Fail | <reason> |
```

For `RowCount`, state prominently that exact table counts were compared but row
content and complete schema equality were not validated. Include all A/B counts
and query timestamps in the machine-readable or evidence report even when chat
shows only the summary.

Include approved exceptions, checks not fully proven, query timestamps, isolation,
quiescence or cutoff evidence, expected post-cutoff divergence, content-hash
algorithms and ranges, and the report/evidence
location. A failure row must always identify the object when one exists and explain
the reason. For database-level failures, use the database name as the object.
