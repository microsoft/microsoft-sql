#!/usr/bin/env node
// The skill-feedback skill builds a prefilled issue by field id. Those ids are
// therefore a CONTRACT, not an implementation detail: renaming one silently
// breaks every report the skill files, and nothing else would notice.
//
// This asserts the form still exposes exactly the ids the skill fills.

import { readFileSync } from 'node:fs';

const FORM = '.github/ISSUE_TEMPLATE/skill_feedback.yml';
const REQUIRED = ['skill', 'problem-type', 'agent', 'install-method', 'what-happened', 'skill-said', 'repro', 'additional', 'confirm'];

const text = readFileSync(FORM, 'utf8');
const ids = [...text.matchAll(/^    id:\s*(\S+)\s*$/gm)].map((m) => m[1]);

const missing = REQUIRED.filter((r) => !ids.includes(r));
const extra = ids.filter((i) => !REQUIRED.includes(i));

if (missing.length || extra.length) {
  if (missing.length) console.error(`x ${FORM} is missing field ids the feedback skill fills: ${missing.join(', ')}`);
  if (extra.length) console.error(`x ${FORM} has field ids the feedback skill does not know: ${extra.join(', ')}`);
  console.error('  Update the skill and this list together, or reports will arrive with empty fields.');
  process.exit(1);
}

// The label is the only conversion signal markdown content has.
if (!/labels:.*via-skill/.test(text)) {
  console.error(`x ${FORM} must carry the via-skill label. It is the only conversion signal we get.`);
  process.exit(1);
}
console.log(`prefill contract intact: ${ids.length} field ids, via-skill label present`);
