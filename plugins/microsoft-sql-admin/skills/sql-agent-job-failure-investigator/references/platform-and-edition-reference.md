# SQL Server Agent — Platform, Edition, and Version Reference

Authoritative technical reference for where SQL Server Agent jobs are supported, how support
differs by platform and edition, and the metadata used to investigate them. Use this file to
route the investigation to the correct diagnostic path and to avoid running `msdb` Agent queries
against platforms that do not have SQL Server Agent.

Sources: Microsoft Learn — *SQL Server Agent*, *Job automation with SQL Agent jobs (Azure SQL
Managed Instance)*, *Automation in Azure SQL overview (Elastic Jobs vs. SQL Agent)*.

## 1. Platform support matrix

| Platform | SQL Server Agent | Notes | Automation alternative when Agent is absent |
| --- | --- | --- | --- |
| SQL Server on-premises (Enterprise, Standard, Web, Developer, Evaluation, BI) | Yes | Full feature set. Agent is a Windows service. | — |
| SQL Server Express / Express with Advanced Services / LocalDB | No | SQL Server Agent is **not included**. The service is absent/disabled and jobs cannot run. | Windows Task Scheduler + `sqlcmd`; or schedule from another full instance |
| SQL Server on Azure VM (IaaS) | Yes | Identical to on-premises for the installed edition (Express on a VM still has no Agent). | — |
| Azure SQL Managed Instance (PaaS) | Yes (most features) | Agent is always running and its settings are read-only. See limitations in §4. | Elastic Jobs can also target MI databases |
| Azure SQL Database (single database, elastic pool) | No | SQL Server Agent is not available. | **Elastic Jobs** (job automation service for Azure SQL Database) |
| Azure Synapse Analytics — dedicated SQL pool | No | No SQL Server Agent. | Synapse/ADF **pipelines with recurring triggers** |
| Azure Synapse Analytics — serverless SQL pool | No | No SQL Server Agent. | Pipelines / Azure Data Factory |
| SQL database in Microsoft Fabric | No | No SQL Server Agent and no Elastic Jobs. | Fabric **pipelines / Data Factory**, Spark jobs/notebooks |

> Key rule: SQL Server Agent exists only on **SQL Server (non-Express)** and **Azure SQL Managed
> Instance**. Everywhere else, do not query `msdb` Agent tables — route to the alternative.

## 2. Editions and `EngineEdition` detection

`SELECT SERVERPROPERTY('EngineEdition')` is the most reliable way to identify the platform because
it is consistent across versions and does not depend on host name or IP inference.

| `EngineEdition` | Platform / edition family | SQL Server Agent |
| ---: | --- | --- |
| 1 | Personal / Desktop Engine (legacy; not returned by SQL Server 2005+) | n/a |
| 2 | Standard (returned for **Standard**, **Web**, **Business Intelligence**) | Yes |
| 3 | Enterprise (returned for **Enterprise**, **Developer**, **Evaluation**) | Yes |
| 4 | Express (returned for **Express**, **Express with Advanced Services**, **LocalDB**) | **No** |
| 5 | Azure SQL Database | No (use Elastic Jobs) |
| 6 | Azure Synapse Analytics — dedicated SQL pool | No |
| 8 | Azure SQL Managed Instance | Yes (see §4) |
| 9 | Azure SQL Edge | No |
| 11 | Azure Synapse serverless SQL pool (also surfaced by Fabric Warehouse / SQL analytics endpoint) | No |
| 12 | SQL database in Microsoft Fabric | No |

Notes:
- `EngineEdition` values 1–9 are stable and documented. Values 11/12 relate to Synapse serverless
  and Fabric surfaces; **verify on the target instance** before relying on the exact number, as
  Fabric surfaces have evolved.
- Express is edition family 4 and never supports Agent even though the host may otherwise look like
  a normal SQL Server. Always confirm the Agent service exists (see §6) before assuming jobs can run.
- `SERVERPROPERTY('Edition')` and `SERVERPROPERTY('ProductVersion')` give the human-readable edition
  string and version; `@@VERSION` gives the full banner.

## 3. Version applicability (SQL Server and Azure VM)

SQL Server Agent behavior described here applies to all currently supported box versions:

