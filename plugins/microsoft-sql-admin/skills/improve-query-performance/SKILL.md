---
name: improve-query-performance
description: "Use when the user asks to optimize, tune, speed up or improve a specific SQL query ('make this faster'), with or without a plan; default when no technique is named. For a rewrite only, use `query-rewrite`."
argument-hint: "[QueryText or ShowplanFilePath]"
---

# Improve Query Performance

Use this skill when the user wants to optimize, tune, or improve a SQL query's performance. Start a bounded first look for generic requests. Follow an explicit request for plans, rewrites, indexes or hints directly; full analysis requires that broader scope.

## When to Use — THIS IS THE DEFAULT SKILL FOR QUERY PERFORMANCE

- User says "optimize this query", "tune this query", "make this faster"
- User says "improve query performance", "this query is slow"
- User says "improve this query", "help me with this query", "help me improve this"
- User says "reduce IO/CPU/duration for this query"
- User wants a comprehensive analysis combining hints, rewrites, and indexes
- User says "why is my query slow", "why is this slow"
- User provides a query or execution plan and asks for performance help
- **Any ambiguous or generic performance request** — when in doubt, use this skill

## When NOT to Use

- User only wants plan metadata (warnings, indexes used, row counts) — read the plan XML directly
- User wants server-level diagnostics (not query-specific) → use `resource-usage-*` or `health-audit-*` skills

## Required tools

