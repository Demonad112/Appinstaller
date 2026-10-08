# Chrome bookmarks, copied from the bundle's files\Bookmarks.json (saved by Capture-Profile.cmd on
# the old computer) into the Default profile. Bookmarks only: this module never reads or writes
# passwords, cookies, history, extension data or any sign-in state.
# Options: bookmarks (file), replaceExisting (bool)
#
# - Chrome rewrites its bookmarks when it exits, so the module skips while Chrome is running.
# - An existing bookmark list is kept (module skips) unless replaceExisting is set; a replaced file
#   is first copied to %LOCALAPPDATA%\Appinstaller\chrome-data\Bookmarks.original.
# - The file must be Chrome bookmark JSON; the "checksum" and "sync_metadata" fields are dropped so
#   the bookmarks are not tied to the old computer's account.
# - State: %LOCALAPPDATA%\Appinstaller\chrome-data\state.json ({ hadOriginal }) so uninstall can undo.

function Get-ChromeDataPaths {
    $profileDir = Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data\Default'
    $stateDir = Join-Path $LogDir 'chrome-data'
    [pscustomobject]@{
        ProfileDir = $profileDir
        Target     = Join-Path $profileDir 'Bookmarks'
        StateDir   = $stateDir
        State      = Join-Path $stateDir 'state.json'
        Original   = Join-Path $stateDir 'Bookmarks.original'
    }
}

function Test-BookmarkNodesPresent {
    param($Node)
    if ($null -eq $Node) { return $false }
    if ($Node.type -eq 'url') { return $true }
    foreach ($c in @($Node.children)) { if (Test-BookmarkNodesPresent $c) { return $true } }
    return $false
}

function Test-BookmarksFileHasEntries {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        $j = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($r in @('bookmark_bar', 'other', 'synced')) {
            if ($j.roots -and (Test-BookmarkNodesPresent $j.roots.$r)) { return $true }
        }
        return $false
    } catch { return $true }   # unreadable: treat as something worth keeping
}

$Modules += [pscustomobject]@{
    Id      = 'chrome-data'
    Install = {
        param($Cfg, $Ctx)
        $p = Get-ChromeDataPaths
        if (-not $Ctx.ChromePath) {
            Write-Log "Chrome was not found; skipping bookmarks."
            return "Chrome wasn't found on this computer, so the bookmarks step was skipped."
        }
        if (Get-Process -Name 'chrome' -ErrorAction SilentlyContinue) {
            Write-Log "Chrome is running; skipping bookmarks."
            return "Chrome is open, so your bookmarks were not copied (Chrome would overwrite them). Close Chrome and run this setup again."
        }
        $src = if ($BundleDir) { Join-Path (Join-Path $BundleDir 'files') 'Bookmarks.json' } else { $null }
        if (-not $src -or -not (Test-Path -LiteralPath $src)) {
            throw "The bookmarks file (Bookmarks.json) was not found next to this setup file. Extract the whole zip first (right-click it, Extract All), then run the setup from the extracted folder."
        }
        if ((Get-Item -LiteralPath $src).Length -gt 20MB) { throw 'The bookmarks file is too large to be a Chrome bookmark list.' }
        try { $json = Get-Content -LiteralPath $src -Raw -Encoding UTF8 | ConvertFrom-Json } catch { throw 'The bookmarks file is not valid JSON. Use a file saved by Capture-Profile.cmd.' }
        if (-not $json.roots -or -not $json.roots.bookmark_bar) { throw 'The file is not a Chrome bookmarks file. Use a file saved by Capture-Profile.cmd.' }
        foreach ($drop in @('checksum', 'sync_metadata')) {
            if ($json.PSObject.Properties[$drop]) { $json.PSObject.Properties.Remove($drop) }
        }
        $text = $json | ConvertTo-Json -Depth 100

        New-Item -ItemType Directory -Path $p.ProfileDir -Force | Out-Null
        New-Item -ItemType Directory -Path $p.StateDir -Force | Out-Null
        $had = Test-Path -LiteralPath $p.Target
        if ($had -and (Test-BookmarksFileHasEntries $p.Target) -and -not $Cfg.replaceExisting) {
            Write-Log "Chrome already has bookmarks; leaving them."
            return "Chrome already has bookmarks, so they were left alone. Tick 'Replace the bookmarks Chrome already has' to swap them."
        }
        if ($had -and -not (Test-Path -LiteralPath $p.State)) {
            # First time we touch this file: keep the original so uninstall can restore it.
            Copy-Item -LiteralPath $p.Target -Destination $p.Original -Force
            Write-Log "Saved the existing bookmarks to $($p.Original)"
        }
        if (-not (Test-Path -LiteralPath $p.State)) {
            $hadOrig = $had -and (Test-Path -LiteralPath $p.Original)
            ([pscustomobject]@{ hadOriginal = $hadOrig } | ConvertTo-Json) | Set-Content -LiteralPath $p.State -Encoding UTF8
        }
        [IO.File]::WriteAllText($p.Target, $text, (New-Object Text.UTF8Encoding($false)))
        Write-Log "Bookmarks written to $($p.Target)"
        return "Your bookmarks were added to Chrome."
    }
}
