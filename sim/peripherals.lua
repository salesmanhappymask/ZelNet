local marshal = require("sim.marshal")
local util = require("sim.util")
local vfs = require("sim.vfs")
local termlib = require("sim.term")
local aes = require("sim.aes")
local bitops = require("sim.bitops")

local M = {}

local fail = util.fail
local toInt = util.toInt
local floor, max, min, ceil = math.floor, math.max, math.min, math.ceil

local Base = {}
Base.__index = Base
M.Base = Base

function M.new(world, ptype, cls)
    local p = setmetatable({ world = world, ptype = ptype, methods = {}, order = {}, accesses = {}, accessList = {} }, cls or Base)
    return p
end

function Base:def(name, fn, tick)
    if not self.methods[name] then self.order[#self.order + 1] = name end
    self.methods[name] = { fn = fn, tick = tick and true or false }
end

function Base:methodNames()
    local out = {}
    for i, n in ipairs(self.order) do out[i] = n end
    return out
end

function Base:attach(access)
    if self.accesses[access] then return end
    self.accesses[access] = true
    self.accessList[#self.accessList + 1] = access
    if self.onAttach then self:onAttach(access) end
end

function Base:detach(access)
    if not self.accesses[access] then return end
    if self.onDetach then self:onDetach(access) end
    self.accesses[access] = nil
    for i, a in ipairs(self.accessList) do
        if a == access then
            table.remove(self.accessList, i)
            break
        end
    end
end

function Base:computers()
    local out = {}
    for _, a in ipairs(self.accessList) do out[#out + 1] = a end
    return out
end

function Base:queueAll(event, ...)
    for _, a in ipairs(self:computers()) do a.computer:queueEvent(event, a.name, ...) end
end

function Base:location()
    if self.pos and self.dim ~= nil then return self.dim, self.pos end
    local a = self.accessList[1]
    if a then return a.computer.dim, a.computer.pos end
    if self.owner then return self.owner.dim, self.owner.pos end
    return nil
end

local function num(v, msg)
    if type(v) ~= "number" then fail(msg or "Expected number") end
    return v
end

local function parseChannel(v)
    if type(v) ~= "number" then fail("Expected number") end
    local c = toInt(v)
    if c < 0 or c > 65535 then fail("Expected number in range 0-65535") end
    return c
end

local Modem = setmetatable({}, { __index = Base })
Modem.__index = Modem

local function modemCommon(p)
    p.open = {}
    p.openCount = 0
    p:def("open", function(self, access, ch)
        ch = parseChannel(ch)
        if not self.open[ch] then
            if self.openCount >= 128 then fail("Too many open channels") end
            self.open[ch] = true
            self.openCount = self.openCount + 1
        end
    end)
    p:def("isOpen", function(self, access, ch)
        ch = parseChannel(ch)
        return self.open[ch] == true
    end)
    p:def("close", function(self, access, ch)
        ch = parseChannel(ch)
        if self.open[ch] then
            self.open[ch] = nil
            self.openCount = self.openCount - 1
        end
    end)
    p:def("closeAll", function(self)
        self.open = {}
        self.openCount = 0
    end)
    p:def("transmit", function(self, access, ch, reply, payload)
        ch = parseChannel(ch)
        reply = parseChannel(reply)
        self:send(ch, reply, payload)
    end)
    p:def("isWireless", function(self)
        return self.wireless
    end)
end

function Modem:onAttach(access)
    if self.access and self.access ~= access then fail("modem is already attached to another computer") end
    self.access = access
    self.session = access.session
    if self.wireless then
        self.world.wireless[self] = true
    elseif self.cable then
        self.cable.modems[self] = true
        self.remoteAccess = {}
        for _, name in ipairs(self.cable.order) do
            local rp = self.cable.remotes[name]
            if rp then self:attachRemote(name, rp, true) end
        end
    end
end

function Modem:onDetach(access)
    if self.wireless then
        self.world.wireless[self] = nil
    elseif self.cable then
        for name, ra in pairs(self.remoteAccess or {}) do
            ra.peripheral:detach(ra)
            access.computer:releaseAccess(ra)
            if access.computer.running and not access.computer.stopping then
                access.computer:queueEvent("peripheral_detach", name)
            end
        end
        self.remoteAccess = {}
        self.cable.modems[self] = nil
    end
    self.open = {}
    self.openCount = 0
    self.access = nil
    self.session = nil
end

function Modem:attachRemote(name, rp)
    local c = self.access.computer
    local ra = c:newAccess(name, rp, self)
    self.remoteAccess[name] = ra
    rp:attach(ra)
    c:queueEvent("peripheral", name)
end

function Modem:detachRemote(name)
    local ra = self.remoteAccess and self.remoteAccess[name]
    if not ra then return end
    self.remoteAccess[name] = nil
    ra.peripheral:detach(ra)
    local c = self.access.computer
    c:releaseAccess(ra)
    c:queueEvent("peripheral_detach", name)
end

function Modem:range()
    local w = self.world
    local c = self.access and self.access.computer
    if not c then return 0 end
    local cfg = w.config
    local range, high = cfg.modemRange, cfg.modemHighAltitudeRange
    if w.storm[c.dim] then range, high = cfg.modemRangeDuringStorm, cfg.modemHighAltitudeRangeDuringStorm end
    local y = c.pos[2]
    if y > 96 and high > range then
        return range + (y - 96) * ((high - range) / (cfg.worldHeight - 1 - 96))
    end
    return range
end

function Modem:receive(ch, reply, payload, distance)
    local a = self.access
    if not a or a.session ~= self.session or not self.open[ch] then return end
    a.computer:queueEvent("modem_message", a.name, ch, reply, marshal.fromJava(payload), distance)
end

function Modem:send(ch, reply, payload)
    local w = self.world
    local c = self.access.computer
    local jpayload = marshal.toJava(payload)
    if self.wireless then
        local range = self:range()
        local targets = {}
        for r in pairs(w.wireless) do
            if r ~= self and r.open[ch] and r.access then
                local rc = r.access.computer
                if rc.dim == c.dim then
                    local d = util.dist(rc.pos, c.pos)
                    local lim = max(range, r:range())
                    if d * d <= lim * lim then targets[#targets + 1] = { r, d } end
                end
            end
        end
        table.sort(targets, function(a, b) return a[1].uid < b[1].uid end)
        for _, t in ipairs(targets) do t[1]:receive(ch, reply, jpayload, t[2]) end
    elseif self.cable then
        local cable = self.cable
        w:schedule(1, function()
            local list = {}
            for r in pairs(cable.modems) do
                if r ~= self and r.access then list[#list + 1] = r end
            end
            table.sort(list, function(a, b) return a.uid < b.uid end)
            for _, r in ipairs(list) do
                local rc = r.access.computer
                local d = 0
                if rc.pos and c.pos then
                    d = math.abs(rc.pos[1] - c.pos[1]) + math.abs(rc.pos[2] - c.pos[2]) + math.abs(rc.pos[3] - c.pos[3])
                end
                r:receive(ch, reply, jpayload, d)
            end
        end)
    end
end

function M.wirelessModem(world)
    local p = M.new(world, "modem", Modem)
    p.wireless = true
    p.uid = world:uid()
    modemCommon(p)
    return p
end

function M.wiredModem(world, cable)
    local p = M.new(world, "modem", Modem)
    p.wireless = false
    p.cable = cable
    p.uid = world:uid()
    p.remoteAccess = {}
    modemCommon(p)
    p:def("getNamesRemote", function(self)
        local out = {}
        for _, name in ipairs(self.cable.order) do
            if self.cable.remotes[name] then out[#out + 1] = name end
        end
        return out
    end)
    p:def("isPresentRemote", function(self, access, name)
        if type(name) ~= "string" then fail("Expected string") end
        return self.cable.remotes[name] ~= nil
    end)
    p:def("getTypeRemote", function(self, access, name)
        if type(name) ~= "string" then fail("Expected string") end
        local rp = self.cable.remotes[name]
        if rp then return rp.ptype end
        return nil
    end)
    p:def("getMethodsRemote", function(self, access, name)
        if type(name) ~= "string" then fail("Expected string") end
        local rp = self.cable.remotes[name]
        if rp then return rp:methodNames() end
        return nil
    end)
    p:def("callRemote", function()
        fail("callRemote must be dispatched by the computer")
    end)
    return p
end

local Cable = {}
Cable.__index = Cable
M.Cable = Cable

function M.cable(world, name)
    return setmetatable({ world = world, name = name, modems = {}, remotes = {}, order = {}, names = {} }, Cable)
end

function Cable:attach(p, name)
    if self.names[p] then return self.names[p] end
    name = name or self.world:nextName(p.ptype)
    if self.remotes[name] then error("name already used on cable " .. self.name .. ": " .. name, 2) end
    self.remotes[name] = p
    self.names[p] = name
    self.order[#self.order + 1] = name
    p.cables = p.cables or {}
    p.cables[self] = name
    local list = {}
    for m in pairs(self.modems) do list[#list + 1] = m end
    table.sort(list, function(a, b) return a.uid < b.uid end)
    for _, m in ipairs(list) do
        if m.access then m:attachRemote(name, p) end
    end
    return name
end

function Cable:detach(p)
    local name = self.names[p]
    if not name then return end
    local list = {}
    for m in pairs(self.modems) do list[#list + 1] = m end
    table.sort(list, function(a, b) return a.uid < b.uid end)
    for _, m in ipairs(list) do
        if m.access then m:detachRemote(name) end
    end
    self.remotes[name] = nil
    self.names[p] = nil
    if p.cables then p.cables[self] = nil end
    for i, n in ipairs(self.order) do
        if n == name then
            table.remove(self.order, i)
            break
        end
    end
end

function Cable:nameOf(p)
    return self.names[p]
end

local Monitor = setmetatable({}, { __index = Base })
Monitor.__index = Monitor

function M.monitor(world, opts)
    opts = opts or {}
    local p = M.new(world, "monitor", Monitor)
    p.blocksW = opts.w or 1
    p.blocksH = opts.h or 1
    p.color = opts.color and true or false
    p.scale = 2
    local w, h = termlib.monitorSize(p.blocksW, p.blocksH, 1)
    p.term = termlib.Terminal.new(w, h, p.color)
    local raw = termlib.methods(function() return p.term end)
    for _, name in ipairs({ "write", "scroll", "setCursorPos", "setCursorBlink", "getCursorPos", "getSize", "clear", "clearLine" }) do
        local f = raw[name]
        p:def(name, function(self, access, ...) return f(...) end)
    end
    p:def("setTextScale", function(self, access, ...)
        local s = ...
        if select("#", ...) < 1 or type(s) ~= "number" then fail("Expected number") end
        local v = toInt(s * 2)
        if v < 1 or v > 10 then fail("Expected number in range 0.5-5") end
        self:setScale(v)
    end)
    for _, name in ipairs({ "setTextColour", "setTextColor", "setBackgroundColour", "setBackgroundColor", "isColour", "isColor" }) do
        local f = raw[name]
        p:def(name, function(self, access, ...) return f(...) end)
    end
    return p
end

function Monitor:setScale(v)
    if v == self.scale then return end
    self.scale = v
    local w, h = termlib.monitorSize(self.blocksW, self.blocksH, v * 0.5)
    if w ~= self.term.w or h ~= self.term.h then
        self.term:resize(w, h)
        self.term:clear()
        self.world:schedule(1, function() self:queueAll("monitor_resize") end)
    end
end

function Monitor:touch(x, y)
    if not self.color then return false end
    self:queueAll("monitor_touch", x, y)
    return true
end

function Monitor:screenLines()
    return self.term:lines()
end

function Monitor:screenText()
    return self.term:screenText()
end

local FLOPPY_ITEM_ID = 4256

function M.floppy(world, opts)
    opts = opts or {}
    local f = {
        kind = "floppy",
        id = FLOPPY_ITEM_ID,
        count = 1,
        maxSize = 1,
        label = opts.label,
        diskId = opts.diskId or world:newDiskId(),
        mount = vfs.MemMount.new(opts.capacity or world.config.floppySpace),
        uid = world:uid(),
    }
    for path, content in pairs(opts.files or {}) do f.mount:setFile(vfs.sanitize(path), content) end
    function f:readFile(path) return self.mount:getFile(vfs.sanitize(path)) end
    function f:writeFile(path, s) self.mount:setFile(vfs.sanitize(path), s) end
    function f:files() return self.mount:snapshot() end
    return f
end

local function describe(item)
    if not item then return nil end
    if item.kind == "floppy" then
        return { id = item.id, name = "Floppy Disk", rawName = "item.ccdisk", qty = item.count or 1, dmg = 0, maxdmg = 0, maxSize = 1 }
    end
    return {
        id = item.id or 0,
        name = item.name or "Unknown",
        rawName = item.rawName or ("item." .. tostring(item.name or "unknown")),
        qty = item.count or 1,
        dmg = item.damage or 0,
        maxdmg = item.maxDamage or 0,
        maxSize = item.maxSize or 64,
    }
end
M.describe = describe

local function stackable(a, b)
    return a.kind ~= "floppy" and b.kind ~= "floppy" and a.id == b.id and (a.damage or 0) == (b.damage or 0) and a.nbtHash == b.nbtHash
end

local function maxSizeOf(item)
    if item.kind == "floppy" then return 1 end
    return item.maxSize or 64
end

local function splitItem(item, n)
    if item.kind == "floppy" then return item end
    local c = util.copy(item)
    c.count = n
    return c
end

function M.moveItem(src, srcSlot, dst, dstSlot, maxAmount)
    local stack = src:getStack(srcSlot + 1)
    if not stack or maxAmount <= 0 then return 0 end
    local amount = min(maxAmount, stack.count or 1)
    local slots = {}
    if dstSlot == -1 then
        for i = 1, dst:invSize() do slots[#slots + 1] = i end
    else
        slots[1] = dstSlot + 1
    end
    local moved = 0
    for _, i in ipairs(slots) do
        if moved >= amount then break end
        if dst:acceptsAt(i, stack) then
            local cur = dst:getStack(i)
            if not cur then
                local n = min(amount - moved, maxSizeOf(stack))
                dst:setStack(i, splitItem(stack, n))
                moved = moved + n
                if stack.kind == "floppy" then break end
            elseif stackable(cur, stack) then
                local room = maxSizeOf(cur) - (cur.count or 1)
                local n = min(room, amount - moved)
                if n > 0 then
                    local merged = util.copy(cur)
                    merged.count = (cur.count or 1) + n
                    dst:setStack(i, merged)
                    moved = moved + n
                end
            end
        end
    end
    if moved > 0 then
        local left = (stack.count or 1) - moved
        if left <= 0 or stack.kind == "floppy" then
            src:setStack(srcSlot + 1, nil)
        else
            local rest = util.copy(stack)
            rest.count = left
            src:setStack(srcSlot + 1, rest)
        end
    end
    return moved
end

local Drive = setmetatable({}, { __index = Base })
Drive.__index = Drive

function M.diskDrive(world)
    local p = M.new(world, "drive", Drive)
    p.mounts = {}
    p.uid = world:uid()
    p:def("isDiskPresent", function(self) return self.item ~= nil end)
    p:def("getDiskLabel", function(self)
        if self:media() then return self.item.label end
        return nil
    end)
    p:def("setDiskLabel", function(self, access, label)
        if label ~= nil and type(label) ~= "string" then fail("Expected string") end
        if self:media() then self.item.label = label end
    end)
    p:def("hasData", function(self, access) return self.mounts[access] ~= nil end)
    p:def("getMountPath", function(self, access) return self.mounts[access] end)
    p:def("hasAudio", function(self)
        if self:media() then return false end
        return false
    end)
    p:def("getAudioTitle", function(self)
        if self:media() then return nil end
        return false
    end)
    p:def("playAudio", function() end)
    p:def("stopAudio", function() end)
    p:def("ejectDisk", function(self)
        local item = self.item
        if item then
            self:setStack(1, nil)
            self.world.dropped[#self.world.dropped + 1] = item
            self.ejected = item
        end
    end)
    p:def("getDiskID", function(self)
        if self:media() then return self.item.diskId end
        return nil
    end)
    return p
end

function Drive:media()
    return self.item and self.item.kind == "floppy" and self.item or nil
end

function Drive:mountFor(access)
    local media = self:media()
    if media then
        if not self.mounts[access] then media.mount:remeasure() end
        local c = access.computer
        local i = 1
        while not self.mounts[access] and i < 1000 do
            local loc = i == 1 and "disk" or ("disk" .. i)
            self.mounts[access] = c:mountFor(access, loc, media.mount, true)
            i = i + 1
        end
    end
    access.computer:queueEvent("disk", access.name)
end

function Drive:unmountFor(access)
    local loc = self.mounts[access]
    if loc then
        access.computer:unmountFor(access, loc)
        self.mounts[access] = nil
    end
    access.computer:queueEvent("disk_eject", access.name)
end

function Drive:onAttach(access)
    if self.item then self:mountFor(access) end
end

function Drive:onDetach(access)
    if self.mounts[access] then
        access.computer:unmountFor(access, self.mounts[access])
        self.mounts[access] = nil
    end
end

function Drive:invSize() return 1 end
function Drive:invName() return "Disk Drive" end
function Drive:getStack(i)
    if i == 1 then return self.item end
    return nil
end
function Drive:acceptsAt(i, item)
    return i == 1 and self.item == nil
end
function Drive:setStack(i, item)
    if i ~= 1 then return end
    if self.item then
        for _, a in ipairs(self:computers()) do self:unmountFor(a) end
    end
    self.item = item
    if item then
        for _, a in ipairs(self:computers()) do self:mountFor(a) end
    end
end

function Drive:insert(floppy)
    if self.item then return false end
    self:setStack(1, floppy)
    return true
end

function Drive:remove()
    local item = self.item
    if item then self:setStack(1, nil) end
    return item
end

function Drive:disk()
    return self.item
end

M.DIRECTIONS = { "down", "up", "north", "south", "west", "east" }
local DIRSET = {}
for i, d in ipairs(M.DIRECTIONS) do DIRSET[d] = i end
M.OPPOSITE = { down = "up", up = "down", north = "south", south = "north", west = "east", east = "west" }

local function checkDir(d)
    if type(d) ~= "string" or not DIRSET[d] then fail("Invalid direction") end
    return d
end

local function checkSlotId(inv, slot, name)
    if slot ~= -1 then
        local size = inv:invSize()
        if slot < 0 then fail(name .. " slot id (" .. slot .. ") must not be negative") end
        if slot >= size then fail(name .. " slot id (" .. slot .. ") must be less than size (" .. size .. ")") end
    end
end

local function optInt(v, default)
    if v == nil then return default end
    if type(v) ~= "number" then fail("Invalid argument type") end
    return toInt(v)
end

local function opCommon(p)
    p.neighbors = p.neighbors or {}
    p.opPeripheral = true
    p:def("listMethods", function(self)
        return table.concat(self:methodNames(), ", ")
    end)
    p:def("getAdvancedMethodsData", function(self)
        local out = {}
        for _, n in ipairs(self:methodNames()) do out[n] = { name = n, description = "", args = {}, returnTypes = {} } end
        return out
    end)
end

local function opInventory(p)
    p:def("getInventoryName", function(self) return self:invName() end, true)
    p:def("getInventorySize", function(self) return self:invSize() end, true)
    p:def("condenseItems", function() end, true)
    p:def("swapStacks", function(self, access, from, to)
        from = toInt(num(from)) - 1
        to = toInt(num(to)) - 1
        checkSlotId(self, from, "input")
        checkSlotId(self, to, "output")
        local a, b = self:getStack(from + 1), self:getStack(to + 1)
        self:setStack(from + 1, nil)
        self:setStack(to + 1, nil)
        self:setStack(from + 1, b)
        self:setStack(to + 1, a)
    end, true)
    p:def("getStackInSlot", function(self, access, slot)
        slot = toInt(num(slot)) - 1
        checkSlotId(self, slot, "input")
        return describe(self:getStack(slot + 1))
    end, true)
    p:def("getAllStacks", function(self)
        local out = {}
        for i = 1, self:invSize() do out[i] = describe(self:getStack(i)) end
        return out
    end, true)
    p:def("destroyStack", function(self, access, slot)
        slot = toInt(num(slot)) - 1
        checkSlotId(self, slot, "input")
        self:setStack(slot + 1, nil)
    end, true)
    local function pull(self, access, dir, slot, maxAmount, intoSlot)
        dir = checkDir(dir)
        if type(slot) ~= "number" then fail("Not enough arguments or invalid slot") end
        local other = self.neighbors[dir]
        if not other or other == self then return 0 end
        maxAmount = optInt(maxAmount, 64)
        intoSlot = optInt(intoSlot, 0)
        local from, to = toInt(slot) - 1, intoSlot - 1
        checkSlotId(other, from, "input")
        checkSlotId(self, to, "output")
        return M.moveItem(other, from, self, to, maxAmount)
    end
    local function push(self, access, dir, slot, maxAmount, intoSlot)
        dir = checkDir(dir)
        if type(slot) ~= "number" then fail("Not enough arguments or invalid slot") end
        local other = self.neighbors[dir]
        if not other or other == self then return 0 end
        maxAmount = optInt(maxAmount, 64)
        intoSlot = optInt(intoSlot, 0)
        local from, to = toInt(slot) - 1, intoSlot - 1
        checkSlotId(self, from, "input")
        checkSlotId(other, to, "output")
        return M.moveItem(self, from, other, to, maxAmount)
    end
    p:def("pullItem", pull, true)
    p:def("pullItemIntoSlot", pull, true)
    p:def("pushItem", push, true)
    p:def("pushItemIntoSlot", push, true)
end

local Tesseract = setmetatable({}, { __index = Base })
Tesseract.__index = Tesseract

function M.tesseract(world, opts)
    opts = opts or {}
    local p = M.new(world, opts.type or world.config.tesseractType, Tesseract)
    p.frequency = opts.frequency or 0
    p.mode = opts.mode or "both"
    p.owner = opts.ownerName or "Player"
    p.neighbors = {}
    p.uid = world:uid()
    p.dim = opts.dim
    p.pos = opts.pos and util.vec(opts.pos) or nil
    p.delay = opts.delay or world.config.tesseractDelay
    p.buffer = nil
    opCommon(p)
    opInventory(p)
    p:def("getOwner", function(self) return self.owner end)
    p:def("getFrequency", function(self) return self.frequency end)
    p:def("setFrequency", function(self, access, f)
        if type(f) ~= "number" then fail("Invalid argument type") end
        self.frequency = toInt(f)
        return true
    end)
    p:def("canSendItems", function(self) return self:canSend() end)
    p:def("canSendFluid", function(self) return self:canSend() end)
    p:def("canSendEnergy", function(self) return self:canSend() end)
    p:def("canReceiveItems", function(self) return self:canReceive() end)
    p:def("canReceiveFluid", function(self) return self:canReceive() end)
    p:def("canReceiveEnergy", function(self) return self:canReceive() end)
    p:def("getOwnerName", function(self) return self.owner end)
    p:def("canPlayerAccess", function() return true end)
    p:def("getAccess", function() return "PUBLIC" end)
    world.tesseracts[#world.tesseracts + 1] = p
    return p
end

function Tesseract:canSend() return self.mode == "send" or self.mode == "both" end
function Tesseract:canReceive() return self.mode == "receive" or self.mode == "both" end
function Tesseract:invSize() return 1 end
function Tesseract:invName() return "tile.thermalexpansion.tesseract.name" end
function Tesseract:getStack(i)
    if i == 1 then return self.buffer end
    return nil
end
function Tesseract:acceptsAt(i, item)
    return i == 1 and self.buffer == nil
end
function Tesseract:setStack(i, item)
    if i ~= 1 then return end
    self.buffer = item
    if item then
        self.readyAt = self.world.tick + self.delay
        self.world.activeTesseracts[self] = true
    end
end

function Tesseract:adjacent(dir, inv)
    checkDir(dir)
    self.neighbors[dir] = inv
    return self
end

function Tesseract:setMode(mode)
    self.mode = mode
end

function Tesseract:tryDeliver()
    local item = self.buffer
    if not item then return true end
    if not self:canSend() or self.world.tick < (self.readyAt or 0) then return false end
    for _, r in ipairs(self.world.tesseracts) do
        if r ~= self and r.frequency == self.frequency and r:canReceive() then
            for _, d in ipairs(M.DIRECTIONS) do
                local inv = r.neighbors[d]
                if inv and inv ~= r then
                    for slot = 1, inv:invSize() do
                        if inv:acceptsAt(slot, item) and not inv:getStack(slot) then
                            self.buffer = nil
                            inv:setStack(slot, item)
                            self.world:log("tesseract " .. self.frequency .. " delivered " .. tostring(item.kind) .. " to " .. d .. " of receiver " .. r.uid)
                            self.lastDelivery = { tick = self.world.tick, receiver = r, item = item }
                            return true
                        end
                    end
                end
            end
        end
    end
    self.retries = (self.retries or 0) + 1
    return false
end

local BitNet = setmetatable({}, { __index = Base })
BitNet.__index = BitNet

function M.bitnetTower(world, opts)
    opts = opts or {}
    local p = M.new(world, "bitnet_tower", BitNet)
    p.tower = true
    p.complete = opts.complete ~= false
    p.dim = opts.dim
    p.pos = opts.pos and util.vec(opts.pos) or nil
    p.range = opts.range or world.config.towerRange
    p.stormRange = opts.stormRange or world.config.towerRangeStorm
    p.seen = {}
    p.uid = world:uid()
    p:def("isTowerComplete", function(self) return self.complete end)
    p:def("transmit", function(self, access, ...)
        local n = select("#", ...)
        if n ~= 1 then fail("expected 1 arg(s), got " .. n) end
        local payload = ...
        if payload == nil then fail("expected ?, got nil") end
        if not self.complete then return false, "BitNet Communications Tower incomplete." end
        self:send(payload)
        return true
    end)
    world.bitnet[#world.bitnet + 1] = p
    return p
end

function M.bitnetAntenna(world, opts)
    opts = opts or {}
    local p = M.new(world, "bitnet_antenna", BitNet)
    p.tower = false
    p.dim = opts.dim
    p.pos = opts.pos and util.vec(opts.pos) or nil
    p.range = opts.range or world.config.miniAntennaRange
    p.stormRange = opts.stormRange or world.config.miniAntennaRangeStorm
    p.seen = {}
    p.uid = world:uid()
    p:def("transmit", function(self, access, ...)
        local n = select("#", ...)
        if n ~= 1 then fail("expected 1 arg(s), got " .. n) end
        local payload = ...
        if payload == nil then fail("expected ?, got nil") end
        self:send(payload)
    end)
    world.bitnet[#world.bitnet + 1] = p
    return p
end

function BitNet:registered()
    return not self.tower or self.complete
end

function BitNet:setComplete(on)
    self.complete = on and true or false
    return self
end

function BitNet:place(dim, pos)
    self.dim = dim
    self.pos = util.vec(pos)
    return self
end

function BitNet:send(payload)
    local w = self.world
    w.messageSeq = w.messageSeq + 1
    local msg = { id = w.messageSeq, payload = marshal.toJava(payload), distance = 0 }
    w:bitnetTransmit(self, msg)
end

function BitNet:receive(msg)
    if self.seen[msg.id] then return end
    local comps = self:computers()
    if #comps > 0 then
        for _, a in ipairs(comps) do
            a.computer:queueEvent("bitnet_message", a.name, marshal.fromJava(msg.payload), msg.distance)
        end
    elseif self.tower then
        self.world:bitnetTransmit(self, msg)
        self.repeated = (self.repeated or 0) + 1
    end
    self.seen[msg.id] = true
end

local Cipher = setmetatable({}, { __index = Base })
Cipher.__index = Cipher

function M.cipherBlock(world, opts)
    opts = opts or {}
    local p = M.new(world, opts.type or world.config.cipherType, Cipher)
    p.slots = {}
    p.uid = world:uid()
    for i = 1, 6 do
        local it = opts.items and opts.items[i]
        if it then
            p.slots[i] = { kind = "item", id = it.id or 1, damage = it.damage or it.dmg or 0, count = it.count or it.qty or 1, nbtHash = it.nbtHash, name = it.name, maxSize = it.maxSize or 64 }
        end
    end
    opCommon(p)
    p:def("encrypt", function(self, access, text)
        if type(text) == "number" then text = marshal.javaDouble(text) end
        if type(text) ~= "string" then fail("Invalid argument type, expected string") end
        return self:encrypt(text)
    end, false)
    p:def("decrypt", function(self, access, text)
        if type(text) == "number" then text = marshal.javaDouble(text) end
        if type(text) ~= "string" then fail("Invalid argument type, expected string") end
        return self:decrypt(text)
    end, false)
    opInventory(p)
    p:updateKey()
    return p
end

local function lowByte(v)
    return floor(v) % 256
end

function Cipher:updateKey()
    local key, iv = {}, {}
    for i = 0, 31 do key[i] = 0 end
    for i = 0, 15 do iv[i] = 0 end
    for i = 0, 5 do
        local s = self.slots[i + 1]
        if s then
            local id, dmg, size = s.id or 0, s.damage or 0, s.count or 1
            key[i * 5] = lowByte(id)
            key[i * 5 + 1] = lowByte(floor(id / 256))
            key[i * 5 + 2] = lowByte((dmg % 4) + size * 4)
            key[i * 5 + 3] = lowByte(floor(dmg / 4))
            iv[i * 2] = bitops.xor8(lowByte(dmg), lowByte(floor(dmg / 256)))
            if s.nbtHash then
                key[i * 5 + 4] = lowByte(s.nbtHash)
                iv[i * 2 + 1] = lowByte(floor(s.nbtHash / 256))
            end
        end
    end
    local real = {}
    for j = 0, 15 do real[j + 1] = bitops.xor8(key[j], key[j + 16]) end
    local ivb = {}
    for j = 0, 15 do ivb[j + 1] = iv[j] end
    self.key, self.iv = real, ivb
    self.keyId = table.concat(real, ",") .. "|" .. table.concat(ivb, ",")
end

function Cipher:encrypt(text)
    local bytes = marshal.textToFileBytes(text)
    return aes.b64encode(aes.cbcEncrypt(self.key, self.iv, bytes))
end

function Cipher:decrypt(text)
    local raw = aes.b64decode(text)
    if not raw then return nil end
    local plain = aes.cbcDecrypt(self.key, self.iv, raw)
    if not plain then return nil end
    return marshal.fileBytesToText(plain)
end

function Cipher:invSize() return 6 end
function Cipher:invName() return "asielib.inventory.null" end
function Cipher:getStack(i) return self.slots[i] end
function Cipher:acceptsAt(i, item) return i >= 1 and i <= 6 end
function Cipher:setStack(i, item)
    self.slots[i] = item
    self:updateKey()
end
function Cipher:setItems(items)
    for i = 1, 6 do
        local it = items[i]
        self.slots[i] = it and { kind = "item", id = it.id or 1, damage = it.damage or it.dmg or 0, count = it.count or it.qty or 1, nbtHash = it.nbtHash, name = it.name, maxSize = it.maxSize or 64 } or nil
    end
    self:updateKey()
end

local Cell = setmetatable({}, { __index = Base })
Cell.__index = Cell

function M.energyCell(world, opts)
    opts = opts or {}
    local p = M.new(world, opts.type or "cofh_thermalexpansion_energycell", Cell)
    p.stored = opts.stored or 0
    p.max = opts.max or 600000
    p.uid = world:uid()
    opCommon(p)
    local function side(v)
        if v ~= nil and (type(v) ~= "string" or not DIRSET[v] and v ~= "unknown") then fail("Invalid direction") end
    end
    p:def("getEnergyStored", function(self, access, s)
        side(s)
        return self.stored
    end)
    p:def("getMaxEnergyStored", function(self, access, s)
        side(s)
        return self.max
    end)
    return p
end

function Cell:setStored(n)
    self.stored = n
end

return M
