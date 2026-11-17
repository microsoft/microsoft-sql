# Memory Pressure Investigation — SQL Queries

Run all queries with the SQL query tool. Replace `{{parameter}}` placeholders with values from the skill parameters.

---

## Step 1: Confirm Memory Pressure

First detect the platform, then run the appropriate query below.

### Step 1a: Detect platform

```sql
SELECT CAST(SERVERPROPERTY('EngineEdition') AS INT) AS engine_edition;
```

- **Result 6 or 11** → Azure Synapse Analytics (Dedicated or serverless SQL pool) / Fabric Warehouse → **Stop**. This skill is not designed for these platforms. Memory management differs significantly in DW environments. Note: Fabric SQL Database (EngineEdition 12) is supported.
- **Result 5 or 12** → Azure SQL DB / Fabric SQL DB → run **Step 1b (Azure)**.
- **Result 8 or any other value** → Azure SQL MI / SQL Server on-prem / IaaS → run **Step 1c (On-Prem/MI)**. Note: `sys.dm_db_resource_stats` is not available on MI; use the same server-level DMVs as on-prem.

### Step 1b: Azure SQL DB / Fabric SQL DB (EngineEdition 5, 12)

```sql
;WITH CteMemoryLast AS (
    SELECT
          MIN(end_time)                AS window_start_utc
        , MAX(end_time)                AS window_end_utc
        , AVG(avg_memory_usage_percent) AS avg_memory_percent
        , MAX(avg_memory_usage_percent) AS max_memory_percent
        , MIN(avg_memory_usage_percent) AS min_memory_percent
        , CASE
            WHEN AVG(avg_memory_usage_percent) >= {{MemoryThreshold}} THEN 'Memory pressure likely'
            ELSE 'No sustained memory pressure in last ' + CAST({{ConfirmLookbackMinutes}} AS VARCHAR) + 'm'
          END                          AS sustained_memory_assessment
    FROM sys.dm_db_resource_stats
    WHERE end_time >= DATEADD(MINUTE, -{{ConfirmLookbackMinutes}}, SYSUTCDATETIME())
)
SELECT * FROM CteMemoryLast
WHERE avg_memory_percent >= {{MemoryThreshold}}
OPTION (MAXDOP 1);
```

### Step 1c: SQL Server on-premises / IaaS / Azure SQL MI (all other EngineEditions)

```sql
SELECT
      sm.total_physical_memory_kb / 1024                    AS total_physical_memory_mb
    , sm.available_physical_memory_kb / 1024                AS available_physical_memory_mb
    , CAST(100.0 - (sm.available_physical_memory_kb * 100.0
        / NULLIF(sm.total_physical_memory_kb, 0))
      AS DECIMAL(5,2))                                      AS os_memory_used_percent
    , sm.system_memory_state_desc                           AS os_memory_state
    , pm.physical_memory_in_use_kb / 1024                   AS sql_physical_memory_in_use_mb
    , pm.locked_page_allocations_kb / 1024                  AS locked_pages_mb
    , pm.memory_utilization_percentage                      AS sql_memory_utilization_percent
    , pm.process_physical_memory_low                        AS process_physical_memory_low
    , pm.process_virtual_memory_low                         AS process_virtual_memory_low
    , CAST(c_target.cntr_value / 1024.0 AS DECIMAL(12,2))   AS target_server_memory_mb
    , CAST(c_total.cntr_value / 1024.0 AS DECIMAL(12,2))    AS total_server_memory_mb
    , CAST(100.0 * c_total.cntr_value
        / NULLIF(c_target.cntr_value, 0)
      AS DECIMAL(5,2))                                      AS memory_target_percent
    , CASE
        WHEN pm.process_physical_memory_low = 1 THEN 'OS physical memory pressure detected'
        WHEN pm.process_virtual_memory_low = 1  THEN 'Virtual memory pressure detected'
        WHEN 100.0 * c_total.cntr_value / NULLIF(c_target.cntr_value, 0) >= {{MemoryThreshold}}
            THEN 'SQL Server memory consumption near target'
        ELSE 'No strong memory pressure signals detected'
      END                                                   AS memory_pressure_assessment
FROM sys.dm_os_sys_memory AS sm
CROSS JOIN sys.dm_os_process_memory AS pm
OUTER APPLY (
    SELECT MAX(pc.cntr_value) AS cntr_value
    FROM sys.dm_os_performance_counters AS pc
    WHERE pc.object_name LIKE '%:Memory Manager%'
      AND pc.counter_name = 'Target Server Memory (KB)'
      AND ISNULL(pc.instance_name, '') = ''
) AS c_target
OUTER APPLY (
    SELECT MAX(pc.cntr_value) AS cntr_value
    FROM sys.dm_os_performance_counters AS pc
    WHERE pc.object_name LIKE '%:Memory Manager%'
      AND pc.counter_name = 'Total Server Memory (KB)'
      AND ISNULL(pc.instance_name, '') = ''
) AS c_total
OPTION (MAXDOP 1);
```

