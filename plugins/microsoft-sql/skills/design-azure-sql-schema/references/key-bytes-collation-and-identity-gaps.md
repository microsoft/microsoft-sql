# Index key bytes, collation, identity gaps: the statements that produced every number

Every number and message quoted in `SKILL.md` came from a run on **2026-08-28** against a live
engine reporting `EngineEdition` 5 and `Edition` `SQL Azure`, product version 12.0.2000.8, server
collation `SQL_Latin1_General_CP1_CI_AS`. Output is copied verbatim.

## Contents

- [How to reproduce](#how-to-reproduce)
- [Defaults a new database gets](#defaults-a-new-database-gets)
- [Index key limits in bytes](#index-key-limits-in-bytes)
- [What a key column may not be](#what-a-key-column-may-not-be)
- [Foreign keys must match exactly](#foreign-keys-must-match-exactly)
- [Collation and uniqueness](#collation-and-uniqueness)
- [The collation retrofit that does not work](#the-collation-retrofit-that-does-not-work)
- [Implicit conversion and the lost seek](#implicit-conversion-and-the-lost-seek)
- [Identity and sequence gaps across a restart](#identity-and-sequence-gaps-across-a-restart)
- [Unique indexes and NULL](#unique-indexes-and-null)
- [The json type](#the-json-type)
- [The vector type](#the-vector-type)
- [Boundaries](#boundaries)
- [What did not hold](#what-did-not-hold)

## How to reproduce

Run a local Azure SQL Database container, connect as an administrative login with a password taken
from the environment rather than written down, and confirm the engine before trusting anything
below:

```sql
SELECT SERVERPROPERTY('EngineEdition') AS ee,      -- 5
       SERVERPROPERTY('Edition')       AS ed,      -- SQL Azure
       SERVERPROPERTY('Collation')     AS servercoll;
```

Every statement below runs in a database created with `CREATE DATABASE schemalab;` and no other
options, with `SET QUOTED_IDENTIFIER ON` and `SET ANSI_NULLS ON`.

## Defaults a new database gets

```sql
CREATE DATABASE schemalab;
SELECT name, collation_name, is_read_committed_snapshot_on, compatibility_level
FROM sys.databases WHERE name = 'schemalab';
```

```text
name       collation_name                is_read_committed_snapshot_on  compatibility_level
schemalab  SQL_Latin1_General_CP1_CI_AS  1                              170
```

Three things follow. The default collation is case-insensitive **and** it is a SQL collation, which
is the combination sections 2 and 3 of `SKILL.md` are about. Read committed snapshot isolation is
on by default. The compatibility level of a new database was 170.

## Index key limits in bytes

Each statement, and what the server returned.

| Statement | Result |
|---|---|
| `CREATE UNIQUE INDEX ux ON t(NVARCHAR(1000) col)` | warning, 2000 bytes against 1700 |
| `CREATE UNIQUE INDEX ux ON t(NVARCHAR(851) col)` | warning, 1702 bytes against 1700 |
| `CREATE UNIQUE INDEX ux ON t(NVARCHAR(850) col)` | **clean** |
| `PRIMARY KEY CLUSTERED (NVARCHAR(451) col)` | warning, 902 bytes against 900 |
| `PRIMARY KEY CLUSTERED (NVARCHAR(450) col)` | **clean** |
| `CREATE UNIQUE INDEX ux ON t(a, b, c)`, three `NVARCHAR(300)` | warning, 1800 bytes against 1700 |
| `CREATE UNIQUE INDEX ux ON t(NVARCHAR(400) a) INCLUDE (NVARCHAR(4000), NVARCHAR(MAX))` | **clean** |
| `CREATE UNIQUE INDEX ux ON t(VARCHAR(1700) col COLLATE ..._UTF8)` | **clean** |
| `CREATE UNIQUE INDEX ux ON t(VARCHAR(1701) col COLLATE ..._UTF8)` | warning, 1701 bytes against 1700 |

The warning, in full:

```text
Warning! The maximum key length for a nonclustered index is 1700 bytes.
The index 'ux_acct_email' has maximum length of 2000 bytes.
For some combination of large values, the insert/update operation will fail.
```

`sys.messages` gives that message id **1945** at **severity 10**, so it is a warning and a client
that only surfaces errors shows nothing at all.

The deferred failure, on the first row long enough to matter:

```sql
INSERT INTO dbo.acct (email) VALUES (REPLICATE(CAST(N'a' AS NVARCHAR(MAX)), 900));
```

```text
Msg 1946, Level 16, State 3, Server SQL Azure, Line 1
Operation failed. The index entry of length 1800 bytes for the index 'ux_acct_email'
exceeds the maximum length of 1700 bytes for nonclustered indexes.
```

And where a column was narrowed rather than over-sized, the engine refuses instead of truncating:

```sql
INSERT INTO dbo.n450 (slug) VALUES (REPLICATE(CAST(N'a' AS NVARCHAR(MAX)), 451));
```

```text
Msg 2628, Level 16, State 1, Server SQL Azure, Line 1
String or binary data would be truncated in table 'schemalab.dbo.n450', column 'slug'.
Truncated value: 'aaaaaaaa...'.
```

## What a key column may not be

```text
CREATE INDEX ix_big ON dbo.lob_t (big);          -- big is NVARCHAR(MAX)
Msg 1919  Column 'big' in table 'dbo.lob_t' is of a type that is invalid for use as a key column
          in an index.

CREATE INDEX ix_doc ON dbo.doc (payload);        -- payload is json
Msg 1978  Column 'payload' in table 'dbo.doc' is of a type that is invalid for use as a key column
          in an index or statistics.

CREATE TABLE dbo.emb2 (v VECTOR(4) NOT NULL PRIMARY KEY);
Msg 1919  Column 'v' in table 'emb2' is of a type that is invalid for use as a key column
          in an index.
```

A fixed-width row over the page limit is refused at create time:

```text
CREATE TABLE dbo.wide_fixed (a NCHAR(4000), b NCHAR(1000));
Msg 1701  Creating or altering table 'wide_fixed' failed because the minimum row size would be
          10007, including 7 bytes of internal overhead. This exceeds the maximum allowable table
          row size of 8060 bytes.
```

The variable-width equivalent, `NVARCHAR(4000)` plus `NVARCHAR(1000)`, was created without a
warning, because those columns are eligible for row overflow.

## Foreign keys must match exactly

```text
-- parent NVARCHAR(64), child NVARCHAR(128)
Msg 1753  Column 'dbo.p2.k' is not the same length or scale as referencing column 'c2.k' in
          foreign key 'FK__c2__k__0F624AF8'. Columns participating in a foreign key relationship
          must be defined with the same length and scale.

-- parent COLLATE Latin1_General_CS_AS, child on the database default
Msg 1757  Column 'dbo.p3.k' is not of same collation as referencing column 'c3.k' in
          foreign key 'FK__c3__k__14270015'.
```

A parent key of `NVARCHAR(900)`, 1800 bytes, raised the 1945 warning on its own primary key and the
child column had to match it, so an oversized key propagates rather than staying local.

## Collation and uniqueness

```sql
CREATE TABLE dbo.tok_ci (t NVARCHAR(64) NOT NULL PRIMARY KEY);
CREATE TABLE dbo.tok_cs (t NVARCHAR(64) COLLATE Latin1_General_CS_AS NOT NULL PRIMARY KEY);

INSERT INTO dbo.tok_cs (t) VALUES (N'aB1x'), (N'Ab1X');   -- 2 rows
INSERT INTO dbo.tok_ci (t) VALUES (N'aB1x');              -- 1 row
INSERT INTO dbo.tok_ci (t) VALUES (N'Ab1X');
```

```text
Msg 2627, Level 14, State 1, Server SQL Azure, Line 2
Violation of PRIMARY KEY constraint 'PK__tok_ci__3BD01999B8939C9B'.
Cannot insert duplicate key in object 'dbo.tok_ci'. The duplicate key value is (Ab1X).
```

Final counts: `tok_cs` 2 rows, `tok_ci` 1 row.

## The collation retrofit that does not work

```sql
-- in a fresh database on the default collation
CREATE TABLE dbo.old_t (c VARCHAR(50) NOT NULL);
-- sys.columns.collation_name for old_t.c: SQL_Latin1_General_CP1_CI_AS

ALTER DATABASE collab2 COLLATE Latin1_General_CS_AS;   -- succeeds

-- sys.columns.collation_name for old_t.c: SQL_Latin1_General_CP1_CI_AS, UNCHANGED
CREATE TABLE dbo.new_t (c VARCHAR(50) NOT NULL);
-- sys.columns.collation_name for new_t.c: Latin1_General_CS_AS

SELECT COUNT(*) FROM dbo.old_t o JOIN dbo.new_t n ON o.c = n.c;
```

```text
Msg 468, Level 16, State 9, Server SQL Azure, Line 2
Cannot resolve the collation conflict between "Latin1_General_CS_AS" and
"SQL_Latin1_General_CP1_CI_AS" in the equal to operation.
```

`CREATE DATABASE collab COLLATE Latin1_General_100_CI_AS_SC_UTF8;` was accepted, so stating the
collation at creation is available and is the only version of this decision that works cleanly.
`sys.fn_helpcollations()` returned 1585 collations whose name ends in `_UTF8`.

## Implicit conversion and the lost seek

Three tables, 20,000 identical rows of the form `u<n>@example.com`, each with a unique index on
`email`.

```sql
CREATE TABLE dbo.users_v (id INT IDENTITY PRIMARY KEY, email VARCHAR(320) NOT NULL);
CREATE TABLE dbo.users_w (id INT IDENTITY PRIMARY KEY,
                          email VARCHAR(320) COLLATE Latin1_General_CI_AS NOT NULL);
CREATE TABLE dbo.users_n (id INT IDENTITY PRIMARY KEY, email NVARCHAR(320) NOT NULL);
```

```sql
DECLARE @p NVARCHAR(320) = N'u12345@example.com';
SELECT id FROM dbo.users_v WHERE email = @p;
```

`SET STATISTICS IO ON` reported, for one row returned:

| Table | Column type and collation | Scan count | Logical reads |
|---|---|---|---|
| `users_v` | `VARCHAR`, `SQL_Latin1_General_CP1_CI_AS` | 1 | **80** |
| `users_w` | `VARCHAR`, `Latin1_General_CI_AS` | 1 | 2 |
| `users_n` | `NVARCHAR` | 0 | 2 |
| `users_v` with a `VARCHAR` parameter | `VARCHAR`, default collation | 0 | 2 |
| `u8` | `VARCHAR`, `Latin1_General_100_CI_AS_SC_UTF8` | 0 | 2 |

`SET SHOWPLAN_TEXT ON` for the same three statements:

```text
-- users_v, VARCHAR under the default SQL collation
|--Index Scan(OBJECT:([dbo].[users_v].[ux_v]),
     WHERE:(CONVERT_IMPLICIT(nvarchar(320),[dbo].[users_v].[email],0)=[@p]))

-- users_w, VARCHAR under a Windows collation
|--Compute Scalar(DEFINE:(([Expr1005],[Expr1006],[Expr1004])=GetRangeThroughConvert(...)))
|--Index Seek(OBJECT:([dbo].[users_w].[ux_w]),
     SEEK:([email] > [Expr1005] AND [email] < [Expr1006]), ...)

-- users_n, NVARCHAR
|--Index Seek(OBJECT:([dbo].[users_n].[ux_n]), SEEK:([email]=[@p]) ORDERED FORWARD)
```

The conversion is applied to the **column** in the first plan, which is what removes the seek. In
the second it is applied to the parameter and a range is derived instead. The UTF-8 collation
behaved like the Windows collation, because it is one.

## Identity and sequence gaps across a restart

Setup, then a full engine restart, which is what a planned reconfiguration looks like from inside
the database.

```sql
CREATE TABLE dbo.inv_int (id INT    IDENTITY(1,1) PRIMARY KEY, note NVARCHAR(20));
CREATE TABLE dbo.inv_big (id BIGINT IDENTITY(1,1) PRIMARY KEY, note NVARCHAR(20));
CREATE SEQUENCE dbo.seq_cached  AS BIGINT START WITH 1 INCREMENT BY 1;
CREATE SEQUENCE dbo.seq_nocache AS BIGINT START WITH 1 INCREMENT BY 1 NO CACHE;
-- three inserts into each table, two values from each sequence
```

| | Last value before restart | First value after |
|---|---|---|
| `INT IDENTITY` | 3 | **1002** |
| `BIGINT IDENTITY` | 3 | **10002** |
| `SEQUENCE`, default cache | 2 | **51** |
| `SEQUENCE ... NO CACHE` | 2 | 3 |

The fix an agent recalls from a non-PaaS engine is refused:

```text
DBCC TRACEON (272, -1);
Msg 40518, Level 16, State 5, Server SQL Azure, Line 2
DBCC command 'traceon' is not supported in this version of SQL Server.
```

The lever that does work, and a second restart to prove it:

```sql
ALTER DATABASE SCOPED CONFIGURATION SET IDENTITY_CACHE = OFF;
-- three inserts, MAX(id) = 3, restart, one insert
```

`MAX(id)` afterwards was **4**, and `sys.database_scoped_configurations` still reported
`IDENTITY_CACHE = 0`, so the setting survives the restart.

A sequence with no `START WITH`:

```sql
CREATE SEQUENCE dbo.seq_nostart AS BIGINT;
SELECT NEXT VALUE FOR dbo.seq_nostart;   -- -9223372036854775808
```

`sys.sequences` reported `start_value` and `minimum_value` both `-9223372036854775808`.

## Unique indexes and NULL

```sql
CREATE UNIQUE INDEX ux_code ON dbo.nulltest (code);
INSERT INTO dbo.nulltest (code) VALUES (NULL);   -- 1 row
INSERT INTO dbo.nulltest (code) VALUES (NULL);
```

```text
Msg 2601, Level 14, State 1, Server SQL Azure, Line 1
Cannot insert duplicate key row in object 'dbo.nulltest' with unique index 'ux_code'.
The duplicate key value is (<NULL>).
```

The same violation through a unique **constraint** rather than an index reports `Msg 2627`.

The filtered index accepts many:

```sql
CREATE UNIQUE INDEX ux_code2 ON dbo.nulltest2 (code) WHERE code IS NOT NULL;
INSERT INTO dbo.nulltest2 (code) VALUES (NULL), (NULL);
SELECT COUNT(*) FROM dbo.nulltest2;   -- 5
```

Creating it under a client that had not set `QUOTED_IDENTIFIER ON` failed with `Msg 1934`, naming
`QUOTED_IDENTIFIER` directly. Drivers set it; a command line client may not.

## The json type

```sql
CREATE TABLE dbo.doc (id INT IDENTITY PRIMARY KEY, payload JSON NULL);
```

`sys.columns` reports type `json` with `max_length` of `-1`.

```text
CREATE INDEX ix_doc ON dbo.doc (payload);
Msg 1978  ... invalid for use as a key column in an index or statistics.

SELECT COUNT(*) FROM dbo.doc WHERE payload = N'{"tenant":"acme","n":1}';
Msg 402   The data types json and nvarchar are incompatible in the equal to operator.
```

The promotion pattern, both statements clean:

```sql
ALTER TABLE dbo.doc ADD tenant AS CAST(JSON_VALUE(payload, '$.tenant') AS NVARCHAR(64)) PERSISTED;
CREATE INDEX ix_doc_tenant ON dbo.doc (tenant);
CREATE INDEX ix_doc_inc    ON dbo.doc (tenant) INCLUDE (payload);   -- json as an included column
```

Microsoft Learn adds that the type is generally available on Azure SQL Database, is available under
**all** database compatibility levels, stores up to 2 GB, and permits a `json` column as an
included column and in the `WHERE` clause of a filtered index. Read the
[json data type](https://learn.microsoft.com/sql/t-sql/data-types/json-data-type) page for the full
size table rather than copying it here.

## The vector type

```text
CREATE TABLE dbo.emb3 (v VECTOR(1999));
Msg 2717  The size (1999) given to the column 'v' exceeds the maximum allowed (1998).
```

`VECTOR(1998)` was accepted. `sys.columns` reports `max_length` 6152 for a `VECTOR(1536)`, which is
`1536 * 4 + 8`. A table carrying a `VECTOR(1536)` beside two `NVARCHAR(1000)` columns allocated a
`ROW_OVERFLOW_DATA` unit, so the vector is pushed off-row once the row is wide.

## Boundaries

```text
ALTER TABLE dbo.local_child ADD CONSTRAINT fk_x FOREIGN KEY (parent_id)
  REFERENCES otherdb.dbo.some_parent (id);
Msg 40515, Level 15, State 1, Server SQL Azure, Line 16
Reference to database and/or server name in 'otherdb.dbo.some_parent' is not supported
in this version of SQL Server.
```

Both databases existed on the same container, so this is the database boundary being enforced and
not a missing object.

```sql
SELECT name, type_desc FROM sys.filegroups;   -- PRIMARY, ROWS_FILEGROUP. One row.
CREATE PARTITION SCHEME ps  AS PARTITION pf TO ([PRIMARY], [SECONDARY]);  -- Msg 208, invalid object name 'SECONDARY'
CREATE PARTITION SCHEME ps2 AS PARTITION pf ALL TO ([PRIMARY]);           -- succeeds
```

A table with no clustered index was created and accepted rows, so a heap is permitted. The belief
that this engine requires a clustered index on every table is out of date.

## What did not hold

Recorded so the next author does not re-derive it.

- **The catalog note said "identity against sequences" as though the choice were a style
  preference.** It is not. The measured gap is 999 for `INT` and 9999 for `BIGINT`, and a default
  `SEQUENCE` gapped by 49, so a sequence is only the safer choice when it is declared `NO CACHE`.
  A sequence with the default cache is no better than an identity column.
- **`ALTER DATABASE ... COLLATE` reads like a fix and is not one.** It was expected either to fail
  or to work. It did neither: it succeeded and changed nothing that mattered, which is the worse of
  the two outcomes.
- **`DATABASEPROPERTYEX(db, 'CatalogCollation')` returned `NULL`** on this container rather than a
  collation name, so no claim about catalog collation is made in `SKILL.md`.
- **`ALTER DATABASE ... SET COMPATIBILITY_LEVEL = 150` did not take effect** on this container: the
  database stayed at 170. Any claim tying a type to a compatibility level should be taken from
  Microsoft Learn rather than measured here.
