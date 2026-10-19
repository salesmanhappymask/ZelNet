local need = ...
local compat = need("compat")
local util = need("util")
local crypto = need("crypto")
local frame = need("frame")
local seal = need("seal")
local cipherMod = need("cipher")
local config = need("config")
local version = need("version")

local M = {}

M.INF = 16
M.RADIO_METRIC = 1
M.BRIDGE_METRIC = 4
M.QUEUE_MAX = 200
M.QUEUE_TTL = 3600
M.RETRY_INTERVAL = 10
M.NONCE_TTL = 1800
M.MAX_REALMS = 64
M.MAX_BATCH = 500

local Backbone = {}
Backbone.__index = Backbone

local function isBridgeLink(linkId)
    return type(linkId) == "string" and linkId:sub(1, 7) == "bridge:"
end

function M.new(ctx, srv)
    local self = setmetatable({}, Backbone)
    self.ctx = ctx
    self.srv = srv
    self.node = ctx.node
    self.cfg = ctx.cfg
    self.log = ctx.log or ctx.node.log
    self.realm = ctx.cfg.realm
    self.myId = ctx.node.myId
    self.key = ctx.cfg.backboneKey
    self.cipher = ctx.cipher
    self.isMain = ctx.cfg.role == "main"
    self.neighbors = {}
    self.radioById = {}
    self.routes = {}
    self.queue = {}
    self.nonces = util.newSeenSet(M.NONCE_TTL, 20000)
    self.floodSeen = util.newSeenSet(M.NONCE_TTL, 20000)
    self.fwdSeen = util.newSeenSet(300, 6000)
    self.helloSeq = 0
    self.advSeq = 0
    self.bridgeSet = {}
    self.bridgeModule = nil
    self.enabled = false
    self.fp = nil
    self.advertDue = false
    self.recomputeDue = false
    self.lastAdvert = -100
    self.counters = {
        rx = 0, tx = 0, forwarded = 0, delivered = 0, flooded = 0, queued = 0, expired = 0,
        badMac = 0, replays = 0, hellos = 0, adverts = 0, dropped = 0,
    }
    return self
end

function Backbone:helloInterval()
    return tonumber(self.cfg.helloInterval) or 20
end

function Backbone:routeInterval()
    return tonumber(self.cfg.routeInterval) or 30
end

function Backbone:warn(text)
    if self.srv and self.srv.warn then
        self.srv:warn(text)
    else
        self.log.warn(text)
    end
end

function Backbone:count(key, n)
    self.counters[key] = (self.counters[key] or 0) + (n or 1)
end

function Backbone:checkCipher()
    local c = self.cipher
    if not c then
        self.enabled = false
        self:warn("no cipher block: backbone disabled")
        return false
    end
    if c.kind == "software" and not self.cfg.allowSoftwareBackbone then
        self.enabled = false
        self:warn("software cipher not allowed: backbone disabled")
        return false
    end
    local ok, fp = pcall(cipherMod.fingerprint, c)
    if not ok or type(fp) ~= "string" then
        self.enabled = false
        self:warn("cipher block not responding: backbone disabled")
        return false
    end
    if self.fp and self.fp ~= fp then
        self:warn("cipher items changed on this server")
        for _, nb in pairs(self.neighbors) do nb.up = false end
        self:recompute()
    end
    self.fp = fp
    if c.kind == "software" then self:warn("using software backbone cipher") end
    self.enabled = true
    return true
end

function Backbone:start()
    local n = self.node
    self:checkCipher()
    n:onFrame("h", function(_, f, linkId) self:onHello(f, linkId) end)
    n:onFrame("x", function(_, f, linkId) self:onFrame(f, linkId) end)
    n:after(0.5, function() self:sendHellos() end, "bb-hello-first")
    n:every(self:helloInterval(), function() self:sendHellos() end, "bb-hello")
    n:every(self:routeInterval(), function() self:advertise() end, "bb-advert")
    n:every(1, function() self:tick() end, "bb-tick")
    n:every(5, function() self:maintain() end, "bb-maintain")
    n:every(M.RETRY_INTERVAL, function() self:retryQueue() end, "bb-retry")
    n:every(120, function() self:checkCipher() end, "bb-cipher")
    for _, bcfg in ipairs(self.cfg.bridges or {}) do
        local ok, err = self:addBridge(bcfg, true)
        if not ok then self:warn("bridge " .. tostring(bcfg.peer) .. ": " .. tostring(err)) end
    end
