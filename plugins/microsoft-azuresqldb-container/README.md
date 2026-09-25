# Microsoft Azure SQL Database container

`microsoft-azuresqldb-container` · Version 1.0.0

Develop and test applications locally with the Azure SQL Database container, including setup, secure connections, schema and data management, CI, migration from SQL Server containers, local-to-cloud workflows, APIs, and RAG.

This package follows the [Agent Plugins 1.0](https://agent-plugins.org/specification) format and
is published in [`microsoft/microsoft-sql`](https://github.com/microsoft/microsoft-sql).

## Included skills

| Skill | Description |
| --- | --- |
| `azuresql-db-auth` | Connects an app to the Azure SQL Database container securely, with a least-privilege database user instead of the sa login, the right auth method per environment, and safe handling of the connection secret. |
| `azuresql-db-ci` | Runs integration tests against the Azure SQL Database container (Private Preview, local engine) in CI. |
| `azuresql-db-connections` | Makes an app's database connections reliable against the local Azure SQL Database container (Private Preview) and, unchanged, against Azure SQL Database in the cloud. |
| `azuresql-db-container` | Runs the Azure SQL Database container locally (Private Preview). |
| `azuresql-db-dab` | Stands up an instant no-code REST + GraphQL API over the local Azure SQL Database container using Microsoft Data API Builder (DAB). |
| `azuresql-db-faq` | Answers questions about what the Azure SQL Database container (Private Preview) can and cannot do, and WHY it differs from Azure SQL Database in the Microsoft Azure cloud. |
| `azuresql-db-feedback` | Reports a bug or files feedback about the azuresql-db-* agent skills themselves, or about the Azure SQL Database container (Private Preview). |
| `azuresql-db-from-sql-server` | Migrates a local SQL Server setup to the Azure SQL Database container for Azure-faithful local development. |
| `azuresql-db-functions` | Builds a serverless API and event-driven handlers over the local Azure SQL Database container using Azure Functions with the Azure SQL bindings. |
| `azuresql-db-import` | Imports an existing Azure SQL Database or SQL Server schema and data INTO the local Azure SQL Database container using SqlPackage. |
| `azuresql-db-local-to-cloud` | Proves that code built and tested against the local Azure SQL Database container runs unchanged against Azure SQL Database in the cloud, with only the connection string changing. |
| `azuresql-db-rag` | Builds local vector search, RAG, embeddings, and semantic search on the Azure SQL Database container using the native VECTOR type and VECTOR_DISTANCE. |
| `azuresql-db-scaffold` | Scaffolds a NEW app (.NET Aspire, FastAPI, Next.js, NestJS) wired to the local Azure SQL Database container as its default dev database. |
| `azuresql-db-schema-migration` | Runs database schema migrations against the local Azure SQL Database container so the same migrations apply identically on the local engine and in the Azure cloud. |
| `azuresql-db-seed` | Populates the local Azure SQL Database container's database (appdb) with realistic sample/test data so a developer has something to build against. |
| `azuresql-db-sidecar` | Adds the Azure SQL Database container as a sidecar service in an existing Docker Compose stack or Dev Container. |
| `azuresql-db-testing` | Writes integration tests that run IN CODE against a real Azure SQL Database container, spun up per test or per suite with Testcontainers and torn down after. |

## Install

- Copilot CLI: `copilot plugin marketplace add microsoft/microsoft-sql`, then `copilot plugin install microsoft-azuresqldb-container@microsoft-sql`
- Claude Code: `/plugin marketplace add microsoft/microsoft-sql`, then `/plugin install microsoft-azuresqldb-container@microsoft-sql`
- VS Code: add the repository to `chat.plugins.marketplaces`, then install from the Extensions view (`@agentPlugins`)
- Codex: `codex plugin marketplace add microsoft/microsoft-sql --ref main`, then `codex plugin add microsoft-azuresqldb-container@microsoft-sql`
- Cursor and Grok Build: Cursor reads `.cursor-plugin/`; Grok Build reads the Claude Code descriptors
- Any Agent Skills client: copy `skills/<skill>/` wherever the client discovers `SKILL.md`
