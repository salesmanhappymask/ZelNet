# ZelNet

ZelNet is one ComputerCraft program that runs a whole multi-dimension network: servers, routers, TekMail clients, and a general packet carrier that any program can use. It replaces the separate TekMail server, client, router and TekBridge programs.

Built for Minecraft 1.6.4 with ComputerCraft 1.63, MoarPeripherals 1.5, Computronics 0.4.2, OpenPeripheral Core 0.4.1 and Thermal Expansion tesseracts.

## What you get

* **One Main server** that holds the network directory and the username registry, and as many **Satellite servers** as you have dimensions. Every server serves its own dimension and talks to the others.
* **Provisioning on pocket computers.** Any server writes a ready-to-boot install onto an advanced pocket computer (item 31965:1) in its setup drive, for a client, router, endpoint, or (from Main) a satellite server. A pocket computer holds about 1 MB, so every install fits on one. Floppy disks still work as a fallback. A device trusts only the server that made its install.
* **A display wall on every server.** One large monitor shows live traffic and processes, a second shows a tabbed, touchable copy of the console, and a small monitor between them sets up new devices by touch.
* **Encryption everywhere.** Traffic between servers is encrypted with the Computronics Cipher Block and authenticated with an HMAC. Traffic between a device and its server uses a per-device key from its disk. Data on server disks is encrypted too.
* **Links that fit your build.** Wireless and wired modems for short range, BitNet towers (3000 blocks) and mini antennas (650 blocks) for long range, and tesseract disk bridges between dimensions, built into each server.
* **TekMail** with private messages across dimensions, a global chatroom and a local one per dimension, an account directory and admin tools.
* **A carrier for any program**: send packets, make requests, and publish or subscribe to topics across every dimension. See [docs/PROTOCOL.md](docs/PROTOCOL.md).
* **A public gateway for plain rednet.** Computers that do not run ZelNet can send messages and share topics across every dimension with ordinary `rednet`, through any ZelNet server or router in range. See [docs/PUBLIC.md](docs/PUBLIC.md).

## Hardware

| Computer | Needs |
|---|---|
| Main server | Advanced computer, wireless modem (or BitNet tower), Cipher Block on the wired network, the display wall below, data drives, optional OpenCCSensors proximity sensor |
| Satellite server | Same as Main, plus a tesseract bridge towards a server in another dimension |
| Router | Computer with a wireless modem, or a BitNet tower or mini antenna |
| Client | Computer (standard or advanced) with a wireless modem |
| Endpoint | Any computer with a modem that runs your own program |

### Server layout

Every server uses the same build:

* The computer with 3 disk drives on each side (data storage, one pocket computer in each drive you use), a wireless router, a proximity sensor, and a Cipher Block.
* Two large advanced monitors, each 6 blocks wide and 3 tall, with a 1 wide, 2 tall advanced monitor between them and one disk drive (the setup drive) under that small monitor.
* All monitors and drives, and any printers, connect to the computer through wired modems.

The 1x3 monitors that used to sit above the side drives are no longer used; the drive data now lives on the Drives tab.

| Display | Shows |
|---|---|
| Activity monitor (6x3) | Live traffic (every packet in, out and across the backbone, plus log events), packets per second, the running processes and timers, and headline numbers |
| Console monitor (6x3) | The console as touch tabs: Overview, Devices, Accounts, Network, Bridges, Drives, Airlocks, Log. Read only; changes are made on the terminal |
| Setup monitor (1x2) | Device setup by touch: pick a role, accept or tap in a name, and the install is written to the pocket computer in the setup drive. Works only while the console is unlocked |

The setup wizard asks for each display by its peripheral name. While it asks, every monitor shows its own name in large text; type `12` or `monitor_12` (and `7` or `drive_7` for the setup drive). Change them later under Settings, Displays.

### Cipher Blocks

Every server needs a Computronics Cipher Block reachable by the computer (side or wired modem). The encryption key comes from the six item stacks inside the block, so **every server's Cipher Block must hold exactly the same items in the same slots with the same stack sizes**. Avoid named or enchanted items. Put the server and its Cipher Block somewhere players cannot open them: anyone who can see the items can copy the key.

ZelNet checks this for you. Servers exchange a fingerprint of their Cipher Block, and the console shows a warning if a neighbor's items differ.

### Tesseract bridges (between dimensions)

A bridge uses two tesseracts and two disk drives on each side, exactly like TekBridge:

