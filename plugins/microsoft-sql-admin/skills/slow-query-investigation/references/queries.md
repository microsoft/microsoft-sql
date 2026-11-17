# Slow Query Investigation — SQL Queries

Run all queries with the SQL query tool. Replace {{parameter}} placeholders with values from the skill parameters.

> **Confirmation gate for remediation.** The diagnostic queries in Steps 0–7 are read-only. The
> remediation commands shown under "What to Do" — `KILL`, `sp_query_store_force_plan`,
> `sp_query_store_unforce_plan`, `sp_query_store_set_hints`, `sp_create_plan_guide`,
> `UPDATE STATISTICS`, and `ALTER DATABASE ... SET ...` — change server or database state. Present
> them as recommendations only. Never run any of them without the user's explicit confirmation for
> that specific command, and explain its impact and rollback first (for example: `KILL` rolls back
> the session's open transaction and cannot be undone; a forced plan is reverted with
> `sp_query_store_unforce_plan`; Query Store hints are removed with `sp_query_store_clear_hints`).

### Step 0: Environment Detection

Execute this query **before any other step** to determine the SQL Server
version, engine edition, and whether Query Store is available and active:

```sql
SELECT
    SERVERPROPERTY('ProductVersion') AS [SQL Version],
    SERVERPROPERTY('ProductMajorVersion') AS [Major Version],
    SERVERPROPERTY('Edition') AS [Edition],
    SERVERPROPERTY('EngineEdition') AS [Engine Edition],
    CASE CAST(SERVERPROPERTY('EngineEdition') AS INT)
        WHEN 5 THEN 'Azure SQL Database'
        WHEN 6 THEN 'Azure Synapse Analytics (Dedicated SQL pool)'
        WHEN 8 THEN 'Azure SQL Managed Instance'
        WHEN 9 THEN 'Azure SQL Edge'
        WHEN 11 THEN 'Azure Synapse serverless SQL pool / Fabric SQL Warehouse'
        WHEN 12 THEN 'Fabric SQL Database'
        ELSE 'SQL Server (on-premises)'
    END AS [Engine Type],
    CASE WHEN CAST(SERVERPROPERTY('EngineEdition') AS INT) IN (6, 11)
         THEN 1 ELSE 0
    END AS is_unsupported_dw,
    CASE
        WHEN OBJECT_ID('sys.database_query_store_options') IS NOT NULL
        THEN (SELECT TOP 1 actual_state_desc FROM sys.database_query_store_options)
        ELSE 'NOT AVAILABLE'
    END AS [Query Store State],
    CASE
        WHEN OBJECT_ID('sys.database_query_store_options') IS NOT NULL
        THEN (SELECT TOP 1 desired_state_desc FROM sys.database_query_store_options)
        ELSE 'NOT AVAILABLE'
    END AS [Query Store Desired State],
    CASE
        WHEN OBJECT_ID('sys.query_store_wait_stats') IS NOT NULL THEN 'Yes'
        ELSE 'No'
    END AS [Wait Stats Available]
    OPTION (MAXDOP 1);
```

#### Routing Logic

Use the results from Step 0 to determine the investigation path:

- **If `is_unsupported_dw = 1`** (EngineEdition 6 or 11 — Synapse Dedicated, Synapse serverless, Fabric Warehouse): **STOP** — this skill does not support data-warehouse endpoints. Tell the user the platform is not supported and suggest using platform-specific diagnostics.

| Query Store State | Path |
|-------------------|------|
| `READ_WRITE` or `READ_ONLY` | Proceed with **Steps 1–6** (full Query Store investigation) |
| `OFF`, `ERROR`, or `NOT AVAILABLE` | Skip to **Step 7: DMV Fallback** |

> **Note on Wait Stats**: The `Wait Stats Available` column checks for `sys.query_store_wait_stats`
> which requires SQL Server 2017+ or Azure SQL Database. If `No`, skip **Step 2** (Wait Category
> Analysis) even when Query Store is active — the other steps still work.

#### Version-Specific Capabilities

| Feature | Minimum Version | How Detected |
|---------|----------------|---------------|
| Query Store | SQL Server 2016 (13.x) | `Query Store State` != `NOT AVAILABLE` |
| Query Store Wait Stats | SQL Server 2017 (14.x) | `Wait Stats Available` = `Yes` |
| Query Store Hints | SQL Server 2022 (16.x) | `Major Version` >= 16 |
| Memory Grant Feedback | SQL Server 2019 (15.x) | `Major Version` >= 15 |
| Intelligent Query Processing | SQL Server 2019 (15.x) | `Major Version` >= 15 |
| `sys.dm_db_resource_stats` | Azure SQL DB / MI only | `Engine Edition` IN (5, 8) |

Include the detected environment info in the report header.

### Step 1: Find Volatile Queries

> **Requires**: Query Store active (`READ_WRITE` or `READ_ONLY` from Step 0)

Execute this query to identify queries with inconsistent performance:

```sql
SELECT TOP ({{TopN}})
    q.query_id AS [Query ID],
    q.query_hash AS [Query Hash],
    COUNT(DISTINCT p.plan_id) AS [Plan Count],
    COUNT(rs.runtime_stats_id) AS [Execution Intervals],
    CAST(MIN(rs.avg_duration / 1000.0) AS NUMERIC(18,1)) AS [Min Avg Duration (ms)],
    CAST(MAX(rs.avg_duration / 1000.0) AS NUMERIC(18,1)) AS [Max Avg Duration (ms)],
    CAST(SUM(rs.avg_duration * rs.count_executions) / NULLIF(SUM(rs.count_executions), 0) / 1000.0 AS NUMERIC(18,1)) AS [Overall Avg Duration (ms)],
    CAST(STDEV(rs.avg_duration / 1000.0) AS NUMERIC(18,1)) AS [StdDev Duration (ms)],
    CAST(
        CASE WHEN SUM(rs.avg_duration * rs.count_executions) / NULLIF(SUM(rs.count_executions), 0) > 0
             THEN (STDEV(rs.avg_duration) / (SUM(rs.avg_duration * rs.count_executions) / NULLIF(SUM(rs.count_executions), 0))) * 100
             ELSE 0
        END AS NUMERIC(18,1)
    ) AS [Coefficient of Variation %],
    SUM(rs.count_executions) AS [Total Executions],
    CAST(SUM(rs.avg_logical_io_reads * rs.count_executions) / NULLIF(SUM(rs.count_executions), 0) AS NUMERIC(18,1)) AS [Avg Logical Reads],
    CAST(SUM(rs.avg_cpu_time * rs.count_executions) / NULLIF(SUM(rs.count_executions), 0) / 1000.0 AS NUMERIC(18,1)) AS [Avg CPU Time (ms)]
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

#### Typical Interpretations

- **CV% > 100%**: Extreme variability — strongly suggests plan regression, parameter sniffing, or resource contention. Prioritize these queries.
- **CV% 50–100%**: High variability — likely indicates intermittent issues. Cross-reference with Steps 2–4 for root cause.
- **CV% < 50%**: Moderate variability — may be normal for queries with varying data volumes. Less urgent.
- **Plan Count > 1**: Multiple plans suggest parameter sniffing or plan instability. Check Step 4.
- **High StdDev with low Plan Count (1)**: Points to external factors (blocking, resource contention) rather than plan changes.
- **No rows returned**: The issue may not be occurring during the lookback window. Suggest expanding `LookbackMinutes` to 1440 (24h) or 10080 (7 days).

#### What to Do

- **CV% > 100% with Plan Count > 1**: This is likely parameter sniffing or plan regression. Proceed to Step 4 to confirm, then, if the plan passes the forcing check at the end of Step 4, recommend forcing the best plan (run only after the user explicitly confirms this command; roll back with `sp_query_store_unforce_plan`):
  ```sql
  EXEC sp_query_store_force_plan @query_id = <Query ID>, @plan_id = <best_plan_id>;
  
```
- **CV% > 100% with Plan Count = 1**: External factors (blocking, resource contention). Proceed to Step 2 for wait analysis and Step 5 for time-of-day correlation.
- **High Avg Logical Reads**: Run the `missing-index-analysis` skill to check for missing indexes on the affected queries.
- **High Avg CPU Time with low Logical Reads**: Investigate scalar UDFs, complex expressions, or implicit conversions in the query. Consider rewriting.
- **All top queries share high variability**: Likely a systemic issue (resource throttling, blocking) rather than individual query problems. Run the `investigate-sql-cpu-pressure` skill or the `investigate-sql-data-io-pressure` skill.

### Step 2: Analyze Wait Categories

> **Requires**: Query Store active AND `Wait Stats Available` = `Yes` from Step 0
> (SQL Server 2017+ or Azure SQL Database). If wait stats are not available, skip this
> step and rely on Steps 3–6 for root cause analysis.

Execute this query to determine the root cause:

```sql
SELECT TOP ({{TopN}})
    q.query_id AS [Query ID],
    q.query_hash AS [Query Hash],
    ws.wait_category_desc AS [Wait Category],
    SUM(ws.total_query_wait_time_ms) AS [Total Wait Time (ms)],
    CAST(SUM(ws.avg_query_wait_time_ms * ws.total_query_wait_time_ms)
        / NULLIF(SUM(ws.total_query_wait_time_ms), 0) AS NUMERIC(18,1)) AS [Avg Wait (ms)],
    SUM(ws.total_query_wait_time_ms) * 100.0
        / NULLIF(SUM(SUM(ws.total_query_wait_time_ms)) OVER (PARTITION BY q.query_id), 0)
        AS [Wait Category % of Query Total],
    COUNT(DISTINCT p.plan_id) AS [Plan Count]
FROM sys.query_store_query q
INNER JOIN sys.query_store_plan p
    ON q.query_id = p.query_id
INNER JOIN sys.query_store_wait_stats ws
    ON p.plan_id = ws.plan_id
INNER JOIN sys.query_store_runtime_stats_interval rsi
    ON ws.runtime_stats_interval_id = rsi.runtime_stats_interval_id
WHERE rsi.start_time >= DATEADD(MINUTE, -{{LookbackMinutes}}, GETUTCDATE())
  AND q.is_internal_query = 0
