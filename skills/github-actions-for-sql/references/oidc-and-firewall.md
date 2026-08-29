# Measured: token claims, login failures, and what the action does

## Contents

- [How these were measured](#how-these-were-measured)
- [The subject claim, both job shapes](#the-subject-claim-both-job-shapes)
- [Finding the prefix without running anything](#finding-the-prefix-without-running-anything)
- [The three failure messages, in full](#the-three-failure-messages-in-full)
- [Creating the credential](#creating-the-credential)
- [What the action does, step by step](#what-the-action-does-step-by-step)
- [What the hosted runner ships](#what-the-hosted-runner-ships)
- [Environment protection rules](#environment-protection-rules)

## How these were measured

On 2026-08-28, on a throwaway repository with a user-assigned identity holding federated
credentials, deleted afterwards along with its resource group. `azure/sql-action` behaviour was
read from the source at tag `v2.4`, released 2026-07-23.

Three credentials were created in turn against the same workflow, and the workflow was re-run
after each: a branch-shaped subject, the documented environment-shaped subject, and the subject
the token actually carried.

## The subject claim, both job shapes

A job requests its own token and decodes the payload. No third-party action is involved:

```bash
TOKEN=$(curl -sS -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange" | jq -r .value)
PAYLOAD=$(echo "$TOKEN" | cut -d. -f2)
case $(( ${#PAYLOAD} % 4 )) in 2) PAYLOAD="${PAYLOAD}==";; 3) PAYLOAD="${PAYLOAD}=";; esac
echo "$PAYLOAD" | tr '_-' '/+' | base64 -d | jq -r '"sub = " + .sub, "aud = " + .aud, "iss = " + .iss'
```

Results from one run, two jobs differing only by an `environment:` line:

```text
sub = repo:OWNER@<ownerId>/REPO@<repoId>:ref:refs/heads/main
aud = api://AzureADTokenExchange
iss = https://token.actions.githubusercontent.com

sub = repo:OWNER@<ownerId>/REPO@<repoId>:environment:production
```

The environment segment replaces the ref segment. `aud` and `iss` are stable and are the two
easy fields to get right.

## Finding the prefix without running anything

```bash
gh api repos/OWNER/REPO/actions/oidc/customization/sub
```

Measured response on a repository nobody had configured:

```json
{"use_default": true, "use_immutable_subject": false, "sub_claim_prefix": "repo:OWNER@<ownerId>/REPO@<repoId>"}
```

`use_default` being `true` and the prefix still carrying ids is the point: the ids are the
default, not a customisation. Take `sub_claim_prefix` and append the job segment.

| Job shape | Segment to append |
|---|---|
| runs on a branch | `:ref:refs/heads/<branch>` |
| runs on a tag | `:ref:refs/tags/<tag>` |
| declares an environment | `:environment:<name>` |
| triggered by a pull request | `:pull_request` |

## The three failure messages, in full

**A subject that does not match**, whether because the environment segment was not accounted for
or because the prefix was composed by hand:

```text
##[error]AADSTS700213: No matching federated identity record found for presented assertion
subject 'repo:OWNER@<ownerId>/REPO@<repoId>:environment:production'. Check your federated
identity credential Subject, Audience and Issuer against the presented assertion.
https://learn.microsoft.com/entra/workload-id/workload-identity-federation
Trace ID: <trace id> Correlation ID: <correlation id> Timestamp: <timestamp>
```

**The line the login step prints next**, which names an input that is not the problem:

```text
##[error]Login failed with Error: The process '/usr/bin/az' failed with exit code 1.
Double check if the 'auth-type' is correct.
```

**A directory policy refusal**, which looks like the first message and is not. This one was
returned once the subject matched, by a directory that requires an extra claim on tokens from
this issuer:

```text
##[error]AADSTS7002381: Federated identity credentials issued by
'https://token.actions.githubusercontent.com/' for applications or managed identities registered
in this tenant must contain the enterprise claim with value '<...>' but actual value is ''.
```

The distinction matters. The first is fixed in the credential. The third cannot be fixed by
editing the subject at all, and it is also useful evidence: reaching it proves the subject
matched, because the subject is checked first.

## Creating the credential

For a user-assigned identity, which needs no application registration:

```bash
az identity federated-credential create \
  --name gh-deploy-production \
  --identity-name <identity name> \
  -g <resource group> \
  --issuer "https://token.actions.githubusercontent.com" \
  --subject "<sub_claim_prefix>:environment:production" \
  --audiences "api://AzureADTokenExchange"
```

For an application registration, the same three fields under a different command:

```bash
az ad app federated-credential create --id <application object id> --parameters @credential.json
```

One credential per job shape. A workflow whose plan job runs on the branch and whose deploy job
runs under an environment needs two, and there is no wildcard that covers both.

## What the action does, step by step

Read from `src/main.ts`, `src/SqlUtils.ts`, `src/FirewallManager.ts` and `src/AzureSqlAction.ts`
at `v2.4`:

1. Downloads a pinned `go-sqlcmd` release into the runner tool cache and puts it on `PATH`. It
   does not install the deployment tool.
2. Unless `skip-firewall-check` is `true`, connects with `sqlcmd` to `master`, then to the target
   database if that fails.
3. On failure it searches the **error text** for an address. If it finds one, it obtains an
   authorizer from the login step's session, resolves the logical server through the management
   API, and adds a firewall rule whose start and end are that address.
4. If the error carries no address it throws
   `Failed to add firewall rule. Unable to detect client IP Address. <underlying error>`.
5. For a project path, runs `dotnet build "<path>" -p:NetCoreBuild=true <build-arguments>` and
   then looks for `<project dir>/bin/<configuration>/<project file name>.dacpac`, configuration
   defaulting to `Debug`.
6. Runs the deployment tool with `/Action:<action>` and `/TargetConnectionString:"<connection
   string>"`.
7. Removes the firewall rule in a `finally` block, so it goes away even when the deployment fails.

Consequences worth carrying: the identity needs to be able to write firewall rules on the server
resource for step 3, an authentication problem is reported by step 4 as a firewall problem, and
step 5 will not find an output redirected by a property set inside the project file rather than
passed through `build-arguments`.

Path resolution for the deployment tool: on Windows it collects every install it can find and
picks the highest version. On Linux it checks a global tool location and otherwise uses the bare
name on `PATH`. On macOS it throws `This action is not supported on a Mac environment.`

## What the hosted runner ships

Measured on `ubuntu-latest`, which resolved to `ubuntu-24.04`, image `20260823.283.1`:

| Check | Result |
|---|---|
| `which sqlpackage` | not found |
| `~/.dotnet/tools` on `PATH` | yes, before the run installs anything |
| `dotnet --version` | `10.0.400` |
| installed SDKs | 8.0.x, 9.0.x and 10.0.x side by side |
| after `dotnet tool install -g microsoft.sqlpackage` | resolves at `/home/runner/.dotnet/tools/sqlpackage` |

So one install step is enough, and it does not need a path override.

## Environment protection rules

Creating the environment and its rule, and reading back what actually exists:

```bash
gh api -X PUT repos/OWNER/REPO/environments/production \
  --input - <<< '{"wait_timer":0,"reviewers":[{"type":"User","id":<user id>}]}'
```

On a private repository whose plan does not include the feature this is refused outright:

```text
{"message":"Failed to create the environment protection rule. Please ensure the billing plan
supports the required reviewers protection rule.","status":"422"}
```

The environment itself is still created by the same call shape without the reviewer block, the
workflow referencing it is still valid, and jobs naming it run without waiting. So the absence of
a gate is silent from the workflow's side. Read the rules back:

```bash
gh api repos/OWNER/REPO/environments/production --jq '[.protection_rules[].type]'
# ["required_reviewers"]
```

Releasing a waiting job, which is what a reviewer does:

```bash
gh api repos/OWNER/REPO/actions/runs/<run id>/pending_deployments \
  --jq '.[] | {env: .environment.name, can_approve: .current_user_can_approve}'
gh api -X POST repos/OWNER/REPO/actions/runs/<run id>/pending_deployments \
  -f state=approved -f comment="reviewed" -F "environment_ids[]=<environment id>"
```

Observed during one run with the rule in place: the job with no environment reported `success`
while the two jobs declaring the environment reported `waiting`, and both moved only after the
approval was posted.
