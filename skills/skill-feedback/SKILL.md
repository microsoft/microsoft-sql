---
name: skill-feedback
description: >-
  Turns a defect in an Azure SQL agent skill, or in this catalog itself, into a redacted,
  prefilled GitHub issue the user reviews and submits. Use when a skill gave wrong or missing
  instructions, the wrong skill fired or none did, a skill would not install, or a description,
  example or routing in the catalog is itself wrong; also when the agent had to work around a
  defect in the skill it was following, even though the task still succeeded. Triggers on "file a
  bug", "report this", "open an issue", "give feedback on this skill". Not for an ordinary Azure
  SQL Database or T-SQL failure where the skill's guidance was correct and only the service or the
  query is misbehaving; that belongs to the skill that owns the topic, such as
  diagnose-connection-errors or t-sql-correctness. Strips connection strings, passwords, tokens,
  keys, server names, subscription and tenant ids, and real email addresses before building the
  URL, and never submits anything without the user's explicit confirmation.
---

# Report a defect in a skill, or in the catalog itself

**This reports on the skills, not on Azure SQL Database.** If the skill said the right thing and
the engine or the query is what misbehaved, that is a product problem and does not belong here.
If the skill said the wrong thing, said nothing when it should have, or the wrong skill fired at
all, that is what this builds a report for.

Verified on 2026-08-29 against `scripts/check-prefill-contract.mjs` and
`.github/ISSUE_TEMPLATE/skill_feedback.yml` in `microsoft/azure-sql-skills`, and against the
mechanism the shipped `azuresql-db-feedback` skill already uses in production.

## The facts that shape this

- **Repository:** `microsoft/azure-sql-skills`. Every report opens there, whichever catalog skill
  it is about.
- **Mechanism:** build a URL, hand it to the user, the user opens it. This skill never calls a
  network endpoint, never sends a beacon, and never reports back on its own; the one request that
  ever fires is the browser request a human makes by opening the link. That is the whole trust
  model, and it never changes.
- **`aka.ms` short links drop query strings.** A human-friendly empty-form link exists
  (`https://aka.ms/sql-agent-skills-feedback`), but it redirects to the bare form with nothing
  filled in. A prefilled report always uses the full `github.com` URL from
  [references/issue-fields.md](references/issue-fields.md).
- **The `skill` dropdown is a fixed, verbatim list**, and it will not contain every catalog id.
  Never invent a value or guess the closest-sounding one: if the exact id is not in the list, use
  `Not sure`, or `The collection as a whole (install, discovery, or the wrong skill loaded)` for an
  install or routing problem.
- **Checkboxes never prefill.** The form ends with two required confirmations; tell the user they
  still have to tick both before GitHub accepts the submission.
- **A `labels=` parameter replaces the template's labels, it does not add to them.** Always pass
  the full set, never just one.

## Step 1: is this actually a skill or catalog defect

Ask what actually failed, not what feels broken.

| What happened | Report it here | Why |
|---|---|---|
| A skill's instructions were wrong, incomplete, or the agent had to deviate from them to finish | yes | the instructions are the defect |
| The wrong skill fired, or none did, for a prompt that clearly named the task | yes | routing is part of the catalog |
| A skill would not install, or an installed skill never loaded | yes | that is a catalog defect too |
| A description, example, or cross-reference inside a skill is stale or points nowhere | yes | still a catalog defect |
| The skill's guidance was correct and the database, driver, or query still failed | no | hand this to the skill that owns the topic instead |
| The user only wants to say something worked well | no | point them at the repository's Discussions instead of opening an issue |

When genuinely unsure, ask the user rather than guessing. Do not open an issue for a plain product
question or an ordinary debugging session; that is what the topic skills are for, and filing it
here sends it to the wrong queue.

## Step 2: gather what you already have

Only ask the user for what you cannot already see from the conversation.

