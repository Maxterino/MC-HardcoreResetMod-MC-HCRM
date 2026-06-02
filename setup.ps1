<#
  MCHC Hardcore - setup script
  Downloads the Fabric server (x2) and all mods, and builds the mod jar.
  Builds the complete runnable structure in .\MCHC-Server\

  Run via 1-SETUP.bat (double-click) or:  powershell -ExecutionPolicy Bypass -File setup.ps1
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
function Fail($m){ Write-Host "[FAIL ] $m" -ForegroundColor Red }

function Download($url, $dest){
    $dir = Split-Path -Parent $dest
    if(-not (Test-Path $dir)){ New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    Info "download: $url"
    Invoke-WebRequest -Uri $url -OutFile $dest -Headers @{ 'User-Agent' = $UA } -UseBasicParsing
    Ok ("saved: " + (Split-Path -Leaf $dest))
}

# Writes text as UTF-8 WITHOUT BOM (otherwise TOML/properties parsers crash).
function Write-NoBom($path, $text){
    $dir = Split-Path -Parent $path
    if(-not (Test-Path $dir)){ New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))
}

# Fetches the latest Fabric version of a Modrinth mod for MC $MC and downloads it.
# We fetch ALL fabric versions and filter client-side -> more reliable than server-side filters.
function Get-ModrinthJar($slug, $destDir){
    New-Item -ItemType Directory -Force -Path $destDir | Out-Null
    $url = "https://api.modrinth.com/v2/project/$slug/version?loaders=%5B%22fabric%22%5D"
    try {
        $vs = Invoke-RestMethod -Uri $url -Headers @{ 'User-Agent' = $UA } -UseBasicParsing
    } catch {
        Fail "Modrinth API error for '$slug': $($_.Exception.Message). Manual: https://modrinth.com/mod/$slug"
        return $false
    }
    $pick = $vs | Where-Object { $_.game_versions -contains $MC }   | Select-Object -First 1
    if(-not $pick){ $pick = $vs | Where-Object { $_.game_versions -contains '26.1' } | Select-Object -First 1 }
    if(-not $pick){ $pick = $vs | Select-Object -First 1 }
    if(-not $pick){ Fail "No Fabric version found for '$slug'. Manual: https://modrinth.com/mod/$slug"; return $false }
    $file = $pick.files | Where-Object { $_.primary } | Select-Object -First 1
    if(-not $file){ $file = $pick.files | Select-Object -First 1 }
    try {
        Download $file.url (Join-Path $destDir $file.filename)
    } catch {
        Fail "Download failed for '$slug': $($_.Exception.Message)"
        return $false
    }
    Start-Sleep -Milliseconds 300
    return $true
}

Write-Host ""
Write-Host "==================================================================" -ForegroundColor Magenta
Write-Host "  MCHC Hardcore - automatic setup (Minecraft $MC, Fabric)"          -ForegroundColor Magenta
Write-Host "==================================================================" -ForegroundColor Magenta
Write-Host ""

# --- 0. Java check -------------------------------------------------------------
try {
    $javaVer = (& java -version 2>&1) -join "`n"
    if($javaVer -match '"(\d+)'){ $maj = [int]$Matches[1] } else { $maj = 0 }
    if($maj -lt 25){ Warn "Java $maj detected. Minecraft $MC requires Java 25. Install Temurin 25: https://adoptium.net/temurin/releases/?version=25" }
    else { Ok "Java $maj found." }
} catch {
    Fail "Java not found in PATH. Install Temurin 25: https://adoptium.net/temurin/releases/?version=25"
}

# --- 1. Folder structure -------------------------------------------------------
Info "Creating folder structure in $Server"
foreach($d in @('control','alpha\mods','beta\mods','client-mods')){
    New-Item -ItemType Directory -Force -Path (Join-Path $Server $d) | Out-Null
}

# --- 2. Gradle wrapper + build the jar -----------------------------------------
$wrapperBat = 'https://raw.githubusercontent.com/FabricMC/fabric-example-mod/26.1/gradlew.bat'
$wrapperJar = 'https://raw.githubusercontent.com/FabricMC/fabric-example-mod/26.1/gradle/wrapper/gradle-wrapper.jar'

