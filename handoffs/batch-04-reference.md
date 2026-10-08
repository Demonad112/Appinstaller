> This file was compiled by an assistant from a prior conversation on this
> project. Treat it as background material, not verified fact — reason
> independently before relying on anything here, especially items presented
> as correct, decided, or working. It's meant to bring a new collaborator up
> to speed, not to define how they should proceed.

# Reference: Appinstaller batch 4 (bundle output, `bundled` source, secrets, key-pattern guard)

## Quick Recap
Appinstaller (`Demonad112/Appinstaller`) is a GitHub Pages site that renders a self-contained Windows `.cmd`
(batch/PowerShell 5.1 polyglot) from a module catalog, for setting up family PCs. Batch 4 added a second output
shape: when a build carries files or secrets, the download is one deterministic zip
(`<Name>/Install-<Name>.cmd`, `Uninstall-<Name>.cmd`, `files/...`) instead of two loose `.cmd` files. It also added
a `bundled` app source (installer shipped inside the zip, SHA-256/signer-verified on the target), `secret` options
(values only in `files/secrets.json`, masked in logs), and a Linux key-pattern CI guard. PR Demonad112/Appinstaller#10
merged on 2026-10-03 as `3f08b16` (head `7a1b420`). Every CI job was green on that head: `catalog`, `browser`, the
13 earlier scenarios and the 3 new ones. No handoff or Batch 5 prompt file has been committed yet; this file and
the chat prompt are the handoff. Next up is batch 5 (Office/ODT), and the license type is still undecided.

## Working Context

### Where things live
- Local clone: `C:\Users\Addy7\Projects\Work\Appinstaller`. The session started in the unrelated SetupKit repo
  (`C:\Users\Addy7\Projects\Work\App Install`, `Demonad112/setupkit`); Appinstaller had no local checkout before this.
- Repo-local git identity was set to `Addy7 <addynetgrp@gmail.com>`, copied from SetupKit. No global identity exists
  on this PC, so commits fail without it.
- Uncommitted in the clone: `.claude/settings.json` (a read-only permission allowlist) and this file.
- The local branch `batch-04-bundle-secrets` still exists, and local `main` may be behind origin (`git pull`).
- PR #9 (batch 3 docs and handoffs) was merged at the start of this session, after its slow Adobe job finished green.

### Decisions and reasoning (all owner-approved in plan mode; worth re-checking against the code)
- **Zip only when needed.** Builds with no file or secret payload stay two `.cmd` downloads, so existing goldens
  changed only through the `common.ps1` change. A zip means one thing for a family member to carry, and the layout
  can't get split up.
- **Zip writer in `docs/render-core.js`** (STORE, CRC32, fixed 1980-01-01 timestamps, UTF-8 flag, fixed entry order).
  No dependency, and browser and Node produce identical bytes. render-core is still the only assembler.
- **New option type `file`.** Bytes go into `files/<fileName>` and never into the config. It is generic, so
  chrome-data (batch 6) could reuse it.
- **`bundled` source**: `{type:"bundled", file, sha256?, signer?, args, timeoutSec?}`. `expandCatalog` adds a
  required `installer` file option. The SHA-256 is checked at generate time, an early error in the browser or Node,
  and again on the target: copy to `%TEMP%`, verify the copy, `Unblock-File`, run. The run path is shared with `url`
  through `Invoke-VerifiedInstaller`.
