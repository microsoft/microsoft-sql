---
name: plan-cache-qds-bridge
description: "Use when the user needs one query's cached plan and Query Store history, by text, query_hash, query_id or plan handle, including a query gone from cache. For cache-wide bloat, use `plan-cache-analysis`."
argument-hint: "[query text, query_hash, query_id or plan_handle]"
user-invocable: true
---

# Locate one query across cache and Query Store

Use [the lookup queries](references/query-lookup.md) for identity resolution,
database-scoped lookup, and the cache/history comparison. This is a read-only
investigation; do not flush the cache, enable Query Store, force a plan or execute
the workload just to make evidence appear.

## Scope

- For cache-wide plan cache health, use `plan-cache-analysis`.
- For workload-wide historical regression, use `query-store-investigation`.

## Available capabilities

Use the connected host's SQL query tool: prefer `mssql_execute_query` from the
SQL Tools MCP server that ships with the `microsoft-sql-admin` plugin, or an
already authorized SQL CLI connection. If that server is not connected or lists
no connections, follow the `sql-tools-mcp-setup` skill, which asks before
installing or configuring anything. Verify the selected server/database and
permissions before interpreting absence as a finding.

If the catalog exposes `getEstimatedShowplanForQuery`, it can resolve a complete
statement's optimizer hash without executing the workload. Compilation can still
require permissions, locks and auto-statistics work; skip it when the requested
scope prohibits those effects. Otherwise use the reference's text-search path
and report ambiguity. Do not send `GO` or rely on SET state across independent
raw-query calls. No tool available means provide the diagnostic SQL and identify
what remains unobserved.

## Evidence rules

- Establish Query Store state, capture coverage and the requested time window.
  Missing history can mean disabled capture, retention or permissions, not that a
  query never ran.
- A plan handle identifies a batch and is volatile. Resolve the intended
  statement and offsets before associating it with a query hash. A query hash is
  a matching aid, not proof of semantic identity or database ownership.
- Keep target database, query text/context and statement identity in the join.
  An ad hoc cache row with null database ID is ambiguous; require independent
  database evidence rather than assuming it belongs to this connection.
- Aggregate Query Store intervals using execution-weighted metrics in a common
  time window. Keep regular, aborted and exception executions distinguishable.
  Cache cumulative counters and historical interval averages are different
  populations; report their units and reset/retention limits.
- A changed plan hash is evidence of a different plan, not proof of a regression.
  Compare compatible workload/context and runtime evidence before recommending
  action. Reuse a matching supplied plan or existing compact tool results.

Return query identity and uncertainty, cache observations, historical coverage,
plan differences, and the next smallest useful investigation. When delegated,
preserve the caller's requested scope and output format.
