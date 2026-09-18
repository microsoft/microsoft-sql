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

Verified 2026-09-03 against the Azure Developer CLI 1.32.0, Azure CLI 2.90.0, sqlcmd 1.10.0 and
.NET 8.0.421, by listing the template gallery and reading the shipped Bicep of every
Microsoft-published template it returns for Azure SQL Database.

## The correction: a first-party template's infrastructure is not a reviewed baseline

An agent treats a Microsoft sample's `infra` directory as settled, spends its attention on the
application code, and asked to reach Azure SQL Database without a password recommends the
first-party template as the way to get there. **That inference is wrong in two separate ways at
once**, and every claim below is settled by a command rather than by reading.

### Ask the gallery what exists, do not extrapolate from the family

```bash
azd version
azd template list --output json | grep -c '"Azure-Samples/todo-'
```

Measured 2026-09-18: 303 templates, **zero** `todo-` entries. The family was archived 2026-09-04 and
left the gallery 2026-09-08, yet `azd init -t todo-csharp-sql` still initializes it and Microsoft
Learn still lists it, so users still arrive with it. `todo-csharp-cosmos-sql` is Cosmos DB for
NoSQL. **`todo-nodejs-sql` and `todo-python-sql` never existed.**

### The archived web application blueprint for Azure SQL Database uses a password

Read its infrastructure without cloning it:

```bash
curl -s https://raw.githubusercontent.com/Azure-Samples/todo-csharp-sql/main/infra/app/db-avm.bicep \
  | grep -n -i "administratorLogin\|create user\|db_owner\|external provider"
```

Measured 2026-09-03: `administratorLogin`, `create user ${APPUSERNAME} with password`,
`alter role db_owner add member`, and zero hits for `external provider`.

| It does | Not |
|---|---|
| Provisions the logical server with an `administratorLogin` and a password | Microsoft Entra-only authentication |
| Creates the application's database user with a password, from a deployment script | `CREATE USER ... FROM EXTERNAL PROVIDER` |
| Adds that user to `db_owner` | Any narrower role |
| Stores the connection string, user name and password included, in a vault | A passwordless connection string |

**The template does create a managed identity, and that is what makes the misreading survive a
glance.** It is system-assigned to the API and it reads the vault. What the vault holds is a
connection string with a password in it. "It uses managed identity" is true of the vault and false
of the database. Converting the template is an infrastructure change, not an application one: the
server's authentication mode, the deployment script, the role and the connection string all move
together.

### The firewall rule that survives choosing correctly

```bash
for r in todo-csharp-sql:app/db-avm.bicep \
         functions-quickstart-dotnet-azd-sql:app/db.bicep \
         functions-quickstart-python-azd-sql:app/db.bicep \
         functions-quickstart-typescript-azd-sql:app/db.bicep; do
  printf '%-42s ' "${r%%:*}"
  curl -s "https://raw.githubusercontent.com/Azure-Samples/${r%%:*}/main/infra/${r##*:}" \
    | grep -c "startIpAddress: '0.0.0.1'"
done
```

**Four of four**, measured 2026-09-03: `1` on every line. All four build the logical server from
the Azure Verified Module and all four ship a rule named `Azure Services` running `0.0.0.1` to
`255.255.255.254`, **every address a client can present**. Three are Entra-only with a managed
identity and are otherwise the ones to copy, so picking the better template fixes the password and
leaves the firewall open.

**The name points at a different rule.** The Azure CLI's own help for `--start-ip-address` says to
use `0.0.0.0` to represent all Azure-internal IP addresses, and Microsoft Learn records the Allow
Azure services special case as a rule whose start and end address are both `0.0.0.0`. A rule from
`0.0.0.1` to `255.255.255.254` is not a narrower version of it.

**Say this to the user, then let them decide.** These are Microsoft-published samples and are not
ours to edit on someone's behalf. Name the rule out loud and offer to narrow it:

```bash
az sql server firewall-rule list -g <group> -s <server> -o table
az sql server firewall-rule delete -g <group> -s <server> -n "Azure Services"

# the documented Allow Azure services case, if Azure-internal traffic is what was meant
az sql server firewall-rule create -g <group> -s <server> -n AllowAzureServices \
  --start-ip-address 0.0.0.0 --end-ip-address 0.0.0.0

# and the developer machine, if it connects directly
az sql server firewall-rule create -g <group> -s <server> -n dev-box \
  --start-ip-address <your-ip> --end-ip-address <your-ip>
```

