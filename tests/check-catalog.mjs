#!/usr/bin/env node
// Fast, platform-independent catalog checks (runs on Linux CI before the Windows matrix):
//  - every catalog module has install.ps1, uninstall.ps1 and tests/modules/<id>.Verify.ps1
//  - every Windows CI scenario has a fixture, and every fixture is in the matrix
//  - each core template contains each placeholder exactly once (a second copy, e.g. in a
//    comment, would get substituted too)
//  - every fixture renders, and no placeholder survives into the output

import { readFileSync, writeFileSync, readdirSync, existsSync } from 'node:fs';
import { createHash } from 'node:crypto';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { renderAll, loadCatalog, loadRawCatalog } from '../tools/render.mjs';

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const errors = [];
const rawCatalog = loadRawCatalog();
const catalog = loadCatalog(); // expanded: hand-written modules + one app-<id> module per docs/apps/<id>.json

const OPTION_TYPES = ['text', 'url', 'select', 'radio', 'checkbox', 'icon', 'secret', 'multiselect'];
const NEEDS_VALUES = ['select', 'radio', 'multiselect'];

function checkSchema(m) {
  const at = `module '${m.id}'`;
  if ('needsAdmin' in m) errors.push(`${at}: needsAdmin was replaced by scope: "user"|"machine"`);
  if (!['user', 'machine'].includes(m.scope)) errors.push(`${at}: scope must be "user" or "machine"`);
  if (!Array.isArray(m.options)) { errors.push(`${at}: options must be an array`); return; }
  const keys = new Set();
  for (const o of m.options) {
    const oat = `${at} option '${o.key}'`;
    if (!/^[A-Za-z][A-Za-z0-9]*$/.test(o.key || '')) errors.push(`${at}: option key '${o.key}' must be alphanumeric`);
    if (keys.has(o.key)) errors.push(`${oat}: duplicate key`);
    keys.add(o.key);
    if (!OPTION_TYPES.includes(o.type)) { errors.push(`${oat}: unknown type '${o.type}'`); continue; }
    if (o.type === 'secret') errors.push(`${oat}: secret options are not allowed until the secrets batch (they would be embedded in the .cmd)`);
    if (!o.label) errors.push(`${oat}: missing label`);
    if (NEEDS_VALUES.includes(o.type)) {
      if (!Array.isArray(o.values) || o.values.length === 0 || o.values.some((v) => !v || typeof v.value !== 'string' || !v.label)) {
        errors.push(`${oat}: ${o.type} needs a non-empty values list of {value,label}`);
      } else {
        const vals = o.values.map((v) => v.value);
        const defs = o.type === 'multiselect' ? o.default || [] : o.default === undefined ? [] : [o.default];
        for (const d of defs) if (!vals.includes(d)) errors.push(`${oat}: default '${d}' is not in values`);
        if (o.type === 'multiselect' && o.default !== undefined && !Array.isArray(o.default)) errors.push(`${oat}: multiselect default must be an array`);
      }
    } else if (o.values !== undefined) errors.push(`${oat}: values only apply to select/radio/multiselect`);
    if (o.type === 'checkbox' && o.default !== undefined && typeof o.default !== 'boolean') errors.push(`${oat}: checkbox default must be boolean`);
    if (['text', 'url', 'secret'].includes(o.type) && o.default !== undefined && typeof o.default !== 'string') errors.push(`${oat}: default must be a string`);
    if (o.type === 'icon' && !/B64$/.test(o.key)) errors.push(`${oat}: icon option keys must end in B64 (fixtures use the matching ...Path)`);
    if (o.pattern !== undefined) {
      try { new RegExp(o.pattern); } catch { errors.push(`${oat}: pattern is not a valid regex`); }
    }
    if (o.sanitize !== undefined && o.sanitize !== 'filename') errors.push(`${oat}: sanitize must be "filename"`);
  }
  if (m.fileNameFrom !== undefined && !m.options.some((o) => o.key === m.fileNameFrom && ['text', 'url'].includes(o.type))) {
    errors.push(`${at}: fileNameFrom '${m.fileNameFrom}' is not a text option of this module`);
  }
}

