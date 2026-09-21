# Four corrected claims, carried to `microsoft/azure-sql-database-container` on 2026-09-19

> **Read this first, added 2026-09-20.** This document was written the day before the ownership
> direction was reversed, and it describes the world as it stood then:
> `microsoft/azure-sql-database-container` was the parent of the 17 `azuresql-db-*` skills, this
> catalog held copies, and a correction landing here first was a **debt owed upstream** recorded in
> `catalog/container-parity-debt.jsonc`. Carlos Robles reversed that on **2026-09-20**. This catalog
> is now the parent: the 17 are authored, optimised, evaluated and tested here, the pilot repository
> receives copies, and that copy is **on hold** until he says go. The debt file was deleted with the
> flip, because a difference is no longer a debt, it is the pending copy that
> `scripts/check-container-parity.mjs` measures on every run. **Nothing below is owed to anybody
> now.** The rest is kept exactly as written, because the measurement is the point and rewriting a
> record to match a later decision destroys the only thing it was for.

**Recorded 2026-09-19. HANDED OVER THE SAME DAY.**
`microsoft/azure-sql-database-container` took all four corrections in its pull request 161,
merged as `c105046`. The parity debt this document was written against was therefore paid: the
ten entries in `catalog/container-parity-debt.jsonc` were deleted when the parity check confirmed
the two repositories agree again. What follows is the record of what moved and why.

Four claims in three of the 17 `azuresql-db-*` skills are wrong. In every case the engine
refuses exactly what the skill says it refuses, so **no instruction in any skill changes**.
What changes is the error number, the message text, or the question a probe asks. They were
corrected in `microsoft/azure-sql-skills` first, which made those files differ from that
repository, and every differing file was recorded in `catalog/container-parity-debt.jsonc` as debt
against this handover.

## How they were found, and how they were confirmed

Pull request 110 in `microsoft/azure-sql-skills-lab` ran all 17 skills' own probes against
the engine for the first time. 98 of 104 passed. The six reds were the four claims below.

Every one was then **re-measured by hand on 2026-09-19 before anything was edited**, on a
scratch container started from image tag `18.0.226_4_147` with no `MSSQL_AAD_*` variables,
reporting `EngineEdition` 5, Edition `SQL Azure`, build `12.0.2000.8`. Statements were run
through `sqlcmd` in the image against a scratch user database, which is the session the
probes use. The hand measurement agreed with the run in all four cases.

That second measurement was not ceremony. One of these numbers had already been "corrected"
once, on 2026-09-04, to the value this run contradicts. A number this project treated as
settled had flipped before, so it was read off a live engine again rather than trusted.

## The four claims

### 1. `CREATE USER ... WITH PASSWORD` is refused with `Msg 33233`, not `Msg 15007`

```
Msg 33233, Level 16, State 1
You can only create a user with a password in a contained database.
```

Identical from a user database and from `master`. `Msg 15007` was never produced by this
engine for this statement. The guidance is unchanged: a server login plus a mapped database
user is still the local recipe, and it is still the inverse of Azure SQL Database in the cloud.

Where it was printed: `azuresql-db-auth/SKILL.md`,
`azuresql-db-auth/references/auth-and-secrets.md` (with message text this engine does not
produce), `azuresql-db-auth/skill.spec.jsonc` probe 2 and `value_declaration.covers[0]`,
`azuresql-db-faq/SKILL.md`, `azuresql-db-faq/references/faq.md`,
`azuresql-db-faq/skill.spec.jsonc` probe 5 and `value_declaration.covers[2]`.

### 2. `SET CONTAINMENT = PARTIAL` is refused with `Msg 12824`, not `Msg 12844`

```
Msg 12824, Level 16, State 1
The sp_configure value 'contained database authentication' must be set to 1 in order to
alter a contained database.  You may need to use RECONFIGURE to set the value_in_use.
Msg 5069, Level 16, State 1
ALTER DATABASE statement failed.
```

Identical for `ALTER DATABASE CURRENT ...` in a user database and for a named database from
`master`. The text the skills printed, "this functionality is not available in the current
edition of SQL Server", is not what this engine says.

**This number has now been wrong twice, in both directions, and that is worth carrying in
the fix.** It shipped as an unmeasured number with the `sp_configure` wording; on 2026-09-04
it was changed to `Msg 12844` with the edition wording; the first live run of the probe says
`Msg 12824` and the `sp_configure` wording, which is close to where it began. Neither earlier
value was ever read off this engine by the lane. This one was.

Note the second-order fact, which the corrected text now states: the remedy `Msg 12824` names
is unreachable. `sp_configure` does not exist on this engine and answers `Msg 2812`, which
`azuresql-db-container` probe 5 already pins. So the conclusion the skills draw, that the
contained route cannot be enabled at all, is still exactly right.

Where it was printed: the same files as claim 1, plus `azuresql-db-auth` probe 3 and
`azuresql-db-faq` probe 6.

### 3. `CREATE USER ... FROM EXTERNAL PROVIDER` is refused with `Msg 33134`, not `Msg 37525`

On a container started with **zero** `MSSQL_AAD_*` variables:

```
Msg 33134, Level 16, State 72
Principal 'probe-app@contoso.com' could not be resolved.
Error message: 'Unable to query Azure AD certificate from local cert store.'
```

`CREATE LOGIN ... FROM EXTERNAL PROVIDER` on a `master` connection answers the same `33134`
on the same container.