**Narrow it after the first successful deployment, not before.** The post-provision hook runs from
a machine that then needs a rule of its own, and without one it fails as a timeout rather than as a
permission error. The three Functions quickstarts ship `infra/scripts/addclientip.ps1` for exactly
this. `provision-azure-sql-db` owns authoring firewall rules; this skill owns catching an inherited
one.

### On any other template, run the same two greps before running anything

```bash
grep -ri "external provider" ./infra | wc -l   # 0 means the database user is password-based
grep -rn "IpAddress" ./infra                   # read the range, not the rule's name
azd provision --preview                        # what would be created, before it is
```

Open [references/azd-and-azure-sql.md](references/azd-and-azure-sql.md) **before** choosing a
template or writing the hook: it carries the per-template evidence, which templates are
Microsoft-published rather than community ones, and the hook wiring end to end.

**What to copy instead.** The three serverless quickstarts are the pattern worth taking: an
Entra-only server, the deploying user as administrator, a user-assigned managed identity for the
application, and the grant run from a `postprovision` hook against the user database. Their roles
are `db_datareader`, `db_datawriter` and `db_ddladmin`, still wider than most applications need;
`least-privilege-database-roles` owns where to land.

## The seam in the middle, which the good templates exist to close

**The deployment tool provisions Azure resources and deploys code. A database user is neither.** The
application's identity means nothing to the database until somebody runs
`CREATE USER ... FROM EXTERNAL PROVIDER` and grants it roles, inside the database, from a connection
authenticated with Microsoft Entra ID. Until then the run goes green and the application fails at
its first query with a login failure that reads as a bad credential.

`entra-id-auth` owns that statement, its clauses and its error codes. **Open it when you are about
to write the grant.** This skill owns where the grant goes in the sequence and how it gets run.

## The four commands, and what each one actually does

| Command | What it does | What it does not do |
|---|---|---|
| `init` | Sets up `azure.yaml`, an `infra` directory, an environment under `.azure`, from a template or from existing code | Create anything in Azure |
| `provision` | Creates the Azure resources and writes the template's outputs into the environment | Deploy code. Create anything inside the database |
| `deploy` | Pushes built application code to resources that already exist | Create resources. A deploy before a provision has nothing to deploy to |
| `up` | Runs packaging, provisioning and deployment in one command | Anything the individual steps do not do. It is a convenience, not extra behaviour |

Keeping the two halves apart is how you debug them. Build the artifact yourself and hand it over:

```bash
dotnet publish ./src/api -c Release -o ./artifacts/api
azd deploy api --from-package ./artifacts/api
```

**Do not depend on the internal ordering of `up`.** `azd up --help` calls it package, provision and
deploy; the hooks reference on Microsoft Learn calls it restore, provision and deploy. What is
stable is that provisioning happens before deployment and that `postprovision` runs after resources
are created. Pin the order explicitly if the project needs it, in the shape the command's own help
gives:

```yaml
# azure.yaml
workflows:
  up:
    - azd: provision
    - azd: package --all
    - azd: deploy --all
```

## Step 1: know where the infrastructure is coming from

`azure.yaml` at the project root is the only required file, mapping each service to a host and a
source directory:

```yaml
name: my-project
services:
  api:
    project: ./src/api
    language: csharp
    host: appservice
```

Provisioning reads Bicep from `./infra` with `main.bicep` as the entry point, both overridable
under an `infra` key, `path` and `module`.

**That Bicep has to come from somewhere, and there are only two real sources**: a template, read
first on the terms above, or hand-written from Azure Verified Modules. There is no third option,
and this is where an agent invents one:

> **The compose feature cannot create an Azure SQL Database.** Its database resource types are
> Azure Cosmos DB, Azure Cosmos DB for MongoDB, Azure Cosmos DB for PostgreSQL, Azure Cache for
> Redis and Azure Database for MySQL. There is no Azure SQL Database entry, so `azd add` will not
> produce one, and `azd infra generate` only writes out what compose already knows.

