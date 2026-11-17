# Microsoft SQL for Visual Studio Code

`microsoft-sql-vscode` · Version 1.0.0

Build and manage Azure SQL Database applications in Visual Studio Code with the MSSQL extension, including connections, schema and ORM workflows, deployment, diagnostics, security, data movement, recovery, T-SQL, vector search, and database projects. Data API Builder configuration guidance is excluded where it would duplicate tools provided by the extension; hosting Data API Builder in Azure and connecting remote MCP clients are included.

This package follows the [Agent Plugins 1.0](https://agent-plugins.org/specification) format and
is published in [`microsoft/microsoft-sql`](https://github.com/microsoft/microsoft-sql).

## Included skills

| Skill | Description |
| --- | --- |
| `azure-functions-sql-bindings` | Use when wiring Azure Functions to Azure SQL Database: a serverless CRUD API with SQL input or output bindings, SqlTrigger on row changes, a SQL trigger that never fires, an output binding that updated instead of inserting. |
| `bulk-load-and-bulk-copy` | Use when loading a large file or many rows into an Azure SQL Database table fast. |
| `connect-from-dotnet` | Use when connecting a .NET app to Azure SQL Database with Microsoft.Data.SqlClient. |
| `connect-from-python` | Use when connecting Python to Azure SQL Database: mssql-python or pyodbc, the ODBC driver, 'data source name not found', driver missing in a container image, Entra tokens. |
| `connect-from-typescript-and-node` | Use when connecting Node.js or TypeScript to Azure SQL Database with mssql. |
| `connect-to-azure-sql` | Use when connecting an app to Azure SQL Database: which driver, what goes in the connection string, retry, a first connection that fails then works (40613), certificate errors or TrustServerCertificate. |
| `dab-mcp-endpoint` | Use when connecting an AI agent to a hosted Data API builder MCP endpoint, writing its server description, making its tools read-only, or diagnosing role, tool, permission or session failures. |
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
| `authentication-diagnostics` | Use when a login fails (18456, 'Login failed for user'), a user can't open a database, a permission is denied, or an Entra or managed identity login fails. |
| `check-live-blocking` | Use when queries hang right now: who is blocking, the head blocker, why a blocking DMV looks empty. |
| `connectivity-troubleshoot` | Use when a client can't connect or gets a connection error (timeout, 53/10060/10061, SQLSTATE 08001, TLS, firewall 'IP not allowed', 4060). |
| `create-xe-session` | Use when the user wants an Extended Events session to capture slow queries, deadlocks or blocking over hours or days, or an XE ring buffer stays empty. |
| `deadlock-analysis-azuresql` | Use when the user asks about deadlocks, deadlock history or prevention on Azure SQL Database or Fabric SQL Database. |
| `investigate-sql-cpu-pressure` | Use when CPU is high on SQL Server or Azure SQL (alerts, throttling, SOS_SCHEDULER_YIELD waits) and the user wants the queries responsible. |
| `investigate-sql-data-io-pressure` | Use when data-file reads are slow or heavy: PAGEIOLATCH waits, high read latency, many physical reads, Azure SQL data IO throttling. |
| `investigate-sql-log-io-pressure` | Use when commits are slow or log writes lag: WRITELOG waits, high log write percent, log throughput throttling, too many VLFs. |
| `investigate-sql-memory-issues` | Use when queries wait on memory grants (RESOURCE_SEMAPHORE), spill to tempdb, hit out-of-memory errors (701, 802, 8645), or PLE drops. |
| `resource-usage-sqlserver` | Use when many queries time out under load, or SQL Server or Azure SQL is slow overall and it's unclear whether CPU, memory, IO, TempDB or disk is the cause. |
| `slow-query-investigation` | Use when one specific query got slow, changed plans, or swings from seconds to minutes with the same parameters. |

## Host tools and overlapping skills

Use the MSSQL extension's SQL tools for database access. This plugin includes a curated subset
of administration skills and does not configure the standalone SQL Tools MCP server. Installing
`microsoft-sql-admin` alongside it duplicates that subset. For the full administration bundle in a
general-purpose agent host, use `microsoft-sql` with `microsoft-sql-admin`.

Data API Builder configuration and local execution belong to the extension's designer. The
included `deploy-dab-to-azure` and `dab-mcp-endpoint` skills cover Azure hosting and remote MCP
clients.

## Install

- Copilot CLI: `copilot plugin marketplace add microsoft/microsoft-sql`, then `copilot plugin install microsoft-sql-vscode@microsoft-sql`
- Claude Code: `/plugin marketplace add microsoft/microsoft-sql`, then `/plugin install microsoft-sql-vscode@microsoft-sql`
- VS Code: add `microsoft/microsoft-sql` to `chat.plugins.marketplaces`, then install from **Chat: Open Customizations** using **Browse** or **Plugins > Browse Marketplace**
- Codex: `codex plugin marketplace add microsoft/microsoft-sql --ref main`, then `codex plugin add microsoft-sql-vscode@microsoft-sql`
- Cursor: `cursor-agent plugin marketplace add https://github.com/microsoft/microsoft-sql`, then run `cursor-agent` and install `microsoft-sql-vscode` from `/plugin`
- Grok Build: `grok plugin marketplace add microsoft/microsoft-sql`, then install from the Marketplace tab in `/plugins`; for a direct CLI install after review, use `grok plugin install 'microsoft/microsoft-sql#plugins/microsoft-sql-vscode' --trust`
- Other Agent Skills clients: copy `skills/<skill>/` only when the client has no plugin marketplace
