# ZelNet module contracts

This file is the binding interface between modules. Read [ARCHITECTURE.md](ARCHITECTURE.md) and [PROTOCOL.md](PROTOCOL.md) first. When a contract here and an existing source file disagree, the source file of an already written module (section 2) wins; tell the integrator.

## 1. Conventions (all modules)

* Lua 5.1 as in ComputerCraft 1.63 (LuaJ). No code comments. No em dashes in code, strings or docs.
* Forbidden: `term.blit`, `os.epoch`, `os.date`, `bit32`, `table.unpack`, `string.format` with `%.Nf`, `goto`, `settings`, `colors.toBlit`, `string.pack`. Use `util.fmtFixed` for decimals. `%d` only with integers.
* Every module file starts with `local need = ...` and returns one table. Dependencies: `local util = need("util")`. Add new modules to `src/MODULES` in dependency order.
* Limits: under 150 top level `local` declarations per file, under 60 upvalues per function. Prefer methods on a table (`function Obj:method()`) and state in `self`.
* Never call `os.pullEvent` with a filter in a coroutine that must also see other events. Long loops call `compat.breathe()` (only in worker style contexts) or `compat.yieldNow()`.
* OpenPeripheral calls (tesseract `pullItem`, `getFrequency`, inventory methods) take a tick and swallow events delivered to the calling coroutine meanwhile. Only make them from a dedicated task (the bridge task) or from the worker.
* Data that crosses modems, BitNet, the Cipher Block or text files must be ASCII. `codec.encode` output is ASCII safe. Never send raw binary strings.
* Use `codec.encode` / `codec.decode` (or `util.readTable` / `util.writeTable`) for persistence, never `textutils.unserialize` on untrusted text.
* Time: `compat.now()` (seconds since boot, use for intervals and timeouts) and `compat.stamp()` (in-game hours since world start, `os.day()*24 + os.time()`, use for user visible timestamps). Never use `os.time()` alone as a timestamp.
* Errors that a user can cause must not crash a task. Handlers are wrapped in `pcall` by the node runtime, but keep internal state consistent.
* Usernames: `^[a-z][a-z0-9_]*$`, 3 to 16 characters, stored lower case, unique across the whole network. Display names keep the case typed at creation.
* UI must work on standard (non advanced) computers: every screen is usable with the keyboard. Universal keys: arrows, Enter, Tab, Backspace, and a tap of Ctrl (`keys.leftCtrl` or `keys.rightCtrl`) means Back. Mouse and monitor touch are extras. A monitor touch only counts for the surface bound to that monitor.

## 2. Already written modules (do not rewrite; read the source)

| Module | Key API |
|---|---|
| `compat` | `band bor bxor bnot rshift lshift rrot bxor8 unpack now stamp breathe(weight) yieldNow isCC` |
| `codec` | `encode(v) -> s or nil, err`, `decode(s) -> v or nil, err` (data only parser, reads textutils output too) |
| `crypto` | `sha256 sha256bin hmac(keyHex,msg) hmacBin mac(keyHex,msg) derive rc4 encrypt(keyHex,nonceHex,plain) toHex fromHex b64encode b64decode adler32 constEq randHex(nBytes) addEntropy sealString openString sealTable openTable serialize unserialize newKey passwordHash(saltHex,pw)` |
| `util` | `clamp fmtFixed fmtTrim fmtBytes fmtAmount fmtDuration fmtStamp trim split startsWith fitText padRight center sanitize wrapText copy deepCopy count sortedKeys contains serialize unserialize readFile writeFile(atomic) readTable writeTable newId newRing newLogger newSeenSet newQueue normRealm normName parseAddress formatAddress normAddress validPort validTopic topicMatches` |
| `version` | `{ program = "1.0.0", protocol = 1, name = "ZelNet" }` |
| `config` | `DIR PATH ROLES isServer(cfg) validate(cfg) applyDefaults(cfg) load(path) save(cfg, path) newServer(opts) newDevice(serverCfg, role, name, serverId) netIdFor(name)` |
| `cipher` | `open({preferred, softwareKey}) -> obj, warning`; `obj.encrypt(text) -> b64 or nil`, `obj.decrypt(b64) -> text or nil`, `obj.kind` is `"hardware"` or `"software"`; `selfTest(obj)`, `fingerprint(obj)`, `findName()` |
| `frame` | `make(netId, kind, from, to, data)`, `valid`, `validAccess`, `validBackbone`, `validBeacon`, `validHello` |
| `seal` | `sealAccess(deviceKey, pkt, dir, dev)`, `openAccess(deviceKey, w)`, `sealBackbone(cipherObj, backboneKey, pkt, via)`, `verifyBackbone`, `openBackbone(cipherObj, backboneKey, w) -> pkt, nonce`, `beaconMac`, `helloMac`, `storeSeal(cipherObj, dataKey, value) -> text`, `storeOpen(cipherObj, dataKey, text) -> value` |
| `links` | `new(opts)`, `:scan() :list() :count() :hasBitnet() :sendOn(link, f) :broadcast(f, exceptLinkId) :sendTo(cid, f) :learn :forget :decode(ev, ...) -> f, linkId, dist :closeAll()`; links have `id` (`"modem:top"`, `"bitnet:bitnet_tower_0"`), `kind`, `wireless`, `open`, `tx`, `rx` |
| `node` | see section 3 |
| `api` | public library (`open run loop send request receive reply listen unlisten publish subscribe unsubscribe register resolve ping address realm isConnected status on version attach node`) |
| `ui` | see section 4 |

