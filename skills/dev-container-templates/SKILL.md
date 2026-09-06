---
name: dev-container-templates
description: >-
  Sets up a local development environment from the Azure SQL Dev Container templates in
  microsoft/azuresql-devcontainers, which cover .NET, .NET Aspire, Node.js and Python and ship a
  sample database and schema. Use when a user asks to "start from the Azure SQL dev container
  template", "which Azure SQL devcontainer should I pick", "add a dev container with a database
  already in it", or reports that "the dev container came up but the database is empty", "the
  dacpac never deployed", or "the second dev container says SQL-Library is already in use". Covers
  choosing a template, the postCreateCommand contract that builds and publishes the SQL project,
  the wait these templates leave out so postCreateCommand can run before the database accepts a
  login, the two containers that share one network namespace, and the engine identity check that
  says whether the local database is the Azure SQL Database engine. Reach for this before assuming
  a template named for Azure SQL runs the Azure SQL Database engine.
---

# Start from an Azure SQL Dev Container template

`microsoft/azuresql-devcontainers` ships four Dev Container templates. Each starts two containers,
one for the application toolchain and one for a database, with a sample `Library` schema deployed
into it. The published walkthrough is a screenshot tour; what breaks is in the files. Not covered: a database added to an existing compose stack (`azuresql-db-sidecar`),
scaffolding without a template (`azuresql-db-scaffold`), the engine alone
(`azuresql-db-container`), a cloud database (`provision-azure-sql-db`).

Template files read at commit `9a03f64`, pushed 2024-07-22, on 2026-08-27. Commands below
re-run 2026-09-03 against Docker 29.4.0, Compose v5.1.2, .NET SDK 8.0.421, azd 1.32.0 and bash
3.2.57 and 5.3.15.

## First: find out which engine is actually running

The templates are named for Azure SQL Database. The database service in all four compose files is
`image: mcr.microsoft.com/azure-sql-edge`, a different engine. Never infer the engine from the
template name. Read the image, then ask the server:

```bash
docker compose -f .devcontainer/docker-compose.yml config | grep -E '^[[:space:]]+image:'

sqlcmd -S localhost,1433 -U sa -P "$MSSQL_SA_PASSWORD" -C -I -b \
  -Q "SELECT SERVERPROPERTY('EngineEdition'), SERVERPROPERTY('Edition')"
```

| EngineEdition | Edition | What that means |
|---|---|---|
| `5` | `SQL Azure` | the Azure SQL Database engine, cloud edition semantics |
| `9` | `Azure SQL Edge Developer (64-bit)` | what the templates start today |

Both numbers come from the SERVERPROPERTY reference below. Against the shipped image the query
returns `9`, `Azure SQL Edge Developer (64-bit)`, version `15.0.2000.1574`. Azure SQL Edge is
retired, lifecycle date 1 October 2025, `latest` built February 2023. Azure SQL Database syntax
fails on it:

```text
CREATE TABLE #v (id int, e VECTOR(3));
Msg 2715, Level 16, State 6, Column, parameter, or variable #2: Cannot find data type VECTOR.
```

The redeeming half is the SQL project: `database/Library/Library.sqlproj` targets the Azure SQL
Database schema provider, so a schema that builds is validated against Azure SQL Database even
though the running engine is not it. Trust the build for schema compatibility and nothing for
runtime behavior, error numbers or features. Expect the image to change, so keep reading it from the
compose file; when `EngineEdition` returns `5` this section stops applying.

## Up is not ready, and nothing in the template closes the gap

Docker's startup-order guidance says Compose does not wait until a container is ready, only until
it is running. Read what the compose file actually asks for:

```bash
docker compose -f .devcontainer/docker-compose.yml config | grep -A3 'depends_on:'
```

`network_mode: service:db` makes Compose synthesise `depends_on: db: condition: service_started`.
Measured 2026-09-03. That releases the app container the moment the database process exists, not
when the engine accepts a login. The gap is reachable: give the engine an SA password it refuses and
the container stays `Up` indefinitely while the engine never finishes starting, so `docker ps`
proves nothing. Only a login proves readiness:

```bash
until /opt/mssql-tools18/bin/sqlcmd -S localhost,1433 -U sa -P "$MSSQL_SA_PASSWORD" \
  -C -I -b -l 2 -Q "SELECT 1" >/dev/null 2>&1; do sleep 2; done
```

`-l 2` bounds the login wait, without which a poll against a half-started engine can hang instead of
being refused. `-C` trusts the self-signed certificate. `-I` sets `QUOTED_IDENTIFIER` ON, which the
image's `sqlcmd` at that path leaves OFF while every shipping driver defaults it ON.