- A SQL query tool connected to the target server and database. Prefer, in order: the SQL Tools MCP server that ships with the `microsoft-sql-admin` plugin (`mssql_list_database_connections`, `mssql_connect_database`, then `mssql_execute_query`); any other SQL tool the agent host provides for running T-SQL and reading result sets; [`sqlcmd`](https://learn.microsoft.com/sql/tools/sqlcmd/sqlcmd-utility) from a terminal. If using the SET-based scripts below instead of a dedicated plan tool, the host must interpret `GO` batch separators in one session (or explicitly preserve that session between calls), because `SET SHOWPLAN_XML` and `SET STATISTICS XML` only apply to the session that sets them. Plan, rewrite, index, and hint analysis are read-only by default; anything that executes the query, or creates objects, runs only with the user's permission. If the SQL Tools MCP server is not connected or lists no connections, follow the `sql-tools-mcp-setup` skill, which asks before installing or configuring anything. If no SQL tool can be made available, give the user the T-SQL to run and ask for the results.
- File read access, when the user provides a `.sqlplan` or `.xml` showplan file.

### SQL Tools MCP session boundary

With SQL Tools MCP, do not send `GO` separators to `mssql_execute_query`, and do not rely on session SET options surviving a second tool call. That tool accepts raw T-SQL, not a sqlcmd script. Prefer `getEstimatedShowplanForQuery` for estimated-plan retrieval; it is in the server's default tool set, so when it is missing the host has filtered the tools or runs an older build. Use `getShowplanWithExecutionStatsForQuery` only with explicit authorization to execute the workload. Call a plan tool once per plan and reuse its result; do not loop re-running the statement through `mssql_execute_query` to compare variants. Otherwise use supplied plan XML or a verified same-session `sqlcmd` capture. Keep estimated-plan capture separate from execution.


## Workflow

### Step 1: Bounded first look and requested scope

For a generic request such as "make this query faster", inspect the query text
and supplied evidence immediately. State at most three concrete observations and
which are hypotheses. Do not stop at a scope menu. Reuse a matching supplied plan,
preserving actual counters; otherwise obtain an estimated plan only when a
suitable connected capability and compilation permission are available. With only
a plan, analyze that capture directly. An evidence-only task stays evidence-only.

Check that a supplied capture belongs to the query before using its counters.
If correspondence is uncertain, disclose it; do not attach unrelated runtime
evidence to the query. Reuse an initialized connection. Obtain at most one matching
estimated capture when needed; do not compile again just to obtain its cost.
`RewriteQuery`, when present, returns workflow instructions rather than rewritten
SQL. Follow those instructions only within the requested rewrite scope.

Use available compact metadata/warning tools first when they answer the question;
inspect the relevant XML when they do not. For tools absent from the active
catalog, use the portable procedures in the specialized skills. Do not assume
that a model-visible local file is reachable by a remote MCP process.

Do not infer the chosen access path from query syntax alone. Some conversions,
including date extraction from supported datetime types, can produce an optimizer
range seek. A half-open range is a useful candidate, but confirm the data type,
access and residual predicates, rows read, and matching plan before saying the
original must scan or the rewrite is faster. Without that evidence, label it a
hypothesis and avoid universal rules about functions on indexed columns.

Quick triage ends with the strongest supported finding, remaining uncertainty,
and one useful next investigation. It does not automatically rewrite the query,
try every hint, create indexes or execute the workload. Estimated compilation
is not workload execution, but may take locks or trigger statistics work; respect
stricter requested boundaries.

An explicit plan-only, rewrite-only, index-only or hint-only request goes directly
to that workflow. For explicitly requested full analysis, continue through the
applicable steps without requesting the same scope again. User authorization for
an investigation does not authorize workload execution or schema changes. When
execution has already been explicitly authorized, honor that scope instead of
asking repeatedly; reject ineligible execution even if a tool is available.

### Step 2: Obtain Execution Plan

If the user provides a `.sqlplan` or `.xml` file path, read that file directly.

Otherwise, generate one (see the `plan-analysis` skill for details):
- By default, get an estimated execution plan. This compiles but does not execute the workload; compilation can still require locks, permissions and statistics work. With `sqlcmd` or a verified batch-aware host, send `SET SHOWPLAN_XML ON;`, the query, and `SET SHOWPLAN_XML OFF;` in **one session**, each in its own batch separated by `GO`; the result is the showplan XML. Never send the query in a separate request on the assumption that `SHOWPLAN_XML` is still on — if the tool does not keep the session, the query would execute.
- If the user explicitly agrees to execute the query (or you need actual runtime statistics for deeper analysis), capture the actual plan instead by running the query between `SET STATISTICS XML ON;` and `SET STATISTICS XML OFF;`. **Require explicit authorization for executing the query; reuse authorization already given for this scope**, as it will run against the database and may be long-running or resource-intensive.
- Keep the showplan XML for the later steps; if you have file write access, also save it as a `.sqlplan` file and tell the user the path.

### Step 3: Analyze the Plan

Follow the `plan-analysis` skill workflow. In summary:

1. Run the `plan-analysis` bottleneck procedure to identify cost-dominant subtrees covering ≥80% of total cost.
   - The bottleneck candidates are **signals**, not authoritative answers.
   - Also read the plan XML yourself to identify warnings, missing index hints, cardinality estimate issues, and key lookups.
   - Merge your own analysis with the procedure's signals.

See the `plan-analysis` skill for full details on choosing the right procedure and report template.

Reuse existing actual statistics. Offer runtime capture only when the evidence
is estimated, eligible query text is available and the request permits that next
step. Do not offer execution for a supplied-plan-only or evidence-only task.
When delegated, preserve the caller's output format and requested depth.

### Step 4: Query Rewrite

Follow the `query-rewrite` skill workflow. In summary:

- Run the `query-rewrite` procedure on the original query text: apply its rewrite strategies, keep only rewrites whose estimated cost (from `SET SHOWPLAN_XML`) is lower than the baseline and that are not `NotEquivalent`, and rank them by cost.
- If a valid rewrite is found, present the best one, identify each change, and explain the rationale.
- If no rewrite is accepted, state "The query could not be improved via rewrite" — do **not** provide your own ad-hoc rewrite.
- For a different-rewrite follow-up, use the `query-rewrite` skill's follow-up rules: select an accepted candidate not previously selected as the primary or a follow-up recommendation, even if it was already listed in the report. Preserve its cost and equivalence status. Do not rerun the rewrite strategies merely to select an existing candidate. If none remain, say so; rerun only when the user requests further exploration. A changed query or database context requires a new investigation.

See the `query-rewrite` skill for full details and report template.

### Step 5: Index Recommendations

Use the LLM (no dedicated tool) to suggest index improvements based on:
- The query text and its predicates, joins, and ORDER BY columns
- Missing index hints from the execution plan XML (`<MissingIndexes>` elements)
- The bottleneck analysis from Step 3

Provide `CREATE INDEX` statements with equality columns, inequality columns, and included columns.

**Offer evaluation:** after presenting the candidate `CREATE INDEX` statements, ask the user whether they want you to measure the estimated plan-cost impact of the candidates on this query (for example: "Would you like me to measure the plan-cost impact of these candidate indexes? This creates the indexes, compares the estimated plan, then drops them. Run it on a non-production copy if possible."). Only proceed if the user accepts. Do not run it automatically.

When the user accepts:

1. State that building an index reads the table, takes locks, and uses log and tempdb space, and confirm the target database (prefer a non-production copy with representative data). Use `ONLINE = ON` where the edition supports it.
2. Create each candidate with a recognizable name prefix, for example `CREATE NONCLUSTERED INDEX [eval_IX_Orders_CustomerID] ON dbo.Orders (CustomerID) INCLUDE (OrderDate);`.
3. Get the estimated plan for the query again with `SET SHOWPLAN_XML ON` (see Step 2). Read `StatementSubTreeCost`, check whether the plan uses the new indexes, and report the cost delta vs the baseline.
4. Always drop the indexes you created afterwards, even if an earlier step failed (`DROP INDEX [eval_IX_Orders_CustomerID] ON dbo.Orders;`), and confirm with `SELECT name FROM sys.indexes WHERE name LIKE N'eval[_]%';` that none remain.

If the user declines, or any step fails (for example, insufficient permissions), drop anything you created, say the estimate was not produced, and keep the recommendations based on the plan analysis. For a broader workload-based evaluation, suggest the documented [Database Engine Tuning Advisor](https://learn.microsoft.com/sql/relational-databases/performance/database-engine-tuning-advisor) on SQL Server, or [automatic tuning index recommendations](https://learn.microsoft.com/azure/azure-sql/database/automatic-tuning-overview) on Azure SQL Database.

### Step 6: Query Hint Tuning (QHRT)

Follow the `query-hint-tuning` skill workflow. In summary:

- **Phase 1 (default — no execution):** Get the estimated plan (`SET SHOWPLAN_XML ON`) for the query with each candidate `OPTION (<hint>)` and compare `QueryPlanHash` and `StatementSubTreeCost` with the baseline to find hints that produce distinct plans. Report the best hint by estimated cost.
- **Phase 2 (requires user permission):** Only if the user agrees to execute the query, run the baseline and each distinct-plan hint with `SET STATISTICS XML ON` to measure actual runtime metrics (elapsed time, CPU time, logical reads).

See the `query-hint-tuning` skill for full details, hint selection guide, and report template.

### Step 7: Generate Report

Present the final report using this template:

```
## Query Tuning Report

### Section 1: Baseline Performance Metrics
- Statement: (first 200 chars of query)
- Total Estimated Cost: {{cost}}
- DOP: {{degree of parallelism}}
- Key Bottlenecks: {{bottleneck summary from Step 2}}

### Section 2: Query Rewrite Recommendations

```sql
{{REWRITTEN_QUERY or "No rewrite found"}}
```

### Section 3: Estimated Improvement
- Original Cost: {{original cost}}
- Rewritten Cost: {{rewritten cost}}

#### Explanation of Changes
{{List each transformation applied and its rationale}}

### Section 4: Index Recommendations
{{CREATE INDEX statements with rationale}}

### Section 5: Query Hint Recommendations

#### Candidate Hints Performance Summary
{{Table showing each hint tested, plan hash, estimated cost, elapsed time, CPU time}}
{{List any hints that produced duplicate plans (same plan hash as baseline)}}

#### Best Query Hints
- Best by Elapsed Time: {{hint}} — {{improvement %}}
- Best by CPU Time: {{hint}} — {{improvement %}}

{{If Phase 2 was not run, omit elapsed-time and CPU recommendations and state: "Runtime performance not measured — Phase 1 results are tentative."}}
{{If Phase 2 ran but no hint met its configured minimum percentage gain, report that no hint met the configured elapsed-time improvement threshold over baseline, and include that threshold (default 50%). Only present runtime-qualified recommendations under the `query-hint-tuning` threshold rule.}}

### Summary
{{2-3 sentence summary of findings and top recommendation}}
```

## Important Rules

1. **Base recommendations on the plan-cost comparisons from those procedures, not on ad-hoc opinion.** Do not provide your own hints or rewrites without first running the `query-hint-tuning` or `query-rewrite` procedure and comparing plan costs, and label estimated plan costs as estimates, never as measured results.
2. **Apply the conditional scope gate consistently.** Ask Step 1 only when the request is genuinely ambiguous. When the user explicitly selects or clearly implies an analysis path, proceed with that path without a redundant menu.
3. **Run only the explicitly selected or clearly implied scope.** Do not silently expand it. For a bounded supplied-evidence task, analyze only that evidence and identify anything that cannot be established from it.
4. **State which path you followed** in the final report so the user understands what was explored.
5. **Report the time each step took** so users understand the time investment.
6. **Add a disclaimer** asking the user to verify generated results before applying to production.

## Related Skills

- `missing-index-analysis` — DMV-based missing index analysis for a database or table
- `slow-query-investigation` — Broader diagnostic workflow for intermittent slow queries from Query Store data
- `investigate-statistics-issues` — Stale statistics can cause bad cardinality estimates and suboptimal plans