**Azure SQL result interpretation:**
- No rows returned → Memory usage not sustained above {{MemoryThreshold}}%
- Consider expanding `ConfirmLookbackMinutes` or proceeding to Steps 5–7

**SQL Server on-premises key signals:**
- `process_physical_memory_low = 1` → OS is signaling low physical memory to SQL Server
- `process_virtual_memory_low = 1` → Virtual address space pressure
- `memory_target_percent >= 90%` → SQL Server consuming most of its target allocation
- `os_memory_state` = `Available physical memory is low` → OS-level memory pressure
- `total_server_memory_mb` close to `target_server_memory_mb` → SQL Server has consumed its full allocation

---

## Step 2: Resource Semaphore Health (Grant Pool Status)

Shows the state of the memory grant pool — how much memory is available for query grants,
how much is currently granted, and whether any queries are waiting.

```sql
SELECT
      resource_semaphore_id
    , pool_id
    , total_memory_kb
    , available_memory_kb
    , granted_memory_kb
    , used_memory_kb
    , grantee_count
    , waiter_count
    , timeout_error_count
    , forced_grant_count
    , CASE
        WHEN waiter_count > 0 THEN 'CRITICAL: Queries waiting for memory grants'
        WHEN available_memory_kb < total_memory_kb * 0.1 THEN 'WARNING: Less than 10% grant memory available'
        WHEN forced_grant_count > 0 THEN 'WARNING: Forced grants detected (small query pool)'
        ELSE 'OK: Grant pool healthy'
      END AS grant_pool_status
FROM sys.dm_exec_query_resource_semaphores
OPTION (MAXDOP 1);
```

**Key signals:**
- `waiter_count > 0` → Queries are actively waiting for memory grants (`RESOURCE_SEMAPHORE` wait)
- `timeout_error_count > 0` → Grant timeouts have occurred (error 8645)
- `available_memory_kb` very low → Grant pool is nearly exhausted
- `forced_grant_count > 0` → Small-query semaphore had to force grants (mild pressure)

---

## Step 3: Active and Waiting Memory Grant Consumers

Shows sessions that currently hold or are waiting for memory grants. Sessions with
`grant_time IS NULL` are still waiting for their grant.

```sql
SELECT TOP ({{TopN}})
      mg.session_id
    , mg.request_id
    , r.status                                              AS request_status
    , r.wait_type
    , r.wait_time                                           AS wait_time_ms
    , mg.requested_memory_kb
    , mg.granted_memory_kb
    , mg.required_memory_kb
    , mg.used_memory_kb
    , mg.max_used_memory_kb
    , mg.ideal_memory_kb
    , CASE
        WHEN mg.grant_time IS NULL THEN 'WAITING for grant'
        WHEN mg.granted_memory_kb < mg.required_memory_kb THEN 'UNDER-GRANTED (spill likely)'
        WHEN mg.max_used_memory_kb < mg.granted_memory_kb * 0.2 THEN 'OVER-GRANTED (wasting memory)'
        ELSE 'Normal'
      END                                                   AS grant_assessment
    , mg.wait_time_ms                                       AS grant_wait_time_ms
    , mg.queue_id
    , mg.wait_order
    , mg.is_next_candidate
    , mg.pool_id
    , r.cpu_time                                            AS cpu_time_ms
    , r.total_elapsed_time                                  AS elapsed_time_ms
    , r.logical_reads
    , r.open_transaction_count
    , r.query_hash
    , r.query_plan_hash
FROM sys.dm_exec_query_memory_grants AS mg
LEFT JOIN sys.dm_exec_requests AS r
    ON mg.session_id = r.session_id
    AND mg.request_id = r.request_id
WHERE mg.session_id <> @@SPID
ORDER BY
    CASE WHEN mg.grant_time IS NULL THEN 0 ELSE 1 END,  -- waiters first
    mg.requested_memory_kb DESC
OPTION (MAXDOP 1);
```

