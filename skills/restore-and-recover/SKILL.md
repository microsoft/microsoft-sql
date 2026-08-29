---
name: restore-and-recover
description: >-
  Recovers an Azure SQL Database after data loss, an accidental drop, or a bad deployment, using
  point-in-time restore, geo-restore, and long-term retention. Use when someone asks to
  "restore my Azure SQL database", "undo a dropped table or database", "roll back to before this
  migration ran", "recover from a region outage", or asks for RESTORE DATABASE or BACKUP DATABASE
  syntax. There is no backup or restore T-SQL on Azure SQL Database: BACKUP DATABASE, RESTORE
  DATABASE, and every RESTORE ... ONLY variant are refused outright, and restoring is a control
  plane operation, never a query. Every restore creates a brand new database next to the one being
  recovered rather than overwriting it in place, and this covers choosing the right restore type
  and the rename or connection swap back that nothing does automatically. Not a schema rollback,
  which is schema-migrations-safely, and not a logical export or import, which is
  sqlpackage-import-export. Creating the database in the first place is provision-azure-sql-db.
---

# Recover an Azure SQL Database

This is about getting data back after it is gone: a dropped table, a bad deployment, a bad
backfill, or a region outage. It is not schema rollback and it is not a bacpac. Both of those
inherit an assumption from SQL Server that does not survive contact with this service.

Measured on 2026-08-29 against a live engine reporting `SERVERPROPERTY('EngineEdition')` 5,
Edition `SQL Azure`, `ProductVersion` 12.0.2000.8: every T-SQL statement in this file was run and
its exact error captured, in [references/verified-behaviour.md](references/verified-behaviour.md).
**Point-in-time restore, geo-restore, long-term retention restore, and the restore REST, CLI and
PowerShell surface all require a real Azure SQL Database logical server and were not run here.**
Every section below that depends on one says so and links Microsoft Learn instead of stating a
number this skill cannot stand behind.

## The correction

Asked to recover an Azure SQL Database, an agent trained on SQL Server reaches for
`RESTORE DATABASE ... WITH REPLACE`, `BACKUP DATABASE`, `RESTORE HEADERONLY` or
`ALTER DATABASE ... SET RECOVERY`. None of that T-SQL surface exists here. Every one of those
statements is refused outright with `Msg 40510`, "Statement is not supported in this version of
SQL Server", measured on the engine above. Restoring is triggered from the CLI, PowerShell, the
REST API or the portal, never from a query window. The second wrong belief compounds the first:
every restore, point-in-time, geo-restore, or from long-term retention, creates a brand new
database next to the one being recovered rather than overwriting it in place, under whatever name
was given at restore time. Putting that new database back where the application actually connects
is a step the developer performs themselves, with a database rename or a connection string change,
and nothing in the restore operation does it automatically or warns anyone if it is skipped.

## What Azure SQL Database actually gives you

- **Automated backups.** Taken by the service on every database, not requested. Point-in-time
  restore works from these, inside a retention window you configure, from 1 to 35 days.
- **Geo-restore.** Restores from the most recent geo-redundant backup to any logical server in
  another region. Only available if geo-redundant backup storage is enabled on the source, and the
  recovery point can lag the failure by up to about an hour; read the Learn page in References
  before treating it as a failover mechanism.
- **Long-term retention.** An optional policy that keeps weekly, monthly, or yearly backups for up
  to 10 years, independent of the 1 to 35 day window above. A database with LTR configured can be
  restored from an archived point even after the source database and its short-term backups are
  long gone.

