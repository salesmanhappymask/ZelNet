# ZelNet Architecture

Status: design draft, version 1 of the protocol.

ZelNet replaces four separate programs (Mars server, Mars client, Mars router, TekBridge interdimensional bridge) with one program, `zelnet`, that runs in one of several roles. It targets Minecraft 1.6.4 with ComputerCraft 1.63, MoarPeripherals 1.5 (BitNet towers), Computronics 0.4.2 (Cipher Block) and OpenPeripheral 0.4.1 (tesseract inventory access).

## 1. Goals

1. One network for any number of dimensions. One server is the **Main** server (root of trust and directory). Every other server is a **Satellite** that serves its own dimension and talks to Main and to other satellites.
2. Every server can provision devices onto a floppy disk: clients, routers, endpoints (third party programs) and, on Main, satellite servers. A provisioned device trusts only the server that provisioned it (its **authority**).
3. Any node can reach any other node in any dimension: client to client, client to a service on another server, or a third party program to another third party program.
4. All traffic that passes through a server, and all traffic between servers, is encrypted with the Computronics Cipher Block and authenticated with an HMAC.
5. Links: wireless and wired modems, MoarPeripherals BitNet towers (long range), and tesseract disk bridges (between dimensions). Each server owns its bridges directly; there is no separate bridge computer.
6. A general carrier protocol and library so any program can send packets, make requests, and publish or subscribe to topics without touching TekMail.

## 2. Vocabulary

| Term | Meaning |
|---|---|
| Network | One ZelNet installation. Identified by a network name and a shared backbone secret. |
| Realm | The part of the network served by one server, usually one dimension. Named in upper case, e.g. `EARTH`, `MARS`. |
| Server | Main or Satellite. Exactly one server per realm. |
| Node | Any ZelNet computer: server, router, client, endpoint. |
| Device | A provisioned node (router, client, endpoint) as recorded by its authority server. |
| Link | A physical path: modem (wireless or wired), BitNet tower, tesseract bridge. |
| Access network | The links inside one realm between the server, its routers and its devices. |
| Backbone | The links between servers (radio links between servers in range, and tesseract bridges). |
| Port | A string naming a service on a node, e.g. `tekmail`, `power`. Ports starting with `zn.` are reserved. |
| Topic | A string naming a publish and subscribe channel, e.g. `power.mars`. |

## 3. Addresses

```
EARTH          the EARTH server
EARTH:17       computer 17 in the EARTH realm
EARTH:powermon the node registered under the name "powermon" in EARTH
```

Rules: realm names match `^[A-Z][A-Z0-9_]*$` and are at most 12 characters. Node parts are a computer ID or a registered name matching `^[a-z][a-z0-9_%-]*$`. The library accepts lower case realm names and upper cases them.

## 4. Roles

All roles run from the same file. The role comes from the config file `/.zelnet/config`, which is written by the setup wizard (servers) or by a provisioning disk (devices).

| Role | Purpose | Started by |
|---|---|---|
| `main` | Root server. Directory of realms and usernames, network admin, provisions satellites. | `/startup` runs `zelnet` |
| `satellite` | Server for one realm. Registers with Main. | `/startup` runs `zelnet` |
| `router` | Relays access traffic inside a realm. Status screen and log. | `/startup` runs `zelnet` |
| `client` | TekMail client (mail, DMs, chatroom, admin tools). | `/startup` runs `zelnet` |
| `endpoint` | No user interface. Other programs load ZelNet as a library. | user programs: `local zn = dofile("/zelnet")` |

## 5. Software structure

Source modules live in `src/` and are bundled by `tools/build.lua` into one file, `build/zelnet`. The bundle can be:

* run as a program: `zelnet` (role from config), `zelnet setup`, `zelnet status`, `zelnet send <addr> <port> <text>`.
* loaded as a library: `local zn = dofile("/zelnet")` returns the public API table.
* loaded with `os.loadAPI("/zelnet")`, which exposes the same API as the global `zelnet`.

Module layout (dependency order, each file returns a table):

