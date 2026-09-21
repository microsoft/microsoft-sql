# Data API Builder snippets

## Contents

- End-to-end with the CLI
- DAB as a container against the SQL container
- DAB as a compose service
- Sample REST calls
- Sample GraphQL calls
- Seeding a table to return rows

## End-to-end with the CLI

Assumes the container is running and `appdb` is provisioned (see
**azuresql-db-container** / **azuresql-db-scaffold**), with a `dbo.Books` table.

```bash
dotnet tool install --global Microsoft.DataApiBuilder   # once; needs .NET 8

: "${SQL_CONNECTION_STRING:?Build and export SQL_CONNECTION_STRING as shown in SKILL.md Step 2}"
dab init --database-type mssql \
  --connection-string "@env('SQL_CONNECTION_STRING')" \
  --host-mode Development
dab add Book --source dbo.Books --source.type table --permissions "anonymous:*"
ASPNETCORE_URLS=http://127.0.0.1:5000 dab start
```

`anonymous:*` is only for this loopback local demonstration.

## DAB as a container against the SQL container

DAB in its own container must reach the SQL container over the Docker network,
so the caller-supplied `SQL_CONNECTION_STRING` uses the
**service/container name** `sqldb`, not `localhost`. Set it and a unique
`MSSQL_SA_PASSWORD`, then put both containers on one network:

```bash
(
set +x
if [ -z "${MSSQL_SA_PASSWORD:-}" ] || [ -z "${SQL_CONNECTION_STRING:-}" ]; then
  echo "Set MSSQL_SA_PASSWORD and the complete SQL_CONNECTION_STRING." >&2
  exit 1
fi
export MSSQL_SA_PASSWORD SQL_CONNECTION_STRING

docker network create appnet 2>/dev/null

# SQL engine on the network (name: sqldb)
docker run -d --name sqldb --network appnet --platform linux/amd64 \
  -e ACCEPT_EULA=Y -e MSSQL_SA_PASSWORD \
  -p 127.0.0.1:1433:1433 sqldbpreview-dpgaeqhmgphzd4bk.azurecr.io/azure-sql/db-dev:latest
# ... wait for ready + CREATE DATABASE appdb (see azuresql-db-container) ...

# DAB on the same network; connection host is sqldb, not localhost
docker run -d --name dab --network appnet -p 127.0.0.1:5000:5000 \
  -e SQL_CONNECTION_STRING \
  -v "$PWD/dab-config.json:/App/dab-config.json" \
  mcr.microsoft.com/azure-databases/data-api-builder:latest
)
```

If the SQL engine runs on the host instead, DAB-in-a-container reaches it at
`host.docker.internal,1433`.

## DAB as a compose service

Add DAB alongside the `sqldb` sidecar (see **azuresql-db-sidecar** for the
engine service + `sqldb-init`). Set `SQL_CONNECTION_STRING` in the caller
environment; host is the service name `sqldb`:

```yaml
services:
  # sqldb: ...        (engine, see azuresql-db-sidecar)
  # sqldb-init: ...   (creates appdb, see azuresql-db-sidecar)

  dab:
    image: mcr.microsoft.com/azure-databases/data-api-builder:latest
    depends_on:
      sqldb-init:
        condition: service_completed_successfully
    environment:
      - SQL_CONNECTION_STRING
    ports:
      - "127.0.0.1:5000:5000"
    volumes:
      - ./dab-config.json:/App/dab-config.json:ro
```

## Sample REST calls

```bash
curl http://localhost:5000/api/Book                         # list
curl http://localhost:5000/api/Book/id/1                    # by primary key
curl "http://localhost:5000/api/Book?\$filter=title eq 'Dune'&\$select=id,title"
curl -X POST http://localhost:5000/api/Book \
  -H 'Content-Type: application/json' -d '{"title":"New Title"}'
```

## Sample GraphQL calls

```bash
curl -s http://localhost:5000/graphql \
  -H 'Content-Type: application/json' \
  -d '{"query":"{ books(first:5) { items { id title } } }"}'

# mutation
curl -s http://localhost:5000/graphql \
  -H 'Content-Type: application/json' \
  -d '{"query":"mutation { createBook(item:{ title:\"New\" }) { id title } }"}'
```

## Seeding a table to return rows

DAB serves whatever is in the table; to see non-empty results, seed after
`appdb` exists:

```bash
(
set +x
if [ -z "${MSSQL_SA_PASSWORD:-}" ]; then
  echo "Set MSSQL_SA_PASSWORD to the credential used by sqldb." >&2
  exit 1
fi
export SQLCMDPASSWORD="$MSSQL_SA_PASSWORD"
docker exec -e SQLCMDPASSWORD -i sqldb /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa \
  -C -b -d appdb -Q \
  "IF OBJECT_ID('dbo.Books') IS NULL CREATE TABLE dbo.Books(id INT IDENTITY PRIMARY KEY, title NVARCHAR(200));
   INSERT INTO dbo.Books(title) VALUES (N'Dune'),(N'Neuromancer');"
)
```
