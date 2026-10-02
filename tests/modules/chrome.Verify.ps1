# Asserts Chrome is present after install AND after uninstall (the module deliberately never
# removes it), and that chrome-state.json matches how the scenario expects Chrome to have arrived:
#   _ci.expectChrome = "existing" (no state file) or "direct" (state file, that method).
param(
    [Parameter(Mandatory = $true)]$Cfg,
    $Ci,
    [switch]$ExpectAbsent,
    [int]$ExpectedCount = 1
)

$failures = @()
$exe = @(
    (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe'),
    (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe')
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $exe) { $failures += "chrome.exe not found in any standard location" }

$expect = if ($Ci -and $Ci.expectChrome) { $Ci.expectChrome } else { 'existing' }
$statePath = Join-Path $env:LOCALAPPDATA 'Appinstaller\chrome-state.json'
if ($expect -eq 'existing') {
    if (Test-Path $statePath) { $failures += "Chrome was pre-installed but chrome-state.json claims this setup installed it" }
} else {
    if (-not (Test-Path $statePath)) {
        $failures += "Expected chrome-state.json (Chrome installed via $expect), not found"
    } else {
        $state = Get-Content $statePath -Raw | ConvertFrom-Json
        if ($state.method -ne $expect) { $failures += "Expected Chrome install method '$expect', state says '$($state.method)'" }
        if ($exe -and $exe -notlike "$env:LOCALAPPDATA*") { $failures += "Expected a per-user Chrome under LOCALAPPDATA, found $exe" }
    }
}
return $failures
