#!/usr/bin/env node
// Compare the 17 azuresql-db-* skills in THIS repository, which is where they are
// authored, against the copies of them in the pilot repository,
// microsoft/azure-sql-database-container, which is downstream.
//
//   node scripts/check-container-parity.mjs
//   node scripts/check-container-parity.mjs --pilot-repo /path/to/checkout
//   AZURE_SQL_CONTAINER_REPO=/path/to/checkout node scripts/check-container-parity.mjs
//
// THE DIRECTION WAS REVERSED ON 2026-09-20, AND THAT IS THE WHOLE CHANGE HERE.
//
// Until that day the pilot repository was the parent: the 17 were authored there,
// this catalog held copies, and this script failed the catalog for every byte it
// did not match. Carlos Robles decided on 2026-09-20 that the azuresql-db-* family
// is authored, optimised, evaluated and tested HERE and copied to the pilot
// repository afterwards. So the comparison is the same comparison and the verdict
// it produces is the opposite one: a difference is now the pilot repository being
// BEHIND this catalog, and the catalog is never wrong for having moved first.
//
// AND THE COPY IS ON HOLD. Carlos asked, in the same decision, that nothing be
// pushed downstream yet. So "behind" is the EXPECTED state, not a fault, and this
// check reports it and exits 0. It prints how many files are waiting and since
// when, so the size of the pending copy is in front of anyone who runs the tests
// rather than in somebody's head.
//
// WHAT STILL FAILS THIS RUN, because a check that cannot fail is not a check:
//
//   1. The pilot repository cannot be read. That is UNVERIFIED and it is never
//      OK. "I could not check" and "I checked and it is fine" are the two things
//      this whole exercise exists to stop confusing, and no amount of flipping
//      the ownership direction changes that.
//   2. Anything wrong on THIS side: a sidecar missing from this repository, a
//      sidecar that will not parse, an id that disagrees with its directory, an
//      empty id or correction here, or a field in neither mustMatch, mayDiffer
//      nor unreconciled. Those are defects in the source, and the source is here.
//
// EVERY FIELD IS RULED ON, SINCE 2026-09-20. `value`, `posture` and `applies_to`
// were reported on every run and enforced by nothing, sitting in the
// `unreconciled` class below because nobody had looked at them rather than
// because anyone had decided they may differ. Carlos Robles looked and decided:
// the pilot repository's per-skill `value` labels were adopted where they were
// better, `posture` was ruled skill by skill on what each one has a reader do,
// and `applies_to` differed only in key order. All three are mustMatch now and
// the `unreconciled` class is empty.
//
// WHAT REPLACED THE DEBT FILE. catalog/container-parity-debt.jsonc recorded every
// place this catalog knowingly differed from the pilot repository, as a debt owed
// upstream, because under the old direction a difference was a fault that had to
// be argued for. Under this direction the same set of differences is simply the
// pending copy, and this script computes it from the live comparison on every run.
// The file was deleted on 2026-09-20 rather than renamed: a hand-maintained list
// of differences beside a script that measures the differences is a second copy of
// the same fact, and the hand-maintained one is the one that goes stale. There is
// now one representation of "what the pilot repository has not taken yet", and it
// is the PENDING SYNC section this script prints.

import { readFileSync, existsSync, readdirSync } from 'node:fs';
import { join, relative } from 'node:path';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';

// The pilot repository, and the ref that carries the downstream copies.
//
// PROVENANCE, AND HOW STALENESS SURFACES. The ref is a live branch rather than
// a commit SHA, deliberately. A pinned SHA would turn this into a snapshot
// comparison that goes green forever while the pilot repository moves underneath
// it, which is the same defect one step removed. A branch ref cannot go stale
// silently: it either resolves to whatever the pilot repository says today, or
// it 404s and this script goes red and names the ref it could not find.
const PILOT = {
  repo: 'microsoft/azure-sql-database-container',
  ref: 'main',
  // In the pilot repository the skills live at skills/<id>/, the same relative
  // layout as here.
  dir: 'skills',
};

