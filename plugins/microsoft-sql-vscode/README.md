# Microsoft SQL for Visual Studio Code

`microsoft-sql-vscode` · Version 1.0.0

Build and manage Azure SQL Database applications in Visual Studio Code with the MSSQL extension, including connections, schema and ORM workflows, deployment, diagnostics, security, data movement, recovery, T-SQL, vector search, and database projects. Data API Builder guidance is excluded where it would duplicate tools provided by the extension.

This package follows the [Agent Plugins 1.0](https://agent-plugins.org/specification) format and
is published in [`microsoft/microsoft-sql`](https://github.com/microsoft/microsoft-sql).

## Included skills

| Skill | Description |
| --- | --- |
| `azure-functions-sql-bindings` | Wires Azure Functions to Azure SQL Database with the SQL input and output bindings and the SQL trigger, including the change tracking the trigger cannot run without and the identity permissions the trigger needs beyond the ones the bindings need. |
| `bulk-load-and-bulk-copy` | Loads data into Azure SQL Database fast by choosing the right route. |
| `capture-with-extended-events` | Creates, starts, reads back and drops a database-scoped Extended Events session on Azure SQL Database, and names the ways one reports success while capturing nothing. |
| `connect-from-dotnet` | Connects a .NET application to Azure SQL Database with Microsoft.Data.SqlClient. |
| `connect-from-python` | Connects a Python application to Azure SQL Database, choosing between Microsoft's first-party mssql-python driver and the incumbent pyodbc, and covering driver installation, the connection string each one wants, connection pooling. |
| `connect-from-typescript-and-node` | Connects a TypeScript or JavaScript application to Azure SQL Database with the mssql package over tedious. |
| `connect-to-azure-sql` | Connects an application to Azure SQL Database: picks the Microsoft driver for the language, sets encryption and certificate validation, sizes the pool against the worker limit not the session limit, and makes retry part of the first version of the code. |
| `deploy-app-to-azure` | Takes a working local application and its Azure SQL Database to Azure with the Azure Developer CLI, reading its infrastructure rather than inheriting it. |
| `design-azure-sql-schema` | Designs tables for Azure SQL Database so the first index or long value does not force a rebuild. |
| `dev-container-templates` | Sets up local development from the Azure SQL Database dev container templates in microsoft/azuresql-devcontainers (.NET, .NET Aspire, Node.js, Python), each with a sample database and schema loaded. |
| `diagnose-blocking-and-deadlocks` | Finds who is blocking whom on Azure SQL Database right now, and reads a completed deadlock graph out of the database-scoped Extended Events session that captured it. |
| `diagnose-connection-errors` | Diagnoses an Azure SQL Database connection refused before a credential was evaluated, reading the error number to name the layer that refused. |
| `diagnose-resource-pressure` | Answers whether an Azure SQL Database is slow because of CPU, data or log IO, memory, or a worker and session limit. |
| `diagnose-slow-query` | Triages a slow Azure SQL Database query into one of four causes before anyone touches an index or a service tier. |
| `ef-core-azure-sql` | Configures Entity Framework Core against Azure SQL Database, where retry is on by default and redefines a transaction. |
| `embeddings-and-external-models` | Generates embeddings and chunks inside Azure SQL Database with CREATE EXTERNAL MODEL, AI_GENERATE_EMBEDDINGS, AI_GENERATE_CHUNKS and sp_invoke_external_rest_endpoint, covering the database scoped credential naming rule, the permissions. |
| `entra-id-auth` | Takes an application identity to a passwordless connection to Azure SQL Database, and diagnoses it when that fails. |
| `github-actions-for-sql` | Ships schema changes to Azure SQL Database from a GitHub Actions workflow with `azure/sql-action`. |
| `langchain-and-llamaindex-on-azure-sql` | Wires LangChain or LlamaIndex to Azure SQL Database from Python. |
| `prevent-sql-injection` | Handles SQL injection on Azure SQL Database beyond parameterisation. |
| `prisma-azure-sql` | Uses Prisma ORM against Azure SQL Database on JavaScript and TypeScript, inside the connector's real limits. |
| `provision-azure-sql-db` | Creates an Azure SQL Database and returns a connection string that actually works, covering the free offer and paid tiers, the firewall rule, and Microsoft Entra-only administration. |
| `provision-hyperscale` | Puts a real workload on the Hyperscale service tier of Azure SQL Database. |
| `rag-on-azure-sql` | Builds retrieval augmented generation end to end on Azure SQL Database. |
| `read-execution-plan` | Retrieves an Azure SQL Database execution plan, estimated or actual, and pulls out the small set of facts that explain slowness. |
| `restore-and-recover` | Recovers an Azure SQL Database after data loss, an accidental drop or a bad deployment, using point-in-time restore, geo-restore and long-term retention. |
| `rls-multi-tenant` | Builds tenant isolation on Azure SQL Database that a test can prove, with a row level security policy whose filter predicate and block predicate are written together, because a filter alone still accepts a cross-tenant write and hides the row from the app that made it. |
| `schema-migrations-safely` | Decides whether a schema change is safe to apply to a live Azure SQL Database, and rewrites the migration so it is. |
| `skill-feedback` | Turns a defect in a Microsoft SQL agent skill, plugin, or marketplace into a redacted, prefilled GitHub issue the user reviews and submits. |
| `sql-database-projects` | Builds and publishes a SQL database project against Azure SQL Database. |
| `sqlalchemy-azure-sql` | Uses SQLAlchemy correctly against Azure SQL Database, where the dialect appends an OUTPUT clause to INSERT statements and that single clause explains two failures agents never connect. |
| `sqlpackage-import-export` | Moves a whole Azure SQL Database as a portable file with SqlPackage, choosing between the Extract, Publish, Export and Import actions, stating what each one carries, and giving the command line for each. |
| `t-sql-correctness` | Writes T-SQL that returns the right answer on Azure SQL Database, and catches statements that return a wrong answer with no error. |
| `t-sql-json-and-openjson` | Queries and stores JSON on Azure SQL Database using the native json type, a JSON index, and OPENJSON with an explicit WITH schema, instead of the older nvarchar(max) plus JSON_VALUE pattern the training data is full of. |
| `t-sql-upserts-merge` | Writes an upsert for Azure SQL Database that is still correct when two sessions run it at the same moment, and refuses the MERGE shapes that lose rows. |
| `vector-search-azure-sql` | Stores and searches vectors natively in Azure SQL Database: the vector type, VECTOR_DISTANCE, the 1998 dimension ceiling, the DiskANN vector index, and the long list of places a vector column is refused. |

## Install

- Copilot CLI: `copilot plugin marketplace add microsoft/microsoft-sql`, then `copilot plugin install microsoft-sql-vscode@microsoft-sql`
- Claude Code: `/plugin marketplace add microsoft/microsoft-sql`, then `/plugin install microsoft-sql-vscode@microsoft-sql`
- VS Code: add the repository to `chat.plugins.marketplaces`, then install from the Extensions view (`@agentPlugins`)
- Codex: `codex plugin marketplace add microsoft/microsoft-sql --ref main`, then `codex plugin add microsoft-sql-vscode@microsoft-sql`
- Cursor and Grok Build: Cursor reads `.cursor-plugin/`; Grok Build reads the Claude Code descriptors
- Any Agent Skills client: copy `skills/<skill>/` wherever the client discovers `SKILL.md`
