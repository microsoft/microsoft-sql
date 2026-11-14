---
name: dab-mcp-endpoint
description: "Use when connecting an AI agent to a hosted Data API builder MCP endpoint, writing its server description, making its tools read-only, or diagnosing role, tool, permission or session failures, including describe_entities reporting 'no entities configured' for a configured endpoint."
---

# Connect agents to the Data API builder MCP endpoint

The MCP endpoint is the same Data API builder runtime as REST and GraphQL: the same entities, the
same roles and the same permissions, offered to an agent as a fixed set of tools. What breaks is
everything between the client and those tools, and on version 2.1 **most of those failures arrive
inside an HTTP 200**.

Verified against Data API builder 2.1.5 with raw JSON-RPC requests over Streamable HTTP, against
a container built from the 2.1.5 image and a SQL engine in a container. Client configuration
formats are from the Visual Studio Code MCP reference and Microsoft Learn; they have not been
exercised against a hosted endpoint. How the server description reaches the client was read from
the 2.1.5 source, not measured.

## The boundary

| Question | Owner |
|---|---|
| Running the endpoint locally and adding it to the workspace MCP configuration, in VS Code | The MSSQL extension's Data API builder view |
| Per-entity MCP settings, descriptions and `anonymous`/`authenticated` permissions, in VS Code | The MSSQL extension's Data API builder designer |
| Hosting it in Azure, `runtime.mcp.allowed-hosts`, replicas, health | `deploy-dab-to-azure` |
| The identity DAB uses to reach the database | `entra-id-auth` |

This skill owns the hosted endpoint: the client, its credential and role selection, the settings the
designer does not set, and proving what the agent can reach.

## What the endpoint is

- `POST /mcp`, Streamable HTTP, protocol version `2025-06-18`. `serverInfo.name` is
  `SQL MCP Server`. Clients send `Accept: application/json, text/event-stream`; replies arrive as
  `event: message` frames. A browser opening `/mcp` sees an error; that is not a fault.
- `initialize` returns an `Mcp-Session-Id` header. Every later request carries it. The session
  lives in the process that issued it.
- Seven tools, the same list for every caller. Their configuration keys under
  `runtime.mcp.dml-tools` name them: `describe-entities`, `read-records`, `create-record`,
  `update-record`, `delete-record`, `execute-entity`, `aggregate-records`; clients show the same
  names with underscores. There is no free-form SQL and no schema change. Stored procedures run
  through the execute tool, or as named tools of their own.
