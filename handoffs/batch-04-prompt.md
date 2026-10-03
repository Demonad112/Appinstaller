Context: continuing Demonad112/Appinstaller, a GitHub Pages builder that renders a self-contained
Windows .cmd (batch/PowerShell 5.1 polyglot) from a module catalog. Read `CLAUDE.md`,
`handoffs/batch-03-handoff.md` and `handoffs/batch-03-reference.md` first (background, verify against the
code). Start in plan mode; ask blocking questions in a popup.

Workflow: one branch + draft PR per batch (`batch-NN-<topic>`; or the session's designated branch), subscribe to
PR activity, fix red CI, merge only when green, then write `handoffs/batch-NN-handoff.md` and
`handoffs/batch-NN+1-prompt.md` (layered recap + copy-paste prompt) and send both. If context gets large with
CI still red, put the failure and attempted fixes in the handoff and make "fix it first" step 1 of the next
prompt. Never write real keys/passwords anywhere; use `{{PLACEHOLDER}}`.
Tip: a Linux pwsh + PSScriptAnalyzer can be installed in the sandbox for parse/lint (tarball,
`DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1`); run new Windows behaviour through a `tools/Probe-*` style CI
job first, as batch 3 did with `tools/Probe-Winget.ps1`.

Owner decisions: family members are admins on their own PCs; Appinstaller naming; Office license type
still undecided (ask at the Office batch, 5).

BATCH 4: bundle output + `bundled` source + secrets + key-pattern CI guard.
1. Bundle output: decide in plan mode and justify how the generator can emit more than one `.cmd` (for
   example a folder/zip holding the installer plus files an app needs), and what the browser and Node renderers
   share (`docs/render-core.js` stays the ONE assembler; `tests/browser.mjs` must still prove
   browser == Node == golden for every output file).
2. `bundled` app source: an app whose installer ships inside the bundle (no download), verified by SHA-256 (and/or
   Authenticode signer) before it runs, with the same detect / idempotent re-run / uninstall / fail-closed
   behavior as the `winget` and `url` sources (schema in `docs/apps/*.json`, validated in
   `tests/check-catalog.mjs`, unknown keys rejected). Prove it on windows-latest with a fixture, including a
   tamper scenario like `app-tampered`.
3. Secrets: enable `secret` options (currently rejected by check-catalog). Decide how a secret reaches the
   target without being embedded in a `.cmd` the owner might share or commit (for example a separate file in the
   bundle, or entered at install time); never log or echo it; rendered output and logs must not contain it.
4. Key-pattern CI guard: a Linux CI step that fails if any file in the repo, fixtures, goldens or rendered
   output matches common key/password/token patterns (allow `{{PLACEHOLDER}}`); prove it with a negative test
   that plants a fake pattern.
5. All 13 existing scenarios and the `browser` job stay green; goldens change only deliberately
   (`--update-goldens`, review the diff).
Known open items to consider (from the batch 3 handoff): user-scope app path never exercised in CI, VLC pin has no
freshness check, duplicated helper code between `docs/modules/app/install.ps1` and `uninstall.ps1`.
Then write the Batch 5 prompt.

Remaining batches: 5 Office/ODT (ask license type first); 6 chrome-data + Capture-Profile.cmd; 7 profiles;
8 tabs UI; 9 pro/AD bundle. Each ends with green CI, merge, handoff, next prompt.
