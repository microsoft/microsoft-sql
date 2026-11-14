---
name: deploy-dab-to-azure
description: "Use when deploying Data API builder to Azure Container Apps, or a deployed DAB app shows identity, health (403), host (MCP 403), scaling or startup failures."
---

# Deploy Data API builder to Azure Container Apps

A Container App revision that reports Running proves the container started. It does not prove the
database is reachable, that callers are authenticated, or that an agent can reach `/mcp`. On
version 2.1, **each of those can fail while the revision stays green**.

Verified against Data API builder 2.1.5: the CLI, and the
`mcr.microsoft.com/azure-databases/data-api-builder:2.1.5` and `:2.1.5-nonroot` images with the
configuration baked in, run in Docker against a SQL engine in a container. Thirty-four runtime
checks held. The Azure commands come from Microsoft Learn and the Azure CLI's own help; they have
not been run against Azure resources.

## The boundary

| Question | Owner |
|---|---|
| Entities, API types, `anonymous`/`authenticated` permissions and field descriptions, in VS Code | The MSSQL extension's Data API builder designer, which writes the same configuration file |
| Running it locally first | The MSSQL extension's Data API builder view in VS Code, or `dab start` |
| Pointing VS Code, Foundry or another MCP client at the hosted `/mcp` | `dab-mcp-endpoint` |
| The Microsoft Entra administrator, the database user and its grant | `entra-id-auth` |
| Creating the logical server, the database and the firewall rule | `provision-azure-sql-db` |
| An application with its own code, deployed with the Azure Developer CLI | `deploy-app-to-azure` |

This skill owns what the designer does not set: the inbound provider and its token settings, named
roles, health roles, the MCP host allowlist, the image, the Azure resources and the verification.

## What a green revision hides

Each observed on 2.1.5 when this skill was written. Every row is a deployment that looks finished. To the
user they are documentation, not something you measured: say so, and name what you did not run.

| Observation | What it actually means |
|---|---|
| `GET /` returns 200 `{"status":"Healthy"}` | The process is up. It returned exactly this with the database stopped. |
| `GET /health` returns 403 to every caller | `host.mode` is `production` and `runtime.health.roles` is empty or missing. |
| `GET /health` returns HTTP 200 | Nothing yet. The body said `"status": "Unhealthy"` under HTTP 200 with the database stopped. Read the body. |
| `POST /mcp` returns 403 "The request Host header is not in the list of trusted hosts" | The app's host name is not in `runtime.mcp.allowed-hosts`. Only loopback is trusted by default, and REST and GraphQL on the same host keep working. |
| An MCP client intermittently gets 404 `Session not found` (-32001) | A second replica received a session the first one issued. MCP sessions live in one process. |
| The revision exits at startup: "EasyAuth is configured with host.mode set to production, but the Azure App Service environment could not be detected" | The `AppService` provider is in use outside App Service. |

## 1. Gate before anything is created

Stop and fix the configuration if any of these fails. Nothing here needs Azure.

1. **Pin one version.** `dab --version` and the image tag must match, for example `2.1.5`. Do not
   deploy `latest`: Learn's walkthrough does, and a rebuild then changes the runtime silently.
2. **Read what is published.** `dab configure --show-effective-permissions`. No entity reaches
   `anonymous` unless the user asked for public access. A role you never wrote is the finding: a
   grant to `anonymous` is inherited by every role not configured on that entity.
3. **Inbound authentication is a decision.** `dab init` writes `"provider": "Unauthenticated"`,
   which evaluates every request as `anonymous`. Keep it only for an intentionally public API, or
   one behind a gateway that enforces access.
4. **Only the surfaces asked for.** `dab init` enables REST, GraphQL and MCP, with GraphQL
   introspection on. Turn off the rest, in the designer's API types where it is in use, otherwise
   with `dab configure --runtime.graphql.enabled false` and likewise for `rest` or `mcp`.
5. **If MCP is on, it says what it is for.** `runtime.mcp.description` is what every connecting
   agent is told at `initialize`, and it is baked into the image. If it is empty or generic, draft
   one with the user before building; `dab-mcp-endpoint` covers what it must say.
