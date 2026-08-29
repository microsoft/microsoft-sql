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

**Name the bottleneck before naming the fix.** "The database is slow" is not a diagnosis. CPU, data
IO, log IO, memory, and worker or session exhaustion each have a different cause and a different
fix, and guessing wrong wastes a scale-up that changes nothing.

Measured on 2026-08-29 against a live engine reporting `SERVERPROPERTY('EngineEdition')` = 5 and
`SERVERPROPERTY('Edition')` = `SQL Azure` (the local Azure SQL Database container), and against
Microsoft Learn. Full detail, every query, and the exact error text are in
[references/dmv-and-limits-reference.md](references/dmv-and-limits-reference.md).

## Facts that shape the triage

- **The DMV built to answer this question does not exist on the container.** `sys.dm_db_resource_stats`
  raises `Msg 208, Invalid object name` against the local Azure SQL Database container. It is the
  first thing to reach for on a real Azure SQL Database and it is simply absent locally, not empty
  and not slow, absent.
- **`sys.database_service_objectives` exists on the container and answers with a fixed value**
  (`GeneralPurpose` / `GP_Gen5_2` in the check) regardless of anything about the container's actual
  resources. Nothing enforces that tier locally. Do not use it, or any tier name it returns, to
  reason about local headroom.
- **Error 10928's "request limit" wording is a Resource ID, not a connection count.** Resource ID 1
  means the worker limit was reached; Resource ID 2 means the session limit. The two are not the
  same thing, and 10928 is worded around workers only for backward compatibility.
- **MAXDOP multiplies workers per query, and its default is invisible in its own setting.** Every
  Azure SQL Database created since September 2020 defaults to an effective MAXDOP of 8, but
  `sys.database_scoped_configurations` still reports `value = 0` for that database, because `0` on
  Azure SQL Database means "use the platform default" rather than "unlimited," which is what `0`
  means on the container and on a self-managed engine. A worker-limit diagnosis that never checks
  MAXDOP is guessing.

## Triage in order

1. **Confirm the target.** Cloud database, or the local container? The available diagnostics differ
   enough that this decides the rest of the steps. See the availability table in the reference for
   every object this skill touches.

2. **CPU.** On a real database, read `avg_cpu_percent` and `avg_instance_cpu_percent` from
   `sys.dm_db_resource_stats` over the last several rows. On the container, there is no equivalent
   summary number; order `sys.dm_exec_query_stats` by `total_worker_time` directly to find the
   heaviest queries. Order by the metric itself, never by a ratio between worker time and elapsed
   time to guess which queries are "CPU-bound": a reversed comparison in that kind of filter
   silently drops exactly the queries being searched for, and returns a confident, wrong, empty-handed
   answer instead of an error.

3. **Data or log IO.** `sys.dm_io_virtual_file_stats()` works in both places and reports raw IOPS,
   throughput and latency per file, including `io_stall_queued_read_ms` and
   `io_stall_queued_write_ms`, which isolate delay added by IO governance from delay added by
   storage itself. On a real database, `avg_data_io_percent` and `avg_log_write_percent` from
   `sys.dm_db_resource_stats` give the governance-relative view on top of that.

4. **Memory.** `sys.dm_os_memory_clerks` (which clerk holds the most memory) and
   `sys.dm_exec_query_resource_semaphores` (`available_memory_kb` near zero means grants are
   queuing) work in both places and returned real data in the check. On a real database, treat
   `avg_memory_usage_percent` and `avg_instance_memory_percent` sitting near 100% as expected rather
   than alarming: Azure SQL Database caches aggressively by design, and a near-100% reading on a
   non-idle database is documented normal behavior, not evidence of a problem on its own.

