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

// Option keys of a given type for a module. "icon" payloads are install-only (stripped from the
// uninstaller's config); "file" bytes and "secret" values never enter any config: they go into
// the bundle's files/ folder (see renderOutputs).
export function optionKeys(catalog, id, type) {
  const m = catalog.modules.find((x) => x.id === id);
  return ((m && m.options) || []).filter((o) => o.type === type).map((o) => o.key);
}
export const iconKeys = (catalog, id) => optionKeys(catalog, id, 'icon');

// Curated apps are data: catalog.json lists app ids and docs/apps/<id>.json defines each one.
// expandCatalog() turns them into ordinary catalog modules `app-<id>` that share ONE fragment
// pair (docs/modules/app/{install,uninstall}.ps1); the app definition itself is embedded in the
// runtime config (modules['app-<id>'].app) so the generic fragment stays data-driven.
// appDefs: { [appId]: parsed docs/apps/<appId>.json }. Pure; browser and Node both call it.
export function expandCatalog(catalog, appDefs) {
  const modules = [...catalog.modules];
  for (const id of catalog.apps || []) {
    const a = appDefs && appDefs[id];
    if (!a) throw new Error(`Missing app definition '${id}' (docs/apps/${id}.json)`);
    // A bundled app's installer is picked when the bundle is generated and shipped in files/.
    const options = a.source && a.source.type === 'bundled'
      ? [{ key: 'installer', type: 'file', label: `Installer file (${a.source.file})`, required: true, fileName: a.source.file,
          hint: 'Checked against the pinned fingerprint before it goes into the download.' }]
      : [];
    modules.push({
      id: `app-${id}`,
      label: a.label,
      description: a.description,
      order: a.order,
      scope: a.scope,
      requires: a.requires || [],
      default: false,
      options,
      fragment: 'app',
      app: a,
      ...(a.test ? { test: true } : {}),
    });
  }
  return { ...catalog, modules };
}

// The files to load per fragment, as { [fragmentId]: [paths under docs/] }: a plain module's own
// modules/<id>/<kind>.ps1; a shared fragment's modules/<f>/common.ps1 (helpers both kinds use)
// followed by modules/<f>/<kind>.ps1. Callers load and join them with joinFragment().
export function fragmentFiles(catalog, ids, kind) {
  const out = {};
  for (const id of ids) {
    const m = catalog.modules.find((x) => x.id === id);
    const f = (m && m.fragment) || id;
    if (!out[f]) out[f] = m && m.fragment ? [`modules/${f}/common.ps1`, `modules/${f}/${kind}.ps1`] : [`modules/${f}/${kind}.ps1`];
  }
  return out;
}
export const joinFragment = (texts) => texts.map((t) => t.replace(/\s+$/, '')).join('\n\n');

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

// A module with a "fragment" shares that fragment's text with its siblings: the text is emitted
// once (at first use) and each module is registered by `$Modules += New-<Fragment>Module -Id '<id>'`
// (e.g. New-AppModule). Plain modules emit their own fragment unchanged.
function assemble(coreText, commonText, catalog, ids, fragments, runtimeConfig) {
  const shared = new Set();
  const body = ids
    .map((id) => {
      const m = catalog.modules.find((x) => x.id === id);
      const key = (m && m.fragment) || id;
      const text = fragments[key];
      if (typeof text !== 'string') throw new Error(`Missing script fragment for module '${id}'`);
      if (!m.fragment) return `# ==== module: ${id} ====\n${text.replace(/\s+$/, '')}\n`;
      let out = '';
      if (!shared.has(key)) {
        shared.add(key);
        out += `# ==== shared: ${key} ====\n${text.replace(/\s+$/, '')}\n\n`;
      }
      const factory = `New-${key.charAt(0).toUpperCase()}${key.slice(1)}Module`;
      return `${out}# ==== module: ${id} ====\n$Modules += ${factory} -Id '${id}'\n`;
    })
    .join('\n');
  const configB64 = utf8ToBase64(JSON.stringify(runtimeConfig));
  // split/join rather than String.replace: no `$&`-style special patterns in the inserted text.
  return coreText
    .split('__COMMON__').join(commonText.replace(/\s+$/, ''))
    .split('__CONFIG_B64__').join(configB64)
    .split('__MODULES__').join(body);
}

