---
name: entra-id-auth
description: >-
  Takes an application identity to a working passwordless connection to Azure SQL Database, and
  diagnoses it when that fails: sets the Microsoft Entra administrator, creates the database user
  for a managed identity or service principal, grants roles, and writes the driver's
  authentication keyword. Use when a user asks to "set up Microsoft Entra authentication for Azure
  SQL", "connect with a managed identity", "stop putting the database password in configuration",
  or "turn on Microsoft Entra-only authentication", and for the container's database side once its
  MSSQL_AAD_ variables are set. Owns every failure arriving after a credential was evaluated: Msg
  33134 "Principal could not be resolved", Msg 33131 "duplicate display name", 18456 "Login failed
  for user" and a login naming a token-identified principal, and 4060 "Cannot open database". What
  fails before that, transport, pre-login, certificates and timeouts, belongs to
  diagnose-connection-errors, and drivers and pooling to the connect skills.
---

# Microsoft Entra ID authentication for an application identity

Getting an application onto a passwordless connection is an ordered procedure whose failures do not
arrive in order: steps succeed while achieving nothing, and the errors name the wrong component.

Every flag below was read from the tool on 2026-09-03: Azure CLI 2.90.0, `sqlcmd` 1.10.0, `azd`
1.32.0. The container behaviour was measured the same day. Cloud engine behaviour and message text
are from Microsoft Learn, cited in `references/`.

## What this skill owns, and what it does not

**Owns** the server-side identity configuration, the database user, the grant, the authentication
keyword, and every failure about **who the caller is**. Route the rest.

| Question | Skill |
|---|---|
| Retry, encryption, pooling, and whether the container has Entra ID configured at all | `connect-to-azure-sql` |
| Drivers and per-language syntax | `connect-from-dotnet`, `connect-from-python`, `connect-from-typescript-and-node` |
| The server, the database, the firewall rule | `provision-azure-sql-db` |
| Transport, pre-login, certificates, timeouts, the `40xxx` gateway family | `diagnose-connection-errors` |
| Which roles the application should hold | `least-privilege-database-roles` |
| Server-level Entra logins and fixed server roles | `entra-logins-and-server-roles` |
| Identity through a hosting service, and the deployment | `managed-identity-across-azure-services`, `deploy-app-to-azure` |

**The split, stated once.** `diagnose-connection-errors` owns every failure before a credential is
evaluated; this skill owns every failure after it: `18456`, `4060`, `33134`, `33131`, `37545`. A
failure carrying no SQL error number is neither.

## 18456 and 4060 arrive after the credential

Both read as "login failed", neither is a network problem, and no edit to the server name,
encryption or timeout fixes either one.

- **`18456`** means the credential was evaluated and refused. Naming
  `<token-identified principal>` it means the opposite of what it looks like: the token was
  **accepted**, and no matching principal exists in the database.
- **`4060`** means the login is valid and has no user in **that** database. After a deployment that
  is almost always a missing database user: a login lives on the server, a user lives in the
  database, and deployment tooling creates neither.

Both are answered by step 5, run on the user database. `40532` reads the same and is the gateway
refusing before a database was reached, so it is `diagnose-connection-errors`.

## The order that works

Steps 2, 5 and 7 are the ones that fail quietly.

1. **Set the Microsoft Entra administrator on the logical server.** Nothing works until it exists,
   and the CLI takes an object id rather than a name, so look it up first.

   ```bash
   az ad user list --display-name "<display name>" --query "[].{id:id, upn:userPrincipalName}" -o table
   az sql server ad-admin create -g <resource-group> -s <server> \
     --display-name "<display name>" --object-id <object-id>
   ```

