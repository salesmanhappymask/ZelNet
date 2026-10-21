local S = require("tests.scen")
local need = require("tools.devload").make(".")
local crypto = need("crypto")
local w = S.world()
local earth, mars = S.twoRealms(w, crypto)
w:run(60)
local router = S.device(w, { id = 41, dim = "mars", pos = { 20, 70, 0 } }, S.provision(w, mars, "2", "outpost"))
mars:pressKey(S.keys.leftCtrl) w:run(1)
w:run(60)

local visited = false
local function versionsPage()
    if not visited then
        for _ = 1, 11 do earth:pressKey(S.keys.down) end
        visited = true
    end
    earth:pressKey(S.keys.enter) w:run(2)
    earth:pressKey(S.keys.enter) w:run(3)
    local text = earth:screenText()
    earth:pressKey(S.keys.leftCtrl) w:run(1)
    earth:pressKey(S.keys.leftCtrl) w:run(1)
    return text
end

local first = versionsPage()
print("---- VERSIONS ----\n" .. first)
local mainBuild = S.program:match('build = "(%w+)"')
print("mars reported:", first:find("MARS", 1, true) ~= nil and first:find("outpost", 1, true) ~= nil)

local prov = need("provision")
local full = prov.expand(mars:readFile("/zelnet"))
local oldFull = full:gsub('build = "%w+"', 'build = "0ld0ld00"', 1):gsub("release = %d+", "release = 3", 1)
mars:writeFile("/zelnet", prov.makeStub(oldFull))
mars:reboot()
w:run(30)
S.unlock(w, mars)
w:run(120)
local second = versionsPage()
print("---- VERSIONS AFTER MARS WENT OLD ----\n" .. second)
w:run(200)
S.unlock(w, mars)
w:run(30)
local third = versionsPage()
print("---- VERSIONS AFTER MARS REBOOTED ----\n" .. third)
print("mars current ok:", third:find("MARS[^\n]*r%d+ current") ~= nil)
print("mars file build:", mars:readFile("/zelnet"):match('build = "(%w+)"'), "main build:", mainBuild)
print("versions ok:", first:find("MARS", 1, true) ~= nil and first:find("outpost", 1, true) ~= nil)
print("satellite catch up ok:", mars:readFile("/zelnet"):match('build = "(%w+)"') == mainBuild)
S.errors(earth, "earth")
S.errors(mars, "mars")
S.errors(router, "router")