GROUP BY q.query_id, q.query_hash, ws.wait_category_desc
ORDER BY [Total Wait Time (ms)] DESC
OPTION (MAXDOP 1);
```

#### Typical Interpretations

- **Lock**: Blocking from other sessions. Run the `check-live-blocking` skill to investigate.
- **CPU**: Plan regressions, parameter sniffing, or insufficient compute resources. Check Steps 3–4.
- **IO**: Missing indexes, table scans, or storage throttling. Run the `missing-index-analysis` skill.
- **Memory**: Excessive memory grants, sort/hash spills. Update statistics and check cardinality estimates.
- **Network**: Large result sets or client-side latency. Review query result sizes.
- **Parallelism**: CXPACKET/CXCONSUMER waits — skewed parallel plan distribution. Consider MAXDOP hints.
- **Wait Category % > 80%**: Dominant root cause — focus remediation here.
- **Multiple categories with similar %**: Multi-factor issue — address each in priority order.

### Step 3: Detect Plan Regressions

> **Requires**: Query Store active (`READ_WRITE` or `READ_ONLY` from Step 0)

Execute this query to find queries whose recent performance is significantly worse
than their historical baseline — a hallmark of plan regressions and a top cause of intermittent slowness:

```sql
;WITH recent AS (
    SELECT
        q.query_id,
        SUM(rs.avg_duration * rs.count_executions) / NULLIF(SUM(rs.count_executions), 0) / 1000.0 AS avg_duration_ms,
        SUM(rs.avg_cpu_time * rs.count_executions) / NULLIF(SUM(rs.count_executions), 0) / 1000.0 AS avg_cpu_ms,
        SUM(rs.avg_logical_io_reads * rs.count_executions) / NULLIF(SUM(rs.count_executions), 0) AS avg_logical_reads,
        SUM(rs.count_executions) AS total_executions
    FROM sys.query_store_query q
    INNER JOIN sys.query_store_plan p ON q.query_id = p.query_id
    INNER JOIN sys.query_store_runtime_stats rs ON p.plan_id = rs.plan_id
    INNER JOIN sys.query_store_runtime_stats_interval rsi
        ON rs.runtime_stats_interval_id = rsi.runtime_stats_interval_id
    WHERE rsi.start_time >= DATEADD(MINUTE, -{{LookbackMinutes}}, GETUTCDATE())
      AND q.is_internal_query = 0
    GROUP BY q.query_id
),
-- Historical baseline: uses the same interval table rows already filtered by date range.
-- Pre-aggregate by query_id to reduce the data volume before the outer JOIN.
historical AS (
    SELECT
        q.query_id,
        SUM(rs.avg_duration * rs.count_executions) / NULLIF(SUM(rs.count_executions), 0) / 1000.0 AS avg_duration_ms,
        SUM(rs.avg_cpu_time * rs.count_executions) / NULLIF(SUM(rs.count_executions), 0) / 1000.0 AS avg_cpu_ms,
        SUM(rs.avg_logical_io_reads * rs.count_executions) / NULLIF(SUM(rs.count_executions), 0) AS avg_logical_reads,
        SUM(rs.count_executions) AS total_executions
    FROM sys.query_store_query q
    INNER JOIN sys.query_store_plan p ON q.query_id = p.query_id
    INNER JOIN sys.query_store_runtime_stats rs ON p.plan_id = rs.plan_id
    INNER JOIN sys.query_store_runtime_stats_interval rsi
        ON rs.runtime_stats_interval_id = rsi.runtime_stats_interval_id
    -- Historical baseline: 7 days back, excluding the recent lookback window.
    -- Ensure LookbackMinutes < 10080 (7 days) to avoid overlap.
    WHERE rsi.start_time >= DATEADD(DAY, -7, GETUTCDATE())
      AND rsi.start_time < DATEADD(MINUTE, -{{LookbackMinutes}}, GETUTCDATE())
      AND q.is_internal_query = 0
      -- Only look at queries that also appear in the recent window (reduces scan scope)
      AND q.query_id IN (SELECT query_id FROM recent)
    GROUP BY q.query_id
    HAVING SUM(rs.count_executions) >= 10
)
SELECT TOP ({{TopN}})
    r.query_id AS [Query ID],
    q.query_hash AS [Query Hash],
    CAST(h.avg_duration_ms AS NUMERIC(18,1)) AS [Historical Avg Duration (ms)],
    CAST(r.avg_duration_ms AS NUMERIC(18,1)) AS [Recent Avg Duration (ms)],
    CAST(r.avg_duration_ms / NULLIF(h.avg_duration_ms, 0) AS NUMERIC(18,2))
        AS [Regression Factor],
    CAST(h.avg_cpu_ms AS NUMERIC(18,1)) AS [Historical Avg CPU (ms)],
    CAST(r.avg_cpu_ms AS NUMERIC(18,1)) AS [Recent Avg CPU (ms)],
    CAST(h.avg_logical_reads AS NUMERIC(18,0)) AS [Historical Avg Reads],
    CAST(r.avg_logical_reads AS NUMERIC(18,0)) AS [Recent Avg Reads],
    COUNT(DISTINCT p.plan_id) AS [Total Plan Count]
FROM recent r
INNER JOIN historical h ON r.query_id = h.query_id
INNER JOIN sys.query_store_query q ON r.query_id = q.query_id
INNER JOIN sys.query_store_plan p ON q.query_id = p.query_id
WHERE r.avg_duration_ms > h.avg_duration_ms * {{RegressionFactor}}
GROUP BY r.query_id, q.query_hash,
         h.avg_duration_ms, r.avg_duration_ms,
         h.avg_cpu_ms, r.avg_cpu_ms,
         h.avg_logical_reads, r.avg_logical_reads
