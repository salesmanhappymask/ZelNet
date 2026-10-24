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

local function world(opts)
    opts = opts or {}
    local detect = opts.detect or function() return DETECT end
    local reseal = opts.reseal or function() return RESEAL end
    local blip = opts.blip or BLIP
    local flicker = opts.flicker or 0
    local ctx = { cfg = { realm = "MARS", airlocks = true }, log = util.newLogger(50) }
    local al = airlock.new(ctx)
    local W = { now = 0, breach = {}, areas = {}, doors = {}, nodes = {}, cmds = {}, al = al }
    local commonOf = {}
    for _, c in ipairs(navmap.COMMONS) do
        W.areas[c.id] = { o2 = true }
        for _, d in ipairs(c.doors) do commonOf[d] = c.id end
    end
    for _, z in ipairs(navmap.ZONES) do W.areas[z.group] = { o2 = true } end
    local id = 0
    for _, z in ipairs(navmap.ZONES) do
        for _, L in ipairs({ "A", "B", "C" }) do
            id = id + 1
            local name = z.group .. "-" .. L
            local n = { id = id, name = name, zone = z.group, far = commonOf[name], sensor = L == "C", open = true }
            W.nodes[id] = n
            W.nodes[name] = n
            if not n.sensor then W.doors[#W.doors + 1] = n end
        end
    end
    al.rsend = function(_, nid, msg)
        local n = W.nodes[tonumber(nid)]
        if not n or n.sensor then return true end
        local action = msg.type == "alk_cmd" and msg.action or (msg.type == "alk_ack" and msg.command) or nil
        if action then
            if msg.type == "alk_cmd" then W.cmds[#W.cmds + 1] = { at = W.now, name = n.name, action = action } end
            n.pending = { at = W.now + ACT, open = action == "unseal" }
        end
        return true
    end
    function W.reading(n)
        if n.sensor then
            local z = W.areas[n.zone]
            if z.flickerUntil and W.now < z.flickerUntil then return false end
            return z.o2
        end
        if n.openedAt and W.now - n.openedAt < blip then return false end
        local a = n.sensor and W.areas[n.zone] or W.areas[n.far]
        if a.flickerUntil and W.now < a.flickerUntil then return false end
        return W.areas[n.far].o2
    end
    function W.report(n, kind)
        n.last = W.reading(n)
        al:handleMessage(n.id, { type = kind, name = n.name, role = n.sensor and "sensor" or "door", oxygenated = n.last, sealed = not n.sensor and not n.open or nil })
    end
    for i = 1, id do W.report(W.nodes[i], "alk_register") end
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
    function W.step(dt)
        W.now = W.now + dt
        env.advance(dt)
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
            local key = table.concat((function() table.sort(members) return members end)(), ",")
            if breached then
                W.areas[members[1]].since = W.areas[members[1]].since or W.now
                for _, a in ipairs(members) do
                    local ar = W.areas[a]
                    if not ar.badAt then ar.badAt, ar.detectIn = W.now, detect() end
                    if W.now - ar.badAt >= ar.detectIn then ar.o2 = false end
                    ar.goodAt = nil
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
        for i = 1, #W.doors + 8 do
            local n = W.nodes[i]
            if n and W.reading(n) ~= n.last then W.report(n, "alk_status") end
        end
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
    return W
end

local SOUTH = { ["Athena-B"] = true, ["Athena6-A"] = true, ["Athena7-A"] = true }

t.case("breaking a block in South settles with only the South doors shut", function()
    local W = world()
    W.run(20)
    W.breach.south = true
    W.run(240)
    local st = W.openState()
    for name, open in pairs(st) do
        if SOUTH[name] then t.eq(open, false, name .. " sealed") else t.eq(open, true, name .. " open") end
    end
    t.eq(W.cmdsSince(W.now - 90), 0, "no door has moved for 90 seconds")
    t.ok(#W.cmds < 80, "settled without flapping: " .. #W.cmds .. " commands")
    W.breach.south = nil
    W.run(120)
    for name, open in pairs(W.openState()) do t.eq(open, true, name .. " open after repair") end
    t.eq(W.cmdsSince(W.now - 40), 0, "quiet after repair")
end)

t.case("a breach in zone 6 seals only Athena6", function()
    local W = world()
    W.run(20)
    W.breach.Athena6 = true
    W.run(240)
    for name, open in pairs(W.openState()) do
        local want = not (name == "Athena6-A" or name == "Athena6-B")
        t.eq(open, want, name)
    end
    t.eq(W.cmdsSince(W.now - 90), 0, "settled")
end)

t.case("a breach in the hub seals the four hub doors only", function()
    local W = world()
    W.run(20)
    W.breach.hub = true
    W.run(240)
    local hub = { ["Athena-A"] = true, ["Athena2-A"] = true, ["Athena3-A"] = true, ["Athena4-A"] = true }
    for name, open in pairs(W.openState()) do t.eq(open, not hub[name], name) end
    t.eq(W.cmdsSince(W.now - 90), 0, "settled")
end)

t.case("harsh timing: slow detectors, long doorway blips and merge flicker still settle", function()
    math.randomseed(7)
    for round = 1, 5 do
        local W = world({
            detect = function() return 1 + math.random() * 2 end,
            reseal = function() return 4 + math.random() * 4 end,
            blip = 3, flicker = 1,
        })
        W.run(20)
        W.breach.south = true
        W.run(400)
        for name, open in pairs(W.openState()) do
            if SOUTH[name] then t.eq(open, false, "round " .. round .. " " .. name) else t.eq(open, true, "round " .. round .. " " .. name) end
        end
        t.eq(W.cmdsSince(W.now - 120), 0, "round " .. round .. " settled")
        W.breach.south = nil
        W.run(200)
        for name, open in pairs(W.openState()) do t.eq(open, true, "round " .. round .. " " .. name .. " after repair") end
    end
end)

t.finish()