// The decision this script now implements, and the hold that goes with it.
// Printed on every run, because a hold nobody is reminded of is a hold that
// quietly becomes a fork.
const HOLD = {
  decided_on: '2026-09-20',
  decided_by: 'Carlos Robles',
  what: 'The azuresql-db-* family is authored in this repository and copied to the pilot repository afterwards. The copy is ON HOLD and needs Carlos Robles to say go.',
};

const ROOT = 'skills';
const CATALOG = 'catalog/catalog.json';
const DOMAIN = 'azure-sql-database-container';
const SIDECAR = 'skill.spec.jsonc';

// ---- THE SHIPPED TEXT --------------------------------------------------
//
// WHY THIS IS COMPARED AT ALL, 2026-09-08. Everything below the sidecar policy
// compared contract files and nothing else. So SKILL.md and references/ , which
// are the only files a reader is ever served, were nobody's check. That blind
// spot was then measured, and at the time all 17 SKILL.md files and 5 reference
// files in this catalog were older than the pilot repository's while every gate in
// `npm test` stayed green. The flip on 2026-09-20 does not retire the comparison,
// it retires the verdict: the same drift measured today means the pilot repository
// has not been given this catalog's text yet.
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

// SINCE WHEN A FILE HAS BEEN WAITING. The differing file is a file of THIS
// repository, so this repository's own history is the record of when it last
// moved, and git is the one place that record cannot be typed in wrongly. A file
// git does not know about, because it is new and uncommitted or because this is
// not a checkout, reports itself as that rather than as a date.
function lastChangedHere(path) {
  try {
    const out = execFileSync('git', ['log', '-1', '--format=%cs', '--', path], { encoding: 'utf8' }).trim();
    return out || null;
  } catch {
    return null;
  }
}
const waitingSince = (path) => lastChangedHere(path) ?? 'not committed here yet';

// THE FIELD POLICY.
//
// Every field either must match, may differ for a stated reason, or is not
// reconciled yet. There is no fourth state and there is no default: a field
// that appears in either repository and is not named below FAILS THE RUN, so a
// new field cannot be added on one side and go unpoliced on the other. That
// guard survives the flip untouched, because it is about this repository knowing
// what its own contract contains and not about which repository is the parent.
const POLICY = {
  // Must be identical in both repositories. A difference here is the pilot
  // repository being behind on something that decides what the skill IS.
  mustMatch: {
    id: 'The identity of the skill. If these differ the two files are not about the same thing.',
    domain:
      'Places the skill in this catalog. The family is authored here, so this repository is where the domain is decided.',
    maturity:
      'Derived from what the live probe lane actually ran. If the two disagree, one of them is telling a reader that a claim was tested when it was not.',
    value_declaration:
      'A written acceptance of value signed by a named person on a named date, in place of a measurement. Two versions of that text mean two different things were signed, and nobody could say which one Carlos Robles agreed to.',
    'validation.target':
      'Declares which engines the skill was validated against, and so which runs are owed. Disagreement means the two repositories owe different runs for the same skill.',
    // RULED 2026-09-20 BY CARLOS ROBLES. These three sat in `unreconciled` below
    // from the day this script was written, not because anyone had looked at them
    // and decided they were allowed to differ, but because nobody had looked. That
    // is the state the `unreconciled` bucket exists to make uncomfortable, and it
    // worked: 26 differences across these three fields were reported on every run
    // for long enough to be read, and then ruled on. The ruling was to take the
    // pilot repository's labels where they were better, which on `value` they were
    // on 14 of 17, and to decide `posture` freshly on what each skill has a reader
    // do. What the two repositories say now is the result of that reading, so a
    // difference from here on is drift rather than an unanswered question.
    value:
      'Why the skill is worth shipping. This catalog said not-in-training-data for all 17, which was a bulk fill rather than a reading of 17 skills; the per-skill lists were adopted from the pilot repository on 2026-09-20, checked one label at a time against each skill\'s own correction sentence and body. Two versions of this field mean the two repositories disagree about what the skill is FOR.',
    posture:
      'What the skill has a reader do. Descriptive metadata for grouping and filtering, never an authorization control. Ruled field by field on 2026-09-20 on what each skill actually instructs, so a difference is now a disagreement about the instructions rather than about the vocabulary.',
    applies_to:
      'Who the guidance is for. The one difference on 2026-09-20 was azuresql-db-local-to-cloud carrying the same two values in the other order; this catalog carries them sorted and the comparison below treats all three of these fields as the sets their schema declares them to be, so an order is not a difference. A difference in MEMBERSHIP is, because it changes which engine a reader is told this applies to.',
  },

  // Differ on purpose. The reason is the record of the decision.
  mayDiffer: {
    correction:
      'DELIBERATE. This catalog carries a short summary sized for a catalog entry; the pilot repository carries the full text. Both are true, and forcing them together would either bloat the catalog or truncate the longer text. Both are still required to be present and non-empty.',
    $schema:
      'Catalog only. A relative path to this repository schema, which has no meaning in the pilot repository.',
    related:
      'Pilot only. Cross-references between the 17 as they sit in the pilot repository, which is a different neighbourhood from this catalog of many domains.',
    value_probe:
      'Pilot only. The two-arm value measurement definition as it sits there.',
    triggering:
      'The catalog entries are the pilot eval prompt set, deliberately narrow; the pilot repository carries the fuller authored set. Not reconciled and not intended to be.',
  },

  // Divergent today, with no ruling either way. REPORTED, NOT ENFORCED, and the
  // report says so on every run so that this list is uncomfortable to leave
  // alone. Moving an entry from here to mustMatch or mayDiffer is a decision
  // somebody has to make and write down.
  //
  // EMPTY SINCE 2026-09-20, and kept rather than deleted. It emptied because the
  // last three entries in it were ruled on, which is the only way an entry is
  // meant to leave. Deleting the bucket would delete the place the next
  // unclassified field has to sit and be seen, and a field with nowhere to sit
  // fails the run instead, which is a worse way to find out.
  unreconciled: {},
};

