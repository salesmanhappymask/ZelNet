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
local activity = w:monitor({ w = 6, h = 3, color = true })
local console = w:monitor({ w = 6, h = 3, color = true })
local setup = w:monitor({ w = 1, h = 2, color = true })
local oldTop = w:monitor({ w = 1, h = 3, color = true })
local setupDrive = w:diskDrive()
w:connect("earth", activity, "monitor_1")
w:connect("earth", console, "monitor_2")
w:connect("earth", setup, "monitor_3")
w:connect("earth", oldTop, "monitor_4")
w:connect("earth", setupDrive, "drive_7")
for i = 0, 5 do
    local d = w:diskDrive()
    w:connect("earth", d, "drive_" .. (20 + i))
    if i < 2 then d:insert(w:pocket({ label = "data" .. i })) end
end

local cfg = S.serverCfg("EARTH", "main", "EARTH", crypto.newKey(), {
    displays = { activity = "monitor_1", console = "monitor_2", setup = "monitor_3", drive = "drive_7" },
    storage = { drives = { accounts = "drive_20", mail = "drive_21" } },
})
local earth = S.server(w, { id = 1, realm = "EARTH", dim = "overworld", pos = { 0, 70, 0 }, cable = "earth", cfg = cfg })
w:run(10)
print("activity size", activity.term.w, activity.term.h, "console size", console.term.w, console.term.h, "setup size", setup.term.w, setup.term.h)
dump("sim_setup_locked", setup)
print(setup:screenText())

local pocket = w:pocket({ label = "Steve's pocket", files = { ["/startup"] = "print('mine')", ["/games/worm"] = "x" } })
setupDrive:insert(pocket)
S.unlock(w, earth)
w:run(3)
dump("sim_setup_home", setup)
print(setup:screenText())

setup:touch(7, 10)
w:run(2)
dump("sim_setup_name", setup)
print(setup:screenText())
setup:touch(12, 22)
w:run(2)
dump("sim_setup_confirm", setup)
print(setup:screenText())
setup:touch(12, 23)
w:run(60)
dump("sim_setup_done", setup)
print(setup:screenText())

console:touch(30, 4)
w:run(2)
dump("sim_console_devices", console)
console:touch(80, 4)
w:run(6)
dump("sim_console_drives", console)
dump("sim_activity", activity)
print(console:screenText())

setup:touch(7, 23)
w:run(2)
local disk = setupDrive:remove()
print("pocket files:", table.concat((function() local t = {} for k in pairs(disk:files()) do t[#t + 1] = k end table.sort(t) return t end)(), " "))

local client = S.device(w, { id = 10, dim = "overworld", pos = { 20, 70, 0 } }, disk)
S.shot(client, "CLIENT FROM POCKET")
w:run(20)
dump("sim_activity_after", activity)
print(activity:screenText())
print("old 1x3 monitor untouched:", oldTop:screenText() == "")
S.errors(earth, "earth")
S.errors(client, "client")