end

function Backbone:nextSeq(prev)
    local s = math.floor(compat.stamp() * 100)
    if s <= prev then s = prev + 1 end
    return s
end

function Backbone:helloData()
    self.helloSeq = self:nextSeq(self.helloSeq)
    local d = {
        realm = self.realm, id = self.myId, main = self.isMain, ver = version.protocol,
        prog = version.program, seq = self.helloSeq, fp = self.fp,
    }
    d.mac = seal.helloMac(self.key, d)
    return d
end

function Backbone:sendHellos()
    if not self.enabled then return end
    local d = self:helloData()
    self.node.links:broadcast(frame.make(self.cfg.netId, "h", self.myId, nil, d))
end

function Backbone:sendBridgeHellos()
    if not self.enabled then return end
    for _, entry in pairs(self.bridgeSet) do
        if not entry.removed then
            local ok, err = pcall(entry.obj.enqueue, entry.obj, { hello = self:helloData() })
            if not ok then self.log.debug("bridge hello: " .. tostring(err)) end
        end
    end
end

function Backbone:onHello(f, linkId)
    if not self.enabled then return end
    local d = f.d
    if not frame.validHello(d) then return end
    local viaBridge = isBridgeLink(linkId)
    if d.realm == self.realm then
        if d.id ~= self.myId then self:warn("another server (#" .. tostring(d.id) .. ") uses realm " .. self.realm) end
        return
    end
    if not util.normRealm(d.realm) or util.normRealm(d.realm) ~= d.realm then return end
    if not crypto.constEq(seal.helloMac(self.key, d), d.mac) then
        self:count("badMac")
        return
    end
    if not viaBridge and d.id ~= f.f then return end
    local key
    if viaBridge then
        key = linkId
    else
        key = "radio:" .. d.realm
    end
    local now = compat.now()
    local nb = self.neighbors[key]
    if viaBridge and not nb then return end
    if nb and type(nb.seq) == "number" and d.seq <= nb.seq and (nb.up or now - (nb.lastSeen or 0) < 600) then return end
    if not nb then
        nb = { key = key, realm = d.realm, kind = "radio", metric = M.RADIO_METRIC, up = false }
        self.neighbors[key] = nb
    end
    if viaBridge and nb.realm ~= d.realm then
        self:warn("bridge " .. tostring(nb.bridge) .. " reaches realm " .. d.realm)
        nb.realm = d.realm
    end
    if not viaBridge then
        if nb.id and nb.id ~= d.id then self.radioById[nb.id] = nil end
        self.radioById[d.id] = key
        nb.link = linkId
    end
    nb.id = d.id
    nb.lastSeen = now
    nb.seenStamp = compat.stamp()
    nb.seq = d.seq
    nb.fp = d.fp
    nb.prog = type(d.prog) == "string" and util.sanitize(d.prog):sub(1, 16) or nil
    nb.main = d.main == true
    nb.ver = d.ver
    self:count("hellos")
    local problem
    if d.ver ~= version.protocol then
        problem = "protocol " .. tostring(d.ver)
        self:warn("realm " .. d.realm .. " speaks protocol " .. tostring(d.ver))
    elseif d.fp ~= self.fp then
        problem = "cipher items differ"
        self:warn("cipher items differ with " .. d.realm)
    end
    nb.problem = problem
    local wasUp = nb.up
    nb.up = problem == nil
    if nb.up and not wasUp then
        self.log.info("backbone neighbor up: " .. d.realm .. " (" .. nb.kind .. ")")
        self.advertDue = true
        self:recompute()
    elseif wasUp and not nb.up then
        nb.adv = nil
        self:recompute()
    end
end

function Backbone:neighborKey(f, linkId)
    if isBridgeLink(linkId) then return linkId end
    return self.radioById[f.f]
end

