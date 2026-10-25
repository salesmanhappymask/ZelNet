local S = require("tests.scen")
local need = require("tools.devload").make(".")
local crypto = need("crypto")
local progText = need("prog_airlock")

local w = S.world()
local http = { whitelist = "*pastebin.com;*computercraft.info;paste.rs;dpaste.com", files = { ["https://paste.rs/"] = "https://paste.rs/Zq7" }, delay = 2 }
w.config.http = http
local cfg = S.serverCfg("EARTH", "main", "EARTH", crypto.newKey(), { airlocks = true })
local earth = S.server(w, { id = 1, realm = "EARTH", dim = "overworld", pos = { 0, 70, 0 }, cable = "earth", cfg = cfg })
w:run(10)
S.unlock(w, earth)

local function writeAirlockDisk()
    local fl = w:floppy({ label = "blank" })
    earth.provDrive:insert(fl)
    w:run(1)
    earth:typeText("2") w:run(2)
    earth:typeText("n") w:run(2)
    earth:typeText("4") w:run(2)
    earth:pressKey(S.keys.enter) w:run(2)
    earth:pressKey(S.keys.enter) w:run(5)
    earth:pressKey(S.keys.enter) w:run(1)
    earth:pressKey(S.keys.leftCtrl) w:run(1)
    return earth.provDrive:remove()
end

local function airlockComputer(id, x, disk)
    local c = w:addComputer({ id = id, dim = "overworld", pos = { x, 70, 0 }, color = true })
    c:attach("top", w:wirelessModem())
    local d = w:diskDrive()
    c:attach("bottom", d)
    d:insert(disk)
    c:setRedstoneInput("back", true)
    c:boot()
    w:run(4)
    return c, d
end

local disk = writeAirlockDisk()
print("disk carries the update key:", disk:readFile("airlock.key") ~= nil)
local door, doorDrive = airlockComputer(70, 10, disk)
door:typeText("1") w:run(1)
door:pressKey(S.keys.enter) w:run(4)
door:pressKey(S.keys.enter) w:run(1)
door:typeText("6") w:run(1)
door:typeText("3") w:run(1)
door:typeText("1") w:run(1)
door:typeText("2") w:run(1)
S.shot(door, "LIGHT QUESTION")
door:typeText("5") w:run(8)
doorDrive:remove()
print("door has the update key:", door:readFile("/airlock.key") ~= nil and door:readFile("/airlock.key") == disk:readFile("airlock.key"))

local sensor, sensorDrive = airlockComputer(71, 14, writeAirlockDisk())
sensor:typeText("2") w:run(1)
sensor:pressKey(S.keys.enter) w:run(1)
sensor:typeText("6") w:run(1)
sensor:typeText("1") w:run(1)
sensor:typeText("1") w:run(8)
sensorDrive:remove()
w:run(10)
print("door open, light off:", door.rsOut.left == 15 and (door.rsOut.right or 0) == 0)

earth:typeText("7") w:run(2)
S.shot(earth, "AIRLOCKS")
earth:typeText("l") w:run(2)
earth:pressKey(S.keys.enter) w:run(3)
S.shot(door, "DOOR IN LOCKDOWN")
print("door shows lockdown:", door:screenText():find("STATION LOCKDOWN", 1, true) ~= nil)
print("door sealed by lockdown:", door.rsOut.left == 0)
local seen = {}
for _ = 1, 8 do
    w:run(0.25)
    seen[(door.rsOut.right or 0) > 0 and "on" or "off"] = true
end
print("warning light flashes:", seen.on == true and seen.off == true)
print("sensor shows lockdown:", sensor:screenText():find("LOCKDOWN", 1, true) ~= nil)
earth:typeText("x") w:run(2)
earth:pressKey(S.keys.enter) w:run(20)
print("door reopens after release:", door.rsOut.left == 15 and not door:screenText():find("LOCKDOWN", 1, true))
w:run(2)
print("light off when open:", (door.rsOut.right or 0) == 0)

earth:typeText("p") w:run(8)
S.shot(earth, "PUSH LOGS")
local screen = earth:screenText()
print("push logs shows the address:", screen:find("https://paste.rs/Zq7", 1, true) ~= nil)
local body = http.posts and http.posts[#http.posts] and http.posts[#http.posts].body or ""
print("bundle has server events:", body:find("ZELNET AIRLOCK LOG BUNDLE", 1, true) ~= nil and body:find("LOCKDOWN EARTH", 1, true) == nil and body:find("cmd dock-A seal", 1, true) ~= nil)
print("bundle has the door's own log:", body:find("== dock-A (#70) local log", 1, true) ~= nil and body:find("station lockdown", 1, true) ~= nil)
local bf = io.open("build/sample_bundle.txt", "w") bf:write(body) bf:close()
print("bundle saved on the server:", earth:readFile("/airlock_logs.txt") ~= nil)
earth:pressKey(S.keys.enter) w:run(1)

door:writeFile("/startup", (progText:gsub('local VERSION = "%w+"', 'local VERSION = "0ld0ld00"', 1)))
door:reboot()
w:run(60)
S.shot(door, "DOOR AFTER UPDATE")
local now = door:readFile("/startup") or ""
print("door updated over the air:", now:gsub("[\r\n]+$", "") == progText:gsub("[\r\n]+$", ""))
local dlog = door:readFile("/airlock.log") or ""
print("door logged the update:", dlog:find("installed, rebooting", 1, true) ~= nil)
print("door still open after update:", door.rsOut.left == 15)

S.errors(earth, "earth")
S.errors(door, "door")
S.errors(sensor, "sensor")
