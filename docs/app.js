// Appinstaller configurator. Everything below runs entirely in the browser: nothing typed or
// uploaded here is sent anywhere. It loads docs/catalog.json, renders one checklist card per
// module, and on submit fetches the core + selected module fragments and assembles them with
// docs/render-core.js -- the same module tools/render.mjs uses for the CI-tested build.

import {
  expandCatalog,
  fragmentFiles,
  joinFragment,
  renderOutputs,
  selectedModules,
  sanitizeFilename,
  bytesToBase64,
  sha256Hex,
} from './render-core.js';

const form = document.getElementById('config-form');
const modulesDiv = document.getElementById('modules');
const generateBtn = document.getElementById('generate-btn');
const resultsPanel = document.getElementById('results');
const downloadsDiv = document.getElementById('downloads');
const hashDiv = document.getElementById('hash');
const auditPre = document.getElementById('audit-pre');
const errorNotice = document.getElementById('error-notice');

// ---- Data-driven option fields ----------------------------------------------
// Every module's form comes from its "options" list in docs/catalog.json (types: text, url,
// select, radio, checkbox, icon, secret, multiselect, file). collectOptions() returns the module's
// options (file bytes and secret values included; render-core moves those into the download's
// files/ folder, never into a .cmd), or throws a message for the user.
function el(tag, props = {}, ...children) {
  const node = Object.assign(document.createElement(tag), props);
  node.append(...children);
  return node;
}

function labelWithHint(opt, forId) {
  const label = el('label', { htmlFor: forId || '' }, opt.label);
  if (opt.hint) label.append(' ', el('span', { className: 'hint', textContent: opt.hint }));
  return label;
}

function buildField(moduleId, opt) {
  const id = `opt-${moduleId}-${opt.key}`;
  const wrap = el('div', { className: 'field' });
  wrap.dataset.key = opt.key;
  const fromUrl = opt.param && params.get(opt.param);
  switch (opt.type) {
    case 'text':
    case 'url':
    case 'secret': {
      const input = el('input', {
        id,
        type: opt.type === 'url' ? 'url' : opt.type === 'secret' ? 'password' : 'text',
        placeholder: opt.placeholder || '',
        value: fromUrl || opt.default || '',
      });
      if (opt.maxLength) input.maxLength = opt.maxLength;
      if (opt.type === 'secret') {
        input.value = '';
        input.autocomplete = 'off';
      }
      wrap.append(labelWithHint(opt, id), input);
      if (opt.type === 'secret') {
        wrap.append(el('p', { className: 'hint', textContent: 'Kept out of the setup files: it goes into a separate file inside the downloaded zip. Don\'t share that zip, and delete it after installing.' }));
      }
      break;
    }
    case 'file': {
      wrap.append(labelWithHint(opt, id), el('input', { id, type: 'file' }));
      break;
    }
    case 'select': {
      const select = el('select', { id });
      for (const v of opt.values) select.append(el('option', { value: v.value, textContent: v.label }));
      select.value = fromUrl || opt.default || opt.values[0].value;
      wrap.append(labelWithHint(opt, id), select);
      break;
    }
    case 'radio': {
      const set = el('fieldset');
      set.append(el('legend', { textContent: opt.label }));
      if (opt.hint) set.append(el('span', { className: 'hint', textContent: opt.hint }));
      const chosen = opt.default || opt.values[0].value;
      for (const v of opt.values) {
        const radio = el('input', { type: 'radio', name: id, value: v.value, checked: v.value === chosen });
        set.append(el('label', {}, radio, ' ' + v.label));
      }
      wrap.append(set);
      break;
    }
    case 'checkbox': {
      const row = el('div', { className: 'checkbox-row' });
      row.append(el('input', { id, type: 'checkbox', checked: !!opt.default }), el('label', { htmlFor: id, textContent: opt.label }));
      wrap.append(row);
      break;
    }
    case 'multiselect': {
      const set = el('fieldset');
      set.append(el('legend', { textContent: opt.label }));
      if (opt.hint) set.append(el('span', { className: 'hint', textContent: opt.hint }));
      const chosen = new Set(opt.default || []);
      for (const v of opt.values) {
        const box = el('input', { type: 'checkbox', value: v.value, checked: chosen.has(v.value) });
        set.append(el('label', {}, box, ' ' + v.label));
      }
      wrap.append(set);
      break;
    }
    case 'icon': {
      wrap.append(
        labelWithHint(opt, id),
        el('input', { id, type: 'file', accept: '.ico,.png,.jpg,.jpeg,image/x-icon,image/png,image/jpeg' }),
      );
      break;
    }
    default:
      throw new Error(`Unknown option type '${opt.type}' for ${moduleId}.${opt.key}`);
  }
  return wrap;
}

