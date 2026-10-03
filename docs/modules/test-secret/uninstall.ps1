# Removes what the CI-only test-secret module stored.

$Modules += [pscustomobject]@{
    Id        = 'test-secret'
    Uninstall = {
        param($Cfg)
        Remove-Item -Path 'HKCU:\Software\Appinstaller\TestSecret' -Recurse -Force -ErrorAction SilentlyContinue
        return 'Test secret removed.'
    }
}
