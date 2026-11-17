# Active Connections Analysis — SQL Queries

Run all queries with the SQL query tool. Replace {{parameter}} placeholders with values from the skill parameters.

### Step 1: Platform Detection

> Execute with the SQL query tool. Detects engine edition and validates platform support.

```sql
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

SELECT TOP ({{TopN}})
      CAST(SERVERPROPERTY('Edition') AS NVARCHAR(128))           AS sql_edition
    , CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(128))    AS sql_version
    , CASE @EngineEdition
        WHEN 5  THEN 'Azure SQL Database'
        WHEN 8  THEN 'Azure SQL Managed Instance'
        WHEN 12 THEN 'Fabric SQL Database'
        WHEN 6  THEN 'Azure Synapse Analytics - Dedicated SQL pool (not supported by this skill)'
        WHEN 11 THEN 'Azure Synapse serverless SQL pool / Fabric Warehouse (not supported by this skill)'
        ELSE         'SQL Server (on-prem / IaaS)'
      END                                                        AS engine_type
    , @EngineEdition                                             AS engine_edition
    , CASE WHEN @EngineEdition IN (6, 11) THEN 1 ELSE 0 END     AS is_unsupported_dw
    , (SELECT COUNT(*) FROM sys.dm_exec_sessions WHERE is_user_process = 1) AS total_user_sessions
    , (SELECT COUNT(*) FROM sys.dm_exec_connections)             AS total_connections
    OPTION (MAXDOP 1);

IF @EngineEdition IN (6, 11)
BEGIN
    SELECT 'This skill is not designed for Azure Synapse Analytics or Fabric Warehouse/Lakehouse endpoints (EngineEdition 6 or 11). Session DMVs and connection patterns differ significantly in these environments. Note: Fabric SQL Database (EngineEdition 12) is supported.' AS unsupported_message;
    RETURN;
END
```

**What to do:**
| Assessment | Action |
|------------|--------|
| `is_unsupported_dw = 1` | **Stop** — this skill does not apply to Azure Synapse (edition 6) or Synapse serverless / Fabric Warehouse (edition 11). Fabric SQL Database (edition 12) is supported. |
| `total_user_sessions` very high (> 500) | Potential connection management issue — proceed to all steps for detailed analysis |
| Any other edition | Proceed to Step 2 |

---

### Step 2: Active User Connections by Database

> Execute with the SQL query tool. Shows connection counts grouped by database, login, and program.

```sql
SELECT TOP ({{TopN}})
      DB_NAME(s.database_id)                                    AS database_name
    , s.login_name
    , s.program_name
    , COUNT(*)                                                   AS connection_count
    , SUM(CASE WHEN s.status = 'running' THEN 1 ELSE 0 END)     AS active_running
    , SUM(CASE WHEN s.status = 'sleeping' THEN 1 ELSE 0 END)    AS sleeping
    , MIN(s.login_time)                                          AS earliest_login
    , MAX(s.last_request_end_time)                               AS latest_request
FROM sys.dm_exec_sessions AS s
WHERE s.is_user_process = 1
  AND s.session_id <> @@SPID
GROUP BY s.database_id, s.login_name, s.program_name
ORDER BY COUNT(*) DESC
OPTION (MAXDOP 1);
```

**Interpreting results:**
- `connection_count` → total sessions from this login/program/database combination.
- `active_running` vs `sleeping` → ratio shows how many connections are actually working vs idle.
- A single program with many connections may indicate connection pool exhaustion or a connection leak.

**What to do:**
| Finding | Recommendation |
|---------|----------------|
| Single login/program with very high `connection_count` (> 50) | Possible connection leak or pool misconfiguration — check application connection string for max pool size |
| Most connections `sleeping` with very few `active_running` | Normal pooling behavior if counts are reasonable; flag if total exceeds expected pool size |
| Connections to unexpected databases | Review application configuration — may indicate misrouted connections |
| No user connections | Database may be inaccessible or application is down |

---

### Step 3: Idle Session Analysis

> Execute with the SQL query tool. Identifies sleeping sessions that have been idle longer than
the threshold. Long-idle sessions waste resources and may hold locks or prevent log truncation.

