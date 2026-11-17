# Volatile Query Investigation — SQL Queries

Run all queries with the SQL query tool. Replace {{parameter}} placeholders with values from the skill parameters.

## Platform Detection

**Run this check first** to identify the SQL platform and block unsupported environments.

Execute this query:

```sql
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

SELECT
      @EngineEdition AS engine_edition
    , CASE @EngineEdition
        WHEN 1 THEN 'Personal / Desktop'
        WHEN 2 THEN 'Standard'
        WHEN 3 THEN 'Enterprise'
        WHEN 4 THEN 'Express'
        WHEN 5 THEN 'Azure SQL Database'
        WHEN 6 THEN 'Azure Synapse Analytics - Dedicated SQL pool'
        WHEN 8 THEN 'Azure SQL Managed Instance'
        WHEN 9 THEN 'Azure SQL Edge'
        WHEN 11 THEN 'Azure Synapse serverless SQL pool / Fabric Warehouse'
        WHEN 12 THEN 'Fabric SQL Database'
        ELSE 'Unknown (' + CAST(@EngineEdition AS VARCHAR(10)) + ')'
      END AS edition_name
    , CASE
        WHEN @EngineEdition IN (6, 11) THEN 1
        ELSE 0
      END AS is_unsupported_dw
    , SERVERPROPERTY('ProductVersion') AS product_version;
```

> **If `is_unsupported_dw = 1`:** Stop and inform the user that this skill is not applicable to Azure Synapse Analytics (edition 6) or Azure Synapse serverless SQL pool / Fabric Warehouse (edition 11). Query Store on these platforms has a fundamentally different architecture and the queries in this skill may return errors or misleading results.
>
> **Fabric SQL DB (edition 12):** Treat the same as Azure SQL Database — Query Store is fully supported.

## Step 0: Query Store Health Check

**Always run this step first** to confirm Query Store is enabled, capturing data, and not in a
degraded state. If Query Store is read-only, historical data may still be available — proceed with subsequent steps but note that new data is not being captured. Even if Query Store is off, previously collected data may still exist depending on when it was turned off.

Execute this query:

```sql
DECLARE @MajorVersion INT = CAST(SERVERPROPERTY('ProductMajorVersion') AS INT);
DECLARE @sql NVARCHAR(MAX);

SET @sql = N'
SELECT
      actual_state_desc           AS [QDS State]
    , readonly_reason             AS [Read-Only Reason]
    , desired_state_desc          AS [Desired State]
    , current_storage_size_mb     AS [Current Size (MB)]
    , max_storage_size_mb         AS [Max Size (MB)]
    , CAST(current_storage_size_mb * 100.0 / NULLIF(max_storage_size_mb, 0)
        AS NUMERIC(5,1))          AS [Storage Used %]
    , interval_length_minutes     AS [Interval Length (min)]
    , stale_query_threshold_days  AS [Stale Query Threshold (days)]
    , query_capture_mode_desc     AS [Capture Mode]
    , size_based_cleanup_mode_desc AS [Cleanup Mode]
    , max_plans_per_query         AS [Max Plans Per Query]'
    -- wait_stats_capture_mode_desc is only available on SQL Server 2017+ (major version >= 14)
    + CASE WHEN @MajorVersion >= 14
           THEN N', wait_stats_capture_mode_desc AS [Wait Stats Capture]'
           ELSE N', N''N/A (requires SQL 2017+)'' AS [Wait Stats Capture]'
      END
    + N'
FROM sys.database_query_store_options
OPTION (MAXDOP 1);'

EXEC sp_executesql @sql;
```

### Interpreting Step 0 Results

