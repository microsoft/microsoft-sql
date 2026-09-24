# Microsoft SQL for Fabric Database Hub (`microsoft-sql-fdh`) 0.1.0

A skill curated for Fabric Database Hub estate observability through read-only, Entra-authenticated Fabric APIs: tenant-wide database inventory across Azure SQL, Arc SQL Server, Azure Database for PostgreSQL, Azure Cosmos DB and Fabric SQL; operational health; and authentication, auditing and customer-managed-key security posture. Draft maturity: local evaluation passed with findings on 2026-09-22; live Fabric qualification pending.

Portable [Agent Plugins 1.0](https://agent-plugins.org/specification) package with Claude Code,
Codex and Cursor descriptors. Published by
[`microsoft/microsoft-sql`](https://github.com/microsoft/microsoft-sql); bundled skill files are
generated artifacts.

## Skills (1)

| Skill | Description |
| --- | --- |
| `databasehub-cli` | Use this skill when the user asks for tenant-wide Database Hub inventory, cross-engine SQL/PostgreSQL/Cosmos health, security posture, auditing or CMK warnings, or Fabric SQL catalog inventory through Entra-authenticated Fabric APIs. Do not use it for one-database SQL tuning or Warehouse/Lakehouse/Mirrored Database SQL. |

## Example prompts

The plugin is designed for read-only questions about the database estate visible to the signed-in Microsoft Entra user. It queries the Fabric Database Hub APIs, follows required pagination, and reports missing permissions, incomplete metric coverage, or partial results instead of treating missing data as healthy.

### Check performance

| Prompt | What the plugin does |
| --- | --- |
| How are my databases performing? | Summarizes Microsoft SQL and PostgreSQL CPU, storage, and memory health separately, then reports Cosmos DB availability and normalized RU consumption. |
| Are there any performance issues I should know about? | Identifies high-utilization resources and Database Hub performance findings across the supported database families, including the timeframe and metric coverage. |
| Which databases have the highest memory or storage utilization? | Uses Database Hub usage details to rank affected Microsoft SQL or PostgreSQL resources without running queries against the databases. |

### Review security

| Prompt | What the plugin does |
| --- | --- |
| How secure are my databases? | Summarizes security findings across Microsoft SQL, PostgreSQL, and Cosmos DB, including network exposure and authentication posture. |
| What should I fix first to improve security? | Prioritizes returned security issues before suggestions and compares authentication, auditing, and customer-managed-key coverage. It recommends actions but does not remediate resources. |
| What are the biggest security risks in my environment? | Ranks findings by affected-resource count and blast radius while preserving the scope of each denominator. |

### Explore inventory

| Prompt | What the plugin does |
| --- | --- |
| Show my database estate by engine and subscription. | Pages the mixed Database Hub inventory and groups resources by database family and subscription. |
| How many Azure SQL, PostgreSQL, Cosmos DB, and Arc SQL resources do I have? | Uses tenant-wide count and inventory routes and clearly labels populations that use different denominators. |
| List the Fabric SQL databases in the Sales workspace. | Searches the Fabric SQL catalog and resolves workspace or item names without guessing IDs. Fabric SQL support in this plugin is inventory-only. |

Database Hub does not expose Query Store, active sessions, query text, execution plans, blocking, or database-level DMVs through this plugin. Requests such as "Why is this query slow?" or "Show long-running queries in this database" require an item-level SQL diagnostic capability and direct database access.

## Install

- Claude Code: `/plugin install microsoft-sql-fdh@microsoft-sql` after `/plugin marketplace add <this repository>`
- Copilot CLI: `copilot plugin install microsoft-sql-fdh@microsoft-sql` after `copilot plugin marketplace add <this repository>`, or `copilot --plugin-dir <path to this directory>`
- VS Code: add the repository to `chat.plugins.marketplaces`, then install from the Extensions view (`@agentPlugins`)
- Codex: the repository's `.agents/plugins/marketplace.json` indexes this plugin; skills can also be copied into `.agents/skills/`
- Cursor and Grok Build: Cursor reads `.cursor-plugin/`; Grok Build reads the Claude Code descriptors
- Any Agent Skills client: copy `skills/<skill>/` wherever the client discovers `SKILL.md`
