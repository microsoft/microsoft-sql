# Database-Scoped CPU Investigation — Query Store

Use this path **instead of** the server-DMV steps when the effective database user
has `VIEW DATABASE PERFORMANCE STATE` (SQL Server 2022+) or `VIEW DATABASE STATE`
(SQL Server 2016–2019) but no server-state permission. Managed Instance and
Azure SQL use their database permissions regardless of the reported major version.
All queries use only the connected database. Query Store records **completed captured queries**; it cannot measure
instance-wide CPU utilization, currently running requests, or uncaptured queries.
The host connection and database-user permissions remain the authorization boundary.

## Check Query Store availability

Execute via the SQL query tool:

```sql
SELECT actual_state_desc AS query_store_state
FROM sys.database_query_store_options
OPTION (MAXDOP 1);
```

If this fails, report the actual SQL error. If `query_store_state = OFF` or
`ERROR`, stop with an evidence gap: do not enable Query Store. If `READ_ONLY`
or `READ_CAPTURE_SECONDARY`, continue but note that new local workload may
not be captured. If `READ_WRITE`,
proceed. Never interpret an unavailable Query Store as low CPU.

## Step 4: Recently Active Database CPU Consumers

Execute via the SQL query tool after replacing `{{TopN}}` and
`{{HistoryLookbackHours}}` with the skill defaults or caller values. Use only
decimal integer values (`TopN` 1–100; `HistoryLookbackHours` 1–8760).
Reject nonnumeric or out-of-range caller values; never concatenate caller text into SQL.

```sql
SELECT TOP ({{TopN}})
      q.query_id
    , p.plan_id
    , q.query_hash
    , p.query_plan_hash
    , OBJECT_NAME(q.object_id) AS object_name
    , SUM(rs.count_executions) AS execution_count
    , CAST(SUM(rs.avg_cpu_time * rs.count_executions) / 1000.0 AS decimal(20,2)) AS recorded_cpu_ms
    , CAST(SUM(rs.avg_cpu_time * rs.count_executions)
        / NULLIF(SUM(rs.count_executions), 0) / 1000.0 AS decimal(20,2)) AS cpu_per_exec_ms
    , CAST(MAX(rs.max_cpu_time) / 1000.0 AS decimal(20,2)) AS max_cpu_ms
    , MAX(rs.last_execution_time) AS last_execution_time
FROM sys.query_store_runtime_stats AS rs
JOIN sys.query_store_plan AS p ON p.plan_id = rs.plan_id
JOIN sys.query_store_query AS q ON q.query_id = p.query_id
WHERE rs.execution_type = 0
  AND q.is_internal_query = 0
  AND rs.last_execution_time >= DATEADD(HOUR, -{{HistoryLookbackHours}}, SYSDATETIMEOFFSET())
GROUP BY q.query_id, p.plan_id, q.query_hash, p.query_plan_hash, q.object_id
ORDER BY recorded_cpu_ms DESC
OPTION (MAXDOP 1);
```

`avg_cpu_time` is in **microseconds**; `recorded_cpu_ms` is the sum of
interval-average CPU multiplied by execution count, converted to milliseconds.
This filters by *last execution* in the lookback, but each selected runtime
stats row may include executions from earlier in its aggregation interval.
Do not label these numbers exact CPU consumed during the lookback or compare
them to the `CpuThresholdPct` instance/database utilization threshold.
Unlike the plan-cache path, do not filter out single-execution plans using
`MinExecutionCount` or `MinTotalWorkerTimeUs`: one expensive query matters.
An empty result may mean Query Store has not captured the workload, not that
CPU pressure is absent.

## Step 7: Inspect Captured Offenders (conditional)

If Step 4 returns one or more CPU-consuming plans, select at most `{{TopN}}`
distinct top `(query_id, plan_id)` pairs to inspect. Substitute **only positive
integer identifiers returned by Step 4**, never caller text or arbitrary input.
Run this query once per selected pair via the SQL query tool:

```sql
SELECT
      q.query_id
    , p.plan_id
    , q.query_hash
    , p.query_plan_hash
    , OBJECT_NAME(q.object_id) AS object_name
    , qt.query_sql_text AS statement_text
    , p.query_plan
FROM sys.query_store_query AS q
JOIN sys.query_store_plan AS p ON p.query_id = q.query_id
JOIN sys.query_store_query_text AS qt ON qt.query_text_id = q.query_text_id
WHERE q.query_id = {{QueryId}}
  AND p.plan_id = {{PlanId}}
  AND q.is_internal_query = 0
OPTION (MAXDOP 1);
```

If no plan is available, analyze the returned text only. Apply the text/plan
analysis checklist in `references/step-7-query-text-and-plan-analysis.md`
without running its **server-DMV Step 7a query**. Base recommendations on
observed query text and plan, not on CPU rankings alone.

## Report

Include Query Store state, the lookback window, top recorded CPU consumers,
and any concrete Step 7 findings in `references/report-template.md`. State
that scheduler pressure and instance CPU percentage were **not measured**.
Retain any collected Azure resource-stats Step 1 as a separate database CPU signal,
even if Query Store is unavailable or returns no rows.
When there are no rows, disabled capture, or a query failure, record the
corresponding evidence gap; never conclude that the reported CPU alert was false.