ORDER BY [Regression Factor] DESC
OPTION (MAXDOP 1);
```

#### Typical Interpretations

- **Regression Factor > 5×**: Severe regression — likely a plan change due to statistics update, schema change, or parameter sniffing. Prioritize immediately.
- **Regression Factor 2–5×**: Significant regression — investigate whether a new plan was introduced. Check Plan Count.
- **High Regression Factor + Plan Count > 1**: Strong indicator of plan regression. Use Query Store to identify the good vs bad plan and consider forcing the good plan.
- **High Regression Factor + Plan Count = 1**: Same plan but worse performance — could be data growth, increased concurrency, or resource contention rather than a plan change.
- **No rows returned**: No queries regressed beyond the `{{RegressionFactor}}` threshold. This is good — the issue may be caused by blocking or resource-level contention rather than plan changes.

#### What to Do

- **Regression detected with Plan Count > 1**: A new, worse plan was introduced. Recommend forcing the previous good plan if it passes the forcing check at the end of Step 4 (the `SELECT` is read-only; run the `EXEC` only after the user explicitly confirms it; roll back with `sp_query_store_unforce_plan`):
  ```sql
  -- Identify the best historical plan for the regressed query (average duration per plan, in microseconds)
  SELECT p.plan_id,
         SUM(rs.count_executions) AS executions,
         SUM(rs.avg_duration * rs.count_executions) / NULLIF(SUM(rs.count_executions), 0) AS avg_duration_us,
         MAX(rs.last_execution_time) AS last_execution_time
  FROM sys.query_store_plan AS p
  JOIN sys.query_store_runtime_stats AS rs ON rs.plan_id = p.plan_id
  WHERE p.query_id = <Query ID>
  GROUP BY p.plan_id
  ORDER BY avg_duration_us ASC
  OPTION (MAXDOP 1);

  -- Force the best plan
  EXEC sp_query_store_force_plan @query_id = <Query ID>, @plan_id = <best_plan_id>;
  
```
- **Regression detected with Plan Count = 1**: Same plan but degraded — investigate data growth, increased concurrency, or stale statistics. Run Step 6 to check statistics freshness.
- **Both CPU and Reads regressed**: Plan change is almost certain. Check if an index was dropped, a schema changed, or statistics were rebuilt around the regression timeframe.
- **CPU regressed but Reads stable**: Could be increased parallelism overhead or CPU throttling (Azure SQL). Check resource consumption against service-tier limits with `sys.dm_db_resource_stats`.
- **Multiple queries regressed simultaneously**: Suggests a global event (statistics rebuild, failover, service tier change). Check database event logs.

### Step 4: Identify Parameter Sniffing Candidates

> **Requires**: Query Store active (`READ_WRITE` or `READ_ONLY` from Step 0)

Execute this query to find queries with multiple plans that show dramatically
different performance per plan — the signature of parameter sniffing:

```sql
SELECT TOP ({{TopN}})
    q.query_id AS [Query ID],
    q.query_hash AS [Query Hash],
    p.plan_id AS [Plan ID],
    p.is_forced_plan AS [Is Forced],
    CAST(rs.avg_duration / 1000.0 AS NUMERIC(18,1)) AS [Avg Duration (ms)],
    CAST(rs.min_duration / 1000.0 AS NUMERIC(18,1)) AS [Min Duration (ms)],
    CAST(rs.max_duration / 1000.0 AS NUMERIC(18,1)) AS [Max Duration (ms)],
    CAST(rs.avg_cpu_time / 1000.0 AS NUMERIC(18,1)) AS [Avg CPU (ms)],
    CAST(rs.avg_logical_io_reads AS NUMERIC(18,0)) AS [Avg Logical Reads],
    CAST(rs.avg_physical_io_reads AS NUMERIC(18,0)) AS [Avg Physical Reads],
    rs.count_executions AS [Executions],
    CAST(rs.avg_rowcount AS NUMERIC(18,0)) AS [Avg Rowcount]
FROM sys.query_store_query q
INNER JOIN sys.query_store_plan p ON q.query_id = p.query_id
CROSS APPLY (
    SELECT
        AVG(rs2.avg_duration) AS avg_duration,
        MIN(rs2.min_duration) AS min_duration,
        MAX(rs2.max_duration) AS max_duration,
        AVG(rs2.avg_cpu_time) AS avg_cpu_time,
        AVG(rs2.avg_logical_io_reads) AS avg_logical_io_reads,
        AVG(rs2.avg_physical_io_reads) AS avg_physical_io_reads,
        SUM(rs2.count_executions) AS count_executions,
        AVG(rs2.avg_rowcount) AS avg_rowcount
    FROM sys.query_store_runtime_stats rs2
    INNER JOIN sys.query_store_runtime_stats_interval rsi2
        ON rs2.runtime_stats_interval_id = rsi2.runtime_stats_interval_id
    WHERE rs2.plan_id = p.plan_id
      AND rsi2.start_time >= DATEADD(MINUTE, -{{LookbackMinutes}}, GETUTCDATE())
) rs
WHERE q.is_internal_query = 0
  -- Only consider queries with multiple plans created within the lookback window
  AND EXISTS (
    SELECT 1
    FROM sys.query_store_plan p2
    WHERE p2.query_id = q.query_id
      AND p2.last_execution_time >= DATEADD(MINUTE, -{{LookbackMinutes}}, GETUTCDATE())
    HAVING COUNT(DISTINCT p2.plan_id) > 1
  )
  AND rs.count_executions > 0
ORDER BY q.query_id, rs.avg_duration DESC
OPTION (MAXDOP 1);
```

#### Typical Interpretations

- **Fastest plan > 3× faster than slowest**: Confirmed parameter sniffing. The optimizer compiled a plan for one parameter value that is suboptimal for others.
- **Plan marked `Is Forced = 1`**: A plan is already being forced. Verify it is the best plan — if forced plan is the slow one, unforce it.
- **High Avg Logical Reads on one plan but not another**: Different plans use different access methods (scan vs seek). The high-read plan likely has a bad cardinality estimate.
- **Large Avg Rowcount difference between plans**: Confirms data skew — different parameter values access very different data volumes.
- **No rows returned**: No multi-plan queries found, or no executions in the lookback window. Parameter sniffing is unlikely to be the root cause.

#### What to Do

- **Confirmed parameter sniffing (fastest > 3× slowest)**: Recommend remediation in this priority order (each command only after the user explicitly confirms it — see the confirmation gate at the top of this file):
  1. **Force the best plan** (immediate and reversible; only if it passes the forcing check below):
     ```sql
     EXEC sp_query_store_force_plan @query_id = <Query ID>, @plan_id = <fastest_plan_id>;
     