function Backbone:onFrame(f, linkId)
    if not self.enabled then return end
    local w = f.d
    if not frame.validBackbone(w) or w.v ~= version.protocol then
        self:count("dropped")
        return
    end
    self:count("rx")
    local fromKey = self:neighborKey(f, linkId)
    local nb = fromKey and self.neighbors[fromKey]
    if nb and nb.kind == "bridge" then nb.lastSeen = compat.now() end
    if w.dst == "*" then
        self:onFlood(w, fromKey)
        return
    end
    local a = util.parseAddress(w.dst)
    if not a or a.realm == "*" then
        self:count("dropped")
        return
    end
    if a.realm == self.realm then
        local pkt, nonce = seal.openBackbone(self.cipher, self.key, w)
        if not pkt then
            self:count("badMac")
            return
        end
        if self.nonces.check(nonce) then
            self:count("replays")
            return
        end
        if pkt.port == "zn.route" then
            self:onAdvert(fromKey, pkt)
            return
        end
        self:count("delivered")
        self.srv:routePacket(pkt, "backbone")
        return
    end
    if self.fwdSeen.has(w.id) then
        self:count("dropped")
        return
    end
    if not seal.verifyBackbone(self.key, w) then
        self:count("badMac")
        return
    end
    self.fwdSeen.check(w.id)
    w.ttl = w.ttl - 1
    if w.ttl <= 0 then
        self:fail(w, "ttl", "ttl expired in " .. self.realm)
        return
    end
    w.via = self.realm
    self:forward(w, fromKey)
end

function Backbone:onFlood(w, fromKey)
    if self.floodSeen.has(w.id) then return end
    local pkt, nonce = seal.openBackbone(self.cipher, self.key, w)
    if not pkt then
        self:count("badMac")
        return
    end
    self.floodSeen.check(w.id)
    if self.nonces.check(nonce) then
        self:count("replays")
        return
    end
    if w.ttl > 1 then
        w.ttl = w.ttl - 1
        w.via = self.realm
        local origin = util.parseAddress(w.src)
        local originRealm = origin and origin.realm
        for key, nb in pairs(self.neighbors) do
            if nb.up and key ~= fromKey and nb.realm ~= originRealm then self:transmit(nb, w) end
        end
    end
    self:count("flooded")
    self.srv:routePacket(pkt, "flood")
end

function Backbone:transmit(nb, w)
    if nb.kind == "bridge" then
        local entry = self.bridgeSet[nb.bridge]
        if not entry or entry.removed then return false end
        local ok, res = pcall(entry.obj.enqueue, entry.obj, w)
        if ok and res then
            self:count("tx")
            return true
        end
        return false
    end
    if not nb.id then return false end
    local sent = self.node.links:sendTo(nb.id, frame.make(self.cfg.netId, "x", self.myId, nb.id, w))
    if sent then self:count("tx") end
    return sent
end

function Backbone:nextHop(realm)
    local r = self.routes[realm]
    if not r or r.metric >= M.INF then return nil end
    local nb = self.neighbors[r.via]
    if not nb or not nb.up then return nil end
    return nb, r
end

function Backbone:forward(w, fromKey)
    local a = util.parseAddress(w.dst)
    local realm = a and a.realm
    local nb = realm and self:nextHop(realm)
    if nb and self:transmit(nb, w) then
        if fromKey then self:count("forwarded") end
        return true
    end
    self:store(w, realm)
    return false
end

function Backbone:mightExist(realm)
    if not realm or realm == "*" then return false end
    if self.routes[realm] then return true end
    local dir = self.srv and self.srv.dir
    if not dir then return true end
    if dir:known(realm) then return true end
    if self.isMain then return false end
    return not dir.synced
end

