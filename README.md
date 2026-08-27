# Azure SQL Agent Skills

Domain expertise for the AI coding agents developers already use. Skills teach an agent what it
otherwise gets wrong about Azure SQL Database, usually because it learned SQL from PostgreSQL or
from documentation written before Azure existed.

**This is the published catalog.** Skills are authored in
[`microsoft/azure-sql-skills-lab`](https://github.com/microsoft/azure-sql-skills-lab) and promoted
here once they are gate-green.

## What is here today

| | |
|---|---|
| **Skills with content** | 17, the Azure SQL Database container family, carried over unchanged from the pilot |
| **In the manifest** | 142 across 16 domains, so the generated surfaces know what is coming |
| **Wave 1 target** | 64 skills, 28 September 2026 |

The manifest lists the whole catalog, not just what exists on disk. That is deliberate: the
generators, the roadmap and the persona selections all need to know about skills that have not been
written yet.

## Layout

```
skills/<domain>/<skill-name>/
    SKILL.md              frontmatter: name and description only
    references/           progressive disclosure, one level deep
    skill.spec.jsonc      the maintainer sidecar. The agent never reads it
catalog/catalog.json      all 142 skills: domain, wave, priority, status, value
```

**The domain directory is a source convention, not something a consumer sees.**
`skills/{scope}/*/SKILL.md` is a documented discovery pattern, and every install tool **strips the
domain segment**: a skill installed from `skills/ai-vector-and-rag/rag-on-azure-sql/` lands at
`<agent skills dir>/rag-on-azure-sql/`. That is what keeps the taxonomy free, and it is why the
one-level layout that GitHub Copilot requires is satisfied automatically.

Verified rather than assumed, by installing it.

## Installing

```bash
# GitHub CLI, first party, 40+ agents on --agent
gh skill install microsoft/azure-sql-skills <skill-name> --agent github-copilot
gh skill install microsoft/azure-sql-skills --all --agent claude-code

# The portable path
npx skills add microsoft/azure-sql-skills -a cursor
```

Committed to `.github/skills/` in your own repository, skills reach the GitHub Copilot coding agent
and Visual Studio agent mode with no install step at all.

Persona subsets, which install only the part of the catalog matching your job, land in wave 2.

## The bar a skill has to clear

A skill ships only if it passes at least one of these, and **convenience only is a reject**:

- **Not in training data.** Too new or too narrow to be in the model's weights.
- **Corrects a wrong assumption.** The model is confidently wrong, usually from PostgreSQL or
  pre-Azure documentation.
- **Changes too fast to memorize.** GA status, CLI flags, quotas, error semantics.
- **Multi-step with silent failures.** An ordered procedure where steps fail quietly and the error
  points somewhere else.

And every skill states **the correction it is anchored on**. If the correction cannot be stated,
the skill is not ready. That single rule is why this catalog is 142 skills and not 400.

## Scope

**Local** means the Azure SQL Database container. **Cloud** means Azure SQL Database, not Managed
Instance, not Fabric SQL, not SQL Server on VMs. The on-premises engine appears only in the
migration domain, as the source.

The Fabric line is load-bearing rather than tidy: several AI functions exist only in Fabric and are
routinely hallucinated into Azure SQL Database.

## Feedback

Use the [skill feedback form](../../issues/new?template=skill_feedback.yml). The `skill-feedback`
skill can build the report from context your agent already has, redact secrets, and hand it to you
to submit. It never submits without asking.

If the **product** misbehaved rather than the skill, that belongs in the product's own repository.
Rule of thumb: if the skill said the right thing and it still failed, that is a product bug.

## Contributing

Skills are authored in the lab, not here. See
[`microsoft/azure-sql-skills-lab`](https://github.com/microsoft/azure-sql-skills-lab), and read
[how it works](https://github.com/microsoft/azure-sql-skills-lab/blob/main/docs/how-it-works.md)
before proposing one.

This project welcomes contributions and suggestions. Most contributions require you to agree to a
Contributor License Agreement (CLA) declaring that you have the right to, and actually do, grant us
the rights to use your contribution. For details, visit
[Contributor License Agreements](https://cla.opensource.microsoft.com).

When you submit a pull request, a CLA bot will automatically determine whether you need to provide
a CLA and decorate the PR appropriately (e.g., status check, comment). Simply follow the
instructions provided by the bot. You will only need to do this once across all repos using our CLA.

This project has adopted the
[Microsoft Open Source Code of Conduct](https://opensource.microsoft.com/codeofconduct/). For more
information see the [Code of Conduct FAQ](https://opensource.microsoft.com/codeofconduct/faq/) or
contact [opencode@microsoft.com](mailto:opencode@microsoft.com) with any additional questions or
comments.

## Trademarks

This project may contain trademarks or logos for projects, products, or services. Authorized use of
Microsoft trademarks or logos is subject to and must follow
[Microsoft's Trademark & Brand Guidelines](https://www.microsoft.com/legal/intellectualproperty/trademarks/usage/general).
Use of Microsoft trademarks or logos in modified versions of this project must not cause confusion
or imply Microsoft sponsorship. Any use of third-party trademarks or logos are subject to those
third-party's policies.