5. **Workers and sessions.** Count sessions with `sys.dm_exec_sessions`, and look for
   `blocking_session_id` and `wait_type` in `sys.dm_exec_requests`. If the symptom is error 10928,
   10929 or 10936, read the Resource ID before proposing a fix: `1` is workers, `2` is sessions.
   A worker-limit hit is usually parallelism (check MAXDOP) or a blocking pileup (route to
   `diagnose-blocking-and-deadlocks`) rather than raw connection volume, and reducing connection
   pool size alone will not fix a worker-limit problem it did not cause.

6. **Transaction log rate.** On a real database under a bulk load, look for the `LOG_RATE_GOVERNOR`,
   `POOL_LOG_RATE_GOVERNOR` and `INSTANCE_LOG_RATE_GOVERNOR` wait types. The container has no log
   rate governance, so these waits never appear there; a saturated container log shows up as raw
   `WRITELOG` wait or elevated `Log Flush Wait Time` instead. Their absence locally is not evidence
   a cloud workload is not log-rate limited.

7. **Only after naming the bottleneck, talk about the service tier.** Scaling up fixes CPU, memory
   and IO headroom and raises the worker and session ceiling, but it does not fix a query that is
   simply doing more work than it needs to, and it does not change MAXDOP. State which resource is
   exhausted before recommending it.

## Validation rules

- The answer names one specific resource (CPU, data IO, log IO, memory, or workers/sessions), not
  "the database is slow" or "it needs to scale."
- If the target is the local container and `sys.dm_db_resource_stats` (or another cloud-only object
  from the reference table) was needed, the response says so explicitly and used the local
  substitute rather than assuming the query returned rows or silently returning nothing.
- A worker or session limit diagnosis (10928, 10929, 10936) named the Resource ID and did not treat
  it as a plain connection count.
- If MAXDOP was relevant, the diagnosis checked `sys.database_scoped_configurations` and stated
  whether the target is the container (0 means unbounded) or a real Azure SQL Database (0 means the
  platform default of 8 applies).
- CPU-bound queries were found by ordering on `total_worker_time`, not by a worker-time-to-elapsed-time
  ratio filter.
- A service-tier recommendation on the container was not based on `sys.database_service_objectives`.

## Do not

- Do not query `sys.dm_db_resource_stats`, `sys.resource_stats`, `sys.dm_user_db_resource_governance`
  or `sys.dm_instance_resource_governance` against the local container and read the "invalid object
  name" error as evidence something is broken. They are simply not implemented there.
- Do not read `sys.database_service_objectives` on the container as if it reflects real, enforced
  capacity. It returns a fixed value unrelated to anything about the container's actual resources.
- Do not conclude "too many connections" from a 10928 or 10936 with Resource ID 1. That resource id
  names workers, and MAXDOP is usually the multiplier, not the number of open sessions.
- Do not treat `sys.database_scoped_configurations` MAXDOP `0` as unlimited parallelism when the
  target is a real Azure SQL Database. It means the platform default (8, for databases created since
  September 2020) applies, invisibly, underneath that reported value.
- Do not filter candidate "CPU-bound" queries with a ratio between worker time and elapsed time.
  Order by `total_worker_time` directly.
- Do not diagnose a blocking chain to conclusion here; hand it to `diagnose-blocking-and-deadlocks`
  once `blocking_session_id` shows one exists.
- Do not read or explain an execution plan here; hand that to `read-execution-plan`.
- Do not answer error 40613, 18456 or 4060 here even if they were pasted alongside a resource
  question; they are connection and login failures, and belong to `diagnose-connection-errors` and
  `entra-id-auth`.
- Do not recommend a service tier change as the first move, before separating CPU from IO from
  memory from worker exhaustion; each has a different fix, and only some of them are fixed by scale.

## References

- [references/dmv-and-limits-reference.md](references/dmv-and-limits-reference.md): every DMV named
  above with its exact container-versus-cloud availability as measured, the query for each question,
  the full error code table for 10928/10929/10936, the MAXDOP default history, and the log rate
  governance wait types. Read it before running a query this skill only summarizes.
