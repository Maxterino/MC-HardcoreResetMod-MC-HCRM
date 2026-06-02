<#
  MCHC Hardcore - setup script
  Downloadt server, proxy, alle mods en bouwt de twee jars (mod + velocity-plugin).
  Bouwt de complete draaibare structuur in .\MCHC-Server\

  Draai dit via 1-SETUP.bat (dubbelklik) of:  powershell -ExecutionPolicy Bypass -File setup.ps1
#>

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Root   = $PSScriptRoot
$Server = Join-Path $Root 'MCHC-Server'
$MC     = '26.1.2'
$UA     = 'MCHC-setup/1.0 (contact: maxvmaasakker@gmail.com)'

function Info($m){ Write-Host "[setup] $m" -ForegroundColor Cyan }
function Ok($m){   Write-Host "[ ok  ] $m" -ForegroundColor Green }
function Warn($m){ Write-Host "[warn ] $m" -ForegroundColor Yellow }
function Fail($m){ Write-Host "[FOUT ] $m" -ForegroundColor Red }

function Download($url, $dest){
    $dir = Split-Path -Parent $dest
    if(-not (Test-Path $dir)){ New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    Info "download: $url"
    Invoke-WebRequest -Uri $url -OutFile $dest -Headers @{ 'User-Agent' = $UA } -UseBasicParsing
    Ok ("opgeslagen: " + (Split-Path -Leaf $dest))
}

# Schrijft tekst weg als UTF-8 ZONDER BOM (anders crashen TOML/properties-parsers).
function Write-NoBom($path, $text){
    $dir = Split-Path -Parent $path
    if(-not (Test-Path $dir)){ New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))
}

# Haalt de nieuwste Fabric-versie van een Modrinth-mod voor MC $MC op en downloadt die.
# We halen ALLE fabric-versies op en filteren client-side -> betrouwbaarder dan server-side filters.
function Get-ModrinthJar($slug, $destDir){
    New-Item -ItemType Directory -Force -Path $destDir | Out-Null
    $url = "https://api.modrinth.com/v2/project/$slug/version?loaders=%5B%22fabric%22%5D"
    try {
        $vs = Invoke-RestMethod -Uri $url -Headers @{ 'User-Agent' = $UA } -UseBasicParsing
    } catch {
        Fail "Modrinth-API-fout voor '$slug': $($_.Exception.Message). Handmatig: https://modrinth.com/mod/$slug"
        return $false
    }
    $pick = $vs | Where-Object { $_.game_versions -contains $MC }   | Select-Object -First 1
    if(-not $pick){ $pick = $vs | Where-Object { $_.game_versions -contains '26.1' } | Select-Object -First 1 }
    if(-not $pick){ $pick = $vs | Select-Object -First 1 }
    if(-not $pick){ Fail "Geen Fabric-versie gevonden voor '$slug'. Handmatig: https://modrinth.com/mod/$slug"; return $false }
    $file = $pick.files | Where-Object { $_.primary } | Select-Object -First 1
    if(-not $file){ $file = $pick.files | Select-Object -First 1 }
    try {
        Download $file.url (Join-Path $destDir $file.filename)
    } catch {
        Fail "Download mislukt voor '$slug': $($_.Exception.Message)"
        return $false
    }
    Start-Sleep -Milliseconds 300
    return $true
}

Write-Host ""
Write-Host "==================================================================" -ForegroundColor Magenta
Write-Host "  MCHC Hardcore - automatische setup (Minecraft $MC, Fabric)"       -ForegroundColor Magenta
Write-Host "==================================================================" -ForegroundColor Magenta
Write-Host ""

# --- 0. Java check -------------------------------------------------------------
try {
    $javaVer = (& java -version 2>&1) -join "`n"
    if($javaVer -match '"(\d+)'){ $maj = [int]$Matches[1] } else { $maj = 0 }
    if($maj -lt 25){ Warn "Java $maj gedetecteerd. Minecraft $MC vereist Java 25. Installeer Temurin 25: https://adoptium.net/temurin/releases/?version=25" }
    else { Ok "Java $maj gevonden." }
} catch {
    Fail "Java niet gevonden in PATH. Installeer Temurin 25: https://adoptium.net/temurin/releases/?version=25"
}

# --- 1. Mappenstructuur --------------------------------------------------------
Info "Mappenstructuur aanmaken in $Server"
foreach($d in @('control','velocity\plugins','alpha\mods','beta\mods','client-mods')){
    New-Item -ItemType Directory -Force -Path (Join-Path $Server $d) | Out-Null
}

# --- 2. Gradle wrapper ophalen + jars bouwen -----------------------------------
$wrapperBat = 'https://raw.githubusercontent.com/FabricMC/fabric-example-mod/26.1/gradlew.bat'
$wrapperJar = 'https://raw.githubusercontent.com/FabricMC/fabric-example-mod/26.1/gradle/wrapper/gradle-wrapper.jar'