```
  2. **Query Store Hints** (SQL Server 2022+ / Azure SQL DB):
     ```sql
     EXEC sp_query_store_set_hints @query_id = <Query ID>, @query_hints = N'OPTION (OPTIMIZE FOR UNKNOWN)';
     
```
  3. **RECOMPILE hint** (if execution frequency is low — adds CPU overhead per execution):
     ```sql
     -- Add to the query or stored procedure
     OPTION (RECOMPILE)
     
```
  4. **Plan guides** (when query text cannot be modified): Use `sp_create_plan_guide`
- **Forced plan is the slow one**: Recommend unforcing it (run only after the user explicitly confirms; re-force with `sp_query_store_force_plan` to roll back):
  ```sql
  EXEC sp_query_store_unforce_plan @query_id = <Query ID>, @plan_id = <forced_plan_id>;
  
```
- **All plans are slow**: Parameter sniffing is not the root cause — the query itself needs optimization. Run the `missing-index-analysis` skill and check for stale statistics (Step 6).

#### Before Recommending a Forced Plan: Can It Still Be Forced?

Forcing works only while every index the plan uses still exists under the same name and is enabled. If one was dropped, renamed or disabled after the plan was compiled, `sp_query_store_force_plan` still succeeds, but every compile then fails to apply the plan (`last_force_failure_reason_desc` = `NO_INDEX`, 8712) and the query gets the plan the optimizer would have chosen anyway, so forcing does not undo the regression. Check the candidate plan before recommending it (read-only):

```sql
DECLARE @plan_id bigint = <best_plan_id>;
WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan'),
plan_objects AS (
    SELECT DISTINCT
           o.value('@Database', 'nvarchar(258)') AS database_name,
           o.value('@Schema',   'nvarchar(258)') AS schema_name,
           o.value('@Table',    'nvarchar(258)') AS table_name,
           o.value('@Index',    'nvarchar(258)') AS index_name
    FROM sys.query_store_plan AS p
    CROSS APPLY (SELECT TRY_CONVERT(xml, p.query_plan) AS plan_xml) AS x
    CROSS APPLY x.plan_xml.nodes('//Object[@Index]') AS n(o)
    WHERE p.plan_id = @plan_id
)
SELECT po.schema_name, po.table_name, po.index_name,
       CASE WHEN i.index_id IS NULL THEN 'missing' ELSE 'disabled' END AS problem
FROM plan_objects AS po
LEFT JOIN sys.indexes AS i
       ON i.object_id = OBJECT_ID(po.schema_name + N'.' + po.table_name)
      AND QUOTENAME(i.name) = po.index_name
WHERE po.database_name = QUOTENAME(DB_NAME())
  AND (i.index_id IS NULL OR i.is_disabled = 1);
```

- **No rows**: every index the plan names in this database still exists and is enabled. Forcing can still fail for other reasons; after the user forces it and the query recompiles, read `force_failure_count` and `last_force_failure_reason_desc` for the plan.
- **Rows**: forcing this plan will fail with `NO_INDEX`. Do not present forcing as a fix on its own. A dropped index is often the cause of the regression itself; propose recreating or re-enabling it (take its definition from the release script or source control; the plan shows only the columns it sought on and read), and judge any other fix by the plan the optimizer produces without the forced plan.
- Run the check in the database the query ran in. Indexes in other databases (cross-database queries) are not checked; run the same check there. A plan whose XML cannot be converted to `xml` (nesting deeper than 128 levels) returns no rows: read its `Object` elements from the plan text instead.

### Step 5: Time-of-Day Performance Correlation

> **Requires**: Query Store active (`READ_WRITE` or `READ_ONLY` from Step 0)

Execute this query to reveal whether slowness clusters at specific times —
indicating workload contention windows, batch job interference, or resource throttling patterns.

> **Note**: This step always uses a 24-hour lookback regardless of `{{LookbackMinutes}}` because
> time-of-day correlation requires a full day of data to detect hourly patterns.

```sql
SELECT
    DATEPART(HOUR, rsi.start_time) AS [Hour (UTC)],
    CASE WHEN ((DATEPART(WEEKDAY, rsi.start_time) + @@DATEFIRST - 1) % 7) IN (0, 6) THEN 'Weekend' ELSE 'Weekday' END AS [Day Type],
    COUNT(DISTINCT q.query_id) AS [Active Queries],
    CAST(SUM(rs.avg_duration * rs.count_executions) / NULLIF(SUM(rs.count_executions), 0) / 1000.0 AS NUMERIC(18,1)) AS [Avg Duration (ms)],
    CAST(MAX(rs.avg_duration / 1000.0) AS NUMERIC(18,1)) AS [Max Avg Duration (ms)],
    SUM(rs.count_executions) AS [Total Executions],
    CAST(SUM(rs.avg_cpu_time * rs.count_executions) / NULLIF(SUM(rs.count_executions), 0) / 1000.0 AS NUMERIC(18,1)) AS [Avg CPU (ms)],
    CAST(SUM(rs.avg_logical_io_reads * rs.count_executions) / NULLIF(SUM(rs.count_executions), 0) AS NUMERIC(18,0)) AS [Avg Logical Reads],
    CAST(SUM(rs.avg_physical_io_reads * rs.count_executions) / NULLIF(SUM(rs.count_executions), 0) AS NUMERIC(18,0)) AS [Avg Physical Reads]
