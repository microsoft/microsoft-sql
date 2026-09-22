# QUOTENAME returning NULL, and the ORDER BY type clashes: the measured runs

## Contents

- [How this was measured](#how-this-was-measured)
- [QUOTENAME above 128 characters](#quotename-above-128-characters)
- [The silent no-op, end to end](#the-silent-no-op-end-to-end)
- [QUOTENAME with an embedded closing bracket](#quotename-with-an-embedded-closing-bracket)
- [CASE in ORDER BY mixing types](#case-in-order-by-mixing-types)
- [The safe pattern, with OFFSET FETCH](#the-safe-pattern-with-offset-fetch)
- [What is documented rather than measured](#what-is-documented-rather-than-measured)

## How this was measured

One engine, reachable over the network, reporting:

```text
SERVERPROPERTY('EngineEdition') = 5
SERVERPROPERTY('Edition')       = SQL Azure
```

Date of the run: 2026-08-29. A dedicated database, `dq_injection`, carried a table:

```sql
CREATE TABLE dbo.Grid (id INT, name NVARCHAR(50), amount DECIMAL(10,2), created DATE);
INSERT INTO dbo.Grid VALUES (1,'b',10.50,'2026-01-01'),(2,'a',20.25,'2026-02-01'),(3,'c',5.00,'2026-03-01');
ALTER TABLE dbo.Grid ADD nickname NVARCHAR(50) NULL;
UPDATE dbo.Grid SET nickname = name;
```

## QUOTENAME above 128 characters

```sql
DECLARE @n128 NVARCHAR(200) = REPLICATE(N'a', 128);
DECLARE @n129 NVARCHAR(200) = REPLICATE(N'a', 129);
SELECT LEN(@n128) AS len128, QUOTENAME(@n128) AS q128, LEN(QUOTENAME(@n128)) AS qlen128;
SELECT LEN(@n129) AS len129, QUOTENAME(@n129) AS q129, LEN(QUOTENAME(@n129)) AS qlen129;
```

Result: at exactly 128 characters, `QUOTENAME` returns the bracketed string (130
characters once wrapped) with no complaint. At exactly 129 characters, `QUOTENAME`
returns `NULL`. The boundary is precise, not approximate, and it is `NULL`, not a
truncated or escaped value.

## The silent no-op, end to end

```sql
DECLARE @tbl NVARCHAR(400) = REPLICATE(N'x', 129);
DECLARE @sql NVARCHAR(MAX) = N'SELECT * FROM ' + QUOTENAME(@tbl);
PRINT 'sql value is: ' + ISNULL(@sql, N'<<NULL>>');
EXEC sp_executesql @sql;
PRINT 'executed with no error, @@ERROR=' + CAST(@@ERROR AS NVARCHAR(10));
```

Output:

```text
sql value is: <<NULL>>
executed with no error, @@ERROR=0
```

No rows, no error, no non-zero `@@ERROR`, exit code 0. `sp_executesql` was given a
`NULL` batch and treated it as nothing to do, not as a malformed call.

This is not specific to `sp_executesql`. The same `NULL` batch handed to `EXEC(@sql)`
behaves identically: control reaches the next statement, `@@ERROR` is 0, and sqlcmd's
own process exit code is 0 in both cases. So the failure mode is "a `NULL` dynamic
batch executes as a no-op", not a quirk of one calling convention. Anywhere a
concatenated identifier can silently become `NULL` (a bad `QUOTENAME` call is the
common source, but plain string concatenation with a `NULL` variable does the same
thing), the statement built from it disappears without a trace at any severity level.

## QUOTENAME with an embedded closing bracket

```sql
SELECT QUOTENAME(N'my]col') AS escaped;
-- [my]]col]
```

`QUOTENAME` doubles an embedded `]` correctly, the standard T-SQL bracket-escaping
convention, so escaping itself is not the defect. The defect is exclusively the
128-character ceiling and its `NULL` return, which nothing downstream reports.

## CASE in ORDER BY mixing types

Four columns: `id INT`, `name NVARCHAR(50)`, `amount DECIMAL(10,2)`, `created DATE`.
Each test picks a column at runtime with `CASE @col WHEN 'x' THEN colx WHEN 'y' THEN
coly END`, the shape an agent reaches for to make `ORDER BY` accept a user-chosen
column without ever putting an identifier in a parameter.

The first pass at this (below, "mixed at all") only asked whether a pairing fails.
Re-measured with the sort key varied across its own possible values, on a second
table, `dbo.T (i INT, d DATE, s NVARCHAR(50))` holding two rows, `(1, '2026-01-01',
N'Ann')` and `(2, '2026-02-01', N'Bob')`: the runtime pairings do not fail
unconditionally. They fail only for the sort key value that selects the
lower-precedence branch, and the exact same statement runs clean for the other
value. Presenting a runtime pairing as "fails" without both values is exactly the
setup where a reader tests the passing value, ships it, and only hits the failing
value in production.

### int mixed with date, or decimal mixed with date: unconditional, compile time

```sql
DECLARE @c CHAR(1) = N'a';   -- or 'b', or a value matching neither
SELECT * FROM dbo.T
ORDER BY CASE @c WHEN N'a' THEN i WHEN N'b' THEN d END;
```

`Msg 206, Level 16: Operand type clash: int is incompatible with date.` Fires for
every value of `@c`, including one that matches neither branch, because there is
no implicit conversion between `int` and `date` at all: the clash is detected
compiling the expression, before any row or any branch selection is evaluated.
`amount` (decimal) mixed with `created` (date) fails the same way: `Msg 206,
Operand type clash: decimal is incompatible with date.`

This one is also not catchable in the same batch. Wrapping the statement in
`BEGIN TRY` / `END CATCH` does not run the `CATCH` block; the batch aborts at the
clash, before the surrounding `TRY` has a chance to take effect:

```sql
BEGIN TRY
    SELECT * FROM dbo.T ORDER BY CASE @c WHEN N'a' THEN i WHEN N'b' THEN d END;
END TRY
BEGIN CATCH
    PRINT 'caught';   -- never reached
END CATCH
-- result: Msg 206 raised directly, nothing after it in the batch runs, no PRINT
```

### int or date mixed with a string column: only when the matched branch is the string

```sql
-- branches: 'a' -> s (nvarchar), 'b' -> d (date)
DECLARE @c CHAR(1) = N'a';  -- selects s, the lower-precedence branch
SELECT sample.s, sample.d
FROM (VALUES (N'Ann', CONVERT(date, '2026-01-01')),
             (N'Bob', CONVERT(date, '2026-01-02'))) AS sample(s, d)
ORDER BY CASE WHEN @c = N'a' THEN sample.s END,
         CASE WHEN @c = N'b' THEN sample.d END;
```

| Branches | `@c` | Branch selected | Result |
|---|---|---|---|
| `'a' THEN s` (nvarchar), `'b' THEN d` (date) | `'b'` | `d`, the higher-precedence side | Runs clean, 2 rows |
| `'a' THEN s` (nvarchar), `'b' THEN d` (date) | `'a'` | `s`, the lower-precedence side | `Msg 241, Level 16: Conversion failed when converting date and/or time from character string.` |
| `'a' THEN i` (int), `'b' THEN s` (nvarchar) | `'a'` | `i`, the higher-precedence side | Runs clean, 2 rows |
| `'a' THEN i` (int), `'b' THEN s` (nvarchar) | `'b'` | `s`, the lower-precedence side | `Msg 245, Level 16: Conversion failed when converting the nvarchar value 'Ann' to data type int.` |
| Either pairing above | a value matching neither `'a'` nor `'b'`, e.g. `'x'` | neither; `CASE` falls through to implicit `ELSE NULL` | Runs clean, 2 rows, no conversion attempted |

`date` and `int` both outrank `nvarchar` in type precedence, so the string branch
is the one coerced toward the winning type, and only the row values actually
reached by the **selected** branch are ever converted. When the selected branch is
already the winning type, nothing needs converting and the statement runs whether
or not the other, unreached branch would have failed. This is what makes the
runtime pairings a sharper trap than the compile-time one: the statement is
correct T-SQL, passes a test run against whichever sort key was tried, and fails
only when a caller picks the other one, in production, against a clause that has
not changed.

### Same-typed and freely-convertible pairings never hit this

| Branches mixed | Result |
|---|---|
| `name` (nvarchar), `nickname` (nvarchar) | Runs cleanly for every value of the sort key. Both branches are the same type. |
| `id` (int), `amount` (decimal) | Runs cleanly for every value of the sort key. Both are numeric types with a defined implicit conversion between them. |

### The fix removes the value-dependence, not just the error

One `CASE` **per candidate column**, each with a single type across its own
branches, has no mixed-type common type to coerce toward, at compile time or at
runtime. That is true whichever sort key is passed, so the fix is not "avoid the
failing value," it is "make there be no failing value." See
[the safe pattern below](#the-safe-pattern-with-offset-fetch).

## The safe pattern, with OFFSET FETCH

```sql
DECLARE @col SYSNAME = N'created', @dir CHAR(1) = N'A';
SELECT * FROM dbo.Grid
ORDER BY
  CASE WHEN @col = N'id'      AND @dir = N'A' THEN id      END ASC,
  CASE WHEN @col = N'id'      AND @dir = N'D' THEN id      END DESC,
  CASE WHEN @col = N'name'    AND @dir = N'A' THEN name    END ASC,
  CASE WHEN @col = N'name'    AND @dir = N'D' THEN name    END DESC,
  CASE WHEN @col = N'created' AND @dir = N'A' THEN created END ASC,
  CASE WHEN @col = N'created' AND @dir = N'D' THEN created END DESC
OFFSET 0 ROWS FETCH NEXT 10 ROWS ONLY;
```

Ran cleanly, correctly sorted by `created`, three rows returned. This is the fix that
actually works: one `CASE` expression **per candidate column**, each with a single
type in its `THEN`, rather than one `CASE` with every candidate column as a branch.
The columns that do not match `@col` evaluate to `NULL` for every row and sort as
ties, so ordering by the chosen column is unaffected. `OFFSET`/`FETCH` composes with
this pattern without any further interaction; it does not need `ORDER BY` to name a
literal column, only a valid ordering expression, and this is one.

A server-side allowlist (map the UI's sort key to a fixed, reviewed set of column
names before ever building SQL) and this per-column `CASE` pattern are the two
approaches that hold. Neither ever puts a column name where a parameter would go, and
neither depends on `QUOTENAME` at all, so the 128-character defect above does not
apply to either.

## What is documented rather than measured

**Always Encrypted and a literal predicate.** Microsoft Learn documents that a query
comparing an Always Encrypted column to a literal fails, because the literal is never
encrypted client-side and the comparison becomes a plaintext-to-ciphertext operand type
clash; only a parameter passed through a driver with `Column Encryption Setting=Enabled`
is encrypted before it reaches the server, so parameterisation is required for the
query to run at all, not merely safer. **This was not reproduced against the engine
used for the rest of this file**, because Always Encrypted needs a column master key
provisioned outside the database (a certificate store, Azure Key Vault, or an HSM),
which this run did not set up. Treat the QUOTENAME and CASE findings above as measured,
and this one as documented.
