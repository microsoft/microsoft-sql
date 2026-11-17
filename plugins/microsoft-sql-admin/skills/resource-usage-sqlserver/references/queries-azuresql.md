# Resource Usage — Azure SQL Database / Fabric SQL Database Queries

All queries target **Azure SQL Database (Engine Edition 5)** and **Fabric SQL Database (Engine Edition 12)**.
Execute each query with the SQL query tool. Replace `{{parameter}}` placeholders with values from the skill parameters.

> **Platform differences**: Azure SQL DB (Edition 5) exposes meaningful values for `avg_instance_cpu_percent` and `avg_instance_memory_percent`; Fabric SQL DB (Edition 12) has these columns but they return NULL. Steps 1 and 3 branch by edition to avoid misleading classifications; Step 4 returns all columns (NULLs are expected on Fabric).

---

### Step 0: Detect Platform

> Determines the SQL Server engine edition. If the result shows an unsupported platform, stop the skill.

```sql
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

SELECT
      CAST(SERVERPROPERTY('Edition') AS NVARCHAR(128))           AS sql_edition
    , CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(128))    AS sql_version
    , CASE @EngineEdition
        WHEN 1  THEN 'Personal / Desktop Engine'
        WHEN 2  THEN 'Standard'
        WHEN 3  THEN 'Enterprise'
        WHEN 4  THEN 'Express'
        WHEN 5  THEN 'Azure SQL Database'
        WHEN 6  THEN 'Azure Synapse Analytics (Dedicated SQL Pool)'
        WHEN 8  THEN 'Azure SQL Managed Instance'
        WHEN 9  THEN 'Azure SQL Edge'
        WHEN 11 THEN 'Azure Synapse Serverless SQL Pool / Microsoft Fabric (non-SQL DB)'
        WHEN 12 THEN 'Fabric SQL Database'
        ELSE         'SQL Server (on-prem / IaaS)'
      END                                                        AS engine_type
    , @EngineEdition                                             AS engine_edition
    , CASE WHEN @EngineEdition IN (6, 9, 11) THEN 1 ELSE 0 END  AS is_unsupported_platform;
```

**What to do:**

| Finding | Action |
|---------|--------|
| `engine_edition = 5` — Azure SQL Database | Continue with this file. |
| `engine_edition = 12` — Fabric SQL Database | Continue with this file. |
| `engine_edition IN (1,2,3,4,8)` — SQL Server / MI | **Switch to `references/queries-sqlserver.md`** — these platforms use ring buffers and OS-level DMVs. |
| `is_unsupported_platform = 1` (edition 6, 9, 11) | **Stop** — report unsupported platform. |

---

### Step 1: CPU Utilization

> Sources CPU history from `sys.dm_db_resource_stats`, which retains ~1 hour at 15-second intervals (~240 rows).
> - **Azure SQL DB (Edition 5)**: Exposes both `avg_cpu_percent` (DB workload) and `avg_instance_cpu_percent` (total instance CPU including system workloads).
> - **Fabric SQL DB (Edition 12)**: Only `avg_cpu_percent` is available.

