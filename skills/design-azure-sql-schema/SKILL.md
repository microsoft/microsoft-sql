---
name: design-azure-sql-schema
description: >-
  Designs tables for Azure SQL Database so the first index, the first long value or the first
  failover does not force a rebuild. Covers index key limits counted in bytes, why Unicode sizing
  makes NVARCHAR(850) and NVARCHAR(450) the real ceilings, collation as a decision taken once at
  CREATE DATABASE, the implicit conversion that turns a lookup into a full index scan, identity
  gaps of a thousand across a restart, unique columns that accept exactly one NULL, and where a
  json or vector column belongs. Use when creating or reviewing tables, choosing a key, a string
  length or a database collation, or when someone reports a warning about maximum key length, an
  insert failing long after its migration succeeded, a lookup that suddenly scans, identity values
  that jumped, or a duplicate key on NULL. This is the engine rule underneath the mappers:
  ef-core-azure-sql and sqlalchemy-azure-sql own how each one expresses it, t-sql-correctness owns
  query syntax, and vector-search-azure-sql owns vector search.
---

# Design a schema Azure SQL Database will not make you rebuild

These are the schema decisions Azure SQL Database punishes **later**, not at `CREATE TABLE`.
Normalisation and naming are not here: they are the same everywhere.

Everything below was measured on 2026-08-28 against a live engine where
`SERVERPROPERTY('EngineEdition')` returns `5` and `Edition` is `SQL Azure`.
Open [the measured statements](references/key-bytes-collation-and-identity-gaps.md) when a number
below disagrees with your engine, and before changing one.

| | |
|---|---|
| The DDL | succeeds, sometimes with a warning nobody reads |
| The migration | succeeds |
| The failure | arrives on a row, a plan or a failover, weeks later, in production |

**A syntax error costs minutes. Each item here costs a table rebuild, a collation rebuild or a
duplicated key.**

## 1. The index key budget is in bytes, and Unicode spends two per character

**1700 bytes for a nonclustered index key, 900 for a clustered one**, and a composite key spends
the **sum**. `NVARCHAR(n)` costs `2n` bytes, so:

| Position | Widest safe Unicode column | Widest safe UTF-8 column |
|---|---|---|
| Nonclustered index or unique constraint | `NVARCHAR(850)` | `VARCHAR(1700)` |
| Clustered index or clustered primary key | `NVARCHAR(450)` | `VARCHAR(900)` |
| Anything not in a key | unbounded | unbounded |

`NVARCHAR(450)` is the only length safe in **every** index position, which is why EF Core narrows
an indexed string to it.

Over-shooting is a **warning**, message 1945 at severity 10. The index exists, the migration
reports success, short values insert fine:

```text
Warning! The maximum key length for a nonclustered index is 1700 bytes.
The index 'ux_acct_email' has maximum length of 2000 bytes.
For some combination of large values, the insert/update operation will fail.
```

The failure waits for the first long row, and this one is an error:

```text
Msg 1946, Level 16, State 3
Operation failed. The index entry of length 1800 bytes for the index 'ux_acct_email'
exceeds the maximum length of 1700 bytes for nonclustered indexes.
```

**Consequence of being wrong: a write path that has worked for months starts rejecting exactly the
rows that matter,** and the fix is an `ALTER COLUMN` plus an index rebuild on a live table.

- **`INCLUDE` columns do not count against the budget.** A covering index can include
  `NVARCHAR(MAX)`.
- **A foreign key column must match the parent's length and collation exactly**, `Msg 1753` and
  `Msg 1757`, so an oversized parent key propagates to every child.
- `NVARCHAR(MAX)`, `json` and `vector` cannot be key columns at all: `Msg 1919`, `Msg 1978`.

## 2. Collation is chosen at CREATE DATABASE, and it decides two things

A new database with no collation stated gets `SQL_Latin1_General_CP1_CI_AS`.

`CI` means identifiers are not unique the way the design assumes:

```sql
CREATE TABLE dbo.tokens (t NVARCHAR(64) NOT NULL PRIMARY KEY);
INSERT INTO dbo.tokens (t) VALUES (N'aB1x');
INSERT INTO dbo.tokens (t) VALUES (N'Ab1X');
-- Msg 2627, Violation of PRIMARY KEY constraint. The duplicate key value is (Ab1X).
```

**Consequence of being wrong: any column holding a case-significant token, API key, slug or short
link code collides at roughly the rate its alphabet implies**, as a user-visible insert failure.
The fix is per column:

```sql
ALTER TABLE dbo.tokens ALTER COLUMN t NVARCHAR(64) COLLATE Latin1_General_CS_AS NOT NULL;
```