```sql
SELECT TOP ({{TopN}})
      s.session_id
    , s.login_name
    , s.host_name
    , s.program_name
    , DB_NAME(s.database_id)                                    AS database_name
    , s.status
    , s.login_time
    , s.last_request_start_time
    , s.last_request_end_time
    , DATEDIFF(MINUTE, COALESCE(s.last_request_end_time, s.last_request_start_time), GETDATE()) AS idle_minutes
    , s.memory_usage * 8                                        AS memory_usage_kb
    , s.open_transaction_count
    , CASE
        WHEN s.open_transaction_count > 0
            THEN 'CRITICAL — idle with open transaction (blocks log truncation)'
        WHEN DATEDIFF(MINUTE, COALESCE(s.last_request_end_time, s.last_request_start_time), GETDATE()) > {{IdleThresholdMinutes}} * 4
            THEN 'Warning — very long idle session'
        ELSE 'Idle beyond threshold'
      END                                                        AS idle_assessment
FROM sys.dm_exec_sessions AS s
WHERE s.is_user_process = 1
  AND s.session_id <> @@SPID
  AND s.status = 'sleeping'
  AND DATEDIFF(MINUTE, COALESCE(s.last_request_end_time, s.last_request_start_time), GETDATE()) >= {{IdleThresholdMinutes}}
ORDER BY
    s.open_transaction_count DESC,
    DATEDIFF(MINUTE, COALESCE(s.last_request_end_time, s.last_request_start_time), GETDATE()) DESC
    OPTION (MAXDOP 1);
```

**Interpreting results:**
- `idle_minutes` → how long since the session's last request completed. Sessions idle for hours may be leaked connections.
- `open_transaction_count > 0` → **critical** — an idle session holding an open transaction prevents log truncation and may hold locks.
- `memory_usage_kb` → memory consumed by the idle session. Usually minimal, but some frameworks cache data.

**What to do:**
| Finding | Recommendation |
|---------|----------------|
| Idle session with `open_transaction_count > 0` | **Urgent** — application left a transaction uncommitted. Identify the app, fix the code, and consider killing the session if safe |
| Sessions idle > 4 hours | Likely leaked connections — review application dispose/close patterns; enable connection lifetime in the pool |
| Many idle sessions from same `program_name` | Connection pool not reclaiming connections — check pool settings (min/max size, connection lifetime) |
| High `memory_usage_kb` on idle session | Session caching data — investigate the application framework |

---

### Step 4: Connection Pooling Behavior Patterns

> Execute with the SQL query tool. Analyzes connection pooling patterns by examining how
connections are distributed across client applications and whether pool sizes appear healthy.

```sql
SELECT TOP ({{TopN}})
      s.program_name
    , s.login_name
    , COUNT(*)                                                   AS total_sessions
    , SUM(CASE WHEN s.status = 'running' THEN 1 ELSE 0 END)     AS running
    , SUM(CASE WHEN s.status = 'sleeping' THEN 1 ELSE 0 END)    AS sleeping
    , SUM(CASE WHEN s.status = 'dormant' THEN 1 ELSE 0 END)     AS dormant
    , CAST(SUM(CASE WHEN s.status = 'sleeping' THEN 1.0 ELSE 0 END)
        / NULLIF(COUNT(*), 0) * 100 AS DECIMAL(5,1))            AS idle_pct
    , MIN(s.login_time)                                          AS oldest_connection
    , MAX(s.login_time)                                          AS newest_connection
    , DATEDIFF(MINUTE, MIN(s.login_time), MAX(s.login_time))    AS pool_age_span_min
    , AVG(s.memory_usage) * 8                                    AS avg_memory_kb
    , SUM(s.open_transaction_count)                              AS total_open_txns
FROM sys.dm_exec_sessions AS s
WHERE s.is_user_process = 1
  AND s.session_id <> @@SPID
GROUP BY s.program_name, s.login_name
ORDER BY COUNT(*) DESC
OPTION (MAXDOP 1);
```

**Interpreting results:**
- `idle_pct > 90%` with high `total_sessions` → pool is oversized or connections are being leaked.
- `pool_age_span_min` very small (< 5) with many sessions → pool recently re-created (app restart or pool reset).
- `running` consistently near `total_sessions` → pool may be at capacity; workload may need more connections.
- `total_open_txns > 0` → some connections have uncommitted transactions.