```sql
SET NOCOUNT ON;
DECLARE @CPUHighThreshold INT = {{CPUHighThreshold}};
DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));

IF @EngineEdition = 12
BEGIN
    -- Fabric SQL Database: avg_instance_cpu_percent not available
    SELECT
        'Fabric SQL Database' AS Platform,
        end_time AS EventTime,
        avg_cpu_percent AS cpu_percent,
        CASE
            WHEN avg_cpu_percent > @CPUHighThreshold
                THEN 'HIGH CPU USAGE'
            ELSE 'NORMAL CPU USAGE'
        END AS CPU_Classification,
        'cpu_percent = DB workload CPU consumption' AS CPU_Interpretation
    FROM sys.dm_db_resource_stats
    ORDER BY end_time DESC;
    RETURN;
END

-- Azure SQL Database (Edition 5)
SELECT
    'Azure SQL Database' AS Platform,
    end_time AS EventTime,
    avg_cpu_percent AS cpu_percent,
    avg_instance_cpu_percent AS sql_instance_cpu_percent,
    CASE
        WHEN avg_instance_cpu_percent > @CPUHighThreshold AND avg_cpu_percent > @CPUHighThreshold
            THEN 'HIGH CPU: Overall instance and DB both under pressure'
        WHEN avg_cpu_percent > @CPUHighThreshold AND avg_instance_cpu_percent <= @CPUHighThreshold
            THEN 'DB-SPECIFIC CPU ISSUE (Your workload is heavy)'
        WHEN avg_instance_cpu_percent > @CPUHighThreshold
            THEN 'INSTANCE CPU HIGH (Other DBs / system workloads consuming CPU)'
        ELSE 'NORMAL CPU USAGE'
    END AS CPU_Classification,
    'cpu_percent = DB workload CPU consumption; sql_instance_cpu_percent = total CPU across user + system workloads'
    AS CPU_Interpretation
FROM sys.dm_db_resource_stats
ORDER BY end_time DESC;
```

---

### Step 2: Workload Metrics (Past Hour)

> Provides a broader view of resource consumption including worker and session utilization over the past hour.

```sql
SET NOCOUNT ON;

SELECT TOP 60
    end_time AS [Event Time],
    avg_cpu_percent AS [CPU %],
    avg_data_io_percent AS [Data IO %],
    avg_log_write_percent AS [Log Write %],
    max_worker_percent AS [Max Worker %],
    max_session_percent AS [Max Session %]
FROM sys.dm_db_resource_stats
ORDER BY end_time DESC;
```

---

### Step 3: Memory Pressure

> Uses `sys.dm_db_resource_stats` to detect memory pressure.
> - **Azure SQL DB (Edition 5)**: Exposes both `avg_memory_usage_percent` and `avg_instance_memory_percent`.
> - **Fabric SQL DB (Edition 12)**: Only `avg_memory_usage_percent` is available.

```sql
SET NOCOUNT ON;
DECLARE @MemoryHighThreshold INT = {{MemoryHighThreshold}};
DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));

IF @EngineEdition = 12
BEGIN
    -- Fabric SQL Database: avg_instance_memory_percent not available
    SELECT
        'Fabric SQL Database' AS Platform,
        end_time AS EventTime,
        avg_memory_usage_percent,
        CASE
            WHEN avg_memory_usage_percent > @MemoryHighThreshold
                THEN 'HIGH MEMORY USAGE (DB nearing limit)'
            WHEN avg_memory_usage_percent BETWEEN (@MemoryHighThreshold - 20) AND @MemoryHighThreshold
                THEN 'MODERATE MEMORY PRESSURE'
            ELSE 'MEMORY HEALTHY'
        END AS Memory_Classification,
        'avg_memory_usage_percent = DB memory usage vs tier limit' AS Memory_Interpretation
    FROM sys.dm_db_resource_stats
    ORDER BY end_time DESC;
    RETURN;
END

-- Azure SQL Database (Edition 5)
SELECT
    'Azure SQL Database' AS Platform,
    end_time AS EventTime,
    avg_memory_usage_percent,
    avg_instance_memory_percent,
    CASE
        WHEN avg_memory_usage_percent > @MemoryHighThreshold
            THEN 'HIGH MEMORY USAGE (DB nearing limit)'
        WHEN avg_instance_memory_percent > @MemoryHighThreshold
            THEN 'INSTANCE MEMORY HIGH (other DBs / system load)'
        WHEN avg_memory_usage_percent BETWEEN (@MemoryHighThreshold - 20) AND @MemoryHighThreshold
            THEN 'MODERATE MEMORY PRESSURE'
        ELSE 'MEMORY HEALTHY'
    END AS Memory_Classification,
    'avg_memory_usage_percent = DB memory usage vs tier limit; avg_instance_memory_percent = total memory usage at instance level'
    AS Memory_Interpretation
FROM sys.dm_db_resource_stats
ORDER BY end_time DESC;
```