**State the collation in `CREATE DATABASE`, or accept the default deliberately.** There is no
server collation to inherit, and `ALTER DATABASE ... COLLATE` afterwards re-collates nothing that
already exists: it succeeds, changes only what is created next, and leaves you joining across a
collation conflict, `Msg 468`. The second half of the default's cost is section 3.

## 3. The implicit conversion that costs the seek

The common drivers bind a string parameter as Unicode by default. Under the **default** collation,
comparing that parameter to a `VARCHAR` column converts the **column**, and a converted column
cannot be sought. Measured over 20,000 rows with a unique index on `email`:

| Column | Collation | Parameter | Plan | Logical reads |
|---|---|---|---|---|
| `VARCHAR(320)` | `SQL_Latin1_General_CP1_CI_AS` (the default) | `NVARCHAR` | **Index Scan** | **80** |
| `VARCHAR(320)` | `Latin1_General_CI_AS` | `NVARCHAR` | Index Seek | 2 |
| `VARCHAR(850)` | `Latin1_General_100_CI_AS_SC_UTF8` | `NVARCHAR` | Index Seek | 2 |
| `NVARCHAR(320)` | any | `NVARCHAR` | Index Seek | 2 |
| `VARCHAR(320)` | the default | `VARCHAR` | Index Seek | 2 |

```text
|--Index Scan(OBJECT:([dbo].[users_v].[ux_v]),
     WHERE:(CONVERT_IMPLICIT(nvarchar(320),[dbo].[users_v].[email],0)=[@p]))
```

Row two seeks because a Windows collation lets the optimizer build a range with
`GetRangeThroughConvert`. **A SQL collation cannot, and the default is a SQL collation.**

**Consequence of being wrong: every lookup on that column reads the whole index instead of three
pages, forever, with no error and no warning.** Two designs avoid it, and one has to be chosen up
front:

1. **`NVARCHAR` for anything a driver will bind a string to.** Correct, and it costs key bytes.
2. **A UTF-8 collation on `VARCHAR`** when the data is ASCII-dominant and the key is tight.
   `VARCHAR(1700)` then fits a nonclustered key, and the seek survives because UTF-8 collations are
   Windows collations. The cost is that `VARCHAR(n)` counts **bytes**.

Do not mix. `VARCHAR` under the default collation plus an application binding Unicode is row one.

## 4. Identity gaps are routine here, and the remembered fix does not exist

Measured across one engine restart, which is what a planned failover looks like from inside:

| Column | Last value before | First value after | Gap |
|---|---|---|---|
| `INT IDENTITY` | 3 | **1002** | 999 |
| `BIGINT IDENTITY` | 3 | **10002** | 9999 |
| `SEQUENCE`, default cache | 2 | **51** | 49 |
| `SEQUENCE ... NO CACHE` | 2 | 3 | none |
| `INT IDENTITY` with `IDENTITY_CACHE = OFF` | 3 | **4** | none |

**Consequence of being wrong: any number a human reads or a regulator counts, an invoice number, a
ticket number, an order reference, develops thousand-wide holes, unrecoverably.** Nothing errors.

```sql
-- The remembered remedy from a non-PaaS engine. Refused here.
DBCC TRACEON (272, -1);   -- Msg 40518, DBCC command 'traceon' is not supported

-- The lever that works. It survives a restart and costs a log write per value.
ALTER DATABASE SCOPED CONFIGURATION SET IDENTITY_CACHE = OFF;

-- A human-facing number gets its own sequence, and START WITH is not optional:
-- omitted, the first value is -9223372036854775808.
CREATE SEQUENCE dbo.invoice_no AS BIGINT START WITH 1 INCREMENT BY 1 NO CACHE;
```

A surrogate key may be `IDENTITY`: gaps in a key nobody reads are free, and the cache is why
inserts are fast. A number a person reads is not a surrogate key.

## 5. A unique index accepts exactly one NULL

This one arrives from PostgreSQL habit, where every NULL is distinct.

```sql
CREATE UNIQUE INDEX ux_code ON dbo.accounts (code);
INSERT INTO dbo.accounts (code) VALUES (NULL);   -- 1 row
INSERT INTO dbo.accounts (code) VALUES (NULL);
-- Msg 2601, Cannot insert duplicate key row ... The duplicate key value is (<NULL>).
-- Msg 2627 instead, where the constraint is a unique constraint rather than an index.

-- The fix, verified to accept many NULL rows:
DROP INDEX ux_code ON dbo.accounts;
CREATE UNIQUE INDEX ux_code ON dbo.accounts (code) WHERE code IS NOT NULL;
```

