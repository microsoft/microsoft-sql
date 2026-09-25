---
name: connect-from-dotnet
description: >-
  Connects a .NET application to Azure SQL Database with Microsoft.Data.SqlClient: which package
  references are required, the encryption defaults and what changed, connection pooling and the
  keys that split a pool, and managed identity or other Microsoft Entra ID modes. Use when a user
  says "connect .NET to Azure SQL", "Microsoft.Data.SqlClient", "SqlConnection", "passwordless
  access for my .NET app", "managed identity for my API", "Active Directory Default", "Max Pool
  Size", "Encrypt=Strict", or asks whether "Microsoft.Data.SqlClient.Extensions.Azure" is needed.
  Also use when an app authenticates with a password locally and must use an identity in Azure.
  Covers packages, connection string keywords, pooling and Entra ID for .NET only; the ORM path is
  ef-core-azure-sql, and encryption doctrine plus transient-fault retry belong to
  connect-to-azure-sql.
---

# Connect from .NET

The driver is `Microsoft.Data.SqlClient`, encryption is on by default, pooling is automatic, and
since version 7.0 Microsoft Entra authentication needs a **second package reference** that nothing
in the connection string hints at.

Measured 2026-09-03 on `Microsoft.Data.SqlClient` 7.0.2, `Microsoft.Data.SqlClient.Extensions.Azure`
7.0.2 and .NET SDK 8.0.421, with the commands in **Check it worked**.

Encryption doctrine, retry and pool sizing are the same in every language and live in
`connect-to-azure-sql`. Entity Framework Core is `ef-core-azure-sql`.

## The packages

```bash
dotnet add package Microsoft.Data.SqlClient
```

`System.Data.SqlClient` is the older provider and receives no new features. A
`using System.Data.SqlClient;` in a new file is a mistake worth fixing first.

## Gotcha: Entra ID needs a second package from version 7.0

7.0 moved the Entra dependencies out of the core package. Read the restored graph, do not guess:

```bash
dotnet list package --include-transitive | grep -E '> (Azure\.Identity|Azure\.Core|Microsoft\.Identity\.Client) '
```

On the core package alone that prints nothing, so the driver registers no Entra provider, and you
can see that without a server at all:

```csharp
using Microsoft.Data.SqlClient;
var provider = SqlAuthenticationProvider.GetProvider(SqlAuthenticationMethod.ActiveDirectoryDefault);
Console.WriteLine(provider is null ? "NONE" : provider.GetType().FullName);
```

`NONE` means every `Active Directory *` mode has nothing to resolve to. Against a server that offers
Microsoft Entra authentication the login then raises `ArgumentException`: `Cannot find an
authentication provider for 'ActiveDirectoryDefault'`, naming the package to install. The fix is
that package reference and no code change:

```bash
dotnet add package Microsoft.Data.SqlClient.Extensions.Azure
```

Re-run both commands. The graph now lists `Azure.Identity`, `Azure.Core` and
`Microsoft.Identity.Client`, and the provider prints
`Microsoft.Data.SqlClient.ActiveDirectoryAuthenticationProvider`. The extension registers itself.
SQL authentication, and applications that supply their own token through `AccessToken` or
`AccessTokenCallback`, keep the lighter graph.

**The local container is not where that exception reproduces.** The provider is looked up during
the login exchange, so the `ArgumentException` needs a server offering Microsoft Entra
authentication. Against the Azure SQL Database container, which has no Entra configuration,
`Authentication=Active Directory Default` fails earlier and differently, as `Msg 18456`,
`Login failed for user ''`, naming neither a provider nor a package; that one is
`diagnose-connection-errors`. Decide the package from the graph and the mode, never from whether a
local connection happened to succeed.

## Encryption defaults, and the version that changed them

