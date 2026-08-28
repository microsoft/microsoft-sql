---
name: deploy-app-to-azure
description: >-
  Takes a working local application and its Azure SQL Database to Azure with the Azure Developer
  CLI, reading its infrastructure rather than inheriting it. The one first-party template pairing
  a web app with Azure SQL Database uses a database password and grants db_owner, and the firewall
  rule it ships under an Azure services name spans the whole public address space. Use when a user
  says "deploy my app to Azure", "azd up", "which azd template should I start from", "get this into
  Azure without a password", or when a deployment reported success and the app then fails its first
  database call with a login failure. Covers what each first-party template does about identity,
  what init, provision, deploy and up each do, where the database-side grant belongs, why an
  environment value is not an application setting, and what teardown leaves behind.
  github-actions-for-sql owns pipelines, provision-azure-sql-db owns creating the server and
  database, and entra-id-auth owns the database user and the grant.
---

# Deploy an application and its Azure SQL Database to Azure

**This owns the deployment sequence, and the infrastructure handed to you at the start of it.** It
does not create the database, it does not own the identity, and it is not the pipeline.

Verified on 2026-08-27 against the Azure Developer CLI 1.31.2, by listing the template gallery and
reading the infrastructure of every Microsoft-published template it returns for Azure SQL Database.

## The correction: a first-party template's infrastructure is not a reviewed baseline

An agent treats a Microsoft sample's `infra` directory as settled and spends its attention on the
application code. Asked to reach Azure SQL Database without a password, it recommends the
first-party template as the way to get there.

**That inference is the failure, and it is wrong in two separate ways at once.**

### The only first-party web application template for Azure SQL Database uses a password

The gallery returns 317 templates. The blueprint family is nine of them, named
`todo-<language>-<database>`, and **exactly one is Azure SQL Database**:
`Azure-Samples/todo-csharp-sql`. There is no `todo-nodejs-sql` and no `todo-python-sql`, and
`todo-csharp-cosmos-sql` is Cosmos DB despite the name.

What that one template's `infra/app/db-avm.bicep` actually does:

| It does | Not |
|---|---|
| Provisions the logical server with an `administratorLogin` and a password | Microsoft Entra-only authentication |
| Creates the application's database user with `create user ... with password`, from a deployment script | `CREATE USER ... FROM EXTERNAL PROVIDER` |
| Adds that user to `db_owner` | Any narrower role |
| Stores the resulting connection string, user name and password included, in a vault | A passwordless connection string |

The string `FROM EXTERNAL PROVIDER` does not appear anywhere under its `infra` directory.

**The template does create a managed identity, and that is what makes the misreading survive a
glance.** The identity is real, it is system-assigned to the API, and it is used to read the vault.
What the vault holds is a connection string with a password in it. "It uses managed identity" is
true of the vault and false of the database.

So recommending it as the passwordless starting point is wrong, and converting it is an
infrastructure change rather than an application change: the server's authentication mode, the
deployment script, the role, and the connection string all move together.

### The firewall rule that survives choosing correctly

Every Microsoft-published template here that builds the logical server from the Azure Verified
Module ships the same rule, whatever it does about identity:

| Template | Database authentication | Firewall rule shipped |
|---|---|---|
| `todo-csharp-sql` | Password, `db_owner` | `Azure Services`, `0.0.0.1` to `255.255.255.254` |
| `functions-quickstart-dotnet-azd-sql` | Entra-only, managed identity | The same rule |
| `functions-quickstart-python-azd-sql` | Entra-only, managed identity | The same rule |
| `functions-quickstart-typescript-azd-sql` | Entra-only, managed identity | The same rule |

**That range is every address a client can present.** The rule the name points at is a different
one: the documented Allow Azure services special case is a rule whose start and end address are
both `0.0.0.0`. A rule from `0.0.0.1` to `255.255.255.254` is not a narrower version of it, and it
is not Azure-internal traffic.

