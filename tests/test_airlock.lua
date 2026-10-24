package.path = "./?.lua;" .. package.path
local nativePcall = pcall
local env = require("tests.fakecc").install({ id = 4 })
rawset(_G, "__nativePcall", rawget(_G, "__nativePcall") or nativePcall)
local need = require("tools.devload").make(".")
local util = need("util")
local config = need("config")
local node = need("node")
local airlock = need("airlock")
local t = require("tests.tiny")

local net = { opened = {}, sent = {}, bc = {} }
_G.rednet = {
    open = function(side) net.opened[#net.opened + 1] = side end,
    send = function(id, msg) net.sent[#net.sent + 1] = { id = id, msg = util.deepCopy(msg) } end,
    broadcast = function(msg) net.bc[#net.bc + 1] = util.deepCopy(msg) end,
}

local function resetNet()
    net.opened, net.sent, net.bc = {}, {}, {}
end

local function memStorage()
    local st = { data = {}, audits = {}, isReady = true }
    function st:ready() return self.isReady end
    function st:read(role, rel, default)
        local v = self.data[role .. "/" .. rel]
        if v == nil then return default end
        return util.deepCopy(v)
    end
    function st:write(role, rel, value)
        if not self.isReady then return nil, "storage offline" end
        self.data[role .. "/" .. rel] = util.deepCopy(value)
        return true
    end
    function st:exists(role, rel) return self.data[role .. "/" .. rel] ~= nil end
    function st:audit(actor, action, target, detail, ok)
        self.audits[#self.audits + 1] = { actor = actor, action = action, target = target, detail = detail, ok = ok }
    end
    return st
end

local function mk(st, extra)
    local cfg = { realm = "MARS", airlocks = true }
    for k, v in pairs(extra or {}) do cfg[k] = v end
    local ctx = { cfg = cfg, log = util.newLogger(50), storage = st or memStorage() }
    return airlock.new(ctx), ctx
end

local function sentTo(id, kind)
    local out = {}
    for _, s in ipairs(net.sent) do
        if s.id == id and (not kind or s.msg.type == kind) then out[#out + 1] = s.msg end
    end
    return out
end

local function actions(st, name)
    local out = {}
    for _, a in ipairs(st.audits) do
        if a.action == name then out[#out + 1] = a end
    end
    return out
end

t.case("group names and roles", function()
    local g, s = airlock.groupInfo("Dock-East-A")
    t.eq(g, "Dock-East")
    t.eq(s, "A")
    g, s = airlock.groupInfo("Lab-12")
    t.eq(g, "Lab")
    t.eq(s, "12")
    g, s = airlock.groupInfo("Plain")
    t.eq(g, "Plain")
    t.eq(s, nil)
    g, s = airlock.groupInfo("dock-c")
    t.eq(s, "C")
    t.eq(airlock.normalize({ name = "Dock-C" }).role, "sensor")
    t.eq(airlock.normalize({ name = "Dock-A" }).role, "door")
    t.eq(airlock.normalize({ name = "Dock-C", role = "door" }).role, "door")
end)

t.case("seal policy priorities", function()
    local al = mk()
    al.nodes = {
        ["1"] = airlock.normalize({ id = 1, name = "Bay-A" }),
        ["2"] = airlock.normalize({ id = 2, name = "Bay-C", oxygenated = true }),
    }
    local door, sensor = al.nodes["1"], al.nodes["2"]
    t.eq(al:desired(sensor), false, "sensors never seal")
    t.eq(al:desired(door), false)
    sensor.oxygenated = false
    t.eq(al:desired(door), true, "chamber sensor low seals the group")
    door.manual = "unseal"
    t.eq(al:desired(door), false, "manual unseal beats the sensor")
    door.oxygenated = false
    t.eq(al:desired(door), false, "manual unseal beats own oxygen")
    door.manual = "seal"
    sensor.oxygenated = true
    door.oxygenated = true
    t.eq(al:desired(door), true, "manual seal")
    door.manual = "unseal"
    door.locked = true
    t.eq(al:desired(door), true, "locked beats manual")
    door.locked = nil
    door.manual = nil
    door.oxygenated = false
    t.eq(al:desired(door), true, "own oxygen low seals")
end)

t.case("register, ack, status reports and state change audits", function()
    resetNet()
    local al, ctx = mk()
    t.ok(al:handleMessage(12, { type = "alk_register", name = "Dock-A", reqID = "r1", oxygenated = true }))
    local acks = sentTo(12, "alk_ack")
    t.eq(#acks, 1)
    t.eq(acks[1].reqID, "r1")
    t.eq(acks[1].name, "Dock-A")
    t.eq(acks[1].role, "door")
    t.eq(acks[1].command, "unseal")
    t.eq(acks[1].locked, false)
    t.eq(#actions(ctx.storage, "register"), 1)
    t.ok(not al:handleMessage(12, { type = "alk_ack" }), "own message types ignored")
    t.ok(not al:handleMessage(12, { type = "chat" }))
    t.ok(not al:handleMessage("x", { type = "alk_status" }))
    al:handleMessage(12, { type = "alk_register", name = "Dock-A" })
    t.eq(#actions(ctx.storage, "register"), 1, "repeat register of an online node is not audited")
    al:handleMessage(12, { type = "alk_status", oxygenated = false })
    al:handleMessage(12, { type = "alk_status", oxygenated = false })
    al:handleMessage(12, { type = "alk_status", oxygenated = false })
    t.eq(#actions(ctx.storage, "depressurized"), 1, "only the transition is audited")
    acks = sentTo(12, "alk_ack")
    t.eq(acks[#acks].command, "seal")
    al:handleMessage(12, { type = "alk_status", oxygenated = true })
    t.eq(#actions(ctx.storage, "repressurized"), 1)
    al:handleMessage(13, { type = "alk_status", name = "Lab" })
    t.eq(#actions(ctx.storage, "discovered"), 1)
    t.eq(al:list()[1].name, "Dock-A")
    t.ok(ctx.storage.data["system/airlocks.db"] ~= nil, "persisted to storage role system")
end)

t.case("chamber sensor drives the whole group", function()
    resetNet()
    local al = mk()
    al:handleMessage(1, { type = "alk_register", name = "Bay-A", oxygenated = true })
    al:handleMessage(2, { type = "alk_register", name = "Bay-B", oxygenated = true })
    al:handleMessage(3, { type = "alk_register", name = "Bay-C", oxygenated = true })
    resetNet()
    al:handleMessage(3, { type = "alk_status", oxygenated = false })
    local c1 = sentTo(1, "alk_cmd")
    local c2 = sentTo(2, "alk_cmd")
    t.eq(#c1, 1)
    t.eq(c1[1].action, "seal")
    t.eq(c2[1].action, "seal")
    t.eq(#sentTo(3, "alk_cmd"), 0, "sensor gets no command")
    t.eq(sentTo(3, "alk_ack")[1].command, "unseal")
    local groups = al:groups()
    t.eq(#groups, 1)
    t.eq(groups[1].group, "Bay")
    t.eq(groups[1].total, 3)
    t.eq(groups[1].sealed, 2)
    t.eq(groups[1].chamberLow, true)
    t.eq(groups[1].grouped, true)
    t.eq(groups[1].members[3].suffix, "C", "sensor sorted last")
    local st = al:stats()
    t.eq(st.nodes, 3)
    t.eq(st.sealed, 2)
    t.eq(st.low, 1)
    t.eq(st.offline, 0)
    resetNet()
    al:handleMessage(3, { type = "alk_status", oxygenated = true })
    t.eq(#sentTo(1, "alk_cmd"), 0, "doors wait for the chamber to settle")
    env.advance(airlock.CONTAIN_MIN + 1)
    al:containTick()
    t.eq(sentTo(1, "alk_cmd")[1].action, "unseal")
    t.eq(sentTo(2, "alk_cmd")[1].action, "unseal")
    t.eq(#al:containment(), 0, "containment clears once every zone holds oxygen")
end)

local function athena(al)
    local id = 0
    local ids = {}
    for _, g in ipairs({ "Athena", "Athena2", "Athena3", "Athena4", "Athena5", "Athena6", "Athena7", "Athena8" }) do
        for _, L in ipairs({ "A", "B", "C" }) do
            id = id + 1
            ids[g .. "-" .. L] = id
            al:handleMessage(id, { type = "alk_register", name = g .. "-" .. L, oxygenated = true })
        end
    end
    return ids
end

local function lastCmd(id)
    local c = sentTo(id, "alk_cmd")
    return c[#c] and c[#c].action
end

t.case("station containment: one leak closes every door, the leaking zone stays shut", function()
    resetNet()
    local al, ctx = mk()
    local ids = athena(al)
    t.eq(airlock.stationOf("Athena7"), "Athena")
    t.eq(airlock.stationOf("Athena"), "Athena")
    t.eq(airlock.stationOf("Dock-East"), "Dock-East")
    resetNet()
    al:handleMessage(ids["Athena6-C"], { type = "alk_status", oxygenated = false })
    for name, id in pairs(ids) do
        if not name:match("%-C$") then t.eq(lastCmd(id), "seal", name .. " sealed by containment") end
    end
    t.eq(#actions(ctx.storage, "containment"), 1)
    t.eq(al:containment()[1].station, "Athena")
    t.eq(al:containment()[1].cause, "Athena6-C")
    resetNet()
    env.advance(airlock.CONTAIN_MIN - 5)
    al:containTick()
    t.eq(#net.sent, 0, "nothing reopens before the minimum hold")
    env.advance(6)
    al:containTick()
    t.eq(lastCmd(ids["Athena2-B"]), "unseal", "zones with oxygen on both sides reopen")
    t.eq(lastCmd(ids["Athena-A"]), "unseal")
    t.eq(#sentTo(ids["Athena6-A"], "alk_cmd"), 0, "Athena6-A stays sealed")
    t.eq(#sentTo(ids["Athena6-B"], "alk_cmd"), 0, "Athena6-B stays sealed")
    t.eq(al.nodes[tostring(ids["Athena6-A"])].sealed, true)
    t.eq(#al:containment(), 1, "containment stays while Athena6 has no oxygen")
    resetNet()
    al:handleMessage(ids["Athena6-C"], { type = "alk_status", oxygenated = true })
    al:containTick()
    t.eq(#sentTo(ids["Athena6-A"], "alk_cmd"), 0, "repaired zone waits to settle")
    env.advance(airlock.SETTLE)
    al:containTick()
    t.eq(lastCmd(ids["Athena6-A"]), "unseal")
    t.eq(lastCmd(ids["Athena6-B"]), "unseal")
    t.eq(#al:containment(), 0)
    t.eq(#actions(ctx.storage, "containment_clear"), 1)
end)

t.case("station containment: a door detector losing air seals that side, settles, and repeated trips hold", function()
    resetNet()
    local al, ctx = mk()
    local ids = athena(al)
    resetNet()
    al:handleMessage(ids["Athena2-B"], { type = "alk_status", oxygenated = false })
    t.eq(lastCmd(ids["Athena5-A"]), "seal", "far doors close too")
    env.advance(airlock.CONTAIN_MIN + 1)
    resetNet()
    al:containTick()
    t.eq(#sentTo(ids["Athena2-B"], "alk_cmd"), 0, "door facing the lost side stays sealed")
    t.eq(lastCmd(ids["Athena2-A"]), "unseal", "other door of the zone opens")
    al:handleMessage(ids["Athena2-B"], { type = "alk_status", oxygenated = true })
    al:handleMessage(ids["Athena2-B"], { type = "alk_status", oxygenated = false })
    al:handleMessage(ids["Athena2-B"], { type = "alk_status", oxygenated = true })
    t.eq(al:containment()[1].hold, nil, "two trips do not hold yet")
    al:handleMessage(ids["Athena2-B"], { type = "alk_status", oxygenated = false })
    al:handleMessage(ids["Athena2-B"], { type = "alk_status", oxygenated = true })
    t.eq(al:containment()[1].hold, true, "three trips in ten minutes hold the station shut")
    t.eq(#actions(ctx.storage, "containment_hold"), 1)
    env.advance(airlock.TRIP_WINDOW)
    resetNet()
    al:containTick()
    t.eq(#net.sent, 0, "a hold waits for the console")
    t.ok(al:releaseContainment("Athena", "admin"))
    t.eq(lastCmd(ids["Athena5-A"]), "unseal")
    t.eq(#actions(ctx.storage, "containment_release"), 1)
    local al2 = mk(ctx.storage)
    al2:load()
    t.eq(#al2:containment(), 0, "release persisted")
end)

t.case("station containment survives a restart and can be turned off", function()
    resetNet()
    local al, ctx = mk()
    local ids = athena(al)
    al:handleMessage(ids["Athena3-C"], { type = "alk_status", oxygenated = false })
    local al2 = mk(ctx.storage)
    al2:load()
    t.eq(al2:containment()[1].cause, "Athena3-C")
    t.eq(al2:desired(al2.nodes[tostring(ids["Athena7-A"])]), true, "reloaded containment keeps doors shut")
    resetNet()
    local off = mk(nil, { containment = false })
    local ids2 = athena(off)
    resetNet()
    off:handleMessage(ids2["Athena6-C"], { type = "alk_status", oxygenated = false })
    t.eq(#off:containment(), 0)
    t.eq(lastCmd(ids2["Athena6-A"]), "seal", "group rule still works")
    t.eq(#sentTo(ids2["Athena5-A"], "alk_cmd"), 0, "other groups untouched")
end)

t.case("manual modes, locking, rename and remove", function()
    resetNet()
    local al, ctx = mk()
    al:handleMessage(1, { type = "alk_register", name = "Bay-A", oxygenated = true })
    al:handleMessage(3, { type = "alk_register", name = "Bay-C", oxygenated = true })
    resetNet()
    local ok, desired = al:setManual(1, "seal")
    t.ok(ok)
    t.eq(desired, true)
    t.eq(sentTo(1, "alk_cmd")[1].action, "seal")
    t.eq(#actions(ctx.storage, "airlock_seal"), 1)
    t.eq(select(2, al:setManual(1, "sideways")), "Unknown mode.")
    t.eq(select(2, al:setManual(99, "seal")), "Unknown airlock.")
    al:setManual(1, "auto")
    t.eq(al.nodes["1"].sealed, false)
    resetNet()
    t.ok(al:setLocked(1, true))
    local cmd = sentTo(1, "alk_cmd")[1]
    t.eq(cmd.action, "seal")
    t.eq(cmd.locked, true)
    t.eq(#actions(ctx.storage, "airlock_lock"), 1)
    t.eq(select(2, al:setLocked(3, true)), "Sensors have no door to lock.")
    resetNet()
    t.ok(al:setLocked(1, false))
    t.eq(sentTo(1, "alk_cmd")[1].action, "unseal")
    t.eq(sentTo(1, "alk_cmd")[1].locked, false)
    t.ok(al:rename(1, "Dock-A"))
    t.eq(al.nodes["1"].group, "Dock")
    t.eq(select(2, al:rename(1, "   ")), "Name is empty.")
    resetNet()
    al:handleMessage(1, { type = "alk_status", name = "Bay-A" })
    t.eq(al.nodes["1"].name, "Dock-A", "admin rename is kept")
    t.eq(sentTo(1, "alk_ack")[1].name, "Dock-A")
    t.ok(al:remove(1))
    t.eq(al.nodes["1"], nil)
    t.eq(#actions(ctx.storage, "airlock_remove"), 1)
end)

t.case("offline detection uses the clock since boot", function()
    resetNet()
    local al, ctx = mk()
    al:handleMessage(5, { type = "alk_register", name = "Hatch" })
    env.advance(600)
    t.eq(al:poll(), 1)
    t.eq(#sentTo(5, "alk_poll"), 1)
    t.eq(al.nodes["5"].online, true)
    env.advance(301)
    al:poll()
    t.eq(al.nodes["5"].online, false)
    t.eq(#actions(ctx.storage, "offline"), 1)
    t.eq(actions(ctx.storage, "offline")[1].ok, false)
    al:poll()
    t.eq(#actions(ctx.storage, "offline"), 1, "offline audited once")
    t.eq(al:stats().offline, 1)
    al:handleMessage(5, { type = "alk_status" })
    t.eq(al.nodes["5"].online, true)
    t.eq(#actions(ctx.storage, "online"), 1)
end)

t.case("records persist and reload with a grace period", function()
    resetNet()
    local st = memStorage()
    local al = mk(st)
    al:handleMessage(7, { type = "alk_register", name = "Lock-A", oxygenated = false })
    al:setLocked(7, true)
    al:setManual(7, "seal")
    local al2 = mk(st)
    t.ok(al2:load())
    local rec = al2.nodes["7"]
    t.ok(rec ~= nil)
    t.eq(rec.name, "Lock-A")
    t.eq(rec.locked, true)
    t.eq(rec.manual, "seal")
    t.eq(rec.oxygenated, false)
    t.eq(rec.online, true)
    t.eq(rec.group, "Lock")
    env.advance(899)
    al2:checkOffline()
    t.eq(rec.online, true, "not offline before the window after a restart")
    st.isReady = false
    local al3 = mk(st)
    t.ok(not al3:load(), "storage offline defers the load")
    al3:handleMessage(9, { type = "alk_register", name = "New" })
    st.isReady = true
    al3:tick()
    t.ok(al3.nodes["7"] ~= nil and al3.nodes["9"] ~= nil, "late load merges with records heard meanwhile")
    al3:save()
    t.ok(st.data["system/airlocks.db"].nodes["9"] ~= nil)
end)

t.case("task opens rednet on every modem, discovers without blocking, handles events", function()
    resetNet()
    env.setPeripheral("top", { type = "modem", methods = { isWireless = function() return true end, open = function() end, isOpen = function() return false end, close = function() end, closeAll = function() end, transmit = function() end } })
    env.setPeripheral("modem_5", { type = "modem", methods = { isWireless = function() return false end, open = function() end, isOpen = function() return false end, close = function() end, closeAll = function() end, transmit = function() end } })
    env.setPeripheral("drive_1", { type = "drive", methods = {} })
    local cfg = config.newServer({ realm = "MARS" })
    local n = node.new(cfg)
    local st = memStorage()
    local ctx = { cfg = cfg, log = n.log, node = n, storage = st }
    local al = airlock.new(ctx)
    local seenAck
    env.run(function()
        n:loop(function()
            al:start()
            sleep(1)
            os.queueEvent("rednet_message", 21, { type = "alk_register", name = "Gate-A", reqID = 9 }, nil)
            os.queueEvent("rednet_message", 22, "not a table", nil)
            sleep(1)
            seenAck = sentTo(21, "alk_ack")[1]
            al:discover()
            sleep(1)
        end)
    end, 120)
    table.sort(net.opened)
    t.eq(#net.opened, 2)
    t.eq(net.opened[1], "modem_5")
    t.eq(net.opened[2], "top")
    t.eq(#net.bc, 6, "three discover broadcasts at start and three on request")
    t.eq(net.bc[1].type, "alk_discover")
    t.ok(seenAck ~= nil)
    t.eq(seenAck.reqID, 9)
    t.eq(al:list()[1].name, "Gate-A")
    env.setPeripheral("top", nil)
    env.setPeripheral("modem_5", nil)
    env.setPeripheral("drive_1", nil)
end)

t.case("disabled by config", function()
    resetNet()
    local al = mk(nil, { airlocks = false })
    t.ok(al:start())
    t.eq(al.task, nil)
    t.eq(al:poll(), 0)
    t.eq(#al:list(), 0)
    t.eq(al:discover(), false)
end)

t.case("review: a report before storage is ready keeps the stored lock, override and name", function()
    resetNet()
    local st = memStorage()
    local a1 = mk(st)
    a1:start()
    a1:handleMessage(21, { type = "alk_status", name = "Door-A", oxygenated = true })
    a1:rename(21, "Hatch-A")
    a1:setLocked(21, true)
    a1:handleMessage(22, { type = "alk_status", name = "Bay-B", oxygenated = true })
    a1:setManual(22, "seal")
    st.isReady = false
    resetNet()
    local a2 = mk(st)
    a2:start()
    a2:handleMessage(21, { type = "alk_status", name = "Door-A", oxygenated = true })
    a2:handleMessage(22, { type = "alk_status", name = "Bay-B", oxygenated = true })
    st.isReady = true
    a2:tick()
    local r21, r22
    for _, r in ipairs(a2:list()) do
        if r.id == 21 then r21 = r end
        if r.id == 22 then r22 = r end
    end
    t.eq(r21.name, "Hatch-A")
    t.eq(r21.locked, true)
    t.eq(r21.sealed, true)
    t.eq(r22.manual, "seal")
    t.eq(r22.sealed, true)
    local cmds = sentTo(21, "alk_cmd")
    t.ok(#cmds >= 1 and cmds[#cmds].action == "seal" and cmds[#cmds].locked == true, "the lock is sent again")
    a2:save()
    t.eq(st.data["system/airlocks.db"].nodes["21"].locked, true)
end)

t.finish()
