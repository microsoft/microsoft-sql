# Query Store queries for slow-query triage

Queries that widen the triage steps in the Azure SQL guidance, and how to read what each returns.

## Contents

- [Rank instability across the whole database](#rank-instability-across-the-whole-database)
- [Find every query with more than one plan](#find-every-query-with-more-than-one-plan)
- [Query text is normalized, and comments do not survive](#query-text-is-normalized-and-comments-do-not-survive)
- [The permission error, verbatim](#the-permission-error-verbatim)

## Rank instability across the whole database

Widens step 3 of the Azure SQL guidance from one query to every query with more than one
execution, so the worst coefficient of variation in the database surfaces without knowing which
query to ask about first:

```sql
SELECT TOP 20 qsq.query_id, qsp.plan_id, rs.avg_duration, rs.stdev_duration,
       rs.stdev_duration / NULLIF(rs.avg_duration, 0) AS coefficient_of_variation,
       rs.count_executions
FROM sys.query_store_query qsq
JOIN sys.query_store_plan qsp ON qsq.query_id = qsp.query_id
JOIN sys.query_store_runtime_stats rs ON qsp.plan_id = rs.plan_id
WHERE rs.count_executions > 1
ORDER BY coefficient_of_variation DESC;
```

A query executed with widely different row counts ranks near the top; one whose duration is
effectively constant ranks at the bottom, with a coefficient of variation near zero. The ranking,
not any single number, is what points at the one worth reading further.

`count_executions > 1` matters: a coefficient of variation from two executions is barely a sample,
and a `query_id` with `count_executions = 1` divides by an `avg_duration` that is also its only
data point, which ranks as perfectly stable for having nothing to vary against.

## Find every query with more than one plan

Step 4 needs a `query_id` to inspect. This finds every one with plan history worth reading, across
the whole database, in one pass:

```sql
SELECT query_id, COUNT(*) AS plan_count
FROM sys.query_store_plan
GROUP BY query_id
HAVING COUNT(*) > 1
ORDER BY plan_count DESC;
```

Plan history left by forcing a plan and then unforcing it has the same shape a real plan change
leaves behind: one `query_id` with two plans. `is_forced_plan` on `sys.query_store_plan`
distinguishes a plan the optimizer chose from one an
operator pinned, and is worth selecting alongside `plan_id` when reading the result.

## Query text is normalized, and comments do not survive

Even a query Query Store did capture is not stored as the text that ran. Executed as:

```sql
SELECT COUNT(*) FROM dbo.q WHERE id>0 /*QSTIME_cheap4*/
```

it is stored in `sys.query_store_query_text.query_sql_text` as:

```
(@1 tinyint)SELECT COUNT(*) FROM [dbo].[q] WHERE [id]>@1
```

A `LIKE '%QSTIME_cheap4%'` and a `LIKE '%id>0%'` both return zero rows for this exact query, even
when it was captured moments earlier under `QUERY_CAPTURE_MODE = ALL`. The literal is gone,
replaced by a typed parameter placeholder, `@1 tinyint`. The comment is gone entirely. Identifiers
gain brackets they did not have in the original text.

**The brackets and the `@N` placeholder are the same event, and it does not happen to every
query.** The `(@1 tinyint)` prefix is what Microsoft Learn calls the marker of a statement the
engine parameterized: the names and types of the parameters come before the text of the submitted
batch. The bracketing rides along with that rewrite, so a statement the engine did not rewrite
keeps its identifiers as the author wrote them. Learn also warns that parameter names, which
literals get parameterized, and the spacing can change between builds, a second reason not to match
on the rewritten shape.

For example, `SELECT @rc = COUNT(*) FROM dbo.probe_qs_norm WHERE id > 0` can be captured, found by
a search for `probe_qs_norm`, and NOT found by a search for `[dbo].[probe_qs_norm]`. A bracketed
pattern that matches the single-table case above can miss a statement like this one, in the same
view.

So search the bare object name, which matches a rewritten capture and an unrewritten one alike,
then read the text back rather than guessing which you got:

```sql
SELECT query_sql_text
FROM sys.query_store_query_text
WHERE query_sql_text LIKE '%q%';
```

If you do search a bracketed pattern, `[[]` escapes a literal `[` for `LIKE`, since `[` is itself a
wildcard character in T-SQL pattern matching, and `LIKE '%[[]dbo].[[]q]%'` is what matches the
rewritten row above.

The single-table case above has its literal stripped, its comment stripped and brackets added,
while a two table JOIN is captured with its comment stripped and its literal left in place.
**Comment stripping is the one constant across every shape; the literal rewrite and the brackets
are not.**

## The permission error, verbatim

A login or user with `CONNECT` only, and neither `VIEW DATABASE STATE` nor
`VIEW DATABASE PERFORMANCE STATE`, gets this from `sys.dm_exec_query_stats`:

```
Msg 262, Level 14, State 1, Server SQL Azure, Line 1
VIEW DATABASE PERFORMANCE STATE permission denied in database '<database name>'.
```

Granting `VIEW DATABASE STATE` alone, the older and more commonly already-granted permission, is
sufficient to clear this for both `sys.dm_exec_query_stats` and the `sys.query_store_*` catalog
views `sys.query_store_query`, `sys.query_store_plan`, `sys.query_store_runtime_stats`, and
`sys.query_store_wait_stats`. The error names the newer permission; do not assume that name is the
only one that satisfies it before checking what the account already has with:

```sql
SELECT permission_name, state_desc
FROM sys.database_permissions dp
JOIN sys.database_principals p ON dp.grantee_principal_id = p.principal_id
WHERE p.name = '<the account>';
```
