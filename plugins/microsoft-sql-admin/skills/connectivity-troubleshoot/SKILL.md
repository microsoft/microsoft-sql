---
name: connectivity-troubleshoot
description: "Use when a client can't connect or gets a connection error (timeout, 53/10060/10061, SQLSTATE 08001, TLS, firewall 'IP not allowed', 4060). For login or permission issues, use `authentication-diagnostics`."
user-invocable: true
argument-hint: "[ErrorCode] [LoginName] [IPAddress] [Category]"
---

# Connectivity

Use this skill when the user asks to test connectivity, verify a connection, check if they can connect, or validate database access.

## Scope

- Covers DNS, TCP and timeout failures (53, 10060, 10061, SQLSTATE 08001), TLS and pre-login handshakes, Azure firewall rejections (40615, client IP address not allowed), login and database-open errors at connect time (18456, 4060), and transient service errors.
- Separate transport from identity and database access, and do not assume a generic login failure means Microsoft Entra authentication. For deeper login, token, principal or permission diagnosis, use `authentication-diagnostics`.

## Azure SQL Database specialization

For Azure SQL Database (EngineEdition 5), read [Azure-specific guidance](references/azure-sql/guidance.md) before choosing diagnostic queries. It preserves the service-specific permissions, capture limitations and error interpretation. Keep this skill's scope and authorization rules; the reference is not a second workflow to run unconditionally.

### Azure errors and authentication handoff

Read error number, severity and driver output together. An informational severity-10 message can accompany a successful process exit, so `sqlcmd` exit status alone does not establish success. Check the actual client version and behavior. Separate DNS/TCP/TLS failures from authentication or database-access failures; hand login/token/principal/grant diagnosis to `authentication-diagnostics`. Retry transient service/resume failures with bounds, not permanent credential failures. Do not open a firewall or broaden permissions as an automatic diagnostic step.


## Required tools

- A read-only SQL query tool connected to the target server and database. Prefer, in order: the SQL
  Tools MCP server that ships with the `microsoft-sql-admin` plugin (`mssql_list_database_connections`,
  `mssql_connect_database`, then `mssql_execute_query`); any other SQL tool the agent host provides for
  running T-SQL and reading result sets;
  [`sqlcmd`](https://learn.microsoft.com/sql/tools/sqlcmd/sqlcmd-utility) from a terminal. If the SQL
  Tools MCP server is not connected or lists no connections, follow the `sql-tools-mcp-setup` skill,
  which asks before installing or configuring anything. If no SQL tool can be made available, give the
  user the T-SQL to run and ask for the results.
- Least privilege: connect that tool with a diagnostic login that cannot write, for example one that
  holds only `VIEW SERVER PERFORMANCE STATE` (`VIEW SERVER STATE` before SQL Server 2022) or, on Azure
  SQL Database, `VIEW DATABASE PERFORMANCE STATE` or `##MS_ServerStateReader##`, plus any other read
  permission these queries need. A tool is only as read-only as the login it connects with.

## Remediation Safety

- All diagnostic queries in this skill are read-only.
- The resolutions it reports (`ALTER USER ... WITH LOGIN`, `DROP USER`, `ALTER LOGIN ... ENABLE`,
  and granting server access) change security principals. They are **recommendations only**.
- Never run any of them without the user's explicit confirmation for that specific command. A
  request to investigate, diagnose, or "fix" the problem is not that confirmation.
- Before asking, state the principal, the change, and how to undo it.

## Investigation Workflow

Execute these steps in order based on user symptoms. Use the `QueryExecutedAtUTC` value returned by the `ConnectivityChecker` query (or the current system date) for the report header date.

### Pre-Connection Troubleshooting

If connection **cannot be established at all**, guide the user through client-side diagnostics first:

1. **DNS Resolution**: `nslookup <server>.database.windows.net`
2. **Port Reachability**: `Test-NetConnection -ComputerName <server> -Port 1433`
3. **Azure SQL Connectivity Checker**: https://github.com/Azure/SQL-Connectivity-Checker

### Step 1: Verify Connection Status

Connect using the host's SQL tool, or with `sqlcmd` (for example `sqlcmd -S <server> -d <database> -N`
plus the appropriate authentication flags, such as `-E` for Windows authentication or
`--authentication-method ActiveDirectoryDefault` / `ActiveDirectoryInteractive` for Microsoft Entra).
Do not put passwords or other credentials in commands or examples; let the tool or the user supply them.

Then confirm the connection and which server and database you are connected to:

```sql
SELECT @@SERVERNAME AS ServerName, DB_NAME() AS DatabaseName, SUSER_SNAME() AS LoginName,
       SERVERPROPERTY('EngineEdition') AS EngineEdition;
```

