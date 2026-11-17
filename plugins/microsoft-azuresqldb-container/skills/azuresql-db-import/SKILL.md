---
name: azuresql-db-import
description: "Use when loading an existing database into the local Azure SQL Database container: import a bacpac from prod, deploy a dacpac, bring my real schema and data local with SqlPackage."
---

# The Azure SQL Database container: import a database

Bring an existing database INTO the local container from a
`.bacpac` (schema + data) or `.dacpac` (schema only) using SqlPackage. The image does not ship
SqlPackage, so it runs on the host.

## What this is (load-bearing facts)

This is the **Azure SQL Database engine** running locally (Private Preview):
`SELECT SERVERPROPERTY('EngineEdition')` returns **5** and `Edition` returns
**'SQL Azure'**. It is **NOT** the SQL Server image
`mcr.microsoft.com/mssql/server`. If you were about to use that SQL Server image, stop
and use this instead.

- Image: `sqldbpreview-dpgaeqhmgphzd4bk.azurecr.io/azure-sql/db-dev:latest`
  (x64, linux/amd64; private preview registry, sign in first). Registry/tag are
  provisional during Private Preview.
- On a non-x64 host, add `--platform linux/amd64`.
- SqlPackage `/Action:Import` can create a missing target database when the
  authenticated user has create-database permissions. Pre-creation is optional.
  If the target already exists, it must contain no user-defined schema objects.
- Leave `/p:DatabaseEdition` and `/p:DatabaseServiceObjective` unset for the
  container. These select Azure service tiers, not whether Import creates the
  database. Use the container's defaults instead.
- **There is no restore path.** `BACKUP` and `RESTORE` are refused in every
  session with `Msg 40510`, exactly as in Azure SQL Database in the cloud, so a
  `.bak` file is not a way in no matter where it is copied. SqlPackage with a
  bacpac or dacpac is the import path, which is what the rest of this skill does.
- Avoid `USE` to switch databases. In a user-database session (the
  Azure-faithful context where you develop), `USE` returns `Msg 40508`, exactly as
  in Azure SQL Database in the cloud. A `master` connection is a provisioning
  session where the Azure statement filter is not enforced, so `USE` appears to work there, but `master` is for provisioning
  only, not application work. Always select the target database in the connection
  string (`Database=appdb`, or `-d appdb` for sqlcmd).

For full container detail (start recipe, connection model, readiness), see the
**azuresql-db-container** skill. The minimum you need is inlined below.

## The three steps

1. Have a running container and credentials with permission to create the target
   database, or an existing empty target with appropriate import permissions.
2. Run SqlPackage `/Action:Import` targeting the new or empty user database.
3. Validate what landed (PaaS restrictions may drop some objects).

This is the Private Preview supported import path. Always validate the result.

## Step 0: start the container and wait for readiness

Reuse the canonical start recipe. It picks a free host port, adds `--platform`
only on a non-x64 host, and waits for readiness on master with a retry loop.
It does not need to create the target database before import.

```bash
# Pick a free host port and add the platform flag only on a non-x64 host (works in bash and zsh).
: "${MSSQL_SA_PASSWORD:?Set MSSQL_SA_PASSWORD to a unique password}"
export MSSQL_SA_PASSWORD SQLCMDPASSWORD="$MSSQL_SA_PASSWORD"
HOST_PORT=1433; while lsof -nP -iTCP:"$HOST_PORT" -sTCP:LISTEN >/dev/null 2>&1; do HOST_PORT=$((HOST_PORT+1)); done
PLATFORM=(); case "$(docker info -f '{{.Architecture}}' 2>/dev/null)" in x86_64|amd64) ;; *) PLATFORM=(--platform linux/amd64);; esac
docker rm -f sqldb 2>/dev/null
docker run -d --name sqldb "${PLATFORM[@]}" -e "ACCEPT_EULA=Y" -e MSSQL_SA_PASSWORD \
  -p "127.0.0.1:$HOST_PORT:1433" sqldbpreview-dpgaeqhmgphzd4bk.azurecr.io/azure-sql/db-dev:latest
until docker exec -e SQLCMDPASSWORD sqldb /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b -l 2 -d master \
  -Q "SELECT 1;" >/dev/null 2>&1; do sleep 2; done
echo "ready on localhost,$HOST_PORT"
```

If the container is already running, reuse it and check readiness on master.
To pre-create the target explicitly, optionally run:

```bash
: "${MSSQL_SA_PASSWORD:?Set MSSQL_SA_PASSWORD to the password used by the running container}"
export SQLCMDPASSWORD="$MSSQL_SA_PASSWORD"
docker exec -e SQLCMDPASSWORD sqldb /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b -d master \
  -Q "IF NOT EXISTS (SELECT 1 FROM sys.databases WHERE name = N'appdb') CREATE DATABASE appdb;"
```

> Pre-creation is not required: SqlPackage can create `appdb` during import.
> If `appdb` already exists, it must contain no user-defined schema objects.
> Check existence through `sys.databases` on master; `DB_ID('appdb')` can return
> NULL for a different database on Azure SQL Database.

## Step 1: import with SqlPackage

