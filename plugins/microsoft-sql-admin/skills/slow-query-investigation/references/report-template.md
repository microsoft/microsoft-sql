# Slow Query Investigation — Report Template & Decision Tree

## Report Template

Combine the results from Steps 1–6 into this unified report format. Steps 3–6 are optional
depth-enhancers — include their sections only when their queries return actionable data.

```
## Slow Query Investigation Report
Database: {{database name}}
Date: {{current date in YYYY-MM-DD format}}
SQL Server: {{SQL Version}} ({{Engine Type}})
Query Store: {{Query Store State}} | Wait Stats: {{Wait Stats Available}}
Data Source: {{Query Store if active, else DMV fallback}}
Lookback: {{LookbackMinutes}} minutes

---

### Overview

{{If Step 1 returned no volatile queries:}}
"No queries with significant performance variability were found in Query Store
over the last {{LookbackMinutes}} minutes. This could mean the issue is not
currently occurring, or the lookback window needs to be expanded."
{{STOP HERE — skip remaining sections. Suggest expanding lookback to 1440 minutes (24 hours).}}

{{If volatile queries were found:}}
"{{count}} queries with significant performance variability were identified.
The dominant wait category is **{{dominant category}}**, indicating
{{1-sentence assessment of the situation}}."

---

### Top Volatile Queries

| Query ID | Query Hash | Plan Count | Executions | Min Dur (ms) | Max Dur (ms) | Avg Dur (ms) | CV% |
|----------|------------|------------|------------|--------------|--------------|--------------|-----|
{{Limit to top 10 rows.}}
{{CV% interpretation: < 50% moderate variability, 50-100% high, > 100% extreme}}

---

### Wait Category Analysis

#### Wait Category Summary

| Wait Category | Total Wait Time (ms) | # Queries Affected | Assessment |
|---------------|---------------------|--------------------|------------|
{{One row per wait category, aggregated across all queries, sorted by total wait time descending}}
{{Assessment: plain language interpretation of what this wait category means}}

#### Primary Root Cause

{{Use the decision tree below to state the root cause clearly.}}

---

### Plan Regression Analysis

{{If Step 3 returned results:}}

| Query ID | Query Hash | Historical Avg (ms) | Recent Avg (ms) | Regression Factor | Plan Count |
|----------|------------|---------------------|------------------|-------------------|------------|
{{Limit to top 5 rows. Regression Factor > 2× is significant, > 5× is severe.}}

{{If no regressions found: omit this section entirely.}}

---

### Parameter Sniffing Suspects

{{If Step 4 returned results, group by Query ID and show per-plan stats:}}

#### Query ID: {{query_id}}
| Plan ID | Forced? | Avg Duration (ms) | Avg CPU (ms) | Avg Reads | Executions | Avg Rows |
|---------|---------|-------------------|--------------|-----------|------------|----------|
{{If the fastest plan is 3× faster than the slowest plan, flag as "confirmed parameter sniffing."}}
{{If only one plan per query: omit this section entirely.}}

---

### Time-of-Day Performance Pattern

{{If Step 5 returned results:}}

| Hour (UTC) | Active Queries | Avg Duration (ms) | Max Avg Duration (ms) | Executions | Avg CPU (ms) |
|------------|---------------|-------------------|----------------------|------------|--------------|
{{Highlight hours with Avg Duration > 2× the daily average as "contention windows."}}
{{If pattern is flat: state "No significant time-of-day correlation detected."}}

---

### Statistics Health

{{If Step 6 returned stale statistics:}}

| Table | Statistic | Last Updated | Rows | Modifications | Mod % | Sample % |
|-------|-----------|-------------|------|---------------|-------|----------|
{{Flag Mod % > 20% as "stale — likely causing plan quality issues."}}
{{If all statistics are current: state "No stale statistics detected."}}

---

### Affected Queries Detail

{{For each of the top 5 most affected queries (by total wait time):}}

#### Query ID: {{query_id}} (Query Hash: {{query_hash}})
- **Wait Category**: {{dominant wait category for this query}}
- **Avg Duration**: {{avg_duration}} ms (range: {{min}} — {{max}} ms)
- **Coefficient of Variation**: {{CV%}} — {{interpret: < 50% moderate, 50-100% high, > 100% extreme}}
- **Plan Count**: {{number of distinct plans}} {{if > 1: "⚠ Multiple plans detected — possible plan regression or parameter sniffing"}}

> **Note**: Query hash is provided instead of SQL text to identify the query. Use the query hash
> with Query Store or plan cache DMVs to retrieve the full query text if needed.

---

### Recommended Next Steps

{{Based on the primary root cause, provide specific next steps:}}
```