**Interpreting results:**
- `grant_time IS NULL` → Session is waiting for a memory grant (`RESOURCE_SEMAPHORE` wait)
- `granted_memory_kb < required_memory_kb` → Hash/sort spill to tempdb is likely
- `max_used_memory_kb < granted_memory_kb * 0.2` → Query was over-granted; wastes memory for other queries
- `grant_wait_time_ms > 0` → Query had to wait before receiving its grant
- `wait_type = 'RESOURCE_SEMAPHORE'` → Confirms grant wait is the bottleneck

---

## Step 4: Top Memory Clerks

Identifies which internal components are consuming the most memory. The clerk type reveals
the root cause category.

```sql
SELECT TOP ({{TopN}})
      [type]                                                AS clerk_type
    , SUM(pages_kb) / 1024                                  AS total_pages_mb
    , SUM(virtual_memory_committed_kb) / 1024               AS virtual_committed_mb
    , SUM(awe_allocated_kb) / 1024                          AS awe_allocated_mb
    , CASE
        WHEN [type] = 'MEMORYCLERK_SQLBUFFERPOOL'       THEN 'Buffer Pool — data page cache'
        WHEN [type] = 'MEMORYCLERK_SQLQERESERVATIONS'   THEN 'Query Grants — sort/hash/bulk operations'
        WHEN [type] = 'OBJECTSTORE_LOCK_MANAGER'        THEN 'Lock Manager — row/page/table locks'
        WHEN [type] = 'MEMORYCLERK_SQLCLR'              THEN 'CLR — .NET assemblies in SQL Server'
        WHEN [type] = 'MEMORYCLERK_HOST'                THEN 'Host DLLs — linked servers, third-party'
        WHEN [type] = 'MEMORYCLERK_SQLOPTIMIZER'        THEN 'Query Optimizer — compilation memory'
        WHEN [type] = 'CACHESTORE_SQLCP'                THEN 'SQL Plan Cache — compiled plans'
        WHEN [type] = 'CACHESTORE_OBJCP'                THEN 'Object Plan Cache — proc/trigger plans'
        WHEN [type] = 'MEMORYCLERK_SQLLOGPOOL'          THEN 'Log Pool — transaction log buffers'
        WHEN [type] = 'MEMORYCLERK_SQLTRACE'            THEN 'SQL Trace / Extended Events'
        ELSE 'Other — see SQL Server memory clerk documentation'
      END                                                   AS clerk_description
FROM sys.dm_os_memory_clerks
WHERE memory_node_id <> 64   -- exclude Dedicated Admin Connection (DAC) node
GROUP BY [type]
HAVING SUM(pages_kb) > 1024  -- at least 1 MB
ORDER BY SUM(pages_kb) DESC
OPTION (MAXDOP 1);
```

**Key clerk types and their meaning:**
| Clerk Type | Normal Dominant? | What it means when high |
|-----------|:---:|-------------|
| `MEMORYCLERK_SQLBUFFERPOOL` | Yes | Buffer pool is the largest consumer by design. Only concerning if paired with low available memory, high IO waits, or low PLE |
| `MEMORYCLERK_SQLQERESERVATIONS` | No | Large or numerous memory grants — investigate top grant consumers in Steps 3, 6, 7 |
| `OBJECTSTORE_LOCK_MANAGER` | No | Many row-level locks held — check for long transactions, escalation settings |
| `MEMORYCLERK_SQLCLR` | No | CLR objects consuming significant memory — review CLR assemblies |
| `MEMORYCLERK_HOST` | No | Third-party DLLs, linked servers, or external components inside SQL process |
| `CACHESTORE_SQLCP` | No | Plan cache bloat — check for non-parameterized ad-hoc queries |
| `MEMORYCLERK_SQLOPTIMIZER` | No | Excessive compilation memory — check for frequent recompilations |

---

## Step 5: Recent Out-of-Memory Events

> **Engine Edition safeguard:** This DMV is available **only** on Azure SQL Database, SQL Managed Instance,
> and Fabric SQL Database (EngineEdition IN (5, 8, 12)). On SQL Server on-premises / IaaS, the query
> returns an informational message instead.

