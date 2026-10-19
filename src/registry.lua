local need = ...
local compat = need("compat")
local util = need("util")

local M = {}

M.FILE = "devices.db"
M.MIRROR_DIR = "/.zelnet"
M.ROLE = "system"
M.ONLINE_WINDOW = 300
M.MAX_ALIASES = 8
M.DEVICE_ROLES = { client = true, router = true, endpoint = true }

local Registry = {}
Registry.__index = Registry

function M.storageReady(ctx)
    local st = ctx and ctx.storage
    if type(st) ~= "table" or type(st.ready) ~= "function" then return false end
    local ok, ready = pcall(st.ready, st)
    return ok and ready == true
end

function M.mirrorPath(rel)
    return M.MIRROR_DIR .. "/" .. rel
end

function M.readBoth(ctx, rel)
    local stored
    local ready = M.storageReady(ctx)
    if ready then
        local ok, v = pcall(ctx.storage.read, ctx.storage, M.ROLE, rel, nil)
        if ok and type(v) == "table" then stored = v end
    end
    local mirror = util.readTable(M.mirrorPath(rel), nil)
    return stored, mirror, ready
end

function M.writeBest(ctx, rel, value)
    local path = M.mirrorPath(rel)
    if M.storageReady(ctx) then
        local ok, res, err = pcall(ctx.storage.write, ctx.storage, M.ROLE, rel, value)
        if ok and res then
            if fs.exists(path) then pcall(fs.delete, path) end
            return true, "storage"
        end
        local wok, werr = util.writeTable(path, value)
        if not wok then return false, "mirror", werr end
        return true, "mirror", ok and err or res
    end
    local wok, werr = util.writeTable(path, value)
    if not wok then return false, "mirror", werr end
    return true, "mirror"
end

local function isKey(v)
    return type(v) == "string" and #v == 64 and v:match("^%x+$") ~= nil
end

local function validRecord(name, rec)
    if type(name) ~= "string" or util.normName(name) ~= name then return false end
    if type(rec) ~= "table" or rec.name ~= name then return false end
    if not isKey(rec.key) then return false end
    if type(rec.role) ~= "string" then return false end
    if rec.cid ~= nil and type(rec.cid) ~= "number" then return false end
    return true
end

local function cleanAliases(rec)
    local out = {}
    if type(rec.aliases) == "table" then
        for alias, v in pairs(rec.aliases) do
            if v and util.normName(alias) == alias and alias ~= rec.name then out[alias] = true end
        end
    end
    rec.aliases = out
end

function M.new(ctx)
    local self = setmetatable({}, Registry)
    self.ctx = ctx
    self.log = ctx.log or (ctx.node and ctx.node.log) or util.newLogger(50)
    self.devices = {}
    self.cidIndex = {}
    self.aliasIndex = {}
    self.rt = {}
    self.dirty = false
    self.waitStorage = false
    self.source = "memory"
    self.saves = 0
    self.lastError = nil
    return self
end

function Registry:reindex()
    self.cidIndex = {}
    self.aliasIndex = {}
    for name, rec in pairs(self.devices) do
        if rec.cid and rec.status ~= "revoked" then
            local other = self.cidIndex[rec.cid]
            if not other or (rec.lastSeen or 0) > (self.devices[other].lastSeen or 0) then
                self.cidIndex[rec.cid] = name
            end
        end
        for alias in pairs(rec.aliases or {}) do
            if not self.devices[alias] then self.aliasIndex[alias] = name end
        end
    end
end

