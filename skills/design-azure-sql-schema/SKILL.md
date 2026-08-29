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
  ef-core-azure-sql, prisma-azure-sql and sqlalchemy-azure-sql own how each one expresses it,
  t-sql-correctness owns query syntax, and vector-search-azure-sql owns vector search.
license: MIT
---

# Design a schema Azure SQL Database will not make you rebuild

This is the set of schema decisions that Azure SQL Database punishes **later**, not at `CREATE
TABLE`. General modelling, normalisation and naming are not here, because they are the same
everywhere and the agent already does them.

Everything below was measured on 2026-08-28 against a live engine where
`SERVERPROPERTY('EngineEdition')` returns `5` and `Edition` is `SQL Azure`. The statements, the
plans and the byte counts are in [references/verified-behaviour.md](references/verified-behaviour.md).

## The shape of every failure on this page

| | |
|---|---|
| The DDL | succeeds, sometimes with a warning nobody reads |
| The migration | succeeds |
| The failure | arrives on a row, a plan or a failover, weeks later, in production |

That is why these five items are worth a skill and normalisation is not. **A syntax error costs
minutes. Each item here costs a table rebuild, a collation rebuild, or a duplicated key.**

## 1. The index key budget is in bytes, and Unicode spends two per character

The limits are **1700 bytes for a nonclustered index key and 900 bytes for a clustered one**, and
a composite key spends the **sum** of its columns.

`NVARCHAR(n)` costs `2n` bytes, so:

| Position | Widest safe Unicode column | Widest safe UTF-8 column |
|---|---|---|
| Nonclustered index or unique constraint | `NVARCHAR(850)` | `VARCHAR(1700)` |
| Clustered index or clustered primary key | `NVARCHAR(450)` | `VARCHAR(900)` |
| Anything not in a key | unbounded | unbounded |

`NVARCHAR(450)` is the width an indexed string is narrowed to by EF Core, and that choice is right:
it is the only length safe in **every** index position, clustered included.

### What over-shooting actually does

Creating a unique index on `NVARCHAR(1000)`, which is 2000 bytes:

```text
Warning! The maximum key length for a nonclustered index is 1700 bytes.
The index 'ux_acct_email' has maximum length of 2000 bytes.
For some combination of large values, the insert/update operation will fail.
```

That is **message 1945 at severity 10**. It is a warning. The index exists, the migration reports
success, and every short value inserts fine. The failure waits for the first long row:

```text
Msg 1946, Level 16, State 3
Operation failed. The index entry of length 1800 bytes for the index 'ux_acct_email'
exceeds the maximum length of 1700 bytes for nonclustered indexes.
```

**Consequence of being wrong: a write path that has worked for months starts rejecting exactly the
rows that matter,** and the fix is an `ALTER COLUMN` plus an index rebuild on a live table.

Two more rules that come out of the same budget:

- **`INCLUDE` columns do not count against it.** A covering index can include `NVARCHAR(MAX)`.
  Verified.
- **A foreign key inherits the parent key's width, and the lengths must match exactly.** A
  mismatch is refused at create time with `Msg 1753`, so an oversized parent key propagates.
- `NVARCHAR(MAX)`, `json` and `vector` cannot be key columns at all (`Msg 1919`, `Msg 1978`).

How each mapper reaches these lengths, and its own default, is `ef-core-azure-sql`,
`prisma-azure-sql` and `sqlalchemy-azure-sql`.

## 2. Collation is chosen at CREATE DATABASE, and it decides two different things

A new database gets `SQL_Latin1_General_CP1_CI_AS` when none is stated. That single default
decides both of the following, and neither is obvious from the name.

### 2a. `CI` means identifiers are not unique the way the design assumes

```sql
INSERT INTO dbo.tokens (t) VALUES (N'aB1x');
INSERT INTO dbo.tokens (t) VALUES (N'Ab1X');
-- Msg 2627, Violation of PRIMARY KEY constraint. The duplicate key value is (Ab1X).
```