| Condition | Impact | Action |
|-----------|--------|--------|
| `QDS State` = `OFF` | Not capturing new data — but historical data may still exist if Query Store was previously enabled | Try running subsequent steps; if data is returned it is still valid for analysis. Recommend re-enabling: `ALTER DATABASE CURRENT SET QUERY_STORE = ON` |
| `QDS State` = `READ_ONLY` | Not capturing new data — but all previously collected data is still queryable and valid | Proceed with analysis using existing data. Check `Read-Only Reason` to resolve: storage full → increase `max_storage_size_mb`; secondary replica → expected behavior |
| `QDS State` = `ERROR` | Query Store is in error state | Run `ALTER DATABASE CURRENT SET QUERY_STORE CLEAR` then re-enable (destroys history) |
| `Storage Used %` > 90% | At risk of switching to `READ_ONLY` | Increase `max_storage_size_mb` or reduce `stale_query_threshold_days` |
| `Capture Mode` = `NONE` | Not capturing new queries | Set to `AUTO` or `ALL`: `ALTER DATABASE CURRENT SET QUERY_STORE (QUERY_CAPTURE_MODE = AUTO)` |
| `Wait Stats Capture` = `OFF` | Step 3 (wait categories) will return no data | Enable: `ALTER DATABASE CURRENT SET QUERY_STORE (WAIT_STATS_CAPTURE_MODE = ON)` |

**If `QDS State` is `READ_WRITE`:** proceed normally — Query Store is healthy and actively capturing.
**If `QDS State` is `READ_ONLY`:** proceed with analysis — data is still queryable. Note in the report that new data is not being captured and recommend resolving the read-only reason.
**If `QDS State` is `OFF`:** attempt subsequent steps — historical data may still be present. If steps return no results, report that Query Store must be enabled first.
**If `QDS State` is `ERROR`:** report the error state and recommend `ALTER DATABASE CURRENT SET QUERY_STORE CLEAR` then re-enable (this destroys history).

## Step 1: Identify Volatile Queries

**Skip this step if the user already provided a `QueryId` — proceed directly to Step 2.**

Execute this query:

```sql
SELECT TOP ({{TopN}})
    q.query_id AS [Query ID],
    q.query_hash AS [Query Hash],
    COUNT(DISTINCT p.plan_id) AS [Plan Count],
    COUNT(rs.runtime_stats_id) AS [Execution Intervals],
    CAST(MIN(rs.avg_duration / 1000.0) AS NUMERIC(18,1)) AS [Min Avg Duration (ms)],
    CAST(MAX(rs.avg_duration / 1000.0) AS NUMERIC(18,1)) AS [Max Avg Duration (ms)],
    CAST(AVG(rs.avg_duration / 1000.0) AS NUMERIC(18,1)) AS [Overall Avg Duration (ms)],
    CAST(STDEV(rs.avg_duration / 1000.0) AS NUMERIC(18,1)) AS [StdDev Duration (ms)],
    CAST(
        CASE WHEN AVG(rs.avg_duration) > 0
             THEN (STDEV(rs.avg_duration) / AVG(rs.avg_duration)) * 100
             ELSE 0
        END AS NUMERIC(18,1)
    ) AS [Coefficient of Variation %],
    SUM(rs.count_executions) AS [Total Executions],
    CAST(AVG(rs.avg_logical_io_reads) AS NUMERIC(18,1)) AS [Avg Logical Reads],
    CAST(AVG(rs.avg_cpu_time / 1000.0) AS NUMERIC(18,1)) AS [Avg CPU Time (ms)]
FROM sys.query_store_query q
INNER JOIN sys.query_store_plan p
    ON q.query_id = p.query_id
INNER JOIN sys.query_store_runtime_stats rs
    ON p.plan_id = rs.plan_id
INNER JOIN sys.query_store_runtime_stats_interval rsi
    ON rs.runtime_stats_interval_id = rsi.runtime_stats_interval_id
WHERE rsi.start_time >= DATEADD(MINUTE, -{{LookbackMinutes}}, GETUTCDATE())
  AND q.is_internal_query = 0
GROUP BY q.query_id, q.query_hash
HAVING COUNT(rs.runtime_stats_id) >= 2
ORDER BY [Coefficient of Variation %] DESC
OPTION (MAXDOP 1);
```

### Step 1 Report Template

```
## Top Volatile Queries
Database: {{database name}}
Date: {{current date in YYYY-MM-DD format}}
Lookback: {{LookbackMinutes}} minutes

---

| Query ID | Query Hash | Plan Count | Executions | Min Dur (ms) | Max Dur (ms) | Avg Dur (ms) | CV% | Avg CPU (ms) | Avg Reads |
|----------|------------|------------|------------|--------------|--------------|--------------|-----|--------------|-----------|
{{one row per query, use Query Hash to identify queries}}
```