function Build-Project($projDir, $jarGlob, $destFiles){
    Info "Bouw project: $projDir"
    Download $wrapperBat (Join-Path $projDir 'gradlew.bat')
    Download $wrapperJar (Join-Path $projDir 'gradle\wrapper\gradle-wrapper.jar')
    Push-Location $projDir
    try {
        & .\gradlew.bat --no-daemon build
        if($LASTEXITCODE -ne 0){ throw "gradle build faalde (exit $LASTEXITCODE)" }
    } finally { Pop-Location }
    $jar = Get-ChildItem -Path (Join-Path $projDir 'build\libs') -Filter $jarGlob |
           Where-Object { $_.Name -notmatch '-sources' -and $_.Name -notmatch '-dev' } |
           Select-Object -First 1
    if(-not $jar){ throw "Geen jar gevonden in $projDir\build\libs ($jarGlob)" }
    foreach($d in $destFiles){ Copy-Item $jar.FullName $d -Force; Ok "jar -> $d" }
}

$buildOk = $true
try {
    Build-Project (Join-Path $Root 'mod') 'mchc-hardcore*.jar' @(
        (Join-Path $Server 'alpha\mods\mchc-hardcore.jar'),
        (Join-Path $Server 'beta\mods\mchc-hardcore.jar')
    )
} catch { Fail "Mod bouwen mislukt: $_"; $buildOk = $false }

# (Geen proxy meer: Velocity ondersteunt het 26.1-protocol nog niet. We gebruiken de
#  vanilla transfer-packet die de mod zelf verstuurt, dus er is geen proxy-plugin nodig.)

# --- 3. Fabric server-launcher (alpha + beta) ----------------------------------
try {
    $loader    = (Invoke-RestMethod "https://meta.fabricmc.net/v2/versions/loader/$MC" -Headers @{ 'User-Agent'=$UA } -UseBasicParsing)[0].loader.version
    $installer = (Invoke-RestMethod "https://meta.fabricmc.net/v2/versions/installer"   -Headers @{ 'User-Agent'=$UA } -UseBasicParsing)[0].version
    $srvUrl    = "https://meta.fabricmc.net/v2/versions/loader/$MC/$loader/$installer/server/jar"
    Download $srvUrl (Join-Path $Server 'alpha\server.jar')
    Download $srvUrl (Join-Path $Server 'beta\server.jar')
    Ok "Fabric server (loader $loader, installer $installer)"
} catch {
    Fail "Fabric server-jar downloaden mislukt: $_  -> handmatig: https://fabricmc.net/use/server/"
}

# --- 4. (geen proxy) -----------------------------------------------------------

# --- 5. Server-mods (alpha + beta) ---------------------------------------------
$serverMods = @('fabric-api','lithium','ferrite-core','krypton')
foreach($m in $serverMods){
    Get-ModrinthJar $m (Join-Path $Server 'alpha\mods') | Out-Null
    Get-ModrinthJar $m (Join-Path $Server 'beta\mods')  | Out-Null
}

# --- 6. Client-mods (voor in je .minecraft\mods) -------------------------------
$clientMods = @('fabric-api','sodium','lithium','ferrite-core','krypton','iris','immediatelyfast','entityculling')
foreach($m in $clientMods){
    Get-ModrinthJar $m (Join-Path $Server 'client-mods') | Out-Null
}

# --- 7. Configuratie + scripts genereren ---------------------------------------
Info "Configuratie genereren"

function New-ServerProperties($name, $port, $seed){
@"
# MCHC Hardcore - $name
server-port=$port
online-mode=false
enforce-secure-profile=false
accepts-transfers=true
hardcore=true
difficulty=hard
gamemode=survival
pvp=true
level-name=world
level-seed=$seed
motd=MCHC Hardcore ($name)
max-players=8
view-distance=10
simulation-distance=10
spawn-protection=0
allow-flight=true
sync-chunk-writes=true
max-tick-time=-1
enable-command-block=false
white-list=false
"@
}

function Rand-Seed { $r = New-Object System.Random; return ([int64]$r.Next() -shl 32) -bor [int64]($r.Next()) }

Set-Content -Path (Join-Path $Server 'alpha\server.properties') -Value (New-ServerProperties 'alpha' 25566 (Rand-Seed)) -Encoding ASCII
Set-Content -Path (Join-Path $Server 'beta\server.properties')  -Value (New-ServerProperties 'beta'  25567 (Rand-Seed)) -Encoding ASCII

Set-Content -Path (Join-Path $Server 'alpha\eula.txt') -Value "eula=true" -Encoding ASCII
Set-Content -Path (Join-Path $Server 'beta\eula.txt')  -Value "eula=true" -Encoding ASCII

function New-HardcoreProps($name, $partner, $partnerPort){
@"
serverName=$name
partnerName=$partner
partnerPort=$partnerPort
controlDir=../control
countdownSeconds=5
title=%player% is dood gegaan
subtitle=Kaulo slecht lol, wereld wordt gereset
localTransferHost=127.0.0.1
# Vul je PUBLIEKE IP in zodat je vriend (over internet) ook automatisch mee-verhuist
# bij een reset. Laat leeg als je alleen lokaal test.
publicTransferHost=
"@
}
Write-NoBom (Join-Path $Server 'alpha\hardcore.properties') (New-HardcoreProps 'alpha' 'beta'  25567)
Write-NoBom (Join-Path $Server 'beta\hardcore.properties')  (New-HardcoreProps 'beta'  'alpha' 25566)

