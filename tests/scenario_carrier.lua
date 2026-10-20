local S = require("tests.scen")
local need = require("tools.devload").make(".")
local crypto = need("crypto")

local w = S.world()
local earth, mars = S.twoRealms(w, crypto)
mars:attach("right", w:bitnetTower({ dim = "mars", pos = { 0, 80, 0 } }))
w:run(60)

local pubDisk = S.provision(w, mars, "3", "powermon")
local subDisk = S.provision(w, earth, "3", "dashboard")
local routerDisk = S.provision(w, earth, "2", "relay1")
local farDisk = S.provision(w, earth, "1", "farclient")
local bnRouterDisk = S.provision(w, mars, "2", "outpost")
local bnClientDisk = S.provision(w, mars, "1", "outpostpc")

local f = io.open("examples/power_publisher.lua") local publisher = f:read("*a") f:close()
publisher = publisher:gsub("local INTERVAL = 10", "local INTERVAL = 5")

local pub = S.device(w, { id = 30, dim = "mars", pos = { 10, 70, 5 } }, pubDisk)
pub:attach("left", w:energyCell({ stored = 400000, max = 1000000 }))
S.shot(pub, "ENDPOINT AFTER INSTALL")
pub:writeFile("/startup", publisher)

local subscriber = [[
local zn = dofile("/zelnet")
assert(zn.open())
zn.subscribe("power.*", function(topic, data, src)
    local h = fs.open("/got.txt", "a")
    h.writeLine(topic .. " " .. tostring(src) .. " " .. tostring(data.cells and data.cells.stored))
    h.close()
end)
zn.run(function()
    print("dashboard " .. zn.address())
    sleep(5)
    local t, err = zn.ping("MARS:powermon", 60)
    local h = fs.open("/ping.txt", "w")
    h.writeLine(tostring(t) .. " " .. tostring(err))
    h.close()
    while true do sleep(60) end
end)
]]
local sub = S.device(w, { id = 31, dim = "overworld", pos = { -10, 70, 5 } }, subDisk)
sub:writeFile("/startup", subscriber)
sub:reboot()
pub:reboot()
w:run(240)
S.shot(pub, "PUBLISHER")
S.shot(sub, "SUBSCRIBER")
print("GOT:\n" .. tostring(sub:readFile("/got.txt")))
print("PING:", tostring(sub:readFile("/ping.txt")))

local router = S.device(w, { id = 40, dim = "overworld", pos = { 55, 70, 0 } }, routerDisk)
local far = S.device(w, { id = 41, dim = "overworld", pos = { 105, 70, 0 }, wait = 80 }, farDisk)
S.shot(router, "ROUTER")
S.shot(far, "FAR CLIENT VIA ROUTER")

local bnRouter = S.device(w, { id = 50, dim = "mars", pos = { 2000, 70, 0 } }, bnRouterDisk)
bnRouter:attach("right", w:bitnetTower({ dim = "mars", pos = { 2000, 80, 0 } }))
bnRouter:reboot()
w:run(30)
local bnClient = S.device(w, { id = 51, dim = "mars", pos = { 2030, 70, 0 }, wait = 80 }, bnClientDisk)
S.shot(bnRouter, "BITNET ROUTER")
S.shot(bnClient, "CLIENT BEHIND BITNET ROUTER")

for _, pair in ipairs({ { earth, "earth" }, { mars, "mars" }, { pub, "pub" }, { sub, "sub" }, { router, "router" }, { far, "far" }, { bnRouter, "bnrouter" }, { bnClient, "bnclient" } }) do
    S.errors(pair[1], pair[2])
end
