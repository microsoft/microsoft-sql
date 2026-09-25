---
name: databasehub-cli
description: "Use this skill when the user asks for tenant-wide Database Hub inventory, cross-engine SQL/PostgreSQL/Cosmos health, security posture, auditing or CMK warnings, or Fabric SQL catalog inventory through Entra-authenticated Fabric APIs. Do not use it for one-database SQL tuning or Warehouse/Lakehouse/Mirrored Database SQL."
---

> **Telemetry - MANDATORY.** Every `api.fabric.microsoft.com` call must carry
> `x-ms-fabric-skill: databasehub-cli` (`az rest`: `--headers "x-ms-fabric-skill=databasehub-cli"`),
> including every retry and page request. Snippets omit it only when the header
> is already shown in the surrounding command.

> **CRITICAL NOTES**
> 1. To find workspace details from a workspace name, list workspaces and filter
>    by `displayName`.
> 2. To find item details from a workspace ID, item type, and item name, list
>    items of that type in the workspace and filter by `displayName`.
> 3. Database Hub estate routes are tenant-scoped and usually need neither a
>    workspace nor an item ID. Apply notes 1-2 only when resolving a Fabric SQL
>    catalog item or handing off to an item-specific capability.

# Database Hub CLI

Read-only analysis of the database estate exposed through Database Hub. This
skill executes live API calls; it does not answer estate questions from generic
best practices or from files in the current directory.

Claims in this skill were verified on 2026-09-22 against `assessment.json` and
`final-matrix-adjudication-v2.json`; those artifacts cover sealed fixture
behavior, while live Fabric execution remains pending.

## When to use

Use this skill for tenant-wide or cross-engine questions about:

- database counts, subscriptions, hierarchy, and mixed estate inventory;
- Microsoft SQL and PostgreSQL CPU, storage, and memory health;
- Cosmos DB availability and normalized RU coverage;
- security findings plus authentication, auditing, and CMK posture; and
- Fabric SQL catalog inventory.

Do not use it for Query Store, DMVs, execution plans, blocking, indexes, T-SQL,
warehouse `queryinsights`, OneLake governance, Eventhouse queries, or resource
changes. Route those requests to the owning capability described below.

## Prerequisite knowledge

- Before issuing any Database Hub request, open the [Private-over-public API contract](references/private-over-public-api.md)
  for identity, route selection, pagination, partial-result, error, and
  read-only safety rules.
- Open [Fabric API and CLI basics](references/fabric-api-basics.md) when signing
  in, validating the tenant or token audience, adding request attribution, or
  resolving Fabric workspaces and items.