Better, put the wait in the files. A health check plus an explicit `depends_on` replaces the
synthesised `service_started` and survives alongside `network_mode`, confirmed with `docker compose
config` on 2026-09-03:

```yaml
services:
  app:
    depends_on:
      db:
        condition: service_healthy
  db:
    healthcheck:
      test: ["CMD-SHELL", "/opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P \"$$MSSQL_SA_PASSWORD\" -C -b -l 2 -Q 'SELECT 1'"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 60s
```

`$$` is Compose's escape for a literal `$`, so the container's shell expands the password.

Then set `"waitFor": "postCreateCommand"` in `devcontainer.json`. The Dev Container specification
defaults `waitFor` to `updateContentCommand` and otherwise runs `postCreateCommand` in the
background, so the editor attaches while the deployment is still going. That is one way "the dev
container came up but the database is empty" gets reported and then will not reproduce.

## The four templates

All four are version 1.2.2 and share one database service, one sample database and one
`postCreateCommand`. They differ in the toolchain image and what is layered on top.

| Template id | Default variant | Ports forwarded | Layered on top |
|---|---|---|---|
| `dotnet` | 8.0-bookworm | 5000, 5001, 8000, 1433 | Azure CLI with Bicep, azd, Docker CLI |
| `dotnet-aspire` | 8.0-bookworm | 5000, 5001, 8000, 1433 | the same, plus the Aspire workload |
| `javascript-node` | 22-bullseye | 3000, 1433 | .NET SDK 8 for the SQL project, global `mssql` |
| `python` | 3.12-bullseye | 5000, 1433 | .NET SDK 8, `msodbcsql17`, `pyodbc` |

Check the toolchain arrived rather than assume the layer ran:

```bash
dotnet --list-sdks   # expect an 8.0.x line: every template needs it for the SQL project
azd version          # dotnet and dotnet-aspire only
```

The .NET SDK in the Node.js and Python templates is the price of the SQL database project;
removing it removes the schema deployment. Two package feeds are pinned to the wrong distribution,
so look there first when a build fails: `installSQLtools.sh` adds the Ubuntu 20.04 feed on
top of Debian base images in all four, and `install-dotnet.sh` fetches Debian 12 while the Node.js
and Python default variant is `bullseye`, Debian 11. Both still resolved on 2026-08-27.

## Two containers, one network namespace

The app service carries `network_mode: service:db`, so it joins the database container's network
stack rather than getting its own. Each consequence was checked:

- **`localhost,1433` reaches the database from inside the app container**, while `db` and the
  hostname `SQL-Library` keep resolving. `localhost` starts working; nothing stops.
- **The app container's hostname is `SQL-Library`**, so anything deriving identity from the
  hostname sees the database container's name.
- **The database service declares no volume**, so removing the container discards the database, and
  the schema returns only because the create step reruns.
- **A `ports:` block on the app service is refused, and validating the file will not tell you.**
  Measured 2026-09-03: `docker compose config` accepts a service carrying both `network_mode:
  service:db` and `ports:`, exit 0. The daemon refuses it at create time:

  ```text
  Error response from daemon: conflicting options: port publishing and the container type network mode
  ```

  `forwardPorts` in `devcontainer.json` is the mechanism instead, and unlike a published port it
  works in a cloud workspace.
- **`container_name: SQL-Library` is hardcoded, so two stacks cannot run at once:**

  ```text
  Error response from daemon: Conflict. The container name "/SQL-Library" is already in use
  ```

  Two at once means editing `container_name` and `hostname` in one first.

## The postCreateCommand contract

One line in `devcontainer.json` does the schema deployment, and it takes one argument, a directory:

```json
"postCreateCommand": "bash .devcontainer/sql/postCreateCommand.sh 'database/Library/bin/Debug'"
```

Four things about that argument are load-bearing and none are documented:

1. **The project directory is its first two path segments**, so `database/Library` is built. Output
   that is not exactly two segments deep builds the wrong directory, or nothing.
2. **The database name comes from the dacpac file name.** `Library.dacpac` gives a database named
   `Library`, so renaming the `.sqlproj` renames the database and `devcontainer.json` never says so.
3. **The build is inside the deployment gate, not before it.** The script scans for a dacpac first
   and only then runs `dotnet build`, so with no dacpac on disk the project is never built. Hence
   `Library.dacpac` being committed, and a `.gitignore` excluding `bin/` making the step a no-op.
