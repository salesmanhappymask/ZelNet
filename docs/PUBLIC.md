# Public gateway: ZelNet for plain rednet

Any computer can use the ZelNet network with ordinary rednet. Nothing has to be installed. Every ZelNet server and router is a gateway; a computer only needs a wireless modem and to be within rednet range (64 blocks) of one.

## Find a gateway

```lua
rednet.open("top")
local gw = rednet.lookup("zelnet")
```

`rednet.lookup` takes about two seconds and returns the ID of a gateway in range, or `nil` when there is none. Every message below is sent to that ID with the protocol `"zelnet"`, and every answer comes back with the protocol `"zelnet"`.

## Addresses

A computer's address is its realm and its computer ID: `EARTH:42` is computer 42 in the realm EARTH. The gateway tells you your own address in its `hello` answer.

## What you can send

| Message | What it does | Answer |
|---|---|---|
| `{ op = "hello" }` | Introduces this computer to the gateway | `{ type = "hello", realm, address, gateway, connected }` |
| `{ op = "ping" }` | Checks that the gateway is there | `{ type = "pong", realm, address, gateway, connected }` |
| `{ op = "send", to = "MARS:60", data = ... }` | Sends `data` to one computer anywhere on the network | none, unless it fails |
| `{ op = "publish", topic = "reactor.main", data = ... }` | Sends `data` to everyone watching the topic, in every realm | none, unless it fails |
| `{ op = "subscribe", topic = "reactor.*" }` | Watches a topic. `reactor.*` matches everything that starts with `reactor.` | `{ type = "subscribed", topic }` |
| `{ op = "unsubscribe", topic = "reactor.*" }` | Stops watching | none |

`data` can be text, a number, a boolean, or a table of those, up to 4096 bytes once serialized.

## What you receive

| Message | When |
|---|---|
| `{ type = "message", from = "EARTH:17", data = ... }` | Someone sent this computer a message |
| `{ type = "topic", topic = "reactor.main", from = "MARS:60", data = ..., retained = true? }` | A topic this computer watches got a new value. Right after subscribing, the latest value of each matching topic arrives with `retained = true` |
| `{ type = "error", op, error, message }` | Something was refused. `error` is one of `bad_request`, `bad_address`, `bad_topic`, `bad_data`, `too_large`, `rate_limited`, `no_route`, `off` |

## Example: watch a reactor from another dimension

On the reactor's computer, in any realm:

```lua
rednet.open("top")
local gw = rednet.lookup("zelnet")
local reactor = peripheral.wrap("back")
while true do
  rednet.send(gw, { op = "publish", topic = "reactor.main", data = {
    heat = reactor.getHeat(), power = reactor.getEnergyProducedLastTick(),
  } }, "zelnet")
  sleep(10)
end
```

On the monitoring computer, in any other realm:

```lua
rednet.open("top")
local gw = rednet.lookup("zelnet")
rednet.send(gw, { op = "subscribe", topic = "reactor.main" }, "zelnet")
while true do
  local id, msg = rednet.receive("zelnet")
  if msg.type == "topic" then
    print(msg.topic, "heat", msg.data.heat, "power", msg.data.power)
  end
end
```

Ready to copy versions are in `examples/public_publisher.lua` and `examples/public_monitor.lua`.

## Good to know

* **Topics are the easy way to share readings.** The publisher does not need to know who is watching, any number of computers can watch, and new watchers get the latest value at once.
* **Receiving direct messages:** a computer that only receives `send` messages should send `{ op = "hello" }` when it starts, and again every hour, so its realm knows which gateway can reach it. Sending anything else counts too.
* **Subscriptions last a day.** Subscribe again when your program starts; doing it more often is harmless.
* **Limits:** each computer may send 10 messages every 10 seconds, and the same topic can be published about once a second.
* **Rednet is not private.** Anyone in range can listen to rednet, and the sender ID can be faked. ZelNet keeps the traffic between dimensions encrypted, but the hop between your computer and the gateway is plain rednet. Do not send passwords this way; encrypt the data yourself or use the ZelNet library instead.
* **Talking to ZelNet programs:** a program that uses the ZelNet library receives public messages on port `pub`, and can watch public topics as `pub.reactor.main`. It can also send to a plain computer with `zn.send("MARS:60", "pub", data)`.
* **Admins** can switch the gateway off or block computer IDs under Settings, Public gateway on the server console.