// ---- Curated apps (docs/apps/<id>.json) ------------------------------------------------------
// Admission rules (CLAUDE.md): pinned winget ID (the engine always adds --source winget --exact)
// or a signature/hash-checked URL, a detect step, an uninstall path. Unknown keys are errors so a
// typo can't silently weaken a check.
const APP_KEYS = ['id', 'label', 'description', 'order', 'scope', 'requires', 'source', 'detect', 'uninstall', 'notes'];
const ENV_ROOTED = /^%(ProgramFiles|ProgramFiles\(x86\)|ProgramW6432|LOCALAPPDATA|APPDATA|ProgramData|SystemRoot|windir|USERPROFILE)%[\\/]/i;
const WINGET_ID = /^[A-Za-z0-9][A-Za-z0-9_-]*(\.[A-Za-z0-9][A-Za-z0-9_-]*)+$/;

function unknownKeys(obj, allowed, at) {
  for (const k of Object.keys(obj)) if (!allowed.includes(k)) errors.push(`${at}: unknown key '${k}'`);
}
function checkArgs(args, at) {
  if (!Array.isArray(args) || args.some((a) => typeof a !== 'string' || a === '')) errors.push(`${at}: args must be an array of non-empty strings`);
}
function checkRegex(v, at) {
  if (typeof v !== 'string' || !v) { errors.push(`${at}: must be a non-empty regex string`); return; }
  try { new RegExp(v); } catch { errors.push(`${at}: not a valid regex`); }
}

function checkApp(id, a) {
  const at = `app '${id}'`;
  if (!/^[a-z0-9][a-z0-9-]*$/.test(id)) errors.push(`${at}: id must be lowercase letters, digits and dashes`);
  if (a.id !== id) errors.push(`${at}: "id" in docs/apps/${id}.json is '${a.id}'`);
  unknownKeys(a, APP_KEYS, at);
  for (const k of ['label', 'description']) if (!a[k] || typeof a[k] !== 'string') errors.push(`${at}: missing ${k}`);
  if (typeof a.order !== 'number' || a.order < 100) errors.push(`${at}: order must be a number >= 100 (hand-written modules use < 100)`);
  if (!['user', 'machine'].includes(a.scope)) errors.push(`${at}: scope must be "user" or "machine"`);
  if (a.requires !== undefined && (!Array.isArray(a.requires) || a.requires.some((r) => typeof r !== 'string'))) errors.push(`${at}: requires must be an array of module ids`);

  const s = a.source || {};
  if (s.type === 'winget') {
    unknownKeys(s, ['type', 'id'], `${at} source`);
    if (!WINGET_ID.test(s.id || '')) errors.push(`${at}: source.id '${s.id}' is not a winget package ID (Publisher.Package)`);
  } else if (s.type === 'url') {
    unknownKeys(s, ['type', 'url', 'sha256', 'signer', 'args', 'timeoutSec'], `${at} source`);
    if (!/^https:\/\/[^\s/]+\/\S+$/.test(s.url || '')) errors.push(`${at}: source.url must be an https:// URL`);
    if (s.sha256 === undefined && s.signer === undefined) errors.push(`${at}: a url source needs sha256 and/or signer (never run an unverified download)`);
    if (s.sha256 !== undefined && !/^[0-9a-f]{64}$/.test(s.sha256)) errors.push(`${at}: sha256 must be 64 lowercase hex characters`);
    if (s.signer !== undefined) checkRegex(s.signer, `${at} source.signer`);
    checkArgs(s.args, `${at} source.args (silent switches)`);
    if (s.timeoutSec !== undefined && !(Number.isInteger(s.timeoutSec) && s.timeoutSec > 0 && s.timeoutSec <= 3600)) errors.push(`${at}: timeoutSec must be 1-3600`);
  } else errors.push(`${at}: source.type must be "winget" or "url"`);

  if (!Array.isArray(a.detect) || a.detect.length === 0) errors.push(`${at}: detect must be a non-empty array`);
  else {
    a.detect.forEach((d, i) => {
      const dat = `${at} detect[${i}]`;
      if (d.type === 'file') {
        unknownKeys(d, ['type', 'path'], dat);
        if (!ENV_ROOTED.test(d.path || '')) errors.push(`${dat}: path must start with a known %ENV% root (e.g. %ProgramFiles%\\...)`);
        if (/\.\./.test(d.path || '')) errors.push(`${dat}: path must not contain ..`);
      } else if (d.type === 'arp') {
        unknownKeys(d, ['type', 'displayName', 'publisher'], dat);
        checkRegex(d.displayName, `${dat}.displayName`);
        if (d.publisher !== undefined) checkRegex(d.publisher, `${dat}.publisher`);
      } else errors.push(`${dat}: type must be "file" or "arp"`);
    });
  }

  const u = a.uninstall || {};
  if (u.type === 'winget') {
    unknownKeys(u, ['type'], `${at} uninstall`);
    if (s.type !== 'winget') errors.push(`${at}: uninstall type "winget" needs a winget source`);
  } else if (u.type === 'exe') {
    unknownKeys(u, ['type', 'path', 'args', 'timeoutSec'], `${at} uninstall`);
    if (!ENV_ROOTED.test(u.path || '')) errors.push(`${at}: uninstall.path must start with a known %ENV% root`);
    checkArgs(u.args, `${at} uninstall.args`);
  } else errors.push(`${at}: uninstall.type must be "winget" or "exe"`);
}