// The three fields above that the schema declares as SETS: arrays with
// `uniqueItems`, whose order nothing reads. They are compared as sets here, so
// ["admin", "provision", "read"] and ["read", "provision", "admin"] are the same
// answer written two ways rather than a difference worth a line in a report.
//
// THIS IS NOT A RELAXATION, because order is still pinned, one level down and in
// the place that can act on it. scripts/backfill-container-sidecars.mjs --check
// compares these three fields against its own literals with JSON.stringify, which
// is order-exact, and it fails this repository's `npm test` on a reordering. So
// the house order is enforced HERE, where it can be fixed, and membership is
// enforced ACROSS the two repositories, where order is somebody else's file.
const SET_FIELDS = new Set(['value', 'posture', 'applies_to']);
const asSet = (field, v) => (SET_FIELDS.has(field) && Array.isArray(v) ? [...v].sort() : v);

// validation is compared subfield by subfield rather than as a whole object,
// because it also carries `assert`, which the two repositories are migrating away
// from at different speeds.
//
// probes are mustMatch, and that is a ruling rather than a tidy-up. `maturity` is
// also mustMatch, and under this repository's own definition of the word,
// `preview` MEANS validation.probes is non-empty and every probe in it ran and
// passed. A repository publishing the maturity without carrying the probes is
// publishing a claim whose stated evidence it does not hold, which is the same
// shape as a check that is green while verifying nothing.
const VALIDATION_SUBFIELDS = { target: 'mustMatch', assert: 'mayDiffer', probes: 'mustMatch' };

const args = process.argv.slice(2);
// --product-repo is the name this flag had while the pilot repository was the
// parent. It still works, because renaming a flag that CI or a maintainer's shell
// history might carry is not worth a broken run.
const flagIndex = args.findIndex((a) => a === '--pilot-repo' || a === '--product-repo');
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

// ---- resolve the pilot repository, or die saying why ---------------------
//
// Every branch below that cannot see the pilot repository says UNVERIFIED and
// exits non-zero. There is no fourth branch that quietly passes.

