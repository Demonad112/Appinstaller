# Batch 6 prompt: chrome-data + Capture-Profile.cmd

Start a fresh session in `C:\Dev\projects\Appinstaller`. Read `CLAUDE.md`, `handoffs/batch-05-handoff.md`,
`handoffs/batch-04-handoff.md` and `handoffs/batch-05-reference.md` (which holds the batch 6 plan).

Goal: add the `chrome-data` module (reusing the generic `file` option and the zip output from batch 4) and a
`Capture-Profile.cmd` helper. Hard limits from CLAUDE.md: never move Chrome passwords or cookies, never sign anyone
into Chrome/Office, no secrets in the repo.

Workflow: branch `batch-06-chrome-data`, draft PR, module ships install, uninstall, Verify script, fixture and a
`validate.yml` matrix entry. Run `node tests/check-catalog.mjs`, `check-secrets.mjs` and `browser.mjs` before each commit.
Merge only when CI is green, then write `handoffs/batch-06-handoff.md` and `batch-07-prompt.md`.
Before starting, produce a plan first and wait for approval.
