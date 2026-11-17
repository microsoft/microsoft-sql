# Microsoft SQL administration

`microsoft-sql-admin` · Version 1.0.0

Diagnose and administer SQL Server, Azure SQL Database, Azure SQL Managed Instance, and Fabric SQL databases, including performance and wait analysis, Query Store and execution plans, blocking and deadlocks, backup and recovery, high availability and disaster recovery, security, schema health, and SQL Server Agent jobs.

This package follows the [Agent Plugins 1.0](https://agent-plugins.org/specification) format and
is published in [`microsoft/microsoft-sql`](https://github.com/microsoft/microsoft-sql).

## Included skills

| Skill | Description |
| --- | --- |
| `active-connections` | Use when the user asks who is connected, which sessions are idle or hold the oldest open transaction, or how connections split by login or app. |
| `always-encrypted-columns` | Use when the user asks which plaintext columns can or should use Always Encrypted, or why a column is disqualified. |
| `authentication-diagnostics` | Use when a login fails (18456, 'Login failed for user'), a user can't open a database, a permission is denied, or an Entra or managed identity login fails. |
| `backup-history-azuresql` | Use when the user asks for backup history, the latest backups or backup retention on Azure SQL Database or Fabric SQL Database. |
| `backup-strategy-sqlserver` | Use when the user asks to review or design a SQL Server or Managed Instance backup strategy, or whether the recovery model and backup schedule meet an RPO. |
| `blocking-root-cause-analysis` | Use when the user asks what caused blocking that already ended (yesterday's incident, intermittent lock waits) or who is behind a supplied blocking chain. |
| `check-live-blocking` | Use when queries hang right now: who is blocking, the head blocker, why a blocking DMV looks empty. |
| `code-analysis` | Use when the user asks to review, fix, explain or refactor T-SQL or a stored procedure without running it, incl. injection and SARGability. |
| `connectivity-troubleshoot` | Use when a client can't connect or gets a connection error (timeout, 53/10060/10061, SQLSTATE 08001, TLS, firewall 'IP not allowed', 4060). |
| `create-xe-session` | Use when the user wants an Extended Events session to capture slow queries, deadlocks or blocking over hours or days, or an XE ring buffer stays empty. |
| `database-config-azuresql` | Use when the user asks to review an Azure SQL Database's configuration. |
| `database-settings-review` | Use when the user asks to review a database's options: recovery model, AUTO_CLOSE, RCSI, compatibility level, Query Store, scoped configurations. |
| `deadlock-analysis` | Use when the user asks about deadlocks or deadlock history on SQL Server or Managed Instance, or to explain a supplied deadlock graph or XML. |
| `deadlock-analysis-azuresql` | Use when the user asks about deadlocks, deadlock history or prevention on Azure SQL Database or Fabric SQL Database. |
| `geo-dr-assessment-health-check` | Use when the user asks whether geo-replication or a failover group is healthy and ready for a planned failover (GO/NO_GO), or what the geo-DR RPO/RTO is. |
| `ha-assessment-health-check` | Use when the user wants a proactive Always On availability group health check before an audit, go-live or change. |
| `health-audit-sqlserver` | Use when the user asks for a health audit of a SQL Server or Managed Instance (not Azure SQL Database). |
| `improve-query-performance` | Use when the user asks to optimize, tune, speed up or improve a specific SQL query ('make this faster'), with or without a plan. |
| `investigate-geo-dr-issues` | Use when a geo-secondary lags behind the primary right now, a geo-replication link is suspended, or a failover group fails over unexpectedly. |
| `investigate-ha-issues` | Use when an availability group has sync or failover problems. |
| `investigate-sql-cpu-pressure` | Use when CPU is high on SQL Server or Azure SQL (alerts, throttling, SOS_SCHEDULER_YIELD waits) and the user wants the queries responsible. |
| `investigate-sql-data-io-pressure` | Use when data-file reads are slow or heavy: PAGEIOLATCH waits, high read latency, many physical reads, Azure SQL data IO throttling. |
| `investigate-sql-log-io-pressure` | Use when commits are slow or log writes lag: WRITELOG waits, high log write percent, log throughput throttling, too many VLFs. |
| `investigate-sql-memory-issues` | Use when queries wait on memory grants (RESOURCE_SEMAPHORE), spill to tempdb, hit out-of-memory errors (701, 802, 8645), or PLE drops. |
| `investigate-statistics-issues` | Use when row estimates are far from actual rows, statistics may be stale, or the user asks which to update or if auto-update keeps up. |
| `ledger-tables` | Use when the user asks about ledger tables: whether ledger fits a tamper-evidence need, creating updatable or append-only ones, or listing them and their history. |
| `missing-index-analysis` | Use when the user asks which indexes are missing, whether a table needs one, or whether index suggestions are worth creating. |
| `partitioned-tables` | Use when the user asks about partitioned tables: skew or hot partitions, boundaries or missing future partitions, per-partition fragmentation, index alignment, or partition elimination. |
| `plan-analysis` | Use when the user supplies an execution plan (showplan XML, .sqlplan) or asks to explain or check one. |
| `plan-cache-analysis` | Use when the user asks about plan cache bloat, single-use or ad hoc plans, poor plan reuse, SET option pollution or parameter sniffing suspects. |
| `plan-cache-qds-bridge` | Use when the user needs one query's cached plan and Query Store history, by text, query_hash, query_id or plan handle, including a query gone from cache. |
| `query-hint-tuning` | Use when the user wants to try query hints on a slow SELECT: compare join, parallelism or cardinality estimation hints by estimated cost or measured runtime. |
| `query-rewrite` | Use when the user explicitly asks to rewrite or restructure a SQL query or predicate, e.g. make a WHERE clause SARGable, keeping results and NULL semantics. |
| `query-store-investigation` | Use when the user asks for top or regressed queries in Query Store. |
| `query-store-volatile-historical-slow-queries-comparison` | Use when queries have erratic durations in Query Store, the user wants one query_id's timeline, or suspects parameter sniffing or failing forced plans. |
| `resource-usage-sqlserver` | Use when many queries time out under load, or SQL Server or Azure SQL is slow overall and it's unclear whether CPU, memory, IO, TempDB or disk is the cause. |
| `schema-design-guidance` | Use when the user asks to design or review tables or a proposed schema. |
| `slow-query-investigation` | Use when one specific query got slow, changed plans, or swings from seconds to minutes with the same parameters. |
| `sql-admin-analyze-readiness-at-scale` | Use only when the user asks for estate-wide migration readiness across many Azure Arc SQL Server instances. |
| `sql-admin-evaluate-azure-migration-assessment` | Use when the user wants to run, rerun or refresh an Azure Arc SQL Server migration assessment for fresh readiness and SKU results. |
| `sql-admin-get-migration-assessment` | Use when the user asks about existing Azure Arc SQL Server migration assessment results (readiness, SKUs, costs), including supplied JSON. |
| `sql-agent-job-failure-investigator` | Use when a SQL Server Agent job failed, was canceled, keeps retrying, is stuck running or missed its schedule, and the user wants the failing step and error. |
| `sql-tools-mcp-setup` | Use when the SQL Tools MCP server from the microsoft-sql-admin plugin must be set up, enabled, connected or repaired. |
| `table-access-analysis` | Use when the user asks which tables are most read, written or scanned, which are unused, or whether anything still touches a table. |
| `table-health-check` | Use when the user asks about table corruption, consistency errors, suspect pages, repair, or structural issues. |
| `top-queries-noqds` | Use when the user wants top CPU or most expensive queries, or queries with several cached plans, and Query Store is off or unavailable (DMVs only). |
| `wait-category-analysis` | Use when the user asks why queries are slow in terms of waits. |

## Requirements

These skills diagnose a live database, so the agent needs a way to connect to SQL Server or
Azure SQL and run T-SQL. The plugin bundles the configuration of its companion, the
**SQL Tools MCP server** (the NuGet package `Microsoft.SqlServer.SQLtools.MCPserver`): hosts that
support plugin MCP servers start it with `dnx`, which needs the
[.NET SDK 10 or later](https://dotnet.microsoft.com/download/dotnet/10.0) and downloads the pinned
version from NuGet the first time it runs. Besides read-only T-SQL execution it brings
execution-plan analysis, hint and rewrite comparison, syntax validation and schema exploration,
and the skills prefer those tools when they are connected.

The server reads the `CONNECTION_STRING` environment variable in its own process; the plugin ships
no server connection or credentials. Set it in the host's MCP server environment, or in the shell
that starts the host when that host forwards it. Some hosts filter inherited variables, so check
`mssql_list_database_connections` after setup. The `sql-tools-mcp-setup` skill provides host-specific
instructions. When the server is not
connected, the skills say so, offer to set it up, and ask before installing software or changing
configuration. Until then they use the SQL tool your host already provides (for example the SQL
tools in GitHub Copilot for SQL Server Management Studio or another MSSQL MCP server) or run
[`sqlcmd`](https://learn.microsoft.com/sql/tools/sqlcmd/sqlcmd-utility) from a terminal, and when
no SQL tool is available they give you the T-SQL to run and interpret the results you paste back.

The server sends telemetry to Microsoft by default. To turn it off, set
`SQLTOOLS__TELEMETRYENABLED=false` for the server process, in the same place as `CONNECTION_STRING`.

Hosts ask for your approval before they run one of the server's tools. For scripted or
non-interactive use, allow the `sql-tools` server's tools in the host's own permission settings,
for example `default_tools_approval_mode = "approve"` under `[mcp_servers.sql-tools]` in Codex's
`config.toml`, or `"permissions": {"allow": ["Mcp(sql-tools:*)"]}` in `.cursor/cli.json` for
Cursor's command-line agent.

Install `microsoft-sql` alongside this plugin for application development. That plugin does not
declare a second MCP server; its skills can use the administration plugin's connected server.

Most workflows read catalog views, dynamic management views, Query Store, and Extended Events
data. Some can make changes when you ask, such as creating an Extended Events session or ledger
table, or running a query repeatedly to compare hints. Review generated scripts and run them with
an appropriately privileged login.

The agent can choose any of these skills on its own when a request matches its description. You
can also run one explicitly by name, for example `/health-audit-sqlserver`.

## Example prompts

| Prompt | What the plugin does |
| --- | --- |
| Why are my queries slow? | Analyzes wait categories to show whether locking, CPU, IO, memory, or network waits dominate. |
| This report query got slower last week. | Uses Query Store to find regressed plans and compare runtime statistics. |
| Who is blocking whom? | Shows live head blockers, blocking chains, and their impact. |
| Summarize recent deadlocks. | Reads deadlock reports from Extended Events and explains the victims and resources. |
| Review my backup strategy. | Checks recovery models, backup history, Agent jobs, and maintenance plans against recovery goals. |
| Is my availability group healthy? | Assesses replica synchronization, failover readiness, and RPO/RTO exposure. |
| Why did my SQL Agent job fail last night? | Correlates job history, failed steps, schedules, ownership, and retries to find the cause. |

The three migration-assessment skills use an `sql-admin-` prefix so they do not collide with the
separate `microsoft-sql-migration` workflow skills. Install `microsoft-sql-migration` for
end-to-end SQL Server to Azure migration.

## SQL Tools MCP server

This plugin configures `Microsoft.SqlServer.SQLtools.MCPserver@1.0.0` through
`mcp.json` (and `.mcp.json` for Claude-compatible hosts). The host downloads the package
separately; it is not included in this repository. Review its
[Microsoft software license terms](https://www.nuget.org/packages/Microsoft.SqlServer.SQLtools.MCPserver/1.0.0/License)
before using it. The repository's MIT license applies to the plugin content, not the MCP package.

The plugin enables External skill delivery and disables preview features. The installed skill
files provide the guidance; the server supplies SQL and plan-analysis tools without duplicating
the skills as MCP resources or tools.

## Install

- Copilot CLI: `copilot plugin marketplace add microsoft/microsoft-sql`, then `copilot plugin install microsoft-sql-admin@microsoft-sql`
- Claude Code: `/plugin marketplace add microsoft/microsoft-sql`, then `/plugin install microsoft-sql-admin@microsoft-sql`
- VS Code: add `microsoft/microsoft-sql` to `chat.plugins.marketplaces`, then install from **Chat: Open Customizations** using **Browse** or **Plugins > Browse Marketplace**
- Codex: `codex plugin marketplace add microsoft/microsoft-sql --ref main`, then `codex plugin add microsoft-sql-admin@microsoft-sql`
- Cursor: `cursor-agent plugin marketplace add https://github.com/microsoft/microsoft-sql`, then run `cursor-agent` and install `microsoft-sql-admin` from `/plugin`
- Grok Build: `grok plugin marketplace add microsoft/microsoft-sql`, then install from the Marketplace tab in `/plugins`; for a direct CLI install after review, use `grok plugin install 'microsoft/microsoft-sql#plugins/microsoft-sql-admin' --trust`
- Other Agent Skills clients: copy `skills/<skill>/` only when the client has no plugin marketplace