If this returns a row, the connection is established; proceed to Step 2. If the connection attempt
fails, capture the exact error number and message and go to Step 3 (and the Pre-Connection
Troubleshooting steps above).

### Step 2: Run ConnectivityChecker

Execute the `ConnectivityChecker` query. This returns:
- Current connection details (server, database, login, auth method)
- Encryption status and TLS version
- TCP listener info (SQL Server only)
- Private/public endpoint detection (Azure SQL only)

### Step 3: Error-Specific Diagnosis

If the user provides an error code (e.g., 18456, 4060, 40613):
1. Run `CommonConnectivityErrors` query to get targeted resolution guidance
2. For **login errors (18456)**: Run `LoginDiagnostics` to check login status, lock state, and permissions
3. For **firewall errors (40532)**: Run `ListFirewallRules` (Azure SQL DB only, requires `master` database)

### Step 4: Platform-Specific Checks

Detect platform via Engine Edition, then run appropriate checks:

| Platform | Engine Edition | Additional Checks |
|----------|----------------|-------------------|
| **Azure SQL Database** | 5 | `ListFirewallRules`, `TestConnectivity` |
| **Azure SQL Managed Instance** | 8 | `TestConnectivity` (VNET/NSG/DNS guidance) |
| **Fabric SQL Database** | 11 | `TestConnectivity` |
| **SQL Server (VM/on-prem)** | 1-4 | `LoginDiagnostics`, `TestConnectivity` |

### Step 5: Generate Report

Present findings using the Report Template below.


## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| ErrorCode | *(none)* | Specific SQL error code (e.g., 18456, 4060, 40613) to filter diagnostics and show targeted resolution guidance |
| ErrorState | *(none)* | For error 18456, the specific state number (5, 7, 8, 11, 18, 38, 40) to get targeted resolution |
| Category | *(none)* | Filter errors by category: `Network`, `TLS/Certificate`, `Authentication`, `Azure Transient`, `Resource` |
| DiagnosticLevel | `full` | Level of diagnostics: `quick` (basic connectivity check only), `full` (all sections), or `custom` (user selects which checks to run) |
| LoginName | *(current)* | Login name to diagnose (defaults to current login). Use to check another user's status |
| ShowAllLogins | `false` | Show all logins/users instead of just current login. Useful for security audits |
| IPAddress | *(auto-detected)* | Client IP to validate against firewall rules (defaults to current connection IP) |
| IncludeFirewallCheck | `true` | Whether to run firewall rule analysis (Azure SQL Database only) |
| IncludeLoginDiagnostics | `true` | Whether to run login status and permission checks |
| IncludeEncryptionCheck | `true` | Whether to verify TLS/encryption status |
| IncludeVNetRules | `true` | Whether to query Virtual Network service endpoint rules |
| Port | `1433` | Target TCP port for connectivity validation and recommendations |
| MaxResults | `20` | Maximum rows to return per diagnostic section |
| TopRecommendations | `10` | Maximum number of platform-specific recommendations to return |

## Report Template

Present results in this exact format:

```
## Connectivity Diagnostics Report
Server: {{ServerName}}
Database: {{DatabaseName}}
Platform: {{Platform}}
Date: {{current date}}

---

### Connection Status: {{Connected/Failed}}

| Property | Value |
|----------|-------|
| Auth Method | {{AuthScheme}} |
| Encryption | {{EncryptionEnabled}} |
| TDS Protocol Version | {{TDSProtocolVersion}} |
| Client IP | {{ClientIP}} |
| Server Port | {{ServerPort}} |

---

### Issues Detected

{{List issues with severity: Critical/Warning/Info}}

| Severity | Issue | Details |
|----------|-------|---------|
{{one row per issue detected}}

---

### Recommended Actions

{{Numbered list of platform-specific recommendations, ordered by priority}}

1. {{Most critical action}}
2. {{Next action}}
...

---

### Additional Resources

- Azure SQL Connectivity Checker: https://github.com/Azure/SQL-Connectivity-Checker
- Connectivity Settings: https://learn.microsoft.com/en-us/azure/azure-sql/database/connectivity-settings
- Troubleshooting Checklist: https://learn.microsoft.com/en-us/troubleshoot/sql/database-engine/connect/resolve-connectivity-errors-checklist
```

## SQL Queries

### ConnectivityChecker - Comprehensive connection diagnostics

