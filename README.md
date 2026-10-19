# ZelNet

ZelNet is one ComputerCraft program that runs a whole multi-dimension network: servers, routers, TekMail clients, and a general packet carrier that any program can use. It replaces the separate TekMail server, client, router and TekBridge programs.

Built for Minecraft 1.6.4 with ComputerCraft 1.63, MoarPeripherals 1.5, Computronics 0.4.2, OpenPeripheral Core 0.4.1 and Thermal Expansion tesseracts.

## What you get

* **One Main server** that holds the network directory and the username registry, and as many **Satellite servers** as you have dimensions. Every server serves its own dimension and talks to the others.
* **Provisioning disks.** Any server writes a ready-to-boot floppy for a client, router, endpoint, or (from Main) a satellite server. A device trusts only the server that made its disk.
* **Encryption everywhere.** Traffic between servers is encrypted with the Computronics Cipher Block and authenticated with an HMAC. Traffic between a device and its server uses a per-device key from its disk. Data on server disks is encrypted too.
* **Links that fit your build.** Wireless and wired modems for short range, BitNet towers (3000 blocks) and mini antennas (650 blocks) for long range, and tesseract disk bridges between dimensions, built into each server.
* **TekMail** with private messages across dimensions, a global chatroom and a local one per dimension, an account directory and admin tools.
* **A carrier for any program**: send packets, make requests, and publish or subscribe to topics across every dimension. See [docs/PROTOCOL.md](docs/PROTOCOL.md).

## Hardware

| Computer | Needs |
|---|---|
| Main server | Advanced computer, wireless modem (or BitNet tower), Cipher Block on the wired network, a disk drive for provisioning, optional data drives, optional monitors, optional OpenCCSensors proximity sensor |
| Satellite server | Same as Main, plus a tesseract bridge towards a server in another dimension |
| Router | Computer with a wireless modem, or a BitNet tower or mini antenna |
| Client | Computer (standard or advanced) with a wireless modem |
| Endpoint | Any computer with a modem that runs your own program |

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

1. On the Main console open **Devices**, choose **New device**, pick **Satellite server**, enter the realm name (for example `MARS`) and pick the drive with an empty floppy.
2. Carry the floppy to the new dimension, put it in the new server's drive and reboot. The installer copies the program and the network keys.
3. Run through the short local setup (console password, drives, monitors) and set up the bridge on the **Bridges** page on both sides.

### 3. Routers, clients and endpoints

On any server's console: **Devices**, **New device**, pick the role, a name and an empty floppy. Put the disk in the new computer and reboot. The device finds the network by itself and connects to the server that made its disk.

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

Tests run with `lua5.1 tests/<name>.lua`. `sim/` contains a ComputerCraft 1.63 world simulator used by the scenario tests. It runs the real CC 1.63 ROM, which is not stored in the repo; extract it from the mod jar once with `tools/extract_rom.sh path/to/ComputerCraft1.63.jar`.

## Documents

* [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): how the network is put together.
* [docs/PROTOCOL.md](docs/PROTOCOL.md): packet formats, reserved ports and the library API.
* [docs/CONTRACTS.md](docs/CONTRACTS.md): module interfaces for contributors.

## Version

ZelNet 1.0.0 (protocol 1). The version shows in every header and in `zelnet version`.
