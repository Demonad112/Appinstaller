# Mom-Setup installer core (rendered, not run directly)
# docs/render-core.js substitutes the CONFIG_B64 placeholder (base64 UTF-8 JSON of the selected
# modules' options) and the MODULES placeholder (the selected modules'
# docs/modules/<id>/install.ps1 fragments, in catalog order). Placeholder names are written
# without their underscores in comments on purpose: every literal occurrence gets replaced. The same function runs in the browser (docs/app.js) and in CI
# (tools/render.mjs), so what CI validates is byte-for-byte what the website hands out.
#
# Module contract: each fragment appends one object to $Modules:
#   Id         string
#   NeedsAdmin { param($Cfg) ... }        -> $true if this module must run elevated on this machine
#   Install    { param($Cfg, $Ctx) ... }  -> string[] of user-facing result lines
# $Ctx is shared state across modules (e.g. $Ctx.ChromePath). Modules that write per-user state
# (HKCU, Desktop, %LOCALAPPDATA%) must never return $true from NeedsAdmin: an over-the-shoulder
# UAC elevation runs as the admin's profile, not the person the setup is for.

$ErrorActionPreference = 'Stop'

# When the .cmd is launched from a PowerShell 7 (pwsh) window, this Windows PowerShell 5.1
# process inherits pwsh's PSModulePath and would autoload pwsh's copies of built-in modules
# (e.g. Microsoft.PowerShell.Security -> Get-AuthenticodeSignature), which fail to load in 5.1.
if ($PSVersionTable.PSEdition -ne 'Core') {
    $paths = @(($env:PSModulePath -split ';') | Where-Object { $_ -and $_ -notmatch '\\PowerShell\\' })
    $builtin = Join-Path $PSHOME 'Modules'
    if ($paths -notcontains $builtin) { $paths += $builtin }
    $env:PSModulePath = $paths -join ';'
}

$ConfigB64 = '__CONFIG_B64__'

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

$Modules = @()

__MODULES__

# ---- Main -------------------------------------------------------------------
try {
    if (-not $IsWindows -and $PSVersionTable.PSVersion.Major -ge 6) {
        Show-Result -IsError $true -Message "This setup only works on Windows."
        exit 1
    }

    $Config = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($ConfigB64)) | ConvertFrom-Json
    Write-Log ("Starting install. Modules: " + (($Modules | ForEach-Object { $_.Id }) -join ', '))

    $needsAdmin = @()
    foreach ($m in $Modules) {
        if (& $m.NeedsAdmin $Config.modules.($m.Id)) { $needsAdmin += $m.Id }
    }
    if ($needsAdmin.Count -gt 0 -and -not (Test-IsAdmin)) {
        Write-Log ("Relaunching elevated; required by: " + ($needsAdmin -join ', '))
        Start-Process -FilePath $SELF -Verb RunAs -Wait
        exit 0
    }

    $Ctx = @{ ChromePath = (Find-Chrome) }
    $lines = @()
    $failed = @()
    foreach ($m in $Modules) {
        try {
            Write-Log "Module '$($m.Id)': starting"
            $lines += @(& $m.Install $Config.modules.($m.Id) $Ctx)
            Write-Log "Module '$($m.Id)': done"
        } catch {
            $failed += $m.Id
            Write-Log "ERROR in module '$($m.Id)': $($_.Exception.ToString())"
            $lines += "One step ($($m.Id)) didn't finish: $($_.Exception.Message)"
        }
    }

    if ($failed.Count -gt 0) {
        $lines += "`r`nA log file with details was saved at:`r`n$LogPath`r`n`r`nPlease send that file for help."
        Show-Result -Message ($lines -join "`r`n") -IsError $true
        Write-Log ("Install finished with failures: " + ($failed -join ', '))
        exit 1
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
