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

local function tick(al, seconds)
    for _ = 1, seconds do
        env.advance(1)
        al:containTick()
    end
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
    env.advance(airlock.LOSS_CONFIRM)
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
    t.eq(#sentTo(1, "alk_cmd"), 0, "a single reading waits to be confirmed")
    tick(al, airlock.LOSS_CONFIRM)
    local c1 = sentTo(1, "alk_cmd")
    local c2 = sentTo(2, "alk_cmd")
    t.eq(#c1, 1)
    t.eq(c1[1].action, "seal")
    t.eq(c2[1].action, "seal")
    t.eq(#sentTo(3, "alk_cmd"), 0, "sensor gets no command")
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
    tick(al, airlock.SETTLE - 1)
    t.eq(#sentTo(1, "alk_cmd"), 0, "doors wait for the chamber to settle")
    tick(al, 1)
    t.eq(#sentTo(1, "alk_cmd") + #sentTo(2, "alk_cmd"), 1, "doors reopen one at a time")
    tick(al, airlock.OPEN_GAP)
    t.eq(sentTo(1, "alk_cmd")[1].action, "unseal")
    t.eq(sentTo(2, "alk_cmd")[1].action, "unseal")
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

t.case("default: a leak seals only the breached zone, then it settles before reopening", function()
    resetNet()
    local al, ctx = mk()
    local ids = athena(al)
    resetNet()
    al:handleMessage(ids["Athena6-C"], { type = "alk_status", oxygenated = false })
    tick(al, airlock.LOSS_CONFIRM)
    t.eq(lastCmd(ids["Athena6-A"]), "seal")
    t.eq(lastCmd(ids["Athena6-B"]), "seal")
    t.eq(#sentTo(ids["Athena5-A"], "alk_cmd"), 0, "the rest of the station stays open")
    t.eq(#sentTo(ids["Athena2-B"], "alk_cmd"), 0)
    t.eq(#al:containment(), 0, "no lockdown by default")
    t.eq(#actions(ctx.storage, "containment"), 0)
    resetNet()
    al:handleMessage(ids["Athena2-B"], { type = "alk_status", oxygenated = false })
    tick(al, airlock.LOSS_CONFIRM)
    t.eq(#sentTo(ids["Athena5-B"], "alk_cmd"), 0, "one stale reader out of three does not seal a room")
    t.eq(al:areaStates("Athena").commons.north, "pending")
    al:handleMessage(ids["Athena5-B"], { type = "alk_status", oxygenated = false })
    tick(al, airlock.LOSS_CONFIRM)
    t.eq(al:areaStates("Athena").commons.north, "lost")
    t.eq(lastCmd(ids["Athena2-B"]), "seal", "door facing the lost North area seals")
    t.eq(lastCmd(ids["Athena5-B"]), "seal", "every door into the North area seals")
    t.eq(lastCmd(ids["Athena8-B"]), "seal")
    t.eq(#sentTo(ids["Athena2-A"], "alk_cmd"), 0, "other door of that zone stays open")
    resetNet()
    al:handleMessage(ids["Athena6-C"], { type = "alk_status", oxygenated = true })
    al:handleMessage(ids["Athena5-B"], { type = "alk_status", oxygenated = true })
    tick(al, airlock.SETTLE - 1)
    t.eq(#sentTo(ids["Athena6-A"], "alk_cmd"), 0, "repaired zone waits to settle")
    tick(al, airlock.OPEN_GAP + 2)
    t.eq(lastCmd(ids["Athena6-A"]), "unseal")
    t.eq(lastCmd(ids["Athena6-B"]), "unseal")
    t.eq(#sentTo(ids["Athena5-B"], "alk_cmd"), 0, "North stays sealed while it has no oxygen")
end)

t.case("one low detector seals every door of its room; a single blip after a door opens is ignored", function()
    resetNet()
    local al = mk()
    local ids = athena(al)
    resetNet()
    al:handleMessage(ids["Athena-B"], { type = "alk_status", oxygenated = false })
    al:handleMessage(ids["Athena6-A"], { type = "alk_status", oxygenated = false })
    t.eq(#sentTo(ids["Athena7-A"], "alk_cmd"), 0, "a one second flicker is not acted on")
    tick(al, airlock.LOSS_CONFIRM)
    t.eq(lastCmd(ids["Athena7-A"]), "seal", "South confirmed, all its doors seal")
    t.eq(lastCmd(ids["Athena-B"]), "seal")
    al:handleMessage(ids["Athena-B"], { type = "alk_status", oxygenated = true })
    al:handleMessage(ids["Athena6-A"], { type = "alk_status", oxygenated = true })
    resetNet()
    tick(al, airlock.SETTLE + 3 * airlock.OPEN_GAP)
    t.eq(lastCmd(ids["Athena7-A"]), "unseal")
    t.eq(lastCmd(ids["Athena-B"]), "unseal")
    resetNet()
    al:handleMessage(ids["Athena-B"], { type = "alk_status", oxygenated = false })
    tick(al, 3)
    al:handleMessage(ids["Athena-B"], { type = "alk_status", oxygenated = true })
    tick(al, 3)
    local cmds = 0
    for _, m in ipairs(net.sent) do if m.msg.type == "alk_cmd" then cmds = cmds + 1 end end
    t.eq(cmds, 0, "doorway blip right after opening does not reseal")
    local acks = sentTo(ids["Athena-B"], "alk_ack")
    t.eq(acks[#acks].command, "unseal")
end)

t.case("a door that loses air right after opening backs off before trying again", function()
    resetNet()
    local al, ctx = mk()
    local ids = athena(al)
    al:handleMessage(ids["Athena-C"], { type = "alk_status", oxygenated = false })
    tick(al, airlock.LOSS_CONFIRM)
    al:handleMessage(ids["Athena-C"], { type = "alk_status", oxygenated = true })
    tick(al, airlock.SETTLE + 2 * airlock.OPEN_GAP)
    t.eq(al.nodes[tostring(ids["Athena-A"])].sealed, false)
    al:handleMessage(ids["Athena-C"], { type = "alk_status", oxygenated = false })
    tick(al, airlock.GRACE)
    t.eq(al.nodes[tostring(ids["Athena-A"])].sealed, true, "real loss after the grace still seals")
    t.ok(#actions(ctx.storage, "door_retry") >= 1, "the reopen counts as a failed try")
    al:handleMessage(ids["Athena-C"], { type = "alk_status", oxygenated = true })
    tick(al, airlock.SETTLE + 2 * airlock.OPEN_GAP)
    t.eq(al.nodes[tostring(ids["Athena-A"])].sealed, true, "still waiting out the back off")
    tick(al, airlock.BACKOFF)
    t.eq(al.nodes[tostring(ids["Athena-A"])].sealed, false, "tries again after the back off")
end)

t.case("manual lockdown seals the whole station until released", function()
    resetNet()
    local al, ctx = mk()
    local ids = athena(al)
    t.eq(al:stations()[1], "Athena")
    t.ok(not al:lockdown("Nowhere"))
    resetNet()
    t.ok(al:lockdown("Athena", "admin"))
    for name, id in pairs(ids) do
        if not name:match("%-C$") then t.eq(lastCmd(id), "seal", name .. " sealed by lockdown") end
    end
    t.eq(al:containment()[1].manual, true)
    t.eq(#actions(ctx.storage, "lockdown"), 1)
    env.advance(3600)
    resetNet()
    al:containTick()
    t.eq(#net.sent, 0, "lockdown never clears by itself")
    local al2 = mk(ctx.storage)
    al2:load()
    t.eq(al2:containment()[1].manual, true, "lockdown survives a restart")
    t.ok(al:releaseContainment("Athena", "admin"))
    tick(al, 16 * airlock.OPEN_GAP + 2)
    t.eq(lastCmd(ids["Athena5-A"]), "unseal")
end)

t.case("opt-in containment: one leak closes every door, the leaking zone stays shut", function()
    resetNet()
    local al, ctx = mk(nil, { containment = true })
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
    tick(al, 6 + 16 * airlock.OPEN_GAP)
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
    tick(al, airlock.SETTLE + 2 * airlock.OPEN_GAP)
    t.eq(lastCmd(ids["Athena6-A"]), "unseal")
    t.eq(lastCmd(ids["Athena6-B"]), "unseal")
    t.eq(#al:containment(), 0)
    t.eq(#actions(ctx.storage, "containment_clear"), 1)
end)

t.case("opt-in containment: a door detector losing air seals that side, settles, and repeated trips hold", function()
    resetNet()
    local al, ctx = mk(nil, { containment = true })
    local ids = athena(al)
    resetNet()
    al:handleMessage(ids["Athena2-B"], { type = "alk_status", oxygenated = false })
    t.eq(lastCmd(ids["Athena5-A"]), "seal", "far doors close too")
    resetNet()
    tick(al, airlock.CONTAIN_MIN + 16 * airlock.OPEN_GAP)
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
    tick(al, 16 * airlock.OPEN_GAP + 2)
    t.eq(lastCmd(ids["Athena5-A"]), "unseal")
    t.eq(#actions(ctx.storage, "containment_release"), 1)
    local al2 = mk(ctx.storage)
    al2:load()
    t.eq(#al2:containment(), 0, "release persisted")
end)

t.case("opt-in containment survives a restart and is off by default", function()
    resetNet()
    local al, ctx = mk(nil, { containment = true })
    local ids = athena(al)
    al:handleMessage(ids["Athena3-C"], { type = "alk_status", oxygenated = false })
    local al2 = mk(ctx.storage)
    al2:load()
    t.eq(al2:containment()[1].cause, "Athena3-C")
    t.eq(al2:desired(al2.nodes[tostring(ids["Athena7-A"])]), true, "reloaded containment keeps doors shut")
    resetNet()
    local off = mk()
    local ids2 = athena(off)
    resetNet()
    off:handleMessage(ids2["Athena6-C"], { type = "alk_status", oxygenated = false })
    tick(off, airlock.LOSS_CONFIRM)
    t.eq(#off:containment(), 0)
    t.eq(lastCmd(ids2["Athena6-A"]), "seal", "group rule still works")
    t.eq(#sentTo(ids2["Athena5-A"], "alk_cmd"), 0, "other groups untouched")
end)

t.case("a door interlocked by its sensor stays sealed and seals its zone partner", function()
    resetNet()
    local al = mk()
    local ids = athena(al)
    resetNet()
    al:handleMessage(ids["Athena7-A"], { type = "alk_status", name = "Athena7-A", role = "door", oxygenated = true, sealed = true, interlock = true })
    local acks = sentTo(ids["Athena7-A"], "alk_ack")
    t.eq(acks[#acks].command, "seal", "interlocked door is told to stay sealed")
    t.eq(#sentTo(ids["Athena7-B"], "alk_cmd"), 0, "a fresh interlock waits to be confirmed before it moves the partner")
    tick(al, airlock.LOSS_CONFIRM)
    t.eq(lastCmd(ids["Athena7-B"]), "seal", "zone partner seals although the server never heard Athena7-C")
    t.eq(al:areaStates("Athena").zones.Athena7, "lost")
    t.eq(#sentTo(ids["Athena5-A"], "alk_cmd"), 0, "nothing else moves")
    resetNet()
    al:handleMessage(ids["Athena7-A"], { type = "alk_status", name = "Athena7-A", role = "door", oxygenated = true, sealed = true })
    tick(al, 3 * airlock.OPEN_GAP)
    t.eq(al.nodes[tostring(ids["Athena7-A"])].sealed, false, "reopens when the interlock clears")
    t.eq(al.nodes[tostring(ids["Athena7-B"])].sealed, false)
    resetNet()
    al:handleMessage(ids["Athena7-A"], { type = "alk_status", name = "Athena7-A", role = "door", oxygenated = true, sealed = true, interlock = true })
    al:setManual(ids["Athena7-A"], "unseal")
    local cmd = sentTo(ids["Athena7-A"], "alk_cmd")
    t.eq(cmd[#cmd].action, "unseal", "manual unseal still wins")
    t.eq(cmd[#cmd].force, true, "and tells the door to override its interlock")
end)

t.case("event log records reports, commands with reasons and area changes; bundle includes door logs", function()
    resetNet()
    local al = mk()
    local ids = athena(al)
    al:handleMessage(ids["Athena6-C"], { type = "alk_status", oxygenated = false })
    tick(al, airlock.LOSS_CONFIRM)
    local text = table.concat(al.events, "\n")
    t.ok(text:find("rx Athena6-C status o2=false", 1, true), "report logged")
    t.ok(text:find("cmd Athena6-A seal (hallway Athena6: no oxygen)", 1, true), "command logged with its reason")
    t.ok(text:find("area zone Athena6 holding -> pending", 1, true) and text:find("area zone Athena6 pending -> lost", 1, true), "area changes logged")
    resetNet()
    t.eq(al:requestLogs(), 24)
    t.eq(#sentTo(ids["Athena6-A"], "alk_dump"), 1)
    local nonce = sentTo(ids["Athena6-A"], "alk_dump")[1].nonce
    t.ok(al:handleMessage(ids["Athena6-A"], { type = "alk_log", nonce = nonce, text = "  12.0 boot Athena6-A" }))
    t.ok(not al:handleMessage(ids["Athena6-B"], { type = "alk_log", nonce = "wrong", text = "x" }), "stale dump ignored")
    local b = al:logBundle("server MARS #4 r40")
    t.ok(b:find("ZELNET AIRLOCK LOG BUNDLE", 1, true))
    t.ok(b:find("Athena6-A", 1, true) and b:find("hallway Athena6: no oxygen", 1, true), "airlock table shows why each door is sealed")
    t.ok(b:find("== Athena6-A (#" .. ids["Athena6-A"] .. ") local log", 1, true) and b:find("boot Athena6-A", 1, true), "door log included")
    t.ok(b:find("Athena6-B (#" .. ids["Athena6-B"] .. ") sent no log", 1, true), "missing door log noted")
end)

t.case("lockdown reaches every door, including doors that were already sealed", function()
    resetNet()
    local al = mk()
    local ids = athena(al)
    al:handleMessage(ids["Athena6-C"], { type = "alk_status", oxygenated = false })
    tick(al, airlock.LOSS_CONFIRM)
    resetNet()
    al:lockdown("Athena", "admin")
    local c = sentTo(ids["Athena6-A"], "alk_cmd")
    t.eq(#c, 1, "already sealed door still told")
    t.eq(c[1].lockdown, true)
    t.eq(sentTo(ids["Athena5-A"], "alk_cmd")[1].lockdown, true)
    al:handleMessage(ids["Athena5-A"], { type = "alk_hello", oxygenated = true, sealed = true })
    local acks = sentTo(ids["Athena5-A"], "alk_ack")
    t.eq(acks[#acks].lockdown, true, "heartbeat answers carry the lockdown")
    resetNet()
    al:releaseContainment("Athena", "admin")
    t.eq(sentTo(ids["Athena6-A"], "alk_cmd")[1].lockdown, nil, "release clears it on every door")
end)

t.case("signed updates: one door at a time, served in chunks, never during lockdown", function()
    resetNet()
    local crypto = need("crypto")
    local key = crypto.newKey()
    local al = mk(nil, { airlockKey = key })
    local prog = al:program()
    t.ok(prog and prog.ver and prog.chunks >= 1, "server knows the airlock program")
    local ids = athena(al)
    resetNet()
    al:handleMessage(ids["Athena-A"], { type = "alk_hello", oxygenated = true, sealed = false, ver = "old", keyed = true })
    local offer = sentTo(ids["Athena-A"], "alk_update")[1]
    t.ok(offer, "out of date door gets an offer")
    t.eq(offer.mac, crypto.hmac(key, "alk_update|" .. offer.ver .. "|" .. offer.size .. "|" .. table.concat(offer.hashes, ",")))
    t.eq(#offer.hashes, offer.chunks)
    t.ok(offer.ver ~= "dev" and #offer.ver == 8, "the build stamps a version into the program")
    al:handleMessage(ids["Athena-B"], { type = "alk_hello", oxygenated = true, sealed = false, ver = "old", keyed = true })
    t.eq(#sentTo(ids["Athena-B"], "alk_update"), 0, "only one door updates at a time")
    al:handleMessage(ids["Athena2-A"], { type = "alk_hello", oxygenated = true, sealed = false, ver = "old" })
    t.eq(#sentTo(ids["Athena2-A"], "alk_update"), 0, "doors without the key get no offer")
    t.ok(al:handleMessage(ids["Athena-A"], { type = "alk_get", ver = offer.ver, i = 1 }))
    local ch = sentTo(ids["Athena-A"], "alk_chunk")[1]
    t.eq(ch.data, prog.text:sub(1, airlock.CHUNK))
    t.ok(not al:handleMessage(ids["Athena-A"], { type = "alk_get", ver = offer.ver, i = 999 }))
    local parts = {}
    for i = 1, offer.chunks do
        al:handleMessage(ids["Athena-A"], { type = "alk_get", ver = offer.ver, i = i })
        local got = sentTo(ids["Athena-A"], "alk_chunk")
        parts[i] = got[#got].data
    end
    t.eq(table.concat(parts), prog.text, "chunks rebuild the program")
    t.eq(crypto.sha256(parts[1]), offer.hashes[1])
    al:handleMessage(ids["Athena-A"], { type = "alk_hello", oxygenated = true, sealed = false, ver = prog.ver, keyed = true })
    t.eq(al.updating, nil, "done once the door reports the new version")
    al:handleMessage(ids["Athena-B"], { type = "alk_hello", oxygenated = true, sealed = false, ver = "old", keyed = true })
    t.eq(#sentTo(ids["Athena-B"], "alk_update"), 1, "next door goes after the first finished")
    al.updating = nil
    al:lockdown("Athena", "admin")
    resetNet()
    al:handleMessage(ids["Athena3-A"], { type = "alk_hello", oxygenated = true, sealed = true, ver = "old", keyed = true })
    t.eq(#sentTo(ids["Athena3-A"], "alk_update"), 0, "no updates during lockdown")
end)

t.case("upload falls back to dpaste and reports both refusals", function()
    local posts = {}
    local answers = {}
    _G.http = { post = function(url, body)
        posts[#posts + 1] = { url = url, body = body }
        local a = answers[url]
        if not a then return nil end
        return { readAll = function() return a end, close = function() end }
    end }
    _G.textutils = _G.textutils or {}
    _G.textutils.urlEncode = _G.textutils.urlEncode or function(s) return s end
    answers["https://paste.rs/"] = "https://paste.rs/Ab3"
    t.eq(airlock.upload("hello"), "https://paste.rs/Ab3")
    answers["https://paste.rs/"] = nil
    answers["https://dpaste.com/api/v2/"] = "https://dpaste.com/XYZ\n"
    t.eq(airlock.upload("hello"), "https://dpaste.com/XYZ.txt")
    answers["https://dpaste.com/api/v2/"] = nil
    local url, err = airlock.upload("hello")
    t.eq(url, nil)
    t.ok(err:find("paste.rs", 1, true) and err:find("dpaste.com", 1, true))
    _G.http = nil
end)

t.case("an area that keeps losing air must hold longer before doors open into it", function()
    resetNet()
    local al = mk()
    local ids = athena(al)
    local hub = { "Athena-A", "Athena2-A", "Athena3-A", "Athena4-A" }
    local function hubAir(v)
        for _, n in ipairs(hub) do al:handleMessage(ids[n], { type = "alk_status", oxygenated = v }) end
    end
    for _ = 1, 3 do
        hubAir(false)
        tick(al, airlock.LOSS_CONFIRM + 1)
        hubAir(true)
        tick(al, 4)
    end
    t.ok(table.concat(al.events, "\n"):find("area area hub UNSTABLE", 1, true), "logged as unstable")
    t.ok(al:logBundle():find("area hub=", 1, true) and al:logBundle():find("UNSTABLE(3 drops)", 1, true))
    tick(al, airlock.SETTLE + 2)
    t.eq(al:areaStates("Athena").commons.hub, "pending", "8 seconds is no longer enough")
    tick(al, airlock.UNSTABLE_SETTLE)
    t.eq(al:areaStates("Athena").commons.hub, "holding", "30 seconds of steady air is")
end)

local ROOM_OF = {
    ["Athena-A"] = "Hub", ["Athena2-A"] = "Hub", ["Athena3-A"] = "Hub", ["Athena4-A"] = "Hub",
    ["Athena2-B"] = "North", ["Athena5-B"] = "North", ["Athena8-B"] = "North",
    ["Athena-B"] = "South", ["Athena6-A"] = "South", ["Athena7-A"] = "South",
    ["Athena3-B"] = "West", ["Athena6-B"] = "West", ["Athena8-A"] = "West",
    ["Athena4-B"] = "East", ["Athena5-A"] = "East", ["Athena7-B"] = "East",
}

local function roomed(al)
    local ids = {}
    local id = 100
    for _, g in ipairs({ "Athena", "Athena2", "Athena3", "Athena4", "Athena5", "Athena6", "Athena7", "Athena8" }) do
        for _, L in ipairs({ "A", "B", "C" }) do
            id = id + 1
            local name = g .. "-" .. L
            ids[name] = id
            al:handleMessage(id, { type = "alk_register", name = name, role = L == "C" and "sensor" or "door", room = ROOM_OF[name], oxygenated = true, sealed = false })
        end
    end
    for _, room in ipairs({ "Hub", "North", "South", "East", "West" }) do
        id = id + 1
        ids[room] = id
        al:handleMessage(id, { type = "alk_register", name = room, role = "room", room = room, oxygenated = true })
    end
    return ids
end

t.case("room sensors are the authority for their rooms", function()
    resetNet()
    local al = mk()
    local ids = roomed(al)
    t.eq(al:roomKeyOf(al.nodes[tostring(ids["Athena7-A"])]), "south")
    t.eq(al:stationOfRec(al.nodes[tostring(ids["South"])]), "Athena", "room sensors join the station")
    local names = al:roomNames()
    t.eq(table.concat(names, ","), "East,Hub,North,South,West")
    resetNet()
    al:handleMessage(ids["Athena7-A"], { type = "alk_status", oxygenated = false, sealed = false })
    tick(al, airlock.LOSS_CONFIRM + 1)
    t.eq(#sentTo(ids["Athena6-A"], "alk_cmd"), 0, "one door detector disagreeing with the South sensor changes nothing")
    t.eq(al:areaStates("Athena").commons.south, "holding")
    t.eq(al:areaStates("Athena").sources.south, "sensor")
    al:handleMessage(ids["Athena7-A"], { type = "alk_status", oxygenated = true, sealed = false })
    resetNet()
    al:handleMessage(ids["South"], { type = "alk_status", oxygenated = false })
    tick(al, airlock.LOSS_CONFIRM)
    for _, n in ipairs({ "Athena-B", "Athena6-A", "Athena7-A" }) do t.eq(lastCmd(ids[n]), "seal", n .. " seals when the South sensor reads no oxygen") end
    t.eq(#sentTo(ids["Athena-A"], "alk_cmd"), 0, "hub side untouched")
    local c = sentTo(ids["Athena7-A"], "alk_cmd")
    t.eq(c[#c].why, "room South: no oxygen", "the door is told why")
    resetNet()
    al:handleMessage(ids["South"], { type = "alk_status", oxygenated = true })
    tick(al, airlock.SETTLE + 3 * airlock.OPEN_GAP + 1)
    for _, n in ipairs({ "Athena-B", "Athena6-A", "Athena7-A" }) do t.eq(lastCmd(ids[n]), "unseal", n .. " reopens") end
end)

t.case("a door held by its room sensor does not mark its hallway as lost", function()
    resetNet()
    local al = mk()
    local ids = roomed(al)
    al:handleMessage(ids["Athena-B"], { type = "alk_status", oxygenated = false, sealed = true, interlock = true, ilHall = false, ilRoom = true })
    tick(al, airlock.LOSS_CONFIRM + 1)
    local st = al:areaStates("Athena")
    t.eq(st.zones.Athena, "holding", "hallway Athena still holds")
    t.eq(st.commons.south, "lost", "South counts as lost from the interlock")
    t.eq(al.nodes[tostring(ids["Athena-A"])].sealed, false, "the hub side door stays open")
end)

t.case("without an online room sensor the room falls back to its doors' detectors", function()
    resetNet()
    local al = mk()
    local ids = roomed(al)
    al.nodes[tostring(ids["North"])].online = false
    t.eq(al:areaStates("Athena").sources.north, "doors")
    resetNet()
    al:handleMessage(ids["Athena2-B"], { type = "alk_status", oxygenated = false, sealed = false })
    al:handleMessage(ids["Athena5-B"], { type = "alk_status", oxygenated = false, sealed = false })
    tick(al, airlock.LOSS_CONFIRM)
    t.eq(lastCmd(ids["Athena8-B"]), "seal", "two of three North doors read no oxygen")
end)

t.case("door rooms come from setup, can be set from the console, and the list is shared", function()
    resetNet()
    local al = mk()
    local ids = roomed(al)
    local acks = sentTo(ids["Athena7-A"], "alk_ack")
    t.eq(acks[#acks].room, "South")
    t.ok(table.concat(acks[#acks].roomList, ","):find("South", 1, true))
    resetNet()
    t.ok(al:setRoom(ids["Athena7-A"], "Galley"))
    local c = sentTo(ids["Athena7-A"], "alk_cmd")
    t.eq(c[#c].room, "Galley", "the door is told its new room")
    al:handleMessage(ids["Athena7-A"], { type = "alk_status", room = "South", oxygenated = true, sealed = false })
    t.eq(al.nodes[tostring(ids["Athena7-A"])].room, "Galley", "a room set on the console wins")
    t.eq(al:roomKeyOf(al.nodes[tostring(ids["Athena7-A"])]), "galley")
    t.ok(table.concat(al:roomNames(), ","):find("Galley", 1, true))
    t.eq(select(2, al:setRoom(ids["Athena7-C"], "x")), "Only doors and security doors open into rooms.")
end)

t.case("security doors lock and unlock from the console and close when a room loses air", function()
    resetNet()
    local al = mk()
    local ids = roomed(al)
    al:handleMessage(500, { type = "alk_register", name = "Vault", role = "security", rooms = { "North", "East" }, oxygenated = true, sealed = false })
    local vault = al.nodes["500"]
    t.eq(vault.role, "security")
    t.eq(al:stationOfRec(vault), "Athena")
    t.eq(vault.sealed, false, "open while unlocked")
    resetNet()
    al:setLocked(500, true)
    t.eq(lastCmd(500), "seal")
    al:setLocked(500, false)
    t.eq(lastCmd(500), "unseal")
    resetNet()
    al:handleMessage(ids["East"], { type = "alk_status", oxygenated = false })
    tick(al, airlock.GRACE)
    t.eq(lastCmd(500), "seal", "closes when East loses air")
    t.eq(sentTo(500, "alk_cmd")[1].why, "room East: no oxygen")
    al:handleMessage(ids["East"], { type = "alk_status", oxygenated = true })
    tick(al, airlock.SETTLE + 1)
    t.eq(lastCmd(500), "unseal", "reopens once East holds air")
    al:lockdown("Athena", "admin")
    t.eq(lastCmd(500), "seal", "lockdown closes it")
    t.eq(sentTo(ids["South"], "alk_cmd")[#sentTo(ids["South"], "alk_cmd")].lockdown, true, "room sensors hear about the lockdown")
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
