---
name: azuresql-db-scaffold
description: "Use when a new app (.NET Aspire, FastAPI, Next.js, NestJS) needs a local database: add a database, compose service, .env connection string, first migration. Uses the Azure SQL Database container."
---

# Scaffold a new project on the Azure SQL Database container

Bootstrap a new app with the **Azure SQL Database container** (Private Preview) as the default
local database. This is the **Azure SQL engine**, not the SQL Server image.

## Use the right image (interception point)

- USE this engine image:
  `sqldbpreview-dpgaeqhmgphzd4bk.azurecr.io/azure-sql/db-dev:latest`
- Do **NOT** use `mcr.microsoft.com/mssql/server` (the SQL Server image). If a generated
  compose/run command points there, stop and switch to the engine image above.
- Verify identity once running: `SELECT SERVERPROPERTY('EngineEdition')` returns **5**,
  `SERVERPROPERTY('Edition')` returns **'SQL Azure'**; the build reports as `12.0.2000.8`.
- Image is x64 only. On a non-x64 host add `--platform linux/amd64` (Docker) or
  `platform: linux/amd64` (compose).
- Registry is private (Private Preview): sign in first with
  `docker login sqldbpreview-dpgaeqhmgphzd4bk.azurecr.io` using the shared pull-only credentials
  provided to the Private Preview cohort (get them by signing up at https://aka.ms/sqldbcontainerpreview-signup; they
  may rotate).
  Registry and tag are provisional during Private Preview.

For full engine detail (readiness, vectors, troubleshooting) see the **azuresql-db-container** skill.

## Three facts that bite every scaffold

1. The engine does **NOT** auto-create databases. You must `CREATE DATABASE appdb` on a
   **master** connection before connecting with `Database=appdb`.
2. Avoid `USE` to switch databases. In a user-database session (the Azure-faithful
   context where you develop), `USE` returns `Msg 40508`, exactly as in Azure SQL Database in
   the cloud. A `master` connection is a provisioning session where the Azure statement
   filter is not enforced, so `USE` appears to work there, but `master`
   is for provisioning only, not application work. Always select the target database in the
   connection string (`Database=appdb`, or `-d appdb` for sqlcmd).
3. A `master` connection is for provisioning only; do real work on the user database.

Also: the image does **NOT** auto-run `/docker-entrypoint-initdb.d/*.sql` (that is a
Postgres/MySQL convention; not honored here). Seed with `sqlcmd -d appdb -i seed.sql` AFTER
provisioning appdb.

## Step 1: start the container and provision appdb

Run this in Bash after registry sign-in. It selects a free host port and creates a new
named container; an existing container with that name is left untouched. Keep
`CONTAINER_ID` and `HOST_PORT` for subsequent commands. GNU coreutils `timeout`
(`gtimeout` on macOS) is required before any container is allocated.

