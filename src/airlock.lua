local need = ...
local compat = need("compat")
local util = need("util")

local M = {}

M.ROLE = "system"
M.FILE = "airlocks.db"
M.POLL_INTERVAL = 300
M.OFFLINE_AFTER = 900
M.TICK = 30
M.DISCOVER_COUNT = 3
M.DISCOVER_GAP = 0.2
M.NAME_MAX = 32
M.MAX_NODES = 256
M.MODES = { seal = true, unseal = true, auto = true }
M.IGNORED = { alk_ack = true, alk_cmd = true, alk_poll = true, alk_discover = true, alk_peer = true }
M.RELAY_PORT = "zn.alk"
M.PATH_HOLD = 600
M.CONTAIN_MIN = 15
M.SETTLE = 8
M.CONTAIN_TICK = 1
M.LOSS_CONFIRM = 2
M.GRACE = 8
M.OPEN_GAP = 4
M.PROBE = 15
M.BACKOFF = 30
M.BACKOFF_MAX = 600
M.TRIP_WINDOW = 600
M.TRIP_LIMIT = 3

local Airlock = {}
Airlock.__index = Airlock

function M.groupInfo(name)
    local base, suffix = tostring(name or ""):match("^(.-)%-([%w]+)$")
    if base and base ~= "" then return base, suffix:upper() end
    return tostring(name or ""), nil
end

function M.stationOf(group)
    local g = tostring(group or "")
    local base = g:gsub("%d+$", "")
    if base == "" then return g end
    return base
end

function M.normalize(rec)
    local g, suf = M.groupInfo(rec.name)
    rec.group = g
    rec.suffix = suf
    if rec.role ~= "sensor" and rec.role ~= "door" then
        rec.role = (suf == "C") and "sensor" or "door"
    end
    return rec
end

local function cleanName(s)
    if type(s) ~= "string" then return "" end
    return util.trim(util.sanitize(s)):sub(1, M.NAME_MAX)
end

local function memberKey(r)
    if r.role == "sensor" then return "~" .. tostring(r.suffix or r.name) end
    return tostring(r.suffix or r.name)
end

function M.new(ctx)
    local self = setmetatable({}, Airlock)
    self.ctx = ctx
    self.cfg = ctx.cfg or {}
    self.node = ctx.node
    self.log = ctx.log or (ctx.node and ctx.node.log) or util.newLogger(50)
    self.enabled = self.cfg.airlocks ~= false
    self.nodes = {}
    self.loaded = false
    self.dirty = false
    self.urgent = false
    self.ver = 0
    self.opened = 0
    self.started = false
    self.counters = { reports = 0, acks = 0, commands = 0, polls = 0, ignored = 0 }
    self.contain = {}
    self.lastOpen = {}
    self.layouts = {}
    self.containOn = self.cfg.containment == true
    return self
end

function Airlock:rednet()
    local r = rawget(_G, "rednet")
    if type(r) == "table" then return r end
    return nil
end

function Airlock:rsend(id, msg)
    local rec = self.nodes[tostring(id)]
    if rec and rec.via and self.node then
        self.node:send(rec.via, M.RELAY_PORT, { op = "deliver", cid = tonumber(id), msg = msg })
        return true
    end
    local r = self:rednet()
    if not r or type(r.send) ~= "function" then return false end
    local ok, err = pcall(r.send, tonumber(id) or id, msg)
    if not ok then self.log.debug("airlock send: " .. tostring(err)) end
    return ok
end

