# Verifies chrome-data. After install the Default profile's Bookmarks holds the fixture's bookmark
# URL, without the account-linked "checksum" / "sync_metadata" fields; a re-run leaves one copy.
# After uninstall the file is gone (the scenario starts with no Chrome profile) and the module
# state is cleared.
param(
    [Parameter(Mandatory = $true)]$Cfg,
    $Ci,
    [switch]$ExpectAbsent,
    [int]$ExpectedCount = 1
)

$failures = @()
$profileDir = Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data\Default'
$target = Join-Path $profileDir 'Bookmarks'
$state = Join-Path $env:LOCALAPPDATA 'Appinstaller\chrome-data\state.json'

if ($ExpectAbsent) {
    if (Test-Path -LiteralPath $target) { $failures += "$target still exists after uninstall" }
    if (Test-Path -LiteralPath $state) { $failures += "chrome-data state.json still exists after uninstall" }
} else {
    if (-not (Test-Path -LiteralPath $target)) {
        $failures += "$target was not created"
    } else {
        $raw = Get-Content -LiteralPath $target -Raw -Encoding UTF8
        $j = $raw | ConvertFrom-Json
        $urls = @($j.roots.bookmark_bar.children | Where-Object { $_.url -eq 'https://example.com/appinstaller-ci' })
        if ($urls.Count -ne 1) { $failures += "Expected exactly 1 fixture bookmark in the bookmark bar, found $($urls.Count)" }
        foreach ($f in @('checksum', 'sync_metadata')) {
            if ($j.PSObject.Properties[$f]) { $failures += "Bookmarks still has the account-linked field '$f'" }
        }
    }
    if (-not (Test-Path -LiteralPath $state)) { $failures += 'chrome-data state.json was not written' }
}
return $failures
