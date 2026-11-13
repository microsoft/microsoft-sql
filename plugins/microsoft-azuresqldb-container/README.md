# Microsoft Azure SQL Database container

`microsoft-azuresqldb-container` · Version 1.0.0

Develop and test applications locally with the Azure SQL Database container, including setup, secure connections, schema and data management, CI, migration from SQL Server containers, local-to-cloud workflows, APIs, and RAG.

This package follows the [Agent Plugins 1.0](https://agent-plugins.org/specification) format and
is published in [`microsoft/microsoft-sql`](https://github.com/microsoft/microsoft-sql).

## Included skills

| Skill | Description |
| --- | --- |
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

## Install

- Copilot CLI: `copilot plugin marketplace add microsoft/microsoft-sql`, then `copilot plugin install microsoft-azuresqldb-container@microsoft-sql`
- Claude Code: `/plugin marketplace add microsoft/microsoft-sql`, then `/plugin install microsoft-azuresqldb-container@microsoft-sql`
- VS Code: add `microsoft/microsoft-sql` to `chat.plugins.marketplaces`, then install from **Chat: Open Customizations** using **Browse** or **Plugins > Browse Marketplace**
- Codex: `codex plugin marketplace add microsoft/microsoft-sql --ref main`, then `codex plugin add microsoft-azuresqldb-container@microsoft-sql`
- Cursor: `cursor-agent plugin marketplace add https://github.com/microsoft/microsoft-sql`, then run `cursor-agent` and install `microsoft-azuresqldb-container` from `/plugin`
- Grok Build: `grok plugin marketplace add microsoft/microsoft-sql`, then install from the Marketplace tab in `/plugins`; for a direct CLI install after review, use `grok plugin install 'microsoft/microsoft-sql#plugins/microsoft-azuresqldb-container' --trust`
- Other Agent Skills clients: copy `skills/<skill>/` only when the client has no plugin marketplace
