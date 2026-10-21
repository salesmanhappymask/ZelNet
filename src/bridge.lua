local need = ...
local compat = need("compat")
local util = need("util")
local codec = need("codec")
local crypto = need("crypto")
local config = need("config")

local M = {}

M.FILE = "zn_bridge.dat"
M.FORMAT = 1
M.DIRECTIONS = { "north", "south", "east", "west", "up", "down" }
M.OPPOSITE = { north = "south", south = "north", east = "west", west = "east", up = "down", down = "up" }
M.DEFAULTS = { settle = 0.3, poll = 0.5, maxBatch = 100000 }
M.FLOPPY_MAX = 125000
M.BATCH_MIN = 2048
M.BATCH_CAP = 120000
M.HEADER_ROOM = 512
M.QUEUE_MAX = 500
M.QUEUE_BYTES = 1000000
M.QUEUE_TTL = 3600
M.MAX_TRIES = 3
M.RETURN_WARN = 120
M.NO_DISK_GRACE = 30
M.SWEEP_EVERY = 15
M.BACKOFF_MAX = 30
M.SEEN_TTL = 1800
M.ADDR_MAX = 32

local VALID_DIR = {}
for _, d in ipairs(M.DIRECTIONS) do VALID_DIR[d] = true end

local GEAR_KEYS = { "sendTess", "sendDrive", "recvTess", "recvDrive" }
local LABELS = {
    sendTess = "send tesseract", recvTess = "receive tesseract",
    sendDrive = "send drive", recvDrive = "receive drive",
    sendDir = "send direction", recvDir = "receive direction",
}

local function rethrow(ok, err)
    if not ok and err == "Terminated" then error("Terminated", 0) end
    return ok, err
end

local function call(name, method, ...)
    if type(name) ~= "string" then return nil end
    local ok, a = pcall(peripheral.call, name, method, ...)
    rethrow(ok, a)
    if not ok then return nil, a end
    return a
end

local function methodSet(name)
    local set = {}
    if type(name) ~= "string" or not peripheral.isPresent(name) then return set end
    local ok, list = pcall(peripheral.getMethods, name)
    if ok and type(list) == "table" then
        for _, m in ipairs(list) do set[m] = true end
    end
    return set
end

local function isTesseract(name, methods)
    if not methods.pullItem then return false end
    if methods.getFrequency then return true end
    local tp = peripheral.getType(name) or ""
    return name:find("tesseract", 1, true) ~= nil or tp:find("tesseract", 1, true) ~= nil
end

function M.diskIn(drive)
    return call(drive, "isDiskPresent") == true
end

function M.diskGone(drive)
    return peripheral.isPresent(drive) and call(drive, "isDiskPresent") == false
end

function M.mountOf(drive)
    if not M.diskIn(drive) then return nil end
    local p = call(drive, "getMountPath")
    if type(p) ~= "string" or p == "" then return nil end
    local clean = p:gsub("^/+", "")
    return "/" .. clean
end