| Module | Responsibility |
|---|---|
| `compat` | CC 1.63 shims: bit operations, unpack, time, yielding helpers. |
| `util` | Formatting (`fmtFixed`), text wrapping, table helpers, ids, logging ring buffer, safe file read/write of serialized tables. |
| `crypto` | SHA-256, HMAC-SHA-256, RC4-drop-768 keystream, `seal`/`open` of tables, random hex, constant time compare. |
| `cipher` | Computronics Cipher Block wrapper with self test and software fallback. |
| `config` | Load, validate and save `/.zelnet/config`; defaults; role checks. |
| `frame` | Link frame encode/decode and validation. |
| `links` | Link drivers: `modem` (raw channel), `bitnet` (tower), uniform `send`/`broadcast` and an event normalizer. |
| `bridge` | Tesseract disk bridge driver (batching, disk return protocol, direction probe, setup helpers). |
| `access` | Access network: beacons, parent selection, upstream forwarding, learned downstream routes, flooding fallback. |
| `backbone` | Server to server: neighbor discovery, distance vector routing, cipher sealing, store and forward queue. |
| `node` | Runtime core used by every role: event loop (rx coroutine plus worker), packet dispatch to ports, request/response with timeouts, pub/sub client, name registration. |
| `api` | Public library API (`zn.*`). |
| `registry` | Server side device registry (provisioned devices, keys, bindings, last seen). |
| `server` | Server role: realm services, directory sync with Main, broker for pub/sub, name service, forwarding between access and backbone. |
| `tekmail` | TekMail service: accounts, mail, DMs, chatroom, admin operations, federation across realms. |
| `storage` | Drive roles, encrypted table storage on disks, data key handling. |
| `airlock` | Airlock controller support (legacy rednet protocol). |
| `provision` | Writes provisioning disks (program, config, installer). |
| `ui` | ZelOS UI kit for terminals and monitors (frame buffer, header, cards, buttons, forms, lists, input). |
| `serverui` | Server admin console, setup wizard, lock screen. |
| `panels` | Server display wall: activity monitor (live traffic trace, packets per second, processes), touch console tabs, and the touch setup monitor that provisions onto the pocket computer in the setup drive. |
| `clientui` | TekMail client screens. |
| `routerui` | Router status screen. |
| `main` | Entry point: argument parsing, role dispatch, library export. |

House rules for every module: no code comments, no em dashes, Lua 5.1 only, nothing from section 12 of this document, every function under 60 upvalues, every chunk under 150 top level locals, and any loop that can run long yields through `compat.breathe()`.

## 6. Layers

```
  application   TekMail, third party programs (ports, topics, requests)
  node          dispatch, request/response, pub/sub, names
  network       access routing (inside a realm) | backbone routing (between realms)
  security      access sealing (software, per device key) | backbone sealing (Cipher Block)
  link          modem channel | BitNet tower | tesseract bridge
```

### 6.1 Link layer

All radio traffic uses one raw modem channel, `4747` by default (`config.channel`). ZelNet does not use rednet for its own traffic, so it never floods legacy rednet programs and is not affected by the rednet repeat channel. Legacy rednet is still opened on servers for the airlock protocol.

A frame is a Lua table:

```lua
{ zn = 1, net = "<network id>", k = "<kind>", f = <sender computer id>, t = <receiver computer id or nil>, d = <data> }
```

Kinds: `b` beacon, `p` access packet, `x` backbone packet, `h` backbone hello. Receivers drop frames whose `net` differs, whose `t` is set and is not their own ID, or that fail validation. BitNet towers broadcast to every tower in range, so `t` does the addressing. Frames over modems use `transmit(channel, channel, frame)`.

The receive coroutine only validates the outer shape and queues frames. All cryptography runs in the worker coroutine, so no modem, BitNet or UI event is ever lost to a filtered `os.pullEvent`.

### 6.2 Access network (inside a realm)

* The server broadcasts a **beacon** every 10 s on every radio link: `{realm, root = serverId, seq, hops = 0, ver, mac}`. The MAC is `HMAC(realmKey, realm .. "|" .. root .. "|" .. seq)`. `realmKey` is given to every device provisioned in that realm.
* Routers accept a beacon if the MAC is valid and the sequence number is new or the hop count is better. A router's **parent** is the neighbor with the lowest hop count in the newest sequence. The router rebroadcasts each new sequence once, with `hops + 1`.
* Devices pick the best beacon source (server or router) as their parent. A device that hears no beacon for 35 s searches again.
* Upstream: a node sends its packet in a frame addressed to its parent. Each router forwards upstream to its own parent and remembers `downRoute[src] = frame.f` for 10 minutes.
* Downstream: the server sends the frame to the neighbor it learned for the destination. Routers use `downRoute`. If a router has no route it floods the packet once downward (`t = nil`, deduplicated by packet id, TTL limited).
* All access packets go through the server, including packets between two devices in the same realm. The server checks the sender and re-seals for the receiver.

### 6.3 Backbone (between servers)

* Radio: servers in radio or BitNet range send `h` hello frames every 20 s. A hello carries `{realm, id, main = bool, ver, mac}` with `HMAC(backboneKey, ...)`.
* Bridges: each configured bridge names its peer realm. Bridge frames are batched onto one disk trip.
* Routing: distance vector over realm names. Every 30 s, and on change, each server sends its table `{realm = metric}` to each neighbor. Link metric: radio 1, bridge 4. Infinity is 16. Split horizon with poisoned reverse. Routes expire after 3 missed updates.
* Main holds the **directory**: the list of realms (with versions and last seen times) and the username registry. Satellites register with Main at startup and every 5 minutes. Main pushes directory changes to all servers.
* Store and forward: a server queues backbone packets for a realm with no route for up to 1 hour and retries when a route appears. TekMail deliveries are persisted to disk so they survive reboots.

