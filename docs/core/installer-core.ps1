# Appinstaller installer core (rendered, not run directly)
# docs/render-core.js substitutes the CONFIG_B64 placeholder (base64 UTF-8 JSON of the selected
# modules' options and their scopes) and the MODULES placeholder (the selected modules'
# docs/modules/<id>/install.ps1 fragments, in catalog order). Placeholder names are written
# without their underscores in comments on purpose: every literal occurrence gets replaced. The same function runs in the browser (docs/app.js) and in CI
# (tools/render.mjs), so what CI validates is byte-for-byte what the website hands out.
#
# Module contract: each fragment appends one object to $Modules:
#   Id         string
#   NeedsAdmin { param($Cfg) ... }        -> (machine-scope modules only, optional) $true if this
#                                            module must run elevated on this computer; absent = always
#   Install    { param($Cfg, $Ctx) ... }  -> string[] of user-facing result lines
# $Ctx is shared state across modules in a phase (e.g. $Ctx.ChromePath). The core runs in two
# phases (see common.ps1): user-scope modules in-process as the real user, machine-scope modules
# that need admin in an elevated child. Modules that write per-user state (HKCU, Desktop,
# %LOCALAPPDATA%) must be user scope: an elevated child can be a different profile.
# The common placeholder below splices in docs/core/common.ps1 (named without underscores in this
# comment on purpose: every literal occurrence of a placeholder gets replaced).

$ErrorActionPreference = 'Stop'

$Kind = 'install'
$LogName = 'install.log'
$ConfigB64 = '__CONFIG_B64__'
$SELF = $env:SELF

__COMMON__

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
    $code = @(Invoke-Appinstaller -Modules $Modules -Config $Config -Noun 'Install' `
        -NewContext { @{ ChromePath = (Find-Chrome) } } `
        -Action { param($m, $cfg, $ctx) & $m.Install $cfg $ctx })[-1]
    exit ([int]$code)
}
catch {
    Close-Progress
    $msg = "Setup ran into a problem: $($_.Exception.Message)`r`n`r`nA log file with details was saved at:`r`n$LogPath`r`n`r`nPlease send that file for help."
    Show-Result -Message $msg -IsError $true
    Write-Log "ERROR: $($_.Exception.ToString())"
    exit 1
}