**This one has a consequence beyond the number, and it is the most important line in this
document.** `azuresql-db-container/references/entra-auth.md` told a reader to tell a
configured engine from an unconfigured one by getting `Msg 33134` rather than `Msg 37525`.
On this build an **unconfigured** engine also answers `33134`, so **that test cannot
distinguish the two states** and a reader following it would conclude Entra was configured
when it was not. The corrected page points at the message detail instead: with nothing
configured the detail names the local certificate store. The first verification step on that
page, grepping the error log for an authentication manager failure, is unaffected and is now
the load-bearing one.

Where it was printed: `azuresql-db-auth/SKILL.md` (three places),
`azuresql-db-auth/skill.spec.jsonc` probe 4 and `value_declaration.covers[2]`,
`azuresql-db-faq/SKILL.md`, and `azuresql-db-container/references/entra-auth.md`.

### 4. `sys.databases` does list `msdb`, and there is still no SQL Server Agent

From a user database and from `master` alike, `sys.databases` returns five rows: `master`,
`tempdb`, `model`, `msdb` and the user database. `azuresql-db-container` probe 6 asserted a
count of zero for `msdb` and said in its rationale that a user-database session lists master
and the current database only. Both are false.

**The claim the probe was defending is true and stays.** There is no Agent:
`OBJECT_ID('msdb.dbo.sysjobs')` is `NULL`, and a three-part reference into another database
is refused with `Msg 40515` in any case. Presence of the database is not presence of the job
store. The probe now asks `OBJECT_ID('msdb.dbo.sysjobs') IS NULL`, which is the question the
parity claim actually rests on, and the parity checklist says plainly that `msdb` is listed
so nobody re-derives the old conclusion from a `sys.databases` query.

Where it was printed: `azuresql-db-container/skill.spec.jsonc` probe 6 and
`value_declaration.covers[4]`, `azuresql-db-container/SKILL.md`,
`azuresql-db-container/references/paas-parity-checklist.md`.

## Every file that changed in the pilot repository

Ten files, all under `skills/`. Each was also an entry in `catalog/container-parity-debt.jsonc`,
and taking the fix meant deleting that entry, which the parity check enforced at the time: an
entry that no longer excused anything failed the run. That file no longer exists; see the note at
the top.

| Skill | File | What changes |
|---|---|---|
| `azuresql-db-auth` | `SKILL.md` | verification paragraph, load-bearing facts, Step 1, Do not |
| `azuresql-db-auth` | `references/auth-and-secrets.md` | the contained-user paragraph |
| `azuresql-db-auth` | `skill.spec.jsonc` | probes 2, 3, 4; `correction`; `value_declaration.covers[0..2]` |
| `azuresql-db-faq` | `SKILL.md` | verification paragraph, the least-privilege answer |
| `azuresql-db-faq` | `references/faq.md` | the least-privilege answer |
| `azuresql-db-faq` | `skill.spec.jsonc` | probes 5, 6; `value_declaration.covers[2]` |
| `azuresql-db-container` | `SKILL.md` | verification paragraph |
| `azuresql-db-container` | `references/paas-parity-checklist.md` | the SQL Server Agent entry |
| `azuresql-db-container` | `references/entra-auth.md` | verification step 2 |
| `azuresql-db-container` | `skill.spec.jsonc` | probe 6; `value_declaration.covers[4]` |

`scripts/backfill-container-sidecars.mjs` in the catalog also carries `correction` and
`value_declaration` as literals and was updated in step with the sidecars. If the product
repository has its own generator, it needs the same six strings.

## The signed text, and what was decided about it on 2026-09-20

`value_declaration` is a **written acceptance signed by a named person on a named date**, and
five of its `covers` lines quoted these numbers: `azuresql-db-auth` `covers[0..2]`,
`azuresql-db-faq` `covers[2]` and `azuresql-db-container` `covers[4]`. Correcting them made the
signed text read differently from the text accepted on 2026-09-04. This section used to leave
that open for Carlos Robles. It is settled.

**The substance is unchanged.** The same claims are covered; only the error number cited
inside the sentence moved, and in claim 4 the false premise was replaced by the true fact it
was standing in for. Nothing was added to or removed from what the declaration reaches.

**The corrected numbers stay, and the change is recorded rather than silent.** Freezing the
signed words would have left three declarations quoting error numbers an engine had already
contradicted, and a signed argument that quotes a false number is worse than one that carries a
correction on its face. Re-signing was not needed either, because the argument did not move: the
engine refuses exactly what the declarations said it refuses. So on 2026-09-20 each of the three
`rationale` strings gained a dated sentence naming what moved, when, and on which build, while
`decided_by` and `decided_on` keep naming the 2026-09-04 signature. A reader can tell what was
signed from what has changed since, which is the property that was actually at stake.

The rule this produced is written into the `rationale` description in
`catalog/skill.spec.schema.json`, so the next amendment does not have to rediscover it: a
correction to a FACT is annotated in place; a correction that changes what the declaration
CONCLUDES is re-signed, not annotated.

## What was not done

- `microsoft/azure-sql-database-container` was untouched when this was written, by instruction.
  It has since taken all four corrections in its pull request 161, merged as `c105046` on
  2026-09-19, and its own copies of the 17 skills' probes were run against the engine there:
  104 of 104 pass.
- `maturity` was not changed by hand anywhere. The three skills involved declare `preview`;
  whether their evidence now supports it is a reading of the lab's report, recorded with this
  change and not decided here.
- Four probes still hardcode `Password=YourStr0ng_Passw0rd` instead of reading
  `PROBE_PASSWORD`, so a live run needs `LAB_SA_PASSWORD=YourStr0ng_Passw0rd` to pass. That is
  a thing the product repository may want to change, and it is unrelated to these four claims.
