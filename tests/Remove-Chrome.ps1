# CI test setup only: removes every Chrome install from the machine so the chrome module's
# install path can be exercised on a GitHub-hosted runner (which ships with machine-wide Chrome).
# Fails loudly if any chrome.exe is still findable afterwards.

$ErrorActionPreference = 'Stop'

Get-Process -Name chrome -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

$roots = @(
    @{ Dir = (Join-Path $env:ProgramFiles 'Google\Chrome\Application'); Level = '--system-level' },
    @{ Dir = (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application'); Level = '--system-level' },
    @{ Dir = (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application'); Level = $null }
)
foreach ($r in $roots) {
    if (-not (Test-Path $r.Dir)) { continue }
    foreach ($setup in Get-ChildItem -Path $r.Dir -Filter setup.exe -Recurse -ErrorAction SilentlyContinue) {
        $argList = @('--uninstall', '--force-uninstall') + @($r.Level | Where-Object { $_ })
        Write-Host "Running $($setup.FullName) $($argList -join ' ')"
        $p = Start-Process -FilePath $setup.FullName -ArgumentList $argList -PassThru -Wait
        Write-Host "  exit code $($p.ExitCode)"   # Chrome's uninstaller returns 19/20 on success
    }
    if (Test-Path (Join-Path $r.Dir 'chrome.exe')) {
        Write-Host "chrome.exe still present in $($r.Dir); removing the folder"
        Remove-Item -Path $r.Dir -Recurse -Force
    }
}

foreach ($k in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe')) {
    if (Test-Path $k) {
        $v = (Get-Item $k).GetValue('')
        if (-not $v -or -not (Test-Path $v)) { Remove-Item -Path $k -Recurse -Force; Write-Host "Removed stale $k" }
    }
}

$left = @(
    (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe'),
    (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe')
) | Where-Object { Test-Path $_ }
if ($left) { throw "Chrome still installed after removal: $($left -join ', ')" }
Write-Host "Chrome removed." -ForegroundColor Green
