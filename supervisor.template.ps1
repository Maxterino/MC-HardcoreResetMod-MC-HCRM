<#
  MCHC supervisor — bevriest de inactieve standby-server om CPU en fysiek RAM te besparen.

  Hoe:
   - Elke server-JVM start met -Dmchc.server=alpha (of beta), zodat we hem terugvinden.
   - Een server die 'ready' is maar geen spelers heeft (.active ontbreekt) en niet gewekt
     wordt, wordt bevroren: alle threads suspended (0% CPU) + working set geleegd
     (fysiek RAM gaat terug naar het systeem / pagefile).
   - Zodra de mod 'wake-<naam>.flag' schrijft (begin van de dood-melding) of er spelers
     op zitten (.active), wordt de server direct hervat — ruim voordat spelers aankomen.

  Geen admin nodig. Sluit dit venster om het bevriezen te stoppen (servers blijven dan
  gewoon allebei draaien).
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

# naam -> @{ Proc=Process; Suspended=$bool }
$state = @{}
foreach($s in $Servers){ $state[$s] = @{ Proc = $null; Suspended = $false } }

function Find-ServerProcess($name){
    $cur = $state[$name].Proc
    if($cur -and -not $cur.HasExited){ return $cur }
    # opnieuw zoeken (PID verandert na elke reset/herstart)
    try {
        $ci = Get-CimInstance Win32_Process -Filter "Name='java.exe'" -ErrorAction Stop |
              Where-Object { $_.CommandLine -and $_.CommandLine -match "mchc\.server=$name(\s|$|`")" } |
              Select-Object -First 1
    } catch { return $null }
    if($ci){
        try { $p = Get-Process -Id $ci.ProcessId -ErrorAction Stop } catch { return $null }
        $null = $p.Handle  # cache handle nu het proces nog niet suspended is
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
        Write-Host ("[supervisor] '{0}' BEVROREN (pid {1}) - 0% CPU, RAM vrijgegeven." -f $name, $p.Id) -ForegroundColor DarkCyan
    } catch {
        Write-Host ("[supervisor] suspend van '{0}' mislukt: {1}" -f $name, $_.Exception.Message) -ForegroundColor Red
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
        Write-Host ("[supervisor] '{0}' HERVAT (pid {1})." -f $name, $p.Id) -ForegroundColor Cyan
    } catch {
        Write-Host ("[supervisor] resume van '{0}' mislukt: {1}" -f $name, $_.Exception.Message) -ForegroundColor Red
    }
}

Write-Host "==============================================================" -ForegroundColor Magenta
Write-Host "  MCHC supervisor actief - bespaart resources op de standby." -ForegroundColor Magenta
Write-Host "  (Laat dit venster open. Sluiten = niet meer bevriezen.)"      -ForegroundColor Magenta
Write-Host "==============================================================" -ForegroundColor Magenta

# partner-naam opzoeken
$partnerOf = @{ 'alpha' = 'beta'; 'beta' = 'alpha' }

while($true){
    foreach($name in $Servers){
        $partner       = $partnerOf[$name]
        $ready         = Test-Path (Join-Path $Control "$name.ready")
        $active        = Test-Path (Join-Path $Control "$name.active")
        $wake          = Test-Path (Join-Path $Control "wake-$name.flag")
        $partnerActive = Test-Path (Join-Path $Control "$partner.active")

        # Proces is gestopt? -> state opschonen.
        $p = $state[$name].Proc
        if($p -and $p.HasExited){ $state[$name].Proc = $null; $state[$name].Suspended = $false }

        if($wake){
            Resume-Server $name
            Remove-Item (Join-Path $Control "wake-$name.flag") -Force -ErrorAction SilentlyContinue
            continue
        }

        if($active){
            # Er zitten spelers op: NOOIT bevriezen.
            Resume-Server $name
            continue
        }

        # Alleen bevriezen als WIJ leeg en klaar zijn EN de partner het actieve spel draait.
        # (Bij de allereerste start is niemand actief -> we laten alpha staan zodat je kunt verbinden.)
        if($ready -and -not $active -and $partnerActive){
            Suspend-Server $name
        }
    }
    Start-Sleep -Milliseconds 500
}
