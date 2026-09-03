---
name: diagnose-resource-pressure
description: >-
  Answers whether an Azure SQL Database is slow because of CPU, data or log IO, memory, or a
  worker and session limit, and what to actually do about each. Use when someone reports the
  database as slow, throttled or timing out under load, pastes a resource governance error such
  as "the request limit for the database is 200 and has been reached" or a raw error number
  10928, 10929 or 10936, asks whether to scale up the service tier, or is reading
  sys.dm_db_resource_stats, sys.dm_os_performance_counters or sys.dm_os_wait_stats and needs the
  numbers interpreted. Covers Azure SQL Database and the local Azure SQL Database container, and
  is explicit about which diagnostics exist in each. Does not read an execution plan (see
  read-execution-plan), diagnose a blocking chain (see diagnose-blocking-and-deadlocks), rewrite a
  slow individual query (see diagnose-slow-query), or resolve a connection or login failure (see
  diagnose-connection-errors).
---

# Diagnose Azure SQL Database resource pressure

**On SQL Server you look at the machine. Here the machine is not yours and the governed limit is
the product.** Every headline number is a percentage of a ceiling set by the service objective,
not a reading off hardware. Ask which limit is being hit, not how busy the box is: CPU,
data IO, log IO, memory, and workers and sessions each have their own fix, and only some are
fixed by scaling.

Checked 2026-09-03 against Microsoft Learn and 2026-08-29 against a live engine reporting
`SERVERPROPERTY('EngineEdition')` = 5 and `Edition` = `SQL Azure`, the local Azure SQL Database
container.

## 1. Substrate and purchasing model

```sql
SELECT SERVERPROPERTY('EngineEdition') AS engine_edition, SERVERPROPERTY('Edition') AS edition;
SELECT TOP 1 end_time, dtu_limit, cpu_limit
FROM sys.dm_db_resource_stats ORDER BY end_time DESC;
```

`dtu_limit` is NULL on a vCore database and `cpu_limit`, the vCore count, is NULL on a DTU one, so
this row settles the purchasing model. On a DTU database
`SELECT COUNT(*) FROM sys.dm_os_schedulers WHERE status = N'VISIBLE ONLINE';` is the only way to
see a vCore count, and on the container that count is whatever CPUs it was given and says nothing
about a tier. The row settles the substrate too: locally the second statement fails
`Msg 208, Invalid object name 'sys.dm_db_resource_stats'`, that view being Azure SQL Database
only. Both answers steer everything below, so run it first.

## 2. CPU

```sql
SELECT TOP 20 end_time, avg_cpu_percent, avg_instance_cpu_percent, avg_memory_usage_percent
FROM sys.dm_db_resource_stats ORDER BY end_time DESC;
```

`avg_cpu_percent` is the user workload against the user CPU limit; `avg_instance_cpu_percent` is
every workload, internal included, against another limit. Learn is explicit: different
scales, not comparable, and either in the 70 to 100 range flattens throughput. On a DTU
database the headline is
`avg_dtu_percent = MAX(avg_cpu_percent, avg_data_io_percent, avg_log_write_percent)`.

The container has no such summary. Order the plan cache on the metric itself, never on a
worker-time-to-elapsed ratio, which silently drops the queries you want:

```sql
SELECT TOP 20 qs.total_worker_time, qs.execution_count,
       qs.total_worker_time / qs.execution_count AS avg_worker_time,
       SUBSTRING(st.text, 1, 200) AS query_text
FROM sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS st
ORDER BY qs.total_worker_time DESC;
```

## 3. Data IO and log IO

```sql
SELECT file_id, num_of_reads, num_of_writes, io_stall_read_ms, io_stall_write_ms,
       io_stall_queued_read_ms, io_stall_queued_write_ms
FROM sys.dm_io_virtual_file_stats(DB_ID(), NULL);
```

Runs in both places. The two queued columns separate delay added by IO governance from delay added
by storage; `avg_data_io_percent` and `avg_log_write_percent` are the governed view on top.

Log rate governance shows up as named waits, and only in the cloud:

```sql
SELECT wait_type, waiting_tasks_count, wait_time_ms FROM sys.dm_os_wait_stats
WHERE wait_type IN ('LOG_RATE_GOVERNOR', 'POOL_LOG_RATE_GOVERNOR', 'INSTANCE_LOG_RATE_GOVERNOR')
  AND waiting_tasks_count > 0;
```

The container has no log rate governor, so this returns nothing there however hard it is pushed,
and a saturated container log surfaces as `WRITELOG`. Empty locally says nothing about the cloud.

## 4. Memory

```sql
SELECT TOP 5 type, pages_kb FROM sys.dm_os_memory_clerks ORDER BY pages_kb DESC;
SELECT resource_semaphore_id, available_memory_kb, grantee_count, waiter_count
FROM sys.dm_exec_query_resource_semaphores;
```