### Interpreting Step 1 Results

#### Coefficient of Variation (CV%)

CV% measures how much a query's duration varies relative to its average:

| CV% Range | Interpretation | Likely Causes |
|-----------|---------------|---------------|
| < 50% | Moderate variability | Normal fluctuation, minor contention |
| 50% – 100% | High variability | Blocking, plan changes, resource pressure |
| > 100% | Extreme variability | Severe blocking, plan regression, parameter sniffing |

#### Plan Count

- **Plan Count = 1**: Single plan used consistently. Variability is not due to plan changes.
- **Plan Count > 1**: Multiple execution plans detected — strong indicator of **plan regression**
  or **parameter sniffing**. Flag in the report.

### No Results Found (Step 1)

- State: "No queries with significant performance variability were found in Query Store over
  the last {{LookbackMinutes}} minutes."
- Suggest expanding to 1440 minutes (24 hours).
- Do NOT proceed to Step 2 if no volatile queries are found.

## Step 2: Query Interval Comparison

After Step 1 surfaces candidate queries (or the user provides a `QueryId` directly),
run this query for the chosen `QueryId`. Ask the user which Query ID to drill into if
Step 1 returned multiple candidates and no `QueryId` was pre-specified.

Execute this query:

```sql
SELECT
    rsi.start_time AS [Interval Start (UTC)],
    rsi.end_time AS [Interval End (UTC)],
    p.plan_id AS [Plan ID],
    rs.count_executions AS [Executions],
    CAST(rs.avg_duration / 1000.0 AS NUMERIC(18,1)) AS [Avg Duration (ms)],
    CAST(rs.min_duration / 1000.0 AS NUMERIC(18,1)) AS [Min Duration (ms)],
    CAST(rs.max_duration / 1000.0 AS NUMERIC(18,1)) AS [Max Duration (ms)],
    CAST(rs.stdev_duration / 1000.0 AS NUMERIC(18,1)) AS [StdDev Duration (ms)],
    CAST(rs.avg_cpu_time / 1000.0 AS NUMERIC(18,1)) AS [Avg CPU (ms)],
    CAST(rs.avg_logical_io_reads AS NUMERIC(18,0)) AS [Avg Logical Reads],
    CAST(rs.avg_query_max_used_memory * 8.0 / 1024 AS NUMERIC(18,1)) AS [Avg Memory (MB)]
FROM sys.query_store_query q
INNER JOIN sys.query_store_plan p
    ON q.query_id = p.query_id
INNER JOIN sys.query_store_runtime_stats rs
    ON p.plan_id = rs.plan_id
INNER JOIN sys.query_store_runtime_stats_interval rsi
    ON rs.runtime_stats_interval_id = rsi.runtime_stats_interval_id
WHERE q.query_id = {{QueryId}}
  AND rsi.start_time >= DATEADD(MINUTE, -{{LookbackMinutes}}, GETUTCDATE())
ORDER BY rsi.start_time
OPTION (MAXDOP 1);
```

### Step 2 Report Template

```
## Query Interval Performance Comparison
Database: {{database name}}
Date: {{current date in YYYY-MM-DD format}}
Query ID: {{QueryId}}
Lookback: {{LookbackMinutes}} minutes

---

### Performance Over Time

| Interval Start (UTC) | Plan ID | Executions | Avg Dur (ms) | Min Dur (ms) | Max Dur (ms) | StdDev (ms) | Avg CPU (ms) | Avg Reads | Avg Memory (MB) |
|----------------------|---------|------------|--------------|--------------|--------------|-------------|--------------|-----------|----------------|
{{one row per interval, chronologically ordered}}

---

### Analysis

{{Provide analysis based on the interpretation guidelines below}}

---

### Conclusion

{{1-2 sentence summary of what the interval data reveals about the query's behavior}}
```

### Interpreting Step 2 Results

#### Pattern: High Duration, Low CPU → Blocking
When you see intervals where:
- `Avg Duration` is significantly elevated (2x or more above baseline)
- `Avg CPU` remains relatively low and stable
- `Max Duration` has extreme spikes

