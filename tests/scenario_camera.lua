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

local function box(ox, oy, oz, dx, dy, dz, x0, x1, y0, y1, z0, z1)
    local tmin, tmax = 0, math.huge
    for _, ax in ipairs({ { ox, dx, x0, x1 }, { oy, dy, y0, y1 }, { oz, dz, z0, z1 } }) do
        local o, d, lo, hi = ax[1], ax[2], ax[3], ax[4]
        if math.abs(d) < 1e-9 then
            if o < lo or o > hi then return nil end
        else
            local t1, t2 = (lo - o) / d, (hi - o) / d
            if t1 > t2 then t1, t2 = t2, t1 end
            tmin, tmax = math.max(tmin, t1), math.min(tmax, t2)
            if tmin > tmax then return nil end
        end
    end
    return tmin
end

local function scene(x, y)
    local dx, dy, dz = x, y, 1
    local best
    local function hit(t) if t and t > 0 and (not best or t < best) then best = t end end
    local function plane(o, d, v) if math.abs(d) > 1e-9 then local t = (v - o) / d if t > 0 then return t end end end
    local function inside(t, fn) if t then local px, py, pz = dx * t, dy * t, dz * t if fn(px, py, pz) then hit(t) end end end
    inside(plane(0, dy, -1.5), function(px, py, pz) return pz < 30 and math.abs(px) < 6 end)
    inside(plane(0, dy, 2.5), function(px, py, pz) return pz < 14 end)
    inside(plane(0, dx, -2), function(px, py, pz) return pz < 14 end)
    inside(plane(0, dx, 2), function(px, py, pz) return pz < 14 end)
    inside(plane(0, dz, 14), function(px, py, pz) return not (math.abs(px) < 1 and py < 1) end)
    inside(plane(0, dz, 26), function(px, py, pz) return math.abs(px) < 6 end)
    hit(box(0, 0, 0, dx, dy, dz, 0.8, 1.6, -1.5, 2.5, 5, 6))
    hit(box(0, 0, 0, dx, dy, dz, -1.6, -0.6, -1.5, -0.5, 9, 10))
    if not best then return -1 end
    local dist = best * math.sqrt(dx * dx + dy * dy + dz * dz)
    if dist > 32 then return -1 end
    return dist
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
w:run(6)
dump("camera_rough", activity)
w:run(14)
dump("camera_partial", activity)
w:run(70)
dump("camera_view", activity)
local text = activity:screenText()
print("activity shows the camera:", text:find("Camera MARS", 1, true) ~= nil and text:find("VIEW FROM MARS", 1, true) ~= nil)
print("picture reached full detail:", text:find("full", 1, true) ~= nil)
print("report names the camera:", text:find("camera 0", 1, true) ~= nil)
print("camera was scanned:", cam.calls > 1000)
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