function Airlock:routers()
    local srv = self.ctx.server
    local out = {}
    if not srv or not srv.reg or type(srv.reg.devices) ~= "table" then return out end
    for name, rec in pairs(srv.reg.devices) do
        if rec.role == "router" and rec.cid and rec.status ~= "revoked" then
            local st = srv.reg.statusOf and srv.reg:statusOf(name)
            if st == nil or st == "online" then out[#out + 1] = rec.cid end
        end
    end
    return out
end

function Airlock:rbroadcast(msg)
    if self.node and self.cfg.realm then
        for _, cid in ipairs(self:routers()) do
            self.node:send(self.cfg.realm .. ":" .. cid, M.RELAY_PORT, { op = "broadcast", msg = msg })
        end
    end
    local r = self:rednet()
    if not r or type(r.broadcast) ~= "function" then return false end
    return (pcall(r.broadcast, msg))
end

function Airlock:onRelay(msg)
    local srv = self.ctx.server
    local dev = srv and srv.deviceFromSrc and srv:deviceFromSrc(msg.src)
    if not dev or dev.role ~= "router" then return end
    local b = msg.data
    if type(b) ~= "table" or type(b.msg) ~= "table" or not tonumber(b.cid) then return end
    self.counters.relayed = (self.counters.relayed or 0) + 1
    self:handleMessage(tonumber(b.cid), b.msg, msg.src)
end

function Airlock:choosePath(rec, via, now)
    if via then
        if rec.directAt and now - rec.directAt < M.PATH_HOLD then return false end
        if rec.via and rec.via ~= via and rec.viaAt and now - rec.viaAt < M.PATH_HOLD then return false end
        if rec.via ~= via then self:changed(rec, true) end
        rec.via = via
        rec.viaAt = now
    else
        if rec.via then self:changed(rec, true) end
        rec.via = nil
        rec.viaAt = nil
        rec.directAt = now
    end
    return true
end

function Airlock:openRednet()
    local r = self:rednet()
    if not r or type(r.open) ~= "function" then return 0 end
    local n = 0
    local names = peripheral.getNames and peripheral.getNames() or { "top", "bottom", "left", "right", "front", "back" }
    for _, name in ipairs(names) do
        if peripheral.getType(name) == "modem" then
            if pcall(r.open, name) then n = n + 1 end
        end
    end
    self.opened = n
    return n
end

function Airlock:audit(actor, action, target, detail, ok)
    local st = self.ctx.storage
    if st and type(st.audit) == "function" then pcall(st.audit, st, actor, action, target, detail, ok) end
end

function Airlock:changed(rec, urgent)
    self.ver = self.ver + 1
    self.dirty = true
    if urgent then self.urgent = true end
    if self.ctx.emit then pcall(self.ctx.emit, "airlock", rec and rec.id) end
end

function Airlock:storageReady()
    local st = self.ctx.storage
    if not st then return true end
    if type(st.ready) ~= "function" then return true end
    local ok, v = pcall(st.ready, st, M.ROLE)
    return ok and v == true
end

function Airlock:load()
    if self.loaded then return true end
    local st = self.ctx.storage
    if not st then
        self.loaded = true
        return true
    end
    if not self:storageReady() then return false end
    local ok, t = pcall(st.read, st, M.ROLE, M.FILE, nil)
    if not ok then return false end
    if t == nil and type(st.exists) == "function" and st:exists(M.ROLE, M.FILE) then return false end
    local now = compat.now()
    if type(t) == "table" and type(t.contain) == "table" then
        for station, c in pairs(t.contain) do
            if type(station) == "string" and type(c) == "table" and not self.contain[station] then
                self.contain[station] = { since = now, cause = cleanName(c.cause), hold = c.hold == true or nil, manual = c.manual == true or nil, trips = {} }
            end
        end
    end
    if type(t) == "table" and type(t.nodes) == "table" then
        for key, r in pairs(t.nodes) do
            local id = type(r) == "table" and tonumber(r.id)
            local live = id and tostring(id) == key and self.nodes[key]
            if live then
                self:mergeStored(live, r)
            elseif id and tostring(id) == key then
                local rec = {
                    id = id, name = cleanName(r.name) ~= "" and cleanName(r.name) or ("Airlock " .. key),
                    role = r.role, oxygenated = r.oxygenated, locked = r.locked == true or nil,
                    manual = (r.manual == "seal" or r.manual == "unseal") and r.manual or nil,
                    sealed = r.sealed == true, lockSync = r.lockSync, named = r.named == true or nil,
                    online = r.online ~= false, seen = tonumber(r.seen), lastSeen = now,
                    via = type(r.via) == "string" and r.via or nil, viaAt = type(r.via) == "string" and now or nil,
                }
                if type(rec.oxygenated) ~= "boolean" then rec.oxygenated = nil end
                if rec.oxygenated == true then rec.oxyAt = now - M.SETTLE end
                if rec.oxygenated == false then rec.lowAt = now - M.GRACE end
                if type(rec.lockSync) ~= "boolean" then rec.lockSync = nil end
                self.nodes[key] = M.normalize(rec)
            end
        end
    end
    self.loaded = true
    return true
end

function Airlock:mergeStored(live, r)
    if r.locked == true and not live.locked then live.locked = true end
    if not live.manual and (r.manual == "seal" or r.manual == "unseal") then live.manual = r.manual end
    if r.named == true and not live.named and cleanName(r.name) ~= "" then
        live.name = cleanName(r.name)
        live.named = true
        live.role = nil
    end
    M.normalize(live)
    self:applyPolicy(live, true)
    self:applyGroup(live.group)
    self:changed(live, true)
end

function Airlock:snapshot()
    local out = {}
    for key, r in pairs(self.nodes) do
        out[key] = {
            id = r.id, name = r.name, role = r.role, oxygenated = r.oxygenated, locked = r.locked,
            manual = r.manual, sealed = r.sealed, lockSync = r.lockSync, named = r.named, online = r.online, seen = r.seen,
            via = r.via,
        }
    end
    local contain = {}
    for station, c in pairs(self.contain) do contain[station] = { cause = c.cause, hold = c.hold, manual = c.manual } end
    return { v = 1, nodes = out, contain = contain }
end

function Airlock:save()
    if not self.loaded and not self:load() then return false end
    local st = self.ctx.storage
    local ver = self.ver
    self.urgent = false
    if not st then
        self.dirty = false
        return true
    end
    local ok, res, err = pcall(st.write, st, M.ROLE, M.FILE, self:snapshot())
    if ok and res then
        if self.ver == ver then self.dirty = false end
        return true
    end
    self.log.debug("airlock save: " .. tostring(ok and err or res))
    return false
end

function Airlock:groupSensor(group)
    if not group then return nil end
    for _, r in pairs(self.nodes) do
        if r.group == group and r.suffix == "C" then return r end
    end
    return nil
end

function Airlock:stable(r, now)
    if r.oxygenated == false then return false end
    if r.oxygenated == nil then return true end
    return r.oxyAt == nil or now - r.oxyAt >= M.SETTLE
end

function Airlock:layout(station)
    local l = self.layouts[station]
    if l ~= nil then return l or nil end
    l = false
    local ok, nav = pcall(need, "navmap")
    if ok and type(nav) == "table" and nav.STATION == station and type(nav.COMMONS) == "table" then
        l = {}
        for _, c in ipairs(nav.COMMONS) do
            for _, name in ipairs(c.doors) do l[name:lower()] = c.id end
        end
    end
    self.layouts[station] = l
    return l or nil
end

function Airlock:farArea(rec)
    local station = M.stationOf(rec.group)
    local l = self:layout(station)
    local id = l and type(rec.name) == "string" and l[rec.name:lower()]
    if not id then return { members = { rec }, doors = { rec } } end
    local area = { members = {}, doors = {} }
    for _, r in ipairs(self:members(station)) do
        if r.role ~= "sensor" and type(r.name) == "string" and l[r.name:lower()] == id then
            area.members[#area.members + 1] = r
            area.doors[#area.doors + 1] = r
        end
    end
    return area
end

function Airlock:zoneArea(group)
    local area = { members = {}, doors = {} }
    for _, r in pairs(self.nodes) do
        if r.group == group then
            if r.suffix == "C" then area.members[#area.members + 1] = r
            elseif r.role ~= "sensor" then area.doors[#area.doors + 1] = r end
        end
    end
    return area
end

function Airlock:areaState(area, now)
    local recent = false
    for _, d in ipairs(area.doors) do
        if d.openedAt and now - d.openedAt < M.GRACE then recent = true end
    end
    local lows, settling = 0, false
    for _, m in ipairs(area.members) do
        if m.oxygenated == false then lows = lows + 1
        elseif m.oxygenated == true and m.oxyAt and now - m.oxyAt < M.SETTLE then settling = true end
    end
    local wait = (recent and lows < 2) and M.GRACE or M.LOSS_CONFIRM
    local confirmed = false
    for _, m in ipairs(area.members) do
        if m.oxygenated == false and now - (m.lowAt or -math.huge) >= wait then confirmed = true end
    end
    if confirmed then return "lost" end
    if lows > 0 or settling then return "pending" end
    return "holding"
end

function Airlock:desired(rec)
    if rec.role == "sensor" then return false end
    if rec.locked then return true end
    if rec.manual == "seal" then return true end
    if rec.manual == "unseal" then return false end
    local now = compat.now()
    local station = M.stationOf(rec.group)
    local c = self.contain[station]
    if c and (c.hold or now - c.since < M.CONTAIN_MIN) then return true end
    local zone = self:areaState(self:zoneArea(rec.group), now)
    local far = self:areaState(self:farArea(rec), now)
    if zone == "lost" or far == "lost" then return true end
    if rec.sealed ~= true then
        if zone ~= "holding" or far ~= "holding" or (rec.openedAt and now - rec.openedAt < M.PROBE) then self.pendingSettle = true end
        return false
    end
    if zone ~= "holding" or far ~= "holding" then
        self.pendingSettle = true
        return true
    end
    if rec.backoffUntil and now < rec.backoffUntil then
        self.pendingSettle = true
        return true
    end
    local last = self.lastOpen[station]
    if last and now - last < M.OPEN_GAP then
        self.pendingSettle = true
        return true
    end
    return false
end

function Airlock:members(station)
    local out = {}
    for _, r in pairs(self.nodes) do
        if M.stationOf(r.group) == station then out[#out + 1] = r end
    end
    table.sort(out, function(a, b) return tostring(a.name) < tostring(b.name) end)
    return out
end

function Airlock:applyStation(station)
    for _, r in ipairs(self:members(station)) do
        if r.role ~= "sensor" then self:applyPolicy(r, true) end
    end
end

function Airlock:startContainment(rec)
    if not self.containOn then return false end
    local station = M.stationOf(rec.group)
    local now = compat.now()
    local c = self.contain[station]
    local trips = c and c.trips or {}
    local kept = {}
    for _, at in ipairs(trips) do
        if now - at < M.TRIP_WINDOW then kept[#kept + 1] = at end
    end
    kept[#kept + 1] = now
    local hold = (c and c.hold) or (#kept >= M.TRIP_LIMIT) or nil
    self.contain[station] = { since = now, cause = rec.name, trips = kept, hold = hold }
    self:audit("airlock", hold and "containment_hold" or "containment", station, "oxygen lost at " .. tostring(rec.name), false)
    self:applyStation(station)
    self:changed(rec, true)
    return true
end

function Airlock:stations()
    local seen, out = {}, {}
    for _, r in pairs(self.nodes) do
        local st = M.stationOf(r.group)
        if st ~= "" and not seen[st] then
            seen[st] = true
            out[#out + 1] = st
        end
    end
    table.sort(out)
    return out
end

function Airlock:lockdown(station, actor)
    if type(station) ~= "string" or #self:members(station) == 0 then return nil, "Unknown station." end
    local c = self.contain[station]
    self.contain[station] = { since = compat.now(), cause = "lockdown", hold = true, manual = true, trips = c and c.trips or {} }
    self:applyStation(station)
    self:changed(nil, true)
    self:save()
    self:audit(actor or "console", "lockdown", station, "every door sealed", true)
    return true
end

function Airlock:releaseContainment(station, actor)
    local c = self.contain[station]
    if not c then return nil, "No containment is active there." end
    self.contain[station] = nil
    self:applyStation(station)
    self:changed(nil, true)
    self:save()
    self:audit(actor or "console", "containment_release", station, c.cause and ("started at " .. c.cause) or nil, true)
    return true
end

function Airlock:containTick()
    local now = compat.now()
    self.pendingSettle = false
    for station, c in compat.spairs(self.contain) do
        if not c.hold and now - c.since >= M.CONTAIN_MIN then
            local clear = true
            for _, r in ipairs(self:members(station)) do
                if not self:stable(r, now) then clear = false break end
            end
            if clear then
                self.contain[station] = nil
                self:audit("airlock", "containment_clear", station, "every zone holds oxygen", true)
                self:changed(nil, true)
            end
        end
    end
    for _, r in compat.spairs(self.nodes) do
        if r.role ~= "sensor" then self:applyPolicy(r, true) end
    end
    if self.urgent then self:save() end
end

function Airlock:areaStates(station)
    local now = compat.now()
    local out = { zones = {}, commons = {} }
    local l = self:layout(station)
    for _, r in ipairs(self:members(station)) do
        if r.group and out.zones[r.group] == nil then
            local z = self:zoneArea(r.group)
            out.zones[r.group] = #z.members > 0 and self:areaState(z, now) or false
        end
        local key = l and r.role ~= "sensor" and type(r.name) == "string" and l[r.name:lower()]
        if key and out.commons[key] == nil then out.commons[key] = self:areaState(self:farArea(r), now) end
    end
    return out
end

function Airlock:containment()
    local now = compat.now()
    local out = {}
    for station, c in pairs(self.contain) do
        out[#out + 1] = { station = station, cause = c.cause, hold = c.hold, manual = c.manual, age = now - c.since, trips = #(c.trips or {}) }
    end
    table.sort(out, function(a, b) return a.station < b.station end)
    return out
end

function Airlock:sendCommand(rec)
    self.counters.commands = self.counters.commands + 1
    self:rsend(rec.id, { type = "alk_cmd", action = rec.sealed and "seal" or "unseal", locked = rec.locked and true or false })
end

function Airlock:applyPolicy(rec, announce)
    local prev = rec.sealed
    local desired = self:desired(rec)
    if rec.role ~= "sensor" then
        local now = compat.now()
        if prev == true and desired == false then
            rec.openedAt = now
            self.lastOpen[M.stationOf(rec.group)] = now
        elseif prev == false and desired == true and rec.openedAt and now - rec.openedAt < M.PROBE and not rec.locked and not rec.manual then
            rec.backoffN = (rec.backoffN or 0) + 1
            rec.backoffUntil = now + math.min(M.BACKOFF_MAX, M.BACKOFF * 2 ^ (rec.backoffN - 1))
            self:audit("airlock", "door_retry", rec.name, "lost air right after opening; next try in " .. math.floor(rec.backoffUntil - now) .. "s", false)
        elseif prev == false and desired == false and rec.openedAt and now - rec.openedAt >= M.PROBE then
            rec.backoffN = nil
        end
    end
    local lockFlag = rec.locked and true or false
    local changed = (rec.sealed ~= desired) or (rec.lockSync ~= lockFlag)
    if rec.sealed ~= desired then self:changed(rec) end
    rec.sealed = desired
    if announce and changed then
        self:sendCommand(rec)
        rec.lockSync = lockFlag
    end
    return desired, changed
end

function Airlock:applyGroup(group)
    if not group then return end
    for _, r in pairs(self.nodes) do
        if r.group == group and r.role ~= "sensor" then self:applyPolicy(r, true) end
    end
end

function Airlock:handleMessage(senderID, msg, via)
    if type(msg) ~= "table" or type(msg.type) ~= "string" or msg.type:sub(1, 4) ~= "alk_" then return false end
    if M.IGNORED[msg.type] then
        self.counters.ignored = self.counters.ignored + 1
        return false
    end
    local id = tonumber(senderID)
    if not id then return false end
    if not self.loaded then self:load() end
    local key = tostring(id)
    local rec = self.nodes[key]
    local isNew = rec == nil
    if isNew and util.count(self.nodes) >= M.MAX_NODES then return false end
    rec = rec or { id = id }
    if not self:choosePath(rec, via, compat.now()) then
        self.counters.ignored = self.counters.ignored + 1
        return false
    end
    local wasOnline, oldOxy, oldName, oldRole, oldGroup = rec.online, rec.oxygenated, rec.name, rec.role, rec.group
    local nm = cleanName(msg.name)
    if nm ~= "" and not rec.named then rec.name = nm end
    if not rec.name or rec.name == "" then rec.name = "Airlock " .. key end
    if msg.role == "sensor" or msg.role == "door" then rec.role = msg.role end
    if type(msg.oxygenated) == "boolean" then
        if msg.oxygenated and rec.oxygenated ~= true then rec.oxyAt = isNew and (compat.now() - M.SETTLE) or compat.now() end
        if not msg.oxygenated and rec.oxygenated ~= false then rec.lowAt = isNew and (compat.now() - M.GRACE) or compat.now() end
        rec.oxygenated = msg.oxygenated
    end
    if type(msg.sealed) == "boolean" and msg.role ~= "sensor" then rec.sealed = msg.sealed end
    rec.lastSeen = compat.now()
    rec.seen = compat.stamp()
    rec.online = true
    M.normalize(rec)
    self.nodes[key] = rec
    self.counters.reports = self.counters.reports + 1
    self:applyPolicy(rec, false)
    if oldGroup and oldGroup ~= rec.group then self:applyGroup(oldGroup) end
    if rec.oxygenated == false and oldOxy ~= false then
        self:startContainment(rec)
    end
    self:applyStation(M.stationOf(rec.group))
    self.counters.acks = self.counters.acks + 1
    rec.lockSync = rec.locked and true or false
    self:rsend(id, {
        type = "alk_ack", reqID = msg.reqID, name = rec.name, role = rec.role,
        command = (rec.role ~= "sensor" and rec.sealed) and "seal" or "unseal", locked = rec.locked and true or false,
    })
    self:noteReport(rec, msg.type, isNew, wasOnline, oldOxy)
    local structural = isNew or wasOnline == false or oldOxy ~= rec.oxygenated or oldName ~= rec.name or oldRole ~= rec.role
    self:changed(rec, structural)
    if self.urgent then self:save() end
    return true
end

function Airlock:noteReport(rec, kind, isNew, wasOnline, oldOxy)
    local detail = "id " .. tostring(rec.id)
    if kind == "alk_register" and (isNew or wasOnline == false) then
        self:audit("airlock", "register", rec.name, detail, true)
    elseif isNew then
        self:audit("airlock", "discovered", rec.name, detail, true)
    elseif wasOnline == false then
        self:audit("airlock", "online", rec.name, detail, true)
    end
    if rec.oxygenated == false and oldOxy ~= false then
        self:audit("airlock", "depressurized", rec.name, detail, true)
    elseif oldOxy == false and rec.oxygenated == true then
        self:audit("airlock", "repressurized", rec.name, detail, true)
    end
end

function Airlock:checkOffline()
    local now = compat.now()
    local n = 0
    for _, rec in pairs(self.nodes) do
        if rec.online and rec.lastSeen and now - rec.lastSeen > M.OFFLINE_AFTER then
            rec.online = false
            n = n + 1
            self:audit("airlock", "offline", rec.name, "id " .. tostring(rec.id), false)
            self:changed(rec, true)
        end
    end
    return n
end

function Airlock:poll()
    if not self.enabled then return 0 end
    local n = 0
    for _, rec in pairs(self.nodes) do
        self:rsend(rec.id, { type = "alk_poll" })
        n = n + 1
    end
    self.counters.polls = self.counters.polls + 1
    self:checkOffline()
    if self.urgent then self:save() end
    return n
end

function Airlock:find(id)
    local rec = self.nodes[tostring(tonumber(id) or id)]
    if not rec then return nil, "Unknown airlock." end
    return rec
end

function Airlock:clearWait(rec)
    rec.backoffN = nil
    rec.backoffUntil = nil
    self.lastOpen[M.stationOf(rec.group)] = nil
end

function Airlock:setManual(id, mode, actor)
    local rec, err = self:find(id)
    if not rec then return nil, err end
    if not M.MODES[mode] then return nil, "Unknown mode." end
    if mode == "auto" then rec.manual = nil else rec.manual = mode end
    self:clearWait(rec)
    local desired = self:applyPolicy(rec, true)
    self:applyGroup(rec.group)
    self:changed(rec, true)
    self:save()
    self:audit(actor or "console", "airlock_" .. mode, rec.name, "id " .. tostring(rec.id), true)
    return true, desired
end

function Airlock:setLocked(id, locked, actor)
    local rec, err = self:find(id)
    if not rec then return nil, err end
    if rec.role == "sensor" then return nil, "Sensors have no door to lock." end
    rec.locked = locked and true or nil
    self:clearWait(rec)
    self:applyPolicy(rec, false)
    self:sendCommand(rec)
    rec.lockSync = rec.locked and true or false
    self:changed(rec, true)
    self:save()
    self:audit(actor or "console", rec.locked and "airlock_lock" or "airlock_unlock", rec.name, "id " .. tostring(rec.id), true)
    return true
end

function Airlock:rename(id, name, actor)
    local rec, err = self:find(id)
    if not rec then return nil, err end
    local newName = cleanName(name)
    if newName == "" then return nil, "Name is empty." end
    local oldGroup = rec.group
    rec.name = newName
    rec.role = nil
    rec.named = true
    M.normalize(rec)
    self:applyGroup(oldGroup)
    self:applyGroup(rec.group)
    self:changed(rec, true)
    self:save()
    self:audit(actor or "console", "airlock_rename", rec.name, "id " .. tostring(rec.id), true)
    return true
end

function Airlock:remove(id, actor)
    local rec, err = self:find(id)
    if not rec then return nil, err end
    self.nodes[tostring(rec.id)] = nil
    self:applyGroup(rec.group)
    self:changed(rec, true)
    self:save()
    self:audit(actor or "console", "airlock_remove", rec.name, "id " .. tostring(rec.id), true)
    return true
end

function Airlock:pollOne(id)
    local rec, err = self:find(id)
    if not rec then return nil, err end
    self:rsend(rec.id, { type = "alk_poll" })
    return true
end

function Airlock:discover()
    if not self.enabled then return false end
    os.queueEvent("zn_airlock_discover")
    return true
end

local function copyRec(r, now)
    local c = util.copy(r)
    c.age = r.lastSeen and (now - r.lastSeen) or nil
    c.lastSeen = nil
    return c
end

function Airlock:list()
    local now = compat.now()
    local out = {}
    for _, r in pairs(self.nodes) do out[#out + 1] = copyRec(r, now) end
    table.sort(out, function(a, b)
        if a.group ~= b.group then return tostring(a.group) < tostring(b.group) end
        return memberKey(a) < memberKey(b)
    end)
    return out
end

function Airlock:groups()
    local byGroup, order = {}, {}
    for _, r in ipairs(self:list()) do
        local g = r.group or tostring(r.name)
        if not byGroup[g] then
            byGroup[g] = {}
            order[#order + 1] = g
        end
        table.insert(byGroup[g], r)
    end
    table.sort(order)
    local out = {}
    for _, g in ipairs(order) do
        local mem = byGroup[g]
        local sensor, sealed, hasSuffix = nil, 0, false
        for _, r in ipairs(mem) do
            if r.suffix == "C" then sensor = r end
            if r.sealed then sealed = sealed + 1 end
            if r.suffix then hasSuffix = true end
        end
        out[#out + 1] = {
            group = g, members = mem, total = #mem, sealed = sealed, hasSensor = sensor ~= nil,
            chamberLow = sensor ~= nil and sensor.oxygenated == false, grouped = #mem > 1 or hasSuffix,
            contained = self.contain[M.stationOf(g)] ~= nil,
        }
    end
    return out
end

function Airlock:stats()
    local s = { nodes = 0, sealed = 0, low = 0, offline = 0, contained = util.count(self.contain) }
    for _, r in pairs(self.nodes) do
        s.nodes = s.nodes + 1
        if r.sealed then s.sealed = s.sealed + 1 end
        if r.oxygenated == false then s.low = s.low + 1 end
        if not r.online then s.offline = s.offline + 1 end
    end
    return s
end

function Airlock:tick()
    if not self.loaded then self:load() end
    self:checkOffline()
    if self.dirty then self:save() end
end

function Airlock:step(timers, ev, a, b)
    if ev == "rednet_message" then
        if type(b) == "table" and type(b.type) == "string" and b.type:sub(1, 4) == "alk_" then
            self:handleMessage(a, b)
        end
    elseif ev == "timer" then
        if a == timers.discover then
            self:rbroadcast({ type = "alk_discover" })
            timers.left = timers.left - 1
            timers.discover = timers.left > 0 and compat.quietTimer(M.DISCOVER_GAP) or nil
        elseif a == timers.poll then
            timers.poll = compat.quietTimer(M.POLL_INTERVAL)
            self:poll()
        elseif a == timers.tick then
            timers.tick = compat.quietTimer(M.TICK)
            self:tick()
        elseif a == timers.contain then
            timers.contain = nil
            self:containTick()
        end
    elseif ev == "zn_airlock_discover" then
        timers.left = M.DISCOVER_COUNT
        timers.discover = compat.quietTimer(0)
    elseif ev == "peripheral" then
        self:openRednet()
    end
    if not timers.contain and (next(self.contain) or self.pendingSettle) then timers.contain = compat.quietTimer(M.CONTAIN_TICK) end
end

function Airlock:run()
    self:openRednet()
    self:load()
    local timers = {
        left = M.DISCOVER_COUNT, discover = compat.quietTimer(0),
        poll = compat.quietTimer(M.POLL_INTERVAL), tick = compat.quietTimer(M.TICK),
    }
    while true do
        local ev, a, b = os.pullEventRaw()
        local ok, err = pcall(self.step, self, timers, ev, a, b)
        if not ok then self.log.error("airlock: " .. tostring(err)) end
    end
end

function Airlock:start()
    if self.started then return true end
    self.started = true
    if not self.enabled then
        self.log.info("airlocks disabled")
        return true
    end
    self:load()
    if self.node then
        self.node:listen(M.RELAY_PORT, function(msg) self:onRelay(msg) end)
        self.task = self.node:spawn(function() self:run() end, "airlock")
    end
    return true
end

M.Airlock = Airlock

return M