## 3. Node runtime (`node`)

`local n = node.new(cfg, { log = logger })`. Fields: `n.cfg n.log n.role n.isServer n.myId n.realm n.name n.address n.links n.counters n.parent n.connected n.serverId`.

Methods:

* `n:start()` scans links (called by `loop` too).
* `n:loop(mainFn, ...)` runs the scheduler (rx, worker, clock, handler tasks, and `mainFn` as the main task). Returns what `mainFn` returns. Errors in rx, worker, clock or main propagate.
* `n:spawn(fn, name, { critical = bool })` adds a coroutine task. Tasks may block with `os.pullEvent`, `sleep`, `n:request`.
* `n:every(seconds, fn, name)` and `n:after(seconds, fn, name)` run `fn(n)` in the **worker**. Timer functions must not block (no `request`, no `sleep`); use `requestAsync`.
* `n:send(dst, port, body, { re, rq, src, ttl }) -> id` queues a packet. Crypto happens in the worker.
* `n:request(dst, port, body, timeout, { retries }) -> body, src | nil, err` blocks the calling task.
* `n:requestAsync(dst, port, body, cb(body, err, src), timeout) -> id` for worker context.
* `n:reply(msg, body)`, `n:listen(port, handler(msg))`, `n:unlisten(port)`, `n:receive(port, timeout) -> msg`.
* `n:subscribe(topic, handler)`, `n:unsubscribe(topic)`, `n:publish(topic, data, { retain })`, `n:register(name)`, `n:resolve(addr)`, `n:ping(dst, timeout)`.
* `n:status()`, `n:on(event, fn)` with events `connected`, `disconnected`, plus any event a role module emits with `n:emit(event, ...)`.
* Server hooks: `n:onFrame(kind, fn(n, frame, linkId, dist))` replaces the default device handling for that frame kind; `n:setRouter(fn(pkt))` receives every packet the server itself sends to a destination that is not the server (logical packet, unsealed); `n:deliver(pkt)` hands a verified logical packet to local ports (dedupes by id, resolves pending requests, handles `zn.ping` and `zn.err`). For servers, `n.address == cfg.realm` and packets to `REALM` or `REALM:<serverId>` are local.
* `n.localSubscribe(topic)` / `n.localUnsubscribe(topic)` are set by the server so that programs on the server computer itself can subscribe.

Logical packet: `{ v, id, src, dst, port, ttl, rq, re, body }`. Messages handed to handlers and inboxes: `{ src, port, data, id, rq }`.

## 4. UI kit (`ui`)

