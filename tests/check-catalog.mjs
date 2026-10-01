#!/usr/bin/env node
// Fast, platform-independent catalog checks (runs on Linux CI before the Windows matrix):
//  - every catalog module has install.ps1, uninstall.ps1 and tests/modules/<id>.Verify.ps1
//  - every Windows CI scenario has a fixture, and every fixture is in the matrix
//  - each core template contains each placeholder exactly once (a second copy, e.g. in a
//    comment, would get substituted too)
//  - every fixture renders, and no placeholder survives into the output

import { readFileSync, readdirSync, existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { renderAll, loadCatalog } from '../tools/render.mjs';

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const errors = [];
const catalog = loadCatalog();

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
}

for (const core of ['installer-core.ps1', 'uninstall-core.ps1']) {
  const text = readFileSync(path.join(root, 'docs/core', core), 'utf8');
  for (const tok of ['__CONFIG_B64__', '__MODULES__']) {
    const n = text.split(tok).length - 1;
    if (n !== 1) errors.push(`docs/core/${core}: '${tok}' appears ${n} times, expected exactly 1`);
  }
}

const fixtureDir = path.join(root, 'tests/fixtures');
const fixtures = readdirSync(fixtureDir).filter((f) => f.endsWith('.json'));
const workflow = readFileSync(path.join(root, '.github/workflows/validate.yml'), 'utf8');
for (const f of fixtures) {
  const name = f.replace(/\.json$/, '');
  if (!new RegExp(`^\\s*-\\s*${name}\\s*$`, 'm').test(workflow)) errors.push(`fixture ${f} is not in validate.yml's scenario matrix`);
  try {
    const { install, uninstall } = renderAll(JSON.parse(readFileSync(path.join(fixtureDir, f), 'utf8')));
    for (const [kind, text] of [['install', install], ['uninstall', uninstall]]) {
      const left = text && text.match(/__[A-Z0-9_]+__/g);
      if (left) errors.push(`${f}: ${kind} output still contains ${[...new Set(left)].join(', ')}`);
    }
  } catch (e) {
    errors.push(`${f}: render failed: ${e.message}`);
  }
}

if (errors.length) {
  console.error('Catalog check FAILED:\n' + errors.map((e) => ' - ' + e).join('\n'));
  process.exit(1);
}
console.log(`Catalog check passed: ${catalog.modules.length} modules, ${fixtures.length} fixtures.`);
