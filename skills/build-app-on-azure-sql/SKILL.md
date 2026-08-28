---
name: build-app-on-azure-sql
description: >-
  Sequences the work of standing up a new application on Azure SQL Database and routes each
  decision to the skill that owns it. Use at the start of a project, when a user says "build an
  app on Azure SQL", "add Azure SQL Database to my app", "which stack should I use with Azure
  SQL", "where do I start", "generate an API over my database", or "get this into Azure without a
  password in the repo". It establishes the order that works: three server-side prerequisites
  verified before any code, an identity instead of a password, schema through a migration instead
  of at startup, and a generated data API considered before hand-written CRUD. It routes rather
  than repeats. provision-azure-sql-db creates the database, connect-to-azure-sql and the
  per-language connect skills own drivers, retry and pooling, entra-id-auth owns the identity,
  dab-rest-and-graphql and azure-functions-sql-bindings own the API layer, deploy-app-to-azure
  owns shipping, and azuresql-db-scaffold owns the local container version.
license: MIT
---

# Build an application on Azure SQL Database

**This is a router, not a tutorial.** It owns the order the work has to happen in and the four
decisions that get made wrong at the start. Every technique it names belongs to another skill, and
the handoff is the point.

Verified against Microsoft Learn and Azure CLI 2.89.1 on 2026-08-27.

## The failure this exists to prevent

Asked to build an application on Azure SQL Database, an agent starts inside the application: it
picks a stack, writes a data layer, and puts a user name and password in configuration.

**Every first-party Azure SQL Database quickstart starts outside the application.** All four of
them open with the same section, before a single line of code, and it configures the server rather
than the project. The three things that section does are the three things that fail silently:

| Prerequisite | How it fails |
|---|---|
| A firewall rule covering the client address | Up to a **five minute** delay before a rule takes effect, so the first run fails after the rule was created correctly. Address translation also means the address the client connects from is often not the one in its own network configuration |
| A Microsoft Entra administrator on the logical server | Passwordless auth is simply off. The failure arrives at connect time as a login failure, which reads as a wrong credential |
| A database user for the deployed identity | Nothing at deploy time reports it missing. The application returns a server error, and its code is correct |

None of these are code bugs, and all three present as one.

## Step 0: prove the prerequisites, then write code

These are read-only checks. Creating the resources belongs to `provision-azure-sql-db` and
`entra-id-auth`.

```bash
# 1. Is there a rule that covers the address this client actually connects from?
az sql server firewall-rule list -g <rg> -s <server> -o table

# 2. Is there a Microsoft Entra administrator on the logical server?
az sql server ad-admin list -g <rg> -s <server> -o table
```

```sql
-- 3. Run against the USER database, not master. Does the application identity have a user?
SELECT name, type_desc, authentication_type_desc
FROM sys.database_principals
WHERE authentication_type_desc = 'EXTERNAL';
```

Two facts that decide what to do when check 1 looks right and the connection still fails:

- The five minute latency is a **cache**. `DBCC FLUSHAUTHCACHE` on the database forces a refresh
  rather than waiting.
- A rule from `0.0.0.0` to `0.0.0.0` is the documented special case meaning Azure-internal traffic.
  It is not a wildcard for the internet, and it does allow **every** Azure service, including
  services in other subscriptions. Treat it as a getting-started shortcut, not a posture.

Check 3 has an ordering trap of its own. `CREATE USER [<name>] FROM EXTERNAL PROVIDER` requires the
connection running it to be **authenticated with Microsoft Entra ID** and to hold at least
`ALTER ANY USER`. An administrator connected with SQL authentication cannot create the application's
user, which is why "I am the admin and it still fails" is a common dead end. `entra-id-auth` owns
that path and its error codes.

## The four decisions, and where each one goes

A good answer names the decision, states the usual right answer, and hands off.

### 1. What does the application develop against?

**Usually a real Azure SQL Database.** The free offer runs on General Purpose serverless and is
sized for exactly this. Developing against a different engine and deploying to this one is how
edition, limit and error-semantics differences arrive late.

- Create it: `provision-azure-sql-db`
- Offline or fast-teardown parity instead: `azuresql-db-scaffold` and `dev-container-templates`,
  which own the local container story