`Encrypt` defaults to `True` from version 4.0 and defaulted to `False` in 3.x and earlier.
`TrustServerCertificate` defaults to `False`, and under `Encrypt=Strict` it is ignored and treated
as false. So encryption is on and the certificate is validated, and connecting forces a trust
decision rather than deferring one. Code written against a 3.x default surfaces that as a
connection error on upgrade rather than as an upgrade note. Reach for `connect-to-azure-sql` before
changing either value; the answer is almost never `TrustServerCertificate=True`.

## Pooling is automatic, and the connection string is the key

Never cache a `SqlConnection`. Open one, use it, dispose it. The pool underneath does the reuse.

```csharp
await using var connection = new SqlConnection(connectionString);
await connection.OpenAsync(cancellationToken);
```

Four things decide whether pooling actually helps, with every default below read out of
`SqlConnectionStringBuilder` on 7.0.2:

- **The pool key is the whole connection string.** Two strings differing in any way, including a
  per-tenant `Application Name` or a rearranged keyword, get two pools that both count against the
  same server limits. Build the string once.
- **`Connect Timeout` defaults to 15 seconds**, and Microsoft's guidance for Azure SQL Database is
  30. Set it deliberately. `Pooling` is `True`, `Max Pool Size` 100 and `Min Pool Size` 0.
- **`Connect Retry Count`, 1, and `Connect Retry Interval`, 10, are idle-connection resiliency
  inside the driver.** It transparently reconnects a dropped idle connection; it does not replay a
  failed query. From version 5 the effective default is raised for Azure SQL Database endpoints and
  again for serverless ones, so read it from the documentation rather than from the builder.
  Application-level retry is separate, and is `connect-to-azure-sql`. Keep both.
- **`AccessTokenCallback` is part of the pool key.** A new lambda per `SqlConnection` creates a new
  pool per connection. Reference one shared static callback.

Sizing the pool, and why the limit that bites is workers rather than sessions, is
`connect-to-azure-sql`.

## Microsoft Entra ID

Set `Authentication` in the connection string. `Active Directory Managed Identity` for an
Azure-hosted workload, which is the production mode; `Active Directory Default` for development
machines and CI, where the credential varies; `Active Directory Service Principal` for a registered
app, client id in `User Id` and secret in `Password`. `Active Directory Password` is deprecated and
obsolete in 7.0.

System-assigned managed identity needs nothing beyond the mode. User-assigned supplies the identity
in `User Id`, and **which identifier** depends on the driver version: the **client id** from 3.0
onwards, the **object id** on 2.1. Everything current wants the client id, and the object id fails
at token acquisition with an error pointing at the identity endpoint, not at the connection string.

```csharp
var connectionString =
    "Server=tcp:<server>.database.windows.net,1433;" +
    "Database=<database>;" +
    "Authentication=Active Directory Managed Identity;" +
    "User Id=<managed-identity-client-id>;" +   // omit this line for a system-assigned identity
    "Encrypt=Mandatory;Connect Timeout=30;";
```

`Active Directory Default` walks a chain of credential providers on the first connection, failing
ones first, so it costs latency a production workload has no reason to pay. Name the credential type
directly outside development.

The identity still needs a database principal before it can connect. Creating it is `entra-id-auth`;
wiring the identity through the hosting resources and deployment is `deploy-app-to-azure`.

## Check it worked

Four checks. The first three need no database, so run them before blaming the network.

**One: the dependency graph matches the authentication mode.** From the project directory:

```bash
dotnet list package --include-transitive | grep -cE '> (Azure\.Identity|Azure\.Core|Microsoft\.Identity\.Client) '
```

Expect `3` on a project that uses any `Active Directory *` mode, and `0` on one that does not.
Measured 2026-09-03 on 7.0.2 with the extension package: `Azure.Identity` 1.18.0, `Azure.Core`
1.51.1, `Microsoft.Identity.Client` 4.84.2. Without it, all three absent.

**Two: the driver has a provider for the mode you set.** Run the `GetProvider` snippet above. Expect
`Microsoft.Data.SqlClient.ActiveDirectoryAuthenticationProvider`; `NONE` means the extension package
is missing. That answer is the same on a laptop as in production.

