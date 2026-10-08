> Compiled by an assistant from the session. Background, not verified fact: reason independently
> and check against the code before relying on it. Deeper detail: `handoffs/batch-04-reference.md`.

# Batch 4 handoff: bundle output, `bundled` source, secrets, key-pattern guard (PR Demonad112/Appinstaller#10, merged as `3f08b16`)

## Quick recap
Builds that carry `file` options or `secret` values now download as one deterministic zip
(`<Name>/Install-<Name>.cmd`, `Uninstall-<Name>.cmd`, `files/...`); others stay two `.cmd` files. Added the `bundled`
app source (installer shipped in `files/`, SHA-256/signer verified on the target), `secret` options (values only in
`files/secrets.json`, masked in logs) and `tests/check-secrets.mjs`. CI was green on head `7a1b420`.

## Decisions
- Zip only when needed, so earlier goldens moved only through the `common.ps1` change.
- Zip writer lives in `docs/render-core.js` (STORE, CRC32, fixed timestamps and entry order), so browser and Node bytes match.
- `file` option type is generic; chrome-data (batch 6) is meant to reuse it.
- Test-only items use `"test": true` and show on the site only with `?test=1` (`test-secret`, `7zip-bundled`).

## Caveats
See `handoffs/batch-04-reference.md`. Batch 5 followed (see `batch-05-handoff.md`).
