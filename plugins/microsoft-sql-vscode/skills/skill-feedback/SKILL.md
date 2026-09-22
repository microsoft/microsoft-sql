---
name: skill-feedback
description: >-
  Turns a defect in a Microsoft SQL agent skill, plugin, or marketplace into a
  redacted, prefilled GitHub issue the user reviews and submits. Use when a skill gave wrong or
  missing instructions, the wrong skill fired or none did, a skill would not install, or a
  description or routing in the marketplace is wrong; also when the agent worked around a defect in
  the skill it was following even though the task succeeded. Triggers on "file a bug", "report
  this", "open an issue", "give feedback on this skill". Not for an ordinary Azure SQL Database
  or T-SQL failure where the skill's guidance was correct and only the service or the query is
  misbehaving; that belongs to the skill owning the topic, such as diagnose-connection-errors.
  Strips connection strings, passwords, tokens, server names, subscription and tenant ids and
  email addresses, and never submits without confirmation.
---


# Report a defect in a skill, plugin, or marketplace

**This reports on the skills, not on Azure SQL Database.** If the skill said the right thing and the
engine or the query is what misbehaved, that belongs to the skill that owns the topic. If the skill
said the wrong thing, said nothing when it should have, or the wrong skill fired at all, this builds
the report.

Measured 2026-09-22 against the public `skill_feedback.yml` form in
`microsoft/microsoft-sql`. The permission and error-code claims are GitHub's own, from
"Creating an issue from a URL query".

## Use the public Microsoft SQL form

Verify the public repository is reachable before drafting anything:

```bash
gh api repos/microsoft/microsoft-sql --jq '.full_name + " reachable"'
```

Every command below uses `microsoft/microsoft-sql`, the public distribution for all five plugins
and all seventy unique skills. If it is not reachable, say so rather than handing over a dead link.

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

Take what the conversation already shows and ask only for the rest: the plugin id, the skill's
exact id, the agent harness, how the plugin was installed, relevant versions, the prompt, and above
all **the instruction that was wrong or missing, quoted, with what actually worked instead**, the
one field maintainers are otherwise blind to. Write each long field to a file, so newlines survive:

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

Five fields are dropdowns and none takes free text. Pull the form once, then check each value you
mean to use is in it character for character:

```bash
gh api repos/microsoft/microsoft-sql/contents/.github/ISSUE_TEMPLATE/skill_feedback.yml \
  --jq '.content' | base64 -d > form.yml
grep -E '^    id: ' form.yml
grep -Fx '        - microsoft-sql' form.yml
grep -Fx '        - Claude Code' form.yml
```

The first grep must print exactly eleven ids: `plugin`, `skill`, `problem-type`, `agent`,
`install-method`, `version`, `what-happened`, `skill-said`, `repro`, `additional`, `confirm`.
Any other name arrives silently empty. Each exact-value grep must print its line; exit 1 means the
value is gone, and a near neighbour reaches the wrong person.

A missing skill id becomes `Not sure`, or
`The plugin as a whole (install, discovery, or wrong skill loaded)` for install or routing.
Open [references/issue-fields.md](references/issue-fields.md) whenever `form.yml` cannot be
fetched, or for the stable option lists without a network round trip.

## Step 4: build the URL, and leave `labels` out of it

```bash
python3 - <<'PY' > issue-url.txt
import urllib.parse as u
f = {"template": "skill_feedback.yml",
     "title": "[Skill]: connect-from-typescript-and-node hardcodes the port",
     "plugin": "microsoft-sql",
     "skill": "connect-from-typescript-and-node",
     "problem-type": "The skill told the agent to do something wrong",
     "agent": "Claude Code",
     "install-method": "Claude Code plugin marketplace",
     "version": "microsoft-sql 1.0.0; Claude Code <version>"}
f.update({k: open(k + ".txt").read() for k in ("what-happened", "skill-said")})
print("https://github.com/microsoft/microsoft-sql/issues/new?"
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
gh issue list --repo microsoft/microsoft-sql --limit 3 \
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
- Do not guess a dropdown value, do not carry a prefilled report on the
  `aka.ms` short link, and do not add `&labels=`.
