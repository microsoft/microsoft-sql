#!/usr/bin/env node
// House rules that apply to files the skill linter never sees: documentation,
// workflows, shell handlers, CODEOWNERS.
//
// This exists as a script rather than inline workflow YAML so that `npm test`
// and CI run THE SAME CHECK. When the gate lived only in the workflow, a
// contributor could run npm test, see green, push, and fail CI on a rule their
// local run never applied. Two definitions of "clean" is one too many.

import { readdirSync, statSync, readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';

// Built from its code point so this file does not trip its own check.
const EM_DASH = String.fromCharCode(0x2014);

// What this repository authors. Vendored trees are excluded by naming ours
// rather than listing theirs: an exclusion list goes stale silently, and
// OpenSpec ships its own prose full of em-dashes.
const ROOTS = [
  'scripts', 'catalog', 'skills',
  '.github/workflows', '.github/ISSUE_TEMPLATE',
  'README.md', 'AGENTS.md', 'llms.txt', 'apm.yml', '.github/CODEOWNERS',
];

// The 17 carried-over container skills are excluded deliberately. They are the
// product's files, byte-identical to microsoft/azure-sql-database-container,
// and this repository does not get to reformat them. A change there originates
// upstream.
// Nothing is excluded. This used to skip skills/azure-sql-database-container/,
// a path that stopped existing when the layout went flat, so the exclusion had
// been doing nothing for some time while skills/ was outside ROOTS entirely.
const EXCLUDE = [];

const SKIP_DIRS = new Set(['node_modules', '.git']);

function* walk(p) {
  if (!existsSync(p)) return;
  if (statSync(p).isFile()) { yield p; return; }
  for (const name of readdirSync(p)) {
    if (SKIP_DIRS.has(name)) continue;
    yield* walk(join(p, name));
  }
}

const findings = [];
let scanned = 0;

for (const root of ROOTS) {
  for (const file of walk(root)) {
    if (EXCLUDE.some((re) => re.test(file))) continue;
    if (/\.(png|jpg|svg|ico|woff2?)$/.test(file)) continue;
    scanned++;
    const text = readFileSync(file, 'utf8');
    text.split('\n').forEach((line, i) => {
      if (line.includes(EM_DASH)) findings.push({ file, line: i + 1, rule: 'ST007' });
    });
  }
}

// A scan that examines nothing must not report success. This exact failure has
// happened here: an unquoted shell variable meant the gate scanned a single
// nonexistent path and passed.
if (scanned === 0) {
  console.error('x house rules scanned 0 files. That is a broken check, not a clean tree.');
  process.exit(1);
}

if (findings.length) {
  console.error(`${findings.length} house rule violation(s):`);
  for (const f of findings) console.error(`  x ${f.rule} ${f.file}:${f.line}  em-dash character`);
  console.error('\nST007 is a house rule. Use a comma, a colon, or a full stop.');
  process.exit(1);
}
console.log(`house rules OK, ${scanned} files scanned`);