```sql
SET NOCOUNT ON;

DECLARE @EngineEdition int = CONVERT(int, SERVERPROPERTY('EngineEdition'));
DECLARE @Platform nvarchar(60) =
    CASE @EngineEdition
        WHEN 5 THEN N'Azure SQL Database'
        WHEN 8 THEN N'Azure SQL Managed Instance'
        WHEN 11 THEN N'Fabric SQL Database'
        ELSE        N'SQL Server (VM / on-prem)'
    END;

-- Section 1: Current Connection Details
SELECT 
    N'1. Connection Details' AS Section,
    SYSUTCDATETIME() AS QueryExecutedAtUTC,
    @@SERVERNAME AS ServerName,
    DB_NAME() AS DatabaseName,
    @Platform AS Platform,
    SUSER_SNAME() AS LoginName,
    USER_NAME() AS DatabaseUser,
    ORIGINAL_LOGIN() AS OriginalLogin,
    CONNECTIONPROPERTY('net_transport') AS NetTransport,
    CONNECTIONPROPERTY('auth_scheme') AS AuthScheme,
    CONNECTIONPROPERTY('client_net_address') AS ClientIP,
    CONNECTIONPROPERTY('local_net_address') AS ServerIP,
    CONNECTIONPROPERTY('local_tcp_port') AS ServerPort;

-- Section 2: Encryption & TLS
SELECT 
    N'2. Encryption Status' AS Section,
    c.encrypt_option AS EncryptionEnabled,
    c.protocol_type,
    c.protocol_version AS TDSProtocolVersion,
    s.host_name AS ClientHostName,
    s.program_name AS ClientApplication,
    s.client_interface_name AS ClientDriver,
    s.client_version AS ClientProtocolVersion,
    c.num_reads AS PacketsReceived,
    c.num_writes AS PacketsSent,
    DATEDIFF(SECOND, s.login_time, GETDATE()) AS ConnectionDurationSeconds
FROM sys.dm_exec_connections c
JOIN sys.dm_exec_sessions s ON c.session_id = s.session_id
WHERE c.session_id = @@SPID
OPTION (MAXDOP 1);

-- Section 3: TCP Listeners (SQL Server only - not available on Azure SQL DB, MI, or Fabric)
IF @EngineEdition NOT IN (5, 8, 11)
BEGIN
    SELECT 
        N'3. TCP Listeners' AS Section,
        ip_address,
        port,
        state_desc,
        start_time
    FROM sys.dm_tcp_listener_states
    WHERE type_desc = N'TSQL'
      AND state_desc = N'ONLINE'
      OPTION (MAXDOP 1);
END

-- Section 4: Azure Connection Policy & Private Endpoint (Azure SQL only)
IF @EngineEdition = 5
BEGIN
    -- Check if connected via private endpoint (client IP in private range)
    DECLARE @ClientIPCheck varchar(45) = CONVERT(varchar(45), CONNECTIONPROPERTY('client_net_address'));
    DECLARE @IsPrivateEndpoint bit = 
        CASE 
            WHEN @ClientIPCheck LIKE '10.%' THEN 1
            WHEN @ClientIPCheck LIKE '172.1[6-9].%' OR @ClientIPCheck LIKE '172.2[0-9].%' OR @ClientIPCheck LIKE '172.3[0-1].%' THEN 1
            WHEN @ClientIPCheck LIKE '192.168.%' THEN 1
            ELSE 0
        END;
    
    SELECT 
        N'4. Azure Connection Info' AS Section,
        @ClientIPCheck AS ClientIP,
        CASE @IsPrivateEndpoint 
            WHEN 1 THEN 'Private Endpoint (Private IP Range)' 
            ELSE 'Public Endpoint' 
        END AS EndpointType,
        N'Note: Connection policy (Redirect vs Proxy) affects latency. Redirect is faster but requires ports 11000-11999. Check Azure Portal > SQL Server > Networking > Connection policy.' AS PolicyNote;
END
```




