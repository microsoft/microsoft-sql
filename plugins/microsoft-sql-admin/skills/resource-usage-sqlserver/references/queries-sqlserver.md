# Resource Usage — SQL Server / Managed Instance Queries

All queries target **SQL Server (Engine Edition 1–4)** and **Azure SQL Managed Instance (Engine Edition 8)**.
Execute each query with the SQL query tool. Replace `{{parameter}}` placeholders with values from the skill parameters.

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
| `engine_edition IN (1,2,3,4)` — SQL Server | Continue with this file. |
| `engine_edition = 8` — Azure SQL Managed Instance | Continue with this file. |
| `engine_edition IN (5, 12)` — Azure SQL DB / Fabric SQL DB | **Switch to `references/queries-azuresql.md`** — these platforms use `sys.dm_db_resource_stats` instead of ring buffers. |
| `is_unsupported_platform = 1` (edition 6, 9, 11) | **Stop** — report unsupported platform. |

---

### NUMA Configuration

> Returns MAXDOP, NUMA node count, online schedulers, logical CPU count, CPUs per node, and soft-NUMA status for the report's CPU and NUMA Configuration section.
> `softnuma_configuration_desc` requires SQL Server 2016+; on older versions remove that column and report SOFTNUMA as "N/A".

```sql
SELECT
      (SELECT CAST(value_in_use AS INT)
       FROM sys.configurations
       WHERE name = N'max degree of parallelism')                        AS MAXDOP
    , (SELECT COUNT(*)
       FROM sys.dm_os_nodes
       WHERE node_state_desc <> N'ONLINE DAC')                           AS Nodes
    , (SELECT COUNT(*)
       FROM sys.dm_os_schedulers
       WHERE status = N'VISIBLE ONLINE')                                 AS OnlineSchedulers
    , si.cpu_count                                                       AS TotalCores
    , (SELECT MAX(online_scheduler_count)
       FROM sys.dm_os_nodes
       WHERE node_state_desc <> N'ONLINE DAC')                           AS CPU_per_Node
    , si.softnuma_configuration_desc                                     AS SOFTNUMA
FROM sys.dm_os_sys_info AS si
OPTION (MAXDOP 1);
```

---

### Step 1: CPU Utilization (Ring Buffers)

> Sources CPU history from `RING_BUFFER_SCHEDULER_MONITOR`, which retains approximately the last 4 hours (~1 sample/minute).

```sql
SET NOCOUNT ON;
DECLARE @CPUHighThreshold INT = {{CPUHighThreshold}};
DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @ts_now BIGINT;

SELECT @ts_now = cpu_ticks / (cpu_ticks / ms_ticks)
FROM sys.dm_os_sys_info;

SELECT
    CASE @EngineEdition WHEN 8 THEN 'Azure SQL Managed Instance' ELSE 'SQL Server' END AS Platform,
    DATEADD(ms, -1 * (@ts_now - [timestamp]), GETDATE()) AS EventTime,
    SQLProcessUtilization AS SQL_CPU,
    SystemIdle,
    (100 - SystemIdle - SQLProcessUtilization) AS OtherProcessCPU,
    CASE
        WHEN SQLProcessUtilization > @CPUHighThreshold THEN 'SQL Server causing HIGH CPU'
        WHEN (100 - SystemIdle - SQLProcessUtilization) > @CPUHighThreshold THEN 'External process causing HIGH CPU'
        ELSE 'Moderate CPU usage'
    END AS CPU_Classification,
    CASE
        WHEN SQLProcessUtilization > @CPUHighThreshold
            THEN 'Investigate top SQL queries / parallelism / blocking'
        WHEN (100 - SystemIdle - SQLProcessUtilization) > @CPUHighThreshold
            THEN 'Check OS processes (AV, backup, ETL, agents)'
        ELSE 'No immediate CPU bottleneck'
    END AS LikelyCause
FROM
(
    SELECT
        record.value('(./Record/SchedulerMonitorEvent/SystemHealth/SystemIdle)[1]', 'int') AS SystemIdle,
        record.value('(./Record/SchedulerMonitorEvent/SystemHealth/ProcessUtilization)[1]', 'int') AS SQLProcessUtilization,
        [timestamp]
    FROM
    (
        SELECT [timestamp], CONVERT(XML, record) AS record
        FROM sys.dm_os_ring_buffers
        WHERE ring_buffer_type = 'RING_BUFFER_SCHEDULER_MONITOR'
          AND record LIKE '%<SystemHealth>%'
    ) rb
) AS cpu_data
ORDER BY EventTime DESC;
```

