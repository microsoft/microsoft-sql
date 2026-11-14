---
name: schema-design-guidance
description: "Use when the user asks to design or review tables or a proposed schema: keys, constraints, normalization, computed columns, full-text, DDL validation. For heaps or disabled indexes, use `table-health-check`."
user-invocable: true
---

# Schema Design Guidance

Use this skill when the user asks about schema design patterns, computed columns, full-text indexes, indexed columns, or row counts.

## Required tools

- A SQL query tool connected to the target server and database. Prefer, in order: the SQL Tools MCP server that ships with the `microsoft-sql-admin` plugin (`mssql_list_database_connections`, `mssql_connect_database`, then `mssql_execute_query`); any other SQL tool the agent host provides for running T-SQL and reading result sets; [`sqlcmd`](https://learn.microsoft.com/sql/tools/sqlcmd/sqlcmd-utility) from a terminal. It is used to run catalog queries and validate generated DDL, and to execute DDL only when the user orders the task. If the SQL Tools MCP server is not connected or lists no connections, follow the `sql-tools-mcp-setup` skill, which asks before installing or configuring anything. If no SQL tool can be made available, give the user the T-SQL to run and ask for the results.

## Validating DDL

Validate generated DDL without executing it by sending the `SET` statements and the script in **one** request, each `SET` in its own batch:

```sql
SET NOEXEC ON;
GO
<DDL script>
GO
SET NOEXEC OFF;
GO
```

`SET NOEXEC ON` compiles and resolves names but executes nothing (use `SET PARSEONLY ON` / `OFF` for a syntax-only check). Objects created earlier in the same script do not exist yet under `NOEXEC`, so later references to them report errors. **Never** send the script in a separate request on the assumption that `NOEXEC` is still on: if the tool does not keep the session, the DDL would execute.

## Computed Columns

If the user asks for **non-persisted** computed columns, do NOT include `PERSISTED` in the DDL statement.

## Finding Full-Text Indexes

The column `is_full_text_enabled` is on `sys.databases` (not `sys.tables`) and indicates full text is enabled on the database. To find tables with full-text indexes:

```sql
SELECT
    t.name AS TableName,
    s.name AS SchemaName
FROM sys.tables t
INNER JOIN sys.schemas s ON t.schema_id = s.schema_id
WHERE t.object_id IN (
    SELECT object_id FROM sys.fulltext_indexes
)
OPTION (MAXDOP 1);
```

## Searching for Indexed Columns

Use `sys.index_columns`, not `sys.columns`:

```sql
SELECT
    SCHEMA_NAME(t.schema_id) AS SchemaName,
    t.name AS TableName,
    ind.name AS IndexName,
    col.name AS ColumnName,
    ind.type_desc AS IndexType,
    ind.is_unique AS IsUnique,
    ind.is_primary_key AS IsPrimaryKey,
    ind.is_unique_constraint AS IsUniqueConstraint,
    ic.is_included_column AS IsIncludedColumn,
    ic.key_ordinal AS KeyOrdinal
FROM sys.indexes ind
INNER JOIN sys.index_columns ic ON ind.object_id = ic.object_id AND ind.index_id = ic.index_id
INNER JOIN sys.columns col ON ic.object_id = col.object_id AND ic.column_id = col.column_id
INNER JOIN sys.tables t ON ind.object_id = t.object_id
ORDER BY SchemaName, TableName, IndexName, ind.index_id, ic.is_included_column, ic.key_ordinal
OPTION (MAXDOP 1);
```

Only if no records are found with the above query, look up the objects and columns the user referred to by name:

```sql
SELECT
    SCHEMA_NAME(o.schema_id) AS SchemaName,
    o.name AS ObjectName,
    o.type_desc AS ObjectType,
    c.name AS ColumnName,
    TYPE_NAME(c.user_type_id) AS DataType
FROM sys.objects AS o
INNER JOIN sys.columns AS c ON c.object_id = o.object_id
WHERE o.is_ms_shipped = 0
  AND (o.name LIKE N'%<name>%' OR c.name LIKE N'%<name>%')  -- agent substitutes the search term
ORDER BY SchemaName, ObjectName, c.column_id
OPTION (MAXDOP 1);
```

## Row Counting

**IMPORTANT:**
- Always check that the table exists before counting rows.
- **DO NOT** use `RowCount` as an alias — it's a reserved keyword.
- Use `TotalRows` instead.

```sql
-- Good: Row count for all tables (default TOP 10)
SELECT TOP 10
    SCHEMA_NAME(t.schema_id) AS SchemaName,
    t.name AS TableName,
    SUM(p.rows) AS TotalRows
FROM sys.tables AS t
JOIN sys.partitions AS p ON t.object_id = p.object_id
WHERE p.index_id IN (0, 1)
GROUP BY t.schema_id, t.name
ORDER BY TotalRows DESC
OPTION (MAXDOP 1);
```

- Use `sys.tables` + `sys.partitions`, NOT `INFORMATION_SCHEMA`.
- Default to TOP 10 unless the user specifies otherwise.

## Behavioral Guidance

### "How do I..." Questions
If the user asks **how** to do something, educate them — do NOT execute the task. Match the level of generality to the question.

### Task Execution
If the user **orders** task completion, execute it on their behalf.

### Database Object Characteristics
If the user asks about characteristics of database objects, first check if the objects exist before querying them.

### Schema Alteration
When creating ALTER scripts:
1. Find the correct schema for objects (users often omit it)
2. Preserve existing constraints unless asked to modify them
3. Understand dependent object relationships
4. Validate as described in Validating DDL — do it automatically, don't ask