Under a case-sensitive collation both rows are accepted. **Consequence of being wrong: any column
holding a case-significant token, an API key, a slug, a short link code or a base64 identifier
collides at roughly the rate its alphabet implies**, and the collision surfaces as a user-visible
insert failure, not as data corruption you can find later.

The fix is per column, not per database:

```sql
code NVARCHAR(64) COLLATE Latin1_General_CS_AS NOT NULL
```

### 2b. The default is a *SQL* collation, which is where the seek is lost

Covered in section 3, because it is the expensive half.

### Where the decision is made

**State the collation in `CREATE DATABASE`, or accept the default deliberately.** There is no
server collation to inherit here, the database is the only place the decision is made, and
`ALTER DATABASE ... COLLATE` afterwards re-collates nothing that already exists. Measured output
for that statement is in
[references/verified-behaviour.md](references/verified-behaviour.md).

## 3. The implicit conversion that costs the seek

The common drivers bind a string parameter as Unicode by default, and one that does not is the
exception worth checking rather than the rule. Under the **default**
collation, comparing that parameter to a `VARCHAR` column converts the **column**, and a converted
column cannot be sought. Measured over 20,000 rows with a unique index on `email`:

| Column | Collation | Parameter | Plan | Logical reads |
|---|---|---|---|---|
| `VARCHAR(320)` | `SQL_Latin1_General_CP1_CI_AS` (the default) | `NVARCHAR` | **Index Scan** | **80** |
| `VARCHAR(320)` | `Latin1_General_CI_AS` | `NVARCHAR` | Index Seek | 2 |
| `VARCHAR(850)` | `Latin1_General_100_CI_AS_SC_UTF8` | `NVARCHAR` | Index Seek | 2 |
| `NVARCHAR(320)` | any | `NVARCHAR` | Index Seek | 2 |
| `VARCHAR(320)` | the default | `VARCHAR` | Index Seek | 2 |

The plan text for row one:

```text
|--Index Scan(OBJECT:([dbo].[users_v].[ux_v]),
     WHERE:(CONVERT_IMPLICIT(nvarchar(320),[dbo].[users_v].[email],0)=[@p]))
```

Row two seeks because a Windows collation lets the optimizer build a range with
`GetRangeThroughConvert`. **A SQL collation cannot, and the default is a SQL collation.**

**Consequence of being wrong: every lookup on that column reads the whole index instead of three
pages, forever, with no error and no warning.** The cost scales with the table, so it is invisible
in development and arrives as a gradual regression.

Two designs avoid it, and one of them has to be chosen up front:

1. **Use `NVARCHAR` for anything a driver will bind a string to.** This is the default advice and
   it is correct. It costs index key bytes, per section 1.
2. **Use a UTF-8 collation on `VARCHAR`** when the data is ASCII-dominant and the key is tight.
   `VARCHAR(1700)` then fits a nonclustered key where `NVARCHAR(850)` was the ceiling, and the seek
   survives because UTF-8 collations are Windows collations. The cost is that `VARCHAR(n)` counts
   **bytes**, so non-ASCII text stores fewer characters than the number suggests.

Do not mix. A table with `VARCHAR` under the default collation and an application that binds
Unicode is the exact combination that produces row one.

## 4. Identity gaps are routine here, and the remembered fix does not exist

An agent asked about identity gaps recalls trace flag 272. Run it here:

```text
Msg 40518, DBCC command 'traceon' is not supported in this version of SQL Server.
```

Measured across a single engine restart, which is what a planned failover looks like to the
database:

| Column | Last value before | First value after | Gap |
|---|---|---|---|
| `INT IDENTITY` | 3 | **1002** | 999 |
| `BIGINT IDENTITY` | 3 | **10002** | 9999 |
| `SEQUENCE`, default cache | 2 | **51** | 49 |
| `SEQUENCE ... NO CACHE` | 2 | 3 | none |
| `INT IDENTITY` with `IDENTITY_CACHE = OFF` | 3 | **4** | none |

Azure SQL Database reconfigures on its own schedule, so this is not a crash scenario. It is normal
operation.

