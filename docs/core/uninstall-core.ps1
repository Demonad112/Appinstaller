# Appinstaller uninstaller core (rendered, not run directly)
# Same assembly as installer-core.ps1: the CONFIG_B64 placeholder + the selected modules'
# docs/modules/<id>/uninstall.ps1 fragments. Each module removes exactly what its install.ps1
# added and leaves every other policy value, shortcut, and app on the machine untouched.
#
# Module contract: each fragment appends one object to $Modules:
#   Id         string
#   Uninstall  { param($Cfg) ... }  -> string[] of user-facing result lines

$ErrorActionPreference = 'Stop'

$ConfigB64 = '__CONFIG_B64__'

$LogDir = Join-Path $env:LOCALAPPDATA 'Appinstaller'
$LogPath = Join-Path $LogDir 'uninstall.log'
New-Item -ItemType Directory -Path $LogDir -Force -ErrorAction SilentlyContinue | Out-Null

# One-time migration from the pre-rename folder (older builds used 'MomSetup'): state files and
# icons are copied across if missing so an old uninstaller / re-run still finds what it needs.
try {
    $OldDir = Join-Path $env:LOCALAPPDATA 'MomSetup'
    if (Test-Path -LiteralPath $OldDir) {
        foreach ($item in @('chrome-state.json', 'Icons')) {
            $src = Join-Path $OldDir $item
            $dst = Join-Path $LogDir $item
            if ((Test-Path -LiteralPath $src) -and -not (Test-Path -LiteralPath $dst)) {
                Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
} catch {}

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

$Modules = @()

__MODULES__

try {
    $Config = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($ConfigB64)) | ConvertFrom-Json
    $lines = @()
    $failed = @()
    foreach ($m in $Modules) {
        try {
            $lines += @(& $m.Uninstall $Config.modules.($m.Id))
        } catch {
            $failed += $m.Id
            Write-Log "ERROR in module '$($m.Id)': $($_.Exception.ToString())"
            $lines += "One step ($($m.Id)) didn't finish: $($_.Exception.Message)"
        }
    }

    $ok = $failed.Count -eq 0
    Write-Log $(if ($ok) { "Uninstall finished successfully." } else { "Uninstall finished with failures: " + ($failed -join ', ') })
    try {
        $wsh = New-Object -ComObject WScript.Shell
        $title = if ($ok) { "Uninstall Complete" } else { "Uninstall - Something Went Wrong" }
        $wsh.Popup(($lines -join "`r`n"), 30, $title, $(if ($ok) { 64 } else { 48 })) | Out-Null
    } catch {}
    if ($ok) { exit 0 } else { exit 1 }
}
catch {
    Write-Log "ERROR: $($_.Exception.ToString())"
    try {
        $wsh = New-Object -ComObject WScript.Shell
        $wsh.Popup("Uninstall ran into a problem: $($_.Exception.Message)", 30, "Uninstall - Something Went Wrong", 48) | Out-Null
    } catch {}
    exit 1
}
