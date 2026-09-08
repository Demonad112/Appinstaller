# Mom-Setup uninstaller payload (rendered, not run directly)
# Removes exactly what installer-template.ps1 added: the forcelist entry for uBlock Origin
# Lite, its toolbar-pin policy, the desktop shortcut, and the cached icon. Leaves every other
# policy value and every other shortcut on the machine untouched.

$ErrorActionPreference = 'Stop'

$ExtId = 'ddkjiahejlhfcafbddmgiahcphecmpfh'
$ShortcutNameB64 = '__SHORTCUT_NAME_B64__'

$LogDir = Join-Path $env:LOCALAPPDATA 'MomSetup'
$LogPath = Join-Path $LogDir 'uninstall.log'
New-Item -ItemType Directory -Path $LogDir -Force -ErrorAction SilentlyContinue | Out-Null

function Write-Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    try { Add-Content -Path $LogPath -Value $line -ErrorAction SilentlyContinue } catch {}
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Remove-ForceInstallEntry {
    param([string]$PolicyRoot)
    $forcelistPath = Join-Path $PolicyRoot 'ExtensionInstallForcelist'
    if (-not (Test-Path $forcelistPath)) { return }
    $props = (Get-Item -Path $forcelistPath).Property
    foreach ($p in $props) {
        $val = (Get-ItemProperty -Path $forcelistPath -Name $p -ErrorAction SilentlyContinue).$p
        if ($val -like "$ExtId;*") {
            Remove-ItemProperty -Path $forcelistPath -Name $p -ErrorAction SilentlyContinue
            Write-Log "Removed forcelist entry '$p' from $PolicyRoot"
        }
    }
    $settingsPath = Join-Path (Join-Path $PolicyRoot 'ExtensionSettings') $ExtId
    if (Test-Path $settingsPath) {
        Remove-Item -Path $settingsPath -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log "Removed ExtensionSettings entry from $settingsPath"
    }
}

try {
    Remove-ForceInstallEntry -PolicyRoot 'HKCU:\Software\Policies\Google\Chrome'

    if (Test-IsAdmin) {
        Remove-ForceInstallEntry -PolicyRoot 'HKLM:\SOFTWARE\Policies\Google\Chrome'
    } else {
        $hklmForcelist = 'HKLM:\SOFTWARE\Policies\Google\Chrome\ExtensionInstallForcelist'
        $hasHklm = (Test-Path $hklmForcelist) -and (@((Get-Item $hklmForcelist).Property).Count -gt 0)
        if ($hasHklm) {
            Write-Log "Machine-wide entry detected; relaunching elevated to remove it."
            Start-Process -FilePath $env:SELF -Verb RunAs -Wait
        }
    }

    $shortcutName = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($ShortcutNameB64))
    $safeName = ($shortcutName -replace '[\\/:*?"<>|]', '_').Trim()
    $desktop = [Environment]::GetFolderPath('Desktop')
    foreach ($ext in @('.lnk', '.url')) {
        $p = Join-Path $desktop "$safeName$ext"
        if (Test-Path $p) {
            Remove-Item -Path $p -Force -ErrorAction SilentlyContinue
            Write-Log "Removed shortcut $p"
        }
    }
    $iconPath = Join-Path $env:LOCALAPPDATA "MomSetup\Icons\$safeName.ico"
    if (Test-Path $iconPath) {
        Remove-Item -Path $iconPath -Force -ErrorAction SilentlyContinue
        Write-Log "Removed icon $iconPath"
    }

    Write-Log "Uninstall finished successfully."
    try {
        $wsh = New-Object -ComObject WScript.Shell
        $wsh.Popup("Removed the desktop icon and the ad-blocker policy.", 30, "Uninstall Complete", 64) | Out-Null
    } catch {}
    exit 0
}
catch {
    Write-Log "ERROR: $($_.Exception.ToString())"
    try {
        $wsh = New-Object -ComObject WScript.Shell
        $wsh.Popup("Uninstall ran into a problem: $($_.Exception.Message)", 30, "Uninstall - Something Went Wrong", 48) | Out-Null
    } catch {}
    exit 1
}
