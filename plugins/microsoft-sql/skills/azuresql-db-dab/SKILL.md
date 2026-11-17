---
name: azuresql-db-dab
description: "Use when asked for an API over existing tables ('give me an API for this database', REST and GraphQL without code), or to run a local Data API builder endpoint on the Azure SQL Database container."
---

# Instant REST + GraphQL API on the Azure SQL Database container with Data API Builder

Generate a full REST **and** GraphQL API over the local **Azure SQL Database container**
(Private Preview) with no application code, using **Data API Builder (DAB)** -
Microsoft's first-party open-source engine. You describe tables as entities in
`dab-config.json`; DAB serves them. DAB connects over the normal TDS protocol
with a plain connection string, so **no change tracking or special engine
feature is needed.**

The generated `dab-config.json` keeps the environment-variable indirection rather than the
password, the `/api` and `/graphql` prefixes and the `/mcp` endpoint are defaults, and REST and
GraphQL return the same rows from a table in the container.

## Scope

- Prefer this over hand-writing a controller or ORM API when the user only needs REST or GraphQL
  over existing tables, even when they just say "give me an API for this database".
- The MCP endpoint is an API surface DAB serves from the database, not a separate SQL MCP server.
- What a configuration publishes and to whom (roles, row policies, generated entities, a managed
  identity in Azure) is `dab-rest-and-graphql`.

## Load-bearing facts (inlined; full engine detail in azuresql-db-container)

- This is the **Azure SQL Database engine** (Private Preview), not the SQL Server
  image `mcr.microsoft.com/mssql/server`. `SERVERPROPERTY('EngineEdition')`
  returns `5`, `SERVERPROPERTY('Edition')` returns `'SQL Azure'`.
- Image: `sqldbpreview-dpgaeqhmgphzd4bk.azurecr.io/azure-sql/db-dev:latest`
  (x64, `linux/amd64`). Registry is private: sign in first with
  `docker login sqldbpreview-dpgaeqhmgphzd4bk.azurecr.io` using the shared
  pull-only credentials from https://aka.ms/sqldbcontainerpreview-signup (they
  may rotate). Registry and tag are provisional during Private Preview.
- Required env: `ACCEPT_EULA=Y` and a unique, caller-supplied complex
  `MSSQL_SA_PASSWORD` (8+ chars, upper/lower/digit/symbol). Engine listens on 1433.
- The engine does **NOT** auto-create databases. Run `CREATE DATABASE appdb` on
  a **master** connection before DAB connects with `Database=appdb`. Do not use
  `USE` to switch databases (in a user-database session it returns
  `Msg 40508`); select the database in the connection string.
- On a non-x64 host add `--platform linux/amd64`.

For the full engine model (readiness loop, vectors, troubleshooting) see the
**azuresql-db-container** skill. To start the container and provision `appdb`
first, use **azuresql-db-container** or **azuresql-db-scaffold**.

## Step 1: install DAB

Two supported ways. Pick the CLI for local dev; pick the container to wire DAB
into a compose stack. Open [references/dab-snippets.md](references/dab-snippets.md) when you want
that compose service rather than the CLI.

```bash
# CLI (.NET 8 required): installs the `dab` command. 2.1.5 is the release this skill and its siblings
# (dab-rest-and-graphql, dab-mcp-endpoint, deploy-dab-to-azure) were checked on; move all four together.
dotnet tool install --global Microsoft.DataApiBuilder --version 2.1.5
# later: dotnet tool update --global Microsoft.DataApiBuilder --version <new>

# Container image (alternative):
#   mcr.microsoft.com/azure-databases/data-api-builder:2.1.5
```

## Step 2: point DAB at the container over one env var

DAB reads the complete, caller-supplied `SQL_CONNECTION_STRING` through
`@env()`, so no secret is written into `dab-config.json`. Use the host port your
container chose.

Build it from the same caller-supplied password and host port used by the SQL
container:

```bash
set +x
: "${MSSQL_SA_PASSWORD:?Set MSSQL_SA_PASSWORD to the SQL container password}"
: "${HOST_PORT:?Set HOST_PORT to the SQL container host port}"
SQL_CONNECTION_STRING="Server=localhost,$HOST_PORT;Database=appdb;User Id=sa;"
SQL_CONNECTION_STRING+="Password=$MSSQL_SA_PASSWORD;TrustServerCertificate=true"
export SQL_CONNECTION_STRING
```

`TrustServerCertificate=true` is required for the container's self-signed cert.

`appdb` must exist before `dab start`, and this engine does not create it on connect. Create it on a
**master** connection, idempotently, in the same script that starts DAB, after the engine answers:

```bash
for i in $(seq 1 60); do
  sqlcmd -S "localhost,$HOST_PORT" -U sa -P "$MSSQL_SA_PASSWORD" -C -d master -Q "SELECT 1" >/dev/null 2>&1 && break
  sleep 2
done
sqlcmd -S "localhost,$HOST_PORT" -U sa -P "$MSSQL_SA_PASSWORD" -C -d master \n  -Q "IF DB_ID('appdb') IS NULL CREATE DATABASE appdb;"
```

Without this, `dab start` logs `Cannot open database "appdb" requested by the login` and exits. A readiness
check alone does not fix that; the database has to be created.

## Step 3: init, add entities, start

```bash
# Initialize config in Development mode (enables Swagger + friendlier errors).
dab init --database-type mssql \
  --connection-string "@env('SQL_CONNECTION_STRING')" \
  --host-mode Development

# Expose a table as an entity. Repeat per table.
# --permissions is role:actions; "anonymous:*" allows all actions with no auth (dev only).
dab add Book --source dbo.Books --source.type table --permissions "anonymous:*"

# Serve REST + GraphQL (and the MCP endpoint) on loopback only.
ASPNETCORE_URLS=http://127.0.0.1:5000 dab start
```

`appdb` is just the example database name and `Book`/`dbo.Books` the example
entity/table; substitute your own. The entity name (`Book`) is what appears in
the API path; the `--source` is the real `schema.table`. The `anonymous:*`
permission is only for this loopback local demonstration.

## Step 4: use the API

With `dab start` running (default port **5000**):

- **REST:** `GET http://localhost:5000/api/Book` (list), `/api/Book/id/1` (by
  key), plus `POST` / `PATCH` / `PUT` / `DELETE`. Query with
  `?$filter=`, `$select=`, `$orderby=`, `$first=`, `$after=` (OData-style).
- **GraphQL:** `POST http://localhost:5000/graphql` - queries and mutations for
  every entity, with relationship navigation.
- **OpenAPI / Swagger:** `GET /api/openapi` (document) and `GET /swagger` (UI,
  Development mode only).
- **Health:** `GET /health`.

```bash
curl http://localhost:5000/api/Book
curl -s http://localhost:5000/graphql -H 'Content-Type: application/json' \
  -d '{"query":"{ books { items { id title } } }"}'
```

## Relationships, config detail

