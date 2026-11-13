---
name: ledger-tables
description: "Use when the user asks about ledger tables: whether ledger fits a tamper-evidence need, creating updatable or append-only ones, or listing them and their history. SQL Server 2022+ and Azure SQL Database."
user-invocable: true
---

# Ledger Tables

Use this skill when the user asks about ledger tables, creating ledger tables, querying historical ledger data, or auditing data changes.

## Required tools

- A SQL query tool connected to the target server and database. Prefer, in order: the SQL Tools MCP
  server that ships with the `microsoft-sql-admin` plugin (`mssql_list_database_connections`,
  `mssql_connect_database`, then `mssql_execute_query`); any other SQL tool the agent host provides
  for running T-SQL and reading result sets;
  [`sqlcmd`](https://learn.microsoft.com/sql/tools/sqlcmd/sqlcmd-utility) from a terminal. The same
  tool also creates ledger tables when the user asks you to make the change. If the SQL Tools MCP
  server is not connected or lists no connections, follow the `sql-tools-mcp-setup` skill, which
  asks before installing or configuring anything. If no SQL tool can be made available, give the
  user the T-SQL to run and ask for the results.

## SQL Queries

### GetHistoryTableForUpdatableLedgerTable
```sql
SELECT name FROM sys.tables
WHERE ledger_type = 1
  AND object_id = (SELECT history_table_id FROM sys.tables WHERE name = '$LedgerTableName' AND ledger_type = 2)
  OPTION (MAXDOP 1);
```

### GetSystemLedgerViewForLedgerTable
```sql
SELECT name AS LedgerViewName
FROM sys.views
WHERE object_id = '$LedgerViewID'
OPTION (MAXDOP 1);
```

### List All Ledger Tables
```sql
SELECT
    SCHEMA_NAME(schema_id) AS SchemaName,
    name AS TableName,
    ledger_type_desc AS LedgerType,
    ledger_view_id
FROM sys.tables
WHERE ledger_type IN (2, 3)
  AND is_dropped_ledger_table = 0
ORDER BY SchemaName, TableName
OPTION (MAXDOP 1);
```

## Ledger Table Types

### Updatable Ledger Tables
- Use `SYSTEM_VERSIONING = ON` (temporal tables) to maintain full history of changes.
- Ledger type = 2 in `sys.tables`.

### Append-Only Ledger Tables
- Only allow inserts — no updates or deletes.
- Ledger type = 3 in `sys.tables`.

### Unsupported Data Types
XML, SqlVariant, User-defined, FILESTREAM, Vector

## Querying Historical Data

When asked about historical data for a table:
1. Check if the table is a ledger table
2. Use the **system-created ledger view** (not the history table directly)
3. Get the view's `object_id` from `sys.tables.ledger_view_id`

**DO NOT** use the history table directly unless specifically asked.
**DO NOT** use undocumented functions like `DBCC log`, `fn_dblog()`, `fn_dump_dblog()`, `fn_full_dblog()`.

### System-Created Ledger View Columns

| Column | Type | Description |
|--------|------|-------------|
| ledger_transaction_id | BIGINT | Transaction ID that created/deleted a row |
| ledger_sequence_number | BIGINT | Sequence number of row operation |
| ledger_operation_type | TINYINT | 1 = INSERT, 2 = DELETE |
| ledger_operation_type_desc | NVARCHAR(128) | INSERT or DELETE |

### Metadata in sys.tables

| Column | Values |
|--------|--------|
| ledger_type | 0=Non-ledger, 1=History, 2=Updatable, 3=Append-only |
| ledger_view_id | object_id of the ledger view (for types 2 and 3) |
| is_dropped_ledger_table | bit — dropped but preserved for auditing |

**DO NOT** include dropped ledger tables or history tables when listing ledger tables unless specifically asked.

## Creating Ledger Tables

### Updatable Ledger Table Template
```sql
CREATE TABLE [schema].[table_name]
(
    column1 datatype,
    ledger_start_transaction_id BIGINT GENERATED ALWAYS AS TRANSACTION_ID START,
    ledger_end_transaction_id BIGINT GENERATED ALWAYS AS TRANSACTION_ID END,
    ledger_start_sequence_number BIGINT GENERATED ALWAYS AS SEQUENCE_NUMBER START,
    ledger_end_sequence_number BIGINT GENERATED ALWAYS AS SEQUENCE_NUMBER END
)
WITH
(
    SYSTEM_VERSIONING = ON (HISTORY_TABLE = [schema].[history_table_name]),
    LEDGER = ON (
        LEDGER_VIEW = [schema].[view_name] (
            TRANSACTION_ID_COLUMN_NAME = ledger_transaction_id,
            SEQUENCE_NUMBER_COLUMN_NAME = ledger_sequence_number,
            OPERATION_TYPE_COLUMN_NAME = ledger_operation_type,
            OPERATION_TYPE_DESC_COLUMN_NAME = ledger_operation_type_desc
        )
    )
);
```

### Append-Only Ledger Table Template
```sql
CREATE TABLE [schema].[table_name]
(
    column1 datatype,
    ledger_start_transaction_id BIGINT GENERATED ALWAYS AS TRANSACTION_ID START,
    ledger_start_sequence_number BIGINT GENERATED ALWAYS AS SEQUENCE_NUMBER START
)
WITH
(
    LEDGER = ON (
        APPEND_ONLY = ON,
        LEDGER_VIEW = [schema].[view_name] (
            TRANSACTION_ID_COLUMN_NAME = ledger_transaction_id,
            SEQUENCE_NUMBER_COLUMN_NAME = ledger_sequence_number,
            OPERATION_TYPE_COLUMN_NAME = ledger_operation_type,
            OPERATION_TYPE_DESC_COLUMN_NAME = ledger_operation_type_desc
        )
    )
);
```

If the user does not specify updatable vs. append-only, ask for clarification before creating.