- Review [Database Hub in Fabric documentation](https://learn.microsoft.com/fabric/database/hub/)
  and use the [Microsoft Learn MCP server](https://learn.microsoft.com/api/mcp) for official docs.

## Select one mode

| Mode | Use when the request asks for | Read next |
| --- | --- | --- |
| `consumption` | estate counts, subscriptions, resource hierarchy, mixed or engine-specific inventory, saved-view membership, or Fabric SQL catalog entries | [references/consumption.md](references/consumption.md) |
| `operations` | cross-engine performance, CPU/storage/memory, Cosmos DB availability/RU use, critical or monitored resources, issues/suggestions, or authentication/auditing/CMK posture | [references/operations.md](references/operations.md) |

For a request spanning both modes, establish inventory scope first, then run
operations against that scope. Read each reference before issuing its calls.

## Scope and routing boundaries

| Request | Owning capability |
| --- | --- |
| Cross-engine estate inventory, health, findings, or security posture | `databasehub-cli` |
| Query Store, DMVs, blocking, plans, indexes, T-SQL, or tuning for one Fabric SQL Database | an item-level Fabric SQL database skill such as `sqldb-cli` |
| Warehouse, Lakehouse SQL endpoint, or Mirrored Database SQL queries and `queryinsights` | a warehouse SQL skill such as `sqldw-cli` |
| OneLake domains, labels, workspace/capacity governance, descriptions, endorsement, or tags | a OneLake governance skill |
| Fabric workspace item search by name, description, workspace, or type | a Fabric catalog search skill |
| Eventhouse or KQL Database queries | an Eventhouse/KQL skill |
| Azure Monitor mirrored-catalog onboarding and business-impact correlation | an Azure Monitor mirrored-catalog skill |

The named sibling skills are capability owners from the source collection and
may not be installed in every AgentSkills bundle. If the owning sibling is not
available, explain the boundary and stop; do not make Database Hub perform that
sibling's work.

Fabric SQL support here is **catalog inventory only**. Do not claim Database Hub
health or posture coverage for Fabric SQL items. Do not substitute a
single-database diagnostic skill for a cross-engine estate request.

## Execution contract

1. Confirm the active Entra identity and requested scope. Portal-provided
   subscriptions, resource filters, or time range are query hints, never
   authorization.
2. Read the shared API contract and the selected mode reference.
3. Run the documented live calls through `https://api.fabric.microsoft.com`.
4. Follow every continuation token needed for the requested scope.
5. Report timeframe, aggregation, engine coverage, pagination completeness,
   `coverage`, and sanitized `errors`.
6. For prompts containing "all", "across", or "estate", complete every required
   summary/posture call in the selected workflow before answering. Do not defer
   required calls as an optional follow-up.
7. If a route or permission is unavailable, state the exact missing coverage;
   never invent data, switch to a workload host, or query ADX directly.

## Must / Prefer / Avoid

### MUST

- Remain read-only. Decline create, deploy, enable, disable, update, delete, or
  remediation requests and route them to the owning product flow or skill.
- Use a delegated Entra user token for the Fabric API and include
  `x-ms-fabric-skill: databasehub-cli` on every request.
- For cross-engine health, query Microsoft SQL, PostgreSQL, and Cosmos DB
  separately; preserve their different metric contracts in the answer.
- For requests covering the estate, all resources, or databases "across" the
  estate, page Cosmos health with the filtered POST form until
  `continuationToken` is absent. A first-page Cosmos result is incomplete.
- Treat HTTP 200 with non-empty `errors`, incomplete `coverage`, or remaining
  continuation tokens as partial, not complete success.
- Label posture denominators exactly: authentication counts cover Azure SQL
  databases plus Arc SQL Server, while auditing and CMK counts cover Azure SQL
  databases only.
- State that Cosmos DB exposes availability and normalized RU consumption here,
  not CPU, memory, storage, latency, or throttled-request diagnostics.
- State normalized RU saturation and explicitly say it does **not** prove
  throttled requests because this contract exposes no throttling metric.

### PREFER

- Start with summary/count routes, then drill into only the affected population.
- Use server-provided finding summaries and high/low usage classifications
  instead of inventing thresholds.
- Project compact typed summaries from API responses. Do not dump full metric
  series or finding `targetSummaries` unless the user asks for them; oversized
  tool output is harder to ground reliably.
- Group results by database family and priority, with affected counts and named
  examples only when the user asks for detail.
- Reuse an immutable filter snapshot across pages and related filtered calls.

### AVOID

- Direct calls to ADX, Kusto, `arcdataservices.com`, workload regional hosts, or
  any MWC-token flow.
- Agent-authored KQL, schema discovery, or arbitrary telemetry queries.
- Claiming IO support; the current health contract exposes CPU, storage, and
  memory for Microsoft SQL/PostgreSQL.
- Inferring throttled requests or throttling from normalized RU consumption
  alone. This contract reports RU saturation, not throttling events.
- Treating an empty response as healthy when authorization, coverage, paging,
  or partial errors are unresolved.

## Check it worked

Run a bounded count request to verify authentication, the public host, and
request attribution before a larger estate workflow:

```powershell
az rest --method get `
  --resource "https://api.fabric.microsoft.com" `
  --url "https://api.fabric.microsoft.com/v1/databasehub/__private/databases/count" `
  --headers "x-ms-fabric-skill=databasehub-cli" `
  --output json
```

A successful response contains a numeric `totalCount` and a `countByType`
object. For the requested workflow, also confirm:

- every required database family or posture route returned a typed result;
- the reported timeframe and aggregation match the request;
- every required continuation token was consumed, unless the user requested an
  exact bounded number of pages;
- `coverage` and `errors` are disclosed as complete, partial, unavailable, or
  empty rather than silently ignored; and
- no create, update, delete, enable, disable, remediation, direct ADX, or
  workload-token operation was attempted.

If the count request returns 401 or 403, recheck the delegated user, tenant, and
Fabric audience. If expected fields are absent or paging remains incomplete, do
not report a complete estate result; follow the error and partial-result rules
in the API contract.

## Examples

```text
User: Are there any performance issues I should know about in my data estate?
Mode: operations
Action: Query all three health families, report performance findings and partial coverage, then drill into high-usage SQL/PostgreSQL resources when needed.
```

```text
User: What should I fix first to improve security across my databases?
Mode: operations
Action: Compare security issues with authentication, auditing, and CMK posture; prioritize affected resources without changing them.
```

```text
User: Show my database estate by engine and subscription.
Mode: consumption
Action: Read counts, page the requested inventory, and group returned resources by type and subscription.
```

```text
User: How is my CPU consumption looking across my databases recently?
Mode: operations
Action: Query Microsoft SQL and PostgreSQL CPU coverage and explicitly note that this Database Hub Cosmos contract has no CPU metric.
```

```text
User: Give me a breakdown of all issues and suggestions across my data estate.
Mode: operations
Action: Combine health finding summaries with security issue/suggestion summaries and list affected resources through read-only drill-down routes.
```
