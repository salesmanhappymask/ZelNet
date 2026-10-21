local need = ...
local compat = need("compat")
local util = need("util")
local crypto = need("crypto")
local frame = need("frame")
local seal = need("seal")
local config = need("config")
local version = need("version")
local registry = need("registry")
local directory = need("directory")
local backbone = need("backbone")
local gateway = need("gateway")

local M = {}

M.DOWN_ROUTE_TTL = 600
M.RATE_WINDOW = 10
M.RATE_MAX = 100
M.LINK_RATE_MAX = 600
M.ERR_MAX = 30
M.BAD_MAX = 20
M.SUB_TTL = 600
M.MAX_SUBS_PER_NODE = 64
M.MAX_TOPICS = 500
M.PUB_MIN_GAP = 0.9
M.CATCHUP_GAP = 600
M.REPORT_EVERY = 300
M.REPORT_DELAY = 5
M.REPORT_MAX_DEVICES = 200
M.PUB_SUB_TTL = 86400
M.PLAIN_TTL = 21600
M.MAX_PLAIN = 1000
M.UPDATE_CHUNK = 6000
M.UPDATE_REBOOT_DELAY = 120
M.MAX_WARNINGS = 20
M.MAX_INBOX_PORTS = 64
M.FLUSH_INTERVAL = 30
M.FULL_FLUSH_INTERVAL = 300
M.PROGRAM_PATH = "/zelnet"

local Server = {}
Server.__index = Server

local SERVER_ONLY_PORTS = { ["zn.ps"] = true, ["zn.err"] = true, ["zn.hello"] = true, ["zn.update"] = true }

function M.updateAad(ver, size, sha)
    return "zn.update|" .. tostring(ver) .. "|" .. tostring(size) .. "|" .. tostring(sha)
end

M.TRACE_KINDS = { device = "in", backbone = "bb", flood = "flood", ["local"] = "out" }

function M.new(ctx)
    local self = setmetatable({}, Server)
    local cfg = ctx.cfg
    self.ctx = ctx
    self.cfg = cfg
    self.node = ctx.node
    self.log = ctx.log or ctx.node.log
    self.realm = cfg.realm
    self.myId = ctx.node.myId
    self.isMain = cfg.role == "main"
    self.mainRealm = util.normRealm(cfg.mainRealm) or cfg.realm
    self.started = compat.now()
    self.down = {}
    self.rate = {}
    self.linkRate = {}
    self.errRate = {}
    self.badRate = {}
    self.topics = {}
    self.pubTimes = {}
    self.plain = {}
    self.caughtUp = {}
    self.realmVersions = {}
    self.localNames = {}
    self.warnings = {}
    self.noted = {}
    self.beaconSeq = 0
    self.update = nil
    self.fetching = false
    self.running = false
    self.accessSeen = util.newSeenSet(1800, 20000)
    self.counters = {
        accessIn = 0, accessBad = 0, unknownDevice = 0, revoked = 0, spoofed = 0, replays = 0,
        rateLimited = 0, routedDown = 0, flooded = 0, errors = 0, published = 0, beacons = 0,
    }
    self.reg = registry.new(ctx)
    self.dir = directory.new(ctx, self)
    self.bb = backbone.new(ctx, self)
    return self
end

function Server:count(key, n)
    self.counters[key] = (self.counters[key] or 0) + (n or 1)
end

