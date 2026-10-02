Context: continuing Demonad112/Appinstaller, a GitHub Pages builder that renders a self-contained
Windows .cmd (batch/PowerShell 5.1 polyglot) from a module catalog. Read `CLAUDE.md` and
`handoffs/batch-01-handoff.md` first (background, verify against the code). The long-term spec is
`MASTER_HANDOFF.md` (if attached) sections 4-9. Start in plan mode; ask blocking questions in a popup.

Workflow: one branch + draft PR per batch (`batch-NN-<topic>`), subscribe to PR activity, fix red CI,
merge only when green, then write `handoffs/batch-NN-handoff.md` and `handoffs/batch-NN+1-prompt.md`
(layered recap + copy-paste prompt) and send both. If context gets large with CI still red, put the
failure and attempted fixes in the handoff, make "fix it first" step 1 of the next prompt, and start
the next batch meanwhile. Never write real keys/passwords anywhere; use `{{PLACEHOLDER}}`.

Owner decisions: family members are admins on their own PCs; Appinstaller naming; Office license
type still undecided (ask at the Office batch).

BATCH 2: scope, two-phase core, data-driven options.
1. Catalog schema: `scope: user|machine` replaces `needsAdmin` (a machine module may keep a dynamic
   NeedsAdmin, e.g. ublock HKLM case); `options: [{key,type,label,hint,default,required,pattern,values}]`
   with types text|url|select|radio|checkbox|icon|secret|multiselect; validate in `tests/check-catalog.mjs`.
2. Data-driven UI: `docs/app.js` builds option forms from `options`; remove the hand-written
   `collectors` and per-module HTML in `docs/index.html`. Existing fixtures must render byte-identical
   output before/after (golden hashes in check-catalog) and match the browser download (Playwright sha256).
3. Two-phase core (`docs/core/installer-core.ps1`, `uninstall-core.ps1`): header forwards args
   (`@set "APPI_ARGS=%*"`). Parent (the real user) takes a named mutex (run-twice lock); if any selected
   module is machine-scope it launches itself elevated (`-Verb RunAs -Wait`, `--phase machine --run <guid>`),
   reads the child's result JSON from `%ProgramData%\Appinstaller\run-<guid>`, runs user-scope modules
   in-process, shows one combined popup and exits with the combined code. Always spawn the child, even if
   already admin (one code path; CI exercises it). UAC declined => machine modules reported skipped, exit 1.
4. Non-modal progress notice ("Setting things up, please wait") closed before the result popup; fall back to log only.
5. CI: all existing scenarios stay green, plus a fixture forcing a machine-scope path (e.g.
   `_ci.seedHklmForcelist` so ublock-lite writes HKLM in the child) verifying HKLM written in the child and
   HKCU in the parent.
Then write the Batch 3 prompt (generic `app` module + `docs/apps/*.json`: winget/url sources, detect,
uninstall; first apps 7-Zip, VLC, Adobe Reader; run `winget show` per ID first).

Remaining batches: 3 apps; 4 bundle output + `bundled` source + secrets + key-pattern CI guard;
5 Office/ODT (ask license type first); 6 chrome-data + Capture-Profile.cmd; 7 profiles; 8 tabs UI;
9 pro/AD bundle. Each ends with green CI, merge, handoff, next prompt.
