# ZelNet Protocol, version 1

This document specifies the packets, ports and library API of ZelNet. Programs that only want to send data across the network need sections 1 to 3. Sections 4 onwards describe the wire format for implementers.

## 1. Quick start for program authors

1. Ask a server admin to provision an **Endpoint** disk for your computer (server console, Devices, New device, Endpoint). Put the disk in the computer and reboot. The installer puts `/zelnet` and its config on the computer.
2. Load the library and run your program inside it:

```lua
local zn = dofile("/zelnet")
assert(zn.open())

zn.run(function()
    while true do
        local cell = peripheral.wrap("cofh_thermalexpansion_energycell_0")
        zn.publish("power.mars", { stored = cell.getEnergyStored("unknown") }, { retain = true })
        sleep(10)
    end
end)
```

3. Somewhere else in the network, in any dimension:

```lua
local zn = dofile("/zelnet")
assert(zn.open())

zn.subscribe("power.mars", function(topic, data, src)
    print(src .. " stored " .. tostring(data.stored))
end)

zn.run(function()
    while true do sleep(60) end
end)
```

`os.loadAPI("/zelnet")` also works and exposes the same functions as the global table `zelnet`.

## 2. Addresses, ports and topics

| Form | Meaning |
|---|---|
| `MARS` | The MARS server. |
| `MARS:42` | Computer 42 in the MARS realm. |
| `MARS:powermon` | The node that registered the name `powermon` in MARS. |

* Realm: `^[A-Z][A-Z0-9_]*$`, at most 12 characters. The library upper cases realm names you pass.
* Node name: `^[a-z][a-z0-9_%-]*$`, at most 16 characters, unique inside its realm.
* Port: any string of 1 to 24 printable characters. Ports starting with `zn.` are reserved for ZelNet. `tekmail` and `tekmail.fed` are used by TekMail.
* Topic: 1 to 48 characters of `[%w%._%-]`. A subscription ending in `.*` matches every topic with that prefix (for example `power.*`).

## 3. Library API

All functions are on the table returned by `dofile("/zelnet")`.

### Lifecycle

| Function | Returns | Notes |
|---|---|---|
| `zn.open([opts])` | `true` or `nil, err` | Loads `/.zelnet/config`, opens modems and BitNet towers. `opts.config` overrides the config path. |
| `zn.run(fn, ...)` | results of `fn` | Runs the network loop and `fn(...)` together. Returns when `fn` returns. Errors in `fn` are raised. |
| `zn.loop()` | never returns | The network loop on its own, for `parallel.waitForAny(zn.loop, myMain)`. |
| `zn.close()` | | Stops sending, closes channels. |

Blocking functions (`request`, `receive`, `register`, `ping`) must be called from code running under `zn.run` or alongside `zn.loop`.

### Sending and receiving

| Function | Returns | Notes |
|---|---|---|
| `zn.send(dst, port, data)` | packet id, or `nil, err` | Fire and forget. `data` is any value `textutils.serialize` accepts. |
| `zn.request(dst, port, data[, timeout])` | `data, src` or `nil, err` | Waits for a reply. Default timeout 10 s inside a realm, 40 s to another realm. `err` is `"timeout"`, `"no_route"`, `"unknown_node"`, `"denied"`, `"too_large"` or `"remote: <text>"`. |
| `zn.receive(port[, timeout])` | `msg` or `nil` | Next packet for `port`. `msg = { src, port, data, id, rq }`. |
| `zn.reply(msg, data)` | packet id | Answers a request (`msg.rq` is true). |
| `zn.listen(port, handler)` | | `handler(msg)` runs in its own coroutine for each packet, so it may call blocking functions. Replaces any inbox for that port. |
| `zn.unlisten(port)` | | |

### Publish and subscribe

| Function | Returns | Notes |
|---|---|---|
| `zn.publish(topic, data[, opts])` | `true` or `nil, err` | Delivered to every subscriber in every realm. `opts.retain = true` keeps the last value at each server for new subscribers. At most one publish per topic per second per node; extra publishes are dropped. |
| `zn.subscribe(topic[, handler])` | `true` | `handler(topic, data, src)` runs in its own coroutine. Without a handler, messages go to the inbox of port `zn.ps` and come out of `zn.receive("zn.ps")` with `msg.data = { topic, data }`. Subscriptions are renewed automatically. |
| `zn.unsubscribe(topic)` | | |

### Names and diagnostics

| Function | Returns | Notes |
|---|---|---|
| `zn.address()` | `"MARS:42"` | |
| `zn.realm()` | `"MARS"` | |
| `zn.register(name)` | `true` or `nil, err` | Claims `MARS:<name>` for this computer. |
| `zn.resolve(addr)` | full address or `nil, err` | Asks the server to resolve a name. |
| `zn.ping(dst[, timeout])` | seconds or `nil, err` | Round trip time. |
| `zn.isConnected()` | boolean | True when the node has a parent and its authority server has answered its hello. |
| `zn.status()` | table | `{ address, role, realm, parent, hops, connected, links = {...}, counters = {...} }` |
| `zn.version()` | `"1.0.0", 1` | Program version and protocol version. |

## 4. Link frames

Every radio frame is a table sent with `modem.transmit(channel, channel, frame)` on channel `4747` (configurable) or `tower.transmit(frame)` on a BitNet tower.

| Field | Type | Meaning |
|---|---|---|
| `zn` | number | Always `1`. |
| `net` | string | Network id (first 8 hex characters of `SHA256(networkName)`). |
| `k` | string | `b` beacon, `p` access packet, `x` backbone packet, `h` backbone hello. |
| `f` | number | Sender computer id. |
| `t` | number or nil | Receiver computer id. `nil` means every node in range. |
| `d` | table | Payload for the kind. |

