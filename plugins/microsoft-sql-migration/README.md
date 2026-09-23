# Microsoft SQL migration (`microsoft-sql-migration`) 1.1.1

Twelve skills curated for assessing, planning, executing and validating SQL Server to Azure migrations: recommend a migration path, generate a prerequisite plan, run or retrieve Azure Arc migration assessments, evaluate offline readiness, size an Azure SQL SKU from performance data, analyze readiness across an estate, migrate with backup/restore to SQL Server on Azure VM, BACPAC to Azure SQL Database, or Log Replay Service to Azure SQL Managed Instance, and validate data after migration.

Portable [Agent Plugins 1.0](https://agent-plugins.org/specification) package with Claude Code,
Codex and Cursor descriptors. Published by
[`microsoft/microsoft-sql`](https://github.com/microsoft/microsoft-sql); bundled skill files are
generated artifacts.

## Skills (12)

| Skill | Description |
| --- | --- |
| `analyze-readiness-at-scale` | Analyze migration assessment readiness at scale or show an estate-wide migration assessment dashboard for Azure Arc SQL Server instances. |
| `evaluate-azure-migration-assessment` | Run or refresh migration assessment for an Azure SQL Server instance and retrieve readiness and SKU results. |
| `evaluate-offline-migration-readiness` | Run migration readiness assessment for a local or on-premises SQL Server using az datamigration. Windows-only. |
| `generate-migration-prerequisite-plan` | Builds a sourced, scenario-specific prerequisite plan for a SQL Server to Azure migration path. Consumes the structured output of recommend-migration-path or works standalone from a known target and method, asks only unresolved path-specific questions, and returns a readiness summary plus detailed prerequisites as polished Markdown, structured JSON, or both. Trigger when the user asks what must be ready before executing a recommended SQL migration, wants a migration prerequisites checklist, or asks for a partner-ready readiness plan. |
| `get-migration-assessment` | Retrieve existing SQL Server migration assessment data from Azure Resource Graph using required instance-level and database-level queries. |
| `recommend-migration-path` | Preliminary SQL Server to Azure migration disposition and recommended assessment path. Runs a short guided interview, then applies a source-verified knowledge base to pre-select candidate targets (SQL VM, AVS, SQL MI, SQL DB, Fabric SQL DB, Arc SQL MI, container or Arc in-place), migration methods (MI Link, LRS, backup/restore, DAG/AG, modern DMS, transactional replication, BACPAC, Fabric Migration Assistant), blockers, evidence gaps, cost levers and Microsoft program fit. Trigger when the user wants to migrate or modernize SQL Server to Azure, asks for the best or recommended migration path, target or tool, or says 'migrer SQL Server', 'migrate SQL Server' or 'SQL to Azure'. |
| `recommend-sku-sizing` | Collect performance data and calculate Azure SQL SKU recommendations only after the source is explicitly confirmed local/on-premises. Never use for a generic SKU request or bare server name; route unresolved requests through run-migration-assessment. |
| `run-migration-assessment` | Route generic or unresolved SQL Server assessment, readiness, compatibility, cost, and SKU recommendation requests. Use for bare server names or whenever Azure versus local/on-premises is not explicit; ask which source applies, then delegate. |
| `sql-backup-restore-to-azure-sql-vm-migration` | Migrate a SQL Server 2008 through SQL Server 2025 source to a SQL Server 2025 target wherever it runs, including SQL Server on Azure VM, by creating a local full backup, uploading it to Azure Blob Storage with AzCopy and the operator's Microsoft Entra identity, and restoring from URL with the target SQL Server managed identity. Sources newer than SQL Server 2025 are blocked because target restore compatibility has not been validated. Use for SQL-to-SQL, local-backup, AzCopy, managed-identity, Azure SQL VM, or SQL Server 2025 restore migrations. |
| `sql-bacpac-to-azure-sql-db-migration` | Migrate one or all user databases from SQL Server to Azure SQL Database with an offline BACPAC workflow. Use for BACPAC, SqlPackage export/import, bulk database migration, or offline Azure SQL Database migration requests. |
| `sql-server-to-sql-mi-lrs-migration` | Migrate SQL Server databases to Azure SQL Managed Instance with Log Replay Service (LRS) using managed identity for Blob access. Use for SQL Server to SQL MI, LRS, log replay, continuous restore, or low-downtime backup-chain migrations. |
| `validate-post-migration-data` | Validate data and schema after migrating SQL Server to Azure SQL Database, Azure SQL Managed Instance, or SQL Server on Azure VM. Use after migration, restore, BACPAC import, LRS completion, cutover validation, row-count comparison, or source-target reconciliation. |

## Install

- Claude Code: `/plugin install microsoft-sql-migration@microsoft-sql` after `/plugin marketplace add <this repository>`
- Copilot CLI: `copilot plugin install microsoft-sql-migration@microsoft-sql` after `copilot plugin marketplace add <this repository>`, or `copilot --plugin-dir <path to this directory>`
- VS Code: add the repository to `chat.plugins.marketplaces`, then install from the Extensions view (`@agentPlugins`)
- Codex: the repository's `.agents/plugins/marketplace.json` indexes this plugin; skills can also be copied into `.agents/skills/`
- Cursor and Grok Build: Cursor reads `.cursor-plugin/`; Grok Build reads the Claude Code descriptors
- Any Agent Skills client: copy `skills/<skill>/` wherever the client discovers `SKILL.md`
