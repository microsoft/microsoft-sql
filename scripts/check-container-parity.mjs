#!/usr/bin/env node
// Compare the 17 carried-over container sidecars in THIS repository against the
// same 17 files in the product repository, which is where they originate.
//
//   node scripts/check-container-parity.mjs
//   node scripts/check-container-parity.mjs --product-repo /path/to/checkout
//   AZURE_SQL_CONTAINER_REPO=/path/to/checkout node scripts/check-container-parity.mjs
//
// WHY THIS EXISTS, AND WHAT IT REPLACES
//
// scripts/backfill-container-sidecars.mjs --check regenerates these sidecars
// from literals in its own source and compares the result against files in this
// repository. It is a good generator check and it is not a parity check: it
// never opens the product repository, so the claim that the two repositories
// agree was asserted by a reviewer on one day and enforced by nothing on any
// day after it. That is the failure mode this project keeps hitting, a check
// that is green while verifying nothing, so this script does the one thing the
// other one cannot: it reads the other repository.
//
// WHERE THE OTHER REPOSITORY COMES FROM
//
// In resolution order, and there is no fourth branch that quietly passes:
//
//   1. --product-repo <path>, or AZURE_SQL_CONTAINER_REPO in the environment.
//      A local checkout. Offline, instant, and what a maintainer should use,
//      because it compares against the working tree they are actually editing.
//   2. An HTTPS fetch of the 17 files from the public product repository at the
//      ref pinned in SOURCE below. This is what runs in CI. The product
//      repository is public, so this needs no token and no second checkout.
//   3. Nothing. Exit non-zero.
//
// A network error, a non-200, or a file that will not parse is a FAILURE and
// never a skip. If this script cannot see the other repository it must say so
// in red, because "I could not check" and "I checked and it is fine" are the
// two things this whole exercise exists to stop confusing.

import { readFileSync, existsSync, readdirSync } from 'node:fs';
import { join, relative } from 'node:path';
import { createHash } from 'node:crypto';

// The product repository, and the ref that carries the sidecars.
//
// PROVENANCE, AND HOW STALENESS SURFACES. The ref is a live branch rather than
// a commit SHA, deliberately. A pinned SHA would turn this into a snapshot
// comparison that goes green forever while the product repository moves
// underneath it, which is the same defect one step removed. A branch ref cannot
// go stale silently: it either resolves to whatever the product repository says
// today, or it 404s and this script goes red and names the ref it could not
// find.
//
// REPOINTED TO main ON 2026-09-04, WHICH IS THE DESIGN WORKING. This was pinned
// to the integration branch value-declaration-17 while pull requests 151, 152
// and 154 were open, with a note saying it moves to main the day they merge.
// They merged as 7268a41, all 17 sidecars with their 101 probes and 17 value
// declarations are on main, and the branch was left in place afterwards, so the
// fetch would have kept resolving to a snapshot of an already-merged branch
// rather than to what the product repository says today. That is exactly the
// silent staleness the branch ref exists to prevent, and only a repoint stops
// it. main is a branch and not a tag, so the same reasoning holds: it moves when
// the product repository moves, and it cannot be deleted out from under this.
const SOURCE = {
  repo: 'microsoft/azure-sql-database-container',
  ref: 'main',
  // In the product repository the sidecars live at skills/<id>/skill.spec.jsonc,
  // the same relative layout as here.
  dir: 'skills',
};

const ROOT = 'skills';
const CATALOG = 'catalog/catalog.json';
const DOMAIN = 'azure-sql-database-container';
const SIDECAR = 'skill.spec.jsonc';

