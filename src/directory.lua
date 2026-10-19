local need = ...
local compat = need("compat")
local util = need("util")
local codec = need("codec")
local crypto = need("crypto")
local version = need("version")
local registry = need("registry")

local M = {}

M.FILE = "directory.db"
M.REGISTER_INTERVAL = 300
M.PUSH_DELAY = 2
M.MAX_USERS = 1000
M.MAX_REALMS = 64
M.BODY_BUDGET = 30000

local Directory = {}
Directory.__index = Directory

local USER_PATTERN = "^[a-z][a-z0-9_]*$"

function M.normUser(name)
    if type(name) ~= "string" then return nil end
    local u = util.trim(name):lower()
    if #u < 3 or #u > 16 or not u:match(USER_PATTERN) then return nil end
    return u
end

function M.new(ctx, srv)
    local self = setmetatable({}, Directory)
    self.ctx = ctx
    self.srv = srv
    self.node = ctx.node
    self.cfg = ctx.cfg
    self.log = ctx.log or ctx.node.log
    self.realm = ctx.cfg.realm
    self.mainRealm = util.normRealm(ctx.cfg.mainRealm) or ctx.cfg.realm
    self.isMain = ctx.cfg.role == "main"
    self.realms = {}
    self.users = {}
    self.ver = 0
    self.epoch = nil
    self.synced = false
    self.lastSync = nil
    self.pushDue = false
    self.lastRegister = nil
    self.registerPending = false
    self.dirty = false
    self.waitStorage = false
    return self
end

local function cleanRealms(t)
    local out = {}
    if type(t) ~= "table" then return out end
    for r, rec in pairs(t) do
        if util.normRealm(r) == r and type(rec) == "table" then
            out[r] = {
                serverId = tonumber(rec.serverId), main = rec.main == true,
                prog = type(rec.prog) == "string" and util.sanitize(rec.prog):sub(1, 16) or nil,
                lastSeen = tonumber(rec.lastSeen), provisioned = tonumber(rec.provisioned),
            }
        end
    end
    return out
end

local function cleanUsers(t)
    local out = {}
    if type(t) ~= "table" then return out end
    for u, r in pairs(t) do
        if M.normUser(u) == u and util.normRealm(r) == r then out[u] = r end
    end
    return out
end

function Directory:mergeMissing(other)
    if type(other) ~= "table" then return 0 end
    local added = 0
    for r, rec in pairs(cleanRealms(other.realms)) do
        if not self.realms[r] then
            self.realms[r] = rec
            added = added + 1
        end
    end
    for u, r in pairs(cleanUsers(other.users)) do
        if not self.users[u] then
            self.users[u] = r
            added = added + 1
        end
    end
    return added
end

function Directory:load()
    local stored, mirror, ready = registry.readBoth(self.ctx, M.FILE)
    local best, other = stored, mirror
    if type(mirror) == "table" and (type(best) ~= "table" or (tonumber(mirror.ver) or 0) >= (tonumber(best.ver) or 0)) then
        best, other = mirror, stored
    end
    self.waitStorage = self.ctx.storage ~= nil and not ready
    if type(best) == "table" then
        self.realms = cleanRealms(best.realms)
        self.users = cleanUsers(best.users)
        self.ver = tonumber(best.ver) or 0
        self.epoch = type(best.epoch) == "string" and best.epoch or nil
        self.synced = not self.isMain and self.epoch ~= nil
        if self:mergeMissing(other) > 0 then
            self.ver = self.ver + 1
            self.dirty = true
        end
        if type(mirror) == "table" and ready then self.dirty = true end
    end
    if self.isMain then
        if not self.epoch then self.epoch = crypto.randHex(4) end
        local me = self.realms[self.realm] or {}
        me.serverId = self.node.myId
        me.main = true
        me.prog = version.program
        me.lastSeen = compat.stamp()
        self.realms[self.realm] = me
        self:save()
    elseif self.dirty then
        self:save()
    end
    return util.count(self.users)
end

function Directory:snapshot()
    return { ver = self.ver, epoch = self.epoch, realms = util.deepCopy(self.realms), users = util.copy(self.users) }
end

function Directory:adoptStorage()
    if not self.waitStorage or not registry.storageReady(self.ctx) then return false end
    local ok, stored = pcall(self.ctx.storage.read, self.ctx.storage, registry.ROLE, M.FILE, nil)
    if ok and type(stored) == "table" then
        local sver = tonumber(stored.ver) or 0
        self:mergeMissing(stored)
        if sver >= self.ver then self.ver = sver + 1 end
        if type(stored.epoch) == "string" then self.epoch = stored.epoch end
        self.synced = self.synced or (not self.isMain and self.epoch ~= nil)
    end
    self.waitStorage = false
    if self.isMain then self.pushDue = true end
    self.log.info("directory moved to storage")
    return true
