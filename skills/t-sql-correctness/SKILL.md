---
name: t-sql-correctness
description: >-
  Writes T-SQL that returns the right answer on Azure SQL Database, and catches the statements that
  return a wrong answer with no error at all: NULL compared using = or <> or NOT IN, ISNULL and
  COALESCE differing in return type, integer division truncating, a string variable declared with
  no length, and a session where QUOTED_IDENTIFIER is OFF. Also corrects PostgreSQL and MySQL habit
  (LIMIT, RETURNING, SERIAL, ILIKE, NOW(), true, false, double-quoted string literals, TEXT
  columns, ON CONFLICT, USE) and the opposite mistake of avoiding syntax the engine has supported
  since 2025. Use when writing, porting or reviewing SQL for Azure SQL Database or the local
  container, and for "why is that row missing", "why did NOT IN return nothing", "why is this
  average wrong", "how do I paginate", "how do I get the id I just inserted", "is this comparison
  case sensitive". Upserts belong to t-sql-upserts-merge, JSON to t-sql-json-and-openjson, and
  column, index and collation design to design-azure-sql-schema.
---

# Write T-SQL that returns the right answer

Three failures. **The silent one first**, because nothing raises it: the statement succeeds, the
row count looks plausible, the answer is wrong. Then **PostgreSQL habit**, which at least fails
loudly. Then **overcorrection**, hand-rolling what the engine now does natively.

Checked against Microsoft Learn and sqlcmd 1.10.0, 2026-09-03.

## Wrong answers that raise no error

**Nothing equals NULL, and nothing is unequal to it either.** `ANSI_NULLS` is permanently `ON`
and `SET ANSI_NULLS OFF` is deprecated, so every comparison against `NULL` is `UNKNOWN`, and
`WHERE` keeps only the rows that are `TRUE`.

```sql
CREATE TABLE dbo.orders (id INT, status NVARCHAR(20) NULL);
INSERT INTO dbo.orders VALUES (1, N'shipped'), (2, N'held'), (3, NULL);

DECLARE @p NVARCHAR(20) = NULL;
SELECT COUNT(*) FROM dbo.orders WHERE status = @p;          -- 0, not 1
SELECT COUNT(*) FROM dbo.orders WHERE status <> N'shipped'; -- 1, not 2

-- Null-safe equality, true or false and never unknown:
SELECT COUNT(*) FROM dbo.orders WHERE status IS NOT DISTINCT FROM @p;  -- 1
```

The second line reaches production: "everything not shipped" drops every row whose status is
unknown.

**`NOT IN` over a nullable column returns nothing at all.** One `NULL` in the subquery makes the
predicate `UNKNOWN` for every candidate row, so the answer is empty rather than short by one.

```sql
CREATE TABLE dbo.assigned (customer_id INT NULL);
INSERT INTO dbo.assigned VALUES (1), (NULL);
CREATE TABLE dbo.customers (id INT NOT NULL);
INSERT INTO dbo.customers VALUES (1), (2), (3);

SELECT COUNT(*) FROM dbo.customers c
WHERE c.id NOT IN (SELECT customer_id FROM dbo.assigned);   -- 0

-- NOT EXISTS is the fix, and the habit worth defaulting to:
SELECT COUNT(*) FROM dbo.customers c
WHERE NOT EXISTS (SELECT 1 FROM dbo.assigned a WHERE a.customer_id = c.id);  -- 2
```

**Aggregates skip nulls, and say nothing about it.** Measured 2026-09-03 on `EngineEdition` 5
through the **ODBC `sqlcmd`** at `-I -m-1`, the build that does print a severity 10 message's `Msg`
number: this batch returns 30 and **no message at all**. Which build was used is the whole weight of
that sentence, because go-sqlcmd 1.10.0 prints no `Msg` header on a severity 10 message at any `-m`
value, so a silent run there would prove nothing. Message 8153, "Null value is eliminated by an
aggregate", is in `sys.messages` at severity 10 and was never raised. Microsoft Learn's
`SET ANSI_WARNINGS` page says a warning is generated. It is not, so do not plan on being told.

```sql
CREATE TABLE dbo.readings (v INT NULL);
INSERT INTO dbo.readings VALUES (10), (NULL), (20);
SET ANSI_WARNINGS ON;  -- makes no difference here
SELECT SUM(v), COUNT(*), COUNT(v), AVG(v) FROM dbo.readings;  -- 30, 3, 2, 15
```

