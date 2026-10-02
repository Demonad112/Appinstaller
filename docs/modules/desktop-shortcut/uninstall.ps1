# Removes the desktop shortcut (.lnk or .url) and its cached icon.

$Modules += [pscustomobject]@{
    Id        = 'desktop-shortcut'
    Uninstall = {
        param($Cfg)
        $safeName = ($Cfg.name -replace '[\\/:*?"<>|]', '_').Trim()
        if (-not $safeName) { $safeName = 'Website' }
        $desktop = [Environment]::GetFolderPath('Desktop')
        foreach ($ext in @('.lnk', '.url')) {
            $p = Join-Path $desktop "$safeName$ext"
            if (Test-Path $p) {
                Remove-Item -Path $p -Force -ErrorAction SilentlyContinue
                Write-Log "Removed shortcut $p"
            }
        }
        $iconPath = Join-Path $env:LOCALAPPDATA "Appinstaller\Icons\$safeName.ico"
        if (Test-Path $iconPath) {
            Remove-Item -Path $iconPath -Force -ErrorAction SilentlyContinue
            Write-Log "Removed icon $iconPath"
        }
        return "Removed the desktop icon."
    }
}