end

function Directory:save()
    if self.waitStorage then self:adoptStorage() end
    local ok, _, err = registry.writeBest(self.ctx, M.FILE, self:snapshot())
    if not ok then self.log.error("cannot save directory: " .. tostring(err)) end
    self.dirty = false
    return ok
end

function Directory:fits()
    local text = codec.encode(self:snapshot())
    return text ~= nil and #text <= M.BODY_BUDGET
end

function Directory:changed()
    self.ver = self.ver + 1
    self:save()
    if self.isMain then self.pushDue = true end
end

function Directory:start()
    local n = self.node
    if self.isMain then
        n:every(M.PUSH_DELAY, function() self:flushPush() end, "dir-push")
    else
        n:after(3, function() self:register() end, "dir-register-first")
        n:every(M.REGISTER_INTERVAL, function() self:register() end, "dir-register")
        n:on("realm_up", function(r)
            if r == self.mainRealm then self:register() end
        end)
    end
end

function Directory:flushPush()
    if not self.pushDue then return end
    self.pushDue = false
    local body = self:snapshot()
    body.op = "push"
    self.srv:broadcastRealms("zn.dir", body)
end

function Directory:adopt(body)
    if type(body) ~= "table" then return false end
    local ver = tonumber(body.ver) or 0
    local epoch = type(body.epoch) == "string" and body.epoch or nil
    if self.epoch == epoch and ver < self.ver then return false end
    self.realms = cleanRealms(body.realms)
    self.users = cleanUsers(body.users)
    self.ver = ver
    self.epoch = epoch
    self.synced = true
    self.lastSync = compat.now()
    self:save()
    if self.ctx.node then self.ctx.node:emit("directory", self.ver) end
    return true
end

function Directory:register()
    if self.isMain or self.registerPending then return end
    self.registerPending = true
    self.lastRegister = compat.now()
    local body = { op = "register", realm = self.realm, serverId = self.node.myId, prog = version.program }
    self.node:requestAsync(self.mainRealm, "zn.dir", body, function(reply, err)
        self.registerPending = false
        if type(reply) == "table" and reply.ok then
            self:adopt(reply)
        elseif err then
            self.log.debug("directory register: " .. tostring(err))
        end
    end, 40)
end

local function srcRealmOf(src)
    local a = util.parseAddress(src)
    if not a or a.id or a.name or a.realm == "*" then return nil end
    return a.realm
end

function Directory:canManage(srcRealm, owner)
    return srcRealm == self.mainRealm or srcRealm == owner
end

function Directory:applyClaim(srcRealm, body)
    local u = M.normUser(body.user)
    if not u then return { ok = false, err = "bad_name" } end
    local realm = util.normRealm(body.realm) or srcRealm
    if not self:canManage(srcRealm, realm) then return { ok = false, err = "denied" } end
    local cur = self.users[u]
    if cur and cur ~= realm then return { ok = false, err = "taken", realm = cur } end
    if cur == realm then return { ok = true, user = u, realm = realm } end
    if util.count(self.users) >= M.MAX_USERS then return { ok = false, err = "full" } end
    self.users[u] = realm
    if not self:fits() then
        self.users[u] = nil
        self.log.warn("directory full, claim for " .. u .. " refused")
        return { ok = false, err = "full" }
    end
    self:changed()
    return { ok = true, user = u, realm = realm }
end

function Directory:applyRelease(srcRealm, body)
    local u = M.normUser(body.user)
    if not u then return { ok = false, err = "bad_name" } end
    local cur = self.users[u]
    if not cur then return { ok = false, err = "unknown_user" } end
    if not self:canManage(srcRealm, cur) then return { ok = false, err = "denied" } end
    self.users[u] = nil
    self:changed()
    return { ok = true, user = u }
end

function Directory:applyRename(srcRealm, body)
    local old = M.normUser(body.old)
    local new = M.normUser(body.new)
    if not old or not new then return { ok = false, err = "bad_name" } end
    local cur = self.users[old]
    if not cur then return { ok = false, err = "unknown_user" } end
    if not self:canManage(srcRealm, cur) then return { ok = false, err = "denied" } end
    if old == new then return { ok = true, user = new, realm = cur } end
    if self.users[new] then return { ok = false, err = "taken" } end
    self.users[new] = cur
    self.users[old] = nil
    if not self:fits() then
        self.users[old] = cur
        self.users[new] = nil
        return { ok = false, err = "full" }
    end
    self:changed()
    return { ok = true, user = new, realm = cur }
end

