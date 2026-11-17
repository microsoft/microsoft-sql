# Step 7 — Targeted Query Text and Plan Analysis (Conditional)

Trigger conditions live in the parent `SKILL.md` (Step 7 section). Only load this file once a
trigger has fired.

**Procedure:**

1. Build a **shortlist** of at most `{{TopN}}` distinct `(query_hash, query_plan_hash)` pairs by
   merging the top offenders from Steps 3, 4, and 6. Deduplicate on `query_hash`. Prefer hashes
   that appear in more than one step — they are the strongest evidence.
2. For each shortlisted hash pair, run **Step 7a** below to retrieve the full SQL text and the
   cached query plan XML. Substitute the literal `query_hash` / `query_plan_hash` values into the
   query — do **not** loop the whole plan cache without a filter.
3. Analyze the returned text and plan as described in **Step 7b**.

## Step 7a: Retrieve text and plan for a specific hash

Execute via the SQL query tool. Replace `0xHASH` placeholders with the actual `binary(8)`
values from Step 3/4/6 results (they are already in `0x…` form when those steps return them).

```sql
SELECT TOP (1)
      qs.query_hash
    , qs.query_plan_hash
    , qs.execution_count
    , qs.total_worker_time / NULLIF(qs.execution_count, 0) / 1000   AS worker_time_per_exec_ms
    , qs.total_logical_reads / NULLIF(qs.execution_count, 0)        AS logical_reads_per_exec
    , qs.last_execution_time
    , DB_NAME(st.dbid)                                              AS database_name
    , OBJECT_NAME(st.objectid, st.dbid)                             AS object_name
    , SUBSTRING(
          st.text
        , (qs.statement_start_offset / 2) + 1
        , ((CASE qs.statement_end_offset
                WHEN -1 THEN DATALENGTH(st.text)
                ELSE qs.statement_end_offset
            END - qs.statement_start_offset) / 2) + 1
      )                                                             AS statement_text
    , qp.query_plan
FROM sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle)   AS st
CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
WHERE qs.query_hash      = 0xHASH_FROM_PRIOR_STEP
  AND qs.query_plan_hash = 0xPLAN_HASH_FROM_PRIOR_STEP
ORDER BY qs.last_execution_time DESC
OPTION (MAXDOP 1);
```

Notes:
- If `query_plan` is NULL, the plan was evicted or is too large to return via this DMV. Fall back
  to filtering on `query_hash` alone and re-run; if still NULL, report "plan unavailable" for
  that entry and analyze the text only.
- For **currently executing** requests from Step 3 on SQL Server 2016 SP1 or later, use the
  observed `session_id` with `sys.dm_exec_query_statistics_xml({{SessionId}})` and filter its
  rows to the observed `request_id`. The function accepts a session ID, not a plan handle.
  On SQL Server 2014, use the cached-plan query above because the live-statistics function
  is unavailable.

## Step 7b: Analyze the text and plan

For each retrieved query, produce a short, concrete recommendation. Walk this checklist (cross-
reference detected operators against `references/plan-smell-reference.md`):

**From the statement text:**
- Predicates with implicit type mismatches (e.g. `WHERE varchar_col = N'literal'`,
  `WHERE int_col = '123'`) — call out the exact column and propose a type-matched literal or a
  schema change.
- Non-sargable expressions on indexed columns (`WHERE FUNCTION(col) = …`, `WHERE col + 1 = …`,
  leading wildcard `LIKE '%foo'`) — recommend rewriting the predicate.
- `SELECT *` against wide tables — recommend an explicit column list, especially if a Key Lookup
  appears in the plan.
- Scalar UDF invocations in `SELECT`/`WHERE` — recommend inlining or rewriting as iTVF.
- Cursor / RBAR patterns, `WHILE` loops over row sets — recommend set-based rewrite.
- Missing or overly broad `WHERE` clauses driving full scans of large tables.

**From the plan XML:**
- Large **Clustered Index Scan / Table Scan** on a table where the predicate is selective —
  recommend a covering index. Quote the table name and predicate.
- **Key Lookup** with high estimated executions — recommend `INCLUDE` columns on the seek index.
- **Hash Match** or **Sort** with `SpillToTempDb` events — recommend stats update or memory grant
  hint.
- **Nested Loops** with a large outer input and an indexed inner input that is being scanned —
  often a stats / cardinality issue; recommend `UPDATE STATISTICS` and re-check.
- **Parallelism (Gather Streams)** operators with strongly skewed row counts across threads —
  recommend `OPTION (MAXDOP n)` test or fixing the distribution / statistics.
- `<MissingIndexes>` element in the plan XML — quote the recommended index DDL verbatim, but
  caveat that the optimizer's suggestion should be validated against existing indexes before
  creating it.
- `CONVERT_IMPLICIT` warnings in `<Warnings>` — tie back to the offending column and propose a
  fix.

Produce one recommendation block per analyzed query using the Step 7 section of
`references/report-template.md`.
