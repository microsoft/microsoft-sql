---
name: authentication-diagnostics
description: "Use when a login fails (18456, 'Login failed for user'), a user can't open a database, a permission is denied, or an Entra or managed identity login fails. For network errors, use `connectivity-troubleshoot`."
user-invocable: true
---

# Authentication Diagnostics

## Purpose

Use this skill when the user reports login failures, permission errors, authentication mismatches,
or needs to audit the security configuration of a SQL instance. This skill provides a comprehensive
diagnostic workflow covering:
1. Platform detection and version validation
2. Server login existence and status (disabled, locked, expired)
3. Password policy and credential health
4. Authentication mode (Mixed vs Windows-only)
5. Database user mapping and orphan detection
6. Permission audit (explicit DENY, role membership, effective permissions)
7. Entra ID (Azure AD) and managed identity principal validation
8. Default database accessibility
9. Active session authentication scheme detection (Kerberos / NTLM / SQL)
10. Login failure analysis from the error log

> **Scope:** This skill focuses exclusively on diagnostics achievable via T-SQL.
> Network-level checks (DNS, firewall, port connectivity, TLS handshake) are outside the scope
> of this skill — see the `active-connections` skill's Client-Side Connectivity Troubleshooting
> section for those checks.

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

## Prerequisites

- Must be connected to the target database.
- Confirm which server and database you are connected to (e.g. with
  `SELECT @@SERVERNAME, DB_NAME(), SUSER_SNAME(), SERVERPROPERTY('EngineEdition')`); connect first if not already connected.
- Several steps require **server-level permissions** (`VIEW SERVER STATE`, `VIEW ANY DEFINITION`).
  On Azure SQL Database these steps are skipped automatically because server-level DMVs are not
  accessible from a user-database context.

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| TopN | 20 | Number of top results to return in each step |
| LoginFailureHours | 24 | Hours of login failure history to retrieve from the error log |

## Remediation Safety

- All diagnostic queries in this skill are read-only.
- The remediation commands in the tables below change logins, users, permissions, or passwords:
  `ALTER LOGIN` (`ENABLE`, `UNLOCK`, `WITH PASSWORD`, `CHECK_POLICY`, `DEFAULT_DATABASE`),
  `CREATE LOGIN`, `ALTER USER`, `DROP USER`, `GRANT`, and `REVOKE`. They are **recommendations only**.
- Never run any of them without the user's explicit confirmation for that specific command. A
  request to investigate, diagnose, or "fix" the problem is not that confirmation.
- Before asking, state the principal, the change, and the rollback. `DROP USER` removes the user's
  permissions and cannot be undone by re-creating the user alone.
- Never ask for, type, or repeat a password. Show `'<new_password>'` placeholders and have the user run
  password changes themselves, so no password appears in chat, command history, or logs.

## Investigation Workflow

Execute all steps in order. Steps that are not applicable to the current platform are
noted and should be skipped.

---

### Step 1: Platform Detection and Version Validation

> Execute with the SQL query tool. Detects engine edition, version, and validates platform
> support. The version information is critical for later steps that use version-specific DMV columns.

```sql
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @MajorVersion  INT = CAST(SERVERPROPERTY('ProductMajorVersion') AS INT);

SELECT
      CAST(SERVERPROPERTY('Edition') AS NVARCHAR(128))           AS sql_edition
    , CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(128))    AS sql_version
    , @MajorVersion                                              AS major_version
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
    , CASE WHEN @EngineEdition IN (5, 11, 12)  THEN 0 ELSE 1 END AS has_server_level_access
    , CAST(SERVERPROPERTY('IsIntegratedSecurityOnly') AS INT)    AS is_windows_auth_only
    , DB_NAME()                                                  AS current_database;

IF @EngineEdition IN (6, 11)
BEGIN
    SELECT 'This skill is not designed for Azure Synapse Analytics or Fabric Warehouse/Lakehouse endpoints (EngineEdition 6 or 11). Note: Fabric SQL Database (EngineEdition 12) is supported.' AS unsupported_message;
    RETURN;
END
```

**What to do:**
| Assessment | Action |
|------------|--------|
| `is_unsupported_dw = 1` | **Stop** — this skill does not apply to Azure Synapse (edition 6) or Synapse serverless / Fabric Warehouse (edition 11). Fabric SQL Database (edition 12) is supported. |
| `has_server_level_access = 0` (Azure SQL DB / Fabric) | Steps 2, 3, 4, 8, 10 will be skipped or use database-scoped alternatives |
| `is_windows_auth_only = 1` | SQL Authentication is disabled — only Windows/Entra auth is accepted. Note this in the report |
| Any other edition | Proceed to Step 2 |

Save `engine_edition`, `major_version`, and `has_server_level_access` for use in conditional
logic in later steps.

---

### Step 2: Server Login Existence and Status

> Execute with the SQL query tool. Checks whether server-level logins exist, are disabled,
> or are locked out due to failed attempts.

> **Platform:** SQL Server (on-prem / IaaS) and Azure SQL Managed Instance only.
> On Azure SQL Database and Fabric, skip this step — use Step 5 (database principals) instead.

