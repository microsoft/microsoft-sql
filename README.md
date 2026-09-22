# SQL agent skills

Agent skill plugins for Azure SQL Database and SQL Server to Azure migration.

This repository is a generated distribution of agent plugins. Skill content is maintained in
`https://github.com/microsoft/azure-sql-skills`; do not edit skills here.

| Plugin | Version | Skills | Description |
| --- | --- | ---: | --- |
| `azure-sql` | 1.0.0 | 57 | Fifty-seven skills for building on Azure SQL Database and the Azure SQL Database container: provisioning, connecting from .NET, Python and TypeScript, schema design and migrations, bulk load, RAG and vector search, Data API Builder, Azure Functions, CI, security, diagnostics, and T-SQL correctness. |
| `sql-migration` | 1.1.0 | 12 | Twelve skills for assessing, planning, executing and validating SQL Server to Azure migrations: recommend a migration path, generate a prerequisite plan, run or retrieve Azure Arc migration assessments, evaluate offline readiness, size an Azure SQL SKU from performance data, analyze readiness across an estate, migrate with backup/restore to SQL Server on Azure VM, BACPAC to Azure SQL Database, or Log Replay Service to Azure SQL Managed Instance, and validate data after migration. |

## Install

| Client | How |
| --- | --- |
| Claude Code | `/plugin marketplace add <this repository>` then `/plugin install <plugin>@sql-agent-skills` |
| Copilot CLI | `copilot plugin marketplace add <this repository>` then `copilot plugin install <plugin>@sql-agent-skills` |
| VS Code (Copilot) | add this repository to `chat.plugins.marketplaces`, install from the Extensions view (`@agentPlugins`) |
| Codex | `.agents/plugins/marketplace.json` is read from the repository root; or copy `plugins/<plugin>/skills/*` into `.agents/skills/` |
| Cursor | Customize > From GitHub Repository (`.cursor-plugin/marketplace.json`), or copy skills into `.cursor/skills/` |
| Grok Build | reads the Claude Code marketplace and plugin descriptors unchanged |
