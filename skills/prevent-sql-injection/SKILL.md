---
name: prevent-sql-injection
description: >-
  Handles SQL injection on Azure SQL Database, where parameterising values is already
  right and what is left are the identifier and literal cases parameters cannot reach:
  QUOTENAME returning NULL above 128 characters, so a concatenated dynamic statement
  runs as a silent no-op with no error and no rows; a CASE in a dynamic ORDER BY that
  fails only for the sort values whose column is the lower-precedence type; and Always
  Encrypted rejecting a literal predicate outright. Use for a general injection question
  or a pre-production review, when a dynamic statement built with QUOTENAME returns
  nothing and raises nothing, when a sort-by-column feature throws an operand type clash
  or a date conversion error for one column but not the others, or when a query against
  an Always Encrypted column will not take a literal. Row-level tenant isolation is
  rls-multi-tenant.
---

# Prevent SQL injection: the identifier and literal cases parameters do not cover

**Asked a general injection question, answer it from here, and lead with the part that
is already true.** Parameterising values and refusing string-built predicates is
something an agent does correctly on Azure SQL Database without being told, so say so
and do not spend the reply teaching it. Then cover what parameters cannot reach, which
is where the real defects on this platform live: an identifier, or a column whose
encryption makes a literal invalid.

That is the whole shape of a good answer here. Confirm the basics in a sentence, then
check the three cases below, which are measured and which an agent otherwise gets
wrong.

Measured on 2026-08-29 against a live engine reporting `EngineEdition` 5 and Edition
`SQL Azure`. Full statements, messages and the safe pattern are in
[references/verified-behaviour.md](references/verified-behaviour.md).

## The fact that makes this dangerous

A parameter binds a **value**. It never binds an **identifier**: a table name, a
column name, a schema name. `EXEC sp_executesql N'SELECT * FROM @t', N'@t
sysname', @t = @tableName` does not work, because `@t` is a value, not a table.
Any dynamic identifier has to be built into the SQL text itself, which is exactly
the operation a naive skill would tell you to avoid entirely and exactly the
operation this catalog's readers actually need to do safely: sort-by-any-column
grids, multi-tenant table naming, and admin tooling that targets a caller-chosen
object all need it.

The two safe tools for that job, `QUOTENAME` and a fixed allowlist, are both
correct in the case an agent tests first and both have a failure mode that only
shows up later.

## 1. QUOTENAME above 128 characters is a silent no-op, not an error

```sql
DECLARE @n128 NVARCHAR(200) = REPLICATE(N'a', 128);
DECLARE @n129 NVARCHAR(200) = REPLICATE(N'a', 129);
SELECT QUOTENAME(@n128);  -- bracketed string, 130 characters, no complaint
SELECT QUOTENAME(@n129);  -- NULL
```

At 128 characters `QUOTENAME` returns the bracketed identifier. At 129 it returns
`NULL`, exactly at the boundary. Concatenating that `NULL` into a statement makes
the whole statement `NULL`, and handing a `NULL` batch to `sp_executesql`, or to
`EXEC()` of the same string, runs it as nothing: no rows, `@@ERROR` stays 0, the
process exit code stays 0. There is no severity level at which this reports
itself. The only place it shows is a caller who expected rows and got none.

`QUOTENAME` does correctly double an embedded closing bracket (`QUOTENAME(N'my]col')`
returns `[my]]col]`), so escaping itself is not the defect. The defect is
exclusively the 128-character ceiling and the fact that crossing it produces
`NULL` rather than a truncated string or a thrown error.

The fix: check the result of `QUOTENAME` for `NULL` before executing anything
built from it, and reject or flag the input rather than silently running a no-op.
Where the set of valid identifiers is known in advance, such as the columns a UI
is allowed to sort by, prefer a fixed allowlist over `QUOTENAME` entirely; an
allowlist has no length ceiling to cross.

## 2. A single CASE mixing types in a dynamic ORDER BY fails for some sort values and not others

```sql
-- Chooses between id (int) and created (date) at runtime.
ORDER BY CASE @col
            WHEN N'id'      THEN id
            WHEN N'created' THEN created
         END
```

A single `CASE` forces every branch to one common type, picked by SQL Server's
type precedence, not by which branch the current `@col` actually selects. What
that means at runtime is not the same for every pairing, and the difference is
the whole trap.

**`int` mixed with `date` fails unconditionally, at compile time.** No implicit
conversion exists between them at all, so `CASE @c WHEN N'a' THEN i WHEN N'b'
THEN d END` raises `Msg 206, Operand type clash: int is incompatible with date`
whatever `@c` is, including a value that matches neither branch. It also aborts
the batch outright: wrapping the same statement in `BEGIN TRY` / `END CATCH`
does not catch it, because the clash is caught at compile time, before the
`TRY` block's error handling is in scope. Nothing downstream of this statement
in the same batch runs.

**A string column mixed with `int` or `date` fails only when the matched
branch is the lower-precedence side, and only for that one value of the sort
key.** `date` and `int` both outrank `nvarchar`, so the branch typed
`nvarchar` is the one converted, and only when it is the branch actually
selected. Measured on columns `i INT`, `d DATE`, `s NVARCHAR(50)`:

| Branches | `@c` value | Branch selected | Result |
|---|---|---|---|
| `WHEN N'a' THEN s` `WHEN N'b' THEN d` | `'b'` (matches `d`, the higher-precedence branch) | `d` | Runs clean |
| `WHEN N'a' THEN s` `WHEN N'b' THEN d` | `'a'` (matches `s`, the lower-precedence branch) | `s` | `Msg 241, Conversion failed when converting date and/or time from character string` |
| `WHEN N'a' THEN i` `WHEN N'b' THEN s` | `'a'` (matches `i`, the higher-precedence branch) | `i` | Runs clean |
| `WHEN N'a' THEN i` `WHEN N'b' THEN s` | `'b'` (matches `s`, the lower-precedence branch) | `s` | `Msg 245, Conversion failed when converting the nvarchar value 'Ann' to data type int` |

**A sort key matching neither branch also runs clean**, whatever the column
types: `CASE` falls through to an implicit `ELSE NULL`, no branch is evaluated,
and no conversion is attempted.

This is a sharper trap than "mixing types fails," because the same statement
passes for some sort columns and fails for others depending on which one a
caller actually picks. It gets written against whichever sort key the author
tested (commonly the default), passes review, and fails in production the
first time someone clicks a column header that sorts to the lower-precedence
branch, pointing at an `ORDER BY` clause that has not changed since the
passing test.

The fix that actually holds is one `CASE` **per candidate column**, each with a
single type in its `THEN`, rather than one `CASE` spanning every candidate.
This removes the value-dependence entirely: with a separate `CASE` per column,
each expression has exactly one type across all its branches, so there is
never a mixed-type common type to coerce toward, and every sort key behaves
the same way whether it happens to be the one tested first or not:

```sql
ORDER BY
  CASE WHEN @col = N'id'      THEN id      END,
  CASE WHEN @col = N'name'    THEN name    END,
  CASE WHEN @col = N'created' THEN created END
```

Columns that do not match `@col` evaluate to `NULL` for every row and sort as
ties, so this composes correctly with `OFFSET`/`FETCH` and with an `ASC`/`DESC`
toggle per column. A server-side allowlist mapping a UI sort key to one of a
fixed, reviewed set of column names is the other pattern that holds, and it
depends on neither `QUOTENAME` nor `CASE`.

## 3. Always Encrypted makes parameterisation mandatory, not optional

On a column protected by Always Encrypted, a literal predicate does not merely
weaken security, it fails to run: the literal is never encrypted client side, so
comparing it to the ciphertext stored in the column is a type mismatch the
engine rejects. Only a value passed as a parameter through a driver connection
string with `Column Encryption Setting=Enabled` is encrypted before it reaches
the server and can be compared. So on such a column, the fix that is usually
framed as best practice is the only way the query runs at all.

This is documented behaviour, not measured against the engine behind the rest of
this skill: reproducing it needs a column master key provisioned outside the
database, in a certificate store, Azure Key Vault, or an HSM, which the run
behind [references/verified-behaviour.md](references/verified-behaviour.md) did
not set up. Say what the column requires; do not claim it was verified here.

## What this skill assumes is already handled

A probe of both a larger and a smaller model, with no skill loaded, found these
already correct and they are not repeated here: a dynamic statement inside a
procedure, run with `sp_executesql` and full parameter binding, still runs under
the caller's own permissions because ownership chaining is broken by dynamic SQL,
so `EXECUTE`-only callers with no table permission fail rather than succeed;
Dynamic Data Masking is a presentation control, not a defence against injection
or against a user who can already run arbitrary queries; and when an agent
composes and runs a whole statement from free text, the control that matters is
the database permission boundary the agent's own connection runs under, not
parameterising the one value inside it. Route those elsewhere rather than
re-deriving them here.

## Validation rules

- Every dynamic statement built with `QUOTENAME` checks the result for `NULL`
  before executing anything built from it.
- No generated `ORDER BY` uses one `CASE` expression with columns of more than
  one data type as its branches. Either one `CASE` per candidate column, or a
  fixed allowlist.
- Nothing claims `QUOTENAME` truncates an over-length identifier, or merely
  fails to verify the object exists. It returns `NULL`.
- Any claim about Always Encrypted rejecting a literal is stated as documented
  behaviour unless it was actually run against an engine with a column master
  key provisioned.

## Do not

- Do not present `QUOTENAME` as sufficient on its own for a caller-supplied
  identifier without a length check on its result.
- Do not build a caller-chosen `ORDER BY` with one `CASE` spanning columns of
  different types, even when the columns tried in testing happen to share a
  type.
- Do not repeat that `QUOTENAME` truncates long identifiers. It returns `NULL`.
- Do not tell a developer their agent-composed-SQL risk is solved by
  parameterising the one user-supplied value inside a model-authored statement.
  The model authors the whole statement, so the control is the permission
  boundary the connection runs under, not the parameter.
- Do not warn about `xp_cmdshell`, linked servers, or `OPENROWSET` against
  arbitrary providers as live risks on Azure SQL Database. None of them exist
  here to escalate to.

## References

- [references/verified-behaviour.md](references/verified-behaviour.md): every
  statement behind this page, the exact messages for each type pairing, the
  128 versus 129 character boundary, and what is documented rather than
  measured for Always Encrypted.