// ---- THE SHIPPED TEXT --------------------------------------------------
//
// WHY THIS WAS ADDED, 2026-09-08. Everything below the sidecar policy compared
// contract files and nothing else. So SKILL.md and references/ , which are the
// only files a reader is ever served, were nobody's check: this script read
// skill.spec.jsonc, backfill-container-sidecars.mjs regenerates skill.spec.jsonc,
// validate-catalog.mjs checks structure, and none of them opened the prose. That
// blind spot was then measured. All 17 SKILL.md files and 5 reference files in
// this catalog were older than the product repository's, missing the constitution
// fixes to how each skill points at its references and missing the dated
// verification statement added to all 17 on 2026-09-05, while every gate in
// `npm test` stayed green. The catalog was publishing text nobody had compared.
//
// EQUALITY, NOT A POLICY TABLE. The sidecar needs three classes because a sidecar
// field can legitimately differ, and `correction` is the worked example: this
// catalog carries a summary sized for a catalog entry and the product repository
// carries the full text. The shipped text has no such case. AGENTS.md states the
// contract in one line, "anything under skills/ is byte-identical to
// microsoft/azure-sql-database-container ... changes originate there and arrive by
// sync", and the house-rules exclusion for em-dashes is written FROM that contract:
// the container skills are exempt because "they are the product's files, not ours
// to reformat". The two rules that could have forced a deliberate divergence both
// resolve by excluding these files instead. So there is exactly one correct state,
// identical, and this enforces it rather than inviting a future exception to be
// filed as one.
//
// HOW COMPARISON WORKS, AND WHY IT IS A HASH. Both sides are reduced to the git
// blob hash of each file, which is what `git hash-object` computes. That buys two
// things. Over HTTPS the whole file list AND its hashes arrive in ONE request to
// the git trees API, so widening this from 17 files to 100 costs no extra network
// calls and cannot trip the unauthenticated rate limit the way 100 raw fetches
// would. And a blob hash is content only, so the 100755-versus-100644 file modes
// the two repositories happen to carry are ignored, which they should be: a mode
// bit is not text a reader is served.
const isShipped = (relativePath) =>
  relativePath === 'SKILL.md' || relativePath.startsWith('references/');

const blobHash = (buf) =>
  createHash('sha1').update(Buffer.concat([Buffer.from(`blob ${buf.length}\0`), buf])).digest('hex');

function filesUnder(dir, base = dir) {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const full = join(dir, entry.name);
    return entry.isDirectory() ? filesUnder(full, base) : [relative(base, full)];
  });
}

// The shipped files of one skill directory, as { relativePath: blobHash }.
function shippedHashes(skillDir) {
  const out = {};
  for (const f of filesUnder(skillDir).sort()) {
    if (isShipped(f)) out[f] = blobHash(readFileSync(join(skillDir, f)));
  }
  return out;
}

// THE FIELD POLICY.
//
// Every field either must match, may differ for a stated reason, or is not
// reconciled yet. There is no fourth state and there is no default: a field
// that appears in either repository and is not named below fails the run, so a
// new field cannot be added on one side and go unpoliced on the other.
const POLICY = {
  // Must be identical in both repositories. A difference here is a bug.
  mustMatch: {
    id: 'The identity of the skill. If these differ the two files are not about the same thing.',
    domain:
      'Places the skill in this catalog. The 17 are carried over unchanged, so the product repository is where the domain is decided.',
    maturity:
      'Derived from what the live probe lane actually ran, and the lane lives in the product repository. If the two disagree, one of them is telling a reader that a claim was tested when it was not.',
    value_declaration:
      'A written acceptance of value signed by a named person on a named date, in place of a measurement. Two versions of that text mean two different things were signed, and nobody could say which one Carlos Robles agreed to.',
    'validation.target':
      'Declares which engines the skill was validated against, and so which runs are owed. Disagreement means the two repositories owe different runs for the same skill.',
  },

  // Differ on purpose. The reason is the record of the decision.
  mayDiffer: {
    correction:
      'DELIBERATE. The catalog carries a short summary sized for a catalog entry; the product repository carries the full text. Both are true, and forcing them together would either bloat the catalog or truncate the source. Both are still required to be present and non-empty.',
    $schema:
      'Catalog only. A relative path to this repository schema, which has no meaning in the product repository.',
    related:
      'Product only. Cross-references between the 17 as they sit in the product repository, which is a different neighbourhood from this catalog of many domains.',
    value_probe:
      'Product only. The two-arm value measurement definition, which runs from the product repository.',
    triggering:
      'The catalog entries are the pilot eval prompt set, deliberately narrow; the product repository carries the fuller authored set. Not reconciled and not intended to be.',
  },

  // Divergent today, with no ruling either way. REPORTED, NOT ENFORCED, and the
  // report says so on every run so that this list is uncomfortable to leave
  // alone. Moving an entry from here to mustMatch or mayDiffer is a decision
  // somebody has to make and write down.
  unreconciled: {
    value: 'Catalog uses the catalog value taxonomy; the product repository uses its own. Nobody has ruled on whether these should be the same vocabulary.',
    posture: 'Differs on 8 of the 17. Not part of the set a reviewer established, so this script will not invent a ruling on it.',
    applies_to: 'Follows validation.target on one side and not the other. Settle target first.',
  },
};

