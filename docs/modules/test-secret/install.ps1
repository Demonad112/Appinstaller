# CI-only test module (catalog "test": true: hidden on the site unless the URL has ?test=1).
# Proves a secret option reaches a module from the bundle's files\secrets.json and is masked in
# the log: it stores only the SHA-256 of the value and deliberately logs the value itself, which
# Write-Log must turn into ********.

$Modules += [pscustomobject]@{
    Id      = 'test-secret'
    Install = {
        param($Cfg, $Ctx)
        if (-not $Cfg.value) { throw 'No secret value reached the module.' }
        $sha = [Security.Cryptography.SHA256]::Create()
        $hash = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes([string]$Cfg.value)) | ForEach-Object { $_.ToString('x2') })
        $key = 'HKCU:\Software\Appinstaller\TestSecret'
        New-Item -Path $key -Force | Out-Null
        Set-ItemProperty -Path $key -Name 'Sha256' -Value $hash
        Write-Log "Test secret received: $($Cfg.value)"
        return 'Test secret stored (fingerprint only).'
    }
}
