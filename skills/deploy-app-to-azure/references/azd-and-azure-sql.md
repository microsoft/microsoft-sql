# Templates, and the post-provision grant wiring

## Contents

- [Templates that actually exist for Azure SQL Database](#templates-that-actually-exist-for-azure-sql-database)
- [The naming trap in the sample family](#the-naming-trap-in-the-sample-family)
- [What the first-party templates really do about identity](#what-the-first-party-templates-really-do-about-identity)
- [The firewall rule that survives choosing correctly](#the-firewall-rule-that-survives-choosing-correctly)
- [The post-provision grant, end to end](#the-post-provision-grant-end-to-end)
- [Failure table for the wiring](#failure-table-for-the-wiring)

## Templates that actually exist for Azure SQL Database

Verified on 2026-08-27 by listing templates from the gallery, which returned 317 entries, and
filtering them. Template names and repositories move, so confirm before generating a project:

```bash
azd template list -f azuresql
```

The Microsoft-published ones that use Azure SQL Database:

| Repository | What it is |
|---|---|
| `Azure-Samples/todo-csharp-sql` | The blueprint sample: React front end, C# API, Azure SQL Database |
| `Azure-Samples/functions-quickstart-dotnet-azd-sql` | Serverless, triggers and bindings, .NET |
| `Azure-Samples/functions-quickstart-python-azd-sql` | The same, Python |
| `Azure-Samples/functions-quickstart-typescript-azd-sql` | The same, TypeScript |
| `Azure-Samples/azure-sql-db-session-recommender-v2` | Vector search and retrieval over Azure SQL Database |
| `Azure-Samples/blazor-azure-sql-vector-search` | Blazor with hybrid vector search |
| `Azure-Samples/nlp-sql-in-a-box` | Natural language over Azure SQL Database |

Anything else in that filtered list is community-published rather than Microsoft-published, which is
worth saying to a user before it becomes the starting point for their project.

## The naming trap in the sample family

The blueprint samples are named `todo-<language>-<database>`. There are nine of them. **Only one
uses Azure SQL Database**, and it is the C# one. Every other entry in the family is MongoDB or
Cosmos DB.

Two specific mistakes follow from this, and both look reasonable:

- **`todo-nodejs-sql` and `todo-python-sql` do not exist.** An agent extrapolating from the family's
  naming will produce a template name that fails at initialization. There is no first-party
  blueprint sample pairing Node.js or Python with Azure SQL Database. The serverless quickstarts
  above are the closest first-party starting points for those languages.
- **`todo-csharp-cosmos-sql` is not an Azure SQL Database template.** The `sql` in that name is
  Cosmos DB for NoSQL, and its own listed description says the database is MongoDB. Selecting it
  because the name contains `sql` produces a project with the wrong database entirely.

## What the first-party templates really do about identity

SKILL.md carries the headline. This is the per-template evidence behind it, gathered by reading each
`infra` directory on 2026-08-27, because the two generations of template differ completely.

**The blueprint sample is password-based.** `infra/app/db-avm.bicep` provisions the logical server
with `administratorLogin` and a password. A deployment script then creates the application's
contained user with `create user ... with password` and runs `alter role db_owner add member`. The
string `FROM EXTERNAL PROVIDER` does not appear anywhere under `infra`. The application's managed
identity exists and is system-assigned, but its access policy is on the vault, and the secret the
vault holds is a connection string containing the user name and the password. Recommending this as
the passwordless path is wrong. Converting it moves the server's authentication mode, the deployment
script, the role and the connection string together, so it is an infrastructure change rather than
an application change.

**The serverless quickstarts are identity-based.** They create the logical server with
`azureADOnlyAuthentication` on, make the deploying user the administrator, create a user-assigned
managed identity for the application, and run the grant from a post-provision hook. Microsoft ships
the remediation for the seam in these three as `infra/scripts/sql_add_uami_user.sql`. That is the
pattern worth copying. Their granted roles are `db_datareader`, `db_datawriter` and `db_ddladmin`,
narrower than the blueprint's `db_owner` and still wider than most applications need;
`least-privilege-database-roles` owns what to leave in place.

## The firewall rule that survives choosing correctly

| Template | Server module | Database authentication | Firewall rule shipped |
|---|---|---|---|
| `todo-csharp-sql` | Azure Verified Module | Password, `db_owner` | `Azure Services`, `0.0.0.1` to `255.255.255.254` |
| `functions-quickstart-dotnet-azd-sql` | Azure Verified Module | Entra-only, managed identity | The same rule |
| `functions-quickstart-python-azd-sql` | Azure Verified Module | Entra-only, managed identity | The same rule |
| `functions-quickstart-typescript-azd-sql` | Azure Verified Module | Entra-only, managed identity | The same rule |
| `azure-sql-db-session-recommender-v2` | Hand-written | Entra-based | `0.0.0.0` to `0.0.0.0` |
| `blazor-azure-sql-vector-search` | Hand-written | | No rule in `infra` |
| `nlp-sql-in-a-box` | Hand-written | | The deployer's own address |

**Four of four**, and the split follows the module rather than the identity story: every template
that builds the logical server from the Azure Verified Module ships the wide rule, including the
three that are otherwise the ones to copy. Choosing the better template fixes the password and
leaves the firewall open. The range is not in the module's own documented examples, so it travels
with the samples rather than with the module.

**The name points at a different rule.** The documented Allow Azure services special case is a
server-level rule whose start and end address are both `0.0.0.0`. Microsoft Learn already calls that
one more permissive than most customers want. A rule from `0.0.0.1` to `255.255.255.254` is not a
narrower version of it; it is every address a client can present.

Narrowing it means whatever runs the post-provision hook now needs a rule of its own, or the hook
fails as a timeout. `provision-azure-sql-db` owns authoring firewall rules and their latency; this
skill owns catching an inherited one.

### Where it is, verified 2026-08-29

All four repositories were cloned and read on that date.

| Template | File | Condition |
|---|---|---|
| `todo-csharp-sql` | `infra/app/db-avm.bicep`, line 42 | unconditional |
| `functions-quickstart-dotnet-azd-sql` | `infra/app/db.bicep`, line 53 | only when `vnetEnabled` is false |
| `functions-quickstart-python-azd-sql` | `infra/app/db.bicep`, line 53 | only when `vnetEnabled` is false |
| `functions-quickstart-typescript-azd-sql` | `infra/app/db.bicep`, line 53 | only when `vnetEnabled` is false |

The literal shipped in all four:

```bicep
{
  name: 'Azure Services'
  startIpAddress: '0.0.0.1'
  endIpAddress: '255.255.255.254'
}
```

**These are Microsoft-published samples and this skill does not change them.** The rule is
inherited, the user is told about it, and narrowing it is their decision after the first
successful `azd up`. The main body carries the commands.

## The post-provision grant, end to end

Four pieces, in order. The whole thing fails silently if any one is missing.

**1. The infrastructure creates the identity and outputs what the hook needs.** A hook is a shell
script and can only see values that provisioning wrote into the environment:

```bicep
output AZURE_SQL_SERVER_NAME string = sqlServer.outputs.fullyQualifiedDomainName
output AZURE_SQL_DATABASE_NAME string = databaseName
output APP_IDENTITY_NAME string = apiIdentity.outputs.name
output APP_IDENTITY_PRINCIPAL_ID string = apiIdentity.outputs.principalId
output APP_IDENTITY_CLIENT_ID string = apiIdentity.outputs.clientId
```

The principal id is what identifies the identity to the database **in the `FROM EXTERNAL PROVIDER`
and `WITH OBJECT_ID` forms used here**. The client id is what goes into the application's connection
string. They are different values and they are not interchangeable.

The `WITH SID` form does not follow the same rule: for a service principal or a managed identity it
takes the **client** id, not the principal id. That form and the reasons to reach for it belong to
`entra-id-auth`, which carries the full table. Do not carry this section's rule across to it.

**2. The infrastructure makes the deploying identity administrator of the logical server**, with
Microsoft Entra-only authentication on. Without this the hook has no way to authenticate as
something that is allowed to create a user from an external provider.

**3. `azure.yaml` registers the hook at the project root**, not inside a service. A service hook is
scoped to that service's lifecycle; the grant is not.

```yaml
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

**4. The script reads the outputs and runs the statement** against the user database, authenticating
with Microsoft Entra ID:

```bash
#!/usr/bin/env sh
set -eu

# Read what provisioning wrote, rather than guessing resource names.
eval "$(azd env get-values | sed 's/^/export /')"

# The statement, its required clauses and its error codes belong to entra-id-auth.
# Run it against the USER database, never master.
sqlcmd -S "$AZURE_SQL_SERVER_NAME" -d "$AZURE_SQL_DATABASE_NAME" -G \
  -v IDENTITY_NAME="$APP_IDENTITY_NAME" PRINCIPAL_ID="$APP_IDENTITY_PRINCIPAL_ID" \
  -i ./infra/scripts/grant-app-identity.sql
```

The hook can be run on its own while developing it, without a full provision:

```bash
azd hooks run postprovision
```

## Failure table for the wiring

| What is missing | What you see |
|---|---|
| The identity's principal id is not an output | The script reads an empty value and creates a user that resolves to nothing, or fails on a blank argument |
| The hook is registered on a service instead of the project root | It runs for that service's lifecycle, and never for a provision-only run |
| `continueOnError` is set true | The grant fails, the deployment stays green, the application fails at its first query |
| The deploying identity is not administrator of the logical server | The statement is refused, and the message points at permissions rather than at the deployment |
| The machine running the hook has no firewall rule | The script cannot reach the database at all, and the message reads as a timeout |
| The grant runs against `master` | It succeeds, and the application still cannot log in, because the user was created in the wrong database |
| The connection string names the principal id instead of the client id | The application's credential cannot select the identity, and the failure looks like a bad connection string |
