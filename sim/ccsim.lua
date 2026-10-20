local copcall = require("tests.copcall")
local bitops = require("sim.bitops")
local marshal = require("sim.marshal")
local util = require("sim.util")
local vfs = require("sim.vfs")
local termlib = require("sim.term")
local periph = require("sim.peripherals")

local M = {}

local nativePcall = pcall
local nativeLoadstring = loadstring
local nativeGetfenv, nativeSetfenv = getfenv, setfenv
local nativeCreate, nativeResume, nativeYield = coroutine.create, coroutine.resume, coroutine.yield
local nativeStatus, nativeRunning = coroutine.status, coroutine.running
local sethook, getinfo, debugSetfenv = debug.sethook, debug.getinfo, debug.setfenv
local floor, ceil, max, min = math.floor, math.ceil, math.max, math.min
local pack = util.pack
local fail = util.fail
local native = util.native
local toInt = util.toInt
local hostG = _G
local stringMT = getmetatable("")

local HOOK_STEP = 1000
local TICK = 0.05

M.SIDES = { "bottom", "top", "back", "front", "right", "left" }
local SIDESET = {}
for i, s in ipairs(M.SIDES) do SIDESET[s] = i end

local DEFAULTS = {
    romPath = nil,
    seed = 1,
    budget = 5e7,
    eventQueueLimit = 256,
    maxResumesPerTick = 10000,
    modemRange = 64,
    modemHighAltitudeRange = 384,
    modemRangeDuringStorm = 16,
    modemHighAltitudeRangeDuringStorm = 96,
    worldHeight = 256,
    computerSpace = 1000000,
    floppySpace = 125000,
    pocketSpace = 1000000,
    towerRange = 3000,
    towerRangeStorm = 2400,
    miniAntennaRange = 650,
    miniAntennaRangeStorm = 650,
    bitnetDelay = 3,
    tesseractDelay = 2,
    tesseractType = "tile_thermalexpansion_tesseract_name",
    cipherType = "asielib_inventory_null",
    http = false,
    verbose = false,
    worldTime = 0,
    restartDelayTicks = 50,
}

local function defaultRomPath()
    local src = debug.getinfo(1, "S").source
    local dir = src:match("^@(.*)/[^/]*$") or "."
    return dir .. "/rom"
end

local function readHostFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local d = f:read("*a")
    f:close()
    return d
end

local function loadApiTable(path)
    local src = readHostFile(path)
    if not src then return {} end
    local env = setmetatable({}, { __index = hostG })
    local fn = nativeLoadstring(src, "=" .. path)
    if not fn then return {} end
    nativeSetfenv(fn, env)
    nativePcall(fn)
    local out = {}
    for k, v in pairs(env) do out[k] = v end
    return out
end

local Computer = {}
Computer.__index = Computer
M.Computer = Computer

local World = {}
World.__index = World
M.World = World

local EMPTY_MOUNT = vfs.MemMount.new(0)

function M.newWorld(opts)
    opts = opts or {}
    local cfg = {}
    for k, v in pairs(DEFAULTS) do cfg[k] = v end
    for k, v in pairs(opts) do cfg[k] = v end
    cfg.romPath = cfg.romPath or defaultRomPath()
    local w = setmetatable({
        config = cfg,
        seed = cfg.seed,
        tick = 0,
        worldTime = cfg.worldTime,
        computers = {},
        byId = {},
        sched = {},
        storm = {},
        wireless = {},
        bitnet = {},
        tesseracts = {},
        activeTesseracts = {},
        cables = {},
        names = {},
        dropped = {},
        logs = {},
        uidSeq = 0,
        diskSeq = 0,
        opSeq = 0,
        messageSeq = 0,
        nextComputerId = 0,
    }, World)
    w.biosSource = readHostFile(cfg.romPath .. "/bios.lua")
    if not w.biosSource then error("bios.lua not found under " .. cfg.romPath, 2) end
    w.rom = vfs.HostMount.new(cfg.romPath .. "/rom")
    return w
end

function World:uid()
    self.uidSeq = self.uidSeq + 1
    return self.uidSeq
end

function World:newDiskId()
    local id = self.diskSeq
    self.diskSeq = id + 1
    return id
end

function World:nextName(ptype)
    local n = self.names[ptype] or 0
    self.names[ptype] = n + 1
    return ptype .. "_" .. n
end

