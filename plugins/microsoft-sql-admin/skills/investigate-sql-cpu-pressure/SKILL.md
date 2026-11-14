---
name: investigate-sql-cpu-pressure
description: "Use when CPU is high on SQL Server or Azure SQL (alerts, throttling, SOS_SCHEDULER_YIELD waits) and the user wants the queries responsible. For a broad resource snapshot, use `resource-usage-sqlserver`."
argument-hint: "[TopN] [CpuThresholdPct] [ConfirmLookbackMinutes] [HistoryLookbackHours] [CpuThresholdMs] [MinExecutionCount] [MinTotalWorkerTimeUs]"
---

# CPU Pressure Investigation

## Purpose

This is the **primary entry point** for investigating CPU pressure and high CPU consumption in
SQL Server and Azure SQL. Use when a user reports:
- High CPU usage or CPU % alerts
- Queries running slowly due to scheduler pressure
- `SOS_SCHEDULER_YIELD`, `THREADPOOL`, or `CXPACKET` waits
- Azure SQL DTU/vCore CPU throttling

This skill orchestrates a layered investigation:
1. Checking edition-appropriate CPU signals (resource stats on Azure SQL; scheduler snapshot on SQL Server)
2. Identifying real-time CPU consumers and their wait types
3. Shortlisting active offender hashes for targeted SQL text and plan analysis
4. Reviewing historical plan-cache or database-scoped Query Store data for CPU consumers
5. Detecting memory-grant waits and reduced grants that may contribute to spills
6. Identifying plan quality smells (implicit conversions, spills, missing-index hints, key lookups, and scalar UDFs) by inspecting live plan XML
7. **Conditional**: when the evidence points to specific workload queries, retrieving and analyzing the full SQL text and cached plan for the top offending `query_hash` values to produce concrete tuning recommendations

## Required tools

