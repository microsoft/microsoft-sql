# Microsoft SQL

`microsoft-sql` · Version 1.0.0

Build and operate Azure SQL Database applications, from provisioning and secure connections through schema design, deployment, data movement, performance tuning, vector search, RAG, and local development with the Azure SQL Database container.

This package follows the [Agent Plugins 1.0](https://agent-plugins.org/specification) format and
is published in [`microsoft/microsoft-sql`](https://github.com/microsoft/microsoft-sql).

## Included skills

| Skill | Description |
| --- | --- |
| `azure-functions-sql-bindings` | Use when wiring Azure Functions to Azure SQL Database: a serverless CRUD API with SQL input or output bindings, SqlTrigger on row changes, a SQL trigger that never fires, an output binding that updated instead of inserting. |
| `azure-sql` | Use when Azure SQL Database comes up without a specific task. |
| `azuresql-db-auth` | Use when an app connects to the local Azure SQL Database container as sa. |
| `azuresql-db-ci` | Use when CI (GitHub Actions, Azure Pipelines, GitLab) runs integration tests against the Azure SQL Database container as a service. |
| `azuresql-db-connections` | Use when hardening an app's data layer: connections drop or time out under load, add pooling and retry with backoff for transient faults, Max Pool Size. |
| `azuresql-db-container` | Use when running Azure SQL Database or any SQL/mssql container locally for dev or CI. |
| `azuresql-db-dab` | Use when asked for an API over existing tables ('give me an API for this database', REST and GraphQL without code), or to run a local Data API builder endpoint on the Azure SQL Database container. |
| `azuresql-db-faq` | Use when asking what the local Azure SQL Database container (Private Preview) supports or why it differs from the cloud. |
| `azuresql-db-feedback` | Use when an azuresql-db-* skill or the Azure SQL Database container misbehaved, lacks something, or you worked around it. |
| `azuresql-db-from-sql-server` | Use when a project runs mcr.microsoft.com/mssql/server in Docker or compose and local dev should behave like Azure SQL Database. |
| `azuresql-db-functions` | Use when building a serverless CRUD API or reacting to row changes with Azure Functions on the local Azure SQL Database container. |
| `azuresql-db-import` | Use when loading an existing database into the local Azure SQL Database container. |
| `azuresql-db-local-to-cloud` | Use when code built on the local Azure SQL Database container must run on Azure SQL Database. |
| `azuresql-db-rag` | Use when storing embeddings or running similarity search, top-k or RAG on the local Azure SQL Database container with VECTOR(n) and VECTOR_DISTANCE, instead of pgvector, FAISS or a separate vector store. |
| `azuresql-db-scaffold` | Use when a new app (.NET Aspire, FastAPI, Next.js, NestJS) needs a local database. |
| `azuresql-db-schema-migration` | Use when running migrations against the local Azure SQL Database container. |
| `azuresql-db-seed` | Use when the local Azure SQL Database container needs sample data. |
| `azuresql-db-sidecar` | Use when adding the local Azure SQL Database container to an existing docker-compose or devcontainer.json. |
| `azuresql-db-testing` | Use when integration tests start the Azure SQL Database container from code with Testcontainers. |
| `build-app-on-azure-sql` | Use when starting a new app on Azure SQL Database: choose a stack and go from resource group to first request without storing a password. |
| `bulk-load-and-bulk-copy` | Use when loading a large file or many rows into an Azure SQL Database table fast. |
| `connect-from-dotnet` | Use when connecting a .NET app to Azure SQL Database with Microsoft.Data.SqlClient. |
| `connect-from-python` | Use when connecting Python to Azure SQL Database: mssql-python or pyodbc, the ODBC driver, 'data source name not found', driver missing in a container image, Entra tokens. |
| `connect-from-typescript-and-node` | Use when connecting Node.js or TypeScript to Azure SQL Database with mssql. |
| `connect-to-azure-sql` | Use when connecting an app to Azure SQL Database: which driver, what goes in the connection string, retry, a first connection that fails then works (40613), certificate errors or TrustServerCertificate. |
| `dab-mcp-endpoint` | Use when connecting an AI agent to a hosted Data API builder MCP endpoint, writing its server description, making its tools read-only, or diagnosing role, tool, permission or session failures. |
| `dab-rest-and-graphql` | Use when a Data API builder config may expose more than intended, or to set roles and inheritance, row policies, relationships, a passwordless Azure SQL connection, or autoentities patterns that replace hundreds of hand-written entities in dab-config.json. |
| `deploy-app-to-azure` | Use when deploying an app and its Azure SQL Database with azd. |
| `deploy-dab-to-azure` | Use when deploying Data API builder to Azure Container Apps, or a deployed DAB app shows identity, health (403), host (MCP 403), scaling or startup failures. |
| `design-azure-sql-schema` | Use when creating, reviewing or porting tables for Azure SQL Database. |
| `dev-container-templates` | Use when starting from the microsoft/azuresql-devcontainers templates (.NET, Aspire, Node, Python) or they misbehave. |
| `ef-core-azure-sql` | Use when EF Core targets Azure SQL Database: EnableRetryOnFailure, 'does not support user-initiated transactions', duplicate rows after a retry, UseAzureSql or UseSqlServer, AsSplitQuery, JSON columns. |
| `embeddings-and-external-models` | Use when generating embeddings in Azure SQL Database or reviewing that setup. |
| `entra-id-auth` | Use when setting up passwordless Microsoft Entra ID or managed identity access to Azure SQL Database or the container (CREATE USER FROM EXTERNAL PROVIDER), or it fails. |
| `github-actions-for-sql` | Use when deploying schema to Azure SQL Database from GitHub Actions. |
| `langchain-and-llamaindex-on-azure-sql` | Use when using LangChain or LlamaIndex with Azure SQL Database. |
| `prevent-sql-injection` | Use when writing or reviewing dynamic SQL on Azure SQL Database for injection. |
| `prisma-azure-sql` | Use when using Prisma with Azure SQL Database: schema.prisma, prisma migrate failing in Azure (P3020, shadow database), no Json type or enums, url unsupported in Prisma 7, driver adapter. |
| `provision-azure-sql-db` | Use when creating an Azure SQL Database: a free SQL database in Azure, provision SQL for this app, give me a connection string, firewall rule, Entra-only admin, or created but nothing connects. |
| `provision-hyperscale` | Use when choosing or moving to Hyperscale in Azure SQL Database. |
| `rag-local-with-container` | Use when prototyping RAG offline on the local Azure SQL Database container with a local embedding model, no cloud account, or asking what changes when it moves to Azure. |
| `rag-on-azure-sql` | Use when building a RAG pipeline end to end on Azure SQL Database. |
| `read-execution-plan` | Use when reading an Azure SQL Database execution plan: what is expensive, why a scan, actual vs estimated rows, warnings, missing-index hints, getting the actual plan, a plan returned as NULL. |
| `restore-and-recover` | Use when Azure SQL Database data is lost: restore to before a bad deployment, a dropped table or database, point-in-time restore, geo-restore, long-term retention, RESTORE DATABASE refused. |
| `rls-multi-tenant` | Use when isolating tenants in a shared Azure SQL Database or checking isolation. |
| `schema-migrations-safely` | Use when asking if a schema change is safe on a live Azure SQL Database. |
| `skill-feedback` | Use when a Microsoft SQL skill, plugin or marketplace was wrong. |
| `sql-database-projects` | Use when building or publishing a SQL database project (.sqlproj, dacpac) for Azure SQL Database. |
| `sqlalchemy-azure-sql` | Use when using SQLAlchemy or Alembic with Azure SQL Database. |
| `sqlpackage-import-export` | Use when moving a whole Azure SQL Database as a file with SqlPackage. |
| `t-sql-correctness` | Use when writing, porting or reviewing T-SQL for Azure SQL Database, or results look wrong with no error. |
| `t-sql-json-and-openjson` | Use when storing, querying or reviewing JSON in Azure SQL Database. |
| `t-sql-upserts-merge` | Use when writing or reviewing an upsert or MERGE for Azure SQL Database. |
| `vector-search-azure-sql` | Use when writing, reviewing or debugging vector search on Azure SQL Database. |

## Database diagnostics

This plugin includes application performance guidance and execution-plan reading. Install
[`microsoft-sql-admin`](../microsoft-sql-admin/) alongside it for live Query Store investigations,
blocking, deadlocks, Extended Events, and server resource diagnostics. Those workflows have moved
to the administration plugin, which also configures the companion SQL Tools MCP server.

This plugin does not declare an MCP server of its own. Its skills can use SQL tools already
provided by the host or by the administration plugin.

## Install

- Copilot CLI: `copilot plugin marketplace add microsoft/microsoft-sql`, then `copilot plugin install microsoft-sql@microsoft-sql`
- Claude Code: `/plugin marketplace add microsoft/microsoft-sql`, then `/plugin install microsoft-sql@microsoft-sql`
- VS Code: add `microsoft/microsoft-sql` to `chat.plugins.marketplaces`, then install from **Chat: Open Customizations** using **Browse** or **Plugins > Browse Marketplace**
- Codex: `codex plugin marketplace add microsoft/microsoft-sql --ref main`, then `codex plugin add microsoft-sql@microsoft-sql`
- Cursor: `cursor-agent plugin marketplace add https://github.com/microsoft/microsoft-sql`, then run `cursor-agent` and install `microsoft-sql` from `/plugin`
- Grok Build: `grok plugin marketplace add microsoft/microsoft-sql`, then install from the Marketplace tab in `/plugins`; for a direct CLI install after review, use `grok plugin install 'microsoft/microsoft-sql#plugins/microsoft-sql' --trust`
- Other Agent Skills clients: copy `skills/<skill>/` only when the client has no plugin marketplace
