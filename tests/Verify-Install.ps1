# Asserts the on-disk/registry state that Install-*.cmd / Uninstall-*.cmd should produce.
# Used by .github/workflows/validate.yml on a windows-latest runner; also runnable manually
# on a real Windows machine to double-check a handoff before sending it.
#
# Usage:
#   powershell -File tests/Verify-Install.ps1 -ShortcutName "Example Site" -DestUrl "https://example.com/mom"
#   powershell -File tests/Verify-Install.ps1 -ShortcutName "Example Site" -DestUrl "..." -ExpectedCount 1
#   powershell -File tests/Verify-Install.ps1 -ShortcutName "Example Site" -DestUrl "..." -ExpectAbsent   # after Uninstall.cmd

param(
    [Parameter(Mandatory = $true)][string]$ShortcutName,
    [Parameter(Mandatory = $true)][string]$DestUrl,
    [switch]$ExpectAbsent,
    [int]$ExpectedCount = 1
)

$ErrorActionPreference = 'Stop'
$ExtId = 'ddkjiahejlhfcafbddmgiahcphecmpfh'
$failures = @()

function Get-ForcelistMatches {
    param([string]$PolicyRoot)
    $path = Join-Path $PolicyRoot 'ExtensionInstallForcelist'
    if (-not (Test-Path $path)) { return @() }
    $props = (Get-Item -Path $path).Property
    $found = @()
    foreach ($p in $props) {
        $val = (Get-ItemProperty -Path $path -Name $p -ErrorAction SilentlyContinue).$p
        if ($val -like "$ExtId;*") { $found += $val }
    }
    return $found
}

$hkcuMatches = @(Get-ForcelistMatches -PolicyRoot 'HKCU:\Software\Policies\Google\Chrome')
$hklmMatches = @()
try { $hklmMatches = @(Get-ForcelistMatches -PolicyRoot 'HKLM:\SOFTWARE\Policies\Google\Chrome') } catch {}
$allMatches = @($hkcuMatches + $hklmMatches)

if ($ExpectAbsent) {
    if ($allMatches.Count -gt 0) {
        $failures += "Expected no ExtensionInstallForcelist entries for $ExtId, found $($allMatches.Count): $($allMatches -join ', ')"
    }
} elseif ($allMatches.Count -ne $ExpectedCount) {
    $failures += "Expected exactly $ExpectedCount ExtensionInstallForcelist entry for $ExtId, found $($allMatches.Count): $($allMatches -join ', ')"
}

$safeName = ($ShortcutName -replace '[\\/:*?"<>|]', '_').Trim()
$desktop = [Environment]::GetFolderPath('Desktop')
$lnkPath = Join-Path $desktop "$safeName.lnk"
$urlPath = Join-Path $desktop "$safeName.url"
$shortcutExists = (Test-Path $lnkPath) -or (Test-Path $urlPath)

if ($ExpectAbsent) {
    if ($shortcutExists) {
        $failures += "Expected desktop shortcut to be removed, but it still exists"
    }
} elseif (-not $shortcutExists) {
    $failures += "Expected a desktop shortcut at $lnkPath or $urlPath, found neither"
} else {
    if (Test-Path $lnkPath) {
        $wsh = New-Object -ComObject WScript.Shell
        $sc = $wsh.CreateShortcut($lnkPath)
        if ($sc.Arguments -notlike "*$DestUrl*") {
            $failures += "Shortcut .lnk arguments do not contain the expected URL. Got: '$($sc.Arguments)'"
        }
    } else {
        $content = Get-Content -Path $urlPath -Raw
        if ($content -notlike "*$DestUrl*") {
            $failures += ".url shortcut does not contain the expected URL"
        }
    }
}

if ($failures.Count -gt 0) {
    Write-Host "VERIFICATION FAILED:" -ForegroundColor Red
    foreach ($f in $failures) { Write-Host " - $f" -ForegroundColor Red }
    exit 1
}

Write-Host "Verification passed." -ForegroundColor Green
exit 0
