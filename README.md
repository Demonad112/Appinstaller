# Appinstaller — Mom Setup Builder

A GitHub Pages configurator that generates a single, self-contained Windows `.cmd` file which,
with zero required interaction, does two things:

1. Force-installs **uBlock Origin Lite** into Chrome via the browser's enterprise policy
   mechanism, so it can't be accidentally disabled or removed.
2. Creates a desktop shortcut that opens one specific website in Chrome (or the default
   browser, if Chrome isn't installed).

**Live site:** enable GitHub Pages once — see [Enabling Pages](#enabling-pages) — then use it
at `https://<owner>.github.io/<repo>/`.

## How it works

Everything runs client-side in the browser. `docs/index.html` + `docs/app.js` fetch the two
PowerShell templates (`docs/installer-template.ps1`, `docs/uninstall-template.ps1`), substitute
your URL/name/icon into their placeholders, wrap the result in a small batch/PowerShell polyglot
header, and hand you a `.cmd` file to download. Nothing you type or upload is sent to a server.

`tools/render.mjs` performs the identical substitution in Node, so CI (`.github/workflows/validate.yml`)
tests the exact bytes the website produces — there is exactly one copy of the payload logic
(the two `.ps1` templates), not two copies that could drift apart.

### The polyglot file

`-EncodedCommand` isn't viable here because an embedded icon pushes the base64 payload well past
cmd.exe's ~8191-character command-line limit. Instead the `.cmd` is:

```
@set "SELF=%~f0" & @powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -Command "..." & @exit /b
<#PSBEGIN#>
... PowerShell payload ...
```

cmd.exe executes line 1 (which reads the file itself off disk and `iex`'s everything after the
marker) and exits before it ever reaches the PowerShell lines below, so there's no size limit,
no temp file, and the machine's script execution policy is never touched.

### Ad-blocker install

- Extension: **uBlock Origin Lite**, ID `ddkjiahejlhfcafbddmgiahcphecmpfh` (Chrome Web Store).
  Full uBlock Origin was purged from the Chrome Web Store on 2026-08-31 as part of Chrome's
  Manifest V2 removal (Chrome 139+ won't run MV2 at all), so it is not a viable target — hence
  Lite.
- Policy written: `ExtensionInstallForcelist` under
  `HKCU:\Software\Policies\Google\Chrome` (**no admin required** — Chrome honors this as a
  user-scope platform policy).
- If a machine-wide (`HKLM`) forcelist policy already exists, Chrome would ignore the `HKCU`
  value entirely (policy sources don't merge; the higher-priority source wins). The script
  detects this and relaunches itself elevated via `Start-Process -Verb RunAs` to write `HKLM`
  instead — this is the **only** case that produces a UAC prompt.
- Idempotent: re-running updates the existing forcelist entry in place rather than adding
  duplicates, and never touches other extensions' entries.
- **Known limitation:** uBOL installs in **Basic** filtering mode (network/DNR rules only, no
  cosmetic element hiding). Chrome has no policy to pre-grant the optional host permissions
  "Optimal" mode needs — [confirmed by the uBOL maintainer](https://github.com/uBlockOrigin/uBOL-home/discussions/320).
  Upgrading to Optimal is a one-time, 3-click manual step (extension icon → mode slider → grant
  permission).

### Desktop shortcut

- "App window" style (default): a `.lnk` targeting `chrome.exe --app="<url>"` — opens with no
  tabs or address bar.
- "Normal browser tab" style, or automatically if Chrome isn't found: a `.url` internet
  shortcut, which (contrary to a common assumption) *does* carry a custom icon natively via
  `IconFile=`/`IconIndex=`.
- Written to the real Desktop folder (`[Environment]::GetFolderPath('Desktop')`, correct even
  under OneDrive Desktop redirection) and overwritten in place on re-run — never accumulates
  `Name (1).lnk` copies.

## Repository layout

```
docs/                     GitHub Pages root
  index.html, app.js, ico.js, style.css     the configurator
  installer-template.ps1, uninstall-template.ps1   the ONE source of truth for the payload
tools/render.mjs           Node renderer (CI + local testing) — mirrors app.js exactly
tests/
  fixtures/config.json     canonical test config
  Verify-Install.ps1       asserts registry + shortcut state on a real Windows box
.github/workflows/
  pages.yml                deploys docs/ to GitHub Pages
  validate.yml             render → PSScriptAnalyzer → install → verify → idempotency → uninstall
HANDOFF.md                 plain-language page to send along with the .cmd file
```

## Enabling Pages

One-time setup: **Settings → Pages → Source: GitHub Actions**. The `pages.yml` workflow deploys
`docs/` on every push to `main`.

## Local testing

```
node tools/render.mjs tests/fixtures/config.json out
```

Produces `out/Install-Example Site.cmd` and `out/Uninstall-Example Site.cmd` from the checked-in
fixture. Requires an actual Windows machine (or the CI runner) to execute.

## Verifying it worked (do this before handing the file off)

The requirement isn't just "does the extension appear" — it's proving the policy actually forced
it in *and* that a normal click can't undo it:

1. `reg query "HKCU\Software\Policies\Google\Chrome\ExtensionInstallForcelist"`
   → should show one value: `ddkjiahejlhfcafbddmgiahcphecmpfh;https://clients2.google.com/service/update2/crx`
2. `chrome://policy` → **Reload policies** → `ExtensionInstallForcelist` shows Scope **User**,
   Source **Platform**, Status **OK**.
3. `chrome://extensions` → uBlock Origin Lite is present, badged *Installed by enterprise policy*.
4. **The actual proof:** the Remove button is absent and the enable toggle is greyed out and
   won't move.
5. **Harder proof:** delete the extension's folder under
   `%LOCALAPPDATA%\Google\Chrome\User Data\Default\Extensions\ddkjiahejlhfcafbddmgiahcphecmpfh`,
   restart Chrome → it reinstalls itself automatically.
6. **Standard-user test:** run the `.cmd` on a local *standard* account (not an administrator)
   and confirm **zero** UAC prompts, and that steps 1–4 still pass.
7. Double-click the desktop shortcut → correct URL, correct icon, correct window style.
8. Idempotency: run the `.cmd` three times, re-check step 1 → still exactly one entry.
9. Run `Uninstall-<name>.cmd` → the registry entry and shortcut are gone, and the extension
   becomes removable again in `chrome://extensions`.

## Known limitations

- **Basic filtering mode only** for uBlock Origin Lite — see above. Not fixable by policy.
- **Mark of the Web:** a `.cmd` downloaded via email or a browser gets flagged, and double-
  clicking it shows one *"The publisher could not be verified — are you sure you want to run
  this?"* dialog. A `.cmd` can't be meaningfully code-signed, so this can't be engineered away.
  Mitigations, in order of preference: transfer via USB (FAT32 strips the mark), or right-click
  → Properties → check **Unblock** before sending, or run it yourself over a remote-support
  session.
- **"Managed by your organization"** appears in Chrome's `⋮` menu after install. Expected and
  benign — it refers only to this one extension policy.
- A domain-joined machine, or one with a pre-existing machine-wide Chrome policy, triggers the
  one-time elevated (`HKLM`) path described above, which does show a UAC prompt.