```sql
-- Requires: VIEW SERVER STATE or VIEW ANY DEFINITION on SQL Server / MI
-- Guard: skip on Azure SQL Database (EngineEdition 5), Fabric DW (11), and Fabric SQL DB (12) where
-- sys.server_principals is not accessible from a user-database context.
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

IF @EngineEdition IN (5, 11, 12)
BEGIN
    SELECT 'Skipped — server-level login views are not available on Azure SQL Database / Fabric. Use Step 5 (database principals) instead.' AS skip_reason;
    RETURN;
END

-- Uses LOGINPROPERTY() instead of sys.sql_logins to avoid column-availability
-- issues across SQL Server versions. LOGINPROPERTY returns NULL for non-SQL logins.
SELECT TOP ({{TopN}})
      sp.name                                        AS login_name
    , sp.type_desc                                   AS login_type
    , sp.create_date                                 AS created
    , sp.modify_date                                 AS last_modified
    , sp.is_disabled                                 AS is_disabled
    , sp.default_database_name                       AS default_database
    , sp.default_language_name                       AS default_language
    , CASE
        WHEN sp.type = 'S'
             THEN CAST(LOGINPROPERTY(sp.name, 'IsLocked') AS INT)
        ELSE NULL
      END                                            AS is_locked
    , CASE
        WHEN sp.type = 'S'
             THEN CAST(LOGINPROPERTY(sp.name, 'IsExpired') AS INT)
        ELSE NULL
      END                                            AS is_expired
    , CASE
        WHEN sp.type = 'S'
             THEN CAST(LOGINPROPERTY(sp.name, 'IsMustChange') AS INT)
        ELSE NULL
      END                                            AS must_change_password
    , CASE
        WHEN sp.type = 'S'
             THEN CAST(LOGINPROPERTY(sp.name, 'IsExpirationChecked') AS INT)
        ELSE NULL
      END                                            AS is_expiration_on
    , CASE
        WHEN sp.type = 'S'
             THEN CAST(LOGINPROPERTY(sp.name, 'IsPolicyChecked') AS INT)
        ELSE NULL
      END                                            AS is_policy_on
    , CASE
        WHEN sp.is_disabled = 1
            THEN 'DISABLED — login cannot authenticate'
        WHEN sp.type = 'S'
             AND CAST(LOGINPROPERTY(sp.name, 'IsLocked') AS INT) = 1
            THEN 'LOCKED — too many failed attempts'
        WHEN sp.type = 'S'
             AND CAST(LOGINPROPERTY(sp.name, 'IsExpired') AS INT) = 1
            THEN 'EXPIRED — password has expired'
        WHEN sp.type = 'S'
             AND CAST(LOGINPROPERTY(sp.name, 'IsPolicyChecked') AS INT) = 0
            THEN 'WARNING — password policy not enforced'
        ELSE 'OK'
      END                                            AS login_status
    , CASE
        WHEN sp.type = 'S'
             AND LOGINPROPERTY(sp.name, 'PasswordLastSetTime') IS NOT NULL
             THEN CAST(LOGINPROPERTY(sp.name, 'PasswordLastSetTime') AS DATETIME)
        ELSE NULL
      END                                            AS password_last_set
    , CASE
        WHEN sp.type = 'S'
             AND LOGINPROPERTY(sp.name, 'DaysUntilExpiration') IS NOT NULL
             THEN CAST(LOGINPROPERTY(sp.name, 'DaysUntilExpiration') AS INT)
        ELSE NULL
      END                                            AS days_until_expiration
    , CASE
        WHEN sp.type = 'S'
             THEN CAST(LOGINPROPERTY(sp.name, 'BadPasswordCount') AS INT)
        ELSE NULL
      END                                            AS bad_password_count
    , CASE
        WHEN sp.type = 'S'
             AND LOGINPROPERTY(sp.name, 'BadPasswordTime') IS NOT NULL
             AND CAST(LOGINPROPERTY(sp.name, 'BadPasswordTime') AS DATETIME) > '19000101'
             THEN CAST(LOGINPROPERTY(sp.name, 'BadPasswordTime') AS DATETIME)
        ELSE NULL
      END                                            AS last_bad_password_time
FROM sys.server_principals AS sp
WHERE sp.type IN (
    'S',   -- SQL login
    'U',   -- Windows login
    'G',   -- Windows group
    'E',   -- External login (Entra)
    'X'    -- External group (Entra)
)
AND sp.name NOT LIKE '##%'
AND sp.name NOT IN ('sa', 'public')
ORDER BY
    CASE
        WHEN sp.is_disabled = 1 THEN 0
        WHEN sp.type = 'S'
             AND CAST(LOGINPROPERTY(sp.name, 'IsLocked') AS INT) = 1 THEN 1
        ELSE 2
    END,
    sp.name
    OPTION (MAXDOP 1);
```

**Key columns:**
- `login_status` — summarises whether the login is OK, DISABLED, LOCKED, or EXPIRED
- `bad_password_count` — number of failed password attempts since last successful login or reset
- `days_until_expiration` — NULL if expiration is not enabled; 0 or negative if already expired
- `is_policy_on` — whether Windows password policy is enforced for SQL logins

**What to do:**
| Finding | Recommendation |
|---------|----------------|
| `is_disabled = 1` | Login is explicitly disabled. If the user should have access, re-enable: `ALTER LOGIN [name] ENABLE` |
| `is_locked = 1` | Account locked out by password policy. Unlock: `ALTER LOGIN [name] WITH PASSWORD = '<new>' UNLOCK` |
| Login status = `EXPIRED` | Password has expired. Reset: `ALTER LOGIN [name] WITH PASSWORD = '<new>'` |
| `is_policy_on = 0` for SQL login | Password policy not enforced — security risk. Enable: `ALTER LOGIN [name] WITH CHECK_POLICY = ON` |
| `bad_password_count` is high | Someone is guessing passwords. Investigate source via Step 10 (login failure log) |
| Login exists but user reports "login failed" | Proceed to Step 5 to verify database-level user mapping |

---

### Step 3: Password Policy and Credential Health

> Execute with the SQL query tool. Provides a summary view of password policy compliance
> across all SQL logins. This step helps identify systemic credential risks.

> **Platform:** SQL Server (on-prem / IaaS) and Azure SQL Managed Instance only.
> On Azure SQL Database, password policy is enforced by the platform — skip this step.

