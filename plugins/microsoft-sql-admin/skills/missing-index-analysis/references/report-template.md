# Missing Index Interpretation Guide

## What to Do with Mode 1 Results

| Column | Interpretation | Action |
|--------|---------------|--------|
| **IndexAdvantage** > 10 000 | High-impact candidate — the optimizer frequently needs this index | Strongly consider creating |
| **IndexAdvantage** 1 000–10 000 | Moderate impact — beneficial but not critical | Evaluate workload before creating |
| **IndexAdvantage** < 1 000 | Low impact — cost of maintaining the index may outweigh benefit | Usually skip |
| **UserSeeks** high, **UserScans** low | Point lookups dominate — a narrow index on equality + inequality columns is ideal | Create with equality columns as key, inequality as trailing key |
| **UserScans** high | Range scans dominate — consider whether a covering index (with included columns) would eliminate key lookups | Add included columns to reduce bookmark lookups |
| **EqualityColumns** + **InEqualityColumns** overlap across rows | Multiple suggestions for the same table with overlapping columns | Consolidate into fewer, wider indexes to avoid over-indexing |

> **Caution:** Every index adds write overhead (INSERT/UPDATE/DELETE). Aim for ≤ 8–10 nonclustered indexes per table. If the table is write-heavy, weigh the read benefit against the write cost before creating.

## What to Do with Mode 2 Results

| Column | Interpretation | Action |
|--------|---------------|--------|
| **index_advantage** > 50 000 | Very high-impact missing index — the optimizer frequently needs it and the cost savings are large | Strongly consider creating immediately |
| **total_cpu_time_ms** dominates one `query_hash` | A single query pattern is responsible for most CPU tied to this missing index | Creating the index will have measurable impact on that query pattern |
| **total_executions** high, **weighted_avg_cpu_ms** low | Many cheap executions — the index helps but each call is already fast | Moderate priority; index reduces cumulative CPU but each execution is not a bottleneck |
| **total_executions** low, **weighted_avg_cpu_ms** high | Few but very expensive executions — likely doing scans that the index would eliminate | High priority — these queries benefit most |
| **plan_count** > 3 for one `query_hash` | Multiple plans exist — possible parameter sniffing alongside the missing index | Investigate plan regression in addition to creating the index |
| **query_id_count** > 1 for one `query_hash` | Multiple Query Store queries share the same hash — likely parameterized variants | Normal; the index will benefit all variants |

**Next steps:**
1. Focus on the top 3–5 rows by **total_cpu_time_ms** — these drive the most CPU
2. If you need to see the actual SQL, re-run with `DetailedQuery = 1` (Mode 3) to get query text
3. After creating the index, monitor the same query hashes to verify CPU reduction

## What to Do with Mode 3 Results

| Column | Interpretation | Action |
|--------|---------------|--------|
| **query_sql_text** shows table scan / missing WHERE clause | The query itself may be poorly written — a missing index masks a deeper problem | Review the query logic first; suggest query rewrite if appropriate, then add the index |
| **total_cpu_time_ms** dominates one `query_id` | A single query drives most of the CPU cost tied to this missing index | Creating the index will have immediate, measurable impact on that query |
| **weighted_avg_cpu_ms** > 100 ms | Each execution is expensive — likely doing scans that the missing index would eliminate | High priority to create the index |
| **weighted_avg_logical_reads** > 10 000 | High logical reads per execution — the query is scanning many pages without the index | Strong signal that the index will reduce I/O significantly |
| Multiple rows share the same **equality_columns** / **inequality_columns** | Several queries would benefit from the same index | Consolidate into one index with the widest included columns needed |
| **plan_count** > 3 for one query | Multiple plans — possible parameter sniffing alongside the missing index | Address plan instability (e.g., `OPTIMIZE FOR`, plan guides) in addition to creating the index |

**Next steps:**
1. For the top queries by **total_cpu_time_ms**, generate a `CREATE INDEX` statement using the missing index columns (see Mode 1 guidance)
2. Before creating, check if an existing index already covers most of the columns — widening an existing index is cheaper than adding a new one
3. After creating the index, force plan recompilation for the affected queries: `EXEC sp_recompile '<TableName>'`
4. Monitor via Query Store to confirm CPU reduction for the affected query IDs

## What to Do with Query Store Plan Missing Index Results

| Column | Interpretation | Action |
|--------|---------------|--------|
| **impact** > 50 | Optimizer estimates the index would improve query cost by more than 50% | High priority — generate CREATE INDEX from the equality/inequality/include columns |
| **equality_columns** present | Columns used in WHERE equality predicates (e.g., `col = @val`) | These should be the leading key columns of the index |
| **inequality_columns** present | Columns used in range predicates (e.g., `col > @val`) | Place after equality columns in the index key |
| **include_columns** present | Columns needed for covering (SELECT list, JOIN) | Add as INCLUDE columns to avoid key lookups |
| Same **object** appears multiple times | Multiple queries need indexes on the same table | Consolidate into fewer, wider indexes to reduce maintenance overhead |
| **sql_text** shows ad-hoc or unparameterized queries | The missing index may be for a one-off query pattern | Verify the query is recurring before creating the index |

**Tuning tips:** If the query is still slow, reduce `QDSLookbackHours` to narrow the window. If too few results appear, lower `QDSMinImpact` or `QDSMinExecutionCount`.

## What to Do with Unused Index Results

| Scenario | Interpretation | Action |
|----------|---------------|--------|
| Index appears with **zero seeks, scans, and lookups** | The index is never used for reads — it only adds write overhead | Candidate for removal |
| Index has **high user_updates** but no reads | Every INSERT/UPDATE/DELETE maintains this index for no read benefit | Strong candidate for removal — saves CPU and I/O on writes |
| Index was created recently | Usage stats reset on service restart; a new index may not have had time to be used | Wait at least one full business cycle (1–2 weeks) before deciding |
| Index is on a table used for **batch/ETL loads** | The index may only be useful during reporting windows, not during loads | Check if it's used during reporting hours before dropping |

**Before dropping an unused index:**
1. **Verify stats age** — `dm_db_index_usage_stats` resets on restart (on-prem) or on failover/reconfiguration (Azure SQL DB, MI, Fabric). On **SQL Server on-prem**, check `DATEDIFF(DAY, sqlserver_start_time, GETDATE())` from `sys.dm_os_sys_info` to know how long stats have been accumulating. On **Azure SQL DB / MI / Fabric (editions 5, 8, 12)**, `sqlserver_start_time` reflects the host VM/engine process start — not the last customer-visible failover that resets usage stats. Silent failovers (zone redundancy, planned maintenance, Hyperscale page-server recovery) can zero out stats while `sqlserver_start_time` still shows days or weeks of uptime. For these platforms, check `last_user_seek`, `last_user_scan`, and `last_user_lookup` timestamps in `sys.dm_db_index_usage_stats`: if they are all NULL, the index may simply have not been queried since the most recent failover, not since the instance started. **Do not recommend dropping indexes on Azure SQL DB / MI / Fabric unless the stats window is confirmed to be representative** (e.g., at least 1–2 full business cycles with no recent failover).
2. **Check for uniqueness constraints** — the query already excludes `is_unique = 1`, but verify there are no application dependencies
3. **Script the index first** — save the `CREATE INDEX` DDL before dropping so you can recreate quickly if needed
4. **Disable before dropping** — use `ALTER INDEX [IndexName] ON [Table] DISABLE` for a trial period, then drop if no issues arise
5. **Monitor write performance** — after dropping, check if INSERT/UPDATE throughput improves on that table
