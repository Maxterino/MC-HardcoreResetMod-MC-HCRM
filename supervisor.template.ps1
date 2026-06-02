<#
  MCHC supervisor - freezes the inactive standby server to save CPU and physical RAM.

  How:
   - Each server JVM starts with -Dmchc.server=alpha (or beta) so we can find it.
   - A server that is 'ready' but has no players (.active missing) and is not being
     woken, gets frozen: all threads suspended (0% CPU) + working set emptied
     (physical RAM goes back to the system / pagefile).
   - As soon as the mod writes 'wake-<name>.flag' (start of the death message) or players
     are on it (.active), the server is resumed immediately - well before players arrive.

  No admin needed. Close this window to stop freezing (both servers then just keep running).
#>

$ErrorActionPreference = 'Continue'
$Root    = $PSScriptRoot
$Control = Join-Path $Root 'control'
$Servers = @('alpha','beta')

Add-Type -Namespace Mchc -Name Native -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("ntdll.dll")]   public static extern int  NtSuspendProcess(System.IntPtr h);
[System.Runtime.InteropServices.DllImport("ntdll.dll")]   public static extern int  NtResumeProcess(System.IntPtr h);
[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern bool K32EmptyWorkingSet(System.IntPtr h);
'@

# name -> @{ Proc=Process; Suspended=$bool }
$state = @{}
foreach($s in $Servers){ $state[$s] = @{ Proc = $null; Suspended = $false } }

function Find-ServerProcess($name){
    $cur = $state[$name].Proc
    if($cur -and -not $cur.HasExited){ return $cur }
    # search again (PID changes after each reset/restart)
    try {
        $ci = Get-CimInstance Win32_Process -Filter "Name='java.exe'" -ErrorAction Stop |
              Where-Object { $_.CommandLine -and $_.CommandLine -match "mchc\.server=$name(\s|$|`")" } |
              Select-Object -First 1
    } catch { return $null }
    if($ci){
        try { $p = Get-Process -Id $ci.ProcessId -ErrorAction Stop } catch { return $null }
        $null = $p.Handle  # cache the handle while the process is not yet suspended
        $state[$name].Proc = $p
        $state[$name].Suspended = $false
        return $p
    }
    return $null
}

function Suspend-Server($name){
    $st = $state[$name]
    if($st.Suspended){ return }
    $p = Find-ServerProcess $name
    if(-not $p){ return }
    try {
        [Mchc.Native]::NtSuspendProcess($p.Handle) | Out-Null
        [Mchc.Native]::K32EmptyWorkingSet($p.Handle) | Out-Null
        $st.Suspended = $true
        Write-Host ("[supervisor] '{0}' FROZEN (pid {1}) - 0% CPU, RAM released." -f $name, $p.Id) -ForegroundColor DarkCyan
    } catch {
        Write-Host ("[supervisor] suspend of '{0}' failed: {1}" -f $name, $_.Exception.Message) -ForegroundColor Red
    }
}

function Resume-Server($name){
    $st = $state[$name]
    if(-not $st.Suspended){ return }
    $p = $st.Proc
    if(-not $p -or $p.HasExited){ $st.Suspended = $false; return }
    try {
        [Mchc.Native]::NtResumeProcess($p.Handle) | Out-Null
        $st.Suspended = $false
        Write-Host ("[supervisor] '{0}' RESUMED (pid {1})." -f $name, $p.Id) -ForegroundColor Cyan
    } catch {
        Write-Host ("[supervisor] resume of '{0}' failed: {1}" -f $name, $_.Exception.Message) -ForegroundColor Red
    }
}

Write-Host "==============================================================" -ForegroundColor Magenta
Write-Host "  MCHC supervisor active - saves resources on the standby."     -ForegroundColor Magenta
Write-Host "  (Keep this window open. Closing = no more freezing.)"          -ForegroundColor Magenta
Write-Host "==============================================================" -ForegroundColor Magenta

# partner lookup
$partnerOf = @{ 'alpha' = 'beta'; 'beta' = 'alpha' }

while($true){
    foreach($name in $Servers){
        $partner       = $partnerOf[$name]
        $ready         = Test-Path (Join-Path $Control "$name.ready")
        $active        = Test-Path (Join-Path $Control "$name.active")
        $wake          = Test-Path (Join-Path $Control "wake-$name.flag")
        $partnerActive = Test-Path (Join-Path $Control "$partner.active")

        # Process stopped? -> clean up state.
        $p = $state[$name].Proc
        if($p -and $p.HasExited){ $state[$name].Proc = $null; $state[$name].Suspended = $false }

        if($wake){
            Resume-Server $name
            Remove-Item (Join-Path $Control "wake-$name.flag") -Force -ErrorAction SilentlyContinue
            continue
        }

        if($active){
            # Players are on it: NEVER freeze.
            Resume-Server $name
            continue
        }

        # Only freeze if WE are empty and ready AND the partner is running the active game.
        # (On the very first start nobody is active -> we leave alpha running so you can connect.)
        if($ready -and -not $active -and $partnerActive){
            Suspend-Server $name
        }
    }
    Start-Sleep -Milliseconds 500
}
