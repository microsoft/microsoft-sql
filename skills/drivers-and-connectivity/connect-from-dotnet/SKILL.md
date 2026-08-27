---
name: connect-from-dotnet
description: >-
  Connects a .NET application to Azure SQL Database with Microsoft.Data.SqlClient: which package
  references are required, the encryption defaults and what changed, connection pooling and the
  keys that split a pool, and managed identity or other Microsoft Entra ID modes. Use when a user
  says "connect .NET to Azure SQL", "Microsoft.Data.SqlClient", "SqlConnection", "managed identity
  for my API", "Active Directory Default", "Max Pool Size", "Encrypt=Strict", or reports the error
  "Cannot find an authentication provider". Also use when an app authenticates with a password
  locally and must use an identity in Azure. Covers packages, connection string keywords, pooling
  and Entra ID for .NET only; the ORM path is ef-core-azure-sql, and encryption doctrine plus
  transient-fault retry belong to connect-to-azure-sql.
license: MIT
---

# Connect from .NET

The driver is `Microsoft.Data.SqlClient`, encryption is on by default, pooling is automatic, and
since version 7.0 Microsoft Entra authentication needs a **second package reference** that nothing
in the connection string hints at.

Verified on 2026-08-27 against `Microsoft.Data.SqlClient` 7.0.2 and
`Microsoft.Data.SqlClient.Extensions.Azure` 7.0.2, restored and executed rather than recalled.

This skill owns the .NET-specific half: packages, connection string keywords, pooling and Entra ID.
Encryption doctrine, retry and transient-fault handling, and the first-connect error on a paused
database are the same in every language and live in `connect-to-azure-sql`. Entity Framework Core
is `ef-core-azure-sql`.

## The packages

```bash
dotnet add package Microsoft.Data.SqlClient
```

`System.Data.SqlClient` is the older provider and does not receive the new features. New code uses
`Microsoft.Data.SqlClient`; a `using System.Data.SqlClient;` in a new file is a mistake worth
fixing before anything else.

## Gotcha: Entra ID needs a second package from version 7.0

`Microsoft.Data.SqlClient` 7.0 removed the Azure and Entra ID dependencies from the core package.
Confirmed in the restored dependency graph: 7.0.2 pulls **no** `Azure.Identity`, `Azure.Core` or
`Microsoft.Identity.Client`. Those arrive only with the extension package.

So a connection string that used to work now fails at `Open()`. Run against the core package alone,
`Authentication=Active Directory Default` produces:

```
System.ArgumentException: Cannot find an authentication provider for 'ActiveDirectoryDefault'.
Install the 'Microsoft.Data.SqlClient.Extensions.Azure' NuGet package to use Active Directory
(Entra ID) authentication methods.
```

The fix is a package reference, and no code change:

```bash
dotnet add package Microsoft.Data.SqlClient.Extensions.Azure
```

The extension registers its authentication providers automatically. Every `Active Directory *` mode
needs it. Applications that use SQL authentication, Windows integrated authentication, or supply
their own token through `AccessToken` or `AccessTokenCallback` do not, and they get a lighter
dependency graph as a result.

## Encryption defaults, and the version that changed them

| Keyword | Default | Notes |
|---|---|---|
| `Encrypt` | `True` from version 4.0. `False` in 3.x and earlier | Values in 5.0 and later: `true`/`mandatory`, `false`/`optional`, and `strict` for TDS 8.0 |
| `TrustServerCertificate` | `False` | With `Encrypt=Strict` it is ignored and treated as false |
| `HostNameInCertificate` | not set | Available from 5.0, for when the certificate name differs from the data source |

Verified by reading the defaults out of `SqlConnectionStringBuilder` on 7.0.2.

The practical consequence: code written against a 3.x default and upgraded starts validating
certificates, and the failure surfaces as a connection error rather than as an upgrade note. Reach
for `connect-to-azure-sql` before changing either value; the answer is almost never
`TrustServerCertificate=True`.

## Pooling is automatic, and the connection string is the key

Never cache a `SqlConnection`. Open one, use it, dispose it. The pool underneath does the reuse.

```csharp
await using var connection = new SqlConnection(connectionString);
await connection.OpenAsync(cancellationToken);
```

Defaults, read out of the builder on 7.0.2:

| Keyword | Default |
|---|---|
| `Pooling` | `True` |
| `Max Pool Size` | 100 |
| `Min Pool Size` | 0 |
| `Connect Timeout` | 15 |
| `Load Balance Timeout` | 0 |
| `Multiple Active Result Sets` | `False` |
| `Connect Retry Count` | 1 |
| `Connect Retry Interval` | 10 |

Four things that decide whether pooling actually helps:

- **The pool key is the whole connection string.** Two strings that differ in any way, including a
  per-tenant `Application Name` or a rearranged keyword, get two pools, and both count against the
  same server limits. Build the string once.
- **`Connect Timeout` defaults to 15 seconds**, and Microsoft's guidance for Azure SQL Database is
  30. Set it deliberately.
- **`Connect Retry Count` and `Connect Retry Interval` are idle-connection resiliency inside the
  driver**, which transparently reconnects a dropped idle connection. They do not replay a failed
  query. The builder reports 1, but from version 5 the effective default is raised for Azure SQL
  endpoints and raised further for serverless ones, so read the value from the documentation rather
  than from the builder. Application-level retry is a separate thing and is `connect-to-azure-sql`.
  Keep both.
