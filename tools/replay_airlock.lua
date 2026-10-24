package.path = "./?.lua;" .. package.path
local env = require("tests.fakecc").install({ id = 4 })
local need = require("tools.devload").make(".")
local util = need("util")
local airlock = need("airlock")
_G.rednet = { open = function() end, send = function() end, broadcast = function() end }
local path, drops = arg[1], tonumber(arg[2])
local lines = {}
for l in io.lines(path) do lines[#lines + 1] = l end
local ids, names = {}, {}
for _, l in ipairs(lines) do
    local name, id = l:match("^(Athena%d?%-%u)%s+(%d+) ")
    if name then ids[name] = tonumber(id) end
end
local al = airlock.new({ cfg = { realm = "ATHENA", airlocks = true }, log = util.newLogger(50) })
if drops then airlock.UNSTABLE_DROPS = drops end
local opens, backoffs = 0, 0
al.rsend = function(_, id, msg) if msg.type == "alk_cmd" and msg.action == "unseal" then opens = opens + 1 end return true end
local t0 = nil
for name, id in pairs(ids) do al:handleMessage(id, { type = "alk_register", name = name, oxygenated = true, sealed = false }) end
local clock = 0
local function advance(to)
    while clock + 1 <= to do clock = clock + 1 env.advance(1) al:containTick() end
end
for _, l in ipairs(lines) do
    local t, name, kind, o2, sealed = l:match("^d%d+ %d+:%d+ ([%d%.]+) rx (%S+) (%S+) o2=(%a+) sealed=(%a+)")
    if t then
        t = tonumber(t)
        t0 = t0 or t - 5
        advance(t - t0)
        al:handleMessage(ids[name], { type = "alk_" .. kind, name = name, oxygenated = o2 == "true", sealed = sealed == "true" })
    end
end
advance(clock + 60)
for _, e in ipairs(al.events) do if e:find("backoff ", 1, true) then backoffs = backoffs + 1 end end
print(drops and ("unstable after " .. drops .. " drops") or "current rules", "door openings", opens, "failed openings (backoffs)", backoffs)