// validation is compared subfield by subfield rather than as a whole object,
// because it also carries `assert`, which the two repositories are migrating away
// from at different speeds.
//
// probes MOVED FROM mayDiffer TO mustMatch ON 2026-09-04, and this is a ruling
// rather than a tidy-up. It sat in mayDiffer for one reason: this catalog carried
// no probes at all, so nothing could have matched. That is the defect that was
// then measured. All 101 probes lived only in the product repository while this
// catalog published the `maturity` those probes earned, and `maturity` is
// mustMatch. Under this repository's own definition of the word, `preview` MEANS
// validation.probes is non-empty and every probe in it ran and passed. So the
// catalog was publishing a claim whose stated evidence it did not carry, which is
// the same shape as a check that is green while verifying nothing. The 17 were
// resynced on 2026-09-04 and all 101 probes are here now. Enforcing them from the
// same day is what stops that being a one-off act somebody has to remember to
// repeat: the evidence for a field that must match has to match too, or the next
// probe added upstream drifts out of this catalog in silence exactly as the last
// hundred did.
const VALIDATION_SUBFIELDS = { target: 'mustMatch', assert: 'mayDiffer', probes: 'mustMatch' };

const args = process.argv.slice(2);
const flagIndex = args.indexOf('--product-repo');
const localPath = flagIndex !== -1 ? args[flagIndex + 1] : process.env.AZURE_SQL_CONTAINER_REPO;

function fail(lines) {
  console.error('');
  for (const l of lines) console.error(l);
  console.error('');
  process.exit(1);
}

const ids = JSON.parse(readFileSync(CATALOG, 'utf8'))
  .skills.filter((s) => s.domain === DOMAIN)
  .map((s) => s.id)
  .sort();

if (ids.length === 0) {
  fail([`No skills in domain ${DOMAIN} in ${CATALOG}. Nothing to compare, which is itself wrong.`]);
}

// ---- resolve the product repository, or die saying why -------------------

async function loadFromLocal(base) {
  if (!existsSync(base)) {
    fail([
      `The product repository was given as ${base} and there is nothing there.`,
      '',
      'This script will not fall back to the network when it was pointed somewhere',
      'explicitly, because a silent fallback is how a typo turns into a green run.',
      'Fix the path, or drop --product-repo and AZURE_SQL_CONTAINER_REPO to fetch',
      `from ${SOURCE.repo} at ${SOURCE.ref}.`,
    ]);
  }
  const out = {};
  const absent = [];
  for (const id of ids) {
    const p = join(base, SOURCE.dir, id, SIDECAR);
    if (!existsSync(p)) { absent.push(p); continue; }
    out[id] = { text: readFileSync(p, 'utf8'), where: p };
  }
  if (absent.length) {
    fail([
      `${absent.length} of ${ids.length} sidecars are missing from the product checkout at ${base}:`,
      ...absent.map((p) => `  x ${p}`),
      '',
      `The sidecars are on ${SOURCE.ref} in the product repository. Check out`,
      `${SOURCE.ref} in that clone and pull, or unset the path to fetch that ref over HTTPS.`,
    ]);
  }
  const body = Object.fromEntries(ids.map((id) => [id, shippedHashes(join(base, SOURCE.dir, id))]));
  return { out, body, origin: `local checkout ${base}` };
}

async function loadFromGitHub() {
  const base = `https://raw.githubusercontent.com/${SOURCE.repo}/${SOURCE.ref}/${SOURCE.dir}`;
  const results = await Promise.all(
    ids.map(async (id) => {
      const url = `${base}/${id}/${SIDECAR}`;
      try {
        const res = await fetch(url);
        if (!res.ok) return { id, url, error: `HTTP ${res.status}` };
        return { id, url, text: await res.text() };
      } catch (e) {
        return { id, url, error: e.message };
      }
    }),
  );
  const broken = results.filter((r) => r.error);
  if (broken.length) {
    fail([
      `Could not read ${broken.length} of ${ids.length} sidecars from ${SOURCE.repo} at ${SOURCE.ref}:`,
      ...broken.map((r) => `  x ${r.id}: ${r.error}`),
      `      ${broken[0].url}`,
      '',
      'THIS IS A FAILURE AND NOT A SKIP. A parity check that passes when it cannot',
      'see the other repository is the defect it was written to remove.',
      '',
      'Likely causes, in order:',
      `  - the ref ${SOURCE.ref} was deleted or renamed. Repoint SOURCE.ref in this`,
      '    script at the branch the product repository carries the sidecars on.',
      '  - no network egress on this runner. Give the job a local checkout of the',
      '    product repository and set AZURE_SQL_CONTAINER_REPO to it.',
      '  - the product repository stopped being public, which would need a token here.',
    ]);
  }
  return {
    out: Object.fromEntries(results.map((r) => [r.id, { text: r.text, where: r.url }])),
    body: await loadShippedFromGitHub(),
    origin: `${SOURCE.repo} at ${SOURCE.ref} over HTTPS`,
  };
}

