# Appinstaller uninstaller core (rendered, not run directly)
# Same assembly as installer-core.ps1: the CONFIG_B64 placeholder (options + scopes), the shared
# docs/core/common.ps1 and the selected modules' docs/modules/<id>/uninstall.ps1 fragments. Each
# module removes exactly what its install.ps1 added and leaves every other policy value,
# shortcut, and app on the machine untouched.
#
# Module contract: each fragment appends one object to $Modules:
#   Id         string
#   NeedsAdmin { param($Cfg) ... }  -> (machine-scope modules only, optional) $true if removal
#                                      must run elevated on this computer; absent = always
#   Uninstall  { param($Cfg) ... }  -> string[] of user-facing result lines
# Two-phase like the installer: user-scope modules run as the real user, machine-scope modules
# that need admin run in an elevated child (see common.ps1).

$ErrorActionPreference = 'Stop'

$Kind = 'uninstall'
$LogName = 'uninstall.log'
$ConfigB64 = '__CONFIG_B64__'
$SELF = $env:SELF

__COMMON__

$Modules = @()

__MODULES__

try {
    $Config = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($ConfigB64)) | ConvertFrom-Json
    $code = @(Invoke-Appinstaller -Modules $Modules -Config $Config -Noun 'Uninstall' `
        -NewContext { @{} } `
        -Action { param($m, $cfg, $ctx) & $m.Uninstall $cfg })[-1]
    exit ([int]$code)
}
catch {
    Close-Progress
    Write-Log "ERROR: $($_.Exception.ToString())"
    Show-Result -IsError $true -Message "Uninstall ran into a problem: $($_.Exception.Message)"
    exit 1
}