```sql
IF SERVERPROPERTY('EngineEdition') IN (5, 8, 12)   -- Azure SQL DB, SQL MI, or Fabric SQL DB
BEGIN
    SELECT TOP ({{TopN}})
          event_time
        , oom_cause
        , oom_cause_desc
        , available_physical_memory_mb
        , process_memory_usage_mb
        , non_sos_memory_usage_mb
        , committed_memory_target_mb
        , committed_memory_mb
        , allocation_potential_memory_mb
        , oom_factor_desc
        , top_memory_clerks
        , top_resource_pools
        , oom_resource_pools
        , possible_leaked_memory_clerks
        , possible_non_sos_leaked_memory_mb
    FROM sys.dm_os_out_of_memory_events
    WHERE event_time >= DATEADD(HOUR, -{{HistoryLookbackHours}}, SYSUTCDATETIME())
    ORDER BY event_time DESC
    OPTION (MAXDOP 1);
END
ELSE
BEGIN
    SELECT 'sys.dm_os_out_of_memory_events is not available on SQL Server on-premises / IaaS. Use Steps 2-4 for live memory pressure signals.' AS unsupported_message;
END
```

**If no rows returned:** No OOM events were recorded in the last {{HistoryLookbackHours}} hours.
This does not rule out memory pressure — queries may be waiting on grants without triggering OOM.

**If rows returned:** OOM events indicate critical memory pressure. Check:
- `oom_cause_desc` to identify root cause category:
  - `QUERY_MEMORY_GRANTS` → Large grants held by queries (most common actionable cause)
  - `MEMORY_LOW` → General insufficient memory
  - `HEKATON_POOL_MEMORY_LOW` → In-Memory OLTP memory exhaustion
  - `SLOW_BUFFER_POOL_SHRINK` → Buffer pool not releasing memory fast enough
  - `MEMORY_LEAK` / `NON_SOS_MEMORY_LEAK` → Possible memory leak
- `top_memory_clerks` (JSON) → Expand to see which clerks consumed the most memory at OOM time
- `top_resource_pools` (JSON) → Identify which resource pool ran out of memory
- `possible_leaked_memory_clerks` (JSON) → If non-null, possible memory leak detected
- Frequency: multiple OOM events in a short window indicates sustained critical pressure
- Consider scaling up (Azure SLO increase) or tuning the top memory consumers

---

## Step 6: Historical Top Memory Grant Consumers (Plan Cache)

Aggregates **cumulative** memory grant statistics from the plan cache. Identifies queries that
historically request the largest memory grants. Version-gated for SQL 2017+ columns.

```sql
DECLARE @ProductVersion NVARCHAR(128) = CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(128));
DECLARE @MajorVersion INT = CAST(PARSENAME(@ProductVersion, 4) AS INT);

IF @MajorVersion >= 14 OR SERVERPROPERTY('EngineEdition') IN (5, 8, 12)
BEGIN
    -- SQL 2017+ / Azure SQL: grant_kb, used_grant_kb, ideal_grant_kb, spills available
    EXEC sp_executesql N'
    SELECT TOP ({{TopN}})
          qs.query_hash
        , qs.query_plan_hash
        , qs.execution_count
        , CONVERT(DECIMAL(10,2), qs.max_grant_kb / 1024.0)     AS max_grant_mb
        , CONVERT(DECIMAL(10,2), qs.min_grant_kb / 1024.0)     AS min_grant_mb
        , CONVERT(DECIMAL(10,2),
            (qs.total_grant_kb / NULLIF(qs.execution_count, 0))
            / 1024.0)                                           AS avg_grant_mb
        , CONVERT(DECIMAL(10,2), qs.max_used_grant_kb / 1024.0) AS max_used_grant_mb
        , CONVERT(DECIMAL(10,2), qs.min_used_grant_kb / 1024.0) AS min_used_grant_mb
        , CONVERT(DECIMAL(10,2),
            (qs.total_used_grant_kb / NULLIF(qs.execution_count, 0))
            / 1024.0)                                           AS avg_used_grant_mb
        , CONVERT(DECIMAL(10,2),
            (qs.total_ideal_grant_kb / NULLIF(qs.execution_count, 0))
            / 1024.0)                                           AS avg_ideal_grant_mb
        , CASE
            WHEN qs.max_used_grant_kb < qs.max_grant_kb * 0.2
                THEN ''OVER-GRANTED: using < 20% of granted memory''
            WHEN qs.total_spills > 0
                THEN ''UNDER-GRANTED: spills detected''
            ELSE ''Normal''
          END                                                   AS grant_efficiency
        , qs.total_spills
        , qs.max_spills
        , qs.total_worker_time / 1000                           AS total_cpu_time_ms
        , qs.total_logical_reads
        , qs.last_execution_time
    FROM sys.dm_exec_query_stats AS qs
    WHERE qs.max_grant_kb > {{MinGrantKB}}
      AND qs.last_execution_time >= DATEADD(HOUR, -{{HistoryLookbackHours}}, SYSDATETIME())
    ORDER BY qs.max_grant_kb DESC
    OPTION (MAXDOP 1);';
END
ELSE
BEGIN
    -- SQL 2016 and earlier: grant_kb columns not available, use total_worker_time as proxy
    SELECT TOP ({{TopN}})
          qs.query_hash
        , qs.query_plan_hash
        , qs.execution_count
        , qs.total_worker_time / 1000                           AS total_cpu_time_ms
        , qs.total_logical_reads
        , qs.last_execution_time
        , 'Upgrade to SQL 2017+ for memory grant columns (max_grant_kb, total_spills, etc.)' AS version_note
    FROM sys.dm_exec_query_stats AS qs
    WHERE qs.last_execution_time >= DATEADD(HOUR, -{{HistoryLookbackHours}}, SYSDATETIME())
    ORDER BY qs.total_worker_time DESC
    OPTION (MAXDOP 1);
END
```