// The shipped text over HTTPS, in ONE request.
//
// raw.githubusercontent.com can serve a file and cannot list a directory, and
// listing is the half that matters: fetching only the files this catalog already
// has would be blind to a reference file ADDED upstream, which is precisely the
// direction this drift travelled. The git trees API returns every path under the
// ref together with each blob's hash, so one call answers both "which files exist
// there" and "are they the same bytes".
//
// GITHUB_TOKEN is used when the environment offers one, purely for the rate
// limit. It is never required: the product repository is public, and a check that
// only runs where a secret is configured is a check that silently stops running.
async function loadShippedFromGitHub() {
  const url = `https://api.github.com/repos/${SOURCE.repo}/git/trees/${SOURCE.ref}?recursive=1`;
  const headers = { Accept: 'application/vnd.github+json', 'User-Agent': 'check-container-parity' };
  if (process.env.GITHUB_TOKEN) headers.Authorization = `Bearer ${process.env.GITHUB_TOKEN}`;

  let doc;
  try {
    const res = await fetch(url, { headers });
    if (!res.ok) {
      fail([
        `Could not list the shipped files of ${SOURCE.repo} at ${SOURCE.ref}: HTTP ${res.status}`,
        `      ${url}`,
        '',
        'THIS IS A FAILURE AND NOT A SKIP, for the same reason the sidecar fetch above is.',
        '',
        'Likely causes, in order:',
        '  - HTTP 403 with no token: the unauthenticated API rate limit, 60 requests an',
        '    hour per address. Set GITHUB_TOKEN in the environment, or pass',
        '    --product-repo <path> to compare against a local checkout instead.',
        `  - HTTP 404: the ref ${SOURCE.ref} was deleted or renamed. Repoint SOURCE.ref.`,
        '  - no network egress on this runner. Give the job a local checkout and set',
        '    AZURE_SQL_CONTAINER_REPO to it.',
      ]);
    }
    doc = await res.json();
  } catch (e) {
    fail([
      `Could not list the shipped files of ${SOURCE.repo} at ${SOURCE.ref}: ${e.message}`,
      `      ${url}`,
      '',
      'THIS IS A FAILURE AND NOT A SKIP. A parity check that passes when it cannot see',
      'the other repository is the defect it was written to remove.',
    ]);
  }

  // The trees API drops entries once a response grows past its own limit and says
  // so in this flag. A truncated tree would look exactly like a repository with
  // fewer files, so believing it would turn this into a check that passes because
  // it did not see the evidence.
  if (doc.truncated) {
    fail([
      `The git tree of ${SOURCE.repo} at ${SOURCE.ref} came back TRUNCATED, so the file`,
      'list is incomplete and a missing file cannot be told apart from a deleted one.',
      '',
      'Pass --product-repo <path> to compare against a local checkout, which has no',
      'such limit.',
    ]);
  }

  const wanted = new Set(ids);
  const body = Object.fromEntries(ids.map((id) => [id, {}]));
  for (const entry of doc.tree ?? []) {
    if (entry.type !== 'blob') continue;
    const parts = entry.path.split('/');
    if (parts[0] !== SOURCE.dir || !wanted.has(parts[1])) continue;
    const rel = parts.slice(2).join('/');
    if (isShipped(rel)) body[parts[1]][rel] = entry.sha;
  }

  const empty = ids.filter((id) => !body[id]['SKILL.md']);
  if (empty.length) {
    fail([
      `${empty.length} of ${ids.length} skills have no SKILL.md in ${SOURCE.repo} at ${SOURCE.ref}:`,
      ...empty.map((id) => `  x ${SOURCE.dir}/${id}/SKILL.md`),
      '',
      'Either the product repository moved these files, or the tree was read wrongly.',
      'Both are failures here rather than something to compare around.',
    ]);
  }
  return body;
}

const { out: product, body: productBody, origin } = localPath ? await loadFromLocal(localPath) : await loadFromGitHub();

// ---- compare -------------------------------------------------------------

const canon = (v) =>
  JSON.stringify(v, (_k, x) =>
    x && typeof x === 'object' && !Array.isArray(x)
      ? Object.fromEntries(Object.keys(x).sort().map((k) => [k, x[k]]))
      : x,
  );

