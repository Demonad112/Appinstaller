# Removes the uBlock Origin Lite forcelist entry and its toolbar-pin policy, from HKCU and (when
# elevated, or by relaunching elevated if a machine-wide entry exists) HKLM.

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

$Modules += [pscustomobject]@{
    Id        = 'ublock-lite'
    Uninstall = {
        param($Cfg)
        Remove-ForceInstallEntry -PolicyRoot 'HKCU:\Software\Policies\Google\Chrome'
        if (Test-IsAdmin) {
            Remove-ForceInstallEntry -PolicyRoot 'HKLM:\SOFTWARE\Policies\Google\Chrome'
        } else {
            $hklmForcelist = 'HKLM:\SOFTWARE\Policies\Google\Chrome\ExtensionInstallForcelist'
            $hasHklm = (Test-Path $hklmForcelist) -and (@((Get-Item $hklmForcelist).Property).Count -gt 0)
            if ($hasHklm) {
                Write-Log "Machine-wide entry detected; relaunching elevated to remove it."
                Start-Process -FilePath $env:SELF -Verb RunAs -Wait
            }
        }
        return "Removed the ad-blocker policy."
    }
}
