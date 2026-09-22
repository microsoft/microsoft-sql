# Working in this repository

**Where each skill is authored, which is now two different answers.**

- **The 40 authored skills are written in the workbench**,
  [`microsoft/azure-sql-skills-lab`](https://github.com/microsoft/azure-sql-skills-lab), and
  promoted into this repository once they are gate-green. Do not write one here.
- **The 17 `azuresql-db-*` container skills are written HERE.** This repository is their parent:
  they are authored, optimised, evaluated and tested in this repository, and
  [`microsoft/azure-sql-database-container`](https://github.com/microsoft/azure-sql-database-container),
  the pilot repository, receives copies. **That copy is ON HOLD** and needs Carlos Robles to say
  go, so nothing is pushed downstream today.

Read [how it works](https://github.com/microsoft/azure-sql-skills-lab/blob/main/docs/how-it-works.md)
before proposing anything.

## What this repository holds

- `skills/<skill-name>/` , the content a customer installs. Flat, one level, as the Agent Plugins
  specification requires
- `catalog/catalog.json` , all 142 skills, including the ones with no content yet
- `catalog/plugins.json` , which skills each scoped plugin carries
- `plugins/<plugin-name>/` , generated copies of those subsets. Never edit anything under here
- `scripts/` , the structural gates CI runs

## Two rules that matter most here

**Every skill folder needs a `skill.spec.jsonc`.** The scaffolder in the lab writes one for an
authored skill; a hand-created folder will not have it, and CI fails. The 17 container skills are
the one sanctioned exception, backfilled once by `scripts/backfill-container-sidecars.mjs`.

**The container family is authored here, and the pilot repository is downstream.** Every
`skills/azuresql-db-*/` folder is this project's source copy. Write the change here, run the gates
here, and the pilot repository takes it afterwards.

**Until 2026-09-20 this said the opposite, and the history matters.** The 17 were authored in
`microsoft/azure-sql-database-container`, this repository held byte-identical copies, and editing
one here was called forking the product. Carlos Robles reversed the direction on 2026-09-20: the
catalog is the parent, and the pilot repository receives copies. **The copy is ON HOLD** until he
says go, so the pilot repository is expected to be behind and nothing is pushed to it.

`npm run sidecars:parity` measures that gap, on the sidecar fields AND on the shipped text,
meaning `SKILL.md` and everything under `references/`. It reads the pilot repository over HTTPS, or
from a local checkout given as `--pilot-repo <path>`, and it reports how many files are waiting and
since when. **A difference never fails this repository**, because being ahead is the point. Two
things still fail it: a defect on this side, such as a sidecar that will not parse or a field in no
policy class, and a pilot repository it could not read at all, which is UNVERIFIED and never OK.

**Every sidecar field is now ruled on.** `value`, `posture` and `applies_to` sat in the script's
`unreconciled` class from the day it was written: reported on every run, enforced by nothing,
because nobody had decided. Carlos Robles decided on 2026-09-20 and all three are `mustMatch`, so
the class is empty. The three are compared as SETS, because their schema declares them
`uniqueItems` and nothing reads their order; their order is still exact and
`npm run sidecars:check` fails this repository on a reordering. Adding a field to a sidecar without
classifying it in `POLICY` still fails the run, which is the guard that makes an empty
`unreconciled` safe rather than a hole.

**There is no debt file any more.** `catalog/container-parity-debt.jsonc` recorded every difference
as a debt owed upstream, which was the right shape while the pilot repository was the parent. It
was deleted on 2026-09-20, because the same set of differences is now simply the pending copy and
`scripts/check-container-parity.mjs` computes it from the live comparison on every run. One
representation, measured rather than typed in.
`docs/container-claim-corrections-2026-09-19.md` stays as the record of the last hand-carry
upstream, made the day before the flip.

## The sidecar installs with the skill, and that is expected

`gh skill install` and `npx skills add` copy the whole skill folder, so
`skill.spec.jsonc` lands on the user's machine alongside `SKILL.md`. Verified by installing.

That is fine and it is not a leak. The file never enters the agent's context, because only
`SKILL.md` and the files it references are read. It carries no secrets, and downstream it is useful
provenance. **Do not "fix" this by moving sidecars out of the skill folder**: co-location is what
keeps a skill and its contract from drifting apart, and the eval finds them by that path.

Fan-out to other collections is the exception. The sidecar is stripped when a skill is copied into
another collection, unless that collection asks for it, because it names our domains and our personas, which
mean nothing in someone else's repository.

## The manifest is checked in both directions

`catalog/catalog.json` lists all 142 skills, so "is it current?" cannot be answered by reading it.
CI checks it against the filesystem both ways: every skill on disk must have an entry marked
`shipped-pilot`, and every entry marked `shipped-pilot` must have a directory. Neither can be forgotten.

## Domains are data, not directories

`catalog/taxonomy.json` is the authority on which domains exist. A domain directory under `skills/`
appears only when its first skill does, because git does not track empty directories.

This is worth knowing because it already caused a failure: the first CI run of this gate derived
the valid domain set from the filesystem. That **passed locally**, where fifteen empty directories
existed, and **failed on a fresh checkout**, where they did not. If a check reads the filesystem to
decide what is valid, ask what a clean clone actually contains.

## Generated surfaces

`llms.txt`, `apm.yml`, `plugin.json`, `.claude-plugin/`, `.codex-plugin/`, `.cursor-plugin/`,
`.grok-plugin/`, everything under `plugins/`, the skill options inside
`.github/ISSUE_TEMPLATE/skill_feedback.yml` and the catalog table inside `README.md` are all
generated by `scripts/generate.mjs` from `catalog/catalog.json`, `catalog/taxonomy.json` and
`catalog/plugins.json`.

`plugins/` holds a folder per scoped plugin: its four manifests, its logo, a README saying it is
generated, and **byte copies of the skills it carries**. Copies rather than symlinks because Codex
installs an empty skills directory from a symlinked plugin without reporting an error, and a Windows
clone turns each link into a small text file. So a skill's content exists more than once on disk, and
there is still exactly one place a human edits it: `skills/`.

**Never edit them by hand.** CI regenerates and diffs. Change the source, run `npm run generate`,
commit the result.

Prose outside the `BEGIN GENERATED CATALOG` markers in README.md is hand-written and stays that
way; only the marked region is replaced.

**`mcp.json` is deliberately not generated.** The plan is to ship a pointer to the SQL MCP endpoint
beside the skills. There is no endpoint yet, and writing a plausible URL would produce a manifest
that looks correct and resolves to nothing.

## What this repository does NOT check

Skill **content** rules are not gated here. The linter that enforces them lives in the workbench
and this workflow cannot reach it, so nothing here checks frontmatter limits, body size,
reference depth, security patterns, or whether a skill earns its place, against the skills it
ships.

**That gap got sharper on 2026-09-20.** While the 17 container skills were authored elsewhere, an
unlinted container skill was somebody else's file. They are authored here now, so the 18
error-severity findings the content linter reports across them are this repository's to fix, and
the `fail-on: never` in `.github/workflows/validate.yml` is a decision to be revisited rather than
a fact about where the files come from.

What IS checked here: structure, manifest parity in both directions, sidecar schema conformance,
generated-surface parity, the feedback prefill contract, and the house rules on files this
repository authors.

Closing the gap is what `azure-sql-skills-eval` is for. Until then, run the lab's linter against
this repository by hand before a release:

```bash
node ../azure-sql-skills-lab/scripts/lint-skills.mjs skills
```

Saying this out loud rather than leaving it implied, because a green build here currently means
less than it looks like it means.

## House conventions

- **Feature branch and a pull request, always.** Never commit to `main`.
- **No em-dashes** in files this repository authors, checked in CI. That includes the 17
  `azuresql-db-*` skills, which this repository now authors. The exclusion list in
  `scripts/check-house-rules.mjs` is empty and stays empty.
- **No AI attribution in commits or pull requests.**
- **Validate, do not assume.** `npm test` before opening a pull request, and if you are claiming an
  install behaviour, install it and look at where the files landed.