// Report WHERE two values differ, not just that they do. A truncated dump of two
// near-identical thousand-character objects tells a reader nothing.
function firstDiff(a, b, path = '') {
  if (canon(a) === canon(b)) return null;
  if (a && b && typeof a === 'object' && typeof b === 'object' && !Array.isArray(a) === !Array.isArray(b)) {
    const keys = Array.isArray(a)
      ? [...new Set([...a.keys(), ...b.keys()])]
      : [...new Set([...Object.keys(a), ...Object.keys(b)])];
    for (const k of keys) {
      const d = firstDiff(a[k], b[k], Array.isArray(a) ? `${path}[${k}]` : path ? `${path}.${k}` : String(k));
      if (d) return d;
    }
  }
  const trim = (v) => { const t = JSON.stringify(v) ?? 'absent'; return t.length > 200 ? t.slice(0, 200) + ' ...' : t; };
  return `${path || '(whole value)'}\n        catalog: ${trim(a)}\n        product: ${trim(b)}`;
}

const errors = [];
const notes = [];

const classOf = (field) =>
  field in POLICY.mustMatch ? 'mustMatch'
  : field in POLICY.mayDiffer ? 'mayDiffer'
  : field in POLICY.unreconciled ? 'unreconciled'
  : null;

for (const id of ids) {
  const here = join(ROOT, id, SIDECAR);
  if (!existsSync(here)) { errors.push(`${id}: ${here} does not exist in this repository`); continue; }

  let a, b;
  try { a = JSON.parse(readFileSync(here, 'utf8')); }
  catch (e) { errors.push(`${id}: ${here} will not parse: ${e.message}`); continue; }
  try { b = JSON.parse(product[id].text); }
  catch (e) { errors.push(`${id}: ${product[id].where} will not parse: ${e.message}`); continue; }

  for (const field of new Set([...Object.keys(a), ...Object.keys(b)])) {
    if (field === 'validation') continue;
    const cls = classOf(field);
    if (!cls) {
      errors.push(
        `${id}: field "${field}" is in neither mustMatch, mayDiffer nor unreconciled. ` +
        'Classify it in POLICY before it can ship, so no field crosses these two repositories unpoliced.',
      );
      continue;
    }
    if (canon(a[field]) === canon(b[field])) continue;
    if (cls === 'mustMatch') {
      errors.push(`${id}: ${field} differs and must match, at ${firstDiff(a[field], b[field])}`);
    } else if (cls === 'unreconciled') {
      notes.push({ id, field });
    }
  }

  // id and correction must exist on both sides even where the text may differ,
  // because "may differ" was never a licence for one side to be empty.
  for (const req of ['id', 'correction']) {
    for (const [label, obj] of [['catalog', a], ['product', b]]) {
      if (!obj[req] || String(obj[req]).trim() === '') errors.push(`${id}: ${label} has no ${req}`);
    }
  }
  if (a.id !== id || b.id !== id) errors.push(`${id}: the id field inside the sidecar does not match its directory`);

  for (const [sub, cls] of Object.entries(VALIDATION_SUBFIELDS)) {
    const av = a.validation?.[sub], bv = b.validation?.[sub];
    if (cls !== 'mustMatch') continue;
    if (canon(av) !== canon(bv)) {
      // firstDiff, not a whole-value dump. validation.probes is now mustMatch and
      // a skill carries up to twelve probes with a paragraph of prose each, so
      // dumping both sides prints tens of thousands of characters and hides the
      // one line that differs.
      errors.push(`${id}: validation.${sub} differs and must match, at ${firstDiff(av, bv)}`);
    }
  }
}

// ---- the shipped text ----------------------------------------------------
//
// One entry per file, naming the file, because "azuresql-db-rag differs" sends a
// reader to look at four files when one moved.
const textErrors = [];

for (const id of ids) {
  const here = join(ROOT, id);
  if (!existsSync(here)) continue; // already reported by the sidecar loop above
  const mine = shippedHashes(here);
  const theirs = productBody[id] ?? {};

  for (const rel of [...new Set([...Object.keys(mine), ...Object.keys(theirs)])].sort()) {
    if (mine[rel] === theirs[rel]) continue;
    if (!theirs[rel]) { textErrors.push({ id, rel, why: 'is in this catalog and not in the product repository. It was either deleted there and not here, or added here, which forks the product.' }); continue; }
    if (!mine[rel]) { textErrors.push({ id, rel, why: 'exists in the product repository and is missing here, so this catalog is serving a skill whose own links point at a file it does not carry.' }); continue; }
    textErrors.push({ id, rel, why: 'differs' });
  }
}

