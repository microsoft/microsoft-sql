---
name: always-encrypted-columns
description: "Use when the user asks which plaintext columns can or should use Always Encrypted, or why a column is disqualified. Eligibility only: not for listing already-encrypted columns or their keys."
user-invocable: true
---

# Always Encrypted Column Analysis

Use this skill only when the user asks which currently plaintext columns are eligible candidates for Always Encrypted or wants a table evaluated for prospective encryption eligibility.

Do **not** use this workflow to inventory existing encryption. Requests containing "already encrypted," "currently encrypted," "which CEK," "which column encryption key," or "which column master key" need an existing-encryption catalog query, not the eligibility query below.

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

### GetColumnsThatCanBeEncryptedWithAlwaysEncrypted

The user must provide `$SchemaName` and `$TableName` parameters.

```sql
DECLARE @SchemaName SYSNAME = '$SchemaName',
        @TableName  SYSNAME = '$TableName';

DECLARE @TableId INT;
SELECT @TableId = t.object_id
FROM sys.tables AS t
JOIN sys.schemas AS s ON t.schema_id = s.schema_id
WHERE s.name = @SchemaName AND t.name = @TableName
OPTION (MAXDOP 1);

IF @TableId IS NULL
BEGIN
    RAISERROR('Table %s.%s not found!', 16, 1, @SchemaName, @TableName);
    RETURN;
END;

;WITH ColumnList AS (
    SELECT
        c.object_id, c.column_id, c.name AS ColumnName,
        CASE
          WHEN t.name IN ('decimal','numeric')
            THEN t.name + '(' + CAST(c.precision AS VARCHAR(10)) + ',' + CAST(c.scale AS VARCHAR(10)) + ')'
          WHEN t.name IN ('char','varchar','nchar','nvarchar')
            THEN t.name +
                 CASE WHEN c.max_length = -1 THEN '(max)'
                   WHEN t.name IN ('nchar','nvarchar') THEN '(' + CAST(c.max_length/2 AS VARCHAR(10)) + ')'
                   ELSE '(' + CAST(c.max_length AS VARCHAR(10)) + ')' END
          WHEN t.name IN ('binary','varbinary')
            THEN t.name + CASE WHEN c.max_length = -1 THEN '(max)' ELSE '(' + CAST(c.max_length AS VARCHAR(10)) + ')' END
          ELSE t.name
        END AS ColumnType,
        c.is_nullable
    FROM sys.columns AS c
    JOIN sys.types AS t ON c.user_type_id = t.user_type_id
    WHERE c.object_id = @TableId
),
Violations AS (
    SELECT c.object_id, c.column_id, CAST(NULL AS NVARCHAR(200)) AS Reason, CAST(NULL AS INT) AS ReasonCode
    FROM ColumnList AS c WHERE 1=0

    UNION ALL SELECT c.object_id, c.column_id, 'Unsupported data type (' + ut.name + ')', 1
    FROM ColumnList c JOIN sys.columns col ON col.object_id = c.object_id AND col.column_id = c.column_id
    JOIN sys.types ut ON col.user_type_id = ut.user_type_id
    WHERE LOWER(ut.name) IN ('xml','text','ntext','image','timestamp','rowversion','sql_variant','hierarchyid','geography','geometry') OR ut.is_user_defined = 1

    UNION ALL SELECT c.object_id, c.column_id, 'Identity column', 2
    FROM ColumnList c JOIN sys.columns col ON col.object_id = c.object_id AND col.column_id = c.column_id WHERE col.is_identity = 1

    UNION ALL SELECT c.object_id, c.column_id, 'FILESTREAM column', 3
    FROM ColumnList c JOIN sys.columns col ON col.object_id = c.object_id AND col.column_id = c.column_id WHERE col.is_filestream = 1

    UNION ALL SELECT c.object_id, c.column_id, 'ROWGUIDCOL column', 4
    FROM ColumnList c JOIN sys.columns col ON col.object_id = c.object_id AND col.column_id = c.column_id WHERE col.is_rowguidcol = 1

    UNION ALL SELECT c.object_id, c.column_id, 'Computed column', 5
    FROM ColumnList c JOIN sys.columns col ON col.object_id = c.object_id AND col.column_id = c.column_id WHERE col.is_computed = 1

    UNION ALL SELECT c.object_id, c.column_id, 'Sparse column set', 7
    FROM ColumnList c JOIN sys.columns col ON col.object_id = c.object_id AND col.column_id = c.column_id WHERE col.is_sparse = 1 AND col.is_column_set = 1

    UNION ALL SELECT c.object_id, c.column_id, 'Primary key column', 8
    FROM ColumnList c JOIN sys.index_columns ic ON ic.object_id = c.object_id AND ic.column_id = c.column_id
    JOIN sys.indexes ix ON ix.object_id = ic.object_id AND ix.index_id = ic.index_id WHERE ix.is_primary_key = 1

    UNION ALL SELECT c.object_id, c.column_id, 'Unique index/constraint', 9
    FROM ColumnList c JOIN sys.index_columns ic ON ic.object_id = c.object_id AND ic.column_id = c.column_id
    JOIN sys.indexes ix ON ix.object_id = ic.object_id AND ix.index_id = ic.index_id WHERE ix.is_unique = 1 AND ix.is_primary_key = 0

    UNION ALL SELECT c.object_id, c.column_id, 'Indexed column', 10
    FROM ColumnList c JOIN sys.index_columns ic ON ic.object_id = c.object_id AND ic.column_id = c.column_id
    JOIN sys.indexes ix ON ix.object_id = ic.object_id AND ix.index_id = ic.index_id WHERE ix.is_primary_key = 0 AND ix.is_unique = 0

    UNION ALL SELECT c.object_id, c.column_id, 'Full-text index', 11
    FROM ColumnList c JOIN sys.fulltext_index_columns fti ON fti.object_id = c.object_id AND fti.column_id = c.column_id

    UNION ALL SELECT c.object_id, c.column_id, 'Default constraint', 12
    FROM ColumnList c JOIN sys.default_constraints dc ON dc.parent_object_id = c.object_id AND dc.parent_column_id = c.column_id

    UNION ALL SELECT c.object_id, c.column_id, 'Check constraint', 13
    FROM ColumnList c JOIN sys.check_constraints ck ON ck.parent_object_id = c.object_id
    WHERE ck.definition LIKE '%[' + c.ColumnName + ']%' OR ' ' + ck.definition + ' ' LIKE '% ' + c.ColumnName + ' %'

    UNION ALL SELECT c.object_id, c.column_id, 'Foreign key constraint', 14
    FROM ColumnList c JOIN sys.foreign_key_columns fk
    ON (fk.parent_object_id = c.object_id AND fk.parent_column_id = c.column_id)
    OR (fk.referenced_object_id = c.object_id AND fk.referenced_column_id = c.column_id)

    UNION ALL SELECT c.object_id, c.column_id, 'Statistics on column', 15
    FROM ColumnList c JOIN sys.stats_columns sc ON sc.object_id = c.object_id AND sc.column_id = c.column_id

    UNION ALL SELECT c.object_id, c.column_id, 'Partitioning column', 16
    FROM ColumnList c JOIN sys.index_columns ic ON ic.object_id = c.object_id AND ic.column_id = c.column_id WHERE ic.partition_ordinal = 1

    UNION ALL SELECT c.object_id, c.column_id, 'Change Data Capture (CDC)', 17
    FROM ColumnList c JOIN sys.tables t ON t.object_id = c.object_id WHERE t.is_tracked_by_cdc = 1

    UNION ALL SELECT c.object_id, c.column_id, 'Dynamic Data Masking', 18
    FROM ColumnList c JOIN sys.masked_columns m ON m.object_id = c.object_id AND m.column_id = c.column_id

    UNION ALL SELECT c.object_id, c.column_id, 'Stretch-enabled table', 19
    FROM ColumnList c JOIN sys.tables t ON t.object_id = c.object_id WHERE t.is_remote_data_archive_enabled = 1

    UNION ALL SELECT c.object_id, c.column_id, 'External table', 20
    FROM ColumnList c JOIN sys.tables t ON t.object_id = c.object_id WHERE t.is_external = 1
)
SELECT
    cl.ColumnName,
    cl.ColumnType,
    CanBeEncrypted = CASE WHEN v.ReasonList IS NULL THEN 'Yes' ELSE 'No' END,
    Reason = ISNULL(v.ReasonList, 'meets all required conditions')
FROM ColumnList AS cl
OUTER APPLY (
    SELECT STRING_AGG(Reason, '; ') WITHIN GROUP (ORDER BY ReasonCode) AS ReasonList
    FROM Violations WHERE Violations.object_id = cl.object_id AND Violations.column_id = cl.column_id
) AS v
ORDER BY cl.column_id
OPTION (MAXDOP 1);
```

## Report Format

Report **all** columns — even those that do not meet requirements — as a Markdown table:

| Column Name | Column Type | Can Be Encrypted | Reason |
|-------------|-------------|------------------|--------|

## Key Requirements for Always Encrypted

A column **cannot** be encrypted if it:
- Has unsupported types: xml, timestamp, rowversion, image, ntext, text, sql_variant, hierarchyid, geography, geometry, alias, or user-defined types
- Is an IDENTITY, FILESTREAM, ROWGUIDCOL, computed, or sparse column set column
- Is a primary key, unique constraint, or indexed column
- Is in a full-text index, has default/check constraints, foreign keys, or statistics
- Is a partitioning column, CDC-tracked, dynamically masked, in a Stretch-enabled or external table

**Note**: CHAR, VARCHAR, NCHAR, NVARCHAR, VARCHAR(MAX), NVARCHAR(MAX) columns will have their collation changed to binary-code point (`_BIN2`) if encrypted.
