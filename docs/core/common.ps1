# Appinstaller shared core helpers (rendered, not run directly)
# docs/render-core.js splices this file into both installer-core.ps1 and uninstall-core.ps1 at the
# common placeholder. It must NOT contain any of the core placeholders itself.
#
# The core defines before this point: $Kind ('install'|'uninstall'), $LogName, $SELF.
# Provides: logging, migration, Test-IsAdmin, the run lock, the progress notice, the result popup
# and Invoke-Appinstaller, the two-phase driver:
#   phase "user"    (the real, un-elevated user) runs user-scope modules in-process, holds the run
#                   lock, shows the progress notice, then launches the elevated child for any
#                   machine-scope modules that need admin on this computer and merges its result.
#   phase "machine" (the elevated child: "--phase machine --run <guid>") runs only those modules
#                   and reports back through %ProgramData%\Appinstaller\run-<guid>\result.json.

# When the .cmd is launched from a PowerShell 7 (pwsh) window, this Windows PowerShell 5.1
# process inherits pwsh's PSModulePath and would autoload pwsh's copies of built-in modules
# (e.g. Microsoft.PowerShell.Security -> Get-AuthenticodeSignature), which fail to load in 5.1.
if ($PSVersionTable.PSEdition -ne 'Core') {
    $paths = @(($env:PSModulePath -split ';') | Where-Object { $_ -and $_ -notmatch '\\PowerShell\\' })
    $builtin = Join-Path $PSHOME 'Modules'
    if ($paths -notcontains $builtin) { $paths += $builtin }
    $env:PSModulePath = $paths -join ';'
}

$LogDir = Join-Path $env:LOCALAPPDATA 'Appinstaller'
$LogPath = Join-Path $LogDir $LogName
New-Item -ItemType Directory -Path $LogDir -Force -ErrorAction SilentlyContinue | Out-Null

