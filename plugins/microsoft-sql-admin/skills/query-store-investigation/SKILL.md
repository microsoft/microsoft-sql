---
name: query-store-investigation
description: "Use when the user asks for top or regressed queries in Query Store: what got slower since a deploy versus a baseline, or which earlier plan to force. When Query Store is off, use `top-queries-noqds`."
user-invocable: true
argument-hint: "[TopN] [HistDaysBack] [CurrHoursBack] [AvgCpuTime] [MinExecCount] [RegressionFactor]"
---

# Query Store Performance Investigation

Use this skill when the user asks about query performance analysis, top resource-consuming queries, or recently regressed queries and **Query Store is enabled**.

## Scope

- Covers top resource-consuming queries (duration, CPU, logical IO), regressed queries found by comparing a recent runtime window with a historical baseline, and the best historical plan versus the current plan.
- For volatile or intermittent queries, one query_id's interval-by-interval drill-down, per-query waits, aborted executions, forced-plan failures, or parameter sensitivity, use `query-store-volatile-historical-slow-queries-comparison`.

## Required tools

- A SQL query tool connected to the target server and database. Prefer, in order: the SQL Tools MCP
  server that ships with the `microsoft-sql-admin` plugin (`mssql_list_database_connections`,
  `mssql_connect_database`, then `mssql_execute_query`); any other SQL tool the agent host provides
  for running T-SQL and reading result sets;
  [`sqlcmd`](https://learn.microsoft.com/sql/tools/sqlcmd/sqlcmd-utility) from a terminal. If the
  SQL Tools MCP server is not connected or lists no connections, follow the `sql-tools-mcp-setup`
  skill, which asks before installing or configuring anything. If no SQL tool can be made available,
  give the user the T-SQL to run and ask for the results.

With the SQL Tools MCP server, run these queries through `mssql_execute_query`. To inspect a plan,
pass its `plan_id` as `queryStorePlanId` to `SummarizePlan`, `GetPlanWarnings` or
`PlanBottleneckAnalysis` rather than returning showplan XML. One plan-tool call per plan; do not
re-run the workload to compare plans.

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| TopN | 25 | Maximum number of rows to return per query |
| HistDaysBack | 1 | Days back for the historical baseline window |
| CurrHoursBack | 1 | Hours back for the current (recent) window |
| AvgCpuTime | 1000 | Minimum avg CPU time (µs) to include a query |
| MinExecCount | 3 | Minimum execution count to include a query |
| RegressionFactor | 2 | Only return queries where current avg CPU > best historical avg CPU × this multiplier |

## Best Practices

1. By default, only get the first 100 chars of query text.
2. Don't return showplan XML unless specifically asked — plans can be very large.
3. Preserve `datetimeoffset` boundaries when filtering Query Store timestamps. Casting them to
   `datetime`, or comparing with local `GETDATE()`, shifts windows on non-UTC SQL Server hosts.
4. **Confirmation gate for state-changing commands.** `sp_query_store_force_plan`,
   `sp_query_store_unforce_plan`, `sp_query_store_remove_plan`, `sp_query_store_set_hints`,
   `sp_query_store_clear_hints`, and `sp_query_store_remove_query` change Query Store state and
   query behavior. Present them as recommendations only. Never run any of them without the
   user's explicit confirmation for that specific command, and explain its impact and how to roll
   it back first. The investigation queries in this skill are read-only.
5. **A historical plan can be forced only while every index it uses still exists.** If the plan
   names an index that was dropped, renamed or disabled since it was compiled (often by the release
   that caused the regression), `sp_query_store_force_plan` succeeds but the plan is never applied
   (`NO_INDEX`, 8712). Before you recommend forcing a plan, run the read-only check under
   `ForceBestHistPlanCmd` below; when it returns rows, forcing is not a fix.

## Example Queries

### Top Resource-Consuming Queries (Last Hour)
```sql
SELECT TOP 10
    ([rs].[avg_duration]) [AvgDuration],
    SUM([rs].[count_executions]) [TotalExecutions],
    [qsq].[query_id],
    LEFT([qst].[query_sql_text], 100) AS query_text_snippet,
    CASE
        WHEN [qsq].[object_id] = 0 THEN N'Ad-hoc'
        ELSE OBJECT_NAME([qsq].[object_id])
    END AS [ObjectName]
FROM [sys].[query_store_query] [qsq]
JOIN [sys].[query_store_query_text] [qst] ON [qsq].[query_text_id] = [qst].[query_text_id]
JOIN [sys].[query_store_plan] [qsp] ON [qsq].[query_id] = [qsp].[query_id]
JOIN [sys].[query_store_runtime_stats] [rs] ON [qsp].[plan_id] = [rs].[plan_id]
WHERE [rs].[last_execution_time] > DATEADD(HOUR, -1, GETUTCDATE())
    AND [rs].[execution_type] = 0
GROUP BY [rs].[avg_duration], [qsq].[query_id], [qst].[query_sql_text], [qsq].[object_id]
ORDER BY ([rs].[avg_duration]) DESC
OPTION (MAXDOP 1);
```

### Top Queries by Logical IO (Last Hour)
```sql
SELECT TOP 10
    ([rs].[avg_logical_io_reads]) [AvgLogicalIO],
    SUM([rs].[count_executions]) [TotalExecutions],
    [qsq].[query_id],
    LEFT([qst].[query_sql_text], 100) AS query_text_snippet,
    CASE
        WHEN [qsq].[object_id] = 0 THEN N'Ad-hoc'
        ELSE OBJECT_NAME([qsq].[object_id])
    END AS [ObjectName]
FROM [sys].[query_store_query] [qsq]
JOIN [sys].[query_store_query_text] [qst] ON [qsq].[query_text_id] = [qst].[query_text_id]
JOIN [sys].[query_store_plan] [qsp] ON [qsq].[query_id] = [qsp].[query_id]
JOIN [sys].[query_store_runtime_stats] [rs] ON [qsp].[plan_id] = [rs].[plan_id]
WHERE [rs].[last_execution_time] > DATEADD(HOUR, -1, GETUTCDATE())
GROUP BY [rs].[avg_logical_io_reads], [qsq].[query_id], [qst].[query_sql_text], [qsq].[object_id]
ORDER BY ([rs].[avg_logical_io_reads]) DESC
OPTION (MAXDOP 1);
```

### Recently Regressed Queries (Last Hour vs. Prior 24 Hours)
```sql
WITH Last24Hours AS (
    SELECT
        qsq.query_id,
        LEFT(qst.query_sql_text, 100) AS query_text_snippet,
        CASE WHEN qsq.object_id = 0 THEN N'Ad-hoc' ELSE OBJECT_NAME(qsq.object_id) END AS object_name,
        AVG(rs.avg_duration) AS avg_duration,
        AVG(rs.avg_logical_io_reads) AS avg_logical_io_reads,
        SUM(rs.count_executions) AS total_executions
    FROM sys.query_store_query qsq
    JOIN sys.query_store_query_text qst ON qsq.query_text_id = qst.query_text_id
    JOIN sys.query_store_plan qsp ON qsq.query_id = qsp.query_id
    JOIN sys.query_store_runtime_stats rs ON qsp.plan_id = rs.plan_id
    WHERE rs.last_execution_time BETWEEN DATEADD(hour, -25, SYSDATETIMEOFFSET()) AND DATEADD(hour, -1, SYSDATETIMEOFFSET())
    GROUP BY qsq.query_id, qst.query_sql_text, qsq.object_id
),
LastHour AS (
    SELECT
        qsq.query_id,
        LEFT(qst.query_sql_text, 100) AS query_text_snippet,
        CASE WHEN qsq.object_id = 0 THEN N'Ad-hoc' ELSE OBJECT_NAME(qsq.object_id) END AS object_name,
        AVG(rs.avg_duration) AS avg_duration,
        AVG(rs.avg_logical_io_reads) AS avg_logical_io_reads,
        SUM(rs.count_executions) AS total_executions
    FROM sys.query_store_query qsq
    JOIN sys.query_store_query_text qst ON qsq.query_text_id = qst.query_text_id
    JOIN sys.query_store_plan qsp ON qsq.query_id = qsp.query_id
    JOIN sys.query_store_runtime_stats rs ON qsp.plan_id = rs.plan_id
    WHERE rs.last_execution_time > DATEADD(hour, -1, SYSDATETIMEOFFSET())
    GROUP BY qsq.query_id, qst.query_sql_text, qsq.object_id
)
SELECT TOP ({{TopN}})
    l24.query_id, l24.query_text_snippet, l24.object_name,
    l24.avg_duration AS last_24h_avg_duration,
    lh.avg_duration AS last_hour_avg_duration,
    l24.avg_logical_io_reads AS last_24h_avg_io,
    lh.avg_logical_io_reads AS last_hour_avg_io,
    l24.total_executions AS last_24h_executions,
    lh.total_executions AS last_hour_executions,
    CASE WHEN l24.avg_duration = 0 THEN 0
         ELSE ((lh.avg_duration - l24.avg_duration) / l24.avg_duration) * 100
    END AS duration_change_pct,
    CASE WHEN l24.avg_logical_io_reads = 0 THEN 0
         ELSE ((lh.avg_logical_io_reads - l24.avg_logical_io_reads) / l24.avg_logical_io_reads) * 100
    END AS io_change_pct
FROM Last24Hours l24
JOIN LastHour lh ON l24.query_id = lh.query_id
WHERE CASE WHEN l24.avg_duration = 0 THEN 0
           ELSE ((lh.avg_duration - l24.avg_duration) / l24.avg_duration) * 100 END > 10
   OR CASE WHEN l24.avg_logical_io_reads = 0 THEN 0
           ELSE ((lh.avg_logical_io_reads - l24.avg_logical_io_reads) / l24.avg_logical_io_reads) * 100 END > 10
ORDER BY duration_change_pct DESC, io_change_pct DESC
OPTION (MAXDOP 1);
```

### Regressed Queries with Best Plan Recommendation

Identifies queries whose CPU has regressed in a recent window compared to a historical baseline, and surfaces the best historical plan to force as a remediation option. Returns `RemoveCurrentPlanCmd` and `ForceBestHistPlanCmd` columns as generated command text for the user to review; the query itself does not change Query Store (it only uses session temp tables) and never runs them.

> **Note on window overlap:** the historical window spans the full `{{HistDaysBack}}` day(s) and intentionally overlaps with the current window. This provides a robust full-day CPU baseline that includes recent hours.

```sql
-- Time windows derived from parameters
DECLARE @StartTime     DATETIMEOFFSET = DATEADD(HOUR, -{{CurrHoursBack}}, SYSDATETIMEOFFSET());
DECLARE @EndTime       DATETIMEOFFSET = SYSDATETIMEOFFSET();
DECLARE @HistStartTime DATETIMEOFFSET = DATEADD(DAY,  -{{HistDaysBack}},  SYSDATETIMEOFFSET());
DECLARE @HistEndTime   DATETIMEOFFSET = DATEADD(MILLISECOND, -3, DATEADD(DAY, {{HistDaysBack}}, @HistStartTime));

DROP TABLE IF EXISTS #CurrentStats, #HistStats, #HistPlans,
    #BestHistPlan30Days, #CurrentPlans, #TotalCpuCurrentInterval;

-- Current stats: aggregated CPU over the recent window
SELECT TOP ({{TopN}})
    p.query_id,
    SUM(rs.count_executions * rs.avg_cpu_time) / SUM(rs.count_executions) AS AvgCpuTime,
    SUM(rs.count_executions)                                               AS ExecCount,
    AVG(rs.count_executions * rs.avg_cpu_time)                            AS AvgTotallExTime,
    COUNT(DISTINCT rs.runtime_stats_interval_id)                          AS QtyIntervals
INTO #CurrentStats
FROM sys.query_store_runtime_stats rs
JOIN sys.query_store_runtime_stats_interval rsi
    ON rs.runtime_stats_interval_id = rsi.runtime_stats_interval_id
JOIN sys.query_store_plan p ON rs.plan_id = p.plan_id
WHERE rsi.start_time BETWEEN @StartTime AND @EndTime
  AND rs.count_executions > {{MinExecCount}}
  AND rs.avg_cpu_time     > {{AvgCpuTime}}
GROUP BY p.query_id
OPTION (MAXDOP 1);

-- Total CPU across all plans in current window (used for % of total calculation)
SELECT SUM(rs.avg_cpu_time * rs.count_executions) AS TotalCpuTimeCurrentWindow
INTO #TotalCpuCurrentInterval
FROM sys.query_store_runtime_stats rs
JOIN sys.query_store_runtime_stats_interval rsi
    ON rs.runtime_stats_interval_id = rsi.runtime_stats_interval_id
WHERE rsi.start_time BETWEEN @StartTime AND @EndTime
OPTION (MAXDOP 1);

-- Most recent plan used per query in the current window
SELECT
    p.query_id,
    p.plan_id AS CurrentPlanId,
    AVG(rs.count_executions * rs.avg_cpu_time) AS PlanAvgTotallExTime,
    ROW_NUMBER() OVER (PARTITION BY p.query_id ORDER BY MAX(rs.last_execution_time) DESC) AS rn
INTO #CurrentPlans
FROM sys.query_store_plan p
JOIN sys.query_store_runtime_stats rs ON rs.plan_id = p.plan_id
JOIN sys.query_store_runtime_stats_interval rsi
    ON rs.runtime_stats_interval_id = rsi.runtime_stats_interval_id
WHERE rsi.start_time BETWEEN @StartTime AND @EndTime
GROUP BY p.query_id, p.plan_id
OPTION (MAXDOP 1);

-- Historical stats over the baseline window
SELECT
    p.query_id,
    SUM(rs.avg_cpu_time * rs.count_executions) / SUM(rs.count_executions) AS HistAvgCpuTime,
    SUM(rs.count_executions)                                               AS ExecCount,
    AVG(rs.count_executions * rs.avg_cpu_time)                            AS HistAvgTotallExTime,
    COUNT(DISTINCT rs.runtime_stats_interval_id)                          AS HistQtyIntervals
INTO #HistStats
FROM sys.query_store_runtime_stats rs
JOIN sys.query_store_runtime_stats_interval rsi
    ON rs.runtime_stats_interval_id = rsi.runtime_stats_interval_id
JOIN sys.query_store_plan p ON rs.plan_id = p.plan_id
WHERE rsi.start_time BETWEEN @HistStartTime AND @HistEndTime
  AND rs.count_executions > {{MinExecCount}}
  AND rs.avg_cpu_time     > {{AvgCpuTime}}
GROUP BY p.query_id
OPTION (MAXDOP 1);

-- Best historical plan per query over the last 30 days (lowest avg CPU)
SELECT t.query_id, t.plan_id AS BestHistPlanId, t.PlanAvgCpuTime
INTO #BestHistPlan30Days
FROM (
    SELECT
        p.query_id,
        rs.plan_id,
        SUM(rs.avg_cpu_time * rs.count_executions) / SUM(rs.count_executions) AS PlanAvgCpuTime,
        ROW_NUMBER() OVER (
            PARTITION BY p.query_id
            ORDER BY SUM(rs.avg_cpu_time * rs.count_executions) / SUM(rs.count_executions) ASC
        ) AS rn
    FROM sys.query_store_runtime_stats rs
    JOIN sys.query_store_runtime_stats_interval rsi
        ON rs.runtime_stats_interval_id = rsi.runtime_stats_interval_id
    JOIN sys.query_store_plan p ON rs.plan_id = p.plan_id
    WHERE rsi.start_time > DATEADD(DAY, -30, SYSDATETIMEOFFSET())
    GROUP BY p.query_id, rs.plan_id
) t
JOIN (
    SELECT query_id FROM #CurrentStats
    UNION
    SELECT query_id FROM #HistStats
) qId ON t.query_id = qId.query_id
WHERE t.rn = 1
OPTION (MAXDOP 1, RECOMPILE);

-- Final output: regressed queries with plan remediation commands
SELECT TOP ({{TopN}})
    cs.query_id,
    cp.CurrentPlanId,
    CAST(
        (cp.PlanAvgTotallExTime * 100.0)
        / (SELECT TotalCpuTimeCurrentWindow FROM #TotalCpuCurrentInterval)
        AS DECIMAL(10, 2)
    )                                                                  AS BadPlanCpuPctOfTotal,
    cs.ExecCount                                                       AS CurrentExecCount,
    hs.ExecCount                                                       AS HistExecCount,
    cs.ExecCount / cs.QtyIntervals                                     AS CurrentExecPerInterval,
    hs.ExecCount / hs.HistQtyIntervals                                 AS HistExecPerInterval,
    CAST(cs.AvgTotallExTime  / 1000 AS BIGINT)                        AS CurrentAvgTotalCpuMS,
    CAST(hs.HistAvgTotallExTime / 1000 AS BIGINT)                     AS HistAvgTotalCpuMS,
    CAST(cs.AvgCpuTime       / 1000 AS BIGINT)                        AS CurrentAvgCpuMS,
    CAST(bh.PlanAvgCpuTime   / 1000 AS BIGINT)                        AS HistAvgCpuMS,
    CAST(cs.AvgCpuTime * 1.0 / bh.PlanAvgCpuTime AS DECIMAL(10, 2))  AS RegressionFactor,
    q.query_hash,
    qt.query_sql_text                                                  AS QuerySQLText,
    'EXEC sp_query_store_remove_plan @plan_id = '
        + CAST(cp.CurrentPlanId AS NVARCHAR(100))                     AS RemoveCurrentPlanCmd,
    'EXEC sp_query_store_force_plan @query_id = '
        + CAST(cs.query_id AS NVARCHAR(100))
        + ', @plan_id = '
        + CAST(bh.BestHistPlanId AS NVARCHAR(100))                    AS ForceBestHistPlanCmd,
    bh.BestHistPlanId
FROM #CurrentStats cs
JOIN #HistStats hs          ON cs.query_id = hs.query_id
JOIN #BestHistPlan30Days bh ON cs.query_id = bh.query_id
JOIN #CurrentPlans cp       ON cs.query_id = cp.query_id AND cp.rn = 1
JOIN sys.query_store_query q ON cs.query_id = q.query_id
JOIN sys.query_store_query_text qt ON q.query_text_id = qt.query_text_id
WHERE cs.AvgCpuTime > bh.PlanAvgCpuTime * {{RegressionFactor}}
ORDER BY BadPlanCpuPctOfTotal DESC
OPTION (MAXDOP 1);

-- Cleanup
DROP TABLE IF EXISTS #CurrentStats, #HistStats, #HistPlans,
    #BestHistPlan30Days, #CurrentPlans, #TotalCpuCurrentInterval;
```

## Plan Remediation Commands

The final output of the **Regressed Queries** query includes two generated remediation commands. Present them to the user as recommendations only and explain what each does before anything is executed.

> **Confirmation required.** These commands change Query Store state and the plans the query uses. Never run `sp_query_store_force_plan`, `sp_query_store_unforce_plan`, or `sp_query_store_remove_plan` (or any similar Query Store procedure) without the user's explicit confirmation for that specific command. Before asking, state the impact (which `query_id`/`plan_id` is affected, what changes for the workload) and the rollback (unforce a forced plan; a removed plan cannot be restored). A general request to "fix" or "investigate" is not confirmation.

### `RemoveCurrentPlanCmd` — `sp_query_store_remove_plan`

```sql
EXEC sp_query_store_remove_plan @plan_id = <CurrentPlanId>
```

**What it does:** Permanently deletes the bad plan from Query Store. SQL Server will recompile the query on next execution and pick a new plan from scratch.

**When to use:**
- The current plan is clearly bad (high `RegressionFactor`, high `BadPlanCpuPctOfTotal`) but you don't have a known-good historical plan to force
- You want to give the optimizer a clean slate without locking in a specific plan
- Use as a last resort — once removed, the plan history for that `plan_id` is gone

> ⚠️ This is destructive. The plan cannot be recovered after removal.

---

### `ForceBestHistPlanCmd` — `sp_query_store_force_plan`

```sql
EXEC sp_query_store_force_plan @query_id = <query_id>, @plan_id = <BestHistPlanId>
```

**What it does:** Tells Query Store to always use the specified historical plan for this query, bypassing the optimizer's plan selection. The forced plan persists until explicitly unforced.

**When to use:**
- You have a verified good historical plan (`BestHistPlanId`) that was performing well before the regression
- The regression is caused by a bad plan choice (parameter sniffing, stale statistics, cardinality estimation error) rather than a schema or data volume change
- As a **fast mitigation** during an active incident — stops the bleeding immediately while you investigate root cause

**Check first that the plan can still be forced.** Forcing works only while every index the plan uses still exists under the same name and is enabled. If one was dropped, renamed or disabled after the plan was compiled, `sp_query_store_force_plan` still succeeds, but every compile then fails to apply the plan (`last_force_failure_reason_desc` = `NO_INDEX`, 8712) and the query keeps the optimizer's own plan. This read-only query, run in the query's database, lists the indexes the plan names that are now missing or disabled:

```sql
DECLARE @plan_id bigint = <BestHistPlanId>;
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

Any row means forcing this plan will not take effect: do not present it as a fix on its own. The missing index is often the cause of the regression; propose recreating or re-enabling it (its definition is in the release script or source control). No rows means every index the plan names in this database is there; forcing can still fail for other reasons, so after the user forces it and the query recompiles, read `force_failure_count` and `last_force_failure_reason_desc` for the plan. Indexes in other databases are not checked, and a plan nested deeper than the `xml` type allows (128 levels) returns no rows; read its `Object` elements from the plan text instead.

**To unforce a plan later:**
```sql
EXEC sp_query_store_unforce_plan @query_id = <query_id>, @plan_id = <BestHistPlanId>
```

**Recommended order of operations** (each command only after the user explicitly confirms it):
1. Recommend `ForceBestHistPlanCmd` first, if the plan passes the check above — immediate relief, reversible
2. Monitor CPU improvement via `BadPlanCpuPctOfTotal`
3. If forcing doesn't help (e.g. data volume changed), recommend `RemoveCurrentPlanCmd` to trigger a fresh recompile
4. Investigate root cause (missing index, stale stats, implicit conversion) to prevent recurrence

---

## Query Store Schema Reference

### sys.query_store_plan key columns
- `plan_id`, `query_id`, `query_plan_hash`, `is_forced_plan`, `is_parallel_plan`
- `last_compile_start_time`, `last_execution_time`, `count_compiles`

### sys.query_store_query key columns
- `query_id`, `query_text_id`, `object_id`, `query_hash`
- `initial_compile_start_time`, `last_execution_time`, `count_compiles`

### sys.query_store_runtime_stats_interval key columns
- `runtime_stats_interval_id`, `start_time`, `end_time`

## Correlating incident captures

Use the [shared incident evidence rules](references/incident-evidence.md): execution-weighted averages, per-query time windows, positive-session blocking graphs, sleeping heads and distinct downstream counts. Keep diagnostic candidates separate from authorized actions.
