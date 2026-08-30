---
name: entra-id-auth
description: >-
  Takes an application identity to a working passwordless connection to Azure SQL Database, and
  diagnoses it when that fails: sets the Microsoft Entra administrator, creates the database user
  for a managed identity or service principal, grants roles, and writes the driver's
  authentication keyword. Use when a user asks to "set up Microsoft Entra authentication for Azure
  SQL", "connect with a managed identity", "stop putting the database password in configuration",
  or "turn on Microsoft Entra-only authentication". Owns every failure arriving after a credential
  has been evaluated: Msg 33134 "Principal could not be resolved", Msg 33131 "duplicate display
  name", 18456 "Login failed for user" and a login naming a token-identified principal, and 4060,
  "Cannot open database requested by the login, the login failed", usually a missing database
  user. What fails before that, transport, pre-login, certificates and timeouts, belongs to
  diagnose-connection-errors, and drivers and pooling to the connect skills.
---

# Microsoft Entra ID authentication for an application identity

Getting an application onto a passwordless connection is an ordered procedure whose failures do not
arrive in order. Steps succeed while achieving nothing, and the one error that does arrive names
the wrong component.

Verified against Microsoft Learn, Azure CLI 2.89.1 and sqlcmd 1.10.0 on 2026-08-27. Every message
and keyword below is sourced in `references/`.

## What this skill owns, and what it does not

**Owns** the server-side identity configuration, the database user, the grant, the authentication
keyword in the connection string, and every failure about **who the caller is**. **Does not own**
the following, so route them rather than answering here.

| Question | Skill |
|---|---|
| Retry, encryption, pool sizing, the connection model | `connect-to-azure-sql` |
| Installing the driver and per-language syntax | `connect-from-dotnet`, `connect-from-python`, `connect-from-typescript-and-node` |
| Creating the server, the database and the firewall rule | `provision-azure-sql-db` |
| Transport failures, pre-login, certificates, timeouts, the `40xxx` gateway family | `diagnose-connection-errors` |
| Which roles the application should hold | `least-privilege-database-roles` |
| Server-level Entra logins and fixed server roles | `entra-logins-and-server-roles` |
| Wiring identity through a hosting service | `managed-identity-across-azure-services` |
| The deployment itself, `azd`, infrastructure | `deploy-app-to-azure`, which hands the database-side grant back here |

**The split with `diagnose-connection-errors`, stated once.** That skill owns every failure that
happens before a credential is evaluated. This one owns every failure after it: `18456`, `4060`,
`33134`, `33131` and `37545`. A failure carrying no SQL error number is not this skill.

## 18456 and 4060 arrive after the credential

Both read as "login failed", neither is a network problem, and no edit to the server name,
encryption or timeout in the connection string fixes either.

- **`18456`** means the credential was evaluated and refused. Naming
  `<token-identified principal>` it means the opposite of what it looks like: the token was
  **accepted**, and no matching principal exists in the database.
- **`4060`** means the login is valid and has no user in **that** database. After a successful
  deployment that is almost always a missing database user, because a login lives on the server, a
  user lives in the database, and deployment tooling creates neither.

Both are answered by step 5 below, run on the user database. `40532` reads the same and is
neither: it is the gateway refusing before a database was reached, and telling the three apart is
`diagnose-connection-errors`. Exact text for each is in
[references/identity-errors.md](references/identity-errors.md).

## The order that works

Each step names the failure it prevents. Steps 2, 5 and 7 are the ones that fail quietly.

1. **Set the Microsoft Entra administrator on the logical server.** Nothing works until it exists,
   and the CLI takes an object id rather than a name, so look the id up first.

   ```bash
   az ad user list --display-name "<display name>" --query "[].{id:id, upn:userPrincipalName}" -o table
   az sql server ad-admin create -g <resource-group> -s <server> \
     --display-name "<display name>" --object-id <object-id>
   az sql server ad-admin list -g <resource-group> -s <server> -o table
   ```