**What to do:**
| Finding | Recommendation |
|---------|----------------|
| `idle_pct > 90%` + `total_sessions > 30` | Oversized pool — reduce `Max Pool Size` in connection string or set `Connection Lifetime` to reclaim idle connections |
| `running` ≈ `total_sessions` | Pool exhaustion — increase `Max Pool Size` or optimize query duration to release connections faster |
| `total_open_txns > 0` in sleeping sessions | Application not committing/rolling back — review transaction management in the code |
| Single `program_name` dominating connections | Review if this application is the expected primary consumer; check for connection leaks |
| `pool_age_span_min = 0` with many sessions | All connections created simultaneously — likely app restart or pool cleared event |

---

### Step 5: Client IP / Hostname Distribution and Connection Properties

> Execute with the SQL query tool. Shows which client machines are connecting, how many
sessions each has, and connection-level properties (transport, encryption, authentication).
Useful for identifying connection concentration, unexpected clients, or insecure connections.

> **Azure SQL note:** `client_net_address` may show the gateway IP rather than the actual client IP
on Azure SQL Database. `host_name` from `dm_exec_sessions` is more reliable for client identification.

```sql
SELECT TOP ({{TopN}})
      s.host_name
    , c.client_net_address
    , s.login_name
    , COUNT(*)                                                   AS session_count
    , SUM(CASE WHEN s.status = 'running' THEN 1 ELSE 0 END)     AS active_running
    , SUM(CASE WHEN s.status = 'sleeping' THEN 1 ELSE 0 END)    AS sleeping
    , MIN(s.login_time)                                          AS earliest_login
    , MAX(s.last_request_end_time)                               AS latest_activity
    , MAX(c.net_transport)                                       AS net_transport
    , MAX(c.protocol_type)                                       AS protocol_type
    , MIN(c.auth_scheme)                                         AS auth_scheme
    , MIN(c.encrypt_option)                                      AS encrypt_option
    , MAX(CAST(c.protocol_version AS VARCHAR(20)))               AS tds_protocol_version
FROM sys.dm_exec_sessions     AS s
LEFT JOIN sys.dm_exec_connections AS c
  ON s.session_id = c.session_id
WHERE s.is_user_process = 1
  AND s.session_id <> @@SPID
GROUP BY s.host_name, c.client_net_address, s.login_name
ORDER BY COUNT(*) DESC
OPTION (MAXDOP 1);
```

**Interpreting results:**
- `session_count` per client → shows connection concentration. A single client with many sessions may indicate a busy app server or connection issue.
- `client_net_address` → actual IP address of the connecting client. Multiple hosts from same IP may indicate a load balancer or shared NAT.
- `encrypt_option = FALSE` → connection is **not encrypted**. This is a security concern, especially in production.
- `auth_scheme = SQL` → using SQL authentication (username/password). Consider migrating to Windows/Entra authentication.
- `net_transport` → connection transport protocol (TCP, Shared Memory, Named Pipe). Shared Memory is local-only.
- `tds_protocol_version` → TDS version indicates client driver age. Very old versions may lack features or have known issues.
- All sessions `sleeping` from a client → that client may be idle or have a connection leak.

**What to do:**
| Finding | Recommendation |
|---------|----------------|
| Single client with disproportionate session count | Check if the application on that host is leaking connections or has an oversized pool |
| Unknown `host_name` or `client_net_address` | Unexpected client — verify it's authorized and expected |
| `encrypt_option = FALSE` | Connection not encrypted — enable `Encrypt=True` in the client connection string or enforce encryption server-side |
| `auth_scheme = SQL` in production | SQL auth uses passwords — consider migrating to Windows Authentication or Microsoft Entra ID for stronger security |
| Old `tds_protocol_version` | Client is using an old driver — recommend updating to the latest ODBC/OLE DB/SqlClient driver |
| `net_transport = Shared Memory` | Local connection — expected for management tools on the server host |
| `client_net_address = '<local machine>'` | Connection from the SQL Server host itself — usually management tools or local apps |

---

### Step 6: Sessions with Open Transactions