* `ui.palette(isColor)` gives the ZelOS colors: `bg header div inset accent text muted dim brand ok good warn bad orange purple headerText selected field`.
* `ui.surface(target, monitorName)` wraps the terminal (`term`) or a monitor (`peripheral.wrap(name)`, pass the name). Methods: `:resize() :begin() :rect(x,y,w,h,bg) :text(x,y,s,fg,bg) :field(x,y,w,s,fg,bg,align) :setCursor(x,y) :invalidate() :flush(force) :pointer(ev,a,b,c) -> x, y, kind, button`. Fields `w h isColor c`. The surface is a frame buffer: build a whole frame, then `flush()` writes only changed cells.
* `ui.page(surf)` starts a frame and returns a page with `:hotspot(x,y,w,h,action) :hit(x,y) :header(title, left, right) :card(x,y,w,h,title,accent,right) -> ix,iy,iw,ih :container(title, subtitle) -> ix,iy,iw,ih :bar(x,y,w,h,pct,color) :kv(x,y,w,label,value,color) :button(x,y,w,h,label,bg,fg,action) :pill(x,y,label,bg,fg) :tabs(x,y,w,items,activeId,h) :wrapped(x,y,w,maxRows,text,fg,bg) :list(x,y,w,h,rows,offset,selectedIndex,actionPrefix) :inputBox(x,y,w,value,mask,focused)`.
* Modal helpers (each runs its own event loop in the calling task): `ui.form(surf, { title, subtitle, intro, fields = { { label, key, value, mask, required, numeric, maxLen, hint, validate } }, submit, backLabel, error }) -> values | nil`, `ui.ask(surf, title, label, { mask, value, intro, required }) -> string | nil`, `ui.menu(surf, { title, subtitle, items = { { label, hint, color, action } }, draw = fn(page, ix, iy, iw, ih) -> rowsUsed, refresh = fn() -> result|nil, interval, onEvent, onAction, back, footer, footerRight, keepOpen }) -> index, item | nil`, `ui.message(surf, title, lines, { button, color })`, `ui.confirm(surf, title, text, { yes, no, danger }) -> bool`, `ui.busy(surf, title, text)`, `ui.attachMonitor(name, scale)`, `ui.findMonitors()`, `ui.footerButtons(page, x, y, w, left, right)`.
* UI code owners may extend `ui.lua` with new generic widgets (for example a chat view or a scrollable log view) but must not change existing signatures. Keep Ctrl as Back in every new widget.

## 5. Shared context

`main` builds one context table and passes it to server side modules:

```lua
ctx = {
    cfg = cfg,
    log = logger,
    node = n,
    cipher = cipherObj,
    storage = st,
    server = srv,
    tekmail = tm,
    airlock = al,
    version = version,
    emit = function(event, ...) n:emit(event, ...) end,
}
```

Modules are created in this order: storage, server, tekmail, airlock; each `new(ctx)` stores `ctx` and the caller then assigns it into `ctx`. `start()` is called after all are created.

## 6. Storage (`storage`)

```lua
local st = storage.new(ctx)
st:init() -> ok, problems
st:ready() -> bool
st:read(role, rel, default) -> value
st:write(role, rel, value) -> ok, err
st:delete(role, rel) -> ok
st:exists(role, rel) -> bool
st:list(role, relDir) -> { names }
st:info() -> { { role, drive, label, mount, present, free, files } }
st:assign(role, driveName) -> ok, err
st:audit(actor, action, target, detail, ok)
st:auditTail(n) -> { entries newest first }
```

* Roles: `accounts`, `mail`, `chat`, `audit`, `system`. `cfg.storage.drives[role]` names a drive peripheral (for example `drive_10`). A role with no drive uses `/.zelnet/data/<role>` on the computer. A drive must contain a floppy with data; the disk gets the label `ZelNet-<Role>`.
* Every file is sealed with `seal.storeSeal(ctx.cipher, cfg.dataKey, value)` and written atomically with `util.writeFile`. Reads that fail to decrypt return `default` and log an error, and the failed file is renamed to `<name>.bad` so it is never overwritten silently.
* Paths are relative inside the role (`"alice.db"`, `"alice/index.db"`). `rel` must not contain `..`. Directories are created on write.
* Floppy limit is 125000 bytes. `write` returns `nil, "disk full"` when `fs.getFreeSpace` is lower than the new size plus 512.
* `audit` appends to a ring of 300 entries in `audit/log.db` (each `{ s = compat.stamp(), actor, action, target, detail, ok }`) and is cheap enough to call per admin action, not per packet.
* `disk` and `disk_eject` events: `main` forwards them by calling `st:onDiskEvent(ev, side)`, which re-checks assignments. A missing role disk makes `st:ready()` false and writes for that role fail with `"storage offline"`.

