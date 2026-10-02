# Removes the uBlock Origin Lite forcelist entry and its toolbar-pin policy from HKCU and, when
# running elevated, HKLM. Machine scope with a dynamic NeedsAdmin: only a machine-wide entry of
# ours makes the core run this in the elevated child.

$UBlockExtId = 'ddkjiahejlhfcafbddmgiahcphecmpfh'

function Remove-ForceInstallEntry {
    param([string]$PolicyRoot)
    $forcelistPath = Join-Path $PolicyRoot 'ExtensionInstallForcelist'
    if (-not (Test-Path $forcelistPath)) { return }
    $props = (Get-Item -Path $forcelistPath).Property
    foreach ($p in $props) {
        $val = (Get-ItemProperty -Path $forcelistPath -Name $p -ErrorAction SilentlyContinue).$p
        if ($val -like "$UBlockExtId;*") {
            Remove-ItemProperty -Path $forcelistPath -Name $p -ErrorAction SilentlyContinue
            Write-Log "Removed forcelist entry '$p' from $PolicyRoot"
        }
    }
    $settingsPath = Join-Path (Join-Path $PolicyRoot 'ExtensionSettings') $UBlockExtId
    if (Test-Path $settingsPath) {
        Remove-Item -Path $settingsPath -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log "Removed ExtensionSettings entry from $settingsPath"
    }
}

function Test-HklmEntryPresent {
    $hklmForcelist = 'HKLM:\SOFTWARE\Policies\Google\Chrome\ExtensionInstallForcelist'
    try {
        if (Test-Path $hklmForcelist) {
            foreach ($p in (Get-Item $hklmForcelist).Property) {
                $val = (Get-ItemProperty -Path $hklmForcelist -Name $p -ErrorAction SilentlyContinue).$p
                if ($val -like "$UBlockExtId;*") { return $true }
            }
        }
    } catch {}
    return $false
}

$Modules += [pscustomobject]@{
    Id         = 'ublock-lite'
    NeedsAdmin = { param($Cfg) Test-HklmEntryPresent }
    Uninstall  = {
        param($Cfg)
        Remove-ForceInstallEntry -PolicyRoot 'HKCU:\Software\Policies\Google\Chrome'
        if (Test-IsAdmin) {
            Remove-ForceInstallEntry -PolicyRoot 'HKLM:\SOFTWARE\Policies\Google\Chrome'
        }
        return "Removed the ad-blocker policy."
    }
}
