Context: continuing Demonad112/Appinstaller, a GitHub Pages builder that renders a self-contained
Windows .cmd (batch/PowerShell 5.1 polyglot) from a module catalog. Read `CLAUDE.md` and
`handoffs/batch-02-handoff.md` first (background, verify against the code). The long-term spec is
`MASTER_HANDOFF.md` (if attached). Start in plan mode; ask blocking questions in a popup.

Workflow: one branch + draft PR per batch (`batch-NN-<topic>`), subscribe to PR activity, fix red CI,
merge only when green, then write `handoffs/batch-NN-handoff.md` and `handoffs/batch-NN+1-prompt.md`
(layered recap + copy-paste prompt) and send both. If context gets large with CI still red, put the
failure and attempted fixes in the handoff, make "fix it first" step 1 of the next prompt, and start
the next batch meanwhile. Never write real keys/passwords anywhere; use `{{PLACEHOLDER}}`.
Tip: a Linux pwsh + PSScriptAnalyzer can be installed in the sandbox for parse/lint (see the handoff).

Owner decisions: family members are admins on their own PCs; Appinstaller naming; Office license type
still undecided (ask at the Office batch).

BATCH 3: generic `app` module (curated apps as data).
1. One generic module `app` whose options come from the catalog schema (e.g. a `multiselect` of app
   ids, or one catalog entry per app: decide in plan mode and justify). App definitions live in
   `docs/apps/*.json`: id, label, description, scope (user|machine), source (`winget` with pinned ID +
   `--source winget`, or `url` with SHA-256 / Authenticode signer), silent args, detect step
   (registry/file/winget list), uninstall, optional `requires`. Validate the app schema in
   `tests/check-catalog.mjs`; keep goldens deliberate (`--update-goldens`, review the diff).
2. Machine-scope apps go through the existing elevated child (`NeedsAdmin`); user-scope apps run in the
   parent. Do not add new elevation paths.
3. First apps: 7-Zip, VLC, Adobe Reader. For each, run `winget show <id>` FIRST and record the real ID,
   installer type, scope support and silent switches in the app JSON; reject any app that cannot be
   proven silent on windows-latest.
4. CI: a fixture per source type (winget, url) proving install -> detect -> idempotent re-run ->
   uninstall -> gone on windows-latest, plus verify scripts; all existing scenarios stay green and
   `browser` still proves browser == Node == golden for the new options UI.
5. Idempotency/failure: an already-installed app is detected and skipped; a failed download/signature
   check fails closed with a clear message and non-zero exit (reuse the chrome-blocked pattern).
Then write the Batch 4 prompt (bundle output + `bundled` source + secrets + key-pattern CI guard).

Remaining batches: 4 bundle output + `bundled` source + secrets + key-pattern CI guard; 5 Office/ODT
(ask license type first); 6 chrome-data + Capture-Profile.cmd; 7 profiles; 8 tabs UI; 9 pro/AD bundle.
Each ends with green CI, merge, handoff, next prompt.