`AVG` divides by 2, not 3, and `COUNT(v)` disagrees with `COUNT(*)` for the same reason. If the
intent was 10, write `AVG(ISNULL(v, 0))` and mean it.

**Integer division truncates, and `ISNULL` truncates its own replacement.** `/` returns the
higher-precedence operand's type, and two integers give an integer. `ISNULL` returns the type of
its **first** argument and converts the second into it; `COALESCE` returns the highest-precedence
type of all of them.

```sql
SELECT 7 / 2, CAST(7.0 / 2 AS DECIMAL(4,1));  -- 3 and 3.5

DECLARE @short NVARCHAR(3) = NULL;
SELECT ISNULL(@short, N'abcdef'), COALESCE(@short, N'abcdef');  -- abc and abcdef
```

`ISNULL` also reports its result as not nullable where `COALESCE` reports nullable, so a computed
column that must come out `NOT NULL` needs `ISNULL`.

**A string with no length is one character, except in a cast, where it is thirty.** Assigning to
an undersized variable truncates in silence; only an undersized column refuses.

```sql
DECLARE @v NVARCHAR = N'abcdef';
SELECT @v, LEN(CAST(REPLICATE(CAST(N'a' AS NVARCHAR(MAX)), 40) AS NVARCHAR));  -- a and 30
```

Always give a length. The inner cast is there because `REPLICATE` otherwise returns
`nvarchar(4000)`.

## Session settings change what a statement means

`QUOTED_IDENTIFIER` is decided at parse time, so the same text is two different statements:

```sql
SET QUOTED_IDENTIFIER OFF;
SELECT "not a column";   -- returns the string, one row
SET QUOTED_IDENTIFIER ON;
SELECT "not a column";   -- Msg 207, invalid column name
```

`ON` is the default and the ODBC and OLE DB drivers set it on connect, so application code sees
`ON`. The container's own `sqlcmd` leaves it **OFF**, so a script behaves one way in a container
shell and another way run by the app. Pass `-I` to settle it.

## PostgreSQL habit, translated

| It will write | It must write | Because |
|---|---|---|
| `LIMIT 10 OFFSET 20` | `ORDER BY id OFFSET 20 ROWS FETCH NEXT 10 ROWS ONLY` | `OFFSET` and `FETCH` are clauses **of** `ORDER BY`; `FETCH` without `OFFSET` is invalid |
| `RETURNING id` | `OUTPUT INSERTED.id` | Read the trigger rule below before shipping it |
| `id SERIAL PRIMARY KEY` | `id INT IDENTITY(1,1) PRIMARY KEY` | Or a `SEQUENCE` when the generator is shared |
| `is_active = true`, `WHERE is_active` | `is_active = 1` | No Boolean type. `bit` is an integer, and a value rather than a predicate |
| `NOW()` | `SYSDATETIME()`, or `SYSUTCDATETIME()` | `CURRENT_TIMESTAMP` also works and is ANSI |
| `name ILIKE 'ana%'` | `name LIKE 'ana%'` | The default collation `SQL_Latin1_General_CP1_CI_AS` is already case-insensitive |
| `WHERE name = "ana"` | `WHERE name = 'ana'` | Escape a quote by doubling it, `'it''s'`, and prefix Unicode with `N` |
| `bio TEXT` | `bio NVARCHAR(MAX)` | `text` and `ntext` are deprecated and barred from several operators |
| `ON CONFLICT DO UPDATE` | See `t-sql-upserts-merge` | That skill owns upserts, including when not to use `MERGE` |
| `USE otherdb;` | Open a new connection | Unsupported, along with cross-database three and four part names |

`USE` is the trap that survives review: it **works on the container** and fails in the cloud. Open [references/postgres-to-tsql.md](references/postgres-to-tsql.md) before porting a
schema or a query file, and when a statement crosses a database boundary.

`TOP` and `OFFSET FETCH` cannot be combined in one query expression, and a stable page needs a
**unique** sort key: `ORDER BY placed_at DESC, order_id DESC`.

A bare `OUTPUT` fails with `Msg 334` when the target has an enabled trigger for that action, so
capture into a table variable:

```sql
CREATE TABLE dbo.new_orders (order_id INT IDENTITY PRIMARY KEY, total DECIMAL(9,2));
DECLARE @new TABLE (order_id INT);
INSERT INTO dbo.new_orders (total)
OUTPUT INSERTED.order_id INTO @new
VALUES (19.99);
SELECT order_id FROM @new;
```