2. **Decide whether the logical server needs its own identity.** It does **only** if a service
   principal, rather than a signed-in person, will run the `CREATE USER` statement. That is the
   normal case for a pipeline. See [Msg 33134](#msg-33134-does-not-mean-what-it-says).

3. **Give the application an identity.** A managed identity on the hosting resource, or an app
   registration if the workload runs outside Azure.

4. **Connect to the user database with a Microsoft Entra authenticated connection.** Not `master`,
   and not a SQL login.

   ```bash
   sqlcmd -S <server>.database.windows.net -d <database> -U <admin-upn> -G -l 30
   ```

5. **Create the database user.** `CREATE USER` adds the user to the **current** database, so the
   database in step 4 is the one that gets it.

   ```sql
   CREATE USER [<identity-name>] FROM EXTERNAL PROVIDER;
   ```

6. **Grant roles, and name them.** Add `db_ddladmin` only if the application really applies schema.

   ```sql
   ALTER ROLE db_datareader ADD MEMBER [<identity-name>];
   ALTER ROLE db_datawriter ADD MEMBER [<identity-name>];
   ```

7. **Write the connection string.** Every driver spells the authentication keyword differently and
   there is no shared vocabulary. See
   [the per-driver table](#the-authentication-keyword-is-not-the-same-string-twice).

8. **Verify from the database, not from the application.** The queries are below.

## The steps that fail without saying so

| What happens | Why nothing reports it | How it surfaces later |
|---|---|---|
| `CREATE USER` is run against `master` | It is valid there and succeeds. `CREATE USER` "adds a user to the current database" | The application connects to the user database and fails, with correct code |
| The database user is never created | Deployment tooling has no view into the database | A login failure naming `<token-identified principal>`, which reads as a bad credential |
| Roles are granted after the application first connected | The host caches the identity token and refreshes it only on expiry | The grant is correct and the application keeps failing until the cache turns over |
| `WITH OBJECT_ID` is used without a name suffix | The statement succeeds | Nothing records which principal the user is for |
| The server identity is deleted or loses its permission | Nothing in the database changes | Entra authentication stops working, later, for everyone |

## Msg 33134 does not mean what it says

```output
Msg 33134, Level 16, State 1, Line 1
Principal 'test-user' could not be resolved.
Error message: 'Server identity is not configured. ...'
```

The first line sends an agent to check the principal name. The principal name is almost always
fine. **The fault is on the logical server**, and the mechanism explains why the same statement
works by hand and fails in a pipeline:

- When a **Microsoft Entra user** runs `CREATE USER`, the service impersonates that user and
  queries Microsoft Graph with the user's own permissions. The server identity is not involved.
- When a **service principal** runs it, an application cannot impersonate another application, so
  the engine falls back to the **server identity**. If the logical server has no identity, or that
  identity cannot read Microsoft Graph, the lookup fails and the message blames the principal.

Three ways out, in order of how much tenant privilege they need. The commands and the exact Graph
permissions are in [references/identity-errors.md](references/identity-errors.md).

1. **Assign the server identity and grant it Microsoft Graph read**, either the three application
   permissions or the broader `Directory Readers` role. Both need a `Privileged Role
   Administrator` and a script.
2. **Put the server identity in a role-assignable group holding `Directory Readers`.** The
   production shape, because a group owner can then add servers without that administrator.
3. **Skip the lookup.** A form of `CREATE USER` exists that never consults Microsoft Graph, which
   is the answer wherever the tenant privilege is not available, in practice most pipelines.

## Three forms of CREATE USER, and when each is forced

| Form | Looks the principal up | Use it when |
|---|---|---|
| `CREATE USER [<name>] FROM EXTERNAL PROVIDER;` | Yes | The default. A person is running it, or the server identity is configured |
| `CREATE USER [<alias>] FROM EXTERNAL PROVIDER WITH OBJECT_ID = '<object-id>';` | Yes | The display name is **not unique** in the tenant, so the plain form fails |
| `CREATE USER [<name>] WITH SID = <id-as-binary>, TYPE = E;` | **No** | No Graph permission is available, or Msg 33134 has to be worked around |

**`WITH OBJECT_ID` is not the general fix, and it is not what answers Msg 33134.** It exists for
one problem: Microsoft Entra ID permits duplicate display names for applications, and the engine
requires a unique name. The duplicate produces a different error.

```output
Msg 33131, Level 16, State 1, Line 4
Principal 'myapp' has a duplicate display name.
```

Two traps in the `OBJECT_ID` form: the object id must exist in this tenant or the statement fails
with `Msg 37545`, and the **Object ID on an app registration is not the Object ID of its service
principal**. This clause wants the enterprise application one, and the documentation warns about
exactly that pair.

The `SID` and `TYPE` form has its own trap: for a **user or a group** the value is the Microsoft
Entra **object id**, but for a **service principal or a managed identity** it is the **application
(client) id**. `TYPE = E` covers users, applications and managed identities, `TYPE = X` groups.
Nothing validates it, so a wrong id creates a user no token will ever match. Worked T-SQL for all
three cases is in [references/identity-errors.md](references/identity-errors.md).

## A SQL-authenticated administrator cannot do any of this

> Only Microsoft Entra users can create other Microsoft Entra users in Azure SQL Database. No users
> based on SQL authentication, including the server admin, can create a Microsoft Entra user.

That is why "I am the admin and it still fails" is a common dead end. The permission needed is
`ALTER ANY USER`, carried by `db_owner`, but no database permission substitutes for the connection
itself being Entra authenticated.

## The name to put in the brackets

Getting this wrong produces `Msg 33134` or `Msg 33131` and looks like a permissions problem.

| Principal | The name |
|---|---|
| A person | Their user principal name |
| A group | Its display name |
| An app registration or a user-assigned managed identity | Its display name |
| A system-assigned managed identity | The name of the Azure resource that owns it |
| A system-assigned identity on a deployment slot | `<app-name>/slots/<slot-name>` |

The slot form is the one nobody guesses, and an application that works in production and fails in a
staging slot is usually missing that user.

## The authentication keyword is not the same string twice

This is the highest-risk line in any passwordless configuration, because every value below is
plausible in every driver and each one is only valid in one of them.

| Stack | Passwordless default | Managed identity, explicit | User-assigned client id goes in |
|---|---|---|---|
| .NET, `Microsoft.Data.SqlClient` | `Authentication=Active Directory Default` | `Active Directory Managed Identity`, alias `Active Directory MSI` | `User Id=` |
| Python, `mssql-python` | `Authentication=ActiveDirectoryDefault` | `Authentication=ActiveDirectoryMSI` | `UID=` |
| Python, `pyodbc` on ODBC Driver 18 | **no such value exists** | `Authentication=ActiveDirectoryMsi` | `UID=`, but see below |
| Node.js, `mssql` on `tedious` | `authentication: { type: 'azure-active-directory-default' }` | `azure-active-directory-msi-app-service`, `azure-active-directory-msi-vm` | `authentication.options.clientId` |
| Java, the Microsoft JDBC driver | `authentication=ActiveDirectoryDefault` | `ActiveDirectoryManagedIdentity`, alias `ActiveDirectoryMSI` | `msiClientId`, or `user` |
| `sqlcmd` | `--authentication-method=ActiveDirectoryDefault` | `ActiveDirectoryManagedIdentity` or `ActiveDirectoryMSI` | not applicable |

Five facts a plausible guess gets wrong:

- **ODBC has no `ActiveDirectoryDefault`.** Its whole set is `SqlPassword`,
  `ActiveDirectoryIntegrated`, `ActiveDirectoryInteractive`, `ActiveDirectoryMsi`,
  `ActiveDirectoryServicePrincipal` and the deprecated `ActiveDirectoryPassword`. So **Python is two
  stories**: `mssql-python` has a default mode, `pyodbc` does not.
- **ODBC spells it `ActiveDirectoryMsi`**, mixed case. `ActiveDirectoryMSI` belongs to
  `mssql-python` and JDBC, and `ActiveDirectoryManagedIdentity` exists in neither Python driver.
- **ODBC does not always take the client id.** For a user-assigned identity, `UID` is the client id
  on a small set of hosts and the **object id** everywhere else.
- **In Node.js the client id is nested**, in `authentication.options.clientId`, not the connection
  `options` bag beside `encrypt`. The driver reads only the nested one.
- **Spaces belong to .NET only.** Every other driver writes the same idea without them.

**`Microsoft.Data.SqlClient` 7.0 is a breaking change for all of this.** The core package no longer
carries the Entra dependencies, and any `Active Directory *` mode needs the
`Microsoft.Data.SqlClient.Extensions.Azure` package added. Connection strings are unchanged. In the
same release `ActiveDirectoryPassword` became `[Obsolete]`.

`Active Directory Password`, in whichever spelling, is deprecated across the drivers: it rests on
the resource owner password credentials grant, is incompatible with mandatory multifactor
authentication, and may already fail in a tenant that enforces it.

## System-assigned or user-assigned

Two independent decisions get confused, because both use the same words.

- **The server identity** is what the logical server uses to read Microsoft Graph. On Azure SQL
  Database it is optional and only needed for the service-principal path in step 2. Either kind
  works, and a user-assigned one survives deleting the server and can hold the Graph permissions
  once for many servers.
- **The application identity** is what the application authenticates as. A system-assigned identity
  shares the lifetime of its resource and cannot be shared; a user-assigned identity is a standalone
  resource and can be attached to several.

What changes in the connection string: **nothing for system-assigned**. A user-assigned identity
must name its client id, because the host may carry several and the token request is otherwise
ambiguous. Which keyword carries it is in the table above.


## Microsoft Entra-only authentication

Enabling it disables SQL authentication at the **server** level, for every database on it and for
the server administrator too. Existing SQL logins and users are not removed, and new ones can still
be created; they simply cannot connect.

```bash
az sql server ad-only-auth enable -g <resource-group> -n <server>
az sql server ad-only-auth get -g <resource-group> -n <server>
```

```sql
SELECT SERVERPROPERTY('IsExternalAuthenticationOnly');   -- 1 on, 0 off
```

Three things that are easy to get wrong. **The Microsoft Entra administrator must be set first**, or
enabling fails through every interface. Once enabled, the administrator **cannot be removed** until
it is disabled again. And the two Azure roles are deliberately split, so no single narrow role both
sets the administrator and toggles the setting.

Turning it on also turns off elastic jobs, SQL Data Sync, SQL Insights, `EXEC AS` for members of a
Microsoft Entra group, and some change data capture paths. Check that list against the workload
before enabling it on a server that already has work running on it.

**Enforcing it takes two Azure Policy definitions, not one**, because one evaluates a server at
creation and the other the setting on an existing server, and neither covers the other's gap.
Assign the initiative holding both. Names and effects are in
[references/entra-only-and-policy.md](references/entra-only-and-policy.md).

## Verify it actually worked

Run against the **user database**, not `master`.

```sql
SELECT name, type, type_desc, authentication_type_desc,
       CAST(CAST(sid AS varbinary(16)) AS uniqueidentifier) AS entra_id
FROM sys.database_principals
WHERE authentication_type_desc = 'EXTERNAL';
```

`entra_id` is the check that matters: for an application it is the client id, and a row carrying
the wrong one looks exactly like success. The role membership query and the server-side checks are
in the reference.

## References

- [references/identity-errors.md](references/identity-errors.md): each identity error number with
  its verbatim text and real cause, the three forms of `CREATE USER` with worked T-SQL, and which
  identifier each one wants. Read it when a statement failed.
- [references/driver-auth-keywords.md](references/driver-auth-keywords.md): the complete accepted
  set of authentication values per driver. Read it before writing one.
- [references/entra-only-and-policy.md](references/entra-only-and-policy.md): Entra-only
  authentication in full, and the two Azure Policy definitions with their identifiers.

Tenant-side role assignment changes, so fetch the Learn articles on service principal setup and the
Directory Readers role rather than recalling them.

## Validation rules

- The Microsoft Entra administrator was read back from the server before any `CREATE USER` was run.
- The connection that ran `CREATE USER` was Entra authenticated and was on the user database.
- The principal appears in `sys.database_principals` of the **user database** with
  `authentication_type_desc = 'EXTERNAL'`, and its stored id matches the running identity.
- The roles granted are named and justified, not inherited from whatever a one-command tool applied.
- The authentication keyword is one the chosen driver documents, checked rather than transposed.
- The connection string carries no password and no user name, unless that user name is a
  user-assigned identity's client id.
- If Entra-only authentication was enabled, the administrator was set first and the disabled
  features were stated.
- A login failure was answered at the layer that raised it: `18456` as a login, a secret or a
  missing database user, `4060` as a missing user in the database that was asked for, and neither
  as a firewall rule or a connection-string edit.

## Do not

- Do not answer `Msg 33134` by editing the principal name. Check the logical server identity and its
  Microsoft Graph permission first.
- Do not reach for `WITH OBJECT_ID` as a general fix. It answers `Msg 33131`, a duplicate display
  name, and nothing else, and it wants the enterprise application object id, not the app
  registration one.
- Do not run `CREATE USER FROM EXTERNAL PROVIDER` on `master` and report the identity as configured.
- Do not attempt the create from a SQL-authenticated connection, including as server administrator.
  No permission grant makes that work.
- Do not transpose an authentication keyword between drivers, and never write
  `ActiveDirectoryDefault` into an ODBC connection string.
- Do not use `Active Directory Password` in any spelling. It is deprecated and fails under enforced
  multifactor authentication.
- Do not put a client secret in a connection string when the workload runs on Azure. That is what
  the managed identity is for.
- Do not enable Microsoft Entra-only authentication on a shared server without naming what it turns
  off, and do not assign a single Azure Policy definition and call the estate enforced.
- Do not grant `CONTROL ON DATABASE` because a tool did. Hand role design to
  `least-privilege-database-roles`.
- Do not conclude that a grant failed until the identity token cache has turned over. The grant can
  be correct and the application still refused.

## Checklist before reporting success

- [ ] Server administrator confirmed by reading it back, not by having run the command
- [ ] The creating connection was Entra authenticated, on the user database
- [ ] `sys.database_principals` shows the principal, and its stored id matches the real identity
- [ ] Roles are named, and no wider grant was left in place
- [ ] The connection string keyword matches the driver in use, character for character, and a
      user-assigned client id is in the keyword that driver reads
- [ ] For .NET on 7.0 or later, the Entra extension package is referenced
