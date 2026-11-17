---
name: active-connections
description: "Use when the user asks who is connected, which sessions are idle or hold the oldest open transaction, or how connections split by login or app. If a client can't connect, use `connectivity-troubleshoot`."
user-invocable: true
---
# Active Connections Analysis

## Purpose

Use this skill for active connections, current session analysis, or session-level connectivity diagnostics. It provides:
1. Platform detection and connection summary
2. Active user connections by database, login, and program
3. Idle session analysis (sleeping sessions exceeding thresholds)
4. Connection pooling behavior patterns
5. Client IP / hostname distribution and connection properties
6. Sessions with open transactions
7. MARS, connection policy (Proxy/Redirect), and client connection diagnostics
8. Database state and availability check
9. Connection rate analysis (spike detection)
10. Database principal and contained user validation

For clients that cannot connect at all, use the client-side troubleshooting guidance in `references/report-template.md`.

## Required tools

- A read-only SQL query tool connected to the target server and database. Prefer, in order: the SQL
  Tools MCP server that ships with the `microsoft-sql-admin` plugin (`mssql_list_database_connections`,
  `mssql_connect_database`, then `mssql_execute_query`); any other SQL tool the agent host provides for
  running T-SQL and reading result sets;
  [`sqlcmd`](https://learn.microsoft.com/sql/tools/sqlcmd/sqlcmd-utility) from a terminal. If the SQL
  Tools MCP server is not connected or lists no connections, follow the `sql-tools-mcp-setup` skill,
  which asks before installing or configuring anything. If no SQL tool can be made available, give the
  user the T-SQL to run and ask for the results.
- Least privilege: connect that tool with a diagnostic login that cannot write, for example one that
  holds only `VIEW SERVER PERFORMANCE STATE` (`VIEW SERVER STATE` before SQL Server 2022) or, on Azure
  SQL Database, `VIEW DATABASE PERFORMANCE STATE` or `##MS_ServerStateReader##`, plus any other read
  permission these queries need. A tool is only as read-only as the login it connects with.

## Prerequisites

- Connected to the target database. Confirm which server and database you are connected to (e.g. with
  `SELECT @@SERVERNAME, DB_NAME(), SUSER_SNAME(), SERVERPROPERTY('EngineEdition')`); connect first if not already connected.

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| TopN | 20 | Number of top results to return in each step |
| IdleThresholdMinutes | 30 | Minutes of inactivity before a session is flagged as idle |
| OpenTxnThresholdSeconds | 300 | Seconds an open transaction must be held to be flagged |

## Remediation Safety

- All diagnostic queries in this skill are read-only.
- State-changing commands in the references (`KILL <session_id>`, `ALTER DATABASE ... SET MULTI_USER`,
  `ALTER USER ... WITH LOGIN`, and `DROP USER`) are **recommendations only**.
- Never run any of them without the user's explicit confirmation for that specific command. A
  request to investigate, diagnose, or "fix" the problem is not that confirmation.
- Before asking, explain the impact: `KILL` rolls back the session's open transaction and cannot be
  undone, and changing `user_access` affects every connection to the database.

## Investigation Workflow

Execute the Step 1-10 queries from `references/queries.md` in order with the SQL query tool.
That reference contains the exact SQL, interpretation guidance, and "What to do" tables for each step.

### Step 1: Platform Detection
Run the Step 1 query from `references/queries.md`.
Use it to confirm engine type, baseline session counts, and whether the target is an unsupported platform (Synapse editions 6/11) before continuing. Fabric SQL Database (edition 12) is supported.

### Step 2: Active User Connections by Database
Run the Step 2 query from `references/queries.md`.
Use it to identify which database, login, and program combinations dominate the current connection footprint.

### Step 3: Idle Session Analysis
Run the Step 3 query from `references/queries.md`.
Use it to find long-idle sleeping sessions, especially any session that is idle while still holding open transactions.

### Step 4: Connection Pooling Behavior Patterns
Run the Step 4 query from `references/queries.md`.
Use it to spot oversized pools, pool exhaustion, recent pool resets, and pooled connections that still carry open transactions.

### Step 5: Client IP / Hostname Distribution and Connection Properties
Run the Step 5 query from `references/queries.md`.
Use it to identify dominant clients plus transport, encryption, authentication, and driver-version signals for each connection source.

### Step 6: Sessions with Open Transactions
Run the Step 6 query from `references/queries.md`.
Use it to isolate sessions with active transactions, prioritize sleeping sessions first, and measure duration plus log usage impact.

### Step 7: MARS, Connection Policy, and Client Connection Diagnostics
Run the Step 7 query from `references/queries.md`.
Use it to detect active MARS usage, MARS risk patterns, Azure SQL Proxy vs Redirect routing, and unencrypted connections.

### Step 8: Database State and Availability Check
Run the Step 8 query from `references/queries.md`.
Use it to verify the current database is online, writable when expected, and not restricted by state or access mode.

### Step 9: Connection Rate Analysis / Spike Detection
Run the Step 9 query from `references/queries.md`.
Use it to identify connection storms, rapid pool recycling, or sustained reconnection patterns over recent time buckets.

### Step 10: Database Principal and Contained User Validation
Run the Step 10 query from `references/queries.md`.
Use it to review principal types, contained users, Entra identities, and server-mapped users relevant to current connectivity.

## Report & Decision Tree

After completing all ten steps, populate the report template in `references/report-template.md`.
Use the same reference for the root-cause decision tree and prioritized next-step recommendations.

## Client-Side Connectivity Troubleshooting

If a client cannot connect at all, the failure happens before SQL Server creates a visible session, so DMVs will not show it.
Use the client-side checklist in `references/report-template.md` for DNS, ports, TLS, firewall, authentication, connection-string, and Azure SQL Connectivity Checker guidance.
