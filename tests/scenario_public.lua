local S = require("tests.scen")
local need = require("tools.devload").make(".")
local crypto = need("crypto")

local w = S.world()
local earth, mars = S.twoRealms(w, crypto)
w:run(60)

local routerDisk = S.provision(w, earth, "2", "relay1")
local router = S.device(w, { id = 40, dim = "overworld", pos = { 55, 70, 0 } }, routerDisk)

local reactorProgram = [[
rednet.open("top")
local gw = rednet.lookup("zelnet")
local h = fs.open("/gw.txt", "w") h.writeLine(tostring(gw)) h.close()
local heat = 500
parallel.waitForAny(function()
    while true do
        heat = heat + 1
        rednet.send(gw, { op = "publish", topic = "reactor.main", data = { heat = heat, power = 9000 } }, "zelnet")
        sleep(5)
    end
end, function()
    while true do
        local id, msg = rednet.receive("zelnet")
        local f = fs.open("/inbox.txt", "a")
        f.writeLine(textutils.serialize(msg):gsub("%s+", " "))
        f.close()
    end
end)
]]

local monitorProgram = [[
rednet.open("top")
local gw = rednet.lookup("zelnet")
local h = fs.open("/gw.txt", "w") h.writeLine(tostring(gw)) h.close()
rednet.send(gw, { op = "ping" }, "zelnet")
rednet.send(gw, { op = "subscribe", topic = "reactor.*" }, "zelnet")
local sentReply = false
while true do
    local id, msg = rednet.receive("zelnet")
    local f = fs.open("/got.txt", "a")
    f.writeLine(tostring(msg.type) .. " " .. tostring(msg.topic) .. " " .. tostring(msg.from) .. " " .. tostring(type(msg.data) == "table" and msg.data.heat or msg.realm or msg.error))
    f.close()
    if msg.type == "topic" and not sentReply then
        sentReply = true
        rednet.send(gw, { op = "send", to = msg.from, data = "seen your reactor" }, "zelnet")
        rednet.send(gw, { op = "send", to = "NOWHERE:5", data = "x" }, "zelnet")
        rednet.send(gw, { op = "publish", topic = "bad topic!", data = 1 }, "zelnet")
    end
end
]]

local reactor = w:addComputer({ id = 60, dim = "mars", pos = { 10, 70, 0 }, color = true, startup = reactorProgram })
reactor:attach("top", w:wirelessModem())
local monitor = w:addComputer({ id = 61, dim = "overworld", pos = { 100, 70, 0 }, color = true, startup = monitorProgram })
monitor:attach("top", w:wirelessModem())
monitor:boot()
w:run(10)
reactor:boot()
w:run(240)

print("reactor gateway:", reactor:readFile("/gw.txt"))
print("monitor gateway:", monitor:readFile("/gw.txt"))
print("MONITOR GOT:\n" .. tostring(monitor:readFile("/got.txt")))
print("REACTOR INBOX:\n" .. tostring(reactor:readFile("/inbox.txt")))
local got = monitor:readFile("/got.txt") or ""
local inbox = reactor:readFile("/inbox.txt") or ""
print("topic ok:", got:find("topic reactor.main MARS:60", 1, true) ~= nil)
print("pong ok:", got:find("pong nil nil EARTH", 1, true) ~= nil)
print("direct ok:", inbox:find("seen your reactor", 1, true) ~= nil and inbox:find("EARTH:61", 1, true) ~= nil)
print("errors ok:", got:find("bad_topic", 1, true) ~= nil and got:find("no_route", 1, true) ~= nil)
S.errors(earth, "earth")
S.errors(mars, "mars")
S.errors(router, "router")
S.errors(reactor, "reactor")
S.errors(monitor, "monitor")