**Consequence of being wrong: an optional unique field, an external account id, a nullable slug,
works for the first row that leaves it empty and rejects the second.** A model with two or three
optional unique fields is unusable here and correct on other engines. The session creating a
filtered index, and every session writing to the table, needs `QUOTED_IDENTIFIER ON`, else
`Msg 1934`. Drivers set it; a command line client may not.

## 6. Where the json and vector types belong

Both are storage decisions, not key decisions.

| | `json` | `vector(n)` |
|---|---|---|
| Index key column | no, `Msg 1978` | no, `Msg 1978` |
| Primary key | no | no, `Msg 1919` |
| `INCLUDE` column | yes, verified | route to `vector-search-azure-sql` |
| Compared with `=` | no, `Msg 402` against `nvarchar` | route to `vector-search-azure-sql` |
| Ceiling | 2 GB | 1998 dimensions, `Msg 2717` above it |

A `json` column is not a filter. Promote anything a query filters on **every time** into a real
column:

```sql
ALTER TABLE dbo.doc ADD tenant AS CAST(JSON_VALUE(payload, '$.tenant') AS NVARCHAR(64)) PERSISTED;
CREATE INDEX ix_doc_tenant ON dbo.doc (tenant);
```

A `vector` column is a payload beside the key, never part of it. A `vector(1536)` occupies 6152 of
the 8060 bytes in a row, so keep the table narrow: put the embedding next to an integer key.

## 7. Two boundaries a design cannot cross here

```sql
-- No foreign key reaches another database, even one on the same server.
ALTER TABLE dbo.local_child ADD CONSTRAINT fk_x FOREIGN KEY (parent_id)
  REFERENCES otherdb.dbo.some_parent (id);
-- Msg 40515, Reference to database and/or server name in 'otherdb.dbo.some_parent'
--            is not supported in this version of SQL Server.

-- There is one filegroup, so a partition scheme maps everything to it.
SELECT name, type_desc FROM sys.filegroups;   -- PRIMARY, and nothing else
CREATE PARTITION SCHEME ps AS PARTITION pf ALL TO ([PRIMARY]);
```

A shared-lookup-database design has no referential integrity here. Partitioning buys
manageability, never storage separation.

## Check it worked

Run the DDL through `sqlcmd` with `-m-1`, because message 1945 is **severity 10** and `-b` alone
does not report severity 10 at all, so a migration that emitted it still exits 0:

**`-m-1` is an ODBC `sqlcmd` instruction**, meaning the 18.x build from `mssql-tools18` or the
Microsoft command line utilities. Measured 2026-09-05, go-sqlcmd 1.10.0, the 1.x build
`brew install sqlcmd` and `winget install sqlcmd` install, prints no `Msg` header on a severity 10
message at any `-m` value, so on that build the `grep` below finds no message 1945 to report. `build-app-on-azure-sql` tells the two
builds apart in one table.

```bash
export SQLCMDPASSWORD='<password>'
sqlcmd -S <server-name>.database.windows.net,1433 -d <database> -U <user> -C -b -m-1 \
  -i schema.sql -o schema.out
grep -nE 'Warning!|^Msg ' schema.out
```

Expect no output from `grep`. A `Warning!` line naming a key length is message 1945 and predicts
`Msg 1946` on a production insert.

Then audit the schema the engine actually has, as `schema-audit.sql`:

```sql
-- 1. Index keys over budget. Expect zero rows.
SELECT OBJECT_NAME(i.object_id) AS table_name, i.name AS index_name, i.type_desc,
       SUM(CASE WHEN c.max_length = -1 THEN 0 ELSE c.max_length END) AS key_bytes,
       CASE WHEN i.type = 1 THEN 900 ELSE 1700 END AS budget
FROM sys.indexes AS i
JOIN sys.index_columns AS ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
                            AND ic.is_included_column = 0
JOIN sys.columns AS c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
WHERE i.type IN (1, 2) AND OBJECTPROPERTY(i.object_id, 'IsUserTable') = 1
GROUP BY i.object_id, i.name, i.type, i.type_desc
HAVING SUM(CASE WHEN c.max_length = -1 THEN 0 ELSE c.max_length END)
       > CASE WHEN i.type = 1 THEN 900 ELSE 1700 END;

-- 2. Unique indexes over a nullable column with no filter: one NULL row each. Expect zero.
SELECT OBJECT_NAME(i.object_id) AS table_name, i.name AS index_name, c.name AS column_name
FROM sys.indexes AS i
JOIN sys.index_columns AS ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
                            AND ic.is_included_column = 0
JOIN sys.columns AS c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
WHERE i.is_unique = 1 AND i.has_filter = 0 AND c.is_nullable = 1;

-- 3. VARCHAR or CHAR key columns on a SQL collation: the lost seek. Expect zero rows.
SELECT DISTINCT OBJECT_NAME(c.object_id) AS table_name, c.name AS col, c.collation_name
FROM sys.columns AS c
JOIN sys.index_columns AS ic ON ic.object_id = c.object_id AND ic.column_id = c.column_id
                            AND ic.is_included_column = 0
JOIN sys.types AS t ON t.user_type_id = c.user_type_id
WHERE t.name IN ('varchar', 'char') AND c.collation_name LIKE 'SQL[_]%';

-- 4. Sequences left on the type minimum because START WITH was omitted. Expect zero rows.
SELECT name, CAST(start_value AS BIGINT) AS start_value
FROM sys.sequences WHERE CAST(start_value AS BIGINT) < 0;

-- 5. The two settings the design assumed. Read them, do not assume them.
SELECT DATABASEPROPERTYEX(DB_NAME(), 'Collation') AS db_collation,
       (SELECT value FROM sys.database_scoped_configurations
        WHERE name = 'IDENTITY_CACHE') AS identity_cache;
```

