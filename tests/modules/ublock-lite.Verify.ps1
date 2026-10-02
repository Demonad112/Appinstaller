# Asserts the uBlock Origin Lite forcelist state: exactly -ExpectedCount entries across HKCU+HKLM
# after install, none after uninstall. With $Ci.seedHklmForcelist (a machine-wide forcelist exists,
# so the elevated child must have written HKLM) the entry must be in HKLM and not in HKCU.
param(
    [Parameter(Mandatory = $true)]$Cfg,
    $Ci,
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

$hkcuRoot = 'HKCU:\Software\Policies\Google\Chrome'
$hklmRoot = 'HKLM:\SOFTWARE\Policies\Google\Chrome'
$hkcuMatches = @(Get-ForcelistMatches -PolicyRoot $hkcuRoot)
$hklmMatches = @()
try { $hklmMatches = @(Get-ForcelistMatches -PolicyRoot $hklmRoot) } catch {}
$all = @($hkcuMatches) + @($hklmMatches)
$machineWide = [bool]($Ci -and $Ci.seedHklmForcelist)

if ($ExpectAbsent) {
    if ($all.Count -gt 0) { $failures += "Expected no forcelist entries for $ExtId, found $($all.Count): $($all -join ', ')" }
} else {
    if ($all.Count -ne $ExpectedCount) { $failures += "Expected exactly $ExpectedCount forcelist entry for $ExtId, found $($all.Count): $($all -join ', ')" }
    if ($machineWide) {
        if ($hklmMatches.Count -ne $ExpectedCount) { $failures += "Expected the entry in HKLM (written by the elevated phase), found $($hklmMatches.Count) there" }
        if ($hkcuMatches.Count -ne 0) { $failures += "Expected nothing in HKCU while a machine-wide forcelist exists, found $($hkcuMatches.Count)" }
    } elseif ($hklmMatches.Count -ne 0) {
        $failures += "Expected nothing in HKLM, found $($hklmMatches.Count)"
    }
    if ($Cfg.pinToolbar) {
        $pinRoot = if ($machineWide) { $hklmRoot } else { $hkcuRoot }
        $pin = (Get-ItemProperty -Path "$pinRoot\ExtensionSettings\$ExtId" -Name toolbar_pin -ErrorAction SilentlyContinue).toolbar_pin
        if ($pin -ne 'force_pinned') { $failures += "Expected $pinRoot\ExtensionSettings\$ExtId\toolbar_pin = force_pinned, got '$pin'" }
    }
}
return $failures