### TestConnectivity - platform-aware connectivity troubleshooting recommendations
```sql
SET NOCOUNT ON;
DECLARE @EngineEdition int = CONVERT(int, SERVERPROPERTY('EngineEdition'));
DECLARE @Platform nvarchar(60) =
    CASE @EngineEdition
        WHEN 5 THEN N'Azure SQL Database'
        WHEN 8 THEN N'Azure SQL Managed Instance'
        WHEN 11 THEN N'Fabric SQL Database'
        ELSE        N'SQL Server (VM / on-prem)'
    END;
DECLARE @rec TABLE
(
    SortOrder       int IDENTITY(1,1),
    Platform        nvarchar(60),
    Severity        nvarchar(20),  -- 'Critical', 'Warning', 'Info'
    Recommendation  nvarchar(max)
);
-- Common baseline (applies to all flavors)
INSERT INTO @rec(Platform, Severity, Recommendation)
VALUES
(@Platform, N'Critical', N'Validate server/FQDN/connection string and confirm the SQL port.'),
(@Platform, N'Critical', N'From the client/network host, test TCP port reachability: PowerShell "Test-NetConnection -ComputerName <server> -Port 1433" (or custom port), and/or "sqlcmd" to validate end-to-end SQL connectivity.');
-- Azure SQL Database recommendations
IF @EngineEdition = 5
BEGIN
    INSERT INTO @rec(Platform, Severity, Recommendation)
    VALUES
    (@Platform, N'Warning', N'Connect to [master] and run ListFirewallRules to check if client IP is allowed. Use sp_set_firewall_rule to add rules.'),
    (@Platform, N'Warning', N'Review "Allow Azure services" setting in Azure Portal > Networking (avoid enabling broadly in production).'),
    (@Platform, N'Info', N'Verify DNS resolves to intended endpoint (private vs public). Run Azure SQL Connectivity Checker: https://github.com/Azure/SQL-Connectivity-Checker');
END
-- Azure SQL Managed Instance recommendations
IF @EngineEdition = 8
BEGIN
    INSERT INTO @rec(Platform, Severity, Recommendation)
    VALUES
    (@Platform, N'Critical', N'Run Azure SQL Connectivity Checker: https://github.com/Azure/SQL-Connectivity-Checker'),
    (@Platform, N'Critical', N'Test-NetConnection <server>.database.windows.net -Port <TCPPort> — confirm TcpTestSucceeded=True.'),
    (@Platform, N'Critical', N'Validate VNET path, NSG rules on MI subnet (inbound 1433), and DNS resolution (custom DNS/private DNS zone misconfig is common).'),
    (@Platform, N'Warning', N'Public vs private endpoint? Public: https://learn.microsoft.com/azure/azure-sql/managed-instance/public-endpoint-configure'),
    (@Platform, N'Warning', N'Validate route tables (UDR/forced tunneling/NVA paths can break connectivity).');
END
-- Fabric SQL Database recommendations
IF @EngineEdition = 11
BEGIN
    INSERT INTO @rec(Platform, Severity, Recommendation)
    VALUES
    (@Platform, N'Critical', N'Fabric SQL Database: Verify workspace access and permissions in Microsoft Fabric portal.'),
    (@Platform, N'Warning', N'Fabric SQL Database: Check if the SQL endpoint is enabled for the lakehouse/warehouse.'),
    (@Platform, N'Info', N'Fabric SQL Database: Ensure you are using Microsoft Entra authentication (SQL auth not supported).'),
    (@Platform, N'Warning', N'Fabric SQL Database: Validate network path if using private endpoints or ExpressRoute.');
END
-- SQL Server on Azure VM/on-prem recommendations (excludes Fabric)
IF @EngineEdition NOT IN (5, 8, 11)
BEGIN
    INSERT INTO @rec(Platform, Severity, Recommendation)
    VALUES
    (@Platform, N'Critical', N'Verify SQL Server is started (error log: "SQL Server is now ready for client connections").'),
    (@Platform, N'Critical', N'Validate NSG rules (NIC/subnet) allow inbound TCP to SQL port. Validate Windows Firewall (and UDP 1434 for SQL Browser/named instances).'),
    (@Platform, N'Critical', N'Checklist: https://learn.microsoft.com/troubleshoot/sql/database-engine/connect/resolve-connectivity-errors-checklist'),
    (@Platform, N'Warning', N'If using Public IP/LB, validate inbound NAT/LB rules map to correct backend port and AG listener config.');
END
-- Emit recommendations as a result set (ordered by severity priority)
SELECT
    Platform,
    Severity,
    Recommendation
FROM @rec
ORDER BY 
    CASE Severity 
        WHEN N'Critical' THEN 1 
        WHEN N'Warning' THEN 2 
        WHEN N'Info' THEN 3 
        ELSE 4 
    END,
    SortOrder
    OPTION (MAXDOP 1);
```

### LoginDiagnostics - Check login status and permissions

