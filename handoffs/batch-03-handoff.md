> Compiled by an assistant from the session. Background, not verified fact: reason independently
> and check against the code before relying on it. Deeper detail: `handoffs/batch-03-reference.md`.

# Batch 3 handoff: curated apps as data (PR Demonad112/Appinstaller#8, merged as `54ec22a`)

## Quick recap
Batch 3 added `docs/apps/<id>.json` curated apps. Each becomes a catalog module `app-<id>` that shares one
install/uninstall fragment, so there is no per-app PowerShell. First apps: 7-Zip and Adobe Reader (winget),
VLC (URL, vendor SHA-256). CI on the merged head `1d8d252`: `catalog`, `browser`, the 7 original scenarios and
the 6 new ones (`app-7zip`, `app-7zip-present`, `app-vlc`, `app-adobe-reader`, `app-blocked`, `app-tampered`) all green.
The 7 original goldens did not change; new goldens were additions only. Docs, the probe URL fix and this handoff
landed in the follow-up PR Demonad112/Appinstaller#9.

## Decisions
- One catalog module per app (not one `app` module + multiselect): scope, `requires` and failure reporting are per
  module in the two-phase core, so per-app scope needed no core change and no new elevation path.
- App helpers live in `docs/modules/app/*`, not `common.ps1`, to keep the existing goldens byte-identical.
- Install is detect-first; uninstall only removes apps recorded in `apps-state.json` (ProgramData for machine
  scope, LOCALAPPDATA for user scope); a pre-existing app is never removed.
- No `--scope` on winget (7-Zip fails 0x8A150010; VLC would install a portable zip).
- VLC uses a URL source so both source types are proven by real apps; its detect is file-only because winget
  leaves an HKCU ARP stub behind.

## What changed
`docs/render-core.js` (`expandCatalog`, `fragmentIds`, shared-fragment `assemble`), `tools/render.mjs`, `docs/app.js`,
`docs/modules/app/{install,uninstall}.ps1`, `docs/apps/*.json`, `tests/check-catalog.mjs` (app schema),
`tests/Run-Scenario.ps1` (`removeApps`, `preinstallApps`, `expectApp`, `corruptSha256`, list-valued `expectElevated`),
`tests/Set-App.ps1`, `tests/modules/app.Verify.ps1`, `tests/fixtures/app-*.json`, `tools/Probe-Winget.ps1`,
`.github/workflows/probe-winget.yml`, README "Adding an app", CLAUDE.md.

## Caveats / untested
- No user-scope app exists, so the engine's LOCALAPPDATA state path is not exercised in CI.
- UAC-declined path and a standard user supplying another admin's credentials: still unproven.
- winget missing on a real PC: fail-closed message only reasoned about, not run.
- VLC's pin (url + SHA-256) goes stale with each release and nothing flags it; the signer was never captured.
- `install.ps1` / `uninstall.ps1` duplicate ~80 lines of helpers (each core splices only its own fragment); fix both on change.
- `apps-state.json` under `%ProgramData%\Appinstaller\` sits in a folder the un-elevated parent creates, so it is
  user-writable; a forged record could make the elevated uninstall remove a pinned app listed in that `.cmd`.
- Each CI install run still takes ~30 s (result popup auto-dismiss); the Adobe job takes ~5 min.

## Next
Batch 4: `handoffs/batch-04-prompt.md`. Remaining after: 5 Office/ODT (ask license type first), 6 chrome-data +
Capture-Profile.cmd, 7 profiles, 8 tabs UI, 9 pro/AD bundle.