2. **Decide whether the logical server needs its own identity.** It does **only** if a service
   principal, rather than a signed-in person, runs `CREATE USER`, which is the normal case for a
   pipeline. See [Msg 33134](#msg-33134-does-not-mean-what-it-says).

3. **Give the application an identity, and take its client id from the deployment, not the portal.**
   `azd` prints the client id among the environment values only if the infrastructure declared it
   as an output, so add that output rather than copying a GUID.

   ```bash
   azd env get-values -e <environment>
   az ad sp show --id <application-client-id> --query "{appId:appId, objectId:id}"
   ```

   `appId` is the client id, which step 5 wants. `objectId` is the enterprise application object id,
   which only `WITH OBJECT_ID` wants. They are not interchangeable.

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

6. **Grant roles, and name them.** Add `db_ddladmin` only if the application applies schema.

   ```sql
   ALTER ROLE db_datareader ADD MEMBER [<identity-name>];
   ALTER ROLE db_datawriter ADD MEMBER [<identity-name>];
   ```

7. **Write the connection string**, from
   [the per-driver table](#the-authentication-keyword-is-not-the-same-string-twice).

8. **Check it worked from the database**, below.

## The steps that fail without saying so

| What happens | Why nothing reports it | How it surfaces later |
|---|---|---|
| `CREATE USER` runs against `master` | It is valid there and succeeds | The application fails against the user database, with correct code |
| Roles are granted after the application first connected | The host caches the token until expiry | The grant is correct and the application keeps failing until the cache turns over |

## Msg 33134 does not mean what it says

```output
Msg 33134, Level 16, State 1, Line 1
Principal 'test-user' could not be resolved.
Error message: 'Server identity is not configured. ...'
```

The first line sends an agent to check the principal name, which is almost always fine. **The fault
is on the logical server.** A **Microsoft Entra user** running `CREATE USER` is impersonated and
Graph is queried with that user's permissions, but an application cannot impersonate another
application, so a **service principal** falls back to the **server identity**. If the server has
none, or it cannot read Graph, the lookup fails and the message blames the principal, which is why
the same statement works by hand and fails in a pipeline.

```bash
az sql server update -g <resource-group> -n <server> -i
az sql server show -g <resource-group> -n <server> --query identity
```

**The flag is `-i`, long form `--assign_identity` with an underscore.** Measured 2026-09-03 on Azure
CLI 2.90.0: the hyphenated `--assign-identity` exits with `unrecognized arguments`, so a script
carrying it assigns nothing and the next `CREATE USER` still raises `33134`.

Then, in order of tenant privilege needed: grant that identity Microsoft Graph read, either three
application permissions or the broader `Directory Readers` role, both needing a `Privileged Role
Administrator`; or put it in a role-assignable group holding `Directory Readers`, the production
shape because a group owner can then add servers; or skip the lookup entirely with the third
`CREATE USER` form below, which is the answer wherever that privilege is absent. Open
[references/identity-errors.md](references/identity-errors.md) before attempting any of the three,
because it names the exact Graph permissions.

## Three forms of CREATE USER, and when each is forced

| Form | Looks the principal up | Use it when |
|---|---|---|
| `CREATE USER [<name>] FROM EXTERNAL PROVIDER;` | Yes | The default. A person is running it, or the server identity is configured |
| `CREATE USER [<alias>] FROM EXTERNAL PROVIDER WITH OBJECT_ID = '<object-id>';` | Yes | The display name is **not unique** in the tenant, so the plain form fails |
| `CREATE USER [<name>] WITH SID = <id-as-binary>, TYPE = E;` | **No** | No Graph permission is available, or Msg 33134 has to be worked around. Needs an engine that has Microsoft Entra configured, so on a bare container it raises `40530` |

The third form written out, because agents paraphrase it into something that does not run.
`TYPE = E` covers users, applications and managed identities, `TYPE = X` groups:

```sql
DECLARE @principal_name SYSNAME = 'example-app';
DECLARE @clientId UNIQUEIDENTIFIER = '<the application client id>';
DECLARE @cmd NVARCHAR(MAX) = N'CREATE USER [' + @principal_name + '] WITH SID = '
  + CONVERT(VARCHAR(MAX), CONVERT(VARBINARY(16), @clientId), 1) + N', TYPE = E;';
EXEC (@cmd);
```

**Nothing validates that id**, so a wrong value creates a user no token will ever match and it reads
back as a healthy row. For a **user or group** it is the **object id**; for a **service principal or
managed identity** it is the **application (client) id**.

**`WITH OBJECT_ID` is not the general fix and does not answer Msg 33134.** It exists for one
problem: Microsoft Entra ID permits duplicate application display names and the engine requires a
unique one. That produces a different error.

```output
Msg 33131, Level 16, State 1, Line 4
Principal 'myapp' has a duplicate display name.
```

Two traps: the object id must exist in this tenant or the statement fails with `Msg 37545`, and the
**Object ID on an app registration is not the one on its service principal**. This clause wants the
enterprise application one, `objectId` in step 3.

## A SQL-authenticated administrator cannot do any of this

Learn is explicit: only Microsoft Entra users can create other Entra users in Azure SQL Database,
and no SQL-authenticated user, the server admin included, can. That is why "I am the admin and it still fails" is a dead end. The permission needed is
`ALTER ANY USER`, carried by `db_owner`, but no grant substitutes for the connection itself being
Entra authenticated. The `WITH SID` form is the exception: it performs no external lookup.

## The name to put in the brackets

A wrong name produces `Msg 33134` or `Msg 33131` and reads as a permissions problem. The one nobody
guesses: a **system-assigned** identity on a deployment slot is `<app-name>/slots/<slot-name>`,
which is why an application works in production and fails in staging. Open
[references/identity-errors.md](references/identity-errors.md) before typing a name you inferred,
because it tables all five principal kinds.

## The authentication keyword is not the same string twice

Every value below is plausible in every driver and each is valid in only one of them.

| Stack | Passwordless default | Managed identity, explicit | User-assigned client id goes in |
|---|---|---|---|
| .NET, `Microsoft.Data.SqlClient` | `Authentication=Active Directory Default` | `Active Directory Managed Identity`, alias `Active Directory MSI` | `User Id=` |
| Python, `mssql-python` | `Authentication=ActiveDirectoryDefault` | `Authentication=ActiveDirectoryMSI` | `UID=` |
| Python, `pyodbc` on ODBC Driver 18 | **no such value exists** | `Authentication=ActiveDirectoryMsi` | `UID=`, object id on most hosts |
| Node.js, `mssql` on `tedious` | `type: 'azure-active-directory-default'` | `azure-active-directory-msi-app-service`, `azure-active-directory-msi-vm` | `authentication.options.clientId` |
| Java, the Microsoft JDBC driver | `authentication=ActiveDirectoryDefault` | `ActiveDirectoryManagedIdentity`, alias `ActiveDirectoryMSI` | `msiClientId`, or `user` |

**In production, name the managed identity mode, not the default.** The default walks a chain of
credential providers, which Microsoft warns costs response time, and can pick up a developer
credential on a machine that has one.

Two facts a plausible guess gets wrong. **ODBC has no `ActiveDirectoryDefault`** and spells managed
identity `ActiveDirectoryMsi`, mixed case, so Python is two stories: `mssql-python` has a default
mode and uses `ActiveDirectoryMSI`, `pyodbc` has neither. **In Node.js the client id is nested**, in
`authentication.options.clientId`, not the connection `options` bag beside `encrypt`.

Open [references/driver-auth-keywords.md](references/driver-auth-keywords.md) before writing one of
these values, because each list there is the driver's complete accepted set and a value outside it
is not a value. A driver that names its own set, such as `sqlcmd`, is faster to ask than to recall.

**`Microsoft.Data.SqlClient` 7.0 needs the `Microsoft.Data.SqlClient.Extensions.Azure` package**, or
every `Active Directory *` mode fails at run time; connection strings do not change. `Active
Directory Password` is deprecated across the drivers and `[Obsolete]` in 7.0, because it rests on
the resource owner password credentials grant.

```bash
dotnet add package Microsoft.Data.SqlClient.Extensions.Azure
```

## System-assigned or user-assigned

Two decisions, confused because both use the same words. **The server identity** reads Microsoft
Graph and matters only for step 2; a user-assigned one survives the server and holds the Graph
permissions once for many. **The application identity** is what the application authenticates as,
and changes the connection string **only if user-assigned**, which must name its client id because
the host may carry several.

## On the Azure SQL Database container, the shape is login then user

The container reads a certificate, the application (client) id and the tenant id from three
environment variables set at creation. One command says which case you are in.

```bash
docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' <container> | grep -c '^MSSQL_AAD_'
```

`0` means Entra ID was never configured: an Entra login returns `18456`, `Login failed for user ''`,
which is `connect-to-azure-sql`, not this skill, and the error below. `3` means
`MSSQL_AAD_CLIENT_ID`,
`MSSQL_AAD_PRIMARY_TENANT` and `MSSQL_AAD_CERTIFICATE_FILE_PATH` are set and the database side is
yours. Learn documents that trio, and the statements below, for the SQL Server on Linux image and
not for this one, so confirm the engine agreed rather than assuming:

```bash
docker exec <container> bash -c "grep Entra /var/opt/mssql/log/errorlog"
```

Expected: `Microsoft Entra ID authentication is enabled.` The principal is then a server login and
a database user from that login, not a contained user:

```sql
CREATE LOGIN [<upn>] FROM EXTERNAL PROVIDER;
CREATE USER [<upn>] FROM LOGIN [<upn>];
```

### Msg 40530 blames the batch, and the batch is fine

In the `0` case the no-lookup form is refused too, by a message naming the wrong thing. Measured
2026-09-03 with no `MSSQL_AAD_` variables:

```output
Msg 40530, Level 16, State 1, Line 1
The CREATE USER statement must be the only statement in the batch.
```

It **was** the only statement in the batch. `TYPE = X` fails identically, and so does every rewrite
tried, `EXEC (@cmd)` and `GO` separation included, so a reader who trusts the text rewrites the
batch forever and never succeeds. `CREATE USER [<name>] WITHOUT LOGIN;`, the same batch shape,
succeeds, which rules the batch out. **The fix is server configuration, not SQL**: the engine has no
Microsoft Entra configuration and refuses the external principal types. Set the three variables and
recreate the container, or run against Azure SQL Database. Open
[references/identity-errors.md](references/identity-errors.md) before believing the number, because
Microsoft Learn documents `40530` only as the batch rule and that disagreement is recorded there.

Two things have no local equivalent, so a green local run proves nothing about either: the **server
identity** and its Graph permission, which `Msg 33134` is about, and **Entra-only authentication**
with its Azure Policy enforcement.

## Microsoft Entra-only authentication

Enabling it disables SQL authentication at the **server** level, for every database and the server
administrator too. Existing SQL logins are not removed and new ones can still be created; they
simply cannot connect.

```bash
az sql server ad-only-auth enable -g <resource-group> -n <server>
az sql server ad-only-auth get -g <resource-group> -n <server>
```

**The administrator must be set first**, or enabling fails through every interface, and cannot be
removed until the setting is disabled again. Enabling also silently disables elastic jobs, SQL Data
Sync, SQL Insights, `EXEC AS` for Entra group members and some change data capture paths.

**Enforcing it takes two Azure Policy definitions, not one**: one evaluates a server at creation,
the other the setting on an existing server. Open
[references/entra-only-and-policy.md](references/entra-only-and-policy.md) before enabling this on a
shared server or naming a policy in a plan, because it carries the full disabled-feature list, the
role split, and the two definition ids.

## Check it worked

Run the first two against the **user database**, never `master`.

**1. The principal exists and its stored id is the identity you meant.**

```sql
SELECT name, type, type_desc,
       CAST(CAST(sid AS varbinary(16)) AS uniqueidentifier) AS entra_id,
       DATALENGTH(sid) AS sid_bytes
FROM sys.database_principals
WHERE type IN ('E', 'X');
```

Expected: `type_desc` is `EXTERNAL_USER` for an application or a person, `EXTERNAL_GROUP` for a
group. `entra_id` must equal the client id the workload runs as; a row carrying the wrong one looks
exactly like success. `sid_bytes` is `16` for a contained user, `18` for one from a server login. On
a container with no `MSSQL_AAD_` variables it returns nothing: no `E` or `X` principal exists
there.

**2. The roles are the ones you named, and nothing wider.**

```sql
SELECT r.name AS role_name, m.name AS member_name
FROM sys.database_role_members rm
JOIN sys.database_principals r ON r.principal_id = rm.role_principal_id
JOIN sys.database_principals m ON m.principal_id = rm.member_principal_id
WHERE m.type IN ('E', 'X');
```

Expected: exactly the roles from step 6. A `db_owner` or `CONTROL` grant nobody asked for is the
usual leftover of a one-command tool.

**3. On the cloud, the server side agrees.**

```bash
az sql server ad-admin list -g <resource-group> -s <server> -o table
az sql server show -g <resource-group> -n <server> --query identity
```

Expected: the administrator from step 1, and a non-null identity if step 2 said you needed one.
Having run the command is not evidence it took.

## References

- Open [references/identity-errors.md](references/identity-errors.md) when a statement has failed
  and you need its verbatim text, its real cause, or worked T-SQL for the form it forces.
- Open [references/driver-auth-keywords.md](references/driver-auth-keywords.md) before writing an
  authentication value, because it holds each driver's complete accepted set.
- Open [references/entra-only-and-policy.md](references/entra-only-and-policy.md) before enabling
  Entra-only authentication or naming a policy.

Tenant-side role assignment changes, so fetch the Learn articles rather than recalling them.

## Do not

- Do not answer `Msg 33134` by editing the principal name. Check the server identity, its Graph
  permission, and that the assign command used `-i`.
- Do not reach for `WITH OBJECT_ID` as a general fix. It answers `Msg 33131` and nothing else, and
  wants the enterprise application object id, not the app registration's.
- Do not run `CREATE USER FROM EXTERNAL PROVIDER` on `master` and report the identity as configured.
- Do not attempt the lookup forms from a SQL-authenticated connection, server administrator
  included. No grant makes those work.
- Do not transpose an authentication keyword between drivers, and never write
  `ActiveDirectoryDefault` into an ODBC connection string.
- Do not use `Active Directory Password` in any spelling, or leave a .NET 7.0 application on an
  `Active Directory *` mode without the extension package.
- Do not put a client secret in a connection string on Azure, or grant `CONTROL ON DATABASE`
  because a tool did. Role design is `least-privilege-database-roles`.
- Do not enable Entra-only authentication on a shared server without naming what it turns off, or
  assign one Azure Policy definition and call the estate enforced.
- Do not conclude a grant failed until the identity token cache has turned over.
- Do not answer `Msg 40530` by rewriting the batch. On a bare container it means the engine has no
  Entra configuration.
- Do not read a clean container run as evidence the cloud path works. The server identity, `Msg
  33134` and Entra-only authentication have no local equivalent.
