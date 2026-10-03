# Appinstaller: notes for Claude sessions

Generates a self-contained Windows `.cmd` (batch/PowerShell 5.1 polyglot) from a module catalog.
The site is static (`docs/`, GitHub Pages from `main`). Windows CI is the only proof an install works.

## Layout
- `docs/catalog.json` modules (`id, label, description, order, scope, requires, options`, optional `fileNameFrom`)
- `docs/render-core.js` the ONE assembler; browser (`docs/app.js`) and Node (`tools/render.mjs`) both import it
- `docs/core/common.ps1` shared helpers + two-phase driver, spliced into both cores at the common placeholder
- `docs/core/{installer,uninstall}-core.ps1` config decode + entry point
- `docs/modules/<id>/{install,uninstall}.ps1` fragments
- `docs/apps/<id>.json` curated apps (listed in `catalog.json` `"apps"`); `expandCatalog()` turns each into module `app-<id>` that shares `docs/modules/app/{common,install|uninstall}.ps1` (`fragment: "app"`, emitted once via `fragmentFiles()`, one `$Modules += New-AppModule -Id ...` line per app). Sources: `winget`, `url`, `bundled` (installer shipped in the zip's `files/`)
- Output: `renderOutputs()` returns the two `.cmd` texts, plus one deterministic zip (`zipStore`) when a build has `file` options or `secret` values; goldens pin `install`, `uninstall`, `zip`
- `"test": true` (module or app) = CI-only item, shown on the site only with `?test=1`: `test-secret`, `7zip-bundled` (installer committed as `tests/assets/7z2603-x64.exe`)
- `tools/Probe-Winget.ps1` + `.github/workflows/probe-winget.yml` admission probe: run it before writing an app JSON
- `tests/` `check-catalog.mjs` (Linux; schema + golden hashes), `browser.mjs` (Playwright), `Run-Scenario.ps1` (Windows), `modules/<id>.Verify.ps1`, `fixtures/*.json`, `golden.json`
- `handoffs/` per-batch handoff + next-batch prompt; the plan lives in the latest handoff

## Module contract
A fragment appends `{ Id; NeedsAdmin = {param($Cfg)}; Install = {param($Cfg,$Ctx)} }` to `$Modules`
(`Install` returns user-facing lines). Uninstall fragments: `{ Id; NeedsAdmin; Uninstall = {param($Cfg)} }`.
`scope` (catalog) is `user` or `machine`. User modules run in-process as the real user and write
per-user state (HKCU, Desktop, `%LOCALAPPDATA%`). Machine modules run in the elevated child
(`--phase machine --run <guid>`, result via `%ProgramData%\Appinstaller\run-<guid>\result.json`)
when `NeedsAdmin` returns true (absent = always). User modules run first, so a user module may not
`require` a machine module (enforced). The parent holds the `Global\Appinstaller.run` mutex.
Options are catalog data (`options`); the UI and validation are generated, never hand-written.
`secret` values and `file` bytes never enter a `.cmd`: they go to the zip's `files/` (`secrets.json`);
the config lists secret key names only, `Import-AppiSecrets` (common.ps1) merges the values into
`$Cfg` at run time and `Write-Log`/`Show-Result` mask them. State and logs live in
`%LOCALAPPDATA%\Appinstaller` (migrated from the old `MomSetup`).

## Rules
- Each core placeholder (`__COMMON__`, `__CONFIG_B64__`, `__MODULES__`) appears exactly once per core, comments included, and never in `common.ps1`.
- Installs are idempotent, have an uninstall path, and verify downloads by Authenticode signer or SHA-256.
- Admission for a new app: pinned winget ID (`--source winget`) or signature/hash-checked URL, a detect step, an uninstall, proven on windows-latest.
- Every module ships install, uninstall, a Verify script, a fixture and a matrix entry in `validate.yml`. An app ships its JSON, `tests/fixtures/app-<id>.json` and a matrix entry (Verify is the shared `tests/modules/app.Verify.ps1`).
- App helpers live in `docs/modules/app/*`, not `common.ps1`, so existing goldens stay byte-identical. Uninstall removes only apps recorded in `apps-state.json`. Native exit codes: use `Invoke-AppNative` (PS 5.1 leaves `ExitCode` empty without the cached handle and `[int]$null` is 0).
- The polyglot header is a single line (`@set "APPI_ARGS=%*"` first) ending in an errorlevel passthrough; `chrome-blocked` proves a failure exits non-zero.
- Rendered output is pinned by `tests/golden.json`; after an intended change run `node tests/check-catalog.mjs --update-goldens` and review the diff. `tests/browser.mjs` proves the website download equals the Node render.
- Secrets: never write keys, passwords or credentials into the repo, fixtures, logs or replies; use `{{PLACEHOLDER}}`. `tests/check-secrets.mjs` (CI) enforces it on tracked files and rendered output (decoded config included); `--self-test` proves each pattern still fires.
- Do not automate signing anyone into Office/Chrome, or moving Chrome passwords/cookies.

## Commands
- `node tests/check-catalog.mjs`, `node tests/check-secrets.mjs` and `node tests/browser.mjs` before every commit (`npm ci` first)
- `node tools/render.mjs tests/fixtures/<name>.json out` render a fixture
- Windows only: `./tests/Run-Scenario.ps1 -Fixture tests/fixtures/<name>.json`

## Workflow
One branch + draft PR per batch (`batch-NN-<topic>`). Merge only when CI is green, then add
`handoffs/batch-NN-handoff.md` and `handoffs/batch-NN+1-prompt.md`.
