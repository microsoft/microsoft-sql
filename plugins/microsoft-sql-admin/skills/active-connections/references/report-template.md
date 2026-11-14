# Active Connections Analysis — Report Template, Decision Tree & Client-Side Troubleshooting

Combine results from all steps into this unified report:

```
## Active Connections Analysis Report
Database:   {{database name}}
Date:       {{current date in YYYY-MM-DD format}}
Data Source: sys.dm_exec_sessions, sys.dm_exec_connections, sys.dm_tran_active_transactions, sys.databases, sys.database_principals
Parameters: TopN={{TopN}}, IdleThreshold={{IdleThresholdMinutes}}m,
            OpenTxnThreshold={{OpenTxnThresholdSeconds}}s

---

### Step 1 — Platform & Connection Summary

| Metric | Value |
|--------|-------|
| Engine Type | {{engine_type}} |
| Total User Sessions | {{total_user_sessions}} |
| Total Connections | {{total_connections}} |

---

### Step 2 — Connections by Database

| Database | Login | Program | Connections | Running | Sleeping | Earliest Login | Latest Request |
|----------|-------|---------|-------------|---------|----------|----------------|----------------|
{{Top rows. Flag connection_count > 50 as warning.}}

---

### Step 3 — Idle Sessions (> {{IdleThresholdMinutes}}m)

| Session | Login | Host | Program | Database | Idle (min) | Open Txns | Assessment |
|---------|-------|------|---------|----------|------------|-----------|------------|
{{Flag open_transaction_count > 0 as critical.}}

---

### Step 4 — Connection Pooling Patterns

| Program | Login | Total | Running | Sleeping | Idle % | Pool Age (min) | Open Txns |
|---------|-------|-------|---------|----------|--------|----------------|-----------|
{{Flag idle_pct > 90% with total > 30 as oversized pool.}}

---

### Step 5 — Client Distribution & Connection Properties

| Host | Client IP | Login | Sessions | Running | Sleeping | Transport | Auth | Encrypted | TDS Version |
|------|-----------|-------|----------|---------|----------|-----------|------|-----------|-------------|
{{Flag encrypt_option = FALSE as unencrypted. Flag single client with disproportionate count as warning.}}

---

### Step 6 — Open Transactions

| Session | Login | Host | Program | Status | Txn Duration (sec) | Log MB Used | State | Assessment |
|---------|-------|------|---------|--------|---------------------|-------------|-------|------------|
{{Flag sleeping + open txn as critical. Flag txn > 5 min as warning.}}

---

### Step 7 — MARS, Connection Policy & Client Diagnostics

| Session | Login | Host | Program | Active Requests | Open Txns | MARS Assessment | Connection Policy | Encrypted | Connection Age (min) |
|---------|-------|------|---------|-----------------|-----------|-----------------|-------------------|-----------|----------------------|
{{Flag active_request_count > 1 as MARS active. Flag encrypt_option = FALSE as unencrypted. Flag Proxy connections as suboptimal.}}

---

### Step 8 — Database State & Availability

| Database | State | User Access | Read Only | Availability Assessment |
|----------|-------|-------------|-----------|-------------------------|
{{Flag any state other than ONLINE as critical. Flag SINGLE_USER or RESTRICTED_USER as warning.}}

---

### Step 9 — Connection Rate Analysis

| Time Bucket | Connections Established | Rate Assessment |
|-------------|------------------------|-----------------|
{{Flag spikes > 50 as connection storm. Flag > 20 as elevated.}}

---

### Step 10 — Database Principals & Contained Users

| Principal | Type | Auth Type | Active Sessions | Auth Notes |
|-----------|------|-----------|-----------------|------------|
{{Flag contained users for password policy review. Flag server-mapped users on Azure as migration candidate.}}

---

### Summary & Recommended Next Steps

{{Based on findings across all steps, provide prioritized actions.}}
```

---

## Root Cause Decision Tree and Next Steps

### Too many connections from a single application (Step 2/4)

**Root cause: Connection pool misconfiguration or connection leak.**

