local need = ...
local compat = need("compat")
local frame = need("frame")

local M = {}

local SIDES = { "top", "bottom", "left", "right", "front", "back" }
local BITNET_TYPES = { bitnet_tower = "tower", bitnet_antenna = "antenna" }

local LinkSet = {}
LinkSet.__index = LinkSet

function M.new(opts)
    local self = setmetatable({}, LinkSet)
    self.channel = opts.channel or 4747
    self.netId = opts.netId
    self.myId = opts.myId or os.getComputerID()
    self.log = opts.log
    self.useWired = opts.useWired ~= false
    self.useBitnet = opts.useBitnet ~= false
    self.links = {}
    self.order = {}
    self.neighbors = {}
    self.stats = { tx = 0, rx = 0, dropped = 0, bad = 0 }
    return self
end

local function logf(self, level, text)
    if self.log and self.log[level] then self.log[level](text) end
end

local function safeCall(name, method, ...)
    local ok, a, b = pcall(peripheral.call, name, method, ...)
    if not ok then return nil, a end
    return a, b
end

function LinkSet:add(link)
    if self.links[link.id] then
        self.links[link.id].present = true
        return self.links[link.id]
    end
    link.tx, link.rx, link.present = 0, 0, true
    self.links[link.id] = link
    self.order[#self.order + 1] = link.id
    logf(self, "info", "link up: " .. link.id)
    return link
end

function LinkSet:scan()
    for _, l in pairs(self.links) do l.present = false end
    for _, side in ipairs(SIDES) do
        if peripheral.isPresent(side) and peripheral.getType(side) == "modem" then
            local wireless = safeCall(side, "isWireless")
            if wireless or self.useWired then
                local link = self:add({ id = "modem:" .. side, kind = "modem", name = side, wireless = wireless and true or false })
                if not safeCall(side, "isOpen", self.channel) then
                    local ok, err = pcall(peripheral.call, side, "open", self.channel)
                    if not ok then logf(self, "warn", "cannot open channel on " .. side .. ": " .. tostring(err)) end
                end
                link.open = safeCall(side, "isOpen", self.channel) and true or false
            end
        end
    end
    if self.useBitnet then
        local names = {}
        local seen = {}
        for _, side in ipairs(SIDES) do
            seen[side] = true
            names[#names + 1] = side
        end
        if peripheral.getNames then
            for _, n in ipairs(peripheral.getNames()) do
                if not seen[n] then
                    seen[n] = true
                    names[#names + 1] = n
                end
            end
        end
        for _, n in ipairs(names) do
            if peripheral.isPresent(n) then
                local kind = BITNET_TYPES[peripheral.getType(n) or ""]
                if kind then
                    local link = self:add({ id = "bitnet:" .. n, kind = "bitnet", sub = kind, name = n, wireless = true })
                    if kind == "tower" then
                        link.complete = safeCall(n, "isTowerComplete") and true or false
                    else
                        link.complete = true
                    end
                    link.open = link.complete
                end
            end
        end
    end
    local keep = {}
    for _, id in ipairs(self.order) do
        local l = self.links[id]
        if l.present then
            keep[#keep + 1] = id
        else
            logf(self, "warn", "link down: " .. id)
            self.links[id] = nil
        end
    end
    self.order = keep
    return self:list()
end

function LinkSet:list()
    local out = {}
    for _, id in ipairs(self.order) do out[#out + 1] = self.links[id] end
    return out
end

function LinkSet:count()
    local n = 0
    for _, id in ipairs(self.order) do
        if self.links[id].open then n = n + 1 end
    end
    return n
end

function LinkSet:hasBitnet()
    for _, id in ipairs(self.order) do
        local l = self.links[id]
        if l.kind == "bitnet" and l.open then return true end
    end
    return false
end

function LinkSet:sendOn(link, f)
    if not link or not link.open then return false end
    local ok, err
    if link.kind == "modem" then
        ok, err = pcall(peripheral.call, link.name, "transmit", self.channel, self.channel, f)
    else
        local okCall, res, msg = pcall(peripheral.call, link.name, "transmit", f)
        ok = okCall and res ~= false
        err = okCall and msg or res
        if okCall and res == false and link.sub == "tower" then link.complete = false end
    end
    if ok then
        link.tx = link.tx + 1
        self.stats.tx = self.stats.tx + 1
        return true
    end
    self.stats.dropped = self.stats.dropped + 1
    logf(self, "debug", "send failed on " .. link.id .. ": " .. tostring(err))
    return false
end

function LinkSet:broadcast(f, exceptLink)
    local sent = 0
    for _, id in ipairs(self.order) do
        if id ~= exceptLink and self:sendOn(self.links[id], f) then sent = sent + 1 end
    end
    return sent > 0
end

function LinkSet:sendTo(cid, f)
    f.t = cid
    local nb = self.neighbors[cid]
    if nb and self.links[nb.link] and compat.now() - nb.t < 120 then
        if self:sendOn(self.links[nb.link], f) then return true end
    end
    return self:broadcast(f)
end

function LinkSet:learn(cid, linkId, dist)
    local nb = self.neighbors[cid]
    local now = compat.now()
    if not nb then
        nb = { link = linkId, t = now, dist = dist }
        self.neighbors[cid] = nb
        return nb
    end
    local current = self.links[nb.link]
    local better = linkId == nb.link or not current or now - nb.t > 60
    if not better and current and current.kind == "bitnet" and linkId:sub(1, 6) == "modem:" then better = true end
    if better then
        nb.link = linkId
        nb.dist = dist
    end
    nb.t = now
    return nb
end

function LinkSet:forget(cid)
    self.neighbors[cid] = nil
end

function LinkSet:isLinkEvent(ev)
    return ev == "modem_message" or ev == "bitnet_message"
end

function LinkSet:isPeripheralEvent(ev)
    return ev == "peripheral" or ev == "peripheral_detach"
end

function LinkSet:decode(ev, a, b, c, d, e)
    local f, linkId, dist
    if ev == "modem_message" then
        if b ~= self.channel then return nil end
        f, linkId, dist = d, "modem:" .. tostring(a), e
    elseif ev == "bitnet_message" then
        f, linkId, dist = b, "bitnet:" .. tostring(a), c
    else
        return nil
    end
    if not frame.valid(f, self.netId, self.myId) then
        if type(f) == "table" and f.zn == 1 then self.stats.bad = self.stats.bad + 1 end
        return nil
    end
    if f.f == self.myId then return nil end
    local link = self.links[linkId]
    if link then link.rx = link.rx + 1 end
    self.stats.rx = self.stats.rx + 1
    self:learn(f.f, linkId, dist)
    return f, linkId, dist
end

function LinkSet:closeAll()
    for _, id in ipairs(self.order) do
        local l = self.links[id]
        if l.kind == "modem" then pcall(peripheral.call, l.name, "close", self.channel) end
        l.open = false
    end
end

return M
