package.path = "./?.lua;" .. package.path
local env = require("tests.fakecc").install({ id = 4 })
local need = require("tools.devload").make(".")
local util = need("util")
local airlock = need("airlock")
local navmap = need("navmap")
local t = require("tests.tiny")

_G.rednet = { open = function() end, send = function() end, broadcast = function() end }

local DETECT = 1
local RESEAL = 3
local BLIP = 1.5
local ACT = 0.5
local LATENCY = 0.1
local RETRY_EVERY, RETRY_MAX = 1, 5
local HEARTBEAT, PEER_EVERY, PEER_STALE = 30, 10, 60
local PEER_DELAY, OPEN_GRACE, FAILSAFE, PEER_CONFIRM = 5, 10, 5, 3

local function world(opts)
    opts = opts or {}
    local detect = opts.detect or function() return DETECT end
    local reseal = opts.reseal or function() return RESEAL end
    local blip = opts.blip or BLIP
    local flicker = opts.flicker or 0
    local drop = opts.drop or 0
    local ctx = { cfg = { realm = "MARS", airlocks = true }, log = util.newLogger(50) }
    local al = airlock.new(ctx)
    local W = { now = 0, breach = {}, areas = {}, doors = {}, sensors = {}, nodes = {}, cmds = {}, inbox = {}, al = al, sent = 0, lost = 0 }
    local function delivered()
        W.sent = W.sent + 1
        if drop > 0 and math.random() < drop then
            W.lost = W.lost + 1
            return false
        end
        return true
    end
    local commonOf = {}
    for _, c in ipairs(navmap.COMMONS) do
        W.areas[c.id] = { o2 = true }
        for _, d in ipairs(c.doors) do commonOf[d] = c.id end
    end
    for _, z in ipairs(navmap.ZONES) do W.areas[z.group] = { o2 = true } end
    local all = {}
    local id = 0
    for _, z in ipairs(navmap.ZONES) do
        for _, L in ipairs({ "A", "B", "C" }) do
            id = id + 1
            local name = z.group .. "-" .. L
            local n = { id = id, name = name, zone = z.group, far = commonOf[name], sensor = L == "C", open = true,
                beatAt = math.random() * HEARTBEAT, peerAt = math.random() * PEER_EVERY }
            W.nodes[id] = n
            W.nodes[name] = n
            all[#all + 1] = n
            if n.sensor then W.sensors[z.group] = n else W.doors[#W.doors + 1] = n end
        end
    end
    local function interlocked(n)
        local p = n.peer
        if p == nil or not p.low or W.now - p.at >= PEER_STALE then return false end
        local afterOpen = n.unsealedAt ~= nil and p.since >= n.unsealedAt and p.since - n.unsealedAt < OPEN_GRACE
        return not afterOpen or W.now - p.since >= PEER_CONFIRM
    end
    function W.reading(n)
        if n.sensor then
            local z = W.areas[n.zone]
            if z.flickerUntil and W.now < z.flickerUntil then return false end
            return z.o2
        end
        if n.openedAt and W.now - n.openedAt < blip then return false end
        local a = W.areas[n.far]
        if a.flickerUntil and W.now < a.flickerUntil then return false end
        return a.o2
    end
    local function sealedNow(n)
        if n.pending then return not n.pending.open end
        return not n.open
    end
    local function send(n, kind, retry)
        local msg = { type = kind, name = n.name, role = n.sensor and "sensor" or "door", oxygenated = n.reading,
            sealed = (not n.sensor) and sealedNow(n) or nil, interlock = (not n.sensor) and interlocked(n) or nil, reqID = tostring(W.now) .. n.name }
        if retry then n.retry = { reqID = msg.reqID, tries = (n.retry and n.retry.tries or 0) + 1, at = W.now + RETRY_EVERY } end
        if delivered() then al:handleMessage(n.id, msg) end
    end
    local function applyAction(n, action, force)
        if n.sensor then return end
        if action == "unseal" and interlocked(n) and not force and sealedNow(n) then
            n.reportDue = true
            return
        end
        if action == "unseal" and sealedNow(n) then n.unsealedAt = W.now end
        n.pending = { at = W.now + ACT, open = action == "unseal" }
    end
    al.rsend = function(_, nid, msg)
        local n = W.nodes[tonumber(nid)]
        if not n then return true end
        if msg.type == "alk_cmd" then W.cmds[#W.cmds + 1] = { at = W.now, name = n.name, action = msg.action } end
        if delivered() then W.inbox[#W.inbox + 1] = { at = W.now + LATENCY, n = n, msg = msg } end
        return true
    end
    local function broadcastPeer(s)
        for _, L in ipairs({ "A", "B" }) do
            local d = W.nodes[s.zone .. "-" .. L]
            if delivered() then
                local was = interlocked(d)
                local low = not s.reading
                d.peer = { low = low, at = W.now, since = (low and d.peer and d.peer.low) and d.peer.since or W.now }
                if was ~= interlocked(d) then d.reportDue = true end
                local justOpened = d.unsealedAt and W.now - d.unsealedAt < OPEN_GRACE
                if d.peer.low and not sealedNow(d) and not justOpened then
                    d.peerSealAt = d.peerSealAt or (W.now + PEER_DELAY)
                elseif not d.peer.low then
                    d.peerSealAt = nil
                end
            end
        end
    end
    for _, n in ipairs(all) do
        n.reading = W.reading(n)
        send(n, "alk_register")
    end
    function W.volumes()
        local parent = {}
        local function find(a)
            while parent[a] and parent[a] ~= a do a = parent[a] end
            return a
        end
        for k in pairs(W.areas) do parent[k] = k end
        for _, d in ipairs(W.doors) do
            if d.open then parent[find(d.zone)] = find(d.far) end
        end
        local vols = {}
        for k in pairs(W.areas) do
            local r = find(k)
            vols[r] = vols[r] or {}
            table.insert(vols[r], k)
        end
        return vols
    end
    local function physics()
        for _, d in ipairs(W.doors) do
            if d.pending and W.now >= d.pending.at then
                local opening = d.pending.open and not d.open
                if opening then d.openedAt = W.now end
                d.open = d.pending.open
                if opening and flicker > 0 then
                    for _, members in pairs(W.volumes()) do
                        local hit = false
                        for _, a in ipairs(members) do if a == d.zone then hit = true end end
                        if hit then
                            for _, a in ipairs(members) do W.areas[a].flickerUntil = W.now + flicker end
                        end
                    end
                end
                d.pending = nil
            end
        end
        for _, members in pairs(W.volumes()) do
            local breached, low = false, false
            for _, a in ipairs(members) do
                if W.breach[a] then breached = true end
                if not W.areas[a].o2 then low = true end
            end
            table.sort(members)
            local key = table.concat(members, ",")
            if breached then
                for _, a in ipairs(members) do
                    local ar = W.areas[a]
                    if not ar.badAt then ar.badAt, ar.detectIn = W.now, detect() end
                    if W.now - ar.badAt >= ar.detectIn then ar.o2 = false end
                end
            else
                for _, a in ipairs(members) do W.areas[a].badAt = nil end
                if low then
                    local first = W.areas[members[1]]
                    if first.goodKey ~= key then first.goodKey, first.goodAt, first.resealIn = key, W.now, reseal() end
                    if W.now - first.goodAt >= first.resealIn then
                        for _, a in ipairs(members) do W.areas[a].o2 = true end
                    end
                end
            end
        end
    end
    local function programs()
        local due = W.inbox
        W.inbox = {}
        for _, item in ipairs(due) do
            if item.at > W.now then
                W.inbox[#W.inbox + 1] = item
            else
                local n, msg = item.n, item.msg
                if msg.type == "alk_ack" then
                    if n.retry and n.retry.reqID == msg.reqID then n.retry = nil end
                    applyAction(n, msg.command, msg.force)
                elseif msg.type == "alk_cmd" then
                    applyAction(n, msg.action, msg.force)
                    n.reportDue = true
                end
            end
        end
        for _, n in ipairs(all) do
            local r = W.reading(n)
            if r ~= n.reading then
                n.reading = r
                n.reportDue = true
                if n.sensor then
                    broadcastPeer(n)
                    n.peerAt = W.now + 1
                end
                if not n.sensor then
                    if not r and not sealedNow(n) then
                        local justOpened = n.unsealedAt and W.now - n.unsealedAt < OPEN_GRACE
                        n.failAt = W.now + FAILSAFE + (justOpened and OPEN_GRACE or 0)
                    elseif r then
                        n.failAt = nil
                    end
                end
            end
            if n.failAt and W.now >= n.failAt then
                n.failAt = nil
                if not n.reading and not sealedNow(n) then
                    n.pending = { at = W.now + ACT, open = false }
                    n.reportDue = true
                end
            end
            if n.peerSealAt and W.now >= n.peerSealAt then
                n.peerSealAt = nil
                if not sealedNow(n) then
                    n.pending = { at = W.now + ACT, open = false }
                    n.reportDue = true
                end
            end
            if n.sensor and W.now >= n.peerAt then
                n.peerAt = W.now + PEER_EVERY
                broadcastPeer(n)
            end
            if n.reportDue then
                n.reportDue = false
                send(n, "alk_status", true)
            elseif n.retry and W.now >= n.retry.at then
                if n.retry.tries >= RETRY_MAX then n.retry = nil else send(n, "alk_status", true) end
            end
            if W.now >= n.beatAt then
                n.beatAt = W.now + HEARTBEAT
                send(n, "alk_hello")
            end
        end
    end
    function W.step(dt)
        W.now = W.now + dt
        env.advance(dt)
        physics()
        programs()
        if math.floor(W.now * 10 + 0.5) % 10 == 0 then al:containTick() end
    end
    function W.run(seconds)
        for _ = 1, math.floor(seconds / 0.25) do W.step(0.25) end
    end
    function W.cmdsSince(at)
        local n = 0
        for _, c in ipairs(W.cmds) do if c.at >= at then n = n + 1 end end
        return n
    end
    function W.openState()
        local out = {}
        for _, d in ipairs(W.doors) do out[d.name] = d.open end
        return out
    end
    function W.areaStates()
        return al:areaStates("Athena")
    end
    return W
end

local SOUTH = { ["Athena-B"] = true, ["Athena6-A"] = true, ["Athena7-A"] = true }
local NORTH = { ["Athena2-B"] = true, ["Athena5-B"] = true, ["Athena8-B"] = true }
local HUB = { ["Athena-A"] = true, ["Athena2-A"] = true, ["Athena3-A"] = true, ["Athena4-A"] = true }

local function expectShut(W, shut, label)
    for name, open in pairs(W.openState()) do
        t.eq(open, not shut[name], label .. " " .. name .. (shut[name] and " sealed" or " open"))
    end
end

local function exposure(W, zone, seconds)
    local worst = 0
    local door = { W.nodes[zone .. "-A"], W.nodes[zone .. "-B"] }
    local since = nil
    for _ = 1, math.floor(seconds / 0.25) do
        W.step(0.25)
        local bad = not W.areas[zone].o2 and (door[1].open or door[2].open)
        if bad then since = since or W.now else since = nil end
        if since and W.now - since > worst then worst = W.now - since end
    end
    return worst
end

t.case("breaking a block in South settles with only the South doors shut", function()
    local W = world()
    W.run(20)
    W.breach.south = true
    W.run(240)
    expectShut(W, SOUTH, "south")
    t.eq(W.cmdsSince(W.now - 90), 0, "no door has moved for 90 seconds")
    t.eq(W.areaStates().commons.hub, "holding", "hub reports sealed while South is breached")
    W.breach.south = nil
    W.run(120)
    expectShut(W, {}, "repaired")
    t.eq(W.cmdsSince(W.now - 40), 0, "quiet after repair")
end)

t.case("a North breach leaves the hub sealed", function()
    local W = world()
    W.run(20)
    W.breach.north = true
    W.run(240)
    expectShut(W, NORTH, "north")
    local st = W.areaStates()
    t.eq(st.commons.hub, "holding")
    t.eq(st.commons.north, "lost")
end)

t.case("a breach in hallway zone 7 seals Athena7-A and B and keeps South and East sealed", function()
    local W = world()
    W.run(20)
    W.breach.Athena7 = true
    W.run(240)
    expectShut(W, { ["Athena7-A"] = true, ["Athena7-B"] = true }, "zone 7")
    local st = W.areaStates()
    t.eq(st.commons.south, "holding")
    t.eq(st.commons.east, "holding")
    t.eq(st.zones.Athena7, "lost")
    t.eq(exposure(W, "Athena7", 120), 0, "zone 7 never opens to South or East while it has no air")
end)

t.case("a breach in zone 6 seals only Athena6, and the hub breach only the hub doors", function()
    local W = world()
    W.run(20)
    W.breach.Athena6 = true
    W.run(240)
    expectShut(W, { ["Athena6-A"] = true, ["Athena6-B"] = true }, "zone 6")
    local H = world()
    H.run(20)
    H.breach.hub = true
    H.run(240)
    expectShut(H, HUB, "hub")
end)

t.case("lossy radio: a fifth of all messages lost, hallways and rooms still isolate", function()
    math.randomseed(11)
    local cases = {
        { breach = "Athena7", shut = { ["Athena7-A"] = true, ["Athena7-B"] = true } },
        { breach = "Athena5", shut = { ["Athena5-A"] = true, ["Athena5-B"] = true } },
        { breach = "north", shut = NORTH },
        { breach = "south", shut = SOUTH },
    }
    for _, c in ipairs(cases) do
        for round = 1, 3 do
            local W = world({ drop = 0.2, detect = function() return 1 + math.random() * 2 end, reseal = function() return 4 + math.random() * 4 end, blip = 3 })
            W.run(30)
            W.breach[c.breach] = true
            W.run(420)
            expectShut(W, c.shut, c.breach .. " round " .. round)
            t.eq(W.cmdsSince(W.now - 120), 0, c.breach .. " round " .. round .. " settled")
            if c.breach ~= "hub" then t.eq(W.areaStates().commons.hub, "holding", c.breach .. " round " .. round .. " hub sealed") end
            W.breach[c.breach] = nil
            W.run(240)
            expectShut(W, {}, c.breach .. " round " .. round .. " repaired")
        end
    end
end)

t.case("lossy radio: a breached hallway is never left open to vacuum for long", function()
    math.randomseed(5)
    for round = 1, 5 do
        local W = world({ drop = 0.2, detect = function() return 1 + math.random() * 2 end, reseal = function() return 4 + math.random() * 4 end, blip = 3 })
        W.run(30)
        W.breach.Athena7 = true
        local worst = exposure(W, "Athena7", 300)
        t.ok(worst <= 15, "round " .. round .. " zone 7 open to vacuum for " .. worst .. "s")
    end
end)

t.case("harsh timing: slow detectors, long doorway blips and merge flicker still settle", function()
    math.randomseed(7)
    for round = 1, 3 do
        for _, c in ipairs({ { b = "south", shut = SOUTH }, { b = "Athena7", shut = { ["Athena7-A"] = true, ["Athena7-B"] = true } } }) do
            local W = world({ detect = function() return 1 + math.random() * 2 end, reseal = function() return 4 + math.random() * 4 end, blip = 3, flicker = 1 })
            W.run(20)
            W.breach[c.b] = true
            W.run(400)
            expectShut(W, c.shut, "harsh " .. c.b .. " round " .. round)
            t.eq(W.cmdsSince(W.now - 120), 0, "harsh " .. c.b .. " round " .. round .. " settled")
        end
    end
end)

t.case("worst case: merge flicker and lost messages together still isolate only the breach", function()
    for _, c in ipairs({ { b = "Athena7", shut = { ["Athena7-A"] = true, ["Athena7-B"] = true } }, { b = "Athena5", shut = { ["Athena5-A"] = true, ["Athena5-B"] = true } }, { b = "south", shut = SOUTH }, { b = "north", shut = NORTH } }) do
        for seed = 1, 3 do
            math.randomseed(seed)
            local W = world({ drop = 0.1, detect = function() return 1 + math.random() * 2 end, reseal = function() return 4 + math.random() * 4 end, blip = 3, flicker = 1 })
            W.run(30)
            W.breach[c.b] = true
            W.run(420)
            expectShut(W, c.shut, "worst " .. c.b .. " seed " .. seed)
            t.eq(W.cmdsSince(W.now - 120), 0, "worst " .. c.b .. " seed " .. seed .. " settled")
        end
    end
end)

t.finish()
