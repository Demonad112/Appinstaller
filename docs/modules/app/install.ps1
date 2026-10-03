# Shared install fragment for every curated app (docs/apps/<id>.json). The renderer emits this
# text once (after docs/modules/app/common.ps1) and registers each selected app with:
# $Modules += New-AppModule -Id 'app-<id>'
# The app definition (source, detect, uninstall) arrives as $Cfg.app, embedded in the config.
#
# Rules: an already-installed app (any detect entry matches) is left alone and not recorded;
# winget sources always run with --source winget --exact (the package ID is the pin, winget
# verifies the manifest hash); url and bundled installers are copied to %TEMP% and that copy is
# verified (SHA-256 and/or Authenticode signer) BEFORE it is launched; any failure throws, so the
# run exits non-zero.

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

# Verifies an installer copy in %TEMP% against the app's pins, then runs it. $What names where it
# came from in messages ("Downloaded" / "Bundled").
function Invoke-VerifiedInstaller {
    param($App, [string]$Exe, [string]$What)
    $s = $App.source
    if ($s.sha256) {
        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $Exe).Hash.ToLower()
        Write-Log "Installer SHA-256: $hash"
        if ($hash -ne $s.sha256) { throw "$What $($App.label) installer failed verification (SHA-256 mismatch); nothing was installed." }
    }
    if ($s.signer) {
        $sig = Get-AuthenticodeSignature -FilePath $Exe
        $subject = if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { '' }
        Write-Log "Installer signature: $($sig.Status) / $subject"
        if ($sig.Status -ne 'Valid' -or $subject -notmatch $s.signer) {
            throw "$What $($App.label) installer failed verification (signature $($sig.Status), '$subject'); nothing was installed."
        }
    }
    # Verified, so drop the downloaded-from-the-internet mark: otherwise Windows can stop a silent
    # install with an "Open File - Security Warning" prompt.
    Unblock-File -LiteralPath $Exe -ErrorAction SilentlyContinue
    $timeout = if ($s.timeoutSec) { [int]$s.timeoutSec } else { 900 }
    $code = Invoke-AppNative -File $Exe -Arguments @($s.args) -TimeoutSec $timeout
    if ($code -ne 0 -and $code -ne 3010) { throw "The $($App.label) installer exited with code $code" }
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
        Invoke-VerifiedInstaller $App $exe 'Downloaded'
    } finally {
        Remove-Item -LiteralPath $exe -Force -ErrorAction SilentlyContinue
    }
}

# The installer ships in the bundle's files\ folder next to the .cmd. It is copied first and the
# copy is what gets verified and run, so the file can't be swapped between check and launch.
function Install-AppBundled {
    param($App)
    $s = $App.source
    $name = [string]$s.file
    if ([IO.Path]::GetFileName($name) -ne $name) { throw "Invalid bundled file name for $($App.label)." }
    $src = if ($BundleDir) { Join-Path (Join-Path $BundleDir 'files') $name } else { $null }
    if (-not $src -or -not (Test-Path -LiteralPath $src)) {
        throw "The $($App.label) installer ($name) was not found next to this setup file. Extract the whole zip first (right-click it, Extract All), then run the setup from the extracted folder."
    }
    $exe = Join-Path $env:TEMP ("Appinstaller-" + [guid]::NewGuid().ToString('N') + "-" + $name)
    try {
        Copy-Item -LiteralPath $src -Destination $exe -Force
        Write-Log "Using bundled installer $src"
        Invoke-VerifiedInstaller $App $exe 'Bundled'
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
        switch ($app.source.type) {
            'winget' { Install-AppWinget $app }
            'url' { Install-AppUrl $app }
            'bundled' { Install-AppBundled $app }
            default { throw "Unknown source type '$($app.source.type)' for $($app.label)." }
        }
        if (-not (Wait-AppDetected $app $true)) { throw "$($app.label) installer finished but the app was not found afterwards." }
        $state = Read-AppState $app.scope
        $state[$app.id] = [ordered]@{ installedBy = 'appinstaller'; source = $app.source.type; at = (Get-Date).ToString('o') }
        Write-AppState $app.scope $state
        Write-Log "Installed $($app.label) ($($app.source.type))."
        return "$($app.label) installed."
    }
    return $mod
}