---

### Step 4: Full Resource Usage Metrics

> Returns all available resource metrics from `sys.dm_db_resource_stats` for detailed analysis.

```sql
SET NOCOUNT ON;

SELECT TOP 60
    end_time AS [End Time],
    avg_cpu_percent,
    avg_data_io_percent,
    avg_log_write_percent,
    avg_memory_usage_percent,
    xtp_storage_percent,
    max_worker_percent,
    max_session_percent,
    avg_login_rate_percent,
    avg_instance_cpu_percent,
    avg_instance_memory_percent
FROM sys.dm_db_resource_stats
ORDER BY end_time DESC;
```

> ⚠️ On Fabric SQL Database (Edition 12), `avg_instance_cpu_percent` and `avg_instance_memory_percent` exist but return NULL. This is expected — these metrics are only meaningful on Azure SQL Database (Edition 5).

---

### Step 5: Memory Usage per Clerk

> Shows the top memory-consuming memory clerks by total allocation.

```sql
SET NOCOUNT ON;
DECLARE @TopNClerks INT = {{TopNClerks}};
DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));

DECLARE @Platform NVARCHAR(40) =
    CASE @EngineEdition
        WHEN 5 THEN 'Azure SQL Database'
        WHEN 12 THEN 'Fabric SQL Database'
        ELSE 'Unknown'
    END;

IF OBJECT_ID('tempdb..#TopClerks') IS NOT NULL DROP TABLE #TopClerks;
CREATE TABLE #TopClerks
(
    ClerkType NVARCHAR(60) NOT NULL PRIMARY KEY,
    TotalKB   BIGINT       NOT NULL,
    TotalMB   DECIMAL(19,2) NOT NULL,
    PctTotal  DECIMAL(9,2)  NOT NULL
);

DECLARE @TotalAllKB BIGINT;
SELECT
    @TotalAllKB =
        SUM(CONVERT(BIGINT,
              pages_kb
            + virtual_memory_committed_kb
            + awe_allocated_kb
            + shared_memory_committed_kb))
FROM sys.dm_os_memory_clerks;

;WITH ClerkRollup AS
(
    SELECT
        [type] AS ClerkType,
        TotalKB =
            SUM(CONVERT(BIGINT,
                  pages_kb
                + virtual_memory_committed_kb
                + awe_allocated_kb
                + shared_memory_committed_kb))
    FROM sys.dm_os_memory_clerks
    GROUP BY [type]
)
INSERT #TopClerks (ClerkType, TotalKB, TotalMB, PctTotal)
SELECT TOP (@TopNClerks)
    ClerkType,
    TotalKB,
    CONVERT(DECIMAL(19,2), TotalKB / 1024.0),
    CONVERT(DECIMAL(9,2), CASE WHEN @TotalAllKB > 0 THEN (100.0 * TotalKB) / @TotalAllKB ELSE 0 END)
FROM ClerkRollup
ORDER BY TotalKB DESC;

SELECT
    CaptureTime = GETDATE(),
    Platform = @Platform,
    ClerkType,
    TotalKB,
    TotalMB,
    PctTotal
FROM #TopClerks
ORDER BY TotalKB DESC;
```

---

### Step 6: Plan Cache Bloat

> Identifies plan cache bloat — single-use plans that waste memory.