```sql
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

IF @EngineEdition IN (5, 11, 12)
BEGIN
    SELECT 'Skipped — password policy is platform-managed on Azure SQL Database / Fabric.' AS skip_reason;
    RETURN;
END

SELECT
      COUNT(*)                                                          AS total_sql_logins
    , SUM(CASE WHEN CAST(LOGINPROPERTY(sp.name, 'IsPolicyChecked') AS INT) = 1
               THEN 1 ELSE 0 END)                                      AS policy_enforced
    , SUM(CASE WHEN CAST(LOGINPROPERTY(sp.name, 'IsPolicyChecked') AS INT) = 0
               THEN 1 ELSE 0 END)                                      AS policy_not_enforced
    , SUM(CASE WHEN CAST(LOGINPROPERTY(sp.name, 'IsExpirationChecked') AS INT) = 1
               THEN 1 ELSE 0 END)                                      AS expiration_enabled
    , SUM(CASE WHEN CAST(LOGINPROPERTY(sp.name, 'IsExpirationChecked') AS INT) = 0
               THEN 1 ELSE 0 END)                                      AS expiration_disabled
    , SUM(CASE WHEN sp.is_disabled = 1 THEN 1 ELSE 0 END)              AS disabled_logins
    , SUM(CASE WHEN CAST(LOGINPROPERTY(sp.name, 'IsLocked') AS INT) = 1
               THEN 1 ELSE 0 END)                                      AS locked_logins
    , SUM(CASE WHEN CAST(LOGINPROPERTY(sp.name, 'IsExpired') AS INT) = 1
               THEN 1 ELSE 0 END)                                      AS expired_passwords
    , SUM(CASE WHEN CAST(LOGINPROPERTY(sp.name, 'IsMustChange') AS INT) = 1
               THEN 1 ELSE 0 END)                                      AS must_change_passwords
    , SUM(CASE WHEN LOGINPROPERTY(sp.name, 'PasswordLastSetTime') IS NOT NULL
               AND DATEDIFF(DAY,
                   CAST(LOGINPROPERTY(sp.name, 'PasswordLastSetTime') AS DATETIME),
                   GETDATE()) > 90
               THEN 1 ELSE 0 END)                                      AS passwords_older_than_90d
FROM sys.server_principals AS sp
WHERE sp.type = 'S'   -- SQL logins only
  AND sp.name NOT LIKE '##%'
  AND sp.name <> 'sa'
  OPTION (MAXDOP 1);
```

**What to do:**
| Finding | Recommendation |
|---------|----------------|
| `policy_not_enforced > 0` | SQL logins without password policy. Enforce: `ALTER LOGIN [name] WITH CHECK_POLICY = ON` |
| `expiration_disabled` is high | Passwords never expire — acceptable for service accounts but risky for interactive users |
| `locked_logins > 0` | Active lockouts — investigate cause via Step 10. May indicate brute-force attempts |
| `expired_passwords > 0` | Users with expired passwords cannot log in. Reset or disable the logins |
| `passwords_older_than_90d` is high | Stale credentials — review password rotation policy |

---

### Step 4: Authentication Mode Check

> Execute with the SQL query tool. Determines whether SQL Server is configured for
> Windows Authentication Only or Mixed Mode (Windows + SQL Authentication).

> **Platform:** SQL Server (on-prem / IaaS) and Azure SQL Managed Instance only.
> Azure SQL Database always supports both SQL and Entra authentication — skip this step.

```sql
-- Guard: skip on Azure SQL Database (5), Fabric DW (11), and Fabric SQL DB (12) where
-- authentication mode is platform-managed.
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

IF @EngineEdition IN (5, 11, 12)
BEGIN
    SELECT 'Skipped — authentication mode is platform-managed on Azure SQL Database / Fabric. Both SQL and Entra authentication are always supported.' AS skip_reason;
    RETURN;
END

DECLARE @AuthMode INT = CAST(SERVERPROPERTY('IsIntegratedSecurityOnly') AS INT);

SELECT
      CASE @AuthMode
        WHEN 1 THEN 'Windows Authentication Only'
        WHEN 0 THEN 'Mixed Mode (Windows + SQL Authentication)'
      END                                           AS authentication_mode
    , @AuthMode                                     AS is_windows_only
    , CASE @AuthMode
        WHEN 1 THEN 'SQL logins will fail — only Windows/Kerberos/NTLM authentication is accepted'
        WHEN 0 THEN 'Both Windows and SQL authentication are accepted'
      END                                           AS mode_impact
    , (SELECT COUNT(*)
       FROM sys.server_principals
       WHERE type_desc = 'SQL_LOGIN'
         AND name NOT LIKE '##%'
         AND name <> 'sa')                          AS sql_login_count
    , (SELECT COUNT(*)
       FROM sys.server_principals
       WHERE type_desc IN ('WINDOWS_LOGIN', 'WINDOWS_GROUP'))
                                                    AS windows_login_count
    , (SELECT COUNT(*)
       FROM sys.server_principals
       WHERE type_desc IN ('EXTERNAL_LOGIN', 'EXTERNAL_GROUP'))
                                                    AS entra_login_count
    , CASE
        WHEN @AuthMode = 1
             AND EXISTS (SELECT 1 FROM sys.server_principals
                         WHERE type_desc = 'SQL_LOGIN'
                           AND name NOT LIKE '##%'
                           AND name <> 'sa'
                           AND is_disabled = 0)
        THEN 'WARNING — Active SQL logins exist but server is in Windows-only mode. These logins cannot authenticate.'
        ELSE ''
      END                                           AS mode_mismatch_warning
      OPTION (MAXDOP 1);
```

**What to do:**
| Finding | Recommendation |
|---------|----------------|
| `is_windows_only = 1` and user tries SQL auth | SQL logins are rejected. Either switch to Windows/Entra auth or change server to Mixed Mode (requires restart) |
| `mode_mismatch_warning` is not empty | Active SQL logins exist that can never authenticate — disable them or switch to Mixed Mode |
| `sql_login_count > 0` in Mixed Mode | Expected. Verify password policies are enforced (Step 3) |
| `entra_login_count > 0` | Entra authentication is configured. Proceed to Step 7 for detailed validation |

---

### Step 5: Database User Mapping and Orphan Detection

> Execute with the SQL query tool. Identifies database-level users, their authentication
> type, and detects orphaned users (users that have no matching server login).

> **Platform:** All platforms. This is the primary authentication check for Azure SQL Database
> and Fabric SQL Database where server-level views are not available.

