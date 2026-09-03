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

**This reports on the skills, not on Azure SQL Database.** If the skill said the right thing and the
engine or the query is what misbehaved, that belongs to the skill that owns the topic. If the skill
said the wrong thing, said nothing when it should have, or the wrong skill fired at all, this builds
the report.

Measured 2026-09-03 against the two live `skill_feedback.yml` forms and against
`scripts/check-prefill-contract.mjs` in `microsoft/azure-sql-skills`. The permission and error-code
claims are GitHub's own, from "Creating an issue from a URL query".

## Two forms exist, and the wrong one loses the report

Both are named `skill_feedback.yml` and expose the same nine field ids; their option lists and label
sets differ. Find out which one this reader reaches before drafting anything:

```bash
gh api repos/microsoft/azure-sql-skills --jq '.full_name + " reachable"' \
  || echo "not reachable, fall back to microsoft/azure-sql-database-container"
```

Prefer `microsoft/azure-sql-skills`: it owns all forty skills and every command below uses it. It is
private to the preview and 404s to everyone else, so when that command fails and the report is about
an `azuresql-db-*` skill, fall back to the public `microsoft/azure-sql-database-container`, reading
the comparison in [references/issue-fields.md](references/issue-fields.md) before you switch. If
neither is reachable, say so rather than handing over a dead link.

**`https://aka.ms/sql-agent-skills-feedback` is not a substitute.** It 301s to the container
repository's empty form and drops the whole query string on the way:

```bash
curl -sS -o /dev/null -w '%{redirect_url}\n' \
  'https://aka.ms/sql-agent-skills-feedback?skill=skill-feedback'
```

Expect a URL with no `skill=` in it.

## Step 1: is this actually a skill or catalog defect

Here: instructions that were wrong or incomplete, an agent that had to deviate from them to finish,
the wrong skill firing or none firing, a skill that would not install or load, a stale description or
cross-reference. Not here: correct guidance where the database, driver or query failed anyway, which
belongs to the skill that owns the topic. Praise belongs in Discussions. When unsure, ask; a product
question filed here reaches the wrong queue.

## Step 2: gather, then redact, before any URL exists

Take what the conversation already shows and ask only for the rest: the skill's exact catalog id,
the agent harness, how the skills were installed, the prompt, and above all **the instruction that
was wrong or missing, quoted, with what actually worked instead**, the one field maintainers are
otherwise blind to. Write each long field to a file, so newlines survive:

```bash
mkdir -p report && cd report
cat > skill-said.txt <<'EOF'
The skill said:       port: 1433, hardcoded in the sample.
What actually worked: reading the port from the connection string.
Server=tcp:your-server.database.windows.net,11433;Database=appdb;User Id=svc_app;Password=***;
EOF
```

Everything submitted is public and permanent. A password becomes `Password=***`, a subscription or
tenant id becomes `00000000-0000-0000-0000-000000000000`, a server becomes
`your-server.database.windows.net`, and a token is described in words rather than pasted: even a
truncated one can be enough to use. Then let a gate disagree with you:

```bash
grep -nEi 'password=[^*;]|pwd=[^*;]|(bearer|token|apikey|accountkey)[=: ][A-Za-z0-9._-]{16,}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' *.txt
```

No output and exit 1 is the pass; any hit is a secret still in the draft. The gate is a net, not a
judgment: no customer name or internal hostname trips it, so read the files too.

## Step 3: copy the dropdown values from the live form, never from memory

Four fields are dropdowns and none takes free text. Pull the form once, then check each value you
mean to use is in it character for character:

```bash
gh api repos/microsoft/azure-sql-skills/contents/.github/ISSUE_TEMPLATE/skill_feedback.yml \
  --jq '.content' | base64 -d > form.yml
grep -E '^    id: ' form.yml
grep -Fx '        - Claude Code' form.yml
```

The first grep must print exactly nine ids: `skill`, `problem-type`, `agent`, `install-method`,
`what-happened`, `skill-said`, `repro`, `additional`, `confirm`. That set is the contract
`check-prefill-contract.mjs` enforces, and any other name arrives silently empty. The second must
print its line; exit 1 means the value is gone, and a near neighbour reaches the wrong person.

Two traps in the `skill` list: divider entries such as `-- Drivers and connectivity --` are
selectable and mean nothing, so never emit one, and a missing id becomes `Not sure`, or
`The collection as a whole (install, discovery, or the wrong skill loaded)` for install or routing. Open [references/issue-fields.md](references/issue-fields.md) whenever `form.yml`
cannot be fetched, or for those lists without a network round trip.

## Step 4: build the URL, and leave `labels` out of it

```bash
python3 - <<'PY' > issue-url.txt
import urllib.parse as u
f = {"template": "skill_feedback.yml",
     "title": "[Skill]: connect-from-typescript-and-node hardcodes the port",
     "skill": "connect-from-typescript-and-node",
     "problem-type": "The skill told the agent to do something wrong",
     "agent": "Claude Code",
     "install-method": "npx skills add"}
f.update({k: open(k + ".txt").read() for k in ("what-happened", "skill-said")})
print("https://github.com/microsoft/azure-sql-skills/issues/new?"
      + u.urlencode(f, quote_via=u.quote))
PY
wc -c < issue-url.txt
```

**No `&labels=` parameter.** GitHub returns 404 to anyone without permission to add labels, which is
most people reporting a bug, and both forms declare their own labels anyway, so passing them by hand
can only turn a working link into a dead one.

Watch the character count: GitHub returns 414 past its URL length limit, so stay under 8000, trim a
long log to the lines that matter and tell the user what you cut. Then show them the title and every
field in full before the link: they are agreeing to what gets submitted.

Then hand the URL over and let the user open it. Never open or submit it yourself without their
explicit yes, and take no for an answer without asking again. `gh issue create` is no shortcut: it
posts a plain issue that skips the form, so no field id and no template label applies.

## Check it worked

Three things, none of them "the command exited 0".

**The form loaded with the fields filled.** GitHub documents prefilling an issue form's *text*
fields from query parameters and does not document prefilling a dropdown, so treat those four as
unproven and ask the user to read them back; a blank one did not carry and they pick it by hand. A
404 instead of a form means the repository is out of reach, or a parameter needed a permission they
do not have.

**Both checkboxes are ticked.** Neither prefills, both are required, and GitHub refuses the
submission until they are. Say so before the user opens the link, not after they reach the end.

**The report arrived where a maintainer will see it.** Nothing here phones home, so an issue is the
only evidence anything was sent:

```bash
gh issue list --repo microsoft/azure-sql-skills --limit 3 \
  --json number,title,labels,createdAt
```

Their issue should be at the top carrying `skills`, `needs-triage` and the repository's third label.
Absent means nothing was filed and the user still holds the draft. Present with no labels means the
form's labels did not apply and it will miss the triage queue, so ask them to add the labels or say
so in a comment.

## Do not

- Do not open, submit or comment on an issue without the user's explicit confirmation of the full
  content, and never add a network call, beacon or automatic report here. A human opening a link is
  the only thing that leaves the machine.
- Do not include a password, token, connection-string secret, subscription id, tenant id or real
  email address in any field, ever, even redacted-looking ones that still carry real digits.
- Do not guess a dropdown value or emit a divider entry, do not carry a prefilled report on the
  `aka.ms` short link, and do not add `&labels=`.
