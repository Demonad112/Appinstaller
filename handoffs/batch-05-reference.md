> This file was compiled by an assistant from a prior conversation on this
> project. Treat it as background material, not verified fact — reason
> independently before relying on anything here, especially items presented
> as correct, decided, or working. It's meant to bring a new collaborator up
> to speed, not to define how they should proceed.

# Reference: Appinstaller batch 5 (Microsoft 365 via the Office Deployment Tool)

## Quick Recap
Appinstaller (`Demonad112/Appinstaller`, local `C:\Dev\projects\Appinstaller`) is a GitHub Pages builder that
renders a self-contained Windows `.cmd` (batch/PowerShell 5.1 polyglot) for setting up family PCs. Batches 1-4 are
merged; `origin/main` is `53d8bab` (batch 4 merge `3f08b16` + a `.gitignore` commit + `handoffs/batch-04-reference.md`).
The last session answered the open batch-5 questions with the owner and proposed a plan, but no batch-5 code,
branch or probe exists yet. It also tidied folders: the unrelated SetupKit repo now lives at
`C:\Dev\projects\SetupKit` (kept, not in active use).

## Working Context

### Owner answers (2026-10-03)
- License: **Microsoft 365 subscription** (family). No product key, so no `secret` option, no zip, no
  `secrets.json` handling. Office is a plain app entry built as the usual two `.cmd` downloads.
- Apps: **Word, Excel, PowerPoint, Outlook** only (exclude the rest).
- `secrets.json` after a successful install: **keep it** (current behaviour; unrelated to Office now).

### Plan proposed last session (not yet approved — owner was asked "start with the probe?")
1. Probe first (`tools/Probe-Office.ps1` + a CI job, like `Probe-Winget`). Questions to answer:
   - Can winget's `Microsoft.Office` package take a custom configuration (e.g. `--override`)? If yes, a winget
     source might replace steps 2-3 entirely.
   - Install time and download size on `windows-latest` for `O365HomePremRetail`.
   - Which detect signals appear (file paths, `HKLM\SOFTWARE\Microsoft\Office\ClickToRun\Configuration`).
   - What a Remove leaves behind.
2. New app source type `odt` in `docs/modules/app/install.ps1`: download ODT `setup.exe`, verify it via the existing
   `Invoke-VerifiedInstaller` (signer pin), write a `configuration.xml` to `%TEMP%` from source fields
   (product, channel, language, excluded apps), run `setup.exe /configure <xml>`, delete the XML.
3. New uninstall type `odt`: same `setup.exe` with a `<Remove>` configuration.
4. `docs/apps/office.json`, machine scope, detect-first so OEM-preinstalled Office is skipped; uninstall only if
   recorded in `apps-state.json`.
5. Schema rules in `tests/check-catalog.mjs`, goldens regenerated (only app fragment should change), fixture
   `tests/fixtures/app-office.json`, matrix entry in `validate.yml`. One branch `batch-05-office` + draft PR.

### Constraints from the repo's CLAUDE.md worth keeping in view
- "Do not automate signing anyone into Office/Chrome." Each family member signs in after install to activate.
- Admission needs a pinned source verified by signer or SHA-256, a detect step, an uninstall, proven on windows-latest.
- App helpers belong in `docs/modules/app/*`, not `common.ps1`, so non-app goldens stay byte-identical.
- Before every commit: `node tests/check-catalog.mjs`, `node tests/check-secrets.mjs`, `node tests/browser.mjs`.

### Repo housekeeping state
- `handoffs/` has batch-01..04 files but **no `batch-04-handoff.md` and no `batch-05-prompt.md`** (the workflow
  describes one handoff + next prompt per batch). `batch-04-reference.md` is committed.
- `.claude/` is untracked and now gitignored (commit `71e0681`).
- A stale local branch `batch-04-bundle-secrets` probably still exists (merged).
- Committing directly to `main` worked (no branch protection rejected the push of `53d8bab`).

## Deep Reference

### Existing code the plan would build on (line numbers as of `53d8bab`; re-check)
- `docs/modules/app/install.ps1`
  - `:18` `Install-AppWinget` (`winget install --id ... --exact --source winget --silent ...`)
  - `:29` `Invoke-VerifiedInstaller` — SHA-256 and/or Authenticode signer check (`$sig.Status -eq 'Valid'` and
    subject `-match $s.signer`), then `Unblock-File`, `Invoke-AppNative`, accepts 0/3010
  - `:53` `Install-AppUrl`, `:71` `Install-AppBundled`
  - `:106-108` dispatch `switch` on `source.type` (`winget`/`url`/`bundled`) — an `odt` case would go here
- `docs/modules/app/uninstall.ps1:22` branches on `uninstall.type -eq 'winget'` (else exe)
- `tests/check-catalog.mjs`
  - `:105` url source keys `type, url, sha256, signer, args, timeoutSec`
  - `:112` a url/bundled source needs sha256 and/or signer — **signer-only is already allowed**
  - `:117` `source.type must be "winget", "url" or "bundled"`; `:144` `uninstall.type must be "winget" or "exe"`
- Example app JSONs: `docs/apps/vlc.json` (url + exe uninstall, with probe notes), `docs/apps/adobe-reader.json`
  (winget, arp detect).

### ODT facts recalled from general knowledge (unverified in this project; check before use)
- ODT bootstrapper URL often cited: `https://officecdn.microsoft.com/pr/wsus/setup.exe` (signed by Microsoft
  Corporation; changes frequently, hence signer pin rather than SHA-256).
- Consumer M365 product ID: `O365HomePremRetail`; business: `O365BusinessRetail`; enterprise: `O365ProPlusRetail`.
- Typical exclusions for "Word/Excel/PowerPoint/Outlook only": `Access`, `Publisher`, `OneNote`, `Groove`, `Lync`,
  `Teams`, `OneDrive` (decide whether OneDrive stays). Exact `ExcludeApp` IDs vary by product/version.
- Common config elements: `<Add OfficeClientEdition="64" Channel="Current">`, `<Language ID="MatchOS"/>`,
  `<Display Level="None" AcceptEULA="TRUE"/>`, `<Property Name="FORCEAPPSHUTDOWN" Value="TRUE"/>`.
- Many OEM Windows 11 images preinstall `O365HomePremRetail` in several languages; detect-first matters.