> Execute with the SQL query tool. Identifies sessions holding open transactions. Open
transactions can block other queries, prevent log truncation, and cause log file growth.

```sql
SELECT TOP ({{TopN}})
      s.session_id
    , s.login_name
    , s.host_name
    , s.program_name
    , DB_NAME(s.database_id)                                    AS database_name
    , s.status                                                   AS session_status
    , at.transaction_begin_time
    , DATEDIFF(SECOND, at.transaction_begin_time, GETDATE())    AS txn_duration_sec
    , dt.database_transaction_log_bytes_used                    AS log_bytes_used
    , CAST(dt.database_transaction_log_bytes_used / 1048576.0
        AS DECIMAL(18,2))                                       AS log_mb_used
    , at.transaction_type
    , CASE at.transaction_state
        WHEN 0 THEN 'Initializing'
        WHEN 1 THEN 'Initialized'
        WHEN 2 THEN 'Active'
        WHEN 3 THEN 'Ended (read-only)'
        WHEN 4 THEN 'Commit started'
        WHEN 5 THEN 'Prepared'
        WHEN 6 THEN 'Committed'
        WHEN 7 THEN 'Rolling back'
        WHEN 8 THEN 'Rolled back'
      END                                                        AS transaction_state
    , r.query_hash
    , CASE
        WHEN s.status = 'sleeping' AND DATEDIFF(SECOND, at.transaction_begin_time, GETDATE()) > {{OpenTxnThresholdSeconds}}
            THEN 'CRITICAL — idle session with long-running open transaction'
        WHEN DATEDIFF(SECOND, at.transaction_begin_time, GETDATE()) > {{OpenTxnThresholdSeconds}}
            THEN 'Warning — long-running transaction'
        ELSE 'Active transaction within threshold'
      END                                                        AS txn_assessment
FROM sys.dm_tran_active_transactions         AS at
JOIN sys.dm_tran_session_transactions        AS st
  ON at.transaction_id = st.transaction_id
JOIN sys.dm_exec_sessions                    AS s
  ON st.session_id = s.session_id
LEFT JOIN sys.dm_tran_database_transactions  AS dt
  ON at.transaction_id = dt.transaction_id
  AND dt.database_id = s.database_id
LEFT JOIN sys.dm_exec_requests               AS r
  ON s.session_id = r.session_id
WHERE s.session_id <> @@SPID
  AND s.is_user_process = 1
ORDER BY
    CASE WHEN s.status = 'sleeping' THEN 0 ELSE 1 END,
    DATEDIFF(SECOND, at.transaction_begin_time, GETDATE()) DESC
    OPTION (MAXDOP 1);
```

**Interpreting results:**
- `session_status = 'sleeping'` + open transaction → **most dangerous** — idle session holding transaction, likely a forgotten commit.
- `txn_duration_sec` → how long the transaction has been open. Transactions held for minutes in OLTP are suspicious.
- `log_mb_used` → log space consumed by this transaction. High values with long duration = log file growth risk.
- `transaction_state = 'Active'` for a long time → the application started a transaction but hasn't committed or rolled back.

**What to do:**
| Finding | Recommendation |
|---------|----------------|
| Sleeping session with open transaction > 5 min | **Urgent** — likely orphaned transaction. Identify the application, fix the commit/rollback logic. Kill session if safe: `KILL <session_id>` |
| Active transaction with high `log_mb_used` | Large uncommitted change — check if the operation should be batched into smaller transactions |
| Many sessions with open transactions | Systemic issue — review application transaction management (missing `using` blocks, explicit commit/rollback patterns) |
| Transaction in state 7 (Rolling back) for a long time | Rollback in progress — let it complete. Estimate remaining time from progress |

---

### Step 7: MARS, Connection Policy, and Client Connection Diagnostics

> Execute with the SQL query tool. Identifies connections using Multiple Active Result Sets (MARS),
detects connection policy (Proxy vs Redirect on Azure SQL), and diagnoses client-side connection issues.
MARS allows multiple active requests on a single connection, which can cause contention, transaction scope
confusion, and unexpected blocking.

