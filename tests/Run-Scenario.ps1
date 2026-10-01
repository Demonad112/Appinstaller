# Runs one end-to-end scenario on a real Windows machine (CI runner or a test VM):
#   render -> PSScriptAnalyzer -> install x3 (verify after 1st and 3rd) -> uninstall -> verify removed
# Every selected module's tests/modules/<id>.Verify.ps1 is run at each verify point, so adding a
# module to the catalog adds its assertions here automatically.
#
# Usage (pwsh, from the repo root):
#   ./tests/Run-Scenario.ps1 -Fixture tests/fixtures/default.json
#
# Fixture "_ci" keys (test-harness only, ignored by the renderer):
#   removeChrome  uninstall the machine's Chrome first, to exercise the chrome module's install path
#   hideWinget    strip winget from PATH while the installer runs, to exercise the direct-download fallback

param(
    [Parameter(Mandatory = $true)][string]$Fixture,
    [string]$OutDir = 'out'
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $RepoRoot

$fixtureObj = Get-Content -LiteralPath $Fixture -Raw | ConvertFrom-Json
$moduleIds = @($fixtureObj.modules.PSObject.Properties.Name)
$ci = $fixtureObj._ci
Write-Host "Scenario: $Fixture  modules: $($moduleIds -join ', ')"

function Step([string]$Name) { Write-Host "`n==== $Name ====" -ForegroundColor Cyan }

function Show-Logs {
    foreach ($log in @('install.log', 'uninstall.log')) {
        $p = Join-Path $env:LOCALAPPDATA "MomSetup\$log"
        if (Test-Path $p) { Write-Host "--- $log ---"; Get-Content $p | Write-Host }
    }
}

function Invoke-Verify([string]$Label, [switch]$ExpectAbsent, [int]$ExpectedCount = 1) {
    Step "Verify: $Label"
    $failures = @()
    foreach ($id in $moduleIds) {
        $script = Join-Path $PSScriptRoot "modules/$id.Verify.ps1"
        $r = @(& $script -Cfg $fixtureObj.modules.$id -Ci $ci -ExpectAbsent:$ExpectAbsent -ExpectedCount $ExpectedCount)
        foreach ($f in $r) { if ($f) { $failures += "[$id] $f" } }
    }
    if ($failures.Count -gt 0) {
        $failures | ForEach-Object { Write-Host " - $_" -ForegroundColor Red }
        Show-Logs
        throw "Verification failed ($Label): $($failures.Count) failure(s)"
    }
    Write-Host "Verification passed ($Label)." -ForegroundColor Green
}

function Invoke-Cmd([string]$Label, [string]$Path) {
    Step $Label
    $savedPath = $env:PATH
    try {
        if ($ci -and $ci.hideWinget) {
            $env:PATH = (($env:PATH -split ';') | Where-Object { $_ -and $_ -notlike '*\Microsoft\WindowsApps*' }) -join ';'
            if (Get-Command winget -ErrorAction SilentlyContinue) { throw "hideWinget: winget still resolvable" }
        }
        & $Path
        $code = $LASTEXITCODE
    } finally {
        $env:PATH = $savedPath
    }
    if ($code -ne 0) { Show-Logs; throw "$Label exited with code $code" }
}

function Test-Payload([string]$CmdPath) {
    $text = Get-Content -LiteralPath $CmdPath -Raw
    $marker = '<' + '#PSBEGIN#' + '>'
    $idx = $text.IndexOf($marker)
    if ($idx -lt 0) { throw "PSBEGIN marker not found in $CmdPath" }
    $ps = Join-Path $OutDir ((Split-Path -Leaf $CmdPath) + '.payload.ps1')
    Set-Content -LiteralPath $ps -Value $text.Substring($idx + $marker.Length)
    $results = Invoke-ScriptAnalyzer -Path $ps -Severity Error
    if ($results) {
        $results | Format-Table -AutoSize | Out-String | Write-Host
        throw "PSScriptAnalyzer found $($results.Count) error(s) in $CmdPath"
    }
}

# ---- Pre-conditions ---------------------------------------------------------
if ($ci -and $ci.removeChrome) {
    Step 'Remove machine Chrome (test setup)'
    & (Join-Path $PSScriptRoot 'Remove-Chrome.ps1')
}

# ---- Render -----------------------------------------------------------------
Step 'Render'
$rendered = node tools/render.mjs $Fixture $OutDir
if ($LASTEXITCODE -ne 0) { throw "render.mjs failed" }
$rendered | Write-Host
$installCmd = ($rendered | Where-Object { $_ -like 'Wrote *Install-*' } | Select-Object -First 1).Substring(6)
$uninstallCmd = ($rendered | Where-Object { $_ -like 'Wrote *Uninstall-*' } | Select-Object -First 1).Substring(6)

# ---- Lint -------------------------------------------------------------------
Step 'Lint (PSScriptAnalyzer)'
if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) {
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
    Install-Module -Name PSScriptAnalyzer -Force -Scope CurrentUser
}
Test-Payload $installCmd
Test-Payload $uninstallCmd

# ---- Install / idempotency / uninstall -------------------------------------
Invoke-Cmd 'Install (1st run)' $installCmd
Invoke-Verify 'after 1st install'
Invoke-Cmd 'Install (2nd run)' $installCmd
Invoke-Cmd 'Install (3rd run)' $installCmd
Invoke-Verify 'after 3rd install (idempotency)' -ExpectedCount 1
Invoke-Cmd 'Uninstall' $uninstallCmd
Invoke-Verify 'after uninstall' -ExpectAbsent

Show-Logs
Write-Host "`nScenario passed: $Fixture" -ForegroundColor Green
