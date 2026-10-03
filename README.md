# Appinstaller — Appinstaller

A GitHub Pages configurator that generates a single, self-contained Windows `.cmd` file which,
with zero required interaction, sets up whichever of these **modules** you tick:

| Module | What it does | Admin? |
|---|---|---|
| `chrome` | Installs Google Chrome for the current user if no Chrome exists (Google's signed per-user installer). No-op if Chrome is present; left installed on uninstall. | No |
| `desktop-shortcut` | Desktop icon that opens one website in a Chrome app window (or the default browser). | No |
| `ublock-lite` | Force-installs **uBlock Origin Lite** into Chrome via enterprise policy, so it can't be accidentally disabled or removed. | Only if a machine-wide Chrome policy already exists |
| `app-7zip`, `app-vlc`, `app-adobe-reader` | Curated apps defined as data in `docs/apps/*.json` (see [Adding an app](#adding-an-app)). Skipped if already installed; uninstall only removes what this setup installed. | One UAC prompt, only if something needs installing |

**Live site:** enable GitHub Pages once — see [Enabling Pages](#enabling-pages) — then use it
at `https://<owner>.github.io/<repo>/`.

## How it works

Everything runs client-side in the browser. The page reads `docs/catalog.json` and shows one
checkbox card per **module** (a separately tested setup item). On generate, `docs/app.js` fetches
`docs/core/installer-core.ps1` plus each ticked module's `docs/modules/<id>/install.ps1`,
concatenates them in catalog order, embeds the options as one base64 JSON blob, wraps it all in a
small batch/PowerShell polyglot header, and hands you a `.cmd` to download. Nothing you type or
upload is sent to a server.

The assembly itself lives in exactly one place, `docs/render-core.js`, which both the browser
and `tools/render.mjs` (CI) import, so CI tests the exact bytes the website produces.

On the target machine the core decodes the options and runs in two phases. The real, un-elevated
user takes a run lock (a second run exits with "already running"), shows a small non-modal
"please wait" window, and runs every **user-scope** module in-process, so per-user changes land
on the right profile. If any **machine-scope** module needs admin on this computer, the script
then launches itself once more elevated (one UAC prompt) for just those modules; the child reports
back through `%ProgramData%\Appinstaller\run-<guid>\result.json`. The parent shows one combined
result popup and exits non-zero if any module failed, or if UAC was declined (those modules are
reported as skipped). Both phases and the shared helpers are in `docs/core/common.ps1`.

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

### Chrome install

- Runs first, so the shortcut and ad-blocker modules see the newly installed Chrome.
- Skips entirely if `chrome.exe` is found anywhere (machine-wide or per-user). It never upgrades,
  downgrades or repairs an existing Chrome.
- Downloads Google's per-user standalone installer (`needsadmin=false`). It runs it with
  `/silent /install` **only if** `Get-AuthenticodeSignature` reports `Valid` with signer
  `O=Google LLC`. Otherwise it fails closed.
- **Why not winget:** on `windows-latest`, `winget install Google.Chrome --scope user` fails
  with `0x8A150010` (no applicable installer). The package only ships a machine-scope MSI,
  which would mean a UAC prompt and an install for every account on the PC. winget remains the
  preferred mechanism for future modules whose packages offer a user-scope installer.
- Per-user install to `%LOCALAPPDATA%\Google\Chrome\Application`, so no UAC prompt.
- Writes `%LOCALAPPDATA%\Appinstaller\chrome-state.json` (method, path, time) when it installed Chrome.
- **Uninstall leaves Chrome installed** on purpose. Removing a browser deletes its bookmarks
  and history.
- The download is roughly 130–170 MB, and the hidden window shows no progress. On a slow
  connection, the final "Setup Complete" box can take several minutes to appear.

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
  detects this, and the module (machine scope with a dynamic `NeedsAdmin`) then runs in the
  core's elevated child to write `HKLM` instead — this is the **only** case that produces a UAC
  prompt.
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
docs/                       GitHub Pages root
  index.html, app.js, ico.js, style.css   the configurator (checklist UI)
  catalog.json              module registry: id, label, description, order, scope, requires, options
  render-core.js            THE renderer, shared by app.js and tools/render.mjs
  core/common.ps1           shared helpers + two-phase (user / elevated machine) driver
  core/installer-core.ps1   config decode + install entry point (splices common.ps1)
  core/uninstall-core.ps1   same, for rollback
  modules/<id>/install.ps1, uninstall.ps1   one folder per module
  modules/app/install.ps1, uninstall.ps1    shared fragment for every curated app
  apps/<id>.json            one curated app: source, detect, uninstall (listed in catalog.json "apps")
tools/render.mjs            Node CLI around render-core.js (CI + local testing)
tools/Probe-Winget.ps1      admission probe for a candidate app (run via probe-winget.yml)
tests/
  fixtures/<scenario>.json  one CI scenario each (which modules + options)
  modules/<id>.Verify.ps1   per-module assertions (installed / idempotent / removed)
  modules/app.Verify.ps1    assertions for every curated app (-AppId)
  Set-App.ps1               CI setup: put a curated app in a known state (absent / present)
  Run-Scenario.ps1          render -> lint -> install x3 -> verify -> uninstall -> verify
  check-catalog.mjs         fast cross-platform consistency + schema checks + golden hashes
  golden.json               sha256 of each fixture's rendered .cmd (regenerate on purpose)
  browser.mjs               Playwright: browser download == Node render == golden
.github/workflows/
  pages.yml                 deploys docs/ to GitHub Pages
  validate.yml              catalog check, then a windows-latest job per scenario
HANDOFF.md                  plain-language page to send along with the .cmd file
```

## Adding a module

The catalog is curated. Each app is researched, built and proven on real Windows CI before it
shows up on the page.

**Admission criteria.** An app gets in only if all of these hold:
- It has a pinned winget package ID (preferred, when it has an installer for the scope needed),
  or a vendor download URL whose Authenticode signer can be checked.
- It has a silent, unattended install path that has been proven on `windows-latest`.
  Interactive-only installers are rejected.
- It has a defined uninstall behavior, even if that behavior is to deliberately leave the app
  in place.
- Modules that write per-user state (HKCU, Desktop, `%LOCALAPPDATA%`) are `scope: "user"` and
  run as the real user, never elevated. An over-the-shoulder UAC elevation (a standard user
  typing an admin's password) runs as the *admin's* profile, so per-user changes would land on
  the wrong account. Only `scope: "machine"` modules can run in the elevated child.

**Checklist.**
1. Add an entry to `docs/catalog.json` with `id`, `label`, `description`, `order`
   (execution order), `scope` (`user` | `machine`), `requires` and `options`. A user-scope module
   may not require a machine-scope one (user modules run first).
2. Write `docs/modules/<id>/install.ps1`. It appends `{ Id; NeedsAdmin; Install }` to
   `$Modules` (`NeedsAdmin` only matters for machine scope: absent means "always elevate");
   `Install` returns the result lines shown to the user. See `docs/core/installer-core.ps1` for
   the contract and `docs/core/common.ps1` for the shared helpers.
3. Write `docs/modules/<id>/uninstall.ps1`, which appends `{ Id; NeedsAdmin; Uninstall }`.
4. Options are data: list them in the catalog entry as
   `{ key, type, label, hint, default, required, pattern, values }` (types `text`, `url`,
   `select`, `radio`, `checkbox`, `icon`, `multiselect`, `secret`, `file`; see
   [Bundles and secrets](#bundles-and-secrets)). The form and its validation are generated by
   `docs/app.js`; there is no per-module HTML or JavaScript. `"test": true` hides a CI-only item
   unless the page URL has `?test=1`.
5. Add `tests/modules/<id>.Verify.ps1`. It returns failure strings and handles `-ExpectAbsent`.
6. Add `tests/fixtures/<scenario>.json` and list the scenario in `validate.yml`'s matrix.
   `node tests/check-catalog.mjs` enforces steps 1–6.
7. Push, and get the whole matrix green.

## Adding an app

Apps are data, not code: one JSON file per app, no PowerShell to write. Each file becomes a
catalog module `app-<id>` (off by default) that shares `docs/modules/app/{install,uninstall}.ps1`.

1. **Probe it on real Windows first.** Run the *Probe winget candidates* workflow (Actions tab,
   *Run workflow*) with the winget ID, a DisplayName regex and optionally a vendor URL. It prints
   the installer type, whether `--scope user` works, a timed install -> detect -> uninstall cycle
   and, for a URL, its SHA-256 and Authenticode signer. Reject anything not provably silent.
2. Write `docs/apps/<id>.json` and add `<id>` to `"apps"` in `docs/catalog.json`:

   ```
   id, label, description, order (>= 100), scope: "user" | "machine", requires: [module ids]
   source   {type:"winget", id:"Publisher.Package"}
            {type:"url", url:"https://...", sha256?:hex64, signer?:regex, args:[...], timeoutSec?}
            {type:"bundled", file:"name.exe", sha256?:hex64, signer?:regex, args:[...], timeoutSec?}
   detect   [ {type:"file", path:"%ProgramFiles%\..."} | {type:"arp", displayName:regex, publisher?:regex} ]
   uninstall {type:"winget"} (winget source only) | {type:"exe", path:"%ProgramFiles%\...", args:[...]}
   ```

   winget installs always run with `--source winget --exact --silent`; the package ID is the pin
   and winget verifies the manifest hash. A URL source must pin `sha256` and/or `signer` and is
   verified before it is run. Detect with files when possible: winget can leave stub registry
   entries behind (VLC), which would make a registry check say "installed" after removal.
3. Add `tests/fixtures/app-<id>.json` (`_ci.removeApps` removes an app the runner image ships,
   `_ci.expectApp` is `fresh` or `existing`, `_ci.expectElevated` lists modules that must finish
   in the elevated child) and list it in `validate.yml`'s matrix. `check-catalog` validates the
   schema and these files; regenerate goldens with `--update-goldens` and review the diff.

**Behavior.** An app that is already installed is left alone and not recorded; uninstall only
removes apps recorded in `apps-state.json` (`%ProgramData%\Appinstaller` for machine scope,
`%LOCALAPPDATA%\Appinstaller` for user scope). Machine-scope apps share the one elevated child, and
UAC appears only if something actually needs installing.

**Known tradeoffs.**
- URL sources are version-pinned (VLC pins 3.0.23 by SHA-256): bump `url` and `sha256` together
  when the vendor releases; nothing flags a stale pin yet.
- winget must exist on the target PC (Windows 10 without *App Installer* may lack it); without it
  a winget app fails closed with a message and a non-zero exit.
- The verified installer sits in `%TEMP%` until launched (same trust model as the elevated child
  re-running the on-disk `.cmd`).

## Bundles and secrets

A build is normally two self-contained `.cmd` files. When it needs files (a `file` option, e.g. a
`bundled` app's installer) or has a `secret` value, the download is one zip instead:

```
<Name>/Install-<Name>.cmd
<Name>/Uninstall-<Name>.cmd
<Name>/files/<installer>.exe     (bundled app installers)
<Name>/files/secrets.json        (secret values)
```

Extract the whole zip (right-click, *Extract All*) and run `Install-<Name>.cmd` from the extracted
folder. Running it straight from inside the zip fails with a message saying so. The zip is built by
`docs/render-core.js` (no compression, fixed timestamps), so the browser and Node produce the same
bytes and `tests/golden.json` pins its hash.

- **Bundled installers** are checked against the app's pinned SHA-256 when the zip is generated,
  and again on the target PC: the file is copied to `%TEMP%`, the copy is verified (SHA-256 and/or
  signer), unblocked and run. Detect, re-run, uninstall and fail-closed work as for `url` apps.
- **Secrets** never go into a `.cmd`. The embedded config lists only their key names; the values
  are in `files/secrets.json`, read by each phase at run time and passed to the module as normal
  options. Every log line and popup masks them as `********`. **The zip contains the secret: don't
  share or commit it, and delete it after installing.** Secret options can't have a `default` or a
  URL prefill (`param`).
- **Key-pattern guard:** `node tests/check-secrets.mjs` (CI, after `--self-test`) fails on anything
  that looks like a real key, password or token in tracked files or rendered output, including the
  decoded embedded config. Use `{{PLACEHOLDER}}` values in fixtures and docs.

## Enabling Pages

One-time setup: **Settings → Pages → Source: GitHub Actions**. The `pages.yml` workflow deploys
`docs/` on every push to `main`.

## Local testing

```
node tests/check-catalog.mjs                       # any OS (add --update-goldens after an intended output change)
node tests/browser.mjs                             # any OS; needs `npm ci` and Chromium
node tools/render.mjs tests/fixtures/default.json out
pwsh ./tests/Run-Scenario.ps1 -Fixture tests/fixtures/default.json   # Windows only; changes the machine
```

`render.mjs` produces `out/Install-Example Site.cmd` and `out/Uninstall-Example Site.cmd` from
the fixture. `Run-Scenario.ps1` is what CI runs: it actually installs, re-runs twice, uninstalls,
and asserts state at each point, so only run it on a disposable machine.

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
- The Chrome module only ever installs Chrome for the user who runs the file. Run it as the
  person who will use the computer, not from an admin account.
