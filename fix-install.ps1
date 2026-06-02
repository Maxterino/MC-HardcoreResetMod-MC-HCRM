<#
  MCHC - reparatie:
   1) Download de Fabric-mods (server + client) opnieuw, robuust via de Modrinth-API.
   2) Herschrijf velocity.toml en andere configs ZONDER BOM (anders crasht de TOML-parser).
  Veilig om opnieuw te draaien.
#>
$ErrorActionPreference = 'Continue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$S  = Join-Path $PSScriptRoot 'MCHC-Server'
$MC = '26.1.2'
$UA = 'MCHC-setup/1.0 (maxvmaasakker@gmail.com)'

function Write-NoBom($path, $text){
    $enc = New-Object System.Text.UTF8Encoding($false)   # UTF-8 zonder BOM
    [System.IO.File]::WriteAllText($path, $text, $enc)
}

# Download de nieuwste passende Fabric versie van een Modrinth-mod (client-side filteren = betrouwbaar).
function Get-Mod($slug, $dest){
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    $url = "https://api.modrinth.com/v2/project/$slug/version?loaders=%5B%22fabric%22%5D"
    try {
        $vs = Invoke-RestMethod -Uri $url -Headers @{ 'User-Agent' = $UA } -UseBasicParsing
    } catch {
        Write-Host ("  [API-fout] {0}: {1}" -f $slug, $_.Exception.Message) -ForegroundColor Red
        return
    }
    $pick = $vs | Where-Object { $_.game_versions -contains $MC }   | Select-Object -First 1
    if(-not $pick){ $pick = $vs | Where-Object { $_.game_versions -contains '26.1' } | Select-Object -First 1 }
    if(-not $pick){ $pick = $vs | Select-Object -First 1 }
    if(-not $pick){ Write-Host "  [geen versie] $slug" -ForegroundColor Red; return }
    $f = $pick.files | Where-Object { $_.primary } | Select-Object -First 1
    if(-not $f){ $f = $pick.files | Select-Object -First 1 }
    $out = Join-Path $dest $f.filename
    try {
        Invoke-WebRequest -Uri $f.url -OutFile $out -Headers @{ 'User-Agent' = $UA } -UseBasicParsing
        Write-Host ("  [ok] {0,-16} -> {1}" -f $slug, $f.filename) -ForegroundColor Green
    } catch {
        Write-Host ("  [download-fout] {0}: {1}" -f $slug, $_.Exception.Message) -ForegroundColor Red
    }
    Start-Sleep -Milliseconds 300   # vriendelijk voor de Modrinth-API
}

Write-Host "== Server-mods (alpha + beta) ==" -ForegroundColor Cyan
# Geen proxy meer: we gebruiken de vanilla transfer-packet, dus geen fabricproxy-lite.
$serverMods = @('fabric-api','lithium','ferrite-core','krypton')
foreach($m in $serverMods){
    Get-Mod $m (Join-Path $S 'alpha\mods')
    Get-Mod $m (Join-Path $S 'beta\mods')
}

Write-Host "== Client-mods ==" -ForegroundColor Cyan
$clientMods = @('fabric-api','sodium','lithium','ferrite-core','krypton','iris','immediatelyfast','entityculling')
foreach($m in $clientMods){ Get-Mod $m (Join-Path $S 'client-mods') }

Write-Host "== Configs zonder BOM herschrijven ==" -ForegroundColor Cyan
foreach($p in @('alpha\hardcore.properties','beta\hardcore.properties')){
    $fp = Join-Path $S $p
    if(Test-Path $fp){
        $t = [System.IO.File]::ReadAllText($fp) -replace "^﻿",""
        Write-NoBom $fp $t
        Write-Host "  [ok] BOM-check: $p" -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "Klaar. Inhoud alpha\mods:" -ForegroundColor White
Get-ChildItem (Join-Path $S 'alpha\mods') -ErrorAction SilentlyContinue | Select-Object Name, @{n='KB';e={[int]($_.Length/1KB)}} | Format-Table -AutoSize