```sql
SET NOCOUNT ON;

-- Parameters (set these before running)
DECLARE @LoginName nvarchar(256) = NULL;       -- NULL = current login, or specify login to check
DECLARE @ShowAllLogins bit = 0;                 -- 0 = specified login only, 1 = all logins
DECLARE @MaxResults int = 20;                   -- Max rows to return per section

DECLARE @EngineEdition int = CONVERT(int, SERVERPROPERTY('EngineEdition'));
DECLARE @TargetLogin nvarchar(256) = ISNULL(@LoginName, SUSER_SNAME());
DECLARE @CurrentUser nvarchar(256) = USER_NAME();

-- Section 1: Current Identity
SELECT 
    N'1. Current Identity' AS Section,
    SUSER_SNAME() AS CurrentServerLogin,
    @CurrentUser AS CurrentDatabaseUser,
    ORIGINAL_LOGIN() AS OriginalLogin,
    CONNECTIONPROPERTY('auth_scheme') AS AuthMethod,
    IS_SRVROLEMEMBER('sysadmin') AS IsSysAdmin,
    IS_MEMBER('db_owner') AS IsDbOwner,
    @TargetLogin AS TargetLoginBeingDiagnosed;

-- Section 2: Login Status (SQL Server / MI only - not available in Azure SQL DB)
IF @EngineEdition NOT IN (5)
BEGIN
    -- Check if is_locked column exists (not available on all versions)
    IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('sys.sql_logins') AND name = 'is_locked')
    BEGIN
        EXEC sp_executesql N'
        SELECT TOP (@MaxRows)
            N''2. Login Status'' AS Section,
            sp.name AS LoginName,
            sp.type_desc AS LoginType,
            CASE WHEN sl.is_disabled = 1 THEN ''DISABLED'' ELSE ''Enabled'' END AS LoginStatus,
            CASE WHEN sl.is_locked = 1 THEN ''LOCKED'' ELSE ''Not Locked'' END AS LockStatus,
            CASE WHEN sl.is_expiration_checked = 1 THEN ''Yes'' ELSE ''No'' END AS PasswordExpirationChecked,
            sl.default_database_name AS DefaultDatabase,
            sp.create_date AS CreatedDate,
            sp.modify_date AS ModifiedDate
        FROM sys.server_principals sp
        LEFT JOIN sys.sql_logins sl ON sp.principal_id = sl.principal_id
        WHERE @ShowAll = 1 OR sp.name = @Login
        ORDER BY 
            CASE WHEN sl.is_disabled = 1 THEN 0 ELSE 1 END,
            CASE WHEN sl.is_locked = 1 THEN 0 ELSE 1 END,
            sp.name
        OPTION (MAXDOP 1);',
        N'@Login nvarchar(256), @ShowAll bit, @MaxRows int', @TargetLogin, @ShowAllLogins, @MaxResults;
    END
    ELSE
    BEGIN
        -- Fallback without is_locked for older versions
        SELECT TOP (@MaxResults)
            N'2. Login Status' AS Section,
            sp.name AS LoginName,
            sp.type_desc AS LoginType,
            CASE WHEN sl.is_disabled = 1 THEN 'DISABLED' ELSE 'Enabled' END AS LoginStatus,
            N'Unknown (column not available)' AS LockStatus,
            CASE WHEN sl.is_expiration_checked = 1 THEN 'Yes' ELSE 'No' END AS PasswordExpirationChecked,
            sl.default_database_name AS DefaultDatabase,
            sp.create_date AS CreatedDate,
            sp.modify_date AS ModifiedDate
        FROM sys.server_principals sp
        LEFT JOIN sys.sql_logins sl ON sp.principal_id = sl.principal_id
        WHERE @ShowAllLogins = 1 OR sp.name = @TargetLogin
        ORDER BY 
            CASE WHEN sl.is_disabled = 1 THEN 0 ELSE 1 END,
            sp.name
            OPTION (MAXDOP 1);
    END
END

-- Section 2b: Azure SQL DB contained users (when on Azure SQL DB)
IF @EngineEdition = 5
BEGIN
    SELECT TOP (@MaxResults)
        N'2. Database Users (Azure SQL DB)' AS Section,
        dp.name AS UserName,
        dp.type_desc AS UserType,
        dp.authentication_type_desc AS AuthType,
        dp.create_date AS CreatedDate,
        dp.modify_date AS ModifiedDate
    FROM sys.database_principals dp
    WHERE dp.type IN ('S', 'E', 'X')  -- SQL user, External user, External group
      AND (@ShowAllLogins = 1 OR dp.name = @CurrentUser)
    ORDER BY dp.name
    OPTION (MAXDOP 1);
END

-- Section 3: Database User Permissions (with SQL Server 2016 compatibility fallback)
DECLARE @SqlVersion int = CONVERT(int, SERVERPROPERTY('ProductMajorVersion'));

IF @SqlVersion >= 14 -- SQL Server 2017+ has STRING_AGG
BEGIN
    EXEC sp_executesql N'
    SELECT 
        N''3. Database Roles'' AS Section,
        dp.name AS UserName,
        dp.type_desc AS UserType,
        STRING_AGG(r.name, '', '') AS DatabaseRoles
    FROM sys.database_principals dp
    LEFT JOIN sys.database_role_members drm ON dp.principal_id = drm.member_principal_id
    LEFT JOIN sys.database_principals r ON drm.role_principal_id = r.principal_id
    WHERE dp.name = @User
    GROUP BY dp.name, dp.type_desc
    OPTION (MAXDOP 1);',
    N'@User nvarchar(256)', @CurrentUser;
END
ELSE
BEGIN
    -- SQL Server 2016 compatible version using FOR XML PATH
    SELECT 
        N'3. Database Roles' AS Section,
        dp.name AS UserName,
        dp.type_desc AS UserType,
        STUFF((
            SELECT ', ' + r.name
            FROM sys.database_role_members drm
            JOIN sys.database_principals r ON drm.role_principal_id = r.principal_id
            WHERE drm.member_principal_id = dp.principal_id
            FOR XML PATH(''), TYPE
        ).value('.', 'nvarchar(max)'), 1, 2, '') AS DatabaseRoles
    FROM sys.database_principals dp
    WHERE dp.name = @CurrentUser
    OPTION (MAXDOP 1);
END

-- Section 4: Effective Permissions on Current Database
-- fn_my_permissions returns: entity_name, subentity_name, permission_name
SELECT TOP (@MaxResults)
    N'4. Database Permissions' AS Section,
    entity_name AS EntityName,
    subentity_name AS SubEntityName,
    permission_name AS PermissionName
FROM fn_my_permissions(NULL, 'DATABASE')
ORDER BY permission_name
OPTION (MAXDOP 1);

-- Section 5: Orphaned Users Detection (users without matching server login)
IF @EngineEdition NOT IN (5, 11)  -- Not applicable for Azure SQL DB or Fabric
BEGIN
    SELECT TOP (@MaxResults)
        N'5. Orphaned Users' AS Section,
        dp.name AS UserName,
        dp.type_desc AS UserType,
        dp.sid AS UserSID,
        N'User has no matching server login. Fix with ALTER USER ... WITH LOGIN or DROP USER.' AS Resolution
    FROM sys.database_principals dp
    WHERE dp.type IN ('S', 'U')  -- SQL user or Windows user
      AND dp.sid IS NOT NULL
      AND dp.sid <> 0x00
      AND dp.name NOT IN ('dbo', 'guest', 'INFORMATION_SCHEMA', 'sys')
      AND NOT EXISTS (
          SELECT 1 FROM sys.server_principals sp WHERE sp.sid = dp.sid
      )
      OPTION (MAXDOP 1);
END
```

