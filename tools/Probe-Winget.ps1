# Admission probe for a candidate app, run on a real Windows machine (windows-latest via
# .github/workflows/probe-winget.yml). Informational: it prints what winget and the vendor really
# do so the app JSON in docs/apps/ records facts instead of assumptions. It never fails the job
# (read the log), except when winget itself is missing.
#
#   ./tools/Probe-Winget.ps1 -Id 7zip.7zip -ArpRegex '^7-Zip' [-Url https://... ] [-Install]
#
# Records: OS/admin/winget version, `winget show` (installer type, scope, switches, hash), whether
# the app is already on the image, `--scope user` support, and (with -Install) a timed
# install -> detect -> uninstall -> detect cycle. With -Url: SHA-256 and Authenticode signer of the
# vendor download, plus the vendor's published .sha256 for cross-checking when it exists.

param(
    [Parameter(Mandatory = $true)][string]$Id,
    [string]$ArpRegex = '',
    [string]$Url = '',
    [switch]$Install
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

function Section([string]$t) { Write-Host "`n==== $t ====" -ForegroundColor Cyan }

function Get-Arp {
    param([string]$Regex)
    if (-not $Regex) { return @() }
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($r in $roots) {
        Get-ItemProperty -Path $r -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -and $_.DisplayName -match $Regex } |
            ForEach-Object { [pscustomobject]@{ Root = $r.Split('\')[0] + '\..\' + ($r -split '\\')[-2]; Name = $_.DisplayName; Version = $_.DisplayVersion; Publisher = $_.Publisher; Uninstall = $_.UninstallString; Quiet = $_.QuietUninstallString } }
    }
}

function Invoke-Timed {
    param([string]$Label, [scriptblock]$Block)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    & $Block 2>&1 | ForEach-Object { Write-Host "  $_" }
    $code = $LASTEXITCODE
    $sw.Stop()
    Write-Host ("[{0}] exit code {1} (0x{2:X8}) in {3:N1}s" -f $Label, $code, ([uint32]([int]$code)), $sw.Elapsed.TotalSeconds) -ForegroundColor Yellow
    return $code
}

Section 'Environment'
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$admin = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Host "OS: $([Environment]::OSVersion.VersionString)  user: $($id.Name)  admin: $admin  PS: $($PSVersionTable.PSVersion)"
$wg = Get-Command winget -ErrorAction SilentlyContinue
if (-not $wg) { Write-Host 'winget NOT FOUND on PATH' -ForegroundColor Red; exit 1 }
Write-Host "winget: $($wg.Source)"
winget --version

Section "winget show $Id"
winget show --id $Id --exact --source winget --accept-source-agreements --disable-interactivity
Write-Host "[show] exit code $LASTEXITCODE"

Section 'Already on this image?'
$before = @(Get-Arp $ArpRegex)
if ($before.Count) { $before | Format-List | Out-String | Write-Host } else { Write-Host "No ARP entry matches '$ArpRegex'." }

if ($Url) {
    Section "Vendor URL $Url"
    $f = Join-Path $env:TEMP ('probe-' + [IO.Path]::GetFileName(([uri]$Url).AbsolutePath))
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $Url -OutFile $f -UseBasicParsing
    Write-Host "size: $((Get-Item $f).Length)"
    Write-Host "sha256: $((Get-FileHash -Algorithm SHA256 -LiteralPath $f).Hash.ToLower())"
    $sig = Get-AuthenticodeSignature -FilePath $f
    Write-Host "signature: $($sig.Status)"
    Write-Host "signer subject: $($sig.SignerCertificate.Subject)"
    try {
        $pub = (Invoke-WebRequest -Uri ($Url + '.sha256') -UseBasicParsing).Content
        Write-Host "vendor-published .sha256: $(([string]$pub).Trim())"
    } catch { Write-Host "no vendor .sha256 at $Url.sha256 ($($_.Exception.Message))" }
    Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
}

Section "winget install --scope user (expect failure for machine-only packages)"
if ($Install) {
    Invoke-Timed 'scope-user' { winget install --id $Id --exact --source winget --scope user --silent --accept-package-agreements --accept-source-agreements --disable-interactivity } | Out-Null
    $afterUser = @(Get-Arp $ArpRegex)
    Write-Host "ARP entries after --scope user attempt: $($afterUser.Count)"
    if ($afterUser.Count -gt $before.Count) {
        Invoke-Timed 'uninstall-after-scope-user' { winget uninstall --id $Id --exact --silent --disable-interactivity } | Out-Null
    }
} else { Write-Host 'skipped (no -Install)' }

if ($Install) {
    Section 'Remove pre-existing copy (so install is a real install)'
    if (@(Get-Arp $ArpRegex).Count) {
        Invoke-Timed 'pre-uninstall' { winget uninstall --id $Id --exact --silent --disable-interactivity } | Out-Null
        Write-Host "ARP entries after pre-uninstall: $(@(Get-Arp $ArpRegex).Count)"
    }

    Section "winget install $Id (machine default)"
    Invoke-Timed 'install' { winget install --id $Id --exact --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity } | Out-Null
    $mid = @(Get-Arp $ArpRegex)
    Write-Host "ARP entries after install: $($mid.Count)"
    $mid | Format-List | Out-String | Write-Host
    foreach ($p in @("$env:ProgramFiles", "${env:ProgramFiles(x86)}", "$env:LOCALAPPDATA\Programs")) {
        Get-ChildItem -LiteralPath $p -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '7-Zip|VideoLAN|Adobe' } |
            ForEach-Object { Write-Host "dir: $($_.FullName)" }
    }

    Section 'second install (idempotency as winget sees it)'
    Invoke-Timed 'install-again' { winget install --id $Id --exact --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity } | Out-Null
    Write-Host "ARP entries after 2nd install: $(@(Get-Arp $ArpRegex).Count)"

    Section "winget uninstall $Id"
    Invoke-Timed 'uninstall' { winget uninstall --id $Id --exact --silent --disable-interactivity } | Out-Null
    $after = @(Get-Arp $ArpRegex)
    Write-Host "ARP entries after uninstall: $($after.Count)"
    $after | Format-List | Out-String | Write-Host
}
exit 0