const appIds = rawCatalog.apps || [];
if (new Set(appIds).size !== appIds.length) errors.push('catalog.json "apps" has duplicate ids');
for (const id of appIds) {
  const f = path.join(root, 'docs/apps', `${id}.json`);
  if (!existsSync(f)) { errors.push(`catalog app '${id}': missing docs/apps/${id}.json`); continue; }
  checkApp(id, JSON.parse(readFileSync(f, 'utf8')));
  if (rawCatalog.modules.some((m) => m.id === `app-${id}`)) errors.push(`app '${id}': module id 'app-${id}' is already used in catalog.json`);
}
const appDir = path.join(root, 'docs/apps');
if (existsSync(appDir)) {
  for (const f of readdirSync(appDir).filter((x) => x.endsWith('.json'))) {
    if (!appIds.includes(f.replace(/\.json$/, ''))) errors.push(`docs/apps/${f} is not listed in catalog.json "apps"`);
  }
}


const ids = new Set();
for (const m of catalog.modules) {
  if (ids.has(m.id)) errors.push(`duplicate module id '${m.id}'`);
  ids.add(m.id);
  // App modules (generated from docs/apps/<id>.json) share the fragment pair and Verify script of
  // the 'app' fragment; each app needs its own fixture.
  const frag = m.fragment || m.id;
  const wanted = [`docs/modules/${frag}/install.ps1`, `docs/modules/${frag}/uninstall.ps1`, `tests/modules/${frag}.Verify.ps1`];
  if (m.fragment) wanted.push(`tests/fixtures/${m.id}.json`);
  for (const f of wanted) {
    if (!existsSync(path.join(root, f))) errors.push(`module '${m.id}': missing ${f}`);
  }
  for (const r of m.requires || []) if (!catalog.modules.some((x) => x.id === r)) errors.push(`module '${m.id}' requires unknown '${r}'`);
  for (const k of ['label', 'description']) if (!m[k]) errors.push(`module '${m.id}': missing ${k}`);
  if (typeof m.order !== 'number') errors.push(`module '${m.id}': order must be a number`);
  checkSchema(m);
}
for (const m of catalog.modules) {
  // Ordering rule of the two-phase core: user-scope modules run first, so they cannot depend on a
  // machine-scope module.
  if (m.scope === 'user') {
    for (const r of m.requires || []) {
      const dep = catalog.modules.find((x) => x.id === r);
      if (dep && dep.scope === 'machine') errors.push(`module '${m.id}' (user scope) requires machine-scope '${r}'`);
    }
  }
}

