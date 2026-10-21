local S = require("tests.scen")
local need = require("tools.devload").make(".")
local crypto = need("crypto")
local w = S.world()
local activity = w:monitor({ w = 6, h = 3, color = true })
local console = w:monitor({ w = 6, h = 3, color = true })
local setup = w:monitor({ w = 1, h = 2, color = true })
w:connect("earth", activity, "monitor_1")
w:connect("earth", console, "monitor_2")
w:connect("earth", setup, "monitor_3")
w:connect("earth", w:diskDrive(), "drive_7")
local cfg = S.serverCfg("EARTH", "main", "EARTH", crypto.newKey(), {
    displays = { activity = "monitor_1", console = "monitor_2", setup = "monitor_3", drive = "drive_7" },
})
local earth = S.server(w, { id = 1, realm = "EARTH", dim = "overworld", pos = { 0, 70, 0 }, cable = "earth", cfg = cfg })
w:run(20)
local depth = tonumber(os.getenv("DEPTH") or "0")
local p = earth:profile()
if depth > 0 then p.samples = {} p.depth = depth end
w:run(120)
print(("displays idle: resumes/min %.0f instr/min %.0f peak %d timers/min %.0f"):format(p.resumes / 2, p.instr / 2, p.peak, p.timers / 2))
if depth > 0 then
    local list = {}
    for key, n in pairs(p.samples) do list[#list + 1] = { key, n } end
    table.sort(list, function(a, b) return a[2] > b[2] end)
    for i = 1, math.min(20, #list) do print(list[i][2], list[i][1]) end
end
S.errors(earth, "earth")