> **Why MARS matters:** When MARS is enabled, a single connection can have multiple interleaved requests.
This can cause:
> - Transaction scope confusion (all requests share the same transaction)
> - Blocking between requests on the same connection
> - Memory overhead from maintaining multiple result sets
> - Difficult-to-debug issues where one result set blocks another

> **Connection Policy (Azure SQL):** Azure SQL Database supports Proxy and Redirect connection policies.
Redirect gives better latency by connecting directly to the node hosting the database, but requires
outbound ports 11000-11999 on the client side. If clients cannot open those ports, they fall back to
Proxy (all traffic through port 1433 gateway), which adds latency.

```sql
SELECT TOP ({{TopN}})
      c.session_id
    , s.login_name
    , s.host_name
    , s.program_name
    , DB_NAME(s.database_id)                                    AS database_name
    , c.net_transport
    , c.protocol_type
    , c.auth_scheme
    , c.encrypt_option
    , c.num_reads                                                AS connection_reads
    , c.num_writes                                               AS connection_writes
    , c.connect_time
    , c.client_net_address
    , c.local_net_address
    , c.local_tcp_port
    , s.status                                                   AS session_status
    , (SELECT COUNT(*)
       FROM sys.dm_exec_requests r2
       WHERE r2.session_id = c.session_id)                       AS active_request_count
    , s.open_transaction_count
    , CASE
        WHEN (SELECT COUNT(*)
              FROM sys.dm_exec_requests r2
              WHERE r2.session_id = c.session_id) > 1
            THEN 'MARS ACTIVE — multiple concurrent requests on this connection'
        WHEN s.open_transaction_count > 0
             AND s.status = 'sleeping'
             AND (SELECT COUNT(*)
                  FROM sys.dm_exec_requests r2
                  WHERE r2.session_id = c.session_id) = 0
            THEN 'MARS RISK — idle with open transaction (typical MARS + DataReader pattern)'
        ELSE 'Single request or no MARS activity'
      END                                                        AS mars_assessment
    , DATEDIFF(MINUTE, c.connect_time, GETDATE())               AS connection_age_min
    , CASE
        WHEN c.encrypt_option = 'FALSE'
            THEN 'WARNING — connection not encrypted'
        ELSE 'Encrypted'
      END                                                        AS encryption_status
    , CASE
        WHEN c.net_transport = 'TCP'
             AND c.local_tcp_port = 1433
            THEN 'Proxy (through gateway — higher latency on Azure SQL)'
        WHEN c.net_transport = 'TCP'
             AND c.local_tcp_port BETWEEN 11000 AND 11999
            THEN 'Redirect (direct to node — optimal for Azure SQL)'
        WHEN c.net_transport = 'Shared Memory'
            THEN 'Local (shared memory — server host only)'
        WHEN c.net_transport = 'Named pipe'
            THEN 'Named Pipe (local or domain)'
        ELSE c.net_transport
      END                                                        AS connection_policy
FROM sys.dm_exec_connections AS c
JOIN sys.dm_exec_sessions    AS s
  ON c.session_id = s.session_id
WHERE s.is_user_process = 1
  AND s.session_id <> @@SPID
ORDER BY
    (SELECT COUNT(*)
     FROM sys.dm_exec_requests r2
     WHERE r2.session_id = c.session_id) DESC,
    c.num_reads + c.num_writes DESC
    OPTION (MAXDOP 1);
```

**Interpreting results:**
- `active_request_count > 1` → **MARS is actively in use** — multiple requests running on the same connection simultaneously.
- `mars_assessment = 'MARS RISK'` → idle session with an open transaction and no active request. This is a common MARS pattern where a `DataReader` was opened inside a transaction but the connection is waiting for the next read.
- `connection_policy = 'Proxy'` → connection goes through the Azure SQL gateway on port 1433. Higher latency than Redirect. Common when clients cannot open outbound ports 11000-11999.
- `connection_policy = 'Redirect'` → connection is direct to the database node. Optimal for Azure SQL.
- `connection_reads` / `connection_writes` → total network packets. Very high values on a single connection may indicate a chatty application.
- `connection_age_min` → how long the physical connection has been open. Very old connections may indicate missing connection lifetime settings.
- `encrypt_option = FALSE` → **security risk** — data in transit is not encrypted.
- `local_tcp_port` → the port on the server side. On Azure SQL, port 1433 = Proxy, 11000-11999 = Redirect.

