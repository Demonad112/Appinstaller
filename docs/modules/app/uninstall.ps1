# Shared uninstall fragment for curated apps (see install.ps1). Removes an app only if the state
# file says THIS tool installed it; software that was already on the computer is never touched.
# Registered per app by the renderer: $Modules += New-AppModule -Id 'app-<id>'

function Get-AppStatePath {
    param([string]$Scope)
    $dir = if ($Scope -eq 'machine') { Join-Path $env:ProgramData 'Appinstaller' } else { $LogDir }
    return (Join-Path $dir 'apps-state.json')
}

function Read-AppState {
    param([string]$Scope)
    $p = Get-AppStatePath $Scope
    $state = [ordered]@{}
    if (Test-Path -LiteralPath $p) {
        try {
            $obj = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json
            foreach ($prop in $obj.PSObject.Properties) { $state[$prop.Name] = $prop.Value }
        } catch { Write-Log "Could not read $p ($($_.Exception.Message)); treating as empty." }
    }
    return $state
}

function Write-AppState {
    param([string]$Scope, $State)
    $p = Get-AppStatePath $Scope
    if ($State.Count -eq 0) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue; return }
    ($State | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $p -Encoding UTF8
}

function Test-AppDetected {
    param($App)
    foreach ($d in @($App.detect)) {
        if ($d.type -eq 'file') {
            $f = [Environment]::ExpandEnvironmentVariables([string]$d.path)
            if (Test-Path -LiteralPath $f) { return $true }
        } elseif ($d.type -eq 'arp') {
            $roots = @(
                'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
                'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
            )
            foreach ($r in $roots) {
                $hit = Get-ItemProperty -Path $r -ErrorAction SilentlyContinue | Where-Object {
                    $_.DisplayName -and ($_.DisplayName -match $d.displayName) -and
                    ((-not $d.publisher) -or ($_.Publisher -and ($_.Publisher -match $d.publisher)))
                } | Select-Object -First 1
                if ($hit) { return $true }
            }
        }
    }
    return $false
}

# Some installers/uninstallers (NSIS) hand off to a detached copy of themselves and exit at once.
# Poll briefly until detection reaches the wanted state; returns whether it did.
function Wait-AppDetected {
    param($App, [bool]$Want, [int]$TimeoutSec = 90)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ($true) {
        if ((Test-AppDetected $App) -eq $Want) { return $true }
        if ((Get-Date) -gt $deadline) { return $false }
        Start-Sleep -Seconds 2
    }
}

function Invoke-AppNative {
    param([string]$File, [string[]]$Arguments, [int]$TimeoutSec = 900)
    $out = Join-Path $env:TEMP ('appi-' + [guid]::NewGuid().ToString('N') + '.out')
    $err = Join-Path $env:TEMP ('appi-' + [guid]::NewGuid().ToString('N') + '.err')
    try {
        $sp = @{ FilePath = $File; PassThru = $true; WindowStyle = 'Hidden'; RedirectStandardOutput = $out; RedirectStandardError = $err }
        if ($Arguments -and $Arguments.Count -gt 0) { $sp.ArgumentList = $Arguments }
        $p = Start-Process @sp
        if (-not $p.WaitForExit($TimeoutSec * 1000)) {
            try { $p.Kill() } catch {}
            throw "$([IO.Path]::GetFileName($File)) did not finish within $TimeoutSec seconds"
        }
        $p.WaitForExit()   # flushes redirected output and makes ExitCode reliable after the timed wait
        foreach ($f in @($out, $err)) {
            if (Test-Path -LiteralPath $f) {
                Get-Content -LiteralPath $f -ErrorAction SilentlyContinue | Where-Object { $_ -match '[A-Za-z0-9]' -and $_ -notmatch '^\s*[-\\|/]\s*$' -and $_ -notmatch '[█▒]' } | ForEach-Object { Write-Log "  | $_" }
            }
        }
        Write-Log ("{0} exit code {1}" -f [IO.Path]::GetFileName($File), $p.ExitCode)
        return [int]$p.ExitCode
    } finally {
        Remove-Item -LiteralPath $out, $err -Force -ErrorAction SilentlyContinue
    }
}

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
            if ($app.uninstall.type -eq 'winget') {
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
