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

// Internal shorthand that means nothing to a reader here.
//
// The rule ids come from a constitution, and the decision ids and section
// numbers come from a planning document, and BOTH LIVE IN A DIFFERENT
// REPOSITORY that a reader of this one cannot open. So the reference is not
// merely terse, it is unresolvable: there is no document to go and look it up
// in. That is the difference between jargon and a citation.
//
// Carlos, 2026-09-01, reading a rule id in the sidecar schema description:
// "nobody will understand that and I'm not planning to checkout the PRD."
// The id he was looking at is the one this file's own check would now flag, so
// it is not quoted here: like the em-dash above, naming it would trip the rule.
//
// Say the rule in words instead. If the words are too long for the sentence,
// the sentence is carrying a rule that needs its own line.
//
// Deliberately NOT matched: product error codes such as SQL71627 and Msg 40510,
// which are real identifiers a reader can search for and which skills must keep
// naming precisely. The prefixes below are ours alone.
const SHORTHAND = [
  { re: /\b(?:VAL|BD|SEC|ST|FM|SCP|LAY|XR)\d{3}\b/, what: 'an internal rule id' },
  { re: /\bSection \d+(?:\.\d+)* of the PRD\b/i, what: 'a section number in a document readers here do not have' },
  { re: /\bADR-\d+\b/, what: 'an internal decision id' },
];

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
      if (line.includes(EM_DASH)) findings.push({ file, line: i + 1, why: 'em-dash character' });
      for (const s of SHORTHAND) {
        const m = s.re.exec(line);
        if (m) findings.push({ file, line: i + 1, why: `"${m[0]}" is ${s.what}` });
      }
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
  for (const f of findings) console.error(`  x ${f.file}:${f.line}  ${f.why}`);
  console.error('');
  console.error('Em-dashes: use a comma, a colon, or a full stop.');
  console.error('Internal ids: say the rule in words. The document that defines the id lives in');
  console.error('another repository, so a reader here has nothing to look it up in.');
  process.exit(1);
}
console.log(`house rules OK, ${scanned} files scanned`);
