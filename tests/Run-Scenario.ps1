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
#   expectChrome  passed through to chrome.Verify.ps1 ("existing" | "direct")
#   blockHosts    host names pointed at 127.0.0.1 in the hosts file for the run, so a download
#                 genuinely fails (removed again in a finally block)
#   expectExit    expected exit code of the 1st install (default 0). When non-zero the scenario
#                 asserts that code plus a log line (expectLog, default 'Install finished with
#                 failures') in install.log, then stops: no verify, no further runs
#   expectLog     regex the log must match when expectExit is non-zero
#   seedHklmForcelist  creates a machine-wide Chrome ExtensionInstallForcelist (dummy entry) first,
#                 so ublock-lite must write HKLM from the elevated child; removed again in finally
#   expectElevated  whether the 1st install must have run the elevated machine phase (default
#                 false: scenarios without a machine-wide policy must never elevate)
#   holdLock      the harness holds the Appinstaller run lock while the .cmd runs (use with
#                 expectExit 1 and expectLog 'already in progress')

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
        $p = Join-Path $env:LOCALAPPDATA "Appinstaller\$log"
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
    # Launched from pwsh on purpose: the payload must cope with inheriting pwsh's PSModulePath.
    & $Path
    $code = $LASTEXITCODE
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

$HostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$HostsBackup = $null
function Set-BlockedHosts([string[]]$Names) {
    $script:HostsBackup = Get-Content -LiteralPath $HostsPath -Raw
    $extra = ($Names | ForEach-Object { "127.0.0.1 $_" }) -join "`r`n"
    Set-Content -LiteralPath $HostsPath -Value ($script:HostsBackup + "`r`n" + $extra + "`r`n")
    ipconfig /flushdns | Out-Null
    Write-Host "Blocked hosts: $($Names -join ', ')"
}
function Restore-Hosts {
    if ($null -ne $script:HostsBackup) {
        Set-Content -LiteralPath $HostsPath -Value $script:HostsBackup
        ipconfig /flushdns | Out-Null
        $script:HostsBackup = $null
    }
}

$ForcelistKey = 'HKLM:\SOFTWARE\Policies\Google\Chrome\ExtensionInstallForcelist'
$SeedName = 'appinstaller-ci-seed'
$script:SeedKeyExisted = $false
$script:HeldLock = $null
function Set-SeedForcelist {
    $script:SeedKeyExisted = Test-Path $ForcelistKey
    if (-not $script:SeedKeyExisted) { New-Item -Path $ForcelistKey -Force | Out-Null }
    New-ItemProperty -Path $ForcelistKey -Name $SeedName -Value 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa;https://clients2.google.com/service/update2/crx' -PropertyType String -Force | Out-Null
    Write-Host 'Seeded machine-wide Chrome forcelist (HKLM).'
}
function Remove-SeedForcelist {
    if (-not (Test-Path $ForcelistKey)) { return }
    Remove-ItemProperty -Path $ForcelistKey -Name $SeedName -ErrorAction SilentlyContinue
    if (-not $script:SeedKeyExisted) { Remove-Item -Path $ForcelistKey -Force -ErrorAction SilentlyContinue }
}

function Get-InstallLogLines { 
    $p = Join-Path $env:LOCALAPPDATA 'Appinstaller\install.log'
    if (Test-Path $p) { return @(Get-Content $p) } else { return @() }
}

# Asserts whether the 1st install ran the elevated machine phase, that it finished its modules,
# and that it cleaned up its run folder.
function Assert-Phase([string[]]$NewLog, [bool]$ExpectElevated) {
    $start = ($NewLog | Select-String -SimpleMatch 'phase=machine start' | Select-Object -First 1)
    $elevated = [bool]$start
    if ($elevated -ne $ExpectElevated) { Show-Logs; throw "Expected elevated machine phase = $ExpectElevated, got $elevated" }
    if ($elevated) {
        $afterIdx = [array]::IndexOf($NewLog, $start.Line)
        $after = $NewLog[$afterIdx..($NewLog.Count - 1)]
        if (-not ($after -match "Module 'ublock-lite': done")) { Show-Logs; throw "Machine phase did not finish ublock-lite" }
        if (-not ($after -match 'phase=machine end \(ok=True\)')) { Show-Logs; throw 'Machine phase did not end ok' }
        $leftover = @(Get-ChildItem -LiteralPath (Join-Path $env:ProgramData 'Appinstaller') -Directory -Filter 'run-*' -ErrorAction SilentlyContinue)
        if ($leftover.Count -gt 0) { throw "Run folder(s) not cleaned up: $($leftover.Name -join ', ')" }
        Write-Host 'Elevated machine phase ran and cleaned up.' -ForegroundColor Green
    } else {
        Write-Host 'No elevation (as expected).' -ForegroundColor Green
    }
}

try {
    # ---- Pre-conditions ---------------------------------------------------------
    if ($ci -and $ci.seedHklmForcelist) { Set-SeedForcelist }
    if ($ci -and $ci.blockHosts) { Set-BlockedHosts @($ci.blockHosts) }
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
    $expectExit = if ($ci -and $ci.expectExit) { [int]$ci.expectExit } else { 0 }
    if ($expectExit -ne 0) {
        # Negative test: the .cmd must report failure through its process exit code.
        Step 'Install (expected to fail)'
        if ($ci -and $ci.holdLock) {
            $script:HeldLock = New-Object System.Threading.Mutex($true, 'Global\Appinstaller.run')
            Write-Host 'Harness is holding the run lock.'
        }
        & $installCmd
        $code = $LASTEXITCODE
        Show-Logs
        if ($code -ne $expectExit) { throw "Expected exit code $expectExit from the install .cmd, got $code" }
        $log = Get-Content (Join-Path $env:LOCALAPPDATA 'Appinstaller\install.log') -Raw
        $wantLog = if ($ci -and $ci.expectLog) { [string]$ci.expectLog } else { 'Install finished with failures' }
        if ($log -notmatch $wantLog) { throw "install.log has no line matching '$wantLog'" }
        Write-Host "`nScenario passed (failure propagated, exit code $code): $Fixture" -ForegroundColor Green
        # The step's own exit status is the last native exit code; the expected failure must not leak.
        $global:LASTEXITCODE = 0
        return
    }
    $logBefore = (Get-InstallLogLines).Count
    Invoke-Cmd 'Install (1st run)' $installCmd
    Assert-Phase @((Get-InstallLogLines) | Select-Object -Skip $logBefore) ([bool]($ci -and $ci.expectElevated))
    Invoke-Verify 'after 1st install'
    Invoke-Cmd 'Install (2nd run)' $installCmd
    Invoke-Cmd 'Install (3rd run)' $installCmd
    Invoke-Verify 'after 3rd install (idempotency)' -ExpectedCount 1
    Invoke-Cmd 'Uninstall' $uninstallCmd
    Invoke-Verify 'after uninstall' -ExpectAbsent

    Show-Logs
    Write-Host "`nScenario passed: $Fixture" -ForegroundColor Green
} finally {
    Restore-Hosts
    if ($script:HeldLock) { try { $script:HeldLock.ReleaseMutex() } catch {}; $script:HeldLock.Dispose() }
    if ($ci -and $ci.seedHklmForcelist) { Remove-SeedForcelist }
}
