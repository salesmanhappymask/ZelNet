package.path = "./?.lua;" .. package.path
require("tests.fakecc").install({ id = 4 })
local need = require("tools.devload").make(".")
local navmap = need("navmap")
local t = require("tests.tiny")

t.case("door lines cross each hallway where it meets its room", function()
    local lines = navmap.doorLines()
    local n = 0
    for name, ln in pairs(lines) do
        n = n + 1
        t.eq(#ln.cells, 5, name .. " spans the hallway plus a wall block at each end")
    end
    t.eq(n, 16)
    local a = lines["Athena7-A"]
    t.eq(a.horizontal, false, "Athena7-A crosses the ring corridor top to bottom")
    t.eq(a.cells[1][1], 17)
    local b = lines["Athena2-B"]
    t.eq(b.horizontal, true)
    t.eq(b.cells[1][2], -29)
end)

t.case("door states map to colors and labels", function()
    local function info(r) return navmap.doorInfo(r) end
    t.eq(info(nil), "missing")
    t.eq(info({ online = false }), "offline")
    t.eq(info({ online = true, sealed = false }), "open")
    t.eq(info({ online = true, sealed = true, lockdown = true }), "lockdown")
    t.eq(info({ online = true, sealed = true, locked = true }), "locked")
    t.eq(info({ online = true, sealed = true, manual = "seal" }), "manual")
    t.eq(info({ online = true, sealed = true, why = "room South: no oxygen" }), "breach")
    local cat, label = info({ online = true, sealed = true, why = "retry in 40s (lost air after opening)" })
    t.eq(cat, "retry")
    t.eq(label, "RETRY 40s")
    t.eq(info({ online = true, sealed = true, why = "waiting: room North settling" }), "sealing")
    t.eq(info({ online = true, sealed = true, why = "waiting its turn to open" }), "sealing")
    t.eq(navmap.doorCode("Athena7-A"), "7A")
    t.eq(navmap.doorCode("Athena-B"), "1B")
end)

t.finish()