| Version | Internal | Agent | Notable Agent-related changes |
| --- | --- | --- | --- |
| SQL Server 2025 | 17.x | Yes | TDS 8.0 + TLS 1.3 **strict encryption** support for Agent connections |
| SQL Server 2022 | 16.x | Yes | — |
| SQL Server 2019 | 15.x | Yes | `#NOSQLPS` first-line directive to skip auto-loading SQLPS in PowerShell steps |
| SQL Server 2017 | 14.x | Yes | PowerShell subsystem uses SQLPS by default |
| SQL Server 2016 | 13.x | Yes | — |
| 2008–2014 | 10.x–12.x | Yes | Out of mainstream/extended support; core Agent model unchanged |

Deprecated / removed Agent features to be aware of when reading older jobs:
- **ActiveX Script** subsystem — removed in modern versions; treat as legacy.
- **Pager** and **net send** notifications — deprecated; avoid in new work.

## 4. Azure SQL Managed Instance — supported vs. unsupported

SQL Agent on MI is very similar to SQL Server, but the following differences matter during an
investigation:

Supported:
- Job step types: **T-SQL**, **OS command / PowerShell**, **SSIS** (via Azure-SSIS IR / ADF),
  **Transactional replication**.
- Schedules: start when Agent starts (job reactivates after failover), one-time, recurring.
- Email notifications via Database Mail.

Not supported (do not classify these as misconfiguration bugs on MI — they are platform limits):
- Agent settings are **read-only**; `sp_set_agent_properties` is unsupported.
- Enabling/disabling Agent is not possible — **Agent is always running**.
- **Alerts** are not supported.
- **Pager** and **net send** notifications are not supported (email is).
- **Proxies** are not supported.
- **Windows event log** notification is not supported.
- **Idle-CPU** schedule trigger is not supported.
- **Merge replication** and **Queue Reader** job steps are not supported.
- **Analysis Services** steps are not supported.
- Running a script stored as a **file on disk** is not supported.
- Importing external PowerShell modules (e.g., `dbatools`, `dbachecks`) is not supported.
- **PowerShell Core** is not supported.
- **MSX/TSX multiserver administration** is not available.

Fixed behavior on MI:
- Job history retention is fixed: **1,000 total records** and **max 100 records per job**. Older
  history is purged automatically, so absence of history may be a retention limit, not proof a job
  never ran.
- Database Mail profile **must** be named `AzureManagedInstance_dbmail_profile` or the Agent cannot
  send mail.
- Non-sysadmin logins added to a SQL Agent fixed role may need explicit `EXECUTE` grants in
  `master` on `xp_sqlagent_enum_jobs`, `xp_sqlagent_is_starting`, `xp_sqlagent_notify`
  (otherwise error 229).

## 5. Azure SQL Database — Elastic Jobs (the alternative, not SQL Agent)

Azure SQL Database has no SQL Server Agent. Elastic Jobs is the substitute and is a **separate
diagnostic path** — never present its history as SQL Server Agent history.

| Aspect | Elastic Jobs | SQL Server Agent |
| --- | --- | --- |
| Platform | Azure SQL Database | SQL Server, Azure SQL Managed Instance |
| Target scope | Any number of databases across logical servers, subscriptions, regions (enumerated at run time) | Databases in the same instance as the Agent (MSX/TSX for multi-server on SQL Server only) |
| APIs / tools | T-SQL, PowerShell, REST, Azure portal, ARM | T-SQL, PowerShell, SSMS |
| Metadata | Job agent database (`jobs`, `job_versions`, `job_steps`, `job_executions`, target groups) | `msdb` Agent tables (§7) |

## 6. Agent service state (SQL Server / Azure VM only)

- The Agent service is **disabled by default** after install unless autostart was chosen.
- Default instance service name: `SQLSERVERAGENT`. Named instance: `SQLAgent$<instancename>`.
- Detect state with `sys.dm_server_services` (requires `VIEW SERVER STATE`), filtering on
  `servicename LIKE 'SQL Server Agent%'` or `filename LIKE '%SQLAGENT%'`.
- `sys.dm_server_services` is **not available on Azure SQL Managed Instance**; querying it there
  fails with *Invalid object name*. Restrict the read to `EngineEdition` 2 or 3. On Managed
  Instance the Agent service is platform-managed and always running (§4), so there is no service
  state to check.
- Failover cluster instances (FCI): jobs running at the moment of failover **do not resume** on the
  new node; they are logged as started with no completion/failure entry and can appear to never end.