## 7. Server networking (`registry`, `server`, `backbone`, `directory`)

One agent owns these four modules. `server` is the facade other modules use.

```lua
local srv = server.new(ctx)
srv:start()
srv:status() -> {
    realm, role, isMain, serverId, uptime,
    devices = { total, online },
    neighbors = { { realm, kind = "radio" or "bridge", id, link, lastSeen, fp, prog } },
    routes = { { realm, via, metric, kind } },
    bridges = { bridgeStatus... },
    queue = { backbone = n, stored = n },
    counters = { ... },
    cipher = { kind, name, fingerprint, ok },
    warnings = { strings },
}
srv:devices() -> { { name, role, cid, status = "pending"|"online"|"offline"|"revoked", lastSeen, prog, hops, parent, created } }
srv:provision(role, name) -> deviceConfigTable | nil, err
srv:revoke(name) -> ok, err
srv:resetBinding(name) -> ok, err
srv:removeDevice(name) -> ok, err
srv:realms() -> { { realm, serverId, main, prog, lastSeen, reachable, metric } }
srv:addBridge(bridgeCfg) -> ok, err
srv:removeBridge(peer) -> ok
srv:bridges() -> { bridge objects }
srv:userHome(username) -> realm | nil
srv:claimUser(username) -> ok, err
srv:releaseUser(username) -> ok, err
srv:renameUser(old, new) -> ok, err
srv:listUsers() -> { { name, realm } }
srv:broadcastRealms(port, body) -> sends a backbone packet with dst "*" (pub/sub style flood)
srv:pushUpdate(programText, versionString) -> ok, err (Main only; see section 12)
srv:on(event, fn) events: device_online(name), device_offline(name), realm_up(realm), realm_down(realm), warning(text)
```

`claimUser`, `releaseUser` and `renameUser` block (they make requests to Main) and must only be called from a task, never from a timer. On Main they act locally.

Responsibilities:

