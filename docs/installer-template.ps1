# Mom-Setup installer payload (rendered, not run directly)
# Placeholders of the form __TOKEN__ are substituted by tools/render.mjs (CI/local) and
# docs/app.js (the live GitHub Pages generator) with the identical logic, so what CI
# validates is byte-for-byte what the website hands out.
#
# This file is the single source of truth for the installer's behavior.

$ErrorActionPreference = 'Stop'

# ---- Rendered configuration -------------------------------------------------
$ExtId          = 'ddkjiahejlhfcafbddmgiahcphecmpfh'   # uBlock Origin Lite (MV3), Chrome Web Store
$UpdateUrl      = 'https://clients2.google.com/service/update2/crx'
$DestUrlB64     = '__DEST_URL_B64__'
$ShortcutNameB64 = '__SHORTCUT_NAME_B64__'
$IconB64        = '__ICON_B64__'                        # may be empty
$ShortcutStyle  = '__SHORTCUT_STYLE__'                  # "App" or "Url"
$PinToolbar     = __PIN_TOOLBAR__                        # $true / $false
$AutoRestartChrome = __AUTO_RESTART_CHROME__             # $true / $false
# ------------------------------------------------------------------------------

$SELF = $env:SELF
$LogDir = Join-Path $env:LOCALAPPDATA 'MomSetup'
$LogPath = Join-Path $LogDir 'install.log'
New-Item -ItemType Directory -Path $LogDir -Force -ErrorAction SilentlyContinue | Out-Null

function Write-Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    try { Add-Content -Path $LogPath -Value $line -ErrorAction SilentlyContinue } catch {}
}

function Show-Result {
    param([string]$Message, [bool]$IsError = $false)
    Write-Log $Message
    try {
        $wsh = New-Object -ComObject WScript.Shell
        $title = if ($IsError) { 'Setup - Something Went Wrong' } else { 'Setup Complete' }
        $icon = if ($IsError) { 48 } else { 64 }   # 48 = warning, 64 = information
        # 3rd arg is auto-dismiss timeout in seconds so an unattended run never blocks.
        $wsh.Popup($Message, 30, $title, $icon) | Out-Null
    } catch {}
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Find-Chrome {
    $candidates = @()
    $appPathKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe'
    )
    foreach ($k in $appPathKeys) {
        try {
            if (Test-Path $k) {
                $v = (Get-Item $k -ErrorAction Stop).GetValue('')
                if ($v) { $candidates += $v }
            }
        } catch {}
    }
    $candidates += @(
        (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe'),
        (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe')
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c)) { return $c }
    }
    return $null
}

function Set-ForceInstallPolicy {
    param([string]$PolicyRoot, [string]$ExtEntry)
    $forcelistPath = Join-Path $PolicyRoot 'ExtensionInstallForcelist'
    if (-not (Test-Path $forcelistPath)) {
        New-Item -Path $forcelistPath -Force | Out-Null
    }
    $extId = $ExtEntry.Split(';')[0]
    $existingProps = (Get-Item -Path $forcelistPath).Property
    $matchName = $null
    foreach ($p in $existingProps) {
        $val = (Get-ItemProperty -Path $forcelistPath -Name $p -ErrorAction SilentlyContinue).$p
        if ($val -like "$extId;*") { $matchName = $p; break }
    }
    if ($matchName) {
        Set-ItemProperty -Path $forcelistPath -Name $matchName -Value $ExtEntry -Type String
        Write-Log "Updated existing forcelist entry '$matchName' under $PolicyRoot"
    } else {
        $used = @($existingProps | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ })
        $next = 1
        while ($used -contains $next) { $next++ }
        New-ItemProperty -Path $forcelistPath -Name "$next" -Value $ExtEntry -PropertyType String -Force | Out-Null
        Write-Log "Added forcelist entry '$next' under $PolicyRoot"
    }
}

