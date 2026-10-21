local S = require("tests.scen")
local need = require("tools.devload").make(".")
local crypto = need("crypto")

local w = S.world()
local earth = S.server(w, { id = 1, realm = "EARTH", dim = "overworld", pos = { 0, 70, 0 }, cable = "earth",
    cfg = S.serverCfg("EARTH", "main", "EARTH", crypto.newKey()) })
w:run(10)
S.unlock(w, earth)
local bob = S.device(w, { id = 10, dim = "overworld", pos = { 20, 70, 0 } }, S.provision(w, earth, "1", "bob"))
local alice = S.device(w, { id = 11, dim = "overworld", pos = { 25, 70, 0 } }, S.provision(w, earth, "1", "alice"))
earth:pressKey(S.keys.leftCtrl) w:run(1)
local function create(c, user)
    c:typeText("2") w:run(2)
    c:typeText(user) c:pressKey(S.keys.tab) c:typeText("hunter22") c:pressKey(S.keys.tab) c:typeText("hunter22") c:pressKey(S.keys.enter)
    w:run(30)
end
create(bob, "bob")
create(alice, "alice")

local comps = { earth = earth, bob = bob, alice = alice }
local order = { "earth", "bob", "alice" }
local function phase(name, seconds, action)
    for _, k in ipairs(order) do comps[k]:profile() end
    if action then action() end
    w:run(seconds)
    print(("== %s (%d s)"):format(name, seconds))
    for _, k in ipairs(order) do
        local c = comps[k]
        local p = c.prof
        local mins = seconds / 60
        print(("%-6s resumes/min %7.0f  instr/min %10.0f  peak %9d on %-14s  timers/min %6.0f  coroutines live %3d created %4d  running %s"):format(
            k, p.resumes / mins, p.instr / mins, p.peak, tostring(p.peakEvent), p.timers / mins, c.liveCoroutines(), p.coCreated, tostring(c:isOn())))
        if os.getenv("PROF_TRACE") and p.bestTrace then print(p.bestTrace) end
        if os.getenv("PROF_EVENTS") then
            local list = {}
            for e, n in pairs(p.events or {}) do list[#list + 1] = e .. "=" .. n end
            table.sort(list)
            print("       events: " .. table.concat(list, " "))
            local ts = {}
            for k2, n in pairs(p.timerSites or {}) do ts[#ts + 1] = { k2, n } end
            table.sort(ts, function(x, y) return x[2] > y[2] end)
            for i = 1, math.min(4, #ts) do print("       timer " .. ts[i][2] .. " at " .. ts[i][1]) end
        end
    end
end

phase("idle, logged in at home", 300)
phase("bob writes to alice, alice in thread", 120, function()
    bob:typeText("2") w:run(2)
    bob:typeText("alice") bob:pressKey(S.keys.enter) w:run(10)
    alice:typeText("1") w:run(5)
    alice:pressKey(S.keys.enter) w:run(10)
    for i = 1, 15 do
        bob:typeText("message number " .. i .. " with some text in it") bob:pressKey(S.keys.enter)
        w:run(3)
    end
end)
phase("idle, both in the thread", 300)
alice:pressKey(S.keys.leftCtrl) w:run(2)
alice:typeText("3") w:run(2)
phase("alice on Network status", 120)
S.errors(earth, "earth")
S.errors(bob, "bob")
S.errors(alice, "alice")
