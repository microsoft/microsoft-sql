# Microsoft Entra ID modes and connection string keywords

`Microsoft.Data.SqlClient` reference detail. SKILL.md carries the three modes most
applications need and the defaults that change behaviour; this file carries the full lists.

- [Authentication modes](#authentication-modes)
- [Encryption keywords](#encryption-keywords)
- [Pooling and connection keywords](#pooling-and-connection-keywords)

## Authentication modes

Every value accepted by the `Authentication` connection string keyword, with the driver version it
arrived in. All of them need the `Microsoft.Data.SqlClient.Extensions.Azure` package reference on
7.0 and later.

| Value | From | Use it for |
|---|---|---|
| `Active Directory Managed Identity` or `Active Directory MSI` | 2.1.0 | An Azure-hosted workload. The production mode |
| `Active Directory Default` | 3.0.0 | Development machines and CI, where the credential varies |
| `Active Directory Workload Identity` | 5.2.0 | A federated identity on a Kubernetes-style host |
| `Active Directory Service Principal` | 2.0.0 | A registered app, client id in `User Id`, secret in `Password` |
| `Active Directory Interactive` | 2.0.0 | A person at a browser, with multifactor authentication |
| `Active Directory Device Code Flow` | 2.1.0 | A host with no browser. Raise `Connect Timeout` for the sign-in |
| `Active Directory Integrated` | 2.0.0 | A domain-joined Windows client |
| `Active Directory Password` | 1.0 | Nothing. Deprecated, and obsolete in 7.0 |

`Active Directory Default` walks a chain of credential providers on every first connection, failing
ones first, so it costs latency a production workload has no reason to pay.

## Encryption keywords

| Keyword | Default | Notes |
|---|---|---|
| `Encrypt` | `True` from version 4.0. `False` in 3.x and earlier | Values in 5.0 and later: `true`/`mandatory`, `false`/`optional`, and `strict` for TDS 8.0 |
| `TrustServerCertificate` | `False` | With `Encrypt=Strict` it is ignored and treated as false |
| `HostNameInCertificate` | not set | Available from 5.0, for when the certificate name differs from the data source |

## Pooling and connection keywords

Read out of `SqlConnectionStringBuilder` on 7.0.2, measured 2026-09-03 on .NET SDK 8.0.421.

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

`Connect Retry Count` and `Connect Retry Interval` are idle-connection resiliency inside the driver.
The builder reports the library default; from version 5 the effective default is raised for Azure SQL
Database endpoints and again for serverless ones, so read the current number from
[SqlConnection.ConnectionString](https://learn.microsoft.com/dotnet/api/microsoft.data.sqlclient.sqlconnection.connectionstring)
rather than from the builder.