4. **Detection is an unquoted glob inside `[ -f ]`, so it fails silently.** Reproduce the shipped
   shape with no container at all, varying how many files you create:

   ```bash
   d=$(mktemp -d); touch "$d/Library.dacpac" "$d/Old.dacpac"
   bash -c "if [ -f $d/*.dacpac ]; then echo 'would build and publish'; fi"; echo "exit=$?"
   ```

   Measured 2026-09-03, identical on bash 3.2.57 and 5.3.15:

   | In the directory | What happens | Exit |
   |---|---|---|
   | exactly one `.dacpac` | builds the project, then publishes | 0 |
   | none, or no such directory | nothing at all, no message | 0 |
   | exactly two | `[: <first file>: binary operator expected`, then nothing | 0 |
   | three or more | `[: too many arguments`, then nothing | 0 |

   A second dacpac, from another project or a renamed leftover, disables deployment for both, and
   the create step still reports success, so the only symptom is an empty database.

`postCreateCommand` runs at create, not on every start; `postStartCommand` is the every-start hook.
After a schema change, build and republish rather than restarting and expecting a redeploy:

```bash
dotnet build database/Library/Library.sqlproj -c Debug
bash .devcontainer/sql/postCreateCommand.sh 'database/Library/bin/Debug'
```

## Where the credential lives, and why the preseeded profile cannot use it

`MSSQL_SA_PASSWORD` is set in `.devcontainer/.env` and `env_file` appears **only on the database
service**, so the variable does not exist in the container you develop in, and the preseeded
`LocalDev` profile references it anyway. The deployment script reads the file directly instead, a
`grep` piped into `xargs`, and that loader mangles two ordinary password shapes while the database
container, reading the same file through `env_file`, gets the value intact:

| Value in the file | What the script ends up using |
|---|---|
| no spaces or quotes | the value, correctly |
| contains a space | everything up to the first space, plus a non-fatal `export` error |
| contains quote characters | the value with the quotes stripped out |

Both look identical: the readiness loop exhausts its thirty attempts, then the publish fails on
login. Keep the sample password free of whitespace and quoting, and never reuse it outside
the workspace; it is committed in plaintext in a public repository. For the user an application
connects as, see `azuresql-db-auth`.

## Check it worked

Four checks, each a command rather than an impression:

```bash
# 1. the engine is the one you think, and is accepting logins at all
sqlcmd -S localhost,1433 -U sa -P "$MSSQL_SA_PASSWORD" -C -I -b -m-1 \
  -Q "SELECT SERVERPROPERTY('EngineEdition') AS engine_edition"

# 2. exactly one dacpac in the directory postCreateCommand was handed
ls -1 database/Library/bin/Debug/*.dacpac | wc -l

# 3. a database named after that dacpac exists
sqlcmd -S localhost,1433 -U sa -P "$MSSQL_SA_PASSWORD" -C -I -b \
  -Q "SELECT name FROM sys.databases WHERE database_id > 4"

# 4. the schema landed, not just the database
sqlcmd -S localhost,1433 -U sa -P "$MSSQL_SA_PASSWORD" -C -I -b -d Library \
  -Q "SELECT COUNT(*) AS user_tables FROM sys.tables"
```

Expect `9` from the first until the image changes, `1` from the second, `Library` from the third and
a non-zero count from the fourth. A database present with zero user tables means the publish half
ran and the build half did not. `-m-1` makes severity 10 messages print their `Msg` number: without
it a warning prints unnumbered, and `-b` will not fail on it either, since `-b` only sets a non-zero
exit at severity 11 and above.

**`-m-1` is an ODBC `sqlcmd` instruction**, meaning the 18.x build from `mssql-tools18` or the
Microsoft command line utilities. Measured 2026-09-05, go-sqlcmd 1.10.0, the 1.x build
`brew install sqlcmd` and `winget install sqlcmd` install, prints no `Msg` header on a severity 10
message at any `-m` value, so on that build these four checks print a warning with no number
whatever `-m` says. The ODBC build is inside the container image at
`/opt/mssql-tools18/bin/sqlcmd`, which is the path the health check above already uses, so run
these through `docker exec` when the laptop's `sqlcmd` reports 1.x.
`build-app-on-azure-sql` tells the two builds apart in one table.

## References

- `src/<template>/.devcontainer/docker-compose.yml`: read it first, every time; the image, the
  shared namespace and the container name are decided there.
- `src/<template>/.devcontainer/sql/postCreateCommand.sh`: open it when the create step reported
  success and the database is empty.
- `src/<template>/devcontainer-template.json`: open it when choosing an image variant.
- [SERVERPROPERTY](https://learn.microsoft.com/sql/t-sql/functions/serverproperty-transact-sql) and
  the [Azure SQL Edge lifecycle entry](https://learn.microsoft.com/lifecycle/products/azure-sql-edge)
  when the EngineEdition numbers or the retirement date are disputed.
- [The Dev Container specification](https://containers.dev/implementors/json_reference/) for
  `waitFor`, and [Compose startup order](https://docs.docker.com/compose/how-tos/startup-order/) for
  `depends_on` conditions, before changing when the schema deployment runs.
