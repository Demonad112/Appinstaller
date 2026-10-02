# Google Chrome, installed per-user (no admin) only when no Chrome is present at all.
# Uses Google's per-user standalone installer, run only if its Authenticode signature is valid
# and from Google LLC. Never reinstalls, upgrades, or downgrades an existing Chrome.
# Records what it did in %LOCALAPPDATA%\Appinstaller\chrome-state.json.
# Options: none
#
# Why not winget: verified on windows-latest that `winget install Google.Chrome --scope user`
# fails with 0x8A150010 (no applicable installer) -- the package only ships a machine-scope
# MSI, which would force a UAC prompt and install for every account on the PC.

# needsadmin=false in the tag makes Google's installer do a per-user install even when elevated.
$ChromeDirectUrl = 'https://dl.google.com/tag/s/appguid%3D%7B8A69D345-D564-463C-AFF1-A69D9E530F96%7D%26iid%3D%7B00000000-0000-0000-0000-000000000000%7D%26lang%3Den%26browser%3D4%26usagestats%3D0%26appname%3DGoogle%2520Chrome%26needsadmin%3Dfalse%26ap%3Dx64-stable-statsdef_1%26installdataindex%3Dempty/chrome/install/ChromeStandaloneSetup64.exe'
$ChromeInstallTimeoutSec = 900

function Install-ChromeDirect {
    $exe = Join-Path $env:TEMP 'Appinstaller-ChromeStandaloneSetup64.exe'
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $ProgressPreference = 'SilentlyContinue'   # the progress bar makes 5.1 downloads crawl
        Write-Log "Downloading Chrome standalone installer"
        Invoke-WebRequest -Uri $ChromeDirectUrl -OutFile $exe -UseBasicParsing
        $sig = Get-AuthenticodeSignature -FilePath $exe
        $subject = if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { '' }
        Write-Log "Installer signature: $($sig.Status) / $subject"
        if ($sig.Status -ne 'Valid' -or $subject -notmatch '(^|, )O=Google LLC(,|$)') {
            throw "Downloaded Chrome installer failed signature verification ($($sig.Status), '$subject')"
        }
        $p = Start-Process -FilePath $exe -ArgumentList '/silent', '/install' -PassThru
        if (-not $p.WaitForExit($ChromeInstallTimeoutSec * 1000)) {
            throw "Chrome installer did not finish within $ChromeInstallTimeoutSec seconds"
        }
        Write-Log "Chrome standalone installer exit code $($p.ExitCode)"
        if ($p.ExitCode -ne 0) { throw "Chrome installer exited with code $($p.ExitCode)" }
    } finally {
        Remove-Item -LiteralPath $exe -Force -ErrorAction SilentlyContinue
    }
}

$Modules += [pscustomobject]@{
    Id         = 'chrome'
    NeedsAdmin = { param($Cfg) $false }
    Install    = {
        param($Cfg, $Ctx)
        if ($Ctx.ChromePath) {
            Write-Log "Chrome already installed at $($Ctx.ChromePath); leaving it as is."
            return "Chrome is already installed."
        }
        Install-ChromeDirect
        $Ctx.ChromePath = Find-Chrome
        if (-not $Ctx.ChromePath) { throw "Chrome installer finished but chrome.exe was not found" }

        $state = [ordered]@{ chromeInstalledBy = 'appinstaller'; method = 'direct'; path = $Ctx.ChromePath; at = (Get-Date).ToString('o') }
        $state | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $LogDir 'chrome-state.json')
        Write-Log "Chrome installed at $($Ctx.ChromePath)"
        return "Google Chrome installed."
    }
}
