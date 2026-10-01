# Google Chrome, installed per-user (no admin) only when no Chrome is present at all.
# Primary: winget, pinned package id, user scope. Fallback (winget missing or failed): Google's
# per-user standalone installer, run only if its Authenticode signature is valid and from
# Google LLC. Never reinstalls, upgrades, or downgrades an existing Chrome.
# Records what it did in %LOCALAPPDATA%\MomSetup\chrome-state.json.
# Options: none

$ChromeWingetId = 'Google.Chrome'
# needsadmin=false in the tag makes Google's installer do a per-user install even when elevated.
$ChromeDirectUrl = 'https://dl.google.com/tag/s/appguid%3D%7B8A69D345-D564-463C-AFF1-A69D9E530F96%7D%26iid%3D%7B00000000-0000-0000-0000-000000000000%7D%26lang%3Den%26browser%3D4%26usagestats%3D0%26appname%3DGoogle%2520Chrome%26needsadmin%3Dfalse%26ap%3Dx64-stable-statsdef_1%26installdataindex%3Dempty/chrome/install/ChromeStandaloneSetup64.exe'
$ChromeInstallTimeoutSec = 900

function Install-ChromeWithWinget {
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) { Write-Log "winget not available"; return $false }
    # Windows PowerShell 5.1 turns redirected native stderr into terminating errors under 'Stop'.
    $ErrorActionPreference = 'Continue'
    $wingetArgs = @('install', '--id', $ChromeWingetId, '--exact', '--scope', 'user', '--silent',
        '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
    Write-Log "Running: winget $($wingetArgs -join ' ')"
    $out = & $winget.Source @wingetArgs 2>&1 | Out-String
    $code = $LASTEXITCODE
    Write-Log ("winget exit code {0} (0x{1:X8}). Output:`r`n{2}" -f $code, $code, ($out -replace '[^\x20-\x7E\r\n]', ''))
    return ($code -eq 0)
}

function Install-ChromeDirect {
    $exe = Join-Path $env:TEMP 'MomSetup-ChromeStandaloneSetup64.exe'
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
        return ($p.ExitCode -eq 0)
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
        $method = $null
        if (Install-ChromeWithWinget) { $method = 'winget' }
        $Ctx.ChromePath = Find-Chrome
        if (-not $Ctx.ChromePath) {
            Write-Log "Chrome not present after winget step; trying the direct installer."
            if (Install-ChromeDirect) { $method = 'direct' }
            $Ctx.ChromePath = Find-Chrome
        }
        if (-not $Ctx.ChromePath) { throw "Chrome could not be installed" }

        $state = [ordered]@{ chromeInstalledBy = 'momsetup'; method = $method; path = $Ctx.ChromePath; at = (Get-Date).ToString('o') }
        $state | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $LogDir 'chrome-state.json')
        Write-Log "Chrome installed via $method at $($Ctx.ChromePath)"
        return "Google Chrome installed."
    }
}
