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
M.IGNORED = { alk_ack = true, alk_cmd = true, alk_poll = true, alk_discover = true }

local Airlock = {}
Airlock.__index = Airlock

function M.groupInfo(name)
    local base, suffix = tostring(name or ""):match("^(.-)%-([%w]+)$")
    if base and base ~= "" then return base, suffix:upper() end
    return tostring(name or ""), nil
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
    return self
end

function Airlock:rednet()
    local r = rawget(_G, "rednet")
    if type(r) == "table" then return r end
    return nil
end

function Airlock:rsend(id, msg)
    local r = self:rednet()
    if not r or type(r.send) ~= "function" then return false end
    local ok, err = pcall(r.send, tonumber(id) or id, msg)
    if not ok then self.log.debug("airlock send: " .. tostring(err)) end
    return ok
end

function Airlock:rbroadcast(msg)
    local r = self:rednet()
    if not r or type(r.broadcast) ~= "function" then return false end
    return (pcall(r.broadcast, msg))
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
    if type(t) == "table" and type(t.nodes) == "table" then
        for key, r in pairs(t.nodes) do
            local id = type(r) == "table" and tonumber(r.id)
            if id and tostring(id) == key and not self.nodes[key] then
                local rec = {
                    id = id, name = cleanName(r.name) ~= "" and cleanName(r.name) or ("Airlock " .. key),
                    role = r.role, oxygenated = r.oxygenated, locked = r.locked == true or nil,
                    manual = (r.manual == "seal" or r.manual == "unseal") and r.manual or nil,
                    sealed = r.sealed == true, lockSync = r.lockSync, named = r.named == true or nil,
                    online = r.online ~= false, seen = tonumber(r.seen), lastSeen = now,
                }
                if type(rec.oxygenated) ~= "boolean" then rec.oxygenated = nil end
                if type(rec.lockSync) ~= "boolean" then rec.lockSync = nil end
                self.nodes[key] = M.normalize(rec)
            end
        end
    end
    self.loaded = true
    return true
end

function Airlock:snapshot()
    local out = {}
    for key, r in pairs(self.nodes) do
        out[key] = {
            id = r.id, name = r.name, role = r.role, oxygenated = r.oxygenated, locked = r.locked,
            manual = r.manual, sealed = r.sealed, lockSync = r.lockSync, named = r.named, online = r.online, seen = r.seen,
        }
    end
    return { v = 1, nodes = out }
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

function Airlock:desired(rec)
    if rec.role == "sensor" then return false end
    if rec.locked then return true end
    if rec.manual == "seal" then return true end
    if rec.manual == "unseal" then return false end
    if rec.oxygenated == false then return true end
    local s = self:groupSensor(rec.group)
    if s and s.oxygenated == false then return true end
    return false
end

function Airlock:sendCommand(rec)
    self.counters.commands = self.counters.commands + 1
    self:rsend(rec.id, { type = "alk_cmd", action = rec.sealed and "seal" or "unseal", locked = rec.locked and true or false })
end

function Airlock:applyPolicy(rec, announce)
    local desired = self:desired(rec)
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

function Airlock:handleMessage(senderID, msg)
    if type(msg) ~= "table" or type(msg.type) ~= "string" or msg.type:sub(1, 4) ~= "alk_" then return false end
    if M.IGNORED[msg.type] then
        self.counters.ignored = self.counters.ignored + 1
        return false
    end
    local id = tonumber(senderID)
    if not id then return false end
    local key = tostring(id)
    local rec = self.nodes[key]
    local isNew = rec == nil
    if isNew and util.count(self.nodes) >= M.MAX_NODES then return false end
    rec = rec or { id = id }
    local wasOnline, oldOxy, oldName, oldRole, oldGroup = rec.online, rec.oxygenated, rec.name, rec.role, rec.group
    local nm = cleanName(msg.name)
    if nm ~= "" and not rec.named then rec.name = nm end
    if not rec.name or rec.name == "" then rec.name = "Airlock " .. key end
    if msg.role == "sensor" or msg.role == "door" then rec.role = msg.role end
    if type(msg.oxygenated) == "boolean" then rec.oxygenated = msg.oxygenated end
    rec.lastSeen = compat.now()
    rec.seen = compat.stamp()
    rec.online = true
    M.normalize(rec)
    self.nodes[key] = rec
    self.counters.reports = self.counters.reports + 1
    self:applyPolicy(rec, false)
    if oldGroup and oldGroup ~= rec.group then self:applyGroup(oldGroup) end
    self:applyGroup(rec.group)
    local desired = self:desired(rec)
    self.counters.acks = self.counters.acks + 1
    self:rsend(id, {
        type = "alk_ack", reqID = msg.reqID, name = rec.name, role = rec.role,
        command = desired and "seal" or "unseal", locked = rec.locked and true or false,
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

function Airlock:setManual(id, mode, actor)
    local rec, err = self:find(id)
    if not rec then return nil, err end
    if not M.MODES[mode] then return nil, "Unknown mode." end
    if mode == "auto" then rec.manual = nil else rec.manual = mode end
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
        }
    end
    return out
end

function Airlock:stats()
    local s = { nodes = 0, sealed = 0, low = 0, offline = 0 }
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
            timers.discover = timers.left > 0 and os.startTimer(M.DISCOVER_GAP) or nil
        elseif a == timers.poll then
            timers.poll = os.startTimer(M.POLL_INTERVAL)
            self:poll()
        elseif a == timers.tick then
            timers.tick = os.startTimer(M.TICK)
            self:tick()
        end
    elseif ev == "zn_airlock_discover" then
        timers.left = M.DISCOVER_COUNT
        timers.discover = os.startTimer(0)
    elseif ev == "peripheral" then
        self:openRednet()
    end
end

function Airlock:run()
    self:openRednet()
    self:load()
    local timers = {
        left = M.DISCOVER_COUNT, discover = os.startTimer(0),
        poll = os.startTimer(M.POLL_INTERVAL), tick = os.startTimer(M.TICK),
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
        self.task = self.node:spawn(function() self:run() end, "airlock")
    end
    return true
end

M.Airlock = Airlock

return M
