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
        } elseif ($d.type -eq 'c2r') {
            # Office Click-to-Run: the installed product IDs, not just any Office file, so a
            # different or half-removed product doesn't count.
            $c2r = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction SilentlyContinue
            if ($c2r -and $c2r.ProductReleaseIds -and ([string]$c2r.ProductReleaseIds -match $d.product)) { return $true }
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

# Office Deployment Tool (source.type "odt"): downloads setup.exe, requires a Valid Authenticode
# signature from source.signer BEFORE launching it, writes a configuration.xml in %TEMP% (deleted
# afterwards) and runs `setup.exe /configure`. -Mode install adds source.product (minus excludeApps);
# -Mode remove removes it. The catalog schema restricts every interpolated value to safe characters.
function Invoke-AppOdt {
    param($App, [ValidateSet('install', 'remove')][string]$Mode)
    $s = $App.source
    $id = [guid]::NewGuid().ToString('N')
    $exe = Join-Path $env:TEMP "Appinstaller-$id-setup.exe"
    $cfgFile = Join-Path $env:TEMP "Appinstaller-$id-office.xml"
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $ProgressPreference = 'SilentlyContinue'
        Write-Log "Downloading the Office Deployment Tool from $($s.url)"
        Invoke-WebRequest -Uri $s.url -OutFile $exe -UseBasicParsing
        $sig = Get-AuthenticodeSignature -FilePath $exe
        $subject = if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { '' }
        Write-Log "Office Deployment Tool signature: $($sig.Status) / $subject"
        if ($sig.Status -ne 'Valid' -or $subject -notmatch $s.signer) {
            throw "The Office Deployment Tool failed verification (signature $($sig.Status), '$subject'); nothing was changed."
        }
        Unblock-File -LiteralPath $exe -ErrorAction SilentlyContinue
        $lines = @('<Configuration>')
        if ($Mode -eq 'install') {
            $edition = if ($s.edition) { [string]$s.edition } else { '64' }
            $channel = if ($s.channel) { [string]$s.channel } else { 'Current' }
            $lang = if ($s.language) { [string]$s.language } else { 'MatchOS' }
            $lines += "  <Add OfficeClientEdition=`"$edition`" Channel=`"$channel`">"
            $lines += "    <Product ID=`"$($s.product)`">"
            $lines += "      <Language ID=`"$lang`" />"
            foreach ($x in @($s.excludeApps)) { if ($x) { $lines += "      <ExcludeApp ID=`"$x`" />" } }
            $lines += '    </Product>'
            $lines += '  </Add>'
            $lines += '  <Updates Enabled="TRUE" />'
        } else {
            $lines += '  <Remove All="FALSE">'
            $lines += "    <Product ID=`"$($s.product)`" />"
            $lines += '  </Remove>'
        }
        $lines += '  <Display Level="None" AcceptEULA="TRUE" />'
        $lines += '  <Property Name="FORCEAPPSHUTDOWN" Value="TRUE" />'
        $lines += '</Configuration>'
        Set-Content -LiteralPath $cfgFile -Value $lines -Encoding UTF8
        $timeout = if ($s.timeoutSec) { [int]$s.timeoutSec } else { 3000 }
        $code = Invoke-AppNative -File $exe -Arguments @('/configure', ('"' + $cfgFile + '"')) -TimeoutSec $timeout
        if ($code -ne 0 -and $code -ne 3010) { throw "The Office Deployment Tool ($Mode) exited with code $code" }
    } finally {
        Remove-Item -LiteralPath $exe, $cfgFile -Force -ErrorAction SilentlyContinue
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