1. **Registry** (`registry` module, used only by `server`): device records in `storage` role `system`, file `devices.db`: `{ [name] = { name, role, key, cid, created, status, lastSeen, prog, hops, parent } }`. Names unique per realm. The server's own realm key and keys never leave the server except on provisioning disks.
2. **Beacons**: every `cfg.beaconInterval` seconds broadcast `k = "b"` on all links with `seq = math.floor((os.day() * 24 + os.time()) * 100)` (monotonic across reboots) and the MAC from `seal.beaconMac`.
3. **Access frames** (`k = "p"`, `dir = "u"`, `t == serverId`): validate, look up the device by `w.dev`, check `status ~= "revoked"`, verify and open with `seal.openAccess`. Bind on first contact (`cid` from `w.src`), reject a src that does not match the bound cid. Record the downstream route `cid -> frame.f` and the neighbor link. Update `lastSeen`. Then route the logical packet (step 6).
4. **Reserved ports on the server** via `n:listen`: `zn.hello` (reply `{ ok = true, realm, server = serverId, prog }`, mark online, store prog/hops), `zn.name` (register, release, resolve; names per realm, owner is the device), `zn.ps` (sub, unsub, pub; see 7), `zn.dir` (directory, see 8), `zn.route` (route adverts), `zn.admin` (Main asks satellites for `srv:status()`).
5. **Backbone**: hello frames `k = "h"` every `cfg.helloInterval` on radio links with `fp = cipher.fingerprint(ctx.cipher)`; neighbors whose `fp` differs get a warning "cipher items differ" and are not used. Distance vector routes over realms (`zn.route` packets sent directly to each neighbor, metric radio 1, bridge 4, infinity 16, split horizon with poisoned reverse, expiry after 3 missed adverts). Backbone packets travel as frames `k = "x"` with `t = neighbor server id` over radio, or through `bridge:enqueue(wire)` for bridge neighbors. Received backbone packets: check `frame.validBackbone`, `seal.verifyBackbone`; if `dst` is for this realm, `seal.openBackbone`, reject replayed nonces (seen set, 30 minutes), then route locally. Otherwise decrement ttl and forward along the route; `dst = "*"` floods to all neighbors except the one it came from, once per id, and is also delivered locally.
6. **Routing a logical packet** (from a device, from the backbone, or from `n:setRouter`): resolve `dst`. Same realm: the server itself (`REALM` or `REALM:<serverId>`) goes to `n:deliver`; a device (by cid or registered name) gets the packet re-sealed with its key (`dir = "d"`, `dev = name`) and sent to the learned next hop (`links:sendTo`), or flooded with `t = nil` if no route is known; an unknown node gets `zn.err` `unknown_node`. Other realm: seal with `seal.sealBackbone` and send toward the next hop; with no route, store the packet in the store and forward queue (in memory, max 200 packets, expire after 1 hour, retried every 10 s) and if it expires send `zn.err` `no_route` back to the source. A packet whose body is too large produces `zn.err` `too_large`.
7. **Pub/sub broker**: topics table `{ [topic] = { subs = { [addr] = expiry }, retained = { data, from, t } } }`. Subscriptions from devices last 10 minutes and are renewed by the device. `pub` from a device or a local program: rate limit 1 per second per (src, topic); deliver locally to matching subscribers as `{ op = "msg", topic, data, from }` on port `zn.ps`; flood to all realms with `dst = "*"`, port `zn.ps`, body `{ op = "fwd", topic, data, from, retain }`. Servers receiving `fwd` deliver to their local subscribers and keep retained values. Subscribers get the retained value immediately on subscribe. Programs on the server computer subscribe through `n.localSubscribe`.
8. **Directory** (`directory` module): Main keeps `system/directory.db` = `{ realms = { [realm] = { serverId, main, prog, lastSeen } }, users = { [name] = realm } }`. Satellites send `zn.dir` `{ op = "register", realm, serverId, prog }` to Main at start and every 5 minutes; Main replies with the full directory and pushes changes (`op = "push"`) to every realm. `op = "claim"` `{ user, realm }` replies `{ ok }` or `{ ok = false, err = "taken" }`; `release`, `rename`, `lookup`, `list`. Satellites cache the last directory in `system/directory.db` so lookups work when Main is unreachable; claims need Main.
9. **Bridges**: for each entry in `cfg.bridges`, create `bridge.new(bcfg, ctx)` and spawn its task with `n:spawn(function() b:run(function(wires) ... end) end, "bridge:" .. peer)`. Each received wire packet is handled like a backbone frame from neighbor realm `peer` (metric 4).
10. **Self protection**: drop packets with a different protocol major version, ttl at or below 0, oversized bodies; rate limit per device (100 packets per 10 seconds) and log abuse once.

## 8. Bridge (`bridge`)

```lua
local b = bridge.new(bcfg, ctx)
b:enqueue(wire) -> ok, err
b:run(onReceive)
b:status() -> { peer, state = "idle"|"sending"|"waiting"|"receiving"|"fault"|"unconfigured", queued, sent, received, trips, lastTrip, errors, lastError, sendDisk = bool, recvDisk = bool }
bridge.findGear() -> { drives = { names }, tesseracts = { names } }
bridge.probe(tessName, driveName, settle) -> direction | nil, err
bridge.check(bcfg) -> ok, problems
```