// Say WHERE the text differs, not only that it does. A reader who is told
// "SKILL.md differs" opens a 400-line file and starts reading; a reader who is
// given the line number and both sides of it knows within seconds whether this is
// a missed sync or somebody editing the catalog copy by hand.
async function productLines(id, rel) {
  if (localPath) return readFileSync(join(localPath, SOURCE.dir, id, rel), 'utf8').split('\n');
  const res = await fetch(`https://raw.githubusercontent.com/${SOURCE.repo}/${SOURCE.ref}/${SOURCE.dir}/${id}/${rel}`);
  if (!res.ok) return null;
  return (await res.text()).split('\n');
}

if (textErrors.length) {
  for (const e of textErrors.filter((e) => e.why === 'differs')) {
    const theirLines = await productLines(e.id, e.rel);
    if (!theirLines) continue;
    const mineLines = readFileSync(join(ROOT, e.id, e.rel), 'utf8').split('\n');
    const n = Math.max(mineLines.length, theirLines.length);
    for (let i = 0; i < n; i++) {
      if (mineLines[i] === theirLines[i]) continue;
      const trim = (v) => (v === undefined ? '(end of file)' : v.length > 160 ? v.slice(0, 160) + ' ...' : v);
      e.why = `differs, first at line ${i + 1}\n        catalog: ${trim(mineLines[i])}\n        product: ${trim(theirLines[i])}`;
      break;
    }
  }
}

// ---- report --------------------------------------------------------------

console.log(`Compared ${ids.length} container sidecars in ${ROOT}/ against ${origin}.`);
console.log('');
const mustMatchValidation = Object.entries(VALIDATION_SUBFIELDS)
  .filter(([, cls]) => cls === 'mustMatch')
  .map(([sub]) => `validation.${sub}`);
console.log('Must match:   ' + [...Object.keys(POLICY.mustMatch).filter((f) => f !== 'validation.target'), ...mustMatchValidation].join(', ')
  + ', and both sides must carry a non-empty correction.');
console.log('May differ:   ' + Object.keys(POLICY.mayDiffer).join(', '));
console.log('Unreconciled: ' + Object.keys(POLICY.unreconciled).join(', ') + '  (reported, not enforced)');
console.log('');
console.log(`Compared the shipped text of the same ${ids.length}: SKILL.md and references/, by git blob hash.`);
console.log('These must be IDENTICAL. AGENTS.md: the container family is carried over, not forked.');

if (notes.length) {
  console.log('');
  const byField = {};
  for (const n of notes) (byField[n.field] ??= []).push(n.id);
  console.log(`${notes.length} unreconciled difference(s) across ${Object.keys(byField).length} field(s). NOT FAILING THE RUN, AND NOT FINE EITHER:`);
  for (const [f, list] of Object.entries(byField)) {
    console.log(`  ~ ${f}: differs on ${list.length} of ${ids.length}  (${list.join(', ')})`);
    console.log(`      ${POLICY.unreconciled[f]}`);
  }
  console.log('  Rule each of these into mustMatch or mayDiffer and this section goes away.');
}

if (textErrors.length) {
  console.error('');
  console.error(`${textErrors.length} shipped file(s) differ from ${SOURCE.repo} at ${SOURCE.ref}:`);
  for (const e of textErrors) console.error(`  x ${e.id}/${e.rel} ${e.why}`);
  console.error('');
  console.error('This text is what a user installs, so a difference here is the catalog');
  console.error('publishing something other than what the product ships.');
  console.error('');
  console.error('THE FIX IS ALWAYS IN ONE DIRECTION. The product repository is the source; copy');
  console.error(`${SOURCE.dir}/<id>/SKILL.md and ${SOURCE.dir}/<id>/references/ from there to here.`);
  console.error('Do not edit these files in this repository to make them agree: that forks the');
  console.error('product, and the next sync silently discards whatever was written here.');
}

if (errors.length) {
  console.error('');
  console.error(`${errors.length} parity failure(s) between this repository and ${SOURCE.repo}:`);
  for (const e of errors) console.error(`  x ${e}`);
}

if (errors.length || textErrors.length) {
  console.error('');
  process.exit(1);
}

console.log('');
console.log(`All ${ids.length} agree on every field that must match, and on every byte of the text they ship.`);
