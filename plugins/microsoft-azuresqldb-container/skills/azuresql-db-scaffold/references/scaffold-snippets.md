# Scaffold snippets

Per-stack skeletons wired to the Azure SQL Database container. Every snippet assumes the
container is running and **appdb is already provisioned on a master connection** (see the
canonical start recipe in SKILL.md). Apps read `SQL_CONNECTION_STRING`; ORMs that need a URL
also read `DATABASE_URL`. Image is
`sqldbpreview-dpgaeqhmgphzd4bk.azurecr.io/azure-sql/db-dev:latest` (NOT the
`mcr.microsoft.com/mssql/server` SQL Server image). On a non-x64 host add `platform: linux/amd64`.

## Contents

- [Provision appdb first](#provision-appdb-first-every-stack-below-assumes-this-has-run)
- [Shared: compose service](#shared-compose-service)
- [.NET Aspire (EF Core)](#net-aspire-ef-core)
- [FastAPI (SQLAlchemy / pyodbc)](#fastapi-sqlalchemy--pyodbc)
- [Next.js (Prisma)](#nextjs-prisma)
- [NestJS (Prisma or TypeORM)](#nestjs-prisma-or-typeorm)

## Provision appdb first (every stack below assumes this has run)

The engine does not auto-create databases. On a master connection:

```bash
: "${MSSQL_SA_PASSWORD:?Set MSSQL_SA_PASSWORD to a unique password}"
export SQLCMDPASSWORD="$MSSQL_SA_PASSWORD"
docker exec -e SQLCMDPASSWORD sqldb /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b \
  -Q "IF DB_ID('appdb') IS NULL CREATE DATABASE appdb;"
```

## Shared: compose service

`compose.yaml`. The provisioner sidecar creates appdb so the app never hits a missing database.

```yaml
services:
  sqldb:
    image: sqldbpreview-dpgaeqhmgphzd4bk.azurecr.io/azure-sql/db-dev:latest
    # On a non-x64 host, uncomment:
    # platform: linux/amd64
    environment:
      ACCEPT_EULA: "Y"
      MSSQL_SA_PASSWORD: "${MSSQL_SA_PASSWORD:?Set MSSQL_SA_PASSWORD}"
    ports:
      - "127.0.0.1:${HOST_PORT:?Set HOST_PORT}:1433"
    healthcheck:
      test: ["CMD-SHELL", "SQLCMDPASSWORD=\"$$MSSQL_SA_PASSWORD\" /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b -l 2 -Q \"SELECT 1\""]
      interval: 5s
      timeout: 5s
      retries: 30
  provision:
    image: sqldbpreview-dpgaeqhmgphzd4bk.azurecr.io/azure-sql/db-dev:latest
    # platform: linux/amd64
    depends_on:
      sqldb:
        condition: service_healthy
    environment:
      MSSQL_SA_PASSWORD: "${MSSQL_SA_PASSWORD:?Set MSSQL_SA_PASSWORD}"
    entrypoint: ["/bin/bash", "-c"]
    command: >
      SQLCMDPASSWORD="$$MSSQL_SA_PASSWORD" /opt/mssql-tools18/bin/sqlcmd -S sqldb -U sa -C -b
      -Q "IF DB_ID('appdb') IS NULL CREATE DATABASE appdb;"
```

Connection string the app consumes (host side, using the selected `HOST_PORT`):

```
Server=localhost,<HOST_PORT>;Database=appdb;User Id=sa;Password=<MSSQL_SA_PASSWORD>;TrustServerCertificate=true
```

## .NET Aspire (EF Core)

`.env` / user-secrets:

```
SQL_CONNECTION_STRING=Server=localhost,<HOST_PORT>;Database=appdb;User Id=sa;Password=<MSSQL_SA_PASSWORD>;TrustServerCertificate=true
```

Provision appdb (once, on master) before the first migration: see
[Provision appdb first](#provision-appdb-first-every-stack-below-assumes-this-has-run).

`Program.cs` reads the single env var:

```csharp
var conn = Environment.GetEnvironmentVariable("SQL_CONNECTION_STRING")
           ?? throw new InvalidOperationException("SQL_CONNECTION_STRING not set");
builder.Services.AddDbContext<AppDbContext>(o => o.UseSqlServer(conn));
```

First migration (EF Core targets appdb via the connection string, never `USE`):

```bash
dotnet ef migrations add InitialCreate
dotnet ef database update
```

Typed, parameterized data access (EF parameterizes by default):

```csharp
var widgets = await db.Widgets
    .Where(w => w.Name == name)   // name is parameterized, never concatenated
    .ToListAsync();
```

For the migration workflow in depth, see the **azuresql-db-schema-migration** skill.

## FastAPI (SQLAlchemy / pyodbc)

`.env`:

```
SQL_CONNECTION_STRING=Server=localhost,<HOST_PORT>;Database=appdb;User Id=sa;Password=<MSSQL_SA_PASSWORD>;TrustServerCertificate=true
```

Provision appdb on master before the app connects (see
[Provision appdb first](#provision-appdb-first-every-stack-below-assumes-this-has-run)).

`db.py`: build a SQLAlchemy URL from the canonical string via pyodbc.

```python
import os, urllib.parse
from sqlalchemy import create_engine, text

raw = os.environ["SQL_CONNECTION_STRING"]
# Hand the ODBC string straight to the driver; SQLAlchemy passes it through.
url = "mssql+pyodbc:///?odbc_connect=" + urllib.parse.quote_plus(
    raw + ";Driver={ODBC Driver 18 for SQL Server}"
)
engine = create_engine(url, pool_pre_ping=True)

def get_widget(name: str):
    with engine.connect() as cx:
        # Parameterized; never f-string the value into SQL.
        return cx.execute(
            text("SELECT id, name FROM dbo.widgets WHERE name = :name"),
            {"name": name},
        ).all()
```

First migration with Alembic (it connects to appdb from the same URL):

```bash
alembic revision --autogenerate -m "initial"
alembic upgrade head
```

Vector insert (dimension is a LITERAL in the SQL text, value is bound):

```python
cx.execute(
    text("INSERT INTO dbo.docs (embedding) VALUES (CAST(CAST(:v AS NVARCHAR(MAX)) AS VECTOR(1536)))"),
    {"v": "[0.1, 0.2, 0.3]"},   # 1536 is literal; do NOT bind it as a parameter
)
```

## Next.js (Prisma)

Prisma needs a `sqlserver://` URL. Provide both env vars; keep them describing the same instance.

`.env`:

```
SQL_CONNECTION_STRING=Server=localhost,<HOST_PORT>;Database=appdb;User Id=sa;Password=<MSSQL_SA_PASSWORD>;TrustServerCertificate=true
DATABASE_URL=sqlserver://localhost:<HOST_PORT>;database=appdb;user=sa;password=<URL_ENCODED_MSSQL_SA_PASSWORD>;trustServerCertificate=true;encrypt=true
```

Install Prisma (pinned to v6):

```bash
npm install -D prisma@6
npm install @prisma/client@6
```

Pinned to Prisma 6 (6.19.3) on purpose: Prisma 7 (7.10.0, the current stable) rejects the
`url = env("DATABASE_URL")` block below and wants a `prisma.config.ts` plus a driver adapter
(`@prisma/adapter-mssql`). Pin the major explicitly rather than letting npm pick: `prisma` has
carried 8.x prereleases on its `latest` dist-tag.

`prisma/schema.prisma`:

```prisma
datasource db {
  provider = "sqlserver"
  url      = env("DATABASE_URL")
}
```

Provision appdb on master, THEN run the first migration (Prisma will not create the database):

```bash
: "${MSSQL_SA_PASSWORD:?Set MSSQL_SA_PASSWORD to a unique password}"
export SQLCMDPASSWORD="$MSSQL_SA_PASSWORD"
docker exec -e SQLCMDPASSWORD sqldb /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b \
  -Q "IF DB_ID('appdb') IS NULL CREATE DATABASE appdb;"
npx prisma migrate dev --name init
```

Typed, parameterized data access (Prisma Client parameterizes all inputs):

```ts
const widgets = await prisma.widget.findMany({ where: { name } });
```

## NestJS (Prisma or TypeORM)

`.env` (the same vars as Next.js; the TypeORM DataSource below also reads `MSSQL_SA_PASSWORD`):

```
SQL_CONNECTION_STRING=Server=localhost,<HOST_PORT>;Database=appdb;User Id=sa;Password=<MSSQL_SA_PASSWORD>;TrustServerCertificate=true
DATABASE_URL=sqlserver://localhost:<HOST_PORT>;database=appdb;user=sa;password=<URL_ENCODED_MSSQL_SA_PASSWORD>;trustServerCertificate=true;encrypt=true
# Supply MSSQL_SA_PASSWORD through the launch environment.
```

Provision appdb on master before bootstrapping (see
[Provision appdb first](#provision-appdb-first-every-stack-below-assumes-this-has-run)).

Prisma path: same pinned install (`npm install prisma@6 @prisma/client@6`), `schema.prisma`, and
`npx prisma migrate dev --name init` as Next.js above.

TypeORM path: parse the canonical string into `DataSourceOptions`.

Template: add the application's classes to the empty `entities` and `migrations` arrays.

```ts
import { DataSource } from "typeorm";

const password = process.env.MSSQL_SA_PASSWORD; const port = Number(process.env.HOST_PORT); if (!password || !Number.isInteger(port) || port < 1 || port > 65535) throw new Error("MSSQL_SA_PASSWORD and HOST_PORT must be set");
export const AppDataSource = new DataSource({
  type: "mssql",
  host: "localhost",
  port,
  username: "sa",
  password,
  database: "appdb",                 // selected here, never via USE
  options: { trustServerCertificate: true },
  entities: [],
  migrations: [],
});
```

First migration:

```bash
# TypeORM 0.3+: the name is a positional path and the data source is passed with -d
# (the legacy -n flag was removed). Adjust paths to your project layout.
npm run typeorm -- migration:generate ./src/migrations/Init -d ./src/AppDataSource.ts
npm run typeorm -- migration:run -d ./src/AppDataSource.ts
```

Typed, parameterized data access (TypeORM binds parameters):

```ts
const widgets = await repo
  .createQueryBuilder("w")
  .where("w.name = :name", { name })   // bound, never string-concatenated
  .getMany();
```

For the full migration workflow across stacks, see the **azuresql-db-schema-migration** skill.