## 7. `msdb` Agent metadata (investigation surface)

All read with three-part names (`msdb.dbo.<table>`). Core tables:

| Table | Purpose |
| --- | --- |
| `sysjobs` | Job definitions (name, owner_sid, enabled, category_id) |
| `sysjobsteps` | Steps: subsystem, `database_name`, `command`, proxy_id, retries, on_success/on_fail actions |
| `sysjobschedules` | Links jobs to schedules; cached `next_run_date`/`next_run_time` |
| `sysschedules` | Schedule definitions (`freq_type`, `freq_interval`, subday settings, active window) |
| `sysjobhistory` | Outcome history; `step_id = 0` is the job-level outcome row |
| `sysjobactivity` | Current/most-recent run per session (start/stop, last executed step) |
| `syssessions` | Agent sessions; latest `session_id` identifies the current Agent session |
| `sysjobservers` | Job ↔ server association and last run outcome |
| `syscategories` | Job categories |
| `sysoperators` | Notification operators (email/pager/netsend) |
| `sysproxies`, `sysproxylogin`, `sysproxysubsystem`, `syssubsystems` | Proxy/credential/subsystem config (not on MI) |
| `sysalerts`, `sysnotifications` | Alerts and operator notifications (alerts not on MI) |
| `systargetservers`, `systargetservergroups`, `sysdownloadlist` | MSX/TSX multiserver (SQL Server only) |

Helpful stored procedures: `sp_help_job`, `sp_help_jobhistory`, `sp_help_jobactivity`,
`sp_start_job`, `sp_stop_job`, `sp_update_job`, `sp_add_operator`, `sp_send_dbmail`.

## 8. Status and schedule code reference

`sysjobhistory.run_status`:

| Value | Meaning |
| ---: | --- |
| 0 | Failed |
| 1 | Succeeded |
| 2 | Retry |
| 3 | Canceled |
| 4 | In progress |

`sysschedules.freq_type`:

| Value | Meaning |
| ---: | --- |
| 1 | One time |
| 4 | Daily |
| 8 | Weekly |
| 16 | Monthly (day of month) |
| 32 | Monthly relative (e.g., 2nd Tuesday) |
| 64 | Start automatically when SQL Server Agent starts |
| 128 | Start when the computer is idle |

`sysschedules.freq_subday_type`:

| Value | Meaning |
| ---: | --- |
| 1 | At the specified time |
| 2 | Every N seconds |
| 4 | Every N minutes |
| 8 | Every N hours |

Encodings to remember:
- `sysjobhistory.run_duration` and `run_time` use `HHMMSS` integer encoding; `run_date` is
  `YYYYMMDD`. Convert with `msdb.dbo.agent_datetime(run_date, run_time)`.
- `run_duration` can exceed six digits for runs longer than 24 hours.

## 9. Security roles (msdb)

| Role | Capability |
| --- | --- |
| `sysadmin` (server) | Full control over all Agent objects |
| `SQLAgentUserRole` | Manage only owned jobs; limited visibility |
| `SQLAgentReaderRole` | Read all jobs plus SQLAgentUserRole rights |
| `SQLAgentOperatorRole` | Read/execute all jobs, manage own, limited multiserver |

A login in none of these roles (and not `sysadmin`) cannot use SQL Server Agent. History visibility
gaps during investigation are frequently a permissions issue rather than missing data.

## 10. Job step subsystems

| Subsystem | On SQL Server | On Azure SQL MI |
| --- | --- | --- |
| Transact-SQL (`TSQL`) — no proxy; uses `EXECUTE AS` owner context | Yes | Yes |
| Operating System (`CmdExec`) | Yes | Yes (PowerShell/OS command; no on-disk script files) |
| PowerShell | Yes | Yes (Windows PowerShell only; no PS Core, no external modules) |
| SSIS package execution | Yes | Yes (via Azure-SSIS IR) |
| Replication: Transaction-Log Reader / Snapshot / Distribution | Yes | Yes (transactional replication) |
| Replication: Merge / Queue Reader | Yes | **No** |
| Analysis Services Command / Query | Yes | **No** |
| ActiveX Script (legacy/removed) | Legacy | No |

For Transact-SQL steps there is no subsystem/proxy: the step runs as the **job owner** (or under
the Agent service context when the owner is a member of `sysadmin`).