```sql
SET NOCOUNT ON;

SELECT
    objtype AS [CacheType],
    COUNT_BIG(*) AS [Total Plans],
    SUM(CAST(size_in_bytes AS DECIMAL(18,2)))/1024/1024 AS [Total MBs],
    AVG(usecounts) AS [Avg Use Count],
    SUM(CASE WHEN usecounts = 1 THEN 1 ELSE 0 END) AS [Plans Used Once],
    SUM(CASE WHEN usecounts = 1 THEN CAST(size_in_bytes AS DECIMAL(18,2)) ELSE 0 END)/1024/1024 AS [MBs Used Once]
FROM sys.dm_exec_cached_plans
GROUP BY objtype
ORDER BY [Total MBs] DESC;
```

---

### Step 7: TempDB Contention

> Detects active TempDB latch waits on PFS/GAM/SGAM pages.
> ⚠️ On Azure SQL DB / Fabric, `sys.dm_os_waiting_tasks` is database-scoped and TempDB latch waits may not be visible (they originate in database_id 2).

```sql
SET NOCOUNT ON;
DECLARE @TempDBWaitThresholdMs INT = {{TempDBWaitThresholdMs}};
DECLARE @TempDBHighSeverityMs INT = {{TempDBHighSeverityMs}};
DECLARE @MaxResults INT = {{MaxResults}};
DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));

DECLARE @PlatformCaveat NVARCHAR(200) =
    'NOTE: TempDB latch waits may not be visible on Azure SQL DB / Fabric (DMV is database-scoped).';

;WITH Base AS
(
    SELECT TOP (100)
        wt.session_id,
        wt.wait_type,
        wt.wait_duration_ms,
        wt.resource_description,
        er.status,
        er.command,
        rd = wt.resource_description
    FROM sys.dm_os_waiting_tasks wt
    LEFT JOIN sys.dm_exec_requests er
        ON er.session_id = wt.session_id
    WHERE wt.wait_type LIKE 'PAGELATCH%'
      AND wt.wait_duration_ms > @TempDBWaitThresholdMs
      AND wt.resource_description LIKE '%:%:%'
    ORDER BY wt.wait_duration_ms DESC
),
Parsed AS
(
    SELECT
        b.*,
        database_id =
            TRY_CONVERT(INT, LEFT(rd, CHARINDEX(':', rd) - 1)),
        file_id =
            TRY_CONVERT(INT,
                SUBSTRING(
                    rd,
                    CHARINDEX(':', rd) + 1,
                    CHARINDEX(':', rd, CHARINDEX(':', rd) + 1) - CHARINDEX(':', rd) - 1
                )
            ),
        page_id =
            TRY_CONVERT(BIGINT,
                RIGHT(rd, LEN(rd) - CHARINDEX(':', rd, CHARINDEX(':', rd) + 1))
            )
    FROM Base b
),
Final AS
(
    SELECT
        p.*,
        IsTempDB = CASE WHEN p.database_id = 2 THEN 1 ELSE 0 END,
        PageType =
            CASE
                WHEN p.database_id = 2 AND (p.page_id = 1 OR (p.page_id > 0 AND p.page_id % 8088 = 0)) THEN 'PFS'
                WHEN p.database_id = 2 AND (p.page_id = 2 OR (p.page_id > 0 AND p.page_id % 511232 = 0)) THEN 'GAM'
                WHEN p.database_id = 2 AND (p.page_id = 3 OR (p.page_id > 0 AND (p.page_id - 1) % 511232 = 0)) THEN 'SGAM'
                ELSE 'OTHER'
            END
    FROM Parsed p
)
SELECT TOP (@MaxResults)
    GETDATE() AS CaptureTime,
    CASE @EngineEdition WHEN 5 THEN 'Azure SQL Database' WHEN 12 THEN 'Fabric SQL Database' END AS Platform,
    @PlatformCaveat AS PlatformCaveat,
    session_id,
    wait_type,
    wait_duration_ms,
    resource_description,
    database_id,
    file_id,
    page_id,
    CASE WHEN IsTempDB = 1 THEN 'TEMPDB CONTENTION'
         ELSE 'NON-TEMPDB CONTENTION'
    END AS ContentionScope,
    PageType,
    COUNT(*) OVER (PARTITION BY database_id, file_id, page_id) AS WaitersOnSamePage,
    CASE
        WHEN IsTempDB = 1 AND wait_duration_ms > @TempDBHighSeverityMs THEN 'HIGH'
        WHEN IsTempDB = 1 THEN 'MODERATE'
        ELSE 'LOW'
    END AS ContentionSeverity,
    CASE
        WHEN PageType IN ('PFS','GAM','SGAM')
            THEN 'Tempdb allocation contention (temp objects / spills / high concurrency)'
        ELSE 'General latch contention'
    END AS LikelyCause,
    status,
    command
FROM Final
ORDER BY wait_duration_ms DESC;
```