This indicates the query is **waiting** (not computing). The most common cause is **blocking** —
the query is waiting for locks held by another session. The CPU stays low because the query
isn't doing work, it's just waiting.

#### Pattern: High Duration, High CPU → Plan Regression
When you see intervals where:
- Both `Avg Duration` and `Avg CPU` spike together
- `Avg Logical Reads` may also increase significantly
- The `Plan ID` may change between intervals

This indicates a **plan regression** — the query optimizer chose a less efficient execution plan.
Look for intervals where the Plan ID changed; the new plan is likely the cause.

#### Pattern: Gradual Increase in Duration and Reads → Data Growth
When you see:
- Steady increase in `Avg Duration` and `Avg Logical Reads` over time
- CPU increases proportionally
- Same Plan ID throughout

This indicates the query's performance is degrading due to **data growth**. The same plan
is reading more data over time. Consider adding or adjusting indexes.

#### Pattern: Intermittent Spikes → Resource Contention
When you see:
- Isolated intervals with elevated duration surrounded by normal intervals
- No plan changes
- Irregular pattern

This indicates **intermittent resource contention** — blocking, throttling, or competing workloads
that appear and disappear. Consider setting up monitoring to capture the specific conditions.

### No Results Found (Step 2)

If the query returns no rows:
- Confirm the Query ID is correct.
- The query may not have executed during the lookback period.
- Suggest expanding `LookbackMinutes` to capture more history.

## Step 3: Wait Category Breakdown per Query

Shows which wait categories are dominating a query's execution time. This answers **why** a query
is slow — CPU queueing, lock contention, I/O latency, memory grants, etc. — rather than inferring
from duration/CPU ratios.

**Requirements:** SQL Server 2017+ or Azure SQL. `wait_stats_capture_mode` must be `ON` (verify
via Step 0). If wait stats capture is off, skip this step and note it in the report.

**Skip this step entirely on SQL Server 2016.** The `sys.query_store_wait_stats` DMV was
introduced in SQL Server 2017. Running this query on 2016 will produce an error.

Execute this query:

```sql
SELECT TOP ({{TopN}})
      q.query_id                                            AS [Query ID]
    , q.query_hash                                          AS [Query Hash]
    , ws.wait_category_desc                                 AS [Wait Category]
    , SUM(ws.total_query_wait_time_ms)                      AS [Total Wait Time (ms)]
    , CAST(AVG(ws.avg_query_wait_time_ms) AS NUMERIC(18,1)) AS [Avg Wait Time (ms)]
    , COUNT(DISTINCT ws.runtime_stats_interval_id)          AS [Intervals Affected]
FROM sys.query_store_wait_stats ws
INNER JOIN sys.query_store_plan p
    ON ws.plan_id = p.plan_id
INNER JOIN sys.query_store_query q
    ON p.query_id = q.query_id
INNER JOIN sys.query_store_runtime_stats_interval rsi
    ON ws.runtime_stats_interval_id = rsi.runtime_stats_interval_id
WHERE rsi.start_time >= DATEADD(MINUTE, -{{LookbackMinutes}}, GETUTCDATE())
  AND q.is_internal_query = 0
GROUP BY q.query_id, q.query_hash, ws.wait_category_desc
ORDER BY [Total Wait Time (ms)] DESC
OPTION (MAXDOP 1);
```

### Wait Category Reference

| Wait Category | What It Means | Typical Root Cause |
|--------------|---------------|-------------------|
| `CPU` | Scheduler queueing, compute-bound work | Missing indexes, expensive expressions, inadequate tier |
| `Lock` | Row/page/table lock contention | Long transactions, hot rows, escalation |
| `IO` | Data/log file I/O latency | Missing indexes, buffer pool pressure, slow storage |
| `Memory` | `RESOURCE_SEMAPHORE` — waiting for memory grant | Large sorts/hashes, stale statistics, memory pressure |
| `Network` | Waiting on client to consume results | Large result sets, slow client, network latency |
| `Parallelism` | `CXPACKET` / `CXSYNC_CONSUMER` — parallel thread sync | Thread skew, high DOP, small data with parallel plan |
| `Idle` | Session is idle (not a problem) | Ignore unless dominant |