- If the target is serverless, the first connection to a paused database is **expected** to fail
  while it resumes: `connect-to-azure-sql` owns that and `serverless-and-auto-pause` owns the tier

### 2. How does the application authenticate?

**Passwordless, in both places, with one connection string whose only difference is the auth mode.**
The application code does not change between a developer's machine and Azure. What changes is which
credential the identity library discovers.

The mode is spelled differently by each driver, and this is where a plausible guess produces a
string the driver rejects. Verified spellings:

| Stack | Local | Deployed |
|---|---|---|
| .NET, `Microsoft.Data.SqlClient` | `Authentication="Active Directory Default"` | same string, resolves to the managed identity |
| Node.js and TypeScript, `mssql` | `authentication: { type: 'azure-active-directory-default' }` | same value |
| Python, `mssql-python` | `Authentication=ActiveDirectoryDefault` | `Authentication=ActiveDirectoryMSI` |

- The doctrine every stack inherits, including retry, encryption and pool sizing:
  `connect-to-azure-sql`
- Installation, syntax and pooling per stack: `connect-from-dotnet`, `connect-from-python`,
  `connect-from-typescript-and-node`
- Making the identity itself work, and its error codes: `entra-id-auth`
- An error number that needs a cause: `diagnose-connection-errors`

### 3. Who writes the data layer?

This is the decision most likely to be answered by reflex, and hand-written CRUD is usually the
wrong reflex.

| The application needs | Usual answer | Skill |
|---|---|---|
| REST or GraphQL over tables and views that already exist | Generate it. Do not hand-write controllers | `dab-rest-and-graphql` |
| Serverless endpoints, or code that runs when a row changes | Input, output and trigger bindings | `azure-functions-sql-bindings` |
| Rich domain objects and a mapped model | An ORM, chosen for the language | `ef-core-azure-sql`, `prisma-azure-sql`, `sqlalchemy-azure-sql`, `django-azure-sql` |
| A few queries with full control over the SQL | The driver directly | the three `connect-from-*` skills |

Whatever the answer, values reach the database as parameters. Every quickstart sample below
parameterises, and the Python one carries an explicit warning against shipping its raw statements.
`prevent-sql-injection` owns that.

### 4. How does the schema get there?

**Through a migration or a schema project, run as its own step.** Not at application startup.

This one needs saying out loud because the sample code contradicts it. Three of the four
quickstarts create their table during startup and label it, in the sample itself, as testing only:
"Table should be created ahead of time in production app", "Table would be created ahead of time in
production". An agent that has absorbed those samples reproduces the startup DDL and drops the
label.

- The tool-neutral doctrine, including why startup migration is wrong: `schema-migrations-safely`
- Getting the model right before it is expensive to change: `design-azure-sql-schema`

## Verified starting points

The first-party quickstart for each stack, as of the verification date. Names and packages move, so
treat this as the pointer and fetch the current page before generating a project.

| Stack | Framework in the quickstart | What it installs |
|---|---|---|
| .NET, driver directly | Minimal API, `dotnet new web` | `Microsoft.Data.SqlClient` |
| .NET, ORM | Minimal API, `dotnet new web` | `Microsoft.EntityFrameworkCore`, `.SqlServer`, `.Design`, plus OpenAPI packages, with real `dotnet ef migrations` steps |
| TypeScript and Node.js | Express | `mssql express swagger-ui-express yamljs dotenv` |
| Python | FastAPI | `mssql-python`, `fastapi`, `uvicorn[standard]`, `pydantic`, `python-dotenv` |

Three things to know about that table:

- **There is no first-party Azure SQL Database quickstart for Next.js.** Building one means server
  side data access in the Node.js runtime, because the driver speaks a TCP protocol and cannot run
  in an edge runtime. `connect-from-edge-runtimes` owns the runtimes with no TCP, where the honest
  answer is a data API over HTTPS rather than a driver.
- **Django is a supported path**, through the Microsoft-maintained `mssql-django` backend, which now
  tracks Django releases within days. `django-azure-sql` owns it.
