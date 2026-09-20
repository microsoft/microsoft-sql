#!/usr/bin/env node
// Structural gate for the catalog. This is what makes drift impossible for
// anything that actually exists.
//
// The manifest lists all 142 skills, including the ones with no content yet, so
// "is the manifest current?" cannot be answered by looking at the manifest. It
// is answered by checking BOTH directions against the filesystem:
//
//   every skill on disk        ->  has a manifest entry
//   every entry marked shipped ->  has a directory
//
// A skill added without a manifest entry fails the build. A manifest entry
// claiming to be shipped with nothing behind it fails the build. Neither can be
// forgotten, which is the point: the pilot's manifest surfaces were maintained
// by hand and drifted.

import { readFileSync, readdirSync, existsSync, statSync } from 'node:fs';
import { join } from 'node:path';

const SKILLS = 'skills';
const CATALOG = 'catalog/catalog.json';
const TAXONOMY = 'catalog/taxonomy.json';
const SIDECAR_SCHEMA = 'catalog/skill.spec.schema.json';

const errors = [];
const warnings = [];
const check = (ok, msg) => { if (!ok) errors.push(msg); };
const warn = (ok, msg) => { if (!ok) warnings.push(msg); };

const catalog = JSON.parse(readFileSync(CATALOG, 'utf8'));
const byId = Object.fromEntries(catalog.skills.map((s) => [s.id, s]));

// The authoritative domain list is DATA, not filesystem state. Git does not
// track empty directories, so a domain with no skills yet has no directory, and
// deriving the valid set from the filesystem would make every unwritten domain
// look invalid. That is exactly what happened the first time this ran in CI:
// it passed locally, where the empty directories existed, and failed on a fresh
// checkout, where they did not.
const taxonomy = JSON.parse(readFileSync(TAXONOMY, 'utf8'));

// The sidecar schema is a COPY of the one in azure-sql-skills-lab, which owns it.
// Nothing syncs the two automatically, so validating every sidecar against this
// copy is what turns a stale copy into a build failure here. It caught exactly
// that: the copy forbade a key that all 17 shipped sidecars carry.
const sidecarSchema = JSON.parse(readFileSync(SIDECAR_SCHEMA, 'utf8'));
const sidecarAllowed = new Set(Object.keys(sidecarSchema.properties ?? {}));
const sidecarRequired = sidecarSchema.required ?? [];
const validDomains = new Set(taxonomy.domains.map((d) => d.slug));
check(validDomains.size === 16, `${TAXONOMY} has ${validDomains.size} domains, expected 16`);

// skills/ is FLAT. The Agent Plugins specification discovers skills only as
// immediate children of skills/ and forbids clients from recursing, so a domain
// cannot be a directory here. Domain is metadata in the sidecar, and the
// grouping is generated into the README, llms.txt and the Hub.
//
// This also satisfies the GitHub Copilot one-level rule and gh skill's
// skills/*/SKILL.md convention, so one layout serves every channel.
const skillDirs = existsSync(SKILLS)
  ? readdirSync(SKILLS).filter((d) => statSync(join(SKILLS, d)).isDirectory()).sort()
  : [];