**If a specific `QueryId` was identified in Step 1:** filter the query by adding
`AND q.query_id = {{QueryId}}` to the WHERE clause to see wait categories for that query only.

## Step 4: Aborted and Failed Executions

Detects queries that are frequently aborting (timeouts, cancellations) or failing (runtime errors,
deadlocks). Step 1 filters to successful executions only (`HAVING COUNT(rs.runtime_stats_id) >= 2`) — this step catches
what it misses.

Execute this query:

```sql
SELECT TOP ({{TopN}})
      q.query_id                                            AS [Query ID]
    , q.query_hash                                          AS [Query Hash]
    , rs.execution_type_desc                                AS [Execution Type]
    , SUM(rs.count_executions)                              AS [Failure Count]
    , CAST(AVG(rs.avg_duration / 1000.0) AS NUMERIC(18,1))  AS [Avg Duration (ms)]
    , CAST(AVG(rs.avg_cpu_time / 1000.0) AS NUMERIC(18,1))  AS [Avg CPU (ms)]
    , MAX(rs.last_execution_time)                           AS [Last Failure Time]
FROM sys.query_store_runtime_stats rs
INNER JOIN sys.query_store_plan p
    ON rs.plan_id = p.plan_id
INNER JOIN sys.query_store_query q
    ON p.query_id = q.query_id
INNER JOIN sys.query_store_runtime_stats_interval rsi
    ON rs.runtime_stats_interval_id = rsi.runtime_stats_interval_id
WHERE rsi.start_time >= DATEADD(MINUTE, -{{LookbackMinutes}}, GETUTCDATE())
  AND rs.execution_type IN (3, 4)   -- 3 = Aborted, 4 = Exception (SQL Server 2017+ / Azure SQL; on SQL 2016, use execution_type_desc filtering instead)
GROUP BY q.query_id, q.query_hash, rs.execution_type_desc
HAVING SUM(rs.count_executions) >= 1
ORDER BY [Failure Count] DESC
OPTION (MAXDOP 1);
```

### Interpreting Step 4 Results

| Execution Type | Meaning | Common Causes |
|---------------|---------|---------------|
| `Aborted` | Query was cancelled or timed out before completion | Client timeout, `LOCK_TIMEOUT`, query governor |
| `Exception` | Query failed with a runtime error | Deadlock victim, arithmetic overflow, conversion error, insufficient permissions |

- **High `Failure Count` + high `Avg Duration`:** query is running long and timing out — likely blocking or resource starvation.
- **High `Failure Count` + low `Avg Duration`:** query fails fast — likely a runtime error (deadlock, permission, data issue).
- If a query appears in both Step 1 (volatile) and Step 4 (aborted), the abortions are likely causing the volatility.

### No Results Found (Step 4)

No aborted or failed executions in the lookback window. All queries completed successfully.

## Step 5: Forced Plan Failure Detection

Identifies plans that are forced via `sp_query_store_force_plan` but are silently failing. When a
forced plan fails, SQL Server falls back to optimizer plan selection — the user may not realize
the forced plan is no longer being used.

Execute this query:

```sql
SELECT
      q.query_id                                AS [Query ID]
    , p.plan_id                                 AS [Plan ID]
    , q.query_hash                              AS [Query Hash]
    , p.is_forced_plan                          AS [Is Forced]
    , p.force_failure_count                     AS [Force Failure Count]
    , p.last_force_failure_reason_desc          AS [Last Failure Reason]
    , p.last_compile_start_time                 AS [Last Compile Time]
    , p.last_execution_time                     AS [Last Execution Time]
    , p.count_compiles                          AS [Compile Count]
FROM sys.query_store_plan p
INNER JOIN sys.query_store_query q
    ON p.query_id = q.query_id
WHERE p.is_forced_plan = 1
  AND p.force_failure_count > 0
ORDER BY p.force_failure_count DESC
OPTION (MAXDOP 1);
```

### Interpreting Step 5 Results