6. **No secret in the file.** The connection string is `@env('DATABASE_CONNECTION_STRING')` or
   `@akv('<secret-name>')`, never a literal.
7. **Validate against a reachable database.** Set `DATABASE_CONNECTION_STRING` and run
   `dab validate`. With the variable unset, 2.1.5 prints only `Config is invalid.` and no reason.
8. **Confirm before spending.** Subscription, region, a new or existing resource group, public or
   internal ingress, and that Container Apps, Container Registry and Log Analytics cost money. Ask
   the user; do not choose for them.

## 2. Make the configuration fit the host

If the MSSQL extension's designer manages the configuration, finish its edits first, make the host
edits below afterwards, and read the file again after any later designer change. The designer does
not set any of them.

**Edit order matters in 2.1.5.** Every `dab configure` call resets `runtime.health.roles` to `[]`,
whatever setting it changes. `dab add` and `dab update` leave it alone. Run every other
`dab configure` first, set the health roles last, then read the file:

```bash
dab configure --runtime.host.authentication.provider EntraID \
  --runtime.host.authentication.jwt.audience "<aud from a real token>" \
  --runtime.host.authentication.jwt.issuer "<iss from a real token>"
dab configure --runtime.health.roles "monitoring"     # last
grep -A3 '"health"' dab-config.json                   # roles must not be []
```

- **Audience and issuer come from a token, not from memory.** A v2.0 access token carries the API's
  client ID as `aud` and an `iss` ending in `/v2.0`. A v1.0 token can carry the Application ID URI
  and the `https://sts.windows.net/<tenant-id>/` issuer. Which one arrives is set by the API's app
  registration. A mismatch is a 401 on a token that looks valid.
- **Health is for a monitoring role, not `anonymous`.** Anonymous `/health` listed every entity
  name and the enabled surfaces, and reported `Unhealthy` for each entity anonymous cannot read.
- **Do not use `AppService` or `StaticWebApps` on Container Apps.** 2.1 refuses to start them in
  production unless App Service's own EasyAuth variables (`WEBSITE_AUTH_ENABLED`,
  `WEBSITE_AUTH_DEFAULT_PROVIDER`) are present. Setting those by hand disables a guard against
  forged `X-MS-CLIENT-PRINCIPAL` headers. Use `EntraID`.

**If MCP is enabled, add the host to `runtime.mcp.allowed-hosts`.** There is no CLI flag; edit the
JSON after all CLI edits:

```json
"mcp": { "enabled": true, "path": "/mcp", "allowed-hosts": [ "dab-api.<environment-default-domain>" ] }
```

Matching is by exact host name, case-insensitive, port ignored, with no wildcard subdomains. A
non-empty `Origin` header must also be listed. List every name clients use, including custom
domains. Never use `"*"`, which turns the check off. Write a literal host: `@env()` here resolves at
runtime, but in 2.1.5 it makes `dab configure`, `add`, `update` and `validate` fail with
`Failed to read the config file`. Container Apps lets you compute the host name before building, as
`<app-name>.<environment default domain>`.

## 3. Outbound identity: the container to the database

Use a **user-assigned** managed identity, created before the app so its database user can exist
first. The connection string carries no password:

```text
Server=tcp:<server>.database.windows.net,1433;Database=<database>;Authentication=Active Directory Managed Identity;User Id=<identity-client-id>;Encrypt=True;
```

`entra-id-auth` creates the database user and grants it. Grant what the configuration uses:
`db_datareader` for read-only entities, `db_datawriter` only if an entity grants `create`,
`update` or `delete`, and `EXECUTE` on each stored procedure an entity exposes. This identity
serves every caller, so DAB's role permissions, not the database grant, separate one caller from
another.

## 4. Build and run

```dockerfile
FROM mcr.microsoft.com/azure-databases/data-api-builder:2.1.5-nonroot
COPY dab-config.json /App/dab-config.json
USER app
HEALTHCHECK CMD curl -fsS http://localhost:5000/ || exit 1
```

