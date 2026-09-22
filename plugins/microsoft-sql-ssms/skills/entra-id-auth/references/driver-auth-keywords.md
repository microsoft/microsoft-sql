# The authentication keyword, per driver, verbatim

## Contents

- [How to use this file](#how-to-use-this-file)
- [Microsoft.Data.SqlClient, for .NET](#microsoftdatasqlclient-for-net)
- [ODBC Driver 18 for SQL Server, including pyodbc](#odbc-driver-18-for-sql-server-including-pyodbc)
- [mssql-python](#mssql-python)
- [tedious, under the Node.js mssql package](#tedious-under-the-nodejs-mssql-package)
- [The Microsoft JDBC driver](#the-microsoft-jdbc-driver)
- [sqlcmd](#sqlcmd)
- [The same idea, five spellings](#the-same-idea-five-spellings)
- [Password authentication is deprecated everywhere](#password-authentication-is-deprecated-everywhere)
- [Sources](#sources)

## How to use this file

Read it before writing an authentication keyword into a connection string. Each list below is the
**complete** documented set for that driver, so a value not in the list is not a value.

The failure this prevents is quiet: a driver that does not recognise the value may fall through to
a different mechanism and produce a login failure that reads as a database permission problem.

## Microsoft.Data.SqlClient, for .NET

The only family that writes the values **with spaces**.

| Value | Since |
|---|---|
| `Active Directory Integrated` | 2.0.0 |
| `Active Directory Interactive` | 2.0.0 |
| `Active Directory Service Principal` | 2.0.0 |
| `Active Directory Device Code Flow` | 2.1.0 |
| `Active Directory Managed Identity`, and the alias `Active Directory MSI` | 2.1.0 |
| `Active Directory Default` | 3.0.0 |
| `Active Directory Workload Identity` | 5.2.0 |
| `Active Directory Password` | 1.0, deprecated |

- User-assigned managed identity: `User Id=<client id>`. On 3.0 and later that is the **client id**;
  on 2.1 it was the object id.
- `Active Directory Default` reads the same `User Id` property for the managed identity client id.
- `Active Directory Workload Identity` also takes the client id in `User Id`, and otherwise defaults
  from environment variables.
- Microsoft warns that `Active Directory Default` "can come with performance impacts because it has
  to look in multiple places for authentication information", and is not recommended where response
  times are tight. Name the mode explicitly in production.

**Version 7.0 is a breaking change.** The core package no longer carries the Azure and Entra
dependencies, and any of these modes needs the `Microsoft.Data.SqlClient.Extensions.Azure` package
added. Connection strings do not change. `SqlAuthenticationMethod.ActiveDirectoryPassword` became
`[Obsolete]` in the same release. An application that authenticated fine before the upgrade and
fails after it is usually missing that package reference, and says so at run time with
`Cannot find an authentication provider for 'ActiveDirectoryDefault'.`

```bash
dotnet list package --include-transitive | grep Microsoft.Data.SqlClient
```

## ODBC Driver 18 for SQL Server, including pyodbc

The complete documented set, verbatim from the keyword table:

> `(not set)`(default), `(empty string)`, `SqlPassword`, `ActiveDirectoryIntegrated`,
> `ActiveDirectoryInteractive`, `ActiveDirectoryMsi`, `ActiveDirectoryServicePrincipal`,
> `ActiveDirectoryPassword` [DEPRECATED]

**There is no `ActiveDirectoryDefault` and no `ActiveDirectoryManagedIdentity` in ODBC.** There is
also no device code mode. Writing any of those into a `pyodbc` connection string is the single most
common invented value in this area.

Managed identity, quoted:

> `ActiveDirectoryMsi` - Authenticate with a Microsoft Entra managed identity. For a user-assigned
> identity, set UID to the identity's client ID for Azure App Service or Azure Container Instance;
> otherwise, use its object ID. For system-assigned identity, UID isn't required.

```text
server=<server>;database=<database>;Authentication=ActiveDirectoryMsi;Encrypt=yes;
server=<server>;database=<database>;UID=<object id>;Authentication=ActiveDirectoryMsi;Encrypt=yes;
```

Version notes: managed identity arrived in 17.3.1.1 for both identity kinds;
`ActiveDirectoryServicePrincipal` in 17.7, where `UID` is the client id and `PWD` the client secret.

A token can be supplied instead through the `SQL_COPT_SS_ACCESS_TOKEN` pre-connection attribute.
When it is used, the connection string must not contain `UID`, `PWD`, `Authentication` or
`Trusted_Connection`.

## mssql-python

Seven modes, all through the `Authentication` connection-string keyword.

| Value | What it does |
|---|---|
| `ActiveDirectoryDefault` | `DefaultAzureCredential`, which walks a chain of providers |
| `ActiveDirectoryInteractive` | Browser sign-in |
| `ActiveDirectoryDeviceCode` | Code entry on a second device |
| `ActiveDirectoryMSI` | Managed identity, either kind |
| `ActiveDirectoryServicePrincipal` | `UID` is the client id, `PWD` the client secret |
| `ActiveDirectoryIntegrated` | Kerberos, in a federated domain |
| `ActiveDirectoryPassword` | Deprecated |

`ActiveDirectoryDefault`, `ActiveDirectoryInteractive` and `ActiveDirectoryDeviceCode` need the
`azure-identity` package installed alongside the driver.

User-assigned managed identity, quoted: "Specify the client ID of a user-assigned managed identity
in the `UID` field."

```python
"Server=<server>.database.windows.net;"
"Database=<database>;"
"Authentication=ActiveDirectoryMSI;"
"UID=<managed identity client id>;"
"Encrypt=yes;"
```

Note the spelling: `ActiveDirectoryMSI` here, `ActiveDirectoryMsi` in ODBC, and
`ActiveDirectoryManagedIdentity` in neither.

## tedious, under the Node.js mssql package

The value is an object, not a string, and the driver validates the type against a fixed list:
`default`, `ntlm`, `token-credential`, `azure-active-directory-password`,
`azure-active-directory-access-token`, `azure-active-directory-default`,
`azure-active-directory-msi-vm`, `azure-active-directory-msi-app-service`,
`azure-active-directory-service-principal-secret`.

```js
authentication: {
  type: 'azure-active-directory-default',
  options: { clientId: '<user assigned identity client id>' }
}
```

**The client id is read from `authentication.options.clientId` and nowhere else.** A sample that
places `clientId` in the connection `options` bag beside `encrypt` appears to work only when the
matching environment variable is also set, which the credential chain picks up on its own. Remove
the environment variable and the same code silently falls back to the system-assigned identity.

`token-credential` takes a credential object from the identity library directly, and is the
cleanest option when the credential is already constructed in application code.

The Node.js package's own README lists an older, shorter set of types. It passes `authentication`
straight through, so the driver's list above is the authority.

## The Microsoft JDBC driver

`authentication=` accepts `NotSpecified` (the default), `SqlPassword`, `ActiveDirectoryPassword`,
`ActiveDirectoryIntegrated`, `ActiveDirectoryInteractive`, `ActiveDirectoryServicePrincipal`,
`ActiveDirectoryServicePrincipalCertificate`, `ActiveDirectoryManagedIdentity` and
`ActiveDirectoryDefault`.

- `ActiveDirectoryMSI` is accepted as a **synonym** for `ActiveDirectoryManagedIdentity`. Prefer the
  long form on driver 12.2 and later.
- User-assigned client id goes in `msiClientId`, and from 12.2 the `user` property is also accepted.
  JDBC takes the **client** id, unlike ODBC.
- Dependencies split by mode: the MSAL library for the interactive, integrated, password and service
  principal modes, and the Azure identity library for the managed identity and default modes.
  Missing the right one produces a class-loading failure rather than a login failure.

## sqlcmd

Verified by running the tool at version 1.10.0. Supplying an invalid value prints the accepted set:

```text
Invalid federated authentication type 'NotARealMode': expected one of [ActiveDirectoryApplication
ActiveDirectoryServicePrincipal ActiveDirectoryDefault ActiveDirectoryIntegrated
ActiveDirectoryInteractive ActiveDirectoryManagedIdentity ActiveDirectoryMSI ActiveDirectoryPassword
ActiveDirectoryAzCli ActiveDirectoryDeviceCode ActiveDirectoryAzureDeveloperCli
ActiveDirectoryAzurePipelines ActiveDirectoryEnvironment ActiveDirectoryWorkloadIdentity
ActiveDirectoryClientAssertion ActiveDirectoryOnBehalfOf]
```

`-G` selects Entra authentication with the interactive or default flow, and
`--authentication-method=<value>` names one of the above. Asking the tool is faster and more
reliable than recalling the list, and it is a good habit for any driver that will tell you.

## The same idea, five spellings

One concept, managed identity, across the drivers:

| Driver | The value |
|---|---|
| `Microsoft.Data.SqlClient` | `Active Directory Managed Identity` |
| ODBC Driver 18 | `ActiveDirectoryMsi` |
| `mssql-python` | `ActiveDirectoryMSI` |
| `tedious` | `azure-active-directory-msi-app-service` or `azure-active-directory-msi-vm` |
| JDBC | `ActiveDirectoryManagedIdentity` |

And the passwordless default mode does not exist at all in ODBC.

## Password authentication is deprecated everywhere

The drivers carry the same wording:

> The ActiveDirectoryPassword authentication option (Microsoft Entra ID password authentication) is
> deprecated in the Microsoft SQL drivers. This high-risk authentication flow is incompatible with
> mandatory Microsoft Entra multifactor authentication (MFA) and might not work in tenants where MFA
> is enforced. Plan to migrate to a different Microsoft Entra authentication method.

It rests on the resource owner password credentials grant. No removal version is stated anywhere, so
it is a deprecation rather than a removal, but a tenant enforcing multifactor authentication already
breaks it. The documented replacements: an interactive or integrated mode when a person is present,
managed identity on Azure, and a service principal with a certificate rather than a secret elsewhere.

## Sources

All read on 2026-08-27. Fetch rather than trust this summary when a value is load-bearing.

- SqlClient: `/sql/connect/ado-net/sql/azure-active-directory-authentication`, which carries the value table, the version column and the 7.0 migration section.
- ODBC: `/sql/connect/odbc/using-azure-active-directory`, which carries the keyword table and the managed identity id rule.
- mssql-python: `/sql/connect/python/mssql-python/entra-authentication`, which carries the seven modes and the `UID` rule.
- JDBC: `/sql/connect/jdbc/connecting-using-azure-active-directory-authentication`, which carries the property values, the synonym and the dependency table.
- tedious: the driver's own source and released documentation, which is the authority over the wrapping package's README.