# new-seed.ps1 (gebruikt door run-scripts bij elke reset)
@'
param([string]$PropsFile)
$rand = New-Object System.Random
$seed = ([int64]$rand.Next() -shl 32) -bor [int64]($rand.Next())
$lines = @()
if(Test-Path $PropsFile){ $lines = Get-Content $PropsFile | Where-Object { $_ -notmatch '^\s*level-seed=' } }
$lines += "level-seed=$seed"
Set-Content -Path $PropsFile -Value $lines -Encoding ASCII
Write-Host "[new-seed] nieuwe seed: $seed"
'@ | Set-Content -Path (Join-Path $Server 'new-seed.ps1') -Encoding UTF8

# run-scripts (auto-restart loops met wereld-reset)
function New-RunScript($name){
@"
@echo off
setlocal
cd /d "%~dp0"
set CONTROL=..\control
set NAME=$name
:loop
rem Kill een eventueel achtergebleven (of bevroren) JVM van DEZE server, zodat de wereld-lock
rem altijd vrij is. Anders crasht de start met "another process has locked the file".
powershell -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name='java.exe'\" | Where-Object { `$_.CommandLine -match 'mchc.server=%NAME%' } | ForEach-Object { Stop-Process -Id `$_.ProcessId -Force -ErrorAction SilentlyContinue }" >nul 2>&1

if exist "%CONTROL%\%NAME%.reset-now.flag" (
  echo [%NAME%] RESET: wereld wissen en nieuwe seed zetten...
  if exist world rmdir /s /q world
  powershell -NoProfile -ExecutionPolicy Bypass -File "..\new-seed.ps1" "%CD%\server.properties"
  del "%CONTROL%\%NAME%.reset-now.flag" >nul 2>&1
)
if exist "%CONTROL%\%NAME%.ready"  del "%CONTROL%\%NAME%.ready"  >nul 2>&1
if exist "%CONTROL%\%NAME%.active" del "%CONTROL%\%NAME%.active" >nul 2>&1

echo [%NAME%] Server start...
java -Dmchc.server=%NAME% -Xms1G -Xmx2G -jar server.jar nogui
echo [%NAME%] Server gestopt. Herstart over 2 sec... (sluit dit venster om definitief te stoppen)
timeout /t 2 /nobreak >nul
goto loop
"@ | Set-Content -Path (Join-Path $Server "$name\run.bat") -Encoding ASCII
}
New-RunScript 'alpha'
New-RunScript 'beta'

@"
@echo off
cd /d "%~dp0"
echo Start MCHC Hardcore (alpha + beta + supervisor) in aparte vensters...
start "MCHC alpha"    cmd /k alpha\run.bat
start "MCHC beta"     cmd /k beta\run.bat
timeout /t 2 /nobreak >nul
start "MCHC supervisor" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0supervisor.ps1"
echo.
echo Klaar.
echo   Verbind als je net begint met de ACTIEVE server:  localhost:25566   (alpha)
echo   Bij een dood verhuis je automatisch (transfer) naar de andere server - niets doen.
echo   Je vriend gebruikt jouw-publieke-IP en moet poorten 25566 en 25567 (TCP) geforward hebben.
echo Sluit de vensters om te stoppen.
pause
"@ | Set-Content -Path (Join-Path $Server 'START.bat') -Encoding ASCII

# supervisor.ps1 — bevriest de inactieve standby-server (RAM/CPU besparen)
Copy-Item (Join-Path $Root 'supervisor.template.ps1') (Join-Path $Server 'supervisor.ps1') -Force -ErrorAction SilentlyContinue
if(-not (Test-Path (Join-Path $Server 'supervisor.ps1'))){
    Warn "supervisor.template.ps1 niet gevonden naast setup.ps1 - standby wordt dan niet bevroren. (Niet kritiek.)"
}

Write-Host ""
Write-Host "==================================================================" -ForegroundColor Magenta
if($buildOk){ Ok "SETUP KLAAR." } else { Warn "Setup klaar, maar het bouwen van een jar is mislukt - zie meldingen hierboven." }
Write-Host "==================================================================" -ForegroundColor Magenta
Write-Host ""
Write-Host "Volgende stappen:" -ForegroundColor White
Write-Host "  1) Server starten:  dubbelklik  MCHC-Server\START.bat"
Write-Host "  2) Client-mods:     kopieer alles uit  MCHC-Server\client-mods\  naar  %APPDATA%\.minecraft\mods"
Write-Host "                      (installeer eerst Fabric Loader voor MC $MC via https://fabricmc.net/use/installer/)"
Write-Host "  3) Verbind met:     localhost:25566   (jij, begin altijd op alpha)"
Write-Host "                      jouw-publieke-IP:25566   (je vriend; forward TCP 25566 EN 25567)"
Write-Host "                      Vul je publieke IP in bij publicTransferHost in beide hardcore.properties."
Write-Host ""
