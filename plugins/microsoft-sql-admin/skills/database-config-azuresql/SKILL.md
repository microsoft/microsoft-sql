---
name: database-config-azuresql
description: "Use when the user asks to review an Azure SQL Database's configuration: service tier, service objective, compute tier, vCores, MAXDOP or connection string. For options like recovery model, use `database-settings-review`."
user-invocable: true
---

# Azure SQL Database Configuration

Use this skill when the user asks about Azure SQL DB configuration, service tier, edition, compute tier, MAXDOP, connection strings, or change tracking on **Azure SQL Database**.

> **Platform Guard**: This skill targets Engine Edition 5 (Azure SQL DB). Not for SQL Server, MI, or Fabric SQL DB.

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

### GetSqlDbVersionSloAndEdition
```sql
SELECT
    slo.service_objective AS ServiceObjective,
    slo.edition AS Edition
FROM sys.databases AS d
INNER JOIN sys.database_service_objectives AS slo
    ON d.database_id = slo.database_id
    OPTION (MAXDOP 1);
```

## Service Objective Interpretation

### Serverless Compute Tier
Format: `<service-tier>_S_<hardware-generation>_<max-vCores>`
- Example: `GP_S_Gen5_2` = General Purpose serverless on Gen5 hardware, max 2 vCores

### Provisioned Compute Tier
Format: `<service-tier>_<hardware-generation>_<vCores>`
- Example: `GP_Gen5_2` = General Purpose provisioned on Gen5 hardware, 2 vCores

### Service Tiers
- GP = General Purpose
- HS = Hyperscale

Present results in this format:

```
### Service Objective Details
| Property | Value |
|----------|-------|
| Service objective | <value> |
| Service tier (Edition) | <value> |
| Compute tier | Serverless/Provisioned |
| Hardware | <generation> |
| vCores / Maximum vCores | <value> |

<human-like description of the SLO>
```

## Database-Scoped MAXDOP

When the user asks about MAXDOP, retrieve the Azure SQL Database setting:

```sql
SELECT name, value
FROM sys.database_scoped_configurations
WHERE name = 'MAXDOP'
OPTION (MAXDOP 1);
```

- Azure SQL Database uses database-scoped MAXDOP rather than the server-scoped setting.
- A value of `0` lets the optimizer choose parallelism up to the compute resources available to the database.
- Recommend changing MAXDOP only after evaluating workload concurrency, query plans, and the database's vCore allocation.

## Connection String Generation

When the user asks for a connection string:

1. **Retrieve** SERVER_NAME, DATABASE_NAME from the current connection (`SELECT @@SERVERNAME, DB_NAME()`). On Azure SQL Database, `@@SERVERNAME` returns the logical server name; the host name is `<logical server name>.database.windows.net`.
2. **Ask** for CATEGORY (ADO.NET, JDBC, ODBC, PHP, Go) and AUTHENTICATION METHOD if not specified.
3. **Generate** using known templates. Replace placeholders with real values where available.
4. If values are missing, present the template with placeholders and note them.

### Available Categories and Auth Methods

| Category | Authentication Methods |
|----------|----------------------|
| ADO.NET | Entra passwordless, SQL auth, Entra password, Entra integrated |
| JDBC | SQL auth, Entra password, Entra integrated |
| ODBC (Node.js) | SQL auth, Entra password, Entra integrated |
| PHP | SQL auth |
| Go | SQL auth |

If category/auth is not specified, present a few sample connection strings. Conclude by informing that other options are available.

## Change Tracking

When asked about tracking changes in an Azure SQL Database, focus on change tracking options **compatible with Azure SQL DB**.

## Collation Guidance

When comparing collations:
1. There are both **database** and **server** default collations.
2. Include information about both unless the user specifies.
3. If you must choose, use the **database** collation but state which you chose.
4. Compare database and server collation — note any differences.