```sql
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

SELECT TOP ({{TopN}})
      dp.name                                       AS user_name
    , dp.type_desc                                  AS user_type
    , dp.authentication_type_desc                   AS authentication_type
    , dp.create_date                                 AS created
    , dp.modify_date                                 AS last_modified
    , dp.default_schema_name                        AS default_schema
    , dp.sid                                        AS user_sid
    , CASE
        -- Contained database user (authenticates at database level)
        WHEN dp.authentication_type = 2
            THEN 'Contained user — authenticates directly against this database'
        -- External (Entra / AAD) user
        WHEN dp.authentication_type = 4
            THEN 'External (Entra/AAD) principal'
        -- Server-login-mapped user — check for orphan
        WHEN dp.authentication_type = 0
             AND dp.type IN ('S', 'U', 'G')
             AND dp.sid IS NOT NULL
             AND @EngineEdition NOT IN (5, 11, 12)   -- orphan check only on SQL Server / MI
             AND NOT EXISTS (
                 SELECT 1 FROM sys.server_principals sp
                 WHERE sp.sid = dp.sid
             )
            THEN 'ORPHANED — no matching server login found'
        -- Server-login-mapped, login exists
        WHEN dp.authentication_type = 0
             AND dp.type IN ('S', 'U', 'G')
             AND dp.sid IS NOT NULL
             AND @EngineEdition NOT IN (5, 11, 12)
             AND EXISTS (
                 SELECT 1 FROM sys.server_principals sp
                 WHERE sp.sid = dp.sid
             )
            THEN 'Mapped to server login'
        -- Azure SQL DB / Fabric — cannot check orphan from user DB context
        WHEN dp.authentication_type = 0
             AND dp.type IN ('S', 'U', 'G')
             AND @EngineEdition IN (5, 11, 12)
            THEN 'Server-login mapped (orphan check not available from user database)'
        ELSE ''
      END                                           AS mapping_status
    , (SELECT COUNT(*)
       FROM sys.dm_exec_sessions s
       WHERE s.security_id = dp.sid)                AS active_session_count
    , (SELECT STRING_AGG(r.name, ', ')
       FROM sys.database_role_members drm
       JOIN sys.database_principals r
         ON drm.role_principal_id = r.principal_id
       WHERE drm.member_principal_id = dp.principal_id)
                                                    AS role_memberships
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
    CASE
        WHEN dp.authentication_type = 0
             AND @EngineEdition NOT IN (5, 11, 12)
             AND NOT EXISTS (
                 SELECT 1 FROM sys.server_principals sp WHERE sp.sid = dp.sid
             )
        THEN 0  -- orphans first
        ELSE 1
    END,
    dp.name
    OPTION (MAXDOP 1);
```

**Key columns:**
- `mapping_status` — indicates whether the user is mapped, orphaned, contained, or external
- `authentication_type` — `NONE` (server-mapped), `DATABASE` (contained), `EXTERNAL` (Entra)
- `role_memberships` — all database roles the user belongs to
- `active_session_count` — currently active sessions for this principal

**What to do:**
| Finding | Recommendation |
|---------|----------------|
| `ORPHANED` user | No matching server login. Remap: `ALTER USER [username] WITH LOGIN = [loginname]` or drop if no longer needed |
| Contained user (`DATABASE` auth type) | Authenticates at database level — verify password policy is enforced. On Azure SQL DB, this is the default pattern |
| User exists but `active_session_count = 0` | User is not currently connected — may be legitimate or stale. Cross-reference with application team |
| User has no `role_memberships` | User has no role-based permissions — may rely on explicit grants (check Step 6) or may effectively have no access |
| Login failed but user exists here | Check the login status (Step 2) and permissions (Step 6) |

---

### Step 6: Permission and Role Membership Audit

> Execute with the SQL query tool. Identifies explicit DENY permissions, role membership
> chains, and effective permissions for database principals. A DENY always overrides a GRANT,
> which is a common source of "access denied" errors even when the user appears to have the
> right roles.

> **Platform:** All platforms.

#### Step 6a: Explicit DENY Permissions

```sql
SELECT TOP ({{TopN}})
      pr.name                                        AS principal_name
    , pr.type_desc                                   AS principal_type
    , dp.permission_name                             AS denied_permission
    , dp.state_desc                                  AS permission_state
    , CASE dp.class
        WHEN 0 THEN 'Database'
        WHEN 1 THEN 'Object: ' + ISNULL(OBJECT_SCHEMA_NAME(dp.major_id) + '.' + OBJECT_NAME(dp.major_id), CAST(dp.major_id AS NVARCHAR))
        WHEN 3 THEN 'Schema: ' + ISNULL(SCHEMA_NAME(dp.major_id), CAST(dp.major_id AS NVARCHAR))
        ELSE 'Class ' + CAST(dp.class AS NVARCHAR)
      END                                            AS scope
    , gpr.name                                       AS denied_by
FROM sys.database_permissions dp
JOIN sys.database_principals pr
  ON dp.grantee_principal_id = pr.principal_id
LEFT JOIN sys.database_principals gpr
  ON dp.grantor_principal_id = gpr.principal_id
WHERE dp.state_desc = 'DENY'
ORDER BY pr.name, dp.permission_name
OPTION (MAXDOP 1);
```

#### Step 6b: Role Membership Hierarchy

```sql
;WITH RoleHierarchy AS (
    SELECT
          drm.member_principal_id
        , drm.role_principal_id
        , m.name                                     AS member_name
        , m.type_desc                                AS member_type
        , r.name                                     AS role_name
        , 1                                          AS depth
        , CAST(r.name AS NVARCHAR(MAX))              AS role_chain
    FROM sys.database_role_members drm
    JOIN sys.database_principals m ON drm.member_principal_id = m.principal_id
    JOIN sys.database_principals r ON drm.role_principal_id = r.principal_id

    UNION ALL

    SELECT
          rh.member_principal_id
        , drm.role_principal_id
        , rh.member_name
        , rh.member_type
        , r2.name
        , rh.depth + 1
        , CAST(rh.role_chain + N' → ' + r2.name AS NVARCHAR(MAX))
    FROM RoleHierarchy rh
    JOIN sys.database_role_members drm
      ON rh.role_principal_id = drm.member_principal_id
    JOIN sys.database_principals r2
      ON drm.role_principal_id = r2.principal_id
    WHERE rh.depth < 10
)
SELECT DISTINCT TOP ({{TopN}})
      member_name
    , member_type
    , role_chain
    , depth                                          AS nesting_depth
FROM RoleHierarchy
WHERE member_type IN ('SQL_USER', 'WINDOWS_USER', 'WINDOWS_GROUP', 'EXTERNAL_USER', 'EXTERNAL_GROUP')
ORDER BY member_name, depth
OPTION (MAXDOP 1);
```

#### Step 6c: Effective Permissions for Current User

> This shows permissions for the **currently connected identity**, useful when the user reports
> "I cannot do X" and is connected to the session.

```sql
SELECT
      permission_name
    , subentity_name
    , 'DATABASE' AS scope
FROM fn_my_permissions(NULL, 'DATABASE')
ORDER BY permission_name
OPTION (MAXDOP 1);
```