- A read-only SQL query tool connected to the target server and database. Prefer, in order: the SQL
  Tools MCP server that ships with the `microsoft-sql-admin` plugin
  (`mssql_list_database_connections`, `mssql_connect_database`, then `mssql_execute_query`); any
  other SQL tool the agent host provides for running T-SQL and reading result sets;
  [`sqlcmd`](https://learn.microsoft.com/sql/tools/sqlcmd/sqlcmd-utility) from a terminal. If the
  SQL Tools MCP server is not connected or lists no connections, follow the `sql-tools-mcp-setup`
  skill, which asks before installing or configuring anything. If no SQL tool can be made available,
  provide the T-SQL for the user to run and ask for the results.
- Least privilege: connect that tool with a diagnostic login that cannot write, for example one that
  holds only `VIEW SERVER PERFORMANCE STATE` (`VIEW SERVER STATE` before SQL Server 2022) or, on Azure
  SQL Database, `VIEW DATABASE PERFORMANCE STATE` or `##MS_ServerStateReader##`, plus any other read
  permission these queries need. A tool is only as read-only as the login it connects with.

## Prerequisites

- Use the existing target database connection. No caller arguments or evidence are required:
  apply the parameter defaults and start with Step 0. If the query fails, report the actual
  connectivity or permission error; do not treat an empty or malformed tool response as proof
  that there is no connection.
- Steps 2, 3, 5, and 6 query live DMVs — run them in sequence while CPU pressure is active.
- SQL Server server-level DMVs require `VIEW SERVER STATE` before SQL Server 2022 or
  `VIEW SERVER PERFORMANCE STATE` on SQL Server 2022+; Managed Instance requires
  `VIEW SERVER STATE`. Azure SQL Database and Fabric SQL Database resource stats
  accept `VIEW DATABASE PERFORMANCE STATE` or the broader `VIEW DATABASE STATE`.
  Do not request a broader database-state grant when performance-state access suffices.
  On SQL Server 2022+, the database-scoped Query Store path
  uses `VIEW DATABASE PERFORMANCE STATE` instead of server-level permissions. Report
  permission or Query Store availability failures as evidence gaps, not as zero CPU.

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| TopN | 10 | Number of top queries/sessions to return in each step |
| CpuThresholdPct | 80 | CPU % threshold for Azure SQL Database and Managed Instance resource stats (not applicable to an on-prem scheduler snapshot) |
| ConfirmLookbackMinutes | 10 | Window (minutes) for Azure SQL resource-statistics checks |
| HistoryLookbackHours | 12 | Lookback window (hours) for recently active plan-cache or Query Store entries |
| CpuThresholdMs | 1000 | Minimum `cpu_time` (ms) for a request to be included in real-time steps |
| MinExecutionCount | 10 | Minimum number of executions a plan must have to appear in Step 4 results |
| MinTotalWorkerTimeUs | 1000000 | Minimum cumulative `total_worker_time` (microseconds) for a plan to appear in Step 4 results (default = 1 second) |

## Investigation Workflow

**Mechanics:** before passing any query to the SQL query tool, substitute every
`{{Param}}` placeholder with the corresponding value from the Parameters table above. The tool
does not perform substitution. Validate every caller-supplied override before substitution:
accept only a JSON integer or digit-only string in these ranges: `TopN` 1–100,
`CpuThresholdPct` 0–100, `ConfirmLookbackMinutes` 1–1440, `HistoryLookbackHours` 1–8760,
`CpuThresholdMs` 0–2147483647, `MinExecutionCount` 0–2147483647, and
`MinTotalWorkerTimeUs` 0–9223372036854775807. Reject invalid or out-of-range overrides and
never concatenate caller text, signs, decimal points, or expressions into SQL.

**Loading sub-resources.** When a step names a file, read it from `references/` relative to this `SKILL.md` before executing the step.

**Decision flow — follow this exactly, do not run extra steps:**

1. Always run **Step 0** to detect the engine edition, target identity, and effective
   diagnostic permissions. Stop on unsupported editions (6 and 11) or a connection/query
   failure; include the actual reason in the report.
2. Choose the path using **effective** permissions, not the caller's stated role:
   - **SQL Server / IaaS / Edge:** on major version 16 or later, use the
     server-DMV path only if `can_view_server_performance_state = 1`; on older
     versions use it if `can_view_server_state = 1`. Otherwise, on major
     version **13 or later**, use the **database-scoped Query Store path**
     if either `can_view_database_performance_state = 1` or
     `can_view_database_state = 1`. SQL Server 2014 (major version 12) has no Query Store;
     when server access is also unavailable, report that
     limitation instead of running the Query Store query.
   - **Managed Instance (8):** use the server-DMV path if
     `can_view_server_state = 1`. Otherwise, use the database-scoped Query
     Store path when either `can_view_database_performance_state = 1` or
     `can_view_database_state = 1`, and check the actual Query Store state
     before collecting evidence. Managed Instance with major_version NULL or 12
     still checks Query Store; do not apply the boxed SQL Server 2014 version
     gate. A database performance grant does **not** imply access to instance
     schedulers, requests, or plan cache.
   - **Azure SQL Database / Fabric SQL Database (5/12):** if either
     `can_view_database_performance_state = 1` or `can_view_database_state = 1`,
     run the Azure resource-stats Step 1. Use the database-scoped Query Store path
     for historical workload evidence under the same permission check.
     Azure `major_version = 12` is not boxed SQL Server 2014;
     do not apply its version gate.
     If both database permission flags are 0, skip these database diagnostics
     and report an access evidence gap. If neither is 1 and either is NULL, use
     the unknown-permission rule below.
     Skip live-request Steps 2/3/5/6 because those only see the current session.
     Do not route solely from `VIEW DATABASE STATE` to `sys.dm_exec_query_stats`:
     Basic, S0, S1, and elastic-pool databases require administrator access or
     `##MS_ServerStateReader##` for that DMV.
   - If permission checks are NULL (unknown), try the appropriate edition-specific
     query; report its actual result or error. If neither path has a usable permission,
     stop with an explicit access evidence gap, not "no CPU pressure."
3. **Server-DMV path:** run the edition-specific Step 1 and Steps 2–6.
   On SQL Server / MI, run Steps 2 → 3 → 4 → 5 → 6
   regardless of the Step 1 result: a scheduler snapshot or a lagging/low MI CPU
   average cannot rule out active pressure. If a later DMV fails, record its error
   and continue with the other steps. Never treat a tool error as 0 rows.
4. **Azure resource-stats + database-scoped Query Store path, or database-scoped
   Query Store fallback:** load and execute
   `references/step-4-query-store-cpu.md`. Check Query Store state first. If disabled
   or the query fails, report an evidence gap; do not turn it on or request server
   permissions on the user's behalf. When enabled, rank recent database queries
   by recorded CPU, then conditionally run its Step 7 query for actual offenders.
   Retain any Azure resource-stats Step 1 result collected under the permission
   rules above, even if Query Store is unavailable. If Step 1 fails, record its actual
   error and continue with Query Store; permission checks do not guarantee query success.
   Do **not** run the
   server-DMV Steps 2–6 or the server-plan-cache Step 7 query. Query Store
   measures captured query workload, **not instance CPU %**:
   no rows or low CPU in the selected window cannot disprove a reported CPU alert.
5. After collection, use the **Root Cause Decision Tree** only when live wait evidence
   supports it; for Query Store-only evidence, identify captured CPU consumers or
   say the root cause is inconclusive. Assemble the final report using
   `references/report-template.md`, omitting unexecuted sections.

Step results carry forward: each step's "Capture for downstream use" bullet names the columns
later steps need (especially the `(query_hash, query_plan_hash)` pairs that feed Step 7).

---

### Step 0: Identify the Target and Engine

Execute via the SQL query tool. Use `engine_edition` to select Step 1; use the returned
identities in the final report only when available. Permission flags describe the effective
query identity, not necessarily all access the underlying connection might have. No
user-supplied connection evidence is needed.

```sql
SELECT
      CONVERT(int, SERVERPROPERTY('EngineEdition'))          AS engine_edition
    , CONVERT(int, SERVERPROPERTY('ProductMajorVersion'))    AS major_version
    , CONVERT(nvarchar(128), SERVERPROPERTY('ServerName'))   AS server_name
    , DB_NAME()                                              AS database_name
    , HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW SERVER STATE')      AS can_view_server_state
    , HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW SERVER PERFORMANCE STATE') AS can_view_server_performance_state
    , HAS_PERMS_BY_NAME(DB_NAME(), 'DATABASE', 'VIEW DATABASE STATE') AS can_view_database_state
    , HAS_PERMS_BY_NAME(DB_NAME(), 'DATABASE', 'VIEW DATABASE PERFORMANCE STATE') AS can_view_database_performance_state;
```

| EngineEdition | Step 1 source |
|---|---|
| 5, 12 | Azure SQL Database / Fabric SQL Database: `sys.dm_db_resource_stats` |
| 8 | Azure SQL Managed Instance: `sys.server_resource_stats` |
| 6, 11 | Synapse / Warehouse: not supported by this workflow; stop |
| other | SQL Server on-prem / IaaS / Edge: `sys.dm_os_schedulers` snapshot |

If the corresponding permission flag is 0 or NULL (unknown under some database-user
impersonation contexts), note that diagnostic visibility may be limited and do not
interpret empty live or cached results as proof that no workload is using CPU.
On older engines that do not recognize `VIEW DATABASE PERFORMANCE STATE`, that flag
may be NULL; `VIEW DATABASE STATE` is sufficient for Query Store on those engines.
Permissions alone are not conclusive: some hosting/impersonation contexts return a module-trust
error even when a query is attempted. Record that error and do not suggest changes to
server trust settings as a routine fix; ask a DBA to verify the supported execution context.
When the tool runs under `EXECUTE AS USER`, granting a permission to the original SQL login
alone does not grant it to the impersonated database principal. Do not output executable
GRANT statements without knowing the actual principal, server version, and security policy.

---

### Step 1: Check CPU Signals

This step belongs to the **server-DMV / Azure resource-stats path only**. Execute **only
the query for the Step 0 engine edition** via the SQL query tool.
For resource stats, a NULL average or `sample_count = 0` means no samples, **not** no pressure.

**Azure SQL Database / Fabric SQL Database (5/12):** database CPU percentage relative to its
service tier limit. `sys.dm_db_resource_stats` is not available on SQL Server or Managed Instance.

```sql
;WITH CteCPULast AS (
    SELECT
          MIN(end_time)            AS window_start_utc
        , MAX(end_time)            AS window_end_utc
        , AVG(avg_cpu_percent)     AS avg_cpu_percent
        , MAX(avg_cpu_percent)     AS max_cpu_percent
        , COUNT(*)                 AS sample_count
    FROM sys.dm_db_resource_stats
    WHERE end_time >= DATEADD(MINUTE, -{{ConfirmLookbackMinutes}}, SYSUTCDATETIME())
)
SELECT * FROM CteCPULast
OPTION (MAXDOP 1);
```

**Azure SQL Managed Instance (8):** instance CPU percentage relative to its service tier.
Stats updates can lag 5–10 minutes; no samples in the selected window is inconclusive.

```sql
SELECT
      MIN(end_time)            AS window_start_utc
    , MAX(end_time)            AS window_end_utc
    , AVG(avg_cpu_percent)     AS avg_cpu_percent
    , MAX(avg_cpu_percent)     AS max_cpu_percent
    , COUNT(*)                 AS sample_count
FROM sys.server_resource_stats
WHERE end_time >= DATEADD(MINUTE, -{{ConfirmLookbackMinutes}}, SYSUTCDATETIME())
OPTION (MAXDOP 1);
```

**SQL Server on-prem / IaaS / Edge:** a single scheduler queue snapshot, **not** a CPU %
measurement or historical confirmation. A zero queue does not rule out CPU-intensive
running queries; proceed to live and plan-cache steps regardless.

```sql
SELECT
      SYSUTCDATETIME()          AS snapshot_utc
    , COUNT(*)                  AS online_schedulers
    , SUM(runnable_tasks_count) AS runnable_tasks
FROM sys.dm_os_schedulers
WHERE status = N'VISIBLE ONLINE'
OPTION (MAXDOP 1);
```

**Capture for downstream use:** source, available percentage and sample count (Azure), or
online schedulers and runnable tasks (SQL Server); note any missing permissions.
On Azure SQL Database and Fabric SQL Database, the resource-stats result is the database
CPU signal; do not infer anything about other sessions from an empty `sys.dm_exec_requests`
query on those platforms.

---

### Step 2: Real-Time Engine Pressure — Requests with CPU-Correlated Waits

Execute via the SQL query tool. Shows active requests with CPU-related or NULL wait types,
cumulative CPU time, elapsed time, and the current wait time.

```sql
SELECT TOP ({{TopN}})
      req.session_id
    , req.request_id
    , req.status
    , req.start_time
    , req.cpu_time                                          AS cpu_time_ms
    , req.total_elapsed_time                                AS elapsed_time_ms
    , req.wait_type
    , req.wait_time                                         AS wait_time_ms
FROM sys.dm_exec_requests  AS req
JOIN sys.dm_exec_sessions  AS s
  ON req.session_id = s.session_id
WHERE req.session_id <> @@SPID
  AND req.group_id   >  1                        -- exclude internal engine work
  AND req.cpu_time   > {{CpuThresholdMs}}         -- meaningful CPU threshold
  AND (
        req.wait_type IN (
            N'SOS_SCHEDULER_YIELD',              -- CPU queueing / scheduler pressure
           -- N'THREADPOOL',                       -- worker thread starvation
           -- N'RESOURCE_SEMAPHORE_QUERY_COMPILE', -- CPU + memory pressure during compile 
            N'CXPACKET',                         -- parallel query synchronization
            N'CXSYNC_CONSUMER',
            N'CXCONSUMER'
        )
        OR req.wait_type IS NULL                 -- runnable / actively running
      )
ORDER BY req.cpu_time DESC, req.wait_time DESC
OPTION (MAXDOP 1);
```

**Typical interpretations:**
- `SOS_SCHEDULER_YIELD` identifies a worker that exhausted its scheduler quantum. Treat
  scheduler pressure as likely only when this aligns with a nonzero runnable queue and
  multiple CPU-intensive requests.
- NULL wait type with high CPU → currently running CPU consumer.
- `CXPACKET` / `CXCONSUMER` / `CXSYNC_CONSUMER` identifies parallel coordination,
  not skew by itself. Confirm skew from per-thread plan evidence before recommending DOP changes.

`cpu_time` is cumulative across workers while `total_elapsed_time` is wall-clock time, so do
not subtract them or compute a wait-to-CPU ratio for parallel requests.

**Capture for downstream use:** the prevalent `wait_type` across the top rows, together with
the scheduler snapshot and plan evidence. Row count of 0 does not establish whether active
sessions exist; still proceed to Steps 3–6.

---

### Step 3: Top Real-Time CPU Consumers — SQL Text and Execution Plans

Load `references/step-3-active-offenders.md` and execute the query inside. It extends Step 2 with
`object_name` and the `query_hash` / `query_plan_hash` pair that feeds Step 7.

**Capture for downstream use:** the `(query_hash, query_plan_hash)` pairs of all returned rows —
these are Step 7 shortlist candidates. Empty result set = no visible live request exceeds
`{{CpuThresholdMs}}` ms of CPU; continue to Step 4 for the historical view.

---

### Step 4: Historical Top CPU Consumers — Plan Cache (Cumulative)

Server-DMV path only (SQL Server / IaaS / Edge and Managed Instance). Load
`references/step-4-historical-plan-cache.md` and execute the query inside. Aggregates
cumulative CPU since each plan was compiled, filtered to recently-active plans. Azure SQL
Database and Fabric SQL Database use the database-scoped Query Store Step 4 instead.

**Capture for downstream use:** the `(query_hash, query_plan_hash)` pairs whose
`worker_time_per_exec_ms` > 1000 or whose `execution_count × worker_time_per_exec_ms` is in the
top tier — Step 7 shortlist candidates.

---

### Step 5: Memory-Grant Waits and Reduced Grants

Load `references/step-5-memory-grants-spills.md` and execute the query inside. Returns only
visible requests that are waiting for a grant or received less than requested. A reduced
grant is a spill risk signal, not proof of a spill; confirm spills in plan XML. An empty
snapshot cannot establish that all grants were sufficient historically.

**Capture for downstream use:** requests with `grant_time IS NULL` (currently waiting) or
`granted_memory_kb < requested_memory_kb` (reduced grant). These feed the report's Step 5
narrative and may also be Step 7 candidates if they expose new `query_hash` values.

---

### Step 6: Plan Smell Detection

Load `references/step-6-plan-smells.md` and execute the query inside. Detects implicit
conversions, tempdb spills, missing-index hints, key lookups, and scalar UDFs in live plans.
Translate each flagged column into a fix using `references/plan-smell-reference.md`.

**Capture for downstream use:** any session with one or more smell flags set — those
`query_hash` values are strong Step 7 candidates because they have both runtime impact and a
concrete known anti-pattern.

---

### Step 7: Targeted Query Text and Plan Analysis (Conditional)

The database-scoped path uses its own Step 7 query in
`references/step-4-query-store-cpu.md`; **never** run the server-plan-cache
query under a database-only grant.

**Trigger — run Step 7 if ANY of the following are true:**
- Step 3 returned one or more active offenders with `cpu_time_ms` above `{{CpuThresholdMs}}`.
- Step 4 returned plans with `worker_time_per_exec_ms` > 1000 ms or very high
  `execution_count × worker_time_per_exec_ms` products.
- Step 6 flagged at least one plan smell on an active session.

If no trigger fires, **skip Step 7** and record "Step 7 skipped — no workload-query signal" in
the report.

If triggered, load `references/step-7-query-text-and-plan-analysis.md` for the
hash-targeted retrieval query (Step 7a) and the text + plan analysis checklist (Step 7b). Use
`references/plan-smell-reference.md` when mapping operators to recommendations.

**Capture for downstream use:** per-query findings + recommended changes for the report's Step 7
section (one block per analyzed `query_hash`).

---

## Root Cause Decision Tree and Next Steps

Classify the dominant signal **before** assembling the report. Pick the branch that matches the
most prevalent `wait_type` in Step 2/3 results (or the "workload-queries-implicated" branch when
Step 7 produced concrete per-query findings — that branch is additive to whichever wait branch
applies). If no sufficient wait or workload evidence is available, report an inconclusive
assessment rather than claiming CPU pressure is absent.

### `SOS_SCHEDULER_YIELD` is prevalent

State: **"`SOS_SCHEDULER_YIELD` shows that workers exhausted their scheduler quantum. This
supports scheduler pressure only when runnable tasks are persistently queued and multiple
CPU-intensive requests are visible; by itself it does not prove saturation."**

Next steps:
1. Review Step 3 to identify the specific queries driving scheduler pressure
2. Inspect the offending plans for unnecessary or inefficient parallelism
3. Review `MAXDOP` and `Cost Threshold for Parallelism` server settings
4. In Azure SQL, check if the service tier CPU limit is being hit (consider scaling up)

### `CXPACKET` / `CXSYNC_CONSUMER` / `CXCONSUMER` is prevalent

State: **"Parallel-query coordination is present. These waits do not prove skew or excessive
DOP; confirm an imbalance from per-thread runtime plan evidence before naming parallel skew
as the cause."**

Next steps:
1. Identify the query from Step 3 and inspect the parallel plan for skewed operators
2. Test with a lower `MAXDOP` hint on offending queries
3. Update statistics on tables with skewed data distributions
4. Consider `MAXDOP` resource governor workload groups if the issue affects a class of workloads

### Wait type is NULL with high CPU

State: **"The request was actively running when sampled and had already accumulated high CPU.
Use the query and plan evidence to distinguish normal work from a regression or inefficient
plan."**

Next steps:
1. Compare `worker_time_per_exec_ms` from Step 4 against Step 3 real-time values — a sudden
   increase suggests a plan regression
2. Check Plan Count from Query Store for the same queries (run the slow-query-investigation
   skill if Query Store is enabled)
3. Review `total_logical_reads` from Step 4 — high values indicate table scans or inefficient
   access patterns that drive CPU via repeated row evaluations
4. Consider forced plans via `sp_query_store_force_plan` for known-good plans

### Workload queries are implicated (any wait pattern above with a clear top-offender shortlist)

Whenever Steps 3, 4, or 6 surface specific `query_hash` values that dominate CPU — regardless of
which wait type is on top — **execute Step 7** to retrieve the SQL text and cached plan for those
hashes and produce per-query recommendations. Infrastructure-level fixes (MAXDOP, scaling,
resource governor) and query-level fixes (indexing, predicate rewrites, stats updates) are
complementary; do not stop at the wait-type classification when the data names the offenders.

---

## Final Report

After the available data-collection steps, load `references/report-template.md` and fill
in each section supported by actual results. Use "inconclusive" for root cause when
diagnostic access is insufficient. When the host requires a structured System Agent response, report
missing access in `evidenceGaps`. Prefer a concise plain-text summary and text-only
sections for available findings: each Text section must have a nonempty `body` and
`table`, `query`, and `chart` must all be null. If a section has no supported content,
omit it rather than emitting an empty placeholder. Empty `sections` arrays are valid.
