# Asserts the uBlock Origin Lite forcelist state: exactly -ExpectedCount entries across HKCU+HKLM
# after install, none after uninstall.
param(
    [Parameter(Mandatory = $true)]$Cfg,
    [switch]$ExpectAbsent,
    [int]$ExpectedCount = 1
)

$ExtId = 'ddkjiahejlhfcafbddmgiahcphecmpfh'
$failures = @()

function Get-ForcelistMatches {
    param([string]$PolicyRoot)
    $path = Join-Path $PolicyRoot 'ExtensionInstallForcelist'
    if (-not (Test-Path $path)) { return @() }
    $found = @()
    foreach ($p in (Get-Item -Path $path).Property) {
        $val = (Get-ItemProperty -Path $path -Name $p -ErrorAction SilentlyContinue).$p
        if ($val -like "$ExtId;*") { $found += $val }
    }
    return $found
}

$all = @(Get-ForcelistMatches -PolicyRoot 'HKCU:\Software\Policies\Google\Chrome')
try { $all += @(Get-ForcelistMatches -PolicyRoot 'HKLM:\SOFTWARE\Policies\Google\Chrome') } catch {}

if ($ExpectAbsent) {
    if ($all.Count -gt 0) { $failures += "Expected no forcelist entries for $ExtId, found $($all.Count): $($all -join ', ')" }
} else {
    if ($all.Count -ne $ExpectedCount) { $failures += "Expected exactly $ExpectedCount forcelist entry for $ExtId, found $($all.Count): $($all -join ', ')" }
    if ($Cfg.pinToolbar) {
        $pin = (Get-ItemProperty -Path "HKCU:\Software\Policies\Google\Chrome\ExtensionSettings\$ExtId" -Name toolbar_pin -ErrorAction SilentlyContinue).toolbar_pin
        if ($pin -ne 'force_pinned') { $failures += "Expected ExtensionSettings\$ExtId\toolbar_pin = force_pinned, got '$pin'" }
    }
}
return $failures
