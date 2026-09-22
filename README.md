# Microsoft SQL agent skills

Microsoft SQL agent skill plugins for direct use, Visual Studio Code, SQL Server Management Studio, SQL Server to Azure migration, and Fabric Database Hub estate observability.

This repository is a generated distribution of agent plugins. Skill content is maintained in
`https://github.com/microsoft/azure-sql-skills`; do not edit skills here.

| Plugin | Version | Skills | Description |
| --- | --- | ---: | --- |
| `microsoft-sql` | 1.0.0 | 57 | The complete collection of fifty-seven skills for agents working directly with Azure SQL Database and the Azure SQL Database container: provisioning, application development, connecting from .NET, Python and TypeScript, schema design and migrations, bulk load, RAG and vector search, Data API Builder, Azure Functions, CI, security, diagnostics, and T-SQL correctness. |
| `microsoft-sql-fdh` | 0.1.0 | 1 | A skill curated for Fabric Database Hub estate observability through read-only, Entra-authenticated Fabric APIs: tenant-wide database inventory across Azure SQL, Arc SQL Server, Azure Database for PostgreSQL, Azure Cosmos DB and Fabric SQL; operational health; and authentication, auditing and customer-managed-key security posture. Draft maturity: local evaluation passed with findings on 2026-09-22; live Fabric qualification pending. |
| `microsoft-sql-migration` | 1.1.0 | 12 | Twelve skills curated for assessing, planning, executing and validating SQL Server to Azure migrations: recommend a migration path, generate a prerequisite plan, run or retrieve Azure Arc migration assessments, evaluate offline readiness, size an Azure SQL SKU from performance data, analyze readiness across an estate, migrate with backup/restore to SQL Server on Azure VM, BACPAC to Azure SQL Database, or Log Replay Service to Azure SQL Managed Instance, and validate data after migration. |
| `microsoft-sql-ssms` | 0.1.0 | 15 | Fifteen skills curated for database administration with SQL Server Management Studio: diagnosing slow queries, blocking and resource pressure, reading execution plans, capturing Extended Events, restoring after data loss, row-level security, passwordless access, provisioning, and bulk data movement. Application frameworks, serverless bindings, Data API Builder, and AI development skills are omitted. |
| `microsoft-sql-vscode` | 0.1.0 | 23 | Twenty-three skills curated for application work with the MSSQL extension in Visual Studio Code: connections and drivers, schema and ORMs, T-SQL, vector search and RAG, Azure Functions bindings, and database projects. Data API Builder skills are omitted to avoid conflicting with the extension's agent tools. |

## Install

| Client | How |
| --- | --- |
| Claude Code | `/plugin marketplace add <this repository>` then `/plugin install <plugin>@microsoft-sql` |
| Copilot CLI | `copilot plugin marketplace add <this repository>` then `copilot plugin install <plugin>@microsoft-sql` |
| VS Code (Copilot) | add this repository to `chat.plugins.marketplaces`, install from the Extensions view (`@agentPlugins`) |
| Codex | `.agents/plugins/marketplace.json` is read from the repository root; or copy `plugins/<plugin>/skills/*` into `.agents/skills/` |
| Cursor | Customize > From GitHub Repository (`.cursor-plugin/marketplace.json`), or copy skills into `.cursor/skills/` |
| Grok Build | reads the Claude Code marketplace and plugin descriptors unchanged |
