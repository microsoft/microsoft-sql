# Microsoft SQL migration

`microsoft-sql-migration` · Version 1.0.0

Plan and execute SQL Server migrations to Azure, including target selection, readiness assessment, prerequisite planning, SKU sizing, BACPAC, backup and restore, Log Replay Service, and post-migration validation.

This package follows the [Agent Plugins 1.0](https://agent-plugins.org/specification) format and
is published in [`microsoft/microsoft-sql`](https://github.com/microsoft/microsoft-sql).

## Included skills

| Skill | Description |
| --- | --- |
| `analyze-readiness-at-scale` | Use when analyzing migration assessment readiness at scale or showing an estate-wide migration assessment dashboard for Azure Arc SQL Server instances. |
| `evaluate-azure-migration-assessment` | Use when running or refreshing migration assessment for an Azure SQL Server instance and retrieving readiness and SKU results. |
| `evaluate-offline-migration-readiness` | Use when running migration readiness assessment for a local or on-premises SQL Server with az datamigration on Windows. |
| `generate-migration-prerequisite-plan` | Builds a sourced, scenario-specific prerequisite plan for a SQL Server to Azure migration path. |
| `get-migration-assessment` | Use when retrieving existing SQL Server migration assessment data from Azure Resource Graph with the required instance-level and database-level queries. |
| `recommend-migration-path` | Preliminary SQL Server to Azure migration disposition and recommended assessment path. |
| `recommend-sku-sizing` | Collect performance data and calculate Azure SQL SKU recommendations only after the source is explicitly confirmed local/on-premises. |
| `run-migration-assessment` | Route generic or unresolved SQL Server assessment, readiness, compatibility, cost, and SKU recommendation requests. |
| `sql-backup-restore-to-azure-sql-vm-migration` | Migrate a SQL Server 2008 through SQL Server 2025 source to a SQL Server 2025 target wherever it runs, including SQL Server on Azure VM, by creating a local full backup, uploading it to Azure Blob Storage with AzCopy and the operator's Microsoft Entra identity. |
| `sql-bacpac-to-azure-sql-db-migration` | Migrate one or all user databases from SQL Server to Azure SQL Database with an offline BACPAC workflow. |
| `sql-server-to-sql-mi-lrs-migration` | Migrate SQL Server databases to Azure SQL Managed Instance with Log Replay Service (LRS) using managed identity for Blob access. |
| `validate-post-migration-data` | Validate data and schema after migrating SQL Server to Azure SQL Database, Azure SQL Managed Instance, or SQL Server on Azure VM. |

## Install

- Copilot CLI: `copilot plugin marketplace add microsoft/microsoft-sql`, then `copilot plugin install microsoft-sql-migration@microsoft-sql`
- Claude Code: `/plugin marketplace add microsoft/microsoft-sql`, then `/plugin install microsoft-sql-migration@microsoft-sql`
- VS Code: add `microsoft/microsoft-sql` to `chat.plugins.marketplaces`, then install from **Chat: Open Customizations > Plugins** or the Extensions view (`@agentPlugins`)
- Codex: `codex plugin marketplace add microsoft/microsoft-sql --ref main`, then `codex plugin add microsoft-sql-migration@microsoft-sql`
- Cursor: `cursor-agent plugin marketplace add https://github.com/microsoft/microsoft-sql`, then run `cursor-agent` and install `microsoft-sql-migration` from `/plugin`
- Grok Build: `grok plugin marketplace add microsoft/microsoft-sql`, then `grok plugin install microsoft-sql-migration --trust`
- Other Agent Skills clients: copy `skills/<skill>/` only when the client has no plugin marketplace
