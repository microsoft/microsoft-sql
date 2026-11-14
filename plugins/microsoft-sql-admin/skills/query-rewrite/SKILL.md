---
name: query-rewrite
description: "Use when the user explicitly asks to rewrite or restructure a SQL query or predicate, e.g. make a WHERE clause SARGable, keeping results and NULL semantics. For 'make this faster', use `improve-query-performance`."
argument-hint: "[QueryText]"
---

# Query Rewrite (LITHE)

This skill rewrites T-SQL queries using LLM-generated structural transformations (the LITHE approach). It applies multiple rewrite strategies, validates each rewrite against the query optimizer's estimated cost, and tries to verify semantic equivalence. The result is a ranked list of lower-cost rewrites.

## When to Use

- User says "rewrite this query", "better form of this query", "restructure this query", "find a better SQL form"
- User explicitly asks for a structural rewrite or reformulation of the SQL text
- The `improve-query-performance` skill directed you here after the user selected rewrite analysis

## When NOT to Use

- **Generic requests** like "improve this query", "optimize this query", "make this faster", "help me with this query", "tune this query" → use `improve-query-performance` instead
- User wants hint-based tuning → use `query-hint-tuning` skill instead
- User wants index recommendations → use `missing-index-analysis` skill or LLM-based suggestions
- User wants a full optimization workflow → use `improve-query-performance` skill instead

## Choose the requested scope

For a correctness review of supplied rewrites, evaluate those candidates and
their proof obligations directly. Supplied queries, constraints and sample rows
can establish a counterexample without a database connection. Do not start the
seven-strategy cost search, require plan captures, or refuse this reasoning just
because SQL/MCP access is unavailable. Request missing metadata only when it is
needed for the conclusion; distinguish a sample counterexample from a proof for
all allowed database states. Preserve the requested response format.

For a new performance-rewrite investigation, use the workflow below. A bounded
sample with added TOP, filters or a changed projection is a different query:
do not use its plan cost or result equality as proof about the original query.
Reuse matching evidence and stop when the caller's question is answered.

## Prerequisites (performance investigation)

- Must be connected to a database containing the tables referenced in the query.
- The query must be a valid T-SQL statement (SELECT, CTE + SELECT, etc.).

## Required tools

