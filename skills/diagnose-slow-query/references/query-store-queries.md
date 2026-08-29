# Query Store queries for slow-query triage

Every query in this file was run against a live engine reporting Edition `SQL Azure` and
EngineEdition 5 on 2026-08-29, against a database created for that purpose, not recalled from
memory.

## Contents

- [Rank instability across the whole database](#rank-instability-across-the-whole-database)
- [Find every query with more than one plan](#find-every-query-with-more-than-one-plan)
- [Query text is normalized, and comments do not survive](#query-text-is-normalized-and-comments-do-not-survive)
- [The permission error, verbatim](#the-permission-error-verbatim)
- [Confirming Query Store is on before anything else](#confirming-query-store-is-on-before-anything-else)

## Rank instability across the whole database

Widens step 3 of `SKILL.md` from one query to every query with more than one execution, so the
worst coefficient of variation in the database surfaces without knowing which query to ask about
first:

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

Run against the test database this returned seven queries with more than one execution, headed by
a coefficient of variation of 0.62 on a query executed three times with widely different row
counts, and tailed by one at 0.065 that is effectively constant. The ranking, not either number
alone, is what points at the one worth reading further.

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

On the test database, one `query_id` carried two plans after a plan was deliberately forced and
then unforced during verification, which is the same shape a real plan change leaves behind:
`is_forced_plan` on `sys.query_store_plan` distinguishes a plan the optimizer chose from one an
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

Checked directly on the test engine: a `LIKE '%QSTIME_cheap4%'` and a `LIKE '%id>0%'` both return
zero rows against this exact query, captured moments earlier under `QUERY_CAPTURE_MODE = ALL`. The
literal is gone, replaced by a typed parameter placeholder, `@1 tinyint`. The comment is gone
entirely. Identifiers gain brackets they may not have had in the original text.

Search the normalized shape instead:

```sql
SELECT query_sql_text
FROM sys.query_store_query_text
WHERE query_sql_text LIKE '%[[]dbo].[[]q]%'
  AND query_sql_text LIKE '%[[]id]>@%';
```

`[[]` escapes a literal `[` for `LIKE`, since `[` is itself a wildcard character in T-SQL pattern
matching. This matched the row above on the test engine; the equivalent search on the original
literal or comment did not, against the identical row, in the identical database.

This normalization behavior and the `AUTO` capture gap above were both re-measured on separate,
freshly created databases on 2026-08-29. The single-table case above confirmed the same result
again: literal stripped, comment stripped, brackets added. A JOIN across two tables was captured
with its comment stripped too, but with the literal left in place, not every query shape is
eligible for the literal-to-parameter rewrite, so do not assume every captured query will show an
`@N` placeholder. **Comment-stripping was the one constant across both shapes; the literal
rewrite was not.** A comment tag is the less reliable thing to search for even than a literal
value, because it disappears on every capture regardless of query shape, while a literal
sometimes survives.

## The permission error, verbatim

A login or user with `CONNECT` only, and neither `VIEW DATABASE STATE` nor
`VIEW DATABASE PERFORMANCE STATE`, gets this from `sys.dm_exec_query_stats`:

```
Msg 262, Level 14, State 1, Server SQL Azure, Line 1
VIEW DATABASE PERFORMANCE STATE permission denied in database '<database name>'.
```

Granting `VIEW DATABASE STATE` alone, the older and more commonly already-granted permission, was
sufficient to clear this for both `sys.dm_exec_query_stats` and every `sys.query_store_*` catalog
view tested: `sys.query_store_query`, `sys.query_store_plan`, `sys.query_store_runtime_stats`, and
`sys.query_store_wait_stats`. The error names the newer permission; do not assume that name is the
only one that satisfies it before checking what the account already has with:

```sql
SELECT permission_name, state_desc
FROM sys.database_permissions dp
JOIN sys.database_principals p ON dp.grantee_principal_id = p.principal_id
WHERE p.name = '<the account>';
```

## Confirming Query Store is on before anything else

```sql
SELECT actual_state_desc, query_capture_mode_desc, stale_query_threshold_days, max_storage_size_mb
FROM sys.database_query_store_options;
```

On a database created moments before this was checked, `actual_state_desc` already read
`READ_WRITE` with no configuration step taken. An `actual_state_desc` of `READ_ONLY` means storage
capped out against `max_storage_size_mb` and Query Store stopped accepting new data; that is a
capacity problem to raise with whoever owns the database, not a sign the workload went quiet.
