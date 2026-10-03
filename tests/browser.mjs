#!/usr/bin/env node
// Browser-equivalence test. For every fixture, drives the real configurator page in headless
// Chromium (fills the form from the fixture, clicks Generate, captures the downloads) and asserts
//   sha256(browser download) == sha256(Node render) == tests/golden.json
// so what the website hands out is provably what CI validates.
//
// Usage: node tests/browser.mjs      (from anywhere; needs `npm ci` and a Chromium)
// Chromium: Playwright's own, or $CHROMIUM_PATH, or /opt/pw-browsers/chromium (cloud sandbox).

import { createServer } from 'node:http';
import { readFileSync, readdirSync, existsSync, statSync } from 'node:fs';
import { createHash } from 'node:crypto';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';
import { renderAll, loadCatalog } from '../tools/render.mjs';

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
process.chdir(root); // fixtures reference assets relative to the repo root
const docs = path.join(root, 'docs');
const sha256 = (buf) => createHash('sha256').update(buf).digest('hex');
const golden = JSON.parse(readFileSync(path.join(root, 'tests/golden.json'), 'utf8'));
const catalog = loadCatalog(); // expanded: includes the generated app-<id> modules

const MIME = { '.html': 'text/html', '.js': 'text/javascript', '.json': 'application/json', '.css': 'text/css', '.ps1': 'text/plain' };
const server = createServer((req, res) => {
  const rel = decodeURIComponent(new URL(req.url, 'http://x').pathname).replace(/^\/+/, '') || 'index.html';
  const file = path.join(docs, rel);
  if (!file.startsWith(docs) || !existsSync(file) || !statSync(file).isFile()) { res.writeHead(404).end(); return; }
  res.writeHead(200, { 'content-type': MIME[path.extname(file)] || 'application/octet-stream' }).end(readFileSync(file));
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const base = `http://127.0.0.1:${server.address().port}/`;

const exe = process.env.CHROMIUM_PATH || (existsSync('/opt/pw-browsers/chromium') && !process.env.CI ? '/opt/pw-browsers/chromium' : undefined);
let browser;
try {
  browser = await chromium.launch(exe ? { executablePath: exe } : {});
} catch (e) {
  if (exe) browser = await chromium.launch(); else throw e;
}

// ---- Fill the generated form from a fixture's module options -------------------------------
async function fillModule(page, id, opts) {
  const card = page.locator(`.module[data-module="${id}"]`);
  for (const [key, value] of Object.entries(opts)) {
    const opt = (catalog.modules.find((m) => m.id === id).options || []).find((o) => o.key === key || (o.type === 'icon' && key === o.key.replace(/B64$/, '') + 'Path'));
    if (!opt) throw new Error(`fixture option '${id}.${key}' has no catalog option`);
    const field = card.locator(`[data-key="${opt.key}"]`);
    if (opt.type === 'icon' || opt.type === 'file') await field.locator('input[type=file]').setInputFiles(value);
    else if (opt.type === 'checkbox') await field.locator('input').setChecked(!!value);
    else if (opt.type === 'radio') await field.locator(`input[value="${value}"]`).check();
    else if (opt.type === 'select') await field.locator('select').selectOption(String(value));
    else if (opt.type === 'multiselect') {
      for (const v of opt.values) await field.locator(`input[value="${v.value}"]`).setChecked(value.includes(v.value));
    } else await field.locator('input').fill(String(value));
  }
}

const fixtures = readdirSync(path.join(root, 'tests/fixtures')).filter((f) => f.endsWith('.json')).sort();
const failures = [];
for (const f of fixtures) {
  const name = f.replace(/\.json$/, '');
  const fixture = JSON.parse(readFileSync(path.join(root, 'tests/fixtures', f), 'utf8'));
  const expected = await renderAll(fixture);
  const page = await browser.newPage();
  const downloads = [];
  page.on('download', (d) => downloads.push(d));
  page.on('pageerror', (e) => failures.push(`${name}: page error ${e.message}`));
  await page.goto(base + '?test=1'); // shows the hidden "test": true catalog items
  await page.waitForSelector('.module');
  for (const m of catalog.modules) {
    const on = Object.prototype.hasOwnProperty.call(fixture.modules, m.id);
    await page.locator(`.module-toggle[value="${m.id}"]`).setChecked(on);
    if (on) await fillModule(page, m.id, fixture.modules[m.id]);
  }
  await page.locator('#gen-uninstall').setChecked(fixture.generateUninstall !== false);
  await page.click('#generate-btn');
  await page.waitForSelector('#results:not([hidden])', { timeout: 15000 });
  // A bundle build downloads one zip (which holds the .cmd files); otherwise the .cmd files.
  const want = expected.zip ? 1 : expected.uninstall ? 2 : 1;
  for (let i = 0; i < 50 && downloads.length < want; i++) await page.waitForTimeout(100);
  const got = {};
  for (const d of downloads) {
    const buf = readFileSync(await d.path());
    const fn = d.suggestedFilename();
    got[fn.endsWith('.zip') ? 'zip' : fn.startsWith('Uninstall-') ? 'uninstall' : 'install'] = sha256(buf);
  }
  if (downloads.length !== want) failures.push(`${name}: expected ${want} download(s), got ${downloads.length}`);
  const hashText = await page.textContent('#hash');
  for (const kind of ['install', 'uninstall', 'zip']) {
    const exp = expected[kind] ? sha256(expected[kind]) : null;
    const downloaded = expected.zip ? kind === 'zip' : kind !== 'zip';
    if (downloaded && (got[kind] || null) !== exp) failures.push(`${name} ${kind}: browser ${got[kind]} != node ${exp}`);
    if (exp !== golden[name][kind]) failures.push(`${name} ${kind}: node ${exp} != golden ${golden[name][kind]}`);
    if (exp && !hashText.includes(exp)) failures.push(`${name} ${kind}: hash shown on the page does not match`);
  }
  console.log(`${failures.length ? 'check' : 'ok   '} ${name}`);
  await page.close();
}
await browser.close();
server.close();
if (failures.length) {
  console.error('Browser test FAILED:\n' + failures.map((x) => ' - ' + x).join('\n'));
  process.exit(1);
}
console.log(`Browser test passed: ${fixtures.length} fixtures, browser == node == golden.`);
