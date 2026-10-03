# Verifies the CI-only test-secret module: after install HKCU holds the SHA-256 of the fixture's
# secret (so the value reached the module from files\secrets.json) and the log shows it masked;
# after uninstall the key is gone. Absence of the raw value in the .cmd files and logs is checked
# by Run-Scenario.ps1 (_ci.assertAbsent).
param(
    [Parameter(Mandatory = $true)]$Cfg,
    $Ci,
    [switch]$ExpectAbsent,
    [int]$ExpectedCount = 1
)

$failures = @()
$key = 'HKCU:\Software\Appinstaller\TestSecret'
if ($ExpectAbsent) {
    if (Test-Path $key) { $failures += "$key still exists after uninstall" }
} else {
    $sha = [Security.Cryptography.SHA256]::Create()
    $want = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes([string]$Cfg.value)) | ForEach-Object { $_.ToString('x2') })
    $got = (Get-ItemProperty -Path $key -Name Sha256 -ErrorAction SilentlyContinue).Sha256
    if ($got -ne $want) { $failures += "Expected secret fingerprint $want in $key, got '$got'" }
    $log = Join-Path $env:LOCALAPPDATA 'Appinstaller\install.log'
    if (-not (Select-String -LiteralPath $log -SimpleMatch 'Test secret received: ********' -Quiet)) {
        $failures += 'install.log has no masked "Test secret received: ********" line'
    }
}
return $failures