async function collectOptions(m, card) {
  const out = {};
  for (const opt of m.options || []) {
    const field = card.querySelector(`.field[data-key="${opt.key}"]`);
    let value;
    switch (opt.type) {
      case 'secret': {
        value = field.querySelector('input').value; // not trimmed: spaces can be part of a password
        if (!value) {
          if (opt.required) throw new Error(`Please fill in "${opt.label}".`);
          continue;
        }
        break;
      }
      case 'file': {
        const file = field.querySelector('input').files[0];
        if (!file) {
          if (opt.required) throw new Error(`Please choose "${opt.label}" for ${m.label}.`);
          continue;
        }
        value = new Uint8Array(await file.arrayBuffer());
        break;
      }
      case 'text':
      case 'url': {
        value = field.querySelector('input').value.trim();
        if (opt.sanitize === 'filename') value = sanitizeFilename(value);
        if (!value && opt.default) value = opt.default;
        if (!value) {
          if (opt.required) throw new Error(`Please fill in "${opt.label}".`);
          continue;
        }
        if (opt.type === 'url' && !/^https?:\/\/.+/i.test(value)) {
          throw new Error('Please enter a full web address starting with http:// or https://');
        }
        if (opt.pattern && !new RegExp(opt.pattern).test(value)) {
          throw new Error(`"${opt.label}" isn't in the expected format.`);
        }
        break;
      }
      case 'select':
        value = field.querySelector('select').value;
        break;
      case 'radio':
        value = field.querySelector('input:checked').value;
        break;
      case 'checkbox':
        value = field.querySelector('input').checked;
        break;
      case 'multiselect':
        value = [...field.querySelectorAll('input:checked')].map((b) => b.value);
        if (opt.required && value.length === 0) throw new Error(`Please pick at least one for "${opt.label}".`);
        break;
      case 'icon': {
        const file = field.querySelector('input').files[0];
        if (!file) continue;
        value = bytesToBase64(await window.AppinstallerIco.fileToIcoBytes(file));
        break;
      }
    }
    out[opt.key] = value;
  }
  return out;
}

// ---- Loading ----------------------------------------------------------------
const fetchText = (p) =>
  fetch(p).then((r) => {
    if (!r.ok) throw new Error(`Couldn't load ${p} (${r.status})`);
    return r.text();
  });
const textCache = new Map();
const cachedText = (p) => {
  if (!textCache.has(p)) textCache.set(p, fetchText(p));
  return textCache.get(p);
};

// catalog.json lists the curated app ids; each app is its own docs/apps/<id>.json and becomes a
// catalog module `app-<id>` via expandCatalog (shared with the Node renderer).
const catalogPromise = cachedText('./catalog.json')
  .then(JSON.parse)
  .then(async (raw) => {
    const defs = await Promise.all((raw.apps || []).map((id) => cachedText(`./apps/${id}.json`).then(JSON.parse)));
    return expandCatalog(raw, Object.fromEntries((raw.apps || []).map((id, i) => [id, defs[i]])));
  });
cachedText('./core/installer-core.ps1'); // warm the cache while the user fills out the form
cachedText('./core/uninstall-core.ps1');
cachedText('./core/common.ps1');

async function loadFragments(catalog, ids, kind) {
  const entries = Object.entries(fragmentFiles(catalog, ids, kind));
  const texts = await Promise.all(entries.map(([, files]) => Promise.all(files.map((p) => cachedText(`./${p}`)))));
  return Object.fromEntries(entries.map(([f], i) => [f, joinFragment(texts[i])]));
}

// ---- Checklist UI -----------------------------------------------------------
const params = new URLSearchParams(location.search);