**Consequence of being wrong: any number a human reads or a regulator counts, an invoice number, a
ticket number, an order reference, develops thousand-wide holes, and it is unrecoverable after the
fact.** Nothing errors. Nothing is logged.

The rules that follow:

- **A surrogate key may be `IDENTITY`.** Gaps in a key nobody reads are free, and the cache is why
  inserts are fast.
- **A number a person reads is not a surrogate key.** Give it its own `SEQUENCE ... NO CACHE`, or
  generate it in a transaction against a counter table, and pay the contention on purpose.
- **The database-wide lever is** `ALTER DATABASE SCOPED CONFIGURATION SET IDENTITY_CACHE = OFF;`.
  It removes the gap for every identity column and costs a log write per value. Verified: it
  survives a restart, and after it the sequence went 3, 4.
- **`SEQUENCE` with no `START WITH` starts at the minimum 64-bit integer**, not at 1. Verified: the
  first value returned was `-9223372036854775808`. Always state `START WITH 1`.

## 5. A unique index accepts exactly one NULL

This is the one that arrives from PostgreSQL habit, where every NULL is distinct.

```text
Msg 2601, Cannot insert duplicate key row in object 'dbo.nulltest'
with unique index 'ux_code'. The duplicate key value is (<NULL>).
```

`Msg 2627` where the constraint is a unique constraint rather than an index. **Consequence of being
wrong: an optional unique field, an external account id, a nullable slug, a soft-delete-aware
code, works for the first row that leaves it empty and rejects the second.** A model with two or
three optional unique fields is unusable here and correct on other engines.

The fix is a filtered unique index:

```sql
CREATE UNIQUE INDEX ux_code ON dbo.accounts (code) WHERE code IS NOT NULL;
```

Verified to accept many NULL rows. The session creating it, and every session writing to the table,
needs `QUOTED_IDENTIFIER ON`; the drivers set it, and a script run through a command line client
may not.

## 6. Where the json and vector types belong

Both are storage decisions, not key decisions.

| | `json` | `vector(n)` |
|---|---|---|
| Index key column | no, `Msg 1978` | no, `Msg 1978` |
| Primary key | no | no, `Msg 1919` |
| `INCLUDE` column | yes, verified | route to `vector-search-azure-sql` |
| Compared with `=` | no, `Msg 402` against `nvarchar` | route to `vector-search-azure-sql` |
| Ceiling | 2 GB, 32K unique keys | 1998 dimensions, `Msg 2717` above it |

- **A `json` column is not a filter.** To filter or join on a value inside it, promote that value to
  a `PERSISTED` computed column and index that. Verified working:

  ```sql
  ALTER TABLE dbo.doc ADD tenant AS CAST(JSON_VALUE(payload, '$.tenant') AS NVARCHAR(64)) PERSISTED;
  CREATE INDEX ix_doc_tenant ON dbo.doc (tenant);
  ```

  Anything a query filters on **every time** belongs in a real column, not in the document. The
  query surface, `OPENJSON` with an explicit schema and the JSON index story, is
  `t-sql-json-and-openjson`.
- **A `vector` column is a payload beside the key, never part of it.** A `vector(1536)` occupies
  6152 bytes of the 8060-byte row, so it pushes a wide row off-row: keep the table narrow and put
  the embedding next to an integer key. Dimension choice, distance functions, indexing and the
  restriction list are `vector-search-azure-sql`.

## 7. Two boundaries a design cannot cross here

- **A foreign key cannot reference another database.**
  `Msg 40515, Reference to database and/or server name in 'otherdb.dbo.some_parent' is not
  supported in this version of SQL Server.` A shared-lookup-database design has no referential
  integrity here, so either fold the lookup into the same database or accept that the constraint
  lives in application code.
- **There is one filegroup.** `sys.filegroups` returns `PRIMARY` and nothing else, so a partition
  scheme must map `ALL TO ([PRIMARY])`. Partitioning here buys manageability, never storage
  separation.