Creating the server, the database and the firewall rule with the Azure CLI instead belongs to
`provision-azure-sql-db`.

## Step 2: put the grant between provisioning and deployment

The database user has to exist after the identity and the database do, and before the application
serves its first request. There is exactly one place that is true, and it is the `postprovision`
hook, registered at the project root rather than inside a service:

```yaml
# azure.yaml
hooks:
  postprovision:
    posix:
      shell: sh
      run: ./infra/scripts/configure-database.sh
      continueOnError: false
      interactive: false
    windows:
      shell: pwsh
      run: ./infra/scripts/configure-database.ps1
      continueOnError: false
      interactive: false
```

Inside the script, read what provisioning wrote and authenticate as the identity that provisioned:

```bash
eval "$(azd env get-values | sed 's/^/export /')"
sqlcmd -S "$AZURE_SQL_SERVER_NAME" -d "$AZURE_SQL_DATABASE_NAME" \
  --authentication-method ActiveDirectoryAzureDeveloperCli \
  -i ./infra/scripts/grant-app-identity.sql
```

Develop that hook on its own, without reprovisioning:

```bash
azd hooks run postprovision
```

Four things make this work, and each fails quietly if it is missing.

1. **The infrastructure outputs the identity's name and principal id**, because a hook is a shell
   script and can only see what provisioning wrote into the environment.
2. **The hook reads those outputs** rather than guessing resource names.
3. **`continueOnError` stays false.** Setting it true turns the one step that silently matters into
   a step that silently does not happen.
4. **Whoever runs the hook is administrator of the logical server, authenticated with Microsoft
   Entra ID.** `-G` alone falls back to `ActiveDirectoryDefault`, which can pick a different
   signed-in identity than the one that just provisioned; naming the method is what pins it.

## Step 3: get the connection string to the application

**An environment value is not an application setting.** The value really is set and really does show
up locally, which is why this reads as success.

| | Where it lives | What reads it |
|---|---|---|
| Environment value | `.azure/<environment>/.env` in the project | Provisioning inputs, hooks, and the local command session |
| Application setting | The deployed application's configuration in Azure | The running application |

The infrastructure has to write it as an application setting, which in Bicep means passing it into
the hosting module:

```bicep
appSettings: {
  AZURE_SQL_CONNECTION_STRING: 'Server=${sqlServer.outputs.fullyQualifiedDomainName}; Authentication=Active Directory Default; Database=${databaseName}; User Id=${apiIdentity.outputs.clientId}'
}
```

That is the shape Microsoft Learn gives for a function app reaching Azure SQL Database with a
managed identity. There is no password and no user name, which is the whole point. For a
user-assigned identity the **client** id has to be named, because the default credential otherwise
cannot choose between the identities attached to the host; for a system-assigned one, `User Id` is
omitted instead. The client id is not the principal id the grant uses.

**Open `connect-to-azure-sql` when the driver is not `Microsoft.Data.SqlClient`**: the keyword
spellings differ per driver and are not guessable.

## Step 4: know what teardown does and does not remove

```bash
azd down                    # prompts for confirmation
azd down --purge            # also permanently deletes resources that are soft-deleted by default
azd down --force --purge    # no confirmation at all
```

It deletes the Azure resources for the environment, not local project files and not the
environment's stored values, so `.azure/<environment>/.env` survives holding outputs that now name
resources that no longer exist. **The database goes with everything else** and its data is not
backed up by this command. **A database the project did not create is not deleted**, and the
database user created for the application identity survives inside it, pointing at a principal that
no longer exists.

## Check it worked

A green run is not the check. Four things, in this order, and the last one is the only one that
settles it.

```bash
azd env get-values | grep -i sql   # provisioning wrote the server and database names
azd show                           # the resources azd believes it owns
az sql server ad-admin list -g <group> -s <server> -o table
az sql server firewall-rule list -g <group> -s <server> -o table
az webapp config appsettings list -g <group> -n <app-name> \
  --query "[?name=='AZURE_SQL_CONNECTION_STRING'].name" -o tsv
```

Expect a server and database name in the environment, a named Entra administrator, no rule wider
than you chose, and the setting present on the deployed application. An empty result from the last
command is the Step 3 failure: the value exists locally and never reached Azure.