**Three: nothing in the tree undoes the defaults.** Both expect no output:

```bash
grep -rn 'System\.Data\.SqlClient' --include='*.cs' .
grep -rniE 'TrustServerCertificate *= *true' --include='*.cs' --include='*.json' --include='*.config' .
```

**Four: the connection you opened is the one you meant.** Ask the engine, over the application's own
connection rather than from a query tool signed in as somebody else:

```csharp
await using var connection = new SqlConnection(connectionString);
await connection.OpenAsync();
await using var cmd = new SqlCommand(
    "SELECT c.encrypt_option, SUSER_SNAME() AS login, USER_NAME() AS db_user, DB_NAME() AS db " +
    "FROM sys.dm_exec_connections AS c WHERE c.session_id = @@SPID;", connection);
await using var r = await cmd.ExecuteReaderAsync();
if (await r.ReadAsync()) Console.WriteLine($"encrypt={r[0]} login={r[1]} user={r[2]} db={r[3]}");
```

One row, and each column settles a different question. `encrypt_option` is `TRUE` on an encrypted
connection, so anything else means an `Encrypt=False` survived somewhere in the string. `login` is
the identity the server believes it is talking to: for managed identity the Entra principal, and if
it is the SQL login you meant to stop using, an old connection string is still in play. `db` catches
the connection that opened happily against the wrong database.

**Zero rows means a permission problem, not an unencrypted connection.** `sys.dm_exec_connections`
needs `VIEW DATABASE STATE` on the database, or membership in the `##MS_ServerStateReader##` server
role, and a least-privileged application user has neither by default. There is no unprivileged
substitute: `CONNECTIONPROPERTY` carries `net_transport`, `protocol_type` and `auth_scheme`, not
`encrypt_option`, and returns NULL for any other property name.

## Do not

- Do not assume a connection string alone enables Entra ID on 7.0 or later. It needs the extension
  package, and `GetProvider` says in one line whether it is there.
- Do not start new work on `System.Data.SqlClient`.
- Do not set `TrustServerCertificate=True` to clear a certificate error. Read `connect-to-azure-sql`.
- Do not cache or share a `SqlConnection` across requests, and do not vary the connection string per
  request, per tenant or per call site without meaning a separate pool. Cache nothing; the pool is
  the cache.
- Do not use `Active Directory Password`, and do not pass a managed identity object id to a 3.0 or
  later driver; it wants the client id.
- Do not hard-code a password, token, server hostname or identity id.
- Do not write retry loops here. Transient-fault handling is one policy for every language, in
  `connect-to-azure-sql`.

## References

- Open `references/entra-modes-and-connection-keywords.md` when the mode you need is not one of the
  three above, or before setting a keyword this body does not list: every `Authentication` value
  with the driver version it arrived in, and the encryption and pooling defaults read off 7.0.2.
- [Entra authentication with
  SqlClient](https://learn.microsoft.com/sql/connect/ado-net/sql/azure-active-directory-authentication):
  every mode, the version it arrived in, and the 7.0 migration steps. Read before choosing a mode or
  debugging a provider error.
- [SqlConnection.ConnectionString](https://learn.microsoft.com/dotnet/api/microsoft.data.sqlclient.sqlconnection.connectionstring):
  every keyword with its default. Read it rather than recalling a default.
- [SQL Server connection pooling](https://learn.microsoft.com/sql/connect/ado-net/sql-server-connection-pooling):
  how the pool key is formed. Read it when two code paths appear to fight over connections.
- [sys.dm_exec_connections](https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-views/sys-dm-exec-connections-transact-sql):
  the columns check four reads and the permission it needs. Read it when that query returns no row.
- `connect-to-azure-sql`: encryption doctrine, retry, pool sizing, and the first-connect error on a
  paused database. `ef-core-azure-sql`: the same database through an object-relational mapper, whose
  connection string still comes from here.