Whether a change to any of this is safe to apply to a live database is `schema-migrations-safely`,
and the declarative alternative is `sql-database-projects`. Creating the database itself, including
naming its collation, is `provision-azure-sql-db`.

## Validation rules

- Every string column in an index key, a unique constraint or a foreign key has an explicit length,
  and the key's total is at or under 1700 bytes nonclustered, 900 bytes clustered.
- No `CREATE INDEX` or `CREATE TABLE` in the migration output produced message 1945.
- The database collation is stated in `CREATE DATABASE`, or a note records that the default was
  chosen deliberately.
- Every column holding a case-significant token, key or code carries an explicit case-sensitive
  collation.
- No table mixes `VARCHAR` under a SQL collation with an application that binds Unicode parameters.
- Every human-facing sequential number comes from `SEQUENCE ... NO CACHE` or a counter table, never
  from a bare `IDENTITY`.
- Every `CREATE SEQUENCE` states `START WITH`.
- Every nullable unique column uses a filtered unique index, or the design accepts one NULL row.
- No `json` or `vector` column appears in a key, a `GROUP BY`, a `DISTINCT` or an equality
  predicate.
- Every value a query filters on repeatedly is a real column or a `PERSISTED` computed column, not
  a path into a document.
- No foreign key names another database.

## Do not

- Do not read message 1945 as informational. It is the only notice given, and the failure it
  predicts is `Msg 1946` on a production insert.
- Do not size a key column in characters. The limit is bytes, and Unicode doubles it.
- Do not use `VARCHAR` under the default collation for anything an application looks up by value.
  The lookup scans, silently, forever.
- Do not add `LOWER()` or `UPPER()` around a column to fix a collation problem. That is
  `t-sql-correctness`, and it costs the index too.
- Do not reach for trace flag 272. It is rejected with `Msg 40518`. The lever is
  `IDENTITY_CACHE = OFF`.
- Do not put an invoice number, a ticket number or anything a person or an auditor reads on a bare
  `IDENTITY`. A failover puts a thousand-wide hole in it and reports nothing.
- Do not create a `SEQUENCE` without `START WITH`. It starts at the minimum 64-bit integer.
- Do not give a model two or three optional unique columns and expect PostgreSQL NULL semantics.
- Do not store a value in a `json` document and then filter on it. Promote it.
- Do not teach vector search here, or the mapper-side type configuration. Those belong to
  `vector-search-azure-sql` and to the three mapper skills.

## References

- [references/verified-behaviour.md](references/verified-behaviour.md): every statement run, the
  exact server output, the two query plans, and how to reproduce all of it against a live engine.
  Read it when a claim above needs a source, or before changing a number in this file.
- [Maximum capacity specifications](https://learn.microsoft.com/sql/sql-server/maximum-capacity-specifications-for-sql-server):
  the index key size limits and the column counts. Read it before designing a wide composite key.
- [Collation and Unicode support](https://learn.microsoft.com/sql/relational-databases/collations/collation-and-unicode-support):
  SQL collations against Windows collations, UTF-8 collations, and what a collation actually
  governs. Read it before choosing a database collation.
- [json data type](https://learn.microsoft.com/sql/t-sql/data-types/json-data-type): availability,
  the index restrictions, and the size limits. Read it before putting a document in a column.
- [Database scoped configurations](https://learn.microsoft.com/sql/t-sql/statements/alter-database-scoped-configuration-transact-sql):
  `IDENTITY_CACHE` and the rest of the per-database levers.
- `ef-core-azure-sql`, `prisma-azure-sql`, `sqlalchemy-azure-sql`: how each mapper expresses the
  rules on this page, and the default each one lands on.
- `t-sql-correctness`: query-level correctness, and the PostgreSQL-to-T-SQL translation.
- `t-sql-json-and-openjson`: querying a document column once it exists.
- `vector-search-azure-sql`: the vector type, distance functions and vector indexing.
- `schema-migrations-safely` and `sql-database-projects`: applying a change to this schema safely.
- `provision-azure-sql-db`: creating the database, including its collation.
