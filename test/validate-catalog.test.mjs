// The status check in scripts/validate-catalog.mjs.
//
// Until 2026-09-19 every authored skill in skills/ was marked planned-core in
// catalog/catalog.json and every gate stayed green, because the validator only
// checked that a skill marked shipped had a directory, never that a directory
// was marked shipped. These tests plant both bad states and watch it go red.
//
// They run the real script against a temporary copy of the real catalog/ and
// skills/, the same choice the lab's promote-maturity.test.mjs makes: a gate
// tested only against fixtures written by the hand that wrote the gate is
// pinned to nothing. The first test is the control. If the untouched copy
// fails, every red below proves nothing, so it must pass first.

import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { cpSync, mkdtempSync, readFileSync, readdirSync, writeFileSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const VALIDATE = join(ROOT, 'scripts/validate-catalog.mjs');

function copyOfRepo() {
  const dir = mkdtempSync(join(tmpdir(), 'validate-catalog-'));
  cpSync(join(ROOT, 'catalog'), join(dir, 'catalog'), { recursive: true });
  cpSync(join(ROOT, 'skills'), join(dir, 'skills'), { recursive: true });
  return dir;
}

function editCatalog(dir, fn) {
  const p = join(dir, 'catalog/catalog.json');
  const c = JSON.parse(readFileSync(p, 'utf8'));
  fn(c);
  writeFileSync(p, JSON.stringify(c, null, 2) + '\n');
}

const run = (dir) => spawnSync(process.execPath, [VALIDATE], { cwd: dir, encoding: 'utf8' });

// Sorted so the skill under test is the same one on every machine.
const onDisk = readdirSync(join(ROOT, 'skills'))
  .filter((d) => statSync(join(ROOT, 'skills', d)).isDirectory())
  .sort();

test('the untouched catalog passes, so the reds below mean something', () => {
  const r = run(copyOfRepo());
  assert.equal(r.status, 0, r.stderr);
});

for (const planned of ['planned-core', 'backlog']) {
  test(`a skill in skills/ marked ${planned} fails`, () => {
    assert.ok(onDisk.length > 0, 'found no skill directories to plant against');
    const id = onDisk[0];
    const dir = copyOfRepo();
    editCatalog(dir, (c) => { c.skills.find((s) => s.id === id).status = planned; });
    const r = run(dir);
    assert.equal(r.status, 1, `expected red, got exit ${r.status}\n${r.stdout}`);
    assert.match(r.stderr, new RegExp(`"${id}" has a directory under skills/ but is marked ${planned}`));
  });
}

test('an entry marked shipped-pilot with no directory fails', () => {
  const entries = JSON.parse(readFileSync(join(ROOT, 'catalog/catalog.json'), 'utf8')).skills;
  const absent = entries.map((s) => s.id).filter((id) => !onDisk.includes(id)).sort()[0];
  assert.ok(absent, 'found no roadmap entry to plant against');
  const dir = copyOfRepo();
  editCatalog(dir, (c) => { c.skills.find((s) => s.id === absent).status = 'shipped-pilot'; });
  const r = run(dir);
  assert.equal(r.status, 1, `expected red, got exit ${r.status}\n${r.stdout}`);
  assert.match(r.stderr, new RegExp(`"${absent}" is marked shipped-pilot but has no directory`));
});
