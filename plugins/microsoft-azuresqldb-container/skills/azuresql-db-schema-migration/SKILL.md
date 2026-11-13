---
name: azuresql-db-schema-migration
description: "Use when running migrations against the local Azure SQL Database container: dotnet ef database update, prisma migrate, alembic upgrade head, a dacpac publish, so they match Azure."
---

# Schema migrations on the Azure SQL Database container

Apply schema migrations to the local **Azure SQL Database** container the same way
you would against the cloud, so dev and prod stay identical. This is the Azure SQL
Database engine (`SELECT SERVERPROPERTY('EngineEdition')` returns **5**,
`Edition` returns **'SQL Azure'**), **not** the SQL Server image
`mcr.microsoft.com/mssql/server`. If a tool or template points at the SQL Server image,
stop and use the image below instead.

## Scope

- Applying EF Core, Prisma, Alembic or SqlPackage migrations to the local container, so the same
  migrations apply identically in Azure.
- Building a SQL database project, or a dacpac publish that fails, is `sql-database-projects`.

## The one rule that breaks every migration tool

The engine does **NOT** auto-create databases on connect. Every migration tool
assumes the target database already exists. So:

1. Provision `appdb` on a **master** connection FIRST.
2. Then point the migration tool at the **user** database (`Database=appdb`).

Avoid `USE` to switch databases. In a user-database session (the
Azure-faithful context where you develop), `USE` returns `Msg 40508`, exactly as in
Azure SQL Database in the cloud. A `master` connection is a provisioning
session where the Azure statement filter is not enforced, so `USE` appears to
work there, but `master` is for provisioning only, not
application work. Always select the target database in the connection string
(`Database=appdb`, or `-d appdb` for sqlcmd). A `master` connection is for
provisioning only; run migrations against `appdb`.

## Start the container and provision appdb (canonical recipe)

The engine is not ready the instant `docker run` returns. This **Bash** recipe
waits on a bounded readiness probe, then provisions `appdb` once on `master`.
It requires GNU coreutils `timeout` (`gtimeout` on macOS or `gnutimeout` on
systems whose default uses another implementation); install coreutils before
starting if none is available. Image is x64 only; on a non-x64 host the
recipe adds `--platform linux/amd64` automatically. The registry is private during
Private Preview, so sign in first.

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

docker login sqldbpreview-dpgaeqhmgphzd4bk.azurecr.io   # pull-only creds by signing up at https://aka.ms/sqldbcontainerpreview-signup

# Pick a free host port and add the platform flag only on a non-x64 host.
: "${MSSQL_SA_PASSWORD:?Set MSSQL_SA_PASSWORD to a unique password before running this recipe}"; export MSSQL_SA_PASSWORD
HOST_PORT=1433; while lsof -nP -iTCP:"$HOST_PORT" -sTCP:LISTEN >/dev/null 2>&1; do HOST_PORT=$((HOST_PORT+1)); done
export HOST_PORT
PLATFORM=(); case "$(docker info -f '{{.Architecture}}' 2>/dev/null)" in x86_64|amd64) ;; *) PLATFORM=(--platform linux/amd64);; esac
docker rm -f sqldb 2>/dev/null
docker run -d --name sqldb "${PLATFORM[@]}" -e "ACCEPT_EULA=Y" -e MSSQL_SA_PASSWORD \
  -p "127.0.0.1:$HOST_PORT:1433" sqldbpreview-dpgaeqhmgphzd4bk.azurecr.io/azure-sql/db-dev:latest
# Readiness has a wall-clock deadline as well as a finite attempt count.
deadline=$((SECONDS + READY_TIMEOUT_SECONDS)); attempt=0; ready=0
while [ "$attempt" -lt "$READY_MAX_ATTEMPTS" ]; do
  remaining=$((deadline - SECONDS))
  [ "$remaining" -gt 0 ] || break
  attempt=$((attempt+1)); probe_seconds=5
  [ "$remaining" -ge "$probe_seconds" ] || probe_seconds=$remaining
  if "$TIMEOUT_BIN" --kill-after=1 "$probe_seconds" docker exec sqldb sh -c \
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
"$TIMEOUT_BIN" --kill-after=1 "$PROVISION_TIMEOUT_SECONDS" docker exec sqldb sh -c \
  'SQLCMDPASSWORD="$MSSQL_SA_PASSWORD" exec /opt/mssql-tools18/bin/sqlcmd "$@"' sh \
  -S localhost -U sa -d master -C -b -l 2 -t "$PROVISION_TIMEOUT_SECONDS" \
  -Q "IF DB_ID('appdb') IS NULL CREATE DATABASE appdb;" || { echo "PROVISIONING_FAILED" >&2; exit 71; }
