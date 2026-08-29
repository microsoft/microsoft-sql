---
name: github-actions-for-sql
description: >-
  Ships schema changes to Azure SQL Database from a GitHub Actions workflow with `azure/sql-action`:
  building the database project or publishing a prebuilt dacpac, authenticating with a federated
  credential so no database password or client secret is stored, getting a runner with a changing
  address through the server firewall, and gating the deployment on an environment. Use when a
  user asks to "deploy my database project from GitHub Actions", "publish a dacpac on merge",
  "set up OIDC login to Azure for my pipeline", "stop storing a SQL password in secrets", or
  "require an approval before the schema deploys", and when a run fails with "no matching
  federated identity record found for presented assertion subject", with a login error naming
  `auth-type`, or with "unable to detect client IP address". sql-database-projects owns the
  project and the publish options, entra-id-auth owns the database user and its grant, and
  deploy-app-to-azure owns shipping the application.
---

# Deploy schema to Azure SQL Database from GitHub Actions

**This owns the pipeline: the workflow, the login, the firewall and the gate.** It does not own
the project or its publish options (`sql-database-projects`), the doctrine of how a schema change
is sequenced (`schema-migrations-safely`), the database-side grant for an identity
(`entra-id-auth`), or application deployment (`deploy-app-to-azure`).

Verified on 2026-08-28 by reading `azure/sql-action` at tag `v2.4`, released 2026-07-23, and by
running workflows on a throwaway repository against a real directory and subscription: the token
claims, the login failure, the environment gate and what the hosted runner ships. The
throwaway repository and its Azure resources were deleted afterwards.

## What the action is, as of v2.4

| Input | Notes |
|---|---|
| `connection-string` | **required**, always. This is where the authentication method is chosen |
| `path` | `.sql`, `.dacpac` or `.sqlproj`. A glob is allowed and must match exactly one file |
| `action` | **required for `.dacpac` and `.sqlproj`**. Accepts `Publish`, `Script`, `DriftReport`, `DeployReport` and nothing else |
| `build-arguments` | passed to the build when the path is a project |
| `skip-firewall-check` | default `false` |
| `sqlpackage-path` | override the discovery below |

**It does build a project.** Given a `.sqlproj` it runs `dotnet build "<path>" -p:NetCoreBuild=true`,
then publishes the result. It looks for the output at `<project directory>/bin/<configuration>/<project file name>.dacpac`,
defaulting the configuration to `Debug`, so an output path set inside the project file rather than
passed through `build-arguments` leaves it looking in the wrong place.

`Extract`, `Import` and `Export` are real SqlPackage actions and are rejected here:
`Action Extract is invalid. Supported action types are: Publish, Script, DriftReport, or DeployReport.`

**The runner does not ship the deployment tool.** Measured on `ubuntu-24.04`, image
`20260823.283.1`: `which sqlpackage` finds nothing. The action looks for it as a global .NET tool
and then falls back to the name on `PATH`. One step fixes it, and `~/.dotnet/tools` is already on
`PATH` on that image:

```yaml
- run: dotnet tool install -g microsoft.sqlpackage
```

macOS runners are not supported for the dacpac and project paths at all. The action throws
`This action is not supported on a Mac environment.`

## Authenticating without a stored password

Two secrets are being avoided, and they are different. **A database password** is avoided by
choosing an identity-based authentication keyword in the connection string. **A client secret**
is avoided by federating the workflow's own token to the directory, so nothing long-lived is
stored at all.

```yaml
permissions:
  id-token: write        # without this there is no token to exchange
  contents: read
```

```yaml
- uses: azure/login@v2
  with:
    client-id: ${{ secrets.AZURE_CLIENT_ID }}
    tenant-id: ${{ secrets.AZURE_TENANT_ID }}
    subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}

- uses: azure/sql-action@v2.4
  with:
    connection-string: "Server=tcp:${{ vars.SQL_SERVER }},1433;Initial Catalog=${{ vars.SQL_DATABASE }};Authentication=Active Directory Default;Encrypt=True;"
    path: ./db/ShopDb.sqlproj
    action: Publish
```

