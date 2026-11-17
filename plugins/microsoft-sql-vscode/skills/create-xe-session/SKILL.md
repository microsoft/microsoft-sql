---
name: create-xe-session
description: "Use when the user wants an Extended Events session to capture slow queries, deadlocks or blocking over hours or days, or an XE ring buffer stays empty. To explain a captured deadlock, use read-only SQL Server deadlock graph analysis using the host SQL tools."
argument-hint: "[SessionName] [Purpose] [TemplateSessionName]"
user-invocable: true
---

# Create and Set Up an Extended Events Session

## Scope

- Use this skill when the needed capture is not set up yet, including intermittent deadlocks or slow queries that need durable evidence over hours or days.
- To interpret a deadlock graph that was already captured, use `deadlock-analysis-azuresql` on Azure SQL Database or read-only SQL Server deadlock graph analysis using the host SQL tools on SQL Server and Managed Instance.

## Azure SQL Database specialization

For Azure SQL Database (EngineEdition 5), read [Azure-specific guidance](references/azure-sql/guidance.md) before choosing diagnostic queries. It preserves the service-specific permissions, capture limitations and error interpretation. Keep this skill's scope and authorization rules; the reference is not a second workflow to run unconditionally.

### Prove the capture, not just session creation

For `database_xml_deadlock_report`, read participant `clientapp`, `loginname`, and statement evidence from the native deadlock XML. Event-level actions are not substitutes for participant attribution. Input buffers may be truncated and omit earlier transaction statements; collect additional evidence when needed. See the [Azure deadlock guide](https://learn.microsoft.com/en-us/azure/azure-sql/database/analyze-prevent-deadlocks?view=azuresql).

When asked for a bounded design, distinguish supplied settings from proposed choices. For an event_file target, propose both a per-file size and a finite rollover count, state their approximate total storage bound, and specify a stop condition. Label these as proposals pending platform/permission checks; do not present them as observed settings or create the session without authorization. For a ring_buffer, bound memory and capture duration and explain that older events may be lost.

On Azure SQL Database use database-scoped sessions, views and permissions. Verify event availability and field units on the actual target. A successful CREATE/START does not prove the session will collect evidence: check the event, predicate, attribution actions and target, generate a harmless matching event if authorized, then read the target and confirm the expected row. Stop/drop only the session created for this task when finished, retaining the evidence first.

Do not prescribe SQL Server's `blocked_process_report` recipe unchanged for Azure SQL Database; use the supported Azure blocking diagnostic stream or database-scoped evidence described in the Azure reference. State what cannot be recovered retrospectively. Do not grant permissions or create storage credentials without authorization.


## Purpose

Use this skill when the user wants to:

- design a new Extended Events session for a diagnostic scenario;
- create and optionally start the session;
- derive a new session from an existing XE session;
- inspect how an active or stopped session is configured;
- monitor duration, CPU, reads, waits, errors, deadlocks, blocking, or another supported signal; or
- capture execution identity such as application, host, login, database, or session.

This skill is an orchestration layer. All SQL and detailed templates live under `references/`.

## Required tools

- A SQL query tool connected to the target server and database. Prefer, in order: the SQL Tools MCP
  server that ships with the `microsoft-sql-admin` plugin (`mssql_list_database_connections`,
  `mssql_connect_database`, then `mssql_execute_query`); any other SQL tool the agent host provides
  for running T-SQL and reading result sets;
  [`sqlcmd`](https://learn.microsoft.com/sql/tools/sqlcmd/sqlcmd-utility) from a terminal. Use it
  for metadata discovery, session inspection, DDL execution, and verification. If the SQL Tools MCP
  server is not connected or lists no connections, follow the SQL tools of the Visual Studio Code MSSQL extension; this plugin does not ship the standalone SQL Tools MCP server, which
  asks before installing or configuring anything. If no SQL tool can be made available, provide the
  T-SQL for the user to review and run, then ask for the results.

## Loading References

When a step names a file, read it from `references/` relative to this `SKILL.md` before
executing the step.

## Session Specification

Build this specification before rendering DDL:

```text
purpose
session_name
template_session_name: optional
scope: SERVER | DATABASE
events[]
predicates[] per event
actions[] per event
target: event_file | ring_buffer
target_settings
session_options
start_now
startup_state
replace_existing
sensitive_data_notice
```

Ask only for information that cannot be derived from the request, platform, or template session.
Do not make the user choose raw XE implementation details when the diagnostic intent is enough to
make a safe recommendation.

## Safety Contract

- Discover platform and capabilities before generating DDL.
- Run the event-field metadata query for every selected event.
- Run the global-predicate metadata query before using a global predicate.
- Do not use fields, actions, predicates, or units based only on prior knowledge.
- Do not add actions by default; add only those required by the diagnostic question.
- Warn before capturing SQL text, application, host, login, database, or session identity.
- Inspect whether the destination session exists.
- Never silently stop, drop, or replace an existing session.
- Validate and escape identifiers, integer values, paths, and string predicates.
- Never execute unresolved template placeholders.
- Show the final DDL and expected overhead before execution.
- Verify catalog existence and runtime state after execution.

## Workflow

### Step 0: Detect Platform and Capabilities

Load
[references/step-0-platform-and-capabilities.md](references/step-0-platform-and-capabilities.md).

Determine:

- EngineEdition and supported platform;
- server or database XE scope;
- database identity;
- relevant permissions;
- available event/action metadata; and
- the platform-appropriate default target.

Stop on unsupported or unknown platforms.

### Step 1: Understand the Diagnostic Intent

Load [references/step-1-event-design.md](references/step-1-event-design.md).

Translate the user request into measurable signals, candidate event families, selective
predicates, minimum necessary actions, target requirements, and a bounded capture lifecycle.

Run the XE metadata discovery queries before finalizing any event or predicate.

### Step 2: Inspect an Existing Template

When `TemplateSessionName` is supplied, load
[references/step-2-existing-session-template.md](references/step-2-existing-session-template.md).

Inspect persisted configuration and, when running, events, predicates, actions, and targets from
the XE dynamic management views. Do not read captured target data merely to create a template.

Create a new session name and revalidate every copied element.

### Step 3: Check the Destination Session

Use the existing-session queries in the platform reference:

- SQL Server/MI:
  [references/step-3-sqlserver-session.md](references/step-3-sqlserver-session.md)
- Azure SQL/Fabric SQL Database:
  [references/step-4-database-session.md](references/step-4-database-session.md)

If the destination exists, report whether it is running and ask whether to preserve, clone, or
replace it. Replacement requires explicit approval.

### Step 4: Render the Session

Load the platform-specific reference:

- SQL Server/MI:
  [references/step-3-sqlserver-session.md](references/step-3-sqlserver-session.md)
- Azure SQL/Fabric SQL Database:
  [references/step-4-database-session.md](references/step-4-database-session.md)

For SQL Server/MI, run the default-directory query in the platform reference before rendering an
`event_file` target. Use `ring_buffer` only for bounded short-term capture, explicit user choice,
or downstream compatibility.

### Step 5: Execute, Start, and Verify

After user authorization:

1. Execute the final placeholder-free DDL.
2. Start the session when requested.
3. Re-run the platform verification query.
4. Report the actual state, target, sensitive data captured, expected overhead, and capture
   completion condition.

### Optional Recipe: Intermittent Blocking

Load
[references/blocking-investigation-recipe.md](references/blocking-investigation-recipe.md)
when intermittent blocking requires passive monitoring.

Blocking is one reusable recipe, not the default behavior of this skill.

### Final Report

Load [references/report-template.md](references/report-template.md) and populate it with the final
session specification and verified state.

## Error Handling

- Unsupported platform: stop before generating DDL.
- Event, field, action, or predicate unavailable: return to metadata discovery; do not guess.
- Permission failure: report the missing server or database XE creation/alteration permission.
- Existing session: do not replace without explicit approval.
- Invalid or broad predicate: request a narrower condition.
- Missing event-file directory: do not invent a path.
- Create succeeds but start fails: report `created but stopped`.
- Verification finds no catalog row: report creation as failed.
- Template session is stopped: use catalog views; do not interpret empty runtime DMVs as no
  definition.
