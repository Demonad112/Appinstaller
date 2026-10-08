# Shared uninstall fragment for curated apps (see install.ps1; helpers in common.ps1). Removes an
# app only if the state file says THIS tool installed it; software that was already on the
# computer is never touched. Registered per app by the renderer: $Modules += New-AppModule -Id 'app-<id>'

function New-AppModule {
    param([string]$Id)
    $mod = [pscustomobject]@{ Id = $Id; NeedsAdmin = $null; Uninstall = $null }
    # Only apps this tool installed need removing, and only those may need the elevated child.
    $mod.NeedsAdmin = { param($Cfg) $Cfg.app.scope -eq 'machine' -and (Read-AppState 'machine').Contains([string]$Cfg.app.id) }
    $mod.Uninstall = {
        param($Cfg)
        $app = $Cfg.app
        $state = Read-AppState $app.scope
        if (-not $state.Contains([string]$app.id)) {
            Write-Log "$($app.label) was not installed by this setup; leaving it alone."
            return @()
        }
        if ($app.scope -eq 'machine' -and -not (Test-IsAdmin)) {
            throw "$($app.label) needs administrator permission to remove, and this step is not running with it."
        }
        if (Test-AppDetected $app) {
            if ($app.uninstall.type -eq 'odt') {
                Invoke-AppOdt $app 'remove'
                $code = 0
            } elseif ($app.uninstall.type -eq 'winget') {
                $wg = (Get-Command winget.exe -ErrorAction SilentlyContinue)
                if (-not $wg) { throw "winget is not available, so $($app.label) can't be removed automatically." }
                $code = Invoke-AppNative -File $wg.Source -TimeoutSec 1800 -Arguments @(
                    'uninstall', '--id', $app.source.id, '--exact', '--silent',
                    '--accept-source-agreements', '--disable-interactivity')
            } else {
                $exe = [Environment]::ExpandEnvironmentVariables([string]$app.uninstall.path)
                if (-not (Test-Path -LiteralPath $exe)) { throw "$($app.label) uninstaller not found at $exe" }
                $t = if ($app.uninstall.timeoutSec) { [int]$app.uninstall.timeoutSec } else { 900 }
                $code = Invoke-AppNative -File $exe -Arguments @($app.uninstall.args) -TimeoutSec $t
            }
            if ($code -ne 0) { throw "Removing $($app.label) failed (exit code $code)" }
            if (-not (Wait-AppDetected $app $false)) { throw "$($app.label) is still installed after the uninstaller finished." }
        }
        $state.Remove([string]$app.id)
        Write-AppState $app.scope $state
        Write-Log "$($app.label) removed."
        return "$($app.label) removed."
    }
    return $mod
}