echo "ready on localhost,$HOST_PORT"
```

`-C` trusts the self-signed cert; `-b` makes a SQL error set the exit code.
Readiness retries transient failures but stops after the total deadline or
attempt limit. `-l` bounds login, `-t` bounds queries and GNU timeout bounds a
hung Docker client. The Bash deadline has one-second clock resolution; timeout
cleanup allows up to one additional second of kill grace;
the separate provisioning step has its own bound. These bounds cover readiness
and provisioning, not registry login, image pull or container startup. A failure
exits the recipe before migration tools can run. Docker exec's guest SQL command
retains its own SQL timeouts if the host client disconnects. For full container
lifecycle and owned cleanup detail, see the **azuresql-db-container** skill.

## Connection-string hygiene

Standardize on one form and read it from a single `SQL_CONNECTION_STRING` env var:

```
Server=localhost,1433;Database=appdb;User Id=sa;Password=<sa-password>;TrustServerCertificate=true
```

- Spell the keywords `User Id=` / `Password=` / `Database=` as house style. `Uid=` / `Pwd=` are
  documented SqlClient synonyms and work too.
- `Database=appdb`, never `master`, for migrations and app work.
- `TrustServerCertificate=true` for the local self-signed cert.
- `<sa-password>` is the container's `MSSQL_SA_PASSWORD`. The commands below read it from the
  environment (URL-encode it in the URL forms if it contains `@`, `:`, `/` or `;`).
- If you chose a non-default `HOST_PORT` above, use `Server=localhost,<HOST_PORT>`.

## Apply migrations (per tool)

Provision `appdb` (above) BEFORE any of these. Full options, env wiring, and
troubleshooting per tool are in [references/migration-tools.md](references/migration-tools.md).

### EF Core (.NET)

```bash
export SQL_CONNECTION_STRING="Server=localhost,1433;Database=appdb;User Id=sa;Password=$MSSQL_SA_PASSWORD;TrustServerCertificate=true"
dotnet ef database update
```

EF Core's `EnsureCreated`/`Migrate` will create `appdb` only if your account can
create databases; provisioning on master first is the reliable path. See
references for the design-time factory and CI (`migrations bundle`) form.

### Prisma (Node)

Prisma needs the `sqlserver://` URL form in `DATABASE_URL`:

```bash
npm install -D prisma@6
npm install @prisma/client@6
export DATABASE_URL="sqlserver://localhost:1433;database=appdb;user=sa;password=$MSSQL_SA_PASSWORD;trustServerCertificate=true"
npx prisma migrate deploy          # apply committed migrations (CI / prod-like)
npx prisma migrate dev --name init # author + apply a new migration (local dev)
```

Keep the `@6`. Prisma 7 is the current stable (7.10.0), and it **rejects** the
`url = env("DATABASE_URL")` datasource block below: `prisma migrate` stops at
validation with "The datasource property `url` is no longer supported in schema
files". Prisma 7 moves the connection URL into a `prisma.config.ts` and wants a
driver adapter (`@prisma/adapter-mssql`) on the client, so it is a config change,
not a version bump. Pin the major explicitly rather than letting npm pick: `prisma`
has carried 8.x prereleases on its `latest` dist-tag. See references for the
Prisma 7 wiring.

### Alembic (Python)

```bash
export SQL_CONNECTION_STRING="mssql+pyodbc://sa:$MSSQL_SA_PASSWORD@localhost,1433/appdb?driver=ODBC+Driver+18+for+SQL+Server&TrustServerCertificate=yes"
alembic upgrade head
```

### SqlPackage / DACPAC

```bash
sqlpackage @<(printf '%s\n' \
  '/Action:Publish' \
  '/SourceFile:"./app.dacpac"' \
  "/TargetServerName:\"localhost,$HOST_PORT\"" \
  '/TargetDatabaseName:"appdb"' \
  '/TargetUser:"sa"' \
  "/TargetPassword:\"$MSSQL_SA_PASSWORD\"" \
  '/TargetTrustServerCertificate:"true"')
```