**What to do:**
| Finding | Recommendation |
|---------|----------------|
| `active_request_count > 1` (MARS active) | Verify this is intentional. If not needed, disable MARS in the connection string: `MultipleActiveResultSets=False` |
| MARS active + `open_transaction_count > 0` | Requests share the transaction scope — ensure the application manages commit/rollback correctly across all result sets |
| Idle session with open transaction (MARS risk pattern) | Application likely has an unclosed `DataReader` inside a `TransactionScope`. Fix: ensure all readers are closed/disposed before the transaction completes |
| `connection_policy = 'Proxy'` on Azure SQL | Clients connecting via gateway — higher latency. Ensure outbound ports 11000-11999 are open on the client side, then set connection policy to Redirect on the server |
| All connections showing `Proxy` | Change the logical server's connection policy to Redirect via Azure Portal (SQL server > Networking > Connection policy), Azure CLI (`az sql server conn-policy update --connection-type Redirect`), or PowerShell (`Set-AzSqlServerConnectionPolicy -ConnectionType Redirect`). Verify NSG/firewall allows outbound ports 11000-11999 on the client side |
| `encrypt_option = FALSE` | Enable encryption: add `Encrypt=True;TrustServerCertificate=False` to the connection string, or enforce encryption server-side |
| Very high `connection_reads + connection_writes` | Chatty application — consider batching operations, using stored procedures, or reducing round trips |
| `connection_age_min` > 1440 (24h) | Connection has been alive for over a day — set `Connection Lifetime` in the pool to recycle old connections |
| `auth_scheme = SQL` | Using SQL authentication — consider migrating to Windows/Entra authentication for better security |

---

### Step 8: Database State and Availability Check

> Execute with the SQL query tool. Checks whether the current database is fully online and healthy.
Connection issues are sometimes caused by the database itself being in a transitional or restricted state.
This query uses only database-scoped views and works on all SQL platforms.

```sql
SELECT
      DB_NAME()                                     AS database_name
    , d.state_desc                                  AS database_state
    , d.user_access_desc                            AS user_access
    , d.is_read_only                                AS is_read_only
    , d.collation_name                              AS collation
    , d.compatibility_level                         AS compatibility_level
    , CASE
        WHEN d.state <> 0 THEN 'Database is NOT ONLINE — connections may fail or behave unexpectedly'
        WHEN d.user_access <> 0 THEN 'Database has restricted access — not all users can connect'
        WHEN d.is_read_only = 1 THEN 'Database is READ_ONLY — write operations will fail'
        ELSE 'Database is online and fully accessible'
      END                                           AS availability_assessment
FROM sys.databases d
WHERE d.database_id = DB_ID()
OPTION (MAXDOP 1);
```

**What to do:**
| Finding | Recommendation |
|---------|----------------|
| `database_state` is not `ONLINE` | Investigate why the database is in `RESTORING`, `RECOVERING`, `SUSPECT`, or `OFFLINE` state. Check SQL Server error log for details |
| `user_access` = `SINGLE_USER` or `RESTRICTED_USER` | Only one or limited users can connect. Verify if maintenance is in progress. Change back: `ALTER DATABASE [dbname] SET MULTI_USER` |
| `is_read_only = 1` | Applications attempting writes will receive errors. Verify if this is intentional (e.g., readable secondary, snapshot) |

---

### Step 9: Connection Rate Analysis (Spike Detection)

> Execute with the SQL query tool. Analyzes connection establishment patterns over time to detect
connection storms, rapid recycling, or sustained spikes. Uses `connect_time` from `dm_exec_connections`
which is available on all SQL platforms.

```sql
SELECT
      time_bucket
    , connections_established
    , CASE
        WHEN connections_established > 50 THEN 'Connection spike — possible connection storm or pool reset'
        WHEN connections_established > 20 THEN 'Elevated connection rate — monitor for trend'
        ELSE 'Normal'
      END AS rate_assessment
FROM (
    SELECT
          CONVERT(VARCHAR(16), c.connect_time, 120) AS time_bucket   -- 1-minute granularity
        , COUNT(*)                                   AS connections_established
    FROM sys.dm_exec_connections c
    GROUP BY CONVERT(VARCHAR(16), c.connect_time, 120)
) bucketed
ORDER BY time_bucket DESC
OPTION (MAXDOP 1);
```