function Registry:load()
    local stored, mirror, ready = M.readBoth(self.ctx, M.FILE)
    local merged = {}
    local n = 0
    for _, src in ipairs({ stored or {}, mirror or {} }) do
        for name, rec in pairs(src) do
            if validRecord(name, rec) then
                if not merged[name] then n = n + 1 end
                merged[name] = rec
            end
        end
    end
    for _, rec in pairs(merged) do
        cleanAliases(rec)
        if rec.status == "online" then rec.status = "offline" end
        if rec.status ~= "revoked" and rec.status ~= "offline" and rec.status ~= "pending" then
            rec.status = rec.cid and "offline" or "pending"
        end
    end
    self.devices = merged
    self.rt = {}
    self.waitStorage = self.ctx.storage ~= nil and not ready
    self.source = ready and "storage" or "mirror"
    self.dirty = mirror ~= nil and ready
    self:reindex()
    if self.dirty then self:save() end
    return n
end

function Registry:adoptStorage()
    if not self.waitStorage or not M.storageReady(self.ctx) then return false end
    local ok, stored = pcall(self.ctx.storage.read, self.ctx.storage, M.ROLE, M.FILE, nil)
    if ok and type(stored) == "table" then
        for name, rec in pairs(stored) do
            if validRecord(name, rec) and not self.devices[name] then
                cleanAliases(rec)
                if rec.status == "online" then rec.status = "offline" end
                self.devices[name] = rec
            end
        end
    end
    self.waitStorage = false
    self.source = "storage"
    self:reindex()
    self.log.info("device registry moved to storage")
    self:save()
    return true
end

function Registry:snapshot()
    local out = {}
    for name, rec in pairs(self.devices) do
        local c = util.copy(rec)
        c.aliases = util.copy(rec.aliases)
        out[name] = c
    end
    return out
end

function Registry:save()
    if self.waitStorage then self:adoptStorage() end
    local ok, where, err = M.writeBest(self.ctx, M.FILE, self:snapshot())
    self.saves = self.saves + 1
    if ok then
        self.dirty = false
        self.source = where
        if err then self.lastError = tostring(err) end
    else
        self.lastError = tostring(err)
        self.log.error("cannot save device registry: " .. tostring(err))
    end
    return ok, err
end

function Registry:markDirty()
    self.dirty = true
end

function Registry:flush()
    if self.waitStorage and M.storageReady(self.ctx) then return self:adoptStorage() end
    if self.dirty then return self:save() end
    return true
end

function Registry:get(name)
    if type(name) ~= "string" then return nil end
    return self.devices[name]
end

function Registry:byCid(cid)
    local name = self.cidIndex[cid]
    if not name then return nil end
    local rec = self.devices[name]
    if rec and rec.cid == cid and rec.status ~= "revoked" then return rec end
    return nil
end

function Registry:byAlias(alias)
    local name = self.aliasIndex[alias]
    return name and self.devices[name] or nil
end

function Registry:lookup(name)
    if type(name) ~= "string" then return nil end
    return self.devices[name] or self:byAlias(name)
end

function Registry:isTaken(name)
    return self.devices[name] ~= nil or self.aliasIndex[name] ~= nil
end

function Registry:add(name, role, key)
    local n = util.normName(name)
    if not n then return nil, "bad name" end
    if not M.DEVICE_ROLES[role] then return nil, "bad role" end
    if not isKey(key) then return nil, "bad key" end
    if self:isTaken(n) then return nil, "taken" end
    local rec = {
        name = n, role = role, key = key, cid = nil, created = compat.stamp(), status = "pending",
        lastSeen = nil, prog = nil, hops = nil, parent = nil, aliases = {},
    }
    self.devices[n] = rec
    self:save()
    return rec
end

function Registry:bind(name, cid)
    local rec = self.devices[name]
    if not rec then return nil, "unknown device" end
    local displaced
    local otherName = self.cidIndex[cid]
    if otherName and otherName ~= name then
        local other = self.devices[otherName]
        if other and other.cid == cid then
            other.cid = nil
            other.status = "pending"
            self.rt[otherName] = nil
            displaced = other
        end
    end
    rec.cid = cid
    self:reindex()
    self:save()
    return rec, displaced
end

function Registry:resetBinding(name)
    local rec = self.devices[name]
    if not rec then return nil, "unknown device" end
    rec.cid = nil
    if rec.status ~= "revoked" then rec.status = "pending" end
    self.rt[name] = nil
    self:reindex()
    self:save()
    return true