FROM sys.query_store_runtime_stats rs
INNER JOIN sys.query_store_runtime_stats_interval rsi
    ON rs.runtime_stats_interval_id = rsi.runtime_stats_interval_id
INNER JOIN sys.query_store_plan p ON rs.plan_id = p.plan_id
INNER JOIN sys.query_store_query q ON p.query_id = q.query_id
WHERE rsi.start_time >= DATEADD(DAY, -1, GETUTCDATE())
  AND q.is_internal_query = 0
GROUP BY DATEPART(HOUR, rsi.start_time),
         CASE WHEN ((DATEPART(WEEKDAY, rsi.start_time) + @@DATEFIRST - 1) % 7) IN (0, 6) THEN 'Weekend' ELSE 'Weekday' END
ORDER BY [Day Type], [Hour (UTC)]
OPTION (MAXDOP 1);
```

#### Typical Interpretations

- **Duration spike at specific hours**: Correlate with known batch jobs (ETL, backups, reporting). Suggests workload contention.
- **Weekend vs Weekday difference**: If weekdays are significantly slower, OLTP and batch workloads likely overlap.
- **Flat pattern (no spikes)**: Slowness is not time-dependent — focus on query-level issues (Steps 1–4) rather than workload scheduling.
- **Spike in Physical Reads at certain hours**: Could indicate buffer pool pressure from competing workloads flushing cached pages.
- **High execution count at spike hours**: Increased query volume driving contention. Consider connection pooling or query throttling.

#### What to Do

- **Clear peak-hour spikes**: Identify what workloads run during those hours (ETL, reporting, backups) and stagger them:
  1. Move batch/ETL jobs to off-peak hours
  2. Stagger report generation to avoid overlap with OLTP workload
  3. Move backups to maintenance windows
- **Weekend vs Weekday disparity**: If weekdays are slower, consider Resource Governor to isolate workload groups:
  ```sql
  -- Create a workload group for batch operations with limited resources
  CREATE WORKLOAD GROUP [BatchJobs] WITH (MAX_DOP = 4, REQUEST_MAX_CPU_TIME_SEC = 300);
  
```
- **Consistent high Physical Reads at certain hours**: Competing workloads are flushing the buffer pool. Consider increasing memory or isolating workloads.
- **On Azure SQL**: Check for DTU/vCore throttling during peak hours with `sys.dm_db_resource_stats` (last hour) or `sys.resource_stats` (longer history). Consider scaling up the service tier during peak windows or using auto-scaling.
- **Flat pattern (no correlation)**: Time-of-day is not a factor. Focus on query-level root causes from Steps 1–4.

### Step 6: Statistics Staleness Check

Execute this query to find tables with stale statistics that may cause the
optimizer to generate bad plans — a silent and common root cause of intermittent plan changes:

> **Performance note**: On databases with thousands of tables and many statistics, this query
> can take 30–120 seconds due to per-statistic function calls. The `TOP(N)` and filters help,
> but the `CROSS APPLY` must evaluate every statistic before filtering.

```sql
SELECT TOP ({{TopN}})
    SCHEMA_NAME(o.schema_id) + '.' + o.name AS [Table],
    s.name AS [Statistic],
    sp.last_updated AS [Last Updated],
    sp.rows AS [Table Rows],
    sp.modification_counter AS [Modifications Since Update],
    CAST(
        CASE WHEN sp.rows > 0
             THEN (sp.modification_counter * 100.0) / sp.rows
             ELSE 0
        END AS NUMERIC(18,2)
    ) AS [Modification %],
    sp.rows_sampled AS [Rows Sampled],
    CAST(
        CASE WHEN sp.rows > 0
             THEN (sp.rows_sampled * 100.0) / sp.rows
             ELSE 0
        END AS NUMERIC(18,1)
    ) AS [Sample %]
FROM sys.objects o
INNER JOIN sys.stats s ON o.object_id = s.object_id
CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) sp
WHERE o.type = 'U'
  AND sp.modification_counter > 0
  AND (
      sp.modification_counter > sp.rows * 0.20  -- more than 20% modified
      -- GETDATE() is correct here: sp.last_updated stores local time, not UTC
      OR DATEDIFF(DAY, sp.last_updated, GETDATE()) > 7  -- not updated in 7+ days
  )
