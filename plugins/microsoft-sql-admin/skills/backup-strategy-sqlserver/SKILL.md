---
name: backup-strategy-sqlserver
description: "Use when the user asks to review or design a SQL Server or Managed Instance backup strategy, or whether the recovery model and backup schedule meet an RPO. For Azure SQL Database, use `backup-history-azuresql`."
user-invocable: true
---

# Backup Strategy Analysis — SQL Server

Use this skill when the user asks about database backup strategy, backup jobs, maintenance plans, or backup recommendations on **SQL Server** or **Managed Instance**.

> **Platform Guard**: This skill targets Engine Edition 1–4 or 8. For Azure SQL DB (Engine Edition 5, 11), use `backup-history-azuresql` instead.

## Scope

- Reviews or designs the backup strategy: recovery model, `msdb` backup history, backup Agent jobs, maintenance plans, and the RPO the current strategy achieves.
- Also checks a recovery model and full, differential and log backup schedule that the user supplies against a target RPO (for example, log backups every 90 minutes against a 60-minute RPO).

## Required tools

- A SQL query tool connected to the target server and database. Prefer, in order: the SQL Tools MCP
  server that ships with the `microsoft-sql-admin` plugin (`mssql_list_database_connections`,
  `mssql_connect_database`, then `mssql_execute_query`); any other SQL tool the agent host provides
  for running T-SQL and reading result sets;
  [`sqlcmd`](https://learn.microsoft.com/sql/tools/sqlcmd/sqlcmd-utility) from a terminal. If the
  SQL Tools MCP server is not connected or lists no connections, follow the `sql-tools-mcp-setup`
  skill, which asks before installing or configuring anything. If no SQL tool can be made available,
  give the user the T-SQL to run and ask for the results.

## Data Collection Steps

1. **Server and database name, current date** — include the current date in the report header
2. **Default backup directory** — run `SELECT SERVERPROPERTY('InstanceDefaultBackupPath') AS DefaultBackupDirectory;` (SQL Server 2019+). If it returns NULL (older versions, or Managed Instance, which backs up to URL), ask the user for the backup directory or report it as unknown
3. **Available backups** — generate query against `msdb.dbo.backupset`
4. **Backup maintenance plans** — execute `GetBackupMaintenancePlansForCurrentDatabase`
5. **Backup agent jobs** — execute `GetExistingBackupAgentJobsForCurrentDb`
6. **Recovery model** — execute `GetDatabaseRecoveryModel`

## SQL Queries

### GetExistingBackupAgentJobsForCurrentDb
```sql
SELECT
    j.job_id,
    j.name AS JobName,
    js.step_id,
    js.step_name,
    js.command
FROM msdb.dbo.sysjobs AS j
INNER JOIN msdb.dbo.sysjobsteps AS js ON j.job_id = js.job_id
WHERE (js.command LIKE '%BACKUP DATABASE%' AND js.command LIKE '%' + DB_NAME() + '%')
   OR (js.command LIKE '%BACKUP LOG%' AND js.command LIKE '%' + DB_NAME() + '%')
   OPTION (MAXDOP 1);
```

### GetDatabaseRecoveryModel
```sql
SELECT recovery_model_desc AS RecoveryModel
FROM sys.databases
WHERE name = db_name()
OPTION (MAXDOP 1);
```

### GetBackupMaintenancePlansForCurrentDatabase
```sql
SELECT name, package_data
FROM (
    SELECT
        p.name,
        p.id,
        CAST(CAST(p.packagedata AS VARBINARY(MAX)) AS VARCHAR(MAX)) AS package_data
    FROM msdb.dbo.sysssispackages AS p
    JOIN msdb.dbo.sysssispackagefolders AS pf ON p.folderid = pf.folderid
    WHERE foldername = 'Maintenance Plans'
) AS tab
WHERE package_data LIKE '%Back Up Database Task%' AND package_data LIKE '%' + DB_NAME() + '%'
OPTION (MAXDOP 1);
```

## Report Template

```
## Database Backup Strategy
Database: {{ current database name}}
Recovery Model: {{ current database's recovery model}}
Default Backup Directory: {{ server's current backup directory}}
Date: {{current date in YYYY-MM-DD format}}

### Available Backups
{{Include list of all available backups and their types (use words, not special codes)}}

### Backup Maintenance Plans
{{Include list of all backup maintenance plans related to backups for the current database}}

### Backup Agent Jobs
{{Include list of all backup agent jobs related to backups for the current database}}

### Backup Strategy Summary
{{Include: summary of the backup strategy for the current database and if possible the RPO the current strategy provides.}}

### Recommendations
{{Include: any recommendations for improving the backup strategy for the current database. Show any BACKUP or job-creation T-SQL as a script to review, with its impact; do not run it without the user's explicit confirmation.}}
```

## Behavioral Guidance

### Confirmation Gate for State-Changing Commands

- The data collection queries above are read-only.
- `BACKUP DATABASE`, `BACKUP LOG`, `ALTER DATABASE ... SET RECOVERY ...`, and creating or changing
  SQL Agent backup jobs or schedules (`sp_add_job`, `sp_add_jobstep`, `sp_add_jobschedule`,
  `sp_update_job`, and similar), or maintenance plans, change server state. Present them as
  recommendations or scripts only.
- Never run any of them without the user's explicit confirmation for that specific command. A
  request to analyze or design a backup strategy is not that confirmation.
- Before asking, explain the impact and the rollback: a backup consumes I/O, CPU, and destination
  space, and an ad hoc full or log backup changes the differential base or the log chain unless
  `COPY_ONLY` is used; a new job runs on its schedule until it is disabled or deleted
  (`sp_update_job @enabled = 0` or `sp_delete_job`); a recovery model change affects log growth and
  point-in-time restore until it is switched back and a new full backup is taken.

### Creating Database Backups

If the user asks to **create** a database backup (the confirmation gate above applies):

1. **Gather first:**
   - Server's default backup location
   - Database's current recovery model
   - Date and time of last full backup
2. **Defaults:**
   - Use the current database name unless told otherwise
   - Use the server's default backup location unless told otherwise
3. **Present the `BACKUP` command** with its target path, type, and options (for example
   `COPY_ONLY` for an ad hoc backup that must not change the backup chain), explain the impact, and
   run it only after the user explicitly confirms that command.

### Determining Potential Data Loss

If the user asks about **potential data loss** from a restore:

1. Verify server version — if Azure SQL DB, provide PITR guidance and stop.
2. Gather latest backup information (LSN and date/time). Do NOT use `physical_device_name`.
3. Query active transaction log LSNs from `fn_dblog`. Convert segmented hex LSNs to decimal for comparison.
4. Get current recovery model.
5. Estimate data loss — records in `fn_dblog` with LSNs higher than latest backup LSN represent potential data loss.

**Response requirements:**
- Caution that the estimate is not a guarantee
- Organize into sections: Latest Backup Info, Active Transaction Log, Potential Data Loss Estimate
- If no backups exist, state clearly that no restore is possible