end

function Registry:revoke(name)
    local rec = self.devices[name]
    if not rec then return nil, "unknown device" end
    rec.status = "revoked"
    rec.aliases = {}
    self.rt[name] = nil
    self:reindex()
    self:save()
    return true
end

function Registry:remove(name)
    if not self.devices[name] then return nil, "unknown device" end
    self.devices[name] = nil
    self.rt[name] = nil
    self:reindex()
    self:save()
    return true
end

function Registry:touch(name, info)
    local rec = self.devices[name]
    if not rec then return false end
    local rt = self.rt[name]
    if not rt then
        rt = {}
        self.rt[name] = rt
    end
    rt.seen = compat.now()
    if info then
        for k, v in pairs(info) do rt[k] = v end
        if info.parent ~= nil then rec.parent = info.parent end
    end
    rec.lastSeen = compat.stamp()
    self.dirty = true
    if rec.status ~= "online" and rec.status ~= "revoked" then
        rec.status = "online"
        return true
    end
    return false
end

function Registry:setInfo(name, fields)
    local rec = self.devices[name]
    if not rec then return false end
    for k, v in pairs(fields) do rec[k] = v end
    self.dirty = true
    return true
end

function Registry:aliasesOf(name)
    local rec = self.devices[name]
    if not rec then return {} end
    return util.sortedKeys(rec.aliases)
end

function Registry:addAlias(name, alias)
    local rec = self.devices[name]
    if not rec then return nil, "unknown device" end
    local a = util.normName(alias)
    if not a then return nil, "bad name" end
    if a == name or rec.aliases[a] then return true end
    if self:isTaken(a) then return nil, "taken" end
    if util.count(rec.aliases) >= M.MAX_ALIASES then return nil, "too many names" end
    rec.aliases[a] = true
    self.aliasIndex[a] = name
    self:save()
    return true
end

function Registry:removeAlias(name, alias)
    local rec = self.devices[name]
    if not rec or not rec.aliases[alias] then return nil, "not owner" end
    rec.aliases[alias] = nil
    self.aliasIndex[alias] = nil
    self:save()
    return true
end

function Registry:isOnline(name, now)
    local rt = self.rt[name]
    local rec = self.devices[name]
    if not rt or not rt.seen or not rec or rec.status == "revoked" then return false end
    return (now or compat.now()) - rt.seen <= (self.window or M.ONLINE_WINDOW)
end

function Registry:sweep(window)
    self.window = window or self.window
    local now = compat.now()
    local gone = {}
    for name, rec in pairs(self.devices) do
        if rec.status == "online" and not self:isOnline(name, now) then
            rec.status = "offline"
            gone[#gone + 1] = name
            self.dirty = true
        end
    end
    return gone
end

function Registry:statusOf(name)
    local rec = self.devices[name]
    if not rec then return nil end
    if rec.status == "revoked" then return "revoked" end
    if self:isOnline(name) then return "online" end
    if rec.cid == nil then return "pending" end
    return "offline"
end

function Registry:list()
    local out = {}
    local now = compat.now()
    for _, name in ipairs(util.sortedKeys(self.devices)) do
        local rec = self.devices[name]
        local rt = self.rt[name]
        out[#out + 1] = {
            name = name, role = rec.role, cid = rec.cid, status = self:statusOf(name),
            lastSeen = rec.lastSeen, prog = rec.prog, hops = rec.hops, parent = rec.parent,
            created = rec.created, aliases = util.sortedKeys(rec.aliases),
            age = rt and rt.seen and (now - rt.seen) or nil, link = rt and rt.link or nil,
        }
    end
    return out
end

function Registry:counts()
    local total, online = 0, 0
    for name in pairs(self.devices) do
        total = total + 1
        if self:isOnline(name) then online = online + 1 end
    end
    return total, online
end

return M
