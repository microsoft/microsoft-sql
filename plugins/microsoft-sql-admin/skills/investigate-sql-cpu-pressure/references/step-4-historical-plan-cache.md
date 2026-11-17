# Step 4 — Historical Top CPU Consumers (Plan Cache, Cumulative)

Execute via the SQL query tool. Aggregates **cumulative** CPU since each plan was compiled.
`last_execution_time` filters to recently-active plans, but `total_worker_time` covers all
executions since the plan entered cache — not just the lookback window.

```sql
-- total_worker_time is cumulative since plan compilation, not scoped to the last
-- {{HistoryLookbackHours}}h. last_execution_time is used only to filter recently-active plans.
SELECT TOP ({{TopN}})
      qs.execution_count
    , qs.total_worker_time                                            AS total_worker_time_microsec
    , qs.total_worker_time / 1000                                     AS total_worker_time_ms
    , qs.total_worker_time / NULLIF(qs.execution_count, 0)            AS worker_time_per_exec_microsec
    , (qs.total_worker_time / NULLIF(qs.execution_count, 0)) / 1000   AS worker_time_per_exec_ms
    , qs.total_elapsed_time / 1000                                    AS total_elapsed_time_ms
    , qs.total_logical_reads
    , qs.total_logical_writes
    , qs.max_worker_time / 1000                                       AS max_worker_time_ms
    , qs.last_worker_time / 1000                                      AS last_worker_time_ms
    , qs.last_execution_time
    , DB_NAME(st.dbid)                                                AS database_name
    , OBJECT_NAME(st.objectid, st.dbid)                               AS object_name
    , qs.query_hash
    , qs.query_plan_hash
FROM sys.dm_exec_query_stats      AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle)    AS st
WHERE qs.execution_count > {{MinExecutionCount}}
  AND qs.total_worker_time > {{MinTotalWorkerTimeUs}}  -- at least 1 second of cumulative CPU at default
  AND qs.last_execution_time >= DATEADD(HOUR, -{{HistoryLookbackHours}}, GETDATE())
ORDER BY qs.total_worker_time DESC
OPTION (MAXDOP 1);
```

Rows with high `worker_time_per_exec_ms` or extreme `execution_count` × `worker_time_per_exec_ms`
products are strong candidates for the Step 7 shortlist.