for (const core of ['installer-core.ps1', 'uninstall-core.ps1']) {
  const text = readFileSync(path.join(root, 'docs/core', core), 'utf8');
  for (const tok of ['__COMMON__', '__CONFIG_B64__', '__MODULES__']) {
    const n = text.split(tok).length - 1;
    if (n !== 1) errors.push(`docs/core/${core}: '${tok}' appears ${n} times, expected exactly 1`);
  }
}

const sha256 = (t) => createHash('sha256').update(t, 'utf8').digest('hex');
const goldenPath = path.join(root, 'tests/golden.json');
const updateGoldens = process.argv.includes('--update-goldens');
const golden = existsSync(goldenPath) ? JSON.parse(readFileSync(goldenPath, 'utf8')) : {};
const newGolden = {};

const commonText = readFileSync(path.join(root, 'docs/core/common.ps1'), 'utf8');
for (const tok of ['__COMMON__', '__CONFIG_B64__', '__MODULES__']) {
  if (commonText.includes(tok)) errors.push(`docs/core/common.ps1 must not contain the placeholder '${tok}'`);
}

const fixtureDir = path.join(root, 'tests/fixtures');
const fixtures = readdirSync(fixtureDir).filter((f) => f.endsWith('.json'));
const workflow = readFileSync(path.join(root, '.github/workflows/validate.yml'), 'utf8');
for (const f of fixtures) {
  const name = f.replace(/\.json$/, '');
  if (!new RegExp(`^\\s*-\\s*${name}\\s*$`, 'm').test(workflow)) errors.push(`fixture ${f} is not in validate.yml's scenario matrix`);
  try {
    const { install, uninstall } = renderAll(JSON.parse(readFileSync(path.join(fixtureDir, f), 'utf8')));
    newGolden[name] = { install: sha256(install), uninstall: uninstall ? sha256(uninstall) : null };
    for (const [kind, text] of [['install', install], ['uninstall', uninstall]]) {
      if (text && !/^@set "APPI_ARGS=%\*" & @set "SELF=%~f0" & .*& @if errorlevel 1 \(exit \/b 1\) else \(exit \/b 0\)\r?\n<#PSBEGIN#>\r?\n/.test(text)) {
        errors.push(`${f}: ${kind} polyglot header must be one line ending in the errorlevel passthrough`);
      }
      const left = text && text.match(/__[A-Z0-9_]+__/g);
      if (left) errors.push(`${f}: ${kind} output still contains ${[...new Set(left)].join(', ')}`);
    }
  } catch (e) {
    errors.push(`${f}: render failed: ${e.message}`);
  }
}

// Golden hashes: the rendered .cmd bytes per fixture. Any change to a core, fragment, header or
// the renderer shows up here; update deliberately with --update-goldens and review the diff.
if (updateGoldens) {
  writeFileSync(goldenPath, JSON.stringify(newGolden, null, 2) + '\n');
  console.log('Updated tests/golden.json');
} else {
  for (const [name, h] of Object.entries(newGolden)) {
    const g = golden[name];
    if (!g) errors.push(`no golden hash for fixture '${name}' (run with --update-goldens)`);
    else for (const k of ['install', 'uninstall']) {
      if (g[k] !== h[k]) errors.push(`golden mismatch for ${name} ${k}: rendered output changed (expected ${g[k]}, got ${h[k]}); if intended, run node tests/check-catalog.mjs --update-goldens`);
    }
  }
  for (const name of Object.keys(golden)) if (!newGolden[name]) errors.push(`golden.json has stale entry '${name}'`);
}

if (errors.length) {
  console.error('Catalog check FAILED:\n' + errors.map((e) => ' - ' + e).join('\n'));
  process.exit(1);
}
console.log(`Catalog check passed: ${catalog.modules.length} modules, ${fixtures.length} fixtures.`);
