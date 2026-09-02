#!/usr/bin/env node
// Is this repository actually installable through APM, and is it still
// conformant to Agent Plugins while being so.
//
// WHY THIS EXISTS. `apm.yml` was generated, committed and public for weeks and
// supported nothing. `apm pack` reported "nothing to pack": the manifest carried
// `version: 1`, which OpenAPM requires to be a SemVer string, put the real
// version in `version_number`, which is not a field, listed `skills:` at the top
// level, which is not a field either, and declared no `targets:`. Nobody had run
// the tool against it. A manifest whose presence implies support, with no check
// behind it, is indistinguishable from support until a customer tries.
//
// THE LAYOUT CONSTRAINT IS THE IMPORTANT ONE. APM accepts two source layouts and
// resolves `.apm/` IN PREFERENCE TO root-level `skills/`. The Agent Plugins
// specification pins skills at `skills/`, and its plugin.json schema is closed:
// `additionalProperties: false`, with no `skills` and no `agent` property. So
// creating `.apm/` would shadow the directory every non-APM client reads, break
// conformance, and emit no error anywhere. That check is the reason this file is
// not just a wrapper around the CLI.
//
// Two halves. The static half needs nothing installed and always runs. The live
// half runs `apm` when it is on PATH and is required in CI.
//
// Usage: node scripts/check-apm.mjs [--require-cli]
// Exit:  0 clean, 1 findings, 2 could not run.