* `bcfg = { peer = "MARS", sendTess, sendDrive, sendDir, recvTess, recvDrive, recvDir, settle = 0.3, poll = 0.5, maxBatch = 100000 }`.
* Tesseracts are found by methods (`pullItem` plus `getFrequency`), drives by type `drive`. Directions are the lowercase strings `north south east west up down`, measured from the tesseract.
* Protocol (compatible in spirit with TekBridge): each direction has its own floppy. To send, write `zn_bridge.dat` = `codec.encode({ zb = 1, from = realm, to = peer, seq, frames = { wire, ... }, sum = crypto.adler32(codec.encode(frames)) })` on the floppy in the send drive, then `tess.pullItem(sendDir, 1, 1)` moves it through the tesseract pair to the peer's receive drive. Wait until the disk comes back (it reappears in the send drive when the peer returns it) before the next batch. To receive, when a floppy appears in the receive drive with a file addressed `to = realm`, check the sum, hand the frames to `onReceive(frames)`, delete the file, and return the floppy with `recvTess.pullItem(recvDir, 1, 1)`. A floppy in the receive drive with no valid file is returned as well. Batches carry as many queued wire packets as fit in `maxBatch` bytes of encoded text.
* If a pull fails, try the opposite direction, then all six (as TekBridge did), and save a corrected direction with `config.save`.
* The bridge task is the only place that calls OpenPeripheral methods. It sleeps with `sleep(poll)` between polls.

## 9. TekMail (`tekmail`)

```lua
local tm = tekmail.new(ctx)
tm:start()
tm:listUsers() -> { { name, display, realm, admin, created, lastLogin } }
tm:createUser(name, password, { admin = bool, display }) -> ok, err
tm:resetPassword(name, password) -> ok, err
tm:renameUser(old, new) -> ok, err
tm:deleteUser(name) -> ok, err
tm:setAdmin(name, bool) -> ok, err
tm:chatHistory(room, n) -> { messages }
tm:sessions() -> { { user, client, since, lastSeen } }
tm:stats() -> { users, conversations, chatMessages, outbox, sessions }
```

Ports: `tekmail` (clients to their authority server; server to client notifications) and `tekmail.fed` (server to server).

Client request bodies on port `tekmail` (all replies are `{ ok = true, ... }` or `{ ok = false, err = "<code>", msg = "<human text>" }`):

