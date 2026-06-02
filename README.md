# MCHC Hardcore — coop hardcore with auto-reset (Minecraft 26.1.2, Fabric)

This quick vibe-coded mod resets your server when a player dies so you can automatically keep playing.
Two players, one hardcore world, goal: beat the Ender Dragon. The moment **one of you dies**
a big message appears on screen:

> **\<Playername\> died!**
> _So bad lol, resetting server_

It stays up for **5 seconds**, then you are **seamlessly** placed in a brand-new world
(new seed) — without anyone having to reconnect.

There is also a **HUD overlay** (bottom-left): playtime this run, total playtime, and the
number of deaths per player.

---

## How it works (short)

A Minecraft world cannot regenerate itself "live" with a new seed. So we use a double-buffer
idea: **two servers running at once**, and on death the players are sent to the other server
via the **vanilla transfer packet**.

```
   you + your friend
        |  (on death: automatic TRANSFER, no click)
        v
  Server "alpha" (25566)  <--->  Server "beta" (25567)
  where you play                 already up, fresh world
```

1. You play on **alpha**. **beta** is already fully booted with a fresh world
   (all 3 dimensions — overworld, nether, end — vanilla-generated, so the dragon works 100%).
2. Someone dies → 5s message → the mod sends everyone a **transfer** to **beta**
   (you only briefly see "Loading terrain", no disconnect, no Connect button).
3. In the background **alpha** resets itself: wipe world → **new random seed** → restart →
   ready again as the next standby.
4. Next death → ping-pong back to alpha. And so on.

> **Why no proxy (Velocity)?** Velocity does not support the 26.1 protocol yet — its newest
> build only knows Minecraft up to 1.21.11 and rejects a 26.1.2 client with
> *"Incompatible client"*. The vanilla transfer packet (since 1.20.5) does the same job,
> is already in the game, and needs no extra software.

Communication between the two servers goes through small flag files in `MCHC-Server/control`
(everything runs on your PC, so it's simple and reliable). Stats live in
`control/stats.properties` and survive every reset/transfer.

### Control: auto-reset vs. manual "next"

- **Normal:** death → 5s message → automatic transfer + reset.
- **If you click "Spectate World"** on the death screen within those 5 seconds, the auto-reset
  is **cancelled**. You stay in the current world as a spectator.
- From then on it only continues when you type **`next`** in the server console window
  (alpha or beta). Handy if you want to look around before resetting.

### Saving resources: the standby is "frozen"

Because two servers run at once, you'd expect double RAM/CPU. So a **supervisor** (separate
window) **freezes** the standby server you're not using:

- All threads suspended → **0% CPU** for the standby.
- The working set is emptied → **physical RAM** goes back to Windows (moves to the pagefile).
  In a test on this PC a frozen process dropped from 72 MB resident to ~0 MB.

When someone dies, the mod wakes the standby **immediately** (at the start of the 5-second
message), well before players are transferred — so you don't notice it. A server with players
on it is **never** frozen. On the very first start alpha stays awake so you can connect; beta
is only frozen once you are actually playing on alpha.

Technical: uses the Windows calls `NtSuspendProcess`/`NtResumeProcess` + `EmptyWorkingSet`
(no admin needed). That's why `max-tick-time=-1` is set in `server.properties` — otherwise
Minecraft's watchdog would think a tick took "minutes" after resuming and crash the server.
Don't want this? Just close the supervisor window; both servers keep running normally.

---

## What's included

| Item | What it is |
|---|---|
| `mod/` | **MCHC Hardcore Reset** — Fabric mod (client + server in one jar): detects death, shows the message, sends the transfer, resets the world, tracks stats and draws the HUD. |
| `setup.ps1` + `1-SETUP.bat` | Downloads everything, builds the jar and lays out the runnable structure. |
| `supervisor.template.ps1` | Copied to `MCHC-Server\supervisor.ps1`; freezes the standby. |
| `fix-install.ps1` | Repair: re-download mods + fix BOM, in case the first setup missed something. |

### Mods I imported (extra on top of your list)
- **Fabric API** — required base library for almost all Fabric mods and for this mod (server + client).

> Earlier versions used Velocity + FabricProxy-Lite. Those were **removed** because Velocity
> doesn't support 26.1 yet; it's now fully done with the built-in transfer packet.

### Your mods — server (alpha + beta)
Lithium, FerriteCore, Krypton — plus Fabric API and the `mchc-hardcore` mod.

### Your mods — client (in your own `.minecraft\mods`)
Sodium, Lithium, FerriteCore, Krypton, Iris Shaders, ImmediatelyFast, Entity Culling — plus Fabric API
**and `mchc-hardcore.jar`** (needed for the HUD overlay). Everything is prepared in `MCHC-Server/client-mods/`.

