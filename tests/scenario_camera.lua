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

local function scene(x, y)
    if y < -0.15 then return math.min(30, 1.6 / -y) end
    if math.abs(x + 0.35) < 0.12 and y < 0.5 then return 4 + y end
    if x > 0.3 and y < 0.35 then return 9 + x * 2 end
    if y < 0.25 then return 16 end
    return -1
end

local w = S.world()
local activity = w:monitor({ w = 6, h = 3, color = true })
w:connect("earth", activity, "monitor_1")
local cam = w:camera({ scene = scene })
w:connect("mars", cam, "computertronics_camera_0")
local earth, mars = S.twoRealms(w, crypto, { displays = { activity = "monitor_1" } })
w:run(80)

earth:typeText("5") w:run(2)
earth:typeText("1") w:run(3)
earth:pressKey(S.keys.down) w:run(1)
earth:pressKey(S.keys.enter) w:run(2)
S.shot(earth, "REALM MENU")
earth:typeText("1") w:run(2)
S.shot(earth, "VIEW CAMERA")
earth:pressKey(S.keys.enter) w:run(1)
w:run(20)
dump("camera_partial", activity)
w:run(70)
dump("camera_view", activity)
local text = activity:screenText()
print("activity shows the camera:", text:find("Camera MARS", 1, true) ~= nil)
print("report names the camera:", text:find("camera 0", 1, true) ~= nil)
print("camera was scanned:", cam.calls > 200)
w:touch(activity, 10, 10)
w:run(3)
local after = activity:screenText()
print("touch closes the viewer:", after:find("Camera MARS", 1, true) == nil and after:find("Activity", 1, true) ~= nil)
w:run(45)
local calls = cam.calls
w:run(20)
print("camera stops after the lease:", cam.calls == calls)
S.errors(earth, "earth")
S.errors(mars, "mars")
