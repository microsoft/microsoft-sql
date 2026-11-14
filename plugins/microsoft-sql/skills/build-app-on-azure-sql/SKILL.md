---
name: build-app-on-azure-sql
description: "Use when starting a new app on Azure SQL Database: choose a stack and go from resource group to first request without storing a password."
---

# Build an application on Azure SQL Database

**This is a router, not a tutorial.** It owns the order the work happens in and the four decisions
that get made wrong at the start. Every technique it names belongs to another skill, and the handoff
is the point.

## The failure this exists to prevent

The usual start for an application on Azure SQL Database is inside the application: pick a stack,
write a data layer, and put a user name and password in configuration.

**Every first-party Azure SQL Database quickstart starts outside the application.** All four open
with the same section, before a line of code, and it configures the server rather than the project.
The three things that section does are the three things that fail silently:

| Prerequisite | How it fails |
|---|---|
| A firewall rule covering the client address | Learn documents a latency of **up to** five minutes on security setting changes. **In practice a change usually applies within seconds**, so do not plan around a five minute wait and do not read a refusal as a rule that has not landed yet: see [how long a rule really takes](#how-long-a-firewall-rule-really-takes). Network address translation also means the address the client connects from is often not the one in its own network configuration |
| A Microsoft Entra administrator on the logical server | Passwordless auth is simply off. The failure arrives at connect time as a login failure, which reads as a wrong credential |
| A database user for the deployed identity | Nothing at deploy time reports it missing. The application returns a server error, and its code is correct |

None of these is a code bug, and all three present as one.

## Step 0: prove the prerequisites, then write code

Both commands are read-only. Creating the server is `provision-azure-sql-db` and configuring the
identity is `entra-id-auth`.

```bash
az sql server firewall-rule list -g <resource-group> -s <server> -o table
az sql server ad-admin list -g <resource-group> -s <server> -o table
```

Then take one round trip to the database before an application exists, so that every later failure
is a failure of the code:

```bash
az login
sqlcmd -S <server>.database.windows.net,1433 -d <database> -G -N mandatory -l 30 -m-1 \
  -Q "SELECT SUSER_NAME() AS connected_as, DB_NAME() AS db"
```

`-G` is Microsoft Entra authentication and takes no `-U`. Open `connect-to-azure-sql` when that
command fails, or before turning it into a connection string: it owns the switch-to-keyword
mapping, encryption, retry and pool sizing.

### Which sqlcmd you have decides what you see

Two different programs are called `sqlcmd`, and the message numbers in this skill and in every
skill it routes to come out of only one of them. Microsoft Learn calls them
[the two variants](https://learn.microsoft.com/sql/tools/sqlcmd/sqlcmd-utility#sqlcmd-variants):

| | ODBC `sqlcmd` | Go `sqlcmd`, also written go-sqlcmd |
|---|---|---|
| Where it comes from | the Microsoft command line utilities, `mssql-tools18`, and the Azure SQL Database container image | a standalone download, `winget install sqlcmd`, `brew install sqlcmd` |
| Version it reports | 18.x | 1.x |
| How to tell | `sqlcmd -?` starts `Microsoft (R) SQL Server Command Line Tool` | `sqlcmd --version` prints a version alone |

`-m-1` is an **ODBC `sqlcmd`** instruction, and it is the flag that makes a severity 10 message
print its `Msg` number, which that build otherwise does not do. With ODBC `sqlcmd` 18.x,
`RAISERROR('a severity ten note', 10, 1)` prints `Msg 50000, Level 0, State 1` at `-m-1` and the
bare text without it.

**go-sqlcmd 1.x does not do this.** It prints the `Msg` header only at severity 11 and above, and a
severity 10 message arrives as text with no number at `-m-1`, `-m0` and `-m1` alike, on stdout and
on stderr. Its `-m` still filters, so `-m17` drops a
severity 16 message entirely, but no value of it puts a number back on a warning. If the numbers a
skill tells you to look for never appear, check which build you are running before you conclude the
engine stayed quiet: query `sys.messages`, or run the statement through the ODBC build.

Neither build turns a severity 10 message into a non-zero exit. `-b` returns 1 only above severity
10, so a warning never fails the command on either.

Two facts decide what to do when the rule looks right and the connection still fails:

- The five minute latency is a **cache**, and it is a ceiling rather than a wait to plan around.
  `DBCC FLUSHAUTHCACHE` on the user database forces a refresh rather than waiting. It needs the
  admin account or `KILL DATABASE CONNECTION`, and it needs a connection that already works, so it
  cannot rescue the connection the firewall is refusing.
- A rule from `0.0.0.0` to `0.0.0.0` is the documented special case meaning Azure-internal traffic,
  not a wildcard for the internet, and any virtual machine in Azure may then attempt to connect.
  `deploy-app-to-azure` owns what the first-party templates put there.

### How long a firewall rule really takes

Learn says security setting changes take **up to** five minutes. Up to is the whole sentence: it is
a ceiling, not the expected case, and a first run does not fail because of it. A rule created or
deleted with `az sql server firewall-rule` usually applies, in either direction, to the next
connection attempted after the command returns.

**A connection refused straight after `az sql server firewall-rule create` returned is very
unlikely to be a rule that has not propagated yet, so do not wait five minutes and try again.**
Check the address first: network address translation means the address the server sees is often
not the one the client believes it has, and the refusal message names the address the server saw.

```output
Cannot open server 'example' requested by the login. Client with IP address '203.0.113.7' is not
allowed to access the server.  ...  It may take up to five minutes for this change to take effect.
```

That trailing sentence is part of the server's own message and is where the expectation comes from.
It is a ceiling in the message too.

**One trap worth knowing before you diagnose a firewall at all.** On a server with Entra-only
authentication, a SQL authentication attempt is refused for being SQL authentication, before the
firewall is consulted:

```output
Login failed for user 'someone'. Reason: Azure Active Directory only authentication is enabled.
```

That message appears whether the address is allowed or not, so a SQL-auth connection test cannot
tell you anything about the firewall on such a server. Test with the Entra login the application
will actually use.

The third prerequisite cannot be checked until something is deployed, so it is in **Check it worked**
below.

## The four decisions, and where each one goes

For each one, name the decision, state the usual right answer, and hand off.

### 1. What does the application develop against?

**Usually a real Azure SQL Database.** The free offer runs on General Purpose serverless and is
sized for exactly this. Developing against a different engine and deploying to this one is how
edition, limit and error-semantics differences arrive late.

- Create it: `provision-azure-sql-db`
- Offline or fast-teardown parity instead: `azuresql-db-scaffold` and `dev-container-templates`
- On serverless, the first connection to a paused database is **expected** to fail while it
  resumes: `connect-to-azure-sql` owns that

### 2. How does the application authenticate?

**Passwordless, in both places, with one connection string whose only difference is the auth mode.**
The application code does not change between a developer's machine and Azure. What changes is which
credential the identity library discovers. The deployed string Microsoft Learn publishes for the
Python quickstart carries neither a user name nor a password:

```text
Server=<server>.database.windows.net;Database=<database>;Authentication=ActiveDirectoryMSI;Encrypt=yes;TrustServerCertificate=no;
```

**Do not write that keyword from memory for a different driver.** Every stack spells it
differently, one of them has no default mode at all, and a plausible guess produces a string the
driver rejects. `entra-id-auth` carries the accepted value per driver: open it before writing the
auth mode, not after the login fails.

- Installation, syntax and pooling per stack: `connect-from-dotnet`, `connect-from-python`,
  `connect-from-typescript-and-node`
- An error number that needs a cause: `connectivity-troubleshoot`

### 3. Who writes the data layer?

This is the decision most likely to be answered by reflex, and hand-written CRUD is usually the
wrong reflex.

| The application needs | Usual answer | Skill |
|---|---|---|
| REST or GraphQL over tables and views that already exist | Generate it. Do not hand-write controllers | `dab-rest-and-graphql` |
| Serverless endpoints, or code that runs when a row changes | Input, output and trigger bindings | `azure-functions-sql-bindings` |
| Rich domain objects and a mapped model | An ORM, chosen for the language | `ef-core-azure-sql`, `prisma-azure-sql`, `sqlalchemy-azure-sql`, or a supported Django SQL Server backend |
| A few queries with full control over the SQL | The driver directly | the three `connect-from-*` skills |

Generated, over a schema that already exists:

```bash
dab init --database-type mssql --connection-string "@env('SQL_CONNECTION_STRING')"
dab add Book --source dbo.books --source.type table --permissions "authenticated:read"
```

Open `dab-rest-and-graphql` before starting that engine rather than after: version 2.0 writes an
`Unauthenticated` provider and serves an MCP endpoint over the same entities, so a short
configuration can publish the whole database anonymously while validation passes. Hosting the
generated API in Azure belongs to `deploy-dab-to-azure`, and connecting an agent to its MCP
endpoint to `dab-mcp-endpoint`.

Hand-written, on .NET, from an empty directory:

```bash
dotnet new web -o <app-name>
cd <app-name> || exit 1
dotnet add package Microsoft.Data.SqlClient
```

`ef-core-azure-sql` owns Entity Framework Core, including which provider call to configure it with.
For Prisma, pin the major: the connector for this database is a Prisma 7 feature, and an unpinned
install can resolve to a next-major prerelease that has none.

```bash
npm install --save-dev prisma@7 @prisma/client@7
./node_modules/.bin/prisma migrate deploy
```

Whatever the answer, values reach the database as parameters. `prevent-sql-injection` owns that, and
the Python quickstart carries an explicit warning against shipping its raw statements.

### 4. How does the schema get there?

**Through a migration or a schema project, run as its own step.** Not at application startup.

This needs saying out loud because the sample code contradicts it. Three of the four quickstarts
create their table during startup and label it, in the sample itself, as testing only: "Table should
be created ahead of time in production app". Code modelled on those samples tends to keep the
startup DDL and drop the label.

- The tool-neutral doctrine, including why startup migration is wrong: `schema-migrations-safely`
- Getting the model right before it is expensive to change: `design-azure-sql-schema`

## Getting it to Azure

`deploy-app-to-azure` owns the deployment itself, and `deploy-dab-to-azure` owns it when the data
layer is a generated Data API builder API. One thing belongs in the plan before it starts.

**The identity grant is a real step and it is easy to skip.** Connecting a hosted application to the
database is three operations: enable a managed identity, create a database user for it, grant it
roles. One command does all three, and it needs an extension:

```bash
az extension add --name serviceconnector-passwordless --upgrade

az webapp connection create sql \
  -g <app-resource-group> -n <app-name> \
  --tg <server-resource-group> --server <server> --database <database> \
  --system-identity --client-type dotnet
```

`--client-type` takes one of a closed list that includes `dotnet`, `nodejs`, `python` and `django`.
Behind that one command it also **sets the Microsoft Entra administrator to the signed-in user**,
opens a temporary firewall rule if the local address is blocked and deletes it afterwards, and
writes `AZURE_SQL_CONNECTIONSTRING` onto the application. Changing the administrator changes a
shared server, so say so before running this anywhere but a sandbox.

**Check what it granted.** The documented grant is `GRANT CONTROL ON DATABASE::"<database>" TO
"<user>"`, which Microsoft's own wording invites you to revoke and adjust. The quickstarts grant
`db_datareader` and `db_datawriter` to the same identity instead. Replace either broad grant with
a custom role containing only the permissions the application actually uses.

## Check it worked

Three checks, in the order the failures arrive.

**1. The prerequisites are real, not assumed.** Both commands under Step 0 return a row. An empty
firewall table with a working connection means you are connecting from inside Azure, not that the
rule is unnecessary. The `sqlcmd` round trip returns your Entra identity in `connected_as` and the
user database, never `master`, in `db`.

**2. The deployed application holds a connection string with no secret in it.**

```bash
az webapp config appsettings list -g <app-resource-group> -n <app-name> \
  --query "[?name=='AZURE_SQL_CONNECTIONSTRING'].value" -o tsv
```

Expect one line carrying `Authentication=` and carrying neither `Password=` nor `User ID=`. Empty
output means the connection was never created, which is exactly the failure that presents as a
server error from correct code.

**3. The identity has a database user, and holds the roles you named.** Run the two queries in
`entra-id-auth`'s own check section against the user database. A `CONTROL` or `db_owner` grant
nobody asked for is the usual leftover of the one-command tool above.

## Read the source when

- **A project is about to be generated**: the connect-and-query quickstart for that language on
  Microsoft Learn, which is the only current statement of the framework and package list. There is
  none for Next.js, and no driver runs in an edge runtime because it speaks a TCP protocol. Django
  is supported, through the Microsoft-maintained `mssql-django` backend.
- **A firewall or address question is open**: the Azure SQL Database IP firewall rules article,
  which carries the latency table and the auth cache refresh.
- **The identity will not authenticate**: the Microsoft Entra authentication configuration article,
  which carries the contained-user requirements and their error codes.
- **The one-command connection is being considered**: the Service Connector passwordless tutorial,
  which is the only place the full list of what it changes is written down.

## Checklist before reporting success

- [ ] Firewall rule and Microsoft Entra administrator verified by a connection that succeeded
- [ ] One command-line round trip succeeded before any application code was written
- [ ] Connection configuration has no secret, and names the user database
- [ ] The auth mode string came from `entra-id-auth`, not from memory
- [ ] Schema arrives through a migration step, not through startup code
- [ ] The data-layer choice was made against the routing table, not by reflex
- [ ] Deployed identity has a database user with named, justified roles

## Do not

- Do not write application code before the firewall rule and the Microsoft Entra administrator are
  confirmed. That ordering is the whole skill.
- Do not read a first-run failure as a code or driver bug. Check the address the server saw, then
  the admin, then the database user, in that order, and never declare a new firewall rule a success
  until a connection through it has succeeded.
- Do not put a password in configuration because passwordless "can be added later". The two paths
  differ in the connection string only, so there is nothing to save.
- Do not copy the quickstart's startup table creation into a real application. The sample says so
  itself, in a comment that is easy to drop.
- Do not hand-write CRUD endpoints over an existing schema without first deciding against a
  generated data API.
- Do not leave a one-command grant unexamined. `CONTROL` on the database is not an application role.
- Do not restate driver installation, retry policy, pool sizing, Data API builder configuration or
  binding syntax here. Every one of those has an owner, and duplicating it is how two skills start
  disagreeing.
- Do not answer the local-container version of this question here. That is `azuresql-db-scaffold`.
