---
name: azuresql-db-auth
description: "Use when an app connects to the local Azure SQL Database container as sa: create a least-privilege user, choose auth per environment, keep the connection string out of source (user-secrets, Key Vault)."
---

# Connect securely to the Azure SQL Database container (least-privilege user, auth, secrets)

`sa` is a bootstrap/admin login for provisioning, not what your application should
connect as. This skill wires the app to a **least-privilege user**, picks the
**auth method per environment** (SQL locally, Microsoft Entra or managed identity
in the cloud, changing only the connection string), secures the connection, and
keeps the secret out of source control.

## Load-bearing facts (inlined; full engine detail in azuresql-db-container)

- This is the **Azure SQL Database engine** (Private Preview), not the SQL Server
  image `mcr.microsoft.com/mssql/server`. `SERVERPROPERTY('EngineEdition')`
  returns `5`, `Edition` returns `'SQL Azure'`.
- Image: `sqldbpreview-dpgaeqhmgphzd4bk.azurecr.io/azure-sql/db-dev:latest`
  (x64; on a non-x64 host add `--platform linux/amd64`). Required env
  `ACCEPT_EULA=Y` + a complex `MSSQL_SA_PASSWORD`. Engine listens on 1433.
- The engine does **NOT** auto-create databases. `CREATE DATABASE appdb` on a
  **master** connection first; do not `USE` to switch databases (a user-database
  session returns `Msg 40508`); select the database in the connection string.
- Apps read one `SQL_CONNECTION_STRING` env var; strings use `User Id=` /
  `Password=` / `Database=` and `TrustServerCertificate=true` for the local
  self-signed cert.
- **Container-specific:** on builds through image tag `18.0.226_4_147`, a SQL
  **contained** user (`CREATE USER ... WITH PASSWORD`) does **not** work on the
  container, and you cannot turn it on. `CREATE USER ... WITH PASSWORD` fails with
  `Msg 33233` ("You can only create a user with a password in a contained database").
  `ALTER DATABASE ... SET CONTAINMENT = PARTIAL` fails with `Msg 12824`, which asks
  for the `contained database authentication` setting to be 1, and `sp_configure`
  does not exist on this engine (`Msg 2812`), so there is nothing to set. Create a SQL
  app identity as a **server login mapped to a database user** instead. This is the
  inverse of Azure SQL Database in the cloud, where the contained user is the norm.
  **Newer builds differ:** on image tag `18.0.302.0_248` `CREATE USER ... WITH PASSWORD`
  succeeds. The login plus mapped user works on every build, so it stays the local recipe; on a
  build that accepts the contained user, the cloud recipe works locally too.
