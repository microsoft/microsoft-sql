---
name: github-actions-for-sql
description: >-
  Ships schema changes to Azure SQL Database from a GitHub Actions workflow with
  `azure/sql-action`: building the database project or publishing a prebuilt dacpac, federating
  the workflow's token so no database password or client secret is stored, getting a runner with
  a changing address through the server firewall, and gating the deployment on an environment.
  Use when a user asks to "deploy my database project from GitHub Actions", "publish a dacpac on
  merge", "set up OIDC login to Azure for my pipeline", "stop storing a SQL password in secrets",
  or "require an approval before the schema deploys", and when a run fails with "no matching
  federated identity record found for presented assertion subject", a login error naming
  `auth-type`, or "unable to detect client IP address". sql-database-projects owns the project
  and publish options, entra-id-auth the database user and its grant.
---

# Deploy schema to Azure SQL Database from GitHub Actions

**This owns the pipeline: the workflow, the login, the firewall and the gate.** Not the project
(`sql-database-projects`), the sequencing of a schema change (`schema-migrations-safely`), the
database-side grant (`entra-id-auth`), or the application (`deploy-app-to-azure`).

Checked 2026-09-03 against `azure/sql-action` at tag `v2.4`, commit `eb1f9a80`, still the newest
tag; SqlPackage 170.4.83.3; sqlcmd 1.10.0; Azure CLI 2.90.0.

## The action is three commands. Run them yourself first

| Input | Notes |
|---|---|
| `connection-string` | **required**. This is where the authentication method is chosen |
| `path` | **required**. `.sql`, `.dacpac` or `.sqlproj`. A glob is allowed and must match exactly one file |
| `action` | **required for `.dacpac` and `.sqlproj`**. `Publish`, `Script`, `DriftReport`, `DeployReport`, nothing else |
| `arguments` | appended verbatim to the deployment command line, or to the sqlcmd line for a `.sql` path |
| `build-arguments` | appended to `dotnet build` when the path is a project |
| `skip-firewall-check` | default `false` |
| `sqlpackage-path` | point at a SqlPackage the runner already carries |

The action shells out. These are the three command lines it composes, read from `src/SqlUtils.ts`
and `src/AzureSqlAction.ts` at `v2.4`. A red run that reproduces on a laptop is not a pipeline
problem.

```bash
sqlcmd -S <server>.database.windows.net,1433 -d master \
  --authentication-method=ActiveDirectoryDefault \
  -Q "SELECT 'Validating connection from GitHub SQL Action'"
```

That is the firewall probe, not the deployment, and it runs against `master` first, the target
database second. Then the build, for a `.sqlproj` path only:

```bash
dotnet build "./db/ShopDb.sqlproj" -p:NetCoreBuild=true
```

Then the deployment, and this is the whole argument list rather than an excerpt of one:

```bash
sqlpackage /Action:Publish \
  /TargetConnectionString:"Server=tcp:<server>.database.windows.net,1433;Initial Catalog=<database>;Authentication=Active Directory Default;Encrypt=True;" \
  /SourceFile:"./db/bin/Debug/ShopDb.dacpac"
```

`arguments:` is appended to that line, which is how `/p:BlockOnPossibleDataLoss=true` reaches the
deployment. Which properties each action accepts is `sqlpackage-import-export`; open it before
writing a `/p:` you have not seen in that build's own help output. Four things that shape is
quietly telling you:

- **The output path is guessed, not asked for.** The action looks for
  `<project dir>/bin/<configuration>/<project name>.dacpac`, configuration defaulting to `Debug`,
  so an output redirected inside the project file rather than through `build-arguments` leaves it
  looking in the wrong place.
- **`Extract`, `Import` and `Export` are refused**, real SqlPackage actions though they are:
  `Action Extract is invalid. Supported action types are: Publish, Script, DriftReport, or DeployReport.`
- **The runner ships sqlcmd but not the deployment tool.** The action downloads `go-sqlcmd` 1.6.0
  into the tool cache itself; nothing brings SqlPackage, and on Linux the action calls the bare
  name on `PATH`. One step fixes it with no path override, because `~/.dotnet/tools` is already on
  `PATH` on the hosted image: `dotnet tool install -g microsoft.sqlpackage`.
- **macOS runners are refused** for the dacpac and project paths:
  `This action is not supported on a Mac environment.`

## Authenticating without a stored password

Two different secrets are being avoided. **A database password** goes away with an identity-based
keyword in the connection string: `Active Directory Default` picks up the login step's
credentials, where `Active Directory Password` and `Active Directory Service Principal` put a
secret back and a plain user and password puts the database password back. **A client secret**
goes away by federating the workflow's token, which needs `permissions: id-token: write` in the
workflow below, without which there is no token to exchange.

## The correction: read the subject claim, do not compose it

The credential matches on issuer, audience and subject. The subject is the one that goes wrong,
and composing it from the documented `repo:OWNER/REPO:ref:refs/heads/main` is the failure. Ask the
repository what prefix it presents instead:

```bash
gh api repos/OWNER/REPO/actions/oidc/customization/sub
```

Measured 2026-09-03 across twelve repositories in one account: eleven answered with the plain
name-based prefix, and the twelfth, one that had been renamed, answered with numeric ids in it:

```json
{"use_default":true,"use_immutable_subject":false,"sub_claim_prefix":"repo:OWNER@<ownerId>/REPO@<repoId>"}
```

**Both flags say the default is in force and the shape is still different.** GitHub's OIDC
reference explains why: repositories created, renamed or transferred after 15 July 2026 get an
immutable default subject built from owner and repository ids, and `use_immutable_subject` reports
only the separate opt-in, not the shape. Learn covers the Azure side under
[immutable subjects](https://learn.microsoft.com/entra/workload-id/workload-identities-github-immutable-subjects).
So a template works on eleven repositories and silently fails on the twelfth, which is worse than
failing everywhere.

Take `sub_claim_prefix` and append the job segment: `:ref:refs/heads/<branch>`,
`:ref:refs/tags/<tag>`, `:environment:<name>`, or `:pull_request`. A job naming an environment
presents `:environment:<name>` **in place of** the ref segment, not in addition, so the two jobs
below need two credentials.

```bash
az identity federated-credential create \
  --name gh-deploy-production --identity-name <identity> -g <resource group> \
  --issuer "https://token.actions.githubusercontent.com" \
  --subject "<the prefix>:environment:production" \
  --audiences "api://AzureADTokenExchange"
```

Copy the prefix rather than retyping it: Learn records that credential matching became
case-sensitive in September 2024, so a name typed in the wrong case fails with no other symptom.

A flexible federated identity credential can cover several job shapes at once by wildcard-matching
`sub` alongside `repository_id` or `repository_owner_id`. Learn calls it preview, application
objects only, and says Azure CLI errors on it, while Azure CLI 2.90.0 here exposes
`--claims-matching-expression-value`. The two disagree, so measure before planning around it.

### The error names the wrong thing

A subject that does not match produces `AADSTS700213: No matching federated identity record found
for presented assertion subject '<the subject>'`. **That line is the most useful thing in the run,
because it quotes the subject actually presented.** Copy it into the credential. The line right
after it is the misleading one:

```text
##[error]Login failed with Error: The process '/usr/bin/az' failed with exit code 1.
Double check if the 'auth-type' is correct.
```

`auth-type` is an input of the login step and is not the problem. An agent reading only the last
error changes it, or reaches for a client secret to go green, throwing away the point of
federating. Read upward to the AADSTS line and read its number: a directory can also refuse on
policy grounds, and that refusal is not fixable in the subject at all.

## The firewall problem, and why it disguises the last one

A hosted runner's public address changes between runs, so a fixed rule is not an option. What the
action does instead:

1. Runs the `sqlcmd` probe above, against `master` first and the target database second.
2. If that fails, it searches the **error text** for an IPv4 address and adds a server-level rule
   named `ClientIPAddress_<year>-<month>-<day>_<address>` for exactly that address.
3. It deploys, then drops the rule in a `finally` block, including when the deployment failed.

Two consequences follow, and the second wastes the most time.

**It needs a role on the server resource.** Adding a rule is a control-plane call, so the login
step must have run and the identity must be able to write firewall rules on the logical server.
Without that, the deployment fails at a step that is not the deployment.

**Any login failure is reported as a firewall failure.** If the probe fails for a reason other
than the firewall, the error carries no address, and the action raises
`Failed to add firewall rule. Unable to detect client IP Address. <the underlying error>`. That
message is about the firewall. The cause is usually the credential. Read past the first sentence.

The two alternatives both pair with `skip-firewall-check: true`: a self-hosted runner on a fixed
address, which costs infrastructure and leaves a standing rule, or one reaching a private
endpoint, which exposes nothing publicly and is the most to set up. Allowing all Azure services is
not on that list on purpose. It is not a narrow rule.

## Environment approvals, and what they do not protect

The gate holds the job that names it, and nothing else in the workflow:

- **Another job reads the same repository secrets.** They are available to every job, so anything
  reachable with them is reachable without waiting. Put the deployment credential in
  **environment** secrets, so the gate and the credential cover the same ground.
- **The credential subject is the real binding.** A subject ending `:environment:production`
  cannot be exchanged by a job that does not name that environment. That is enforcement, where
  the approval is only a pause.
- **The rule may not exist at all.** A required-reviewer rule on a private repository whose plan
  excludes it is refused with `Failed to create the environment protection rule.` The environment
  is still created, the workflow still references it, and every job runs unblocked. Read the
  protection rules back rather than assuming the environment implies them.

## A workflow shape that holds together

```yaml
name: deploy-schema
on:
  push:
    branches: [main]
permissions:
  id-token: write
  contents: read
jobs:
  plan:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: dotnet tool install -g microsoft.sqlpackage
      - uses: azure/login@v2
        with:
          client-id: ${{ secrets.AZURE_CLIENT_ID }}
          tenant-id: ${{ secrets.AZURE_TENANT_ID }}
          subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
      - uses: azure/sql-action@v2.4
        with:
          connection-string: ${{ secrets.SQL_CONNECTION_STRING }}
          path: ./db/ShopDb.sqlproj
          action: DeployReport
  deploy:
    needs: plan
    runs-on: ubuntu-latest
    environment: production      # this changes the subject claim
    steps:
      - uses: actions/checkout@v4
      - run: dotnet tool install -g microsoft.sqlpackage
      - uses: azure/login@v2
        with:
          client-id: ${{ secrets.AZURE_CLIENT_ID }}
          tenant-id: ${{ secrets.AZURE_TENANT_ID }}
          subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
      - uses: azure/sql-action@v2.4
        with:
          connection-string: ${{ secrets.SQL_CONNECTION_STRING }}
          path: ./db/ShopDb.sqlproj
          action: Publish
```

Two jobs, two credentials, because they present different subjects: one ending
`:ref:refs/heads/main` and one ending `:environment:production`. The connection string holds no
password, so it is a secret only to keep the server name out of a public log. `DeployReport`
writes the planned changes and touches nothing, which is what the reviewer releasing the second
job should be reading.

## Check it worked

A green run means the action exited zero. It does not say the schema landed, nor that the firewall
was left as it was found. Three checks, none of which changes anything.

```bash
gh run view <run id> --json conclusion,jobs --jq '.conclusion, [.jobs[] | {name, conclusion}]'
```

Expect `success` and every job present. A job at `waiting` is the gate working, not a failure, and
a deploy job that never appears is a `needs:` that never released.

```bash
sqlpackage /Action:DeployReport /SourceFile:"./db/bin/Debug/ShopDb.dacpac" \
  /TargetConnectionString:"<the same connection string>" /OutputPath:after.xml
test -f after.xml || { echo "no report was written"; exit 1; }
grep -c "<Operation " after.xml || true
```

Expect `0`. A publish that landed leaves the next deploy report nothing to do, and any count above
zero names an object the run did not apply. `/OutputPath` is the DeployReport parameter;
`/DeployReportPath` belongs to Publish, so the wrong flag writes no report at all, which is what
the `test -f` is for: a missing report makes the count `0` as well, and without that line the check
reports a clean deployment when it measured nothing.

**`|| true` is not decoration, and it is the reason this check used to fail on success.** `grep -c`
prints `0` and **exits 1** when it selects no lines. A GitHub Actions `run:` block is `bash -e`, so
the step goes red on precisely the outcome you want. Measured 2026-09-05 against a real logical
server: after a clean publish the report was
`<DeploymentReport ...><Alerts /></DeploymentReport>`, `grep -c` printed `0`, and the exit code was
`1`.

**Expect it to be slow, and do not read slow as hung.** On a Basic tier database, measured the same
day, publishing a single three-column table took **3 minutes 16 seconds** and the DeployReport
after it took **2 minutes 50 seconds**. DacFx compares the whole model, so the floor is set by the
tier rather than by the size of the change. While it runs, `sys.dm_exec_sessions` shows a
`DacFx Deploy` session, which is how to tell a working deployment from a stalled one.

**One line in a successful publish reads like a failure.** Between `Updating database (Start)` and
`Creating Table`, a project built from the default template prints
`'QUERY_STORE=OFF' is not supported in this version of SQL Server.` The publish continues and exits
zero. It is not an error and there is nothing to fix.

```bash
az sql server firewall-rule list -g <resource group> -s <server> --query "[].name" -o tsv
```

Expect no name beginning `ClientIPAddress_`. The action removes its own rule even when the
deployment failed, so a leftover means the job was cancelled rather than failed. Do not read the
date out of that name: it is built from `getMonth()`, zero-based, and `getDay()`, the weekday.

## Do not

- Do not compose the subject from a template. Read the prefix the repository reports and append
  the job segment, and do not add an environment to a job without adding its credential too.
- Do not act on the login step's closing line about `auth-type`, or treat "unable to detect client
  IP address" as networking. Both name the step that reported, not the step that failed.
- Do not fall back to a client secret or a database password to get a red run green. That is the
  one thing the design was for.
- Do not open the firewall to all Azure services to avoid managing a rule. It is not narrow.
- Do not assume declaring an environment created a gate, or that a gate on one job protects
  another job holding the same secrets.

## References

- [references/oidc-and-firewall.md](references/oidc-and-firewall.md) holds the token payloads for both job shapes, the failure messages in full, the credential commands for an application identity as well as a user-assigned one, and the action's steps in order. Open it when a login or a firewall step fails and the message on screen does not say which of the two broke.
- [GitHub's OIDC reference](https://docs.github.com/en/actions/reference/security/oidc) when the subject claim is in question; [SqlPackage Publish](https://learn.microsoft.com/sql/tools/sqlpackage/sqlpackage-publish) and [DeployReport](https://learn.microsoft.com/sql/tools/sqlpackage/sqlpackage-deploy-drift-report) when the deployment step's behaviour is.
