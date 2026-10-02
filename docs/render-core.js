// Shared renderer: the ONE implementation of "config -> .cmd bytes". Imported by docs/app.js
// (browser, GitHub Pages) and tools/render.mjs (Node, CI), so the file CI validates is
// byte-for-byte what the website hands out by construction, not by keeping two copies in sync.
//
// Pure functions only: callers load the text files (fetch() in the browser, readFileSync in
// Node) and pass them in. Uses only TextEncoder/btoa, which exist in browsers and Node 16+.
//
// Config shape (see tests/fixtures/*.json):
//   {
//     "modules": {                       // key present = module selected
//       "<module-id>": { ...module options... }
//     },
//     "generateUninstall": true
//   }

export const MARKER = '<' + '#PSBEGIN#' + '>';

function uint8ToBase64(bytes) {
  let binary = '';
  const chunkSize = 0x8000;
  for (let i = 0; i < bytes.length; i += chunkSize) {
    binary += String.fromCharCode.apply(null, bytes.subarray(i, i + chunkSize));
  }
  return btoa(binary);
}

export function utf8ToBase64(str) {
  return uint8ToBase64(new TextEncoder().encode(str));
}

export function bytesToBase64(bytes) {
  return uint8ToBase64(bytes);
}

export function sanitizeFilename(name) {
  return String(name || '').replace(/[\\/:*?"<>|]/g, '_').trim();
}

// Download/file base name: the first selected module (catalog order) that declares
// "fileNameFrom": "<optionKey>" supplies it; otherwise a generic one.
export function outputBaseName(catalog, config) {
  for (const id of selectedModules(catalog, config)) {
    const m = catalog.modules.find((x) => x.id === id);
    const v = m.fileNameFrom && config.modules[id] && config.modules[id][m.fileNameFrom];
    const name = v && sanitizeFilename(v);
    if (name) return name;
  }
  return 'Setup';
}

// Option keys of type "icon" for a module (their payload is install-only and is stripped from
// the uninstaller's config).
export function iconKeys(catalog, id) {
  const m = catalog.modules.find((x) => x.id === id);
  return ((m && m.options) || []).filter((o) => o.type === 'icon').map((o) => o.key);
}

// Selected module ids, in catalog order (which is also execution order on the target).
export function selectedModules(catalog, config) {
  const chosen = config.modules || {};
  return catalog.modules
    .filter((m) => Object.prototype.hasOwnProperty.call(chosen, m.id))
    .sort((a, b) => a.order - b.order)
    .map((m) => m.id);
}

export function buildPolyglot(psPayload) {
  const header =
    '@set "APPI_ARGS=%*" & @set "SELF=%~f0" & @powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass ' +
    '-Command "$c=[IO.File]::ReadAllText($env:SELF);iex $c.Substring(' +
    "$c.IndexOf('<'+'#PSBEGIN#'+'>')+11)\" & @if errorlevel 1 (exit /b 1) else (exit /b 0)";
  const normalized = psPayload.replace(/\r\n/g, '\n').replace(/\n/g, '\r\n');
  return [header, MARKER, normalized].join('\r\n');
}

function assemble(coreText, commonText, ids, fragments, runtimeConfig) {
  const body = ids
    .map((id) => {
      const text = fragments[id];
      if (typeof text !== 'string') throw new Error(`Missing script fragment for module '${id}'`);
      return `# ==== module: ${id} ====\n${text.replace(/\s+$/, '')}\n`;
    })
    .join('\n');
  const configB64 = utf8ToBase64(JSON.stringify(runtimeConfig));
  // split/join rather than String.replace: no `$&`-style special patterns in the inserted text.
  return coreText
    .split('__COMMON__').join(commonText.replace(/\s+$/, ''))
    .split('__CONFIG_B64__').join(configB64)
    .split('__MODULES__').join(body);
}

// The runtime config the core decodes: per-module options plus each module's scope (the catalog
// is the single source of truth for scope; the core uses it to pick the user or machine phase).
function runtimeConfig(catalog, ids, modules) {
  const scopes = {};
  for (const id of ids) scopes[id] = catalog.modules.find((m) => m.id === id).scope;
  return { modules, scopes };
}

// fragments: { [moduleId]: install.ps1 text } for (at least) every selected module.
// common: docs/core/common.ps1 text.
export function renderInstall({ core, common, catalog, fragments, config }) {
  const ids = selectedModules(catalog, config);
  const modules = {};
  for (const id of ids) modules[id] = config.modules[id];
  return buildPolyglot(assemble(core, common, ids, fragments, runtimeConfig(catalog, ids, modules)));
}

// Same as renderInstall, minus the icon payloads the uninstaller never needs.
export function renderUninstall({ core, common, catalog, fragments, config }) {
  const ids = selectedModules(catalog, config);
  const modules = {};
  for (const id of ids) {
    const rest = { ...(config.modules[id] || {}) };
    for (const k of iconKeys(catalog, id)) delete rest[k];
    modules[id] = rest;
  }
  return buildPolyglot(assemble(core, common, ids, fragments, runtimeConfig(catalog, ids, modules)));
}