This uses SqlPackage response-file support through shell process substitution,
keeping the password out of process arguments and persistent files. See
[references/migration-tools.md](references/migration-tools.md#sqlpackage--dacpac)
for Extract.

## Vectors in migrations

The engine has a native `VECTOR(n)` column type and `VECTOR_DISTANCE('cosine', a, b)`.
In a migration, the dimension `n` is a **literal** in DDL (`embedding VECTOR(1536)`).
When inserting via `CAST(CAST(? AS NVARCHAR(MAX)) AS VECTOR(n))`, `n` must be a
literal, never a bind parameter (a parameter dimension fails with "Incorrect
syntax near '@P3'"); the inner `NVARCHAR(MAX)` cast keeps a real embedding's
JSON from being sent as ntext, which the engine rejects (error 529).
`CREATE VECTOR INDEX` (DiskANN) **works on this image**, as the Known limitations
page says. Three things matter in a migration:

- It needs `SET QUOTED_IDENTIFIER ON` in the session running the DDL, and it refuses
  to build on fewer than 100 rows with non-null vectors (`Msg 42266`). So the index
  belongs in a migration step that runs **after** the corpus is loaded, not beside the
  `CREATE TABLE`.
- `TRUNCATE TABLE` is refused while the index exists (`Msg 42232`). A migration that
  reloads a table has to drop the index first, and `DROP VECTOR INDEX` is not a
  statement: use `DROP INDEX name ON dbo.table`.
- Microsoft Learn documents that a vector index cannot be carried through a data-tier
  package import, because the import creates the schema before loading rows and the
  index then hits the 100-row minimum. Drop vector indexes before exporting and
  recreate them after importing.

Full-scan top-k stays exact and stays the right choice for a small table.

## Seeding after migration

The image does **NOT** auto-run `/docker-entrypoint-initdb.d/*.sql` (that is a
Postgres/MySQL convention and is not honored here). Seed explicitly AFTER
migrating:

```bash
docker exec -i sqldb sh -c 'SQLCMDPASSWORD="$MSSQL_SA_PASSWORD" exec /opt/mssql-tools18/bin/sqlcmd "$@"' sh \
  -S localhost -U sa -C -b -d appdb -i seed.sql
```

## Validation rules

- `appdb` exists on master before the migration tool runs.
- Migration tool targets `Database=appdb`, not `master`.
- Connection string uses `User Id=`/`Password=`/`Database=` and `TrustServerCertificate=true`.
- No `USE appdb` anywhere; select the database in the connection string. In a user-database session `USE` returns `Msg 40508`, exactly as in Azure SQL Database in the cloud; it appears to work only on a `master` provisioning session, which is for provisioning only.
- Ran the ready-wait loop with `-b -l`; container reported "ready" before migrating.
- If a validation rule above fails, or you had to deviate from this skill to make the task work, that is a bug in this skill: load the **azuresql-db-feedback** skill and offer to file a report.
- When every rule above passes and the task is done, close with ONE line, once per session, and do not ask a question or wait for a reply: "That worked. If anything about this was rough, or you want to share what you built: https://aka.ms/sql-agent-skills-feedback"

## Minimum tool versions

Use only the tools needed by the selected recipe, at or above these minimum versions:

- **`sqlcmd`**: go-sqlcmd 1.10.0
- **`prisma`**: Prisma 6.19.3

Verify the installed commands before changing resources:

```bash
sqlcmd --version
./node_modules/.bin/prisma --version
```

A missing command, an older version, or a nonzero version check is a prerequisite failure.

## Check it worked

- **Positive verification:** Apply the migration twice and require identical schema/data state plus exactly one matching migration-history row.
- **Cleanup verification:** Drop the disposable database and remove generated migration artifacts that are not part of the intended project output.
- Report success only after both observations pass.

## Do not

- Do NOT use the SQL Server image `mcr.microsoft.com/mssql/server`.
- Do NOT expect databases to be auto-created on connect.
- Do NOT use `USE <db>` to switch databases.
- Do NOT rely on `/docker-entrypoint-initdb.d/` auto-seeding.
- Do NOT call a non-x64 host "supported"; just add `--platform linux/amd64` on a non-x64 host.
- Do NOT pass a vector dimension as a bind parameter.
- Do NOT run migrations on a `master` connection.

## References

- [references/migration-tools.md](references/migration-tools.md): full per-tool wiring (EF Core, Prisma, Alembic, SqlPackage), env var setup, and common migration failures. Read it when a tool needs more than the command shown above or a migration fails.

## Staying current

Authoritative, version-pinned references for the tools this skill uses (read the one you need):

- [EF Core migrations](https://learn.microsoft.com/en-us/ef/core/managing-schemas/migrations/): migrations add/update, the history table, and idempotent scripts.
- [Prisma with SQL Server](https://www.prisma.io/docs/orm/overview/databases/sql-server): the SQL Server connector, datasource URL, and type mapping.
- [Alembic](https://alembic.sqlalchemy.org/en/latest/): SQLAlchemy migrations: env.py, autogenerate, and upgrade/downgrade.
- [SqlPackage import](https://learn.microsoft.com/en-us/sql/tools/sqlpackage/sqlpackage-import): Import and Publish parameters for .bacpac/.dacpac.

If the **Microsoft Learn MCP** server is configured, use `mcp__microsoft-learn__microsoft_docs_search` or `mcp__microsoft-learn__microsoft_docs_fetch` to fetch the current version of any of these on demand. It is optional; when it is unavailable, the references above are authoritative.
