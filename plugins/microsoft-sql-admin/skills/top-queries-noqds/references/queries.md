# Top Queries (Without Query Store) — SQL Queries

## Step 1: Platform Detection

> Run with the SQL query tool. Detects engine edition, validates platform support,
and checks whether Query Store is enabled.

| EngineEdition | Platform | Notes |
|---|---|---|
| 5 | Azure SQL Database | Plan cache DMVs available but scoped to the database |
| 8 | Azure SQL Managed Instance | Full plan cache DMVs available |
| 12 | Fabric SQL Database | Behaves like Azure SQL Database |
| 6 | Azure Synapse Analytics (Dedicated SQL pool) | Not supported — DMV behavior differs significantly |
| 11 | Azure Synapse serverless SQL pool / Fabric Warehouse | Not supported — DMV behavior differs significantly |
| other | SQL Server on-prem / IaaS | Full plan cache DMVs available |

```sql
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

SELECT
      CAST(SERVERPROPERTY('Edition') AS NVARCHAR(128))           AS sql_edition
    , CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(128))    AS sql_version
    , CASE @EngineEdition
        WHEN 5  THEN 'Azure SQL Database'
        WHEN 8  THEN 'Azure SQL Managed Instance'
        WHEN 12 THEN 'Fabric SQL Database'
        WHEN 6  THEN 'Azure Synapse Analytics - Dedicated SQL pool (not supported by this skill)'
        WHEN 11 THEN 'Azure Synapse serverless SQL pool / Fabric Warehouse (not supported by this skill)'
        ELSE         'SQL Server (on-prem / IaaS)'
      END                                                        AS engine_type
    , @EngineEdition                                             AS engine_edition
    , CASE WHEN @EngineEdition IN (6, 11) THEN 1 ELSE 0 END     AS is_unsupported_dw
    , CASE WHEN @EngineEdition IN (6, 11)
        THEN 'This skill is not designed for Azure Synapse Analytics or Fabric Warehouse/Lakehouse endpoints (EngineEdition 6 or 11). Plan cache DMVs and query execution patterns differ significantly in these environments. Note: Fabric SQL Database (EngineEdition 12) is supported.'
        ELSE NULL
      END                                                        AS unsupported_message
    , CASE
        WHEN OBJECT_ID('sys.database_query_store_options') IS NOT NULL
             AND EXISTS (
                 SELECT 1 FROM sys.database_query_store_options
                 WHERE actual_state_desc IN ('READ_WRITE', 'READ_ONLY')
             )
        THEN 1 ELSE 0
      END                                                        AS is_query_store_enabled
    , CASE
        WHEN OBJECT_ID('sys.database_query_store_options') IS NOT NULL
             AND EXISTS (
                 SELECT 1 FROM sys.database_query_store_options
                 WHERE actual_state_desc IN ('READ_WRITE', 'READ_ONLY')
             )
        THEN 'Query Store is enabled. Consider using query-store-volatile-historical-slow-queries-comparison or query-store-investigation for better insights.'
        ELSE 'Query Store is not enabled. These DMV-based queries provide limited history. Consider enabling Query Store: ALTER DATABASE [' + DB_NAME() + '] SET QUERY_STORE = ON (OPERATION_MODE = READ_WRITE);'
      END                                                        AS query_store_recommendation;
```

**What to do:**
| Assessment | Action |
|------------|--------|
| `is_unsupported_dw = 1` | **Stop** — this skill does not apply to Azure Synapse Analytics or Fabric Warehouse (EngineEdition 6 or 11). Fabric SQL Database (EngineEdition 12) is supported |
| `is_query_store_enabled = 1` | Query Store is active — prefer `query-store-volatile-historical-slow-queries-comparison` (Steps 1 and 7), `query-store-investigation`, or `wait-category-analysis` for richer analysis. Proceed with this skill only if DMV-based analysis is specifically needed |
| Any other edition | Proceed to Step 2 |

---

## Step 2a: Active Top CPU Consumers — Live Requests

> Run with the SQL query tool. Shows currently executing requests sorted by CPU consumption.
This captures what is running **right now** — if the expensive query already finished, it won't appear here.