---

## Requirements

- **Java 25** (Temurin): https://adoptium.net/temurin/releases/?version=25 — required for MC 26.1.2.
- Internet (setup downloads the server and mods).
- Enough RAM: **2 servers run at once** (2 GB each by default) + your own Minecraft client.
  Thanks to freezing the standby it uses little in practice. 16 GB is comfortable.

---

## Install — step by step

1. **Double-click `1-SETUP.bat`.** This checks Java, builds the mod, downloads the Fabric server (x2)
   and all mods, and generates all config + scripts in `MCHC-Server\`.
   (First time takes a few minutes.)

2. **Start the server:** double-click `MCHC-Server\START.bat`.
   Three windows open: alpha, beta and the supervisor. Keep them open. (Closing = stopping;
   closing the supervisor window only stops the freezing.)

3. **Prepare the client (you and your friend, both):**
   - Install **Fabric Loader for MC 26.1.2**: https://fabricmc.net/use/installer/
   - Copy **everything** from `MCHC-Server\client-mods\` into `%APPDATA%\.minecraft\mods`
     (create the `mods` folder if it doesn't exist).
   - Start Minecraft with the **Fabric** profile.

4. **Connect:**
   - **You (host PC):** Multiplayer → Direct Connect → `localhost:25566` (always start on **alpha**).
   - **Your friend (internet):** give them your **public IP**; they connect to `your-ip:25566`.
     Forward **TCP 25566 and 25567** in your router (both servers, since the transfer points to the other port).
   - Put your **public IP** at `publicTransferHost` in **both** `hardcore.properties` files, otherwise on a
     reset your friend gets a transfer to `127.0.0.1` (= their own PC).

Done! On every death the message + transfer + reset happen automatically.

---

## Settings

**Message text / 5 seconds / public IP** — `MCHC-Server\alpha\hardcore.properties` and `...\beta\...`:
```
countdownSeconds=5
title=%player% died!
subtitle=So bad lol, resetting server
publicTransferHost=          # <- put your public IP here for your friend
```
(`%player%` is replaced by the name of whoever dies.)

**RAM per server** — in `MCHC-Server\alpha\run.bat` and `...\beta\run.bat` the line
`java -Dmchc.server=... -Xms1G -Xmx2G -jar server.jar nogui` — adjust `-Xmx2G`.

**Whitelist (recommended for just the two of you)** — set `white-list=true` in both `server.properties`.

---

## Manual download links (in case setup can't find something)

- Fabric server: https://fabricmc.net/use/server/
- Sodium: https://modrinth.com/mod/sodium · Lithium: https://modrinth.com/mod/lithium
- FerriteCore: https://modrinth.com/mod/ferrite-core · Krypton: https://modrinth.com/mod/krypton
- Iris: https://modrinth.com/mod/iris · ImmediatelyFast: https://modrinth.com/mod/immediatelyfast
- Entity Culling: https://modrinth.com/mod/entityculling · Fabric API: https://modrinth.com/mod/fabric-api

Pick the **26.1.2 / Fabric** version everywhere. Server mods → `alpha\mods` and `beta\mods`.
Client mods (incl. `mchc-hardcore.jar`) → your `.minecraft\mods`.

---

## Build the jar yourself (without setup)

```
cd mod && gradlew.bat build      # -> build\libs\mchc-hardcore-1.0.0.jar
```
Place it in `alpha\mods`, `beta\mods` and your `.minecraft\mods` (for the HUD).

---

## Troubleshooting

- **"Incompatible client"** → this was caused by Velocity (removed). Now connect directly to `localhost:25566`.
- **"Java 25 required"** → install Temurin 25 and re-run setup.
- **No message/HUD** → make sure `mchc-hardcore.jar` is in `alpha\mods`, `beta\mods` AND your `.minecraft\mods`.
- **Friend ends up on their own PC after a reset** → `publicTransferHost` not filled in `hardcore.properties`.
- **Friend can't connect** → TCP 25566 **and** 25567 forwarded? Firewall allows Java? Public IP correct?
- **"another process has locked the file"** → fixed: `run.bat` kills a leftover/frozen JVM of the same
  server before starting. If you still hit it, make sure no stray `java.exe` is running and restart.
- **Reset doesn't happen** → check `MCHC-Server\control` (flags like `alpha.ready`, `alpha.active`)
  and the server windows for `[MCHC]` log lines.

---

## Honest design note

The mod is **compiled and verified** against the real Minecraft 26.1.2 + Fabric API
(transfer packet, HUD API, networking — all names check out). What I could **not** do here:
play through a real 2-player session. The first live run is the real test; the log lines in
the server windows and the troubleshooting above will point you the right way.
