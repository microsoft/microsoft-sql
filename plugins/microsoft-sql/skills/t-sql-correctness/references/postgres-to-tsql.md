# PostgreSQL and MySQL habits, translated for Azure SQL Database

Checked against Microsoft Learn on 2026-08-27. Where a claim is version-dependent, the date it
became true is given, because that is the part most likely to be out of date in training data.

## Contents

- [How to use this file](#how-to-use-this-file)
- [Statements and clauses](#statements-and-clauses)
  - [The local container is the exception](#the-local-container-is-the-exception)
- [Operators and expressions](#operators-and-expressions)
- [Data types](#data-types)
- [Things that changed recently](#things-that-changed-recently)
- [Things that are still not there](#things-that-are-still-not-there)
- [Sources](#sources)

## How to use this file

Read the left column as the thing about to be written and the right column as the replacement.
Where a row has a note, the note is the part that bites after the substitution compiles.

Two rows deliberately have no answer here, because another skill owns them: upserts go to
`t-sql-upserts-merge`, and anything JSON goes to `t-sql-json-and-openjson`.

## Statements and clauses

| Elsewhere | Azure SQL Database | Note |
|---|---|---|
| `LIMIT n` | `ORDER BY <col> OFFSET 0 ROWS FETCH NEXT n ROWS ONLY`, or `TOP (n)` | `OFFSET` and `FETCH` are part of the `ORDER BY` clause, so a sort is mandatory |
| `LIMIT n OFFSET m` | `ORDER BY <col> OFFSET m ROWS FETCH NEXT n ROWS ONLY` | `OFFSET` is required and `FETCH` is optional, never the other way round |
| `LIMIT` inside a view or subquery | `TOP` or `OFFSET FETCH` | `ORDER BY` is otherwise invalid in views, inline functions, derived tables and subqueries |
| `RETURNING <cols>` | `OUTPUT INSERTED.<cols>` | Without `INTO`, the target cannot have an enabled trigger for that action |
| `RETURNING` on delete | `OUTPUT DELETED.<cols>` | `INSERTED` is unavailable on `DELETE`, `DELETED` on `INSERT` |
| `ON CONFLICT ... DO UPDATE` | See `t-sql-upserts-merge` | |
| `CREATE TABLE IF NOT EXISTS` | `IF OBJECT_ID(N'dbo.t', N'U') IS NULL BEGIN CREATE TABLE ... END` | `CREATE TABLE` has no `IF NOT EXISTS` clause. `DROP TABLE IF EXISTS` does exist, and `CREATE OR ALTER` exists for modules, not tables |
| `USE otherdb;` | Open a new connection to that database | Unsupported in Azure SQL Database. Cross-database three and four part names are unsupported too, except `tempdb` and the current database. **All of this works on the local Azure SQL Database container**, so a local run will not warn you. See [the local container is the exception](#the-local-container-is-the-exception) |
| `SELECT ... FOR UPDATE` | `SELECT ... WITH (UPDLOCK, ROWLOCK)` | A hint, not a clause |
| `ORDER BY x NULLS LAST` | `ORDER BY CASE WHEN x IS NULL THEN 1 ELSE 0 END, x` | There is no `NULLS FIRST` or `NULLS LAST`. Nulls sort as the lowest value |
| `DISTINCT ON (col)` | `ROW_NUMBER() OVER (PARTITION BY col ORDER BY ...)` filtered to 1 | |
| `information_schema` views | They exist, but `sys.` catalog views carry more | Prefer `sys.objects`, `sys.columns`, `sys.indexes` |

### The local container is the exception

This is the one row on the page where the local Azure SQL Database container and Azure SQL Database
in the cloud genuinely differ, and it differs in the direction that hurts. Measured against the
container: `USE appdb` returns `Changed database context to 'appdb'`, and `SELECT ... FROM
appdb.sys.objects` issued from `master` succeeds. Both fail against Azure SQL Database, where each
database is its own boundary.

The container is a single engine hosting several databases, so it accepts both. A query that
crosses a database boundary therefore passes locally, ships, and fails in the cloud with nothing in
the local run to warn you. Test anything that crosses a database boundary against Azure SQL
Database, or do not write it.

## Operators and expressions

| Elsewhere | Azure SQL Database | Note |
|---|---|---|
| `a \|\| b` | `a \|\| b` works, and so do `a + b` and `CONCAT(a, b)` | Generally available since July 2025. `\|\|` and `+` propagate `NULL`; `CONCAT` treats `NULL` as an empty string |
| `x ILIKE 'a%'` | `x LIKE 'a%'` | The default collation is already case-insensitive |
| `LOWER(x) = LOWER(@v)` | `x = @v` | Only add `COLLATE` when the sensitivity genuinely has to differ from the column's |
| `true` / `false` | `1` / `0` | `bit` is an integer type taking `1`, `0` or `NULL`. The strings `'TRUE'` and `'FALSE'` convert to `1` and `0` |
| `WHERE flag` | `WHERE flag = 1` | `bit` is a value, not a predicate |
| `a IS DISTINCT FROM b` | `a IS DISTINCT FROM b` | Supported. Guarantees true or false even when an operand is `NULL` |
| `COALESCE` chains to emulate null-safe equality | `IS NOT DISTINCT FROM` | |
| `GREATEST(a, b)` / `LEAST(a, b)` | Same names, supported | Up to 254 arguments. `NULL` arguments are ignored unless all are `NULL` |
| `NOW()` | `SYSDATETIME()` | `SYSUTCDATETIME()` for UTC, `CURRENT_TIMESTAMP` for the ANSI spelling |
| `EXTRACT(YEAR FROM d)` | `DATEPART(year, d)` | |
| `x::int` | `CAST(x AS int)` | `CONVERT` when a style code is needed |
| `SUBSTRING(s FROM 1 FOR 3)` | `SUBSTRING(s, 1, 3)` | |
| `string_agg(x, ',')` | `STRING_AGG(x, ',') WITHIN GROUP (ORDER BY x)` | Available at any compatibility level. Nulls are skipped along with their separator |
| `trim(both '.' from s)` | `TRIM(BOTH '.' FROM s)` | The positional keywords are the newer part of the function. The documentation attaches a compatibility level 160 requirement to them |
| `'it\'s'` | `'it''s'` | Escape a single quote by doubling it. There is no backslash escape |
| `"col"` as a string | `'col'` | Double quotes are identifiers while `QUOTED_IDENTIFIER` is `ON`, which is the default and what the drivers set |
| `$1`, `$2` parameters | `@name` parameters | The wire placeholder is the driver's business; the T-SQL name is `@`-prefixed |

## Data types

| Elsewhere | Use here | Note |
|---|---|---|
| `TEXT`, `VARCHAR` without length | `NVARCHAR(MAX)`, or `NVARCHAR(n)` when a bound is known | `text` and `ntext` are excluded from `ORDER BY` and from the `\|\|` operator, which is a good signal of where they are heading |
| `BOOLEAN` | `bit` | |
| `SERIAL`, `BIGSERIAL`, `GENERATED ALWAYS AS IDENTITY` | `INT IDENTITY(1,1)`, `BIGINT IDENTITY(1,1)` | A `SEQUENCE` when the generator must be shared across tables |
| `UUID` | `uniqueidentifier` | `NEWSEQUENTIALID()` as a default is friendlier to a clustered index than `NEWID()` |
| `BYTEA` | `varbinary(max)` | |
| `TIMESTAMP` | `datetime2` | Note that the T-SQL type named `timestamp` is a row version, not a time |
| `TIMESTAMPTZ` | `datetimeoffset` | |
| `NUMERIC(p,s)` | `decimal(p,s)` | |
| `DOUBLE PRECISION` | `float` | |
| `JSON`, `JSONB` | See `t-sql-json-and-openjson` | That skill owns the storage choice and the query surface |
| Array types | No equivalent. Model as a child table | A delimited string plus `STRING_SPLIT` is a workaround, not a design |

Two general notes. `nvarchar` stores UTF-16 and is the safe default for user text; a UTF-8 database
or column collation is available if byte size matters, and it applies to `char` and `varchar`, not
to `nchar` and `nvarchar`. And the character types have no implicit length: `NVARCHAR` written
without a length in a cast defaults to a single character in some contexts, so always give the
length.

## Things that changed recently

Anything here was different not long ago, so check rather than recall.

| What | Since | Detail |
|---|---|---|
| `\|\|` string concatenation and `\|\|=` compound assignment | July 2025 | ANSI concatenation. Excludes the `xml`, `json`, `image`, `ntext` and `text` types. Result over 8,000 bytes truncates unless one operand is a large value type |
| `UNISTR` for Unicode string literals | July 2025 | |
| Regular expression functions | November 2025 | Seven functions. Check the database compatibility level and current function-specific limits before use |
| `DATEADD` accepting a `bigint` number | November 2025 | |
| Vector data type and vector functions | June 2025 | Not this skill's subject, but a common source of "that cannot exist" |

## Things that are still not there

Verified absent, so an agent should stop looking rather than invent a spelling.

- `LIMIT` in any form.
- `CREATE TABLE ... IF NOT EXISTS`. Guard with `IF OBJECT_ID(...) IS NULL`.
- `USE` to switch database context, and cross-database queries by three or four part name. Absent
  in Azure SQL Database only. Both work on the local Azure SQL Database container, so this is the
  one entry on the list a local run will not confirm for you: test it against the cloud.
- A Boolean data type.
- `NULLS FIRST` and `NULLS LAST`.
- Array and composite column types.

## Sources

All Microsoft Learn, all read on 2026-08-27.

- T-SQL differences: `/azure/azure-sql/database/transact-sql-tsql-differences-sql-server`
  (`USE` unsupported, cross-database names, the unsupported statement list)
- ORDER BY clause: `/sql/t-sql/queries/select-order-by-clause-transact-sql` (`OFFSET FETCH` syntax,
  `TOP` cannot be combined with it, stable paging conditions, nulls sort lowest)
- OUTPUT clause: `/sql/t-sql/queries/output-clause-transact-sql` (the enabled-trigger restriction,
  the `INTO` target restrictions, `INSERTED` and `DELETED` availability)
- Double pipe operator: `/sql/t-sql/language-elements/string-concatenation-pipes-transact-sql`
  (applies to Azure SQL Database, null behaviour, truncation, excluded types)
- What is new in Azure SQL Database:
  `/azure/azure-sql/database/doc-changes-updates-release-notes-whats-new` (the general availability
  dates quoted above)
- CREATE DATABASE: `/sql/t-sql/statements/create-database-transact-sql` (the default collation
  `SQL_Latin1_General_CP1_CI_AS`, and `CATALOG_COLLATION` fixed at creation)
- Collation and Unicode support: `/sql/relational-databases/collations/collation-and-unicode-support`
  (per-database data and catalog collations, UTF-8 support)
- SET QUOTED_IDENTIFIER: `/sql/t-sql/statements/set-quoted-identifier-transact-sql` (`ON` is the
  default, double quotes delimit identifiers, brackets are unaffected)
- bit: `/sql/t-sql/data-types/bit-transact-sql`
- STRING_AGG: `/sql/t-sql/functions/string-agg-transact-sql` (return type table, nulls skipped, any
  compatibility level)
- TRIM: `/sql/t-sql/functions/trim-transact-sql`
- GREATEST: `/sql/t-sql/functions/logical-functions-greatest-transact-sql`
- IS [NOT] DISTINCT FROM: `/sql/t-sql/queries/is-distinct-from-transact-sql`
- CREATE TABLE: `/sql/t-sql/statements/create-table-transact-sql` (no `IF NOT EXISTS` in the syntax)
