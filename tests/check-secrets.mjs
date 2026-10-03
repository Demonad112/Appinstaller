#!/usr/bin/env node
// Key-pattern guard (Linux CI, catalog job). Fails if anything that looks like a real key,
// password or token appears in:
//   - every tracked text file (git ls-files; binaries, i.e. files containing NUL, are skipped)
//   - every fixture's rendered output: the .cmd texts, the DECODED $ConfigB64 JSON inside them
//     (base64 would hide a secret from a plain grep) and the text entries of a bundle zip
// {{PLACEHOLDER}} values are allowed: fixtures and docs use them instead of real secrets.
//
// Usage: node tests/check-secrets.mjs [--self-test]
//   --self-test  plants fake matches (built at runtime, so this file itself stays clean) and
//                asserts every pattern catches its sample and placeholders are not flagged.

import { execFileSync } from 'node:child_process';
import { readFileSync, readdirSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { renderAll } from '../tools/render.mjs';

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');

// [name, regex]. Literal value after a key word must not be a {{PLACEHOLDER}} or a variable.
const PATTERNS = [
  ['private key block', /-----BEGIN (?:RSA |EC |DSA |OPENSSH |PGP )?PRIVATE KEY( BLOCK)?-----/],
  ['AWS access key', /\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/],
  ['GitHub token', /\b(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{50,})\b/],
  ['Slack token', /\bxox[abposr]-[A-Za-z0-9-]{10,}/],
  ['Google API key', /\bAIza[0-9A-Za-z_-]{35}\b/],
  ['OpenAI/Anthropic-style key', /\bsk-(?:ant-|proj-)?[A-Za-z0-9_-]{20,}/],
  ['Stripe live key', /\b[rs]k_live_[0-9A-Za-z]{16,}/],
  ['JSON Web Token', /\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/],
  ['Windows/Office product key', /\b[A-HJ-NP-Z0-9]{5}(?:-[A-HJ-NP-Z0-9]{5}){4}\b/],
  ['password/token assignment',
    /\b(?:password|passwd|pwd|secret|token|api[_-]?key|client[_-]?secret)\b["']?\s*[:=]\s*["'](?!\{\{[A-Z0-9_]+\}\})(?![$%{(])[^"'\s]{6,}["']/i],
];

function scanText(label, text, hits) {
  for (const [name, re] of PATTERNS) {
    const m = text.match(re);
    if (m) hits.push(`${label}: ${name} (${m[0].slice(0, 6)}…)`);
  }
}

// The .cmd text plus its decoded embedded config.
function scanCmd(label, text, hits) {
  scanText(label, text, hits);
  const m = text.match(/\$ConfigB64 = '([A-Za-z0-9+/=]+)'/);
  if (m) scanText(`${label} (decoded config)`, Buffer.from(m[1], 'base64').toString('utf8'), hits);
}

// Text entries of a STORE-only zip from docs/render-core.js zipStore().
function scanZip(label, zip, hits) {
  const buf = Buffer.from(zip);
  let at = 0;
  while (buf.readUInt32LE(at) === 0x04034b50) {
    const size = buf.readUInt32LE(at + 18);
    const nameLen = buf.readUInt16LE(at + 26);
    const name = buf.toString('utf8', at + 30, at + 30 + nameLen);
    const data = buf.subarray(at + 30 + nameLen, at + 30 + nameLen + size);
    if (!data.includes(0)) {
      const text = data.toString('utf8');
      if (name.endsWith('.cmd')) scanCmd(`${label}:${name}`, text, hits); else scanText(`${label}:${name}`, text, hits);
    }
    at += 30 + nameLen + size;
  }
}

function selfTest() {
  const j = (...p) => p.join('');
  const samples = {
    'private key block': j('-----BEGIN ', 'PRIVATE KEY-----'),
    'AWS access key': j('AKIA', 'Z7QX3MPL4K2NVB8W'),
    'GitHub token': j('ghp_', 'a1B2c3D4e5F6g7H8i9J0k1L2m3N4o5P6q7R8'),
    'Slack token': j('xoxb-', '1234567890-abcdefghij'),
    'Google API key': j('AIza', 'Sy0123456789abcdefghijklmnopqrstuvw'),
    'OpenAI/Anthropic-style key': j('sk-', 'ant-', 'abcdefghijklmnopqrstuvwx'),
    'Stripe live key': j('sk_', 'live_', 'abcdefghijklmnop1234'),
    'JSON Web Token': j('eyJ', 'hbGciOiJIUzI1', '.eyJ', 'zdWIiOiIxMjM0', '.', 'SflKxwRJSMeKKF2QT4'),
    'Windows/Office product key': j('ABCDE', '-FGHJK', '-MNPQR', '-STVWX', '-23456'),
    'password/token assignment': j('"pass', 'word": "', 'Hunter2Hunter2', '"'),
  };
  const fails = [];
  for (const [name] of PATTERNS) {
    const hits = [];
    scanText('sample', samples[name], hits);
    if (!hits.some((h) => h.includes(name))) fails.push(`pattern '${name}' missed its planted sample`);
  }
  // A planted key inside a rendered .cmd's base64 config must be found too.
  const b64 = Buffer.from(JSON.stringify({ modules: { x: { k: samples['AWS access key'] } } })).toString('base64');
  const hits = [];
  scanCmd('sample.cmd', `$ConfigB64 = '${b64}'`, hits);
  if (!hits.some((h) => h.includes('decoded config'))) fails.push('a key inside the base64 config was not found');
  for (const ok of ['"password": "{{WIFI_PASSWORD}}"', '"value": "{{CI_CANARY_SECRET}}"', 'password = $Cfg.value', '{"type":"secret","key":"value"}']) {
    const h = [];
    scanText('placeholder', ok, h);
    if (h.length) fails.push(`false positive on '${ok}': ${h.join('; ')}`);
  }
  if (fails.length) { console.error('Key-pattern self-test FAILED:\n' + fails.map((x) => ' - ' + x).join('\n')); process.exit(1); }
  console.log(`Key-pattern self-test passed: ${PATTERNS.length} patterns caught their samples, placeholders allowed.`);
}

if (process.argv.includes('--self-test')) {
  selfTest();
} else {
  const hits = [];
  const tracked = execFileSync('git', ['ls-files', '-z'], { cwd: root }).toString('utf8').split('\0').filter(Boolean);
  for (const f of tracked) {
    let buf;
    try { buf = readFileSync(path.join(root, f)); } catch { continue; }
    if (buf.includes(0)) continue;
    scanText(f, buf.toString('utf8'), hits);
  }
  process.chdir(root); // fixtures reference assets relative to the repo root
  const fixtureDir = path.join(root, 'tests/fixtures');
  const fixtures = readdirSync(fixtureDir).filter((f) => f.endsWith('.json'));
  for (const f of fixtures) {
    const { install, uninstall, zip } = await renderAll(JSON.parse(readFileSync(path.join(fixtureDir, f), 'utf8')));
    scanCmd(`render:${f}:install`, install, hits);
    if (uninstall) scanCmd(`render:${f}:uninstall`, uninstall, hits);
    if (zip) scanZip(`render:${f}:zip`, zip, hits);
  }
  if (hits.length) {
    console.error('Key-pattern guard FAILED (use {{PLACEHOLDER}} values instead):\n' + hits.map((x) => ' - ' + x).join('\n'));
    process.exit(1);
  }
  console.log(`Key-pattern guard passed: ${tracked.length} tracked files, ${fixtures.length} fixtures' rendered output.`);
}
