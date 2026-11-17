# Step 3 - Resource Health

## Sampling Rules

Execute each eligible snapshot `SampleCount` times with a host-side delay of
`SampleIntervalSeconds`. Do not use a long `WAITFOR` batch. Capture `sampled_at_utc` on every
result and compare changes across samples.

One observation can produce `INFO` or a routing hint. `UNHEALTHY` resource classification requires
a sustained or repeated signal, active waiters/blockers, or corroborating evidence.

## HA-RES-001: Scheduler Pressure Snapshot

Requires server performance visibility.

```sql
SELECT
    SYSUTCDATETIME() AS sampled_at_utc,
    SUM(CASE WHEN s.status = N'VISIBLE ONLINE' THEN 1 ELSE 0 END) AS visible_online_schedulers,
    SUM(CASE WHEN s.status = N'VISIBLE ONLINE' THEN s.runnable_tasks_count ELSE 0 END)
        AS runnable_tasks,
    SUM(CASE WHEN s.status = N'VISIBLE ONLINE' THEN s.current_tasks_count ELSE 0 END)
        AS current_tasks,
    SUM(CASE WHEN s.status = N'VISIBLE ONLINE' THEN s.active_workers_count ELSE 0 END)
        AS active_workers,
    SUM(CASE WHEN s.status = N'VISIBLE ONLINE' THEN s.work_queue_count ELSE 0 END)
        AS work_queue_count,
    MAX(CASE WHEN s.status = N'VISIBLE ONLINE' THEN s.runnable_tasks_count END)
        AS max_runnable_tasks_on_scheduler
FROM sys.dm_os_schedulers AS s
WHERE s.scheduler_id < 255
OPTION (MAXDOP 1);
```

Repeated runnable queues across multiple samples are a CPU/scheduler signal. Delegate to
`investigate-sql-cpu-pressure`; do not assign root cause from scheduler counts alone.

## HA-RES-002: Memory Pressure Snapshot

Requires server performance visibility.

```sql
SELECT
    SYSUTCDATETIME() AS sampled_at_utc,
    sm.total_physical_memory_kb,
    sm.available_physical_memory_kb,
    sm.system_memory_state_desc,
    pm.physical_memory_in_use_kb,
    pm.locked_page_allocations_kb,
    pm.memory_utilization_percentage,
    pm.process_physical_memory_low,
    pm.process_virtual_memory_low
FROM sys.dm_os_sys_memory AS sm
CROSS JOIN sys.dm_os_process_memory AS pm
OPTION (MAXDOP 1);
```

Physical/virtual low-memory flags or repeated low-availability state is a confirmed routing signal
for `investigate-sql-memory-issues`.

## HA-RES-003: Query Memory Grant Snapshot

```sql
SELECT
    SYSUTCDATETIME() AS sampled_at_utc,
    rs.resource_semaphore_id,
    rs.total_memory_kb,
    rs.available_memory_kb,
    rs.granted_memory_kb,
    rs.grantee_count,
    rs.waiter_count,
    rs.timeout_error_count,
    rs.forced_grant_count
FROM sys.dm_exec_query_resource_semaphores AS rs
ORDER BY rs.resource_semaphore_id
OPTION (MAXDOP 1);
```

Any active waiter is `WARN/HIGH`; repeated waiters or timeout growth is `FAIL/HIGH` and routes to
the memory specialist.

## HA-RES-004: Active Blocking Snapshot

```sql
SELECT TOP ({{TopN}})
    SYSUTCDATETIME() AS sampled_at_utc,
    r.session_id,
    r.blocking_session_id,
    r.database_id,
    DB_NAME(r.database_id) AS database_name,
    r.status,
    r.wait_type,
    r.wait_time AS wait_time_ms,
    r.wait_resource,
    r.open_transaction_count,
    r.total_elapsed_time AS elapsed_time_ms
FROM sys.dm_exec_requests AS r
WHERE r.session_id <> @@SPID
  AND r.blocking_session_id > 0
ORDER BY r.wait_time DESC, r.total_elapsed_time DESC
OPTION (MAXDOP 1);
```

Redact `wait_resource` when sensitive output is disabled. Repeated blocking across samples routes
to `blocking-root-cause-analysis`. Do not kill sessions.

## HA-RES-005: Dominant Wait Categories

Waits are cumulative since restart or manual reset. Use the Step 1 boundary.

```sql
SELECT TOP ({{TopN}})
    ws.wait_type,
    ws.waiting_tasks_count,
    ws.wait_time_ms,
    ws.signal_wait_time_ms,
    ws.wait_time_ms - ws.signal_wait_time_ms AS resource_wait_time_ms
FROM sys.dm_os_wait_stats AS ws
WHERE ws.waiting_tasks_count > 0
  AND ws.wait_type NOT IN (
      N'BROKER_EVENTHANDLER', N'BROKER_RECEIVE_WAITFOR', N'BROKER_TASK_STOP',
      N'BROKER_TO_FLUSH', N'CHECKPOINT_QUEUE', N'CHKPT', N'CLR_AUTO_EVENT',
      N'CLR_MANUAL_EVENT', N'DIRTY_PAGE_POLL', N'DISPATCHER_QUEUE_SEMAPHORE',
      N'FT_IFTS_SCHEDULER_IDLE_WAIT', N'HADR_FILESTREAM_IOMGR_IOCOMPLETION',
      N'LAZYWRITER_SLEEP', N'LOGMGR_QUEUE', N'ONDEMAND_TASK_QUEUE',
      N'QDS_ASYNC_QUEUE', N'REQUEST_FOR_DEADLOCK_SEARCH', N'RESOURCE_QUEUE',
      N'SERVER_IDLE_CHECK', N'SLEEP_BPOOL_FLUSH', N'SLEEP_DBSTARTUP',
      N'SLEEP_DCOMSTARTUP', N'SLEEP_MASTERDBREADY', N'SLEEP_MASTERMDREADY',
      N'SLEEP_MASTERUPGRADED', N'SLEEP_MSDBSTARTUP', N'SLEEP_SYSTEMTASK',
      N'SLEEP_TASK', N'SLEEP_TEMPDBSTARTUP', N'SNI_HTTP_ACCEPT',
      N'SP_SERVER_DIAGNOSTICS_SLEEP', N'SQLTRACE_BUFFER_FLUSH',
      N'WAITFOR', N'WAITFOR_TASKSHUTDOWN', N'XE_DISPATCHER_JOIN',
      N'XE_DISPATCHER_WAIT', N'XE_TIMER_EVENT'
  )
ORDER BY ws.wait_time_ms DESC
OPTION (MAXDOP 1);
```

Treat this as directional evidence only. Route dominant categories to
`wait-category-analysis`, data/log IO, CPU, memory, or blocking specialists.

## HA-RES-006: Worker Pressure

```sql
SELECT
    SYSUTCDATETIME() AS sampled_at_utc,
    osi.max_workers_count,
    SUM(s.current_workers_count) AS current_workers,
    SUM(s.active_workers_count) AS active_workers,
    SUM(s.work_queue_count) AS queued_work,
    SUM(s.runnable_tasks_count) AS runnable_tasks
FROM sys.dm_os_sys_info AS osi
CROSS JOIN sys.dm_os_schedulers AS s
WHERE s.scheduler_id < 255
  AND s.status = N'VISIBLE ONLINE'
GROUP BY osi.max_workers_count
OPTION (MAXDOP 1);
```

Repeated queued work near the worker limit is `FAIL/HIGH` and should be correlated with
`THREADPOOL`, blocking, and long-running requests. Do not recommend increasing max worker threads
without specialist evidence.
