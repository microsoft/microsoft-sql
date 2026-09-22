---
name: dev-container-templates
description: >-
  Sets up local development from the Azure SQL Database dev container templates in
  microsoft/azuresql-devcontainers (.NET, .NET Aspire, Node.js, Python), each with a sample database
  and schema loaded. Use for "start from the Azure SQL Database dev container template", "which
  Azure SQL Database devcontainer should I pick", or "add a dev container with a database already in
  it", and for what these templates do: an empty database, a schema project that never deploys, a
  saved profile prompting for a password, a database at localhost not a service name, a vector index
  refused, a port on the app service refused, or the local database in a template not behaving the
  way the Azure SQL Database documentation describes, because it is SQL Server. Covers the SQL
  Database project whose target platform, not the engine, decides what Azure SQL Database accepts,
  and the create-time build and publish.
---

# Start from an Azure SQL Database dev container template

`microsoft/azuresql-devcontainers` ships four dev container templates. Each starts two containers,
one for the application toolchain and one for a database, with a sample `Library` schema deployed
into it. The published walkthrough is a screenshot tour; what breaks is in the files. Not covered:
the SQL Database project format itself (`sql-database-projects`) and a cloud database
(`provision-azure-sql-db`).

The SQL Database project's target platform decides what Azure SQL Database will accept. The
database in these templates is SQL Server, major version 17, which reports EngineEdition 3, not the Azure SQL
Database engine.

Everything below was measured on 2026-09-17 against template version **2.0.0**, applied from
`ghcr.io/microsoft/azuresql-devcontainers/dotnet:2.0.0` and brought up with the dev container CLI
0.89.0 on Docker 29.4.0 and Compose v5.1.2, on an Apple silicon host. The fourteen probes behind
those claims were run again on 2026-09-18 against a fresh application of the same template and all
passed; 2.0.0 was still the newest release and the head of `main` that day. Version 2.0.0 replaced the
engine, the runtimes and the create-time script, so nothing here carries over from 1.2.2.

**Which version is in front of you.** The applied workspace does not record it: the template
tooling omits `devcontainer-template.json`, `README.md` and `NOTES.md` when it copies files in, so
there is no version string to read afterwards. Two files answer it instead:

```bash
grep -m1 image: .devcontainer/docker-compose.yml   # 2.0.0 pins mcr.microsoft.com/mssql/server:2025-latest
grep -m1 FROM .devcontainer/Dockerfile             # 2.0.0 pins a 2-10.0-noble, 5-24-trixie or 3-3.14-trixie base
```

A workspace whose database service still names `mcr.microsoft.com/azure-sql-edge` is 1.2.2 or
earlier, and none of the behaviour below applies to it. Re-apply the template rather than editing
the old files.

## What decides whether your SQL is acceptable, and it is not the engine

This is the one thing to understand about these templates, and the one most likely to be got
wrong. Two different things are in play.

- **The engine in the database container is SQL Server**, not the Azure SQL Database engine. It will
  cheerfully run statements Azure SQL Database refuses.
- **The schema is validated against Azure SQL Database by the SQL Database project**, through one
  setting. `database/Library/Library.sqlproj` declares the target platform:

  ```xml
  <DSP>Microsoft.Data.Tools.Schema.Sql.SqlAzureV12DatabaseSchemaProvider</DSP>
  ```

  That provider is the Azure SQL Database one. It is what makes `dotnet build database/Library` a
  statement about the cloud rather than about the local engine, and changing it removes the only
  check in the workspace that looks at the platform you are deploying to.

The gate has teeth, and it was watched failing rather than assumed. A `FILESTREAM` column is
ordinary SQL Server and does not exist in Azure SQL Database. Added to the shipped project, the
build stops:

```text
Build error SQL70015: Keyword or statement option 'FILESTREAM' is not supported for the targeted platform.
Build FAILED.
```

The same file, in a copy of the same project with only the provider changed to the SQL Server one,
`Sql170DatabaseSchemaProvider`, builds clean. Nothing about the SQL changed; only the platform it
was judged against. For completeness, the running engine parses the statement too and asks for a
filegroup, `Msg 1969`, which is a configuration answer rather than a refusal.

So the working rule in one line: **put schema in the project and let the build judge it, and treat
anything you ran only in an ad hoc session as unproven for Azure SQL Database.** A statement that
succeeds against the local engine proves that SQL Server accepts it and nothing more. `sql-database-projects`
owns the project itself, its publish options and what a dacpac carries.

## What is actually running, as dated context

Read the image out of the compose file, then ask the server, and never infer the engine from a
template named for Azure SQL Database:

```bash
docker compose -f .devcontainer/docker-compose.yml config | grep -E '^[[:space:]]+image:'

sqlcmd -S localhost,1433 -U sa -P "$MSSQL_SA_PASSWORD" -C -I -b \
  -Q "SELECT SERVERPROPERTY('EngineEdition'), SERVERPROPERTY('Edition'), SERVERPROPERTY('ProductMajorVersion')"
```

Measured: EngineEdition `3`, `Enterprise Developer Edition (64-bit)`, ProductMajorVersion `17`, on
Ubuntu 24.04. The patch level moves under the `2025-latest` tag without the template changing:
`17.0.4085.5`, `RTM-CU8-GDR`, on 2026-09-17, and `17.0.5005.3`, `RTM-CU9`, after a fresh pull on
2026-09-18. Read it rather than quote it. The sample database comes up at compatibility level 170. The Azure SQL Database engine answers `5` and
`SQL Azure`, so if this query ever returns `5` the templates have changed engine and this section
needs rewriting rather than reinterpreting.

Where that difference shows, measured in the same session:

| Statement | Answer here | Why it matters |
|---|---|---|
| `SELECT TOP 1 * FROM sys.dm_db_resource_stats` | `Msg 208, Invalid object name` | a cloud-only view. Resource and throttling questions cannot be rehearsed here |
| `ALTER DATABASE Library MODIFY (SERVICE_OBJECTIVE = 'S0')` | `Msg 102, Incorrect syntax near '('` | there is no service objective on this engine |
| `CREATE USER [probe@example.com] FROM EXTERNAL PROVIDER` | `Msg 33134, Unable to query Azure AD certificate from local cert store` | Microsoft Entra principals stay a cloud concern here |
| `BACKUP DATABASE Library TO DISK = '/var/opt/mssql/probe.bak'` | accepted, 554 pages | Azure SQL Database refuses it outright. Do not learn a backup habit here |
| `USE Library` | accepted | Azure SQL Database refuses a database switch on a connection |
| `CREATE TABLE #v (id int, e vector(3))` with `VECTOR_DISTANCE('cosine', ...)` | accepted, returned `0.285714328289032` | the vector type and the distance function are present |
| `CREATE VECTOR INDEX` | `Msg 343, Unknown object type 'VECTOR' used in a CREATE, DROP, or ALTER statement` | until `ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES = ON` has run in that database in an earlier batch, after which the same statement is accepted. The templates ship it off |

None of those seven answers tells you what Azure SQL Database will do. Six of them tell you what it
will not do, which is useful in the other direction, and the seventh, the vector index, is a local
switch rather than a cloud one.

## Up is now ready, and the mechanism is worth knowing

Compose waits until a container is running, not until it is usable, and the application service
carries `network_mode: service:db`, which on its own synthesises `depends_on: db: condition:
service_started`. That combination was the gap in 1.2.2. Version 2.0.0 closes it in the files:

```bash
docker compose -f .devcontainer/docker-compose.yml config | grep -A3 'depends_on:'
```

The database service declares a health check that logs in, and the application service declares
`condition: service_healthy`, which survives alongside `network_mode`. Measured: the check runs
every 10 seconds with a 2 second start interval inside a 120 second start period, and the
application container started 10.1 seconds after the database container, once the login succeeded.
Nothing has to be added to the template.

Two things this does not do. It does not make `docker ps` meaningful: give the engine a password
it refuses and the database container still reports `Up` while the engine never finishes starting, so a
login is still the only proof. And it does not hold the editor, because the dev container
specification defaults `waitFor` to `updateContentCommand`, which leaves `postCreateCommand`
running in the background while the editor attaches. A terminal opened early can find the schema
still deploying. Wait for it the same way the create-time script does:

```bash
until sqlcmd -S localhost,1433 -U sa -P "$MSSQL_SA_PASSWORD" -C -I -b -l 5 -Q "SELECT 1" >/dev/null 2>&1; do sleep 2; done
```

`-l 5` bounds the login wait, without which a poll against a half-started engine can hang instead
of being refused. `-C` trusts the self-signed certificate. `-I` sets `QUOTED_IDENTIFIER` ON.

## The four templates

All four are version 2.0.0. They share one database service, byte for byte, one sample database
and one create-time script, and they differ in the toolchain image and what is layered on top.

