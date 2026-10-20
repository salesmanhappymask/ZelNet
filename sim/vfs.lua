local marshal = require("sim.marshal")
local util = require("sim.util")

local M = {}

local MIN = 512
local fail = util.fail
local floor, max = math.floor, math.max
local byte, char, concat, sub, find, gsub = string.byte, string.char, table.concat, string.sub, string.find, string.gsub

local BAD = { [34] = true, [58] = true, [60] = true, [62] = true, [63] = true, [124] = true }

function M.sanitize(path, wild)
    path = gsub(path, "\\", "/")
    local clean = {}
    for i = 1, #path do
        local c = byte(path, i)
        if c >= 32 and not BAD[c] and (wild or c ~= 42) then clean[#clean + 1] = char(c) end
    end
    path = concat(clean)
    local out = {}
    for part in string.gmatch(path, "[^/]+") do
        if part == "." then
        elseif part == ".." then
            if #out > 0 and out[#out] ~= ".." then
                out[#out] = nil
            else
                out[#out + 1] = ".."
            end
        elseif #part >= 255 then
            out[#out + 1] = sub(part, 1, 255)
        else
            out[#out + 1] = part
        end
    end
    return concat(out, "/")
end

function M.combine(a, b)
    a = M.sanitize(a, true)
    b = M.sanitize(b, true)
    if a == "" then return b end
    if b == "" then return a end
    return M.sanitize(a .. "/" .. b, true)
end

function M.getDir(p)
    p = M.sanitize(p, true)
    if p == "" then return ".." end
    local i = p:match("^.*()/")
    if i then return sub(p, 1, i - 1) end
    return ""
end

function M.getName(p)
    p = M.sanitize(p, true)
    if p == "" then return "root" end
    local i = p:match("^.*()/")
    if i then return sub(p, i + 1) end
    return p
end

local function contains(a, b)
    a = M.sanitize(a)
    b = M.sanitize(b)
    if b == ".." or sub(b, 1, 3) == "../" then return false end
    if b == a then return true end
    if a == "" then return true end
    return sub(b, 1, #a + 1) == a .. "/"
end
M.contains = contains

local function toLocal(path, loc)
    if loc == "" then return path end
    if path == loc then return "" end
    return sub(path, #loc + 2)
end

local function parts(path)
    local out = {}
    for p in string.gmatch(path, "[^/]+") do out[#out + 1] = p end
    return out
end

local MemMount = {}
MemMount.__index = MemMount
M.MemMount = MemMount

function MemMount.new(capacity)
    return setmetatable({ root = { children = {} }, capacity = capacity or 1000000, used = 0, created = false }, MemMount)
end

function MemMount:node(path)
    local n = self.root
    if path == "" then return n end
    for _, part in ipairs(parts(path)) do
        if not n.children then return nil end
        n = n.children[part]
        if not n then return nil end
    end
    return n
end

local function measure(n)
    if n.children then
        local total = MIN
        for _, c in pairs(n.children) do total = total + measure(c) end
        return total
    end
    return max(#n.data, MIN)
end

function MemMount:remeasure()
    if self.created or next(self.root.children) then
        self.created = true
        self.used = measure(self.root)
    else
        self.used = 0
    end
end

function MemMount:remaining()
    return max(self.capacity - self.used, 0)
end

function MemMount:exists(path)
    if path == "" then return true end
    return self:node(path) ~= nil
end

function MemMount:isDir(path)
    local n = self:node(path)
    return n ~= nil and n.children ~= nil
end

function MemMount:list(path)
    local n = self:node(path)
    if not n or not n.children then fail("Not a directory") end
    local out = {}
    for name in pairs(n.children) do out[#out + 1] = name end
    return out
end

function MemMount:getSize(path)
    local n = self:node(path)
    if not n then fail("No such file") end
    if n.children then return 0 end
    return #n.data
end

function MemMount:read(path)
    local n = self:node(path)
    if not n or n.children then fail("No such file") end
    return n.data
end

function MemMount:mkdirs(path)
    local n = self.root
    for _, part in ipairs(parts(path)) do
        local c = n.children[part]
        if not c then
            c = { children = {} }
            n.children[part] = c
        elseif not c.children then
            fail("File exists")
        end
        n = c
    end
    return n
end

function MemMount:makeDir(path)
    self.created = true
    local n = self:node(path)
    if n then
        if not n.children then fail("File exists") end
        return
    end
    if self:remaining() < MIN then fail("Out of space") end
    self:mkdirs(path)
    self.used = self.used - MIN
end

local function freeSubtree(self, n)
    if n.children then
        for _, c in pairs(n.children) do freeSubtree(self, c) end
        self.used = self.used - MIN
    else
        self.used = self.used - max(MIN, #n.data)
    end
end

function MemMount:delete(path)
    if path == "" then fail("Access denied") end
    if not self.created then return end
    local ps = parts(path)
    local parent = self:node(concat(ps, "/", 1, #ps - 1))
    if not parent or not parent.children then return end
    local n = parent.children[ps[#ps]]
    if not n then return end
    freeSubtree(self, n)
    parent.children[ps[#ps]] = nil
end

function MemMount:openWrite(path, append)
    local n = self:node(path)
    if append then
        if not self.created or not n then fail("No such file") end
        if n.children then fail("Cannot write to directory") end
        return { mount = self, node = n, ignore = max(MIN - #n.data, 0), pending = {} }
    end
    self.created = true
    if n and n.children then fail("Cannot write to directory") end
    if not n then
        if self:remaining() < MIN then fail("Out of space") end
        self.used = self.used + MIN
        local ps = parts(path)
        local dir = self:mkdirs(concat(ps, "/", 1, #ps - 1))
        n = { data = "" }
        dir.children[ps[#ps]] = n
    else
        self.used = self.used - max(#n.data, MIN) + MIN
        n.data = ""
    end
    return { mount = self, node = n, ignore = MIN, pending = {} }
end

function MemMount:writeBytes(w, bytes)
    local len = #bytes
    if len == 0 then return true end
    local left = w.ignore - len
    if left >= 0 then
        w.ignore = left
    else
        w.ignore = 0
        if -left > self.capacity - self.used then return false end
        self.used = self.used - left
    end
    w.pending[#w.pending + 1] = bytes
    return true
end

function MemMount:flush(w)
    if #w.pending > 0 then
        w.node.data = w.node.data .. concat(w.pending)
        w.pending = {}
    end
end

function MemMount:setFile(path, data)
    local ps = parts(path)
    local dir = self:mkdirs(concat(ps, "/", 1, #ps - 1))
    dir.children[ps[#ps]] = { data = data }
    self.created = true
    self:remeasure()
end

function MemMount:getFile(path)
    local n = self:node(path)
    if n and not n.children then return n.data end
    return nil
end

function MemMount:snapshot(prefix, out)
    out = out or {}
    local function walk(n, p)
        for name, c in pairs(n.children) do
            local cp = p == "" and name or (p .. "/" .. name)
            if c.children then walk(c, cp) else out[cp] = c.data end
        end
    end
    walk(self.root, prefix or "")
    return out
end

local HostMount = {}
HostMount.__index = HostMount
M.HostMount = HostMount

local hostCache = {}

local function shellQuote(s)
    return "'" .. gsub(s, "'", "'\\''") .. "'"
end

function HostMount.new(dir)
    local cached = hostCache[dir]
    if cached then return cached end
    local self = setmetatable({ dir = dir, nodes = { [""] = { children = {} } } }, HostMount)
    local p = io.popen("find " .. shellQuote(dir) .. " -mindepth 1 -printf '%y %P\\n' 2>/dev/null")
    local entries = {}
    if p then
        for line in p:lines() do entries[#entries + 1] = line end
        p:close()
    end
    table.sort(entries, function(a, b) return #a < #b or (#a == #b and a < b) end)
    for _, line in ipairs(entries) do
        local kind, rel = line:match("^(%a) (.+)$")
        if kind and rel then
            local parent = rel:match("^(.*)/[^/]+$") or ""
            local name = rel:match("([^/]+)$")
            local pn = self.nodes[parent]
            if pn and pn.children then
                local node
                if kind == "d" then node = { children = {} } else node = { file = dir .. "/" .. rel } end
                pn.children[name] = node
                self.nodes[rel] = node
            end
        end
    end
    hostCache[dir] = self
    return self
end

function HostMount:node(path)
    return self.nodes[path]
end

function HostMount:exists(path)
    return self.nodes[path] ~= nil
end

function HostMount:isDir(path)
    local n = self.nodes[path]
    return n ~= nil and n.children ~= nil
end

function HostMount:list(path)
    local n = self.nodes[path]
    if not n or not n.children then fail("Not a directory") end
    local out = {}
    for name in pairs(n.children) do out[#out + 1] = name end
    return out
end

function HostMount:read(path)
    local n = self.nodes[path]
    if not n or n.children then fail("No such file") end
    if not n.data then
        local f = io.open(n.file, "rb")
        if not f then fail("No such file") end
        n.data = f:read("*a")
        f:close()
    end
    return n.data
end

function HostMount:getSize(path)
    local n = self.nodes[path]
    if not n then fail("No such file") end
    if n.children then return 0 end
    return #self:read(path)
end

function HostMount:remaining()
    return 0
end

local FS = {}
FS.__index = FS
M.FileSystem = FS

function FS.new()
    return setmetatable({ mounts = {}, writers = {} }, FS)
end

function FS:mount(label, location, mount, writable)
    location = M.sanitize(location)
    if location == ".." or sub(location, 1, 3) == "../" then fail("Cannot mount below the root") end
    self.mounts[location] = { label = label, location = location, mount = mount, writable = writable and true or false }
end

function FS:unmount(location)
    self.mounts[M.sanitize(location)] = nil
end

function FS:getMount(path)
    if path == ".." or sub(path, 1, 3) == "../" then fail("Invalid Path") end
    local best, bestLen = nil, -1
    for loc, m in pairs(self.mounts) do
        if (loc == "" or path == loc or sub(path, 1, #loc + 1) == loc .. "/") and #loc > bestLen then
            best, bestLen = m, #loc
        end
    end
    if not best then fail("Invalid Path") end
    return best, toLocal(path, best.location)
end

function FS:exists(path)
    path = M.sanitize(path)
    local m, l = self:getMount(path)
    return m.mount:exists(l)
end

function FS:isDir(path)
    path = M.sanitize(path)
    local m, l = self:getMount(path)
    return m.mount:exists(l) and m.mount:isDir(l)
end

function FS:isReadOnly(path)
    path = M.sanitize(path)
    local m = self:getMount(path)
    return not m.writable
end

function FS:list(path)
    path = M.sanitize(path)
    local m, l = self:getMount(path)
    if not m.mount:exists(l) or not m.mount:isDir(l) then fail("Not a directory") end
    local out = m.mount:list(l)
    for loc in pairs(self.mounts) do
        if loc ~= "" and M.getDir(loc) == path then out[#out + 1] = M.getName(loc) end
    end
    table.sort(out)
    return out
end

function FS:getSize(path)
    path = M.sanitize(path)
    local m, l = self:getMount(path)
    if not m.mount:exists(l) then fail("No such file") end
    if m.mount:isDir(l) then return 0 end
    return m.mount:getSize(l)
end

function FS:makeDir(path)
    path = M.sanitize(path)
    local m, l = self:getMount(path)
    if not m.writable then fail("Access Denied") end
    if m.mount:exists(l) then
        if not m.mount:isDir(l) then fail("File exists") end
        return
    end
    m.mount:makeDir(l)
end

function FS:delete(path)
    path = M.sanitize(path)
    local m, l = self:getMount(path)
    if not m.writable then fail("Access Denied") end
    if m.mount:exists(l) then m.mount:delete(l) end
end

function FS:read(path)
    path = M.sanitize(path)
    local m, l = self:getMount(path)
    if not m.mount:exists(l) or m.mount:isDir(l) then fail("No such file") end
    return m.mount:read(l)
end

function FS:openWrite(path, append)
    path = M.sanitize(path)
    local m, l = self:getMount(path)
    if not m.writable then fail("Access Denied") end
    local exists = m.mount:exists(l)
    if exists and m.mount:isDir(l) then fail("Cannot write to directory") end
    if not exists then
        local d = M.getDir(l)
        if l ~= "" and d ~= "" and not m.mount:exists(d) then m.mount:makeDir(d) end
        append = false
    end
    local w = m.mount:openWrite(l, append)
    self.writers[w] = true
    return w
end

function FS:closeWriter(w)
    if self.writers[w] then
        if w.drain then w.drain() end
        w.mount:flush(w)
        self.writers[w] = nil
    end
end

function FS:closeAll()
    for w in pairs(self.writers) do
        if w.drain then w.drain() end
        w.mount:flush(w)
    end
    self.writers = {}
end

function FS:copyRecursive(src, sm, sl, dst, dm, dl)
    if not sm.mount:exists(sl) then return end
    if sm.mount:isDir(sl) then
        dm.mount:makeDir(dl)
        for _, child in ipairs(sm.mount:list(sl)) do
            self:copyRecursive(M.combine(src, child), sm, M.combine(sl, child), M.combine(dst, child), dm, M.combine(dl, child))
        end
    else
        local data = sm.mount:read(sl)
        local d = M.getDir(dl)
        if dl ~= "" and d ~= "" and not dm.mount:exists(d) then dm.mount:makeDir(d) end
        local w = dm.mount:openWrite(dl, false)
        local ok = dm.mount:writeBytes(w, data)
        dm.mount:flush(w)
        if not ok then fail("Out of space") end
    end
end

function FS:move(src, dst)
    src = M.sanitize(src)
    dst = M.sanitize(dst)
    if self:isReadOnly(src) or self:isReadOnly(dst) then fail("Access denied") end
    if not self:exists(src) then fail("No such file") end
    if self:exists(dst) then fail("File exists") end
    if contains(src, dst) then fail("Can't move a directory inside itself") end
    local sm, sl = self:getMount(src)
    local dm, dl = self:getMount(dst)
    self:copyRecursive(src, sm, sl, dst, dm, dl)
    sm.mount:delete(sl)
end

function FS:copy(src, dst)
    src = M.sanitize(src)
    dst = M.sanitize(dst)
    if self:isReadOnly(dst) then fail("Access denied") end
    if not self:exists(src) then fail("No such file") end
    if self:exists(dst) then fail("File exists") end
    if contains(src, dst) then fail("Can't copy a directory inside itself") end
    local sm, sl = self:getMount(src)
    local dm, dl = self:getMount(dst)
    self:copyRecursive(src, sm, sl, dst, dm, dl)
end

function FS:getFreeSpace(path)
    path = M.sanitize(path)
    local m = self:getMount(path)
    if not m.writable then return 0 end
    return m.mount:remaining()
end

function FS:getDrive(path)
    path = M.sanitize(path)
    if self:exists(path) then
        local m = self:getMount(path)
        return m.label
    end
    return nil
end

function FS:find(pattern)
    pattern = M.sanitize(pattern, true)
    local star = find(pattern, "*", 1, true)
    if not star then
        if self:exists(pattern) then return { pattern } end
        return {}
    end
    local before = sub(pattern, 1, star)
    local slash = before:match("^.*()/")
    local start = slash and sub(pattern, 1, slash - 1) or ""
    if not self:isDir(start) then return {} end
    local lp = "^" .. gsub(gsub(pattern, "[%^%$%(%)%%%.%[%]%+%-%?]", "%%%0"), "%*", "[^/]*") .. "$"
    local out = {}
    local function walk(dir)
        for _, entry in ipairs(self:list(dir)) do
            local p = dir == "" and entry or (dir .. "/" .. entry)
            if find(p, lp) then out[#out + 1] = p end
            if self:isDir(p) then walk(p) end
        end
    end
    walk(start)
    return out
end

local function argStr(v)
    return type(v) == "string"
end

local function javaText(v)
    if v == nil then return "" end
    if type(v) == "string" then return v end
    return marshal.javaToString(marshal.toJava(v))
end

local function textReader(text)
    local pos = 1
    local len = #text
    local closed = false
    local h = {}
    local function readLine()
        if closed or pos > len then return nil end
        local s, e = find(text, "[\r\n]", pos)
        local line
        if not s then
            line = sub(text, pos)
            pos = len + 1
        else
            line = sub(text, pos, s - 1)
            if sub(text, s, s) == "\r" and sub(text, s + 1, s + 1) == "\n" then
                pos = s + 2
            else
                pos = s + 1
            end
        end
        return line
    end
    h.readLine = function()
        return readLine()
    end
    h.readAll = function()
        if closed then return nil end
        local out = {}
        local line = readLine()
        while line do
            out[#out + 1] = line
            line = readLine()
        end
        return concat(out, "\n")
    end
    h.close = function()
        closed = true
    end
    return h
end

local function binaryReader(data)
    local pos = 1
    local closed = false
    local h = {}
    h.read = function()
        if closed then return nil end
        local b = byte(data, pos)
        if b then pos = pos + 1 end
        return b
    end
    h.close = function()
        closed = true
    end
    return h
end

local TEXT_CHUNK = 8192

local function writerHandle(fsys, w, binary)
    local closed = false
    local h = {}
    local native = util.native
    if binary then
        h.write = native(function(v)
            if closed then fail("Stream closed") end
            if type(v) == "number" then
                local iv = util.toInt(v)
                if not w.mount:writeBytes(w, char(iv % 256)) then fail("Out of space") end
            end
        end)
    else
        local buf, blen = {}, 0
        local function push(bytes)
            if #bytes == 0 then return end
            buf[#buf + 1] = bytes
            blen = blen + #bytes
            if blen < 2 * TEXT_CHUNK then return end
            local data = concat(buf)
            local pos, full = 1, false
            while #data - pos + 1 >= 2 * TEXT_CHUNK do
                local chunk = sub(data, pos, pos + TEXT_CHUNK - 1)
                pos = pos + TEXT_CHUNK
                if not w.mount:writeBytes(w, chunk) then
                    full = true
                    break
                end
            end
            local rest = sub(data, pos)
            buf, blen = { rest }, #rest
            if full then fail("Out of space") end
        end
        w.drain = function()
            if blen > 0 then
                local data = concat(buf)
                buf, blen = {}, 0
                w.mount:writeBytes(w, data)
            end
        end
        h.write = native(function(v)
            if closed then fail("Stream closed") end
            push(marshal.textToFileBytes(javaText(v)))
        end)
        h.writeLine = native(function(v)
            if closed then fail("Stream closed") end
            push(marshal.textToFileBytes(javaText(v)) .. "\n")
        end)
    end
    h.flush = function()
        if closed then return end
        if w.drain then w.drain() end
        w.mount:flush(w)
    end
    h.close = function()
        if closed then return end
        closed = true
        fsys:closeWriter(w)
    end
    return h
end

function M.makeApi(fsys)
    local api = {}
    local native = util.native
    local function str1(v)
        if not argStr(v) then fail("Expected string") end
    end
    local function str2(a, b)
        if not argStr(a) or not argStr(b) then fail("Expected string, string") end
    end
    api.list = native(function(p)
        str1(p)
        return fsys:list(p)
    end)
    api.combine = native(function(a, b)
        str2(a, b)
        return M.combine(a, b)
    end)
    api.getName = native(function(p)
        str1(p)
        return M.getName(p)
    end)
    api.getSize = native(function(p)
        str1(p)
        return fsys:getSize(p)
    end)
    api.exists = native(function(p)
        str1(p)
        local ok, r = pcall(fsys.exists, fsys, p)
        return ok and r or false
    end)
    api.isDir = native(function(p)
        str1(p)
        local ok, r = pcall(fsys.isDir, fsys, p)
        return ok and r or false
    end)
    api.isReadOnly = native(function(p)
        str1(p)
        local ok, r = pcall(fsys.isReadOnly, fsys, p)
        return ok and r or false
    end)
    api.makeDir = native(function(p)
        str1(p)
        fsys:makeDir(p)
    end)
    api.move = native(function(a, b)
        str2(a, b)
        fsys:move(a, b)
    end)
    api.copy = native(function(a, b)
        str2(a, b)
        fsys:copy(a, b)
    end)
    api.delete = native(function(p)
        str1(p)
        fsys:delete(p)
    end)
    api.open = native(function(p, mode)
        str2(p, mode)
        if mode == "r" then
            local ok, data = pcall(fsys.read, fsys, p)
            if not ok then return nil end
            return textReader(marshal.fileBytesToText(data))
        elseif mode == "rb" then
            local ok, data = pcall(fsys.read, fsys, p)
            if not ok then return nil end
            return binaryReader(data)
        elseif mode == "w" or mode == "a" or mode == "wb" or mode == "ab" then
            local append = mode == "a" or mode == "ab"
            local ok, w = pcall(fsys.openWrite, fsys, p, append)
            if not ok then return nil end
            return writerHandle(fsys, w, mode == "wb" or mode == "ab")
        end
        fail("Unsupported mode")
    end)
    api.getDrive = native(function(p)
        str1(p)
        return fsys:getDrive(p)
    end)
    api.getFreeSpace = native(function(p)
        str1(p)
        return fsys:getFreeSpace(p)
    end)
    api.find = native(function(p)
        str1(p)
        return fsys:find(p)
    end)
    api.getDir = native(function(p)
        str1(p)
        return M.getDir(p)
    end)
    return api
end

return M