Next steps:
1. Review `Max Pool Size` in the application's connection string (default is usually 100)
2. Ensure connections are properly disposed (C#: `using` statements; Java: try-with-resources)
3. Set `Connection Lifetime` to automatically reclaim long-lived pooled connections
4. Monitor with application-side pool metrics if available

### Idle sessions with open transactions (Step 3/6)

**Root cause: Application not committing or rolling back transactions.**

Next steps:
1. **Immediate:** If safe, kill the idle session: `KILL <session_id>`
2. **Fix:** Review application code for missing COMMIT/ROLLBACK in error paths
3. **Prevent:** Set `SET XACT_ABORT ON` in stored procedures to auto-rollback on error
4. **Monitor:** Alert on `open_transaction_count > 0` for sleeping sessions

### High connection count but low activity (Steps 2–4)

**Root cause: Oversized connection pools or leaked connections across multiple apps.**

Next steps:
1. Reduce `Max Pool Size` across application connection strings
2. Enable connection lifetime/timeout to reclaim idle connections
3. Implement connection health checks in the application
4. Consider setting server-level `login timeout` and configuring `remote query timeout`

### MARS-related blocking or transaction confusion (Step 7)

**Root cause: Multiple Active Result Sets enabled, causing multiple interleaved requests per connection.**

Next steps:
1. **If MARS is not needed:** Disable in the connection string: `MultipleActiveResultSets=False`
2. **If MARS is needed:** Ensure the application correctly manages shared transaction scope across all active result sets
3. **MARS risk pattern (idle + open transaction):** Application has unclosed `DataReader` inside a transaction — fix by ensuring all readers are closed/disposed before transaction completes
4. **Blocking on same connection:** MARS requests can block each other — redesign to use separate connections for concurrent operations

### Unencrypted connections (Steps 5/7)

**Root cause: Client connection strings missing `Encrypt=True` or server not enforcing encryption.**

Next steps:
1. Add `Encrypt=True;TrustServerCertificate=False` to all client connection strings
2. On SQL Server: enable "Force Encryption" in SQL Server Configuration Manager
3. On Azure SQL: encryption is enforced by default, but verify `TrustServerCertificate=False`
4. Audit all `encrypt_option = FALSE` connections from Step 5/7 results

### Old TDS protocol or outdated client drivers (Step 5)

**Root cause: Application using outdated SQL client library.**

Next steps:
1. Identify the application via `host_name` and `program_name`
2. Update to the latest Microsoft.Data.SqlClient, ODBC Driver 18, or OLE DB Driver 19
3. Old drivers may lack TLS 1.2 support, connection resiliency, and modern authentication

### Connections using Proxy instead of Redirect on Azure SQL (Step 7)

**Root cause: Client firewall or NSG blocking outbound ports 11000-11999, or server connection policy set to Proxy.**

Next steps:
1. Check the server connection policy: `SELECT CONNECTIONPROPERTY('physical_net_transport')` — if it returns 'TCP', you're on Proxy
2. Ensure client-side firewall allows outbound TCP to Azure SQL IPs on ports 11000-11999
3. Change server policy to Redirect: in Azure Portal → SQL Server → Networking → Connection policy → Redirect
4. Verify NSG rules on the client subnet (if Azure-hosted) allow outbound 11000-11999

### Database not fully online or accessible (Step 8)

**Root cause: Database is in a non-ONLINE state, has restricted access, or is read-only.**

Next steps:
1. Check SQL Server error log for why the database entered the current state
2. For `SINGLE_USER`: verify maintenance is complete, then `ALTER DATABASE [dbname] SET MULTI_USER`
3. For `RESTORING`/`RECOVERING`: wait for the operation to complete, or check if a log restore chain is incomplete
4. For `SUSPECT`: run `DBCC CHECKDB` to assess corruption — engage DBA/support

### Connection storms or rapid pool resets (Step 9)

**Root cause: Mass connection establishment in a short window — often from pool resets, app restarts, failovers, or Azure maintenance events.**

Next steps:
1. Correlate the spike timestamp with application logs, Azure maintenance events, or error log entries
2. Review `Min Pool Size` — setting it > 0 reduces cold-start connection bursts
3. Set `Connection Lifetime` to spread reconnections over time instead of all at once
4. On Azure SQL: check for recent maintenance events in Azure Portal → Resource health
5. Consider implementing connection retry logic with exponential backoff in the application

### Authentication or user principal issues (Step 10)

**Root cause: Misconfigured database principals, orphaned users, or authentication type mismatches.**

Next steps:
1. For orphaned users (server-mapped with no matching login): remap with `ALTER USER [username] WITH LOGIN = [loginname]` or drop if no longer needed
2. For contained users: ensure password complexity policies are enforced. Review with `SELECT * FROM sys.database_principals WHERE authentication_type = 2`
3. When migrating to Azure SQL: convert server-mapped users to contained users or Entra principals
4. For Entra principals with issues: verify the identity exists and is active in the Entra tenant

---

## Client-Side Connectivity Troubleshooting (Cannot Be Detected via DMVs)

> **Important:** The queries in this skill only show connections that have **already succeeded** in reaching
the SQL Server engine. If a client **cannot connect at all**, the failure happens before the connection
reaches the engine and will NOT appear in any DMV. The following checks must be performed **on the client
machine** before raising a support ticket.

### Pre-Ticket Checklist

Before raising a connectivity support ticket, ensure the following client-side checks have been completed.
Document the results — support engineers will ask for this information.

#### 1. DNS Resolution

**What to check:** Can the client machine resolve the SQL Server hostname to the correct IP address?

```
-- Windows PowerShell
Resolve-DnsName <server>.database.windows.net
nslookup <server>.database.windows.net

-- Linux
dig <server>.database.windows.net
host <server>.database.windows.net
```

**Common issues:**
- Stale DNS cache pointing to an old gateway IP (Azure SQL does not guarantee static IPs)
- Hosts file override (`C:\Windows\System32\drivers\etc\hosts`) hardcoding an IP that has changed
- Corporate DNS server not resolving Azure SQL endpoints
- Private Link DNS misconfiguration — `*.privatelink.database.windows.net` not resolving correctly

**Fix:** Flush DNS cache (`ipconfig /flushdns`), remove hosts file entries for SQL endpoints, verify DNS server configuration.

#### 2. Network Port Connectivity

**What to check:** Can the client reach the SQL Server on the required ports?

```
-- Windows PowerShell
Test-NetConnection <server>.database.windows.net -Port 1433

-- For Azure SQL Redirect policy, also test:
Test-NetConnection <server>.database.windows.net -Port 11000
Test-NetConnection <server>.database.windows.net -Port 11999

-- SQL Managed Instance Public Endpoint:
Test-NetConnection <mi-name>.public.<dns-zone>.database.windows.net -Port 3342
```

**Required ports by platform:**
| Platform | Required Ports | Notes |
|----------|---------------|-------|
| Azure SQL Database (Proxy) | 1433 outbound | All traffic through gateway |
| Azure SQL Database (Redirect) | 1433 + 11000-11999 outbound | Initial handshake on 1433, then redirect to 11000-11999 |
| Azure SQL Managed Instance (Private) | 1433 outbound | Within VNet or peered network |
| Azure SQL Managed Instance (Public) | 3342 outbound | Must be enabled on the MI |
| SQL Server on-prem / IaaS | 1433 (default, configurable) | Check SQL Server Configuration Manager for actual port |
| Fabric SQL Database | 1433 outbound | Same as Azure SQL Database |

#### 3. TLS / SSL Configuration

**What to check:** Does the client support TLS 1.2 or higher?

```
-- Windows PowerShell (check supported cipher suites)
Get-TlsCipherSuite | Format-Table Name

-- Check if TLS 1.2 is enabled in registry
Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client' -ErrorAction SilentlyContinue
```

**Common issues:**
- Old OS or .NET Framework version only supports TLS 1.0/1.1 (deprecated by Azure SQL since Nov 2024)
- Client cipher suites incompatible with server — no shared cipher for TLS handshake
- `TrustServerCertificate=True` in connection string bypasses certificate validation (security risk)

**Fix:** Enable TLS 1.2 on the client, update .NET Framework to 4.7.2+, update SQL client drivers.

#### 4. Firewall and NSG Rules (Azure)

**What to check:** Are there firewall rules or Network Security Groups blocking the connection?

- **Azure SQL Database:** Check server-level and database-level IP firewall rules in the Azure Portal
- **VNet Service Endpoints:** If the client is in an Azure VNet with `Microsoft.Sql` service endpoint, a VNet rule must exist on the server
- **Private Endpoint:** Verify the private endpoint DNS zone is correctly linked and resolving
- **NSG outbound rules:** On the client subnet, ensure outbound TCP to SQL on ports 1433 (and 11000-11999 for Redirect) is allowed

**Common error codes (from client):**
| Error | Meaning |
|-------|---------|
| 40615 | Client IP not authorized — add to firewall rules |
| 40914 | VNet service endpoint enabled but no VNet rule on server |
| 47073 | "Deny Public Network Access" is enabled — use Private Endpoint |
| 10060 | TCP connection timeout — port blocked or server unreachable |
| 121 | "Semaphore timeout" — network-level timeout, not SQL timeout |

#### 5. Authentication Issues

**What to check:** Is the correct authentication method configured?

- **SQL Authentication:** Verify username/password. After multiple failures, DoSGuard may block the IP temporarily.
- **Microsoft Entra ID:** Verify the Entra tenant, user permissions, and that the authentication library (MSAL) is up to date.
- **Managed Identity:** Only works from Azure resources (App Service, VM, AKS, etc.) — not from local development machines.

**Common error code:**
| Error | Meaning |
|-------|---------|
| 18456 | Login failed — wrong password, user doesn't exist, or no CONNECT permission to the database |

#### 6. Connection String Best Practices

Ensure the client connection string follows these best practices:

```
Server=tcp:<server>.database.windows.net,1433;
Initial Catalog=<database>;
Encrypt=True;
TrustServerCertificate=False;
Connection Timeout=30;
MultipleActiveResultSets=False;
Application Name=<your-app-name>;
```

**Key settings to verify:**
| Setting | Recommended Value | Why |
|---------|-------------------|-----|
| `Encrypt` | `True` | Protects data in transit |
| `TrustServerCertificate` | `False` | Validates server certificate (prevents MITM attacks) |
| `MultipleActiveResultSets` | `False` (unless needed) | Avoids MARS-related blocking and transaction confusion |
| `Connection Timeout` | `30` (default) | Increase if connecting over high-latency networks |
| `Application Name` | Set to your app name | Appears in `program_name` in DMVs — critical for diagnostics |
| `Max Pool Size` | `100` (default) | Reduce if too many idle connections; increase for high-throughput apps |
| `Connection Lifetime` | Set a value (e.g., `300`) | Recycles connections in the pool periodically |

#### 7. Run the Azure SQL Connectivity Checker

For comprehensive **client-side** connectivity diagnostics, run the
[Azure SQL Connectivity Checker](https://github.com/Azure/SQL-Connectivity-Checker) tool:

Download `AzureSQLConnectivityChecker.ps1` from that repository, review it, and run it locally
as its README describes, with the server name and database. Do not put passwords in the command,
the script file, or the chat; use the script's interactive or Microsoft Entra authentication
options where available.

This tool performs checks that **cannot** be done from the SQL Server side:
- DNS resolution from multiple sources (cache, hosts file, DNS server, OpenDNS)
- TCP port reachability to Azure SQL gateways
- TLS cipher suite compatibility
- Connection policy testing (Proxy vs Redirect)
- Network trace collection for deep packet analysis
- Microsoft Entra authentication endpoint reachability (`login.microsoftonline.com`)
- Private Link endpoint validation

> **Note:** This tool runs on Windows PowerShell, PowerShell Core (Linux/macOS), Docker, and Kubernetes.
See the [GitHub repository](https://github.com/Azure/SQL-Connectivity-Checker) for platform-specific instructions.
