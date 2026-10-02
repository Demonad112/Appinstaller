# Verifies one curated app (docs/apps/<AppId>.json) after install and after uninstall.
# _ci.expectApp = "fresh" (default: this setup installed it) or "existing" (it was already on the
# computer, so it must never be recorded or removed by this setup).
#   after install   : detected; state record present iff fresh; "<label> installed." logged exactly
#                     once iff fresh (idempotency: the 2nd and 3rd runs only log "already installed")
#   after uninstall : fresh -> gone and no record; existing -> still detected, no record
param(
    [Parameter(Mandatory = $true)][string]$AppId,
    [Parameter(Mandatory = $true)]$Cfg,
    $Ci,
    [switch]$ExpectAbsent,
    [int]$ExpectedCount = 1
)

$failures = @()
$app = Get-Content -LiteralPath (Join-Path $PSScriptRoot "../../docs/apps/$AppId.json") -Raw | ConvertFrom-Json
$expect = if ($Ci -and $Ci.expectApp) { [string]$Ci.expectApp } else { 'fresh' }

function Test-Detected {
    foreach ($d in @($app.detect)) {
        if ($d.type -eq 'file') {
            if (Test-Path -LiteralPath ([Environment]::ExpandEnvironmentVariables([string]$d.path))) { return $true }
        } elseif ($d.type -eq 'arp') {
            foreach ($r in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
                if (Get-ItemProperty -Path $r -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -and $_.DisplayName -match $d.displayName }) { return $true }
            }
        }
    }
    return $false
}

$stateDir = if ($app.scope -eq 'machine') { Join-Path $env:ProgramData 'Appinstaller' } else { Join-Path $env:LOCALAPPDATA 'Appinstaller' }
$statePath = Join-Path $stateDir 'apps-state.json'
$hasRecord = $false
if (Test-Path -LiteralPath $statePath) {
    $st = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    $hasRecord = [bool]($st.PSObject.Properties.Name -contains $AppId)
}
$detected = Test-Detected

if ($ExpectAbsent) {
    if ($hasRecord) { $failures += "apps-state.json still has a record for '$AppId' after uninstall" }
    if ($expect -eq 'fresh' -and $detected) { $failures += "$($app.label) is still installed after uninstall" }
    if ($expect -eq 'existing' -and -not $detected) { $failures += "$($app.label) was already on the computer but uninstall removed it" }
} else {
    if (-not $detected) { $failures += "$($app.label) was not detected after install" }
    if ($expect -eq 'fresh' -and -not $hasRecord) { $failures += "Expected an apps-state.json record for '$AppId' (installed by this setup)" }
    if ($expect -eq 'existing' -and $hasRecord) { $failures += "'$AppId' was pre-installed but apps-state.json claims this setup installed it" }
    $log = Join-Path $env:LOCALAPPDATA 'Appinstaller\install.log'
    if (Test-Path -LiteralPath $log) {
        $n = @(Get-Content -LiteralPath $log | Where-Object { $_ -match ('\] ' + [regex]::Escape($app.label) + ' installed\.$') }).Count
        $want = if ($expect -eq 'fresh') { 1 } else { 0 }
        if ($n -ne $want) { $failures += "Expected '$($app.label) installed.' logged $want time(s), found $n (idempotency)" }
    }
}
return $failures
