---
name: backup-history-azuresql
description: "Use when the user asks for backup history, the latest backups or backup retention on Azure SQL Database or Fabric SQL Database. For SQL Server or Managed Instance, use `backup-strategy-sqlserver`."
user-invocable: true
---

# Backup History — Azure SQL Database / Fabric SQL Database

Use this skill when the user asks about backups, backup history, retention, or data recovery on **Azure SQL Database** or **Fabric SQL Database**.

> **Platform Guard**: This skill targets Engine Edition 5 (Azure SQL DB) or 11 (Fabric SQL DB). For SQL Server (Engine Edition 1–4, 8), use `backup-strategy-sqlserver` instead.

## Required tools

- A read-only SQL query tool connected to the target database. Prefer, in order: the SQL Tools MCP
  server that ships with the `microsoft-sql-admin` plugin (`mssql_list_database_connections`,
  `mssql_connect_database`, then `mssql_execute_query`); any other SQL tool the agent host provides
  for running T-SQL and reading result sets;
  [`sqlcmd`](https://learn.microsoft.com/sql/tools/sqlcmd/sqlcmd-utility) from a terminal. If the
  SQL Tools MCP server is not connected or lists no connections, follow the `sql-tools-mcp-setup`
  skill, which asks before installing or configuring anything. If no SQL tool can be made available,
  give the user the T-SQL to run and ask for the results.
- Least privilege: connect that tool with a diagnostic login that cannot write, for example one that
  holds only `VIEW SERVER PERFORMANCE STATE` (`VIEW SERVER STATE` before SQL Server 2022) or, on Azure
  SQL Database, `VIEW DATABASE PERFORMANCE STATE` or `##MS_ServerStateReader##`, plus any other read
  permission these queries need. A tool is only as read-only as the login it connects with.

## SQL Queries

### GetLatestBackupHistory
```sql
SELECT TOP 100
  backup_file_id,
  backup_start_date,
  backup_finish_date,
  CASE
    WHEN backup_type = 'D' THEN 'Full database backup'
    WHEN backup_type = 'I' THEN 'Incremental or differential backup'
    WHEN backup_type = 'L' THEN 'Log backup'
  END AS backup_type,
  CASE
    WHEN in_retention = 0 THEN 'Out of retention'
    WHEN in_retention = 1 THEN 'In retention'
  END AS retention_status
FROM sys.dm_database_backups
ORDER BY backup_finish_date DESC
OPTION (MAXDOP 1);
```

The `$BackupType` parameter can be adjusted based on what the user wants:
- All types: `'D','I','L'`
- Full only: `'D'`
- Differential only: `'I'`
- Log only: `'L'`

## Platform-Specific Guidance

### Azure SQL Database
- The table `msdb.dbo.backupset` is **not available** in Azure SQL Database. Use `sys.dm_database_backups` instead.
- Retention policy is based on the database's service tier. Guide the user to leverage the Azure Portal for retention configuration.
- For backup/restore and disaster recovery questions, focus on Point-In-Time Restore (PITR) and geo-replication capabilities.

### Fabric SQL Database
- Default retention period is **7 days**. The retention period cannot be changed.
- Only short-term retention backups are supported. No long-term retention backup support.
- Fabric SQL Database does not support the `BACKUP` command. Use **SqlPackage** to export a `.bacpac` file instead.

## Behavioral Guidance

- When asked about data loss or system crash recovery, focus on the product's HA and GeoDR functionality.
- When asked general questions about backup, mention the 3 types: full, differential, and transaction log.
- To get backup information, use `GetLatestBackupHistory` — not `msdb.dbo.backupset`.