async function loadFromLocal(base) {
  if (!existsSync(base)) {
    fail([
      `UNVERIFIED. The pilot repository was given as ${base} and there is nothing there.`,
      '',
      'This script will not fall back to the network when it was pointed somewhere',
      'explicitly, because a silent fallback is how a typo turns into a green run.',
      'Fix the path, or drop --pilot-repo and AZURE_SQL_CONTAINER_REPO to fetch',
      `from ${PILOT.repo} at ${PILOT.ref}.`,
    ]);
  }
  const out = {};
  const absent = [];
  for (const id of ids) {
    const p = join(base, PILOT.dir, id, SIDECAR);
    if (!existsSync(p)) { absent.push(p); continue; }
    out[id] = { text: readFileSync(p, 'utf8'), where: p };
  }
  if (absent.length) {
    fail([
      `UNVERIFIED. ${absent.length} of ${ids.length} sidecars are missing from the pilot checkout at ${base}:`,
      ...absent.map((p) => `  x ${p}`),
      '',
      `The copies live on ${PILOT.ref} in the pilot repository. Check out ${PILOT.ref}`,
      'in that clone and pull, or unset the path to fetch that ref over HTTPS.',
      '',
      'A sidecar absent from a checkout is a checkout this script cannot read, not a',
      'measurement that the pilot repository is missing one. Those are different',
      'statements and only the first one is supported by what just happened.',
    ]);
  }
  const body = Object.fromEntries(ids.map((id) => [id, shippedHashes(join(base, PILOT.dir, id))]));
  return { out, body, origin: `local checkout ${base}` };
}

async function loadFromGitHub() {
  const base = `https://raw.githubusercontent.com/${PILOT.repo}/${PILOT.ref}/${PILOT.dir}`;
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
      `UNVERIFIED. Could not read ${broken.length} of ${ids.length} sidecars from ${PILOT.repo} at ${PILOT.ref}:`,
      ...broken.map((r) => `  x ${r.id}: ${r.error}`),
      `      ${broken[0].url}`,
      '',
      'THIS IS A FAILURE AND NOT A SKIP. A check that passes when it cannot see the',
      'other repository is the defect it was written to remove, and reversing which',
      'repository is the parent does not make an unread repository readable.',
      '',
      'Likely causes, in order:',
      `  - the ref ${PILOT.ref} was deleted or renamed. Repoint PILOT.ref in this`,
      '    script at the branch the pilot repository carries the copies on.',
      '  - no network egress on this runner. Give the job a local checkout of the',
      '    pilot repository and set AZURE_SQL_CONTAINER_REPO to it.',
      '  - the pilot repository stopped being public, which would need a token here.',
    ]);
  }
  return {
    out: Object.fromEntries(results.map((r) => [r.id, { text: r.text, where: r.url }])),
    body: await loadShippedFromGitHub(),
    origin: `${PILOT.repo} at ${PILOT.ref} over HTTPS`,
  };
}