ORDER BY [Modification %] DESC
OPTION (MAXDOP 1);
```

#### Typical Interpretations

- **Modification % > 20%**: Statistics are stale. The optimizer is likely using outdated cardinality estimates, leading to bad plan choices. Update immediately with `UPDATE STATISTICS [schema].[table] WITH FULLSCAN`.
- **Modification % > 50%**: Critically stale. Almost certainly causing bad plans. Immediate action required.
- **Sample % < 30% on large tables**: Even if recently updated, low sample rates can produce poor estimates. Re-update with `FULLSCAN` or a higher sample rate.
- **Last Updated > 7 days ago**: Consider enabling `AUTO_UPDATE_STATISTICS_ASYNC` to prevent auto-stats updates from blocking query compilation.
- **No rows returned**: All statistics are reasonably current. Stale statistics are not a contributing factor.

### Step 7: DMV Fallback (When Query Store Is Not Available)

> **Use when**: Step 0 shows Query Store State = `OFF`, `ERROR`, or `NOT AVAILABLE`.
> Also use on SQL Server 2014 or older where Query Store does not exist.
> Step 6 (Statistics Staleness) is still valid without Query Store — run it alongside these.

If Query Store is not enabled, use these DMV-based queries as a fallback.

#### 7a: Top CPU-Consuming Queries (Plan Cache)

```sql
SELECT TOP ({{TopN}})
    CAST(qs.total_worker_time / 1000.0 / qs.execution_count AS NUMERIC(18,1))
        AS [Avg CPU (ms)],
    CAST(qs.total_elapsed_time / 1000.0 / qs.execution_count AS NUMERIC(18,1))
        AS [Avg Duration (ms)],
    qs.execution_count AS [Executions],
    CAST(qs.total_logical_reads / qs.execution_count AS NUMERIC(18,0))
        AS [Avg Logical Reads],
    qs.creation_time AS [Plan Created],
    qs.last_execution_time AS [Last Executed],
    OBJECT_NAME(st.objectid, st.dbid) AS [Object Name],
    qs.query_hash AS [Query Hash],
    qs.query_plan_hash AS [Plan Hash]
FROM sys.dm_exec_query_stats qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st
WHERE qs.execution_count > 1
ORDER BY qs.total_worker_time / qs.execution_count DESC
OPTION (MAXDOP 1);
```

#### 7a-ii: Top Elapsed-Time Queries (Plan Cache)

Catches wait-bound queries (lock waits, IO stalls, network latency) that have high elapsed time but modest CPU:

```sql
SELECT TOP ({{TopN}})
    CAST(qs.total_elapsed_time / 1000.0 / qs.execution_count AS NUMERIC(18,1))
        AS [Avg Duration (ms)],
    CAST(qs.total_worker_time / 1000.0 / qs.execution_count AS NUMERIC(18,1))
        AS [Avg CPU (ms)],
    CAST((qs.total_elapsed_time - qs.total_worker_time) / 1000.0 / qs.execution_count AS NUMERIC(18,1))
        AS [Avg Wait Time (ms)],
    qs.execution_count AS [Executions],
    CAST(qs.total_logical_reads / qs.execution_count AS NUMERIC(18,0))
        AS [Avg Logical Reads],
    qs.creation_time AS [Plan Created],
    qs.last_execution_time AS [Last Executed],
    OBJECT_NAME(st.objectid, st.dbid) AS [Object Name],
    qs.query_hash AS [Query Hash],
    qs.query_plan_hash AS [Plan Hash]
FROM sys.dm_exec_query_stats qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st
WHERE qs.execution_count > 1
ORDER BY qs.total_elapsed_time / qs.execution_count DESC
OPTION (MAXDOP 1);
```

#### 7a-iii: Top IO-Consuming Queries (Plan Cache)

Catches IO-bound queries with high logical reads but modest CPU — typically missing indexes or large scans:

```sql
SELECT TOP ({{TopN}})
    CAST(qs.total_logical_reads / qs.execution_count AS NUMERIC(18,0))
        AS [Avg Logical Reads],
    CAST(qs.total_physical_reads * 1.0 / qs.execution_count AS NUMERIC(18,1))
        AS [Avg Physical Reads],
    CAST(qs.total_elapsed_time / 1000.0 / qs.execution_count AS NUMERIC(18,1))
        AS [Avg Duration (ms)],
    CAST(qs.total_worker_time / 1000.0 / qs.execution_count AS NUMERIC(18,1))
        AS [Avg CPU (ms)],
    qs.execution_count AS [Executions],
    qs.creation_time AS [Plan Created],
    qs.last_execution_time AS [Last Executed],
    OBJECT_NAME(st.objectid, st.dbid) AS [Object Name],
    qs.query_hash AS [Query Hash],
    qs.query_plan_hash AS [Plan Hash]
FROM sys.dm_exec_query_stats qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st
WHERE qs.execution_count > 1
ORDER BY qs.total_logical_reads / qs.execution_count DESC
OPTION (MAXDOP 1);
```

#### Typical Interpretations (7a / 7a-ii / 7a-iii)

- **High Avg CPU but low Avg Logical Reads**: Compute-bound query (string manipulation, scalar UDFs, complex expressions). Consider rewriting.
- **High Avg CPU and high Avg Logical Reads**: Missing indexes causing table/index scans. Run the `missing-index-analysis` skill.
- **High Avg Duration but low Avg CPU** (7a-ii): Wait-bound — the query spends most time waiting (locks, IO, network). Check `Avg Wait Time` and investigate blocking or IO pressure.
- **High Avg Logical Reads but moderate CPU/Duration** (7a-iii): IO-bound — large scans or missing indexes. Run the `missing-index-analysis` skill.
- **Plan Created very recently**: Plan was recently recompiled — may indicate a plan regression. Compare with previous execution patterns.
- **Query Hash**: Use the query hash to group related entries and track the same logical query across plan recompilations.

#### What to Do

- **Top CPU query with high Logical Reads**: Likely missing an index. Run the `missing-index-analysis` skill targeting those tables.
- **Top CPU query with low Logical Reads**: Compute-bound — look for scalar UDFs, implicit type conversions, or complex string operations. Rewrite using inline table-valued functions or set-based logic.
- **Recently created plan with high CPU**: Possible plan regression after a recompile. Compare the `Plan Hash` with known-good plans. If Query Store is available, consider forcing a previous plan.
- **Many entries with same Query Hash but different Plan Hash**: Parameter sniffing in plan cache — different compilations produced different plans. Add `OPTION (OPTIMIZE FOR UNKNOWN)` or `OPTION (RECOMPILE)` to stabilize.
- **Consider enabling Query Store**: If not already enabled, recommend enabling it for ongoing monitoring:
  ```sql
  ALTER DATABASE [DatabaseName] SET QUERY_STORE = ON (OPERATION_MODE = READ_WRITE);
  
