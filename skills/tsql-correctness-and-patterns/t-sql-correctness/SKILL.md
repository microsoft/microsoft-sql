---
name: t-sql-correctness
description: >-
  Writes T-SQL that is correct on Azure SQL Database rather than PostgreSQL or MySQL syntax wearing
  a T-SQL name, and stops the opposite mistake of avoiding syntax the engine has supported since
  2025. Use when writing, porting or reviewing any SQL for Azure SQL Database or the local
  container, and when someone writes LIMIT, RETURNING, SERIAL, ILIKE, NOW(), true or false,
  double-quoted string literals, TEXT columns, ON CONFLICT or USE, or asks "how do I paginate",
  "how do I get the id I just inserted", "is this comparison case sensitive", or "does Azure SQL
  support the double pipe operator". Covers pagination with OFFSET and FETCH, OUTPUT and its
  trigger restriction, IDENTITY, the bit type, collation as the case-sensitivity control, and
  identifier quoting. Upserts belong to t-sql-upserts-merge and JSON to t-sql-json-and-openjson.
license: MIT
---

# Write T-SQL that is correct on Azure SQL Database

Two failures, opposite directions. **The first is PostgreSQL habit**: `LIMIT`, `RETURNING`,
`SERIAL`, `true`. **The second is overcorrection**: told the target is T-SQL, an agent falls back
to syntax from a decade ago and hand-rolls things the engine now does natively.

Verified against Microsoft Learn on 2026-08-27. The full translation table, with sources, is in
[references/postgres-to-tsql.md](references/postgres-to-tsql.md).

## What an agent writes here, and what it must write instead

| It will write | It must write | Because |
|---|---|---|
| `LIMIT 10` | `ORDER BY id OFFSET 0 ROWS FETCH NEXT 10 ROWS ONLY` | `OFFSET` and `FETCH` are clauses **of** `ORDER BY`, so the sort is not optional |
| `LIMIT 10 OFFSET 20` | `ORDER BY id OFFSET 20 ROWS FETCH NEXT 10 ROWS ONLY` | Offset first, then fetch. `FETCH` without `OFFSET` is not valid |
| `RETURNING id` | `OUTPUT INSERTED.id` | And read the trigger rule below before shipping it |
| `id SERIAL PRIMARY KEY` | `id INT IDENTITY(1,1) PRIMARY KEY` | Or a `SEQUENCE` when the value must be shared across tables |
| `is_active = true` | `is_active = 1` | There is no Boolean type. `bit` is an integer type taking `1`, `0` or `NULL` |
| `WHERE is_active` | `WHERE is_active = 1` | A `bit` column is a value, not a predicate |
| `NOW()` | `SYSDATETIME()`, or `SYSUTCDATETIME()` for UTC | `CURRENT_TIMESTAMP` also works and is ANSI |
| `name ILIKE 'ana%'` | `name LIKE 'ana%'` | Case sensitivity is a **collation** property, not an operator. See below |
| `WHERE name = "ana"` | `WHERE name = 'ana'` | Double quotes delimit **identifiers**, not strings |
| `bio TEXT` | `bio NVARCHAR(MAX)` | `text` and `ntext` are deprecated and excluded from several operators |
| `ON CONFLICT DO UPDATE` | See `t-sql-upserts-merge` | That skill owns upserts, including when not to use `MERGE` |
| `USE otherdb;` | Open a new connection to that database | Documented as unsupported: to change database context, connect again |

`USE` failing is the one that surprises people most, and it has a second half: cross-database and
cross-instance queries with three or four part names are not supported either, except three part
names for `tempdb` and the current database.

## Pagination has two more rules than the substitution

```sql
SELECT order_id, placed_at
FROM dbo.orders
ORDER BY placed_at DESC, order_id DESC   -- a tiebreaker, so pages do not overlap
OFFSET @skip ROWS FETCH NEXT @take ROWS ONLY;
```

- **`TOP` and `OFFSET FETCH` cannot be combined in the same query expression.** Pick one.
- **Stable paging needs a unique sort key**, and every page read in one snapshot or serializable
  transaction. Without both, rows move between pages while the user is reading them. Documented,
  not folklore: each page is an independent query, and the client holds the state.

`TOP (n)` is still the right answer for "give me a few rows"; `OFFSET FETCH` is the right answer
for paging. `TOP` without `ORDER BY` returns an arbitrary set, and the documentation says to always
pair them.

## OUTPUT is not quite RETURNING

```sql
INSERT INTO dbo.orders (customer_id, total)
OUTPUT INSERTED.order_id, INSERTED.placed_at
VALUES (@customer_id, @total);
```

Three things `RETURNING` does not make you think about:

1. **A bare `OUTPUT` fails on a table with a trigger.** If `OUTPUT` is used without `INTO`, the
   target of the DML statement cannot have an enabled trigger for that action. Capture into a table
   variable instead, and read the rows back:

   ```sql
   DECLARE @new TABLE (order_id INT);
   INSERT INTO dbo.orders (customer_id, total)
   OUTPUT INSERTED.order_id INTO @new
   VALUES (@customer_id, @total);
   SELECT order_id FROM @new;
   ```

2. **The `INTO` target has its own restrictions.** It cannot have enabled triggers, cannot sit on
   either side of a foreign key, and cannot carry `CHECK` constraints or enabled rules.