// The shipped text over HTTPS, in ONE request.
//
// raw.githubusercontent.com can serve a file and cannot list a directory, and
// listing is the half that matters: fetching only the files this catalog already
// has would be blind to a file the pilot repository carries and this one does not.
// The git trees API returns every path under the ref together with each blob's
// hash, so one call answers both "which files exist there" and "are they the same
// bytes".
//
// GITHUB_TOKEN is used when the environment offers one, purely for the rate
// limit. It is never required: the pilot repository is public, and a check that
// only runs where a secret is configured is a check that silently stops running.
async function loadShippedFromGitHub() {
  const url = `https://api.github.com/repos/${PILOT.repo}/git/trees/${PILOT.ref}?recursive=1`;
  const headers = { Accept: 'application/vnd.github+json', 'User-Agent': 'check-container-parity' };
  if (process.env.GITHUB_TOKEN) headers.Authorization = `Bearer ${process.env.GITHUB_TOKEN}`;

  let doc;
  try {
    const res = await fetch(url, { headers });
    if (!res.ok) {
      fail([
        `UNVERIFIED. Could not list the files of ${PILOT.repo} at ${PILOT.ref}: HTTP ${res.status}`,
        `      ${url}`,
        '',
        'THIS IS A FAILURE AND NOT A SKIP, for the same reason the sidecar fetch above is.',
        '',
        'Likely causes, in order:',
        '  - HTTP 403 with no token: the unauthenticated API rate limit, 60 requests an',
        '    hour per address. Set GITHUB_TOKEN in the environment, or pass',
        '    --pilot-repo <path> to compare against a local checkout instead.',
        `  - HTTP 404: the ref ${PILOT.ref} was deleted or renamed. Repoint PILOT.ref.`,
        '  - no network egress on this runner. Give the job a local checkout and set',
        '    AZURE_SQL_CONTAINER_REPO to it.',
      ]);
    }
    doc = await res.json();
  } catch (e) {
    fail([
      `UNVERIFIED. Could not list the files of ${PILOT.repo} at ${PILOT.ref}: ${e.message}`,
      `      ${url}`,
      '',
      'THIS IS A FAILURE AND NOT A SKIP. A check that passes when it cannot see the',
      'other repository is the defect it was written to remove.',
    ]);
  }

  // The trees API drops entries once a response grows past its own limit and says
  // so in this flag. A truncated tree would look exactly like a repository with
  // fewer files, so believing it would turn this into a check that passes because
  // it did not see the evidence.
  if (doc.truncated) {
    fail([
      `UNVERIFIED. The git tree of ${PILOT.repo} at ${PILOT.ref} came back TRUNCATED, so the`,
      'file list is incomplete and a missing file cannot be told apart from a deleted one.',
      '',
      'Pass --pilot-repo <path> to compare against a local checkout, which has no',
      'such limit.',
    ]);
  }

  const wanted = new Set(ids);
  const body = Object.fromEntries(ids.map((id) => [id, {}]));
  for (const entry of doc.tree ?? []) {
    if (entry.type !== 'blob') continue;
    const parts = entry.path.split('/');
    if (parts[0] !== PILOT.dir || !wanted.has(parts[1])) continue;
    const rel = parts.slice(2).join('/');
    if (isShipped(rel)) body[parts[1]][rel] = entry.sha;
  }

  const empty = ids.filter((id) => !body[id]['SKILL.md']);
  if (empty.length) {
    fail([
      `UNVERIFIED. ${empty.length} of ${ids.length} skills have no SKILL.md in ${PILOT.repo} at ${PILOT.ref}:`,
      ...empty.map((id) => `  x ${PILOT.dir}/${id}/SKILL.md`),
      '',
      'Either the pilot repository moved these files or the tree was read wrongly.',
      'Either way this run did not see what it came to see, so it says so rather',
      'than reporting seventeen skills as waiting on a copy.',
    ]);
  }
  return body;
}

const { out: pilot, body: pilotBody, origin } = localPath ? await loadFromLocal(localPath) : await loadFromGitHub();

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
  return `${path || '(whole value)'}\n        here:  ${trim(a)}\n        pilot: ${trim(b)}`;
}

// errors   defects on THIS side. They fail the run.
// pending  the pilot repository is behind. Reported, never a failure.
// notes    unreconciled fields. Reported, never a failure.
const errors = [];
const pending = [];
const notes = [];

const classOf = (field) =>
  field in POLICY.mustMatch ? 'mustMatch'
  : field in POLICY.mayDiffer ? 'mayDiffer'
  : field in POLICY.unreconciled ? 'unreconciled'
  : null;