function renderChecklist(catalog) {
  // "test": true items exist for CI only; they show with ?test=1 (tests/browser.mjs uses it).
  const showTest = params.get('test') === '1';
  const ordered = [...catalog.modules].filter((m) => showTest || !m.test).sort((a, b) => a.order - b.order);
  for (const m of ordered) {
    const card = document.createElement('section');
    card.className = 'module';
    card.dataset.module = m.id;

    const head = document.createElement('label');
    head.className = 'module-head';
    const box = document.createElement('input');
    box.type = 'checkbox';
    box.className = 'module-toggle';
    box.value = m.id;
    box.checked = m.default !== false;
    const title = document.createElement('span');
    title.className = 'module-title';
    title.textContent = m.label;
    head.append(box, title);
    if (m.scope === 'machine') {
      const badge = document.createElement('span');
      badge.className = 'badge';
      badge.textContent = 'may ask for admin';
      badge.title = 'Can show one Windows "allow changes?" prompt, only if this computer needs it';
      head.append(badge);
    }
    const desc = document.createElement('p');
    desc.className = 'module-desc';
    desc.textContent = m.description;

    const warn = document.createElement('p');
    warn.className = 'module-warn';
    warn.hidden = true;

    card.append(head, desc, warn);
    if ((m.options || []).length > 0) {
      const body = document.createElement('div');
      body.className = 'module-body';
      for (const opt of m.options) body.append(buildField(m.id, opt));
      card.append(body);
    }
    modulesDiv.append(card);
  }

  const sync = () => {
    const on = new Set([...modulesDiv.querySelectorAll('.module-toggle:checked')].map((b) => b.value));
    for (const card of modulesDiv.querySelectorAll('.module')) {
      const m = catalog.modules.find((x) => x.id === card.dataset.module);
      card.classList.toggle('off', !on.has(m.id));
      const body = card.querySelector('.module-body');
      if (body) body.hidden = !on.has(m.id);
      const missing = (m.requires || []).filter((r) => !on.has(r));
      const warn = card.querySelector('.module-warn');
      warn.hidden = !on.has(m.id) || missing.length === 0;
      warn.textContent = missing
        .map((r) => {
          const req = catalog.modules.find((x) => x.id === r);
          return `Works only if "${req ? req.label : r}" is already on the computer — tick it above to guarantee that, otherwise this step is skipped where it's missing.`;
        })
        .join(' ');
    }
  };
  modulesDiv.addEventListener('change', sync);
  sync();
}

catalogPromise
  .then(renderChecklist) // option prefill from ?<param>= happens in buildField
  .catch((err) => showError('Could not load the list of setup items: ' + err.message));

// ---- Output -----------------------------------------------------------------
const hashOf = (data) => sha256Hex(typeof data === 'string' ? new TextEncoder().encode(data) : data);

function triggerDownload(filename, data) {
  const blob = new Blob([data], { type: typeof data === 'string' ? 'text/plain' : 'application/zip' });
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(a.href), 4000);
}

function addRedownloadButton(filename, text) {
  const btn = document.createElement('button');
  btn.type = 'button';
  btn.className = 'secondary';
  btn.textContent = `Download ${filename} again`;
  btn.addEventListener('click', () => triggerDownload(filename, text));
  downloadsDiv.appendChild(btn);
}

function showError(message) {
  errorNotice.textContent = message;
  errorNotice.hidden = false;
  resultsPanel.hidden = true;
}

form.addEventListener('submit', async (event) => {
  event.preventDefault();
  errorNotice.hidden = true;
  generateBtn.disabled = true;
  generateBtn.textContent = 'Generating...';

  try {
    const catalog = await catalogPromise;
    const chosen = [...modulesDiv.querySelectorAll('.module-toggle:checked')].map((b) => b.value);
    if (chosen.length === 0) throw new Error('Tick at least one item to set up.');

    const config = { modules: {}, generateUninstall: document.getElementById('gen-uninstall').checked };
    for (const id of chosen) {
      const m = catalog.modules.find((x) => x.id === id);
      config.modules[id] = await collectOptions(m, modulesDiv.querySelector(`.module[data-module="${id}"]`));
    }

    const ids = selectedModules(catalog, config);
    const [installCore, uninstallCore, common, installFragments, uninstallFragments] = await Promise.all([
      cachedText('./core/installer-core.ps1'),
      cachedText('./core/uninstall-core.ps1'),
      cachedText('./core/common.ps1'),
      loadFragments(catalog, ids, 'install'),
      loadFragments(catalog, ids, 'uninstall'),
    ]);
    const { baseName: base, install, uninstall, zip } = await renderOutputs({
      installCore, uninstallCore, common, catalog, installFragments, uninstallFragments, config,
    });

    downloadsDiv.innerHTML = '';
    const installName = `Install-${base}.cmd`;
    const uninstallName = `Uninstall-${base}.cmd`;
    const hashLines = [];
    if (zip) {
      // Files or secrets go with this setup: one zip, to be extracted before running.
      const zipName = `${base}.zip`;
      triggerDownload(zipName, zip);
      addRedownloadButton(zipName, zip);
      hashLines.push(`${zipName}  sha256:${await hashOf(zip)}  (extract it, then run ${installName})`);
    } else {
      triggerDownload(installName, install);
      addRedownloadButton(installName, install);
      if (uninstall) {
        triggerDownload(uninstallName, uninstall);
        addRedownloadButton(uninstallName, uninstall);
      }
    }
    hashLines.push(`${installName}  sha256:${await hashOf(install)}`);
    if (uninstall) hashLines.push(`${uninstallName}  sha256:${await hashOf(uninstall)}`);

    hashDiv.textContent = hashLines.join('\n');
    auditPre.textContent = install.slice(install.indexOf('\n') + 1);
    resultsPanel.hidden = false;
  } catch (err) {
    console.error(err);
    showError(err && err.message ? err.message : String(err));
  } finally {
    generateBtn.disabled = false;
    generateBtn.textContent = 'Generate installer';
  }
});