### ListFirewallRules - Azure SQL Database server-level firewall rules

```sql
SET NOCOUNT ON;

-- Parameters (set these before running)
DECLARE @IPAddress varchar(45) = NULL;           -- NULL = auto-detect current client IP
DECLARE @IncludeVNetRules bit = 1;               -- 1 = include VNet service endpoint rules
DECLARE @MaxResults int = 50;                    -- Max firewall rules to return

DECLARE @EngineEdition int = CONVERT(int, SERVERPROPERTY('EngineEdition'));

-- Guard clause: sys.firewall_rules is only available on Azure SQL Database
IF @EngineEdition <> 5
BEGIN
    SELECT 
        N'Server Firewall Rules' AS Section,
        N'OUT OF SCOPE: This query only applies to Azure SQL Database (Engine Edition 5).' AS Message,
        CASE @EngineEdition
            WHEN 8 THEN N'Azure SQL Managed Instance uses NSG rules and VNET configuration instead of firewall rules.'
            WHEN 11 THEN N'Fabric SQL Database uses workspace permissions and network settings in Microsoft Fabric portal.'
            ELSE N'SQL Server on-premises/VM uses Windows Firewall and NSG rules instead.'
        END AS Guidance;
    RETURN;
END

-- Guard clause: sys.firewall_rules is only available in master database
IF DB_NAME() <> N'master'
BEGIN
    SELECT 
        N'Server Firewall Rules' AS Section,
        N'ERROR: Must connect to [master] database to query sys.firewall_rules.' AS RuleName,
        N'Run: USE master; or reconnect to master database.' AS Resolution;
    RETURN;
END

-- Use provided IP or auto-detect from current connection
DECLARE @ClientIP varchar(45) = ISNULL(@IPAddress, CONVERT(varchar(45), CONNECTIONPROPERTY('client_net_address')));
DECLARE @ClientIPInt bigint = NULL;

-- Convert client IP to bigint for range comparison (IPv4 only)
IF @ClientIP IS NOT NULL
   AND @ClientIP NOT LIKE '<%'
   AND CHARINDEX(':', @ClientIP) = 0
BEGIN
    SET @ClientIPInt =
        (TRY_CONVERT(bigint, PARSENAME(@ClientIP, 4)) * 256 * 256 * 256) +
        (TRY_CONVERT(bigint, PARSENAME(@ClientIP, 3)) * 256 * 256) +
        (TRY_CONVERT(bigint, PARSENAME(@ClientIP, 2)) * 256) +
        (TRY_CONVERT(bigint, PARSENAME(@ClientIP, 1)));
END

-- Show current client IP first
SELECT 
    N'Current Client IP' AS Section,
    @ClientIP AS ClientIP,
    CASE WHEN @IPAddress IS NULL THEN N'(auto-detected)' ELSE N'(user specified)' END AS Source;

-- List all firewall rules with client IP match indicator
SELECT TOP (@MaxResults)
    N'Server Firewall Rules' AS Section,
    name AS RuleName,
    start_ip_address AS StartIP,
    end_ip_address AS EndIP,
    CASE 
        WHEN start_ip_address = '0.0.0.0' AND end_ip_address = '0.0.0.0' 
        THEN 'Allow Azure Services (Security Risk!)'
        WHEN start_ip_address = end_ip_address 
        THEN 'Single IP'
        ELSE 'IP Range'
    END AS RuleType,
    CASE 
        WHEN @ClientIPInt IS NULL THEN 'Unable to check'
        WHEN @ClientIPInt BETWEEN 
            (TRY_CONVERT(bigint, PARSENAME(start_ip_address, 4)) * 256 * 256 * 256) +
            (TRY_CONVERT(bigint, PARSENAME(start_ip_address, 3)) * 256 * 256) +
            (TRY_CONVERT(bigint, PARSENAME(start_ip_address, 2)) * 256) +
            (TRY_CONVERT(bigint, PARSENAME(start_ip_address, 1)))
        AND 
            (TRY_CONVERT(bigint, PARSENAME(end_ip_address, 4)) * 256 * 256 * 256) +
            (TRY_CONVERT(bigint, PARSENAME(end_ip_address, 3)) * 256 * 256) +
            (TRY_CONVERT(bigint, PARSENAME(end_ip_address, 2)) * 256) +
            (TRY_CONVERT(bigint, PARSENAME(end_ip_address, 1)))
        THEN 'YES - Covers Current Client'
        ELSE 'No'
    END AS CoversCurrentClient
FROM sys.firewall_rules
ORDER BY 
    CASE WHEN start_ip_address = '0.0.0.0' AND end_ip_address = '0.0.0.0' THEN 0 ELSE 1 END,
    name
    OPTION (MAXDOP 1);

-- List Virtual Network Service Endpoint rules (if enabled and available)
IF @IncludeVNetRules = 1 AND OBJECT_ID('sys.virtual_network_rules', 'V') IS NOT NULL
BEGIN
    EXEC sp_executesql N'
    SELECT
        N''Virtual Network Rules'' AS Section,
        name AS RuleName,
        virtual_network_subnet_id AS SubnetResourceId,
        CASE 
            WHEN virtual_network_subnet_id LIKE ''%/subnets/%'' 
            THEN REVERSE(LEFT(REVERSE(virtual_network_subnet_id), CHARINDEX(''/'', REVERSE(virtual_network_subnet_id)) - 1))
            ELSE ''Unknown''
        END AS SubnetName,
        CASE state
            WHEN 0 THEN ''Initializing''
            WHEN 1 THEN ''InProgress''
            WHEN 2 THEN ''Ready''
            WHEN 3 THEN ''Deleting''
            WHEN 4 THEN ''Unknown''
            ELSE ''State: '' + CAST(state AS varchar(10))
        END AS RuleState,
        state_desc AS StateDescription
    FROM sys.virtual_network_rules
    ORDER BY name
    OPTION (MAXDOP 1);';
END
ELSE
BEGIN
    SELECT 
        N'Virtual Network Rules' AS Section,
        N'No VNet service endpoint rules configured (sys.virtual_network_rules not available or empty).' AS Message;
END
```




