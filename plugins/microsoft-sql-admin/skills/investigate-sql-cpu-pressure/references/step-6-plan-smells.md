# Step 6 — Plan Smell Detection

Execute via the SQL query tool. Inspects the live or estimated execution plan XML for known
query anti-patterns (**plan smells**) that commonly cause CPU pressure or excessive waits.
Returns only sessions where at least one smell is detected.

Use when:
- CPU pressure is confirmed but the root cause is unclear
- A specific query is slow and you want to identify actionable plan warnings without opening a graphical plan viewer
- You suspect implicit conversions, key lookups, or scalar UDFs are amplifying CPU cost

```sql
;WITH Req AS
(
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
        , req.sql_handle
        , req.plan_handle
        , req.statement_start_offset
        , req.statement_end_offset
        , OBJECT_NAME(st.objectid, st.dbid)                     AS object_name
        , st.dbid
        , st.objectid
        , req.query_hash
        , req.query_plan_hash

        , CASE 
            WHEN qp.query_plan.exist(
                'declare default element namespace "http://schemas.microsoft.com/sqlserver/2004/07/showplan";
                 //PlanAffectingConvert'
              ) = 1 THEN 1 ELSE 0
          END                                                   AS has_implicit_conversion

        , CASE 
            WHEN qp.query_plan.exist(
                'declare default element namespace "http://schemas.microsoft.com/sqlserver/2004/07/showplan";
                 //SpillToTempDb'
              ) = 1 THEN 1 ELSE 0
          END                                                   AS has_spill_to_tempdb

        , CASE 
            WHEN qp.query_plan.exist(
                'declare default element namespace "http://schemas.microsoft.com/sqlserver/2004/07/showplan";
                 //MissingIndexGroup'
              ) = 1 THEN 1 ELSE 0
          END                                                   AS has_missing_index_suggestion_in_plan

        , CASE 
            WHEN qp.query_plan.exist(
                'declare default element namespace "http://schemas.microsoft.com/sqlserver/2004/07/showplan";
                 //IndexScan[@Lookup="1"]'
              ) = 1 THEN 1 ELSE 0
          END                                                   AS has_key_lookup_in_plan

        , CASE 
            WHEN qp.query_plan.exist(
                'declare default element namespace "http://schemas.microsoft.com/sqlserver/2004/07/showplan";
                 //UserDefinedFunction'
              ) = 1 THEN 1 ELSE 0
          END                                                   AS has_scalar_udf_in_plan

    FROM sys.dm_exec_requests  AS req
    JOIN sys.dm_exec_sessions  AS s
      ON req.session_id = s.session_id
    CROSS APPLY sys.dm_exec_sql_text(req.sql_handle) AS st
    OUTER APPLY sys.dm_exec_query_plan(req.plan_handle) AS qp
    WHERE req.session_id <> @@SPID
      AND req.group_id   >  1
      AND req.cpu_time   > {{CpuThresholdMs}}
    ORDER BY req.cpu_time DESC
)
, FinalQuery AS
(
    SELECT
          r.session_id
        , r.request_id
        , r.status
        , r.start_time
        , r.cpu_time_ms
        , r.elapsed_time_ms
        , r.wait_type
        , r.wait_time_ms
        , r.blocking_session_id
        , r.open_transaction_count
        , r.object_name
        , r.query_hash
        , r.query_plan_hash
        , r.has_implicit_conversion
        , r.has_spill_to_tempdb
        , r.has_missing_index_suggestion_in_plan
        , r.has_key_lookup_in_plan
        , r.has_scalar_udf_in_plan
    FROM Req r
)
SELECT *
FROM FinalQuery
WHERE has_implicit_conversion              = 1
   OR has_spill_to_tempdb                  = 1
   OR has_missing_index_suggestion_in_plan = 1
   OR has_key_lookup_in_plan               = 1
   OR has_scalar_udf_in_plan               = 1
ORDER BY cpu_time_ms DESC
OPTION (MAXDOP 1);
```

Use the smell-to-fix mapping in `references/plan-smell-reference.md` to translate each flagged
column into a concrete recommendation. A parallel plan is not a smell by itself; diagnose skew
only from per-thread runtime evidence.