- Which skill, by its exact catalog id. If none loaded, say so; that omission is itself the bug.
- Which agent harness is running this session (Claude Code, GitHub Copilot in VS Code or the CLI,
  Codex, Cursor).
- How the skills were installed, if known.
- **The instruction that was wrong or missing, quoted, and what actually worked instead.** This is
  the single most useful field in the report, and the one the maintainers are otherwise blind to.
- The prompt the user gave, and what the agent actually did.

## Step 3: redact, before anything else is drafted

Everything submitted becomes a public, permanent record. Strip every one of these from every
field, including any pasted command output or logs:

- Any password or credential value. Show the shape, not the secret: a connection string keeps its
  keys and loses its value, `Password=***` rather than the real one.
- Server, resource and database names that identify a real environment. Use a placeholder such as
  `your-server.database.windows.net`.
- Subscription ids, tenant ids, and directory names. A GUID is not automatically safe to include;
  replace it with a placeholder.
- Access or bearer tokens, signed-URL signatures, and any string that begins the way a token does.
  Describe it in words ("a bearer token was in the header") rather than pasting it.
- Real email addresses, usernames that map to a real person, or any customer or application data.

A worked before-and-after pair is in
[references/issue-fields.md](references/issue-fields.md#redaction-worked-example). If a value's
safety is unclear, redact it and say so, rather than deciding it is probably fine.

## Step 4: choose the dropdown values, verbatim

Every dropdown field takes an exact string from a fixed list; there is no free text fallback for
these four. Copy the value character for character from
[references/issue-fields.md](references/issue-fields.md), which carries the full option list for
`skill`, `problem-type`, `agent`, and `install-method`, current as of the verification date above.
If a value cannot be determined confidently, leave that field out of the URL rather than guessing;
an omitted dropdown renders unselected, a wrong one sends the report to the wrong person.

## Step 5: build the URL and show it, do not open it

Construct one `https://github.com/microsoft/azure-sql-skills/issues/new?template=skill_feedback.yml`
URL with the field ids and the full label set from the reference file, following the worked example
there. Show the user the resulting title and every field's text in full, plain language, before
producing the link: they are agreeing to what gets submitted, not to the idea of submitting
something.

## Step 6: hand it over, never submit unasked

Give the user the finished URL, or write the body to a file and offer the equivalent
`gh issue create` command from [references/issue-fields.md](references/issue-fields.md) if a
GitHub command-line session is already authenticated. Either way, the user is the one who opens the
link or runs the command. Confirm explicitly before doing either yourself, and take no for an
answer without asking again.

## Validation rules

- The report is about a skill or the catalog, never an ordinary product or query failure.
- Every password, connection-string secret, token, subscription id, tenant id, and real email
  address is gone before the URL exists, not redacted afterward.
- Every dropdown value is copied verbatim from the reference file, or the field is left out.
- The full label set is present, not just `via-skill`.
- The user saw the complete title and body and said yes, before anything was opened or run.
- The link is the full `github.com` URL, never the `aka.ms` short link.

## Do not

- Do not open, submit, or comment on an issue without the user's explicit confirmation of the full
  content.
- Do not include a password, token, connection-string secret, subscription id, tenant id, or real
  email address in any field, ever, even redacted-looking versions that still carry real digits.
- Do not guess a dropdown value, including the `skill` id. An unlisted id becomes `Not sure` or
  `The collection as a whole`, never a nearby-sounding option.
- Do not use the `aka.ms` short link to carry a prefilled report; it drops every field you filled
  in and hands the user an empty form.
- Do not file a product or query problem here because the report-building mechanism is convenient.
  The topic skill owns that report.
- Do not treat a clean run of this skill's own checks as proof nothing was missed; redaction is a
  judgment call the agent makes on unfamiliar text, and it is worth a second look before showing
  the user the draft.

## References

- [references/issue-fields.md](references/issue-fields.md): the exact field ids, the verbatim
  dropdown options, the label set, the redaction worked example, and a complete prefilled URL.
  Read this before building any URL or `gh issue create` command.