| op | Fields | Reply |
|---|---|---|
| `hello` | | `realm, motd, prog, rooms` |
| `create` | `user, pass` | `user` (also logs in: `token, display, admin, home`) |
| `login` | `user, pass` | `token, user, display, admin, home` |
| `logout` | `token` | |
| `passwd` | `token, old, new` | |
| `whoami` | `token` | `user, display, admin, home` |
| `inbox` | `token` | `convs = { { peer, display, unread, count, lastT, lastFrom, lastText } }` sorted newest first, `unread` total |
| `thread` | `token, peer, since` | `messages = { { id, seq, from, to, text, t, read } }` (all after `since`, max 50 newest), `seq` = last seq; marks them read |
| `send` | `token, to, text` | `queued = bool` (true when the recipient's home realm is unreachable and the message waits in the outbox) |
| `unread` | `token` | `count` |
| `users` | `token` | `users = { { name, display, realm } }` sorted by name |
| `rooms` | `token` | `rooms = { "global", "<REALM>" }` |
| `chat_get` | `token, room, since` | `messages = { { seq, user, realm, text, t } }`, `seq` |
| `chat_post` | `token, room, text` | `seq` |
| `admin` | `token, action, target, value` | depends on action: `list` (users), `reset_pw`, `delete`, `rename`, `set_admin`, `audit` (entries) |

Error codes: `bad_request`, `bad_token`, `denied`, `unknown_user`, `taken`, `bad_name`, `weak_password` (shorter than 4), `too_long` (text over 1000 characters, chat over 200), `offline` (home realm unreachable), `storage`.

Server to client notification on port `tekmail` (no reply): `{ op = "notify", kind = "mail" | "chat", from, room, text }`, sent to every client address with an active session for that user.

Rules:

* Accounts live on their home server (the realm where they were created, which is the authority realm of the client that created them). `create` claims the name with Main first (`srv:claimUser`).
* `login`, and later requests with a token, for a user whose home is another realm are forwarded by the authority server with `tekmail.fed` `{ op = "proxy", req = <client body>, client = <client address>, via = <authority realm> }` and the reply is passed back unchanged. The authority remembers `token -> home realm`.
* Passwords are stored as `{ salt, hash = crypto.passwordHash(salt, pass) }`. Tokens are `crypto.randHex(16)`, expire after 6 hours idle, at most 4 per user.
* Mail: each user's home server stores `mail/<user>/index.db` and `mail/<user>/<peer>.db` (max 200 messages per conversation, oldest dropped). Sending appends to the sender's copy, then delivers to the recipient's home: locally, or `tekmail.fed` `{ op = "deliver", item = { id, from, fromRealm, to, text, t } }` with retries from a persisted outbox (`system/outbox.db`) until `{ ok = true }` comes back. Duplicate ids are ignored. Delivery triggers `notify`.
* Chat: rooms `global` (replicated to every realm with `tekmail.fed` `{ op = "chat", room = "global", msg }` flooded to `dst = "*"`) and the local realm room. Each server keeps the last 200 messages per room in `chat/<room>.db` with its own `seq`.
* Admins: accounts with `admin = true`. A realm admin manages users of their own realm; an admin whose home is the Main realm can manage any realm (the request is proxied to the target's home). The console can do everything locally through the Lua API.
* Every admin action is audited with `ctx.storage:audit`.

## 10. Airlocks (`airlock`)

```lua
local al = airlock.new(ctx)
al:start()
al:list() -> { records }
al:groups() -> { { group, members = { records }, chamberLow, sealed, total } }
al:setManual(id, "seal" | "unseal" | "auto") -> ok, err
al:setLocked(id, bool) -> ok, err
al:rename(id, name) -> ok, err
al:remove(id) -> ok, err
al:poll() -> count
al:stats() -> { nodes, sealed, low, offline }
```

Port the existing rednet `alk_*` protocol and the seal policy from the old server unchanged on the wire (fields `alk_register`, status reports, `alk_ack`, `alk_cmd`, `alk_poll`, `alk_discover`, group suffix `C` is the chamber sensor). Fixes: use `compat.now()` for online and offline timing, persist in storage role `system` file `airlocks.db`, do not audit every depressurized report (only state changes), receive `rednet_message` in its own task with `rednet.open` on every modem side (raw `os.pullEvent` without filter), discovery after start without blocking. Disabled when `cfg.airlocks == false`.

## 11. Provisioning (`provision`)

```lua
provision.drives(exclude) -> { { name, present, label, free, hasData } }
provision.writeDisk(driveName, deviceCfg, { label, programPath }) -> ok, err
provision.installerSource() -> string
provision.programText() -> text of the running program (shell.getRunningProgram, or "/zelnet")
```

The disk gets `zelnet` (program), `zelnet.cfg` (`codec.encode(deviceCfg)`), `startup` (installer) and the label `ZelNet <role> <name>`. The installer copies the program to `/zelnet`, writes `/.zelnet/config` (directory created), writes `/startup` containing `shell.run("/zelnet")` (not for endpoints), deletes `zelnet.cfg` from the disk, sets the computer label to the device name if none is set, prints next steps and reboots (endpoints: prints the library usage instead of rebooting). Exclude drives assigned to storage roles and bridges.

## 12. Network update

Main console: "Update network" reads a program file (default `/zelnet.new`), checks it compiles with `loadstring`, computes `crypto.sha256` and a MAC with the backbone key, and sends it to every realm in 6000 byte chunks on port `zn.update` (`{ op = "offer", version, size, sha, mac, chunks }` then chunks on request). Each server verifies, stores it as `/zelnet.new`, installs it, and offers it to its own devices with a MAC under each device key. Devices verify, replace `/zelnet` atomically, and reboot. Owners: `server` (transfer and verification), `serverui` (the screen), `main` (device side receive using `node`).

## 13. Console (`serverui`), apps (`clientui`, `routerui`), entry (`main`)

* `serverui.run(ctx)`: lock screen (password of a console admin stored as `cfg.console = { salt, hash }` set in setup; optional OpenCCSensors proximity unlock with `cfg.adminPlayer` (one name or a comma separated list; any listed player in range unlocks, the console locks when none is left) and `cfg.adminRange`; auto lock after `cfg.lockAfter` seconds idle, default 300), then the console: Dashboard, Devices (list, provision to disk, revoke, reset binding, remove), Accounts, Chat, Network (realms, routes, neighbors, links, bridges with status), Bridges (add with the setup helper and probe, remove, test), Airlocks (sealing manager like the old server), Storage (drive roles, assign, info), Audit log, Event log, Settings (displays, sensor players, lock timeout, beacon and hello intervals), Update network (Main), Lock, Exit to shell (requires password), Reboot. `serverui.setup()` is the first run wizard (role main or satellite, network name, realm name, console password, admin TekMail account, cipher check with clear guidance if missing or failing, displays, storage drives, bridges) that writes the config. A satellite normally boots from a disk provisioned by Main whose config already holds the network keys; the wizard then asks only for the local parts.
* Displays: `cfg.displays = { activity, console, setup, drive, scale, setupScale }` holds peripheral names. `panels.new(console)` runs one task (`console-displays`) that redraws every second and handles `monitor_touch`. The console monitor is read only. The setup monitor provisions only while the console is unlocked, and shares `console.provBusy` with the terminal so only one install is written at a time. `node:trace(kind, text)` feeds the activity ring (`node.traceRing`); the server traces every routed packet (kinds `in`, `out`, `bb`, `flood`) and every log line is traced with its level.
* Media: pocket computers (about 1 MB) and floppy disks (125 KB) both work as install and storage media. Media with 200 KB or more is shown as a pocket computer. The installer refuses to run from the root of a pocket computer that is switched on by itself.
* `clientui.run(n)`: TekMail client against port `tekmail` of `cfg.realm` (its authority). Screens: welcome (Login, Create account, Network status, Ping server), main menu (Inbox with unread counts, New message, Chatroom with rooms, Directory, Admin tools when admin, Change password, Network status, Log out). Inbox thread view and chat view are bottom anchored, wrap long lines, use incremental fetch with `since`, and refresh on `notify` pushes plus a slow poll (10 s). Optional redstone pulse on new mail via `cfg.mailPulseSide`.
* `routerui.run(n)`: status screen (realm, parent, hops, links, neighbors, forwarded counts, connection state) with a log view and Ping server. Endpoints with no user program run `routerui` in endpoint mode (status plus a hint on how to use the library).
* `main.start(args, env)`: if loaded with `os.loadAPI` (no `shell` in env) export the `api` table into `env`; if `shell` exists and the running program's file name is not `zelnet`, `zelnet.lua` or `startup`, return the `api` table (library via `dofile`). Otherwise run as a program: `zelnet` (default role run), `zelnet setup`, `zelnet status`, `zelnet send <addr> <port> <text>`, `zelnet ping <addr>`, `zelnet version`, `zelnet help`. With no config: servers start the setup wizard; other computers print how to provision. Servers override `os.pullEvent` with `os.pullEventRaw` while running so Ctrl+T cannot reach the shell.

## Updates from the repository

* `updater.fetch(cfg)` downloads `updater.url(cfg)` (default `https://raw.githubusercontent.com/salesmanhappymask/ZelNet/HEAD/dist/zelnet`, overridden by `cfg.updateUrl`) with `http.request`, waits for `http_success` or `http_failure` for that URL with a timeout, and checks that the text compiles and carries a version. It returns `{ text, version, size, current, same }` or nil and a message that names the `http_whitelist` fix.
* `updater.install(text, path)` writes `path .. ".dl"`, verifies it and moves it over `path`. Never keep a second full copy of the program on disk: a computer has 1 MB.
* Versions are `version.full()`, `program .. "+" .. build`. `tools/build.lua` sets `build` to a checksum of all module sources. Update offers carry this string and servers and devices ignore offers equal to their own.
* `dist/zelnet` is a packed stub made by `provision.makeStub`: its first line is `local __mods, ZN = "packed", { program, build, size }`, it unpacks the program in memory and runs it. `provision.expand(text)` returns the full program for any text (packed or not). Provisioning a satellite copies a packed program as is; device builds are made from the expanded text.
