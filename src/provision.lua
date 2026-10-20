local need = ...
local compat = need("compat")
local util = need("util")
local codec = need("codec")
local version = need("version")

local M = {}

M.FILES = { program = "zelnet", packed = "zelnet.z", config = "zelnet.cfg", installer = "startup" }
M.OURS = { zelnet = true, ["zelnet.z"] = true, ["zelnet.cfg"] = true, startup = true, ["zelnet.tmp"] = true }
M.PART_SIZE = 118000
M.MARGIN = 1024
M.MAX_DIST = 728999
M.TRIES = 16
M.SERVER_ONLY = {
    storage = true, registry = true, directory = true, bridge = true, backbone = true,
    server = true, tekmail = true, airlock = true, serverui = true, panels = true, updater = true,
}
M.MAGIC = "ZNPK1"

local DIGITS, VALUES = {}, {}
do
    local k = 0
    for c = 36, 126 do
        if c ~= 96 then
            DIGITS[k] = string.char(c)
            VALUES[c] = k
            k = k + 1
        end
    end
end

local cache = { key = nil, packed = nil, build = nil, buildKey = nil }

local function dcall(name, method, ...)
    local ok, a = pcall(peripheral.call, name, method, ...)
    if ok then return a end
    return nil
end

local function toSet(list)
    local set = {}
    for k, v in pairs(list or {}) do
        if type(k) == "number" then set[v] = true elseif v then set[k] = true end
    end
    return set
end

function M.excludeFor(cfg, keepSetup)
    local set = {}
    local disp = type(cfg) == "table" and cfg.displays
    if not keepSetup and type(disp) == "table" and type(disp.drive) == "string" then set[disp.drive] = true end
    local st = type(cfg) == "table" and cfg.storage
    if type(st) == "table" and type(st.drives) == "table" then
        for _, d in pairs(st.drives) do
            if type(d) == "string" then set[d] = true end
        end
    end
    for _, b in ipairs(type(cfg) == "table" and cfg.bridges or {}) do
        if type(b) == "table" then
            if b.sendDrive then set[b.sendDrive] = true end
            if b.recvDrive then set[b.recvDrive] = true end
        end
    end
    return set
end