A node drops a frame if any field has the wrong type, if `net` is not its network, or if `t` is set and is not its own id.

## 5. Beacons (`k = "b"`)

```lua
d = { realm = "MARS", root = 12, seq = 381, hops = 0, ver = 1, mac = "<hex>" }
```

`mac = HMAC(HMAC(realmKey, "zn-mac"), "b|" .. realm .. "|" .. root .. "|" .. seq)`. Hop count is not covered by the MAC because routers change it. The server sends one beacon every 10 s. Routers forward each new `seq` once with `hops + 1`.

Parent selection: newest `seq` first, then lowest `hops`, then the strongest link (BitNet beats modem only if no modem neighbor offers the same hop count), then the lowest sender id.

## 6. Access packets (`k = "p"`)

Logical packet:

```lua
{ v = 1, id = "<16 hex>", src = "MARS:42", dst = "EARTH:7", port = "power", ttl = 24, re = nil, rq = nil, body = <value> }
```

Sealed form on the wire, `d` of the frame:

```lua
{ v = 1, id = "...", src = "...", dst = "...", port = "...", ttl = 24, dir = "u", dev = "powermon", re = nil, rq = nil, n = "<32 hex nonce>", ct = "<base64>", mac = "<64 hex>" }
```

* `dir` is `u` (towards the server) or `d` (away from the server).
* `dev` is the device name, which tells the server which device key to use. On downward packets it names the receiving device.
* Keys are separated per purpose: `encKey = HMAC(deviceKey, "zn-enc")` and `macKey = HMAC(deviceKey, "zn-mac")` (hex keys, HMAC-SHA-256).
* `ct = base64(RC4drop768(SHA256(encKey .. n), codec(body)))`, where `n` is a random 16 byte nonce in hex and `codec` is ZelNet's ASCII safe serializer.
* `aad = table.concat({ v, id, src, dst, port, dir, dev, re or "", rq and "1" or "" }, "|")` and `mac = HMAC(macKey, aad .. "|" .. n .. "|" .. ct)`.
* Body size limit after serialization: 8192 bytes.
* Routers decrement `ttl` and drop the packet at 0. They never change any other field.

The server accepts an upward packet only if the MAC verifies with the key of the device named in `dev`, and `src` equals `<realm>:<computer id bound to that device>`. The first valid packet from a device binds the device name to the sender's computer id. An admin can reset the binding.

## 7. Backbone packets (`k = "x"`, and bridge disks)

```lua
{ v = 1, id = "...", src = "MARS:42", dst = "EARTH:7", port = "power", ttl = 24, re = nil, rq = nil, via = "MARS", ct = "<cipher block base64>", mac = "<64 hex>" }
```

* `ct = cipher.encrypt(codec({ n = <32 hex nonce>, t = <sender clock>, b = body }))` using the Computronics Cipher Block (AES-128-CBC, Base64 output).
* `mac = HMAC(HMAC(backboneKey, "zn-mac"), table.concat({ v, id, src, dst, port, re or "", rq and "1" or "" }, "|") .. "|" .. ct)`.
* Body size limit: 32768 bytes.
* `via` is the realm that last forwarded the packet. It is not covered by the MAC and only feeds split horizon and diagnostics.
* A server forwards a backbone packet for another realm without decrypting it. The final server checks the MAC, decrypts, rejects a nonce it saw in the last 30 minutes, and delivers.
* `dst = "*"` floods the packet to every realm (used for pub/sub). Each server forwards a flooded id once.

Hello frames (`k = "h"`):

```lua
d = { realm = "MARS", id = 12, main = false, ver = 1, prog = "1.0.0", seq = 77, fp = "<cipher fingerprint>", mac = HMAC(HMAC(backboneKey, "zn-mac"), "h|" .. realm .. "|" .. id .. "|" .. seq .. "|" .. fp) }
```

## 8. Reserved ports

| Port | Direction | Request body | Reply body |
|---|---|---|---|
| `zn.hello` | device to server | `{ name, role, prog, cid }` | `{ ok = true, realm, server, prog, time }` |
| `zn.ping` | any | `{ t = clock }` | `{ t = <same> }` |
| `zn.err` | server to source | | `{ code = "no_route" / "unknown_node" / "denied" / "too_large" / "ttl", msg, ref = <packet id> }` sent with `re = <packet id>` |
| `zn.name` | device to server | `{ op = "register" / "release" / "resolve", name }` | `{ ok, addr, err }` |
| `zn.ps` | device to server, server to device | `{ op = "sub" / "unsub" / "pub", topic, data, retain }` | `{ ok }` for sub and unsub; deliveries are `{ op = "msg", topic, data, from }` |
| `zn.route` | server to server | `{ seq, routes = { [realm] = metric } }` | none |
| `zn.dir` | server to server | `{ op = "register" / "push" / "claim" / "release" / "lookup", ... }` | depends on op |
| `zn.admin` | Main to satellites | `{ op = "status" / "provision_log" }` | status tables |

## 9. Delivery semantics

* Packets are delivered at most once per id. There are no retransmissions below the library; `zn.request` retries once by default on timeout inside a realm.
* Across realms, servers store packets for an unreachable realm for up to 1 hour, then send `zn.err` with `no_route` to the source.
* Order is not guaranteed.
* Requests: the replying node sends a packet to the request's `src` with `re = <request id>` and the same port.

## 10. Versioning

The protocol major version is `v` in every packet. Nodes drop packets with a different major version and log it. The program version (`prog`) travels in hellos and beacons so servers can show which versions are deployed.