- **`AccessTokenCallback` is part of the pool key.** A new lambda per `SqlConnection` creates a new
  pool per connection. Reference one shared static callback.

Sizing the pool, and why the limit that bites is workers rather than sessions, is
`connect-to-azure-sql`.

## Microsoft Entra ID

Set `Authentication` in the connection string. Values and the version each arrived in:

| Value | From | Use it for |
|---|---|---|
| `Active Directory Managed Identity` or `Active Directory MSI` | 2.1.0 | An Azure-hosted workload. The recommended production mode |
| `Active Directory Default` | 3.0.0 | Development machines and CI, where the credential varies |
| `Active Directory Workload Identity` | 5.2.0 | A federated identity on a Kubernetes-style host |
| `Active Directory Service Principal` | 2.0.0 | A registered application, client id in `User Id` and secret in `Password` |
| `Active Directory Interactive` | 2.0.0 | A person at a browser, with multifactor authentication |
| `Active Directory Device Code Flow` | 2.1.0 | A host with no browser. Raise `Connect Timeout` to allow for the sign-in |
| `Active Directory Integrated` | 2.0.0 | A domain-joined Windows client |
| `Active Directory Password` | 1.0 | Nothing. Deprecated, and marked obsolete in 7.0 |

### Managed identity

System-assigned needs nothing beyond the mode:

```csharp
var connectionString =
    "Server=tcp:<server>.database.windows.net,1433;" +
    "Database=<database>;" +
    "Authentication=Active Directory Managed Identity;" +
    "Encrypt=Mandatory;";
```

User-assigned supplies the identity in `User Id`, and **which identifier** depends on the driver
version: the **client id** from 3.0 onwards, the **object id** on 2.1. Everything current wants the
client id, and passing the object id to a modern driver fails at token acquisition with an error
that points at the identity endpoint rather than at the connection string.

```csharp
var connectionString =
    "Server=tcp:<server>.database.windows.net,1433;" +
    "Database=<database>;" +
    "Authentication=Active Directory Managed Identity;" +
    "User Id=<managed-identity-client-id>;" +
    "Encrypt=Mandatory;";
```

`Active Directory Default` walks a chain of credential providers on the first connection, and the
providers that fail come first, so it costs latency a production workload has no reason to pay.
Microsoft's own guidance is to name the credential type directly outside development.

The identity still needs a database principal before it can connect. Creating it is `entra-id-auth`,
and wiring the identity across Azure resources is `managed-identity-across-azure-services`.

## Validation rules

- The project references `Microsoft.Data.SqlClient`, not `System.Data.SqlClient`.
- Any project using an `Active Directory *` mode also references
  `Microsoft.Data.SqlClient.Extensions.Azure`.
- `Encrypt` is absent, `Mandatory` or `Strict`, and `TrustServerCertificate` is absent or false.
- `Connect Timeout` is set deliberately rather than inheriting 15.
- The connection string is built once, and any variation between call sites is an intentional
  second pool.
- A user-assigned managed identity supplies its client id in `User Id`.
- `SqlConnection` instances are disposed rather than cached, and `AccessTokenCallback`, if used, is
  a single shared instance.
- No password, token, server hostname or identity id is hard-coded.

## Do not

- Do not assume a connection string alone enables Entra ID on 7.0 or later. It needs the extension
  package, and the failure is an `ArgumentException` at `Open()`.
- Do not start new work on `System.Data.SqlClient`.
- Do not set `TrustServerCertificate=True` to clear a certificate error. Read `connect-to-azure-sql`.
- Do not cache or share a `SqlConnection` across requests. Cache nothing; the pool is the cache.
- Do not vary the connection string per request, per tenant or per call site without meaning to
  create a separate pool.
- Do not create a new `AccessTokenCallback` lambda per connection.
- Do not use `Active Directory Password`. It is deprecated and obsolete in 7.0.
- Do not pass a managed identity object id to a 3.0 or later driver; it wants the client id.
- Do not write retry loops here. Transient-fault handling is one policy for every language, in
  `connect-to-azure-sql`.

## References

- [Connect to Azure SQL with Microsoft Entra authentication and
  SqlClient](https://learn.microsoft.com/sql/connect/ado-net/sql/azure-active-directory-authentication):
  every authentication mode, the version it arrived in, and the 7.0 migration steps. Read it before
  choosing a mode or debugging a provider error.
- [SqlConnection.ConnectionString](https://learn.microsoft.com/dotnet/api/microsoft.data.sqlclient.sqlconnection.connectionstring):
  every keyword with its default. Read it rather than recalling a default.
- [SQL Server connection pooling](https://learn.microsoft.com/sql/connect/ado-net/sql-server-connection-pooling):
  how the pool key is formed and when pools are created. Read it when two code paths appear to
  fight over connections.
- `connect-to-azure-sql`: encryption doctrine, retry and transient faults, pool sizing, and the
  first-connect error on a paused database.
- `ef-core-azure-sql`: the same database through an object-relational mapper, where the connection
  string still comes from here.