- `runtime.mcp.description` is returned to the client as `instructions` at `initialize`. It is the
  only text that tells the agent what this server is for; see
  [Tell the agent what this server is for](#tell-the-agent-what-this-server-is-for).
- `dab start --mcp-stdio role:<role>` is for local clients only. It uses the development
  `Simulator` provider and never reaches a hosted endpoint. Over stdio, 2.1.5 sends the
  description only as `serverInfo.description`, a human-readable field, with no `instructions`,
  when the client negotiates protocol `2025-11-25`, so a local client may never give it to the
  model.

## Four things that fail while looking fine

Each observed on 2.1.5 when this skill was written, with an entity granted only to `authenticated`.
To the user they are documentation, not something you measured: say so, and name what you did not run.

1. **`tools/list` is not a permission check.** An anonymous caller was offered all seven tools,
   including the delete tool, for a configuration in which it could do nothing.
2. **The entity-description tool said `NoEntitiesConfigured` when the configuration had
   entities.** The caller's role could see none of them. The request reached DAB as a role with
   nothing granted: usually no `Authorization` header arrived, so it ran as `anonymous`, or the
   entities are granted to a named role and the client sent no `X-MS-API-ROLE`, so it ran as
   `authenticated`, which inherits from `anonymous` and never from a named role. Do not add
   `anonymous` permissions to make the message go away.
3. **A denied tool call is HTTP 200.** A call to the read tool for a role without `read` returned
   200 with a tool result whose `status` is `error` and `type` is `PermissionDenied`. Monitoring
   HTTP status alone sees success. Read the result.
4. **`Session not found` (-32001) is HTTP 404 from another process.** A replica that did not issue
   the session, a restarted container or a new revision all answer this way. The client must call
   `initialize` again. Scaling belongs to `deploy-dab-to-azure`.

A 403 whose body names the `Host` or `Origin` header is the 2.1 host allowlist, not a permission.
`deploy-dab-to-azure` fixes it in the configuration.

## Choose inbound authentication the client can actually perform

The client's credential decides the DAB role for every tool call. The database never sees the
caller: DAB connects with its own identity for every request.

| What the client can send | DAB provider | Consequence |
|---|---|---|
| A Microsoft Entra bearer token for the API | `EntraID`, with the token's `aud` and `iss` | `authenticated`, or a named role when the client also sends `X-MS-API-ROLE` and the token carries that role |
| Nothing | `Unauthenticated` | Every call is `anonymous`; grant `anonymous` only narrow `read` |
| An API key or another scheme | Put Azure API Management in front, which authenticates and forwards | DAB sees what the gateway forwards |

One DAB instance has one inbound scheme. Two clients that need different schemes need two
instances. A client that cannot set custom headers cannot select a named role, so design its access
around `authenticated`.

## Configure the client

Visual Studio Code, `.vscode/mcp.json`. The token is prompted for, never written to the file:

```json
{
  "inputs": [
    { "type": "promptString", "id": "dab-token", "description": "Access token for the Data API builder API", "password": true }
  ],
  "servers": {
    "sql-mcp": {
      "type": "http",
      "url": "https://<host>/mcp",
      "headers": { "Authorization": "Bearer ${input:dab-token}", "X-MS-API-ROLE": "<role>" }
    }
  }
}
```

Drop `X-MS-API-ROLE` to run as `authenticated`. VS Code does not forward servers that need
`${input:...}` to Copilot harness sessions; there, use the portable `.mcp.json` with a top-level
`mcpServers` object and `"Authorization": "Bearer ${DAB_TOKEN}"` read from the environment.

A pasted access token expires within hours. Use it to test. For a lasting connection, use a client
that obtains tokens itself, such as a Foundry agent's Microsoft Entra authentication mode, or a
gateway.

**Foundry agent.** Add a tool, choose Custom, then Model Context Protocol, and enter
`https://<host>/mcp` as the remote endpoint. The authentication mode chosen there must match the
DAB provider; Unauthenticated in Foundry reaches only `anonymous` permissions.

**MCP Inspector**, for debugging only:
`npx -y @modelcontextprotocol/inspector@2.12.0 https://<host>/mcp` (pin the release you have
reviewed), then add the `Authorization` header in its connection settings. Do not host Inspector
where others can reach it.

## Tell the agent what this server is for

Every Data API builder server offers the same seven generic tools. What this one holds, what it is
for and where it stops reach the agent through one setting, `runtime.mcp.description`, returned as
`instructions` at `initialize`. Entity and field descriptions say what a table or column means;
only this says what the server is for, and it is what lets an agent connected to several servers
pick this one for the right questions. Treat it as configuration, not as a comment.

| Property | Consequence |
|---|---|
| One string, the same for every caller and role, returned before any permission is checked | Anonymous callers receive it too. No secrets, internal host or server names, or entities some role must not know exist |
| It restricts nothing | "Read-only" in the text stops no write; permissions do. Text that disagrees with the permissions misleads the agent |
| The client decides whether the model sees it | The MCP specification makes it a hint a client may add to the model's context. Check yours |
| Read once | DAB reads it at startup and a client receives it once per session: restart or redeploy, then reconnect |
| Blank or whitespace | No `instructions` field is sent |

A useful description says, in a few sentences:

1. **Purpose and audience**: what data this is, and which agent or task it serves.
2. **What is here**: the entities and custom tools the agent's role can reach, and what is
   deliberately not available.
3. **How the tools fit together**: list the entities before reading, filter and select columns
   instead of reading whole tables, aggregate for counts and totals.
4. **Limits**: read-only or not, units, currencies and time zones, freshness, and the questions it
   cannot answer.

Leave out what each tool's own description already says, behaviour rules unrelated to this server,
and marketing.

```text
Weak:   Product catalog
Useful: Read-only access to Contoso's product catalog and order history, for the sales assistant
        answering customer questions about products, prices and past orders. Entities: Product,
        Order. Prices are USD; order dates are UTC. List the entities before reading, filter and
        select only the columns needed, and aggregate for counts and totals instead of reading
        every row. Inventory and customer contact details are not available here.
```

**Review it whenever you create or review a configuration with MCP enabled:**

1. Read `runtime.mcp.description` from the file and, for a hosted endpoint, the `instructions`
   that `initialize` returns.
2. It is missing if absent or blank. It is insufficient if it does not cover the four points
   above, or if it contradicts the permissions or the advertised tools.
3. Draft a replacement that opens with what the server is for, built from the configuration: the
   entities and actions the agent's role can reach, the advertised tools, custom tools, and
   entities kept out of MCP. Mark what the file cannot say, such as who the agent serves and what
   it must not be used for, as questions rather than guesses.
4. Present the current text beside the draft. Tell the user that every caller receives it at
   `initialize`, anonymous ones included, and that it restricts nothing. Ask them to confirm the
   purpose and answer the open questions, and wait for approval or edits before writing it.
5. Write it with `dab configure --runtime.mcp.description "<text>"`, set `runtime.health.roles`
   again afterwards (`deploy-dab-to-azure`), restart or redeploy, and confirm `initialize` returns
   the new text.

## Shape what the agent sees

Permissions are the control; tool switches only change what is advertised. Do both.

In VS Code, make the per-entity settings below in the MSSQL extension's designer, which edits the
same file: descriptions, field and parameter descriptions, an entity's MCP switch, and a stored
procedure as a custom tool. The designer offers only `anonymous` and `authenticated` permissions
and no server-wide MCP settings, so named roles such as `agent`, the global tool switches and the
server description still go through the CLI, after the designer's edits.

```bash
# read-only agent: grant read only, then stop advertising write tools
dab update Product --permissions "agent:read"
dab configure --runtime.mcp.dml-tools.create-record false \
  --runtime.mcp.dml-tools.update-record false --runtime.mcp.dml-tools.delete-record false

# keep an entity on REST but out of MCP entirely (writes "mcp": false on the entity)
dab update AuditLog --mcp.dml-tools false

# tell the agent what each entity and column means
dab update Product --description "One row per sellable product."
dab update Product --fields.name Price --fields.description "Unit price in USD."

# a curated stored procedure as its own named tool
dab add GetTopProducts --source dbo.usp_GetTopProducts --source.type stored-procedure \
  --permissions "agent:execute" --mcp.custom-tool true \
  --description "Returns the best-selling products." \
  --parameters.name "top" --parameters.description "How many to return." --parameters.required true
```

With MCP enabled, 2.1.5 `dab validate` warns when entities carry no `fields` definitions. Describe
at least the key and the columns an agent filters on. Any `dab configure` call above resets
`runtime.health.roles`; `deploy-dab-to-azure` covers the order.

## Verify with requests, not with the client UI

Run these against the hosted endpoint as the agent's own identity. Open
[references/mcp-requests.md](references/mcp-requests.md) when you send them; it has the full
bodies in bash and PowerShell.

1. `initialize` returns 200, an `Mcp-Session-Id` header and `instructions` matching
   `runtime.mcp.description`. No `instructions` field means no description is set.
2. `notifications/initialized`, then `tools/list`, carrying the session header.
3. `tools/call` on the entity-description tool lists exactly the entities this role should see.
4. `tools/call` on the read tool with `{"entity": "<Entity>", "first": 1}` returns one record.
5. As a role that must not write, the create tool returns a tool error, not a record. Send this probe only to a
   disposable copy of the database: a permission wider than intended makes it a real insert. Against production,
   prove read-only from `dab configure --show-effective-permissions` and skip the probe.

## When it fails

| Symptom | Cause | Fix |
|---|---|---|
| 403 naming the `Host` or `Origin` header | Host allowlist | `deploy-dab-to-azure` |
| 401 | Token missing, expired, or `aud`/`iss` mismatch | Decode the token and compare with the configuration |
| `NoEntitiesConfigured` with entities configured | The caller's role sees none | Fix the token or `X-MS-API-ROLE`, not the permissions |
| Tool result `PermissionDenied` under HTTP 200 | The role lacks that action on that entity | `dab configure --show-effective-permissions` |
| 404 `Session not found` | Session issued by another process | Re-initialize; `deploy-dab-to-azure` for replicas |
| The agent picks the wrong entity or invents columns | No descriptions or `fields` | Add descriptions and fields as above |
| The agent ignores the server, uses it for questions it cannot answer, or reads whole tables | No `instructions`, or text without purpose, scope or limits | Write `runtime.mcp.description` as above |

## Do not

- Do not commit a token to `mcp.json` or `.mcp.json`.
- Do not treat `tools/list`, an HTTP 200 or a client's green status as proof of access.
- Do not grant `anonymous` to make the entity-description tool return something.
- Do not rely on disabling a tool, or on a description that says read-only, to stop writes; remove
  the permission.
- Do not leave `runtime.mcp.description` empty or generic, and do not put in it anything an
  anonymous caller must not see. Do not rewrite it without the user's approval.
- Do not probe write denial against a production database. A probe that is not denied is a write.
- Do not state the 2.1.5 behaviours above as timeless facts, and do not call them measured, verified or
  tested unless you sent the request yourself in this session. Attribute them as "documented for DAB 2.1.5
  in this skill, not verified against your endpoint", and keep the user's own transcript separate from them.
