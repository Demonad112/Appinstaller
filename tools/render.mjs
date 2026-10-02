#!/usr/bin/env node
// Renders the selected modules into the self-contained polyglot Install/Uninstall .cmd files,
// given a JSON config. All assembly logic lives in docs/render-core.js, which docs/app.js also
// imports in the browser -- this file only does the Node-side file I/O around it.
//
// Usage:
//   node tools/render.mjs <config.json> [outDir]
//
// Config shape (see tests/fixtures/*.json):
//   {
//     "modules": {
//       "desktop-shortcut": { "destUrl": "...", "name": "...", "style": "App" | "Url",
//                             "iconPath": "path/to/icon.ico" },   // Node-only sugar: for an "icon"
//                                                                 // option "fooB64", "fooPath" is read
//                                                                 // into fooB64
//       "ublock-lite":      { "pinToolbar": true, "autoRestartChrome": false },
//       "app-7zip":         {}      // curated apps (docs/apps/<id>.json) are modules named app-<id>
//     },
//     "generateUninstall": true
//   }
// Keys starting with "_" (e.g. "_ci") are test-harness settings and are ignored here.

import { readFileSync, writeFileSync, mkdirSync, appendFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import {
  expandCatalog,
  fragmentIds,
  renderInstall,
  renderUninstall,
  selectedModules,
  outputBaseName,
  iconKeys,
  bytesToBase64,
} from '../docs/render-core.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const DOCS_DIR = path.join(__dirname, '..', 'docs');

const read = (...p) => readFileSync(path.join(DOCS_DIR, ...p), 'utf8');

// The raw docs/catalog.json (modules + the "apps" id list), without the generated app modules.
export function loadRawCatalog() {
  return JSON.parse(read('catalog.json'));
}

export function loadAppDefs(raw = loadRawCatalog()) {
  const defs = {};
  for (const id of raw.apps || []) defs[id] = JSON.parse(read('apps', `${id}.json`));
  return defs;
}

// The catalog every consumer works with: hand-written modules plus one `app-<id>` module per app.
export function loadCatalog() {
  const raw = loadRawCatalog();
  return expandCatalog(raw, loadAppDefs(raw));
}

function loadFragments(catalog, ids, kind) {
  const out = {};
  for (const f of fragmentIds(catalog, ids)) out[f] = read('modules', f, `${kind}.ps1`);
  return out;
}

// Resolves Node-only conveniences (<icon option key minus B64>Path -> <key> as base64) and
// validates module ids.
export function normalizeConfig(raw, catalog) {
  const known = new Set(catalog.modules.map((m) => m.id));
  const modules = {};
  for (const [id, opts] of Object.entries(raw.modules || {})) {
    if (!known.has(id)) throw new Error(`Unknown module '${id}' (not in docs/catalog.json)`);
    const rest = { ...(opts || {}) };
    for (const key of iconKeys(catalog, id)) {
      const pathKey = key.replace(/B64$/, '') + 'Path';
      if (rest[pathKey]) rest[key] = bytesToBase64(readFileSync(rest[pathKey]));
      delete rest[pathKey];
    }
    modules[id] = rest;
  }
  return { modules, generateUninstall: raw.generateUninstall !== false };
}

export function renderAll(rawConfig) {
  const catalog = loadCatalog();
  const config = normalizeConfig(rawConfig, catalog);
  const ids = selectedModules(catalog, config);
  if (ids.length === 0) throw new Error('Config selects no modules');
  return {
    baseName: outputBaseName(catalog, config),
    install: renderInstall({ core: read('core', 'installer-core.ps1'), common: read('core', 'common.ps1'), catalog, fragments: loadFragments(catalog, ids, 'install'), config }),
    uninstall: config.generateUninstall
      ? renderUninstall({ core: read('core', 'uninstall-core.ps1'), common: read('core', 'common.ps1'), catalog, fragments: loadFragments(catalog, ids, 'uninstall'), config })
      : null,
  };
}

function main() {
  const [, , configPath, outDirArg] = process.argv;
  if (!configPath || !existsSync(configPath)) {
    console.error('Usage: node tools/render.mjs <config.json> [outDir]');
    process.exit(1);
  }
  const { baseName, install, uninstall } = renderAll(JSON.parse(readFileSync(configPath, 'utf8')));
  const outDir = outDirArg || path.join(process.cwd(), 'out');
  mkdirSync(outDir, { recursive: true });

  const installOut = path.join(outDir, `Install-${baseName}.cmd`);
  writeFileSync(installOut, install, { encoding: 'utf8' });
  console.log(`Wrote ${installOut}`);
  const envLines = [`INSTALL_CMD_PATH=${installOut}`];

  if (uninstall) {
    const uninstallOut = path.join(outDir, `Uninstall-${baseName}.cmd`);
    writeFileSync(uninstallOut, uninstall, { encoding: 'utf8' });
    console.log(`Wrote ${uninstallOut}`);
    envLines.push(`UNINSTALL_CMD_PATH=${uninstallOut}`);
  }

  // Exposes the actual rendered paths to later CI steps via $GITHUB_ENV rather than making
  // callers reconstruct sanitizeFilename()'s output themselves -- names can contain characters
  // (apostrophes, spaces) that are unsafe to splice into a shell command as literal text via
  // GitHub Actions' ${{ }} interpolation, but are perfectly safe carried through as env var data.
  if (process.env.GITHUB_ENV) {
    appendFileSync(process.env.GITHUB_ENV, envLines.join('\n') + '\n');
  }
}

// A naive `file://${process.argv[1]}` comparison never matches on Windows: process.argv[1]
// is a backslash path (D:\a\...\render.mjs) while import.meta.url is a proper file:// URL
// (file:///D:/a/.../render.mjs), so main() would silently never run. Normalize both through
// fileURLToPath/path.resolve instead, which handles the separator and drive-letter differences.
if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  main();
}