function Directory:applyRegister(srcRealm, body)
    local realm = util.normRealm(body.realm) or srcRealm
    if realm ~= srcRealm then return { ok = false, err = "denied" } end
    local rec = self.realms[realm]
    if not rec and util.count(self.realms) >= M.MAX_REALMS then return { ok = false, err = "full" } end
    local sid = tonumber(body.serverId)
    local prog = type(body.prog) == "string" and util.sanitize(body.prog):sub(1, 16) or nil
    local fresh = not rec or rec.serverId ~= sid or rec.prog ~= prog
    rec = rec or {}
    rec.serverId = sid
    rec.main = false
    rec.prog = prog
    rec.lastSeen = compat.stamp()
    self.realms[realm] = rec
    if fresh then
        self.log.info("realm registered: " .. realm)
        self:changed()
    else
        self.dirty = true
    end
    local reply = self:snapshot()
    reply.ok = true
    return reply
end

function Directory:apply(src, body)
    if type(body) ~= "table" then return { ok = false, err = "bad_request" } end
    local srcRealm = srcRealmOf(src)
    if not srcRealm then return { ok = false, err = "denied" } end
    local op = body.op
    if op == "lookup" then
        local u = M.normUser(body.user)
        local r = u and self.users[u]
        if not r then return { ok = false, err = "unknown_user" } end
        return { ok = true, user = u, realm = r }
    elseif op == "list" then
        return { ok = true, users = self:list() }
    elseif op == "push" then
        if self.isMain or srcRealm ~= self.mainRealm then return nil end
        self:adopt(body)
        return nil
    end
    if not self.isMain then return { ok = false, err = "not_main" } end
    if op == "register" then return self:applyRegister(srcRealm, body) end
    if op == "claim" then return self:applyClaim(srcRealm, body) end
    if op == "release" then return self:applyRelease(srcRealm, body) end
    if op == "rename" then return self:applyRename(srcRealm, body) end
    return { ok = false, err = "bad_request" }
end

function Directory:handle(msg)
    local reply = self:apply(msg.src, msg.data)
    if reply ~= nil and msg.rq then self.node:reply(msg, reply) end
end

function Directory:userHome(name)
    local u = M.normUser(name)
    return u and self.users[u] or nil
end

function Directory:askMain(body)
    local reply, err = self.node:request(self.mainRealm, "zn.dir", body, 40, { retries = 0 })
    if not reply then
        if err == "timeout" or err == "no_route" then return nil, "offline" end
        return nil, err
    end
    if type(reply) ~= "table" then return nil, "bad reply" end
    return reply
end

function Directory:claim(name)
    local u = M.normUser(name)
    if not u then return nil, "bad_name" end
    if self.isMain then
        local r = self:applyClaim(self.realm, { user = u, realm = self.realm })
        if r.ok then return true end
        return nil, r.err
    end
    local reply, err = self:askMain({ op = "claim", user = u, realm = self.realm })
    if not reply then return nil, err end
    if not reply.ok then return nil, reply.err or "refused" end
    self.users[u] = self.realm
    self:save()
    return true
end

function Directory:release(name)
    local u = M.normUser(name)
    if not u then return nil, "bad_name" end
    if self.isMain then
        local r = self:applyRelease(self.realm, { user = u })
        if r.ok then return true end
        return nil, r.err
    end
    local reply, err = self:askMain({ op = "release", user = u })
    if not reply then return nil, err end
    if not reply.ok then return nil, reply.err or "refused" end
    self.users[u] = nil
    self:save()
    return true
end

function Directory:rename(old, new)
    local o, w = M.normUser(old), M.normUser(new)
    if not o or not w then return nil, "bad_name" end
    if self.isMain then
        local r = self:applyRename(self.realm, { old = o, new = w })
        if r.ok then return true end
        return nil, r.err
    end
    local reply, err = self:askMain({ op = "rename", old = o, new = w })
    if not reply then return nil, err end
    if not reply.ok then return nil, reply.err or "refused" end
    local home = self.users[o] or self.realm
    self.users[o] = nil
    self.users[w] = home
    self:save()
    return true
end

function Directory:list()
    local out = {}
    for _, u in ipairs(util.sortedKeys(self.users)) do
        out[#out + 1] = { name = u, realm = self.users[u] }
    end
    return out
end

function Directory:known(realm)
    return self.realms[realm] ~= nil
end

function Directory:noteProvisioned(realm)
    if not self.isMain then return end
    local rec = self.realms[realm] or {}
    rec.provisioned = compat.stamp()
    rec.main = false
    self.realms[realm] = rec
    self:changed()
end

function Directory:forgetRealm(realm)
    if not self.isMain or realm == self.realm or not self.realms[realm] then return false end
    self.realms[realm] = nil
    self:changed()
    return true
end

function Directory:flush()
    if self.dirty or (self.waitStorage and registry.storageReady(self.ctx)) then self:save() end
end

return M