**Interpreting results:**
- `max_used_grant_mb` much smaller than `max_grant_mb` → Query is over-requesting memory. Consider
  adding `OPTION (MAX_GRANT_PERCENT = N)` to limit the grant, or update statistics so the optimizer
  produces better cardinality estimates.
- `total_spills > 0` → Query was under-granted and spilled to tempdb. Consider updating statistics,
  adding appropriate indexes, or using `OPTION (MIN_GRANT_PERCENT = N)` to ensure a minimum grant.
- High `execution_count` with large grants → Cumulative memory pressure from a frequently-executed query.

**Note:** The full query (with `total_spills`, `max_spills`, `total_grant_kb`, `total_used_grant_kb`, `total_ideal_grant_kb`)
runs automatically on SQL Server 2017+ and Azure SQL. On older versions, a fallback query returns
CPU and logical reads only — upgrade to SQL 2017+ for memory grant columns.

---

## Step 7: Historical Top Memory Grant Consumers (Query Store)

Requires Query Store to be enabled on the target database. The query includes a preflight check —
if Query Store is disabled or in an error state, it returns an explicit message instead of empty results.

### Version: By Query Hash

Aggregates by `query_hash` for pattern-level analysis across all plans of the same query shape.

```sql
IF OBJECT_ID('sys.database_query_store_options') IS NOT NULL
   AND EXISTS (
       SELECT 1 FROM sys.database_query_store_options
       WHERE actual_state_desc IN ('READ_WRITE', 'READ_ONLY')
   )
BEGIN
    SELECT TOP ({{TopN}})
          q.query_hash
        , COUNT(DISTINCT p.plan_id)                             AS plan_count
        , SUM(rs.count_executions)                              AS total_executions
        , CONVERT(DECIMAL(10,2),
            AVG(rs.avg_query_max_used_memory) * 8.0 / 1024.0)  AS avg_max_used_memory_mb
        , CONVERT(DECIMAL(10,2),
            MAX(rs.max_query_max_used_memory) * 8.0 / 1024.0)  AS max_used_memory_mb
        , CONVERT(DECIMAL(10,2),
            MIN(rs.min_query_max_used_memory) * 8.0 / 1024.0)  AS min_used_memory_mb
        , CONVERT(DECIMAL(10,2),
            AVG(rs.avg_cpu_time) / 1000.0)                      AS avg_cpu_time_ms
        , CONVERT(DECIMAL(10,2),
            AVG(rs.avg_logical_io_reads) * 8.0 / 1024.0)       AS avg_logical_reads_mb
        , MAX(i.end_time)                                       AS last_interval_end
    FROM sys.query_store_runtime_stats AS rs
    JOIN sys.query_store_runtime_stats_interval AS i
        ON rs.runtime_stats_interval_id = i.runtime_stats_interval_id
    JOIN sys.query_store_plan AS p
        ON rs.plan_id = p.plan_id
    JOIN sys.query_store_query AS q
        ON p.query_id = q.query_id
    WHERE i.end_time >= DATEADD(HOUR, -{{HistoryLookbackHours}}, SYSUTCDATETIME())
    GROUP BY q.query_hash
    HAVING AVG(rs.avg_query_max_used_memory) * 8.0 / 1024.0 > 5  -- > 5 MB average
    ORDER BY AVG(rs.avg_query_max_used_memory) DESC
    OPTION (MAXDOP 1, MAX_GRANT_PERCENT = 5);
END
ELSE
BEGIN
    SELECT
        'Query Store is not enabled or not in a readable state on this database. '
      + 'Skip this step and rely on Step 6 (plan cache) for historical memory grant analysis. '
      + 'To enable Query Store: ALTER DATABASE [' + DB_NAME() + '] SET QUERY_STORE = ON (OPERATION_MODE = READ_WRITE);'
        AS query_store_status;
END
```

