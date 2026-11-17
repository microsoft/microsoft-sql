# Memory Pressure — Root Cause Decision Tree and Remediation

Use this guide after completing all investigation steps to determine the dominant root cause
and prescribe next steps.

---

## Decision Tree

### `RESOURCE_SEMAPHORE` waiters detected (Step 2 waiter_count > 0 or Step 3 waiting sessions)

State: **"Memory grant starvation — queries cannot obtain memory grants and are blocked waiting. This is the most acute form of memory pressure."**

Next steps:
1. Identify the top grant consumers from Steps 3, 6, and 7 — these are monopolizing the grant pool
2. For over-granted queries: add `OPTION (MAX_GRANT_PERCENT = N)` to limit individual grants
3. Update statistics on tables used by top consumers — stale statistics cause cardinality overestimates and inflated grants
4. Add appropriate indexes to reduce sort/hash memory requirements
5. On Azure SQL: consider temporarily scaling up the SLO to increase available memory
6. On SQL Server: review `max server memory` and Resource Governor resource pool settings

### `MEMORYCLERK_SQLQERESERVATIONS` is a dominant clerk (Step 4)

State: **"Query memory grants are consuming a disproportionate share of memory. Large or numerous sort/hash/bulk operations are the likely cause."**

Next steps:
1. Review Step 3 for active over-granted sessions — queries requesting far more memory than they use
2. Cross-reference with Steps 6–7 to identify the worst historical offenders
3. **SQL Server / MI only:** Consider enabling `Resource Governor` to cap memory grants per workload group. **Azure SQL DB / Fabric:** Resource Governor is not available — use `OPTION (MAX_GRANT_PERCENT = N)` on individual queries, tune queries/statistics to reduce grant sizes, or scale up the service tier (SLO) if grants are legitimately large
4. Review query designs — `ORDER BY` on large result sets, `GROUP BY` without supporting indexes, and `DISTINCT` on wide columns are common causes

### `MEMORYCLERK_SQLBUFFERPOOL` dominant but paired with low available memory or high IO waits

State: **"Buffer pool is under pressure — the data cache cannot hold the working set, causing frequent physical reads."**

Note: Buffer pool being the largest clerk is **normal** in SQL Server. This is only a problem when combined with:
- Low `available_physical_memory_kb` on the OS (Step 1)
- High `PAGEIOLATCH_*` waits
- Low Page Life Expectancy (PLE) on SQL Server on-premises

Next steps:
1. Check for table/index scans in frequently-executed queries — these force large volumes of data into the buffer pool
2. Review missing indexes that could convert scans to seeks
3. On SQL Server: verify `max server memory` is set appropriately (not consuming all OS memory)
4. On Azure SQL: consider scaling up the SLO for more memory

### `OBJECTSTORE_LOCK_MANAGER` consuming significant memory (Step 4)

State: **"Lock manager is consuming excessive memory — many fine-grained locks are being held simultaneously."**

Next steps:
1. Check for long-running transactions holding many row-level locks (use the `check-live-blocking` skill)
2. Review whether lock escalation is disabled on specific tables — check for `LOCK_ESCALATION = DISABLE` in `sys.tables`. If found, consider restoring `AUTO` or `TABLE` to allow SQL Server to escalate fine-grained locks to table locks and reduce lock memory
3. Consider shorter transaction scopes to reduce concurrent lock counts
4. On Azure SQL: large transaction scans with `SERIALIZABLE` isolation level commonly trigger this

### `MEMORYCLERK_HOST` consuming significant memory (Step 4)

State: **"Third-party or external components loaded into the SQL Server process are consuming significant memory."**

Next steps:
1. Identify linked servers, CLR assemblies, or third-party DLLs loaded into SQL Server
2. Review Extended Stored Procedures and OLE Automation objects
3. Check for antivirus or monitoring agents injecting DLLs into the SQL Server process
4. Consider isolating third-party functionality outside the SQL Server process

### `CACHESTORE_SQLCP` consuming significant memory (Step 4)

State: **"SQL plan cache is bloated — likely due to non-parameterized ad-hoc queries generating unique plans."**

Next steps:
1. Enable `Optimize for Ad-hoc Workloads` server setting to reduce single-use plan cache entries
2. Review application code for parameterized query usage
3. Consider `forced parameterization` for workloads with many similar ad-hoc queries

### OOM events detected (Step 5) but no specific clerk or grant dominance

State: **"Out-of-memory events occurred but no single memory consumer dominates. Memory pressure may be from a combination of factors or a transient spike."**

Next steps:
1. On Azure SQL: scale up the SLO temporarily to stabilize, then investigate workload patterns
2. On SQL Server: increase `max server memory` if OS memory is available
3. Review application connection patterns — connection storms can cause transient memory spikes
4. Check for memory leaks by monitoring clerk growth over time

### No active pressure signals but historical grant consumers identified (Steps 6–7)

State: **"No current memory pressure, but the workload includes queries with large memory grants that could cause future pressure under load."**

Next steps:
1. Proactively tune the top grant consumers identified in Steps 6–7
2. Add `OPTION (MAX_GRANT_PERCENT = N)` to queries with consistently over-sized grants
3. Update statistics and indexes for queries with spills
4. Monitor with periodic checks during peak load
