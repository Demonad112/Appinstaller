# CI test setup only: puts a curated app (docs/apps/<AppId>.json) into a known state BEFORE a
# scenario, using the app definition's own winget ID / uninstaller (the Remove-Chrome.ps1 analog).
#   -State absent   removes it if present (7-Zip ships on the windows-latest image) and fails
#                   loudly if it is still detected afterwards
#   -State present  installs it with winget if missing (winget-source apps only)
param(
    [Parameter(Mandatory = $true)][string]$AppId,
    [Parameter(Mandatory = $true)][ValidateSet('absent', 'present')][string]$State
)
$ErrorActionPreference = 'Stop'
$app = Get-Content -LiteralPath (Join-Path $PSScriptRoot "../docs/apps/$AppId.json") -Raw | ConvertFrom-Json

function Test-Detected {
    foreach ($d in @($app.detect)) {
        if ($d.type -eq 'file') {
            if (Test-Path -LiteralPath ([Environment]::ExpandEnvironmentVariables([string]$d.path))) { return $true }
        } elseif ($d.type -eq 'c2r') {
            $c2r = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction SilentlyContinue
            if ($c2r -and $c2r.ProductReleaseIds -and ([string]$c2r.ProductReleaseIds -match $d.product)) { return $true }
        } elseif ($d.type -eq 'arp') {
            foreach ($r in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
                if (Get-ItemProperty -Path $r -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -and $_.DisplayName -match $d.displayName }) { return $true }
            }
        }
    }
    return $false
}
function Wait-State([bool]$Want) {
    for ($i = 0; $i -lt 45; $i++) { if ((Test-Detected) -eq $Want) { return $true }; Start-Sleep -Seconds 2 }
    return $false
}

if ($State -eq 'absent') {
    if (-not (Test-Detected)) { Write-Host "$($app.label): not present (nothing to remove)."; return }
    Write-Host "Removing $($app.label) (test setup)"
    if ($app.uninstall.type -eq 'odt') {
        throw "$($app.label) is already installed on this computer; Set-App has no odt remover (the runner image doesn't ship it)."
    } elseif ($app.uninstall.type -eq 'winget') {
        winget uninstall --id $app.source.id --exact --silent --accept-source-agreements --disable-interactivity
    } else {
        $p = Start-Process -FilePath ([Environment]::ExpandEnvironmentVariables([string]$app.uninstall.path)) -ArgumentList @($app.uninstall.args) -PassThru -Wait
        Write-Host "  exit code $($p.ExitCode)"
    }
    if (-not (Wait-State $false)) { throw "$($app.label) still detected after removal" }
    Write-Host "$($app.label) removed." -ForegroundColor Green
} else {
    if (Test-Detected) { Write-Host "$($app.label): already present."; return }
    if ($app.source.type -ne 'winget') { throw "Set-App -State present only supports winget-source apps" }
    Write-Host "Installing $($app.label) (test setup)"
    winget install --id $app.source.id --exact --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity
    if (-not (Wait-State $true)) { throw "$($app.label) not detected after install" }
    Write-Host "$($app.label) present." -ForegroundColor Green
}
