# Backup and restore T-SQL on Azure SQL Database: every statement and its error

## Contents

- [What this file is](#what-this-file-is)
- [Engine identity](#engine-identity)
- [Statements refused outright](#statements-refused-outright)
- [The database rename swap, measured](#the-database-rename-swap-measured)
- [Backup system views that exist and return nothing locally](#backup-system-views-that-exist-and-return-nothing-locally)
- [What this file does NOT cover](#what-this-file-does-not-cover)

## What this file is

Every statement below was run against a live container engine on 2026-08-29 and the
output is copied verbatim, trimmed only of `sqlcmd` padding whitespace. Two rows were
re-measured afterwards and corrected, both toward a refusal: `sp_get_database_backup_policy`
on 2026-09-02 and `SET RECOVERY` on 2026-09-03; each says so in place. This is the evidence
behind the correction in SKILL.md.

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
| `BACKUP DATABASE db TO URL = 'https://...'` | Same `Msg 40510`, same text. The destination does not change the outcome; the statement is rejected before it looks at where the file would go. |
| `BACKUP LOG db TO DISK = '...'` | `Msg 40510`: "Statement 'BACKUP LOG' is not supported in this version of SQL Server." |
| `RESTORE DATABASE db FROM DISK = '...' WITH REPLACE` | `Msg 40510`: "Statement 'RESTORE DATABASE' is not supported in this version of SQL Server." |
| `RESTORE HEADERONLY FROM DISK = '...'` | `Msg 40510`: "Statement 'RESTORE VOLUME' is not supported in this version of SQL Server." Note the message names `RESTORE VOLUME`, not `RESTORE HEADERONLY`; the parser collapses the `RESTORE ... ONLY` family into one internal name before it reports the rejection. Match on the number, never the text. |
| `RESTORE FILELISTONLY FROM DISK = '...'` | Same `Msg 40510`, "RESTORE VOLUME" text. |
| `RESTORE VERIFYONLY FROM DISK = '...'` | Same `Msg 40510`, "RESTORE VOLUME" text. |
| `EXEC sys.sp_get_database_backup_policy 'db'` | `Msg 2812`: "Could not find stored procedure 'sys.sp_get_database_backup_policy'." Re-measured 2026-09-02 on Azure SQL Database (EngineEdition 5, `SQL Azure`, 12.0.2000.8, S0) and on the container: both answer 2812, and `sys.all_objects` holds nothing matching `%backup_policy%`. This row previously said `Msg 15817`, a real message ("The stored procedure is not available in this version of SQL Server") but the wrong one: 15817 is what a version-gated procedure that EXISTS returns, and would have told a reader this one was merely gated off. |
| `ALTER DATABASE db SET RECOVERY FULL` or `SIMPLE` | `Msg 40517, Level 16, State 1`: "Keyword or statement option 'RECOVERY' is not supported in this version of SQL Server." Not `40510`: that refuses a whole statement, while `40517` refuses one option of a statement that is otherwise supported, and `ALTER DATABASE ... MODIFY NAME` below still works. Learn documents `40517` with this exact text, and lists recovery models among the syntax Azure SQL Database does not support. Until 2026-09-03 this row said the statement RAN and moved `recovery_model_desc`, making it the one accepted statement in the family; re-measured, it is refused like the rest. |
| `CREATE DATABASE copy_name AS COPY OF db` | `Msg 102, Level 15`: "Incorrect syntax near 'COPY'." A **parse** error, not a `40510` refusal, so the container's parser does not recognise the clause at all. Azure SQL Database does accept `CREATE DATABASE ... AS COPY OF` for an online database copy, a different operation from restore. Not cross-checked against a live logical server; read Microsoft Learn before writing it. |

## The database rename swap, measured

```sql
ALTER DATABASE dq_restore2 MODIFY NAME = dq_restore_swapped;
-- The database name 'dq_restore_swapped' has been set.

SELECT name FROM sys.databases WHERE name LIKE 'dq_restore%';
-- dq_restore_swapped
```

`ALTER DATABASE ... MODIFY NAME` is ordinary T-SQL, works on this engine, and is the
mechanism for putting a restored database's name back where the application expects it.
It renames in place; it does not merge or delete anything, so the original database
still has to be renamed out of the way or dropped separately.

## Backup system views that exist and return nothing locally

`sys.dm_database_backups`, `sys.dm_database_backup_lineage` and
`sys.fn_db_backup_file_snapshots(NULL)` all resolved as real objects and returned zero
rows, rather than an invalid-object error. The container does not run the Azure backup
service, so there is nothing for them to report.The singular name
`sys.fn_db_backup_file_snapshot` does not exist: `Msg 208`, invalid object name. The real
object is plural.

## What this file does NOT cover

Point-in-time restore, geo-restore, restore from long-term retention, and the
`az sql db restore` / `Restore-AzSqlDatabase` / REST surface all require a real logical
server and were not exercised here. Nothing in this file is evidence about how long a
restore takes, what a restored database is named by default, or whether firewall rules
or the Microsoft Entra administrator carry over. SKILL.md links Microsoft Learn at each
of those points instead of guessing.