function Build-Project($projDir, $jarGlob, $destFiles){
    Info "Building project: $projDir"
    Download $wrapperBat (Join-Path $projDir 'gradlew.bat')
    Download $wrapperJar (Join-Path $projDir 'gradle\wrapper\gradle-wrapper.jar')
    Push-Location $projDir
    try {
        & .\gradlew.bat --no-daemon build
        if($LASTEXITCODE -ne 0){ throw "gradle build failed (exit $LASTEXITCODE)" }
    } finally { Pop-Location }
    $jar = Get-ChildItem -Path (Join-Path $projDir 'build\libs') -Filter $jarGlob |
           Where-Object { $_.Name -notmatch '-sources' -and $_.Name -notmatch '-dev' } |
           Select-Object -First 1
    if(-not $jar){ throw "No jar found in $projDir\build\libs ($jarGlob)" }
    foreach($d in $destFiles){ Copy-Item $jar.FullName $d -Force; Ok "jar -> $d" }
}

$buildOk = $true
try {
    Build-Project (Join-Path $Root 'mod') 'mchc-hardcore*.jar' @(
        (Join-Path $Server 'alpha\mods\mchc-hardcore.jar'),
        (Join-Path $Server 'beta\mods\mchc-hardcore.jar'),
        (Join-Path $Server 'client-mods\mchc-hardcore.jar')
    )
} catch { Fail "Building the mod failed: $_"; $buildOk = $false }

# (No proxy: Velocity does not support the 26.1 protocol yet. We use the vanilla
#  transfer packet that the mod sends itself, so no proxy plugin is needed.)

# --- 3. Fabric server launcher (alpha + beta) ----------------------------------
try {
    $loader    = (Invoke-RestMethod "https://meta.fabricmc.net/v2/versions/loader/$MC" -Headers @{ 'User-Agent'=$UA } -UseBasicParsing)[0].loader.version
    $installer = (Invoke-RestMethod "https://meta.fabricmc.net/v2/versions/installer"   -Headers @{ 'User-Agent'=$UA } -UseBasicParsing)[0].version
    $srvUrl    = "https://meta.fabricmc.net/v2/versions/loader/$MC/$loader/$installer/server/jar"
    Download $srvUrl (Join-Path $Server 'alpha\server.jar')
    Download $srvUrl (Join-Path $Server 'beta\server.jar')
    Ok "Fabric server (loader $loader, installer $installer)"
} catch {
    Fail "Downloading the Fabric server jar failed: $_  -> manual: https://fabricmc.net/use/server/"
}

# --- 4. Server mods (alpha + beta) ---------------------------------------------
$serverMods = @('fabric-api','lithium','ferrite-core','krypton')
foreach($m in $serverMods){
    Get-ModrinthJar $m (Join-Path $Server 'alpha\mods') | Out-Null
    Get-ModrinthJar $m (Join-Path $Server 'beta\mods')  | Out-Null
}

# --- 5. Client mods (for your .minecraft\mods) ---------------------------------
$clientMods = @('fabric-api','sodium','lithium','ferrite-core','krypton','iris','immediatelyfast','entityculling')
foreach($m in $clientMods){
    Get-ModrinthJar $m (Join-Path $Server 'client-mods') | Out-Null
}

# --- 6. Generate config + scripts ----------------------------------------------
Info "Generating configuration"

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
title=%player% died!
subtitle=So bad lol, resetting server
localTransferHost=127.0.0.1
# Fill in your PUBLIC IP so your friend (over the internet) is also transferred
# automatically on a reset. Leave empty if you only test locally.
publicTransferHost=
"@
}
Write-NoBom (Join-Path $Server 'alpha\hardcore.properties') (New-HardcoreProps 'alpha' 'beta'  25567)
Write-NoBom (Join-Path $Server 'beta\hardcore.properties')  (New-HardcoreProps 'beta'  'alpha' 25566)

