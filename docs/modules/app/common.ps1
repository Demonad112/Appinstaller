# Helpers shared by the curated-app install and uninstall fragments. The renderer emits this text
# once, right before docs/modules/app/<kind>.ps1, whenever any app-<id> module is selected.
# State: %ProgramData%\Appinstaller\apps-state.json (machine scope) or
# %LOCALAPPDATA%\Appinstaller\apps-state.json (user scope) records apps THIS tool installed, so
# the uninstaller never removes software that was already on the computer.

function Get-AppStatePath {
    param([string]$Scope)
    $dir = if ($Scope -eq 'machine') { Join-Path $env:ProgramData 'Appinstaller' } else { $LogDir }
    New-Item -ItemType Directory -Path $dir -Force -ErrorAction SilentlyContinue | Out-Null
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

# True when any detect entry matches: a file that exists, or an Add/Remove Programs entry.
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

# Runs a program, logs its output, enforces a timeout; returns the exit code.
function Invoke-AppNative {
    param([string]$File, [string[]]$Arguments, [int]$TimeoutSec = 900)
    $out = Join-Path $env:TEMP ('appi-' + [guid]::NewGuid().ToString('N') + '.out')
    $err = Join-Path $env:TEMP ('appi-' + [guid]::NewGuid().ToString('N') + '.err')
    try {
        $sp = @{ FilePath = $File; PassThru = $true; WindowStyle = 'Hidden'; RedirectStandardOutput = $out; RedirectStandardError = $err }
        if ($Arguments -and $Arguments.Count -gt 0) { $sp.ArgumentList = $Arguments }
        $p = Start-Process @sp
        $null = $p.Handle   # caches the handle so ExitCode is readable in Windows PowerShell 5.1
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
        if ($null -eq $p.ExitCode) { throw "Could not read the exit code of $([IO.Path]::GetFileName($File)); treating it as failed." }
        Write-Log ("{0} exit code {1}" -f [IO.Path]::GetFileName($File), $p.ExitCode)
        return [int]$p.ExitCode
    } finally {
        Remove-Item -LiteralPath $out, $err -Force -ErrorAction SilentlyContinue
    }
}
