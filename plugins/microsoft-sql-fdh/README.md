# Microsoft SQL for Fabric Database Hub

`microsoft-sql-fdh` · Version 1.0.0

Explore database inventory, performance, and security posture across Fabric Database Hub using read-only, Microsoft Entra-authenticated APIs for Azure SQL, Arc-enabled SQL Server, Azure Database for PostgreSQL, Azure Cosmos DB, and Fabric SQL.

This package follows the [Agent Plugins 1.0](https://agent-plugins.org/specification) format and
is published in [`microsoft/microsoft-sql`](https://github.com/microsoft/microsoft-sql).

## Included skills

| Skill | Description |
| --- | --- |
| `databasehub-cli` | Use this skill when the user asks for tenant-wide Database Hub inventory, cross-engine SQL/PostgreSQL/Cosmos health, security posture, auditing or CMK warnings, or Fabric SQL catalog inventory through Entra-authenticated Fabric APIs. |

## Example prompts

The plugin handles read-only questions about the database estate visible to the signed-in
Microsoft Entra user. It follows Fabric Database Hub pagination and reports missing permissions,
incomplete metric coverage, and partial results instead of treating missing data as healthy.

### Check performance

| Prompt | What the plugin does |
| --- | --- |
| How are my databases performing? | Summarizes Microsoft SQL and PostgreSQL CPU, storage, and memory health separately, then reports Cosmos DB availability and normalized RU consumption. |
| Are there any performance issues I should know about? | Identifies high-utilization resources and Database Hub performance findings across supported database families, including the timeframe and metric coverage. |
| Which databases have the highest memory or storage utilization? | Uses Database Hub usage details to rank affected Microsoft SQL or PostgreSQL resources without running queries against the databases. |

### Review security

| Prompt | What the plugin does |
| --- | --- |
| How secure are my databases? | Summarizes security findings across Microsoft SQL, PostgreSQL, and Cosmos DB, including network exposure and authentication posture. |
| What should I fix first to improve security? | Prioritizes returned security issues, then compares authentication, auditing, and customer-managed-key coverage. It recommends actions but does not change resources. |
| What are the biggest security risks in my environment? | Ranks findings by affected-resource count and potential impact while preserving the scope of each denominator. |

### Explore inventory

| Prompt | What the plugin does |
| --- | --- |
| Show my database estate by engine and subscription. | Pages through the mixed Database Hub inventory and groups resources by database family and subscription. |
| How many Azure SQL, PostgreSQL, Cosmos DB, and Arc SQL resources do I have? | Uses tenant-wide count and inventory routes and clearly labels populations that use different denominators. |
| List the Fabric SQL databases in the Sales workspace. | Searches the Fabric SQL catalog and resolves workspace or item names without guessing IDs. Fabric SQL support in this plugin is inventory-only. |

Database Hub does not expose Query Store, active sessions, query text, execution plans, blocking,
or database-level DMVs through this plugin. Questions such as "Why is this query slow?" or "Show
long-running queries in this database" require direct database access and a SQL diagnostics
plugin.

## Install

- Copilot CLI: `copilot plugin marketplace add microsoft/microsoft-sql`, then `copilot plugin install microsoft-sql-fdh@microsoft-sql`
- Claude Code: `/plugin marketplace add microsoft/microsoft-sql`, then `/plugin install microsoft-sql-fdh@microsoft-sql`
- VS Code: add `microsoft/microsoft-sql` to `chat.plugins.marketplaces`, then install from **Chat: Open Customizations > Plugins** or the Extensions view (`@agentPlugins`)
- Codex: `codex plugin marketplace add microsoft/microsoft-sql --ref main`, then `codex plugin add microsoft-sql-fdh@microsoft-sql`
- Cursor: `cursor-agent plugin marketplace add https://github.com/microsoft/microsoft-sql`, then run `cursor-agent` and install `microsoft-sql-fdh` from `/plugin`
- Grok Build: `grok plugin marketplace add microsoft/microsoft-sql`, then `grok plugin install microsoft-sql-fdh --trust`
- Other Agent Skills clients: copy `skills/<skill>/` only when the client has no plugin marketplace
