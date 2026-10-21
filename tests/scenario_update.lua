local S = require("tests.scen")
local sim = require("sim.ccsim")
local need = require("tools.devload").make(".")
local crypto = need("crypto")

local URL = "https://raw.githubusercontent.com/salesmanhappymask/ZelNet/HEAD/dist/zelnet"
local prov = need("provision")
assert(prov.isPacked(S.program), "run with ZN_PROGRAM=dist/zelnet")
local full = prov.expand(S.program)
local newBuild = prov.makeStub((full:gsub('build%s*=%s*"(%w+)"', 'build = "0badc0de"', 1)))
assert(newBuild ~= S.program and loadstring(newBuild))

local http = { whitelist = "*pastebin.com;*computercraft.info", files = { [URL] = newBuild }, delay = 20 }
local origNew = sim.newWorld
sim.newWorld = function(opts)
    opts.http = http
    return origNew(opts)
end
local w = S.world()
sim.newWorld = origNew

local earth, mars = S.twoRealms(w, crypto)
w:run(60)

local function updateMenu(c, downs)
    for _ = 1, downs do c:pressKey(S.keys.down) end
    c:pressKey(S.keys.enter)
    w:run(2)
end

updateMenu(earth, 11)
S.shot(earth, "UPDATE MENU")
earth:pressKey(S.keys.down)
earth:pressKey(S.keys.enter)
w:run(5)
S.shot(earth, "BLOCKED BY WHITELIST")
earth:pressKey(S.keys.enter)
w:run(1)

http.whitelist = "*pastebin.com;*computercraft.info;*githubusercontent.com"
earth:pressKey(S.keys.down)
earth:pressKey(S.keys.enter)
w:run(10)
S.shot(earth, "DOWNLOADED")
earth:pressKey(S.keys.enter)
w:run(5)
S.shot(earth, "OFFERED")
print("earth program updated:", earth:readFile("/zelnet") == newBuild)
earth:pressKey(S.keys.enter)
w:run(400)
print("mars program updated:", mars:readFile("/zelnet") == newBuild)
w:run(120)
S.shot(mars, "MARS AFTER UPDATE")
S.unlock(w, mars)
mars:typeText("5")
w:run(2)
mars:typeText("1")
w:run(3)
S.shot(mars, "MARS REALMS")

local box = w:addComputer({ id = 9, dim = "overworld", pos = { 5, 70, 5 }, color = true, files = { ["/zelnet"] = S.program } })
box:boot()
w:run(2)
box:typeLine("zelnet update")
w:run(15)
S.shot(box, "CLI UPDATE")
print("cli program updated:", box:readFile("/zelnet") == newBuild)
box:typeLine("zelnet update")
w:run(15)
S.shot(box, "CLI SECOND RUN")

S.errors(earth, "earth")
S.errors(mars, "mars")
S.errors(box, "box")