# One-time migration from the pre-rename folder (older builds used 'MomSetup'): state files and
# icons are copied across if missing so an old uninstaller / re-run still finds what it needs.
try {
    $OldDir = Join-Path $env:LOCALAPPDATA 'MomSetup'
    if (Test-Path -LiteralPath $OldDir) {
        foreach ($item in @('chrome-state.json', 'Icons')) {
            $src = Join-Path $OldDir $item
            $dst = Join-Path $LogDir $item
            if ((Test-Path -LiteralPath $src) -and -not (Test-Path -LiteralPath $dst)) {
                Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
} catch {}

function Write-Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    try { Add-Content -Path $LogPath -Value $line -ErrorAction SilentlyContinue } catch {}
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Value following "--<Name>" in the arguments the .cmd header forwarded (APPI_ARGS), or $null.
function Get-AppiArg {
    param([string]$Name)
    $tokens = @(([string]$env:APPI_ARGS -split '\s+') | Where-Object { $_ })
    $i = [array]::IndexOf($tokens, "--$Name")
    if ($i -ge 0 -and ($i + 1) -lt $tokens.Count) { return $tokens[$i + 1] }
    return $null
}

function Show-Result {
    param([string]$Message, [bool]$IsError = $false)
    Write-Log $Message
    try {
        $wsh = New-Object -ComObject WScript.Shell
        $noun = if ($Kind -eq 'uninstall') { 'Uninstall' } else { 'Setup' }
        $title = if ($IsError) { "$noun - Something Went Wrong" } else { "$noun Complete" }
        $icon = if ($IsError) { 48 } else { 64 }   # 48 = warning, 64 = information
        # 3rd arg is auto-dismiss timeout in seconds so an unattended run never blocks.
        $wsh.Popup($Message, 30, $title, $icon) | Out-Null
    } catch {}
}

# ---- Run lock: one Appinstaller run at a time (install and uninstall share it) ------------
$script:LockMutex = $null
function Enter-RunLock {
    try {
        $script:LockMutex = New-Object System.Threading.Mutex($false, 'Global\Appinstaller.run')
        try { return $script:LockMutex.WaitOne(0) }
        catch [System.Threading.AbandonedMutexException] { return $true }
    } catch {
        Write-Log "Run lock unavailable ($($_.Exception.Message)); continuing without it."
        return $true
    }
}

# ---- Progress notice: non-modal "please wait" window on its own STA thread ------------------
# Entirely best effort: if a window can't be created (no desktop session) the run goes on and
# only the log says so.
$script:ProgPs = $null
$script:ProgAsync = $null
$script:ProgSync = $null
function Show-Progress {
    param([string]$Text = 'Setting things up, please wait...')
    try {
        $script:ProgSync = [hashtable]::Synchronized(@{ Close = $false; Ready = $false })
        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = 'STA'
        $rs.ThreadOptions = 'ReuseThread'
        $rs.Open()
        $rs.SessionStateProxy.SetVariable('sync', $script:ProgSync)
        $rs.SessionStateProxy.SetVariable('text', $Text)
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript({
            Add-Type -AssemblyName System.Windows.Forms
            Add-Type -AssemblyName System.Drawing
            $f = New-Object System.Windows.Forms.Form
            $f.Text = 'Setup'
            $f.StartPosition = 'CenterScreen'
            $f.TopMost = $true
            $f.ShowInTaskbar = $false
            $f.ControlBox = $false
            $f.FormBorderStyle = 'FixedDialog'
            $f.ClientSize = New-Object System.Drawing.Size(360, 70)
            $l = New-Object System.Windows.Forms.Label
            $l.Text = $text
            $l.Dock = 'Fill'
            $l.TextAlign = 'MiddleCenter'
            $f.Controls.Add($l)
            $t = New-Object System.Windows.Forms.Timer
            $t.Interval = 200
            $t.Add_Tick({ if ($sync.Close) { $t.Stop(); $f.Close() } })
            $t.Start()
            $sync.Ready = $true
            [System.Windows.Forms.Application]::Run($f)
        })
        $script:ProgPs = $ps
        $script:ProgAsync = $ps.BeginInvoke()
        for ($i = 0; $i -lt 15 -and -not $script:ProgSync.Ready -and -not $script:ProgAsync.IsCompleted; $i++) { Start-Sleep -Milliseconds 100 }
        if ($script:ProgSync.Ready) { Write-Log 'Progress notice shown.' }
        else { Write-Log ('Progress notice unavailable: ' + (@($ps.Streams.Error) -join '; ')) }
    } catch {
        Write-Log "Progress notice unavailable: $($_.Exception.Message)"
    }
}

function Close-Progress {
    if (-not $script:ProgPs) { return }
    try {
        $script:ProgSync.Close = $true
        [void]$script:ProgAsync.AsyncWaitHandle.WaitOne(3000)
        if ($script:ProgAsync.IsCompleted) {
            $script:ProgPs.Dispose()
            Write-Log 'Progress notice closed.'
        }
    } catch {}
    $script:ProgPs = $null
}

# ---- Two-phase driver -----------------------------------------------------------------------
# Machine-scope modules (per the catalog "scopes" map embedded in the config) need elevation
# when they have no NeedsAdmin check, or when their NeedsAdmin check says so on this computer.
function Get-MachineModules {
    param($Modules, $Config)
    $found = @()
    foreach ($m in $Modules) {
        if ($Config.scopes.($m.Id) -ne 'machine') { continue }
        $need = $true
        if ($m.NeedsAdmin) { $need = [bool](& $m.NeedsAdmin $Config.modules.($m.Id)) }
        if ($need) { $found += $m }
    }
    return $found
}

function Invoke-Phase {
    param($List, $Config, [scriptblock]$Action, $Ctx)
    $lines = @()
    $failed = @()
    $ran = @()
    foreach ($m in $List) {
        try {
            Write-Log "Module '$($m.Id)': starting"
            $lines += @(& $Action $m $Config.modules.($m.Id) $Ctx)
            $ran += $m.Id
            Write-Log "Module '$($m.Id)': done"
        } catch {
            $failed += $m.Id
            Write-Log "ERROR in module '$($m.Id)': $($_.Exception.ToString())"
            $lines += "One step ($($m.Id)) didn't finish: $($_.Exception.Message)"
        }
    }
    return [pscustomobject]@{ ok = ($failed.Count -eq 0); lines = $lines; failed = $failed; ran = $ran }
}

# The elevated child. Always reports through result.json; returns its exit code.
function Invoke-MachinePhase {
    param($Modules, $Config, [scriptblock]$Action, [scriptblock]$NewContext)
    $result = [ordered]@{ ok = $false; lines = @(); failed = @(); ran = @(); error = $null }
    $dir = $null
    try {
        $run = Get-AppiArg 'run'
        if ($run -notmatch '^[0-9a-fA-F-]{36}$') { throw 'Invalid or missing run id.' }
        $dir = Join-Path (Join-Path $env:ProgramData 'Appinstaller') "run-$run"
        if (-not (Test-Path -LiteralPath $dir)) { throw 'Run folder not found.' }
        $admin = Test-IsAdmin
        Write-Log "phase=machine start (admin=$admin, run $run)"
        if (-not $admin) { throw 'The elevated step is not running with administrator rights.' }
        $list = @(Get-MachineModules -Modules $Modules -Config $Config)
        $ctx = & $NewContext
        $r = Invoke-Phase -List $list -Config $Config -Action $Action -Ctx $ctx
        $result.ok = $r.ok
        $result.lines = @($r.lines)
        $result.failed = @($r.failed)
        $result.ran = @($r.ran)
    } catch {
        $result.error = $_.Exception.Message
        Write-Log "ERROR in machine phase: $($_.Exception.ToString())"
    }
    if ($dir -and (Test-Path -LiteralPath $dir)) {
        try { ($result | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath (Join-Path $dir 'result.json') -Encoding UTF8 } catch { Write-Log "Could not write result.json: $($_.Exception.Message)" }
    }
    Write-Log "phase=machine end (ok=$($result.ok))"
    if ($result.ok) { return 0 } else { return 1 }
}

# Parent side: always spawns the elevated child (one code path, so CI exercises it) and returns
# @{ Result = <parsed result.json or $null>; Error = <reason or $null> }.
function Start-MachinePhase {
    param([string[]]$Ids)
    $out = [pscustomobject]@{ Result = $null; Error = $null }
    $base = Join-Path $env:ProgramData 'Appinstaller'
    $run = [guid]::NewGuid().ToString()
    $dir = Join-Path $base "run-$run"
    try {
        # Sweep leftovers from crashed runs.
        Get-ChildItem -LiteralPath $base -Directory -Filter 'run-*' -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-1) } |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    } catch {}
    try {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Write-Log "Starting elevated machine phase for: $($Ids -join ', ') (run $run)"
        $p = Start-Process -FilePath $SELF -ArgumentList @('--phase', 'machine', '--run', $run) -Verb RunAs -Wait -PassThru -WindowStyle Hidden
        $code = try { $p.ExitCode } catch { 'unknown' }
        Write-Log "Elevated machine phase exited (code $code)."
        $resultFile = Join-Path $dir 'result.json'
        if (Test-Path -LiteralPath $resultFile) {
            $out.Result = Get-Content -LiteralPath $resultFile -Raw | ConvertFrom-Json
        } else {
            $out.Error = 'The administrator step did not report back.'
        }
    } catch {
        $ex = $_.Exception
        $native = 0
        if ($ex -is [System.ComponentModel.Win32Exception]) { $native = $ex.NativeErrorCode }
        elseif ($ex.InnerException -is [System.ComponentModel.Win32Exception]) { $native = $ex.InnerException.NativeErrorCode }
        $out.Error = if ($native -eq 1223) { 'Administrator permission was not granted.' } else { "Could not start the administrator step: $($ex.Message)" }
        Write-Log "Elevation failed (native error $native): $($ex.Message)"
    }
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    return $out
}

# Entry point used by both cores. $Noun is 'Install' or 'Uninstall'. Returns the exit code.
#   -Action     { param($m, $cfg, $ctx) ... } runs one module and returns its result lines
#   -NewContext { ... } returns the shared $ctx hashtable (built fresh in each phase)
function Invoke-Appinstaller {
    param($Modules, $Config, [string]$Noun, [scriptblock]$Action, [scriptblock]$NewContext)

    if ((Get-AppiArg 'phase') -eq 'machine') {
        return (Invoke-MachinePhase -Modules $Modules -Config $Config -Action $Action -NewContext $NewContext)
    }

    if (-not (Enter-RunLock)) {
        Write-Log "Another Appinstaller run is already in progress; $Kind not started."
        Show-Result -IsError $true -Message "Another setup is already running on this computer. Wait for it to finish, then run this again."
        return 1
    }

    Write-Log ("Starting $Kind. Modules: " + (($Modules | ForEach-Object { $_.Id }) -join ', '))
    $machine = @(Get-MachineModules -Modules $Modules -Config $Config)
    $machineIds = @($machine | ForEach-Object { $_.Id })
    $userList = @($Modules | Where-Object { $machineIds -notcontains $_.Id })

    Show-Progress
    $ctx = & $NewContext
    $user = Invoke-Phase -List $userList -Config $Config -Action $Action -Ctx $ctx
    $lines = @($user.lines)
    $failed = @($user.failed)
    $skipped = @()

    if ($machine.Count -gt 0) {
        $child = Start-MachinePhase -Ids $machineIds
        $ranIds = @()
        if ($child.Result) {
            foreach ($l in @($child.Result.lines)) { $lines += $l; Write-Log "[machine] $l" }
            $failed += @($child.Result.failed)
            $ranIds = @($child.Result.ran) + @($child.Result.failed)
            if ($child.Result.error) { $child.Error = [string]$child.Result.error }
        }
        $notRun = @($machineIds | Where-Object { $ranIds -notcontains $_ })
        if ($notRun.Count -gt 0) {
            $skipped += $notRun
            $reason = if ($child.Error) { $child.Error } else { 'The administrator step did not run.' }
            $lines += "Skipped (needs administrator permission): $($notRun -join ', '). $reason"
            Write-Log "Skipped machine modules: $($notRun -join ', '). $reason"
        }
    }

    Close-Progress
    if ($failed.Count -gt 0 -or $skipped.Count -gt 0) {
        $lines += "`r`nA log file with details was saved at:`r`n$LogPath`r`n`r`nPlease send that file for help."
        Show-Result -Message ($lines -join "`r`n") -IsError $true
        Write-Log ("$Noun finished with failures: " + (($failed + $skipped) -join ', '))
        return 1
    }
    Show-Result -Message ($lines -join "`r`n")
    Write-Log "$Noun finished successfully."
    return 0
}