function Backbone:store(w, realm)
    if not self:mightExist(realm) then
        self:fail(w, "no_route", "unknown realm " .. tostring(realm))
        return
    end
    if #self.queue >= M.QUEUE_MAX then
        local old = table.remove(self.queue, 1)
        self:count("expired")
        self:fail(old.w, "no_route", "store queue full")
    end
    self.queue[#self.queue + 1] = { w = w, t = compat.now(), realm = realm }
    self:count("queued")
end

function Backbone:retryQueue()
    if #self.queue == 0 then return end
    local now = compat.now()
    local keep = {}
    for _, item in ipairs(self.queue) do
        local nb = self:nextHop(item.realm)
        if nb and self:transmit(nb, item.w) then
            self:count("forwarded")
        elseif now - item.t > M.QUEUE_TTL then
            self:count("expired")
            self:fail(item.w, "no_route", "realm " .. tostring(item.realm) .. " unreachable")
        else
            keep[#keep + 1] = item
        end
        compat.breathe()
    end
    self.queue = keep
end

function Backbone:fail(w, code, text)
    if self.srv and self.srv.errorFor then
        self.srv:errorFor({ id = w.id, src = w.src, dst = w.dst, port = w.port }, code, text)
    end
end

function Backbone:sendPacket(pkt)
    if not self.enabled then return nil, "no_route" end
    local w, err = seal.sealBackbone(self.cipher, self.key, pkt, self.realm)
    if not w then return nil, err end
    self:count("tx")
    self:forward(w, nil)
    return true
end

function Backbone:flood(pkt)
    if not self.enabled then return nil, "no_route" end
    local w, err = seal.sealBackbone(self.cipher, self.key, pkt, self.realm)
    if not w then return nil, err end
    self.floodSeen.check(w.id)
    local sent = 0
    for _, nb in pairs(self.neighbors) do
        if nb.up and self:transmit(nb, w) then sent = sent + 1 end
    end
    return true, sent
end

function Backbone:routesFor(key)
    local t = { [self.realm] = 0 }
    for r, rt in pairs(self.routes) do
        if rt.via == key then
            t[r] = M.INF
        else
            t[r] = math.min(rt.metric, M.INF)
        end
    end
    return t
end

function Backbone:sendAdvert(nb)
    self.advSeq = self:nextSeq(self.advSeq)
    local pkt = {
        v = version.protocol, id = util.newId(), src = self.realm, dst = nb.realm, port = "zn.route", ttl = 2,
        body = { seq = self.advSeq, routes = self:routesFor(nb.key) },
    }
    local w = seal.sealBackbone(self.cipher, self.key, pkt, self.realm)
    if w and self:transmit(nb, w) then self:count("adverts") end
end

function Backbone:advertise()
    if not self.enabled then return end
    self.lastAdvert = compat.now()
    self.advertDue = false
    self:sendBridgeHellos()
    for _, nb in pairs(self.neighbors) do
        if nb.up then self:sendAdvert(nb) end
    end
end

function Backbone:tick()
    if self.recomputeDue then
        self.recomputeDue = false
        self:recompute()
    end
    if self.advertDue and compat.now() - self.lastAdvert >= 2 then self:advertise() end
end

function Backbone:onAdvert(fromKey, pkt)
    local nb = fromKey and self.neighbors[fromKey]
    if not nb or not nb.up then return end
    local a = util.parseAddress(pkt.src)
    if not a or a.realm ~= nb.realm or a.id or a.name then return end
    local b = pkt.body
    if type(b) ~= "table" or type(b.routes) ~= "table" then return end
    local now = compat.now()
    local seq = tonumber(b.seq)
    if seq and nb.advSeq and seq < nb.advSeq and now - (nb.advAt or 0) < self:routeInterval() * 3 then return end
    local clean, n = {}, 0
    for r, m in pairs(b.routes) do
        if n >= M.MAX_REALMS then break end
        if type(r) == "string" and util.normRealm(r) == r and type(m) == "number" and m == m then
            clean[r] = util.clamp(math.floor(m), 0, M.INF)
            n = n + 1
        end
    end
    nb.adv = clean
    nb.advAt = now
    nb.advSeq = seq
    nb.lastSeen = now
    self:recompute()
end

function Backbone:consider(best, realm, metric, key)
    if metric >= M.INF then return end
    local cur = best[realm]
    if cur then
        if metric > cur.metric then return end
        if metric == cur.metric then
            local old = self.routes[realm]
            local oldVia = old and old.metric < M.INF and old.via or nil
            if cur.via == oldVia then return end
            if key ~= oldVia and key > cur.via then return end
        end
    end
    best[realm] = { metric = metric, via = key }
end

function Backbone:recompute()
    local now = compat.now()
    local best = {}
    for key, nb in pairs(self.neighbors) do
        if nb.up then
            self:consider(best, nb.realm, nb.metric, key)
            for r, m in pairs(nb.adv or {}) do
                if r ~= self.realm then self:consider(best, r, m + nb.metric, key) end
            end
        end
    end
    local old = self.routes
    local new = {}
    local changed, gained = false, false
    local ups, downs = {}, {}
    for r, b in pairs(best) do
        local o = old[r]
        new[r] = { metric = b.metric, via = b.via, kind = self.neighbors[b.via].kind, t = now }
        if not o or o.metric >= M.INF then
            changed, gained = true, true
            ups[#ups + 1] = r
        elseif o.metric ~= b.metric or o.via ~= b.via then
            changed = true
        else
            new[r].t = o.t
        end
    end
    for r, o in pairs(old) do
        if not best[r] then
            if o.metric < M.INF then
                changed = true
                new[r] = { metric = M.INF, via = o.via, kind = o.kind, t = now, dead = now }
                downs[#downs + 1] = r
            else
                new[r] = o
            end
        end
    end
    self.routes = new
    for _, r in ipairs(ups) do
        self.log.info("realm reachable: " .. r)
        self.node:emit("realm_up", r)
    end
    for _, r in ipairs(downs) do
        self.log.warn("realm unreachable: " .. r)
        self.node:emit("realm_down", r)
    end
    if changed then self.advertDue = true end
    if gained then self:retryQueue() end
end

function Backbone:maintain()
    local now = compat.now()
    local hello = self:helloInterval()
    local route = self:routeInterval()
    local changed = false
    for key, nb in pairs(self.neighbors) do
        local limit = nb.kind == "bridge" and math.max(route * 4, 120) or (hello * 3 + 5)
        if nb.up and now - (nb.lastSeen or 0) > limit then
            nb.up = false
            nb.adv = nil
            changed = true
            self.log.warn("backbone neighbor lost: " .. nb.realm .. " (" .. nb.kind .. ")")
        end
        if nb.adv and now - (nb.advAt or 0) > route * 3 + 5 then
            nb.adv = nil
            changed = true
        end
        if not nb.up and nb.kind == "radio" and now - (nb.lastSeen or 0) > 600 then
            self.neighbors[key] = nil
            if nb.id and self.radioById[nb.id] == key then self.radioById[nb.id] = nil end
        end
    end
    if changed then self:recompute() end
    for r, rt in pairs(self.routes) do
        if rt.metric >= M.INF and now - (rt.dead or now) > route * 2 then self.routes[r] = nil end
    end
end

function Backbone:loadBridgeModule()
    if self.bridgeModule then return self.bridgeModule end
    local ok, mod = pcall(need, "bridge")
    if ok and type(mod) == "table" and type(mod.new) == "function" then
        self.bridgeModule = mod
        return mod
    end
    return nil, tostring(mod)
end

function Backbone:saveBridgeConfig()
    local ok, err = pcall(config.save, self.cfg, self.ctx.configPath)
    if not ok then self.log.error("cannot save config: " .. tostring(err)) end
end

function Backbone:addBridge(bcfg, fromConfig)
    if type(bcfg) ~= "table" then return nil, "bad bridge config" end
    local peer = util.normRealm(bcfg.peer)
    if not peer then return nil, "bad peer realm" end
    if peer == self.realm then return nil, "peer is this realm" end
    if self.bridgeSet[peer] then return nil, "bridge exists" end
    local mod, merr = self:loadBridgeModule()
    if not mod then return nil, "bridge module missing: " .. tostring(merr) end
    bcfg.peer = peer
    local ok, obj, oerr = pcall(mod.new, bcfg, self.ctx)
    if not ok or type(obj) ~= "table" then return nil, tostring(ok and oerr or obj) end
    local entry = { peer = peer, obj = obj, cfg = bcfg, restarts = 0 }
    self.bridgeSet[peer] = entry
    local key = "bridge:" .. peer
    self.neighbors[key] = { key = key, realm = peer, kind = "bridge", bridge = peer, metric = M.BRIDGE_METRIC, up = false, link = key }
    local onItems = function(items) self:onBridgeItems(peer, items) end
    entry.task = self.node:spawn(function()
        while not entry.removed do
            local rok, rerr = pcall(obj.run, obj, onItems)
            if entry.removed then break end
            entry.restarts = entry.restarts + 1
            self.log.error("bridge " .. peer .. " stopped: " .. tostring(rok and "returned" or rerr))
            sleep(5)
        end
    end, "bridge:" .. peer)
    if not fromConfig then
        self.cfg.bridges = self.cfg.bridges or {}
        local found = false
        for _, b in ipairs(self.cfg.bridges) do
            if b == bcfg or util.normRealm(b.peer) == peer then found = true end
        end
        if not found then self.cfg.bridges[#self.cfg.bridges + 1] = bcfg end
        self:saveBridgeConfig()
    end
    self.log.info("bridge to " .. peer .. " ready")
    return true
end

function Backbone:onBridgeItems(peer, items)
    local entry = self.bridgeSet[peer]
    if not entry or entry.removed or type(items) ~= "table" then return end
    local link = "bridge:" .. peer
    local inq = self.node.inq
    local n = 0
    for _, item in ipairs(items) do
        if n >= M.MAX_BATCH then break end
        if type(item) == "table" then
            n = n + 1
            if type(item.hello) == "table" then
                inq.push({ f = { zn = 1, net = self.cfg.netId, k = "h", f = -1, d = item.hello }, link = link })
            else
                inq.push({ f = { zn = 1, net = self.cfg.netId, k = "x", f = -1, d = item }, link = link })
            end
        end
    end
    if n > 0 then self.node:wake() end
end

function Backbone:removeBridge(peer)
    local p = util.normRealm(peer)
    local entry = p and self.bridgeSet[p]
    if not entry then return false end
    entry.removed = true
    if type(entry.obj.stop) == "function" then pcall(entry.obj.stop, entry.obj) end
    if entry.task then entry.task.dead = true end
    self.bridgeSet[p] = nil
    self.neighbors["bridge:" .. p] = nil
    local keep = {}
    for _, b in ipairs(self.cfg.bridges or {}) do
        if util.normRealm(b.peer) ~= p then keep[#keep + 1] = b end
    end
    self.cfg.bridges = keep
    self:saveBridgeConfig()
    self.recomputeDue = true
    self.node:wake()
    return true
end

function Backbone:bridges()
    local out = {}
    for _, peer in ipairs(util.sortedKeys(self.bridgeSet)) do out[#out + 1] = self.bridgeSet[peer].obj end
    return out
end

function Backbone:bridgeStatus()
    local out = {}
    for _, peer in ipairs(util.sortedKeys(self.bridgeSet)) do
        local entry = self.bridgeSet[peer]
        local ok, st = pcall(entry.obj.status, entry.obj)
        if ok and type(st) == "table" then
            st.peer = st.peer or peer
            st.restarts = entry.restarts
            local nb = self.neighbors["bridge:" .. peer]
            st.up = nb and nb.up or false
            out[#out + 1] = st
        else
            out[#out + 1] = { peer = peer, state = "fault", lastError = tostring(st), restarts = entry.restarts, up = false }
        end
    end
    return out
end

function Backbone:bridgeQueued()
    local total = 0
    for _, st in ipairs(self:bridgeStatus()) do total = total + (tonumber(st.queued) or 0) end
    return total
end

function Backbone:neighborList()
    local out = {}
    local now = compat.now()
    for _, key in ipairs(util.sortedKeys(self.neighbors)) do
        local nb = self.neighbors[key]
        out[#out + 1] = {
            realm = nb.realm, kind = nb.kind, id = nb.id, link = nb.link, lastSeen = nb.seenStamp,
            age = nb.lastSeen and (now - nb.lastSeen) or nil, fp = nb.fp, prog = nb.prog, up = nb.up,
            main = nb.main, metric = nb.metric, problem = nb.problem,
        }
    end
    return out
end

function Backbone:routeList()
    local out = {}
    for _, r in ipairs(util.sortedKeys(self.routes)) do
        local rt = self.routes[r]
        local nb = self.neighbors[rt.via]
        out[#out + 1] = { realm = r, via = nb and nb.realm or rt.via, metric = rt.metric, kind = rt.kind, link = nb and nb.link or nil }
    end
    return out
end

function Backbone:metricTo(realm)
    if realm == self.realm then return 0 end
    local r = self.routes[realm]
    return r and r.metric or M.INF
end

function Backbone:reachable(realm)
    return self:metricTo(realm) < M.INF
end

function Backbone:queueSize()
    return #self.queue
end

return M