| Template id | Default variant | Ports forwarded | Layered on top |
|---|---|---|---|
| `dotnet` | `10.0-noble` (or `8.0-noble`) | 5000, 5001, 8000, 1433 | Azure CLI with Bicep, azd, Docker CLI, SqlPackage 170.5.76 |
| `dotnet-aspire` | `10.0-noble` | 5000, 5001, 8000, 1433 | the same, plus the Aspire CLI and project templates, both 13.5.3 |
| `javascript-node` | `24-trixie` | 3000, 1433 | the .NET 10 feature for the schema project, plus the same tools |
| `python` | `3.14-trixie` | 5000, 1433 | the same, plus `mssql-python` 1.14.0 in place of pyodbc |

The variant is the `imageVariant` option and becomes the base image tag, so `24-trixie` builds
`javascript-node:5-24-trixie` and `3.14-trixie` builds `python:3-3.14-trixie`. The schema project is
the SDK-style `Microsoft.Build.Sql/2.2.0` in every template. Those pins were read from the files at
tag `v2.0.0` on 2026-09-18, which is also the head of `main` that day.

Check the toolchain arrived rather than assume the layer ran:

```bash
dotnet --list-sdks   # every template needs one for the schema project
sqlpackage /version  # a .NET tool installed at create time, not part of the image
azd version
```

Measured in the `dotnet` container: .NET SDK 10.0.401, SqlPackage 170.5.76.0, azd 1.34.0, Azure CLI
2.90.0, and `sqlcmd` 1.10.0, which is the Go build rather than the ODBC one. The .NET SDK in the
Node.js and Python templates is the price of the schema project; removing it removes the schema
deployment.

## Two containers, one network namespace

The application service carries `network_mode: service:db`, so it joins the database container's
network stack rather than getting its own. Each consequence was checked:

- **`localhost,1433` reaches the database from inside the application container**, and so do `db`
  and the hostname `SQL-Library`. All three logged in.
- **The application container's hostname is `SQL-Library`**, so anything deriving identity from
  the hostname sees the database container's name, and so does every message the engine prints.
- **The database service declares no volume**, so removing that container discards the database,
  and the schema returns only because the create step reruns.
- **A `ports:` block on the application service is refused, and validating the file will not tell
  you.** `docker compose config` accepts a service carrying both `network_mode: service:db` and
  `ports:`, exit 0. The daemon refuses it at create time:

  ```text
  Error response from daemon: conflicting options: port publishing and the container type network mode
  ```

  `forwardPorts` in `devcontainer.json` is the mechanism instead, and unlike a published port it
  works in a cloud workspace.
- **Two stacks run at once.** 1.2.2 hardcoded `container_name: SQL-Library` and the second stack
  died on a name conflict. No template carries `container_name` now. A second copy of the same
  template started while the first was up, with the same `hostname:` value, because a hostname is
  scoped to its own network and a container name is not.

## The create-time contract

One line in `devcontainer.json` does the schema deployment, and in 2.0.0 it takes no argument:

```json
"postCreateCommand": "bash .devcontainer/sql/postCreateCommand.sh"
```

The script waits for a login, builds `database/Library`, then publishes
`database/Library/bin/Debug/Library.dacpac` with SqlPackage. Five things follow:

1. **The build is no longer inside the deployment gate.** 1.2.2 looked for a dacpac first and
   built only if it found one, so a clean checkout deployed nothing and said nothing. 2.0.0 builds
   every time, which is why no dacpac and no `bin` or `obj` directory is committed any more.
2. **A failed build never publishes.** Measured: with one line of invalid T-SQL added to
   `database/Library/Tables/books.sql`, the script printed `Build error SQL46010` and
   `postCreateCommand.sh failed during: build database/Library (exit 1)`, exited 1, and the
   `Library` database was not created. An empty database is now an error you can see.
3. **The build is the compatibility check, so read a build failure as a finding.** An error
   such as `SQL70015` is the target platform refusing a construct Azure SQL Database does not
   have, not a broken toolchain.
4. **The database name comes from the dacpac file name.** `Library.dacpac` gives a database named
   `Library`, so renaming the `.sqlproj` renames the database and `devcontainer.json` never says
   so.
5. **It runs at create, not at every start.** `postStartCommand` is the every-start hook. After a
   schema change, republish rather than restarting and expecting a redeploy:

```bash
bash .devcontainer/sql/postCreateCommand.sh
```

## Where the credential lives, and how it reaches the saved profile

`MSSQL_SA_PASSWORD` is set in `.devcontainer/.env`, and in 2.0.0 `env_file` is on **both**
services, so the variable exists in the application container you develop in as well as in the database. The
create-time script reads it from the environment rather than parsing the file, so a password
containing a space or a quote no longer loses everything after the first space.

The saved `LocalDev` connection profile is contributed by `devcontainer.json`, and the placeholder
it uses is the whole story. Measured with the dev container CLI 0.89.0 against a running container,
with a different value exported on the host to tell the two sources apart:

