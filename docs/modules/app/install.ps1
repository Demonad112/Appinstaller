# Shared install fragment for every curated app (docs/apps/<id>.json). The renderer emits this
# text once and registers each selected app with: $Modules += New-AppModule -Id 'app-<id>'
# The app definition (source, detect, uninstall) arrives as $Cfg.app, embedded in the config.
#
# Rules: an already-installed app (any detect entry matches) is left alone and not recorded;
# winget sources always run with --source winget --exact (the package ID is the pin, winget
# verifies the manifest hash); url sources are verified (SHA-256 and/or Authenticode signer)
# BEFORE the installer is launched; any failure throws, so the run exits non-zero.
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

# Runs a program, logs its output, enforces a timeout; returns the exit code.
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

function Get-WingetPath {
    $c = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    throw "winget (Windows Package Manager / App Installer) is not available on this computer, so this app can't be installed. Update 'App Installer' from the Microsoft Store and run this again."
}

function Install-AppWinget {
    param($App)
    $wg = Get-WingetPath
    $code = Invoke-AppNative -File $wg -TimeoutSec 1800 -Arguments @(
        'install', '--id', $App.source.id, '--exact', '--source', 'winget', '--silent',
        '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
    if ($code -ne 0) { throw "winget could not install $($App.label) (exit code $code)" }
}

function Install-AppUrl {
    param($App)
    $s = $App.source
    $name = [IO.Path]::GetFileName(([uri]$s.url).AbsolutePath)
    $exe = Join-Path $env:TEMP ("Appinstaller-" + [guid]::NewGuid().ToString('N') + "-" + $name)
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $ProgressPreference = 'SilentlyContinue'   # the progress bar makes 5.1 downloads crawl
        Write-Log "Downloading $($App.label) from $($s.url)"
        Invoke-WebRequest -Uri $s.url -OutFile $exe -UseBasicParsing
        if ($s.sha256) {
            $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $exe).Hash.ToLower()
            Write-Log "Installer SHA-256: $hash"
            if ($hash -ne $s.sha256) { throw "Downloaded $($App.label) installer failed verification (SHA-256 mismatch); nothing was installed." }
        }
        if ($s.signer) {
            $sig = Get-AuthenticodeSignature -FilePath $exe
            $subject = if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { '' }
            Write-Log "Installer signature: $($sig.Status) / $subject"
            if ($sig.Status -ne 'Valid' -or $subject -notmatch $s.signer) {
                throw "Downloaded $($App.label) installer failed verification (signature $($sig.Status), '$subject'); nothing was installed."
            }
        }
        $timeout = if ($s.timeoutSec) { [int]$s.timeoutSec } else { 900 }
        $code = Invoke-AppNative -File $exe -Arguments @($s.args) -TimeoutSec $timeout
        if ($code -ne 0 -and $code -ne 3010) { throw "The $($App.label) installer exited with code $code" }
    } finally {
        Remove-Item -LiteralPath $exe -Force -ErrorAction SilentlyContinue
    }
}

function New-AppModule {
    param([string]$Id)
    $mod = [pscustomobject]@{ Id = $Id; NeedsAdmin = $null; Install = $null }
    # Machine apps only need the elevated child when there is something to install.
    $mod.NeedsAdmin = { param($Cfg) -not (Test-AppDetected $Cfg.app) }
    $mod.Install = {
        param($Cfg, $Ctx)
        $app = $Cfg.app
        if (Test-AppDetected $app) {
            Write-Log "$($app.label) is already installed; leaving it as is."
            return "$($app.label) is already installed."
        }
        if ($app.scope -eq 'machine' -and -not (Test-IsAdmin)) {
            throw "$($app.label) needs administrator permission to install, and this step is not running with it."
        }
        if ($app.source.type -eq 'winget') { Install-AppWinget $app } else { Install-AppUrl $app }
        if (-not (Wait-AppDetected $app $true)) { throw "$($app.label) installer finished but the app was not found afterwards." }
        $state = Read-AppState $app.scope
        $state[$app.id] = [ordered]@{ installedBy = 'appinstaller'; source = $app.source.type; at = (Get-Date).ToString('o') }
        Write-AppState $app.scope $state
        Write-Log "$($app.label) installed."
        return "$($app.label) installed."
    }
    return $mod
}