The exact CLI flag names, PowerShell cmdlet parameters, and retention limits change between
releases, which is why they are not copied into this file: read
[Recover using automated database backups](https://learn.microsoft.com/azure/azure-sql/database/recovery-using-backups)
and [Long-term retention](https://learn.microsoft.com/azure/azure-sql/database/long-term-retention-overview)
before writing the actual restore command, and treat any specific flag name in an older
conversation, including this one, as something to re-check rather than trust.

## 1. There is no restore T-SQL, measured

Every statement below was run against a real database and returned an error, not a permissions
message and not a hang:

| Written from SQL Server habit | What happens here |
|---|---|
| `RESTORE DATABASE db FROM DISK = '...' WITH REPLACE` | `Msg 40510`, not supported |
| `BACKUP DATABASE db TO DISK = '...'` or `TO URL = '...'` | `Msg 40510`, not supported |
| `BACKUP LOG db TO DISK = '...'` | `Msg 40510`, not supported |
| `RESTORE HEADERONLY` / `FILELISTONLY` / `VERIFYONLY` | `Msg 40510`, not supported |
| `EXEC sys.sp_get_database_backup_policy` | `Msg 15817`, procedure not available |
| `ALTER DATABASE db SET RECOVERY FULL` / `SIMPLE` | Runs. Read the caveat in
  [references/verified-behaviour.md](references/verified-behaviour.md) before relying on it doing
  anything to the backups the service actually takes. |

Full detail, exact message text, and the one statement that fails as a syntax error rather than a
refusal is in the reference file. Do not write any statement from the left column expecting it to
work; every one of them is a signal the agent is solving the wrong problem.

## 2. Pick the restore type before touching the CLI

The three sources above answer different questions, and the wrong one is a wasted restore against
a service that bills for every database it creates:

1. **"I need it back from before something happened in the last few weeks"**: point-in-time
   restore, inside the retention window.
2. **"The region is unavailable and I need the database somewhere else, now"**: geo-restore, and
   only if geo-redundant backup was on before the outage. It cannot be turned on retroactively.
3. **"I need something older than the retention window, or I need to prove what a database looked
   like a year ago"**: long-term retention restore, and only if an LTR policy was configured before
   that point existed.

State which of the three applies before writing a command, and say so to whoever asked: it changes
what is possible, not just what flag to pass.

## 3. What comes back, and what it does not inherit

The restored database is a new, separate database on the target server, under the name given at
restore time. Treat these as open questions to verify, not as given:

- **Firewall rules and the Microsoft Entra administrator** are server level settings. A
  point-in-time restore onto the same logical server keeps them; a geo-restore onto a different
  server does not, because the target server has its own.
- **Contained database users** live inside the database and travel with it. **Server level SQL
  logins** do not: a geo-restore to a different logical server can leave an application
  authenticating with a login that has no matching identity there, and the failure surfaces as a
  connection error the application reports, not as anything the restore itself flagged. Neither
  half of this was verified on the container, which has no second logical server to test against;
  confirm current behaviour on Microsoft Learn before promising a customer either outcome.
- **The database is not automatically wired into anything.** Diagnostic settings, alerts, and
  scaling configuration are not guaranteed to carry over; check them explicitly rather than assume.

## 4. The swap nobody automates, measured

The restore leaves two databases: the one that needed recovering, and the new one with the data.
Nothing performs the swap. Two ways to finish it, and the choice matters under load:

**Rename in place**, measured on the engine above:

```sql
ALTER DATABASE app_db MODIFY NAME = app_db_broken;
ALTER DATABASE app_db_restored MODIFY NAME = app_db;
```

`ALTER DATABASE ... MODIFY NAME` is ordinary T-SQL and works here; it renamed a live database with
a one line confirmation and no error. It does not merge data and does not touch the database it
renames away from; that one still exists under its new name until it is dropped on purpose.
Existing connections and connection pools against the old name will fail or reconnect depending on
the driver, so this is a cutover with a brief gap, not a hot swap.

**Repoint the connection string instead**, if the application's configuration can be changed
without a deploy. No rename, no gap in the old database's availability, but every place the
database name is hardcoded, migration tooling included, has to be found and updated, and a stale
copy of the old name in a script or a runbook is a return trip to this exact problem.

Neither option is "the" answer; state which one applies to the situation being solved, and confirm
the choice with whoever owns the application before running it.

## Validation rules

- No `RESTORE` or `BACKUP` T-SQL statement appears anywhere in the plan. The restore command is a
  CLI, PowerShell, REST, or portal action, named as such.
- The restore type, point-in-time, geo-restore, or long-term retention, is stated explicitly and
  matches what the situation actually needs, not the first one that comes to mind.
- The plan names the new database as a new database, never as "restoring db_name in place".
- Firewall rules, the Microsoft Entra administrator, and any server level login are called out as
  things to verify on the restored database, not assumed to have carried over.
- The rename or connection string swap back to the name the application uses is an explicit step in
  the plan, not left implied.
- Any CLI flag, cmdlet parameter, retention limit, or RPO number came from reading Microsoft Learn
  during this task, not from memory.

## Do not

- Do not write `RESTORE DATABASE`, `BACKUP DATABASE`, or any `RESTORE ... ONLY` variant as the
  recovery step. All five are refused outright on this service, measured.
- Do not tell someone a restore updates their existing database. It always creates a new one, under
  a name chosen at restore time.
- Do not promise that firewall rules, the Entra administrator, or SQL logins survive a geo-restore
  to a different logical server without checking; that half of the claim was not verified here and
  is exactly the kind of thing that goes wrong silently.
- Do not treat the restored database as done once it exists. The rename or connection string swap
  is part of the recovery, not a follow-up task.
- Do not quote a specific retention window, CLI flag, or RPO number from memory. State the current
  value only after reading it from the Learn pages below.
- Do not use this skill for a schema rollback or a logical export and import; those are
  schema-migrations-safely and sqlpackage-import-export.

## References

- [references/verified-behaviour.md](references/verified-behaviour.md): every statement run
  against the engine, the exact message for each, and what was deliberately not tested. Read it
  before restating any claim in this file as verified.
- [Recover using automated database backups](https://learn.microsoft.com/azure/azure-sql/database/recovery-using-backups):
  point-in-time restore and geo-restore, the current retention limits, and the CLI, PowerShell and
  REST syntax. Read it before writing the actual restore command.
- [Long-term retention](https://learn.microsoft.com/azure/azure-sql/database/long-term-retention-overview):
  how an LTR policy is configured and what a restore from it looks like. Read it before promising a
  restore point older than the short-term retention window.
- [Business continuity overview](https://learn.microsoft.com/azure/azure-sql/database/business-continuity-high-availability-disaster-recover-hadr-overview):
  where restore sits next to failover groups and active geo-replication, which solve a different
  problem, near zero downtime rather than recovery from bad data.
- `provision-azure-sql-db`: creating a database and its firewall rule in the first place.
- `provision-hyperscale`: Hyperscale specific restore mechanics and read replicas, which behave
  differently from the general case in this file.
- `schema-migrations-safely`: rolling back a bad schema change without touching data at all.
- `sqlpackage-import-export`: bacpac export and import, a logical copy, not a point-in-time
  recovery mechanism.
