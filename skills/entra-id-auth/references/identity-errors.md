# Identity errors, and the three forms of CREATE USER

## Contents

- [How to use this file](#how-to-use-this-file)
- [The error numbers, with their real causes](#the-error-numbers-with-their-real-causes)
- [Msg 33134 in full](#msg-33134-in-full)
- [Msg 33131 and the OBJECT_ID form](#msg-33131-and-the-object_id-form)
- [Msg 40530, where the message and the cause disagree](#msg-40530-where-the-message-and-the-cause-disagree)
- [The no-lookup form, with worked T-SQL](#the-no-lookup-form-with-worked-t-sql)
- [The name to put in the brackets](#the-name-to-put-in-the-brackets)
- [Which id goes where](#which-id-goes-where)
- [What the server identity is for](#what-the-server-identity-is-for)
- [Verification queries](#verification-queries)
- [Sources](#sources)

## How to use this file

Read it when an error number needs its exact text and its actual cause, or when the plain
`CREATE USER [<name>] FROM EXTERNAL PROVIDER` has failed and the next form has to be chosen
deliberately. Sources are listed at the end. Numbers that are not about identity live in
`diagnose-connection-errors`.

## The error numbers, with their real causes

| Number | What the text says | What it usually is |
|---|---|---|
| `33134` | The principal could not be resolved | The logical server has no identity, or that identity cannot read Microsoft Graph. Only ever seen when a service principal runs the statement |
| `33131` | The principal has a duplicate display name | Microsoft Entra ID allows two applications to share a display name and the engine requires a unique one. Answer with `WITH OBJECT_ID` and an alias |
| `37545` | The object id is not valid, or the caller lacks permission | The object id given to `WITH OBJECT_ID` does not exist in this tenant, or the wrong one of the two portal object ids was used |
| `18456` | `Login failed for user '<name>'.` | The credential was evaluated and refused: the login does not exist, is disabled, or the secret is wrong |
| `18456` naming `<token-identified principal>` | Login failed for that literal user name | The token was accepted and no matching principal exists in the database. The database user was never created, or was created in the wrong database |
| `40530` | The `CREATE USER` statement must be the only statement in the batch | On an engine with no Microsoft Entra configuration, the refusal of `TYPE = E` and `TYPE = X`. The batch is not the cause. See below |
| `4060` | `Cannot open database "<name>" requested by the login. The login failed.` | The login is valid and has no user in that database, or the database name is wrong. After a deployment, almost always a missing database user |

`18456` and `4060` are answered here, identity-shaped or plain, because both arrive after the
credential was evaluated. `40532` reads identically and is the gateway refusing before a database
was reached, so it belongs to `diagnose-connection-errors`.

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

Assign the identity with the commands in the skill body. **The flag is `-i`, long form
`--assign_identity` with an underscore.** Measured 2026-09-03 on Azure CLI 2.90.0: the hyphenated
`--assign-identity` exits with `unrecognized arguments`, so a script carrying it assigns nothing and
the next `CREATE USER` raises `33134` again.

The Graph side needs a `Privileged Role Administrator` and can only be done from a script. Grant
either the three application permissions, the least-privilege option, or the `Directory Readers`
role, which is broader than the server needs:

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

1. **Only for nonunique names.** Learn calls it a troubleshooting repair item for nonunique service
   principals, and says the plain statement should be used otherwise.
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

## Msg 40530, where the message and the cause disagree

```output
Msg 40530, Level 16, State 1, Line 1
The CREATE USER statement must be the only statement in the batch.
```

Measured 2026-09-03 on an Azure SQL Database container started with no `MSSQL_AAD_` variables, `EngineEdition` `5`,
`IsExternalAuthenticationOnly` `0`: a lone `CREATE USER [p5] WITH SID = 0x1111..., TYPE = E;` raises
it, `TYPE = X` raises it, `EXEC (@cmd)` and `GO` separation raise it, and a lone
`CREATE USER [p4] WITHOUT LOGIN;` succeeds. The batch is not the cause. The engine has no Microsoft
Entra configuration, refuses the external principal types, and reports a batch rule.

**Microsoft Learn documents `40530` only as the batch rule**: the errors and events table gives
severity 16 and the text `The %.*ls statement must be the only statement in the batch.`, with no
documented connection to Microsoft Entra configuration. The observed behaviour does not match the
documented meaning. That is recorded here as a disagreement rather than resolved: either the engine
reuses a number for a cause it has no message of its own for, or the documentation is incomplete,
and neither has been confirmed with the product team.

## The no-lookup form, with worked T-SQL

Azure SQL Database accepts a form of `CREATE USER` that does not query Microsoft Graph at all, so it
needs no server identity and no Graph permission. It is the practical answer to `Msg 33134` when
tenant-level privilege is not available. Nothing validates the id, so a wrong value produces a user
that no token will ever match.

One block covers all three principals: change the id and the `TYPE`, per the table below. `TYPE` is
`E` for a user, an application or a managed identity, and `X` for a group.

```sql
DECLARE @principal_name SYSNAME = 'example-app';
DECLARE @id UNIQUEIDENTIFIER = '<the object id, or the client id for an application>';
DECLARE @castId NVARCHAR(MAX) = CONVERT(VARCHAR(MAX), CONVERT (VARBINARY(16), @id), 1);
DECLARE @cmd NVARCHAR(MAX) = N'CREATE USER [' + @principal_name + '] WITH SID = ' + @castId + ', TYPE = E;';
EXEC (@cmd);
```

**This form is cloud, or an Entra-configured engine, only.** On an Azure SQL Database container
started without the `MSSQL_AAD_` variables it raises `Msg 40530`, above, and nothing about the
statement can be changed to make it run.

## The name to put in the brackets

The engine matches the token against this name, so a wrong one produces `Msg 33134` or `Msg 33131`
and reads as a permissions problem.

| Principal | The name |
|---|---|
| A person | Their user principal name |
| A group | Its display name |
| An app registration or a user-assigned managed identity | Its display name |
| A system-assigned managed identity | The name of the Azure resource that owns it |
| A system-assigned identity on a deployment slot | `<app-name>/slots/<slot-name>` |

The slot form is the one nobody guesses, and an application that works in production and fails in a
staging slot is usually missing that user.

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

Learn: for Azure SQL Database the server identity is optional, and required only when a Microsoft
Entra service principal creates or manages Entra users, groups or applications on the server.

Either a system-assigned or a user-assigned identity can serve. A user-assigned one can hold the
Graph permissions once and be shared across servers, and it is not deleted with the server.

Deleting whichever identity is serving this role leaves the server unable to reach Microsoft Graph,
and Entra authentication fails until a replacement is assigned and granted.

## Verification queries

The two catalogue queries live in the skill body, under "Check it worked", and run against the user
database, never `master`. What they will not tell you:

- `sid_bytes` is `16` for a contained database user, whose SID is the object or client id itself,
  and `18` for a user created from a Microsoft Entra server login, whose SID carries an `AADE`
  suffix. The two do not match, so a login-based user cannot be correlated to its login by SID until
  that suffix is removed.
- A row that exists with the wrong `entra_id` is indistinguishable from success until the
  application fails, so compare the value rather than checking that the row is there.
- On a container with no `MSSQL_AAD_` variables both queries return nothing, because no `E` or `X`
  principal can be created there.

```sql
SELECT SERVERPROPERTY('IsExternalAuthenticationOnly');   -- 1 on, 0 off
```

## Sources

Fetch these rather than trusting this summary when the details matter. Read on 2026-08-27, except
the last, read 2026-09-03.

- `/azure/azure-sql/database/authentication-aad-service-principal`: the `33134` text and the impersonation mechanism.
- `/azure/azure-sql/database/authentication-aad-service-principal-tutorial`: the Graph permission list, and the rule that only Entra users can create Entra users.
- `/sql/relational-databases/security/authentication-access/authentication-microsoft-entra-create-users-with-nonunique-names`: `33131`, `37545` and the `WITH OBJECT_ID` rules.
- `/sql/t-sql/statements/create-user-transact-sql`: the syntax, `SID` and `TYPE`, and the permission requirement.
- `/azure/azure-sql/database/authentication-azure-ad-user-assigned-managed-identity`: the server identity rules and the no-lookup escape.
- `/azure/azure-sql/database/authentication-aad-overview`: the `sys.database_principals` property table and the 16 against 18 byte SID difference.
- `/azure/azure-sql/database/authentication-azure-ad-logins`: what a SQL admin or SQL user cannot execute.
- `/sql/relational-databases/errors-events/database-engine-events-and-errors-31000-to-41399`: the `40530` row, documented only as the batch rule.