**Four of four.** Picking the better template fixes the password and leaves the firewall open, which
is why this is not a note about one bad sample. Narrowing it means the machine running the
post-provision hook now needs a rule of its own. `provision-azure-sql-db` owns authoring firewall
rules; this skill owns catching an inherited one.

### So read the infrastructure before running it

Two greps settle both questions in seconds, and the answer to the first is `0` for the template most
likely to be suggested:

```bash
grep -ri "external provider" ./infra | wc -l     # 0 means the database user is password-based
grep -rn "IpAddress" ./infra                     # read the range, not the rule's name
azd provision --preview                          # what would be created, before it is
```

The per-template detail, including which templates are Microsoft-published rather than community
ones, is in [references/azd-and-azure-sql.md](references/azd-and-azure-sql.md).

**What to copy instead.** The three serverless quickstarts above are the pattern worth taking: an
Entra-only server, the deploying user as administrator, a user-assigned managed identity for the
application, and the grant run from a `postprovision` hook against the user database. Their roles
are `db_datareader`, `db_datawriter` and `db_ddladmin`, narrower than `db_owner` and still wider
than most applications need; `least-privilege-database-roles` owns where to land.

## The seam in the middle, which the good templates exist to close

Once the infrastructure is honest, one gap remains and nothing reports it.

**The deployment tool provisions Azure resources and deploys code. A database user is neither.** The
application's identity exists in Azure and means nothing to the database until somebody runs
`CREATE USER ... FROM EXTERNAL PROVIDER` and grants it roles, inside the database, from a connection
authenticated with Microsoft Entra ID. The run goes green and the application fails at its first
query with a login failure that reads as a bad credential.

`entra-id-auth` owns that statement, its clauses and its error codes. This skill owns **where it
goes in the sequence and how it gets run**.

## The four commands, and what each one actually does

They are conflated constantly. They are not interchangeable.

| Command | What it does | What it does not do |
|---|---|---|
| `init` | Sets up the project files: `azure.yaml`, an `infra` directory, an environment under `.azure`. Either from a template, or from existing code | Create anything in Azure |
| `provision` | Creates the Azure resources from the infrastructure files. Writes the template's outputs into the environment | Deploy any code. Create anything inside the database |
| `deploy` | Pushes built application code to resources that already exist | Create resources. A deploy before a provision has nothing to deploy to |
| `up` | Runs the packaging, provisioning and deployment steps in one command | Anything the individual steps do not do. It is a convenience, not extra behaviour |

**Do not depend on the internal ordering of `up`.** The command's own help text, the commands
overview page and the hooks reference each state a different order for its sub-steps. What is stable
and documented is that provisioning happens before deployment, and that the `postprovision` hook
runs after resources are created. Pin the order explicitly if the project needs it:

```yaml
# azure.yaml
workflows:
  up:
    - azd: provision
    - azd: deploy --all
```

## Step 1: know where the infrastructure is coming from

`azure.yaml` at the project root is the only required file. It names the project and maps each
service to a host and a source directory:

```yaml
name: my-project
services:
  api:
    project: ./src/api
    language: csharp
    host: appservice
```

Provisioning reads Bicep from `./infra` and uses `main.bicep` as the entry point. Both defaults are
overridable under an `infra` key, `path` and `module`.

**That Bicep has to come from somewhere, and there are only two real sources**: a template, read
first on the terms above, or hand-written from Azure Verified Modules.

There is no third option, and this is where an agent invents one:

> **The compose feature cannot create an Azure SQL Database.** Its database resource types are
> Cosmos DB, Azure Cosmos DB for MongoDB, Azure Database for PostgreSQL, Azure Cache for Redis
> and Azure Database for MySQL. There is no Azure SQL Database entry. `azd add` will not produce
> one, and `azd infra generate` only writes out what compose already knows, so it cannot produce
> one either.

Creating the server, the database and the firewall rule with the Azure CLI instead belongs to
`provision-azure-sql-db`.

## Step 2: put the grant between provisioning and deployment

The database user has to exist after the identity and the database do, and before the application
serves its first request. There is exactly one place that is true, and it is the `postprovision`
hook.