# new-seed.ps1 (used by the run scripts on each reset)
@'
param([string]$PropsFile)
$rand = New-Object System.Random
$seed = ([int64]$rand.Next() -shl 32) -bor [int64]($rand.Next())
$lines = @()
if(Test-Path $PropsFile){ $lines = Get-Content $PropsFile | Where-Object { $_ -notmatch '^\s*level-seed=' } }
$lines += "level-seed=$seed"
Set-Content -Path $PropsFile -Value $lines -Encoding ASCII
Write-Host "[new-seed] new seed: $seed"
'@ | Set-Content -Path (Join-Path $Server 'new-seed.ps1') -Encoding UTF8

# run scripts (auto-restart loops with world reset)
function New-RunScript($name){
@"
@echo off
setlocal
cd /d "%~dp0"
set CONTROL=..\control
set NAME=$name
:loop
rem Kill any leftover (or frozen) JVM of THIS server so the world lock is always free.
rem Otherwise the start crashes with "another process has locked the file".
powershell -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name='java.exe'\" | Where-Object { `$_.CommandLine -match 'mchc.server=%NAME%' } | ForEach-Object { Stop-Process -Id `$_.ProcessId -Force -ErrorAction SilentlyContinue }" >nul 2>&1

if exist "%CONTROL%\%NAME%.reset-now.flag" (
  echo [%NAME%] RESET: wiping world and setting a new seed...
  if exist world rmdir /s /q world
  powershell -NoProfile -ExecutionPolicy Bypass -File "..\new-seed.ps1" "%CD%\server.properties"
  del "%CONTROL%\%NAME%.reset-now.flag" >nul 2>&1
)
if exist "%CONTROL%\%NAME%.ready"  del "%CONTROL%\%NAME%.ready"  >nul 2>&1
if exist "%CONTROL%\%NAME%.active" del "%CONTROL%\%NAME%.active" >nul 2>&1

echo [%NAME%] Server starting...
java -Dmchc.server=%NAME% -Xms1G -Xmx2G -jar server.jar nogui
echo [%NAME%] Server stopped. Restarting in 2 sec... (close this window to stop for good)
timeout /t 2 /nobreak >nul
goto loop
"@ | Set-Content -Path (Join-Path $Server "$name\run.bat") -Encoding ASCII
}
New-RunScript 'alpha'
New-RunScript 'beta'

@"
@echo off
cd /d "%~dp0"
echo Starting MCHC Hardcore (alpha + beta + supervisor) in separate windows...
start "MCHC alpha"    cmd /k alpha\run.bat
start "MCHC beta"     cmd /k beta\run.bat
timeout /t 2 /nobreak >nul
start "MCHC supervisor" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0supervisor.ps1"
echo.
echo Done.
echo   When you start fresh, connect to the ACTIVE server:  localhost:25566   (alpha)
echo   On death you are transferred automatically to the other server - do nothing.
echo   Your friend uses your public IP and must port-forward TCP 25566 AND 25567.
echo Close the windows to stop.
pause
"@ | Set-Content -Path (Join-Path $Server 'START.bat') -Encoding ASCII

# supervisor.ps1 - freezes the inactive standby server (saves RAM/CPU)
Copy-Item (Join-Path $Root 'supervisor.template.ps1') (Join-Path $Server 'supervisor.ps1') -Force -ErrorAction SilentlyContinue
if(-not (Test-Path (Join-Path $Server 'supervisor.ps1'))){
    Warn "supervisor.template.ps1 not found next to setup.ps1 - the standby will not be frozen. (Not critical.)"
}

Write-Host ""
Write-Host "==================================================================" -ForegroundColor Magenta
if($buildOk){ Ok "SETUP DONE." } else { Warn "Setup done, but building a jar failed - see messages above." }
Write-Host "==================================================================" -ForegroundColor Magenta
Write-Host ""
Write-Host "Next steps:" -ForegroundColor White
Write-Host "  1) Start the server:  double-click  MCHC-Server\START.bat"
Write-Host "  2) Client mods:       copy everything from  MCHC-Server\client-mods\  into  %APPDATA%\.minecraft\mods"
Write-Host "                        (install Fabric Loader for MC $MC first via https://fabricmc.net/use/installer/)"
Write-Host "  3) Connect to:        localhost:25566   (you, always start on alpha)"
Write-Host "                        your-public-IP:25566   (your friend; forward TCP 25566 AND 25567)"
Write-Host "                        Fill in your public IP at publicTransferHost in both hardcore.properties files."
Write-Host ""
