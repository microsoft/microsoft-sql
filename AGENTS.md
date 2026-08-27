# Working in this repository

**Skills are not authored here.** They are written in
[`microsoft/azure-sql-skills-lab`](https://github.com/microsoft/azure-sql-skills-lab) and promoted
into this repository once they are gate-green. Read
[how it works](https://github.com/microsoft/azure-sql-skills-lab/blob/main/docs/how-it-works.md)
before proposing anything.

## What this repository holds

- `skills/<domain>/<skill-name>/` , the content a customer installs
- `catalog/catalog.json` , all 142 skills, including the ones with no content yet
- `scripts/` , the structural gates CI runs

## Two rules that matter most here

**Every skill folder needs a `skill.spec.jsonc`.** The scaffolder in the lab writes one; a
hand-created folder will not have it, and CI fails. The 17 carried-over container skills are the
one sanctioned exception, backfilled once by `scripts/backfill-container-sidecars.mjs`.

**The container family is carried over, not forked.** Anything under
`skills/azure-sql-database-container/` is byte-identical to
`microsoft/azure-sql-database-container`, whose users install the same files until the product
leaves Private Preview in November 2026. Changes originate there and arrive by sync. Editing them
here forks the product.

## The sidecar installs with the skill, and that is expected

`gh skill install` and `npx skills add` copy the whole skill folder, so
`skill.spec.jsonc` lands on the user's machine alongside `SKILL.md`. Verified by installing.

That is fine and it is not a leak. The file never enters the agent's context, because only
`SKILL.md` and the files it references are read. It carries no secrets, and downstream it is useful
provenance. **Do not "fix" this by moving sidecars out of the skill folder**: co-location is what
keeps a skill and its contract from drifting apart, and the eval finds them by that path.

Fan-out to other collections is the exception. Section 13.2 of the PRD strips the sidecar on
syndication unless the destination asks for it, because it names our domains, our personas and a
`last_verified` date that would rot invisibly in someone else's repository.

## The manifest is checked in both directions

`catalog/catalog.json` lists all 142 skills, so "is it current?" cannot be answered by reading it.
CI checks it against the filesystem both ways: every skill on disk must have an entry, and every
entry marked shipped must have a directory. Neither can be forgotten.

## House conventions

- **Feature branch and a pull request, always.** Never commit to `main`.
- **No em-dashes** in files this repository authors. Rule ST007, checked in CI. The carried-over
  container skills are excluded: they are the product's files, not ours to reformat.
- **No AI attribution in commits or pull requests.**
- **Validate, do not assume.** `npm test` before opening a pull request, and if you are claiming an
  install behaviour, install it and look at where the files landed.
