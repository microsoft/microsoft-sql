# Verified behaviour: backup and restore T-SQL on Azure SQL Database

## Contents

- [What this file is](#what-this-file-is)
- [Engine identity](#engine-identity)
- [Statements refused outright](#statements-refused-outright)
- [Statements that parse but do nothing useful](#statements-that-parse-but-do-nothing-useful)
- [The database rename swap, measured](#the-database-rename-swap-measured)
- [System views that exist and return nothing locally](#system-views-that-exist-and-return-nothing-locally)
- [What this file does NOT cover](#what-this-file-does-not-cover)

## What this file is

Every statement below was run against a live container engine on 2026-08-29 and the
output is copied verbatim, trimmed only of `sqlcmd` padding whitespace. This is the
evidence behind the correction in SKILL.md. It is not a substitute for reading
Microsoft Learn on the restore types themselves, which this skill deliberately does
not restate.

## Engine identity

```sql
SELECT SERVERPROPERTY('EngineEdition'), SERVERPROPERTY('Edition'), SERVERPROPERTY('ProductVersion');
-- 5   SQL Azure   12.0.2000.8
```

## Statements refused outright

Each ran against a real database with a table and rows in it, not an empty one.

| Statement | Result |
|---|---|
| `BACKUP DATABASE db TO DISK = '...'` | `Msg 40510, Level 16, State 1`: "Statement 'BACKUP DATABASE' is not supported in this version of SQL Server." |
| `BACKUP DATABASE db TO URL = 'https://...'` | Same `Msg 40510`, same text. The destination does not change the outcome; the statement itself is rejected before it looks at where the file would go. |
| `BACKUP LOG db TO DISK = '...'` | `Msg 40510`: "Statement 'BACKUP LOG' is not supported in this version of SQL Server." |
| `RESTORE DATABASE db FROM DISK = '...' WITH REPLACE` | `Msg 40510`: "Statement 'RESTORE DATABASE' is not supported in this version of SQL Server." |
| `RESTORE HEADERONLY FROM DISK = '...'` | `Msg 40510`: "Statement 'RESTORE VOLUME' is not supported in this version of SQL Server." Note the message names `RESTORE VOLUME`, not `RESTORE HEADERONLY`; the parser appears to collapse the `RESTORE ... ONLY` family into one internal name before it reports the rejection. |
| `RESTORE FILELISTONLY FROM DISK = '...'` | Same `Msg 40510`, "RESTORE VOLUME" text. |
| `RESTORE VERIFYONLY FROM DISK = '...'` | Same `Msg 40510`, "RESTORE VOLUME" text. |
| `EXEC sys.sp_get_database_backup_policy 'db'` | `Msg 2812`: "Could not find stored procedure 'sys.sp_get_database_backup_policy'." The procedure does not exist on the service at all. Re-measured 2026-09-02 on Azure SQL Database (EngineEdition 5, `SQL Azure`, 12.0.2000.8, S0) and on the container: both answer 2812, and `sys.all_objects` holds nothing matching `%backup_policy%`. This row previously said `Msg 15817`, which is a real message ("The stored procedure is not available in this version of SQL Server") but the wrong one: 15817 is what a procedure that EXISTS and is version-gated returns. |
| `CREATE DATABASE copy_name AS COPY OF db` | `Msg 102, Level 15`: "Incorrect syntax near 'COPY'." This is a **parse** error, not a `40510` refusal, meaning the container's parser does not recognise the clause at all. Real Azure SQL Database does accept `CREATE DATABASE ... AS COPY OF` for an online database copy, a different operation from restore. This container behaviour was not cross-checked against a live Azure SQL Database and should not be relied on either way; if a database copy is what is actually needed, read Microsoft Learn before writing the statement. |

## Statements that parse but do nothing useful

`ALTER DATABASE db SET RECOVERY FULL` and `ALTER DATABASE db SET RECOVERY SIMPLE` both
ran with no error, and `sys.databases.recovery_model_desc` changed to match each time.
This is the one exception to the pattern above: it is accepted rather than refused.
What was **not** checked is whether changing it has any effect on the automated
backups Azure SQL Database actually takes, or whether the setting persists or reverts.
Treat `recovery_model_desc` as readable, not as a lever, until that is confirmed
against Microsoft Learn.

## The database rename swap, measured

```sql
ALTER DATABASE dq_restore2 MODIFY NAME = dq_restore_swapped;
-- The database name 'dq_restore_swapped' has been set.

SELECT name FROM sys.databases WHERE name LIKE 'dq_restore%';
-- dq_restore_swapped
```

`ALTER DATABASE ... MODIFY NAME` is ordinary T-SQL, works on this engine, and is the
mechanism for putting a restored database's name back where the application expects
it. It renames in place; it does not merge or delete anything, so the original
(broken or stale) database still has to be renamed out of the way or dropped
separately.

## System views that exist and return nothing locally

`sys.dm_database_backups`, `sys.dm_database_backup_lineage` and
`sys.fn_db_backup_file_snapshots(NULL)` all resolved as real objects and returned
zero rows, rather than an invalid-object error. The container does not run the Azure
backup service, so there is nothing for them to report; a healthy Azure SQL Database
with automated backups turned on is expected to populate them. `sys.backup_devices`,
`sys.backup_metadata_store` and `sys.dm_io_backup_tapes` also exist by name
(`sys.all_objects`) and were not queried further. The singular name
`sys.fn_db_backup_file_snapshot` does not exist; `Msg 208`, invalid object name. The
real object is plural, `sys.fn_db_backup_file_snapshots`.

## What this file does NOT cover

Point-in-time restore, geo-restore, restore from long-term retention, and the
`az sql db restore` / `Restore-AzSqlDatabase` / REST surface all require a real Azure
SQL Database logical server and were not exercised here. Nothing in this file is
evidence about how long a restore takes, what a restored database is named by
default, whether firewall rules or the Microsoft Entra admin carry over, or what a
geo-restore looks like across logical servers. SKILL.md says so at each point that
matters and links to Microsoft Learn instead of guessing.