const hasValue = (v) => v !== undefined && v !== null && v !== '';

// The secret values chosen per module: { [moduleId]: { [key]: value } } (only non-empty ones).
function secretValues(catalog, ids, config) {
  const out = {};
  for (const id of ids) {
    for (const k of optionKeys(catalog, id, 'secret')) {
      const v = config.modules[id] && config.modules[id][k];
      if (hasValue(v)) (out[id] = out[id] || {})[k] = String(v);
    }
  }
  return out;
}

// The runtime config the core decodes: per-module options plus each module's scope (the catalog
// is the single source of truth for scope; the core uses it to pick the user or machine phase).
// With secrets, "secrets" lists their key NAMES per module; the values live in files/secrets.json.
function runtimeConfig(catalog, ids, modules, config) {
  const scopes = {};
  for (const id of ids) scopes[id] = catalog.modules.find((m) => m.id === id).scope;
  const secrets = {};
  for (const [id, kv] of Object.entries(secretValues(catalog, ids, config))) secrets[id] = Object.keys(kv);
  return Object.keys(secrets).length ? { modules, scopes, secrets } : { modules, scopes };
}

// Per-module runtime options without file bytes or secret values; an app module also carries its
// definition (not user input).
function moduleRuntime(catalog, id, opts) {
  const rest = { ...(opts || {}) };
  for (const k of [...optionKeys(catalog, id, 'file'), ...optionKeys(catalog, id, 'secret')]) delete rest[k];
  const m = catalog.modules.find((x) => x.id === id);
  if (!m || !m.app) return rest;
  const { id: appId, label, scope, source, detect, uninstall } = m.app;
  return { ...rest, app: { id: appId, label, scope, source, detect, uninstall } };
}

// catalog: the EXPANDED catalog (see expandCatalog).
// fragments: { [fragmentId]: text } (see fragmentFiles / joinFragment), kind-specific.
// common: docs/core/common.ps1 text.
export function renderInstall({ core, common, catalog, fragments, config }) {
  const ids = selectedModules(catalog, config);
  const modules = {};
  for (const id of ids) modules[id] = moduleRuntime(catalog, id, config.modules[id]);
  return buildPolyglot(assemble(core, common, catalog, ids, fragments, runtimeConfig(catalog, ids, modules, config)));
}

// Same as renderInstall, minus the icon payloads the uninstaller never needs.
export function renderUninstall({ core, common, catalog, fragments, config }) {
  const ids = selectedModules(catalog, config);
  const modules = {};
  for (const id of ids) {
    const rest = { ...(config.modules[id] || {}) };
    for (const k of iconKeys(catalog, id)) delete rest[k];
    modules[id] = moduleRuntime(catalog, id, rest);
  }
  return buildPolyglot(assemble(core, common, catalog, ids, fragments, runtimeConfig(catalog, ids, modules, config)));
}