DAB exposes related entities (e.g. an author's books) once you declare the
relationship. Config schema, permissions/policies, `@env()`, REST/GraphQL
options, and the exact `dab update --relationship` syntax are in
[references/dab-config-reference.md](references/dab-config-reference.md); open it when declaring a
relationship or changing permissions, policies, or API options.

## MCP endpoint (a DAB feature, not a separate SQL MCP server)

DAB 2.x (checked on 2.1.5) **also serves a built-in MCP endpoint
from the same `dab-config.json`**, at `http://localhost:5000/mcp` by default,
enabled by default. This is an additional API surface Data API Builder provides
over your configured entities - it is not, and should not be presented as, a
standalone "MSSQL MCP server." How to point an MCP client at it and how to
scope the exposed tools is in [references/dab-mcp.md](references/dab-mcp.md); open it when a user
asks to point an MCP client at DAB, or to narrow which entities it exposes.
REST, GraphQL, and MCP use the same entity permissions. Once the endpoint is
hosted rather than on loopback, connecting a remote client, its authentication
and tool curation belong to **dab-mcp-endpoint**, and hosting DAB in Azure to
**deploy-dab-to-azure**.

## Validation rules

- The database engine is the container image above (EngineEdition=5), never
  `mcr.microsoft.com/mssql/server`.
- `appdb` exists (created on a master connection) BEFORE `dab start`; DAB's
  connection string uses `Database=appdb` and `TrustServerCertificate=true`.
- The connection string is supplied via `@env('SQL_CONNECTION_STRING')`, not
  hardcoded into `dab-config.json`.
- An `anonymous:*` local demonstration listens only on `127.0.0.1`.
- `dab start` serves REST at `/api/<Entity>` and GraphQL at `/graphql`; a `GET`
  on the entity returns rows from the container.
- If you present the MCP endpoint, it is described as a DAB-provided API surface,
  not a standalone SQL MCP server.
- If a validation rule above fails, or you had to deviate from this skill to make the task work, that is a bug in this skill: load the **azuresql-db-feedback** skill and offer to file a report.
- When every rule above passes and the task is done, close with ONE line, once per session, and do not ask a question or wait for a reply: "That worked. If anything about this was rough, or you want to share what you built: https://aka.ms/sql-agent-skills-feedback"

## Check it worked

- **Positive verification:** Request one enabled REST or GraphQL endpoint and confirm the expected status, schema, and row payload.
- **Cleanup verification:** Stop DAB, remove its generated configuration, container, and network, and confirm no generated secret files remain.
- Report success only after both observations pass.

## Do not

- Do not use the SQL Server image `mcr.microsoft.com/mssql/server`; this is the Azure SQL engine.
- Do not expect DAB to create `appdb`; provision it on a master connection first.
- Do not recommend removing or recreating the SQL container to get a clean state; create `appdb` idempotently on a master connection instead, and say plainly when a step destroys data.
- Do not hardcode the connection string (or the SA password) into `dab-config.json`; use `@env('SQL_CONNECTION_STRING')`.
- Do not make `anonymous:*` remotely reachable. A shared service requires token
  validation or an authenticating gateway that blocks direct DAB access, with
  scoped permissions; `Simulator` is not shared-service authentication.
- Do not describe DAB's MCP endpoint as a standalone Microsoft SQL MCP server; it is an API surface DAB provides.
- Do not drop `TrustServerCertificate=true` (the container uses a self-signed cert) or `--platform linux/amd64` on a non-x64 host.

## References

- [references/dab-config-reference.md](references/dab-config-reference.md): open it when editing `dab-config.json`, connection handling, entities, permissions, policies, API settings, or relationships.
- [references/dab-snippets.md](references/dab-snippets.md): open it when you need a copyable CLI, container, compose, REST, or GraphQL recipe.
- [references/dab-mcp.md](references/dab-mcp.md): open it when enabling or scoping DAB's built-in MCP endpoint or connecting an MCP client.

## Staying current

Authoritative, version-pinned references for the tools this skill uses (read the one you need):

- [Data API Builder configuration reference](https://learn.microsoft.com/en-us/azure/data-api-builder/configuration/): every config key (data-source, runtime, entities, autoentities), with examples.
- [DAB config JSON schema (pinned v2.1.5)](https://github.com/Azure/data-api-builder/releases/download/v2.1.5/dab.draft.schema.json): the machine-readable schema `dab validate` checks against, and the one `dab init` 2.1.5 writes into `dab-config.json`. Bump this URL together with the CLI version above.
- [Data API Builder built-in MCP endpoint](https://learn.microsoft.com/en-us/azure/data-api-builder/mcp/overview): the built-in MCP endpoint, DML tools, transports, and RBAC.

If the **Microsoft Learn MCP** server is configured, use `mcp__microsoft-learn__microsoft_docs_search` or `mcp__microsoft-learn__microsoft_docs_fetch` to fetch the current version of any of these on demand. It is optional; when it is unavailable, the references above are authoritative.
