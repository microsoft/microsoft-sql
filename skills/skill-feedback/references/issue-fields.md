# Issue form fields and prefilled URLs

## Contents

- [How prefilling works](#how-prefilling-works)
- [Field ids, the contract](#field-ids-the-contract)
- [Dropdown values, verbatim](#dropdown-values-verbatim)
- [Labels](#labels)
- [Redaction, worked example](#redaction-worked-example)
- [A complete worked URL](#a-complete-worked-url)
- [URL length](#url-length)
- [Alternative: the gh command line](#alternative-the-gh-command-line)
- [Checkboxes cannot be prefilled](#checkboxes-cannot-be-prefilled)
- [If a field or a value does not exist any more](#if-a-field-or-a-value-does-not-exist-any-more)

## How prefilling works

GitHub issue forms prefill from URL query parameters: the parameter name is the field's `id` in
the template, the value is URL-encoded. Base URL:

```
https://github.com/microsoft/azure-sql-skills/issues/new?template=skill_feedback.yml
```

Append one `&<id>=<url-encoded value>` per field. **Always use this full `github.com` URL.** The
human-facing short link `https://aka.ms/sql-agent-skills-feedback` redirects to the bare, empty
form and drops every query parameter, so it can never carry a prefilled report.

## Field ids, the contract

These nine ids are load-bearing: `scripts/check-prefill-contract.mjs` in `microsoft/azure-sql-skills`
asserts the template still exposes exactly this set, so a report built against any other name
lands with that field silently empty.

| id | type | required | what goes in it |
|---|---|---|---|
| `skill` | dropdown | yes | the catalog id, verbatim from the list below |
| `problem-type` | dropdown | yes | verbatim from the list below |
| `agent` | dropdown | yes | which harness is running, verbatim |
| `install-method` | dropdown | yes | how the skills were installed, verbatim |
| `what-happened` | textarea | yes | what the user asked, and what the agent did |
| `skill-said` | textarea | no | the wrong or missing instruction, quoted, and what actually worked |
| `repro` | textarea | no | the prompt and the commands, redacted |
| `additional` | textarea | no | anything else that matters, optional |
| `confirm` | checkboxes | yes | cannot prefill, see below |

Title parameter is `title`, prefix `[Skill]: ` (keep the prefix, add a short summary after it).

## Dropdown values, verbatim

Snapshot taken 2026-08-29 directly from `.github/ISSUE_TEMPLATE/skill_feedback.yml` in
`microsoft/azure-sql-skills`. This list grows as the catalog does and this snapshot will drift; see
[If a field or a value does not exist any more](#if-a-field-or-a-value-does-not-exist-any-more).

### `skill`

```
azure-functions-sql-bindings, azure-sql, azuresql-db-auth, azuresql-db-ci,
azuresql-db-connections, azuresql-db-container, azuresql-db-dab, azuresql-db-faq,
azuresql-db-feedback, azuresql-db-from-sql-server, azuresql-db-functions, azuresql-db-import,
azuresql-db-local-to-cloud, azuresql-db-rag, azuresql-db-scaffold, azuresql-db-schema-migration,
azuresql-db-seed, azuresql-db-sidecar, azuresql-db-testing, build-app-on-azure-sql,
connect-from-dotnet, connect-from-python, connect-from-typescript-and-node, connect-to-azure-sql,
dab-rest-and-graphql, deploy-app-to-azure, design-azure-sql-schema, diagnose-connection-errors,
ef-core-azure-sql, entra-id-auth, prisma-azure-sql, provision-azure-sql-db, provision-hyperscale,
rag-on-azure-sql, sqlalchemy-azure-sql, t-sql-correctness, vector-search-azure-sql,
The collection as a whole (install, discovery, or the wrong skill loaded), Not sure
```

**This list will not contain every catalog id, and that gap is expected rather than a mistake to
paper over.** If the exact id the report is about is not one of these, do not pick the
nearest-sounding entry: use `Not sure`, or `The collection as a whole` when the problem is about
install or discovery rather than one skill's content.

### `problem-type`

```
The skill told the agent to do something wrong
The skill was missing something it needed to say
The wrong skill was used, or no skill was used at all
The skill would not install or would not load
The skill worked, but I want to suggest an improvement
Something else
```

### `agent`

```
Claude Code
GitHub Copilot (VS Code)
GitHub Copilot (CLI)
Codex
Cursor
Other (describe below)
```

### `install-method`

```
npx skills add
Copied the directories in by hand
Not sure
```

## Labels

```
&labels=skills,needs-triage,via-skill
```

A `labels=` parameter **replaces** the template's own labels rather than adding to them, so a URL
that passes only `via-skill` strips the other two and the report lands untriaged. Always pass all
three. `via-skill` is the only signal that lets the maintainers see a report came through an agent
rather than a person typing into the form by hand.

## Redaction, worked example

Before, as it might appear in a terminal or a config file:

```
Server=tcp:your-server.database.windows.net,1433;Database=appdb;User Id=svc_app;Password=YourStr0ng_Passw0rd;TrustServerCertificate=false;
```

After, as it goes in `skill-said` or `repro`:

```
Server=tcp:your-server.database.windows.net,1433;Database=appdb;User Id=svc_app;Password=***;TrustServerCertificate=false;
```

The shape survives (host, database, the fact that TLS validation is on), the secret does not. The
same rule covers everything else that identifies a real environment or a real person: a
subscription id becomes a placeholder such as `00000000-0000-0000-0000-000000000000`, a tenant
name becomes `contoso.onmicrosoft.com`, and a bearer token or an access key is described in words
("a bearer token was sent in the Authorization header") rather than pasted at all, because even a
truncated token can be enough to use.

## A complete worked URL

The `connect-from-typescript-and-node` skill told the agent to open a connection with a hardcoded
port that does not match the sample project, and the agent had to work out the right one itself.

```
https://github.com/microsoft/azure-sql-skills/issues/new
?template=skill_feedback.yml
&labels=skills,needs-triage,via-skill
&title=%5BSkill%5D%3A%20connect-from-typescript-and-node%20hardcodes%20the%20wrong%20port
&skill=connect-from-typescript-and-node
&problem-type=The%20skill%20told%20the%20agent%20to%20do%20something%20wrong
&agent=Claude%20Code
&install-method=npx%20skills%20add
&what-happened=I%20asked%20for%20a%20Node%20connection%20helper%20for%20Azure%20SQL%20Database.%20The%20agent%20followed%20the%20skill%20and%20the%20first%20connection%20attempt%20failed.
&skill-said=The%20skill%20said%3A%20port%3A%201433%20hardcoded%20in%20the%20sample.%0AWhat%20actually%20worked%3A%20reading%20the%20port%20from%20the%20connection%20string%20instead%20of%20hardcoding%20it.%0AThe%20skill%20never%20mentioned%20a%20non-default%20port%20case.
&repro=1.%20Ask%3A%20%22connect%20my%20Node%20app%20to%20Azure%20SQL%20Database%22%0A2.%20Agent%20writes%20the%20sample%20exactly%20as%20shown%2C%20port%201433%20hardcoded%0A3.%20Connection%20fails%20because%20the%20server%20uses%20a%20non-default%20port
```

(Wrapped here for readability; emit it as one line with no whitespace.) Note the password in the
skill's own worked example above is the catalog's documented sample password, not a real one, and
the URL example carries no secret at all because this particular report never needed one.

## URL length

GitHub returns a length error on an over-long URL and can truncate very long values. Keep the
whole URL under roughly 8000 characters: cap `repro` near 1500 characters and `what-happened` near
2000, and trim a long log to the lines that matter, telling the user what was cut so they can paste
the rest into the form themselves. If it genuinely does not fit, prefill the short fields and leave
the long one for the user to fill in by hand.

## Alternative: the gh command line

If a GitHub command-line session is already authenticated, write the body to a file (so newlines
and quoting survive) and offer this instead of a link, still only after the user confirms:

```
gh issue create --repo microsoft/azure-sql-skills \
  --title "[Skill]: <one-line summary>" \
  --label skills --label needs-triage --label via-skill \
  --body-file <path-to-body>
```

## Checkboxes cannot be prefilled

The form ends with two required checkboxes and neither prefills from the URL. Tell the user they
still need to tick both by hand before GitHub accepts the submission; ticking them is also the
moment they take ownership of what is being reported.

## If a field or a value does not exist any more

The nine field ids in the contract above are checked by CI on every change to the template, so a
rename there is caught immediately. The dropdown option lists are not: they are a snapshot, not a
live read, because a shipped skill never makes a network call to refresh itself. If a prefilled
field renders empty, or a value this file lists no longer appears in the form, that is the contract
drifting rather than a mistake in the URL: stop, tell the user the field would not prefill reliably,
and point them at the plain form instead of guessing a new shape.
