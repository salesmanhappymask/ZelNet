package.path = "./?.lua;" .. package.path
require("tests.fakecc").install({ id = 4 })
local termlib = require("sim.term")
local need = require("tools.devload").make(".")
local ui = need("ui")
local navmap = need("navmap")

local OUT = arg[1] or "build/screens"
os.execute("mkdir -p " .. OUT)

local function nodes(lost, extra)
    local list = {}
    for _, z in ipairs(navmap.ZONES) do
        for _, L in ipairs({ "A", "B", "C" }) do
            local name = z.group .. "-" .. L
            local r = { name = name, role = L == "C" and "sensor" or "door", online = true, oxygenated = true, sealed = false }
            if lost[name] then r.oxygenated = false end
            list[#list + 1] = r
        end
    end
    for _, r in ipairs(list) do
        if extra then extra(r) end
    end
    return list
end

local function shot(name, list, contain, frame)
    local w, h = termlib.monitorSize(6, 5, 0.5)
    local t = termlib.Terminal.new(w, h, true)
    local methods = termlib.methods(function() return t end)
    methods.setTextScale = function() end
    local surf = ui.surface(methods, "monitor_9")
    navmap.draw(surf, list, contain, { frame = frame, release = "r38", clock = "Day 41  14:05" })
    surf:flush(true)
    local f = assert(io.open(OUT .. "/" .. name .. ".scr", "w"))
    f:write("# " .. t.w .. " " .. t.h .. "\n")
    for y = 1, t.h do f:write(t.text[y - 1] .. "\n") end
    for y = 1, t.h do f:write(t:textColours(y) .. "\n") end
    for y = 1, t.h do f:write(t:backgroundColours(y) .. "\n") end
    f:close()
    print(name, w, h)
end

shot("navmap_sealed", nodes({}), {}, 0)
local lost = { ["Athena6-C"] = true }
local breach = nodes(lost, function(r)
    if r.name == "Athena6-A" or r.name == "Athena6-B" then r.sealed = true end
end)
shot("navmap_breach_a", breach, { { station = "Athena", cause = "Athena6-C", age = 42 } }, 0)
shot("navmap_breach_b", breach, { { station = "Athena", cause = "Athena6-C", age = 43 } }, 1)
local all = nodes({}, function(r) if r.role == "door" then r.sealed = true end end)
shot("navmap_contain", all, { { station = "Athena", cause = "Athena2-B", age = 8 } }, 0)