### Version: By Query ID and Plan ID

Returns individual query/plan combinations for drilling into specific plan variations.

```sql
IF OBJECT_ID('sys.database_query_store_options') IS NOT NULL
   AND EXISTS (
       SELECT 1 FROM sys.database_query_store_options
       WHERE actual_state_desc IN ('READ_WRITE', 'READ_ONLY')
   )
BEGIN
    SELECT TOP ({{TopN}})
          q.query_id
        , p.plan_id
        , q.query_hash
        , p.query_plan_hash
        , SUM(rs.count_executions)                              AS total_executions
        , CONVERT(DECIMAL(10,2),
            AVG(rs.avg_query_max_used_memory) * 8.0 / 1024.0)  AS avg_max_used_memory_mb
        , CONVERT(DECIMAL(10,2),
            MAX(rs.max_query_max_used_memory) * 8.0 / 1024.0)  AS max_used_memory_mb
        , CONVERT(DECIMAL(10,2),
            MIN(rs.min_query_max_used_memory) * 8.0 / 1024.0)  AS min_used_memory_mb
        , CONVERT(DECIMAL(10,2),
            AVG(rs.avg_cpu_time) / 1000.0)                      AS avg_cpu_time_ms
        , CONVERT(DECIMAL(10,2),
            AVG(rs.avg_logical_io_reads) * 8.0 / 1024.0)       AS avg_logical_reads_mb
        , MAX(i.end_time)                                       AS last_interval_end
        , p.is_forced_plan
    FROM sys.query_store_runtime_stats AS rs
    JOIN sys.query_store_runtime_stats_interval AS i
        ON rs.runtime_stats_interval_id = i.runtime_stats_interval_id
    JOIN sys.query_store_plan AS p
        ON rs.plan_id = p.plan_id
    JOIN sys.query_store_query AS q
        ON p.query_id = q.query_id
    WHERE i.end_time >= DATEADD(HOUR, -{{HistoryLookbackHours}}, SYSUTCDATETIME())
    GROUP BY q.query_id, p.plan_id, q.query_hash, p.query_plan_hash, p.is_forced_plan
    HAVING AVG(rs.avg_query_max_used_memory) * 8.0 / 1024.0 > 5  -- > 5 MB average
    ORDER BY AVG(rs.avg_query_max_used_memory) DESC
    OPTION (MAXDOP 1, MAX_GRANT_PERCENT = 5);
END
ELSE
BEGIN
    SELECT
        'Query Store is not enabled or not in a readable state on this database. '
      + 'Skip this step and rely on Step 6 (plan cache) for historical memory grant analysis. '
      + 'To enable Query Store: ALTER DATABASE [' + DB_NAME() + '] SET QUERY_STORE = ON (OPERATION_MODE = READ_WRITE);'
        AS query_store_status;
END
```

**Interpreting results:**
- High `avg_max_used_memory_mb` with high `total_executions` → Major cumulative memory consumer
- `plan_count > 1` (hash version) → Multiple plans for the same query shape — check for parameter
  sniffing causing different grant sizes across plans
- `is_forced_plan = 1` (ID version) → A plan is being forced — verify it has an appropriate memory grant
- Compare with Step 6 plan-cache results to cross-validate top consumers