| Failure Reason | Meaning | Action |
|---------------|---------|--------|
| `NO_INDEX` (8712) | An index the plan uses no longer exists under that name, or is disabled | Recreate or re-enable the index, or unforce the plan; while the index is missing the query runs with the optimizer's own plan |
| `NO_PLAN` (8698) | The forced plan could not be verified as valid for the query (for example, after a schema change) | Unforce, let the query recompile, and re-evaluate whether to force the new plan |
| `HINT_CONFLICT` (8690) / `SETOPT_CONFLICT` (8691) | A query hint, or the session's SET options, conflict with the plan | Remove the conflicting hint or align the SET options, or unforce |
| `NO_DB` (8689) | A database the plan references no longer exists | Unforce the plan |
| `VIEW_COMPILE_FAILED` (8713) | An indexed view the plan uses has a problem | Check the indexed view and its index; unforce if it was changed or dropped |
| `ONLINE_INDEX_BUILD` (8637) | The query modifies data while an index on the table is being built online | Usually transient; re-check after the build finishes |
| `TIME_OUT` (8684) | The optimizer ran out of allowed operations while searching for the forced plan | Unforce, or force a simpler plan for the query |
| `GENERAL_FAILURE` | Any other forcing error | Investigate the query and its plan; may need a fresh baseline |

`force_failure_count` moves only when the query recompiles, not on every execution, and resets to 0 when the plan is forced again.

**To unforce a failing plan:**
```sql
EXEC sp_query_store_unforce_plan @query_id = <query_id>, @plan_id = <plan_id>;
```

### No Results Found (Step 5)

No forced plan failures detected. All forced plans are being applied successfully.

## Step 6: Top Queries by Memory Grant

Ranks queries by their average memory grant consumption. Large memory grants can cause
`RESOURCE_SEMAPHORE` waits, starving other queries. Queries with high memory grants combined
with `Memory` waits in Step 3 are strong optimization candidates.

Execute this query:

```sql
SELECT TOP ({{TopN}})
      q.query_id                                                        AS [Query ID]
    , q.query_hash                                                      AS [Query Hash]
    , CAST(AVG(rs.avg_query_max_used_memory * 8.0 / 1024) AS NUMERIC(18,1)) AS [Avg Memory Used (MB)]
    , CAST(MAX(rs.max_query_max_used_memory * 8.0 / 1024) AS NUMERIC(18,1)) AS [Max Memory Used (MB)]
    , CAST(AVG(rs.avg_duration / 1000.0) AS NUMERIC(18,1))              AS [Avg Duration (ms)]
    , CAST(AVG(rs.avg_cpu_time / 1000.0) AS NUMERIC(18,1))              AS [Avg CPU (ms)]
    , CAST(AVG(rs.avg_logical_io_reads) AS NUMERIC(18,0))               AS [Avg Logical Reads]
    , SUM(rs.count_executions)                                          AS [Total Executions]
    , COUNT(DISTINCT p.plan_id)                                         AS [Plan Count]
FROM sys.query_store_runtime_stats rs
INNER JOIN sys.query_store_plan p
    ON rs.plan_id = p.plan_id
INNER JOIN sys.query_store_query q
    ON p.query_id = q.query_id
INNER JOIN sys.query_store_runtime_stats_interval rsi
    ON rs.runtime_stats_interval_id = rsi.runtime_stats_interval_id
WHERE rsi.start_time >= DATEADD(MINUTE, -{{LookbackMinutes}}, GETUTCDATE())
  AND q.is_internal_query = 0
GROUP BY q.query_id, q.query_hash
HAVING AVG(rs.avg_query_max_used_memory) > 0
ORDER BY [Avg Memory Used (MB)] DESC
OPTION (MAXDOP 1);
```

### Interpreting Step 6 Results

- **Avg Memory Used > 100 MB**: Large memory consumer. Check for hash joins, sorts on large datasets, or stale statistics causing over-estimation.
- **Max Memory Used >> Avg Memory Used**: Memory grant is volatile — likely parameter sniffing causing different grant sizes.
- **High Memory + Low Logical Reads**: The query is requesting more memory than its data volume justifies — stale statistics or poor cardinality estimation.
- **Cross-reference with Step 3**: If the same `Query ID` shows `Memory` as the dominant wait category, this query is actively causing `RESOURCE_SEMAPHORE` pressure.

### No Results Found (Step 6)

No queries with significant memory grants found in the lookback window.

## Step 7: Parameter Sensitivity Detection