// Frontmatter, read without a YAML dependency. Deliberately narrow: it reads
// the two keys the spec requires and the shape our house rule allows, and
// anything else is left to the linter that will live in the lab.
function frontmatter(text, where) {
  if (!text.startsWith('---\n')) { errors.push(`${where}: no YAML frontmatter`); return null; }
  const end = text.indexOf('\n---', 4);
  if (end < 0) { errors.push(`${where}: frontmatter is not terminated`); return null; }
  const block = text.slice(4, end);
  const out = {};
  let key = null;
  for (const line of block.split('\n')) {
    const kv = /^([a-z-]+):\s*(.*)$/.exec(line);
    if (kv) {
      key = kv[1];
      out[key] = kv[2] === '>-' || kv[2] === '>' || kv[2] === '|' ? '' : kv[2].replace(/^["']|["']$/g, '');
      continue;
    }
    if (key && /^\s+\S/.test(line)) out[key] = (out[key] ? out[key] + ' ' : '') + line.trim();
  }
  return { fields: out, bodyLines: text.slice(end + 4).split('\n').length };
}

const ALLOWED_FRONTMATTER = new Set(['name', 'description', 'license', 'compatibility']);
const onDisk = new Set();

// The Agent Plugins specification fixes discovery at skills/ and states
// clients MUST NOT recurse. A skill one level deeper is invisible to every
// conforming client, and the closed manifest schema has no field to point at
// it. Grouping by domain looks tidy and would ship a catalog that loads
// nothing, so it is checked here rather than left to review. The skill linter
// cannot do this: it is handed individual directories and does not know where
// the root is.
for (const name of skillDirs) {
  const nested = join(SKILLS, name);
  if (!existsSync(join(nested, 'SKILL.md'))) {
    for (const inner of readdirSync(nested).filter((n) => statSync(join(nested, n)).isDirectory())) {
      if (existsSync(join(nested, inner, 'SKILL.md'))) {
        errors.push(`${join(nested, inner)}: a skill must be an immediate child of ${SKILLS}/, never nested deeper. ` +
          `It sits inside "${name}/", where no conforming client will find it. ` +
          `Move it up and record the domain in its sidecar; the grouping is generated.`);
      }
    }
  }
}

for (const name of skillDirs) {
    const base = join(SKILLS, name);
    onDisk.add(name);

    // ---- required files
    const md = join(base, 'SKILL.md');
    const sidecar = join(base, 'skill.spec.jsonc');
    if (!existsSync(md)) { errors.push(`${base}: no SKILL.md`); continue; }
    check(existsSync(sidecar),
      `${base}: no skill.spec.jsonc. The scaffolder writes one; a hand-created folder will not have it.`);

    // ---- frontmatter
    const fm = frontmatter(readFileSync(md, 'utf8'), md);
    if (fm) {
      check(fm.fields.name === name,
        `${md}: frontmatter name "${fm.fields.name}" does not match the directory "${name}"`);
      check(/^[a-z0-9]+(-[a-z0-9]+)*$/.test(name) && name.length <= 64,
        `${base}: "${name}" is not a valid skill name`);
      const d = fm.fields.description ?? '';
      check(d.length > 0, `${md}: description is empty`);
      check(d.length <= 1024, `${md}: description is ${d.length} characters, over the 1024 limit`);
      for (const k of Object.keys(fm.fields)) {
        check(ALLOWED_FRONTMATTER.has(k),
          `${md}: frontmatter key "${k}" is not allowed. Only ${[...ALLOWED_FRONTMATTER].join(' and ')} may appear; everything else belongs in the sidecar beside the skill.`);
      }
      warn(fm.bodyLines < 500, `${md}: body is ${fm.bodyLines} lines, over the 500 line guidance`);
    }

    // ---- the sidecar is now the ONLY source of a skill's domain
    let spec;
    if (existsSync(sidecar)) {
      // The extension is .jsonc: strip full-line comments before parsing, the
      // same way generate.mjs and backfill-container-sidecars.mjs already do.
      // A promoted sidecar can carry a leading "// path/to/file" header comment
      // from the lab scaffolder, and a bare JSON.parse rejected two of the ten
      // wave 1 skills on promotion until this matched the other readers.
      try { spec = JSON.parse(readFileSync(sidecar, 'utf8').replace(/^\s*\/\/.*$/gm, '')); }
      catch (e) { errors.push(`${sidecar}: not valid JSON (${e.message})`); }
      if (spec) {
        check(spec.id === name, `${sidecar}: id "${spec.id}" does not match the directory "${name}"`);
        // The directory no longer carries the domain, so the sidecar is the
        // only source and it must name a real one.
        check(validDomains.has(spec.domain),
          `${sidecar}: domain "${spec.domain}" is not in ${TAXONOMY}`);
        const substantive = (spec.value ?? []).filter((v) => v !== 'convenience-only');
        check(substantive.length > 0,
          `${sidecar}: no value test, or convenience-only alone. Convenience only never ships.`);
        check(typeof spec.correction === 'string' && spec.correction.length >= 40,
          `${sidecar}: no correction. If you cannot state the correction, the skill is not ready.`);
        // Schema conformance, the parts a JSON Schema validator would do. No
        // dependency here, so this covers the two clauses that actually catch
        // mistakes: unknown keys and missing required ones.
        if (sidecarSchema.additionalProperties === false) {
          for (const k of Object.keys(spec)) {
            check(sidecarAllowed.has(k),
              `${sidecar}: key "${k}" is not allowed by ${SIDECAR_SCHEMA}. Either the key is wrong, or that schema is a stale copy of the one in azure-sql-skills-lab.`);
          }
        }
        for (const k of sidecarRequired) {
          check(k in spec, `${sidecar}: missing required key "${k}" per ${SIDECAR_SCHEMA}`);
        }
        check((spec.triggering?.negative ?? []).length > 0,
          `${sidecar}: no negative controls. Without them a broad description scores well and routes badly.`);
      }
    }

    // ---- direction 1: on disk implies in the manifest
    const entry = byId[name];
    check(entry !== undefined,
      `${base}: "${name}" is not in ${CATALOG}. Add it there, or the generated surfaces will not know it exists.`);
    if (entry && spec) {
      check(entry.domain === spec.domain,
        `${CATALOG}: "${name}" is domain "${entry.domain}" in the manifest but "${spec.domain}" in its sidecar`);
    }
}

// ---- direction 2: claimed shipped implies on disk, and on disk implies shipped
//
// shipped-pilot is the one shipped value the schema defines, and the lab's
// linter, in the rule that governs which skills a description may name, reads
// it as "exists in the catalog now", meaning this repository. A directory under
// skills/ is exactly that, so every skill on disk must carry it, and nothing
// else may.
//
// That sentence used to say "the product repository", which read fine while
// there was one other repository in the picture. Since 2026-09-20 this catalog
// is the parent of the 17 azuresql-db-* skills and
// microsoft/azure-sql-database-container is downstream of it, so "the product
// repository" now points at the wrong one.
//
// The second half used to be a warning, and only for backlog. Until 2026-09-19
// all 40 authored skills on disk were still marked planned-core, which this
// block did not even warn about, so every gate was green over a manifest that
// called the whole shipped catalog a roadmap.
for (const s of catalog.skills) {
  if (s.status === 'shipped-pilot') {
    check(onDisk.has(s.id),
      `${CATALOG}: "${s.id}" is marked shipped-pilot but has no directory under ${SKILLS}/`);
  } else {
    check(!onDisk.has(s.id),
      `${CATALOG}: "${s.id}" has a directory under ${SKILLS}/ but is marked ${s.status}. ` +
      `A skill in ${SKILLS}/ is shipped; mark it shipped-pilot.`);
  }
}

// ---- every manifest domain is a real domain
for (const s of catalog.skills) {
  check(validDomains.has(s.domain),
    `${CATALOG}: "${s.id}" names domain "${s.domain}", which is not in ${TAXONOMY}`);
}

const shipped = catalog.skills.filter((s) => s.status === 'shipped-pilot').length;
const represented = new Set();
for (const n of onDisk) { const e = byId[n]; if (e) represented.add(e.domain); }
console.log(`domains        ${validDomains.size} defined, ${represented.size} with content`);
console.log(`skills on disk ${onDisk.size}`);
console.log(`manifest       ${catalog.skills.length} entries, ${shipped} marked shipped`);
console.log(`synced from    ${catalog.synced_from?.source} (${catalog.synced_from?.synced})`);

if (warnings.length) {
  console.log('\nwarnings:');
  for (const w of warnings) console.log(`  ! ${w}`);
}
if (errors.length) {
  console.error(`\n${errors.length} error(s):`);
  for (const e of errors) console.error(`  x ${e}`);
  process.exit(1);
}
console.log('\nOK');