// ---- Bundle (zip) output ---------------------------------------------------------------------
// Deterministic STORE-only zip (no compression, fixed 1980-01-01 timestamps, entries in the given
// order, UTF-8 names), so the browser and Node produce identical bytes.
const CRC_TABLE = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c >>> 0;
  }
  return t;
})();
function crc32(bytes) {
  let c = 0xffffffff;
  for (let i = 0; i < bytes.length; i++) c = CRC_TABLE[(c ^ bytes[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

export function zipStore(entries) {
  const enc = new TextEncoder();
  const parts = [];
  const central = [];
  let offset = 0;
  for (const { name, bytes } of entries) {
    const n = enc.encode(name);
    const crc = crc32(bytes);
    const h = new DataView(new ArrayBuffer(30));
    h.setUint32(0, 0x04034b50, true); h.setUint16(4, 20, true); h.setUint16(6, 0x0800, true);
    h.setUint16(12, 0x21, true); h.setUint32(14, crc, true);
    h.setUint32(18, bytes.length, true); h.setUint32(22, bytes.length, true); h.setUint16(26, n.length, true);
    parts.push(new Uint8Array(h.buffer), n, bytes);
    const c = new DataView(new ArrayBuffer(46));
    c.setUint32(0, 0x02014b50, true); c.setUint16(4, 20, true); c.setUint16(6, 20, true); c.setUint16(8, 0x0800, true);
    c.setUint16(14, 0x21, true); c.setUint32(16, crc, true);
    c.setUint32(20, bytes.length, true); c.setUint32(24, bytes.length, true); c.setUint16(28, n.length, true);
    c.setUint32(42, offset, true);
    central.push(new Uint8Array(c.buffer), n);
    offset += 30 + n.length + bytes.length;
  }
  const cdSize = central.reduce((s, p) => s + p.length, 0);
  const e = new DataView(new ArrayBuffer(22));
  e.setUint32(0, 0x06054b50, true); e.setUint16(8, entries.length, true); e.setUint16(10, entries.length, true);
  e.setUint32(12, cdSize, true); e.setUint32(16, offset, true);
  const all = [...parts, ...central, new Uint8Array(e.buffer)];
  const out = new Uint8Array(all.reduce((s, p) => s + p.length, 0));
  let at = 0;
  for (const p of all) { out.set(p, at); at += p.length; }
  return out;
}

export async function sha256Hex(bytes) {
  const d = await crypto.subtle.digest('SHA-256', bytes);
  return Array.from(new Uint8Array(d), (b) => b.toString(16).padStart(2, '0')).join('');
}

// Everything one build produces. Builds with no file payload are just the two .cmd texts
// (zip = null). A build with "file" options or secret values is ONE zip:
//   <base>/Install-<base>.cmd, <base>/Uninstall-<base>.cmd, <base>/files/<fileName>, <base>/files/secrets.json
// so secrets never sit in a .cmd. A file whose app pins a SHA-256 must match it (fail early).
// config.modules[id][fileKey] is a Uint8Array; secret values are strings.
export async function renderOutputs({ installCore, uninstallCore, common, catalog, installFragments, uninstallFragments, config }) {
  const ids = selectedModules(catalog, config);
  const baseName = outputBaseName(catalog, config);
  const payload = [];
  for (const id of ids) {
    const m = catalog.modules.find((x) => x.id === id);
    for (const o of (m.options || []).filter((x) => x.type === 'file')) {
      const v = config.modules[id] && config.modules[id][o.key];
      if (!hasValue(v)) {
        if (o.required) throw new Error(`Please choose "${o.label}" for ${m.label}.`);
        continue;
      }
      if (!(v instanceof Uint8Array)) throw new Error(`${id}.${o.key}: file content must be bytes`);
      const pin = m.app && m.app.source && m.app.source.sha256;
      if (pin && (await sha256Hex(v)) !== pin) {
        throw new Error(`The file chosen for "${o.label}" (${m.label}) is not the expected installer: its SHA-256 fingerprint does not match.`);
      }
      payload.push({ name: `files/${o.fileName}`, bytes: v });
    }
  }
  const secrets = secretValues(catalog, ids, config);
  if (Object.keys(secrets).length) payload.push({ name: 'files/secrets.json', bytes: new TextEncoder().encode(JSON.stringify(secrets)) });

  const install = renderInstall({ core: installCore, common, catalog, fragments: installFragments, config });
  const uninstall = config.generateUninstall
    ? renderUninstall({ core: uninstallCore, common, catalog, fragments: uninstallFragments, config })
    : null;
  if (payload.length === 0) return { baseName, install, uninstall, zip: null };
  const enc = new TextEncoder();
  const entries = [{ name: `${baseName}/Install-${baseName}.cmd`, bytes: enc.encode(install) }];
  if (uninstall) entries.push({ name: `${baseName}/Uninstall-${baseName}.cmd`, bytes: enc.encode(uninstall) });
  for (const p of payload) entries.push({ name: `${baseName}/${p.name}`, bytes: p.bytes });
  return { baseName, install, uninstall, zip: zipStore(entries) };
}