Identifies queries where different parameter values lead to different execution plans — the classic
**parameter sniffing** problem. When Step 1 shows a query with `Plan Count > 1`, this step reveals
which plans exist and their performance characteristics.

**Requirements:** Available on all SQL Server versions with Query Store. The query below works by
correlating multiple plans for the same `query_id` and comparing their performance profiles.

Execute this query:

```sql
SELECT
      q.query_id                                                        AS [Query ID]
    , q.query_hash                                                      AS [Query Hash]
    , p.plan_id                                                         AS [Plan ID]
    , p.query_plan_hash                                                 AS [Plan Hash]
    , p.is_forced_plan                                                  AS [Is Forced]
    , CAST(SUM(rs.avg_duration * rs.count_executions)
        / NULLIF(SUM(rs.count_executions), 0) / 1000.0 AS NUMERIC(18,1)) AS [Weighted Avg Duration (ms)]
    , CAST(SUM(rs.avg_cpu_time * rs.count_executions)
        / NULLIF(SUM(rs.count_executions), 0) / 1000.0 AS NUMERIC(18,1)) AS [Weighted Avg CPU (ms)]
    , CAST(SUM(rs.avg_logical_io_reads * rs.count_executions)
        / NULLIF(SUM(rs.count_executions), 0) AS NUMERIC(18,0))        AS [Weighted Avg Reads]
    , CAST(AVG(rs.avg_query_max_used_memory * 8.0 / 1024) AS NUMERIC(18,1)) AS [Avg Memory (MB)]
    , SUM(rs.count_executions)                                          AS [Total Executions]
    , MIN(rs.first_execution_time)                                      AS [First Seen]
    , MAX(rs.last_execution_time)                                       AS [Last Seen]
FROM sys.query_store_query q
INNER JOIN sys.query_store_plan p
    ON q.query_id = p.query_id
INNER JOIN sys.query_store_runtime_stats rs
    ON p.plan_id = rs.plan_id
INNER JOIN sys.query_store_runtime_stats_interval rsi
    ON rs.runtime_stats_interval_id = rsi.runtime_stats_interval_id
WHERE rsi.start_time >= DATEADD(MINUTE, -{{LookbackMinutes}}, GETUTCDATE())
  AND q.is_internal_query = 0
  AND q.query_id IN (
      -- Only queries with multiple plans in the lookback window
      SELECT p2.query_id
      FROM sys.query_store_plan p2
      INNER JOIN sys.query_store_runtime_stats rs2 ON p2.plan_id = rs2.plan_id
      INNER JOIN sys.query_store_runtime_stats_interval rsi2
          ON rs2.runtime_stats_interval_id = rsi2.runtime_stats_interval_id
      WHERE rsi2.start_time >= DATEADD(MINUTE, -{{LookbackMinutes}}, GETUTCDATE())
      GROUP BY p2.query_id
      HAVING COUNT(DISTINCT p2.plan_id) > 1
  )
GROUP BY q.query_id, q.query_hash, p.plan_id, p.query_plan_hash, p.is_forced_plan
ORDER BY q.query_id, [Weighted Avg Duration (ms)] DESC
OPTION (MAXDOP 1);
```

### Interpreting Step 7 Results

- **Same `Query ID`, different `Plan ID`, large duration gap:** Classic parameter sniffing. The "fast" plan and "slow" plan serve different parameter values. Consider:
  - `OPTION (RECOMPILE)` for low-frequency queries
  - `OPTION (OPTIMIZE FOR UNKNOWN)` for generic plan
  - `sp_query_store_force_plan` to lock in the best plan
  - Plan guides for targeted plan control
- **Same `Query ID`, different `Plan Hash`:** Structurally different plans — not just recompiles, but genuinely different strategies (e.g., seek vs. scan, nested loop vs. hash join).
- **One plan has `Is Forced = 1`:** A plan is already forced. Compare its performance to alternatives — if a non-forced plan is faster, the forcing may be counterproductive.
- **Cross-reference with Step 1:** If a query has high CV% and multiple plans here, parameter sniffing is the likely root cause of the volatility.

### No Results Found (Step 7)

No queries with multiple execution plans found in the lookback window. Parameter sniffing
is unlikely to be a factor.