## Root Cause Decision Tree and Next Steps

Use the results from all steps to determine the primary root cause. Multiple root causes
may coexist — list all that apply, ranked by impact.

> **Recommendations only.** Every state-changing command in these next steps (`KILL`,
> `sp_query_store_force_plan`, `sp_query_store_unforce_plan`, `sp_query_store_set_hints`,
> `sp_create_plan_guide`, `UPDATE STATISTICS`, `ALTER DATABASE ... SET ...`) goes into the report as
> a recommendation. Never run one without the user's explicit confirmation for that specific
> command, and state its impact and rollback in the report before asking.

### If Lock (Blocking) is dominant:

State: **"Blocking is the primary cause of intermittent slowness. Queries are waiting to acquire locks held by other sessions."**

Next steps:
1. Check for active blocking right now using the `check-live-blocking` skill
2. Use the `query-store-volatile-historical-slow-queries-comparison` skill with the suspect query ID to compare slow vs fast intervals
3. If blocking is intermittent and cannot be caught live, set up targeted monitoring using the `create-xe-session` skill filtered to the suspect query to capture the blocker's identity next time it occurs
4. After the XE session captures data, run the `blocking-root-cause-analysis` skill for full analysis
5. Review isolation levels — consider `READ COMMITTED SNAPSHOT` to reduce lock contention

### If CPU is dominant:

State: **"CPU contention is the primary cause. Check for plan regressions, parameter sniffing, or resource throttling."**

Next steps:
1. Check for queries with multiple plans (Plan Count > 1) — these are candidates for plan regression
2. Use the `query-store-volatile-historical-slow-queries-comparison` skill with suspect query IDs to identify when CPU usage changed
3. Run the `investigate-sql-cpu-pressure` skill for a deep-dive into CPU-specific diagnostics
4. Consider recommending a known-good execution plan be forced via `sp_query_store_force_plan` (only after explicit user confirmation)
5. Review parameter sniffing if queries use parameters with skewed data distributions

### If Plan Regression is detected (Step 3):

State: **"Plan regression detected. {{count}} queries show recent performance degradation of {{max_factor}}× compared to their historical baseline. This is a primary cause of intermittent slowness."**

Next steps:
1. Cross-reference with Step 4 — if the regressed query also has multiple plans, this is likely parameter sniffing
2. Use the `query-store-volatile-historical-slow-queries-comparison` skill to pinpoint exactly when the regression started
3. Use the `query-store-investigation` skill to identify the best historical plan and generate `sp_query_store_force_plan` commands
4. Review Step 4 across all returned queries for a broader view of plan instability
5. Check if an index was dropped, a schema changed, or statistics were updated around the regression time
6. If Query Store shows a known-good plan, recommend forcing it (run only after the user explicitly confirms; roll back with `sp_query_store_unforce_plan`):
   ```sql
   EXEC sp_query_store_force_plan @query_id = {{query_id}}, @plan_id = {{good_plan_id}};
   
```

### If Parameter Sniffing is detected (Step 4):

State: **"Parameter sniffing is causing plan instability. Queries compile plans optimized for one parameter value that perform poorly for other values, leading to intermittent slowness."**

Next steps:
1. Compare per-plan performance — if the fastest plan is > 3× faster than the slowest, this is confirmed parameter sniffing
2. Review the complete Step 4 result set to see all multi-plan queries in scope
3. Remediation options to recommend (in order of preference; each only after explicit user confirmation):
   - **Force a good plan**: `EXEC sp_query_store_force_plan @query_id = {{id}}, @plan_id = {{best_plan}};`
   - **Enable Query Store Hints** (SQL Server 2022+ / `Major Version` >= 16 from Step 0): `EXEC sp_query_store_set_hints @query_id = {{id}}, @query_hints = N'OPTION (OPTIMIZE FOR UNKNOWN)';`
   - **RECOMPILE hint**: Add `OPTION (RECOMPILE)` if execution frequency is low
   - **Plan guides**: Use `sp_create_plan_guide` for queries that cannot be modified
4. Run the `investigate-statistics-issues` skill — stale statistics amplify parameter sniffing effects

### If IO is dominant:

State: **"IO contention is the primary cause. Check for missing indexes, resource throttling, or competing I/O-heavy workloads."**