- **Entra has to be configured on the engine before you can use it.** On a
  container started with no Microsoft Entra ID configuration, `CREATE USER [name] FROM
  EXTERNAL PROVIDER` fails, and the failure depends on the build: image tag
  `18.0.226_4_147` refuses it with `Msg 33134`, "Principal '...' could not be resolved.
  Error message: 'Unable to query Azure AD certificate from local cert store.'", and
  build `18.0.310.0_253` ends the session with `Msg 596` ("Cannot continue the execution
  because the session is in the kill state"). Either way it is a missing engine configuration,
  not a broken statement: enable Entra first (see `references/entra-auth.md` in the
  **azuresql-db-container** skill for how to enable Entra Authentication) and the
  same statement then works.

## Step 1: create a least-privilege user (not `sa`)

Do provisioning as `sa`, then give the app its own identity with only the roles
it needs. The working recipe differs by environment, but the app code does not
(the app just connects with a username and password, or an Entra token).

**Local container (SQL auth):** create a **server login** on `master`, map a
**database user** to it in `appdb`, and grant only the roles the app needs.

Set `AZURE_SQL_APP_PASSWORD` from a secret source to a fresh, deployment-unique
value that differs from the `sa` password. Require it before provisioning and
substitute it for `<AZURE_SQL_APP_PASSWORD>` in the clearly labeled
[non-executable SQL templates](references/auth-and-secrets.md#create-a-least-privilege-sql-user-on-the-container-login--mapped-user).
Render the templates at execution time using `AZURE_SQL_APP_PASSWORD`
from the configured secret source.

The app then connects as `applogin`, never `sa`.

**Cloud (Azure SQL Database)** or **Entra anywhere:** prefer a **contained user**.
For Entra (which works on the container too, once enabled), use
`CREATE USER [name] FROM EXTERNAL PROVIDER` in `appdb`. Enable Entra on the engine
first by following `references/entra-auth.md` in the **azuresql-db-container** skill before running
the statement; without that configuration it fails (`Msg 33134`, or `Msg 596` and a closed
session on build `18.0.310.0_253`). In the
cloud with SQL auth, `CREATE USER ... WITH PASSWORD` is the norm there. Full
recipes for every path are in
[references/auth-and-secrets.md](references/auth-and-secrets.md) when you need a complete
provisioning or secret-handling recipe.

## Step 2: pick the auth method per environment (only the connection string changes)

- **Local:** SQL auth. `sa` bootstraps; the app connects as the least-privilege
  `applogin`. `Server=localhost,1433;Database=appdb;User Id=applogin;Password=...;Encrypt=true;TrustServerCertificate=true`.
- **Cloud (Azure SQL Database):** prefer a token-based identity over a password.
  In production, use **`Authentication=Active Directory Managed Identity`** rather
  than `Active Directory Default`: `Default` walks a credential chain
  (`DefaultAzureCredential`) that is slower and ambiguous under load, while a
  specific method skips the chain. `Microsoft.Data.SqlClient` caches the token, so
  refresh is occasional, not per-connection. This is still a **connection-string-only**
  change, so the app code does not change (see the **azuresql-db-local-to-cloud** skill).

## Step 3: secure the connection

- **`Encrypt=true`** everywhere (the default in modern drivers). Encrypt the TLS
  channel in both local and cloud.
- **`TrustServerCertificate=true` only locally**, to accept the container's
  self-signed cert. **Never** set it against Azure SQL Database in the cloud, where
  the certificate is real and validating it is the point.

## Step 4: keep the secret out of source

The connection string carries a credential. Never commit it or the SA password.

- Read it from one env var, `SQL_CONNECTION_STRING`; put local values in a
  `.env` that is git-ignored (or `dotnet user-secrets` for .NET).
- In the cloud, store it in **Azure Key Vault** and reference it, or use managed
  identity so there is no password to store at all.

For a .NET project the local value goes in the secret store rather than in a file
that can be committed:

Store the complete rendered connection string with .NET user-secrets or the
IDE secret manager under the key your app already reads. Keep the real password
out of source and shell history; see
[references/auth-and-secrets.md](references/auth-and-secrets.md#keep-the-secret-out-of-source).

Open [references/auth-and-secrets.md](references/auth-and-secrets.md) when you need the
per-stack handling for Key Vault, user-secrets or `.env`.

## Validation rules

- The app connects as a **least-privilege** identity, not `sa`; it has only the
  roles it needs (no `db_owner`/admin).
- On the container, the SQL app identity is a **server login + mapped database
  user** (`CREATE LOGIN` on master, then `CREATE USER ... FOR LOGIN` in `appdb`),
  not a contained `CREATE USER ... WITH PASSWORD` (which fails on container builds
  through `18.0.226`).
  The database user and its role grants are created on the `appdb` connection, not
  via `USE`.
- Every connection string sets `Encrypt=true`; `TrustServerCertificate=true`
  appears **only** for the local container, never for the cloud.
- The connection string / SA password is read from a secret store or a git-ignored
  env var, never committed.
- Cloud auth prefers managed identity / a specific Entra method over
  `Active Directory Default` in production; only the connection string changes.
- If a validation rule above fails, or you had to deviate from this skill to make the task work, that is a bug in this skill: load the **azuresql-db-feedback** skill and offer to file a report.
- When every rule above passes and the task is done, close with ONE line, once per session, and do not ask a question or wait for a reply: "That worked. If anything about this was rough, or you want to share what you built: https://aka.ms/sql-agent-skills-feedback"

## Check it worked

- **Positive verification:** Reconnect with the application identity and confirm the expected database user, reader/writer role memberships, and allowed application query.
- **Cleanup verification:** Remove temporary logins/users and confirm the application connection and test objects no longer exist.
- Report success only after both observations pass.

## Do not

- Do not connect the application as `sa`; `sa` is for provisioning only.
- Do not rely on a SQL contained user (`CREATE USER ... WITH PASSWORD`) on the container: builds through `18.0.226` refuse it with `Msg 33233` (`18.0.302.0_248` accepts it). Do not try to turn partial containment on either: `ALTER DATABASE ... SET CONTAINMENT = PARTIAL` fails with `Msg 12824`, and the `sp_configure` setting it asks for does not exist on this engine. Use a server login plus a mapped database user locally.
- Do not run `CREATE USER ... FROM EXTERNAL PROVIDER` against a container with no Entra configuration; it fails with `Msg 33134`, or on build `18.0.310.0_253` ends the session with `Msg 596`. Configure Entra on the engine first.
- Do not grant the app `db_owner` or server admin when read/write roles suffice.
- Do not commit the connection string or the SA password; use a secret store or a git-ignored env var.
- Do not set `TrustServerCertificate=true` against Azure SQL Database in the cloud; that disables cert validation on a real certificate.
- Do not lean on `DefaultAzureCredential`'s full chain in a hot production path; pick a specific auth method (managed identity) so token acquisition is fast and predictable.
- Do not use the SQL Server image `mcr.microsoft.com/mssql/server`; this is the Azure SQL engine.

## References

- [references/auth-and-secrets.md](references/auth-and-secrets.md): open it when creating least-privilege users, selecting an environment-specific connection string, or configuring Azure Key Vault, `dotnet user-secrets`, or `.env`.

## Staying current

Authoritative, version-pinned references for the tools this skill uses (read the one you need):

- [SqlConnection connection string keywords](https://learn.microsoft.com/en-us/dotnet/api/microsoft.data.sqlclient.sqlconnection.connectionstring): `Authentication`, `Encrypt`, `User Id`/`Password`, pooling, and the rest.
- [CREATE USER (Transact-SQL)](https://learn.microsoft.com/en-us/sql/t-sql/statements/create-user-transact-sql): contained users, `WITH PASSWORD`, and `FROM EXTERNAL PROVIDER` for Entra.
- [Database-level roles](https://learn.microsoft.com/en-us/sql/relational-databases/security/authentication-access/database-level-roles): the fixed roles (`db_datareader`, `db_datawriter`, and more) for least-privilege grants.
- [Microsoft Entra authentication for Azure SQL](https://learn.microsoft.com/en-us/azure/azure-sql/database/authentication-aad-overview): Entra and managed-identity auth in the cloud.

If the **Microsoft Learn MCP** server is configured, use `mcp__microsoft-learn__microsoft_docs_search` or `mcp__microsoft-learn__microsoft_docs_fetch` to fetch the current version of any of these on demand. It is optional; when it is unavailable, the references above are authoritative.