### CommonConnectivityErrors - Error code reference with state details

```sql
SET NOCOUNT ON;

-- Parameters (set these before running)
DECLARE @ErrorCode int = NULL;                   -- Specific error code to filter (NULL = all)
DECLARE @ErrorState int = NULL;                  -- For 18456 errors, specific state to highlight
DECLARE @Category nvarchar(50) = NULL;           -- Filter by category: 'Network', 'TLS/Certificate', 'Authentication', 'Azure Transient', 'Resource'
DECLARE @MaxResults int = 50;                    -- Max results to return

-- Error 18456 State Reference (separate section when @ErrorState is specified)
IF @ErrorState IS NOT NULL
BEGIN
    SELECT
        N'Error 18456 State Reference' AS Section,
        v.State,
        v.Meaning,
        v.Resolution
    FROM (VALUES
        (5,  N'Invalid user ID', N'Login does not exist. Verify login name spelling and case sensitivity.'),
        (7,  N'Login disabled', N'Login exists but is disabled. Run: ALTER LOGIN [name] ENABLE;'),
        (8,  N'Incorrect password', N'Password is wrong. Reset password or verify credentials.'),
        (9,  N'Password is not valid', N'The supplied password is invalid. Reset password or verify credentials.'),
        (11, N'Login valid but no server access', N'Login exists but lacks CONNECT SQL permission. Grant server access.'),
        (12, N'Login valid but no server access (trigger)', N'Same as 11, caused by login trigger.'),
        (18, N'Password must be changed', N'Password must be changed before login. User must change via SSMS or reset.'),
        (27, N'Initial database not found', N'Default database does not exist or is offline.'),
        (38, N'Requested database not found', N'Could not find the database requested by the user. Verify database name, existence, and that it is online.'),
        (46, N'Requested database not found', N'Could not find the database requested by the user (same as state 38). Verify database name, existence, and that it is online.'),
        (102, N'AAD authentication failed', N'Azure Active Directory authentication error (states 102-111). Check AAD configuration and user sync.'),
        (132, N'AAD authentication failed', N'Azure Active Directory authentication error (states 132-133). Check AAD configuration and user sync.')
    ) AS v(State, Meaning, Resolution)
    WHERE v.State = @ErrorState OR @ErrorState IS NULL
    OPTION (MAXDOP 1);
END

-- Common connectivity error codes with category for filtering
SELECT TOP (@MaxResults)
    v.ErrorCode,
    v.Category,
    v.[Description],
    v.[Resolution]
FROM (VALUES
    -- Authentication Errors
    (18456,  N'Authentication', N'Login failed',
             N'Check error STATE in SQL error log: State 5=Invalid user, State 7=Login disabled, State 8=Wrong password, State 9=Password not valid, State 11/12=Login valid but no server access, State 18=Password must be changed, State 38/46=Requested database not found, States 102-111/132-133=AAD auth failed. Run LoginDiagnostics query to check login status.'),
    (4060,   N'Authentication', N'Cannot open database requested by the login',
             N'Database may not exist, user lacks access, default database is invalid, or database is offline/restoring. Verify DB name, permissions, and DB state.'),
    
    -- Network Errors
    (53,     N'Network', N'Network path not found',
             N'DNS/name resolution or blocked path. Validate server FQDN and network reachability.'),
    (233,    N'Network', N'Connection broken',
             N'Forcibly closed. Check network stability, idle timeout, connection pooling.'),
    (10054,  N'Network', N'Connection reset by peer',
             N'Firewall timeout, proxy termination, or server-side kill. Check keep-alive settings.'),
    (10060,  N'Network', N'Connection timeout',
             N'Validate firewall/NSG/proxy/VPN path and DNS resolution.'),
    (10061,  N'Network', N'Connection refused',
             N'Service not started or endpoint unreachable. Verify target availability.'),
    
    -- Azure Transient Errors
    (40197,  N'Azure Transient', N'Service error processing request',
             N'Transient failover/scaling. Retry with backoff.'),
    (40532,  N'Azure Transient', N'Cannot open server',
             N'Firewall block. Run ListFirewallRules. For private endpoint, verify DNS.'),
    (40613,  N'Azure Transient', N'Database unavailable',
             N'Resuming/scaling/failing over. Retry with exponential backoff (max 5 retries, 5-30s).'),
    (40615,  N'Azure Transient', N'Cannot connect in region',
             N'Verify correct server FQDN for target region.'),
    (40143,  N'Azure Transient', N'Service tier not supported',
             N'Check DTU vs vCore requirements.'),
    
    -- Resource Limit Errors
    (10928,  N'Resource', N'Worker limit exceeded',
             N'Reduce concurrent connections or scale up.'),
    (10929,  N'Resource', N'Session limit reached',
             N'Close idle connections or scale up.'),
    (40544,  N'Resource', N'Database quota exceeded',
             N'Delete data, archive, or scale up storage.'),
    (40549,  N'Resource', N'Long-running transaction killed',
             N'Optimize query or break into smaller batches.'),
    (49918,  N'Resource', N'Insufficient resources',
             N'Scale up DTU/vCores. Check sys.dm_db_resource_stats.'),
    
    -- TLS/Certificate Errors
    (-2146893019, N'TLS/Certificate', N'SSL certificate validation failed',
             N'Check: cert valid/not expired, chain complete, client trusts root CA, name matches CN/SAN. Ensure TLS 1.2+ on client.'),
    (-2146893007, N'TLS/Certificate', N'Untrusted certificate authority',
             N'Install root CA in client trusted store, or TrustServerCertificate=True (not for production).'),
    (-2146893022, N'TLS/Certificate', N'Target principal name incorrect',
             N'FQDN vs certificate CN/SAN mismatch. Common with private endpoints + custom DNS.'),
    (772,    N'TLS/Certificate', N'Certificate chain untrusted',
             N'Check Windows certificate store for missing intermediate CAs.'),
    (64,     N'TLS/Certificate', N'TLS handshake terminated',
             N'TLS version/cipher mismatch. Ensure TLS 1.2 support. Update client drivers.'),
    (20,     N'TLS/Certificate', N'Certificate not validated',
             N'Check TLS settings, cert validity, and network proxies intercepting TLS.')
) AS v(ErrorCode, Category, [Description], [Resolution])
WHERE (@ErrorCode IS NULL OR v.ErrorCode = @ErrorCode)
  AND (@Category IS NULL OR v.Category = @Category)
ORDER BY v.Category, v.ErrorCode
OPTION (MAXDOP 1);
```