**What to do:**
| Finding | Recommendation |
|---------|----------------|
| Explicit `DENY` on a user/role | DENY always wins over GRANT. Remove the DENY if the user should have access: `REVOKE <permission> ON <scope> FROM [principal]` |
| DENY inherited through nested role | User may not realise they inherit a DENY through role nesting. Check the `role_chain` to trace the path |
| User has no effective permissions | User cannot perform any operations. Grant appropriate role membership (e.g., `db_datareader`) or explicit permissions |
| User missing `CONNECT` permission | User cannot connect to the database at all. Grant: `GRANT CONNECT TO [username]` |
| High-privilege roles (`db_owner`, `db_securityadmin`) | Review whether these elevated roles are appropriate |

---

### Step 7: Entra ID (Azure AD) and Managed Identity Validation

> Execute with the SQL query tool. Validates Entra (Azure AD) principals configured in
> the database, including external users, groups, managed identities, and service principals.

> **Platform:** All platforms. Most relevant for Azure SQL Database and Managed Instance.
> On SQL Server on-prem, Entra auth requires Azure Arc or SQL Server 2022+ with Entra
> integration configured.

```sql
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

SELECT TOP ({{TopN}})
      dp.name                                        AS principal_name
    , dp.type_desc                                   AS principal_type
    , dp.authentication_type_desc                    AS authentication_type
    , dp.create_date                                 AS created
    , dp.modify_date                                 AS last_modified
    , dp.default_schema_name                         AS default_schema
    , CASE
        WHEN dp.type = 'E' THEN 'External User (Entra individual identity or managed identity)'
        WHEN dp.type = 'X' THEN 'External Group (Entra group — members inherit access)'
        ELSE dp.type_desc
      END                                            AS identity_description
    , (SELECT COUNT(*)
       FROM sys.dm_exec_sessions s
       WHERE s.security_id = dp.sid)                 AS active_session_count
    , (SELECT STRING_AGG(r.name, ', ')
       FROM sys.database_role_members drm
       JOIN sys.database_principals r
         ON drm.role_principal_id = r.principal_id
       WHERE drm.member_principal_id = dp.principal_id)
                                                     AS role_memberships
    , CASE
        WHEN (SELECT COUNT(*)
              FROM sys.database_permissions perm
              WHERE perm.grantee_principal_id = dp.principal_id
                AND perm.state_desc = 'DENY') > 0
            THEN 'WARNING — has explicit DENY permissions'
        ELSE 'No DENY'
      END                                            AS deny_status
FROM sys.database_principals dp
WHERE dp.type IN ('E', 'X')
  AND dp.name NOT IN ('dbo', 'guest', 'INFORMATION_SCHEMA', 'sys')
ORDER BY dp.type, dp.name
OPTION (MAXDOP 1);
```

**What to do:**
| Finding | Recommendation |
|---------|----------------|
| No Entra principals found | If Entra auth is expected, ensure the Entra admin is configured on the server (Azure Portal → SQL Server → Microsoft Entra admin) and users are created: `CREATE USER [user@domain.com] FROM EXTERNAL PROVIDER` |
| Entra user with `active_session_count = 0` | Identity exists but is not connected. Verify the Entra identity is still active in the tenant. Token acquisition may be failing on the client side |
| Entra user with no `role_memberships` | User has no role-based access. Grant: `ALTER ROLE db_datareader ADD MEMBER [user@domain.com]` |
| `deny_status` shows WARNING | Explicit DENY overrides any role-based GRANT. Review and remove if unintended |
| Managed identity principal not found | Ensure the identity is created: `CREATE USER [<resource-name>] FROM EXTERNAL PROVIDER`. The Azure resource must have a system-assigned or user-assigned managed identity enabled |
| Entra group (`type = 'X'`) with high-privilege roles | All members of the Entra group inherit these roles. Verify group membership in the Entra portal is appropriate |

---

### Step 8: Default Database Accessibility

> Execute with the SQL query tool. Checks whether server logins have a valid, accessible
> default database. A login whose default database is offline, dropped, or inaccessible will
> fail to connect unless the connection string explicitly specifies a different database.

> **Platform:** SQL Server (on-prem / IaaS) and Azure SQL Managed Instance only.
> On Azure SQL Database, connections always target a specific database — skip this step.

```sql
-- Guard: skip on Azure SQL Database (5), Fabric DW (11), and Fabric SQL DB (12) where
-- connections always target a specific database and sys.server_principals is not accessible.
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

IF @EngineEdition IN (5, 11, 12)
BEGIN
    SELECT 'Skipped — default database check is not applicable on Azure SQL Database / Fabric. Connections always target a specific database.' AS skip_reason;
    RETURN;
END

SELECT TOP ({{TopN}})
      sp.name                                        AS login_name
    , sp.type_desc                                   AS login_type
    , sp.default_database_name                       AS default_database
    , CASE
        WHEN d.database_id IS NULL
            THEN 'MISSING — default database does not exist'
        WHEN d.state <> 0
            THEN 'OFFLINE — default database state: ' + d.state_desc
        WHEN d.user_access <> 0
            THEN 'RESTRICTED — default database access: ' + d.user_access_desc
        WHEN HAS_DBACCESS(sp.default_database_name) = 0
            THEN 'NO ACCESS — login does not have access to default database'
        ELSE 'OK'
      END                                            AS default_db_status
    , d.state_desc                                   AS database_state
    , d.user_access_desc                             AS database_access_mode
FROM sys.server_principals sp
LEFT JOIN sys.databases d
  ON sp.default_database_name = d.name
WHERE sp.type IN ('S', 'U', 'G', 'E', 'X')
  AND sp.name NOT LIKE '##%'
  AND sp.name NOT IN ('sa', 'public')
  AND sp.is_disabled = 0
  AND (
      d.database_id IS NULL          -- default DB does not exist
      OR d.state <> 0                -- default DB is not ONLINE
      OR d.user_access <> 0          -- default DB has restricted access
  )
ORDER BY sp.name
OPTION (MAXDOP 1);
```

**Key columns:**
- `default_db_status` — summarises whether the default database is accessible
- `database_state` — current state of the default database (ONLINE, OFFLINE, RESTORING, etc.)

