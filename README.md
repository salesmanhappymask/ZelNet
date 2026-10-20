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
* Each tesseract touches one disk drive. Put one floppy in your send drive and one in the peer's send drive to start.
* The console's Bridges page finds the gear and probes the directions for you.

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

## Getting the program into the game

The ready-to-use program is `dist/zelnet` (about 220 KB, packed). The first time it runs it unpacks itself in place into the full program (about 530 KB). Pick whichever way works on your server:

* **Copy the file directly** into the computer's folder in the world save: `saves/<world>/computer/<id>/zelnet` (single player) or `world/computer/<id>/zelnet` (server). Find the computer's id with the `id` command.
* **Pastebin**: paste `dist/zelnet` into a new paste (it fits the 512 KB limit easily) and run `pastebin get <code> zelnet` in game. CC 1.63's default HTTP whitelist only allows pastebin.com.

Only servers need the file this way. Every other computer gets ZelNet from a provisioning disk.

## First in-game test

1. Main server: place an advanced computer with a wireless modem on top, a Cipher Block next to it (any six item stacks), and a disk drive. Put `zelnet` on it and run `zelnet`. Follow the wizard (Main server, realm `EARTH`).
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
```

Tests run with `lua5.1 tests/<name>.lua`. `lua5.1 tests/render_displays.lua` followed by `python3 tools/screenshot.py build/screens` renders every display screen to PNG for layout checks. `sim/` contains a ComputerCraft 1.63 world simulator used by the scenario tests. It runs the real CC 1.63 ROM, which is not stored in the repo; extract it from the mod jar once with `tools/extract_rom.sh path/to/ComputerCraft1.63.jar`.

## Documents

* [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): how the network is put together.
* [docs/PROTOCOL.md](docs/PROTOCOL.md): packet formats, reserved ports and the library API.
* [docs/CONTRACTS.md](docs/CONTRACTS.md): module interfaces for contributors.

## Version

ZelNet 1.0.0 (protocol 1). The version shows in every header and in `zelnet version`.
