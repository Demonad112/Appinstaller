> Compiled by an assistant from the session. Background, not verified fact: reason independently
> and check against the code before relying on it. Deeper detail: `handoffs/batch-05-reference.md`.

# Batch 5 handoff: Microsoft 365 via the Office Deployment Tool (PR Demonad112/Appinstaller#12, merged as `a214be4`)

## Quick recap
Batch 5 added `office` (Word, Excel, PowerPoint, Outlook; subscription, no product key, no secret, no zip).
PR #11 (`aee01a9`) first added the admission probe `tools/Probe-Office.ps1` + `probe-office.yml`. PR #12 added a new
`odt` source and uninstall type and a `c2r` detect type. CI on the merged head was all green, including
`scenario (app-office)` (6m57s) and the earlier scenarios. Existing non-app goldens did not change; app goldens
changed because `docs/modules/app/common.ps1` changed.

## Decisions
- ODT instead of winget: the winget `Microsoft.Office` manifest installs the enterprise product and its pinned
  installer hash was already stale.
- `setup.exe` is re-issued by Microsoft, so it is pinned by Authenticode signer (`CN=Microsoft Corporation`), not hash;
  the signature is checked before launch.
- Product `O365HomePremRetail`; ExcludeApp: Access, Groove, Lync, OneDrive, OneNote, Publisher, Teams, Bing.
- Detect via ClickToRun `ProductReleaseIds`, so OEM-preinstalled Office is skipped, never recorded, never removed.
- The setup never signs anyone in; each person signs in themselves.

## What changed
`docs/modules/app/{common,install,uninstall}.ps1` (`Invoke-AppOdt`, `c2r` detect), `docs/apps/office.json`,
`docs/catalog.json`, `tests/check-catalog.mjs` (odt/c2r schema), `tests/modules/app.Verify.ps1`, `tests/Set-App.ps1`,
`tests/fixtures/app-office.json`, `tests/golden.json`, `.github/workflows/validate.yml`, `tools/Probe-Office.ps1`.

## Caveats / untested
- `app-office` costs about 7 min and 4.3 GB per PR; consider running it only for PRs touching Office files.
- `Set-App.ps1` has no `odt` remover (throws if Office is already present; the runner image has none).
- A real PC with an existing Office licence/edition other than `O365HomePremRetail` is detected as "not installed"
  and would get Microsoft 365 added alongside; not tested.
- Still unproven from earlier batches: user-scope app state path, UAC-declined path, winget missing on a real PC,
  `apps-state.json` forgery in a user-writable ProgramData folder.
- PS 5.1 bare-parse of `common.ps1` errors on an existing non-ASCII line; harmless in rendered output (PS7 parses fine).
