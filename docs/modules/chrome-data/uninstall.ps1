# Undoes chrome-data: puts the bookmarks Chrome had before back, or (if there were none) removes
# the bookmark file this setup wrote. Whatever is in Chrome right now is first copied to
# %LOCALAPPDATA%\Appinstaller\chrome-data\Bookmarks.removed so nothing is lost for good.
# Acts only if the install recorded state.json. Skipped while Chrome is running.

$Modules += [pscustomobject]@{
    Id        = 'chrome-data'
    Uninstall = {
        param($Cfg)
        $profileDir = Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data\Default'
        $target = Join-Path $profileDir 'Bookmarks'
        $stateDir = Join-Path $LogDir 'chrome-data'
        $statePath = Join-Path $stateDir 'state.json'
        $original = Join-Path $stateDir 'Bookmarks.original'
        if (-not (Test-Path -LiteralPath $statePath)) {
            Write-Log "No chrome-data state; nothing to undo."
            return @()
        }
        if (Get-Process -Name 'chrome' -ErrorAction SilentlyContinue) {
            Write-Log "Chrome is running; leaving bookmarks as they are."
            return "Chrome is open, so the bookmarks were left as they are. Close Chrome and run the uninstall again."
        }
        if (Test-Path -LiteralPath $target) {
            Copy-Item -LiteralPath $target -Destination (Join-Path $stateDir 'Bookmarks.removed') -Force
        }
        if (Test-Path -LiteralPath $original) {
            Copy-Item -LiteralPath $original -Destination $target -Force
            Write-Log "Restored the bookmarks Chrome had before."
            $msg = "Your earlier Chrome bookmarks were put back."
        } else {
            Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
            Write-Log "Removed the bookmarks file this setup added."
            $msg = "The bookmarks this setup added were removed (a copy is in $stateDir)."
        }
        Remove-Item -LiteralPath $statePath, $original -Force -ErrorAction SilentlyContinue
        return $msg
    }
}