function Set-ToolbarPin {
    param([string]$PolicyRoot, [string]$ExtId)
    # Dictionary policy (ExtensionSettings) expressed as nested registry keys, per Chrome's
    # schema-based registry expansion for Windows. Cosmetic only -- install itself stays on
    # ExtensionInstallForcelist above.
    $settingsPath = Join-Path (Join-Path $PolicyRoot 'ExtensionSettings') $ExtId
    New-Item -Path $settingsPath -Force | Out-Null
    Set-ItemProperty -Path $settingsPath -Name 'toolbar_pin' -Value 'force_pinned' -Type String
    Write-Log "Pinned extension toolbar icon under $settingsPath"
}

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
        $iconDir = Join-Path $env:LOCALAPPDATA 'MomSetup\Icons'
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

# ---- Main -------------------------------------------------------------------
try {
    if (-not $IsWindows -and $PSVersionTable.PSVersion.Major -ge 6) {
        Show-Result -IsError $true -Message "This setup only works on Windows."
        exit 1
    }

    $destUrl = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($DestUrlB64))
    $shortcutName = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($ShortcutNameB64))
    $iconBytes = if ($IconB64) { [Convert]::FromBase64String($IconB64) } else { $null }

    Write-Log "Starting install. URL=$destUrl Name=$shortcutName Style=$ShortcutStyle"

    $hklmForcelist = 'HKLM:\SOFTWARE\Policies\Google\Chrome\ExtensionInstallForcelist'
    $needsHklm = $false
    try {
        if (Test-Path $hklmForcelist) {
            $count = @((Get-Item $hklmForcelist).Property).Count
            if ($count -gt 0) { $needsHklm = $true }
        }
    } catch {}

    if ($needsHklm -and -not (Test-IsAdmin)) {
        Write-Log "Existing machine-wide Chrome policy detected; relaunching elevated to write HKLM."
        Start-Process -FilePath $SELF -Verb RunAs -Wait
        exit 0
    }

    $policyRoot = if ($needsHklm) { 'HKLM:\SOFTWARE\Policies\Google\Chrome' } else { 'HKCU:\Software\Policies\Google\Chrome' }
    $chromePath = Find-Chrome

    $extEntry = "$ExtId;$UpdateUrl"
    $chromeConfigured = $false
    if ($chromePath) {
        Set-ForceInstallPolicy -PolicyRoot $policyRoot -ExtEntry $extEntry
        if ($PinToolbar) { Set-ToolbarPin -PolicyRoot $policyRoot -ExtId $ExtId }
        $chromeConfigured = $true
    } else {
        Write-Log "Chrome was not found on this machine; skipping ad-blocker install."
    }

    $shortcutStyleEffective = if ($chromePath) { $ShortcutStyle } else { 'Url' }
    $shortcutPath = New-DesktopShortcut -ChromePath $chromePath -DestUrl $destUrl `
        -ShortcutName $shortcutName -IconBytes $iconBytes -Style $shortcutStyleEffective

    $restarted = $false
    if ($chromeConfigured -and $AutoRestartChrome) {
        $running = Get-Process -Name 'chrome' -ErrorAction SilentlyContinue
        if ($running) {
            Write-Log "Restarting Chrome so the ad blocker takes effect immediately."
            Stop-Process -Name 'chrome' -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 1
            Start-Process -FilePath $chromePath
            $restarted = $true
        }
    }

    $lines = @()
    $lines += "Desktop icon for $shortcutName is ready."
    if ($chromeConfigured) {
        if ($restarted) {
            $lines += "Ad blocker installed and Chrome restarted."
        } else {
            $lines += "Ad blocker installed. It finishes turning on the next time Chrome opens (usually within a few seconds if Chrome is already open)."
        }
    } else {
        $lines += "Chrome wasn't found on this computer, so the ad blocker step was skipped. The desktop icon still works with your default browser."
    }
    Show-Result -Message ($lines -join "`r`n")
    Write-Log "Install finished successfully."
    exit 0
}
catch {
    $msg = "Setup ran into a problem: $($_.Exception.Message)`r`n`r`nA log file with details was saved at:`r`n$LogPath`r`n`r`nPlease send that file for help."
    Show-Result -Message $msg -IsError $true
    Write-Log "ERROR: $($_.Exception.ToString())"
    exit 1
}