```yaml
# azure.yaml
hooks:
  postprovision:
    posix:
      shell: sh
      run: ./infra/scripts/configure-database.sh
      continueOnError: false
    windows:
      shell: pwsh
      run: ./infra/scripts/configure-database.ps1
      continueOnError: false
```

Four things make this work, and each one fails quietly if it is missing.

1. **The infrastructure outputs the identity's name and object id.** A hook is a shell script; it
   can only see what provisioning wrote into the environment.
2. **The hook reads those outputs** from the environment rather than guessing names.
3. **`continueOnError` stays false.** The default is false. Setting it true turns the one step that
   silently matters into a step that silently does not happen.
4. **Whoever runs the hook is administrator of the logical server and authenticated with Microsoft
   Entra ID.** A password-authenticated administrator cannot create a user from an external
   provider.

The full wiring is in [references/azd-and-azure-sql.md](references/azd-and-azure-sql.md). The
statement itself belongs to `entra-id-auth`. Route to it rather than writing the T-SQL from memory.

## Step 3: get the connection string to the application

**An environment value is not an application setting.** The value really is set and really does show
up locally, which is why this reads as success.

| | Where it lives | What reads it |
|---|---|---|
| Environment value | `.azure/<environment>/.env` in the project | Provisioning inputs, hooks, and the local command session |
| Application setting | The deployed application's configuration in Azure | The running application |

The infrastructure has to write it as an application setting. In Bicep that means passing it into
the hosting module:

```bicep
appSettings: {
  AZURE_SQL_CONNECTION_STRING: 'Server=${sqlServer.outputs.fullyQualifiedDomainName}; Database=${databaseName}; Authentication=Active Directory Default; User Id=${apiIdentity.outputs.clientId}'
}
```

Two details carry weight. There is no password and no user name, which is the whole point. And for a
user-assigned managed identity the client id has to be named, because the default credential
otherwise has no way to choose between the identities attached to the host.

The keyword spellings per driver belong to `entra-id-auth` and `connect-to-azure-sql`. Do not guess
them here.

## Step 4: know what teardown does and does not remove

```bash
azd down            # prompts for confirmation
azd down --purge    # also purges resources that are soft-deleted by default
```

It deletes the Azure resources for the environment. It does not delete local project files, and it
does not delete the environment's stored values, so `.azure/<environment>/.env` survives holding
outputs that now name resources that no longer exist.

- **The database goes with everything else.** The data in it is not backed up by this command.
- **A database the project did not create is not deleted**, and the database user created for the
  application identity survives inside it, pointing at a principal that no longer exists.

## Where this stops

| The request | The owner |
|---|---|
| Create the server, database and firewall rule with the Azure CLI | `provision-azure-sql-db` |
| The database user, the grant, the driver keyword spellings, the error codes | `entra-id-auth` |
| Retry, pooling, encryption and connection doctrine | `connect-to-azure-sql` |
| A pipeline that deploys on push or on merge | `github-actions-for-sql` |
| Getting the schema into the database | `schema-migrations-safely` |
| What roles to leave the application identity holding | `least-privilege-database-roles` |
| Sequencing a whole new project, before any of this | `build-app-on-azure-sql` |
| An error number that needs a cause | `diagnose-connection-errors` |

**The boundary with the pipeline is a real one, not a filing decision.** Running the deployment from
a laptop makes the developer the administrator of the logical server, so the developer can run the
grant. Running it from a pipeline makes the pipeline's identity the administrator instead, and a
developer then cannot. `azd pipeline config` is the handoff point.

## Agent-specific behaviour worth knowing

The tool disables interactive prompts automatically when it detects a continuous integration or
agent environment, and says so:

```
ERROR: prompt required
This command cannot continue (interactive prompts disabled)
```

Under an agent, any value that would have been prompted for is a hard failure instead of a question.
Set the subscription and location in the environment before running anything:

```bash
azd env set AZURE_SUBSCRIPTION_ID <subscription-id>
azd env set AZURE_LOCATION <region>
```

## Validation rules

