---
name: plan-analysis
description: "Use when the user supplies an execution plan (showplan XML, .sqlplan) or asks to explain or check one: costly operators, spills, misestimates. Has tested rules common answers miss, e.g. subtree costs are inclusive. For end-to-end tuning, use `improve-query-performance`."
argument-hint: "[ShowplanFilePath]"
---

# Execution Plan Analysis

Use this skill when the user wants to understand or analyze a SQL Server execution plan. This provides plan summaries, operator cost rankings, and bottleneck identification — all without executing any queries.

## When to Use

- User says "analyze this plan", "explain this execution plan", "find bottlenecks"
- User asks to explain why the supplied plan is slow, limited to plan analysis
- User says "what are the most expensive operators?", "top costly operators"
- User says "summarize this plan", "give me an overview"
- User provides a query and wants to see its estimated plan

## When NOT to Use

- Generic query performance requests, including "why is this query slow?" with a supplied plan, belong to `improve-query-performance`; use this skill when plan analysis itself is requested or delegated.
- User wants server-wide diagnostics → use the `resource-usage-*` or `health-audit-*` skills
- User asks only about plan metadata (warnings, indexes used, row counts, tables accessed) → read the plan XML directly without running the ranking or bottleneck procedures

## Required tools

- File read access, to read a `.sqlplan` or `.xml` showplan file the user provides.
- Only when the user provides a query instead of a plan: a SQL query tool connected to the target server and database. Prefer, in order: the SQL Tools MCP server that ships with the `microsoft-sql-admin` plugin (`mssql_list_database_connections`, `mssql_connect_database`, then `mssql_execute_query`); any other SQL tool the agent host provides for running T-SQL and reading result sets; [`sqlcmd`](https://learn.microsoft.com/sql/tools/sqlcmd/sqlcmd-utility) from a terminal. If using the SET-based scripts below instead of a dedicated plan tool, the host must interpret `GO` batch separators in one session (or explicitly preserve that session between calls), because `SET SHOWPLAN_XML` and `SET STATISTICS XML` only apply to the session that sets them. If the SQL Tools MCP server is not connected or lists no connections, follow the `sql-tools-mcp-setup` skill, which asks before installing or configuring anything. If no SQL tool can be made available, give the user the T-SQL to run and ask for the resulting plan XML.

### SQL Tools MCP session boundary

With SQL Tools MCP, do not send `GO` separators to `mssql_execute_query`, and do not rely on session SET options surviving a second tool call. That tool accepts raw T-SQL, not a sqlcmd script. Prefer `getEstimatedShowplanForQuery` for estimated-plan retrieval; it is in the server's default tool set, so when it is missing the host has filtered the tools or runs an older build. Use `getShowplanWithExecutionStatsForQuery` only with explicit authorization to execute the workload. Call a plan tool once per plan and reuse its result; do not loop re-running the statement through `mssql_execute_query` to compare variants. Otherwise use supplied plan XML or a verified same-session `sqlcmd` capture. Keep estimated-plan capture separate from execution.


## Workflow

Reuse a supplied matching capture and any compact analysis already produced for
that capture. Do not replace actual statistics with a new estimated plan. When
another workflow delegates a specific question, return that answer in its format
instead of restarting scope selection or producing an unrelated full report.

### Optional specialized tools

With the SQL Tools MCP server, `SummarizePlan` and `GetPlanWarnings` provide
compact metadata; `PlanBottleneckAnalysis` provides candidate bottlenecks;
`PlanOperatorAnalysis` provides the requested cost, elapsed-time or CPU ranking.
They read a plan from a file path, `planXml`, a Query Store `queryStorePlanId` or
a plan-cache `planHandle`, so a plan found by query needs no re-execution. Use
only the calls needed for the question (one call per tool per plan), and reuse
their results for the same capture. A tool's file path must be reachable in that
tool's environment; a local host path is not automatically a server path.
When these tools are absent, read the supplied XML and use the bundled calculator
for estimated own-cost ranking.

For CPU ranking, use actual CPU counters and a CPU denominator; elapsed time is
not a substitute. Do not infer a specific wait type from elapsed-minus-CPU alone,
or sum inclusive/overlapping operator counters into a query total. Report the
observed metric and use separate wait/runtime evidence for causal attribution.
If actual counters or the relevant query total are missing or
zero, report the metric unavailable rather than rank placeholder zeros. Do not
execute a query solely to fill that gap unless execution is already authorized
and eligible in the requested scope.

### Step 1: Obtain the Plan

If the user provides a `.sqlplan` or `.xml` file path, read that file directly (it is showplan XML).

If the user provides a query instead:
- By default, get the **estimated plan**. This compiles without executing the workload; compilation can still take locks or trigger statistics work. With `sqlcmd` or a verified batch-aware host, send all of the following in **one session**, with each `SET SHOWPLAN_XML` in its own batch:

  ```sql
  SET SHOWPLAN_XML ON;
  GO
  <the user's query>
  GO
  SET SHOWPLAN_XML OFF;
  GO
  ```

  The query is compiled but not executed; the result is one row per statement with a single XML column containing the showplan. **Never** send the query in a separate request on the assumption that `SHOWPLAN_XML` is still on: if the tool does not keep the session, the query would execute. If the tool cannot send `GO`-separated batches in one request or keep a session, use `sqlcmd` or ask the user to capture the estimated plan.
- Only get the **actual plan** (with runtime statistics) if the user explicitly agrees to execute the query. **Require explicit authorization; reuse authorization already given for this scope** — the query runs against the database and may be long-running or resource-intensive:

  ```sql
  SET STATISTICS XML ON;
  <the user's query>
  SET STATISTICS XML OFF;
  ```

  The query's own result sets are returned first, followed by a result set with the actual showplan XML.
- If you have file write access, save the XML as a `.sqlplan` file so the user can open it graphically (for example in SSMS), and tell the user the path.

### Step 2: Plan Summary

Read the showplan XML (namespace `http://schemas.microsoft.com/sqlserver/2004/07/showplan`) and build a high-level overview for each statement (`StmtSimple` element):
- Statement text — `StatementText` attribute
- Total estimated cost — `StatementSubTreeCost` attribute
- Degree of parallelism (DOP) — `DegreeOfParallelism` attribute on `QueryPlan` (absent or 1 for serial plans)
- Memory grant info (requested/granted/max used) — `RequestedMemory`, `GrantedMemory`, `MaxUsedMemory` on `QueryPlan/MemoryGrantInfo` (granted and max used are only meaningful in actual plans)
- Plan hash — `QueryPlanHash` attribute (useful when comparing plans)

### Step 3: Choose Analysis Based on User Intent

The ranking and bottleneck procedures below work on the `RelOp` elements of the plan. For each `RelOp`, note `NodeId`, `PhysicalOp`, `LogicalOp`, `EstimateRows`, and `EstimatedTotalSubtreeCost`. Its direct child operators are the `RelOp` elements one operator element down (`RelOp/*/RelOp`). Compute:
- **Own cost** = the operator's `EstimatedTotalSubtreeCost` minus the sum of its direct child `RelOp`s' `EstimatedTotalSubtreeCost` (floor at 0).
- **Cost %** = own cost ÷ the statement's `StatementSubTreeCost` × 100.

For reproducible ranking, prefer the bundled local Python 3 helper: `python scripts/plan_costs.py <plan.sqlplan> --top 5` (resolve the script relative to this skill). It rejects DTD/entity declarations, duplicate IDs and invalid statement costs, keeps statements separate, uses decimal arithmetic, floors own cost at zero, and breaks ties by NodeId. Run it on the complete supplied XML; do not manually retype a large plan. Record parser failures instead of inventing a ranking. This reads a local file and does not execute SQL. Estimated cost is not elapsed time or proof of a runtime bottleneck. If Python is unavailable, explicitly use the same calculation rules below.

You can also let SQL Server do the arithmetic (read-only; the agent substitutes the plan XML as a Unicode string literal, doubling any single quotes):

```sql
DECLARE @plan xml = N'<ShowPlanXML ...>'; -- substitute XML, escape single quotes
WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
SELECT s.value('@StatementId', 'int') AS StatementId,
       r.value('@NodeId', 'int') AS NodeId,
       r.value('@PhysicalOp', 'nvarchar(128)') AS PhysicalOp,
       CASE WHEN c.RawOwnCost < 0 THEN 0 ELSE c.RawOwnCost END AS OwnCost
FROM @plan.nodes('//StmtSimple') AS statements(s)
CROSS APPLY s.nodes('QueryPlan//RelOp') AS operators(r)
CROSS APPLY (SELECT r.value('@EstimatedTotalSubtreeCost', 'decimal(38,15)')
    - ISNULL(r.value('sum(*/RelOp/@EstimatedTotalSubtreeCost)', 'decimal(38,15)'), 0)) AS c(RawOwnCost)
ORDER BY StatementId, OwnCost DESC, NodeId;
```

For a plan with several statements, analyze each `StmtSimple` separately.

**For bottleneck investigation** ("find bottlenecks", "why is this query slow?", "identify performance issues", "where to focus optimization"):

1. Analyze the plan XML yourself — identify warnings, missing index hints, cardinality estimate issues, key lookups, spills.
2. Find the cost-dominant subtrees: a minimal set of subtree roots whose combined cost covers ≥80% of total estimated cost.
   1. Start with the set `{root RelOp}`.
   2. Take the node in the set with the largest `EstimatedTotalSubtreeCost` that has child `RelOp`s and is not marked final. Tentatively replace it with its direct children. Keep the replacement if the set's summed `EstimatedTotalSubtreeCost` is still ≥80% of `StatementSubTreeCost`; otherwise undo it and mark the node final.
   3. Repeat step 2 until no node in the set can be replaced.
   4. Drop the cheapest subtrees from the set while the remaining total stays ≥80%.
   - The resulting subtrees are **signals**, not authoritative answers.
3. Merge your own analysis with these signals — confirm, supplement, or skip signals based on your judgment.

**For operator cost ranking** ("top expensive operators", "rank operators by cost", "most costly operators", "which operator takes the most time"):

Rank the `RelOp` operators by own cost (cost %), highest first.
- **Estimated cost** ranking works for all plans.
- **Elapsed time** ranking is only available when the plan includes actual execution statistics (i.e., an actual plan captured with `SET STATISTICS XML ON`). Do not use elapsed time on estimated-only plans. Use `ActualElapsedms` from `RunTimeInformation/RunTimeCountersPerThread` (take the maximum across threads). For row-mode operators this value includes the time of their child operators, so subtract the children's elapsed time to get the operator's own time; batch-mode operators (`ActualExecutionMode="Batch"`) report only their own time.
- For CPU time questions, read the plan XML directly for `ActualCPUms` attributes.

**For plan metadata questions** (warnings, indexes used, row counts, tables accessed, missing indexes, UDFs/TVFs, special optimizations):

Do NOT run the ranking or bottleneck procedures — read the plan XML directly. Examples:
- Warnings → `<Warnings>` elements
- Indexes used → `IndexScan`/`IndexSeek` nodes
- Tables accessed → table references from operator nodes
- Estimated vs actual rows → `EstimateRows` vs `ActualRows` attributes
- Missing index hints → `<MissingIndexes>` elements
- UDFs/TVFs → `ScalarFunction`/`TableValuedFunction` operators
- Top operators by logical/physical reads → `ActualLogicalReads`/`ActualPhysicalReads` from `<RunTimeCountersPerThread>`

CPU, elapsed-time, and read rankings require an actual execution plan containing the relevant runtime counters. If they are absent, report that the supplied plan cannot support the requested ranking. Never execute the query to obtain missing counters without explicit user consent.

### Step 4: Report Findings

Present the analysis in a clear format:

```
## Execution Plan Analysis

### Plan Overview
- Statement: (first 200 chars)
- Total Estimated Cost: {{cost}}
- DOP: {{degree of parallelism}}
- Memory Grant: {{requested}} / {{granted}} / {{max used}}

### Bottleneck Analysis
{{For each bottleneck identified:}}
- **{{Operator}} at Node {{id}}**: {{description of the issue and why it's costly}}

### Top Operators by Cost
| Node | Operator | Cost % | Description |
|------|----------|--------|-------------|
| {{id}} | {{operator}} | {{pct}} | {{brief note}} |

### Warnings & Issues
{{List any plan warnings, cardinality misestimates, missing indexes, spills, key lookups}}

### Recommendations
{{Brief suggestions: consider adding indexes, update statistics, review join strategy, etc.}}
```

## Important Rules

1. **Operator cost ranking is ONLY for cost/time ranking questions** — do not use it for metadata questions (warnings, indexes, row counts, etc.).
2. **The bottleneck procedure is for bottleneck investigation** — do not answer "why is this slow?" or "find bottlenecks" with a plain operator ranking.
3. **You CAN read plan files** — when the user provides a file path, read the file directly. Do NOT say you cannot access files.
4. **Do not execute queries** without user permission — default to the estimated plan (`SET SHOWPLAN_XML ON`) for plan generation.

## Related Skills

- `improve-query-performance` — Full optimization workflow that includes plan analysis as a step
- `query-hint-tuning` — Test query hints after identifying bottlenecks
- `query-rewrite` — Rewrite the query for better performance