```sql
DECLARE @MajorVersion INT = CAST(SERVERPROPERTY('ProductMajorVersion') AS INT);

IF @MajorVersion >= 13
BEGIN
    -- SQL Server 2016+ — dop column is available
    SELECT TOP ({{TopN}})
          req.session_id
        , req.status
        , req.start_time
        , req.cpu_time                                              AS cpu_time_ms
        , req.total_elapsed_time                                    AS elapsed_time_ms
        , req.logical_reads
        , req.reads                                                 AS physical_reads
        , req.writes
        , req.dop
        , req.wait_type
        , req.wait_time                                             AS wait_time_ms
        , req.query_hash
        , req.query_plan_hash
        , OBJECT_NAME(st.objectid, st.dbid)                         AS object_name
    FROM sys.dm_exec_requests  AS req
    JOIN sys.dm_exec_sessions  AS s
      ON req.session_id = s.session_id
    CROSS APPLY sys.dm_exec_sql_text(req.sql_handle) AS st
    WHERE req.session_id <> @@SPID
      AND s.is_user_process = 1
      AND req.group_id   >  1
    ORDER BY req.cpu_time DESC
    OPTION (MAXDOP 1);
END
ELSE
BEGIN
    -- Pre-2016 — dop column does not exist on sys.dm_exec_requests
    SELECT TOP ({{TopN}})
          req.session_id
        , req.status
        , req.start_time
        , req.cpu_time                                              AS cpu_time_ms
        , req.total_elapsed_time                                    AS elapsed_time_ms
        , req.logical_reads
        , req.reads                                                 AS physical_reads
        , req.writes
        , NULL                                                      AS dop
        , req.wait_type
        , req.wait_time                                             AS wait_time_ms
        , req.query_hash
        , req.query_plan_hash
        , OBJECT_NAME(st.objectid, st.dbid)                         AS object_name
    FROM sys.dm_exec_requests  AS req
    JOIN sys.dm_exec_sessions  AS s
      ON req.session_id = s.session_id
    CROSS APPLY sys.dm_exec_sql_text(req.sql_handle) AS st
    WHERE req.session_id <> @@SPID
      AND s.is_user_process = 1
    ORDER BY req.cpu_time DESC
    OPTION (MAXDOP 1);
END
```

**Interpreting results:**
- `cpu_time_ms` → total CPU consumed by this request so far. The primary sort metric.
- `dop > 1` → query is using parallelism (SQL Server 2016+ only; NULL on earlier versions). Check if DOP is appropriate for the workload.
- `logical_reads` → pages touched in memory. Very high values indicate scan-heavy queries.
- `physical_reads > 0` → data being read from disk, not just CPU-bound.
- `wait_type` → if set, the session is currently waiting (e.g., `CXPACKET` = parallel wait, `PAGEIOLATCH` = IO wait).
- `query_hash` → unique identifier for the query pattern. Use to correlate with Step 2b and Step 3.

**What to do:**
| Finding | Recommendation |
|---------|----------------|
| High `cpu_time_ms` + `dop = 1` | Serial execution on a CPU-heavy query — check if parallelism is being suppressed by MAXDOP or cost threshold settings |
| High `cpu_time_ms` + `dop > 4` | Excessive parallelism — review MAXDOP settings and check for parallel plan skew (one thread doing most work) |
| High `logical_reads` + high CPU | Scan-heavy query — look for missing indexes or non-sargable predicates |
| `wait_type = CXPACKET` or `CXCONSUMER` | Parallel wait — check for skewed parallelism or inappropriate DOP |
| No rows returned | No active CPU-intensive requests right now — proceed to Step 2b for historical analysis |

---

## Step 2b: Historical Top CPU Consumers — Plan Cache

> Run with the SQL query tool. Identifies the most CPU-intensive queries from the plan cache
based on cumulative `total_worker_time`. This captures queries that have already completed.

```sql
SELECT TOP ({{TopN}})
      qs.query_hash
    , COUNT(DISTINCT qs.plan_handle)                             AS plan_count
    , SUM(qs.execution_count)                                    AS execution_count
    , SUM(qs.total_worker_time) / 1000                           AS total_cpu_ms
    , SUM(qs.total_worker_time) / NULLIF(SUM(qs.execution_count), 0) / 1000 AS avg_cpu_ms_per_exec
    , SUM(qs.total_elapsed_time) / 1000                          AS total_elapsed_ms
    , SUM(qs.total_logical_reads)                                AS total_logical_reads
    , SUM(qs.total_logical_reads) / NULLIF(SUM(qs.execution_count), 0) AS logical_reads_per_exec
    , SUM(qs.total_physical_reads)                               AS total_physical_reads
    , SUM(qs.total_logical_writes)                               AS total_logical_writes
    , MAX(qs.max_worker_time) / 1000                             AS max_cpu_ms
    , MAX(qs.last_execution_time)                                AS last_execution_time
    , DB_NAME(st.dbid)                                           AS database_name
    , OBJECT_NAME(st.objectid, st.dbid)                          AS object_name
FROM sys.dm_exec_query_stats      AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS st
WHERE qs.last_execution_time   >= DATEADD(HOUR, -{{HistoryLookbackHours}}, GETDATE())
  AND st.dbid = DB_ID()
GROUP BY qs.query_hash, st.dbid, st.objectid
HAVING SUM(qs.execution_count)   >= {{MinExecutionCount}}
   AND SUM(qs.total_worker_time) >= {{MinTotalWorkerTimeUs}}
ORDER BY SUM(qs.total_worker_time) DESC
OPTION (MAXDOP 1);
```

### Drill-down: Retrieve Plans for a Specific Query Hash

> After identifying the top offenders, use this query to retrieve plan handles and execution plans
for a specific `query_hash`:

```sql
SELECT
      qs.query_hash
    , qs.query_plan_hash
    , qs.plan_handle
    , qs.execution_count
    , qs.total_worker_time / 1000                                AS total_cpu_ms
    , qs.total_worker_time / NULLIF(qs.execution_count, 0) / 1000 AS avg_cpu_ms
    , TRY_CAST(qp.query_plan AS XML)                             AS query_plan_xml
FROM sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
WHERE qs.query_hash = {{QueryHash}}
ORDER BY qs.total_worker_time DESC
OPTION (MAXDOP 1);
```

**Interpreting results:**
- `total_cpu_ms` → cumulative CPU time across all executions. The primary ranking metric.
- `avg_cpu_ms_per_exec` → average CPU per execution. High values indicate intrinsically expensive queries.
- `max_cpu_ms` >> `avg_cpu_ms_per_exec` → variable CPU cost, possibly parameter-sensitive.
- `logical_reads_per_exec` → pages touched per execution. Very high values (> 100K) suggest table/index scans.
- High `execution_count` + moderate `avg_cpu_ms_per_exec` → frequent query with aggregate CPU impact.

**What to do:**
| Finding | Recommendation |
|---------|----------------|
| High `avg_cpu_ms_per_exec` (> 1000 ms) | Intrinsically expensive query — review execution plan for scans, sorts, hash joins |
| High `execution_count` + moderate CPU per exec | Frequent execution driving aggregate CPU — consider caching, reducing call frequency, or optimizing the query |
| `max_cpu_ms` >> `avg_cpu_ms_per_exec` | Parameter sensitivity — compare plans for different parameter values; consider `OPTIMIZE FOR` or plan guides |
| High `logical_reads_per_exec` (> 100K) | Scan-heavy pattern — add covering indexes or narrow the scan with better predicates |
| High `total_logical_writes` | Write-heavy query — check for large INSERT/UPDATE/DELETE batches |
| No rows returned | Plan cache may be cold (recently cleared) or thresholds too high — lower `MinExecutionCount` or `MinTotalWorkerTimeUs` |

---

## Step 3: Queries with Multiple Execution Plans (Plan Instability)

> Run with the SQL query tool. Identifies queries that have accumulated multiple distinct
execution plans in the plan cache. Multiple plans for the same `query_hash` often indicate
parameter sniffing, statistics staleness, or SET option differences.

```sql
SELECT TOP ({{TopN}})
      qs.query_hash
    , COUNT(DISTINCT qs.plan_handle)                            AS plan_count
    , SUM(qs.execution_count)                                   AS total_executions
    , SUM(qs.total_worker_time) / 1000                          AS total_cpu_ms
    , MIN(qs.creation_time)                                     AS first_plan_created
    , MAX(qs.last_execution_time)                               AS last_executed
    , MAX(qs.total_worker_time / NULLIF(qs.execution_count, 0)) / 1000 AS worst_avg_cpu_ms
    , MIN(qs.total_worker_time / NULLIF(qs.execution_count, 0)) / 1000 AS best_avg_cpu_ms
    , MAX(CASE WHEN st.objectid IS NULL OR st.objectid = 0 THEN NULL ELSE OBJECT_NAME(st.objectid, st.dbid) END) AS object_name
FROM sys.dm_exec_query_stats      AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS st
WHERE qs.last_execution_time >= DATEADD(HOUR, -{{HistoryLookbackHours}}, GETDATE())
  AND st.dbid = DB_ID()
GROUP BY qs.query_hash
HAVING COUNT(DISTINCT qs.plan_handle) >= {{MinPlanCount}}
ORDER BY COUNT(DISTINCT qs.plan_handle) DESC, SUM(qs.total_worker_time) DESC
OPTION (MAXDOP 1);
```

**Interpreting results:**
- `plan_count > 2` → multiple plans accumulated. The higher the count, the more unstable the plan choice.
- `worst_avg_cpu_ms` vs `best_avg_cpu_ms` → large gaps indicate plan regression. One plan may be orders of magnitude worse.
- `total_executions` → impact scope. High execution count with plan instability affects more users.
- `object_name` → if it's a stored procedure, parameter sniffing is the most likely cause.

**What to do:**
| Finding | Recommendation |
|---------|----------------|
| `plan_count >= 2` with large `worst/best` gap | Parameter sniffing — compare plans for different parameter values. Check if `OPTION (RECOMPILE)` or `OPTIMIZE FOR UNKNOWN` helps |
| `plan_count >= 2` on a stored procedure | Classic parameter sniffing scenario — consider adding `WITH RECOMPILE`, plan guides, or splitting the proc by parameter patterns |
| `plan_count >= 2` with similar `worst/best` | SET option differences (e.g., `ANSI_NULLS`, `QUOTED_IDENTIFIER`) across connections — check application connection strings |
| Many queries with multiple plans | Systemic issue — check if statistics are stale (`DBCC SHOW_STATISTICS`), auto-stats is enabled, or CE model changed |
| No rows returned | No plan instability detected — if performance is still poor, focus on Step 2b results |
