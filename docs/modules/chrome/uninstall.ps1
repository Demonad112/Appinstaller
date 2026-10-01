# Deliberately leaves Chrome installed: removing a browser deletes its bookmarks, passwords and
# history, which is never what "undo this setup" should mean.

$Modules += [pscustomobject]@{
    Id        = 'chrome'
    Uninstall = {
        param($Cfg)
        $state = Join-Path $LogDir 'chrome-state.json'
        if (Test-Path -LiteralPath $state) {
            Write-Log "Chrome was installed by this setup; leaving it installed on purpose."
            return "Google Chrome was left installed (removing it would delete its bookmarks and history). Uninstall it from Settings > Apps if you really want it gone."
        }
        return @()
    }
}