- The .NET ORM quickstart still configures the provider with `UseSqlServer`. Whether that is the
  current best answer for this service belongs to `ef-core-azure-sql`, not here.

## Getting it to Azure

`deploy-app-to-azure` owns the deployment itself. Two things belong in the plan before it starts.

**The identity grant is a real step and it is easy to skip.** Connecting a hosted application to
the database is three operations: enable a managed identity, create a database user for it, grant
it roles. There is a single command that does all three, and it needs an extension:

```bash
az extension add --name serviceconnector-passwordless --upgrade

az webapp connection create sql \
  -g <app-resource-group> -n <app-name> \
  --tg <server-resource-group> --server <server> --database <database> \
  --system-identity --client-type <language>
```

Behind that one command it also enables Microsoft Entra authentication on the server if it was off,
**sets the Microsoft Entra administrator to the signed-in user**, opens a temporary firewall rule if
the local address is blocked, and writes the connection setting onto the application. Two of those
are changes to a shared server, so say so before running it on anything but a sandbox.

**Check what it granted.** The documented grant for Azure SQL Database is
`GRANT CONTROL ON DATABASE::"<database>" TO "<user>"`, which is far wider than an application needs,
and Microsoft's own wording is that you can revoke and adjust it. The portal walkthrough grants
`db_datareader`, `db_datawriter` and `db_ddladmin` instead, and even that carries an explicit note
that a single elevated identity is not a production pattern. `least-privilege-database-roles` owns
what to leave in place.

## Validation rules

- The three prerequisites were checked before application code was written, and the check result is
  visible rather than assumed.
- The connection string carries no password and no user name, names the user database rather than
  `master`, and keeps encryption on with certificate trust off.
- The auth mode string is the one the chosen driver accepts, and the local and deployed values are
  stated separately where they differ.
- No table is created during application startup.
- The data-layer decision was made explicitly. If CRUD is hand-written, there is a stated reason a
  generated data API was not used.
- The deployed identity has a database user, created from a connection authenticated with Microsoft
  Entra ID, and the roles it holds are named.
- Retry exists in the first version of the data access code, not in a follow-up task.

## Do not

- Do not write application code before the firewall rule and the Microsoft Entra administrator are
  confirmed. That ordering is the whole skill.
- Do not read a first-run failure as a code or driver bug. Check the five minute rule latency, then
  the admin, then the database user, in that order.
- Do not create a firewall rule and immediately declare success. Either wait out the latency or
  flush the auth cache.
- Do not put a password in configuration because passwordless "can be added later". The password
  path and the identity path differ in the connection string only, so there is nothing to save.
- Do not copy the quickstart's startup table creation into a real application. The sample says so
  itself, in a comment that is easy to drop.
- Do not hand-write CRUD endpoints over an existing schema without first deciding against a
  generated data API.
- Do not leave a one-command grant unexamined. `CONTROL` on the database is not an application role.
- Do not restate driver installation, retry policy, pool sizing, Data API builder configuration or
  binding syntax here. Every one of those has an owner, and duplicating it is how two skills start
  disagreeing.
- Do not answer the local-container version of this question here. That is `azuresql-db-scaffold`.

## Read the source when

- **A project is about to be generated**: the connect-and-query quickstart for that language on
  Microsoft Learn, which is the only current statement of the framework and package list.
- **A firewall or address question is open**: the Azure SQL Database IP firewall rules article,
  which carries the latency table and the auth cache refresh.
- **The identity will not authenticate**: the Microsoft Entra authentication configuration article,
  which carries the contained-user requirements and their error codes.
- **The one-command connection is being considered**: the Service Connector passwordless tutorial,
  which is the only place the full list of what it changes is written down.

## Checklist before reporting success

- [ ] Firewall rule verified, and the latency either waited out or flushed
- [ ] Microsoft Entra administrator verified on the logical server
- [ ] Connection configuration has no secret, and names the user database
- [ ] Auth mode string matches the driver, local and deployed
- [ ] Schema arrives through a migration step, not through startup code
- [ ] The data-layer choice was made against the routing table, not by reflex
- [ ] Deployed identity has a database user with named, justified roles
- [ ] Every skill this handed off to was actually consulted for its part
