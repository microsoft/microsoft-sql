# Step 6 - Security Exposure Snapshot

## Disclosure Rules

Return counts and categories by default. Principal names, endpoint addresses, service accounts,
and paths require `IncludeSensitiveText = true`.

This step detects immediate exposure. A full durable security review belongs to a dedicated
security/best-practices workflow.

## HA-SEC-001: Authentication Mode and `sa`

```sql
SELECT
    CAST(SERVERPROPERTY('IsIntegratedSecurityOnly') AS int) AS windows_authentication_only,
    (SELECT sp.is_disabled
     FROM sys.server_principals AS sp
     WHERE sp.sid = 0x01) AS sa_is_disabled,
    (SELECT sl.is_policy_checked
     FROM sys.sql_logins AS sl
     WHERE sl.sid = 0x01) AS sa_password_policy_checked,
    (SELECT sl.is_expiration_checked
     FROM sys.sql_logins AS sl
     WHERE sl.sid = 0x01) AS sa_password_expiration_checked
OPTION (MAXDOP 1);
```

Enabled `sa` is `WARN/HIGH` and may be `FAIL/HIGH` when interactive SQL authentication is exposed.
Do not reveal renamed principal text.

## HA-SEC-002: High-Privilege Principal Counts

SQL Server 2012-safe aggregation without `STRING_AGG`:

```sql
SELECT
    role_principal.name AS server_role,
    COUNT(*) AS member_count,
    SUM(CASE WHEN member_principal.is_disabled = 0 THEN 1 ELSE 0 END) AS enabled_member_count,
    SUM(CASE WHEN member_principal.type_desc = N'SQL_LOGIN'
             AND member_principal.is_disabled = 0 THEN 1 ELSE 0 END)
        AS enabled_sql_login_count
FROM sys.server_role_members AS rm
JOIN sys.server_principals AS role_principal
  ON role_principal.principal_id = rm.role_principal_id
JOIN sys.server_principals AS member_principal
  ON member_principal.principal_id = rm.member_principal_id
WHERE role_principal.name IN (N'sysadmin', N'securityadmin', N'serveradmin')
GROUP BY role_principal.name
ORDER BY role_principal.name
OPTION (MAXDOP 1);
```

Counts are evidence, not automatic failures. Unexpected membership requires a supplied approved
access model. Delegate authentication issues to `authentication-diagnostics`.

## HA-SEC-003: Risky Server Options

```sql
SELECT
    c.name,
    c.value_in_use
FROM sys.configurations AS c
WHERE c.name IN (
    N'Ad Hoc Distributed Queries',
    N'clr enabled',
    N'cross db ownership chaining',
    N'Database Mail XPs',
    N'Ole Automation Procedures',
    N'remote access',
    N'remote admin connections',
    N'scan for startup procs',
    N'show advanced options',
    N'xp_cmdshell'
)
ORDER BY c.name
OPTION (MAXDOP 1);
```

Enabled `xp_cmdshell`, OLE Automation, ad hoc distributed queries, or cross-database ownership
chaining is `WARN` pending a documented requirement and control review. Feature availability alone
is not a vulnerability.

## HA-SEC-004: Database Exposure Flags

```sql
SELECT
    d.name AS database_name,
    d.owner_sid,
    d.containment_desc,
    d.is_trustworthy_on,
    d.is_db_chaining_on,
    d.is_broker_enabled,
    d.is_encrypted,
    d.page_verify_option_desc
FROM sys.databases AS d
WHERE ({{IncludeSystemDatabasesBit}} = 1 OR d.database_id > 4)
  AND {{DatabaseNamePredicate}}
ORDER BY d.name
OPTION (MAXDOP 1);
```

Redact owner identity by retaining only `owner_sid` presence/mapping status unless sensitive output
is enabled. `TRUSTWORTHY` or database chaining is a review signal whose severity depends on owner,
module signing, and cross-database requirements. `is_encrypted = 0` is not automatically a failure
without an encryption requirement.

## HA-SEC-005: Current Connection Encryption

```sql
SELECT
    encrypt_option,
    auth_scheme,
    net_transport,
    protocol_type
FROM sys.dm_exec_connections
WHERE session_id = @@SPID
OPTION (MAXDOP 1);
```

This proves only the current session state, not the server-wide force-encryption configuration.
Report it as `INFO`; do not claim all connections are encrypted.

## HA-SEC-006: Publicly Enabled SQL Logins Count

```sql
SELECT
    COUNT(*) AS enabled_sql_login_count,
    SUM(CASE WHEN is_policy_checked = 0 THEN 1 ELSE 0 END)
        AS enabled_sql_logins_without_policy_count
FROM sys.sql_logins
WHERE is_disabled = 0
  AND sid <> 0x01
OPTION (MAXDOP 1);
```

This is exposure inventory. Severity depends on network reachability, credential controls,
approved identities, and authentication policy.
