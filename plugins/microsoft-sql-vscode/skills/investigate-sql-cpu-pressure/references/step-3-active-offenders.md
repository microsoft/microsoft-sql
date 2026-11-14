# Step 3 — Top Real-Time CPU Consumers (Identifiers for Follow-up)

Execute via the SQL query tool. Finds active CPU consumers regardless of their current
wait type, including requests currently running on CPU.

```sql
SELECT TOP ({{TopN}})
      req.session_id
    , req.request_id
    , req.status
    , req.start_time
    , req.cpu_time                                          AS cpu_time_ms
    , req.total_elapsed_time                                AS elapsed_time_ms
    , req.wait_type
    , req.wait_time                                         AS wait_time_ms
    , OBJECT_NAME(st.objectid, st.dbid)                     AS object_name

    , req.query_hash
    , req.query_plan_hash
FROM sys.dm_exec_requests  AS req
JOIN sys.dm_exec_sessions  AS s
  ON req.session_id = s.session_id
CROSS APPLY sys.dm_exec_sql_text(req.sql_handle)             AS st
WHERE req.session_id <> @@SPID
  AND req.group_id   >  1
  AND req.cpu_time   > {{CpuThresholdMs}}
ORDER BY req.cpu_time DESC
OPTION (MAXDOP 1);
```

Each row's `query_hash` / `query_plan_hash` becomes a candidate for the Step 7 shortlist.
The query returns identifiers, not SQL text or plan XML; Step 7 retrieves those for shortlisted
hashes. Retain `session_id` and `request_id` if an in-flight plan follow-up is needed.
