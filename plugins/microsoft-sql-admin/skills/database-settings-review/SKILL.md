---
name: database-settings-review
description: "Use when the user asks to review a database's options: recovery model, AUTO_CLOSE, RCSI, compatibility level, Query Store, scoped configurations. For Azure SQL service tier, use `database-config-azuresql`."
user-invocable: true
argument-hint: "[DatabaseName]"
---

# Database Settings Review

Use this skill for a comprehensive configuration and feature review of the current database.

## Safety

- Execute read-only T-SQL only.
- Never change a database option, scoped configuration, server configuration, file, feature, or
  compatibility level.
- Treat inaccessible or unsupported metadata as `Unavailable`.
- Separate observed facts from recommendations.
- Explain benefits, risks, and workload tradeoffs before recommending any change.

## Workflow

1. Connect to the requested database. If none is named, retain the current database.
2. Load and execute
   [references/platform-and-database-properties.md](references/platform-and-database-properties.md).
   Stop when the platform is unsupported.
3. Load and execute
   [references/database-scoped-configurations.md](references/database-scoped-configurations.md).
   Evaluate every returned row, not only the highlighted settings.
4. Load and execute
   [references/query-store-and-automatic-tuning.md](references/query-store-and-automatic-tuning.md).
5. Load and execute
   [references/files-and-growth.md](references/files-and-growth.md).
6. Load and execute
   [references/feature-and-security-inventory.md](references/feature-and-security-inventory.md).
7. For SQL Server and Azure SQL Managed Instance only, load and execute
   [references/server-configurations.md](references/server-configurations.md). Mark this section
   `Unavailable` on Azure SQL Database.
8. Classify evidence using
   [references/findings-and-recommendations.md](references/findings-and-recommendations.md).
9. Produce the final response from
   [references/report-template.md](references/report-template.md), preserving all twelve sections.

## Required tool behavior

- Use the read-query execution tool exposed by the connected SQL provider. Prefer the SQL Tools MCP
  server that ships with the `microsoft-sql-admin` plugin (`mssql_execute_query`); otherwise another
  SQL tool the host provides, or
  [`sqlcmd`](https://learn.microsoft.com/sql/tools/sqlcmd/sqlcmd-utility) from a terminal. If the
  SQL Tools MCP server is not connected or lists no connections, follow the `sql-tools-mcp-setup`
  skill, which asks before installing or configuring anything.
- Execute queries exactly from the references after applying their platform and metadata guards.
- Do not replace a failed query with an unguarded approximation.
- Preserve permission failures as `Unavailable - insufficient permission`.
