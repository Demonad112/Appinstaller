> Compiled by an assistant from the session. Background, not verified fact: reason independently
> and check against the code before relying on it.

# Batch 1 handoff: foundations (PR Demonad112/Appinstaller#2)

## Quick recap
Batch 1 added `CLAUDE.md`, fixed `.cmd` exit-code propagation with a CI negative test, renamed
`MomSetup` to `Appinstaller` (with migration), and did CI hygiene. CI run 36960938698 on head
`fb99523`: `catalog` plus `default`, `chrome-present`, `chrome-fresh`, `chrome-blocked`,
`default-icon` all green. Status after this file: merged to `main` once CI on the handoff commit is green.

## Decisions (owner, this session)
- One branch + draft PR per batch (`batch-NN-<topic>`); merge only on green CI; then handoff + next prompt.
- Rename `MomSetup` -> `Appinstaller` with migration (state/icons copied from the old folder once, in both cores).
- Family members are admins on their own PCs (UAC = a Yes click, same profile).
- Office license type: undecided, ask at the start of the Office batch.

## What changed
- Header (`docs/render-core.js` `buildPolyglot`): ends `& @if errorlevel 1 (exit /b 1) else (exit /b 0)`.
  `check-catalog.mjs` asserts the one-line header shape.
- `chrome-blocked` scenario: `_ci.blockHosts` (hosts file -> 127.0.0.1, restored in `finally`) +
  `_ci.expectExit: 1`; asserts non-zero exit and `Install finished with failures` in the log.
- `default-icon` scenario: `tests/assets/test.ico` through `iconPath`; Verify checks the `.lnk`
  icon comes from `Appinstaller\Icons`.
- CI: checkout/setup-node/upload-artifact v5, Node 22, concurrency group.

## Caveats / untested
- The original bug was inferred from logs, never reproduced before the fix. `chrome-blocked`
  proves the new header propagates failure; it does not prove the old header was the cause.
- PSScriptAnalyzer never ran locally (no pwsh in the container); CI lint is the check.
- `pages.yml` only had checkout bumped; configure-pages/upload-pages-artifact/deploy-pages are unchanged.
- Manual owner step: switch the repo default branch to `main`, then delete
  `claude/lightweight-installer-package-1mki2y`.

## Next
Batch 2 (scope + options schema, data-driven UI, two-phase user/machine core, run-twice lock,
progress notice). Full plan: `/root/.claude/plans/fluffy-dancing-spindle.md` is session-local, so the
batch list is reproduced in `handoffs/batch-02-prompt.md`.
