# Appinstaller: notes for Claude sessions

Generates a self-contained Windows `.cmd` (batch/PowerShell 5.1 polyglot) from a module catalog.
The site is static (`docs/`, GitHub Pages from `main`). Windows CI is the only proof an install works.

## Layout
- `docs/catalog.json` modules (`id, label, description, order, needsAdmin, requires`)
- `docs/render-core.js` the ONE assembler; browser (`docs/app.js`) and Node (`tools/render.mjs`) both import it
- `docs/core/{installer,uninstall}-core.ps1` helpers, config decode, elevation, module runner
- `docs/modules/<id>/{install,uninstall}.ps1` fragments
- `tests/` `check-catalog.mjs` (Linux), `Run-Scenario.ps1` (Windows), `modules/<id>.Verify.ps1`, `fixtures/*.json`
- `handoffs/` per-batch handoff + next-batch prompt; the plan lives in the latest handoff

## Module contract
A fragment appends `{ Id; NeedsAdmin = {param($Cfg)}; Install = {param($Cfg,$Ctx)} }` to `$Modules`
(`Install` returns user-facing lines). Uninstall fragments: `{ Id; Uninstall = {param($Cfg)} }`.
Modules writing per-user state (HKCU, Desktop, `%LOCALAPPDATA%`) must never need elevation.
State and logs live in `%LOCALAPPDATA%\Appinstaller` (migrated from the old `MomSetup`).

## Rules
- Each core placeholder (`__CONFIG_B64__`, `__MODULES__`) appears exactly once per core, comments included.
- Installs are idempotent, have an uninstall path, and verify downloads by Authenticode signer or SHA-256.
- Admission for a new app: pinned winget ID (`--source winget`) or signature/hash-checked URL, a detect step, an uninstall, proven on windows-latest.
- Every module ships install, uninstall, a Verify script, a fixture and a matrix entry in `validate.yml`.
- The polyglot header is a single line ending in an errorlevel passthrough; `chrome-blocked` proves a failure exits non-zero.
- Secrets: never write keys, passwords or credentials into the repo, fixtures, logs or replies; use `{{PLACEHOLDER}}`.
- Do not automate signing anyone into Office/Chrome, or moving Chrome passwords/cookies.

## Commands
- `node tests/check-catalog.mjs` before every commit
- `node tools/render.mjs tests/fixtures/<name>.json out` render a fixture
- Windows only: `./tests/Run-Scenario.ps1 -Fixture tests/fixtures/<name>.json`

## Workflow
One branch + draft PR per batch (`batch-NN-<topic>`). Merge only when CI is green, then add
`handoffs/batch-NN-handoff.md` and `handoffs/batch-NN+1-prompt.md`.
