> This file was compiled by an assistant from a prior conversation on this
> project. Treat it as background material, not verified fact — reason
> independently before relying on anything here, especially items presented
> as correct, decided, or working. It's meant to bring a new collaborator up
> to speed, not to define how they should proceed.

# Reference: Appinstaller batch 3 (curated apps as data)

## Quick Recap
Batch 3 added data-driven curated apps: `docs/apps/<id>.json` entries become catalog modules `app-<id>` that share one
install/uninstall fragment. 7-Zip and Adobe Reader install via winget, VLC via a hash-pinned URL. PR Demonad112/Appinstaller#8
(head `1d8d252`, all CI green, merged as `54ec22a` on 2026-10-02) shipped it. Docs, the probe URL fix and the batch-3
handoff / batch-4 prompt files were still outstanding at merge time and are not in that PR.

## Working Context
- Expansion: `catalog.json` lists `"apps": [...]`; `expandCatalog(catalog, appDefs)` (render-core.js, shared by browser and Node)
  synthesises `{id:'app-<id>', label, description, order, scope, requires, default:false, options:[], fragment:'app', app:<def>}`.
  `assemble()` emits the shared fragment once, then `$Modules += New-AppModule -Id 'app-<id>'` per app. The app definition
  (id, label, scope, source, detect, uninstall) rides in the runtime config as `modules['app-<id>'].app`.
- Engine semantics: detect-first; machine-scope `NeedsAdmin = not detected` (no UAC when nothing to do; N apps = one UAC);
  throws if machine scope and not admin; after install it polls for detection (`Wait-AppDetected`, 90 s) because NSIS
  installers/uninstallers detach; records `apps-state.json`; uninstall only removes recorded apps.
- Schema (`docs/apps/<id>.json`): `source` = `{type:winget,id}` | `{type:url,url,sha256?,signer?,args[],timeoutSec?}`
  (>=1 of sha256/signer); `detect` = list of `{type:file,path}` / `{type:arp,displayName,publisher?}` (env-var-rooted paths);
  `uninstall` = `{type:winget}` (winget source only) | `{type:exe,path,args[],timeoutSec?}`. Unknown keys are errors.
- Tests: `node tests/check-catalog.mjs [--update-goldens]`, `node tests/browser.mjs`; fixture `_ci` keys added: `removeApps`,
  `preinstallApps`, `expectApp` (fresh|existing), `corruptSha256`, `expectElevated` (true or list of module ids).
  `Run-Scenario.ps1` routes `app-*` ids to `tests/modules/app.Verify.ps1 -AppId`.
- Probe facts (windows-latest, Windows 10.0.26100, winget 1.11.510, pwsh 7.6): 7-Zip 26.03 is preinstalled on the image; winget
  7zip.7zip = NSIS exe, machine only, install ~6 s, uninstall ~2 s; VLC 3.0.23 install ~22 s, `winget uninstall VideoLAN.VLC` exits 0
  without removing it; Adobe.Acrobat.Reader.64-bit installs and uninstalls (~38 s) cleanly; second `winget install` returns 0x8A15002B;
  `winget uninstall` stalls on the msstore source agreement unless `--accept-source-agreements` is passed.

## Deep Reference
### Files added/changed
`docs/apps/{7zip,vlc,adobe-reader}.json`, `docs/catalog.json`, `docs/render-core.js`, `docs/app.js`, `tools/render.mjs`
(`loadRawCatalog`, `loadAppDefs`, `loadCatalog` now expanded), `docs/modules/app/{install,uninstall}.ps1`, `tests/check-catalog.mjs`,
`tests/browser.mjs`, `tests/Run-Scenario.ps1`, `tests/Set-App.ps1`, `tests/modules/app.Verify.ps1`, `tests/fixtures/app-*.json`,
`tests/golden.json`, `.github/workflows/{validate,probe-winget}.yml`, `tools/Probe-Winget.ps1`.

### VLC pin
url `https://download.videolan.org/pub/videolan/vlc/3.0.23/win64/vlc-3.0.23-win64.exe`,
sha256 `20ad191348684b470ddc4e05204316f3d8e39655f412b3e392a0eef97639daaf` (vendor-published `.sha256`; CI confirmed the download matches).
Detect is file-only (`%ProgramFiles%[ (x86)]\VideoLAN\VLC\vlc.exe`) because winget leaves an HKCU ARP stub. Uninstall: NSIS
`uninstall.exe /S`, polled until gone.

### CI bugs found and fixed during the batch (history for similar harness work)
1. Probe: a variable named `$id` shadowed the `-Id` parameter (PowerShell is case-insensitive); exit-code hex formatting overflowed on negative codes.
2. `Run-Scenario.ps1`: `$(if ($ci) { $ci.expectElevated })` unrolled `["app-7zip"]` to a scalar string, so `Assert-Phase` fell back to checking `ublock-lite`.
3. Engine: ExitCode blank in PS 5.1 after timed wait (fixed with `$p.Handle` + second `WaitForExit()` + throw if null).
4. Verify idempotency counted driver echo lines; the engine now logs a unique `Installed <label> (<source>).` line and Verify counts only that.

### Outstanding checklist (as of this file)
README "Adding an app"; CLAUDE.md (layout: `docs/apps/`, `app-<id>`, `fragment`, `tests/Set-App.ps1`, probe workflow); fix probe VLC URL
(`probe-winget.yml` still points at `get.videolan.org/.../3.0.21`, which serves HTML);
`handoffs/batch-03-handoff.md`; `handoffs/batch-04-prompt.md` (bundle output + `bundled` source + secrets + key-pattern CI guard).