**What to do:**
| Finding | Recommendation |
|---------|----------------|
| `MISSING` — default database does not exist | The database was dropped or renamed. Change the login's default: `ALTER LOGIN [name] WITH DEFAULT_DATABASE = [master]` |
| `OFFLINE` — database not online | The database is in a non-online state. Fix the database issue, or change the default database |
| `RESTRICTED` — limited access | Database is in `SINGLE_USER` or `RESTRICTED_USER` mode. Wait for maintenance to complete or change the default |
| `NO ACCESS` — login cannot access default DB | Login lacks permissions on its default database. Either grant access or change the default database |
| No rows returned | All enabled logins have valid, accessible default databases — no issues |

---

### Step 9: Active Session Authentication Scheme Detection

> Execute with the SQL query tool. Analyses the authentication scheme used by currently
> active connections. This detects whether sessions are using Kerberos, NTLM, SQL authentication,
> or other methods. Kerberos vs NTLM fallback is a common source of authentication issues in
> domain environments.

> **Platform:** All platforms.

```sql
SELECT
      c.auth_scheme                                  AS authentication_scheme
    , COUNT(*)                                       AS session_count
    , (SELECT STRING_AGG(login_name, ', ')
       FROM (SELECT DISTINCT s2.login_name
             FROM sys.dm_exec_connections c2
             JOIN sys.dm_exec_sessions s2 ON c2.session_id = s2.session_id
             WHERE s2.is_user_process = 1 AND s2.session_id <> @@SPID
               AND c2.auth_scheme = c.auth_scheme) x)  AS sample_logins
    , (SELECT STRING_AGG(host_name, ', ')
       FROM (SELECT DISTINCT s2.host_name
             FROM sys.dm_exec_connections c2
             JOIN sys.dm_exec_sessions s2 ON c2.session_id = s2.session_id
             WHERE s2.is_user_process = 1 AND s2.session_id <> @@SPID
               AND c2.auth_scheme = c.auth_scheme) x)  AS sample_hosts
    , CASE c.auth_scheme
        WHEN 'SQL'     THEN 'SQL Server authentication (username/password)'
        WHEN 'NTLM'    THEN 'Windows NTLM — may indicate Kerberos failure or fallback'
        WHEN 'KERBEROS' THEN 'Windows Kerberos — preferred for domain authentication'
        WHEN 'NTML'    THEN 'Windows NTLM (legacy variant)'
        ELSE 'Other: ' + ISNULL(c.auth_scheme, 'unknown')
      END                                            AS scheme_description
    , CASE
        WHEN c.auth_scheme = 'NTLM' THEN
            'NTLM may indicate: missing/incorrect SPN, client not in domain, ' +
            'or Kerberos infrastructure issue. Check with setspn -L and klist on the client.'
        WHEN c.auth_scheme = 'SQL' THEN
            'SQL auth in use — consider migrating to Windows/Entra for better security.'
        ELSE ''
      END                                            AS diagnostic_note
FROM sys.dm_exec_connections c
JOIN sys.dm_exec_sessions s
  ON c.session_id = s.session_id
WHERE s.is_user_process = 1
  AND s.session_id <> @@SPID
GROUP BY c.auth_scheme
ORDER BY COUNT(*) DESC
OPTION (MAXDOP 1);
```

**What to do:**
| Finding | Recommendation |
|---------|----------------|
| All sessions using `NTLM` instead of `KERBEROS` | Kerberos is not working. Verify: (1) SPN is registered: `setspn -L <service_account>`, (2) client has Kerberos ticket: `klist`, (3) DNS resolves to FQDN, not IP |
| Mix of `KERBEROS` and `NTLM` | Some clients are falling back to NTLM — likely connecting via IP instead of FQDN, or missing SPN for an alias |
| All sessions using `SQL` auth | No Windows/Entra auth in use. If this is a domain environment, consider migrating to integrated authentication |
| `auth_scheme` is empty or unknown | Unusual — may indicate a very old client driver or non-standard connection method |

---

### Step 10: Login Failure Analysis from Error Log

> Execute with the SQL query tool. Retrieves recent login failure entries from the SQL
> Server error log. This is the most direct way to diagnose "Login failed" errors including the
> exact error reason, source IP, and timestamp.

> **Platform:** SQL Server (on-prem / IaaS) and Azure SQL Managed Instance only.
> On Azure SQL Database, the error log is not accessible via T-SQL — use Azure Monitor /
> Diagnostic Logs instead. Skip this step on Azure SQL DB and Fabric.

> **Note:** On SQL Server 2012+ (major version ≥ 11), `sp_readerrorlog` is used. This procedure
> is available on all supported SQL Server versions and Azure SQL MI.

```sql
-- Read login failures from the current error log (log file 0)
-- Filters to the last {{LoginFailureHours}} hours
-- Guard: skip on Azure SQL Database (EngineEdition 5), Fabric DW (11), and Fabric SQL DB (12) where
-- sp_readerrorlog is not available.
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

IF @EngineEdition IN (5, 11, 12)
BEGIN
    SELECT 'Skipped — sp_readerrorlog is not available on Azure SQL Database / Fabric. Use Azure Monitor Diagnostic Logs for login failure analysis.' AS skip_reason;
    RETURN;
END

CREATE TABLE #LoginFailures (
    LogDate     DATETIME,
    ProcessInfo NVARCHAR(256),
    LogText     NVARCHAR(MAX)
);

INSERT INTO #LoginFailures (LogDate, ProcessInfo, LogText)
EXEC sp_readerrorlog 0, 1, N'Login failed';

SELECT TOP ({{TopN}})
      LogDate                                        AS failure_time
    , LogText                                        AS failure_message
    , CASE
        WHEN LogText LIKE '%Reason:%'
            THEN SUBSTRING(LogText,
                 CHARINDEX('Reason:', LogText) + 8,
                 CHARINDEX('.', LogText, CHARINDEX('Reason:', LogText)) - CHARINDEX('Reason:', LogText) - 8)
        ELSE 'Reason not specified'
      END                                            AS failure_reason
    , CASE
        WHEN LogText LIKE '%CLIENT:%'
            THEN SUBSTRING(LogText,
                 CHARINDEX('CLIENT:', LogText) + 8,
                 CHARINDEX(']', LogText, CHARINDEX('CLIENT:', LogText)) - CHARINDEX('CLIENT:', LogText) - 8)
        ELSE 'Unknown'
      END                                            AS client_ip
    , CASE
        WHEN LogText LIKE '%user ''%'
            THEN SUBSTRING(LogText,
                 CHARINDEX('user ''', LogText) + 6,
                 CHARINDEX('''', LogText, CHARINDEX('user ''', LogText) + 6) - CHARINDEX('user ''', LogText) - 6)
        ELSE 'Unknown'
      END                                            AS attempted_login
FROM #LoginFailures
WHERE LogDate >= DATEADD(HOUR, -{{LoginFailureHours}}, GETDATE())
ORDER BY LogDate DESC
OPTION (MAXDOP 1);

-- Summary: failure count by attempted login and reason
SELECT
      CASE
        WHEN LogText LIKE '%user ''%'
            THEN SUBSTRING(LogText,
                 CHARINDEX('user ''', LogText) + 6,
                 CHARINDEX('''', LogText, CHARINDEX('user ''', LogText) + 6) - CHARINDEX('user ''', LogText) - 6)
        ELSE 'Unknown'
      END                                            AS attempted_login
    , COUNT(*)                                       AS failure_count
    , MIN(LogDate)                                   AS first_failure
    , MAX(LogDate)                                   AS last_failure
FROM #LoginFailures
WHERE LogDate >= DATEADD(HOUR, -{{LoginFailureHours}}, GETDATE())
GROUP BY
    CASE
        WHEN LogText LIKE '%user ''%'
            THEN SUBSTRING(LogText,
                 CHARINDEX('user ''', LogText) + 6,
                 CHARINDEX('''', LogText, CHARINDEX('user ''', LogText) + 6) - CHARINDEX('user ''', LogText) - 6)
        ELSE 'Unknown'
    END
ORDER BY COUNT(*) DESC
OPTION (MAXDOP 1);

DROP TABLE #LoginFailures;
```