---

### Step 2: Per-Scheduler Load

> Analyzes load distribution across SQLOS schedulers. High `runnable_tasks_count` indicates CPU queueing.

```sql
SET NOCOUNT ON;
DECLARE @MaxSchedulers INT = {{MaxSchedulers}};
DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));

DECLARE @Platform NVARCHAR(40) =
    CASE @EngineEdition
        WHEN 8 THEN 'Azure SQL Managed Instance'
        ELSE 'SQL Server (IaaS/Box)'
    END;

;WITH S AS
(
    SELECT
        scheduler_id,
        [status],
        current_tasks_count,
        runnable_tasks_count,
        current_workers_count,
        active_workers_count,
        work_queue_count,
        pending_disk_io_count,
        load_factor
    FROM sys.dm_os_schedulers
    WHERE [status] = 'VISIBLE ONLINE'
),
Agg AS
(
    SELECT
        TotalSchedulers = COUNT(*),
        TotalRunnable   = SUM(CONVERT(BIGINT, runnable_tasks_count)),
        AvgRunnable     = AVG(CONVERT(DECIMAL(18,2), runnable_tasks_count)),
        MaxRunnable     = MAX(runnable_tasks_count),
        TotalWorkQueue  = SUM(CONVERT(BIGINT, work_queue_count)),
        AvgLoadFactor   = AVG(CONVERT(DECIMAL(18,2), load_factor))
    FROM S
)
SELECT
    CaptureTime = GETDATE(),
    EngineEdition = @EngineEdition,
    Platform = @Platform,
    s.scheduler_id,
    s.[status],
    s.runnable_tasks_count,
    s.work_queue_count,
    s.current_tasks_count,
    s.active_workers_count,
    s.current_workers_count,
    s.pending_disk_io_count,
    s.load_factor,
    AnalyzingPerSchedulerLoad =
        (CONVERT(BIGINT, s.runnable_tasks_count) * 100) +
        (CONVERT(BIGINT, s.work_queue_count) * 10) +
        (CONVERT(BIGINT, s.pending_disk_io_count) * 5) +
        (CONVERT(BIGINT, s.load_factor)),
    RunnableSharePct =
        CASE WHEN a.TotalRunnable > 0
             THEN CONVERT(DECIMAL(6,2), (100.0 * s.runnable_tasks_count) / a.TotalRunnable)
             ELSE 0
        END,
    SchedulerHealth =
        CASE
            WHEN s.runnable_tasks_count >= 10 THEN 'High CPU queue on this scheduler'
            WHEN s.runnable_tasks_count BETWEEN 1 AND 9 THEN 'Some CPU queueing'
            ELSE 'No CPU queueing'
        END,
    a.TotalSchedulers,
    a.TotalRunnable,
    a.AvgRunnable,
    a.MaxRunnable,
    a.TotalWorkQueue,
    a.AvgLoadFactor
FROM S s
CROSS JOIN Agg a
ORDER BY
    AnalyzingPerSchedulerLoad DESC,
    s.runnable_tasks_count DESC,
    s.load_factor DESC
OFFSET 0 ROWS FETCH NEXT @MaxSchedulers ROWS ONLY;
```

---

### Step 3: External Memory Pressure

> Uses `sys.dm_os_sys_memory` and `sys.dm_os_process_memory` to detect OS-level and SQL-internal memory pressure.

