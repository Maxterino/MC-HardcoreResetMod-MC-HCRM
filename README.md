# MCHC Hardcore — coop hardcore met auto-reset (Minecraft 26.1.2, Fabric)

Twee spelers, één hardcore-wereld, doel: de Ender Dragon verslaan. Zodra **één van jullie sterft**
verschijnt er een grote melding op het scherm:

> **\<Spelernaam\> is dood gegaan**
> _Kaulo slecht lol, wereld wordt gereset_

Die blijft **5 seconden** staan, daarna worden jullie **naadloos** in een gloednieuwe wereld
(nieuwe seed) gezet — zonder dat iemand opnieuw hoeft te verbinden.

Daarnaast is er een **HUD-overlay** (midden-links): totale speeltijd (uu:mm:ss) met daaronder
het aantal doden per speler.

---

## Hoe het werkt (kort)

Een Minecraft-wereld kan zichzelf niet "live" met een nieuwe seed regenereren. Daarom gebruiken we
jouw double-buffer-idee: **twee servers tegelijk**, en bij een dood gaan de spelers via de
**vanilla transfer-packet** automatisch naar de andere server.

```
   jij + je vriend
        |  (bij dood: automatische TRANSFER, geen klik)
        v
  Server "alpha" (25566)  <--->  Server "beta" (25567)
  waar je speelt                 staat al klaar, verse wereld
```

1. Je speelt op **alpha**. **beta** staat al volledig opgestart klaar met een verse wereld
   (alle 3 dimensies — overworld, nether, end — gewoon vanilla gegenereerd, dus de draak werkt 100%).
2. Iemand sterft → 5 sec melding → de mod stuurt iedereen een **transfer** naar **beta**
   (je ziet alleen even "Loading terrain", geen disconnect, geen Connect-knop).
3. Op de achtergrond reset **alpha** zichzelf: wereld wissen → **nieuwe willekeurige seed** → herstart →
   staat weer klaar als volgende standby.
4. Volgende dood → ping-pong terug naar alpha. Enzovoort.

> **Waarom geen proxy (Velocity) meer?** Velocity ondersteunt het 26.1-protocol nog niet — de
> nieuwste build kent alleen Minecraft t/m 1.21.11 en weigert een 26.1.2-client met
> *"Incompatible client"*. De vanilla transfer-packet (sinds 1.20.5) doet hetzelfde werk,
> zit al in het spel, en heeft geen extra software nodig.

De communicatie tussen de twee servers loopt via simpele bestandjes in `MCHC-Server/control`
(alles draait op jouw pc, dus dat is supersimpel en betrouwbaar). De stats staan in
`control/stats.properties` en blijven dus bewaard over elke reset/transfer heen.

### Resources besparen: de standby wordt "bevroren"

Omdat er twee servers tegelijk draaien, zou je dubbel RAM/CPU verwachten. Daarom draait er een
**supervisor** (apart venster) die de standby-server die je *niet* gebruikt **bevriest**:

- Alle threads worden ge-suspend → **0% CPU** voor de standby.
- De working set wordt geleegd → het **fysieke RAM** gaat terug naar Windows (verhuist naar het
  pagefile). In mijn test op jouw pc zakte een bevroren proces van 72 MB resident naar ~0 MB.

Zodra iemand sterft, wekt de mod de standby **meteen** (bij het begin van de 5-seconden-melding),
ruim voordat de spelers worden doorgestuurd — dus je merkt er in de praktijk niets van. Een server
met spelers erop wordt **nooit** bevroren. Bij de allereerste start blijft alpha bewust wakker
zodat je kunt verbinden; beta wordt pas bevroren zodra jij daadwerkelijk op alpha speelt.

Technisch: gebruikt de Windows-calls `NtSuspendProcess`/`NtResumeProcess` + `EmptyWorkingSet`
(geen admin nodig). Daarom staat `max-tick-time=-1` in `server.properties` — anders zou Minecraft's
watchdog na het ontwaken denken dat een tick "minutenlang" duurde en de server crashen.
Wil je dit niet? Sluit gewoon het supervisor-venster; dan draaien beide servers normaal door.

---

## Wat zit erin

| Onderdeel | Wat het is |
|---|---|
| `mod/` | **MCHC Hardcore Reset** — Fabric-mod (client + server in één jar): detecteert dood, toont de melding, stuurt de transfer, reset de wereld, houdt stats bij en tekent de HUD. |
| `setup.ps1` + `1-SETUP.bat` | Downloadt alles, bouwt de jar en zet de hele draaibare structuur klaar. |
| `supervisor.template.ps1` | Wordt naar `MCHC-Server\supervisor.ps1` gekopieerd; bevriest de standby. |
| `fix-install.ps1` | Reparatie: download mods opnieuw + fix BOM, mocht de eerste setup iets missen. |

### Mods die ik heb geïmporteerd (extra t.o.v. jouw lijst)
- **Fabric API** — verplichte basis-library voor vrijwel alle Fabric-mods én voor mijn mod (server + client).

> Eerdere versies gebruikten Velocity + FabricProxy-Lite. Die zijn **verwijderd** omdat Velocity
> 26.1 nog niet ondersteunt; we doen het nu volledig met de ingebouwde transfer-packet.

### Jouw mods — server (alpha + beta)
Lithium, FerriteCore, Krypton — plus Fabric API en mijn `mchc-hardcore` mod.