**Common failure reasons and their meaning:**
| Error Text Pattern | Root Cause | Recommended Action |
|--------------------|------------|-------------------|
| `Login failed for user 'X'. Reason: Password did not match` | Wrong password | Verify credentials. Check for recent password change |
| `Login failed for user 'X'. Reason: Could not find a login matching the name provided` | Login does not exist | Create the login or fix the username in the connection string |
| `Login failed for user 'X'. Reason: The account is disabled` | Login is disabled | Re-enable if appropriate: `ALTER LOGIN [X] ENABLE` |
| `Login failed for user 'X'. Reason: The account is locked out` | Too many failed attempts | Unlock: `ALTER LOGIN [X] WITH PASSWORD = '<pwd>' UNLOCK` |
| `Login failed for user 'X'. Reason: The password of the account has expired` | Password expired | Reset: `ALTER LOGIN [X] WITH PASSWORD = '<new_pwd>'` |
| `Login failed for user 'X'. Reason: Token-based server access validation failed` | Entra token issue | Verify Entra admin is configured, identity exists, and token is valid |
| `Cannot open database "Y" requested by the login` | Default DB missing/offline | Change default DB: `ALTER LOGIN [X] WITH DEFAULT_DATABASE = [master]` |
| `Login failed for user 'X'. Reason: An attempt to login using SQL authentication failed. Server is configured for Windows authentication only` | Auth mode mismatch | Switch to Windows auth, or change server to Mixed Mode |
| Many failures from same `CLIENT:` IP in short period | Brute-force attempt | Consider blocking the IP via firewall. Review login auditing settings |

**What to do:**
| Finding | Recommendation |
|---------|----------------|
| Repeated failures for a single login | Credential issue — verify password, check expiry, check lock status (Step 2) |
| Failures for non-existent logins | Typo in connection string, or login was dropped. Create login or fix application config |
| Burst of failures from one IP | Possible brute-force attack. Block IP and review security policies |
| `Token-based` failures | Entra authentication issue — verify Entra admin config and client-side token acquisition |
| `Cannot open database` failures | Default database issue — see Step 8 |

---

Combine results from all steps into this unified report:

```
## Authentication Diagnostics Report
Database:   {{database name}}
Server:     {{server name}}
Date:       {{current date in YYYY-MM-DD format}}
Data Source: sys.server_principals, sys.sql_logins, sys.database_principals, sys.database_permissions, sys.dm_exec_connections, sp_readerrorlog
Parameters: TopN={{TopN}}, LoginFailureHours={{LoginFailureHours}}h
```

### Step 1 — Platform & Version
```
| Property               | Value                |
|------------------------|----------------------|
| Edition                | {{sql_edition}}      |
| Version                | {{sql_version}}      |
| Engine Type            | {{engine_type}}      |
| Authentication Mode    | {{auth_mode}}        |
| Server-Level Access    | {{has_server_level_access}} |
```

### Step 2 — Server Login Status
```
List all logins with their status (OK, DISABLED, LOCKED, EXPIRED).
Highlight any logins with bad_password_count > 0 or approaching expiration.
If on Azure SQL DB, note: "Skipped — server-level views not available. See Step 5 for database principals."
```

### Step 3 — Password Policy Summary
```
Show the summary counts: policy enforced vs not, expiration enabled vs not, locked/expired counts.
If on Azure SQL DB, note: "Skipped — password policy is platform-managed."
```

### Step 4 — Authentication Mode
```
State the current mode and note any mismatches (SQL logins on Windows-only server).
If on Azure SQL DB, note: "Skipped — Azure SQL DB supports both SQL and Entra auth."
```

### Step 5 — Database User Mapping
```
List all database users with their mapping status. Flag orphaned users prominently.
Show role memberships for each user.
```

### Step 6 — Permission Audit
```
List all explicit DENY permissions.
Show role hierarchy for users with nested roles.
Include effective permissions for the current user if relevant.
```

### Step 7 — Entra / Managed Identity Principals
```
List all external principals with their type, roles, and active session count.
If no Entra principals found, note whether Entra auth is expected.
```

### Step 8 — Default Database Accessibility
```
List any logins whose default database is missing, offline, or restricted.
If none found, state "All logins have accessible default databases."
If on Azure SQL DB, note: "Skipped — Azure SQL DB connections specify database explicitly."
```

### Step 9 — Authentication Scheme Distribution
```
Show breakdown of Kerberos / NTLM / SQL / other across active sessions.
Flag NTLM-only environments and provide SPN diagnostic guidance.
```

### Step 10 — Login Failures (Last {{LoginFailureHours}}h)
```
Show recent login failures with reason, source IP, and attempted login.
Include the summary count by login.
If on Azure SQL DB, note: "Skipped — use Azure Monitor Diagnostic Logs for login failure analysis."
```