```

#### 7b: Multi-Plan Queries (Plan Cache)

```sql
SELECT TOP ({{TopN}})
    qs.query_hash AS [Query Hash],
    OBJECT_NAME(MIN(st.objectid), MIN(st.dbid)) AS [Object Name],
    COUNT(DISTINCT qs.plan_handle) AS [Plan Count],
    MIN(CAST(qs.total_elapsed_time / 1000.0 / qs.execution_count AS NUMERIC(18,1)))
        AS [Min Avg Duration (ms)],
    MAX(CAST(qs.total_elapsed_time / 1000.0 / qs.execution_count AS NUMERIC(18,1)))
        AS [Max Avg Duration (ms)],
    SUM(qs.execution_count) AS [Total Executions]
FROM sys.dm_exec_query_stats qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st
GROUP BY qs.query_hash
HAVING COUNT(DISTINCT qs.plan_handle) > 1
ORDER BY [Max Avg Duration (ms)] DESC
OPTION (MAXDOP 1);
```

#### Typical Interpretations

- **Plan Count > 3**: High plan instability — strong indicator of parameter sniffing or frequent recompilations.
- **Large gap between Min and Max Avg Duration**: Confirms that different plans have vastly different performance characteristics.
- **Query Hash grouping**: Unlike grouping by SQL text, query hash correctly groups queries with minor text differences (whitespace, casing) that are logically identical.

#### What to Do

- **Plan Count > 3 with large duration gap**: Confirmed plan instability. If Query Store is available, force the best plan. If not, add `OPTION (OPTIMIZE FOR UNKNOWN)` to the query.
- **High Total Executions with multiple plans**: Ad-hoc query pattern — the application is sending unparameterized queries. Recommend:
  1. Enable `FORCED PARAMETERIZATION` on the database:
     ```sql
     ALTER DATABASE [DatabaseName] SET PARAMETERIZATION FORCED;
     
```
  2. Or better: modify the application to use parameterized queries / stored procedures
- **All multi-plan queries are stored procedures**: Classic parameter sniffing. Add `WITH RECOMPILE` to the procedure or use `OPTION (RECOMPILE)` on specific statements.
- **Consider enabling Query Store** for historical plan tracking and plan forcing capabilities.

#### 7c: Currently Running Long Queries

```sql
SELECT TOP ({{TopN}})
    r.session_id AS [Session ID],
    r.start_time AS [Start Time],
    DATEDIFF(SECOND, r.start_time, GETDATE()) AS [Running Seconds],
    r.status AS [Status],
    r.wait_type AS [Wait Type],
    r.wait_time AS [Wait Time (ms)],
    r.blocking_session_id AS [Blocked By],
    CAST(r.cpu_time / 1000.0 AS NUMERIC(18,1)) AS [CPU Time (ms)],
    r.logical_reads AS [Logical Reads],
    r.command AS [Command],
    OBJECT_NAME(st.objectid, st.dbid) AS [Object Name],
    r.query_hash AS [Query Hash],
    r.query_plan_hash AS [Plan Hash]
FROM sys.dm_exec_requests r
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) st
WHERE r.session_id > 50
  AND r.session_id <> @@SPID
ORDER BY r.total_elapsed_time DESC
OPTION (MAXDOP 1);
```

#### Typical Interpretations

- **Wait Type is not NULL**: The query is actively waiting — check what resource it's blocked on (locks, IO, memory).
- **Blocked By > 0**: Active blocking chain. Run the `check-live-blocking` skill for full blocking tree analysis.
- **Running Seconds > 300**: Long-running query — may be holding locks that block others.
- **Command = 'UPDATE' or 'DELETE' with high Logical Reads**: Potentially missing index on the WHERE clause, causing a table scan for the modification.
- **Multiple sessions with same Wait Type**: Systemic resource bottleneck rather than a single bad query.

#### What to Do

- **Blocked By > 0**: Investigate the blocking chain immediately with the `check-live-blocking` skill. If the blocker is an idle session holding locks, you may recommend killing it — never run `KILL` yourself without the user's explicit confirmation for that specific session. First explain the impact: the session's open transaction is rolled back (which can take as long as the work already done and cannot be undone), and the application loses its connection:
  ```sql
  KILL <blocking_session_id>;  -- Recommendation only: run only after explicit user confirmation
  
```
- **Long-running query (> 300s) with no blocking**: Check if it's a runaway query — review the execution plan for table scans or excessive parallelism. Consider setting a query timeout.
- **Wait Type = LCK_M_***: Lock contention — review the transaction isolation level. Consider recommending `READ COMMITTED SNAPSHOT` (a database-wide change that adds tempdb version-store load and needs exclusive access to switch; run only after the user explicitly confirms):
  ```sql
  ALTER DATABASE [DatabaseName] SET READ_COMMITTED_SNAPSHOT ON;
  
```
- **Wait Type = PAGEIOLATCH_***: IO bottleneck — the query is waiting for pages to be read from disk. Run the `missing-index-analysis` skill and check storage performance.
- **Wait Type = CXPACKET/CXCONSUMER**: Parallelism skew — consider lowering MAXDOP for the affected query or at the database level.
- **Many sessions running same Command**: Application-level issue (retry storms, connection pool exhaustion). Investigate the application layer.