`Active Directory Default` is the keyword that picks up the login step's credentials. The other
values the action accepts are `Active Directory Password` and `Active Directory Service Principal`,
both of which put a secret back into the workflow, and a plain user and password, which puts a
database password back.

## The correction: do not write the subject claim, read it

The federated credential matches on three things, and the subject is the one that goes wrong.

**The documented shape is not what gets presented.** On a repository reporting its subject claim as
the default and not customised, the prefix carried numeric ids for both the owner and the
repository:

```text
sub = repo:OWNER@<ownerId>/REPO@<repoId>:environment:production
```

A credential created with the documented `repo:OWNER/REPO:environment:production` did **not**
match it. So composing the subject from a template is the failure, however carefully it is done,
and no amount of care with the job segment rescues a prefix that was written rather than read.

The job segment still has to be right as well. A job naming an environment presents
`:environment:<name>` **in place of** the ref segment, not in addition to it, so the two jobs in
the workflow at the end of this page need two credentials.

**Read the prefix instead of writing it.** The repository reports it, and the answer includes
whether it has been customised:

```bash
gh api repos/OWNER/REPO/actions/oidc/customization/sub
# {"use_default":true,"use_immutable_subject":false,"sub_claim_prefix":"repo:OWNER@<ownerId>/REPO@<repoId>"}
```

Append the job segment to that prefix: `:ref:refs/heads/<branch>`, `:environment:<name>`, or
`:pull_request`. Then create the credential:

```bash
az identity federated-credential create \
  --name gh-deploy --identity-name <identity> -g <resource group> \
  --issuer "https://token.actions.githubusercontent.com" \
  --subject "<the prefix>:environment:production" \
  --audiences "api://AzureADTokenExchange"
```

### The error, and why it names the wrong thing

A subject that does not match produces, verbatim:

```text
##[error]AADSTS700213: No matching federated identity record found for presented assertion
subject 'repo:OWNER@<ownerId>/REPO@<repoId>:environment:production'. Check your federated
identity credential Subject, Audience and Issuer against the presented assertion.
```

**That first line is the most useful thing in the run, because it quotes the subject that was
actually presented.** Copy it into the credential. The line immediately after it is the misleading
one:

```text
##[error]Login failed with Error: The process '/usr/bin/az' failed with exit code 1.
Double check if the 'auth-type' is correct.
```

`auth-type` is an input of the login step and is not the problem. An agent reading only the last
error changes that input, or switches to a client secret to make the run go green, which throws
away the entire point of federating. Read upward to the AADSTS line first.

Not every AADSTS code here is a subject problem. A directory can also refuse a federated
credential on policy grounds, in which case the code and the text are about the policy and not
about the subject, and no amount of correcting the subject helps. Read the code, then decide.

## The firewall problem, and why it disguises the last one

A hosted runner's public address changes between runs, so a fixed firewall rule is not an option.
What the action does about it, from its source:

1. Before deploying, it connects with `sqlcmd`, to `master` first and then to the target database.
2. If that connection fails, it looks for an address inside the **error text** and adds a
   server-level firewall rule for exactly that address.
3. It deploys, and removes the rule afterwards, including when the deployment fails.

Two consequences follow, and the second is the one that wastes time.

**It needs a role on the server resource.** Adding a firewall rule is a control-plane call, so the
login step must have run and the identity must be able to write firewall rules on the logical
server. Without that, the deployment fails at a step that is not the deployment.

**Any login failure is reported as a firewall failure.** If the probe connection fails for a
reason other than the firewall, the error carries no address, and the action raises:

```text
Failed to add firewall rule. Unable to detect client IP Address. <the underlying error>
```

That message is about the firewall. The cause is usually the credential. The underlying error is
appended to it, so read past the first sentence before changing anything about networking.

The alternatives to letting the action manage the rule, all of which pair with
`skip-firewall-check: true`:

| Approach | What it costs |
|---|---|
| the action manages a temporary rule | the identity needs write access to the server resource, and every run edits the firewall |
| a self-hosted runner on a fixed address | infrastructure to run, and a rule that stays |
| a self-hosted runner reaching a private endpoint | no public exposure, and the most to set up |

Allowing all Azure services is not on that list on purpose. It is not a narrow rule.

## Environment approvals, and what they do not protect

The gate holds the job that names it. Measured, on a workflow whose three jobs differ only by
that line: the job without `environment:` completed while the two that declared it sat in
`waiting`, and the pending deployment was released through the API:

```bash
gh api repos/OWNER/REPO/actions/runs/<run id>/pending_deployments
gh api -X POST repos/OWNER/REPO/actions/runs/<run id>/pending_deployments \
  -f state=approved -f comment="reviewed" -F "environment_ids[]=<id>"
```

So the approval is a gate on a job, and it protects nothing else in the workflow:

- **Another job reads the same repository secrets.** Repository-level secrets are available to
  every job. Anything reachable with them is reachable without waiting. Put the deployment
  credential in **environment** secrets, so the gate and the credential cover the same ground.
- **The credential subject is the real binding.** A federated credential whose subject ends in
  `:environment:production` cannot be exchanged by a job that does not name that environment.
  That is enforcement, where the approval is only a pause.
- **The rule may not exist at all.** Creating a required-reviewer rule on a private repository
  whose plan does not include it is refused: `Failed to create the environment protection rule.
  Please ensure the billing plan supports the required reviewers protection rule.` The environment
  is still created, the workflow still references it, and every job runs unblocked. Confirm the
  protection rules exist rather than assuming the environment implies them.

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

Two jobs, two federated credentials, because the two jobs present different subjects: one ending
`:ref:refs/heads/main` and one ending `:environment:production`. The connection string holds no
password, so it is a secret only to keep the server name out of a public log.

`action: DeployReport` on the first job writes the planned changes and touches nothing, which is
what a reviewer should be looking at before releasing the second.

## Validation rules

- The federated credential subject came from the reported prefix or from the presented subject in
  a failure, never from a template written by hand.
- Every job that authenticates has a credential whose subject matches the shape that job will
  present, environment segment included.
- `id-token: write` is granted, and no client secret or database password is stored anywhere.
- The runner installs the deployment tool, because the hosted image does not carry it.
- The path type and the `action` input agree, and `action` is present for a dacpac or a project.
- How the runner reaches the server through the firewall was decided explicitly, and if the action
  manages the rule, the identity can write firewall rules on the server resource.
- A login failure was diagnosed from the identity provider's message rather than from the login
  step's closing line or the firewall step's message.
- The environment's protection rules were confirmed to exist, and the deployment credential lives
  in environment secrets rather than repository secrets.
- A job that reports the plan runs before the job that applies it.

## Do not

- Do not compose the federated credential subject from a documented template. Read the prefix the
  repository reports, then append the job segment.
- Do not add an environment to a job without adding the matching credential. The gate and the
  login break together.
- Do not act on the login step's closing line about `auth-type`. Read the identity provider's
  message above it.
- Do not treat "unable to detect client IP address" as a networking problem before reading the
  error appended to it.
- Do not fall back to a client secret or a database password to get a red run green. That is the
  one thing the design was for.
- Do not open the firewall to all Azure services to avoid managing a rule. It is not narrow.
- Do not assume declaring an environment created a gate, and do not assume a gate on one job
  protects another job holding the same secrets.
- Do not point the deployment at a dacpac built by a different step without knowing which target
  platform it declares. `sql-database-projects` owns that.

## References

- [references/oidc-and-firewall.md](references/oidc-and-firewall.md): the measured token claims,
  the failure messages in full, the credential commands for both an application identity and a
  user-assigned identity, and what the action does step by step from its own source. Read it when
  a login or a firewall step is failing and the message is not enough.
