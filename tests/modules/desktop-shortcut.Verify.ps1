# Asserts the desktop shortcut exists and points at destUrl after install, and is gone after
# uninstall. -ExpectLnk additionally requires the Chrome app-window .lnk (not the .url fallback).
param(
    [Parameter(Mandatory = $true)]$Cfg,
    $Ci,
    [switch]$ExpectAbsent,
    [int]$ExpectedCount = 1
)

$failures = @()
$safeName = ($Cfg.name -replace '[\\/:*?"<>|]', '_').Trim()
$desktop = [Environment]::GetFolderPath('Desktop')
$lnkPath = Join-Path $desktop "$safeName.lnk"
$urlPath = Join-Path $desktop "$safeName.url"
$exists = (Test-Path -LiteralPath $lnkPath) -or (Test-Path -LiteralPath $urlPath)

if ($ExpectAbsent) {
    if ($exists) { $failures += "Expected desktop shortcut to be removed, but it still exists" }
} elseif (-not $exists) {
    $failures += "Expected a desktop shortcut at $lnkPath or $urlPath, found neither"
} elseif (Test-Path -LiteralPath $lnkPath) {
    $sc = (New-Object -ComObject WScript.Shell).CreateShortcut($lnkPath)
    if ($sc.Arguments -notlike "*$($Cfg.destUrl)*") {
        $failures += "Shortcut .lnk arguments do not contain the expected URL. Got: '$($sc.Arguments)'"
    }
    if ($Cfg.iconPath -and $sc.IconLocation -notlike '*Appinstaller\Icons\*.ico*') {
        $failures += "Shortcut icon should come from Appinstaller\Icons, got '$($sc.IconLocation)'"
    }
    if ($sc.TargetPath -notlike '*\chrome.exe') {
        $failures += "Shortcut .lnk target is not chrome.exe. Got: '$($sc.TargetPath)'"
    }
} else {
    if ($Cfg.style -eq 'App') { $failures += "Style 'App' with Chrome present should produce a .lnk, got only a .url" }
    if ((Get-Content -LiteralPath $urlPath -Raw) -notlike "*$($Cfg.destUrl)*") {
        $failures += ".url shortcut does not contain the expected URL"
    }
}
return $failures