function Server:warn(text)
    text = util.sanitize(text)
    for _, w in ipairs(self.warnings) do
        if w.text == text then
            w.count = w.count + 1
            w.t = compat.now()
            return
        end
    end
    self.warnings[#self.warnings + 1] = { text = text, t = compat.now(), count = 1 }
    while #self.warnings > M.MAX_WARNINGS do table.remove(self.warnings, 1) end
    self.log.warn(text)
    self.node:emit("warning", text)
end

function Server:clearWarnings()
    self.warnings = {}
end

function Server:noteOnce(key, text)
    local now = compat.now()
    local last = self.noted[key]
    if last and now - last < 600 then return end
    self.noted[key] = now
    self.log.warn(text)
end

function Server:deviceWindow()
    local keep = tonumber(self.cfg.keepalive) or 120
    return tonumber(self.cfg.deviceTimeout) or math.max(300, keep * 2.5)
end

function Server:start()
    if self.running then return true end
    self.running = true
    local n = self.node
    n:start()
    self.reg.window = self:deviceWindow()
    self.reg:load()
    self.dir:load()
    n:onFrame("p", function(_, f, linkId, dist) self:onAccessFrame(f, linkId, dist) end)
    n:onFrame("b", function(_, f, linkId, dist) self:onBeaconFrame(f, linkId, dist) end)
    n:setRouter(function(pkt) self:routePacket(pkt, "local") end)
    n:listen("zn.hello", function(msg) self:onHelloMsg(msg) end)
    n:listen("zn.name", function(msg) self:onNameMsg(msg) end)
    n:listen("zn.ps", function(msg) self:onPsMsg(msg) end)
    n:listen("zn.dir", function(msg) self.dir:handle(msg) end)
    n:listen("zn.route", function() end)
    n:listen("zn.admin", function(msg) self:onAdminMsg(msg) end)
    n:listen("zn.update", function(msg) self:onUpdateMsg(msg) end)
    n:listen(gateway.CONTROL, function(msg) self:onPubMsg(msg) end)
    self.gateway = gateway.new(n, {
        log = self.log,
        isOff = function() return self.cfg.publicGateway == false end,
        backend = {
            seen = function(cid) self:notePlain(cid, "self") end,
            blocked = function(cid) return self:pubBlocked(cid) end,
            connected = function() return true end,
            op = function(b) self:pubOp(b) end,
        },
    })
    self.gateway:start()
    n.localSubscribe = function(topic) self:subscribe(self.realm, topic, math.huge) end
    n.localUnsubscribe = function(topic) self:unsubscribe(self.realm, topic) end
    self.bb:start()
    self.dir:start()
    n:after(0.2, function() self:sendBeacon() end, "beacon-first")
    n:every(tonumber(self.cfg.beaconInterval) or 10, function() self:sendBeacon() end, "beacon")
    n:every(15, function() self:housekeeping() end, "server-housekeeping")
    n:every(M.FLUSH_INTERVAL, function() self:flushState(false) end, "server-flush")
    n:every(M.FULL_FLUSH_INTERVAL, function() self:flushState(true) end, "server-flush-full")
    n:on("realm_up", function(r) self:onRealmUp(r) end)
    if not self.isMain then
        n:after(20, function() self:sendReport() end, "version-report-first")
        n:every(M.REPORT_EVERY, function() self:sendReport() end, "version-report")
        n:on("realm_up", function(r) if r == self.mainRealm then self:scheduleReport() end end)
    end
    self.log.info("server " .. self.realm .. " (" .. self.cfg.role .. ") started as computer " .. tostring(self.myId))
    return true
end

function Server:on(event, fn)
    return self.node:on(event, fn)
end

function Server:sendBeacon()
    local seq = math.floor(compat.stamp() * 100)
    if seq <= self.beaconSeq then seq = self.beaconSeq + 1 end
    self.beaconSeq = seq
    local d = { realm = self.realm, root = self.myId, seq = seq, hops = 0, ver = version.protocol, prog = version.program }
    d.mac = seal.beaconMac(self.cfg.realmKey, d)
    self.node.links:broadcast(frame.make(self.cfg.netId, "b", self.myId, nil, d))
    self:count("beacons")
end

function Server:onBeaconFrame(f, linkId, dist)
    local d = f.d
    if not frame.validBeacon(d) or d.realm ~= self.realm or d.root == self.myId then return end
    if self.noted["beacon:" .. tostring(d.root)] then return end
    local origin = M.originKey(linkId, dist)
    if self:isBlocked(origin) then return end
    if crypto.constEq(seal.beaconMac(self.cfg.realmKey, d), d.mac) then
        self.noted["beacon:" .. tostring(d.root)] = compat.now()
        self:warn("computer " .. tostring(d.root) .. " also serves realm " .. self.realm)
    else
        self:noteBad(origin)
    end
end

function Server:windowAllow(tbl, key, max, label)
    local now = compat.now()
    local r = tbl[key]
    if not r or now - r.start >= M.RATE_WINDOW then
        local warned = r and r.over or false
        r = { start = now, count = 0, warned = warned, over = false }
        tbl[key] = r
    end
    r.count = r.count + 1
    if r.count > max then
        r.over = true
        self:count("rateLimited")
        if not r.warned then
            r.warned = true
            self.log.warn("rate limit: " .. label)
        end
        return false
    end
    return true
end

function M.originKey(linkId, dist)
    local d = tonumber(dist)
    return tostring(linkId) .. "@" .. (d and util.fmtFixed(d, 1) or "?")
end

function Server:isBlocked(origin)
    local r = self.badRate[origin]
    return r ~= nil and compat.now() - r.start < M.RATE_WINDOW and r.count >= M.BAD_MAX
end

function Server:noteBad(origin)
    self:windowAllow(self.badRate, origin, M.BAD_MAX, "bad packets from the sender at " .. origin)
end

function Server:deviceFromSrc(src)
    local a = util.parseAddress(src)
    if not a or a.realm ~= self.realm or not a.id then return nil end
    return self.reg:byCid(a.id)
end

function Server:onAccessFrame(f, linkId, dist)
    local w = f.d
    if not frame.validAccess(w) then
        self:count("accessBad")
        return
    end
    if w.dir ~= "u" or f.t ~= self.myId or w.ttl ~= w.ttl or w.ttl <= 0 then return end
    local origin = M.originKey(linkId, dist)
    if self:isBlocked(origin) then
        self:count("blocked")
        return
    end
    if not self:windowAllow(self.linkRate, origin, M.LINK_RATE_MAX, "sender at " .. origin) then return end
    local dev = self.reg:get(w.dev)
    if not dev then
        self:count("unknownDevice")
        self:noteOnce("unknown", "packet from unknown device " .. util.sanitize(w.dev))
        return
    end
    if dev.status == "revoked" then
        self:count("revoked")
        self:noteOnce("revoked:" .. dev.name, "revoked device " .. dev.name .. " is still sending")
        return
    end
    local pkt = seal.openAccess(dev.key, w)
    if not pkt then
        self:noteBad(origin)
        self:count("accessBad")
        self.node:count("badMac")
        return
    end
    if self.accessSeen.check(w.id) then
        self:count("replays")
        return
    end
    local a = util.parseAddress(pkt.src)
    if not a or a.realm ~= self.realm or not a.id or pkt.src ~= self.realm .. ":" .. a.id then
        self:count("spoofed")
        return
    end
    local cid = a.id
    if dev.cid == nil then
        local _, displaced = self.reg:bind(dev.name, cid)
        self.log.info("device " .. dev.name .. " bound to computer " .. cid)
        if displaced then self.log.warn("computer " .. cid .. " moved from device " .. displaced.name .. " to " .. dev.name) end
    elseif dev.cid ~= cid then
        self:count("spoofed")
        self:noteOnce("cid:" .. dev.name .. ":" .. cid, "device " .. dev.name .. " sent from computer " .. cid .. " but is bound to " .. dev.cid)
        return
    end
    if not self:windowAllow(self.rate, dev.name, M.RATE_MAX, "device " .. dev.name) then return end
    self.down[cid] = { via = f.f, link = linkId, t = compat.now(), dist = dist }
    local parent = (f.f == cid) and self.myId or f.f
    if self.reg:touch(dev.name, { link = linkId, via = f.f, parent = parent }) then
        self.log.info("device online: " .. dev.name)
        self.node:emit("device_online", dev.name)
    end
    self:count("accessIn")
    self:routePacket(pkt, "device", dev)
end

function Server:isServerTarget(a)
    if not a.id and not a.name then return true end
    if a.id then return a.id == self.myId end
    if a.name == self.node.name or self.localNames[a.name] then return true end
    return self.node.names ~= nil and self.node.names[a.name] == true
end

function Server:findDevice(a)
    local dev
    if a.id then
        dev = self.reg:byCid(a.id)
    elseif a.name then
        dev = self.reg:lookup(a.name)
    end
    if dev and dev.status ~= "revoked" then return dev end
    return nil
end

function Server:routePacket(pkt, origin, dev)
    if type(pkt) ~= "table" or pkt.v ~= version.protocol then return end
    if type(pkt.dst) ~= "string" or type(pkt.src) ~= "string" or type(pkt.id) ~= "string" then return end
    if pkt.port ~= "zn.hello" or origin ~= "local" then
        self.node:trace(M.TRACE_KINDS[origin] or "pkt", pkt.src .. " > " .. pkt.dst .. " " .. tostring(pkt.port) .. (pkt.re and " reply" or ""))
    end
    if pkt.dst == "*" then
        if origin == "device" and pkt.port:sub(1, 3) == "zn." then
            self:count("dropped")
            return
        end
        if origin == "local" or origin == "device" then
            local ok, err = self.bb:flood(pkt)
            if not ok and err == "too_large" then
                self:errorFor({ id = pkt.id, src = pkt.src, dst = self.realm, port = pkt.port }, "too_large", "packet too large for the backbone")
            end
        end
        if origin == "device" or origin == "flood" then self:deliverLocal(pkt, origin) end
        return
    end
    local a = util.parseAddress(pkt.dst)
    if not a or a.realm == "*" then
        self:errorFor(pkt, "unknown_node", "bad address " .. pkt.dst)
        return
    end
    if a.realm ~= self.realm then
        if origin == "backbone" or origin == "flood" then return end
        local ok, err = self.bb:sendPacket(pkt)
        if not ok then self:errorFor(pkt, err == "too_large" and "too_large" or "no_route", tostring(err)) end
        return
    end
    if self:isServerTarget(a) then
        self:deliverLocal(pkt, origin)
        return
    end
    local target = self:findDevice(a)
    if not target then
        if a.id and self:deliverPlain(a.id, pkt) then return end
        self:errorFor(pkt, "unknown_node", "no node " .. pkt.dst)
        return
    end
    if SERVER_ONLY_PORTS[pkt.port] and not self:isServerAddress(pkt.src) then
        self:count("dropped")
        return
    end
    self:sendDown(target, pkt)
end

function Server:inboxFull(pkt)
    local n = self.node
    if n.ports[pkt.port] or n.inboxes[pkt.port] then return false end
    if pkt.port == "zn.ping" or pkt.port == "zn.err" then return false end
    if pkt.re and n.pending[pkt.re] then return false end
    return util.count(n.inboxes) >= M.MAX_INBOX_PORTS
end

function Server:deliverLocal(pkt, origin)
    if pkt.port == "zn.ps" and type(pkt.body) == "table" and pkt.body.op == "msg" and origin ~= "local" then return end
    if origin ~= "local" and self:inboxFull(pkt) then
        self:count("dropped")
        self:noteOnce("inboxes", "too many unanswered ports, dropping packets for port " .. util.sanitize(pkt.port))
        return
    end
    self.node:deliver(pkt)
end

function Server:sendDown(dev, pkt)
    if not dev.cid or dev.status == "revoked" then
        self:errorFor(pkt, "unknown_node", "device " .. dev.name .. " is not installed")
        return false
    end
    local out = {
        v = pkt.v, id = pkt.id, src = pkt.src, dst = self.realm .. ":" .. dev.cid, port = pkt.port, ttl = 24,
        re = pkt.re, rq = pkt.rq, body = pkt.body,
    }
    local w, err = seal.sealAccess(dev.key, out, "d", dev.name)
    if not w then
        self:errorFor(pkt, err == "too_large" and "too_large" or "denied", tostring(err))
        return false
    end
    local f = frame.make(self.cfg.netId, "p", self.myId, nil, w)
    local r = self.down[dev.cid]
    if r and compat.now() - r.t < M.DOWN_ROUTE_TTL then
        self.node.links:sendTo(r.via, f)
    else
        self.node.links:broadcast(f)
        self:count("flooded")
    end
    self:count("routedDown")
    return true
end

function Server:errorFor(pkt, code, text)
    if type(pkt) ~= "table" or pkt.port == "zn.err" or pkt.dst == "*" then return end
    if type(pkt.src) ~= "string" or type(pkt.id) ~= "string" then return end
    if not self:windowAllow(self.errRate, pkt.src, M.ERR_MAX, "errors to " .. pkt.src) then return end
    self:count("errors")
    self.node:send(pkt.src, "zn.err", { code = code, msg = text, ref = pkt.id }, { re = pkt.id })
end

function Server:onHelloMsg(msg)
    local dev = self:deviceFromSrc(msg.src)
    if not dev then
        if msg.rq then self.node:reply(msg, { ok = false, err = "denied" }) end
        return
    end
    local b = type(msg.data) == "table" and msg.data or {}
    local fields = {}
    local oldProg, oldRel = dev.prog, dev.rel
    if type(b.prog) == "string" then fields.prog = util.sanitize(b.prog):sub(1, 24) end
    fields.rel = tonumber(b.rel) and math.floor(tonumber(b.rel)) or nil
    if type(b.hops) == "number" then fields.hops = math.floor(b.hops) end
    if not dev.installed then fields.installed = compat.stamp() end
    self.reg:setInfo(dev.name, fields)
    if msg.rq then
        self.node:reply(msg, { ok = true, realm = self.realm, server = self.myId, prog = version.full(), time = compat.stamp() })
    end
    if fields.prog and oldProg and fields.prog ~= oldProg then
        self.log.info(tostring(dev.role) .. " " .. tostring(dev.name) .. " updated from " .. version.labelOf(oldProg, oldRel) .. " to " .. version.labelOf(fields.prog, fields.rel))
        self:scheduleReport()
    elseif fields.prog and not oldProg then
        self:scheduleReport()
    end
    if fields.prog and fields.prog ~= (self:target()) then self:catchUp(dev) end
end

function Server:resolveName(name)
    if name == self.node.name or self.localNames[name] then
        return { ok = true, addr = self.realm .. ":" .. self.myId }
    end
    local dev = self.reg:lookup(name)
    if not dev or dev.status == "revoked" or not dev.cid then return { ok = false, err = "unknown_node" } end
    return { ok = true, addr = self.realm .. ":" .. dev.cid }
end

function Server:nameOp(src, b)
    if type(b) ~= "table" then return { ok = false, err = "bad_request" } end
    local name = util.normName(b.name)
    if not name then return { ok = false, err = "bad_name" } end
    if b.op == "resolve" then return self:resolveName(name) end
    local isSelf = src == self.realm
    local dev = (not isSelf) and self:deviceFromSrc(src) or nil
    if not isSelf and not dev then return { ok = false, err = "denied" } end
    local addr = self.realm .. ":" .. name
    if b.op == "register" then
        if isSelf then
            if self.reg:isTaken(name) then return { ok = false, err = "taken" } end
            self.localNames[name] = true
            return { ok = true, addr = addr }
        end
        if name == dev.name then return { ok = true, addr = addr } end
        if name == self.node.name or self.localNames[name] then return { ok = false, err = "taken" } end
        local ok, err = self.reg:addAlias(dev.name, name)
        if not ok then return { ok = false, err = err == "bad name" and "bad_name" or err } end
        return { ok = true, addr = addr }
    elseif b.op == "release" then
        if isSelf then
            self.localNames[name] = nil
            if self.node.names then self.node.names[name] = nil end
            return { ok = true }
        end
        local ok, err = self.reg:removeAlias(dev.name, name)
        if not ok then return { ok = false, err = err } end
        return { ok = true }
    end
    return { ok = false, err = "bad_request" }
end

function Server:onNameMsg(msg)
    local reply = self:nameOp(msg.src, msg.data)
    if msg.rq and reply then self.node:reply(msg, reply) end
end

local function validPattern(pattern)
    if not util.validTopic(pattern) then return false end
    local star = pattern:find("%*")
    if not star then return true end
    return star == #pattern and pattern:sub(-2) == ".*" and #pattern > 2
end

local function validExact(topic)
    return util.validTopic(topic) and not topic:find("%*")
end

function Server:topicEntry(key, create)
    local e = self.topics[key]
    if e or not create then return e end
    if util.count(self.topics) >= M.MAX_TOPICS then return nil end
    e = { subs = {}, retained = nil }
    self.topics[key] = e
    return e
end

function Server:subCount(addr)
    local n = 0
    for _, e in pairs(self.topics) do
        if e.subs[addr] then n = n + 1 end
    end
    return n
end

function Server:subscribe(addr, pattern, ttl)
    if not validPattern(pattern) then return nil, "bad topic" end
    local now = compat.now()
    local existing = self.topics[pattern]
    local isNew = not existing or not existing.subs[addr] or existing.subs[addr] < now
    if isNew and self:subCount(addr) >= M.MAX_SUBS_PER_NODE then return nil, "too many subscriptions" end
    local e = self:topicEntry(pattern, true)
    if not e then return nil, "too many topics" end
    e.subs[addr] = now + (ttl or M.SUB_TTL)
    if isNew then
        for key, te in pairs(self.topics) do
            if te.retained and validExact(key) and util.topicMatches(pattern, key) then
                local r = te.retained
                self.node:send(addr, "zn.ps", { op = "msg", topic = key, data = r.data, from = r.from, retained = true })
            end
        end
    end
    return true
end

function Server:dropSubscriber(addr)
    local n = 0
    for key, e in compat.spairs(self.topics) do
        if e.subs[addr] then
            e.subs[addr] = nil
            n = n + 1
        end
        if not e.retained and next(e.subs) == nil then self.topics[key] = nil end
    end
    return n
end

function Server:unsubscribe(addr, pattern)
    local e = self.topics[pattern]
    if not e then return true end
    e.subs[addr] = nil
    if not e.retained and next(e.subs) == nil then self.topics[pattern] = nil end
    return true
end

function Server:publishLocal(topic, data, from, retain)
    if not validExact(topic) then return 0 end
    if type(from) ~= "string" then from = "?" end
    if retain then
        local e = self:topicEntry(topic, data ~= nil)
        if e then
            if data == nil then
                e.retained = nil
            else
                e.retained = { data = data, from = from, t = compat.stamp() }
            end
        end
    end
    local now = compat.now()
    local body = { op = "msg", topic = topic, data = data, from = from }
    local sent = {}
    local n = 0
    for key, e in pairs(self.topics) do
        if util.topicMatches(key, topic) then
            for addr, exp in compat.spairs(e.subs) do
                if exp < now then
                    e.subs[addr] = nil
                elseif not sent[addr] then
                    sent[addr] = true
                    n = n + 1
                    self.node:send(addr, "zn.ps", body)
                end
            end
        end
    end
    return n
end

function Server:publish(src, topic, data, retain)
    if not validExact(topic) then return nil, "bad topic" end
    local key = src .. "|" .. topic
    local now = compat.now()
    local last = self.pubTimes[key]
    if last and now - last < M.PUB_MIN_GAP then
        self:count("rateLimited")
        return nil, "rate_limited"
    end
    self.pubTimes[key] = now
    self:count("published")
    self:publishLocal(topic, data, src, retain)
    self:broadcastRealms("zn.ps", { op = "fwd", topic = topic, data = data, from = src, retain = retain and true or nil })
    return true
end

function Server:psOp(src, b)
    local op = b.op
    if op == "fwd" then
        local a = util.parseAddress(src)
        if not a or a.id or a.name or a.realm == self.realm or a.realm == "*" then return nil end
        self:publishLocal(b.topic, b.data, b.from, b.retain)
        return nil
    end
    local isSelf = src == self.realm
    if not isSelf and not self:deviceFromSrc(src) then return { ok = false, err = "denied" } end
    local ok, err
    if op == "sub" then
        ok, err = self:subscribe(src, b.topic, isSelf and math.huge or M.SUB_TTL)
    elseif op == "unsub" then
        ok, err = self:unsubscribe(src, b.topic)
    elseif op == "pub" then
        ok, err = self:publish(src, b.topic, b.data, b.retain)
    else
        return { ok = false, err = "bad_request" }
    end
    if ok then return { ok = true } end
    return { ok = false, err = err }
end

function Server:onPsMsg(msg)
    if type(msg.data) ~= "table" then return end
    local reply = self:psOp(msg.src, msg.data)
    if msg.rq and reply then self.node:reply(msg, reply) end
end

function Server:pubBlocked(cid)
    local list = self.cfg.publicBlock
    if type(list) ~= "table" then return false end
    for _, id in ipairs(list) do
        if tonumber(id) == tonumber(cid) then return true end
    end
    return false
end

function Server:notePlain(cid, via)
    cid = tonumber(cid)
    if not cid then return end
    if not self.plain[cid] and util.count(self.plain) >= M.MAX_PLAIN then
        local oldest, oldT
        for k, v in pairs(self.plain) do
            if not oldT or v.t < oldT then oldest, oldT = k, v.t end
        end
        if oldest then self.plain[oldest] = nil end
    end
    self.plain[cid] = { via = via, t = compat.now() }
end

function Server:plainFrom(from)
    local a = util.parseAddress(from)
    if not a or a.realm ~= self.realm or not a.id then return nil end
    if self:pubBlocked(a.id) then return nil end
    return a.realm .. ":" .. a.id
end

function Server:pubOp(b)
    if type(b) ~= "table" then return end
    local from = self:plainFrom(b.from)
    if not from then return end
    if b.op == "send" then
        local to = util.normAddress(b.to)
        if to then self.node:send(to, gateway.PORT, b.data, { src = from }) end
    elseif b.op == "publish" and gateway.stripTopic(b.topic) then
        self:publish(from, b.topic, b.data, b.retain)
    elseif b.op == "subscribe" and gateway.stripTopic(b.topic) then
        self:subscribe(from, b.topic, M.PUB_SUB_TTL)
    elseif b.op == "unsubscribe" and gateway.stripTopic(b.topic) then
        self:unsubscribe(from, b.topic)
    end
end

function Server:onPubMsg(msg)
    local dev = self:deviceFromSrc(msg.src)
    if not dev or dev.role ~= "router" or type(msg.data) ~= "table" then return end
    if self.cfg.publicGateway == false then return end
    local b = msg.data
    if b.op == "seen" then
        local cid = tonumber(b.cid)
        if cid and not self:pubBlocked(cid) then self:notePlain(cid, msg.src) end
        return
    end
    self:pubOp(b)
end

function Server:deliverPlain(cid, pkt)
    if self.cfg.publicGateway == false or not self.gateway then return false end
    if pkt.port ~= gateway.PORT and pkt.port ~= "zn.ps" and pkt.port ~= "zn.err" then return false end
    if self:pubBlocked(cid) then return true end
    local msg = gateway.toPlain(pkt, self:isServerAddress(pkt.src))
    if not msg then
        self:count("dropped")
        return true
    end
    local lease = self.plain[cid]
    if lease and lease.via ~= "self" then
        self.node:send(lease.via, gateway.CONTROL, { op = "deliver", cid = cid, msg = msg })
    else
        self.gateway:transmit(cid, msg)
    end
    return true
end

function Server:isServerAddress(src)
    local a = util.parseAddress(src)
    return a ~= nil and a.id == nil and a.name == nil and a.realm ~= "*"
end

function Server:versionReport()
    local devices = {}
    for _, d in ipairs(self.reg:list()) do
        if #devices >= M.REPORT_MAX_DEVICES then break end
        local rec = self.reg.devices[d.name]
        devices[#devices + 1] = { name = d.name, role = d.role, prog = d.prog, rel = rec and rec.rel or nil, status = d.status }
    end
    local pending = self.installed and self.installed.version ~= version.full() and self.installed or nil
    return { op = "versions", realm = self.realm, prog = version.full(), rel = version.release, devices = devices,
        pending = pending and pending.version or nil, pendingRel = pending and pending.rel or nil }
end

function Server:sendReport()
    self.reportArmed = false
    if self.isMain then return end
    self.node:send(self.mainRealm, "zn.admin", self:versionReport())
end

function Server:scheduleReport()
    if self.isMain or self.reportArmed then return end
    self.reportArmed = true
    self.node:after(M.REPORT_DELAY, function() self:sendReport() end, "version-report")
end

function Server:onVersionReport(src, b)
    local a = util.parseAddress(src)
    if not self.isMain or not a or a.id or a.name or a.realm == self.realm or a.realm ~= util.normRealm(b.realm) then return end
    local realm = a.realm
    local prev = self.realmVersions[realm]
    local entry = { prog = type(b.prog) == "string" and b.prog:sub(1, 24) or "?", rel = tonumber(b.rel), t = compat.now(), devices = {},
        pending = type(b.pending) == "string" and b.pending:sub(1, 24) or nil, pendingRel = tonumber(b.pendingRel) }
    local prevDevices = {}
    if prev then
        for _, d in ipairs(prev.devices) do prevDevices[d.name] = d end
        if prev.prog ~= entry.prog then
            self.log.info(realm .. " server updated from " .. version.labelOf(prev.prog, prev.rel) .. " to " .. version.labelOf(entry.prog, entry.rel))
        end
    end
    if type(b.devices) == "table" then
        for i, d in ipairs(b.devices) do
            if i > M.REPORT_MAX_DEVICES then break end
            if type(d) == "table" and type(d.name) == "string" then
                local item = {
                    name = util.sanitize(d.name):sub(1, 32), role = type(d.role) == "string" and d.role:sub(1, 12) or "?",
                    prog = type(d.prog) == "string" and d.prog:sub(1, 24) or nil, rel = tonumber(d.rel),
                    status = type(d.status) == "string" and d.status:sub(1, 12) or "?",
                }
                local old = prevDevices[item.name]
                if old and old.prog and item.prog and old.prog ~= item.prog then
                    self.log.info(realm .. " " .. item.role .. " " .. item.name .. " updated to " .. version.labelOf(item.prog, item.rel))
                end
                entry.devices[#entry.devices + 1] = item
            end
        end
    end
    self.realmVersions[realm] = entry
    local want = self:target()
    if entry.prog ~= want and entry.pending ~= want then self:catchUpRealm(realm) end
end

function Server:catchUpRealm(realm)
    local now = compat.now()
    local key = "realm:" .. realm
    local last = self.caughtUp[key]
    if last and now - last < M.CATCHUP_GAP then return false end
    self.caughtUp[key] = now
    if not self:ownUpdate() then return false end
    local u = self.update
    self.node:send(realm, "zn.update", {
        op = "offer", version = u.version, rel = u.rel, size = u.size, sha = u.sha, chunks = u.chunks,
        mac = crypto.mac(self.cfg.backboneKey, M.updateAad(u.version, u.size, u.sha)),
    })
    self.log.info("offered " .. version.labelOf(u.version, u.rel) .. " to " .. realm .. ", which runs " .. version.labelOf(self.realmVersions[realm] and self.realmVersions[realm].prog, self.realmVersions[realm] and self.realmVersions[realm].rel))
    return true
end

function Server:networkVersions()
    local out = { { realm = self.realm, main = self.isMain, prog = version.full(), rel = version.release, t = 0, devices = {} } }
    out.target, out.targetRel = self:target()
    if out.target ~= version.full() then out[1].pending, out[1].pendingRel = out.target, out.targetRel end
    for _, d in ipairs(self.reg:list()) do
        local rec = self.reg.devices[d.name]
        out[1].devices[#out[1].devices + 1] = { name = d.name, role = d.role, prog = d.prog, rel = rec and rec.rel or nil, status = d.status }
    end
    local now = compat.now()
    local known = {}
    for realm, e in pairs(self.realmVersions) do
        known[realm] = true
        out[#out + 1] = { realm = realm, prog = e.prog, rel = e.rel, t = now - e.t, devices = e.devices, pending = e.pending, pendingRel = e.pendingRel }
    end
    local reach = {}
    for _, r in ipairs(self:realms()) do
        reach[r.realm] = r.reachable
        if r.realm ~= self.realm and not known[r.realm] then out[#out + 1] = { realm = r.realm, devices = {} } end
    end
    for _, e in ipairs(out) do e.reachable = e.realm == self.realm or reach[e.realm] == true end
    table.sort(out, function(x, y)
        if x.realm == self.realm then return true end
        if y.realm == self.realm then return false end
        return x.realm < y.realm
    end)
    return out
end

function Server:onAdminMsg(msg)
    if type(msg.data) == "table" and msg.data.op == "versions" then
        self:onVersionReport(msg.src, msg.data)
        return
    end
    local allowed = msg.src == self.realm or (self:isServerAddress(msg.src) and util.parseAddress(msg.src).realm == self.mainRealm)
    local b = msg.data
    local reply
    if not allowed then
        reply = { ok = false, err = "denied" }
    elseif type(b) ~= "table" then
        reply = { ok = false, err = "bad_request" }
    elseif b.op == "status" then
        reply = self:status()
        reply.ok = true
    elseif b.op == "provision_log" then
        reply = { ok = true, realm = self.realm, devices = self:devices() }
    else
        reply = { ok = false, err = "bad_request" }
    end
    if msg.rq then self.node:reply(msg, reply) end
end

function Server:adminQuery(realm, op, timeout)
    local r = util.normRealm(realm)
    if not r then return nil, "bad realm" end
    op = op or "status"
    if r == self.realm then
        if op == "status" then
            local st = self:status()
            st.ok = true
            return st
        elseif op == "provision_log" then
            return { ok = true, realm = self.realm, devices = self:devices() }
        end
        return nil, "bad_request"
    end
    local reply, err = self.node:request(r, "zn.admin", { op = op }, timeout or 40, { retries = 0 })
    if not reply then return nil, err end
    if type(reply) ~= "table" then return nil, "bad reply" end
    if not reply.ok then return nil, reply.err or "refused" end
    return reply
end

function Server:programPath()
    return self.cfg.programPath or M.PROGRAM_PATH
end

function Server:prepareUpdate(text, ver)
    local sha = crypto.sha256(text)
    local chunks = math.ceil(#text / M.UPDATE_CHUNK)
    local rel = tonumber(text:match("release = (%d+)"))
    self.update = { text = text, version = ver, rel = rel, sha = sha, size = #text, chunks = chunks }
    return {
        op = "offer", version = ver, rel = rel, size = #text, sha = sha, chunks = chunks,
        mac = crypto.mac(self.cfg.backboneKey, M.updateAad(ver, #text, sha)),
    }
end

function Server:target()
    local u = self.update
    if u and u.version ~= version.full() then return u.version, u.rel end
    return version.full(), version.release
end

function Server:offerDevice(rec)
    local u = self.update
    if not u or not rec.cid or rec.status == "revoked" or type(rec.key) ~= "string" then return false end
    self.node:send(self.realm .. ":" .. rec.cid, "zn.update", {
        op = "offer", version = u.version, size = u.size, sha = u.sha, chunks = u.chunks,
        mac = crypto.mac(rec.key, M.updateAad(u.version, u.size, u.sha)),
    })
    return true
end

function Server:offerDevices()
    if not self.update then return 0 end
    local n = 0
    for _, rec in pairs(self.reg.devices) do
        if self:offerDevice(rec) then n = n + 1 end
    end
    return n
end

function Server:ownUpdate()
    if self.update then return self.update end
    local text = util.readFile(self:programPath())
    if type(text) ~= "string" or #text < 1000 then return nil end
    if not text:find('build = "' .. tostring(version.build) .. '"', 1, true) then return nil end
    self:prepareUpdate(text, version.full())
    return self.update
end

function Server:catchUp(dev)
    local now = compat.now()
    local last = self.caughtUp[dev.name]
    if last and now - last < M.CATCHUP_GAP then return false end
    self.caughtUp[dev.name] = now
    if not self:ownUpdate() then return false end
    if self:offerDevice(dev) then
        self.log.info("offered " .. self.update.version .. " to " .. tostring(dev.name) .. ", which runs " .. tostring(dev.prog or "an older build"))
        return true
    end
    return false
end

function Server:pushUpdate(text, ver)
    if not self.isMain then return nil, "only Main can update the network" end
    if type(text) ~= "string" or #text < 64 then return nil, "program text missing" end
    if type(ver) ~= "string" or ver == "" then return nil, "version missing" end
    local fn, err = loadstring(text, "=zelnet")
    if not fn then return nil, "does not compile: " .. tostring(err) end
    local offer = self:prepareUpdate(text, ver)
    self.updateOffer = offer
    self:broadcastRealms("zn.update", offer)
    self:offerDevices()
    self.log.info("network update " .. version.labelOf(ver, self.update.rel) .. " offered to every realm and device")
    return true
end

function Server:onRealmUp(realm)
    if self.isMain and self.updateOffer and realm ~= self.realm then
        self.node:send(realm, "zn.update", self.updateOffer)
    end
end

function Server:serveChunk(msg, b)
    local u = self.update
    local allowed = self:deviceFromSrc(msg.src) or self:isServerAddress(msg.src)
    if not allowed then return { ok = false, err = "denied" } end
    if not u or b.sha ~= u.sha then return { ok = false, err = "no_update" } end
    local i = tonumber(b.i)
    if not i or i < 1 or i > u.chunks or i ~= math.floor(i) then return { ok = false, err = "bad_request" } end
    return { ok = true, i = i, sha = u.sha, data = u.text:sub((i - 1) * M.UPDATE_CHUNK + 1, i * M.UPDATE_CHUNK) }
end

function Server:validOffer(b)
    return type(b.version) == "string" and #b.version <= 24 and type(b.sha) == "string" and #b.sha == 64
        and type(b.size) == "number" and b.size > 0 and b.size < 2000000
        and type(b.chunks) == "number" and b.chunks == math.ceil(b.size / M.UPDATE_CHUNK) and type(b.mac) == "string"
end

function Server:fetchUpdate(b)
    self.fetching = true
    local parts = {}
    for i = 1, b.chunks do
        local reply, err = self.node:request(self.mainRealm, "zn.update", { op = "chunk", sha = b.sha, i = i }, 40, { retries = 2 })
        if type(reply) ~= "table" or not reply.ok or type(reply.data) ~= "string" then
            self.fetching = false
            self:warn("update download failed: " .. tostring(err or (type(reply) == "table" and reply.err) or "bad reply"))
            return false
        end
        parts[i] = reply.data
    end
    local text = table.concat(parts)
    self.fetching = false
    if #text ~= b.size or crypto.sha256(text) ~= b.sha then
        self:warn("update " .. b.version .. " failed its checksum")
        return false
    end
    local fn, cerr = loadstring(text, "=zelnet")
    if not fn then
        self:warn("update " .. b.version .. " does not compile: " .. tostring(cerr))
        return false
    end
    return self:installUpdate(text, b.version)
end

function Server:installUpdate(text, ver)
    local path = self:programPath()
    local tmp = path .. ".dl"
    local ok, err = util.writeFile(tmp, text)
    if ok then
        if fs.exists(path) then fs.delete(path) end
        fs.move(tmp, path)
    else
        pcall(fs.delete, tmp)
    end
    if not ok then
        self:warn("cannot install update " .. ver .. ": " .. tostring(err))
        return false
    end
    self:prepareUpdate(text, ver)
    self.installed = { version = ver, rel = self.update.rel }
    self:offerDevices()
    self:scheduleReport()
    self:warn("update " .. version.labelOf(ver, self.update.rel) .. " installed")
    self.node:emit("update_installed", ver)
    if self.cfg.updateReboot ~= false then
        self.node:after(M.UPDATE_REBOOT_DELAY, function()
            if os.reboot then os.reboot() end
        end, "update-reboot")
    end
    return true
end

function Server:onUpdateMsg(msg)
    local b = msg.data
    if type(b) ~= "table" then return end
    if b.op == "chunk" then
        if msg.rq then self.node:reply(msg, self:serveChunk(msg, b)) end
        return
    end
    if b.op ~= "offer" or self.isMain or msg.src ~= self.mainRealm or not self:validOffer(b) then return end
    if not crypto.constEq(crypto.mac(self.cfg.backboneKey, M.updateAad(b.version, b.size, b.sha)), b.mac) then
        self:warn("rejected an update offer with a bad signature")
        return
    end
    if self.fetching or b.version == version.full() or (self.update and self.update.sha == b.sha) then return end
    self.log.info("downloading update " .. b.version)
    self:fetchUpdate(b)
end

function Server:housekeeping()
    local now = compat.now()
    for _, name in ipairs(self.reg:sweep(self:deviceWindow())) do
        self.log.info("device offline: " .. name)
        self.node:emit("device_offline", name)
    end
    for cid, r in compat.spairs(self.down) do
        if now - r.t > M.DOWN_ROUTE_TTL then self.down[cid] = nil end
    end
    for cid, r in compat.spairs(self.plain) do
        if now - r.t > M.PLAIN_TTL then self.plain[cid] = nil end
    end
    for _, tbl in ipairs({ self.rate, self.linkRate, self.errRate, self.badRate }) do
        for k, r in compat.spairs(tbl) do
            if now - r.start > M.RATE_WINDOW * 6 then tbl[k] = nil end
        end
    end
    for k, t in compat.spairs(self.pubTimes) do
        if now - t > 5 then self.pubTimes[k] = nil end
    end
    for key, e in compat.spairs(self.topics) do
        for addr, exp in compat.spairs(e.subs) do
            if exp < now then e.subs[addr] = nil end
        end
        if not e.retained and next(e.subs) == nil then self.topics[key] = nil end
    end
    for k, t in compat.spairs(self.noted) do
        if now - t > 3600 then self.noted[k] = nil end
    end
    if self.reg.waitStorage then self.reg:flush() end
    if self.dir.waitStorage then self.dir:flush() end
end

function Server:flushState(force)
    self.reg:flush(force)
    self.dir:flush()
end

function Server:status()
    local total, online = self.reg:counts()
    local c = self.ctx.cipher
    local warnings = {}
    for _, w in ipairs(self.warnings) do warnings[#warnings + 1] = w.text end
    local counters = util.copy(self.node.counters)
    for k, v in pairs(self.counters) do counters[k] = v end
    for k, v in pairs(self.bb.counters) do counters["bb_" .. k] = v end
    local linksList = {}
    for _, l in ipairs(self.node.links:list()) do
        linksList[#linksList + 1] = { id = l.id, kind = l.kind, sub = l.sub, name = l.name, complete = l.complete, wireless = l.wireless, open = l.open, tx = l.tx, rx = l.rx }
    end
    return {
        realm = self.realm, role = self.cfg.role, isMain = self.isMain, serverId = self.myId,
        uptime = compat.now() - self.started, mainRealm = self.mainRealm, prog = version.program, protocol = version.protocol,
        devices = { total = total, online = online },
        neighbors = self.bb:neighborList(),
        routes = self.bb:routeList(),
        bridges = self.bb:bridgeStatus(),
        queue = { backbone = self.bb:bridgeQueued(), stored = self.bb:queueSize() },
        counters = counters,
        cipher = { kind = c and c.kind or "none", name = c and c.name or nil, fingerprint = self.bb.fp, ok = self.bb.enabled },
        warnings = warnings,
        links = linksList,
        directory = {
            ver = self.dir.ver, synced = self.isMain or self.dir.synced,
            users = util.count(self.dir.users), realms = util.count(self.dir.realms),
        },
        update = self.update and { version = self.update.version, size = self.update.size } or nil,
    }
end

function Server:devices()
    return self.reg:list()
end

function Server:provisionSatellite(name)
    if not self.isMain then return nil, "only Main can provision satellites" end
    local realm = util.normRealm(name)
    if not realm then return nil, "bad realm name" end
    if realm == self.realm then return nil, "realm exists" end
    local known = self.dir.realms[realm]
    if known and known.serverId then return nil, "realm exists" end
    if not known and util.count(self.dir.realms) >= directory.MAX_REALMS then return nil, "too many realms" end
    local cfg = self.cfg
    local scfg = config.newServer({
        role = "satellite", network = cfg.network, realm = realm, mainRealm = self.mainRealm, backboneKey = cfg.backboneKey,
    })
    scfg.netId = nil
    scfg.channel = cfg.channel
    scfg.useWired = cfg.useWired
    scfg.useBitnet = cfg.useBitnet
    scfg.allowSoftwareBackbone = cfg.allowSoftwareBackbone
    scfg.helloInterval = cfg.helloInterval
    scfg.routeInterval = cfg.routeInterval
    scfg.provisionedBy = self.realm
    self.dir:noteProvisioned(realm)
    self.log.info("satellite provisioned: " .. realm)
    return scfg
end

function Server:provision(role, name)
    if role == "satellite" then return self:provisionSatellite(name) end
    if not registry.DEVICE_ROLES[role] then return nil, "bad role" end
    local n = util.normName(name)
    if not n then return nil, "bad name" end
    if n == self.node.name or self.localNames[n] or self.reg:isTaken(n) then return nil, "taken" end
    local dcfg = config.newDevice(self.cfg, role, n, self.myId)
    local rec, err = self.reg:add(n, role, dcfg.deviceKey)
    if not rec then return nil, err end
    self.log.info("provisioned " .. role .. " " .. n)
    return dcfg
end

function Server:forgetComputer(cid)
    if not cid then return end
    self.down[cid] = nil
    self:dropSubscriber(self.realm .. ":" .. cid)
end

function Server:revoke(name)
    local rec = self.reg:get(name)
    if not rec then return nil, "unknown device" end
    self:forgetComputer(rec.cid)
    local ok, err = self.reg:revoke(name)
    if ok then self.log.warn("device revoked: " .. name) end
    return ok, err
end

function Server:resetBinding(name)
    local rec = self.reg:get(name)
    if not rec then return nil, "unknown device" end
    self:forgetComputer(rec.cid)
    return self.reg:resetBinding(name)
end

function Server:removeDevice(name)
    local rec = self.reg:get(name)
    if not rec then return nil, "unknown device" end
    self:forgetComputer(rec.cid)
    return self.reg:remove(name)
end

function Server:realms()
    local out = {}
    local seen = {}
    local function add(r)
        if seen[r] then return end
        seen[r] = true
        local rec = self.dir.realms[r] or {}
        local metric = self.bb:metricTo(r)
        out[#out + 1] = {
            realm = r, serverId = rec.serverId, main = rec.main or (r == self.mainRealm), prog = rec.prog,
            lastSeen = rec.lastSeen, reachable = metric < backbone.INF, metric = metric,
        }
    end
    add(self.realm)
    for r in pairs(self.dir.realms) do add(r) end
    for r in pairs(self.bb.routes) do add(r) end
    table.sort(out, function(x, y) return x.realm < y.realm end)
    return out
end

function Server:addBridge(bcfg)
    return self.bb:addBridge(bcfg, false)
end

function Server:removeBridge(peer)
    return self.bb:removeBridge(peer)
end

function Server:bridges()
    return self.bb:bridges()
end

function Server:userHome(name)
    return self.dir:userHome(name)
end

function Server:claimUser(name)
    return self.dir:claim(name)
end

function Server:releaseUser(name)
    return self.dir:release(name)
end

function Server:renameUser(old, new)
    return self.dir:rename(old, new)
end

function Server:listUsers()
    return self.dir:list()
end

function Server:broadcastRealms(port, body)
    return self.node:send("*", port, body)
end

return M