local function diskFiles(mount)
    local ok, list = pcall(fs.list, mount)
    if not ok or type(list) ~= "table" then return {}, {} end
    local ours, foreign = {}, {}
    for _, n in ipairs(list) do
        if M.OURS[n] then ours[#ours + 1] = n else foreign[#foreign + 1] = n end
    end
    return ours, foreign
end

function M.drives(exclude)
    local skip = toSet(exclude)
    local out = {}
    local names = peripheral.getNames and peripheral.getNames() or {}
    for _, name in ipairs(names) do
        if not skip[name] and peripheral.getType(name) == "drive" then
            local d = { name = name, present = dcall(name, "isDiskPresent") == true }
            if d.present then
                d.hasData = dcall(name, "hasData") == true
                d.label = dcall(name, "getDiskLabel")
                d.diskId = dcall(name, "getDiskID")
                if d.hasData then
                    d.mount = dcall(name, "getMountPath")
                    if d.mount then
                        local ok, free = pcall(fs.getFreeSpace, d.mount)
                        d.free = ok and tonumber(free) or nil
                        local ours, foreign = diskFiles(d.mount)
                        d.files = #ours + #foreign
                        d.foreign = #foreign
                        d.zelnet = #ours > 0
                    end
                end
            end
            d.empty = d.hasData == true and (d.files or 0) == 0
            out[#out + 1] = d
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

function M.setProgramPath(path)
    M.programPath = path
end

local function isBundle(text)
    return type(text) == "string" and text:sub(1, 27) ~= 'local __mods, ZN = "packed"' and text:find("__mods[\"main\"]", 1, true) ~= nil
end

M.isBundle = isBundle

local STUB = [==[
local __mods, ZN = "packed", { program = "%PROGRAM%", build = "%BUILD%", size = %LEN% }
if shell and shell.getRunningProgram and print then
local ok, run = pcall(shell.getRunningProgram)
if ok and type(run) == "string" and string.find(string.lower(run), "zelnet", 1, true) then print("Starting ZelNet " .. ZN.program .. "+" .. ZN.build .. " ...") end
end
local P = [@@[
%PACKED%]@@]
local V = {}
do
local k = 0
for c = 36, 126 do
if c ~= 96 then V[c] = k k = k + 1 end
end
end
local function breathe()
if os and os.queueEvent and coroutine.running() then
os.queueEvent("zn_unpack")
os.pullEvent("zn_unpack")
end
end
local function U(s)
local out, n = {}, 0
local pos, len = 1, #s
local mark = 0
while pos <= len do
local q = string.find(s, "`", pos, true)
local stop = len
if q then stop = q - 1 end
for k = pos, stop do
n = n + 1
out[n] = string.sub(s, k, k)
end
if not q then break end
local c2 = string.byte(s, q + 1)
if c2 == 96 then
n = n + 1
out[n] = "`"
pos = q + 2
else
local v = V[c2]
local a = V[string.byte(s, q + 2) or 0]
local b = V[string.byte(s, q + 3) or 0]
local ln, dist
if v < 45 then
ln = v + 5
dist = a * 90 + b
pos = q + 4
else
local c = V[string.byte(s, q + 4) or 0]
ln = v - 39
dist = a * 8100 + b * 90 + c
pos = q + 5
end
local from = n - dist
for k = 1, ln do
n = n + 1
out[n] = out[from + k]
end
end
if n - mark > 20000 then
mark = n
breathe()
end
end
return table.concat(out)
end
local prog = U(P)
P = nil
if #prog ~= ZN.size then error("ZelNet did not unpack correctly; download it again", 0) end
local fn, err = loadstring(prog, "=zelnet")
prog = nil
if not fn then error(err, 0) end
setfenv(fn, getfenv(1))
return fn(...)
]==]

M.STUB_HEAD = 'local __mods, ZN = "packed"'

function M.isPacked(text)
    return type(text) == "string" and text:sub(1, #M.STUB_HEAD) == M.STUB_HEAD
end

function M.makeStub(build)
    local packed = M.pack(build)
    local level = 1
    while packed:find("]" .. string.rep("=", level) .. "]", 1, true) do level = level + 1 end
    local eq = string.rep("=", level)
    local program = build:match('program%s*=%s*"(%d[%w%.%-_]*)"') or "0"
    local buildId = build:match('build%s*=%s*"(%w+)"') or "dev"
    local head = STUB:gsub("@@", eq):gsub("%%PROGRAM%%", program):gsub("%%BUILD%%", buildId):gsub("%%LEN%%", tostring(#build))
    local i = head:find("%PACKED%", 1, true)
    return head:sub(1, i - 1) .. packed .. head:sub(i + #"%PACKED%")
end

function M.expand(text)
    if not M.isPacked(text) then return text end
    local _, e, eq = text:find("local P = %[(=*)%[\n")
    if not e then return nil, "damaged packed program" end
    local close = text:find("]" .. eq .. "]", e + 1, true)
    if not close then return nil, "damaged packed program" end
    local out = M.unpack(text:sub(e + 1, close - 1))
    local size = tonumber(text:match("size = (%d+)"))
    if not out or (size and #out ~= size) then return nil, "damaged packed program" end
    return out
end

function M.programText()
    local tried = {}
    local function try(path)
        if type(path) ~= "string" or path == "" or tried[path] then return nil end
        tried[path] = true
        local text = util.readFile(path)
        if text and (isBundle(text) or M.isPacked(text)) then return text end
        return nil
    end
    local text = try(M.programPath)
    if text then return text, M.programPath end
    local sh = shell
    if type(sh) == "table" and sh.getRunningProgram then
        local ok, p = pcall(sh.getRunningProgram)
        if ok and type(p) == "string" then
            p = "/" .. p:gsub("^/+", "")
            text = try(p)
            if text then return text, p end
        end
    end
    text = try("/zelnet")
    if text then return text, "/zelnet" end
    return nil, "cannot find the ZelNet program file"
end

local function normLines(text)
    return (text:gsub("\r\n", "\n"):gsub("\r", "\n"))
end

function M.minify(text)
    text = normLines(text)
    local out = {}
    local closeTag = nil
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        if closeTag then
            out[#out + 1] = line
            if line:find(closeTag, 1, true) then closeTag = nil end
        else
            local s = line:match("^%s*(.-)%s*$")
            if s ~= "" then
                out[#out + 1] = s
                local eq = s:match("%[(=*)%[")
                if eq then
                    local tag = "]" .. eq .. "]"
                    local open = s:find("[" .. eq .. "[", 1, true)
                    if not s:find(tag, open + #eq + 2, true) then closeTag = tag end
                end
            end
        end
    end
    return table.concat(out, "\n") .. "\n"
end

function M.splitBundle(text)
    local first = text:find("\n__mods%[\"")
    if not first then return nil end
    local tailAt = text:find("\nreturn need%(\"main\"%)")
    if not tailAt then return nil end
    local res = { head = text:sub(1, first), tail = text:sub(tailAt + 1), mods = {} }
    local pos = first + 1
    while pos <= tailAt do
        local name = text:match("^__mods%[\"([%w_]+)\"%]", pos)
        if not name then return nil end
        local nextAt = text:find("\n__mods%[\"", pos)
        local stop = (nextAt and nextAt < tailAt) and nextAt or tailAt
        res.mods[#res.mods + 1] = { name = name, text = text:sub(pos, stop) }
        pos = stop + 1
    end
    return res
end

function M.deviceBuild(text)
    local key = #text .. "|" .. text:sub(1, 64) .. "|" .. text:sub(-256)
    if cache.buildKey == key then return cache.build end
    local parts = M.splitBundle(normLines(text))
    local build
    if not parts then
        build = M.minify(text)
    else
        local out = { parts.head }
        for _, m in ipairs(parts.mods) do
            if not M.SERVER_ONLY[m.name] then out[#out + 1] = m.text end
        end
        out[#out + 1] = parts.tail
        build = M.minify(table.concat(out))
    end
    cache.buildKey = key
    cache.build = build
    return build
end

function M.serverBuild(text)
    return M.minify(text)
end

function M.sum(s)
    local a, b = 1, 0
    local byte = string.byte
    local n = #s
    local i = 1
    while i <= n do
        local stop = math.min(n, i + 3999)
        for k = i, stop do
            a = (a + byte(s, k)) % 65521
            b = (b + a) % 65521
        end
        i = stop + 1
        compat.breathe(2)
    end
    return b * 65536 + a
end

local function token(len, dist)
    if dist < 8100 then
        local d1 = math.floor(dist / 90)
        return "`" .. DIGITS[len - 5] .. DIGITS[d1] .. DIGITS[dist - d1 * 90]
    end
    local d1 = math.floor(dist / 8100)
    local r = dist - d1 * 8100
    local d2 = math.floor(r / 90)
    return "`" .. DIGITS[45 + len - 6] .. DIGITS[d1] .. DIGITS[d2] .. DIGITS[r - d2 * 90]
end

function M.pack(s)
    local byte, sub = string.byte, string.sub
    local n = #s
    local head, prev = {}, {}
    local out = {}
    local lit = 1
    local i = 1
    local steps = 0
    local maxD, tries = M.MAX_DIST, M.TRIES
    local function flush(stop)
        if stop >= lit then out[#out + 1] = (sub(s, lit, stop):gsub("`", "``")) end
    end
    while i <= n do
        local bestL, bestD, bestGain = 0, 0, 0
        if i + 3 <= n then
            local key = sub(s, i, i + 3)
            local j = head[key]
            local t = 0
            while j and t < tries do
                local d = i - j
                if d > maxD then break end
                local near = d < 8100
                local lim = math.min(near and 49 or 50, n - i + 1)
                if byte(s, j + bestL) == byte(s, i + bestL) or bestL >= lim then
                    local l = 4
                    while l < lim and byte(s, j + l) == byte(s, i + l) do l = l + 1 end
                    local gain = l - (near and 4 or 5)
                    if l >= (near and 5 or 6) and gain > bestGain then
                        bestL, bestD, bestGain = l, d, gain
                    end
                end
                j = prev[j]
                t = t + 1
            end
            prev[i] = head[key]
            head[key] = i
        end
        if bestGain > 0 then
            flush(i - 1)
            out[#out + 1] = token(bestL, bestD)
            local stop = math.min(i + bestL - 1, n - 3)
            for q = i + 1, stop do
                local key = sub(s, q, q + 3)
                prev[q] = head[key]
                head[key] = q
            end
            i = i + bestL
            lit = i
            steps = steps + 4
        else
            i = i + 1
            steps = steps + 1
        end
        if steps >= 1500 then
            steps = 0
            compat.breathe(40)
        end
    end
    flush(n)
    return table.concat(out)
end

function M.unpack(s)
    local byte, sub = string.byte, string.sub
    local out, n = {}, 0
    local pos, len = 1, #s
    local steps = 0
    while pos <= len do
        local q = s:find("`", pos, true)
        local stop = q and (q - 1) or len
        for k = pos, stop do
            n = n + 1
            out[n] = sub(s, k, k)
        end
        if not q then break end
        local c2 = byte(s, q + 1)
        if c2 == 96 then
            n = n + 1
            out[n] = "`"
            pos = q + 2
        else
            local v = VALUES[c2]
            if not v then return nil, "corrupt data" end
            local len, dist
            if v < 45 then
                local a, b = VALUES[byte(s, q + 2) or 0], VALUES[byte(s, q + 3) or 0]
                if not (a and b) then return nil, "corrupt data" end
                len, dist = v + 5, a * 90 + b
                pos = q + 4
            else
                local a, b, c = VALUES[byte(s, q + 2) or 0], VALUES[byte(s, q + 3) or 0], VALUES[byte(s, q + 4) or 0]
                if not (a and b and c) then return nil, "corrupt data" end
                len, dist = v - 39, a * 8100 + b * 90 + c
                pos = q + 5
            end
            local from = n - dist
            if dist < 1 or from < 0 then return nil, "corrupt data" end
            for k = 1, len do
                n = n + 1
                out[n] = out[from + k]
            end
        end
        steps = steps + 1
        if steps >= 2000 then
            steps = 0
            compat.breathe(40)
        end
    end
    return table.concat(out)
end

function M.packed(build)
    local key = #build .. "|" .. build:sub(1, 64) .. "|" .. build:sub(-256)
    if cache.key == key then return cache.packed end
    local p = M.pack(build)
    cache.key = key
    cache.packed = p
    return p
end

function M.labelFor(deviceCfg, i, n)
    local name = tostring(deviceCfg.name or deviceCfg.realm or "device")
    local role = tostring(deviceCfg.role or "device")
    local label = "ZelNet " .. role .. " " .. name
    if n and n > 1 then label = label .. " " .. i .. "/" .. n end
    return label:sub(1, 32)
end

function M.prepare(deviceCfg, opts)
    opts = opts or {}
    local text = opts.programText
    local err
    if not text then
        if opts.programPath then
            text = util.readFile(opts.programPath)
            if not text then err = "cannot read " .. opts.programPath end
        else
            text, err = M.programText()
        end
    end
    if not text then return nil, err end
    local isServerRole = deviceCfg.role == "main" or deviceCfg.role == "satellite"
    local build
    if isServerRole and M.isPacked(text) then
        build = text
    else
        local full, xerr = M.expand(text)
        if not full then return nil, xerr end
        text = full
        build = isServerRole and M.serverBuild(text) or M.deviceBuild(text)
    end
    if build ~= text and not loadstring(build, "=zelnet") then
        if not loadstring(text, "=zelnet") then return nil, "the program file does not compile" end
        build = text
    end
    local copy = util.copy(deviceCfg)
    copy.netId = nil
    local cfgText, cerr = codec.encode(copy)
    if not cfgText then return nil, "cannot encode config: " .. tostring(cerr) end
    return {
        role = deviceCfg.role, name = deviceCfg.name or deviceCfg.realm, cfg = deviceCfg,
        build = build, cfgText = cfgText, installer = M.installerSource(), label = opts.label,
    }
end

local function writeText(path, text)
    local ok, err = pcall(function()
        local h = fs.open(path, "w")
        if not h then error("cannot open " .. path, 0) end
        h.write(text)
        h.close()
    end)
    if not ok then return false, tostring(err) end
    return true
end

local function checkDrive(driveName)
    if type(driveName) ~= "string" or not peripheral.isPresent(driveName) then return nil, "drive not found" end
    if peripheral.getType(driveName) ~= "drive" then return nil, driveName .. " is not a disk drive" end
    if dcall(driveName, "isDiskPresent") ~= true then return nil, "no disk in " .. driveName end
    if dcall(driveName, "hasData") ~= true then return nil, "the item in " .. driveName .. " is not a pocket computer or disk" end
    local mount = dcall(driveName, "getMountPath")
    if type(mount) ~= "string" or mount == "" then return nil, "the disk in " .. driveName .. " is not mounted" end
    return "/" .. mount:gsub("^/+", "")
end

local function clearDisk(mount, wipe)
    local ours, foreign = diskFiles(mount)
    if #foreign > 0 and not wipe then
        return nil, "the disk has " .. #foreign .. " other file(s); erase it first"
    end
    local list = ours
    if wipe then
        for _, f in ipairs(foreign) do list[#list + 1] = f end
    end
    for _, f in ipairs(list) do pcall(fs.delete, mount .. "/" .. f) end
    return true
end

local function freeOf(mount)
    local ok, free = pcall(fs.getFreeSpace, mount)
    if ok and tonumber(free) then return tonumber(free) end
    return 125000
end

local function partText(set, i)
    return M.MAGIC .. " " .. i .. " " .. #set.bodies .. " " .. set.plen .. " " .. set.psum .. " " .. set.rlen .. " " .. set.rsum
        .. "\n" .. set.bodies[i] .. "."
end

function M.split(plan, cap1)
    local packed = M.packed(plan.build)
    local set = { plen = #packed, psum = M.sum(packed), rlen = #plan.build, rsum = M.sum(plan.build), bodies = {} }
    local headRoom = 80
    local first = math.max(1000, cap1 - headRoom)
    local pos = 1
    local size = first
    while pos <= #packed do
        set.bodies[#set.bodies + 1] = packed:sub(pos, pos + size - 1)
        pos = pos + size
        size = M.PART_SIZE - headRoom
    end
    if #set.bodies == 0 then set.bodies[1] = "" end
    return set
end

function M.writeDisk(driveName, deviceCfg, opts)
    opts = opts or {}
    if type(deviceCfg) ~= "table" then return nil, "no device config" end
    local mount, err = checkDrive(driveName)
    if not mount then return nil, err end
    local plan = opts.plan
    if not plan then
        plan, err = M.prepare(deviceCfg, opts)
        if not plan then return nil, err end
    end
    local ok, cerr = clearDisk(mount, opts.wipe)
    if not ok then return nil, cerr end
    local fixed = #plan.cfgText + #plan.installer + M.MARGIN
    local cap = freeOf(mount) - fixed
    if cap < 2000 then return nil, "not enough space on the disk in " .. driveName end
    local files = {}
    local parts = 1
    if not opts.forcePack and #plan.build + 2 <= cap then
        files[#files + 1] = { M.FILES.program, plan.build }
    else
        local set = M.split(plan, cap)
        plan.set = set
        parts = #set.bodies
        files[#files + 1] = { M.FILES.packed, partText(set, 1) }
    end
    files[#files + 1] = { M.FILES.installer, plan.installer }
    files[#files + 1] = { M.FILES.config, plan.cfgText }
    local written = 0
    for _, f in ipairs(files) do
        local wok, werr = writeText(mount .. "/" .. f[1], f[2])
        if not wok then
            for _, g in ipairs(files) do pcall(fs.delete, mount .. "/" .. g[1]) end
            return nil, "write failed: " .. tostring(werr)
        end
        written = written + #f[2]
    end
    plan.firstDisk = dcall(driveName, "getDiskID")
    pcall(peripheral.call, driveName, "setDiskLabel", opts.label or M.labelFor(deviceCfg, 1, parts))
    return true, { parts = parts, plan = plan, bytes = written, mount = mount }
end

function M.writePart(driveName, plan, i, opts)
    opts = opts or {}
    if type(plan) ~= "table" or not plan.set then return nil, "nothing to write" end
    local set = plan.set
    if not set.bodies[i] or i < 2 then return nil, "bad part number" end
    local mount, err = checkDrive(driveName)
    if not mount then return nil, err end
    local id = dcall(driveName, "getDiskID")
    if id ~= nil and id == plan.firstDisk then return nil, "this is disk 1; insert another disk" end
    local _, foreign = diskFiles(mount)
    if fs.exists(mount .. "/" .. M.FILES.config) then return nil, "this is disk 1; insert another disk" end
    local ok, cerr = clearDisk(mount, opts.wipe)
    if not ok then return nil, cerr end
    local text = partText(set, i)
    if freeOf(mount) < #text + M.MARGIN then return nil, "not enough space on the disk in " .. driveName end
    local wok, werr = writeText(mount .. "/" .. M.FILES.packed, text)
    if not wok then return nil, "write failed: " .. tostring(werr) end
    pcall(peripheral.call, driveName, "setDiskLabel", M.labelFor(plan.cfg, i, #set.bodies))
    return true, { bytes = #text, foreign = #foreign }
end

local INSTALLER = [==[
local VALUES = {}
do
local k = 0
for c = 36, 126 do
if c ~= 96 then VALUES[c] = k k = k + 1 end
end
end
local here = ""
if shell and shell.getRunningProgram then here = fs.getDir(shell.getRunningProgram()) end
local function J(dir, name)
if dir == nil or dir == "" then return "/" .. name end
return "/" .. dir .. "/" .. name
end
local function readAll(p)
if not fs.exists(p) or fs.isDir(p) then return nil end
local h = fs.open(p, "r")
if not h then return nil end
local s = h.readAll()
h.close()
return s
end
local function writeAll(p, s)
local tmp = p .. ".tmp"
if fs.exists(tmp) then fs.delete(tmp) end
local h = fs.open(tmp, "w")
if not h then return false end
h.write(s)
h.close()
if fs.exists(p) then fs.delete(p) end
fs.move(tmp, p)
return true
end
local function parse(s)
if type(s) ~= "string" then return nil end
local ok, v = pcall(textutils.unserialize, s)
if ok and type(v) == "table" then return v end
return nil
end
local function breathe()
os.queueEvent("zn_install")
os.pullEvent("zn_install")
end
local function color(c)
if term.isColor and term.isColor() then term.setTextColor(c) end
end
local function say(s, c)
color(c or colors.white)
print(s)
color(colors.white)
end
local function sum(s)
local a, b = 1, 0
local n = #s
for k = 1, n do
a = (a + string.byte(s, k)) % 65521
b = (b + a) % 65521
if k % 20000 == 0 then breathe() end
end
return b * 65536 + a
end
local function unpackText(s)
local out, n = {}, 0
local pos, len = 1, #s
local mark = 0
while pos <= len do
local q = string.find(s, "`", pos, true)
local stop = len
if q then stop = q - 1 end
for k = pos, stop do
n = n + 1
out[n] = string.sub(s, k, k)
end
if not q then break end
local c2 = string.byte(s, q + 1)
if c2 == 96 then
n = n + 1
out[n] = "`"
pos = q + 2
else
local v = VALUES[c2]
if not v then return nil end
local a = VALUES[string.byte(s, q + 2) or 0]
local b = VALUES[string.byte(s, q + 3) or 0]
local len, dist
if v < 45 then
if not (a and b) then return nil end
len = v + 5
dist = a * 90 + b
pos = q + 4
else
local c = VALUES[string.byte(s, q + 4) or 0]
if not (a and b and c) then return nil end
len = v - 39
dist = a * 8100 + b * 90 + c
pos = q + 5
end
local from = n - dist
if dist < 1 or from < 0 then return nil end
for k = 1, len do
n = n + 1
out[n] = out[from + k]
end
end
if n - mark > 20000 then
mark = n
breathe()
end
end
return table.concat(out)
end
local function header(text)
if type(text) ~= "string" then return nil end
local nl = string.find(text, "\n", 1, true)
if not nl then return nil end
local h = {}
for w in string.gmatch(string.sub(text, 1, nl - 1), "%S+") do h[#h + 1] = w end
if h[1] ~= "ZNPK1" or #h < 7 then return nil end
local body = string.sub(text, nl + 1)
if string.sub(body, -1) == "." then body = string.sub(body, 1, -2) end
return { i = tonumber(h[2]), n = tonumber(h[3]), plen = tonumber(h[4]), psum = tonumber(h[5]), rlen = tonumber(h[6]), rsum = tonumber(h[7]), body = body }
end
local function mounts()
local out = {}
local names = peripheral.getNames and peripheral.getNames() or {}
for _, name in ipairs(names) do
if peripheral.getType(name) == "drive" and disk.hasData(name) then
local m = disk.getMountPath(name)
if m then out[#out + 1] = m end
end
end
return out
end
local function findPart(i, first)
for _, m in ipairs(mounts()) do
local p = header(readAll(J(m, "zelnet.z")))
if p and p.i == i and p.psum == first.psum and p.rsum == first.rsum then return p end
end
return nil
end
local function waitDisk(text)
say(text, colors.yellow)
while true do
local ev, a = os.pullEvent()
if ev == "disk" then return true end
if ev == "key" and a == keys.enter then return false end
end
end
local function finishOld()
local old = parse(readAll("/.zelnet/config"))
if old and fs.exists("/zelnet") then
say("ZelNet is already installed from this disk.", colors.lime)
say("Remove the disk from the drive.")
if old.role ~= "endpoint" and shell then shell.run("/zelnet") end
return true
end
say("This disk has no ZelNet config. It was used already.", colors.red)
say("Ask the server admin for a new disk.")
return false
end
local function main()
if term.clear then term.clear() term.setCursorPos(1, 1) end
say("ZelNet installer", colors.cyan)
local existing = parse(readAll("/.zelnet/config"))
if existing and (existing.role == "main" or existing.role == "satellite") then
say("This computer is the ZelNet server " .. tostring(existing.realm) .. ".", colors.yellow)
say("A provisioning disk is in its drive. Not installing.")
if shell and fs.exists("/zelnet") then shell.run("/zelnet") end
return
end
local cfgPath = J(here, "zelnet.cfg")
if here == "" and fs.exists(cfgPath) then
say("This pocket computer carries a ZelNet install.", colors.yellow)
say("Put it into a disk drive next to the new computer and reboot that computer.")
return
end
local cfgText = readAll(cfgPath)
if not cfgText then
finishOld()
return
end
local cfg = parse(cfgText)
if not cfg or type(cfg.role) ~= "string" then
say("The config on this disk is damaged.", colors.red)
return
end
local name = tostring(cfg.name or cfg.realm or "zelnet")
say("Installing " .. cfg.role .. " " .. name .. " of " .. tostring(cfg.realm))
local program = readAll(J(here, "zelnet"))
if not program then
local first = header(readAll(J(here, "zelnet.z")))
if not first then
say("The program is missing from this disk.", colors.red)
return
end
local bodies = { first.body }
for i = 2, first.n do
local p = findPart(i, first)
while not p do
if not waitDisk("Insert disk " .. i .. " of " .. first.n .. " and wait. Enter cancels.") then
say("Cancelled.", colors.red)
return
end
sleep(0.5)
p = findPart(i, first)
end
bodies[i] = p.body
say("Read disk " .. i .. " of " .. first.n)
end
local packed = table.concat(bodies)
if #packed ~= first.plen or sum(packed) ~= first.psum then
say("The disks are damaged. Ask for new disks.", colors.red)
return
end
say("Unpacking...")
program = unpackText(packed)
if not program or #program ~= first.rlen or sum(program) ~= first.rsum then
say("The program did not unpack correctly.", colors.red)
return
end
end
if not writeAll("/zelnet", program) then
say("Cannot write /zelnet. Is the computer full?", colors.red)
return
end
if not fs.exists("/.zelnet") then fs.makeDir("/.zelnet") end
if fs.exists("/.zelnet/config") then
if fs.exists("/.zelnet/config.old") then fs.delete("/.zelnet/config.old") end
fs.copy("/.zelnet/config", "/.zelnet/config.old")
end
if not writeAll("/.zelnet/config", cfgText) then
say("Cannot write the config.", colors.red)
return
end
if cfg.role ~= "endpoint" then
local old = readAll("/startup")
if old and not string.find(old, "shell.run(\"/zelnet\")", 1, true) then
if fs.exists("/startup.old") then fs.delete("/startup.old") end
fs.move("/startup", "/startup.old")
say("Your old /startup is now /startup.old")
end
writeAll("/startup", "shell.run(\"/zelnet\")\n")
end
if fs.exists(cfgPath) then
fs.delete(cfgPath)
else
local wiped = false
while not wiped do
for _, m in ipairs(mounts()) do
local p = J(m, "zelnet.cfg")
if readAll(p) == cfgText then
fs.delete(p)
wiped = true
end
end
if not wiped and not waitDisk("Put disk 1 back so its keys can be erased. Enter skips.") then
say("Erase zelnet.cfg from disk 1 by hand.", colors.red)
wiped = true
end
end
end
if os.getComputerLabel and not os.getComputerLabel() and os.setComputerLabel then
pcall(os.setComputerLabel, name)
end
say("Installed ZelNet " .. cfg.role .. " " .. name .. ".", colors.lime)
if cfg.role == "endpoint" then
say("Programs on this computer load ZelNet as a library:")
say("  local zn = dofile(\"/zelnet\")", colors.lightGray)
say("  assert(zn.open())", colors.lightGray)
say("  zn.run(function() ... end)", colors.lightGray)
say("Run /zelnet for the status screen. Remove the disk now.")
return
end
if cfg.role == "satellite" then
say("After the reboot the setup asks for the local settings.")
end
say("Remove the disk now. Rebooting in 5 seconds.")
sleep(5)
os.reboot()
end
main()
]==]

function M.installerSource()
    return INSTALLER
end

M.version = version.program

return M
