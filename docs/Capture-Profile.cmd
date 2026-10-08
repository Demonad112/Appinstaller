@set "APPI_ARGS=%*" & @set "SELF=%~f0" & @powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -Command "$c=[IO.File]::ReadAllText($env:SELF);iex $c.Substring($c.IndexOf('<'+'#PSBEGIN#'+'>')+11)" & @if errorlevel 1 (exit /b 1) else (exit /b 0)
<#PSBEGIN#>
# Capture-Profile.cmd: run on the OLD computer. Saves each Chrome profile's bookmarks to the
# Desktop (Bookmarks-Default.json, Bookmarks-Profile-1.json, ...) so you can hand one to the
# "Chrome bookmarks" step of the Appinstaller setup builder.
# It reads ONE file per profile (the bookmark list), changes nothing, and leaves everything else
# in Chrome alone. It does not touch saved passwords, cookies, history or sign-in.

$ErrorActionPreference = 'Stop'

function Show-Note {
    param([string]$Message, [bool]$IsError = $false)
    try {
        $wsh = New-Object -ComObject WScript.Shell
        $title = if ($IsError) { 'Capture Profile - Something Went Wrong' } else { 'Capture Profile Complete' }
        $wsh.Popup($Message, 60, $title, $(if ($IsError) { 48 } else { 64 })) | Out-Null
    } catch {}
}

try {
    $userData = Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data'
    if (-not (Test-Path -LiteralPath $userData)) {
        Show-Note 'Chrome has no saved data for this Windows user, so there is nothing to capture. Run this while signed in to the Windows account that uses Chrome.' $true
        exit 1
    }
    $desktop = [Environment]::GetFolderPath('Desktop')
    $utf8 = New-Object Text.UTF8Encoding($false)
    $saved = @()
    $dirs = @(Get-ChildItem -LiteralPath $userData -Directory | Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' })
    foreach ($d in $dirs) {
        $src = Join-Path $d.FullName 'Bookmarks'
        if (-not (Test-Path -LiteralPath $src)) { continue }
        $json = Get-Content -LiteralPath $src -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $json.roots) { continue }
        # Account-linked fields stay behind.
        foreach ($drop in @('checksum', 'sync_metadata')) {
            if ($json.PSObject.Properties[$drop]) { $json.PSObject.Properties.Remove($drop) }
        }
        $name = 'Bookmarks-' + ($d.Name -replace '[^A-Za-z0-9]+', '-') + '.json'
        [IO.File]::WriteAllText((Join-Path $desktop $name), ($json | ConvertTo-Json -Depth 100), $utf8)
        $saved += $name
    }
    if ($saved.Count -eq 0) {
        Show-Note 'No Chrome bookmarks were found to save.' $true
        exit 1
    }
    Show-Note ("Saved to your Desktop:`r`n`r`n" + ($saved -join "`r`n") + "`r`n`r`nChoose one of these files in the setup builder's 'Chrome bookmarks' step. Only bookmarks were saved: no passwords, cookies or history.")
} catch {
    Show-Note ("Could not save the bookmarks: " + $_.Exception.Message) $true
    exit 1
}
