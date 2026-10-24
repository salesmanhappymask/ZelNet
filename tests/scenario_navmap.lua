local S = require("tests.scen")
local need = require("tools.devload").make(".")
local crypto = need("crypto")

local OUT = "build/screens"
os.execute("mkdir -p " .. OUT)

local function dump(name, mon)
    local t = mon.term
    local f = assert(io.open(OUT .. "/" .. name .. ".scr", "w"))
    f:write("# " .. t.w .. " " .. t.h .. "\n")
    for y = 1, t.h do f:write(t.text[y - 1] .. "\n") end
    for y = 1, t.h do f:write(t:textColours(y) .. "\n") end
    for y = 1, t.h do f:write(t:backgroundColours(y) .. "\n") end
    f:close()
end

local w = S.world()
local nav = w:monitor({ w = 6, h = 5, color = true })
w:connect("earth", nav, "monitor_5")
local cfg = S.serverCfg("EARTH", "main", "EARTH", crypto.newKey(), { airlocks = true })
local earth = S.server(w, { id = 1, realm = "EARTH", dim = "overworld", pos = { 0, 70, 0 }, cable = "earth", cfg = cfg })
w:run(10)
S.unlock(w, earth)

for _ = 1, 10 do earth:pressKey(S.keys.down) end
earth:pressKey(S.keys.enter) w:run(2)
S.shot(earth, "SETTINGS")
earth:typeText("2") w:run(2)
S.shot(earth, "NAVMAP FORM")
earth:typeText("5")
earth:pressKey(S.keys.enter) w:run(3)
S.shot(earth, "AFTER SAVE")
earth:pressKey(S.keys.leftCtrl) w:run(1)
earth:pressKey(S.keys.leftCtrl) w:run(1)
print("navmap size", nav.term.w, nav.term.h)

local FAKE = [[
local NAME, ROLE = "%s", "%s"
rednet.open("top")
local function report(kind)
    rednet.broadcast({ type = kind, name = NAME, role = ROLE, oxygenated = rs.getInput("back"), reqID = tostring(os.clock()) })
end
report("alk_register")
local t = os.startTimer(5)
while true do
    local ev, a, b = os.pullEvent()
    if ev == "redstone" then report("alk_status")
    elseif ev == "timer" and a == t then report("alk_hello") t = os.startTimer(30)
    elseif ev == "rednet_message" and type(b) == "table" and b.type == "alk_poll" then report("alk_status_reply") end
end
]]
local nodes = {}
local id = 100
for _, g in ipairs({ "Athena2", "Athena6" }) do
    for _, L in ipairs({ "A", "B", "C" }) do
        id = id + 1
        local name = g .. "-" .. L
        local c = w:addComputer({ id = id, dim = "overworld", pos = { id - 90, 70, 0 }, color = true,
            files = { ["/startup"] = string.format(FAKE, name, L == "C" and "sensor" or "door") } })
        c:attach("top", w:wirelessModem())
        c:setRedstoneInput("back", true)
        c:boot()
        nodes[name] = c
    end
end
w:run(15)
dump("sim_navmap_ok", nav)
local text = nav:screenText()
print("navmap title:", text:find("STATION ATHENA", 1, true) ~= nil)
print("navmap zones listed:", text:find("6 Athena6", 1, true) ~= nil and text:find("2 Athena2", 1, true) ~= nil)
print("navmap no breach yet:", text:find("BREACH", 1, true) == nil)

nodes["Athena6-C"]:setRedstoneInput("back", false)
w:run(4)
dump("sim_navmap_breach", nav)
text = nav:screenText()
print("navmap breach shown:", text:find("BREACH", 1, true) ~= nil)
print("navmap containment cause:", text:find("Athena6-C", 1, true) ~= nil)
w:run(1)
dump("sim_navmap_breach2", nav)
earth:typeText("7") w:run(2)
S.shot(earth, "AIRLOCKS DURING CONTAINMENT")
print("console shows containment:", earth:screenText():find("CONTAINMENT: Athena", 1, true) ~= nil)
nodes["Athena6-C"]:setRedstoneInput("back", true)
w:run(30)
dump("sim_navmap_clear", nav)
text = nav:screenText()
print("navmap clear again:", text:find("BREACH", 1, true) == nil and text:find("clear", 1, true) ~= nil)
S.errors(earth, "earth")
