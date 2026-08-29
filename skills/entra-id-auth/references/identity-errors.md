# Identity errors, and the three forms of CREATE USER

## Contents

- [How to use this file](#how-to-use-this-file)
- [The error numbers, with their real causes](#the-error-numbers-with-their-real-causes)
- [Msg 33134 in full](#msg-33134-in-full)
- [Msg 33131 and the OBJECT_ID form](#msg-33131-and-the-object_id-form)
- [The no-lookup form, with worked T-SQL](#the-no-lookup-form-with-worked-t-sql)
- [Which id goes where](#which-id-goes-where)
- [What the server identity is for](#what-the-server-identity-is-for)
- [Verification queries](#verification-queries)
- [Sources](#sources)

## How to use this file

Read it when an error number needs its exact text and its actual cause, or when the plain
`CREATE USER [<name>] FROM EXTERNAL PROVIDER` has failed and the next form has to be chosen
deliberately rather than by trial.

Every message below is quoted from a Microsoft Learn page, listed at the end. Numbers that are not
about identity live in `diagnose-connection-errors`.

## The error numbers, with their real causes

| Number | What the text says | What it usually is |
|---|---|---|
| `33134` | The principal could not be resolved | The logical server has no identity, or that identity cannot read Microsoft Graph. Only ever seen when a service principal runs the statement |
| `33131` | The principal has a duplicate display name | Microsoft Entra ID allows two applications to share a display name and the engine requires a unique one. Answer with `WITH OBJECT_ID` and an alias |
| `37545` | The object id is not valid, or the caller lacks permission | The object id given to `WITH OBJECT_ID` does not exist in this tenant, or the wrong one of the two portal object ids was used |
| `18456` | `Login failed for user '<name>'.` | The credential was evaluated and refused: the login does not exist, is disabled, or the secret is wrong |
| `18456` naming `<token-identified principal>` | Login failed for that literal user name | The token was accepted and no matching principal exists in the database. The database user was never created, or was created in the wrong database |
| `4060` | `Cannot open database "<name>" requested by the login. The login failed.` | The login is valid and has no user in that database, or the database name is wrong. After a deployment, almost always a missing database user |

`18456` and `4060` are answered here, both the identity-shaped versions and the plain ones, because
both arrive after the credential was evaluated. `40532` reads identically and is not either of
them: it is the gateway refusing before a database was reached, and it belongs to
`diagnose-connection-errors` along with everything else that fails before that point.

## Msg 33134 in full

```output
Msg 33134, Level 16, State 1, Line 1
Principal 'test-user' could not be resolved.
Error message: 'Server identity is not configured. Please follow the steps in "Assign an Azure AD
identity to your server and add Directory Reader permission to your identity"
(https://aka.ms/sqlaadsetup)'
```

The mechanism, quoted:

> When a Microsoft Entra user executes these commands, Azure SQL's Microsoft application uses
> delegated permissions to impersonate the signed-in user and queries Microsoft Graph using their
> permissions. This flow isn't possible with service principals, because an application can't
> impersonate another application. Instead, the SQL engine tries to use its server identity ... The
> server identity must exist and have the Microsoft Graph query permissions or the operations fail.

So the same statement succeeds when a person runs it and fails from a pipeline, which is the part
that makes it look like a permissions bug in the pipeline's own credential.

Assigning the identity:

```bash
az sql server update -g <resource-group> -n <server> --assign-identity
az sql server show -g <resource-group> -n <server> --query identity
```

The Graph side needs a `Privileged Role Administrator` and cannot be done from the resource pages,
only from a script. Grant either the three application permissions, which is the least-privilege
option, or the `Directory Readers` role, which is broader than the server needs:

- `User.Read.All`
- `GroupMember.Read.All`
- `Application.Read.All`

For production, Microsoft recommends a role-assignable group holding `Directory Readers`, so a
group owner can add server identities without a `Privileged Role Administrator` in the loop for
each one.

## Msg 33131 and the OBJECT_ID form

```output
Msg 33131, Level 16, State 1, Line 4
Principal 'myapp' has a duplicate display name. Make the display name unique in Azure Active
Directory and execute this statement again.
```

The documented answer:

```sql
CREATE USER [<user_name>] FROM EXTERNAL PROVIDER
    WITH OBJECT_ID = '<objectid>';
```

Four rules the documentation is explicit about:

1. **Only for nonunique names.** "If the service principal display name isn't a duplicate, the
   default `CREATE LOGIN` or `CREATE USER` statement should be used. The `WITH OBJECT_ID` extension
   is a troubleshooting repair item implemented for use with nonunique service principals. Using it
   with a unique service principal isn't recommended."
2. **Add a suffix to the name.** Without one the statement succeeds and nothing records which
   principal it was for. The recommended shape is the original name plus the first five characters
   of the object id, for example `myapp2ba6c`, and the alias must fit `sysname`, at most 128
   characters.
3. **The object id must exist in this tenant**, or the statement fails with
   `Msg 37545, Level 16, State 1, Line 1 '' is not a valid object id for '' or you do not have
   permission.`
4. **It is the enterprise application object id**, not the one shown on the app registration page.
   The documentation carries a warning about exactly this pair, because both are labelled Object ID
   and only one works.

Naming an Azure resource the same as an existing app registration is one way to arrive here: two
principals then share a display name, and `Msg 33131` is the collision being reported.

The display name in Microsoft Entra ID and the alias in the database are not synchronised in either
direction. Renaming one never changes the other.

## The no-lookup form, with worked T-SQL

Azure SQL Database accepts a form of `CREATE USER` that does not query Microsoft Graph at all, so it
needs no server identity and no Graph permission. It is the practical answer to `Msg 33134` when
tenant-level privilege is not available. Nothing validates the id, so a wrong value produces a user
that no token will ever match.

A user:

```sql
DECLARE @principal_name SYSNAME = 'bob@contoso.com';
DECLARE @objectId UNIQUEIDENTIFIER = '<the user object id>';
DECLARE @castObjectId NVARCHAR(MAX) = CONVERT(VARCHAR(MAX), CONVERT (VARBINARY(16), @objectId), 1);
DECLARE @cmd NVARCHAR(MAX) = N'CREATE USER [' + @principal_name + '] WITH SID = ' + @castObjectId + ', TYPE = E;';
EXEC (@cmd);
```

A service principal or a managed identity, where the id is the **client id**, not the object id:

```sql
DECLARE @principal_name SYSNAME = 'example-app';
DECLARE @clientId UNIQUEIDENTIFIER = '<the application client id>';
DECLARE @castClientId NVARCHAR(MAX) = CONVERT(VARCHAR(MAX), CONVERT (VARBINARY(16), @clientId), 1);
DECLARE @cmd NVARCHAR(MAX) = N'CREATE USER [' + @principal_name + '] WITH SID = ' + @castClientId + ', TYPE = E;';
EXEC (@cmd);
```

A group, which is `TYPE = X`:

```sql
DECLARE @principal_name SYSNAME = 'example-group';
DECLARE @objectId UNIQUEIDENTIFIER = '<the group object id>';
DECLARE @castObjectId NVARCHAR(MAX) = CONVERT(VARCHAR(MAX), CONVERT (VARBINARY(16), @objectId), 1);
DECLARE @cmd NVARCHAR(MAX) = N'CREATE USER [' + @principal_name + '] WITH SID = ' + @castObjectId + ', TYPE = X;';
EXEC (@cmd);
```

## Which id goes where

Three different identifiers, all GUIDs, all called something ending in ID.

| Clause or property | Principal | The id it wants |
|---|---|---|
| `WITH OBJECT_ID` | Service principal | The **object id** from the enterprise application, not the app registration |
| `WITH SID`, `TYPE = E` | User | The user's **object id** |
| `WITH SID`, `TYPE = E` | Service principal or managed identity | The **application (client) id** |
| `WITH SID`, `TYPE = X` | Group | The group's **object id** |
| Connection string, user-assigned identity | Managed identity | The **client id**, except ODBC, which wants the object id outside a small set of hosts |

The `sid` read back from `sys.database_principals` for an application converts to its
**application id**, so it can be compared with the identity the workload actually runs as.

## What the server identity is for

It is not the application's identity and it is not needed for a person to create users.

> For SQL Database, enabling the server identity is optional and required only if a Microsoft Entra
> service principal (Microsoft Entra application) oversees creating and managing Microsoft Entra
> users, groups, or applications in the server.

Either a system-assigned or a user-assigned identity can serve. A user-assigned one can hold the
Graph permissions once and be shared across servers, and it is not deleted with the server.

Deleting whichever identity is serving this role leaves the server unable to reach Microsoft Graph,
and Entra authentication fails until a replacement is assigned and granted.

## Verification queries

Against the user database, never `master`.

```sql
SELECT name, type, type_desc, authentication_type_desc,
       CAST(CAST(sid AS varbinary(16)) AS uniqueidentifier) AS entra_id
FROM sys.database_principals
WHERE authentication_type_desc = 'EXTERNAL';
```

```sql
SELECT SERVERPROPERTY('IsExternalAuthenticationOnly');   -- 1 on, 0 off
```

```bash
az sql server ad-admin list -g <resource-group> -s <server> -o table
az sql server show -g <resource-group> -n <server> --query identity
az sql server ad-only-auth get -g <resource-group> -n <server>
```

A row that exists with the wrong `entra_id` is indistinguishable from success until the application
fails, so compare the value rather than checking that the row is there.

## Sources

Fetch these rather than trusting this summary when the details matter. All read on 2026-08-27.

- Microsoft Entra service principals with Azure SQL: `/azure/azure-sql/database/authentication-aad-service-principal`, which carries the `33134` text and the impersonation mechanism.
- Create Microsoft Entra users using service principals: `/azure/azure-sql/database/authentication-aad-service-principal-tutorial`, which carries the Graph permission list and the rule that only Entra users can create Entra users.
- Microsoft Entra logins and users with nonunique display names: `/sql/relational-databases/security/authentication-access/authentication-microsoft-entra-create-users-with-nonunique-names`, which carries `33131`, `37545` and the `WITH OBJECT_ID` rules.
- CREATE USER: `/sql/t-sql/statements/create-user-transact-sql`, which carries the syntax, `SID` and `TYPE`, and the permission requirement.
- Managed identity in Microsoft Entra for Azure SQL: `/azure/azure-sql/database/authentication-azure-ad-user-assigned-managed-identity`, which carries the server identity rules and the no-lookup escape.