```bash
sqlcmd -S <server-name>.database.windows.net,1433 -d <database> -U <user> -C -W \
  -i schema-audit.sql -o schema-audit.out
```

Checks 1 to 4 return no rows in a clean schema. Check 5 is the one you read rather than pass:
`identity_cache` of `0` means gaps are off, `1` means an `INT IDENTITY` will jump by about a
thousand across the next reconfiguration.

Last, confirm the seek survived on one real lookup:

```sql
SET STATISTICS IO ON;
DECLARE @p NVARCHAR(320) = N'u9999@example.com';
SELECT id FROM dbo.users WHERE email = @p;
SET STATISTICS IO OFF;
```

Expect single-digit logical reads that do not grow with the table. Reads in the tens over twenty
thousand rows is the implicit conversion in section 3, not a cold cache.

## Do not

- Do not read message 1945 as informational. It is the only notice given, and severity 10 means
  neither `sqlcmd -b` nor most drivers raise it.
- Do not size a key column in characters. The limit is bytes, and Unicode doubles it.
- Do not use `VARCHAR` under the default collation for anything an application looks up by value.
- Do not add `LOWER()` or `UPPER()` around a column to fix a collation problem. That costs the
  index too, and it is `t-sql-correctness`.
- Do not reach for trace flag 272. It is rejected with `Msg 40518`. The lever is
  `IDENTITY_CACHE = OFF`.
- Do not put an invoice or ticket number, or anything an auditor reads, on a bare `IDENTITY`.
- Do not create a `SEQUENCE` without `START WITH`.
- Do not give a model two or three optional unique columns and expect PostgreSQL NULL semantics.
- Do not store a value in a `json` document and then filter on it. Promote it.
- Do not add a clustered index only because you believe this engine demands one. A heap was
  created and took rows on 2026-08-28.

## References

- Open [the measured statements](references/key-bytes-collation-and-identity-gaps.md) when you need
  the statement behind a number above, the two query plans, or the reproduction steps.
- Read [Maximum capacity specifications](https://learn.microsoft.com/sql/sql-server/maximum-capacity-specifications-for-sql-server)
  before designing a wide composite key.
- Read [Collation and Unicode support](https://learn.microsoft.com/sql/relational-databases/collations/collation-and-unicode-support)
  before choosing a database collation: SQL against Windows collations, and UTF-8.
- Read [json data type](https://learn.microsoft.com/sql/t-sql/data-types/json-data-type) before
  putting a document in a column, for the index restrictions and the size limits.
- Read [Database scoped configurations](https://learn.microsoft.com/sql/t-sql/statements/alter-database-scoped-configuration-transact-sql)
  before setting `IDENTITY_CACHE`, and
  [T-SQL differences](https://learn.microsoft.com/azure/azure-sql/database/transact-sql-tsql-differences-sql-server)
  when a statement is refused with 40510, 40515, 40517 or 40518.
- `ef-core-azure-sql` and `sqlalchemy-azure-sql`: how each mapper reaches these lengths and the
  default it lands on. The other mapper skills are listed in `skill.spec.jsonc`.
- `t-sql-correctness` for query-level correctness, `t-sql-json-and-openjson` for querying a
  document column, `vector-search-azure-sql` for the vector type and its indexing.
- `schema-migrations-safely` and `sql-database-projects` for applying a change to a live database,
  and `provision-azure-sql-db` for creating the database and naming its collation.
