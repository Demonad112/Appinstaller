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
import { renderAll, loadCatalog } from '../tools/render.mjs';

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const errors = [];
const catalog = loadCatalog();

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

const ids = new Set();
for (const m of catalog.modules) {
  if (ids.has(m.id)) errors.push(`duplicate module id '${m.id}'`);
  ids.add(m.id);
  for (const f of [`docs/modules/${m.id}/install.ps1`, `docs/modules/${m.id}/uninstall.ps1`, `tests/modules/${m.id}.Verify.ps1`]) {
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
  for (const tok of ['__CONFIG_B64__', '__MODULES__']) {
    const n = text.split(tok).length - 1;
    if (n !== 1) errors.push(`docs/core/${core}: '${tok}' appears ${n} times, expected exactly 1`);
  }
}

const sha256 = (t) => createHash('sha256').update(t, 'utf8').digest('hex');
const goldenPath = path.join(root, 'tests/golden.json');
const updateGoldens = process.argv.includes('--update-goldens');
const golden = existsSync(goldenPath) ? JSON.parse(readFileSync(goldenPath, 'utf8')) : {};
const newGolden = {};

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
      if (text && !/^@set "SELF=%~f0" & .*& @if errorlevel 1 \(exit \/b 1\) else \(exit \/b 0\)\r?\n<#PSBEGIN#>\r?\n/.test(text)) {
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