function World:log(msg)
    local line = string.format("[%6d] %s", self.tick, tostring(msg))
    self.logs[#self.logs + 1] = line
    if self.config.verbose then print(line) end
end

function World:schedule(delay, fn)
    local due = self.tick + max(1, floor(delay))
    local list = self.sched[due]
    if not list then
        list = {}
        self.sched[due] = list
    end
    list[#list + 1] = fn
end

function World:setStorm(dim, on)
    self.storm[dim] = on and true or nil
end

function World:setTime(ticks)
    self.worldTime = ticks
end

function World:timeOfDay()
    return ((self.worldTime + 6000) % 24000) / 1000
end

function World:day()
    return floor((self.worldTime + 6000) / 24000) + 1
end

function World:addComputer(opts)
    opts = opts or {}
    local id = opts.id
    if id == nil then
        while self.byId[self.nextComputerId] do self.nextComputerId = self.nextComputerId + 1 end
        id = self.nextComputerId
    end
    if self.byId[id] then error("computer id " .. id .. " already exists", 2) end
    local c = setmetatable({
        world = self,
        id = id,
        label = opts.label,
        dim = opts.dim or 0,
        pos = util.vec(opts.pos or { 0, 64, 0 }),
        color = opts.color and true or false,
        budget = opts.budget or self.config.budget,
        sides = {},
        sideAccess = {},
        running = false,
        session = 0,
        bootCount = 0,
        outputBuf = {},
        errorList = {},
        dropped = 0,
        rsIn = {},
        rsOut = {},
        bundledIn = {},
        bundledOut = {},
    }, Computer)
    c.hdd = vfs.MemMount.new(opts.space or self.config.computerSpace)
    for path, content in pairs(opts.files or {}) do c.hdd:setFile(vfs.sanitize(path), content) end
    if opts.startup then c.hdd:setFile("startup", opts.startup) end
    c.fs = vfs.FileSystem.new()
    c.fs:mount("hdd", "", c.hdd, true)
    c.fs:mount("rom", "rom", self.rom, false)
    c.term = termlib.Terminal.new(opts.width or 51, opts.height or 19, c.color)
    self.computers[#self.computers + 1] = c
    self.byId[id] = c
    if opts.boot then c:boot() end
    return c
end

function World:computer(id)
    return self.byId[id]
end

function World:wirelessModem()
    return periph.wirelessModem(self)
end

function World:cable(name)
    name = name or "default"
    local cb = self.cables[name]
    if not cb then
        cb = periph.cable(self, name)
        self.cables[name] = cb
    end
    return cb
end

function World:wiredModem(cableName)
    return periph.wiredModem(self, self:cable(cableName))
end

function World:connect(cableName, p, name)
    return self:cable(cableName):attach(p, name)
end

function World:disconnect(cableName, p)
    return self:cable(cableName):detach(p)
end

function World:monitor(opts)
    return periph.monitor(self, opts)
end

function World:diskDrive()
    return periph.diskDrive(self)
end

function World:floppy(opts)
    return periph.floppy(self, opts)
end

function World:pocket(opts)
    return periph.pocket(self, opts)
end

function World:tesseract(opts)
    return periph.tesseract(self, opts)
end

function World:bitnetTower(opts)
    return periph.bitnetTower(self, opts)
end

function World:bitnetAntenna(opts)
    return periph.bitnetAntenna(self, opts)
end

function World:cipherBlock(opts)
    return periph.cipherBlock(self, opts)
end

function World:energyCell(opts)
    return periph.energyCell(self, opts)
end

function World:touch(monitor, x, y)
    return monitor:touch(x, y)
end

function World:bitnetTransmit(sender, msg)
    local sdim, spos = sender:location()
    if sdim == nil then return end
    local storm = self.storm[sdim]
    for _, d in ipairs(self.bitnet) do
        local ddim, dpos = d:location()
        if ddim == sdim and dpos and d:registered() then
            local dist = util.dist(spos, dpos)
            local range = storm and d.stormRange or d.range
            if dist > 0 and dist <= range then
                local copy = { id = msg.id, payload = msg.payload, distance = msg.distance + dist }
                local delay = ceil(dist / 100) * self.config.bitnetDelay
                self:schedule(delay, function() d:receive(copy) end)
            end
        end
    end
end

function World:runScheduled()
    while true do
        local list = self.sched[self.tick]
        if not list then return end
        self.sched[self.tick] = nil
        for _, fn in ipairs(list) do
            local ok, err = nativePcall(fn)
            if not ok then self:log("scheduled task failed: " .. tostring(err)) end
        end
    end
end

function World:step()
    self.tick = self.tick + 1
    self.worldTime = self.worldTime + 1
    self:runScheduled()
    if next(self.activeTesseracts) then
        local list = {}
        for t in pairs(self.activeTesseracts) do list[#list + 1] = t end
        table.sort(list, function(a, b) return a.uid < b.uid end)
        for _, t in ipairs(list) do
            if not t.buffer then
                self.activeTesseracts[t] = nil
            elseif t:tryDeliver() then
                self.activeTesseracts[t] = nil
            end
        end
    end
    for _, c in ipairs(self.computers) do c:tick() end
end

function World:runTicks(n)
    for _ = 1, n do self:step() end
end

function World:run(seconds)
    self:runTicks(floor((seconds or 0) * 20 + 0.5))
end

function World:runUntil(fn, maxSeconds)
    local limit = self.tick + floor((maxSeconds or 60) * 20 + 0.5)
    if fn() then return true end
    while self.tick < limit do
        self:step()
        if fn() then return true end
    end
    return false
end

function World:seconds()
    return self.tick * TICK
end

function Computer:newAccess(name, p, via)
    return { computer = self, name = name, peripheral = p, via = via, session = self.session, mounts = {} }
end

function Computer:releaseAccess(a)
    for loc in pairs(a.mounts) do self.fs:unmount(loc) end
    a.mounts = {}
end

function Computer:mountFor(access, loc, mount, writable)
    local ok, exists = nativePcall(self.fs.exists, self.fs, loc)
    if not ok or exists then return nil end
    self.fs:mount(access.name, loc, mount, writable)
    access.mounts[loc] = true
    return loc
end

function Computer:unmountFor(access, loc)
    self.fs:unmount(loc)
    access.mounts[loc] = nil
end

function Computer:attachAccess(a)
    local p = a.peripheral
    p:attach(a)
    if p.opPeripheral then self:mountFor(a, "openp", EMPTY_MOUNT, false) end
end

function Computer:detachAccess(a)
    a.peripheral:detach(a)
    self:releaseAccess(a)
end

function Computer:attach(side, p)
    if not SIDESET[side] then error("invalid side " .. tostring(side), 2) end
    if self.sides[side] then self:detach(side) end
    self.sides[side] = p
    if p.ptype == "bitnet_tower" or p.ptype == "bitnet_antenna" then p.owner = p.owner or self end
    if self.running then
        local a = self:newAccess(side, p)
        self.sideAccess[side] = a
        self:attachAccess(a)
        self:queueEvent("peripheral", side)
    end
    return p
end

function Computer:detach(side)
    local p = self.sides[side]
    if not p then return nil end
    self.sides[side] = nil
    local a = self.sideAccess[side]
    if a then
        self.sideAccess[side] = nil
        self:detachAccess(a)
        if self.running then self:queueEvent("peripheral_detach", side) end
    end
    return p
end

function Computer:peripheralAt(side)
    return self.sides[side]
end

function Computer:queueEvent(name, ...)
    if not self.running then return false end
    local q = self.queue
    if self.qtail - self.qhead + 1 >= self.world.config.eventQueueLimit then
        self.dropped = self.dropped + 1
        return false
    end
    self.qtail = self.qtail + 1
    q[self.qtail] = pack(name, ...)
    return true
end

function Computer:queueLuaEvent(name, ...)
    local args, n = marshal.packJava(...)
    for i = 1, n do args[i] = marshal.fromJava(args[i]) end
    return self:queueEvent(name, unpack(args, 1, n))
end

function Computer:recordError(msg)
    msg = tostring(msg)
    self.errorList[#self.errorList + 1] = msg
    self.lastErr = msg
    self.world:log("computer " .. self.id .. " error: " .. msg)
end

function Computer:lastError()
    return self.lastErr
end

function Computer:errors()
    local out = {}
    for i, e in ipairs(self.errorList) do out[i] = e end
    return out
end

function Computer:output()
    return table.concat(self.outputBuf)
end

function Computer:clearOutput()
    self.outputBuf = {}
end

function Computer:makeCoroutineLib()
    local c = self
    local hook = function()
        local n = c.instr + HOOK_STEP
        c.instr = n
        if n > c.budget then
            local info = getinfo(2, "S")
            if info and info.source:sub(1, 1) == "@" then return end
            if c.hardAbort then error("Too long without yielding", 0) end
            if not c.softAborted then
                c.softAborted = true
                c.hardAt = n + c.budget * 0.25
                c.world:log("computer " .. c.id .. ": Too long without yielding (soft abort)")
                error("Too long without yielding", 0)
            elseif n > c.hardAt then
                c.hardAbort = true
                error("Too long without yielding", 0)
            end
        end
    end
    self.hook = hook
    local function create(f)
        if type(f) ~= "function" then error("bad argument #1 to 'create' (Lua function expected)", 2) end
        local co = nativeCreate(f)
        sethook(co, hook, "", HOOK_STEP)
        return co
    end
    self.create = create
    local owner = setmetatable({}, { __mode = "k" })
    self.pcallCreate = function(f)
        local co = create(f)
        local cur = nativeRunning()
        if cur then owner[co] = owner[cur] or cur end
        return co
    end
    local lib = {}
    lib.create = create
    lib.resume = nativeResume
    lib.yield = nativeYield
    lib.status = nativeStatus
    lib.running = function()
        local co = nativeRunning()
        return co and owner[co] or co
    end
    lib.wrap = function(f)
        if type(f) ~= "function" then error("bad argument #1 to 'wrap' (Lua function expected)", 2) end
        local co = create(f)
        return function(...)
            local r = pack(nativeResume(co, ...))
            if r[1] then return unpack(r, 2, r.n) end
            error(r[2], 2)
        end
    end
    return lib
end

function Computer:makeMath()
    local m = util.copy(math)
    local state = ((self.world.seed * 7919 + self.id * 104729 + self.bootCount * 15485863) % 2147483646) + 1
    local function nextR()
        state = (state * 16807) % 2147483647
        return (state - 1) / 2147483646
    end
    m.random = function(a, b)
        local r = nextR()
        if a == nil then return r end
        if type(a) ~= "number" then error("bad argument #1 to 'random' (number expected, got " .. type(a) .. ")", 2) end
        if b == nil then
            a = floor(a)
            if a < 1 then error("bad argument #1 to 'random' (interval is empty)", 2) end
            return floor(r * a) + 1
        end
        if type(b) ~= "number" then error("bad argument #2 to 'random' (number expected, got " .. type(b) .. ")", 2) end
        a, b = floor(a), floor(b)
        if a > b then error("bad argument #2 to 'random' (interval is empty)", 2) end
        return floor(r * (b - a + 1)) + a
    end
    m.randomseed = function(x)
        state = (floor(tonumber(x) or 0) % 2147483646) + 1
    end
    return m
end

function Computer:makeOs()
    local c = self
    local os = {}
    os.queueEvent = native(function(name, ...)
        if type(name) ~= "string" then fail("Expected string") end
        if c.booting and c.world.config.dropBootEvents ~= false then
            c.bootDropped = (c.bootDropped or 0) + 1
            return
        end
        c:queueLuaEvent(name, ...)
    end)
    os.startTimer = native(function(t)
        if type(t) ~= "number" then fail("Expected number") end
        local token = c.nextTimer
        c.nextTimer = token + 1
        c.timers[token] = t
        return token
    end)
    os.cancelTimer = native(function(t)
        if type(t) ~= "number" then fail("Expected number") end
        c.timers[toInt(t)] = nil
    end)
    os.setAlarm = native(function(t)
        if type(t) ~= "number" then fail("Expected number") end
        if t < 0 or t >= 24 then fail("Number out of range") end
        local token = c.nextAlarm
        c.nextAlarm = token + 1
        local day = t > c.time and c.day or (c.day + 1)
        c.alarms[token] = { time = t, day = day }
        return token
    end)
    os.cancelAlarm = native(function(t)
        if type(t) ~= "number" then fail("Expected number") end
        c.alarms[toInt(t)] = nil
    end)
    os.shutdown = native(function() c:requestStop(false) end)
    os.reboot = native(function() c:requestStop(true) end)
    os.computerID = native(function() return c.id end)
    os.getComputerID = os.computerID
    os.setComputerLabel = native(function(label)
        if label ~= nil and type(label) ~= "string" then fail("Expected string or nil") end
        c.label = label
    end)
    os.computerLabel = native(function() return c.label end)
    os.getComputerLabel = os.computerLabel
    os.clock = native(function() return c.clock end)
    os.time = native(function() return c.time end)
    os.day = native(function() return c.day end)
    return os
end

function Computer:tickCall(access, m, args)
    local w = self.world
    w.opSeq = w.opSeq + 1
    local id = w.opSeq
    local session = self.session
    local c = self
    c.opWaiting[id] = true
    w:schedule(1, function()
        if c.session ~= session or not c.running then return end
        local r = pack(nativePcall(m.fn, access.peripheral, access, unpack(args, 1, args.n)))
        if c.opWaiting[id] then
            c.opResults[id] = r
            c:queueEvent("op_tick_sync", id)
        end
    end)
    while true do
        local ev = pack(nativeYield("op_tick_sync"))
        if ev[1] == "terminate" then
            c.opWaiting[id] = nil
            return pack(false, "Terminated")
        end
        if ev[1] == "op_tick_sync" and ev[2] == id then break end
    end
    c.opWaiting[id] = nil
    local r = c.opResults[id]
    c.opResults[id] = nil
    return r or pack(false, "Internal error")
end

function Computer:makePeripheralApi()
    local c = self
    local api = {}
    api.isPresent = native(function(side)
        if type(side) ~= "string" then fail("Expected string") end
        return c.sideAccess[side] ~= nil
    end)
    api.getType = native(function(side)
        if type(side) ~= "string" then fail("Expected string") end
        local a = c.sideAccess[side]
        if a then return a.peripheral.ptype end
        return nil
    end)
    api.getMethods = native(function(side)
        if type(side) ~= "string" then fail("Expected string") end
        local a = c.sideAccess[side]
        if a then return a.peripheral:methodNames() end
        return nil
    end)
    api.call = function(...)
        local n = select("#", ...)
        local side, method = ...
        if n < 2 or type(side) ~= "string" or type(method) ~= "string" then error("Expected string, string", 2) end
        local access = c.sideAccess[side]
        if not access then error("No peripheral attached", 2) end
        local args, an = marshal.packJava(select(3, ...))
        args.n = an
        local p = access.peripheral
        if p.ptype == "modem" and not p.wireless and method == "callRemote" then
            local rname, rmethod = args[1], args[2]
            if type(rname) ~= "string" then error("Expected string", 2) end
            if type(rmethod) ~= "string" then error("Expected string", 2) end
            local ra = p.remoteAccess and p.remoteAccess[rname]
            if not ra then error("No peripheral attached", 2) end
            access = ra
            method = rmethod
            local shifted = { n = max(args.n - 2, 0) }
            for i = 3, args.n do shifted[i - 2] = args[i] end
            args = shifted
            p = ra.peripheral
        end
        local m = p.methods[method]
        if not m then error("No such method " .. method, 2) end
        local r
        if m.tick then
            r = c:tickCall(access, m, args)
        else
            r = pack(nativePcall(m.fn, p, access, unpack(args, 1, args.n)))
        end
        if r[1] then return unpack(r, 2, r.n) end
        error(r[2], 2)
    end
    return api
end

function Computer:makeRedstoneApi()
    local c = self
    local rs = {}
    local function side(s)
        if type(s) ~= "string" then fail("Expected string") end
        if not SIDESET[s] then fail("Invalid side.") end
        return s
    end
    rs.getSides = native(function()
        local out = {}
        for i, s in ipairs(M.SIDES) do out[i] = s end
        return out
    end)
    rs.setOutput = native(function(s, v)
        if type(s) ~= "string" or type(v) ~= "boolean" then fail("Expected string, boolean") end
        side(s)
        c.rsOut[s] = v and 15 or 0
    end)
    rs.getOutput = native(function(s)
        side(s)
        return (c.rsOut[s] or 0) > 0
    end)
    rs.getInput = native(function(s)
        side(s)
        return (c.rsIn[s] or 0) > 0
    end)
    rs.setBundledOutput = native(function(s, v)
        if type(s) ~= "string" or type(v) ~= "number" then fail("Expected string, number") end
        side(s)
        c.bundledOut[s] = toInt(v)
    end)
    rs.getBundledOutput = native(function(s)
        side(s)
        return c.bundledOut[s] or 0
    end)
    rs.getBundledInput = native(function(s)
        side(s)
        return c.bundledIn[s] or 0
    end)
    rs.testBundledInput = native(function(s, mask)
        if type(s) ~= "string" or type(mask) ~= "number" then fail("Expected string, number") end
        side(s)
        local v = c.bundledIn[s] or 0
        mask = toInt(mask) % 4294967296
        return bitops.band(v % 4294967296, mask) == mask
    end)
    rs.setAnalogOutput = native(function(s, v)
        if type(s) ~= "string" or type(v) ~= "number" then fail("Expected string, number") end
        side(s)
        v = toInt(v)
        if v < 0 or v > 15 then fail("Expected number in range 0-15") end
        c.rsOut[s] = v
    end)
    rs.setAnalogueOutput = rs.setAnalogOutput
    rs.getAnalogOutput = native(function(s)
        side(s)
        return c.rsOut[s] or 0
    end)
    rs.getAnalogueOutput = rs.getAnalogOutput
    rs.getAnalogInput = native(function(s)
        side(s)
        return c.rsIn[s] or 0
    end)
    rs.getAnalogueInput = rs.getAnalogInput
    return rs
end

local function globMatch(pattern, host)
    local lua = "^" .. pattern:gsub("[%^%$%(%)%%%.%[%]%+%-%?]", "%%%0"):gsub("%*", ".*") .. "$"
    return host:match(lua) ~= nil
end

function M.httpAllowed(whitelist, url)
    local host = tostring(url):match("^https?://([^/:]+)")
    if not host then return nil, "URL not http" end
    for pattern in tostring(whitelist or "*pastebin.com;*computercraft.info"):gmatch("[^;]+") do
        if globMatch(pattern, host) then return true end
    end
    return nil, "Domain not permitted"
end

local function httpBody(text)
    local lines = {}
    for line in (text .. "\n"):gmatch("(.-)\r?\n") do lines[#lines + 1] = line end
    if text:sub(-1) == "\n" then lines[#lines] = nil end
    return lines
end

local function httpHandle(lines, code)
    local pos = 0
    local h = {}
    function h.readLine()
        pos = pos + 1
        return lines[pos]
    end
    function h.readAll()
        local rest = {}
        for i = pos + 1, #lines do rest[#rest + 1] = lines[i] end
        pos = #lines
        return table.concat(rest, "\n")
    end
    function h.close() end
    function h.getResponseCode() return code end
    return h
end

function Computer:makeHttpApi()
    local c = self
    local api = {}
    function api.request(url, post, headers)
        if type(url) ~= "string" then error("Expected string", 2) end
        local hcfg = c.world.config.http
        local ok, err = M.httpAllowed(hcfg.whitelist, url)
        if not ok then error(err, 2) end
        c.world:schedule(hcfg.delay or 10, function()
            local text = (hcfg.files or {})[url]
            if type(text) == "string" then
                c:queueEvent("http_success", url, httpHandle(httpBody(text), 200))
            else
                c:queueEvent("http_failure", url)
            end
        end)
        return true
    end
    return api
end

function Computer:buildEnv()
    local c = self
    local env = {}
    for _, k in ipairs({ "assert", "error", "ipairs", "next", "pairs", "rawequal", "rawget", "rawset", "select", "setmetatable", "getmetatable", "tonumber", "tostring", "type", "unpack" }) do
        env[k] = hostG[k]
    end
    env.next = util.strictNext
    env.pairs = util.strictPairs
    env._VERSION = "Lua 5.1"
    env._G = env
    env.string = util.copy(string)
    env.table = util.copy(table)
    env.math = c:makeMath()
    env.coroutine = c:makeCoroutineLib()
    local cop = copcall.new({ create = c.pcallCreate, intercept = function(err)
        if c.hardAbort then error(err, 0) end
    end })
    env.pcall = cop.pcall
    env.xpcall = function(f, handler) return cop.xpcall(f, handler) end
    env.loadstring = function(s, name)
        if type(s) ~= "string" and type(s) ~= "number" then
            error("bad argument #1 to 'loadstring' (string expected, got " .. type(s) .. ")", 2)
        end
        s = tostring(s)
        if name == nil then name = "string" end
        name = tostring(name)
        local fn = nativeLoadstring(s, "=" .. name)
        if not fn then
            local _, err = nativeLoadstring(s, name)
            return nil, err
        end
        nativeSetfenv(fn, env)
        return fn
    end
    local function mapEnv(e, target)
        if e == hostG then
            if type(target) == "function" then return stringMT end
            return env
        end
        return e
    end
    env.getfenv = function(f)
        local target = f
        if f == nil then
            f = 2
        elseif type(f) == "number" and f > 0 then
            f = f + 1
        end
        if type(f) == "number" then
            local info = getinfo(f + 0, "f")
            target = info and info.func
        end
        return mapEnv(nativeGetfenv(f), target)
    end
    env.setfenv = function(f, t)
        if type(f) == "number" and f > 0 then f = f + 1 end
        return nativeSetfenv(f, t)
    end
    env.os = c:makeOs()
    env.fs = vfs.makeApi(c.fs)
    env.term = termlib.makeApi(function() return c.term end)
    env.peripheral = c:makePeripheralApi()
    local rs = c:makeRedstoneApi()
    env.redstone = rs
    env.rs = rs
    env.bit = bitops.ccApi()
    if type(c.world.config.http) == "table" then env.http = c:makeHttpApi() end
    local wrapped = 0
    setmetatable(env, {
        __newindex = function(t, k, v)
            if k == "printError" and type(v) == "function" then
                local orig = v
                rawset(t, k, function(...)
                    local parts = {}
                    for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
                    c:recordError(table.concat(parts))
                    return orig(...)
                end)
                wrapped = wrapped + 1
            elseif k == "write" and type(v) == "function" then
                local orig = v
                rawset(t, k, function(s)
                    c.outputBuf[#c.outputBuf + 1] = tostring(s)
                    return orig(s)
                end)
                wrapped = wrapped + 1
            else
                rawset(t, k, v)
            end
            if wrapped >= 2 then setmetatable(t, nil) end
        end,
    })
    return env
end

function Computer:boot()
    if self.running then return false end
    local w = self.world
    self.bootCount = self.bootCount + 1
    self.startTick = w.tick
    self.session = w:uid()
    self.running = true
    self.stopping = false
    self.stopRequest = nil
    self.queue, self.qhead, self.qtail = {}, 1, 0
    self.timers, self.alarms = {}, {}
    self.nextTimer, self.nextAlarm = 0, 0
    self.clock = 0
    self.time = w:timeOfDay()
    self.day = w:day()
    self.opResults, self.opWaiting = {}, {}
    self.filter = nil
    self.instr = 0
    self.outY = nil
    self.term:reset()
    for loc, m in pairs(self.fs.mounts) do
        if loc ~= "" and loc ~= "rom" then self.fs.mounts[loc] = nil end
    end
    self.fs.writers = {}
    self.hdd:remeasure()
    local env = self:buildEnv()
    self.env = env
    local fn, err = nativeLoadstring(w.biosSource, "=bios")
    if not fn then
        self.running = false
        self:recordError("Error loading bios.lua: " .. tostring(err))
        return false
    end
    nativeSetfenv(fn, env)
    self.co = self.create(fn)
    debugSetfenv(self.co, env)
    for _, side in ipairs(M.SIDES) do
        local p = self.sides[side]
        if p then
            local a = self:newAccess(side, p)
            self.sideAccess[side] = a
            self:attachAccess(a)
        end
    end
    w:log("computer " .. self.id .. " booted")
    self.booting = true
    self:resume(pack())
    self.booting = false
    return true
end

function Computer:requestStop(reboot)
    if not self.running then return end
    if self.stopRequest == nil or reboot == false then self.stopRequest = reboot and "reboot" or "shutdown" end
end

function Computer:stop()
    if not self.running then return end
    self.stopping = true
    for _, side in ipairs(M.SIDES) do
        local a = self.sideAccess[side]
        if a then
            self.sideAccess[side] = nil
            nativePcall(self.detachAccess, self, a)
        end
    end
    self.fs:closeAll()
    self.running = false
    self.stopping = false
    self.co = nil
    self.env = nil
    self.queue, self.qhead, self.qtail = {}, 1, 0
    self.session = self.world:uid()
    self.world:log("computer " .. self.id .. " stopped")
end

function Computer:shutdown()
    self:stop()
end

function Computer:reboot()
    self:stop()
    self:boot()
end

function Computer:isOn()
    return self.running
end

function Computer:resume(ev)
    if not self.co then return end
    if self.filter ~= nil and ev[1] ~= nil and ev[1] ~= self.filter and ev[1] ~= "terminate" then return end
    self.instr = 0
    self.softAborted = false
    self.hardAbort = false
    local r = pack(nativeResume(self.co, unpack(ev, 1, ev.n)))
    if self.hardAbort then
        self:recordError("Too long without yielding")
        self.crashed = true
        self:stop()
        return
    end
    if not r[1] then
        self:recordError(r[2])
        self.crashed = true
        self:stop()
        return
    end
    if nativeStatus(self.co) == "dead" then
        self:stop()
        return
    end
    if type(r[2]) == "string" then self.filter = r[2] else self.filter = nil end
end

function Computer:advance(dt)
    self.clock = self.clock + dt
    local fired = {}
    for token, left in pairs(self.timers) do
        left = left - dt
        if left <= 0 then
            fired[#fired + 1] = token
        else
            self.timers[token] = left
        end
    end
    table.sort(fired)
    for _, token in ipairs(fired) do
        self.timers[token] = nil
        self:queueEvent("timer", token)
    end
    local w = self.world
    local prevTime, prevDay = self.time, self.day
    local now, today = w:timeOfDay(), w:day()
    if now > prevTime or today > prevDay then
        local cur = self.day * 24 + self.time
        local due = {}
        for token, al in pairs(self.alarms) do
            if cur >= al.day * 24 + al.time then due[#due + 1] = token end
        end
        table.sort(due)
        for _, token in ipairs(due) do
            self.alarms[token] = nil
            self:queueEvent("alarm", token)
        end
    end
    self.time, self.day = now, today
end

function Computer:tick()
    if self.pendingBoot and not self.running and self.world.tick - (self.startTick or -1000) > self.world.config.restartDelayTicks then
        self.pendingBoot = nil
        self:boot()
    end
    if not self.running then return end
    self:advance(TICK)
    local limit = self.world.config.maxResumesPerTick
    local count = 0
    while self.running and self.qhead <= self.qtail and count < limit do
        local ev = self.queue[self.qhead]
        self.queue[self.qhead] = nil
        self.qhead = self.qhead + 1
        count = count + 1
        self:resume(ev)
        if self.stopRequest then break end
    end
    if self.stopRequest and self.running then
        local req = self.stopRequest
        self.stopRequest = nil
        self:stop()
        if req == "reboot" then self.pendingBoot = true end
    end
end

function Computer:screenLines()
    return self.term:lines()
end

function Computer:screenText()
    return self.term:screenText()
end

function Computer:screenColors(y)
    return self.term:textColours(y), self.term:backgroundColours(y)
end

function Computer:cell(x, y)
    return self.term:cell(x, y)
end

function Computer:cursor()
    return self.term.x + 1, self.term.y + 1, self.term.blink
end

function Computer:findText(pattern, plain)
    for y, line in ipairs(self.term:lines()) do
        local s = line:find(pattern, 1, plain)
        if s then return s, y end
    end
    return nil
end

function Computer:typeText(s)
    for i = 1, #s do self:queueEvent("char", s:sub(i, i)) end
end

function Computer:pressKey(code)
    self:queueEvent("key", code)
end

function Computer:typeLine(s)
    self:typeText(s)
    self:pressKey(28)
end

function Computer:paste(s)
    self:queueEvent("paste", s)
end

function Computer:click(x, y, button)
    if not self.color then return false end
    return self:queueEvent("mouse_click", button or 1, x, y)
end

function Computer:drag(x, y, button)
    if not self.color then return false end
    return self:queueEvent("mouse_drag", button or 1, x, y)
end

function Computer:scroll(dir, x, y)
    if not self.color then return false end
    return self:queueEvent("mouse_scroll", dir, x or 1, y or 1)
end

function Computer:terminate()
    return self:queueEvent("terminate")
end

function Computer:setRedstoneInput(side, value)
    if type(value) == "boolean" then value = value and 15 or 0 end
    self.rsIn[side] = value
    self:queueEvent("redstone")
end

function Computer:setBundledInput(side, value)
    self.bundledIn[side] = value
    self:queueEvent("redstone")
end

function Computer:readFile(path)
    local ok, data = nativePcall(self.fs.read, self.fs, path)
    if ok then return data end
    return nil
end

function Computer:writeFile(path, s)
    local m, l = self.fs:getMount(vfs.sanitize(path))
    if not m.writable or not m.mount.setFile then error("read only path " .. path, 2) end
    m.mount:setFile(l, s)
end

function Computer:exists(path)
    local ok, r = nativePcall(self.fs.exists, self.fs, path)
    return ok and r
end

function Computer:deleteFile(path)
    local m, l = self.fs:getMount(vfs.sanitize(path))
    if m.writable then m.mount:delete(l) end
end

function Computer:listFiles(path)
    local ok, r = nativePcall(self.fs.list, self.fs, path or "")
    if ok then return r end
    return nil
end

function Computer:files()
    return self.hdd:snapshot()
end

function Computer:freeSpace(path)
    return self.fs:getFreeSpace(path or "")
end

function Computer:mountPath(drive)
    for _, a in ipairs(drive:computers()) do
        if a.computer == self then return drive.mounts[a] end
    end
    return nil
end

local keys = nil
local colors = nil

function M.keys(romPath)
    if not keys then keys = loadApiTable((romPath or defaultRomPath()) .. "/rom/apis/keys") end
    return keys
end

function M.colors(romPath)
    if not colors then colors = loadApiTable((romPath or defaultRomPath()) .. "/rom/apis/colors") end
    return colors
end

M.copcall = copcall

return M