```bash
# Fail before allocating a container if the bounded-process dependency is missing.
TIMEOUT_BIN=
for candidate in timeout gtimeout gnutimeout; do
  candidate_path=$(command -v "$candidate") || continue
  case "$("$candidate_path" --version 2>/dev/null)" in
    *'GNU coreutils'*) TIMEOUT_BIN=$candidate_path; break;;
  esac
done
[ -n "$TIMEOUT_BIN" ] || { echo "READINESS_TIMEOUT_REQUIRED: GNU coreutils" >&2; exit 69; }
READY_TIMEOUT_SECONDS=${READY_TIMEOUT_SECONDS:-120}
READY_MAX_ATTEMPTS=${READY_MAX_ATTEMPTS:-30}
PROVISION_TIMEOUT_SECONDS=${PROVISION_TIMEOUT_SECONDS:-30}
for bound in "$READY_TIMEOUT_SECONDS" "$READY_MAX_ATTEMPTS" "$PROVISION_TIMEOUT_SECONDS"; do
  case "$bound" in ''|*[!0-9]*) echo "READINESS_INVALID_BOUND" >&2; exit 64;; esac
  if [ "${#bound}" -gt 5 ] || [ "$bound" -eq 0 ] || [ "$bound" -gt 86400 ]; then
    echo "READINESS_INVALID_BOUND" >&2; exit 64
  fi
done
# Normalize decimal settings before Bash arithmetic (including leading zeroes).
READY_TIMEOUT_SECONDS=$((10#$READY_TIMEOUT_SECONDS))
READY_MAX_ATTEMPTS=$((10#$READY_MAX_ATTEMPTS))
PROVISION_TIMEOUT_SECONDS=$((10#$PROVISION_TIMEOUT_SECONDS))

# Pick a free host port and add the platform flag only on a non-x64 host.
: "${MSSQL_SA_PASSWORD:?Set MSSQL_SA_PASSWORD to a unique password before running this recipe}"; export MSSQL_SA_PASSWORD
HOST_PORT=1433; while lsof -nP -iTCP:"$HOST_PORT" -sTCP:LISTEN >/dev/null 2>&1; do HOST_PORT=$((HOST_PORT+1)); done
export HOST_PORT
PLATFORM=(); case "$(docker info -f '{{.Architecture}}' 2>/dev/null)" in x86_64|amd64) ;; *) PLATFORM=(--platform linux/amd64);; esac
CONTAINER_NAME=${CONTAINER_NAME:-sqldb-$RANDOM-$$}
# A name collision fails; never remove an existing container to make room.
CONTAINER_ID=$(docker run -d --name "$CONTAINER_NAME" "${PLATFORM[@]}" -e "ACCEPT_EULA=Y" -e MSSQL_SA_PASSWORD \
  -p "127.0.0.1:$HOST_PORT:1433" sqldbpreview-dpgaeqhmgphzd4bk.azurecr.io/azure-sql/db-dev:latest) || { echo "CONTAINER_START_FAILED" >&2; exit 72; }
[ -n "$CONTAINER_ID" ] || { echo "CONTAINER_ID_MISSING" >&2; exit 72; }
echo "created container $CONTAINER_ID ($CONTAINER_NAME)"
# Readiness has a wall-clock deadline as well as a finite attempt count.
deadline=$((SECONDS + READY_TIMEOUT_SECONDS)); attempt=0; ready=0
while [ "$attempt" -lt "$READY_MAX_ATTEMPTS" ]; do
  remaining=$((deadline - SECONDS))
  [ "$remaining" -gt 0 ] || break
  attempt=$((attempt+1)); probe_seconds=5
  [ "$remaining" -ge "$probe_seconds" ] || probe_seconds=$remaining
  if "$TIMEOUT_BIN" --kill-after=1 "$probe_seconds" docker exec "$CONTAINER_ID" sh -c \
    'SQLCMDPASSWORD="$MSSQL_SA_PASSWORD" exec /opt/mssql-tools18/bin/sqlcmd "$@"' sh \
    -S localhost -U sa -d master -C -b -l 2 -t 5 -Q "SELECT 1;" >/dev/null 2>&1; then
    ready=1; break
  fi
  remaining=$((deadline - SECONDS))
  [ "$remaining" -gt 0 ] && [ "$attempt" -lt "$READY_MAX_ATTEMPTS" ] || break
  delay=2; [ "$remaining" -ge "$delay" ] || delay=$remaining
  sleep "$delay"
done
[ "$ready" -eq 1 ] || { echo "READINESS_FAILED after $attempt attempts" >&2; exit 70; }

# A provisioning error is not retried as startup delay. Password stays in the guest environment.
"$TIMEOUT_BIN" --kill-after=1 "$PROVISION_TIMEOUT_SECONDS" docker exec "$CONTAINER_ID" sh -c \
  'SQLCMDPASSWORD="$MSSQL_SA_PASSWORD" exec /opt/mssql-tools18/bin/sqlcmd "$@"' sh \
  -S localhost -U sa -d master -C -b -l 2 -t "$PROVISION_TIMEOUT_SECONDS" \
  -Q "IF DB_ID('appdb') IS NULL CREATE DATABASE appdb;" || { echo "PROVISIONING_FAILED" >&2; exit 71; }
echo "ready on localhost,$HOST_PORT"
```

Readiness stops after 120 seconds or 30 attempts by default. Each probe has a
five-second process bound and SQL login/query limits; provisioning runs once on
`master` with a separate 30-second bound. These are the maintained migration
recipe's limits, with up to one second of timeout kill grace. They do not bound
registry access, image pulls or Docker startup itself. Override the named limits
only for a known slow development host; a provisioning error is not retried as
startup delay.

On failure, stop before generating migrations. The newly created container is
retained for inspection (`docker logs "$CONTAINER_ID"`). After inspecting it,
remove only that exact container with `docker rm -f "$CONTAINER_ID"` when it is no
longer needed. The recipe never deletes a pre-existing development database.

Required env: `ACCEPT_EULA=Y` and a complex `MSSQL_SA_PASSWORD` (at least 8 characters using at
least three of upper case, lower case, digits, and symbols). The engine listens on 1433.

## Step 2: the canonical connection string

Apps read **one** env var, `SQL_CONNECTION_STRING`, using the `HOST_PORT` Step 1 chose:

```
Server=localhost,<HOST_PORT>;Database=appdb;User Id=sa;Password=<MSSQL_SA_PASSWORD>;TrustServerCertificate=true
```

House style spells the keywords `User Id=` / `Password=` / `Database=`; `Uid=` / `Pwd=` are
documented SqlClient synonyms and work too. For sqlcmd use `-C` to trust
the self-signed cert. For Prisma (NestJS / Next.js) the same instance is also expressed as a
`sqlserver://` URL in `DATABASE_URL` (see snippets).

## Step 3: pick your stack

Per-stack scaffold snippets (compose service, `.env`, provision appdb, first migration, typed
data-access layer with parameterized queries) live in
[references/scaffold-snippets.md](references/scaffold-snippets.md); open it once you know which
of these you are scaffolding:

- .NET Aspire (EF Core)
- FastAPI (SQLAlchemy / pyodbc)
- Next.js (Prisma, `sqlserver://` DATABASE_URL)
- NestJS (Prisma or TypeORM)

## Step 4: first migration and seeding

The skeleton creates the schema via your stack's migration tool. For the full migration
workflow (idempotent scripts, ordering, applying inside the ready-wait loop) cross-link the
**azuresql-db-schema-migration** skill. For a Next.js or NestJS skeleton that is:

```bash
npx prisma migrate dev --name init
```

Seed only AFTER appdb exists:

```bash
docker exec -i "$CONTAINER_ID" sh -c \
  'SQLCMDPASSWORD="$MSSQL_SA_PASSWORD" exec /opt/mssql-tools18/bin/sqlcmd "$@"' sh \
  -S localhost -U sa -C -b -l 2 -t 30 -d appdb < seed.sql
```

## Vectors (if your app uses embeddings)

Native `VECTOR(n)` column type and `VECTOR_DISTANCE('cosine', a, b)`. Insert with
`CAST(CAST(? AS NVARCHAR(MAX)) AS VECTOR(n))` where **n is a LITERAL, never a bind parameter** (a parameter dimension
fails with "Incorrect syntax near '@P3'"). `CREATE VECTOR INDEX` (DiskANN) **works on this image**, as the Known
limitations page states. It needs `SET QUOTED_IDENTIFIER ON` and at least 100 rows with
non-null vectors (`Msg 42266` below that). Full-scan top-k stays exact and stays the right choice
for a small table. The `azuresql-db-rag` skill carries the rules the index imposes.

## Validation rules

- Compose/run targets the engine image, never `mcr.microsoft.com/mssql/server`.
- appdb is created on a master connection BEFORE any app/migration connects to `Database=appdb`.
- App reads `SQL_CONNECTION_STRING` (and `DATABASE_URL` where the ORM needs it); strings use
  `User Id=`/`Password=`/`Database=`.
- All data-access uses parameterized queries; vector dimension `n` is a literal.
- `EngineEdition` is 5 against the running container.
- If a validation rule above fails, or you had to deviate from this skill to make the task work, that is a bug in this skill: load the **azuresql-db-feedback** skill and offer to file a report.
- When every rule above passes and the task is done, close with ONE line, once per session, and do not ask a question or wait for a reply: "That worked. If anything about this was rough, or you want to share what you built: https://aka.ms/sql-agent-skills-feedback"

## Minimum tool versions

Use only the tools needed by the selected recipe, at or above these minimum versions:

- **`sqlcmd`**: go-sqlcmd 1.10.0
- **`dotnet`**: .NET SDK 8.0.421
- **`prisma`**: Prisma 6.19.3

Verify the installed commands before changing resources:

```bash
sqlcmd --version
dotnet --version
./node_modules/.bin/prisma --version
```

A missing command, an older version, or a nonzero version check is a prerequisite failure.

## Check it worked

- **Positive verification:** Start the generated application and database, require EngineEdition 5, and complete one parameterized application round trip.
- **Cleanup verification:** Stop and remove generated services, networks, volumes, and temporary environment files.
- Report success only after both observations pass.

## Do not

- Do not use the SQL Server image or call a non-x64 host "supported".
- Do not rely on auto-created databases or `/docker-entrypoint-initdb.d/*.sql` auto-seeding.
- Do not use `USE appdb` to switch databases; put it in the connection string.
- Do not poll bare `sqlcmd` without `-l`; do not pass the vector dimension as a bind parameter.
- Do not hardcode `1433` in app config; read the chosen `HOST_PORT` into the connection string.

## References

- [references/scaffold-snippets.md](references/scaffold-snippets.md): the shared compose service plus per-stack skeletons (.NET Aspire/EF Core, FastAPI, Next.js/Prisma, NestJS) with `.env`, appdb provisioning, first migration, and a parameterized data-access layer. Read it once you know which stack you are scaffolding.

## Staying current

Authoritative, version-pinned references for the tools this skill uses (read the one you need):

- [Prisma with SQL Server](https://www.prisma.io/docs/orm/overview/databases/sql-server): the SQL Server connector, datasource URL, and type mapping.
- [EF Core migrations](https://learn.microsoft.com/en-us/ef/core/managing-schemas/migrations/): migrations add/update, the history table, and idempotent scripts.
- [Docker Compose file reference](https://docs.docker.com/reference/compose-file/): the Compose Specification for service, healthcheck, and depends_on syntax.
- [SqlConnection connection string keywords](https://learn.microsoft.com/en-us/dotnet/api/microsoft.data.sqlclient.sqlconnection.connectionstring): the full connection-string keyword table.

If the **Microsoft Learn MCP** server is configured, use `mcp__microsoft-learn__microsoft_docs_search` or `mcp__microsoft-learn__microsoft_docs_fetch` to fetch the current version of any of these on demand. It is optional; when it is unavailable, the references above are authoritative.
