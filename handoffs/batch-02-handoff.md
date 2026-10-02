> Compiled by an assistant from the session. Background, not verified fact: reason independently
> and check against the code before relying on it.

# Batch 2 handoff: scope, options schema, two-phase core (PR Demonad112/Appinstaller#4)

## Quick recap
Batch 2 added a `scope: user|machine` + `options` catalog schema, a data-driven configurator UI
(no per-module HTML/JS), and a two-phase core: the real user runs user-scope modules in-process,
then an elevated child runs machine-scope modules that need admin. CI on head `19f99c0`: `catalog`,
`browser` and scenarios `default`, `chrome-present`, `chrome-fresh`, `chrome-blocked`,
`default-icon`, `machine-scope`, `run-lock` all green. Status after this file: merged to `main`
once CI on the handoff commit is green.

## Decisions (owner + this session)
- One branch + draft PR per batch (`batch-NN-<topic>`); merge only on green CI; then handoff + next prompt.
- Family members are admins on their own PCs (UAC = a Yes click, same profile). `Appinstaller` naming.
- Office license type: still undecided, ask at the start of the Office batch (batch 5).
- ublock-lite is `scope: machine` with a dynamic `NeedsAdmin` (HKLM forcelist present), so UAC
  appears only when needed; the badge reads "may ask for admin".
- User modules run first, then the machine child; a user module may not `require` a machine module (enforced).
- `secret` option type exists in the enum but check-catalog rejects it until batch 4.

## What changed
- **Schema** (`docs/catalog.json`): `needsAdmin` removed; `scope`; `options: [{key,type,label,hint,default,required,pattern,values}]`
  plus `placeholder`, `maxLength`, `param` (query-string prefill: `?url=`, `?name=`), `sanitize: "filename"`;
  module-level `fileNameFrom` (download name). Icon option key is `iconB64`; Node fixtures give `iconPath`
  (generic rule: `<key minus B64>Path`). Validated in `tests/check-catalog.mjs`.
- **UI** (`docs/app.js`): `buildField`/`collectOptions` generate and read every field type; `index.html`
  has no module markup. Proven byte-identical: `tests/golden.json` was captured from the batch-1
  renderer and did not change in the schema/UI commit; `tests/browser.mjs` (Playwright, `browser` CI job)
  asserts browser download == Node render == golden for every fixture.
- **Core** (`docs/core/common.ps1`, spliced via `__COMMON__` into both cores): header is
  `@set "APPI_ARGS=%*" & @set "SELF=%~f0" & ...`. Parent takes mutex `Global\Appinstaller.run`
  (contended => popup + exit 1), shows a WinForms "please wait" notice (log-only fallback), runs user
  modules, then ALWAYS spawns `Start-Process $SELF --phase machine --run <guid> -Verb RunAs -Wait` for
  machine modules whose `NeedsAdmin` is true/absent. Child writes
  `%ProgramData%\Appinstaller\run-<guid>\result.json`; parent merges lines/failures, deletes the folder.
  Declined UAC / no result => modules "skipped", exit 1. Runtime config now carries `scopes`.
- **CI**: `_ci.seedHklmForcelist`, `_ci.expectElevated` (default false: every other scenario asserts it
  never elevated), `_ci.holdLock` + `_ci.expectLog`. Goldens regenerated deliberately in the core commit.
- **Docs**: `CLAUDE.md` + `README.md` updated (module contract, add-a-module checklist, commands).

## Caveats / untested
- UAC-declined path is not exercised in CI (needs a real prompt). Covered by code + a stubbed local smoke test.
- The elevated child runs as the SAME account; if a standard user supplies a different admin's
  credentials, per-user state in the child lands in that admin's profile (machine modules must not need it).
- `Deploy Pages` fails on every push to `main` (also before batch 1); README says Settings -> Pages ->
  Source: GitHub Actions must be enabled. Not touched by this batch; owner action.
- Each CI install run takes ~30 s because the result popup's 30 s auto-dismiss blocks in the runner session.
- A Linux `pwsh` 7.4 + PSScriptAnalyzer can be had in the sandbox (download the GitHub release tarball,
  `Install-Module PSScriptAnalyzer -Scope CurrentUser`) for parse/lint checks before pushing. It
  cannot run Windows APIs; Windows CI remains the only proof.
- Elevated child re-executes the `.cmd` from its on-disk (user-writable) location: same trust model as before.

## Next
Batch 3: generic `app` module + `docs/apps/*.json`. Prompt: `handoffs/batch-03-prompt.md`.
Remaining after that: 4 bundle output + `bundled` source + secrets + key-pattern CI guard; 5 Office/ODT
(ask license type first); 6 chrome-data + Capture-Profile.cmd; 7 profiles; 8 tabs UI; 9 pro/AD bundle.
