# uBlock Origin Lite (MV3), force-installed via Chrome's ExtensionInstallForcelist policy.
# HKCU needs no admin. A pre-existing machine-wide (HKLM) forcelist wins over HKCU entirely
# (policy sources don't merge), so that case -- and only that case -- requests elevation.
# Options: pinToolbar (bool), autoRestartChrome (bool)

$UBlockExtId = 'ddkjiahejlhfcafbddmgiahcphecmpfh'   # uBlock Origin Lite, Chrome Web Store
$UBlockUpdateUrl = 'https://clients2.google.com/service/update2/crx'

function Test-HklmForcelistPresent {
    $hklmForcelist = 'HKLM:\SOFTWARE\Policies\Google\Chrome\ExtensionInstallForcelist'
    try {
        if (Test-Path $hklmForcelist) {
            return (@((Get-Item $hklmForcelist).Property).Count -gt 0)
        }
    } catch {}
    return $false
}

function Set-ForceInstallPolicy {
    param([string]$PolicyRoot, [string]$ExtEntry)
    $forcelistPath = Join-Path $PolicyRoot 'ExtensionInstallForcelist'
    if (-not (Test-Path $forcelistPath)) {
        New-Item -Path $forcelistPath -Force | Out-Null
    }
    $extId = $ExtEntry.Split(';')[0]
    $existingProps = (Get-Item -Path $forcelistPath).Property
    $matchName = $null
    foreach ($p in $existingProps) {
        $val = (Get-ItemProperty -Path $forcelistPath -Name $p -ErrorAction SilentlyContinue).$p
        if ($val -like "$extId;*") { $matchName = $p; break }
    }
    if ($matchName) {
        Set-ItemProperty -Path $forcelistPath -Name $matchName -Value $ExtEntry -Type String
        Write-Log "Updated existing forcelist entry '$matchName' under $PolicyRoot"
    } else {
        $used = @($existingProps | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ })
        $next = 1
        while ($used -contains $next) { $next++ }
        New-ItemProperty -Path $forcelistPath -Name "$next" -Value $ExtEntry -PropertyType String -Force | Out-Null
        Write-Log "Added forcelist entry '$next' under $PolicyRoot"
    }
}

function Set-ToolbarPin {
    param([string]$PolicyRoot, [string]$ExtId)
    # Dictionary policy (ExtensionSettings) expressed as nested registry keys, per Chrome's
    # schema-based registry expansion for Windows. Cosmetic only -- install itself stays on
    # ExtensionInstallForcelist above.
    $settingsPath = Join-Path (Join-Path $PolicyRoot 'ExtensionSettings') $ExtId
    New-Item -Path $settingsPath -Force | Out-Null
    Set-ItemProperty -Path $settingsPath -Name 'toolbar_pin' -Value 'force_pinned' -Type String
    Write-Log "Pinned extension toolbar icon under $settingsPath"
}

$Modules += [pscustomobject]@{
    Id         = 'ublock-lite'
    NeedsAdmin = { param($Cfg) Test-HklmForcelistPresent }
    Install    = {
        param($Cfg, $Ctx)
        if (-not $Ctx.ChromePath) {
            Write-Log "Chrome was not found on this machine; skipping ad-blocker install."
            return "Chrome wasn't found on this computer, so the ad blocker step was skipped."
        }
        $policyRoot = if (Test-HklmForcelistPresent) { 'HKLM:\SOFTWARE\Policies\Google\Chrome' } else { 'HKCU:\Software\Policies\Google\Chrome' }
        Set-ForceInstallPolicy -PolicyRoot $policyRoot -ExtEntry "$UBlockExtId;$UBlockUpdateUrl"
        if ($Cfg.pinToolbar) { Set-ToolbarPin -PolicyRoot $policyRoot -ExtId $UBlockExtId }

        if ($Cfg.autoRestartChrome -and (Get-Process -Name 'chrome' -ErrorAction SilentlyContinue)) {
            Write-Log "Restarting Chrome so the ad blocker takes effect immediately."
            Stop-Process -Name 'chrome' -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 1
            Start-Process -FilePath $Ctx.ChromePath
            return "Ad blocker installed and Chrome restarted."
        }
        return "Ad blocker installed. It finishes turning on the next time Chrome opens (usually within a few seconds if Chrome is already open)."
    }
}
