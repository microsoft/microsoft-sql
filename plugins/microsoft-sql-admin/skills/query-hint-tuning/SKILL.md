---
name: query-hint-tuning
description: "Use when the user wants to try query hints on a slow SELECT: compare join, parallelism or cardinality estimation hints by estimated cost or measured runtime. For a hint-free rewrite, use `query-rewrite`."
argument-hint: "[QueryText]"
---

# Query Hint Tuning (QHRT)

Use this skill when the user wants to optimize a specific query using query hints. This tests multiple hints and compares plans to find the best one.

## When to Use

- User provides a specific slow SELECT query to optimize with hints
- After identifying CPU, IO, or memory bottlenecks from plan analysis
- User says "tune this query with hints", "try hints", "optimize with OPTION clause", or "find best hint"
- Query has suboptimal join strategy, parallelism issues, or cardinality estimation problems

## When NOT to Use

- Query modifies data (INSERT/UPDATE/DELETE) — only safe for SELECT queries
- User hasn't provided a specific query

## Required tools

- A SQL query tool connected to the target server and database. Prefer, in order: the SQL Tools MCP server that ships with the `microsoft-sql-admin` plugin (`mssql_list_database_connections`, `mssql_connect_database`, then `mssql_execute_query`); any other SQL tool the agent host provides for running T-SQL and reading result sets; [`sqlcmd`](https://learn.microsoft.com/sql/tools/sqlcmd/sqlcmd-utility) from a terminal. If using the SET-based scripts below instead of a dedicated plan tool, the host must interpret `GO` batch separators in one session (or explicitly preserve that session between calls), because `SET SHOWPLAN_XML` and `SET STATISTICS XML` only apply to the session that sets them. Phase 1 is read-only (plans are compiled, not executed); Phase 2 executes the query and runs only with the user's permission. If the SQL Tools MCP server is not connected or lists no connections, follow the `sql-tools-mcp-setup` skill, which asks before installing or configuring anything. If no SQL tool can be made available, give the user the T-SQL to run and ask for the results.

## Prerequisites

- Must be connected to a database — confirm which server and database you are connected to (for example `SELECT @@SERVERNAME, DB_NAME();`)
- Query must be a SELECT statement (no data modifications)
- Query passed to the tuning procedure must NOT contain an existing OPTION clause; preserve its hints as initial candidates before stripping the clause

### SQL Tools MCP session boundary

With SQL Tools MCP, do not send `GO` separators to `mssql_execute_query`, and do not rely on session SET options surviving a second tool call. That tool accepts raw T-SQL, not a sqlcmd script. Prefer `getEstimatedShowplanForQuery` for estimated-plan retrieval; it is in the server's default tool set, so when it is missing the host has filtered the tools or runs an older build. Use `getShowplanWithExecutionStatsForQuery` only with explicit authorization to execute the workload. Call a plan tool once per plan and reuse its result; do not loop re-running the statement through `mssql_execute_query` to compare variants. Otherwise use supplied plan XML or a verified same-session `sqlcmd` capture. Keep estimated-plan capture separate from execution.


## Scope and available tools

Preserve the caller's explicit technique, output format and execution restrictions.
Reuse matching plan/candidate evidence from this investigation; do not restart a
scope menu or repeat unchanged captures. Use specialized MCP tools only when
advertised in the active catalog and able to access the query/plan in question;
otherwise use the SQL/file procedures below. Missing tooling is a capability gap,
not evidence that a candidate is correct or faster.

With the SQL Tools MCP server, `CollectHintCandidates` and
`DetermineBestHintFromCandidates` are available; keep their phases separate:
estimated distinct-plan discovery first, actual measurement only when the
eligible workload is explicitly authorized. Reuse candidate plans; do not
execute every syntactic hint when several produce the same plan. Missing or zero
runtime totals mean the metric is unavailable.

## Workflow

This is a two-phase workflow: Phase 1 is mandatory; Phase 2 is optional and requires explicit user consent.

### Phase 1: Collect Hint Candidates (default — no execution)

Generate a ranked list of recommended hints based on the query or known bottlenecks:

| Bottleneck Type | Recommended Hints |
|-----------------|-------------------|
| Sort/Hash operators (CPU) | `["HASH JOIN", "MERGE JOIN", "USE HINT('FORCE_LEGACY_CARDINALITY_ESTIMATION')"]` |
| Parallelism issues | `["MAXDOP 1", "USE HINT('ENABLE_PARALLEL_PLAN_PREFERENCE')", "MAXDOP 4"]` |
| Cardinality misestimates | `["USE HINT('FORCE_LEGACY_CARDINALITY_ESTIMATION')", "USE HINT('ASSUME_MIN_SELECTIVITY_FOR_FILTER_ESTIMATES')"]` |
| Join order problems | `["FORCE ORDER", "HASH JOIN", "LOOP JOIN", "MERGE JOIN"]` |
| General (unknown) | `["MAXDOP 1", "HASH JOIN", "LOOP JOIN", "FORCE ORDER", "USE HINT('FORCE_LEGACY_CARDINALITY_ESTIMATION')"]` |

If the original query contains hints, include them first in the candidate list and strip its `OPTION` clause before generating the baseline and variants.

Collect the estimated plan for the baseline query and for each hinted variant. A hinted variant is the query with ` OPTION (<hint>)` appended (before any terminating semicolon). Get all estimated plans in **one** request so the session setting applies to every statement:

```sql
SET SHOWPLAN_XML ON;
GO
<query>;                         -- baseline (no hint)
GO
<query> OPTION (MAXDOP 1);       -- one batch per candidate hint
GO
<query> OPTION (HASH JOIN);
GO
SET SHOWPLAN_XML OFF;
GO
```

Nothing is executed while `SHOWPLAN_XML` is on. **Never** send the queries in a separate request on the assumption that `SHOWPLAN_XML` is still on: if the tool does not keep the session, they would execute. From each returned showplan, read `QueryPlanHash` and `StatementSubTreeCost` on the `StmtSimple` element. If a variant returns an error (for example, "Query processor could not produce a query plan because of the hints defined in this query"), record the hint as invalid and continue.

**Interpret results:**
- Filter to only hints with **distinct plan hashes** (different from baseline). If several hints produce the same new plan hash, keep them grouped as one distinct plan.
- Report the best hint by **estimated cost** from the candidates with distinct plans.
- Also list hints that were tried but produced the same plan as baseline (no effect), and hints for which the optimizer could not produce a plan (invalid).

If no hints produce distinct plans, report that and end hint tuning without running Phase 2. Return to the calling workflow, including Full Analysis and its final report, or conclude the standalone request.

If distinct-plan candidates exist, after reporting Phase 1 results, ask:
> "Would you like me to execute the query with these hints to measure actual runtime performance? This will run the query multiple times against the database."

### Phase 2: Find the Best Hint (requires user permission — executes the query)

**Always ask for user permission before proceeding**, as this phase executes the query multiple times against the database and may be long-running or resource-intensive.

**If the user declines, do NOT execute anything.** Present only the Phase 1 estimated cost results.

If the user agrees, measure the baseline and ALL hints with distinct plans from Phase 1 (do not discard any based on estimated cost), with a minimum percentage gain of 50 (configurable):

1. For each variant (baseline first), execute it with actual-plan capture:

   ```sql
   SET STATISTICS XML ON;
   <query> OPTION (<hint>);    -- the baseline has no OPTION clause
   SET STATISTICS XML OFF;
   ```

2. Run each variant twice and use the second run, so every variant is measured with a warm cache.
3. From the actual showplan XML, read:
   - Elapsed time (ms) — `ElapsedTime` on `QueryPlan/QueryTimeStats`
   - CPU time (ms) — `CpuTime` on `QueryPlan/QueryTimeStats`
   - Logical reads — sum of `ActualLogicalReads` over all `RunTimeCountersPerThread` elements

   If `QueryTimeStats` is not present (older versions), use `SET STATISTICS TIME, IO ON` instead and read the elapsed/CPU times and logical reads from the informational messages, if the tool returns them.
4. Improvement % for each metric = (baseline − candidate) ÷ baseline × 100.

The query's own rows are returned on every run; if the result set is large and the tool struggles with it, run the measurements with `sqlcmd` and send its output to a file.

Report best by elapsed time and, if different, by CPU time.

Only recommend hints meeting the configured minimum percentage gain over baseline based on measured elapsed time (default 50%). Phase 1 estimated-cost results remain tentative candidates, not verified runtime gains.

**If the baseline or the measurement run as a whole fails or times out: do NOT automatically retry.** Report the failure and fall back to the tentative Phase 1 estimated-cost results. A single failing candidate is recorded as failed and the others continue. Run Phase 2 at most once per query per tuning attempt. A new attempt requires a new explicit user request and consent to execution.

## Report Template

Present results in this format. Fill every `<...>` field from this run's plans and measurements; they are placeholders, not typical results, and any hint can land in any row.

```
## Query Hint Tuning Results

**Query:** (first 200 chars of query)
**Database:** {{database name}}

### Phase 1: Estimated Cost Comparison (tentative — may not correspond to runtime)

| Hint | Plan Hash | Estimated Cost | vs Baseline (estimated cost only) |
|------|-----------|---------------|-------------|
| No hint (baseline) | <QueryPlanHash> | <StatementSubTreeCost> | — |
| <hint with a distinct plan> | <QueryPlanHash> | <StatementSubTreeCost> | <n>% lower / higher (estimated) |

Hints with same plan as baseline (no effect): <hints, or none>
Hints with no plan (the optimizer could not produce one): <hints, or none>

**Best by Estimated Cost:** `OPTION (<hint>)` — <n>% lower estimated cost. Runtime speedup is **not** guaranteed; run Phase 2 to confirm actual elapsed-time improvement (requires explicit user consent to execute).

### Phase 2: Actual Execution Comparison (if user approved)

| Hint | Elapsed (ms) | CPU (ms) | Logical Reads | vs Baseline |
|------|-------------|----------|---------------|-------------|
| No hint (baseline) | <ms> | <ms> | <reads> | — |
| <hint> | <ms> | <ms> | <reads> | <n>% faster / slower |

**Best by Elapsed Time:** `OPTION (<hint>)` — reduces elapsed time by <n>% (recommend it only at or above the minimum gain)
```

## Important Notes

- Do not present any recommendation other than the measured results from this procedure, unless user specifically asks.
- Report the time spent on each phase so users understand the time investment.
- Tell the user that QHRT helps identify potentially useful hints, but a DBA should use their judgment before applying hints in production.

## Related Skills

- `improve-query-performance` — Full optimization workflow that can invoke this skill
- `slow-query-investigation` — Broader diagnostic workflow for intermittent slow queries
- `missing-index-analysis` — Check for missing indexes before hint tuning
- `investigate-statistics-issues` — Stale statistics can cause bad cardinality estimates