### Jouw mods — client (in je eigen `.minecraft\mods`)
Sodium, Lithium, FerriteCore, Krypton, Iris Shaders, ImmediatelyFast, Entity Culling — plus Fabric API
**en `mchc-hardcore.jar`** (nodig voor de HUD-overlay). Alles staat klaar in `MCHC-Server/client-mods/`.

---

## Benodigdheden

- **Java 25** (Temurin): https://adoptium.net/temurin/releases/?version=25 — verplicht voor MC 26.1.2.
- Internet (de setup downloadt de server en mods).
- Genoeg RAM: er draaien **2 servers tegelijk** (standaard 2 GB elk) + je eigen Minecraft-client.
  Dankzij het bevriezen van de standby gebruikt die in de praktijk weinig. Op 16 GB zit dat goed.

---

## Installeren — stap voor stap

1. **Dubbelklik `1-SETUP.bat`.** Dit controleert Java, bouwt de mod, downloadt de Fabric-server (×2)
   en alle mods, en genereert alle configuratie + scripts in `MCHC-Server\`.
   (Eerste keer duurt dit een paar minuten.)

2. **Server starten:** dubbelklik `MCHC-Server\START.bat`.
   Er openen 3 vensters: alpha, beta en de supervisor. Laat ze open staan. (Sluiten = stoppen;
   het supervisor-venster sluiten stopt alleen het bevriezen.)

3. **Client klaarmaken (jij en je vriend, allebei):**
   - Installeer **Fabric Loader voor MC 26.1.2**: https://fabricmc.net/use/installer/
   - Kopieer **alles** uit `MCHC-Server\client-mods\` naar `%APPDATA%\.minecraft\mods`
     (maak de `mods`-map aan als die niet bestaat).
   - Start Minecraft met het **Fabric**-profiel.

4. **Verbinden:**
   - **Jij (host-pc):** Multiplayer → Direct connect → `localhost:25566` (begin altijd op **alpha**).
   - **Je vriend (internet):** geef hem je **publieke IP**; hij verbindt met `jouw-ip:25566`.
     Forward in je router **TCP 25566 én 25567** (beide servers, want de transfer wijst naar de andere poort).
   - Zet je **publieke IP** bij `publicTransferHost` in **beide** `hardcore.properties`, anders krijgt
     je vriend bij een reset een transfer naar `127.0.0.1` (= zijn eigen pc).

Klaar! Bij elke dood gebeurt de melding + transfer + reset automatisch.

---

## Instellingen aanpassen

**Melding-tekst / 5 seconden / publiek IP** — `MCHC-Server\alpha\hardcore.properties` en `...\beta\...`:
```
countdownSeconds=5
title=%player% is dood gegaan
subtitle=Kaulo slecht lol, wereld wordt gereset
publicTransferHost=          # <- vul hier je publieke IP in voor je vriend
```
(`%player%` wordt vervangen door de naam van wie sterft.)

**RAM per server** — in `MCHC-Server\alpha\run.bat` en `...\beta\run.bat` de regel
`java -Dmchc.server=... -Xms1G -Xmx2G -jar server.jar nogui` — pas `-Xmx2G` aan.

**Whitelist (aanrader voor alleen jullie twee)** — zet in beide `server.properties` `white-list=true`.

---

## Handmatige download-links (voor als de setup iets niet vindt)

- Fabric server: https://fabricmc.net/use/server/
- Sodium: https://modrinth.com/mod/sodium · Lithium: https://modrinth.com/mod/lithium
- FerriteCore: https://modrinth.com/mod/ferrite-core · Krypton: https://modrinth.com/mod/krypton
- Iris: https://modrinth.com/mod/iris · ImmediatelyFast: https://modrinth.com/mod/immediatelyfast
- Entity Culling: https://modrinth.com/mod/entityculling · Fabric API: https://modrinth.com/mod/fabric-api

Kies overal de versie voor **26.1.2 / Fabric**. Server-mods → `alpha\mods` én `beta\mods`.
Client-mods (incl. `mchc-hardcore.jar`) → je `.minecraft\mods`.

---

## Zelf de jar bouwen (zonder setup)

```
cd mod && gradlew.bat build      # -> build\libs\mchc-hardcore-1.0.0.jar
```
Plaats die in `alpha\mods`, `beta\mods` én in je `.minecraft\mods` (voor de HUD).

---

## Probleemoplossing

- **"Incompatible client"** → dit kwam door Velocity (verwijderd). Verbind nu direct met `localhost:25566`.
- **"Java 25 vereist"** → installeer Temurin 25 en herstart de setup.
- **Geen melding/HUD** → check dat `mchc-hardcore.jar` in `alpha\mods`, `beta\mods` én je `.minecraft\mods` staat.
- **Vriend belandt bij reset op zijn eigen pc** → `publicTransferHost` niet ingevuld in `hardcore.properties`.
- **Vriend kan niet verbinden** → TCP 25566 **en** 25567 geforward? Firewall Java toestaan? Publieke IP klopt?
- **Reset gebeurt niet** → kijk in `MCHC-Server\control` (bestandjes als `alpha.ready`, `alpha.active`)
  en in de servervensters naar `[MCHC]`-logregels.

---

## Belangrijke ontwerp-notitie (eerlijk)

De mod is door mij **gecompileerd en geverifieerd** tegen de echte Minecraft 26.1.2 + Fabric API
(transfer-packet, HUD-API, networking — alle namen kloppen). Wat ik hier **niet** kon: een echte
2-speler-sessie naspelen. De eerste live run is de echte test; de logregels in de servervensters
en de probleemoplossing hierboven wijzen je dan de weg.