function M.encodeBatch(from, to, seq, texts)
    local parts = { "{" }
    for i = 1, #texts do
        parts[#parts + 1] = texts[i]
        parts[#parts + 1] = ","
    end
    parts[#parts + 1] = "}"
    local framesText = table.concat(parts)
    local sum = crypto.adler32(framesText)
    local head = codec.encode({ zb = M.FORMAT, from = from, to = to, seq = seq, n = #texts, bytes = #framesText, sum = sum })
    return head:sub(1, -2) .. "frames=" .. framesText .. ",}", sum
end

function M.packBatch(from, to, seq, frames)
    local texts = {}
    for i = 1, #frames do
        local s, err = codec.encode(frames[i])
        if not s then return nil, err end
        texts[i] = s
    end
    return M.encodeBatch(from, to, seq, texts)
end

function M.decodeBatch(text)
    if type(text) ~= "string" or text == "" then return nil, "empty file" end
    if #text > M.FLOPPY_MAX + 4096 then return nil, "file too large" end
    local head, framesText
    local at = text:find(",frames=", 1, true)
    if at and text:sub(-2) == ",}" then
        head = codec.decode(text:sub(1, at) .. "}")
        framesText = text:sub(at + 8, -3)
        if type(head) ~= "table" or head.bytes ~= #framesText then head = nil end
    end
    if not head then
        local whole = codec.decode(text)
        if type(whole) ~= "table" or type(whole.frames) ~= "table" then return nil, "unreadable file" end
        head = whole
        framesText = codec.encode(whole.frames)
        if not framesText then return nil, "unreadable frames" end
    end
    if head.zb ~= M.FORMAT then return nil, "unknown format" end
    if type(head.from) ~= "string" or type(head.to) ~= "string" then return nil, "missing address" end
    if #head.from > M.ADDR_MAX or #head.to > M.ADDR_MAX then return nil, "bad address" end
    if type(head.sum) ~= "number" or crypto.adler32(framesText) ~= head.sum then return nil, "checksum mismatch" end
    local frames = codec.decode(framesText)
    if type(frames) ~= "table" then return nil, "unreadable frames" end
    local list = {}
    for i = 1, #frames do
        if type(frames[i]) == "table" then list[#list + 1] = frames[i] end
    end
    return { from = head.from, to = head.to, seq = tonumber(head.seq) or 0, sum = head.sum, frames = list, bytes = #framesText }
end

function M.findGear(exclude)
    local skip = {}
    for k, v in pairs(exclude or {}) do
        if type(k) == "number" then skip[v] = true else skip[k] = v and true or nil end
    end
    local out = { drives = {}, tesseracts = {} }
    local names = peripheral.getNames and peripheral.getNames() or {}
    for _, n in ipairs(names) do
        if not skip[n] then
            local tp = peripheral.getType(n)
            if tp == "drive" then
                out.drives[#out.drives + 1] = n
            elseif isTesseract(n, methodSet(n)) then
                out.tesseracts[#out.tesseracts + 1] = n
            end
        end
    end
    table.sort(out.drives)
    table.sort(out.tesseracts)
    return out
end

function M.probe(tessName, driveName, settle)
    settle = tonumber(settle) or M.DEFAULTS.settle
    if type(tessName) ~= "string" or not peripheral.isPresent(tessName) then return nil, "tesseract not found" end
    if not methodSet(tessName).pullItem then return nil, tessName .. " has no pullItem (is OpenPeripheral installed?)" end
    if type(driveName) ~= "string" or peripheral.getType(driveName) ~= "drive" then return nil, "drive not found" end
    if not M.diskIn(driveName) then return nil, "put a floppy in " .. driveName .. " first" end
    local prev
    for _, dir in ipairs(M.DIRECTIONS) do
        if prev and M.diskGone(driveName) then return prev end
        local ok = rethrow(pcall(peripheral.call, tessName, "pullItem", dir, 1, 1))
        if M.diskGone(driveName) then return dir end
        prev = ok and dir or nil
        if ok then compat.sleep(settle + 0.1) end
        if ok and M.diskGone(driveName) then return dir end
    end
    if prev and M.diskGone(driveName) then return prev end
    return nil, "the floppy did not leave " .. driveName .. "; check that " .. tessName .. " touches the drive, is linked to the other side, and that the drive on the other side is empty"
end

local function checkNumber(problems, bcfg, key, lo, hi)
    local v = bcfg[key]
    if v == nil then return end
    v = tonumber(v)
    if not v or v < lo or v > hi then
        problems[#problems + 1] = key .. " must be a number from " .. tostring(lo) .. " to " .. tostring(hi)
    end
end

function M.check(bcfg, opts)
    opts = opts or {}
    local problems = {}
    local function add(s) problems[#problems + 1] = s end
    if type(bcfg) ~= "table" then return false, { "no bridge settings" } end
    local peer = util.normRealm(bcfg.peer)
    if not peer then
        add("peer realm name is missing or invalid")
    elseif opts.realm and util.normRealm(opts.realm) == peer then
        add("peer realm is this server's own realm")
    end
    local present = {}
    for _, key in ipairs(GEAR_KEYS) do
        local n = bcfg[key]
        if type(n) ~= "string" or n == "" then
            add(LABELS[key] .. " not chosen")
        elseif not peripheral.isPresent(n) then
            add(LABELS[key] .. " " .. n .. " not found")
        elseif key == "sendDrive" or key == "recvDrive" then
            if peripheral.getType(n) ~= "drive" then add(LABELS[key] .. " " .. n .. " is not a disk drive") else present[key] = true end
        elseif not methodSet(n).pullItem then
            add(LABELS[key] .. " " .. n .. " has no pullItem (is OpenPeripheral installed?)")
        else
            present[key] = true
        end
    end
    if bcfg.sendTess and bcfg.sendTess == bcfg.recvTess then add("send and receive tesseracts must be two different blocks") end
    if bcfg.sendDrive and bcfg.sendDrive == bcfg.recvDrive then add("send and receive drives must be two different drives") end
    for _, key in ipairs({ "sendDir", "recvDir" }) do
        if bcfg[key] ~= nil and not VALID_DIR[bcfg[key]] then
            add(LABELS[key] .. " must be one of " .. table.concat(M.DIRECTIONS, " "))
        end
    end
    checkNumber(problems, bcfg, "settle", 0.05, 5)
    checkNumber(problems, bcfg, "poll", 0.1, 30)
    checkNumber(problems, bcfg, "maxBatch", M.BATCH_MIN, M.BATCH_CAP)
    if not opts.quick and present.sendTess and present.recvTess then
        local sm, rm = methodSet(bcfg.sendTess), methodSet(bcfg.recvTess)
        if sm.getFrequency and rm.getFrequency then
            local freqS, freqR = call(bcfg.sendTess, "getFrequency"), call(bcfg.recvTess, "getFrequency")
            if freqS ~= nil and freqS == freqR then
                add("send and receive tesseracts share frequency " .. tostring(freqS) .. "; this send frequency must equal the other side's receive frequency and the other way round")
            end
        end
    end
    if opts.disks and present.sendDrive and not M.diskIn(bcfg.sendDrive) then
        add("no floppy in the send drive " .. bcfg.sendDrive .. " (each side keeps one floppy in its send drive)")
    end
    return #problems == 0, problems
end

local Bridge = {}
Bridge.__index = Bridge

function M.new(bcfg, ctx)
    local self = setmetatable({}, Bridge)
    self.cfg = bcfg or {}
    self.ctx = ctx or {}
    self.log = self.ctx.log
    local rootCfg = self.ctx.cfg or {}
    self.realm = util.normRealm(rootCfg.realm)
    self.peer = util.normRealm(self.cfg.peer)
    self.queue = {}
    self.queuedBytes = 0
    self.inflight = nil
    self.outgoing = nil
    self.seq = 0
    self.seen = util.newSeenSet(M.SEEN_TTL, 400)
    self.faults = {}
    self.retry = { send = { at = 0, delay = 0 }, recv = { at = 0, delay = 0 } }
    self.full = {}
    self.confirmed = {}
    self.badDirs = {}
    self.streak = { sendDir = 0, recvDir = 0 }
    self.stats = {
        sent = 0, received = 0, trips = 0, lastTrip = nil, errors = 0, lastError = nil,
        bytesOut = 0, bytesIn = 0, batchesIn = 0, rejected = 0, returned = 0, dropped = 0,
        resent = 0, duplicates = 0, corrections = 0,
    }
    self.state = "idle"
    self.sendDisk, self.recvDisk = false, false
    self.nextSweep = 0
    self.stopped = false
    self.running = false
    self:applyTuning()
    return self
end

function Bridge:applyTuning()
    local c = self.cfg
    self.settle = util.clamp(tonumber(c.settle) or M.DEFAULTS.settle, 0.05, 5)
    self.poll = util.clamp(tonumber(c.poll) or M.DEFAULTS.poll, 0.1, 30)
    self.maxBatch = util.clamp(math.floor(tonumber(c.maxBatch) or M.DEFAULTS.maxBatch), M.BATCH_MIN, M.BATCH_CAP)
end

function Bridge:note(level, text)
    local log = self.log
    if log and log[level] then log[level]("bridge " .. tostring(self.peer or self.cfg.peer) .. ": " .. text) end
end

function Bridge:notice(text)
    self.stats.errors = self.stats.errors + 1
    self.stats.lastError = text
    self:note("warn", text)
end

function Bridge:setFault(side, text, backoff)
    if self.faults[side] ~= text then
        self.stats.errors = self.stats.errors + 1
        self:note("warn", text)
    end
    self.stats.lastError = text
    self.faults[side] = text
    if backoff then
        local r = self.retry[side]
        r.delay = math.min(M.BACKOFF_MAX, math.max(2, r.delay * 2))
        r.at = compat.now() + r.delay
    end
end

function Bridge:recover(side)
    if self.faults[side] then self:note("info", "recovered: " .. self.faults[side]) end
    self.faults[side] = nil
    local r = self.retry[side]
    if r then
        r.delay = 0
        r.at = 0
    end
    self.full[side] = nil
end

function Bridge:gearProblem()
    local c = self.cfg
    if not self.realm then return "unconfigured", "this server's realm is unknown" end
    if not self.peer then return "unconfigured", "peer realm name is missing or invalid" end
    if self.peer == self.realm then return "unconfigured", "peer realm is this server's own realm" end
    for _, key in ipairs(GEAR_KEYS) do
        if type(c[key]) ~= "string" or c[key] == "" then return "unconfigured", LABELS[key] .. " not set" end
    end
    for _, key in ipairs(GEAR_KEYS) do
        local n = c[key]
        if not peripheral.isPresent(n) then return "fault", LABELS[key] .. " " .. n .. " not found" end
        if (key == "sendDrive" or key == "recvDrive") and peripheral.getType(n) ~= "drive" then
            return "fault", LABELS[key] .. " " .. n .. " is not a disk drive"
        end
    end
    return nil
end

function Bridge:enqueue(wire)
    if type(wire) ~= "table" then return nil, "bad packet" end
    if self.state == "unconfigured" then return nil, "bridge unconfigured" end
    local text, err = codec.encode(wire)
    if not text then return nil, err end
    if #text + M.HEADER_ROOM > self.maxBatch then return nil, "too_large" end
    if #self.queue >= M.QUEUE_MAX or self.queuedBytes + #text > M.QUEUE_BYTES then
        self.stats.dropped = self.stats.dropped + 1
        return nil, "queue full"
    end
    self.queue[#self.queue + 1] = { text = text, size = #text, t = compat.now(), tries = 0 }
    self.queuedBytes = self.queuedBytes + #text
    return true
end

function Bridge:putBack(items, countTry)
    local keep, dropped = {}, 0
    for _, it in ipairs(items) do
        if countTry then it.tries = (it.tries or 0) + 1 end
        if (it.tries or 0) >= M.MAX_TRIES then dropped = dropped + 1 else keep[#keep + 1] = it end
    end
    for i = #keep, 1, -1 do
        table.insert(self.queue, 1, keep[i])
        self.queuedBytes = self.queuedBytes + keep[i].size
    end
    if countTry then self.stats.resent = self.stats.resent + #keep end
    if dropped > 0 then
        self.stats.dropped = self.stats.dropped + dropped
        self:notice("dropped " .. dropped .. " packet(s) after " .. M.MAX_TRIES .. " failed deliveries to " .. tostring(self.peer))
    end
end

function Bridge:takeBatch(limit, now)
    local items, texts, size, expired = {}, {}, 2, 0
    while #self.queue > 0 do
        local it = self.queue[1]
        if now - it.t > M.QUEUE_TTL then
            table.remove(self.queue, 1)
            self.queuedBytes = self.queuedBytes - it.size
            expired = expired + 1
        elseif size + it.size + 1 <= limit then
            table.remove(self.queue, 1)
            self.queuedBytes = self.queuedBytes - it.size
            items[#items + 1] = it
            texts[#texts + 1] = it.text
            size = size + it.size + 1
        else
            break
        end
    end
    if expired > 0 then
        self.stats.dropped = self.stats.dropped + expired
        self:notice("dropped " .. expired .. " packet(s) that waited over " .. M.QUEUE_TTL .. "s")
    end
    return items, texts
end

function Bridge:requeueFile(batch)
    local items = {}
    for _, w in ipairs(batch.frames) do
        local text = codec.encode(w)
        if text then items[#items + 1] = { text = text, size = #text, t = compat.now(), tries = 0 } end
    end
    self:putBack(items, false)
    return #items
end

function Bridge:deliver(batch)
    local key = batch.from .. "|" .. tostring(batch.seq) .. "|" .. tostring(batch.sum)
    if self.seen.check(key) then
        self.stats.duplicates = self.stats.duplicates + 1
        return false
    end
    self.stats.received = self.stats.received + #batch.frames
    self.stats.bytesIn = self.stats.bytesIn + (batch.bytes or 0)
    self.stats.batchesIn = self.stats.batchesIn + 1
    if self.onReceive and #batch.frames > 0 then
        local ok, err = rethrow(pcall(self.onReceive, batch.frames))
        if not ok then self:note("error", "receive handler: " .. tostring(err)) end
    end
    return true
end

function Bridge:tryPull(tess, drive, dir)
    local ok, moved = rethrow(pcall(peripheral.call, tess, "pullItem", dir, 1, 1))
    if M.diskGone(drive) then return true end
    if not ok then return false, true end
    compat.sleep(self.settle)
    if M.diskGone(drive) then return true end
    if (tonumber(moved) or 0) > 0 then
        self.badDirs[tess] = self.badDirs[tess] or {}
        self.badDirs[tess][dir] = true
        self:notice("pulled an item from the " .. dir .. " side of " .. tess .. " that was not the floppy; that side is skipped from now on")
    end
    return false
end

function Bridge:eject(tess, drive, dirKey, full)
    if not M.diskIn(drive) then return true end
    local dir = self.cfg[dirKey]
    if not VALID_DIR[dir] then dir = nil end
    local order, seen = {}, {}
    local bad = self.badDirs[tess] or {}
    local function add(d)
        if d and not seen[d] and not bad[d] then
            seen[d] = true
            order[#order + 1] = d
        end
    end
    add(dir)
    local quick = dir and self.confirmed[dirKey] and not full and (self.streak[dirKey] % 4) ~= 3
    if not quick then
        if dir then add(M.OPPOSITE[dir]) end
        for _, d in ipairs(M.DIRECTIONS) do add(d) end
    end
    local prev, hit
    for _, d in ipairs(order) do
        if prev and M.diskGone(drive) then
            hit = prev
            break
        end
        local moved, failed = self:tryPull(tess, drive, d)
        if moved then
            hit = d
            break
        end
        prev = not failed and d or nil
    end
    if not hit and prev and M.diskGone(drive) then hit = prev end
    if hit then
        self.confirmed[dirKey] = true
        self.streak[dirKey] = 0
        if hit ~= dir then self:saveDir(dirKey, hit) end
        return true
    end
    self.streak[dirKey] = self.streak[dirKey] + 1
    if #order == 0 then return false, "floppy did not leave " .. drive .. " (no direction left to try)" end
    return false, "floppy did not leave " .. drive .. " (tried " .. table.concat(order, " ") .. ")"
end

function Bridge:saveDir(dirKey, dir)
    local old = self.cfg[dirKey]
    self.cfg[dirKey] = dir
    self.stats.corrections = self.stats.corrections + 1
    local root = self.ctx.cfg
    local found, saved, err = false, false, nil
    if type(root) == "table" and type(root.bridges) == "table" then
        for _, e in pairs(root.bridges) do
            if type(e) == "table" and util.normRealm(e.peer) == self.peer then
                e[dirKey] = dir
                found = true
            end
        end
        if found then
            local ok, a, b = pcall(config.save, root, self.ctx.configPath)
            if ok then saved, err = a, b else saved, err = false, a end
        end
    end
    local text = LABELS[dirKey] .. " corrected from " .. tostring(old) .. " to " .. dir
    if not found then
        text = text .. " (bridge not in config, not saved)"
    elseif not saved then
        text = text .. " (save failed: " .. tostring(err) .. ")"
    end
    self:note("info", text)
end

function Bridge:labelDisk(drive)
    local want = "ZelNet " .. self.realm .. ">" .. self.peer
    if call(drive, "getDiskLabel") ~= want then call(drive, "setDiskLabel", want) end
end

function Bridge:acceptFile(path)
    local batch, why = M.decodeBatch(util.readFile(path))
    if batch and batch.from == self.realm then
        batch, why = nil, "it is our own batch (do the send and receive tesseracts share a frequency?)"
    elseif batch and batch.to ~= self.realm then
        batch, why = nil, "it is addressed to " .. batch.to
    elseif batch and batch.from ~= self.peer then
        batch, why = nil, "it came from " .. batch.from .. ", expected " .. self.peer
    end
    if not batch then
        self.stats.rejected = self.stats.rejected + 1
        self:notice("rejected a floppy in the receive drive: " .. tostring(why))
        return false
    end
    self:deliver(batch)
    pcall(fs.delete, path)
    if fs.exists(path) then self:notice("cannot delete the batch file on the receive floppy") end
    return true
end

function Bridge:serviceReceive(now, force)
    local c = self.cfg
    local drive = c.recvDrive
    local present = M.diskIn(drive)
    self.recvDisk = present
    if not present then
        if self.faults.recv then self:recover("recv") end
        return false
    end
    if not force and now < self.retry.recv.at then return false end
    self.state = "receiving"
    local mount = M.mountOf(drive)
    if not mount then
        compat.sleep(self.settle)
        mount = M.mountOf(drive)
    end
    local accepted = false
    if mount then
        local path = mount .. "/" .. M.FILE
        if fs.exists(path) then accepted = self:acceptFile(path) end
    elseif M.diskIn(drive) then
        self:notice("returning an item in " .. drive .. " that is not a floppy")
    end
    if not accepted then self.stats.returned = self.stats.returned + 1 end
    local ok, why = self:eject(c.recvTess, drive, "recvDir", force or self.full.recv)
    if not ok then
        self:setFault("recv", "cannot return the floppy to " .. tostring(self.peer) .. ": " .. why, true)
        return false
    end
    self.recvDisk = false
    self:recover("recv")
    return true
end

function Bridge:adoptFile(path, where)
    local batch = M.decodeBatch(util.readFile(path))
    pcall(fs.delete, path)
    if not batch then return end
    if batch.from == self.realm and batch.to == self.peer then
        local n = self:requeueFile(batch)
        self:note("info", "found unsent batch " .. tostring(batch.seq) .. " in the " .. where .. ", queued " .. n .. " packet(s) again")
    elseif batch.from == self.peer and batch.to == self.realm then
        self:deliver(batch)
        self:notice("a floppy from " .. self.peer .. " arrived in the " .. where .. "; check the tesseract frequencies")
    end
end

function Bridge:takeReturn(drive, diskId, now)
    local fl = self.inflight
    self.inflight = nil
    local mount = M.mountOf(drive)
    if not mount then
        compat.sleep(self.settle)
        mount = M.mountOf(drive)
    end
    local path = mount and (mount .. "/" .. M.FILE)
    local present = path and fs.exists(path)
    if not mount or (fl.disk ~= nil and diskId ~= nil and fl.disk ~= diskId) then
        self:notice("a different " .. (mount and "floppy" or "item") .. " is in the send drive; sending " .. #fl.items .. " packet(s) again")
        self:putBack(fl.items, false)
        if present then self:adoptFile(path, "send drive") end
        return
    end
    self.stats.trips = self.stats.trips + 1
    self.stats.lastTrip = now - fl.at
    if not present then
        self.stats.sent = self.stats.sent + #fl.items
        self.stats.bytesOut = self.stats.bytesOut + fl.bytes
        return
    end
    local batch = M.decodeBatch(util.readFile(path))
    pcall(fs.delete, path)
    if batch and batch.from == self.peer and batch.to == self.realm then
        self:deliver(batch)
        self:notice("a floppy from " .. self.peer .. " arrived in the send drive; check the tesseract frequencies")
        self:putBack(fl.items, true)
        return
    end
    self:notice("batch " .. fl.seq .. " came back from " .. tostring(self.peer) .. " undelivered")
    self:putBack(fl.items, true)
end

function Bridge:sendBatch(drive, diskId, now)
    local mount = M.mountOf(drive)
    if not mount then
        self:setFault("send", "the item in " .. drive .. " is not a floppy", true)
        return false
    end
    local path = mount .. "/" .. M.FILE
    if fs.exists(path) then pcall(fs.delete, path) end
    local okFree, free = pcall(fs.getFreeSpace, mount)
    free = okFree and tonumber(free) or M.FLOPPY_MAX
    local limit = math.min(self.maxBatch, free - M.HEADER_ROOM)
    local items, texts = self:takeBatch(limit, now)
    if #items == 0 then
        if #self.queue > 0 then self:setFault("send", "the floppy in " .. drive .. " is full (" .. tostring(free) .. " bytes free)", true) end
        return false
    end
    self.seq = self.seq + 1
    local text = M.encodeBatch(self.realm, self.peer, self.seq, texts)
    local ok, err = util.writeFile(path, text)
    if not ok then
        self:putBack(items, false)
        self:setFault("send", "cannot write the send floppy: " .. tostring(err), true)
        return false
    end
    self.state = "sending"
    self.outgoing = items
    self:labelDisk(drive)
    local sent, why = self:eject(self.cfg.sendTess, drive, "sendDir", self.full.send)
    self.outgoing = nil
    if not sent then
        pcall(fs.delete, path)
        self:putBack(items, false)
        self:setFault("send", why, true)
        return false
    end
    self.inflight = { seq = self.seq, items = items, at = now, disk = diskId, bytes = #text }
    self.sendDisk = false
    self:recover("send")
    return true
end

function Bridge:serviceSend(now)
    local drive = self.cfg.sendDrive
    local present = M.diskIn(drive)
    self.sendDisk = present
    if not present then
        self.noDiskSince = self.noDiskSince or now
        local fl = self.inflight
        if fl then
            if not fl.warned and now - fl.at > M.RETURN_WARN then
                fl.warned = true
                self:notice("floppy not back from " .. tostring(self.peer) .. " after " .. M.RETURN_WARN .. "s (is that bridge running?)")
            end
        elseif #self.queue > 0 and now - self.noDiskSince > M.NO_DISK_GRACE then
            self:setFault("disk", "no floppy in the send drive " .. drive, false)
        end
        return false
    end
    self.noDiskSince = nil
    if self.faults.disk then self:recover("disk") end
    local diskId = call(drive, "getDiskID")
    if self.inflight then
        self:takeReturn(drive, diskId, now)
        return true
    end
    local mount = M.mountOf(drive)
    if mount and fs.exists(mount .. "/" .. M.FILE) then self:adoptFile(mount .. "/" .. M.FILE, "send drive") end
    if #self.queue == 0 then return false end
    if now < self.retry.send.at then return false end
    return self:sendBatch(drive, diskId, now)
end

function Bridge:sweep(now)
    if now < self.nextSweep then return end
    self.nextSweep = now + M.SWEEP_EVERY
    for _, side in ipairs({ "send", "recv" }) do
        if self.faults[side] and self.retry[side].at > 0 then
            self.retry[side].at = 0
            self.full[side] = true
        end
    end
    if self.faults.recv and M.diskIn(self.cfg.recvDrive) then
        self:note("info", "failsafe sweep: returning the floppy stuck in " .. self.cfg.recvDrive)
        self:serviceReceive(now, true)
    end
end

function Bridge:refreshState()
    if self.faults.gear then return end
    if self.faults.send or self.faults.recv or self.faults.disk then
        self.state = "fault"
    elseif self.inflight or not self.sendDisk then
        self.state = "waiting"
    else
        self.state = "idle"
    end
end

function Bridge:step()
    local kind, why = self:gearProblem()
    if kind then
        if self.faults.gear ~= why then
            self.stats.errors = self.stats.errors + 1
            self:note("warn", why)
        end
        self.faults.gear = why
        self.stats.lastError = why
        self.state = kind
        return false
    end
    if self.faults.gear then
        self.faults.gear = nil
        self:note("info", "bridge gear found")
    end
    local did = false
    local ok, res = rethrow(pcall(self.serviceReceive, self, compat.now(), false))
    if not ok then self:setFault("recv", "receive: " .. tostring(res), true) elseif res then did = true end
    ok, res = rethrow(pcall(self.serviceSend, self, compat.now()))
    if not ok then self:setFault("send", "send: " .. tostring(res), true) elseif res then did = true end
    if not did then
        ok, res = rethrow(pcall(self.sweep, self, compat.now()))
        if not ok then self:setFault("recv", "sweep: " .. tostring(res), true) end
    end
    self:refreshState()
    return did
end

function Bridge:run(onReceive)
    if onReceive then self.onReceive = onReceive end
    self.stopped = false
    self.running = true
    while not self.stopped do
        local ok, did = rethrow(pcall(self.step, self))
        if not ok then
            self:setFault("send", "bridge: " .. tostring(did), true)
            did = false
        end
        if self.stopped then break end
        compat.sleep(did and 0.05 or self.poll)
    end
    self.running = false
end

function Bridge:stop()
    self.stopped = true
end

function Bridge:status()
    local s = self.stats
    local fl = self.inflight
    local moving = fl and #fl.items or (self.outgoing and #self.outgoing) or 0
    return {
        peer = self.peer or self.cfg.peer,
        state = self.state,
        queued = #self.queue,
        inflight = moving,
        queuedBytes = self.queuedBytes,
        sent = s.sent,
        received = s.received,
        trips = s.trips,
        lastTrip = s.lastTrip,
        errors = s.errors,
        lastError = s.lastError,
        sendDisk = self.sendDisk,
        recvDisk = self.recvDisk,
        fault = self.faults.gear or self.faults.send or self.faults.recv or self.faults.disk,
        waiting = fl and (compat.now() - fl.at) or nil,
        bytesOut = s.bytesOut,
        bytesIn = s.bytesIn,
        batchesIn = s.batchesIn,
        rejected = s.rejected,
        returned = s.returned,
        dropped = s.dropped,
        resent = s.resent,
        duplicates = s.duplicates,
        corrections = s.corrections,
        sendDir = self.cfg.sendDir,
        recvDir = self.cfg.recvDir,
        seq = self.seq,
    }
end

return M