Next steps:
1. Run the `missing-index-analysis` skill for missing index recommendations on affected queries
2. Review logical reads — high values indicate table scans or inefficient access patterns
3. Run the `investigate-sql-data-io-pressure` skill for a deep-dive into IO-specific diagnostics
4. Check Azure SQL resource limits (DTU/vCore IO caps) with `sys.dm_db_resource_stats`
5. Consider adding covering indexes to reduce key lookups
6. Run the `table-health-check` skill on frequently accessed tables to check for fragmentation

### If Memory is dominant:

State: **"Memory grant issues are the primary cause. Check for bad cardinality estimates or queries requesting excessive memory."**

Next steps:
1. Review execution plans for Sort or Hash warnings (spills to tempdb)
2. Update statistics on affected tables — run the `investigate-statistics-issues` skill to identify stale stats
3. Check for queries with large memory grants relative to actual usage
4. Enable Memory Grant Feedback if available (`Major Version` >= 15 from Step 0, SQL Server 2019+)
5. Run the `investigate-sql-cpu-pressure` skill — memory grant waits can cascade into CPU contention

### If Network is dominant:

State: **"Network latency is the primary cause. Investigate client-side issues or connectivity problems."**

Next steps:
1. Check if affected queries return large result sets
2. Investigate client-side network connectivity
3. Consider reducing result set sizes with pagination
4. Review application connection pooling configuration

### If Stale Statistics are detected (Step 6):

State: **"Stale statistics detected on {{count}} tables. Outdated statistics cause the query optimizer to choose suboptimal plans, which can lead to intermittent performance degradation as data distributions change."**

Next steps:
1. Recommend updating statistics on the most stale tables (a `FULLSCAN` reads the whole table and can trigger recompiles; run only after the user explicitly confirms):
   ```sql
   UPDATE STATISTICS [schema].[table] WITH FULLSCAN;
   
```
2. Run the `investigate-statistics-issues` skill for a comprehensive statistics health report
3. Review automatic statistics update settings — consider enabling `AUTO_UPDATE_STATISTICS_ASYNC`
4. For very large tables, consider incremental statistics or targeted updates
5. Monitor whether plan quality improves after statistics update

### If Time-of-Day Correlation is found (Step 5):

State: **"Performance degradation clusters during specific hours ({{peak_hours}} UTC), suggesting workload contention, batch job interference, or resource throttling during peak usage."**

Next steps:
1. Identify what workloads run during contention windows (ETL, reporting, backups)
2. On Azure SQL, query `sys.dm_db_resource_stats`; on SQL Server, use the `resource-usage-sqlserver` skill to correlate with resource consumption
3. Consider staggering batch jobs to reduce overlap with OLTP workload
4. Review Resource Governor configuration to isolate workload groups
5. If on Azure SQL, check for elastic pool resource contention or DTU throttling

### If No Root Cause Is Clearly Dominant:

State: **"No single dominant root cause was identified. The intermittent slowness may be caused by a combination of factors or may not be active during the lookback window."**

Next steps:
1. Expand the lookback window — re-run with `LookbackMinutes = 1440` (24 hours) or `10080` (7 days)
2. Run the `query-store-volatile-historical-slow-queries-comparison` skill for a broader historical view
3. Set up an Extended Events session using the `create-xe-session` skill to capture slow queries proactively
4. Run the `plan-cache-analysis` skill to check for plan cache bloat from ad-hoc query storms
5. Check server-level health using the `health-audit-sqlserver` skill or the `database-config-azuresql` skill

## Related Skills Reference

These skills provide deeper drill-down capabilities referenced in the next steps above:

| Skill | When to Use |
|-------|-------------|
| `query-store-volatile-historical-slow-queries-comparison` | Standalone volatile query detection and historical slow query triage (combines Steps 1 analysis with historical comparison) |
| `wait-category-analysis` | Standalone wait analysis (Step 2 in isolation) |
| `query-store-investigation` | Find regressed queries and generate plan-forcing commands |
| `check-live-blocking` | Capture currently active blocking chains |
| `blocking-root-cause-analysis` | Analyze blocking data from XE sessions |
| `create-xe-session` | Set up proactive blocking monitoring |
| `investigate-sql-cpu-pressure` | Deep-dive CPU pressure investigation |
| `investigate-sql-data-io-pressure` | Deep-dive IO pressure investigation |
| `missing-index-analysis` | Find missing indexes correlated to slow queries |
| `investigate-statistics-issues` | Comprehensive statistics health assessment |
| `top-queries-noqds` | Fallback when Query Store is not enabled |
| `plan-cache-analysis` | Detect plan cache bloat and ad-hoc query storms |
| `resource-usage-sqlserver` | SQL Server resource consumption metrics |
| `table-health-check` | Index fragmentation and table health |