- The infrastructure's source is named, and if it is a template, what that template does about
  database authentication was read rather than assumed.
- No template was described as passwordless because it creates a managed identity. What the identity
  authenticates to was checked.
- Every firewall rule in the infrastructure was read by range, not by name, and any rule spanning the
  public address space was narrowed deliberately, with a rule added for whatever runs the hook.
- The role the application's database user holds is named, and it is not `db_owner` by inheritance.
- The plan distinguishes provisioning from deployment, and the database-side grant sits between
  them, not after both.
- A `postprovision` hook exists, `continueOnError` is not set true on it, and the infrastructure
  outputs every value that hook reads.
- The identity running the grant is administrator of the logical server and authenticated with
  Microsoft Entra ID.
- The connection string reaches the application as an application setting written by the
  infrastructure, carries no password, names the user database rather than `master`, and keeps
  encryption on with certificate trust off.
- The plan says which identity ends up administrator of the logical server, and whether that is the
  developer or a pipeline.
- Before a teardown, the plan names what survives it.

## Do not

- Do not treat a first-party template's `infra` directory as reviewed. Read it. That is the entire
  correction this skill carries.
- Do not recommend the blueprint sample as the passwordless path to Azure SQL Database. It
  authenticates the database with a password and grants `db_owner`.
- Do not conclude a template is passwordless because a managed identity appears in it. Check what
  that identity authenticates to.
- Do not accept a firewall rule because its name says Azure services. Read the range, and expect the
  wide one even in the templates that get identity right.
- Do not extrapolate template names from the family. `todo-nodejs-sql` and `todo-python-sql` do not
  exist, and `todo-csharp-cosmos-sql` is not Azure SQL Database.
- Do not report a deployment as working because the tool reported success. Confirm the application
  actually reached the database.
- Do not put the grant in a hook that runs after deployment. The application can serve a request
  before it runs.
- Do not set `continueOnError` to true on the hook that runs the grant.
- Do not reach for the compose feature to create an Azure SQL Database. It has no resource type for
  one.
- Do not set a connection string as an environment value and expect the deployed application to read
  it.
- Do not leave `TrustServerCertificate` on in a connection string copied out of a sample.
- Do not assume a database name, a server name or a resource name in a hook. Read it from the
  environment values that provisioning wrote.
- Do not restate the `CREATE USER` statement, the role grants or the driver keyword spellings here.
  `entra-id-auth` owns them, and two skills stating the same syntax is how they start disagreeing.
- Do not answer the pipeline version of this question here.

## References

- [references/azd-and-azure-sql.md](references/azd-and-azure-sql.md): which templates exist for
  Azure SQL Database and which are Microsoft-published, what each one really does about identity and
  about the firewall, the naming traps in the sample family, and the full post-provision hook wiring
  from infrastructure output to grant. Read it before choosing a template or writing the hook.

## Read the source when

- **A template is about to be chosen**: the community gallery at `azure.github.io/awesome-azd`, and
  the template listing command, which is the only current statement of what exists. Then read the
  chosen template's own `infra` directory, because the gallery says nothing about what is in it.
- **A firewall rule needs justifying**: the network access controls article on Microsoft Learn,
  which states the address the Allow Azure services rule actually uses.
- **A hook is being written**: the hooks reference on Microsoft Learn, which carries the full list of
  hook names and their configuration options.
- **An environment value is not arriving where it was expected**: the environment variables article
  on Microsoft Learn.

## Checklist before reporting success

- [ ] Infrastructure exists and its source is named: a template, or written by hand
- [ ] If a template, its database authentication was read, and it is not password-based by default
- [ ] Every firewall rule was read by range, and narrowed if it spanned the public address space
- [ ] The role held by the application's database user is named, and it is not `db_owner`
- [ ] The database user for the application identity was created, and the roles it holds are named
- [ ] That step ran between provisioning and deployment, from a hook that cannot be skipped silently
- [ ] The connection string is an application setting written by the infrastructure, with no secret
- [ ] The application was observed reaching the database, not just deployed
- [ ] The administrator of the logical server is known and stated