**Key columns:**
- `time_bucket` — minute-level bucket showing when connections were established
- `connections_established` — number of connections opened in that minute
- `rate_assessment` — flags spikes that may indicate pool resets, app restarts, or failover reconnections

**What to do:**
| Finding | Recommendation |
|---------|----------------|
| Sharp spike in a single minute (> 50 connections) | **Connection storm** — likely caused by pool reset, app restart, or failover. Check application logs for errors at that timestamp. Review `Connection Lifetime` and `Min Pool Size` settings |
| Sustained high rate across many minutes | Application is continuously opening new connections — check for connection leaks (missing `Dispose`/`Close`) or misconfigured pool settings |
| All connections established at approximately the same time | Full pool reset — could indicate network blip, SQL restart, or Azure maintenance event. Check `sys.dm_os_ring_buffers` for connectivity ring buffer events (SQL Server/MI only) |
| Very old connections (established hours/days ago) | Long-lived pooled connections — set `Connection Lifetime` to periodically recycle. Old connections may hold stale plans or session state |

---

### Step 10: Database Principal and Contained User Validation

> Execute with the SQL query tool. Identifies database-level principals and their authentication type.
This helps detect contained database users, orphaned users (no matching server login), and authentication
misconfigurations. Uses only `sys.database_principals` which works on all SQL platforms without requiring
server-level access.

```sql
SELECT TOP ({{TopN}})
      dp.name                                      AS principal_name
    , dp.type_desc                                 AS principal_type
    , dp.authentication_type_desc                  AS authentication_type
    , dp.create_date                               AS created
    , dp.modify_date                               AS last_modified
    , dp.default_schema_name                       AS default_schema
    , CASE
        WHEN dp.authentication_type = 2 THEN 'Contained user (database-level auth) — no server login required'
        WHEN dp.authentication_type = 4 THEN 'External (Entra/AAD) principal'
        WHEN dp.authentication_type = 0 AND dp.type IN ('S','U','G') AND dp.sid IS NOT NULL
             AND dp.name NOT IN ('dbo','guest','INFORMATION_SCHEMA','sys')
             AND NOT EXISTS (SELECT 1 FROM sys.dm_exec_sessions s WHERE s.security_id = dp.sid)
             THEN 'Mapped to server login — no active sessions currently'
        ELSE ''
      END                                          AS auth_notes
    , (SELECT COUNT(*) FROM sys.dm_exec_sessions s
       WHERE s.security_id = dp.sid)               AS active_session_count
FROM sys.database_principals dp
WHERE dp.type IN (
    'S',   -- SQL user
    'U',   -- Windows user
    'G',   -- Windows group
    'E',   -- External user (Entra)
    'X'    -- External group (Entra)
)
AND dp.name NOT IN ('dbo', 'guest', 'INFORMATION_SCHEMA', 'sys')
ORDER BY
    CASE WHEN dp.authentication_type = 2 THEN 0 ELSE 1 END,  -- contained users first
    dp.name
    OPTION (MAXDOP 1);
```

**Key columns:**
- `authentication_type_desc` — `NONE` (server-login mapped), `DATABASE` (contained user), `EXTERNAL` (Entra/AAD)
- `active_session_count` — how many active sessions this principal currently has
- `auth_notes` — highlights contained users and external principals

**What to do:**
| Finding | Recommendation |
|---------|----------------|
| Contained user (`authentication_type = DATABASE`) | These users authenticate directly against the database. Ensure password policies are enforced. On Azure SQL, this is the default and expected pattern |
| User with 0 active sessions but recently modified | User exists but is not connected — may be legitimate or may be stale. Review with the application team |
| External (Entra) principal with 0 sessions | Expected if user is not currently connected. Verify the Entra identity is still valid in the directory |
| Many users of type `SQL_USER` with `authentication_type = NONE` | Server-login-mapped users — if migrating to Azure SQL, these will need to become contained users or Entra principals |

---