for (const id of ids) {
  const here = join(ROOT, id, SIDECAR);
  if (!existsSync(here)) { errors.push(`${id}: ${here} does not exist in this repository, which authors it`); continue; }

  let a, b;
  try { a = JSON.parse(readFileSync(here, 'utf8')); }
  catch (e) { errors.push(`${id}: ${here} will not parse: ${e.message}`); continue; }
  try { b = JSON.parse(pilot[id].text); }
  catch (e) { pending.push({ id, what: SIDECAR, why: `the copy at ${pilot[id].where} will not parse: ${e.message}. Copying this sidecar from here replaces it.`, since: waitingSince(here) }); continue; }

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
    if (canon(asSet(field, a[field])) === canon(asSet(field, b[field]))) continue;
    if (cls === 'mustMatch') {
      pending.push({ id, what: `${SIDECAR} ${field}`, why: `differs, at ${firstDiff(asSet(field, a[field]), asSet(field, b[field]))}`, since: waitingSince(here) });
    } else if (cls === 'unreconciled') {
      notes.push({ id, field });
    }
  }

  // id and correction must exist on both sides even where the text may differ,
  // because "may differ" was never a licence for one side to be empty. An empty
  // one HERE is a defect in the source and fails; an empty one in the pilot
  // repository is something the copy fixes.
  for (const req of ['id', 'correction']) {
    if (!a[req] || String(a[req]).trim() === '') errors.push(`${id}: this repository has no ${req}`);
    if (!b[req] || String(b[req]).trim() === '') pending.push({ id, what: `${SIDECAR} ${req}`, why: 'the pilot copy has none. Copying this sidecar from here gives it one.', since: waitingSince(here) });
  }
  if (a.id !== id) errors.push(`${id}: the id field inside ${here} does not match its directory`);
  if (b.id !== id) pending.push({ id, what: `${SIDECAR} id`, why: `the pilot copy says "${b.id}", which does not match its directory there.`, since: waitingSince(here) });

  for (const [sub, cls] of Object.entries(VALIDATION_SUBFIELDS)) {
    const av = a.validation?.[sub], bv = b.validation?.[sub];
    if (cls !== 'mustMatch') continue;
    if (canon(av) !== canon(bv)) {
      // firstDiff, not a whole-value dump. validation.probes is mustMatch and a
      // skill carries up to twelve probes with a paragraph of prose each, so
      // dumping both sides prints tens of thousands of characters and hides the
      // one line that differs.
      pending.push({ id, what: `${SIDECAR} validation.${sub}`, why: `differs, at ${firstDiff(av, bv)}`, since: waitingSince(here) });
    }
  }
}

// ---- the shipped text ----------------------------------------------------
//
// One entry per file, naming the file, because "azuresql-db-rag differs" sends a
// reader to look at four files when one moved.
const textPending = [];

for (const id of ids) {
  const here = join(ROOT, id);
  if (!existsSync(here)) continue; // already reported by the sidecar loop above
  const mine = shippedHashes(here);
  const theirs = pilotBody[id] ?? {};

  for (const rel of [...new Set([...Object.keys(mine), ...Object.keys(theirs)])].sort()) {
    if (mine[rel] === theirs[rel]) continue;
    const since = waitingSince(join(here, rel));
    if (!theirs[rel]) { textPending.push({ id, rel, since, why: 'is in this repository and not in the pilot repository. The copy adds it there.' }); continue; }
    if (!mine[rel]) { textPending.push({ id, rel, since, why: 'is in the pilot repository and not here. The copy deletes it there, so check it was meant to go before the copy runs.' }); continue; }
    textPending.push({ id, rel, since, why: 'differs' });
  }
}

// Say WHERE the text differs, not only that it does. A reader who is told
// "SKILL.md differs" opens a 400-line file and starts reading; a reader who is
// given the line number and both sides of it knows within seconds how big the
// pending copy actually is.
async function pilotLines(id, rel) {
  if (localPath) return readFileSync(join(localPath, PILOT.dir, id, rel), 'utf8').split('\n');
  const res = await fetch(`https://raw.githubusercontent.com/${PILOT.repo}/${PILOT.ref}/${PILOT.dir}/${id}/${rel}`);
  if (!res.ok) return null;
  return (await res.text()).split('\n');
}

for (const e of textPending.filter((e) => e.why === 'differs')) {
  const theirLines = await pilotLines(e.id, e.rel);
  if (!theirLines) continue;
  const mineLines = readFileSync(join(ROOT, e.id, e.rel), 'utf8').split('\n');
  const n = Math.max(mineLines.length, theirLines.length);
  for (let i = 0; i < n; i++) {
    if (mineLines[i] === theirLines[i]) continue;
    const trim = (v) => (v === undefined ? '(end of file)' : v.length > 160 ? v.slice(0, 160) + ' ...' : v);
    e.why = `differs, first at line ${i + 1}\n        here:  ${trim(mineLines[i])}\n        pilot: ${trim(theirLines[i])}`;
    break;
  }
}

// ---- report --------------------------------------------------------------