* Your **send** tesseract and the peer's **receive** tesseract share one frequency; your **receive** tesseract and the peer's **send** tesseract share another. Set them to send and receive items.
* Each tesseract touches one disk drive. Put one blank pocket computer in your send drive and one in the peer's send drive to start. A pocket computer carries up to about 1 MB per trip; floppy disks still work but carry only 125 KB.
* The console's Bridges page finds the gear and probes the directions for you.
* **Bridge report.** Press **r** on the terminal's Bridges page, or **Push report** on the console monitor's Bridges tab. The server uploads every bridge's state, faults and retry timers, what is in each drive (disk id, label, batch file), each tesseract's frequency and the last 150 steps the bridge took, including every pull and what it moved, to paste.rs and shows the address. A copy is saved in `/bridge_report.txt`.

### BitNet towers

A complete BitNet tower attached to a server or router extends that node's range to 3000 blocks (2400 in thunderstorms). A tower with **no** computer attached repeats messages automatically, which is an easy way to extend coverage. Mini antennas (650 blocks) work for routers and clients.

## Setting up

### 1. Main server

1. Place the computer, the Cipher Block, a wireless modem and a disk drive. Copy `zelnet` onto the computer.
2. Run `zelnet`. The setup wizard asks for the network name, this dimension's realm name (for example `EARTH`), a console password and the first TekMail admin account, then checks the Cipher Block.
3. Add `shell.run("zelnet")` to `/startup` (the wizard offers to do it).

### 2. Satellite servers (other dimensions)

1. Put a pocket computer in Main's setup drive. On the setup monitor tap **Satellite**, tap in the realm name (for example `MARS`) and tap **Write**. (The terminal's **Devices**, **New device** does the same.)
2. Carry the pocket computer to the new dimension, put it in a disk drive of the new server and reboot. The installer copies the program and the network keys.
3. Run through the short local setup (console password, drives, monitors) and set up the bridge on the **Bridges** page on both sides.

### 3. Routers, clients and endpoints

Put a pocket computer in the server's setup drive, unlock the console, and on the setup monitor tap the role, then **Next** and **Write** (the name is filled in for you). Put the pocket computer into a disk drive next to the new computer and reboot that computer. The device finds the network by itself and connects to the server that made its install. Running a pocket computer by itself does not install anything; it has to sit in a drive.

### 4. Airlocks

An airlock computer needs a modem and redstone from an oxygen detector. It can be within wireless range of the server, on the server's cable, or within wireless range of any ZelNet router; routers pass airlock traffic to their server and back, so airlocks work anywhere the network reaches. Doors also drive the airlock block from a second side. Put a pocket computer in the setup drive and tap **Airlock** on the setup monitor (or use **Devices, New, Airlock** on the console). Put the pocket in a drive next to the airlock computer and reboot it. The first start asks:

* **What the computer is:**
  * **Hallway door** opens and seals. Doors of one hallway share a name ending in a letter (`dock-A`, `dock-B`), and setup asks **which room the door opens into**, offering the rooms the server knows.
  * **Hallway sensor** reports the air in its hallway and is named after its doors with `-C` (`dock-C`).
  * **Room sensor** reports the air in a sealed room and asks for the room's name. `Hub`, `North`, `South`, `East` and `West` (any capitalization) also show on the Athena navmap; any other name works as well.
  * **Security door** joins two rooms with no detector of its own. It is opened and closed from the console with lock and unlock, and it closes by itself while either room has no air.
* **The detector side, the door side, the monitor width and an optional warning light.**

Press **S** on the airlock computer at any time to change these; every question starts on the current answer. The airlock finds the server by itself and links to a rebuilt server too. Airlock control must be on (**Settings, Airlock control**). The program is `programs/airlock.lua` if you want to install it by hand.

How sealing works:

* **Each door joins two areas:** its hallway, read by the hallway's `-C` sensor, and the room it opens into, read by that room's sensor. A door opens only when both hold oxygen and seals when either does not. Its own detector is a local failsafe. A room without a room sensor online is judged from the detectors of the doors that open into it. The room of a door can also be set from the console under **Airlocks, (door), Set room**; a room set there wins over the door's own answer.
* **Room sensors are the authority for their rooms.** Every door of a room listens to the same room sensor, so the doors of a room cannot disagree. Door screens show both areas and say why a door is sealed.
* **The `-C` sensor is the authority for its doors.** Each sensor tells its own doors directly whenever its reading changes, and again every 10 seconds. While it reads no oxygen its doors refuse to open, whatever the server says, and report that back; the server then seals the other door of the zone too. Only a manual unseal from the console overrides this.
* **Rooms vote when they have no sensor.** Without a room sensor, the detectors of the doors that open into a room form its area, and the room counts as breached only when most of them read no oxygen. On Station Athena doors that never answered the room question fall back to the built-in layout.
* **Only the breached section seals.** When an area loses oxygen, every door that borders it seals and the rest of the station stays open.
* **Confirmed losses only.** A low reading has to last 3 seconds before it counts, or 8 seconds when a door into that area just opened, because the doorway air reads as no oxygen for a moment after a door opens. This is what stops the doors from flapping.
* **Staged reopening.** After a breach the whole station often drops at once, since open doors make it one volume. Doors then reopen one at a time, 4 seconds apart, once both of their sides have held oxygen for 8 seconds. A door that loses air within 15 seconds of opening closes again and waits 30 seconds before the next try, doubling up to 10 minutes. The breached area is the one whose doors never reopen.
* **Reliable reports.** Every report waits for the server's answer and is sent again each second, up to five times, and every airlock computer checks in every 30 seconds, so a lost message cannot leave the server with a stale reading for long.
* **Full lockdown on command.** Press **Lockdown (l)** under **Airlocks** on the console to seal every door of a station (a station is every group that shares a name once trailing digits are dropped, so `Athena` and `Athena2` to `Athena8` are one station). It stays sealed, even across a reboot, until you press **Release (x)**. Setting `containment = true` in the config makes any leak close the whole station automatically for at least 15 seconds instead.
* **Without the server.** A sensor also tells its own doors directly when its zone loses air, and a door seals by itself when its own detector loses air. Either way the door then reports to the server, which corrects it if it disagrees.
* **Lockdown on the airlocks.** During a lockdown every airlock computer shows STATION LOCKDOWN. Doors that are locked down, sealed or locked flash red on their screens and monitors. The setup asks for an optional warning light side: a redstone output there pulses with the flash, so lamps next to the airlock blocks flash too.
* **Push logs.** Press **Logs (p)** under **Airlocks** on the console, or **Push logs** on the console monitor's Airlocks tab. The server asks every airlock for its own log, adds its event log (every report, every command with the reason for it, area changes, retries, lockdowns and updates) and a snapshot of every airlock, uploads it to paste.rs (or dpaste.com) and shows the address. A copy is saved in `/airlock_logs.txt`. Airlock computers keep their log in `/airlock.log`, the server in `/zn_airlock.log`.
* **Airlock updates.** Airlock disks carry the network's update key. Airlocks that have it take program updates from the server by themselves, one at a time and never during a lockdown; each update is signed with the key and every part is checked before it is installed. Airlocks installed before this release need one last manual reinstall from a new disk to get the key.
* **Airlocks follow server restarts.** When the server they are linked to restarts, airlocks that carry the update key reboot by themselves, each after 1 to 12 seconds so they do not all go down together; their doors close while they reboot. The restart notice is signed with the key, an airlock that was itself just started only takes note of it, and switching to a different server does not trigger a reboot.
* **Station Athena navmap.** **Settings, Setup Athena Navmap** puts a live map on a 6 wide by 5 tall advanced monitor: the station on the right, each zone green while it holds oxygen, cyan while a reading is being confirmed or settling, and flashing red with a callout when it has no oxygen. Where each door crosses its hallway, a line of blocks flashes while the door is not simply open, with a small label: dark blue SEALING during normal operation, light blue RETRY with its countdown, red and orange NO AIR, magenta LOCKED, purple MANUAL, red LOCKDOWN and gray OFFLINE. The status column lists every door that is not open with the reason the server gives, door states, and a status column on the left with zones, doors, lockdown and alerts. A wider monitor works too: the map stays on the right and the column on the left with space between them. It reads airlocks named `Athena-A` to `Athena8-C`.

## Getting the program into the game

ZelNet installs and updates straight from this repository. The program is `dist/zelnet` (about 220 KB). It stays packed on disk and unpacks itself in memory each time it starts, which leaves room on the computer for an update to be swapped in safely.

### 1. Allow GitHub in ComputerCraft (once per Minecraft server)

ComputerCraft 1.63 only lets computers reach pastebin.com and computercraft.info. In `config/ComputerCraft.cfg` on the Minecraft server, make sure HTTP is on and add GitHub's file host to the whitelist, then restart the server:

```
B:http_enable=true
S:http_whitelist=*pastebin.com;*computercraft.info;*githubusercontent.com
```

### 2. First install on a server computer

CraftOS 1.63 has no `wget`, so the first download uses the Lua prompt. Type `lua`, then this as one line:

```
h=http.get("https://raw.githubusercontent.com/salesmanhappymask/ZelNet/HEAD/dist/zelnet") f=fs.open("zelnet","w") f.write(h.readAll()) f.close() h.close()
```

Type `exit()` to leave the Lua prompt, then run `zelnet`. (Without HTTP you can also copy `dist/zelnet` into `saves/<world>/computer/<id>/zelnet`.)

Only servers need this. Every other computer gets ZelNet from a provisioning pocket computer.

### 3. Updating

Main decides the version for the whole network. Update Main and everything follows: every satellite in every dimension, every router and every client.

* On the Main console open **Update network**, then **Download from the repo**, then **Install and update the network**. Satellites download it over the backbone, install it and reboot by themselves, then pass it to their own routers and clients. Reboot Main once the satellites show the new release.
* `zelnet update` in Main's shell does the same after Main reboots.
* Anything that was switched off, out of range or failed to update is brought up to date as soon as it reports in. Satellites report to Main every few minutes, and devices check with their server every two minutes.
* Satellites follow Main. When Main cannot reach a satellite (a bridge is down, for example), update it by itself: on its console open **Update**, then **Download from the repo**, or run `zelnet update` in its shell. Then reboot it. Update Main to the same build as well, or Main puts its own build back once it reaches the satellite again.

**Releases.** Every build has a release number such as `r28`. It shows on each computer as it starts, in `zelnet version`, and on the console. On Main, **Update network, Network versions** lists every server and device in every realm with its release, marked current, behind or "on reboot" while it waits to restart. The event log notes each update, for example `MARS router outpost updated to r28`.
* Every build carries a build id (for example `1.0.0+29d058ec`) that changes with every change to the code, so any new commit to `dist/zelnet` counts as an update even when the version number stays the same.
* To update from another branch or fork, set `updateUrl` in `/.zelnet/config` or run `zelnet update <url>`.

## First in-game test

1. Main server: place an advanced computer with a wireless modem on top, a Cipher Block next to it (any six item stacks), and a disk drive. Download `zelnet` as above and run `zelnet`. Follow the wizard (Main server, realm `EARTH`).
2. Client: put a pocket computer in the setup drive, unlock the console, and tap Client, Next, Write on the setup monitor. Put the pocket computer in a drive next to a new computer with a wireless modem and reboot that computer. Take it out when the installer finishes.
3. On the client create an account and send yourself a message from a second client.
4. Satellite: on the setup monitor create a Satellite server install on a pocket computer. Install it on a server in the other dimension with its own Cipher Block holding the same six items, then add the bridge on the Bridges page of both servers.

Report anything odd with a screenshot of the screen; the console's Event log page and `/.zelnet/crash.txt` help too.

## Using ZelNet from your own programs

```lua
local zn = dofile("/zelnet")
assert(zn.open())
zn.run(function()
    zn.publish("power.mars", { stored = 12345 }, { retain = true })
end)
```

Ready-made examples are in [`examples/`](examples): `power_publisher.lua` publishes energy cell and solar generator totals from any dimension, and `power_dashboard.lua` shows every dimension's power on one screen. The full API is in [docs/PROTOCOL.md](docs/PROTOCOL.md).

## Keys

Every screen works with the keyboard: arrows, Enter, Tab, Backspace, and a tap of **Ctrl** goes back. Mouse clicks and monitor touches work too on advanced computers.

## Building from source

The program is assembled from the modules in `src/`:

```
lua5.1 tools/check.lua .
lua5.1 tools/build.lua . build/zelnet
lua5.1 tools/dist.lua
```

`tools/dist.lua` minifies and packs `build/zelnet` into `dist/zelnet`. Commit `dist/zelnet` together with the source change; that file is what servers download.

Tests run with `lua5.1 tests/<name>.lua`. `lua5.1 tests/render_displays.lua` followed by `python3 tools/screenshot.py build/screens` renders every display screen to PNG for layout checks. `sim/` contains a ComputerCraft 1.63 world simulator used by the scenario tests. It runs the real CC 1.63 ROM, which is not stored in the repo; extract it from the mod jar once with `tools/extract_rom.sh path/to/ComputerCraft1.63.jar`.

## Documents

* [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): how the network is put together.
* [docs/PROTOCOL.md](docs/PROTOCOL.md): packet formats, reserved ports and the library API.
* [docs/CONTRACTS.md](docs/CONTRACTS.md): module interfaces for contributors.

## Version

ZelNet 1.0.0 (protocol 1). The version shows in every header and in `zelnet version`.
