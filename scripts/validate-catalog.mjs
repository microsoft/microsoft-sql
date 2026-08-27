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
const validDomains = new Set(taxonomy.domains.map((d) => d.slug));
check(validDomains.size === 16, `${TAXONOMY} has ${validDomains.size} domains, expected 16`);

// A domain directory appears when its first skill does.
const domains = existsSync(SKILLS)
  ? readdirSync(SKILLS).filter((d) => statSync(join(SKILLS, d)).isDirectory()).sort()
  : [];
for (const d of domains) {
  check(validDomains.has(d), `${SKILLS}/${d}/ is not a domain in ${TAXONOMY}`);
}

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

for (const domain of domains) {
  const dir = join(SKILLS, domain);
  const skillDirs = readdirSync(dir).filter((n) => statSync(join(dir, n)).isDirectory());

  for (const name of skillDirs) {
    const base = join(dir, name);
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
          `${md}: frontmatter key "${k}" is not allowed. House rule FM001 permits ${[...ALLOWED_FRONTMATTER].join(', ')}.`);
      }
      warn(fm.bodyLines < 500, `${md}: body is ${fm.bodyLines} lines, over the 500 line guidance`);
    }

    // ---- sidecar agrees with where it sits
    if (existsSync(sidecar)) {
      let spec;
      try { spec = JSON.parse(readFileSync(sidecar, 'utf8')); }
      catch (e) { errors.push(`${sidecar}: not valid JSON (${e.message})`); }
      if (spec) {
        check(spec.id === name, `${sidecar}: id "${spec.id}" does not match the directory "${name}"`);
        check(spec.domain === domain,
          `${sidecar}: domain "${spec.domain}" does not match its parent directory "${domain}"`);
        const substantive = (spec.value ?? []).filter((v) => v !== 'convenience-only');
        check(substantive.length > 0,
          `${sidecar}: no value test, or convenience-only alone. Convenience only never ships.`);
        check(typeof spec.correction === 'string' && spec.correction.length >= 40,
          `${sidecar}: no correction. If you cannot state the correction, the skill is not ready.`);
        check((spec.triggering?.negative ?? []).length > 0,
          `${sidecar}: no negative controls. Without them a broad description scores well and routes badly.`);
      }
    }

    // ---- direction 1: on disk implies in the manifest
    const entry = byId[name];
    check(entry !== undefined,
      `${base}: "${name}" is not in ${CATALOG}. Add it there, or the generated surfaces will not know it exists.`);
    if (entry) {
      check(entry.domain === domain,
        `${CATALOG}: "${name}" says domain "${entry.domain}" but it lives under "${domain}"`);
    }
  }
}

// ---- direction 2: claimed shipped implies on disk
for (const s of catalog.skills) {
  if (s.status === 'shipped-pilot') {
    check(onDisk.has(s.id),
      `${CATALOG}: "${s.id}" is marked shipped-pilot but has no directory under ${SKILLS}/${s.domain}/`);
  } else {
    // Not an error. Most of the catalog is roadmap, and roadmap entries are the
    // whole reason the manifest lists more than what exists.
    warn(!onDisk.has(s.id) || s.status !== 'backlog',
      `${CATALOG}: "${s.id}" has content on disk but is still marked ${s.status}`);
  }
}

// ---- every manifest domain is a real domain
for (const s of catalog.skills) {
  check(validDomains.has(s.domain),
    `${CATALOG}: "${s.id}" names domain "${s.domain}", which is not in ${TAXONOMY}`);
}

const shipped = catalog.skills.filter((s) => s.status === 'shipped-pilot').length;
console.log(`domains        ${validDomains.size} defined, ${domains.length} with content`);
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