### Summary & Recommended Next Steps
```
Provide:
1. Overall authentication health assessment
2. Top 3 most critical findings
3. Specific remediation commands for each finding
4. Recommendations for proactive security improvements
```

---

## Root Cause Decision Tree and Next Steps

### Login fails with "Password did not match" (Step 2/10)

**Root cause: Incorrect credentials.**

Next steps:
1. Verify the password with the user or application owner
2. Check if the password was recently changed: `LOGINPROPERTY('login', 'PasswordLastSetTime')`
3. If using a service account, check for password rotation in the secrets vault
4. If using connection string, verify no typo in `Password=` parameter

### Login fails with "Login does not exist" (Step 2/10)

**Root cause: Login name mismatch or login was dropped.**

Next steps:
1. Check exact spelling — SQL logins are case-sensitive on case-sensitive servers
2. Search for similar logins: `SELECT name FROM sys.server_principals WHERE name LIKE '%partial%'`
3. If the login was dropped, recreate it: `CREATE LOGIN [name] WITH PASSWORD = '<pwd>'`
4. For Entra users, verify the UPN matches exactly: `user@domain.com`

### Login disabled or locked out (Step 2/10)

**Root cause: Administrative action or account lockout policy.**

Next steps:
1. **Disabled:** Re-enable if appropriate: `ALTER LOGIN [name] ENABLE`
2. **Locked:** Unlock: `ALTER LOGIN [name] WITH PASSWORD = '<pwd>' UNLOCK`
3. **Repeated lockouts:** Investigate source IPs in the error log (Step 10) for brute-force
4. **Policy:** Review lockout threshold: check Windows Local Security Policy or Group Policy

### Password expired (Step 2/3)

**Root cause: Password expiration policy triggered.**

Next steps:
1. Reset the password: `ALTER LOGIN [name] WITH PASSWORD = '<new_pwd>'`
2. For service accounts, prefer a managed identity, gMSA, or Windows/Entra authentication over a SQL
   login. Do not disable password expiration
3. Implement password rotation automation for service accounts
4. Review expiration policy alignment with organizational standards

### Authentication mode mismatch (Step 4/10)

**Root cause: Server is in Windows-only mode but client uses SQL authentication, or vice versa.**

Next steps:
1. **To switch to Mixed Mode:** Change via SQL Server Configuration Manager or registry, then restart SQL Server
2. **To switch client to Windows auth:** Update connection string to use `Integrated Security=True`
3. **Entra auth:** Available on Azure SQL and SQL Server 2022+ with Azure Arc

### Orphaned database user (Step 5)

**Root cause: Server login was dropped or recreated with a different SID.**

Next steps:
1. **Remap to existing login:** `ALTER USER [username] WITH LOGIN = [loginname]`
2. **If login was recreated:** The SIDs won't match. Drop and recreate the user, or use `ALTER USER` with the new login
3. **Convert to contained user:** `ALTER USER [username] WITH PASSWORD = '<pwd>'` (removes server login dependency)
4. **Clean up:** If no longer needed, drop the user: `DROP USER [username]`

### Explicit DENY blocking access (Step 6)

**Root cause: DENY permission overrides any GRANT, including through role membership.**

Next steps:
1. Identify the DENY: review Step 6a output for the specific permission and scope
2. Remove the DENY: `REVOKE <permission> ON <scope> FROM [principal]` (REVOKE removes DENY)
3. Check for inherited DENY through nested roles (Step 6b role chain)
4. Do NOT use `GRANT` to override a `DENY` — it won't work. Must use `REVOKE`.

### Missing CONNECT permission (Step 6)

**Root cause: User exists in the database but cannot establish a connection to it.**

Next steps:
1. Grant CONNECT: `GRANT CONNECT TO [username]`
2. Verify the user is not in a role that has DENY CONNECT
3. Check if the database has restricted access mode (`SINGLE_USER` / `RESTRICTED_USER`)

### Entra / Managed Identity cannot connect (Step 7)

**Root cause: Entra principal not configured in the database, or token acquisition failure.**

Next steps:
1. **Missing principal:** Create: `CREATE USER [user@domain.com] FROM EXTERNAL PROVIDER` or `CREATE USER [managed-identity-name] FROM EXTERNAL PROVIDER`
2. **Entra admin not set:** Configure in Azure Portal → SQL Server → Microsoft Entra admin
3. **Token failure:** Verify on the client that MSAL can acquire a token for `https://database.windows.net/`
4. **Managed identity:** Ensure the Azure resource has managed identity enabled and the correct identity type (system vs user-assigned) is being used
5. **Conditional Access:** Check if MFA or Conditional Access policies are blocking the token request

### Default database inaccessible (Step 8/10)

**Root cause: Login's default database was dropped, is offline, or the login has no access.**

Next steps:
1. Change the default database: `ALTER LOGIN [name] WITH DEFAULT_DATABASE = [master]`
2. Client workaround: specify database in connection string: `Initial Catalog=<database>`
3. If the database is offline, investigate and bring it online before updating the default

### NTLM instead of Kerberos (Step 9)

**Root cause: Kerberos authentication failed and fell back to NTLM.**

Next steps:
1. **Verify SPN:** `setspn -L <SQL_service_account>` — must have `MSSQLSvc/<FQDN>:1433` and `MSSQLSvc/<FQDN>`
2. **Register SPN:** `setspn -S MSSQLSvc/<FQDN>:1433 <domain\service_account>`
3. **Client-side:** Ensure client connects using FQDN (not IP), and has a valid Kerberos ticket (`klist`)
4. **DNS:** Verify forward and reverse DNS resolution is correct
5. **Delegation:** If using linked servers or double-hop, configure constrained delegation

### Brute-force / repeated login failures from single IP (Step 10)

**Root cause: Automated attack or misconfigured application retrying with bad credentials.**

Next steps:
1. **Immediate:** Block the source IP via firewall (Azure: server-level firewall rule; on-prem: Windows Firewall or network device)
2. **Investigate:** Determine if the IP is internal (misconfigured app) or external (attack)
3. **Harden:** Enable login auditing (`Both failed and successful logins`), enforce password policy, consider Azure AD auth
4. **Monitor:** Set up alerts for login failure spikes using SQL Agent or Azure Monitor