- A SQL query tool connected to the target server and database. Prefer, in order: the SQL Tools MCP server that ships with the `microsoft-sql-admin` plugin (`mssql_list_database_connections`, `mssql_connect_database`, then `mssql_execute_query`); any other SQL tool the agent host provides for running T-SQL and reading result sets; [`sqlcmd`](https://learn.microsoft.com/sql/tools/sqlcmd/sqlcmd-utility) from a terminal. If using the SET-based scripts below instead of a dedicated plan tool, the host must interpret `GO` batch separators in one session (or explicitly preserve that session between calls), because `SET SHOWPLAN_XML` only applies to the session that sets it. Steps 1–4 are read-only (plans are compiled, not executed); Step 5 executes both queries and runs only with the user's permission. If the SQL Tools MCP server is not connected or lists no connections, follow the `sql-tools-mcp-setup` skill, which asks before installing or configuring anything. If no SQL tool can be made available, give the user the T-SQL to run and ask for the results.

### SQL Tools MCP session boundary

With SQL Tools MCP, do not send `GO` separators to `mssql_execute_query`, and do not rely on session SET options surviving a second tool call. That tool accepts raw T-SQL, not a sqlcmd script. Prefer `getEstimatedShowplanForQuery` for estimated-plan retrieval; it is in the server's default tool set, so when it is missing the host has filtered the tools or runs an older build. Use `getShowplanWithExecutionStatsForQuery` only with explicit authorization to execute the workload. Call a plan tool once per plan and reuse its result; do not loop re-running the statement through `mssql_execute_query` to compare variants. Otherwise use supplied plan XML or a verified same-session `sqlcmd` capture. Keep estimated-plan capture separate from execution.


## Procedures Used by the Workflow

### Get Estimated Plan Cost (read-only)

With `sqlcmd` or a verified batch-aware host, send all of the following in **one session**, with each `SET SHOWPLAN_XML` in its own batch:

```sql
SET SHOWPLAN_XML ON;
GO
<query>
GO
SET SHOWPLAN_XML OFF;
GO
```

The query is compiled but not executed. **Never** send the query in a separate request on the assumption that `SHOWPLAN_XML` is still on: if the tool does not keep the session, the query would execute. From the returned showplan XML, on the `StmtSimple` element of the query's statement, read:
- `cost` = `StatementSubTreeCost`
- `planHash` = `QueryPlanHash`
- `plan` = the showplan XML itself (keep it for the equivalence check)

If the batch returns an error instead of a plan (syntax error, invalid object or column name, etc.), treat that as the result.

### Get PK/FK Metadata (read-only)

Take the referenced tables from the `Object` elements (`Database`, `Schema`, `Table` attributes) in the baseline plan, or from the query text. Then run, substituting the table names:

```sql
DECLARE @tables TABLE (name nvarchar(512) NOT NULL);
INSERT INTO @tables (name) VALUES (N'dbo.Table1'), (N'dbo.Table2');  -- agent substitutes the referenced tables

SELECT
    fk.name AS ForeignKeyName,
    QUOTENAME(SCHEMA_NAME(pt.schema_id)) + N'.' + QUOTENAME(pt.name) AS ReferencingTable,
    pc.name AS ReferencingColumn,
    pc.is_nullable AS ReferencingColumnIsNullable,
    QUOTENAME(SCHEMA_NAME(rt.schema_id)) + N'.' + QUOTENAME(rt.name) AS ReferencedTable,
    rc.name AS ReferencedColumn,
    fkc.constraint_column_id AS ColumnOrdinal,
    fk.is_disabled,
    fk.is_not_trusted
FROM sys.foreign_keys AS fk
JOIN sys.foreign_key_columns AS fkc ON fkc.constraint_object_id = fk.object_id
JOIN sys.tables AS pt ON pt.object_id = fk.parent_object_id
JOIN sys.columns AS pc ON pc.object_id = fkc.parent_object_id AND pc.column_id = fkc.parent_column_id
JOIN sys.tables AS rt ON rt.object_id = fk.referenced_object_id
JOIN sys.columns AS rc ON rc.object_id = fkc.referenced_object_id AND rc.column_id = fkc.referenced_column_id
WHERE fk.parent_object_id IN (SELECT OBJECT_ID(name) FROM @tables)
  AND fk.referenced_object_id IN (SELECT OBJECT_ID(name) FROM @tables)
ORDER BY ForeignKeyName, ColumnOrdinal;

SELECT
    QUOTENAME(SCHEMA_NAME(t.schema_id)) + N'.' + QUOTENAME(t.name) AS TableName,
    kc.name AS KeyName,
    kc.type_desc AS KeyType,           -- PRIMARY_KEY_CONSTRAINT or UNIQUE_CONSTRAINT
    c.name AS ColumnName,
    ic.key_ordinal
FROM sys.key_constraints AS kc
JOIN sys.tables AS t ON t.object_id = kc.parent_object_id
JOIN sys.index_columns AS ic ON ic.object_id = kc.parent_object_id AND ic.index_id = kc.unique_index_id
JOIN sys.columns AS c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
WHERE kc.parent_object_id IN (SELECT OBJECT_ID(name) FROM @tables)
ORDER BY TableName, KeyName, ic.key_ordinal;
```

Only foreign keys that are enabled and trusted (`is_disabled = 0` and `is_not_trusted = 0`) guarantee referential integrity. If a referencing column is nullable, rows with NULL in it have no match, so an inner join that is eliminated must be replaced by an `IS NOT NULL` filter on that column.

### Check Rewrite Equivalence (read-only, no execution)

Decide the equivalence status yourself from the two queries and their estimated plans:
1. Compare the output columns: the `OutputList` of the root `RelOp` in each plan must have the same number of columns with compatible types, in the same order. If not → `NotEquivalent`.
2. Check each transformation for known semantic traps: NULL handling (`NOT IN` vs `NOT EXISTS`, `ISNULL`/`COALESCE`, outer vs inner joins), duplicate rows (`IN`/`EXISTS` vs `JOIN`, `DISTINCT`, `UNION` vs `UNION ALL`), aggregates over empty input (`COUNT` returns 0, `SUM`/`MIN`/`MAX` return NULL), `TOP` without a deterministic `ORDER BY`, and non-deterministic functions.
3. Classify:
   - `NotEquivalent` — output columns differ, or you can construct a concrete input where the results differ.
   - `Equivalent` — every transformation is a known equivalence and all its preconditions are verified (for example, a trusted foreign key and a NOT NULL column for join elimination).
   - `PotentiallyEquivalent` — you found no difference, but at least one precondition could not be verified.
   - `Unknown` — the transformation is too complex to reason about reliably.

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| Query | (required) | The T-SQL query to optimize |
| MaxSyntaxFixAttempts | 5 | Maximum attempts to fix syntax errors per rewrite strategy |

## Rewrite Strategies

Apply each of the following strategies in order. For each strategy, generate a complete rewritten T-SQL query that maintains semantic equivalence with the original.

### Strategy 1: Short Prompt

Rewrite the SQL Server query to improve performance while maintaining semantic equivalence. Focus on structural optimizations -- not cosmetic changes.

### Strategy 2: Expert Optimization

Act as a database expert and SQL optimizer. Analyze the query for inefficiencies and transform it into an optimized, functionally equivalent SQL Server query. Focus on improving execution efficiency through structural changes.

### Strategy 3: Verbose Step-by-Step

Follow these steps to rewrite the query:
1. Identify specific inefficiencies in the query. If the query is already efficient, return it unchanged.
2. Determine optimization guidelines and explain the rationale behind each recommended change.
3. Craft a new, optimized query that includes all enhancements while maintaining syntactic and semantic equivalence.

### Strategy 4: CTE Pre-computation Rule

**Rule:** A CTE can factor an expression into a clearer candidate form, but does
not guarantee materialization, one evaluation, fewer scans or faster execution.
SQL Server can expand the expression at each reference; compare actual plans and
authorized measurements before claiming a benefit. Do not silently substitute a
temporary table, which introduces storage, statement/snapshot and permission
considerations. See [CTE usage guidelines](https://learn.microsoft.com/sql/t-sql/queries/with-common-table-expression-transact-sql#usage-guidelines).

**Example:**

Original:
```sql
SELECT employee_id FROM employee_bonus
WHERE bonus_amount < 0.05 * (SELECT MIN(bonus_amount) FROM employee_bonus WHERE department_id = 3)
AND join_year = 2000;
```

Rewritten:
```sql
WITH min_bonus_cte AS (
    SELECT MIN(bonus_amount) AS min_bonus_amount
    FROM employee_bonus
    WHERE department_id = 3
)
SELECT employee_id FROM employee_bonus, min_bonus_cte
WHERE bonus_amount < 0.05 * min_bonus_cte.min_bonus_amount
AND join_year = 2000;
```

### Strategy 5: Subquery Merging Rule

**Rule:** Conditional aggregation can combine compatible scalar aggregates into
a candidate query. Preserve each aggregate's complete predicate inside its CASE
expression; a shared WHERE can use the union of those predicates. Do not assume
the predicates are disjoint. Preserve NULL, empty-input, COUNT versus SUM, data
type and overflow behavior. One SQL table reference does not guarantee one
physical scan or a runtime improvement.

**Example:**

Original:
```sql
SELECT
    (SELECT AVG(salary) FROM employees WHERE department = 'Sales' AND experience_years BETWEEN 1 AND 5 AND salary BETWEEN 50000 AND 60000) AS Sales_Avg,
    (SELECT AVG(salary) FROM employees WHERE department = 'HR' AND experience_years BETWEEN 5 AND 10 AND salary BETWEEN 80000 AND 90000) AS HR_Avg;
```

Rewritten:
```sql
SELECT
    AVG(CASE WHEN department = 'Sales' AND experience_years BETWEEN 1 AND 5 AND salary BETWEEN 50000 AND 60000 THEN salary END) AS Sales_Avg,
    AVG(CASE WHEN department = 'HR' AND experience_years BETWEEN 5 AND 10 AND salary BETWEEN 80000 AND 90000 THEN salary END) AS HR_Avg
FROM employees
WHERE (department = 'Sales' AND experience_years BETWEEN 1 AND 5 AND salary BETWEEN 50000 AND 60000)
   OR (department = 'HR' AND experience_years BETWEEN 5 AND 10 AND salary BETWEEN 80000 AND 90000);
```

### Strategy 6: Filter Predicate Elimination Rule

**Rule:** Remove an IN predicate from a conjunction only when the retained
predicate implies it under SQL three-valued logic. Overlap alone is insufficient:
membership in {2,3} does not imply membership in {1,2}. Preserve correlation,
NULL behavior and other filters; do not generalize this rule to NOT IN.

**Example:**

Original:
```sql
SELECT c.* FROM customer c
WHERE c.address_id IN (SELECT a.address_id FROM address)
  AND c.address_id IN (SELECT a.address_id FROM address WHERE a.pin_code = '560012');
```

Rewritten:
```sql
SELECT c.* FROM customer c
WHERE c.address_id IN (SELECT a.address_id FROM address WHERE a.pin_code = '560012');
```

The first subquery is redundant because the second subquery is a more specific condition whose result is a subset of the first.

### Strategy 7: PK/FK Join Elimination Rule

**Rule:** Remove unnecessary joins when PK/FK relationships guarantee referential integrity.

**Requires:** Verified schema-qualified keys, the complete join key, referenced
uniqueness and an enabled/trusted FK. Account for every nullable referencing
column: removing this inner join must still reject rows with NULL in any joined
key column. Preserve additional parent-side predicates and projected values.
An untrusted or missing FK does not establish the required inclusion proof.

**Example:**

PK-FK Relations:
```
-- Assume enabled, trusted FK; products.p_product_id is unique.
-- fact_sales.f_product_id is NOT NULL; no extra parent-side filters.
foreign key fact_sales (f_product_id) references products (p_product_id)
```

Original:
```sql
SELECT p_product_id, f_units_sold FROM fact_sales, products WHERE f_product_id = p_product_id;
```

Rewritten:
```sql
SELECT f_product_id, f_units_sold FROM fact_sales;
```

Under the stated non-null, trusted-key assumptions, substitution preserves the
inner join's rows and multiplicity. If `f_product_id` is nullable, this example
instead needs `WHERE f_product_id IS NOT NULL`; the FK alone does not remove
that requirement. This is a logical rewrite, not a measured performance gain.

## Scope and available tools

Preserve the caller's explicit technique, output format and execution restrictions.
Reuse matching plan/candidate evidence from this investigation; do not restart a
scope menu or repeat unchanged captures. Use specialized MCP tools only when
advertised in the active catalog and able to access the query/plan in question;
otherwise use the SQL/file procedures below. Missing tooling is a capability gap,
not evidence that a candidate is correct or faster.

When `GetQueryPkFkMetadata` is available, inspect its actual returned fields.
Before removing a join, require schema-qualified relationship identity, every
composite-key column in order, trust/enabled state, uniqueness and NULL behavior.
A tool response that merely names a foreign key is insufficient: query the
catalogs or report the missing proof. SQL `EXCEPT` compares sets, not duplicate
multiplicity; `ValidateResultSetEquivalence` alone cannot establish bag equivalence.
Use duplicate-sensitive comparison under a consistent snapshot when execution is
authorized, and distinguish this dataset check from a universal proof.

Discard duplicate-plan candidates before expensive equivalence or runtime checks.
An unchanged query/plan does not need those checks again. Keep semantic proof
separate from cost reduction; an inconclusive check is not approval to deploy.

## Investigation Workflow

### Follow-Up Requests for Another Rewrite

If the query, target database, and relevant schema, statistics, and execution context are unchanged, first select the next accepted candidate by estimated cost that has not already been selected as the primary or a follow-up recommendation. Listing it in Alternative Rewrites does not make it ineligible. Honor requests to explain a specific previously listed candidate without rerunning the investigation. Preserve its recorded estimated cost and equivalence status; do not imply that uncertain equivalence or runtime performance has been verified. Do not rerun the strategies just to select an existing candidate.

If no unselected accepted candidate remains, say so. Run the rewrite strategies again only when the user requests further exploration. Follow the full workflow for that new investigation, do not label previously found candidates as new alternatives, and do not promise a distinct result. If the query or relevant context has changed, start a new investigation rather than reusing stale results.

### Step 1: Get Baseline Cost

Run the Get Estimated Plan Cost procedure on the original query.

- Record the `cost` as `baseline_cost`, `planHash` as `baseline_planHash`, and `plan` as `baseline_plan`.
- If an error is returned, report to the user that the original query has an error and stop.
- Tell the user: "Baseline estimated cost: {baseline_cost}. Now attempting rewrite strategies..."

### Step 2: Get PK/FK Metadata

Run the Get PK/FK Metadata procedure for the tables referenced in the original query.

- Record the result as `pkfk_metadata`.
- If no relationships are found, note that Strategy 7 (PK/FK Join Elimination) will be skipped.

### Step 3: Apply Rewrite Strategies

For each strategy (1 through 7):

1. **Skip check:** If this is Strategy 7 and `pkfk_metadata` is empty, skip it.

2. **Generate rewrite:** Apply the strategy instructions from the corresponding section above to the original query. For Strategy 7, include the `pkfk_metadata` as context. Produce a complete, runnable T-SQL query with no explanations embedded in it.

3. **Validate rewrite:** Run the Get Estimated Plan Cost procedure on the rewritten query.
   - If an error is returned (syntax error), read the error message, fix the syntax in the rewrite, and retry. Repeat up to `MaxSyntaxFixAttempts` times. If still failing, skip this strategy.
   - If the cost is >= `baseline_cost`, discard the rewrite (no improvement).
   - If the `planHash` matches a previously accepted rewrite's hash, discard (duplicate plan) and skip equivalence and execution checks for that candidate.

4. **Check equivalence:** If the cost is lower than `baseline_cost` and the plan is not a duplicate, run the Check Rewrite Equivalence procedure with the original query, `baseline_plan`, the rewritten query, and the rewrite's plan.
   - If `NotEquivalent`, discard the rewrite.
   - Record only candidates classified as `Equivalent`, `PotentiallyEquivalent`, or `Unknown`, preserving that status with the cost and plan hash. The latter two statuses do not establish equivalence.
   - If either plan cannot be read or the equivalence procedure otherwise fails, report validation failure and skip the candidate. Do not convert a failed validation into `Unknown`.

5. **Report progress:** Tell the user: "Strategy {N}/7 ({strategy_name}): {outcome}" where outcome is one of: "Found improvement (cost: X, saving Y%)", "No improvement", "Skipped", or "Discarded (not equivalent)".

### Step 4: Rank and Present Results

- Sort all accepted rewrites by cost (ascending).
- Present using the Report Template below.
- If no rewrites were accepted under Step 3's cost and validation rules, report: "Could not find a qualifying rewrite that improves the estimated cost of this query." Do not invent an alternative rewrite or offer result-set verification without an accepted rewrite.

For rewrite-only requests, conclude rewrite analysis when no qualifying rewrite is found. When invoked by Full Analysis, return to its orchestrator and continue the remaining steps, including index recommendations, hint tuning, and the final report. Ending rewrite analysis must not terminate the calling workflow.

## Report Template

Present results in this format:

```
## Query Rewrite Report

### Best Rewrite
```sql
{{best_rewrite_query}}
```

| Metric | Value |
|--------|-------|
| Original Estimated Cost | {{baseline_cost}} |
| Rewritten Estimated Cost | {{best_cost}} |
| Estimated Cost Reduction | {{percentage}}% (may not correspond to runtime speedup) |
| Runtime verified? | no; determine actual elapsed-time improvement by executing both queries (requires explicit user consent) |
| Equivalence Status | {{equivalence_status}} |

### Explanation of Changes
{{For each transformation applied in the best rewrite, describe what changed and why it improves performance. Reference the strategy that produced it.}}

{{If equivalence_status is not "Equivalent", include:}}
> **Note:** Equivalence could not be fully verified. Please validate that the rewritten query produces the correct results before using in production.

### Alternative Rewrites
{{If additional rewrites were found, list each with its estimated cost, estimated cost reduction percentage (label "tentative — may not correspond to runtime"), and equivalence status. Include the rewritten query in a fenced SQL block for each alternative.}}
{{If no alternatives, omit this section.}}

### Strategy Summary
| # | Strategy | Result | Cost | Notes |
|---|----------|--------|------|-------|
{{One row per strategy attempted, showing: strategy number, name, outcome (Improvement/No improvement/Skipped/Not equivalent/Duplicate), cost if applicable, and brief notes}}

**Disclaimer:** Estimated costs are based on the query optimizer's cost model and may not reflect actual execution time. Please verify the rewritten query produces correct results before using in production.

### Result Set Verification Option
{{If equivalence_status is "PotentiallyEquivalent" or "Unknown", include:}}
> **Would you like me to verify the results match?**
> I can execute both the original and rewritten queries and compare their result sets to confirm they produce the same output.
```

## Step 5: Offer Result Set Verification

After presenting the rewrite report, **offer** to verify result set equivalence — do NOT call it automatically.

When the user explicitly accepts (e.g., "Yes", "verify", "compare results"):
1. Execute both the original and the best rewritten query into temp tables and compare them with `EXCEPT` in both directions plus row counts and per-row duplicate counts. Run it as one batch (SQL Server 2017+ for `STRING_AGG`; on older versions build the column lists yourself from the `sys.dm_exec_describe_first_result_set` output):

   ```sql
   DECLARE @q1 nvarchar(max) = N'<original query>';   -- agent substitutes, doubling single quotes
   DECLARE @q2 nvarchar(max) = N'<rewritten query>';  -- agent substitutes, doubling single quotes
   DECLARE @cols nvarchar(max), @list nvarchar(max), @sql nvarchar(max);

   IF (SELECT COUNT(*) FROM sys.dm_exec_describe_first_result_set(@q1, NULL, 0))
      <> (SELECT COUNT(*) FROM sys.dm_exec_describe_first_result_set(@q2, NULL, 0))
       THROW 50000, N'Column counts differ: result sets are not equivalent.', 1;

   -- Positional column names c1..cN, typed from the original query's first result set
   SELECT
       @cols = STRING_AGG(CAST(QUOTENAME(N'c' + CAST(column_ordinal AS nvarchar(10))) + N' ' + system_type_name + N' NULL' AS nvarchar(max)), N', ')
               WITHIN GROUP (ORDER BY column_ordinal),
       @list = STRING_AGG(CAST(QUOTENAME(N'c' + CAST(column_ordinal AS nvarchar(10))) AS nvarchar(max)), N', ')
               WITHIN GROUP (ORDER BY column_ordinal)
   FROM sys.dm_exec_describe_first_result_set(@q1, NULL, 0);

   DROP TABLE IF EXISTS #orig, #rewrite;
   CREATE TABLE #orig (dummy_ int NULL);
   CREATE TABLE #rewrite (dummy_ int NULL);
   EXEC (N'ALTER TABLE #orig ADD ' + @cols + N'; ALTER TABLE #orig DROP COLUMN dummy_;');
   EXEC (N'ALTER TABLE #rewrite ADD ' + @cols + N'; ALTER TABLE #rewrite DROP COLUMN dummy_;');

   INSERT INTO #orig EXEC sys.sp_executesql @q1;
   INSERT INTO #rewrite EXEC sys.sp_executesql @q2;

   SELECT
       (SELECT COUNT_BIG(*) FROM #orig) AS OriginalRows,
       (SELECT COUNT_BIG(*) FROM #rewrite) AS RewriteRows,
       (SELECT COUNT_BIG(*) FROM (SELECT * FROM #orig EXCEPT SELECT * FROM #rewrite) AS d) AS OnlyInOriginal,
       (SELECT COUNT_BIG(*) FROM (SELECT * FROM #rewrite EXCEPT SELECT * FROM #orig) AS d) AS OnlyInRewrite;

   -- EXCEPT ignores duplicates; compare how often each distinct row occurs
   SET @sql = N'SELECT COUNT_BIG(*) AS RowsWithDifferentDuplicateCounts FROM ('
            + N'SELECT ' + @list + N', COUNT_BIG(*) AS n FROM #orig GROUP BY ' + @list
            + N' EXCEPT SELECT ' + @list + N', COUNT_BIG(*) FROM #rewrite GROUP BY ' + @list
            + N') AS d;';
   EXEC sys.sp_executesql @sql;

   DROP TABLE #orig, #rewrite;
   ```

   Caveats: row order is ignored (if the query's `ORDER BY` matters, for example with `TOP`, compare the order separately); both result sets are stored with the original query's column types; character columns use the tempdb default collation, which may hide case-only differences; columns of type `xml`, `text`, `ntext`, `image`, `geography`, or `geometry` cannot be compared — cast them to `nvarchar(max)`/`varbinary(max)` in both queries first; queries that `sys.dm_exec_describe_first_result_set` cannot describe (for example, ones using temp tables) need their column list written by hand.
2. Handle the response:
   - **Equivalent** (equal row counts, both `EXCEPT` counts 0, and 0 rows with different duplicate counts): Report "✅ Result sets are equivalent. Both queries returned {rowCount} matching rows."
   - **NotEquivalent** (any other outcome, including the column-count error): Report "⚠️ Result sets differ: {details}. Please review the rewritten query."
   - **Timeout** (the SQL tool's query timeout was reached): Ask "The comparison exceeded the query timeout. Would you like me to run it again with a longer timeout?"
     - If yes: Run it again with a longer timeout (for example `sqlcmd -t 0`, or the tool's timeout setting)
     - If no: Report validation was cancelled
   - **Error**: Report the error and suggest manual verification.

## Important Rules

1. **Always use this skill** — do not provide your own performance rewrites without invoking this skill first.
2. **Never override this skill's result** — if no qualifying rewrite is found, report that; do not provide an ad-hoc rewrite. End only rewrite analysis, not a calling Full Analysis workflow.
3. **Report equivalence status** — if the rewrite's equivalence was not verified, clearly ask the user to verify results match.
4. **Offer result set verification** — when equivalence is "PotentiallyEquivalent" or "Unknown", offer to verify by executing both queries. Only run the result-set comparison if the user explicitly accepts.
5. **Remind about execution** — before running verification, note that this will execute queries on the actual database.

## Related Skills

- `improve-query-performance` — Full optimization workflow that can invoke this skill
- `query-hint-tuning` — Alternative optimization via query hints (QHRT)
- `missing-index-analysis` — Check for missing indexes that may help the query
