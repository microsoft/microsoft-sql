---
name: deadlock-analysis
description: "Use when the user asks about deadlocks or deadlock history on SQL Server or Managed Instance, or to explain a supplied deadlock graph or XML. For Azure SQL Database, use `deadlock-analysis-azuresql`."
user-invocable: true
---

# Deadlock Analysis — SQL Server

Use this skill when the user asks about deadlocks, deadlock reports, or deadlock history on **SQL Server** or **Managed Instance**.

> **Platform Guard**: This skill targets Engine Edition 1–4 or 8. The `system_health` XE session with `fn_xe_file_target_read_file` is not available on Azure SQL DB.

## Scope

- Live retrieval reads `system_health` deadlock reports and works on SQL Server and Managed Instance only.
- Also explains deadlock XML or a deadlock graph that the user supplies: victim, participating processes and statements, contested resources (KEY, PAGE, OBJECT, RID locks), and lock modes.
- For deadlocks on Azure SQL Database, use the `deadlock-analysis-azuresql` skill.

## Required tools

- A read-only SQL query tool connected to the target server and database. Prefer, in order: the SQL
  Tools MCP server that ships with the `microsoft-sql-admin` plugin (`mssql_list_database_connections`,
  `mssql_connect_database`, then `mssql_execute_query`); any other SQL tool the agent host provides for
  running T-SQL and reading result sets;
  [`sqlcmd`](https://learn.microsoft.com/sql/tools/sqlcmd/sqlcmd-utility) from a terminal. If the SQL
  Tools MCP server is not connected or lists no connections, follow the `sql-tools-mcp-setup` skill,
  which asks before installing or configuring anything. If no SQL tool can be made available, give the
  user the T-SQL to run and ask for the results.
- Least privilege: connect that tool with a diagnostic login that cannot write, for example one that
  holds only `VIEW SERVER PERFORMANCE STATE` (`VIEW SERVER STATE` before SQL Server 2022) or, on Azure
  SQL Database, `VIEW DATABASE PERFORMANCE STATE` or `##MS_ServerStateReader##`, plus any other read
  permission these queries need. A tool is only as read-only as the login it connects with.

## SQL Queries

### Get Deadlock Reports (Server-wide)
```sql
SELECT
    event_data.value('(event/@timestamp)[1]', 'datetime2') AS [Date],
    event_data.query('.') AS [Event_Data]
FROM (
    SELECT CAST(event_data AS XML) AS event_data
    FROM sys.fn_xe_file_target_read_file('system_health*.xel', NULL, NULL, NULL)
    WHERE object_name = 'xml_deadlock_report'
) AS events
ORDER BY [Date] DESC;
```

### Get Deadlock Reports (Current Database Only)
```sql
DECLARE @dbid INT = DB_ID();
SELECT
    event_data.value('(event/@timestamp)[1]', 'datetime2') AS [Date],
    event_data.query('.') AS [Event_Data]
FROM (
    SELECT CAST(event_data AS XML) AS event_data
    FROM sys.fn_xe_file_target_read_file('system_health*.xel', NULL, NULL, NULL)
    WHERE object_name = 'xml_deadlock_report'
) AS events
WHERE event_data.exist('/event/data/value/deadlock/process-list/process[@currentdb = sql:variable("@dbid")]') = 1
ORDER BY [Date] DESC;
```

## Behavioral Guidance

- Deadlock reports can be very long and difficult to read.
- Provide a **list** of the deadlock reports found and **summarize each** in 30 words or less.
- Conclude by offering to provide more details on any specific deadlock report.
- Unless the user specifies, default to the **current database** scope.
