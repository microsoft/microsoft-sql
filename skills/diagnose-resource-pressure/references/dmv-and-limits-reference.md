# DMVs, error codes and limits for Azure SQL Database resource pressure

Checked on 2026-08-29 against a live engine reporting `SERVERPROPERTY('EngineEdition')` = 5 and
`SERVERPROPERTY('Edition')` = `SQL Azure` (the local Azure SQL Database container), and against
Microsoft Learn.

## Contents

- [How to use this file](#how-to-use-this-file)
- [DMV availability, container versus a real Azure SQL Database](#dmv-availability-container-versus-a-real-azure-sql-database)
- [The queries, by question](#the-queries-by-question)
- [Resource governance error codes](#resource-governance-error-codes)
- [MAXDOP: the default that is invisible in its own setting](#maxdop-the-default-that-is-invisible-in-its-own-setting)
- [Worker and session limits by tier](#worker-and-session-limits-by-tier)
- [Transaction log rate governance](#transaction-log-rate-governance)
- [Sources](#sources)

## How to use this file

The skill body gives the decision order. This file gives the exact object names, the exact query
to run for each question, and what each object returned when checked directly. Read the
availability table first when the target is the local container, because roughly a third of the
objects a search engine or a model's own memory suggests do not exist there at all.

## DMV availability, container versus a real Azure SQL Database

Every "container" cell here was run directly, not inferred. Every "cloud" cell is Microsoft Learn's
documented behavior for Azure SQL Database; none of it was measured against a live paid database in
this check, because none was available.

| Object | Container | Azure SQL Database (documented) |
|---|---|---|
| `sys.dm_db_resource_stats` | Does not exist. `SELECT * FROM sys.dm_db_resource_stats` raises `Msg 208, Invalid object name 'sys.dm_db_resource_stats'` | Exists, per-database, one row roughly every 15 seconds, the primary answer to "is it CPU, IO or memory" |
| `sys.resource_stats` | Does not exist in any database, including `master` | Exists in the logical server's `master` database only, five-minute granularity, longer retention |
| `sys.dm_user_db_resource_governance` | Does not exist | Exists, reports the effective governance limits (including MAXDOP and storage quota) actually in force for the current database |
| `sys.dm_instance_resource_governance` | Does not exist | Exists, server-wide governance settings |
| `sys.database_service_objectives` | Exists, but returns a fixed placeholder (`GeneralPurpose` / `GP_Gen5_2`) for every database regardless of anything about the container | Exists, reflects the real provisioned or serverless service objective |
| `sys.dm_os_wait_stats` | Exists, real data (76 wait types observed with load in the check database) | Exists, scoped to the resource pool serving the current database |
| `sys.dm_os_performance_counters` | Exists (2695 rows observed), including the full `SQLServer:Buffer Manager` and log-flush counter families, because the container is not sharing the process with any other tenant | Exists; the numbers describe the shared engine process, so read them as a container-only diagnostic rather than a stand-in for `sys.dm_db_resource_stats` on a real database |
| `sys.dm_exec_query_resource_semaphores` | Exists, returns rows (memory grant semaphore state) | Exists |
| `sys.dm_os_memory_clerks` | Exists, returns rows (`MEMORYCLERK_SQLBUFFERPOOL` was the largest clerk in the check) | Exists |
| `sys.dm_exec_query_stats` / `sys.dm_exec_cached_plans` | Exist, plan cache and per-plan CPU and IO stats populate normally | Exist |
| `sys.dm_exec_requests` / `sys.dm_exec_sessions` (`blocking_session_id`, `wait_type`) | Exist, populate normally | Exist |
| `sys.dm_resource_governor_workload_groups` | Exists, shows only `internal` and `default` groups, both at 25% max memory grant | Exists, with the Azure-specific `SloSharedPool1` and `UserPrimaryGroup.DBId[N]` groups Learn documents; the container's generic groups are not that |
| `sp_configure 'max degree of parallelism'` | Fails: `Msg 15123, The configuration option 'max degree of parallelism' does not exist` | Not the configuration surface either; `ALTER DATABASE SCOPED CONFIGURATION` is documented as the way to change MAXDOP |
| `sys.database_scoped_configurations` (MAXDOP) | Exists, reports `value = 0` by default | Exists, also reports `0` by default on an unconfigured database, per Microsoft Learn and the platform behavior described below |

## The queries, by question

Run these against the target database, not `master`, unless a column is noted otherwise.

**Is it CPU?** On a real Azure SQL Database:

```sql
SELECT TOP 20 CONVERT(date, end_time) AS d, avg_cpu_percent, avg_instance_cpu_percent
FROM sys.dm_db_resource_stats
ORDER BY end_time DESC;
```

On the container, there is no equivalent single number. Use the plan cache instead, ordered by the
metric itself rather than a derived ratio:

```sql
SELECT TOP 20 qs.total_worker_time, qs.execution_count,
       qs.total_worker_time / qs.execution_count AS avg_worker_time,
       SUBSTRING(st.text, 1, 200) AS query_text
FROM sys.dm_exec_query_stats qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st
ORDER BY qs.total_worker_time DESC;
```

**Is it data IO or log IO?** On a real database, `avg_data_io_percent` and `avg_log_write_percent`
in `sys.dm_db_resource_stats` are the governance-relative view; `sys.dm_io_virtual_file_stats()`
works in both places for the raw per-file numbers, including `io_stall_queued_read_ms` and
`io_stall_queued_write_ms`, which show delay added specifically by IO governance rather than by the
storage layer itself.

**Is it memory?** `sys.dm_os_memory_clerks` (largest consumer) and
`sys.dm_exec_query_resource_semaphores` (`available_memory_kb` near zero means grants are queuing)
work in both places. On a real database, `avg_memory_usage_percent` and `avg_instance_memory_percent`
from `sys.dm_db_resource_stats` are the documented headline numbers, and Microsoft Learn is explicit
that both routinely sit near 100% on a non-idle database by design, because the engine caches
aggressively; a high reading alone is not evidence of a problem.

**Is it workers or sessions?**

```sql
SELECT COUNT(*) AS sessions FROM sys.dm_exec_sessions WHERE is_user_process = 1;
SELECT r.session_id, r.blocking_session_id, r.wait_type, r.status
FROM sys.dm_exec_requests r
WHERE r.session_id > 50;
```

A large gap between session count and worker count (visible only indirectly, since neither the
container nor a normal user connection exposes a live worker count) usually means parallelism, not
connection volume. See the MAXDOP section below.

## Resource governance error codes

Verified against Microsoft Learn on 2026-08-29.

| Error | Resource ID meaning | Text (abridged) |
|---|---|---|
| `10928` | `1` = workers, `2` = sessions | `Resource ID : %d. The %s limit for the database is %d and has been reached` |
| `10936` | Same as `10928`, for an elastic pool | `Resource ID : %d. The %s limit for the elastic pool is %d and has been reached` |
| `10929` | Same Resource ID meaning, phrased as a soft limit | `Resource ID: %d. The %s minimum guarantee is %d, maximum limit is %d and the current usage for the database is %d. However, the server is currently too busy...` |

Microsoft Learn's own note on `10928`: the wording "request limit" is kept only for backward
compatibility from when Azure SQL Database supported single-threaded queries and a request was
always one worker. The limit actually reached today is the worker count, and a worker is consumed
by a login, a serial query, or each parallel thread of a query running above MAXDOP 1. Diagnosing
either error as a connection-count problem, without checking MAXDOP, is the exact substitution
this reference exists to prevent.

`diagnose-connection-errors` owns the identification of `40613`, `18456` and `4060`, which read
similarly but are not resource governance at all: `40613` is expected serverless resume,
`18456` and `4060` are past the login entirely. Route those there rather than diagnosing them here.

## MAXDOP: the default that is invisible in its own setting

`sys.database_scoped_configurations` reports `MAXDOP = 0` on both the local container and an
unconfigured Azure SQL Database. The behavior behind that `0` is not the same in both places:

- **On the container**, `0` behaves the way it does in a self-managed engine: the database engine
  uses up to the total logical processor count, or 64, whichever is smaller.
- **On Azure SQL Database**, a database-scoped value of `0` means "use the platform default," and
  since September 2020 that platform default is `8` for every newly created database. A database
  created before that date keeps whatever it already had. The database-scoped value never changes
  itself to show `8`; the override happens beneath what the view reports.

Check and set it explicitly rather than trusting the default silently:

```sql
SELECT [value], value_for_secondary FROM sys.database_scoped_configurations WHERE [name] = 'MAXDOP';
ALTER DATABASE SCOPED CONFIGURATION SET MAXDOP = 8;
```

`ALTER DATABASE SCOPED CONFIGURATION` requires the server admin, `db_owner`, or a principal granted
`ALTER ANY DATABASE SCOPED CONFIGURATION`, and cannot run against `master`.

## Worker and session limits by tier

The maximum worker count is set by the compute size, not a fixed platform number. Microsoft Learn's
documented rule of thumb for standard-series (Gen5) hardware is roughly 100 concurrent workers per
vCore, so a 2 vCore General Purpose database supports on the order of 200 workers before `10928`
with Resource ID 1. The exact table is service-tier and generation specific and belongs to
[Resource limits for single databases using the vCore purchasing model](https://learn.microsoft.com/azure/azure-sql/database/resource-limits-vcore-single-databases)
and its DTU-model counterpart, not duplicated here because it is exactly the kind of number that
changes with hardware generations. Fetch the current table rather than trusting a remembered one.

The container enforces no such limit; `sys.dm_os_sys_info` in the check reported `max_workers_count`
of 512, a generic SQL Server default unrelated to any Azure SQL Database compute size, and is not a
number worth quoting as if it represented a service tier.

## Transaction log rate governance

Documented wait types, visible in `sys.dm_exec_requests` and `sys.dm_os_wait_stats` on a real
database when log rate governance is actively throttling:

| Wait type | Meaning |
|---|---|
| `LOG_RATE_GOVERNOR` | Database-level log rate limiting |
| `POOL_LOG_RATE_GOVERNOR` | Elastic pool-level log rate limiting |
| `INSTANCE_LOG_RATE_GOVERNOR` | Instance-level log rate limiting |
| `HADR_THROTTLE_LOG_RATE_SEND_RECV_QUEUE_SIZE` | Feedback control: a replica is not keeping up |
| `HADR_THROTTLE_LOG_RATE_LOG_SIZE` | Feedback control: avoiding an out-of-log-space condition |
| `HADR_THROTTLE_LOG_RATE_MISMATCHED_SLO` | Geo-replication feedback control |

None of these appeared in the container's `sys.dm_os_wait_stats` during the check, because the
container has no log rate governance to throttle against; a bulk load that saturates the container's
log will show as raw log-flush wait time (`WRITELOG`, or elevated `Log Flush Wait Time` in
`sys.dm_os_performance_counters`) instead of one of these named waits. Do not read their absence
locally as evidence a cloud workload is not log-rate limited.

## Sources

- [Resource management - Azure SQL Database](https://learn.microsoft.com/azure/azure-sql/database/resource-limits-logical-server), Microsoft Learn, fetched 2026-08-29.
- [Configure the max degree of parallelism (MAXDOP)](https://learn.microsoft.com/azure/azure-sql/database/configure-max-degree-of-parallelism), Microsoft Learn, fetched 2026-08-29.
- [Troubleshoot common connection issues](https://learn.microsoft.com/azure/azure-sql/database/troubleshoot-common-errors-issues), Microsoft Learn, fetched 2026-08-29, section on errors 10928, 10929 and 10936.
- `sys.dm_db_resource_stats`, `sys.database_scoped_configurations`, `sys.dm_user_db_resource_governance` reference pages, Microsoft Learn.
- Every container row in the availability table: measured directly against the local engine on 2026-08-29.