### 6.4 Security

**Backbone sealing (Cipher Block).** Every server has a Computronics Cipher Block with the same six item stacks, so all servers share the AES key. The block's IV is fixed, so ZelNet prefixes every plaintext with a random 16 byte nonce and a timestamp, so identical messages encrypt differently. The sealed backbone packet is:

```lua
{ id, src, dst, port, ttl, ct = cipher.encrypt(serialize({ n = nonce, t = time, b = body })), mac = HMAC(backboneKey, id .. "|" .. src .. "|" .. dst .. "|" .. port .. "|" .. ct) }
```

Intermediate servers forward the packet without decrypting it. Receivers check the MAC first, then decrypt, then reject nonces seen in the last 30 minutes. If a server has no Cipher Block it refuses to join the backbone unless `config.allowSoftwareBackbone` is true, in which case it uses the software cipher with the backbone key and shows a warning.

**Access sealing (software).** Devices have no Cipher Block. Each device gets a random 32 byte device key at provisioning. Packets between a device and its authority server are sealed with RC4-drop-768 keyed by `SHA256(deviceKey .. nonce)` and authenticated with `HMAC(deviceKey, header .. ciphertext)`. Routers can read the routing header but not the body. Servers re-seal when they forward: access to backbone (device key to Cipher Block), backbone to access (Cipher Block to device key), and access to access.

**Keys.**

| Key | Who has it | Source |
|---|---|---|
| Cipher Block items | every server | placed by hand, identical in every server |
| `backboneKey` | every server | Main generates it at setup; satellite disks carry it |
| `realmKey` | the realm server and its devices | the server generates it at setup |
| `deviceKey` | one device and its authority server | generated at provisioning |
| `dataKey` | one server | at rest encryption of storage (see `storage`) |

Provisioning disks contain keys. The installer deletes the disk's copy of the config after installing, and the server marks the device as installed when it first hears from it. A device key can be revoked from the server console.

### 6.5 Node runtime and the general carrier

Every role runs `node.run(handlers)`, which runs these coroutines in parallel:

1. `rx`: pulls `modem_message` and `bitnet_message` events, validates the frame shape, queues it.
2. `worker`: processes queued frames (routing, verification, decryption, dispatch) and timers (beacons, hellos, route adverts, retries).
3. role tasks: UI, bridge loops, storage, airlocks.

Packets delivered to a port are passed to the port's handler or placed in the port's inbox, which `zn.receive` reads. The full packet format, the reserved ports and the library API are specified in [PROTOCOL.md](PROTOCOL.md).

## 7. Provisioning

The server console has a **Devices** page. Provisioning a device:

1. Choose a role (Client, Router, Endpoint, and on Main also Satellite Server), a name, and an empty drive.
2. The server generates a device key (and for satellites the realm name and backbone key), records the device, and writes to the floppy:
   * `zelnet` (a copy of the running program),
   * `zelnet.cfg` (the device config),
   * `startup` (the installer).
3. Put the disk in the new computer's drive and reboot it. The installer copies the program to `/zelnet`, writes `/.zelnet/config`, writes `/startup`, deletes `zelnet.cfg` from the disk, labels the computer and reboots.
4. The device introduces itself to its authority server, which binds the device name to the computer ID.

## 8. Interdimensional bridge

The bridge driver is built into the server. It uses the method proven by TekBridge: one send tesseract with a drive, one receive tesseract with a drive, a floppy that travels through the tesseract pair, and a disk return step. Changes from TekBridge:

* Batching: one disk trip carries every queued backbone frame up to 100 KB, instead of one chunk per trip.
* Frames are already sealed by the backbone layer, so the disk never holds plaintext.
* Several bridges per server, each with its own peer realm.
* Setup is part of the server setup wizard, including the automatic direction probe.

## 9. Compatibility

* Airlock controllers keep using the existing rednet `alk_*` protocol with the server. That traffic is not encrypted, as before.
* Old TekMail clients, routers and bridges are not compatible and should be replaced by provisioned ZelNet devices.

## 10. Versioning

`src/version.lua` holds the program version (semantic versioning) and the protocol version. Beacons and hellos carry both. Nodes show a warning if a peer's protocol version differs, and refuse traffic if the major protocol version differs.

## 11. Testing

`sim/` contains a CC 1.63 world simulator that runs the real CC 1.63 ROM. `tests/` contains unit tests for pure modules (run with `lua5.1`) and scenario tests that build worlds with several dimensions, servers, routers, clients, BitNet towers and tesseract bridges.

## 12. Forbidden in source (checked by `tools/check.lua`)

`term.blit`, `os.epoch`, `bit32`, `table.unpack`, `string.format` with `%.Nf`, `goto`, `settings`, `colors.toBlit`, `os.date`, `string.pack`, code comments, em dashes.