3. **Order is not guaranteed.** The order rows are applied and the order they land in the output
   target need not match.

Prefer `OUTPUT` over `SCOPE_IDENTITY()`: it returns every row of a multi-row insert, and it works
for `UPDATE`, `DELETE` and `MERGE` as well. `DELETED` is unavailable on `INSERT`, and `INSERTED` is
unavailable on `DELETE`.

## Case sensitivity is collation, and the default is already insensitive

A new database in Azure SQL Database gets `SQL_Latin1_General_CP1_CI_AS` when no collation is
given. `CI` is case-insensitive and `AS` is accent-sensitive, so `WHERE name = 'ana'` already
matches `Ana`, and `ILIKE` has nothing to translate to.

That makes the overcorrection the real risk. Wrapping the column in `LOWER()` to force something
the database already does makes the predicate non-sargable and gives up the index. If one query
genuinely needs a different sensitivity, ask for it at the point of comparison:

```sql
WHERE name = 'ana' COLLATE Latin1_General_CS_AS
```

Two things worth carrying: the **catalog** collation, which governs object identifiers, is fixed at
creation and cannot be changed afterwards; and a database created with a case-sensitive collation
means the column and alias names in every query become case-sensitive too.

## Quoting, and why brackets are the safe habit

`QUOTED_IDENTIFIER` is `ON` by default, and the client drivers set it `ON` when they connect. With
it on, **double quotes delimit identifiers and single quotes delimit literals**, so a
double-quoted string is read as an object name and fails as one.

- String literals: single quotes, and an embedded quote is escaped by **doubling** it,
  `'it''s'`. There is no backslash escape.
- Unicode literals: prefix with `N`, as `N'ana'`. Without it the literal is non-Unicode first.
- Identifiers: `[order]` is the T-SQL idiom and brackets are unaffected by `QUOTED_IDENTIFIER`.

## Do not avoid these. They work

This is the half most reviewers miss, because the training data predates them.

| Available | Note |
|---|---|
| `a || b` string concatenation, and `||=` | Generally available since July 2025. It is ANSI, and unlike `CONCAT` it yields `NULL` if any input is `NULL` |
| `UNISTR` for Unicode literals | Generally available since July 2025 |
| Regular expression functions | Generally available since November 2025. Three of them need a compatibility level check first, so route to `t-sql-regex-and-new-functions` |
| `STRING_AGG(x, ',') WITHIN GROUP (ORDER BY x)` | Available at any compatibility level. Nulls are skipped, and the separator with them |
| `TRIM(BOTH '.' FROM s)` | `TRIM` itself is long-standing; the `LEADING`, `TRAILING` and `BOTH` keywords are the newer part |
| `GREATEST(a, b, c)` and `LEAST(...)` | Row-wise maximum and minimum. Nulls are ignored unless every argument is null |
| `a IS NOT DISTINCT FROM b` | Null-safe equality, so `NULL IS NOT DISTINCT FROM NULL` is true where `=` is unknown |

Two traps inside that list:

- **`STRING_AGG` truncates.** The return type follows the input: `varchar(1..8000)` returns
  `varchar(8000)` and `nvarchar(1..4000)` returns `nvarchar(4000)`. Aggregating many rows without
  converting the input to a `max` type silently loses the tail.
- **`||` and `CONCAT` disagree about `NULL`.** `CONCAT` treats a null argument as an empty string;
  `||` propagates the null and ignores `SET CONCAT_NULL_YIELDS_NULL`.

## Validation rules

- Every paging query has an `ORDER BY` with a unique tiebreaker, and does not mix `TOP` with
  `OFFSET FETCH`.
- Every insert that needs its new key uses `OUTPUT`, with `INTO` if the table has a trigger.
- No `LIMIT`, `RETURNING`, `SERIAL`, `ILIKE`, `NOW()`, `true`, `false`, `ON CONFLICT` or `USE`
  survives into the generated SQL.
- Boolean columns are `bit`, compared against `1` or `0`, never used bare as a predicate.
- Literals are single-quoted, doubled to escape, and `N`-prefixed when they carry Unicode.
- No `LOWER()` wrapper was added to defeat a collation that is already case-insensitive.

## Do not

- Do not translate `ILIKE` into `LOWER(col) = LOWER(@v)`. It fixes nothing on a case-insensitive
  collation and costs the index.
- Do not reach for `MERGE` because `ON CONFLICT` needed a home. Read `t-sql-upserts-merge` first.
- Do not hand-roll string aggregation with `FOR XML PATH`, or a maximum with a `CASE` ladder. Both
  have had a real function for years.
- Do not assume a function is missing because it is missing from memory. A migrated database can
  sit at an old compatibility level, which fails differently: the syntax is valid and the engine
  still refuses. See `post-migration-compatibility-level`.
- Do not put error handling in scope here. `t-sql-error-handling` owns `TRY`, `CATCH` and
  `XACT_ABORT`, and `t-sql-programmability-objects` owns how triggers interact with `OUTPUT`.

## References

- [references/postgres-to-tsql.md](references/postgres-to-tsql.md): the full translation table,
  the data type map, and the Microsoft Learn page behind each claim. Read it when porting a schema
  or a query file rather than writing one statement.
