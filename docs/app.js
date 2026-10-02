// Mom-Setup configurator. Everything below runs entirely in the browser: nothing typed or
// uploaded here is sent anywhere. It loads docs/catalog.json, renders one checklist card per
// module, and on submit fetches the core + selected module fragments and assembles them with
// docs/render-core.js -- the same module tools/render.mjs uses for the CI-tested build.

import {
  renderInstall,
  renderUninstall,
  selectedModules,
  outputBaseName,
  sanitizeFilename,
  bytesToBase64,
} from './render-core.js';

const form = document.getElementById('config-form');
const modulesDiv = document.getElementById('modules');
const generateBtn = document.getElementById('generate-btn');
const resultsPanel = document.getElementById('results');
const downloadsDiv = document.getElementById('downloads');
const hashDiv = document.getElementById('hash');
const auditPre = document.getElementById('audit-pre');
const errorNotice = document.getElementById('error-notice');

// ---- Per-module option collectors ------------------------------------------
// One entry per catalog module that has options in index.html. Returns the module's options
// object (exactly what docs/modules/<id>/install.ps1 receives as $Cfg) or throws a message
// for the user. Modules without an entry are selected with {} as their options.
const collectors = {
  'desktop-shortcut': async () => {
    const destUrl = document.getElementById('dest-url').value.trim();
    if (!/^https?:\/\/.+/i.test(destUrl)) {
      throw new Error('Please enter a full web address starting with http:// or https://');
    }
    const name = sanitizeFilename(document.getElementById('shortcut-name').value) || 'Website';
    const style = form.querySelector('input[name="shortcut-style"]:checked').value;
    const opts = { destUrl, name, style };
    const file = document.getElementById('icon-file').files[0];
    if (file) opts.iconB64 = bytesToBase64(await window.MomSetupIco.fileToIcoBytes(file));
    return opts;
  },
  'ublock-lite': async () => ({
    pinToolbar: document.getElementById('pin-toolbar').checked,
    autoRestartChrome: document.getElementById('auto-restart').checked,
  }),
};

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

const catalogPromise = cachedText('./catalog.json').then(JSON.parse);
cachedText('./core/installer-core.ps1'); // warm the cache while the user fills out the form
cachedText('./core/uninstall-core.ps1');

async function loadFragments(ids, kind) {
  const texts = await Promise.all(ids.map((id) => cachedText(`./modules/${id}/${kind}.ps1`)));
  return Object.fromEntries(ids.map((id, i) => [id, texts[i]]));
}

// ---- Checklist UI -----------------------------------------------------------
const params = new URLSearchParams(location.search);

function renderChecklist(catalog) {
  const bodies = new Map(
    [...modulesDiv.querySelectorAll('.module-body')].map((el) => [el.dataset.module, el]),
  );
  const ordered = [...catalog.modules].sort((a, b) => a.order - b.order);
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
    if (m.needsAdmin) {
      const badge = document.createElement('span');
      badge.className = 'badge';
      badge.textContent = 'asks for admin';
      badge.title = 'Shows one Windows "allow changes?" prompt when it runs';
      head.append(badge);
    }
    const desc = document.createElement('p');
    desc.className = 'module-desc';
    desc.textContent = m.description;

    const warn = document.createElement('p');
    warn.className = 'module-warn';
    warn.hidden = true;

    card.append(head, desc, warn);
    const body = bodies.get(m.id);
    if (body) card.append(body);
    modulesDiv.append(card);
  }
  // Drop option bodies for modules no longer in the catalog.
  for (const [id, el] of bodies) if (!catalog.modules.some((m) => m.id === id)) el.remove();

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
  .then((catalog) => {
    renderChecklist(catalog);
    // Prefill from ?url=&name=
    if (params.get('url')) document.getElementById('dest-url').value = params.get('url');
    if (params.get('name')) document.getElementById('shortcut-name').value = params.get('name');
  })
  .catch((err) => showError('Could not load the list of setup items: ' + err.message));

// ---- Output -----------------------------------------------------------------
async function sha256Hex(text) {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');
}

function triggerDownload(filename, text) {
  const blob = new Blob([text], { type: 'text/plain' });
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
    for (const id of chosen) config.modules[id] = collectors[id] ? await collectors[id]() : {};

    const ids = selectedModules(catalog, config);
    const [installCore, uninstallCore, installFrags] = await Promise.all([
      cachedText('./core/installer-core.ps1'),
      cachedText('./core/uninstall-core.ps1'),
      loadFragments(ids, 'install'),
    ]);
    const base = outputBaseName(config);
    const installCmd = renderInstall({ core: installCore, catalog, fragments: installFrags, config });

    downloadsDiv.innerHTML = '';
    const installName = `Install-${base}.cmd`;
    triggerDownload(installName, installCmd);
    addRedownloadButton(installName, installCmd);
    const hashLines = [`${installName}  sha256:${await sha256Hex(installCmd)}`];

    if (config.generateUninstall) {
      const uninstallFrags = await loadFragments(ids, 'uninstall');
      const uninstallCmd = renderUninstall({ core: uninstallCore, catalog, fragments: uninstallFrags, config });
      const uninstallName = `Uninstall-${base}.cmd`;
      triggerDownload(uninstallName, uninstallCmd);
      addRedownloadButton(uninstallName, uninstallCmd);
      hashLines.push(`${uninstallName}  sha256:${await sha256Hex(uninstallCmd)}`);
    }

    hashDiv.textContent = hashLines.join('\n');
    auditPre.textContent = installCmd.slice(installCmd.indexOf('\n') + 1);
    resultsPanel.hidden = false;
  } catch (err) {
    console.error(err);
    showError(err && err.message ? err.message : String(err));
  } finally {
    generateBtn.disabled = false;
    generateBtn.textContent = 'Generate installer';
  }
});