---

### Step 8: Threadpool Health

> Checks for thread pool starvation, worker queue buildup, and runnable task pressure.

```sql
SET NOCOUNT ON;
DECLARE @RunnableTasksWarning INT = {{RunnableTasksWarning}};
DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));

DECLARE @Platform VARCHAR(50) =
    CASE @EngineEdition
        WHEN 5 THEN 'Azure SQL Database'
        WHEN 12 THEN 'Fabric SQL Database'
        ELSE 'Unknown'
    END;

;WITH SchedulerAgg AS
(
    SELECT
        SUM(runnable_tasks_count) AS TotalRunnableTasks,
        SUM(work_queue_count)     AS TotalQueuedTasks
    FROM sys.dm_os_schedulers
    WHERE status = 'VISIBLE ONLINE'
      AND scheduler_id < 255
),
ThreadPool AS
(
    SELECT
        COUNT(*) AS ActiveThreadPoolWaits
    FROM sys.dm_os_waiting_tasks
    WHERE wait_type = 'THREADPOOL'
)
SELECT
    GETDATE() AS CaptureTime,
    @Platform AS Platform,
    s.TotalRunnableTasks,
    s.TotalQueuedTasks,
    t.ActiveThreadPoolWaits,
    CASE
        WHEN t.ActiveThreadPoolWaits > 0
            THEN 'CRITICAL: THREAD POOL STARVATION'
        WHEN s.TotalQueuedTasks > 0
            THEN 'HIGH RISK: WORKER QUEUE BUILDUP'
        WHEN s.TotalRunnableTasks > @RunnableTasksWarning
            THEN 'WARNING: THREAD PRESSURE'
        WHEN s.TotalRunnableTasks > 0
            THEN 'INFO: MINOR THREAD ACTIVITY'
        ELSE 'HEALTHY'
    END AS ThreadHealth,
    CASE
        WHEN t.ActiveThreadPoolWaits > 0
            THEN 'Check blocking, parallel queries, long-running CPU tasks'
        WHEN s.TotalQueuedTasks > 0
            THEN 'Worker shortage due to concurrency spikes'
        WHEN s.TotalRunnableTasks > @RunnableTasksWarning
            THEN 'CPU pressure / scheduler contention'
        ELSE 'No issue detected'
    END AS LikelyCause,
    CASE
        WHEN @EngineEdition = 5
            THEN 'Azure SQL DB: Worker limits governed by service tier'
        WHEN @EngineEdition = 12
            THEN 'Fabric SQL DB: Worker limits governed by capacity units'
        ELSE 'Adjust thread pool configuration'
    END AS PlatformGuidance
FROM SchedulerAgg s
CROSS JOIN ThreadPool t;
```

---

### Azure SQL–Specific Notes

- `sys.dm_db_resource_stats` is specific to Azure SQL Database / Fabric SQL Database (not available on SQL Server or MI).
- `sys.dm_os_volume_stats` is **not** available — disk volume checks are not applicable.
- Memory usage for multiple databases is not supported — only the current database via `sys.dm_os_memory_clerks`.
- NUMA configuration is managed by the platform and not exposed — omit NUMA sections from the report.