```sql
SET NOCOUNT ON;
DECLARE @MemoryHighThreshold INT = {{MemoryHighThreshold}};
DECLARE @MemoryLowThresholdPct DECIMAL(5,2) = {{MemoryLowThresholdPct}};
DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));

SELECT
    CASE @EngineEdition WHEN 8 THEN 'Azure SQL Managed Instance' ELSE 'SQL Server' END AS Platform,
    GETDATE() AS CaptureTime,
    total_physical_memory_kb / 1024 AS TotalMemoryMB,
    available_physical_memory_kb / 1024 AS AvailableMemoryMB,
    system_memory_state_desc,
    (SELECT physical_memory_in_use_kb / 1024
     FROM sys.dm_os_process_memory) AS SQLMemoryUsedMB,
    (SELECT process_physical_memory_low
     FROM sys.dm_os_process_memory) AS IsPhysicalMemoryLow,
    (SELECT process_virtual_memory_low
     FROM sys.dm_os_process_memory) AS IsVirtualMemoryLow,
    (SELECT committed_kb / 1024
     FROM sys.dm_os_sys_info) AS SQLCommittedMB,
    (SELECT committed_target_kb / 1024
     FROM sys.dm_os_sys_info) AS SQLTargetMB,
    CASE
        WHEN (SELECT process_physical_memory_low FROM sys.dm_os_process_memory) = 1
            THEN 'CRITICAL: LOW PHYSICAL MEMORY'
        WHEN (SELECT committed_kb FROM sys.dm_os_sys_info)
             >= (SELECT committed_target_kb FROM sys.dm_os_sys_info)
            THEN 'HIGH PRESSURE: SQL REACHED TARGET MEMORY'
        WHEN available_physical_memory_kb < (total_physical_memory_kb * (@MemoryLowThresholdPct / 100.0))
            THEN 'OS MEMORY LOW (External Pressure)'
        ELSE 'MEMORY HEALTHY'
    END AS Memory_Classification,
    CASE
        WHEN (SELECT process_physical_memory_low FROM sys.dm_os_process_memory) = 1
            THEN 'Severe memory pressure affecting SQL process'
        WHEN (SELECT committed_kb FROM sys.dm_os_sys_info)
             >= (SELECT committed_target_kb FROM sys.dm_os_sys_info)
            THEN 'SQL needs more memory or workload pressure high'
        WHEN available_physical_memory_kb < (total_physical_memory_kb * (@MemoryLowThresholdPct / 100.0))
            THEN 'External memory pressure (OS / other apps)'
        ELSE 'No memory pressure detected'
    END AS LikelyCause
FROM sys.dm_os_sys_memory;
```

---

### Step 4: Memory Usage per Clerk

> Shows the top memory-consuming memory clerks by total allocation.

```sql
SET NOCOUNT ON;
DECLARE @TopNClerks INT = {{TopNClerks}};
DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));

DECLARE @Platform NVARCHAR(40) =
    CASE @EngineEdition
        WHEN 8 THEN 'Azure SQL Managed Instance'
        ELSE 'SQL Server (IaaS/Box)'
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

### Step 5: Disk Volume Free Space

> Uses `sys.dm_os_volume_stats` to check free space on disk volumes hosting database files. **SQL Server / MI only** — this DMV is not available on Azure SQL DB or Fabric.

```sql
SET NOCOUNT ON;
DECLARE @DiskFreeWarningPct DECIMAL(5,2) = {{DiskFreeWarningPct}};

SELECT
    vs.volume_mount_point AS [Drive],
    vs.logical_volume_name AS [Drive Name],
    CONVERT(DECIMAL(18,2), vs.total_bytes/1073741824.0) AS [Total Size (GB)],
    CONVERT(DECIMAL(18,2), vs.available_bytes/1073741824.0) AS [Available Size (GB)],
    CONVERT(DECIMAL(18,2), vs.available_bytes * 1. / vs.total_bytes * 100.) AS [Free Space %],
    CASE
        WHEN CONVERT(DECIMAL(18,2), vs.available_bytes * 1. / vs.total_bytes * 100.) < @DiskFreeWarningPct
        THEN 'WARNING: LOW DISK SPACE'
        ELSE 'OK'
    END AS [Status]
FROM sys.master_files AS f
CROSS APPLY sys.dm_os_volume_stats(f.database_id, f.[file_id]) AS vs
GROUP BY
    vs.volume_mount_point,
    vs.logical_volume_name,
    vs.total_bytes,
    vs.available_bytes
ORDER BY [Free Space %] ASC;
```

---

### Step 6: TempDB Contention

> Detects active TempDB latch waits on PFS/GAM/SGAM pages.

```sql
SET NOCOUNT ON;
DECLARE @TempDBWaitThresholdMs INT = {{TempDBWaitThresholdMs}};
DECLARE @TempDBHighSeverityMs INT = {{TempDBHighSeverityMs}};
DECLARE @MaxResults INT = {{MaxResults}};

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
    'SQL Server / MI' AS Platform,
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

### Step 7: Threadpool Health

> Checks for thread pool starvation, worker queue buildup, and runnable task pressure.

```sql
SET NOCOUNT ON;
DECLARE @RunnableTasksWarning INT = {{RunnableTasksWarning}};
DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));

DECLARE @Platform VARCHAR(50) =
    CASE @EngineEdition
        WHEN 8 THEN 'Azure SQL Managed Instance'
        ELSE 'SQL Server'
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
        WHEN @EngineEdition = 8
            THEN 'SQL MI: Instance limits apply'
        ELSE 'SQL Server: Adjust thread pool configuration'
    END AS PlatformGuidance
FROM SchedulerAgg s
CROSS JOIN ThreadPool t;
```