Both run in both places; `waiter_count` above zero with `available_memory_kb` near zero is
grants queuing. Do not read `avg_memory_usage_percent` near 100 as a fault: Learn states the
engine uses all available memory for its data cache whatever the load, which is why the DTU
formula excludes it.

`sys.dm_os_performance_counters` exists on Azure SQL Database, but its permission is not uniform:
Basic, S0, S1 and any pooled database need the server admin, the Microsoft Entra admin or
`##MS_ServerStateReader##`, elsewhere `VIEW DATABASE STATE` is enough. The counter query that works
on S3 fails on S1 as a permission error, not a missing counter.

## 5. Workers and sessions: 10928, 10929, 10936

Read the Resource ID first: `1` is workers, `2` is sessions, not one problem.

```sql
SELECT TOP 20 end_time, max_worker_percent, max_session_percent
FROM sys.dm_db_resource_stats ORDER BY end_time DESC;
SELECT r.session_id, r.blocking_session_id, r.wait_type, r.status
FROM sys.dm_exec_requests AS r WHERE r.session_id > 50;
```

Learn keeps "request limit" in 10928 and 10936 for backward compatibility only, from
when a request was one worker. What ran out is workers. A worker is spent by a login, a serial
query, and every parallel thread above MAXDOP 1, so a blocking pileup or parallelism raises the
count far faster than connection volume, and shrinking the pool alone does not fix it. S3
allows 200 concurrent workers and 2400 sessions, so "the request limit for the database is 200 and
has been reached" is an S3 out of workers.

While the limit is being hit, ordinary connections are refused. One still gets in, and is the only
way to run the query above during the incident:

```bash
sqlcmd -S your-server.database.windows.net -d <database> -U <admin-login> \
  -P "$SQLCMD_PASSWORD" -A -Q "SELECT session_id, blocking_session_id, wait_type \
  FROM sys.dm_exec_requests WHERE blocking_session_id <> 0;"
```

`-A` opens the diagnostic connection, also reachable by prefixing the server name with `admin:`.
It needs a logical server administrator, is not supported with `-G`, and only one exists per
database.

## 6. MAXDOP, the worker multiplier

```sql
SELECT [value], value_for_secondary FROM sys.database_scoped_configurations WHERE [name] = 'MAXDOP';
```

Since September 2020 a new Azure SQL Database reports `8` here, and this view is the authority:
nothing is applied underneath. `0` in the cloud means the database predates that change and
uses every logical processor up to 64, which Learn recommends against; `0` on the container is
just the engine default. `sp_configure` is the surface in neither place, and it is absent rather
than restricted: Learn's `sys.sp_configure` page does not list Azure SQL Database, and on the
container `EXEC sp_configure 'max degree of parallelism';` returns `Msg 2812, Could not find stored
procedure 'sp_configure'`, not the option error `Msg 15123` that sends a reader hunting a
permission problem. Change it with
`ALTER DATABASE SCOPED CONFIGURATION SET MAXDOP = 8;`, which needs server admin, `db_owner` or
`ALTER ANY DATABASE SCOPED CONFIGURATION` and cannot run against `master`.

## 7. Only now, the tier

Scaling raises CPU, memory and IO headroom and the worker and session ceilings. It does not fix a
query doing needless work, and it does not change MAXDOP. Name the exhausted resource first.

## Check it worked

The diagnosis is finished when this returns a row and you can name the column that was high:

```sql
SELECT TOP 1 end_time, avg_cpu_percent, avg_instance_cpu_percent, avg_data_io_percent,
       avg_log_write_percent, max_worker_percent, max_session_percent
FROM sys.dm_db_resource_stats ORDER BY end_time DESC;
```

Rows land every 15 seconds and reach back about an hour; an older incident needs
`sys.resource_stats` in the logical server's `master`, 5 minute granularity over 14 days. After the
fix that column falls and the others do not move.

On the container both return `Msg 208` and nothing substitutes, so the check is the step 2 plan
cache query and the step 3 file stats run twice across the change: the heaviest
`total_worker_time` drops, or `io_stall_write_ms` does. An empty cloud-only result is not health.

## Do not

- Do not read `Msg 208` on the container as a broken database. `sys.dm_db_resource_stats`,
  `sys.resource_stats`, `sys.dm_user_db_resource_governance` and
  `sys.dm_instance_resource_governance` are not implemented there.
- Do not treat `sys.database_service_objectives` on the container as real capacity: it answers
  `GP_Gen5_2` for every database and nothing enforces it.

## References

- Open [references/dmv-and-limits-reference.md](references/dmv-and-limits-reference.md) when a
  statement above returns `Msg 208` and you need the local substitute, or before quoting a worker
  or session limit for a tier.
