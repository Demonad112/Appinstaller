#!/usr/bin/env node
// Renders docs/installer-template.ps1 / docs/uninstall-template.ps1 into the self-contained
// polyglot .cmd files, given a JSON config. This performs the *identical* substitution that
// docs/app.js performs in the browser, so CI (tests/) exercises the exact bytes the GitHub
// Pages generator hands out -- there is exactly one script body, never two copies to drift.
//
// Usage:
//   node tools/render.mjs <config.json> [outDir]
//
// Config shape (see tests/fixtures/config.json):
//   {
//     "destUrl": "https://example.com",
//     "shortcutName": "Example",
//     "iconPath": "path/to/icon.ico",       // optional, pre-built .ico
//     "shortcutStyle": "App" | "Url",       // default "App"
//     "pinToolbar": true,                    // default true
//     "autoRestartChrome": false             // default false
//   }

import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const DOCS_DIR = path.join(__dirname, '..', 'docs');

const MARKER = '<' + '#PSBEGIN#' + '>';

function b64(str) {
  return Buffer.from(str, 'utf8').toString('base64');
}

function toPsBool(v) {
  return v ? '$true' : '$false';
}

function sanitizeFilename(name) {
  return name.replace(/[\\/:*?"<>|]/g, '_').trim() || 'Website';
}

function buildPolyglot(psPayload) {
  const header =
    '@set "SELF=%~f0" & @powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass ' +
    '-Command "$c=[IO.File]::ReadAllText($env:SELF);iex $c.Substring(' +
    "$c.IndexOf('<'+'#PSBEGIN#'+'>')+11)\" & @exit /b";
  const normalized = psPayload.replace(/\r\n/g, '\n').replace(/\n/g, '\r\n');
  return [header, MARKER, normalized].join('\r\n');
}

export function renderInstallCmd(config) {
  const template = readFileSync(path.join(DOCS_DIR, 'installer-template.ps1'), 'utf8');
  const iconB64 = config.iconPath ? readFileSync(config.iconPath).toString('base64') : '';

  const payload = template
    .replaceAll('__DEST_URL_B64__', b64(config.destUrl))
    .replaceAll('__SHORTCUT_NAME_B64__', b64(config.shortcutName))
    .replaceAll('__ICON_B64__', iconB64)
    .replaceAll('__SHORTCUT_STYLE__', config.shortcutStyle || 'App')
    .replaceAll('__PIN_TOOLBAR__', toPsBool(config.pinToolbar !== false))
    .replaceAll('__AUTO_RESTART_CHROME__', toPsBool(!!config.autoRestartChrome));

  return buildPolyglot(payload);
}

export function renderUninstallCmd(config) {
  const template = readFileSync(path.join(DOCS_DIR, 'uninstall-template.ps1'), 'utf8');
  const payload = template.replaceAll('__SHORTCUT_NAME_B64__', b64(config.shortcutName));
  return buildPolyglot(payload);
}

function main() {
  const [, , configPath, outDirArg] = process.argv;
  if (!configPath) {
    console.error('Usage: node tools/render.mjs <config.json> [outDir]');
    process.exit(1);
  }
  const config = JSON.parse(readFileSync(configPath, 'utf8'));
  const outDir = outDirArg || path.join(process.cwd(), 'out');
  mkdirSync(outDir, { recursive: true });

  const safeName = sanitizeFilename(config.shortcutName);
  const installOut = path.join(outDir, `Install-${safeName}.cmd`);
  const uninstallOut = path.join(outDir, `Uninstall-${safeName}.cmd`);

  writeFileSync(installOut, renderInstallCmd(config), { encoding: 'ascii' });
  console.log(`Wrote ${installOut}`);

  if (config.generateUninstall !== false) {
    writeFileSync(uninstallOut, renderUninstallCmd(config), { encoding: 'ascii' });
    console.log(`Wrote ${uninstallOut}`);
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main();
}