The `INTO` target has its own limits: no enabled triggers, neither side of a foreign key
(`Msg 332`), no enabled `CHECK` constraints or rules (`Msg 333`), and no guaranteed row order.
Prefer `OUTPUT` to `SCOPE_IDENTITY()`: it returns every row of a multi-row insert, and works on
`UPDATE`, `DELETE` and `MERGE`.

## Do not avoid these. They work

| Available | Note |
|---|---|
| `a \|\| b` and `\|\|=`, `UNISTR` | Generally available July 2025. Unlike `CONCAT`, `\|\|` yields `NULL` if any input is `NULL` |
| Regular expression functions | Generally available November 2025. Route to `t-sql-regex-and-new-functions` |
| `STRING_AGG(x, ',') WITHIN GROUP (ORDER BY x)` | Any compatibility level, but returns `nvarchar(4000)` for `nvarchar(1..4000)` input, so cast to `max` or lose the tail |
| `TRIM(BOTH '.' FROM s)` | The positional keywords need a recent compatibility level; below it they are a **parse** error |
| `GREATEST(a, b, c)`, `LEAST(...)` | Nulls ignored unless every argument is null |
| `a IS NOT DISTINCT FROM b` | Null-safe equality, as above |

A migrated database can sit at an old compatibility level, where the failure looks exactly like
the function not existing: `Msg 102`, `Msg 195` or `Msg 208` at level 150. Check the level before
believing the error. See `post-migration-compatibility-level`.

## Check it worked

Save this as `check-correctness.sql`. The exit code proves nothing here: every statement
succeeds.

```sql
-- 1. The session your script was actually parsed and run under.
SELECT IIF((256 & @@OPTIONS) = 256, 'ON', 'OFF') AS quoted_identifier,
       IIF((32  & @@OPTIONS) = 32,  'ON', 'OFF') AS ansi_nulls,
       IIF((8   & @@OPTIONS) = 8,   'ON', 'OFF') AS ansi_warnings;

-- 2. String columns declared with no length: they hold one character.
SELECT OBJECT_NAME(object_id) AS t, name AS c FROM sys.columns
WHERE system_type_id IN (231, 239, 167, 175) AND max_length <= 2;
```

```bash
sqlcmd -S <server-name>.database.windows.net,1433 -d <database> -U <user> -C -I -b -m-1 \
  -i check-correctness.sql -o check-correctness.out
```

Expected: check 1 returns `ON ON ON`, check 2 no rows. An `OFF` means your script was
parsed under different rules from the ones the application connects with. `-m-1` is there because
`-b` sets a non-zero exit only at severity 11 and above, so any severity 10 message leaves a
script reporting success.

**`-m-1` is an ODBC `sqlcmd` instruction**, meaning the 18.x build from `mssql-tools18` or the
Microsoft command line utilities. Measured 2026-09-05, go-sqlcmd 1.10.0, the 1.x build
`brew install sqlcmd` and `winget install sqlcmd` install, prints no `Msg` header on a severity 10
message at any `-m` value, so on that build a quiet output file is not evidence that the engine
stayed quiet. `build-app-on-azure-sql` tells the two builds apart in one table.

## Do not

- Do not compare with `= NULL` or `<> NULL`, and do not "fix" it by turning `ANSI_NULLS` off.
  That setting is deprecated and permanently `ON`.
- Do not use `NOT IN` against a subquery over a nullable column. Use `NOT EXISTS`.
- Do not swap `ISNULL` for `COALESCE` as a cosmetic edit. The return type differs, so the value
  can change.
- Do not translate `ILIKE` into `LOWER(col) = LOWER(@v)`. It fixes nothing on a case-insensitive
  collation and costs the index seek.
- Do not size, collate or index columns here. `design-azure-sql-schema` owns that, including why
  a `json` column compared with `=` fails with `Msg 402`.
- Do not put error handling here. `t-sql-error-handling` owns `TRY`, `CATCH` and
  `XACT_ABORT`, and `t-sql-programmability-objects` owns triggers.

## References

- [references/postgres-to-tsql.md](references/postgres-to-tsql.md): open it when porting a schema
  or a query file, when a statement crosses a database boundary, or to find the Microsoft Learn
  page behind a row in the table above.