- **Secrets = a file in the zip** (owner's choice over prompting at install time). The config carries key names only
  (`secrets: {moduleId: [keys]}`). `Import-AppiSecrets` in `common.ps1` runs at the top of `Invoke-Appinstaller`
  in both phases, merges values into `$Config.modules.<id>.<key>` and fails closed if the file or a value is missing.
  `Write-Log` and `Show-Result` mask values via `Protect-AppiText`. check-catalog rejects `default` and `param` on
  `secret` and `file` options.
- **Hidden test items** (owner's choice): `"test": true` on a module or app hides it unless the page URL has
  `?test=1`, which `tests/browser.mjs` uses. The two items are `test-secret` (stores only the SHA-256 of the value
  in `HKCU\Software\Appinstaller\TestSecret` and deliberately logs the value so masking is proven) and app
  `7zip-bundled`.
- **The test binary is committed** (owner's choice): `tests/assets/7z2603-x64.exe`. Its SHA-256 matched both
  www.7-zip.org and the winget-pkgs manifest for `7zip.7zip` 26.03. It is not Authenticode-signed, so only the
  SHA-256 is pinned. `tests/` is not published by Pages.
- **App helper dedup**: shared helpers moved to `docs/modules/app/common.ps1`. `fragmentFiles(catalog, ids, kind)`
  plus `joinFragment()` replaced `fragmentIds()`, and both loaders use them.
- **Goldens**: every golden changed once, for the `common.ps1` splice. The diff against `main` was reviewed: non-app
  outputs differ only by the new `$BundleDir`, `Protect-AppiText` and `Import-AppiSecrets` lines. Goldens now have
  `install`, `uninstall` and `zip` (null when there is no bundle).

### Tests and CI
- Linux `catalog` job: `check-catalog.mjs`, `check-secrets.mjs --self-test`, then `check-secrets.mjs`.
- `browser` job: 16 fixtures; a zip build compares the zip download with Node and golden, otherwise the `.cmd` files.
- Windows matrix: 16 scenarios. New ones: `app-7zip-bundled` (removeApps 7zip; elevated), `app-bundled-tampered`
  (flips the last byte of the bundled exe after extraction; expects exit 1 and `SHA-256 mismatch`; nothing installed),
  and `test-secret` (`_ci.assertAbsent` canary `{{CI_CANARY_SECRET}}` must not appear in the `.cmd` files or logs).
- `Run-Scenario.ps1` extracts a zip with `Expand-Archive` into `out/bundle` and runs from there.
- Local Windows checks before the push: all checks plus `browser.mjs` passed, the zips extracted, and all four
  payloads parsed with 0 errors through `[Parser]::ParseInput`. PSScriptAnalyzer is not installed locally, so CI
  ran it. No real install was run on the laptop.
- Your CLAUDE.md says to run `gh pr checks --watch`, but the desktop app's Auto-fix monitor took over CI watching,
  so it wasn't polled manually.

### Open items carried forward (not done in batch 4)
- No user-scope app exists, so the `%LOCALAPPDATA%` `apps-state.json` path isn't exercised in CI.
- VLC's pinned URL and SHA-256 have no freshness check.
- `%ProgramData%\Appinstaller\apps-state.json` is user-writable, so a forged record could make an elevated
  uninstall remove a pinned app (low risk while family members are admins).
- No install-time secret prompt.
- No CI case for running the `.cmd` from inside an unextracted zip (it takes the same throw path as a missing file).
- No signer-only `bundled` app has been tested (7-Zip is hash-only).
- Still unproven from earlier batches: UAC-declined path, another admin's credentials, winget missing on a real PC.

## Deep Reference

### render-core API (docs/render-core.js)
- `expandCatalog(raw, appDefs)`: app modules gain `options` (a bundled app gets
  `{key:'installer', type:'file', required:true, fileName: source.file}`) and `test: true` when set.
- `fragmentFiles(catalog, ids, kind)` returns `{ [frag]: ['modules/<f>/<kind>.ps1'] }`, or for shared fragments
  `['modules/app/common.ps1', 'modules/app/<kind>.ps1']`. `joinFragment(texts)` joins them with a blank line.
- `optionKeys(catalog, id, type)`; `iconKeys` is now a wrapper around it.
- `moduleRuntime` strips `file` and `secret` keys. `runtimeConfig(catalog, ids, modules, config)` adds `secrets`
  key names only when there are any.
- `async renderOutputs({installCore, uninstallCore, common, catalog, installFragments, uninstallFragments, config})`
  returns `{baseName, install, uninstall, zip|null}`. File option values must be `Uint8Array`; secret values are
  strings.
- `zipStore(entries)` and `async sha256Hex(bytes)` use `crypto.subtle`, so the page needs a secure context
  (https or localhost; `file://` won't work).
- `tools/render.mjs` `renderAll()` is now async. A fixture's `file` option value is a repo-relative path. A bundle
  writes only `out/<base>.zip` and appends `BUNDLE_ZIP_PATH` to `GITHUB_ENV`.

### Target-side flow (PowerShell 5.1)
- `common.ps1`: `$BundleDir = Split-Path -Parent $SELF`. The elevated child re-runs the same `.cmd`, so it uses the
  same folder.
- `Import-AppiSecrets` reads `$BundleDir\files\secrets.json` (UTF-8). Each value is added to
  `$script:AppiSecretValues` and to `$Config.modules.<id>` with `Add-Member -Force`.
- `Install-AppBundled` rejects a `file` value containing path parts. If the file is missing, it throws "Extract the
  whole zip first (right-click it, Extract All)...". Otherwise it copies to `%TEMP%\Appinstaller-<guid>-<name>` and
  calls `Invoke-VerifiedInstaller $App $exe 'Bundled'`, which checks SHA-256 and the signer, runs `Unblock-File`,
  runs `Invoke-AppNative` and accepts exit 0 or 3010.

### Schema additions (tests/check-catalog.mjs)
- `OPTION_TYPES` adds `file`. A file option needs `fileName` matching `^[A-Za-z0-9][A-Za-z0-9._-]*$`; other types
  must not have one.
- `APP_KEYS` adds `test`. For a bundled source the allowed keys are `type, file, sha256, signer, args, timeoutSec`;
  `file` must end in `.exe` or `.msi`; at least one of sha256/signer is required. Bundled file names must be unique
  across apps.
- A shared-fragment module also requires `docs/modules/<frag>/common.ps1`.

### Key-pattern guard (tests/check-secrets.mjs)
Patterns: private-key block, AWS `AKIA/ASIA`, GitHub `gh?_` / `github_pat_`, Slack `xox?-`, Google `AIza` + 35
characters, `sk-` (incl. `ant-` / `proj-`), Stripe `sk_live_` / `rk_live_`, JWT, a 5×5 product key (no I or O),
and `password|passwd|pwd|secret|token|api_key|client_secret` followed by `=` or `:` and a quoted literal of 6 or more
characters that isn't `{{UPPER_SNAKE}}` and doesn't start with `$ % { (`. Binary files (any NUL byte) are skipped.
The self-test builds its samples by string concatenation, so the repo itself stays clean. During development it
caught a Google sample that was one character short.

### Pins
- `7z2603-x64.exe`: 1,661,239 bytes, sha256 `0859c524b8a63551848f0c246abddcb1d0b7b656b0fbfe879f8d85e61a9e6edd`,
  winget manifest `7zip.7zip` 26.03 (installer type exe, `https://www.7-zip.org/a/7z2603-x64.exe`).
  On this laptop, `winget show` with no filter picks the 26.03 MSI (`c0680064…`).
- `7zip-bundled` detect: `%ProgramFiles%\7-Zip\7z.exe`; uninstall: `%ProgramFiles%\7-Zip\Uninstall.exe /S`.

### CI runs
- `Validate installer` on PR #10: runs 37123257716 and 37123844016, both successful. The `custom` job is skipped
  outside `workflow_dispatch`.

### Permission allowlist added (uncommitted, Appinstaller/.claude/settings.json)
- PowerShell: `Select-String`, `Get-Content`, `Get-ChildItem`, `Test-Path`, `Get-CimInstance`, `Get-Item`,
  `Get-Process`, `Get-ItemProperty`, `Get-PSDrive`, `Get-WinEvent`.
- Bash: `reg query`, `tasklist`.
- Read-only MCP tools: Claude_Browser `get_page_text` / `read_page` / `read_console_messages` / `find` / `preview_*`
  read tools, `computer-use` `screenshot`, `ccd_pr` `get_status`, chrome-devtools `take_screenshot`, and one
  `search_files` tool.
