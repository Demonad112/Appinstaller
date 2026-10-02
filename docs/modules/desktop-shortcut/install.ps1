# Desktop shortcut to one website. "App" style = chrome.exe --app="<url>" .lnk (no tabs or
# address bar); "Url" style, or automatically when Chrome isn't present = .url internet shortcut
# opened by the default browser. No admin needed.
# Options: destUrl, name, style ("App" | "Url"), iconB64 (optional .ico bytes)

function New-DesktopShortcut {
    param(
        [string]$ChromePath,
        [string]$DestUrl,
        [string]$ShortcutName,
        [byte[]]$IconBytes,
        [string]$Style
    )
    $desktop = [Environment]::GetFolderPath('Desktop')
    $safeName = ($ShortcutName -replace '[\\/:*?"<>|]', '_').Trim()
    if (-not $safeName) { $safeName = 'Website' }

    $iconPath = $null
    if ($IconBytes -and $IconBytes.Length -gt 0) {
        $iconDir = Join-Path $env:LOCALAPPDATA 'Appinstaller\Icons'
        New-Item -ItemType Directory -Path $iconDir -Force -ErrorAction SilentlyContinue | Out-Null
        $iconPath = Join-Path $iconDir "$safeName.ico"
        [IO.File]::WriteAllBytes($iconPath, $IconBytes)
    }

    if ($Style -eq 'Url' -or -not $ChromePath) {
        $path = Join-Path $desktop "$safeName.url"
        $iconLine = if ($iconPath) { "IconFile=$iconPath`r`nIconIndex=0`r`n" } else { "" }
        $content = "[InternetShortcut]`r`nURL=$DestUrl`r`n$iconLine"
        [IO.File]::WriteAllText($path, $content, [Text.Encoding]::ASCII)
        Write-Log "Wrote .url shortcut to $path"
        return $path
    } else {
        $path = Join-Path $desktop "$safeName.lnk"
        $wsh = New-Object -ComObject WScript.Shell
        $sc = $wsh.CreateShortcut($path)
        $sc.TargetPath = $ChromePath
        $sc.Arguments = '--app=' + '"' + $DestUrl + '"'
        $sc.IconLocation = if ($iconPath) { "$iconPath,0" } else { "$ChromePath,0" }
        $sc.WindowStyle = 1
        $sc.Save()
        Write-Log "Wrote .lnk shortcut to $path"
        return $path
    }
}

$Modules += [pscustomobject]@{
    Id         = 'desktop-shortcut'
    NeedsAdmin = { param($Cfg) $false }
    Install    = {
        param($Cfg, $Ctx)
        $iconBytes = if ($Cfg.iconB64) { [Convert]::FromBase64String($Cfg.iconB64) } else { $null }
        $style = if ($Ctx.ChromePath) { $Cfg.style } else { 'Url' }
        Write-Log "Shortcut: URL=$($Cfg.destUrl) Name=$($Cfg.name) Style=$style"
        $null = New-DesktopShortcut -ChromePath $Ctx.ChromePath -DestUrl $Cfg.destUrl `
            -ShortcutName $Cfg.name -IconBytes $iconBytes -Style $style
        if ($Ctx.ChromePath) { return "Desktop icon for $($Cfg.name) is ready." }
        return "Desktop icon for $($Cfg.name) is ready. Chrome wasn't found, so it opens in your default browser."
    }
}
