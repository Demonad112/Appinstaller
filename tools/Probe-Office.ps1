# Admission probe for Microsoft 365 via the Office Deployment Tool (ODT), run on windows-latest
# (.github/workflows/probe-office.yml). Informational: prints facts so docs/apps/office.json records
# what the vendor really does. It never fails the job (read the log).
#
#   ./tools/Probe-Office.ps1 [-Product O365HomePremRetail] [-Install]
#
# Records: whether Office is already on the image, `winget show Microsoft.Office`, the ODT
# bootstrapper (URL, SHA-256, Authenticode signer), and with -Install a timed
# /configure (Word, Excel, PowerPoint, Outlook only) -> detect signals -> /configure <Remove> ->
# what is left behind. No product key is used; a subscription activates by sign-in, which we never automate.

param(
    [string]$Product = 'O365HomePremRetail',
    [string]$OdtUrl = 'https://officecdn.microsoft.com/pr/wsus/setup.exe',
    [switch]$Install
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

function Section([string]$t) { Write-Host "`n==== $t ====" -ForegroundColor Cyan }

function Get-OfficeState {
    $c2r = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'
    $cfg = Get-ItemProperty $c2r -ErrorAction SilentlyContinue
    if ($cfg) {
        Write-Host "ClickToRun: ProductReleaseIds=$($cfg.ProductReleaseIds) Version=$($cfg.VersionToReport) Platform=$($cfg.Platform) Channel=$($cfg.CDNBaseUrl)"
    } else { Write-Host 'ClickToRun registry key: absent' }
    foreach ($p in @("$env:ProgramFiles\Microsoft Office\root\Office16", "${env:ProgramFiles(x86)}\Microsoft Office\root\Office16")) {
        foreach ($exe in 'WINWORD.EXE', 'EXCEL.EXE', 'POWERPNT.EXE', 'OUTLOOK.EXE', 'MSACCESS.EXE', 'ONENOTE.EXE', 'MSPUB.EXE', 'lync.exe', 'Teams.exe', 'OneDrive.exe') {
            $f = Join-Path $p $exe
            if (Test-Path $f) { Write-Host "  present: $f" }
        }
    }
    Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -match 'Microsoft 365|Microsoft Office|OneNote|Teams' } |
        ForEach-Object { Write-Host "  ARP: $($_.DisplayName) | $($_.DisplayVersion) | $($_.UninstallString)" }
    foreach ($d in "$env:ProgramFiles\Microsoft Office", "${env:ProgramFiles(x86)}\Microsoft Office", "$env:ProgramData\Microsoft\Office", "$env:CommonProgramFiles\Microsoft Shared\ClickToRun") {
        if (Test-Path $d) { Write-Host "  folder exists: $d" }
    }
}

Section 'Environment'
$ident = [Security.Principal.WindowsIdentity]::GetCurrent()
$admin = (New-Object Security.Principal.WindowsPrincipal($ident)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Host "OS: $([Environment]::OSVersion.VersionString)  user: $($ident.Name)  admin: $admin  PS: $($PSVersionTable.PSVersion)"
$free = [math]::Round((Get-PSDrive C).Free / 1GB, 1)
Write-Host "Free space on C: $free GB"

Section 'Office already on this image?'
Get-OfficeState

Section 'winget show Microsoft.Office'
if (Get-Command winget -ErrorAction SilentlyContinue) {
    winget show --id Microsoft.Office --exact --source winget 2>&1 | ForEach-Object { Write-Host "  $_" }
    Write-Host '-- does winget accept a custom config? (--help for install options) --'
    winget install --help 2>&1 | Select-String -Pattern 'override|custom|configuration' | ForEach-Object { Write-Host "  $_" }
} else { Write-Host 'winget not found' }

Section 'ODT bootstrapper'
$work = Join-Path $env:RUNNER_TEMP 'odt'
if (-not $env:RUNNER_TEMP) { $work = Join-Path $env:TEMP 'odt-probe' }
New-Item -ItemType Directory -Force -Path $work | Out-Null
$setup = Join-Path $work 'setup.exe'
try {
    Invoke-WebRequest -Uri $OdtUrl -OutFile $setup -UseBasicParsing
    $sig = Get-AuthenticodeSignature $setup
    Write-Host "URL: $OdtUrl"
    Write-Host "Size: $((Get-Item $setup).Length) bytes  SHA-256: $((Get-FileHash $setup -Algorithm SHA256).Hash)"
    Write-Host "Signature: $($sig.Status)  Signer: $($sig.SignerCertificate.Subject)"
    Write-Host "FileVersion: $((Get-Item $setup).VersionInfo.FileVersion)  Product: $((Get-Item $setup).VersionInfo.ProductName)"
} catch { Write-Host "ODT download failed: $($_.Exception.Message)" -ForegroundColor Red; exit 0 }

if (-not $Install) { Write-Host "`n(no -Install: stopping before the install cycle)"; exit 0 }

$excluded = 'Access', 'Groove', 'Lync', 'OneDrive', 'OneNote', 'Publisher', 'Teams', 'Bing'
$addXml = @"
<Configuration>
  <Add OfficeClientEdition="64" Channel="Current">
    <Product ID="$Product">
      <Language ID="MatchOS" />
$(($excluded | ForEach-Object { "      <ExcludeApp ID=`"$_`" />" }) -join "`n")
    </Product>
  </Add>
  <Updates Enabled="TRUE" />
  <Display Level="None" AcceptEULA="TRUE" />
  <Property Name="FORCEAPPSHUTDOWN" Value="TRUE" />
</Configuration>
"@
$removeXml = @"
<Configuration>
  <Remove All="FALSE">
    <Product ID="$Product" />
  </Remove>
  <Display Level="None" AcceptEULA="TRUE" />
  <Property Name="FORCEAPPSHUTDOWN" Value="TRUE" />
</Configuration>
"@
$addCfg = Join-Path $work 'add.xml'
$removeCfg = Join-Path $work 'remove.xml'
Set-Content -Path $addCfg -Value $addXml -Encoding UTF8
Set-Content -Path $removeCfg -Value $removeXml -Encoding UTF8
Write-Host $addXml

function Invoke-Odt([string]$Label, [string]$Cfg) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $p = Start-Process -FilePath $setup -ArgumentList '/configure', "`"$Cfg`"" -Wait -PassThru -NoNewWindow
    $sw.Stop()
    Write-Host ("[{0}] exit code {1} in {2:N1}s" -f $Label, $p.ExitCode, $sw.Elapsed.TotalSeconds) -ForegroundColor Yellow
}

Section "Install $Product (Word, Excel, PowerPoint, Outlook)"
$before = (Get-PSDrive C).Used
Invoke-Odt 'install' $addCfg
Write-Host ("Disk used by install: {0:N2} GB" -f (((Get-PSDrive C).Used - $before) / 1GB))

Section 'After install'
Get-OfficeState

Section 'Remove'
Invoke-Odt 'remove' $removeCfg

Section 'After remove (leftovers)'
Get-OfficeState
Get-ChildItem 'C:\Program Files\Microsoft Office' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 15 FullName | ForEach-Object { Write-Host "  left: $($_.FullName)" }
exit 0