| In the profile | Resolves to |
|---|---|
| `${containerEnv:MSSQL_SA_PASSWORD}` | the value inside the container, which is what `.env` set |
| `${env:MSSQL_SA_PASSWORD}` | the host's environment, empty in the ordinary case |
| `${localEnv:MSSQL_SA_PASSWORD}` | the host's environment, the same empty value |

2.0.0 uses `${containerEnv:MSSQL_SA_PASSWORD}`. Versions from 1.2.2 used `${env:...}`, which left
the saved profile with an empty password, and an empty password is not an error: the editor simply
prompts, so it reads as a forgotten credential rather than a broken template. The extension itself
expands nothing at all, so the substitution has to happen in the dev container tooling, which is
why only the `containerEnv` form works. If you edit that profile, keep the form.

Keep the sample password free of whitespace and quoting, and never reuse it outside the workspace;
it is committed in plaintext in a public repository.

## On Apple silicon, one container is emulated

The database image is x64 only, and the compose file says so with `platform: linux/amd64`.
Measured on an Apple silicon host: the application container reports `aarch64` and runs natively,
the database container reports `x86_64` and runs under emulation. Microsoft does not test or
support the engine under emulation, and the project's own release notes record it aborting during
startup roughly 1 start in 37 under emulation, and once on a native x64 runner. Three starts in
this session were clean. The symptom is a container that exits or a stack that never reaches
healthy; recreating it clears it, and nothing is preserved that a second attempt would inherit.

The database service is also capped at 2 GB, the documented minimum. Raise it in
`docker-compose.yml` before blaming a query for being slow.

## On a restricted network, creation fails while installing tools

Not measured here, and stated as a pointer rather than as a result: behind a proxy that blocks
`api.nuget.org`, the npm registry or PyPI, the image builds and creation then fails inside
`onCreateCommand` or `postCreateCommand`, with a bare TLS or service-index error that names the
registry and nothing else. Each template's `NOTES.md` carries a "Troubleshooting: restricted
networks" section listing the hosts each toolchain needs.

## Check it worked

Four checks, each a command rather than an impression:

```bash
# 1. the engine is the one you think, and is accepting logins at all
sqlcmd -S localhost,1433 -U sa -P "$MSSQL_SA_PASSWORD" -C -I -b \
  -Q "SELECT SERVERPROPERTY('EngineEdition') AS engine_edition"

# 2. the build produced exactly one dacpac for the publish step to use
ls -1 database/Library/bin/Debug/*.dacpac | wc -l

# 3. a database named after that dacpac exists
sqlcmd -S localhost,1433 -U sa -P "$MSSQL_SA_PASSWORD" -C -I -b \
  -Q "SELECT name FROM sys.databases WHERE database_id > 4"

# 4. the schema landed, not just the database
sqlcmd -S localhost,1433 -U sa -P "$MSSQL_SA_PASSWORD" -C -I -b -d Library \
  -Q "SELECT COUNT(*) AS user_tables FROM sys.tables"
```

Expect `3` from the first, `1` from the second, `Library` from the third and `3` from the fourth.
A database present with zero user tables means the publish half ran and the build half did not,
which in 2.0.0 also means the create step exited non-zero and said so.

One caveat on reading those answers. The `sqlcmd` on the application container's PATH is the Go
build, measured at 1.10.0, and it prints a severity 10 message with no `Msg` number whatever `-m`
is set to. The ODBC build inside the database image, measured at 18.6.0002.1 and reachable as
`/opt/mssql-tools18/bin/sqlcmd` there, prints `Msg 50000, Level 0` for the same message. When a
warning matters, run it through the database container.

## References

- `.devcontainer/docker-compose.yml`: read it first, every time; the image, the shared namespace,
  the health check and the memory cap are decided there.
- `.devcontainer/sql/postCreateCommand.sh`: open it when the create step reported success and the
  database is empty, or when you want the exact publish command to rerun by hand.
- `src/<template>/NOTES.md` in the template repository: open it for the restricted-network host
  list and the per-template tasks, because the applied workspace does not contain this file.
- [SERVERPROPERTY](https://learn.microsoft.com/sql/t-sql/functions/serverproperty-transact-sql)
  when the EngineEdition numbers are disputed.
- [The dev container specification](https://containers.dev/implementors/json_reference/) for
  `waitFor` and for the variable forms a profile may use, and
  [Compose startup order](https://docs.docker.com/compose/how-tos/startup-order/) for `depends_on`
  conditions, before changing when the schema deployment runs.