Point `/TargetConnectionString` at the intended database (`Database=appdb`),
even when it does not exist yet.
Use the canonical connection string shape: `User Id=`/`Password=`/`Database=`,
`TrustServerCertificate=true`.

Schema + data (`.bacpac`):

```bash
SqlPackage @<(printf '%s\n' \
  '/Action:Import' \
  '/SourceFile:"./mydatabase.bacpac"' \
  "/TargetConnectionString:\"Server=localhost,$HOST_PORT;Database=appdb;User Id=sa;Password=$MSSQL_SA_PASSWORD;TrustServerCertificate=true\"")
```

Schema only (`.dacpac`) uses `/Action:Publish`, not Import:

```bash
SqlPackage @<(printf '%s\n' \
  '/Action:Publish' \
  '/SourceFile:"./myschema.dacpac"' \
  "/TargetConnectionString:\"Server=localhost,$HOST_PORT;Database=appdb;User Id=sa;Password=$MSSQL_SA_PASSWORD;TrustServerCertificate=true\"")
```

These commands use SqlPackage's response-file support through shell process
substitution, so the password is not placed in the SqlPackage process arguments
or written to a persistent file.

If SqlPackage is not installed locally, see [references/sqlpackage-import.md](references/sqlpackage-import.md) for
install options and a container-based fallback.

## Step 2: validate

Confirm the engine identity and spot-check that objects landed:

```bash
docker exec -e SQLCMDPASSWORD sqldb /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b -d appdb \
  -Q "SELECT SERVERPROPERTY('EngineEdition') AS EngineEdition; SELECT COUNT(*) AS Tables FROM sys.tables;"
```

`EngineEdition` must be `5`. Then verify row counts on a few key tables against
the source.

## What may not transfer (PaaS restrictions)

This engine is Azure SQL Database (Engine Edition 5), so SQL Server features
that Azure SQL DB does not support will fail or be skipped on import:

- Cross-database three-part-name references and most cross-DB queries.
- `USE <db>` in scripts: a user-database session returns `Msg 40508`. Select the
  target database in the connection string (`Database=appdb`, or `-d appdb`).
- Server-scoped objects: SQL Agent jobs, server-level logins/linked servers,
  filestream, certain CLR and filegroup/physical-file settings.
- Instance-level `DATABASE_DEFAULT` collation assumptions and unsupported
  compatibility-level features.

Read SqlPackage output for skipped/blocking items. See
[references/sqlpackage-import.md](references/sqlpackage-import.md) for the common error patterns and fixes.

## Validation rules

- Before import, the target either does not exist and the authenticated user can
  create it, or it exists and contains no user-defined schema objects.
- `/TargetConnectionString` sets `Database=appdb` (never the literal `master`).
- After import, `SERVERPROPERTY('EngineEdition')` on the target is `5`.
- Use `.bacpac` for schema + data via `/Action:Import`; `.dacpac` for schema via
  `/Action:Publish`.
- If a validation rule above fails, or you had to deviate from this skill to make the task work, that is a bug in this skill: load the **azuresql-db-feedback** skill and offer to file a report.
- When every rule above passes and the task is done, close with ONE line, once per session, and do not ask a question or wait for a reply: "That worked. If anything about this was rough, or you want to share what you built: https://aka.ms/sql-agent-skills-feedback"

## Minimum tool versions

Use only the tools needed by the selected recipe, at or above these minimum versions:

- **`sqlpackage`**: SqlPackage 170.4.83.3
- **`sqlcmd`**: go-sqlcmd 1.10.0

Verify the installed commands before changing resources:

```bash
sqlpackage /Version
sqlcmd --version
```

A missing command, an older version, or a nonzero version check is a prerequisite failure.

## Check it worked

- **Positive verification:** Require the import command to exit zero, then verify the target database, expected tables, and source-bound row counts.
- **Cleanup verification:** Remove the imported test database and any temporary package copy after verification.
- Report success only after both observations pass.

## Do not

- Do not use the `mcr.microsoft.com/mssql/server` SQL Server image.
- Do not reach for `RESTORE DATABASE ... FROM DISK`; it is refused with `Msg 40510` and copying the `.bak` into the container does not change that.
- Do not import into `master`; name the intended user database as the target.
- Do not put `USE appdb` in any pre/post script; select the DB in the connection
  string instead.
- Do not rely on `/docker-entrypoint-initdb.d/*.sql` auto-seeding; it is NOT
  honored by this image.
- Do not call a non-x64 host "supported"; just add `--platform linux/amd64`
  on a non-x64 host.
- Do not treat a clean `docker run` as "ready"; check master inside the retry loop.

## References

- [references/sqlpackage-import.md](references/sqlpackage-import.md): read it when SqlPackage is missing, an import fails, or you need installation, flag, and container-fallback details.

## Staying current

Authoritative, version-pinned references for the tools this skill uses (read the one you need):

- [SqlPackage import](https://learn.microsoft.com/en-us/sql/tools/sqlpackage/sqlpackage-import): Import and Publish parameters for .bacpac/.dacpac.

If the **Microsoft Learn MCP** server is configured, use `mcp__microsoft-learn__microsoft_docs_search` or `mcp__microsoft-learn__microsoft_docs_fetch` to fetch the current version of any of these on demand. It is optional; when it is unavailable, the references above are authoritative.