Both 2.1.5 images listen on port 5000 (`ASPNETCORE_URLS=http://+:5000`). `-nonroot` already runs
as `app` (UID 1654); `USER app` states it so a scanner can see it. The `HEALTHCHECK` is for local
Docker runs and proves only that the process answers: Container Apps ignores it and uses its own
probes. Bake the configuration into the image; do not mount it from a file share.

Open [references/aca-cli.md](references/aca-cli.md) when you run the Azure CLI sequence:
identity, registry with `AcrPull` for the identity, `az acr build` with an immutable tag,
environment, the host name computed from its default domain, then the app with
`--target-port 5000`.

**Scaling with MCP enabled.** Observed on 2.1.5 when this skill was written: a session ID issued by one replica returned 404
`Session not found` from another. Keep `--min-replicas 1 --max-replicas 1` for an app serving MCP
unless a multi-replica test passes. If REST must scale out, run it as a second Container App whose
configuration disables MCP.

## Check it worked, in this order

Open [references/verify.md](references/verify.md) when you run these checks; it holds each request
and the answer that counts as a pass. Do not report success from steps 1 and 2 alone.

1. The revision is Running: `az containerapp revision list -g <rg> -n <app> -o table`.
2. `GET https://<host>/` answers 200. This proves the process only.
3. Denied paths: an entity without a token returns 403 unless `anonymous` was granted on purpose,
   and a malformed token returns 401.
4. Allowed path: a real token reads one row, `GET /api/<Entity>?$first=1`.
5. `GET /health` with a token in the health role: read `status` in the body, then each `checks[]`.
6. If MCP is enabled: `initialize` at `https://<host>/mcp` returns 200 with an `Mcp-Session-Id`
   and the `instructions` set in `runtime.mcp.description`, then `tools/list`. Client configuration
   then belongs to `dab-mcp-endpoint`.

## When it fails

| Symptom | Cause | Fix |
|---|---|---|
| Image pull fails on the first revision | `AcrPull` not yet effective for the identity | Wait for role propagation, then `az containerapp update` |
| Logs show 18456 for `<token-identified principal>` | No database user for the identity | `entra-id-auth` |
| Database connection times out | Firewall or network path | `provision-azure-sql-db`, `connectivity-troubleshoot` |
| 401 with a token that decodes cleanly | `aud` or `iss` differs from the configuration | Copy both from the decoded token |
| 403 `AuthorizationCheckFailed` with a valid token | The effective role lacks the action, or `X-MS-API-ROLE` names a role absent from the token's `roles` claim | `dab configure --show-effective-permissions` |
| `/health` 403 to everyone | Health roles empty, often reset by a later `dab configure` | Set roles last, rebuild |
| `/health` body `Unhealthy`, data source `Healthy` | An entity check failed for the caller's role | Not an outage; read `checks[].exception` |
| `/health` shows an entity `Forbidden` while callers with `X-MS-API-ROLE` succeed | Entity checks run without the caller's selected role, so an entity granted only to a named role fails its check (2.1.5, Container Apps fixture) | Not an outage; verify with a role-header request |
| MCP 403 naming the Host or Origin header | Host name missing from `allowed-hosts` | Add the literal host, rebuild |

## Roll back and clean up

- Each image tag creates a revision. Keep the previous tag in the registry; roll back with
  `az containerapp update -g <rg> -n <app> --image <registry>/<repo>:<previous-tag>`.
- Delete only resources this session created, named one by one. Do not delete a resource group the
  user brought. The database user and its grants outlive the app; drop them only if asked.

## Do not

- Do not call a deployment done because a revision is Running or `/` answers 200.
- Do not state the 2.1.5 behaviours above as timeless facts, and do not call them measured, verified or
  tested unless you ran the request yourself in this session. Attribute them as "documented for DAB 2.1.5
  in this skill, not verified against your deployment", and keep the user's own output separate from them.
- Do not grant `anonymous` an entity or `/health` to make a check pass.
- Do not set `allowed-hosts` to `"*"`, or scale an MCP app out without testing sessions.
- Do not pass a password-bearing connection string when a managed identity is possible. If one is
  unavoidable, use a Container Apps secret reference, never a plain environment variable.

Open [references/hosting-choices.md](references/hosting-choices.md) when the user asks for App
Service, Kubernetes or another host instead of Container Apps.