Then confirm the database user exists, connected to the **user database** and not `master`:

```sql
SELECT p.name, p.authentication_type_desc, r.name AS role_name
FROM sys.database_principals AS p
LEFT JOIN sys.database_role_members AS m ON m.member_principal_id = p.principal_id
LEFT JOIN sys.database_principals AS r ON r.principal_id = m.role_principal_id
WHERE p.name = '<identity-name>';
```

Expect at least one row, `authentication_type_desc` reading `EXTERNAL`, and named roles that are not
`db_owner`. **Zero rows is the seam**: the grant did not run, or it ran against `master`. Finish by
calling an application endpoint that reads the database, because only the application proves its own
identity works.

## Under an agent, prompts are failures

`azd` documents `--no-prompt` on every command as automatically enabled when it detects a CI/CD or
AI-agent environment, failing if any required value cannot be resolved (`AZD_NON_INTERACTIVE=false`
opts out). So under an agent, any value that would have been prompted for is a hard failure. Set
them before running anything:

```bash
azd env new <environment-name>
azd env set AZURE_SUBSCRIPTION_ID <subscription-id>
azd env set AZURE_LOCATION <region>
```

Hooks are the other half, and the two Learn pages disagree: the hooks reference says hooks run in
interactive mode by default, the schema reference says `interactive` defaults to false. Set it
explicitly on any hook that runs unattended rather than relying on either.

## Where this stops

| The request | The owner |
|---|---|
| Create the server, database and firewall rule with the Azure CLI | `provision-azure-sql-db` |
| The database user, the grant, the driver keywords, the error codes | `entra-id-auth` |
| Retry, pooling and encryption doctrine | `connect-to-azure-sql` |
| A pipeline that deploys on push or on merge | `github-actions-for-sql` |
| Getting the schema into the database | `schema-migrations-safely` |
| What roles to leave the application identity holding | `least-privilege-database-roles` |
| Sequencing a whole new project, before any of this | `build-app-on-azure-sql` |

**The boundary with the pipeline is a real one, not a filing decision.** Deploying from a laptop
makes the developer administrator of the logical server, so the developer can run the grant.
Deploying from a pipeline makes the pipeline's identity administrator instead, and a developer then
cannot. `azd pipeline config` is the handoff point.

## Do not

- Do not treat a first-party template's `infra` directory as reviewed, and do not call one
  passwordless because a managed identity appears in it. Check what that identity authenticates to.
- Do not accept a firewall rule because its name says Azure services. Read the range, and expect the
  wide one even in the templates that get identity right.
- Do not extrapolate template names from the family, and do not report a deployment as working
  because the tool reported success.
- Do not put the grant in a hook that runs after deployment, and do not set `continueOnError` true
  on it. The application can serve a request before it runs.
- Do not set a connection string as an environment value and expect the deployed application to read
  it, and do not leave `TrustServerCertificate` on in one copied out of a sample.
- Do not assume a database, server or resource name in a hook. Read it from the environment values
  that provisioning wrote.
- Do not restate the `CREATE USER` statement, the role grants or the driver keyword spellings here.
  `entra-id-auth` owns them, and two skills stating the same syntax is how they start disagreeing.

## References

- [references/azd-and-azure-sql.md](references/azd-and-azure-sql.md): open it before choosing a
  template, before writing the post-provision hook, or when a claim above disagrees with what you
  are seeing. It carries the per-template evidence, which templates are Microsoft-published, the
  naming traps, and the hook wiring from infrastructure output to grant.
- `azd template list` and the community gallery at `azure.github.io/awesome-azd` are the only
  current statement of what templates exist. List them rather than recalling them.
- [Hooks reference](https://learn.microsoft.com/azure/developer/azure-developer-cli/azd-extensibility)
  and [azure.yaml schema](https://learn.microsoft.com/azure/developer/azure-developer-cli/azd-schema),
  when a hook name or option is in question;
  [environment variables](https://learn.microsoft.com/azure/developer/azure-developer-cli/manage-environment-variables)
  when a value is not arriving where it was expected;
  [network access controls](https://learn.microsoft.com/azure/azure-sql/database/network-access-controls-overview)
  when a firewall rule needs justifying.
