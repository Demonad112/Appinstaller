// Mom-Setup configurator. Everything below runs entirely in the browser: nothing typed or
// uploaded here is sent anywhere. It fetches the two PowerShell templates (the same files
// tools/render.mjs uses for the CI-tested build) and performs the identical placeholder
// substitution client-side, then wraps the result in a batch/PowerShell polyglot header so
// the download is a single double-clickable .cmd file.

(function () {
  const MARKER = '<' + '#PSBEGIN#' + '>';
  const EXT_ID = 'ddkjiahejlhfcafbddmgiahcphecmpfh'; // uBlock Origin Lite, Chrome Web Store

  const form = document.getElementById('config-form');
  const urlInput = document.getElementById('dest-url');
  const nameInput = document.getElementById('shortcut-name');
  const iconInput = document.getElementById('icon-file');
  const generateBtn = document.getElementById('generate-btn');
  const resultsPanel = document.getElementById('results');
  const downloadsDiv = document.getElementById('downloads');
  const hashDiv = document.getElementById('hash');
  const auditPre = document.getElementById('audit-pre');
  const errorNotice = document.getElementById('error-notice');

  let templatesPromise = null;
  function loadTemplates() {
    if (!templatesPromise) {
      templatesPromise = Promise.all([
        fetch('./installer-template.ps1').then((r) => r.text()),
        fetch('./uninstall-template.ps1').then((r) => r.text()),
      ]);
    }
    return templatesPromise;
  }
  loadTemplates(); // warm the cache while the user fills out the form

  // ---- Prefill from ?url=&name= ------------------------------------------
  const params = new URLSearchParams(location.search);
  if (params.get('url')) urlInput.value = params.get('url');
  if (params.get('name')) nameInput.value = params.get('name');

  // ---- Small encoding helpers ---------------------------------------------
  function uint8ToBase64(bytes) {
    let binary = '';
    const chunkSize = 0x8000;
    for (let i = 0; i < bytes.length; i += chunkSize) {
      binary += String.fromCharCode.apply(null, bytes.subarray(i, i + chunkSize));
    }
    return btoa(binary);
  }

  function utf8ToBase64(str) {
    return uint8ToBase64(new TextEncoder().encode(str));
  }

  function toPsBool(v) {
    return v ? '$true' : '$false';
  }

  function sanitizeFilename(name) {
    const cleaned = name.replace(/[\\/:*?"<>|]/g, '_').trim();
    return cleaned || 'Website';
  }

  async function sha256Hex(text) {
    const bytes = new TextEncoder().encode(text);
    const digest = await crypto.subtle.digest('SHA-256', bytes);
    return Array.from(new Uint8Array(digest))
      .map((b) => b.toString(16).padStart(2, '0'))
      .join('');
  }

  // ---- Polyglot assembly, mirroring tools/render.mjs exactly ---------------
  function buildPolyglotHeader() {
    return (
      '@set "SELF=%~f0" & @powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass ' +
      '-Command "$c=[IO.File]::ReadAllText($env:SELF);iex $c.Substring(' +
      "$c.IndexOf('<'+'#PSBEGIN#'+'>')+11)\" & @exit /b"
    );
  }

  function buildPolyglot(psPayload) {
    const normalized = psPayload.replace(/\r\n/g, '\n').replace(/\n/g, '\r\n');
    return [buildPolyglotHeader(), MARKER, normalized].join('\r\n');
  }

  function replaceAll(str, token, value) {
    return str.split(token).join(value);
  }

  function renderInstall(template, config, iconB64) {
    let out = template;
    out = replaceAll(out, '__DEST_URL_B64__', utf8ToBase64(config.destUrl));
    out = replaceAll(out, '__SHORTCUT_NAME_B64__', utf8ToBase64(config.shortcutName));
    out = replaceAll(out, '__ICON_B64__', iconB64 || '');
    out = replaceAll(out, '__SHORTCUT_STYLE__', config.shortcutStyle);
    out = replaceAll(out, '__PIN_TOOLBAR__', toPsBool(config.pinToolbar));
    out = replaceAll(out, '__AUTO_RESTART_CHROME__', toPsBool(config.autoRestartChrome));
    return out;
  }

  function renderUninstall(template, config) {
    return replaceAll(template, '__SHORTCUT_NAME_B64__', utf8ToBase64(config.shortcutName));
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
    return blob;
  }

  function showError(message) {
    errorNotice.textContent = message;
    errorNotice.hidden = false;
    resultsPanel.hidden = true;
  }

  form.addEventListener('submit', async (event) => {
    event.preventDefault();
    errorNotice.hidden = true;

    const destUrl = urlInput.value.trim();
    if (!/^https?:\/\/.+/i.test(destUrl)) {
      showError('Please enter a full web address starting with http:// or https://');
      return;
    }
    const shortcutName = sanitizeFilename(nameInput.value.trim() || 'Website');
    const shortcutStyle = form.querySelector('input[name="shortcut-style"]:checked').value;
    const pinToolbar = document.getElementById('pin-toolbar').checked;
    const autoRestartChrome = document.getElementById('auto-restart').checked;
    const generateUninstall = document.getElementById('gen-uninstall').checked;

    generateBtn.disabled = true;
    generateBtn.textContent = 'Generating...';

    try {
      const [installTemplate, uninstallTemplate] = await loadTemplates();

      let iconB64 = '';
      const file = iconInput.files[0];
      if (file) {
        const icoBytes = await window.MomSetupIco.fileToIcoBytes(file);
        iconB64 = uint8ToBase64(icoBytes);
      }

      const config = { destUrl, shortcutName, shortcutStyle, pinToolbar, autoRestartChrome };
      const installPs = renderInstall(installTemplate, config, iconB64);
      const installCmd = buildPolyglot(installPs);

      downloadsDiv.innerHTML = '';
      const installBlob = triggerDownload(`Install-${shortcutName}.cmd`, installCmd);
      const installBtn = document.createElement('button');
      installBtn.type = 'button';
      installBtn.className = 'secondary';
      installBtn.textContent = `Download Install-${shortcutName}.cmd again`;
      installBtn.addEventListener('click', () => triggerDownload(`Install-${shortcutName}.cmd`, installCmd));
      downloadsDiv.appendChild(installBtn);

      let hashLines = [`Install-${shortcutName}.cmd  sha256:${await sha256Hex(installCmd)}`];

      if (generateUninstall) {
        const uninstallPs = renderUninstall(uninstallTemplate, config);
        const uninstallCmd = buildPolyglot(uninstallPs);
        triggerDownload(`Uninstall-${shortcutName}.cmd`, uninstallCmd);
        const uninstallBtn = document.createElement('button');
        uninstallBtn.type = 'button';
        uninstallBtn.className = 'secondary';
        uninstallBtn.textContent = `Download Uninstall-${shortcutName}.cmd again`;
        uninstallBtn.addEventListener('click', () => triggerDownload(`Uninstall-${shortcutName}.cmd`, uninstallCmd));
        downloadsDiv.appendChild(uninstallBtn);
        hashLines.push(`Uninstall-${shortcutName}.cmd  sha256:${await sha256Hex(uninstallCmd)}`);
      }

      hashDiv.textContent = hashLines.join('\n');
      auditPre.textContent = installPs;
      resultsPanel.hidden = false;
    } catch (err) {
      console.error(err);
      showError('Something went wrong generating the installer: ' + (err && err.message ? err.message : err));
    } finally {
      generateBtn.disabled = false;
      generateBtn.textContent = 'Generate installer';
    }
  });
})();
