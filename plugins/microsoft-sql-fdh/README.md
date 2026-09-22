# Microsoft SQL for Fabric Database Hub (`microsoft-sql-fdh`) 0.1.0

A skill curated for Fabric Database Hub estate observability through read-only, Entra-authenticated Fabric APIs: tenant-wide database inventory across Azure SQL, Arc SQL Server, Azure Database for PostgreSQL, Azure Cosmos DB and Fabric SQL; operational health; and authentication, auditing and customer-managed-key security posture. Draft maturity: local evaluation passed with findings on 2026-09-22; live Fabric qualification pending.

Portable [Agent Plugins 1.0](https://agent-plugins.org/specification) package with Claude Code,
Codex and Cursor descriptors. Built from `https://github.com/microsoft/azure-sql-skills`; edit the skills there, not here.

## Skills (1)

| Skill | Description |
| --- | --- |
| `databasehub-cli` | Use this skill when the user asks for tenant-wide Database Hub inventory, cross-engine SQL/PostgreSQL/Cosmos health, security posture, auditing or CMK warnings, or Fabric SQL catalog inventory through Entra-authenticated Fabric APIs. Do not use it for one-database SQL tuning or Warehouse/Lakehouse/Mirrored Database SQL. |

## Install

- Claude Code: `/plugin install microsoft-sql-fdh@microsoft-sql` after `/plugin marketplace add <this repository>`
- Copilot CLI: `copilot plugin install microsoft-sql-fdh@microsoft-sql` after `copilot plugin marketplace add <this repository>`, or `copilot --plugin-dir <path to this directory>`
- VS Code: add the repository to `chat.plugins.marketplaces`, then install from the Extensions view (`@agentPlugins`)
- Codex: the repository's `.agents/plugins/marketplace.json` indexes this plugin; skills can also be copied into `.agents/skills/`
- Cursor and Grok Build: Cursor reads `.cursor-plugin/`; Grok Build reads the Claude Code descriptors
- Any Agent Skills client: copy `skills/<skill>/` wherever the client discovers `SKILL.md`