const allPending = [
  ...pending.map((p) => ({ label: `${p.id}/${p.what}`, why: p.why, since: p.since })),
  ...textPending.map((p) => ({ label: `${p.id}/${p.rel}`, why: p.why, since: p.since })),
];
const dates = allPending.map((p) => p.since).filter((s) => /^\d{4}-\d{2}-\d{2}$/.test(s)).sort();

console.log(`Compared the ${ids.length} azuresql-db-* skills in ${ROOT}/, which this repository authors,`);
console.log(`against their copies in ${origin}.`);
console.log('');
console.log(`DIRECTION. This repository is the source. ${PILOT.repo} is the downstream copy.`);
console.log(`Decided ${HOLD.decided_on} by ${HOLD.decided_by}: ${HOLD.what}`);
console.log('So a difference below means the PILOT REPOSITORY IS BEHIND, and this run reports');
console.log('it and exits 0. It never fails this repository for having moved first.');
console.log('');
const mustMatchValidation = Object.entries(VALIDATION_SUBFIELDS)
  .filter(([, cls]) => cls === 'mustMatch')
  .map(([sub]) => `validation.${sub}`);
console.log('Must match:   ' + [...Object.keys(POLICY.mustMatch).filter((f) => f !== 'validation.target'), ...mustMatchValidation].join(', ')
  + ', and both sides must carry a non-empty correction.');
console.log('May differ:   ' + Object.keys(POLICY.mayDiffer).join(', '));
console.log('Unreconciled: ' + (Object.keys(POLICY.unreconciled).join(', ') || 'nothing. value, posture and applies_to were the last three and Carlos Robles ruled on them on 2026-09-20'));
console.log(`Compared as sets, because their schema says uniqueItems and nothing reads their order: ${[...SET_FIELDS].join(', ')}.`);
console.log('Their order is still exact, and enforced by scripts/backfill-container-sidecars.mjs --check.');
console.log('');
console.log(`Compared the shipped text of the same ${ids.length}: SKILL.md and references/, by git blob hash.`);

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

if (allPending.length) {
  console.log('');
  console.log('='.repeat(78));
  console.log(`PENDING SYNC: ${allPending.length} file(s) and field(s) the pilot repository has not taken.`);
  if (dates.length) {
    console.log(`The oldest has been waiting since ${dates[0]}, the newest since ${dates[dates.length - 1]}.`);
  } else {
    console.log('None of them has a commit date here yet, so none has a waiting-since date.');
  }
  console.log(`The copy is on hold, decided ${HOLD.decided_on} by ${HOLD.decided_by}, so this is the`);
  console.log('expected state and NOT A FAILURE. It is also not nothing: until the copy runs,');
  console.log(`a customer installing from ${PILOT.repo} reads the older text.`);
  console.log('='.repeat(78));
  for (const p of allPending) {
    console.log(`  > ${p.label} ${p.why}`);
    console.log(`      waiting since ${p.since}`);
  }
  console.log('='.repeat(78));
  console.log('THE COPY GOES ONE WAY, AND ONLY WHEN CARLOS ROBLES SAYS GO. When it does, copy');
  console.log(`${ROOT}/<id>/ from here to ${PILOT.dir}/<id>/ there. Do not edit these files in the`);
  console.log('pilot repository to make them agree: that forks the source, and the next copy');
  console.log('silently discards whatever was written there.');
}

if (errors.length) {
  console.error('');
  console.error(`${errors.length} defect(s) in this repository, which authors these skills:`);
  for (const e of errors) console.error(`  x ${e}`);
  console.error('');
  console.error('These are not the pilot repository being behind. They are wrong HERE, in the');
  console.error('source, so they fail this run and copying them downstream would spread them.');
  console.error('');
  process.exit(1);
}

console.log('');
if (allPending.length) {
  console.log(`Nothing is wrong in this repository. ${allPending.length} file(s) and field(s) are waiting on a copy`);
  console.log(`to ${PILOT.repo}, which is on hold.`);
} else {
  console.log(`All ${ids.length} agree on every field that must match and on every byte of the text they`);
  console.log('ship, so the pilot repository is not behind on anything. Nothing is waiting.');
}
