# Step 5 — Memory-Grant Waits and Reduced Grants

Execute via the SQL query tool. Best used for:
- Detecting requests waiting for query-execution memory
- Detecting reduced grants that can increase hash/sort spill risk
- Live troubleshooting during high CPU / throughput degradation incidents

`required_memory_kb` is the minimum needed to start, not the full requested grant. A waiting
request normally has a NULL grant, while a running query can receive less than
`requested_memory_kb` and still meet `required_memory_kb`. Returns both cases. If no rows
return, this snapshot found no waiting or reduced grant; it cannot establish that past spills
or memory pressure did not occur.

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
    , req.blocking_session_id
    , req.open_transaction_count
    , OBJECT_NAME(st.objectid, st.dbid)                     AS object_name
    , req.query_hash
    , req.query_plan_hash
    , mg.request_time
    , mg.grant_time
    , mg.requested_memory_kb
    , mg.granted_memory_kb
    , mg.required_memory_kb
    , mg.used_memory_kb
    , mg.max_used_memory_kb
    , mg.wait_time_ms                                      AS grant_wait_time_ms
FROM sys.dm_exec_requests AS req
JOIN sys.dm_exec_sessions AS s
  ON req.session_id = s.session_id
JOIN sys.dm_exec_query_memory_grants AS mg
  ON mg.session_id = req.session_id
 AND mg.request_id = req.request_id
CROSS APPLY sys.dm_exec_sql_text(req.sql_handle) AS st
WHERE req.session_id <> @@SPID
  AND req.group_id > 1
  AND (
        mg.grant_time IS NULL
        OR mg.granted_memory_kb < mg.requested_memory_kb
      )
ORDER BY
      CASE WHEN mg.grant_time IS NULL THEN 0 ELSE 1 END
    , mg.wait_time_ms DESC
    , mg.requested_memory_kb DESC
OPTION (MAXDOP 1);
```

**Interpreting results:**
- `grant_time IS NULL` → request is currently waiting for execution memory
- `granted_memory_kb < requested_memory_kb` → reduced grant; confirm any actual Sort/Hash spill in plan XML
- `grant_wait_time_ms > 0` → time spent waiting for a memory grant
- Match grants by both `session_id` and `request_id`; one session can have multiple active requests
