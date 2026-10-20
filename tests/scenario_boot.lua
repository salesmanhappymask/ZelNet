package.path = "./?.lua;" .. package.path
local sim = require("sim.ccsim")
local need = require("tools.devload").make(".")
require("tests.shim").install()
local codec = need("codec")
local crypto = need("crypto")

local f = assert(io.open("build/zelnet", "rb")) local program = f:read("*a") f:close()

local ITEMS = { { id = 35, dmg = 1, qty = 3 }, { id = 1, dmg = 0, qty = 7 }, { id = 4, qty = 2 }, false, false, false }

local function serverCfg(realm, role, mainRealm, keys)
    local salt = crypto.randHex(16)
    return {
        zn = 1, role = role, network = "ZelNet", realm = realm, mainRealm = mainRealm,
        backboneKey = keys.backbone, realmKey = crypto.newKey(), dataKey = crypto.newKey(),
        console = { salt = salt, hash = crypto.passwordHash(salt, "secret") },
        bridges = {}, storage = { drives = {} }, monitors = {}, airlocks = false,
    }
end

local world = sim.newWorld({ romPath = "sim/rom", seed = 1 })
local keys = { backbone = crypto.newKey() }
local earthCfg = serverCfg("EARTH", "main", "EARTH", keys)
local earth = world:addComputer({ id = 1, label = "earth", dim = "overworld", pos = { 0, 70, 0 }, color = true,
    files = { ["/zelnet"] = program, ["/.zelnet/config"] = codec.encode(earthCfg) },
    startup = 'shell.run("/zelnet")' })
earth:attach("top", world:wirelessModem())
earth:attach("left", world:cipherBlock({ items = ITEMS }))
earth:boot()
world:run(10)
print("---- EARTH SCREEN ----")
print(earth:screenText())
print("---- ERRORS ----")
for _, e in ipairs(earth:errors()) do print(e) end
print("lastError", earth:lastError())
local keys_ = sim.keys("sim/rom")
earth:typeText("secret")
earth:pressKey(keys_.enter)
world:run(3)
print("---- AFTER UNLOCK ----")
print(earth:screenText())
local drive = world:diskDrive()
earth:attach("bottom", drive)
drive:insert(world:floppy({ label = "blank" }))
world:run(1)
earth:typeText("2")
world:run(2)
print("---- DEVICES ----") print(earth:screenText())
local function shot(t) print("---- " .. t .. " ----") print(earth:screenText()) end
earth:typeText("n") world:run(2) shot("NEW")
earth:typeText("1") world:run(2) shot("CLIENT FORM")
earth:typeText("alpha") earth:pressKey(keys_.enter) world:run(3) shot("AFTER NAME")
earth:pressKey(keys_.enter) world:run(15) shot("WRITTEN")
local fl = drive:disk()
if fl then for k, v in pairs(fl:files()) do print("DISK FILE", k, type(v) == "string" and #v or v) end end
earth:pressKey(keys_.enter) world:run(30) shot("AFTER WRITE")
local fl2 = drive:disk()
if fl2 then for k, v in pairs(fl2:files()) do print("DISK FILE", k, type(v) == "string" and #v or tostring(v)) end end
for _, e in ipairs(earth:errors()) do print("ERR", e) end
earth:pressKey(keys_.enter) world:run(1)
local floppy = drive:remove()
local client = world:addComputer({ id = 10, label = nil, dim = "overworld", pos = { 20, 70, 0 }, color = true })
client:attach("top", world:wirelessModem())
local cdrive = world:diskDrive()
client:attach("bottom", cdrive)
cdrive:insert(floppy)
client:boot()
world:run(40)
print("---- CLIENT ----") print(client:screenText())
for _, e in ipairs(client:errors()) do print("CERR", e) end
print("client files:", client:exists("/zelnet"), client:exists("/.zelnet/config"), client:exists("/startup"))
print("disk cfg left:", floppy:readFile("zelnet.cfg") ~= nil)
world:run(30)
print("---- CLIENT LATER ----") print(client:screenText())
earth:typeText("2") world:run(2) shot("DEVICES AFTER")
local function cshot(t) print("---- " .. t .. " ----") print(client:screenText()) end
client:typeText("2") world:run(2) cshot("CREATE FORM")
client:typeText("bob") client:pressKey(keys_.tab) client:typeText("hunter22") client:pressKey(keys_.tab) client:typeText("hunter22") client:pressKey(keys_.enter)
world:run(15) cshot("AFTER CREATE")
