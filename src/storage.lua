local need = ...
local compat = need("compat")
local util = need("util")
local seal = need("seal")
local config = need("config")

local M = {}

M.ROLES = { "accounts", "mail", "chat", "audit", "system" }
M.LOCAL_DIR = "/.zelnet/data"
M.LABEL_PREFIX = "ZelNet-"
M.FLOPPY_LIMIT = 125000
M.MARGIN = 512
M.AUDIT_FILE = "log.db"
M.AUDIT_MAX = 300
M.AUDIT_FLUSH = 3
M.INFO_TTL = 10
M.MAX_PROBLEMS = 20
M.COUNT_LIMIT = 2000
M.RECHECK = 5

local ROLE_SET = {}
for _, r in ipairs(M.ROLES) do ROLE_SET[r] = true end

local Storage = {}
Storage.__index = Storage

function M.labelFor(role)
    return M.LABEL_PREFIX .. role:sub(1, 1):upper() .. role:sub(2)
end

function M.roleForLabel(label)
    if type(label) ~= "string" or label:sub(1, #M.LABEL_PREFIX) ~= M.LABEL_PREFIX then return nil end
    local r = label:sub(#M.LABEL_PREFIX + 1):lower()
    if ROLE_SET[r] then return r end
    return nil
end

function M.validRel(rel)
    if type(rel) ~= "string" or rel == "" or #rel > 128 then return false end
    if rel:find("..", 1, true) or rel:find("//", 1, true) then return false end
    if rel:sub(1, 1) == "/" or rel:sub(-1) == "/" then return false end
    return rel:match("^[%w_%-%./]+$") ~= nil
end

local function dcall(name, method, ...)
    local ok, a = pcall(peripheral.call, name, method, ...)
    if ok then return a end
    return nil
end

local function clip(v, n)
    if v == nil then return nil end
    return util.sanitize(tostring(v)):sub(1, n)
end

local BLOCKING = { ["needs cipher block"] = true, ["needs data key"] = true }

function M.new(ctx)
    local self = setmetatable({}, Storage)
    self.ctx = ctx
    self.cfg = ctx.cfg or {}
    self.log = ctx.log or (ctx.node and ctx.node.log) or util.newLogger(50)
    self.roles = {}
    self.blocked = {}
    self.problems = {}
    self.auditRing = {}
    self.auditLoaded = false
    self.auditDirty = false
    self.flushPending = false
    self.counts = {}
    self.inited = false
    return self
end

function Storage:drives()
    local st = self.cfg.storage
    if type(st) ~= "table" then return {} end
    if type(st.drives) ~= "table" then return {} end
    return st.drives
end

function Storage:driveFor(role)
    local d = self:drives()[role]
    if type(d) == "string" and d ~= "" and d ~= "local" then return d end
    return nil
end

function Storage:localBase(role)
    local st = self.cfg.storage
    local dir = type(st) == "table" and type(st.dir) == "string" and st.dir or M.LOCAL_DIR
    return dir .. "/" .. role
end

function Storage:expectedLabel(drive)
    for _, role in ipairs(M.ROLES) do
        if self:driveFor(role) == drive then return M.labelFor(role) end
    end
    return nil
end

function Storage:note(text)
    text = util.sanitize(text)
    for _, p in ipairs(self.problems) do
        if p.text == text then
            p.t = compat.now()
            return
        end
    end
    self.problems[#self.problems + 1] = { text = text, t = compat.now(), s = compat.stamp() }
    while #self.problems > M.MAX_PROBLEMS do table.remove(self.problems, 1) end
    self.log.warn("storage: " .. text)
    if self.ctx.emit then pcall(self.ctx.emit, "storage_problem", text) end
end

function Storage:checkRole(role)
    local drive = self:driveFor(role)
    local r = { role = role, drive = drive, checked = compat.now() }
    if not drive then
        r.base = self:localBase(role)
        r.mount = r.base
        r.state = "local"
        r.label = "local"
        return r
    end
    r.state = "offline"
    if not peripheral.isPresent(drive) or peripheral.getType(drive) ~= "drive" then
        r.problem = drive .. " not found"
        return r
    end
    if not dcall(drive, "isDiskPresent") then
        r.problem = "no disk in " .. drive
        return r
    end
    if not dcall(drive, "hasData") then
        r.problem = "the disk in " .. drive .. " is not a floppy"
        return r
    end
    local mountName = dcall(drive, "getMountPath")
    if type(mountName) ~= "string" or mountName == "" then
        r.problem = "the disk in " .. drive .. " is not mounted"
        return r
    end
    r.mountName = mountName
    r.mount = "/" .. mountName
    local label = dcall(drive, "getDiskLabel")
    local other = M.roleForLabel(label)
    if other and self:driveFor(other) ~= drive and fs.exists(r.mount .. "/" .. other) and not fs.exists(r.mount .. "/" .. role) then
        r.problem = drive .. " holds the " .. M.labelFor(other) .. " disk, expected " .. M.labelFor(role)
        r.label = label
        return r
    end
    local want = self:expectedLabel(drive) or M.labelFor(role)
    if label ~= want then
        if label and label ~= "" then self.log.info("relabeling disk in " .. drive .. " from " .. tostring(label) .. " to " .. want) end
        dcall(drive, "setDiskLabel", want)
        label = want
    end
    r.label = label
    r.base = r.mount .. "/" .. role
    r.state = "online"
    return r
end

function Storage:init()
    local problems = {}
    for _, role in ipairs(M.ROLES) do
        local r = self:checkRole(role)
        self.roles[role] = r
        if r.problem then problems[#problems + 1] = role .. ": " .. r.problem end
    end
    self.inited = true
    local ok = #problems == 0
    if not self.cfg.dataKey and not self:hardware() then
        problems[#problems + 1] = "no data key and no cipher block: storage is not encrypted"
    end
    for _, p in ipairs(problems) do self:note(p) end
    self:loadAudit()
    return ok, problems
end

function Storage:ensureInit()
    if not self.inited then self:init() end
end

function Storage:hardware()
    local c = self.ctx.cipher
    return type(c) == "table" and c.kind == "hardware"
end

function Storage:retry(r)
    if r.state ~= "offline" or not r.drive or compat.now() - (r.checked or 0) < M.RECHECK then return r end
    return self:recheck(r.role)
end

function Storage:recheck(role)
    local before = self.roles[role] and self.roles[role].state
    local r = self:checkRole(role)
    self.roles[role] = r
    self.counts[role] = nil
    if before ~= r.state then
        if r.state == "offline" then
            self:note(role .. ": " .. tostring(r.problem))
            if self.ctx.emit then pcall(self.ctx.emit, "storage_offline", role) end
        else
            self.log.info("storage: " .. role .. " online on " .. tostring(r.drive or "local"))
            if self.ctx.emit then pcall(self.ctx.emit, "storage_online", role) end
            if role == "audit" then self:loadAudit() end
        end
    end
    return r
end

function Storage:ready(role)
    self:ensureInit()
    if role ~= nil then
        local r = self.roles[role]
        if r then r = self:retry(r) end
        return r ~= nil and r.state ~= "offline"
    end
    for _, name in ipairs(M.ROLES) do
        local r = self.roles[name]
        if r then r = self:retry(r) end
        if not r or r.state == "offline" then return false end
    end
    return true
end

function Storage:mounted(r)
    if r.state == "local" then return true end
    if r.state ~= "online" then return false end
    if not dcall(r.drive, "isDiskPresent") or dcall(r.drive, "getMountPath") ~= r.mountName then
        r.state = "offline"
        r.problem = "disk removed from " .. tostring(r.drive)
        self:note(r.role .. ": " .. r.problem)
        if self.ctx.emit then pcall(self.ctx.emit, "storage_offline", r.role) end
        return false
    end
    return true
end

function Storage:resolve(role, rel)
    self:ensureInit()
    local r = self.roles[role]
    if not r then return nil, nil, "unknown role" end
    r = self:retry(r)
    if rel ~= nil and not M.validRel(rel) then return r, nil, "bad path" end
    if not self:mounted(r) then return r, nil, "storage offline" end
    if rel == nil then return r, r.base end
    return r, r.base .. "/" .. rel
end

function Storage:quarantine(path)
    local dest = path .. ".bad"
    local n = 1
    while fs.exists(dest) and n < 9 do
        n = n + 1
        dest = path .. ".bad" .. n
    end
    if fs.exists(dest) then pcall(fs.delete, dest) end
    local ok = pcall(fs.move, path, dest)
    if ok then return dest end
    return nil
end

function Storage:onBadFile(r, rel, path, err)
    err = tostring(err)
    local c = self.ctx.cipher
    local missing = BLOCKING[err] or (self:hardware() and type(c.present) == "function" and not c.present())
    if missing then
        self.blocked[path] = err
        self:note(r.role .. "/" .. rel .. " cannot be opened (" .. err .. "); writes to it are refused")
        return
    end
    local dest = self:quarantine(path)
    self.log.error("storage: " .. r.role .. "/" .. rel .. " failed to open (" .. err .. ")")
    self:note(r.role .. "/" .. rel .. " was unreadable and moved to " .. tostring(dest and fs.getName(dest) or "?"))
end

function Storage:dataKey()
    return self.cfg.dataKey
end

function Storage:sealed()
    return self.cfg.dataKey ~= nil or self:hardware()
end

function Storage:read(role, rel, default)
    local r, path = self:resolve(role, rel)
    if not path then return default end
    if not fs.exists(path) or fs.isDir(path) then return default end
    local text = util.readFile(path)
    if not text or text == "" then return default end
    if self:sealed() and text:find("zs=0,", 1, true) then
        self:onBadFile(r, rel, path, "unsealed file")
        return default
    end
    local v, err = seal.storeOpen(self.ctx.cipher, self:dataKey(), text)
    if v == nil then
        if err ~= nil then self:onBadFile(r, rel, path, err) end
        return default
    end
    self.blocked[path] = nil
    return v
end

function Storage:freeSpace(r)
    local ok, free = pcall(fs.getFreeSpace, r.mount)
    if not ok then
        ok, free = pcall(fs.getFreeSpace, "/")
    end
    if ok then return tonumber(free) end
    return nil
end

function Storage:write(role, rel, value)
    local r, path, err = self:resolve(role, rel)
    if not path then return nil, err end
    if self.blocked[path] then return nil, "storage locked: " .. self.blocked[path] end
    local text, serr = seal.storeSeal(self.ctx.cipher, self:dataKey(), value)
    if not text then return nil, "seal failed: " .. tostring(serr) end
    local free = self:freeSpace(r)
    if free and free < #text + M.MARGIN then
        self:note(role .. ": disk full")
        return nil, "disk full"
    end
    local ok, werr = util.writeFile(path, text)
    if not ok then
        local e = tostring(werr)
        if e:lower():find("space") then e = "disk full" end
        return nil, e
    end
    self.counts[role] = nil
    return true
end

function Storage:delete(role, rel)
    local _, path = self:resolve(role, rel)
    if not path then return false end
    self.blocked[path] = nil
    if fs.exists(path) then
        local ok = pcall(fs.delete, path)
        self.counts[role] = nil
        return ok
    end
    return true
end

function Storage:exists(role, rel)
    local _, path = self:resolve(role, rel)
    return path ~= nil and fs.exists(path)
end

function Storage:list(role, relDir)
    if relDir == "" then relDir = nil end
    local _, path = self:resolve(role, relDir)
    if not path or not fs.exists(path) or not fs.isDir(path) then return {} end
    local ok, names = pcall(fs.list, path)
    if not ok or type(names) ~= "table" then return {} end
    local out = {}
    for _, n in ipairs(names) do
        if n:sub(-4) ~= ".tmp" then out[#out + 1] = n end
    end
    table.sort(out)
    return out
end

local function countFiles(path, acc)
    local ok, names = pcall(fs.list, path)
    if not ok or type(names) ~= "table" then return acc end
    for _, n in ipairs(names) do
        if acc.n >= M.COUNT_LIMIT then return acc end
        local p = path .. "/" .. n
        if fs.isDir(p) then
            countFiles(p, acc)
        else
            acc.n = acc.n + 1
            local sok, size = pcall(fs.getSize, p)
            if sok and tonumber(size) then acc.bytes = acc.bytes + size end
        end
    end
    return acc
end

function Storage:countRole(r)
    local c = self.counts[r.role]
    local now = compat.now()
    if c and now - c.t < M.INFO_TTL then return c end
    c = { n = 0, bytes = 0, t = now }
    if r.base and r.state ~= "offline" and fs.exists(r.base) then countFiles(r.base, c) end
    self.counts[r.role] = c
    return c
end

function Storage:info()
    self:ensureInit()
    local out = {}
    for _, role in ipairs(M.ROLES) do
        local r = self.roles[role]
        if r.state == "online" then self:mounted(r) end
        local c = self:countRole(r)
        out[#out + 1] = {
            role = role, drive = r.drive, label = r.label, mount = r.mount, present = r.state ~= "offline",
            free = r.state ~= "offline" and self:freeSpace(r) or nil, files = c.n, used = c.bytes,
            state = r.state, problem = r.problem, title = M.labelFor(role):sub(#M.LABEL_PREFIX + 1),
        }
    end
    return out
end

function Storage:problemList()
    local out = {}
    for i = #self.problems, 1, -1 do out[#out + 1] = util.copy(self.problems[i]) end
    return out
end

local function walk(path, rel, out)
    local ok, names = pcall(fs.list, path)
    if not ok or type(names) ~= "table" then return out end
    for _, n in ipairs(names) do
        local p = path .. "/" .. n
        local q = rel and (rel .. "/" .. n) or n
        if fs.isDir(p) then
            walk(p, q, out)
        elseif n:sub(-4) ~= ".tmp" then
            local sok, size = pcall(fs.getSize, p)
            out[#out + 1] = { rel = q, size = sok and tonumber(size) or 0 }
        end
    end
    return out
end

function Storage:migrate(old, new)
    if not old.base or not fs.exists(old.base) then return true end
    if fs.exists(new.base) and #walk(new.base, nil, {}) > 0 then
        self.log.info("storage: " .. new.role .. " already has data on the new location, keeping it")
        return true
    end
    local files = walk(old.base, nil, {})
    local total = 0
    for _, f in ipairs(files) do total = total + f.size end
    local free = self:freeSpace(new)
    if free and free < total + M.MARGIN then return nil, "not enough space for " .. util.fmtBytes(total) end
    for _, f in ipairs(files) do
        local ok, err = pcall(fs.copy, old.base .. "/" .. f.rel, new.base .. "/" .. f.rel)
        if not ok then
            pcall(fs.delete, new.base)
            return nil, "copy failed: " .. tostring(err)
        end
        compat.breathe()
    end
    pcall(fs.delete, old.base)
    return true
end

function Storage:assign(role, driveName)
    self:ensureInit()
    if not ROLE_SET[role] then return nil, "unknown role" end
    if driveName == "" or driveName == "local" then driveName = nil end
    if driveName and (not peripheral.isPresent(driveName) or peripheral.getType(driveName) ~= "drive") then
        return nil, "not a disk drive"
    end
    local cfg = self.cfg
    if type(cfg.storage) ~= "table" then cfg.storage = {} end
    if type(cfg.storage.drives) ~= "table" then cfg.storage.drives = {} end
    local old = self.roles[role]
    local prev = cfg.storage.drives[role]
    cfg.storage.drives[role] = driveName
    local r = self:checkRole(role)
    local ok, err = r.state ~= "offline", r.problem
    if ok and old and old.state ~= "offline" and old.base ~= r.base then ok, err = self:migrate(old, r) end
    if not ok then
        cfg.storage.drives[role] = prev
        self.roles[role] = self:checkRole(role)
        return nil, err or "drive offline"
    end
    self.roles[role] = r
    self.counts[role] = nil
    if cfg.zn == 1 then pcall(config.save, cfg) end
    if role == "audit" then self:loadAudit() end
    self:audit("console", "storage_assign", role, driveName or "local", true)
    return true
end

function Storage:onDiskEvent(ev, side)
    self:ensureInit()
    local touched = false
    for _, role in ipairs(M.ROLES) do
        local drive = self:driveFor(role)
        if drive and (side == nil or drive == side) then
            touched = true
            self:recheck(role)
        end
    end
    if touched then
        for path in pairs(self.blocked) do self.blocked[path] = nil end
    end
    return touched
end

function Storage:loadAudit()
    if self.auditLoaded then return true end
    if not self:ready("audit") then return false end
    local stored = self:read("audit", M.AUDIT_FILE, nil)
    local entries = type(stored) == "table" and type(stored.entries) == "table" and stored.entries or {}
    local merged = {}
    for _, e in ipairs(entries) do
        if type(e) == "table" then merged[#merged + 1] = e end
    end
    for _, e in ipairs(self.auditRing) do merged[#merged + 1] = e end
    while #merged > M.AUDIT_MAX do table.remove(merged, 1) end
    self.auditRing = merged
    self.auditLoaded = true
    if #entries ~= #merged then self.auditDirty = true end
    return true
end

function Storage:flushAudit()
    self.flushPending = false
    if not self.auditDirty then return true end
    if not self.auditLoaded and not self:loadAudit() then return nil, "storage offline" end
    local ok, err = self:write("audit", M.AUDIT_FILE, { v = 1, entries = self.auditRing })
    if ok then self.auditDirty = false end
    return ok, err
end

function Storage:flush()
    return self:flushAudit()
end

function Storage:audit(actor, action, target, detail, ok)
    local e = {
        s = compat.stamp(), actor = clip(actor or "?", 24), action = clip(action or "?", 32),
        target = clip(target, 40), detail = clip(detail, 80), ok = ok ~= false,
    }
    self.auditRing[#self.auditRing + 1] = e
    while #self.auditRing > M.AUDIT_MAX do table.remove(self.auditRing, 1) end
    self.auditDirty = true
    local n = self.ctx.node
    if n and n.running and type(n.after) == "function" then
        if not self.flushPending then
            self.flushPending = true
            n:after(M.AUDIT_FLUSH, function() self:flushAudit() end, "audit-flush")
        end
    else
        self:flushAudit()
    end
    return e
end

function Storage:auditTail(n)
    n = math.max(1, math.floor(tonumber(n) or 50))
    local out = {}
    for i = #self.auditRing, math.max(1, #self.auditRing - n + 1), -1 do
        out[#out + 1] = util.copy(self.auditRing[i])
    end
    return out
end

M.Storage = Storage

return M