import { readFileSync, existsSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const requireCli = process.argv.includes('--require-cli');
const findings = [];
const notes = [];
const fail = (what, why, fix) => findings.push({ what, why, fix });

// A tiny reader for the flat subset of YAML this manifest uses. Pulling in a
// parser for six scalar keys would add a dependency to a repository that has
// none, and the generator writes this file, so the shape is known.
function readManifest(text) {
  const out = {};
  const lines = text.split('\n');
  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i];
    if (!line.trim() || line.trimStart().startsWith('#')) continue;
    const m = /^([a-z_][a-z0-9_]*):\s*(.*)$/i.exec(line);
    if (!m) continue;
    const [, key, rest] = m;
    if (rest === '>-' || rest === '>' || rest === '|') {
      const buf = [];
      for (let j = i + 1; j < lines.length && /^\s+\S/.test(lines[j]); j += 1) buf.push(lines[j].trim());
      out[key] = buf.join(' ');
    } else if (rest === '') {
      const buf = [];
      for (let j = i + 1; j < lines.length && /^\s*-\s/.test(lines[j]); j += 1) buf.push(lines[j].replace(/^\s*-\s*/, '').trim());
      out[key] = buf;
    } else if (/^\[.*\]$/.test(rest)) {
      out[key] = rest.slice(1, -1).split(',').map((x) => x.trim()).filter(Boolean);
    } else {
      out[key] = rest.replace(/^["']|["']$/g, '');
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// The layout constraint. This one is not about APM working; it is about APM
// working WITHOUT breaking everyone else.
// ---------------------------------------------------------------------------
if (existsSync(resolve(ROOT, '.apm'))) {
  fail('.apm/ exists', 'APM resolves .apm/ in preference to root-level skills/, so this shadows the directory the Agent Plugins specification pins and every non-APM client reads. Nothing reports an error; installs simply find no skills.',
    'Delete .apm/ and keep skills/ at the repository root. APM reads the root layout as a skill collection with no structural change.');
}
if (!existsSync(resolve(ROOT, 'skills'))) {
  fail('no skills/ directory', 'Agent Plugins fixes the component location at skills/.', 'Restore it.');
}

// ---------------------------------------------------------------------------
// The Agent Plugins manifest. Its schema is CLOSED, so an extra key is a
// conformance break, not a harmless addition.
// ---------------------------------------------------------------------------
const PLUGIN_ALLOWED = new Set(['$schema', 'name', 'version', 'description', 'author', 'homepage', 'repository', 'license', 'keywords', 'extensions']);
const pluginPath = resolve(ROOT, 'plugin.json');
if (!existsSync(pluginPath)) {
  fail('plugin.json missing', 'The Agent Plugins manifest is required at the repository root.', 'Run node scripts/generate.mjs');
} else {
  let plugin;
  try { plugin = JSON.parse(readFileSync(pluginPath, 'utf8')); }
  catch (e) { fail('plugin.json unparseable', e.message, 'Run node scripts/generate.mjs'); }
  if (plugin) {
    for (const k of ['$schema', 'name']) {
      if (!plugin[k]) fail(`plugin.json has no ${k}`, 'Required by the Agent Plugins schema.', 'Run node scripts/generate.mjs');
    }
    const extra = Object.keys(plugin).filter((k) => !PLUGIN_ALLOWED.has(k));
    if (extra.length) {
      fail(`plugin.json carries ${extra.join(', ')}`,
        'The Agent Plugins schema sets additionalProperties: false and defines no skills and no agent property. An extra key fails conformance validation for every client that checks it.',
        'Skills are discovered from the fixed skills/ directory, never declared. Anything client-specific belongs under extensions, in a reverse-domain namespace.');
    }
  }
}

// ---------------------------------------------------------------------------
// The OpenAPM manifest.
// ---------------------------------------------------------------------------
const SEMVER = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z-.]+)?(?:\+[0-9A-Za-z-.]+)?$/;
const APM_KNOWN = new Set(['name', 'version', 'description', 'author', 'license', 'homepage', 'repository', 'keywords', 'type', 'targets', 'target', 'includes', 'dependencies', 'devDependencies', 'scripts', 'compilation', 'policy', 'marketplace']);
const apmPath = resolve(ROOT, 'apm.yml');
if (!existsSync(apmPath)) {
  fail('apm.yml missing', 'A directory is an APM package once it contains this file.', 'Run node scripts/generate.mjs');
} else {
  const m = readManifest(readFileSync(apmPath, 'utf8'));
  if (!m.name) fail('apm.yml has no name', 'Required by OpenAPM.', 'Run node scripts/generate.mjs');
  if (!m.version) {
    fail('apm.yml has no version', 'Required by OpenAPM.', 'Run node scripts/generate.mjs');
  } else if (!SEMVER.test(String(m.version))) {
    fail(`apm.yml version is "${m.version}"`, 'OpenAPM requires a SemVer 2.0.0 string. This manifest shipped with version: 1 and the real version in a field that does not exist.', 'Run node scripts/generate.mjs');
  }
  if ('skills' in m) {
    fail('apm.yml declares a top-level skills key', 'Not a field in the OpenAPM schema. Skills are discovered from the root skills/ directory.', 'Run node scripts/generate.mjs');
  }
  if ('version_number' in m) {
    fail('apm.yml declares version_number', 'Not a field in the OpenAPM schema.', 'Run node scripts/generate.mjs');
  }
  const targets = m.targets ?? m.target ?? [];
  const list = Array.isArray(targets) ? targets : String(targets).split(',').map((x) => x.trim());
  if (!m.dependencies && !m.marketplace && !list.some((t) => t === 'claude' || t === 'copilot')) {
    fail('apm pack would produce nothing',
      'With no dependencies: block, no marketplace: block and no target including claude or copilot, apm pack reports "nothing to pack". That is the state this repository shipped in.',
      'Declare targets: in apm.yml. The generator does this.');
  }
  const unknown = Object.keys(m).filter((k) => !APM_KNOWN.has(k));
  if (unknown.length) notes.push(`apm.yml carries key(s) not in the OpenAPM reference: ${unknown.join(', ')}. Verify against microsoft.github.io/apm before shipping.`);
}

// ---------------------------------------------------------------------------
// The live half. Proves the tool agrees, rather than trusting this file's
// reading of the schema.
// ---------------------------------------------------------------------------
let cli = null;
try { cli = execFileSync('apm', ['--version'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim(); }
catch { /* not installed */ }

if (!cli) {
  if (requireCli) {
    fail('the apm CLI is not on PATH', 'This run was asked to require it, so the strongest half of the check did not execute.', 'Install APM, or drop --require-cli for a local run.');
  } else {
    notes.push('apm is not on PATH, so only the static half ran. Nothing verified that the tool agrees.');
  }
} else {
  let out = '';
  try {
    out = execFileSync('apm', ['pack', '--offline', '--dry-run'], { cwd: ROOT, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  } catch (e) {
    out = `${e.stdout ?? ''}${e.stderr ?? ''}`;
  }
  if (/nothing to pack/i.test(out)) {
    fail('apm pack produces nothing', out.replace(/\s+/g, ' ').trim().slice(0, 300), 'Declare targets: in apm.yml. The generator does this.');
  } else if (!/would write|plugin manifest/i.test(out)) {
    fail('apm pack said something unexpected', out.replace(/\s+/g, ' ').trim().slice(0, 300), 'Read the output above and reconcile with microsoft.github.io/apm.');
  } else {
    const manifests = [...out.matchAll(/([^\s]*(?:\.claude-plugin|\.github\/plugin)\/plugin\.json)/g)].map((x) => x[1]);
    notes.push(`apm ${cli} would emit ${manifests.length} plugin manifest(s): ${manifests.map((p) => p.replace(ROOT, '.')).join(', ')}`);
  }
}

if (findings.length) {
  console.error(`x ${findings.length} APM or Agent Plugins finding(s)`);
  console.error('');
  for (const f of findings) {
    console.error(`  ${f.what}`);
    console.error(`    ${f.why}`);
    console.error(`    fix: ${f.fix}`);
    console.error('');
  }
  process.exit(1);
}
console.log('APM OK: the package is installable and still conformant to Agent Plugins');
for (const n of notes) console.log(`  ${n}`);
