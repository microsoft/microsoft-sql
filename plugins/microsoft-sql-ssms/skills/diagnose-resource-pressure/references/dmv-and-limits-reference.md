# DMVs, error codes and limits for Azure SQL Database resource pressure

Checked on 2026-09-03 against Microsoft Learn and on 2026-08-29 against a live engine reporting `SERVERPROPERTY('EngineEdition')` = 5 and
`SERVERPROPERTY('Edition')` = `SQL Azure` (the local Azure SQL Database container).

## Contents

- [How to use this file](#how-to-use-this-file)
- [DMV availability, container versus a real Azure SQL Database](#dmv-availability-container-versus-a-real-azure-sql-database)
- [The purchasing model, and the numbers behind the percentages](#the-purchasing-model-and-the-numbers-behind-the-percentages)
- [Resource governance error codes](#resource-governance-error-codes)
- [MAXDOP: the same 0 means two different things](#maxdop-the-same-0-means-two-different-things)
- [Worker and session limits by tier](#worker-and-session-limits-by-tier)
- [Transaction log rate governance](#transaction-log-rate-governance)
- [Sources](#sources)

## How to use this file

The skill body gives the decision order. This file gives what each object returned when checked
directly. Read the availability table first when the target is the container: about a third of the
objects a model reaches for do not exist there.

## DMV availability, container versus a real Azure SQL Database

Every "container" cell was run directly. Every "cloud" cell is Learn's documented behavior, not
measured, because no paid database was available for this check.

| Object | Container | Azure SQL Database (documented) |
|---|---|---|
| `sys.dm_db_resource_stats` | Does not exist. `SELECT * FROM sys.dm_db_resource_stats` raises `Msg 208, Invalid object name 'sys.dm_db_resource_stats'` | Exists, per-database, one row roughly every 15 seconds, the primary answer to "is it CPU, IO or memory" |
| `sys.resource_stats` | Does not exist in any database, including `master` | Exists in the logical server's `master` database only, five-minute granularity, longer retention |
| `sys.dm_user_db_resource_governance` | Does not exist | Exists, reports the effective governance limits (including MAXDOP and storage quota) actually in force for the current database |
| `sys.dm_instance_resource_governance` | Does not exist | Exists, server-wide governance settings |
| `sys.database_service_objectives` | Exists, but returns a fixed placeholder (`GeneralPurpose` / `GP_Gen5_2`) for every database regardless of the container's real size | Exists, reflects the real provisioned or serverless service objective |
| `sys.dm_os_wait_stats` | Exists, real data (76 wait types under load in the check) | Exists, scoped to the resource pool serving the current database |
| `sys.dm_os_performance_counters` | Exists (2695 rows observed), including the full `SQLServer:Buffer Manager` and log-flush counter families, because the container is not sharing the process with any other tenant | Exists, but the permission differs by service objective: Basic, S0, S1 and any pooled database need the server admin, the Microsoft Entra admin or `##MS_ServerStateReader##`, elsewhere `VIEW DATABASE STATE` is enough. The numbers describe the shared engine process, so it is no stand-in for `sys.dm_db_resource_stats` |
| `sys.dm_exec_query_resource_semaphores`, `sys.dm_os_memory_clerks`, `sys.dm_exec_query_stats`, `sys.dm_exec_cached_plans`, `sys.dm_exec_requests`, `sys.dm_exec_sessions` | All exist and populate normally: memory grant semaphore state, `MEMORYCLERK_SQLBUFFERPOOL` as the largest clerk in the check, plan cache with per-plan CPU and IO, and live `blocking_session_id` and `wait_type` | All exist |
| `sp_configure 'max degree of parallelism'` | Not installed: `Msg 2812, Could not find stored procedure 'sp_configure'`, measured 2026-09-03 | Not supported either, and not the configuration surface; see the MAXDOP section below |
| `sys.database_scoped_configurations` (MAXDOP) | Exists, reports `value = 0` (measured) | Exists, reports `8` on every database created since September 2020, and `0` on one created before it |

## The purchasing model, and the numbers behind the percentages

Every percentage in `sys.dm_db_resource_stats` is against a governed limit, so the limit has to be
known first. The same row identifies the model:

```sql
SELECT TOP 1 end_time, dtu_limit, cpu_limit, avg_cpu_percent, avg_instance_cpu_percent,
       avg_data_io_percent, avg_log_write_percent, avg_memory_usage_percent,
       max_worker_percent, max_session_percent
FROM sys.dm_db_resource_stats ORDER BY end_time DESC;
```

- `dtu_limit` is `NULL` on a vCore database; `cpu_limit`, the vCore count, is `NULL` on a DTU one.
- On a DTU database the headline is not a column. Learn defines it as
  `avg_dtu_percent = MAX(avg_cpu_percent, avg_data_io_percent, avg_log_write_percent)`, memory
  excluded because the data cache keeps `avg_memory_usage_percent` near 100 regardless of load.
- `avg_cpu_percent` (user workload) and `avg_instance_cpu_percent` (every workload) are
  percentages of two different limits, not comparable with each other, and either in the 70 to 100
  range flattens throughput.
- `sys.dm_user_db_resource_governance` is the view Learn names as where the actual DTU and vCore
  limits are exposed, and the one to compare when sizing a move between models. Cloud only.

## Resource governance error codes

Verified against Microsoft Learn on 2026-08-29.

| Error | Resource ID meaning | Text (abridged) |
|---|---|---|
| `10928` | `1` = workers, `2` = sessions | `Resource ID : %d. The %s limit for the database is %d and has been reached` |
| `10936` | Same as `10928`, for an elastic pool | `Resource ID : %d. The %s limit for the elastic pool is %d and has been reached` |
| `10929` | Same Resource ID meaning, phrased as a soft limit | `Resource ID: %d. The %s minimum guarantee is %d, maximum limit is %d and the current usage for the database is %d...` |

Learn's note on `10928`: "request limit" is backward compatibility from when a request was one
worker. What is reached is the worker count, consumed by a login, a serial query, or each parallel
thread above MAXDOP 1.

`40613`, `18456` and `4060` read similarly and are not resource governance at all;
`diagnose-connection-errors` owns them.

## MAXDOP: the same `0` means two different things

**Corrected 2026-09-03.** An earlier revision claimed Azure SQL Database reports `0` while
applying `8` invisibly underneath. Learn contradicts it: "the MAXDOP database-scoped configuration
is set to 8" for each new single or elastic pool database, and Learn's own example reads
`sys.database_scoped_configurations` to determine it. The view is the authority.

- **`8` in the cloud** is the default for any database created since September 2020. Databases
  created before that date were not changed.
- **`0` in the cloud** therefore means the database predates that change, or somebody set it back.
  Learn recommends against `0`: it uses the logical processor count up to 64, so a scale-up
  silently widens every parallel plan.
- **`0` on the container** is measured, and is the engine default with no control plane to set
  anything else. It says nothing about what a cloud database would report.

Check and set it explicitly rather than trusting the default silently:

```sql
SELECT [value], value_for_secondary FROM sys.database_scoped_configurations WHERE [name] = 'MAXDOP';
ALTER DATABASE SCOPED CONFIGURATION SET MAXDOP = 8;
```

`ALTER DATABASE SCOPED CONFIGURATION` requires the server admin, `db_owner`, or a principal granted
`ALTER ANY DATABASE SCOPED CONFIGURATION`, and cannot run against `master`. `sp_configure` is not
an alternative, and it is absent rather than restricted. Learn lists `sp_configure` and
`RECONFIGURE` among the syntax Azure SQL Database does not support, and the `sys.sp_configure`
Applies to list omits Azure SQL Database. On the container it is not installed:
`EXEC sp_configure 'max degree of parallelism';` returns `Msg 2812, Could not find stored procedure
'sp_configure'`, measured 2026-09-03. An earlier revision published `Msg 15123`, the option error,
which would have meant the procedure was there and had rejected the option name.

## Worker and session limits by tier

The maximum worker count is set by the compute size, not by a fixed platform number, so the number
in a `10928` message identifies the tier. Microsoft Learn's DTU table for single databases:

| Compute size | Basic | S0 | S1 | S2 | S3 | S4 | S6 | S7 |
|---|---|---|---|---|---|---|---|---|
| Max concurrent workers | 30 | 60 | 90 | 120 | 200 | 400 | 800 | 1600 |
| Max concurrent sessions | 300 | 600 | 900 | 1200 | 2400 | 4800 | 9600 | 19200 |

So "the request limit for the database is 200 and has been reached" is an S3 out of workers, with a
session ceiling twelve times higher. The vCore equivalents are per compute size and hardware
generation: fetch
[vCore resource limits](https://learn.microsoft.com/azure/azure-sql/database/resource-limits-vcore-single-databases)
rather than quoting a remembered number.

The container enforces no such limit; `sys.dm_os_sys_info` reported `max_workers_count` of 512, a
generic engine default unrelated to any compute size and not worth quoting as a service tier.

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

None appeared in the container's `sys.dm_os_wait_stats` during the check: it has no log rate
governance to throttle against, so a bulk load that saturates its log shows as raw log-flush wait
time (`WRITELOG`, or elevated `Log Flush Wait Time` in `sys.dm_os_performance_counters`) instead.

## Sources

- [Resource management](https://learn.microsoft.com/azure/azure-sql/database/resource-limits-logical-server), fetched 2026-08-29.
- [Configure the max degree of parallelism (MAXDOP)](https://learn.microsoft.com/azure/azure-sql/database/configure-max-degree-of-parallelism), fetched 2026-09-03.
- [DTU purchasing model](https://learn.microsoft.com/azure/azure-sql/database/service-tiers-dtu) and [DTU resource limits](https://learn.microsoft.com/azure/azure-sql/database/resource-limits-dtu-single-databases), fetched 2026-09-03: the avg_dtu_percent formula and the worker and session table.
- [sys.dm_os_performance_counters](https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-objects/sys-dm-os-performance-counters-transact-sql), fetched 2026-09-03: the per-service-objective permission split.
- [sys.sp_configure](https://learn.microsoft.com/sql/relational-databases/system-stored-procedures/sp-configure-transact-sql) and [T-SQL differences](https://learn.microsoft.com/azure/azure-sql/database/transact-sql-tsql-differences-sql-server), fetched 2026-09-03: the Applies to list, and `sp_configure` as unsupported.
- [sqlcmd utility](https://learn.microsoft.com/sql/tools/sqlcmd/sqlcmd-utility), fetched 2026-09-03: the -A diagnostic connection and its incompatibility with -G.
- [Troubleshoot common connection issues](https://learn.microsoft.com/azure/azure-sql/database/troubleshoot-common-errors-issues), fetched 2026-08-29: errors 10928, 10929 and 10936.
- `sys.dm_db_resource_stats`, `sys.database_scoped_configurations` and `sys.dm_user_db_resource_governance` reference pages.
- Every container row in the availability table: measured directly against the local engine on 2026-08-29.
