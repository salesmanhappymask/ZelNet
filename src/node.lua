local need = ...
local compat = need("compat")
local util = need("util")
local crypto = need("crypto")
local frame = need("frame")
local seal = need("seal")
local links = need("links")
local config = need("config")
local version = need("version")

local M = {}

local Node = {}
Node.__index = Node

M.MAX_HANDLERS = 24
M.INBOX_MAX = 64
M.OUTQ_MAX = 64

function M.new(cfg, opts)
    opts = opts or {}
    local self = setmetatable({}, Node)
    self.cfg = cfg
    self.log = opts.log or util.newLogger(200)
    self.role = cfg.role
    self.isServer = config.isServer(cfg)
    self.myId = os.getComputerID()
    self.realm = cfg.realm
    self.name = cfg.name
    self.address = self.isServer and cfg.realm or (cfg.realm .. ":" .. self.myId)
    self.links = links.new({
        channel = cfg.channel, netId = cfg.netId, myId = self.myId, log = self.log,
        useWired = cfg.useWired, useBitnet = cfg.useBitnet,
    })
    self.inq = util.newQueue()
    self.outq = util.newQueue()
    self.waitq = util.newQueue()
    self.tasks = {}
    self.starting = {}
    self.handlerCount = 0
    self.ports = {}
    self.inboxes = {}
    self.pending = {}
    self.seen = util.newSeenSet(900, 6000)
    self.fwdSeen = util.newSeenSet(300, 6000)
    self.timers = {}
    self.frameHandlers = {}
    self.cands = {}
    self.parent = nil
    self.lastBeaconSeq = -1
    self.rebroadcastSeq = -1
    self.beaconMacCache = {}
    self.connected = false
    self.serverId = cfg.authority and cfg.authority.id or nil
    self.downRoutes = {}
    self.subs = {}
    self.pubTimes = {}
    self.names = {}
    self.listeners = {}
    self.counters = { sent = 0, delivered = 0, forwarded = 0, dropped = 0, badMac = 0, beacons = 0 }
    self.wakePending = false
    self.running = false
    self.started = compat.now()
    return self
end

function Node:emit(event, ...)
    for _, fn in ipairs(self.listeners[event] or {}) do
        local ok, err = pcall(fn, ...)
        if not ok then self.log.warn("listener " .. event .. ": " .. tostring(err)) end
    end
end

function Node:on(event, fn)
    self.listeners[event] = self.listeners[event] or {}
    table.insert(self.listeners[event], fn)
end

function Node:count(key, n)
    self.counters[key] = (self.counters[key] or 0) + (n or 1)
end

function Node:wake()
    if not self.wakePending then
        self.wakePending = true
        os.queueEvent("zn_work")
    end
end

function Node:spawn(fn, name, opts)
    opts = opts or {}
    local task = { co = coroutine.create(fn), name = name or "task", critical = opts.critical, main = opts.main, handler = opts.handler }
    if task.handler then self.handlerCount = self.handlerCount + 1 end
    self.starting[#self.starting + 1] = task
    if self.running then os.queueEvent("zn_spawn") end
    return task
end

function Node:resumeTask(task, ...)
    local ok, filter = coroutine.resume(task.co, ...)
    if not ok then
        task.dead = true
        if task.critical or task.main then
            task.error = filter
            return false, filter
        end
        self.log.error((task.name or "task") .. ": " .. tostring(filter))
        return true
    end
    if coroutine.status(task.co) == "dead" then
        task.dead = true
        return true
    end
    task.filter = filter
    return true
end

function Node:runScheduler()
    local event = {}
    while true do
        while #self.starting > 0 do
            local list = self.starting
            self.starting = {}
            for _, task in ipairs(list) do
                self.tasks[#self.tasks + 1] = task
                local ok, err = self:resumeTask(task)
                if not ok then error(err, 0) end
                if task.dead and task.main then return task end
            end
        end
        local alive = {}
        for _, task in ipairs(self.tasks) do
            if not task.dead then
                if task.filter == nil or task.filter == event[1] or event[1] == "terminate" then
                    if event[1] ~= nil then
                        local ok, err = self:resumeTask(task, compat.unpack(event))
                        if not ok then error(err, 0) end
                    end
                end
            end
            if task.dead then
                if task.handler then self.handlerCount = self.handlerCount - 1 end
                if task.main then return task end
            else
                alive[#alive + 1] = task
            end
        end
        self.tasks = alive
        if #self.starting == 0 then
            event = { os.pullEventRaw() }
        else
            event = {}
        end
    end
end

function Node:every(seconds, fn, name)
    local t = { interval = seconds, next = compat.now() + seconds, fn = fn, name = name or "timer" }
    self.timers[#self.timers + 1] = t
    return t
end

function Node:after(seconds, fn, name)
    local t = { interval = nil, next = compat.now() + seconds, fn = fn, name = name or "once" }
    self.timers[#self.timers + 1] = t
    return t
end

function Node:runTimers()
    local now = compat.now()
    local keep = {}
    for _, t in ipairs(self.timers) do
        if now >= t.next then
            local ok, err = pcall(t.fn, self)
            if not ok then self.log.error("timer " .. t.name .. ": " .. tostring(err)) end
            if t.interval then
                t.next = now + t.interval
                keep[#keep + 1] = t
            end
        else
            keep[#keep + 1] = t
        end
    end
    self.timers = keep
end

function Node:rxTask()
    while true do
        local ev, a, b, c, d, e = os.pullEventRaw()
        if ev == "terminate" then error("Terminated", 0) end
        if ev == "modem_message" or ev == "bitnet_message" then
            local f, linkId, dist = self.links:decode(ev, a, b, c, d, e)
            if f then
                if self.inq.size() < 400 then
                    self.inq.push({ f = f, link = linkId, dist = dist })
                    self:wake()
                else
                    self:count("dropped")
                end
            end
        elseif ev == "peripheral" or ev == "peripheral_detach" then
            self.inq.push({ rescan = true })
            self:wake()
        end
    end
end

function Node:clockTask()
    local timer = os.startTimer(1)
    while true do
        local ev, id = os.pullEvent("timer")
        if id == timer then
            timer = os.startTimer(1)
            self.inq.push({ tick = true })
            self:wake()
        end
    end
end

function Node:workerTask()
    while true do
        local did = 0
        while true do
            local item = self.inq.pop()
            if not item then break end
            local ok, err = pcall(self.processItem, self, item)
            if not ok then self.log.error("worker: " .. tostring(err)) end
            did = did + 1
            if did % 8 == 0 then compat.yieldNow() end
        end
        while true do
            local pkt = self.outq.pop()
            if not pkt then break end
            local ok, err = pcall(self.transmitPacket, self, pkt)
            if not ok then self.log.error("send: " .. tostring(err)) end
            did = did + 1
            if did % 8 == 0 then compat.yieldNow() end
        end
        self.wakePending = false
        if self.inq.size() == 0 and self.outq.size() == 0 then
            os.pullEvent("zn_work")
        end
    end
end

function Node:processItem(item)
    if item.tick then
        self:runTimers()
        return
    end
    if item.rescan then
        self.links:scan()
        return
    end
    if item.deliver then
        self:deliver(item.deliver)
        return
    end
    local f = item.f
    local handler = self.frameHandlers[f.k]
    if handler then
        handler(self, f, item.link, item.dist)
        return
    end
    if self.isServer then return end
    if f.k == "b" then
        self:onBeacon(f, item.link)
    elseif f.k == "p" then
        self:onAccessFrame(f, item.link)
    end
end

function Node:onFrame(kind, fn)
    self.frameHandlers[kind] = fn
end

function Node:setRouter(fn)
    self.router = fn
end

local function linkPenalty(linkId)
    if type(linkId) == "string" and linkId:sub(1, 7) == "bitnet:" then return 0.5 end
    return 0
end

function Node:verifyBeacon(d)
    local key = tostring(d.root) .. ":" .. tostring(d.seq)
    local cached = self.beaconMacCache[key]
    if cached then return crypto.constEq(cached, d.mac) end
    local expect = seal.beaconMac(self.cfg.realmKey, d)
    self.beaconMacCache[key] = expect
    local n = 0
    for _ in pairs(self.beaconMacCache) do n = n + 1 end
    if n > 64 then self.beaconMacCache = { [key] = expect } end
    return crypto.constEq(expect, d.mac)
end

function Node:choosePair()
    local now = compat.now()
    local window = (self.cfg.beaconInterval or 10) * 2.6
    local maxSeq = -1
    for id, c in pairs(self.cands) do
        if now - c.t > window then
            self.cands[id] = nil
        elseif c.seq > maxSeq then
            maxSeq = c.seq
        end
    end
    local best
    for id, c in pairs(self.cands) do
        if c.seq >= maxSeq - 1 then
            local score = c.hops + linkPenalty(c.link) + (c.seq < maxSeq and 0.25 or 0)
            if not best or score < best.score or (score == best.score and id < best.id) then
                best = { id = id, score = score, c = c }
            end
        end
    end
    return best
end

function Node:setParent(best)
    local old = self.parent
    if not best then
        if old then
            self.parent = nil
            self.connected = false
            self.log.warn("lost parent " .. tostring(old.id))
            self:emit("disconnected")
        end
        return
    end
    local c = best.c
    self.parent = { id = best.id, hops = c.hops, seq = c.seq, link = c.link, root = c.root, t = c.t }
    self.serverId = c.root
    if not old or old.id ~= best.id then
        self.log.info("parent " .. best.id .. " (" .. (c.hops + 1) .. " hops)")
        self:sendHello()
    end
end

function Node:onBeacon(f, linkId)
    local d = f.d
    if not frame.validBeacon(d) or d.realm ~= self.realm then return end
    if not self:verifyBeacon(d) then
        self:count("badMac")
        return
    end
    self:count("beacons")
    if self.lastBeaconSeq >= 0 and d.seq < self.lastBeaconSeq - 5000 and self.parent then return end
    if d.seq > self.lastBeaconSeq or not self.parent then self.lastBeaconSeq = d.seq end
    self.cands[f.f] = { hops = d.hops, seq = d.seq, link = linkId, root = d.root, t = compat.now() }
    local best = self:choosePair()
    self:setParent(best)
    if self.role == "router" and self.parent and d.seq > self.rebroadcastSeq then
        self.rebroadcastSeq = d.seq
        local out = { realm = d.realm, root = d.root, seq = d.seq, hops = self.parent.hops + 1, ver = d.ver, prog = d.prog, mac = d.mac }
        self.links:broadcast(frame.make(self.cfg.netId, "b", self.myId, nil, out))
    end
end

local function cidOf(addr)
    if type(addr) ~= "string" then return nil end
    return tonumber(addr:match(":(%d+)$"))
end

function Node:isForMe(dst)
    if dst == self.address then return true end
    if dst == self.realm .. ":" .. tostring(self.myId) then return true end
    if self.name and dst == self.realm .. ":" .. self.name then return true end
    for name in pairs(self.names) do
        if dst == self.realm .. ":" .. name then return true end
    end
    return false
end

function Node:onAccessFrame(f, linkId)
    local w = f.d
    if not frame.validAccess(w) then return end
    if w.dir == "d" and self:isForMe(w.dst) and w.dev == self.name then
        local pkt, err = seal.openAccess(self.cfg.deviceKey, w)
        if not pkt then
            self:count("badMac")
            self.log.debug("rejected packet: " .. tostring(err))
            return
        end
        self:deliver(pkt)
        return
    end
    if self.role ~= "router" then return end
    if w.ttl <= 1 then
        self:count("dropped")
        return
    end
    if w.dir == "u" then
        if f.t ~= self.myId or not self.parent then return end
        if self.fwdSeen.check("u" .. w.id) then return end
        local src = cidOf(w.src)
        if src then self.downRoutes[src] = { via = f.f, t = compat.now() } end
        w.ttl = w.ttl - 1
        self.links:sendTo(self.parent.id, frame.make(self.cfg.netId, "p", self.myId, self.parent.id, w))
        self:count("forwarded")
    else
        if f.t ~= nil and f.t ~= self.myId then return end
        if self.fwdSeen.check("d" .. w.id) then return end
        w.ttl = w.ttl - 1
        local dst = cidOf(w.dst)
        local route = dst and self.downRoutes[dst]
        if route and compat.now() - route.t < 600 then
            self.links:sendTo(route.via, frame.make(self.cfg.netId, "p", self.myId, route.via, w))
        else
            self.links:broadcast(frame.make(self.cfg.netId, "p", self.myId, nil, w))
        end
        self:count("forwarded")
    end
end

function Node:newPacket(dst, port, body, opts)
    opts = opts or {}
    return {
        v = version.protocol, id = util.newId(), src = opts.src or self.address, dst = dst, port = port,
        ttl = opts.ttl or 24, rq = opts.rq and true or nil, re = opts.re, body = body,
    }
end

function Node:send(dst, port, body, opts)
    local ndst = (dst == "*") and "*" or util.normAddress(dst)
    if not ndst then return nil, "bad address" end
    if not util.validPort(port) then return nil, "bad port" end
    local pkt = self:newPacket(ndst, port, body, opts)
    self.outq.push(pkt)
    self:count("sent")
    self:wake()
    return pkt.id
end

function Node:transmitPacket(pkt)
    if self:isForMe(pkt.dst) or (self.isServer and pkt.dst == self.realm) then
        self:deliver(pkt)
        return
    end
    if self.isServer then
        if self.router then self.router(pkt) end
        return
    end
    if not self.parent then
        if self.waitq.size() < M.OUTQ_MAX then
            pkt.queued = compat.now()
            self.waitq.push(pkt)
        else
            self:count("dropped")
        end
        return
    end
    local w, err = seal.sealAccess(self.cfg.deviceKey, pkt, "u", self.name)
    if not w then
        self:failPending(pkt.id, err or "seal failed")
        return
    end
    self.links:sendTo(self.parent.id, frame.make(self.cfg.netId, "p", self.myId, self.parent.id, w))
end

function Node:flushWaiting()
    local now = compat.now()
    local n = self.waitq.size()
    for _ = 1, n do
        local pkt = self.waitq.pop()
        if not pkt then break end
        if now - (pkt.queued or now) < 30 then
            self.outq.push(pkt)
        else
            self:failPending(pkt.id, "no_route")
        end
    end
    self:wake()
end

function Node:failPending(id, err)
    local p = self.pending[id]
    if not p then return end
    self.pending[id] = nil
    p.done, p.err = true, err
    if p.cb then
        pcall(p.cb, nil, err)
    else
        os.queueEvent("zn_reply", id)
    end
end

function Node:deliver(pkt)
    if self.seen.check("p" .. pkt.id) then return end
    self:count("delivered")
    if pkt.re and self.pending[pkt.re] and pkt.port ~= "zn.err" then
        local p = self.pending[pkt.re]
        self.pending[pkt.re] = nil
        p.done, p.body, p.src = true, pkt.body, pkt.src
        if p.cb then
            local ok, err = pcall(p.cb, pkt.body, nil, pkt.src)
            if not ok then self.log.error("reply callback: " .. tostring(err)) end
        else
            os.queueEvent("zn_reply", pkt.re)
        end
        return
    end
    if pkt.port == "zn.err" then
        local ref = type(pkt.body) == "table" and pkt.body.ref or pkt.re
        if ref and self.pending[ref] then
            local code = type(pkt.body) == "table" and pkt.body.code or "error"
            self:failPending(ref, code)
        end
        return
    end
    if pkt.port == "zn.ping" then
        if pkt.rq then self:send(pkt.src, "zn.ping", pkt.body, { re = pkt.id }) end
        return
    end
    if pkt.port == "zn.ps" and type(pkt.body) == "table" and pkt.body.op == "msg" then
        self:deliverTopic(pkt)
        return
    end
    local msg = { src = pkt.src, port = pkt.port, data = pkt.body, id = pkt.id, rq = pkt.rq }
    self:dispatch(pkt.port, msg)
end

function Node:dispatch(port, msg)
    local p = self.ports[port]
    if p and p.handler then
        if self.handlerCount >= M.MAX_HANDLERS then
            self:count("dropped")
            return
        end
        local fn = p.handler
        self:spawn(function() fn(msg) end, "port:" .. port, { handler = true })
        return
    end
    local box = self.inboxes[port]
    if not box then
        box = util.newQueue()
        self.inboxes[port] = box
    end
    if box.size() >= M.INBOX_MAX then box.pop() end
    box.push(msg)
    os.queueEvent("zn_msg", port)
end

function Node:deliverTopic(pkt)
    local b = pkt.body
    if not util.validTopic(b.topic) then return end
    local delivered = false
    for pattern, sub in pairs(self.subs) do
        if util.topicMatches(pattern, b.topic) then
            delivered = true
            if sub.handler then
                if self.handlerCount < M.MAX_HANDLERS then
                    local fn = sub.handler
                    self:spawn(function() fn(b.topic, b.data, b.from or pkt.src) end, "topic:" .. pattern, { handler = true })
                end
            end
        end
    end
    local wantsInbox = false
    for pattern, sub in pairs(self.subs) do
        if util.topicMatches(pattern, b.topic) and not sub.handler then wantsInbox = true end
    end
    if wantsInbox or not delivered then
        self:dispatch("zn.ps", { src = b.from or pkt.src, port = "zn.ps", data = { topic = b.topic, data = b.data }, id = pkt.id })
    end
end

function Node:request(dst, port, body, timeout, opts)
    opts = opts or {}
    local tries = opts.retries
    if tries == nil then
        local a = util.parseAddress(dst)
        tries = (a and a.realm == self.realm) and 1 or 0
    end
    if timeout == nil then
        local a = util.parseAddress(dst)
        timeout = (a and a.realm ~= self.realm) and 40 or 10
    end
    local ndst = util.normAddress(dst)
    if not ndst then return nil, "bad address" end
    if not util.validPort(port) then return nil, "bad port" end
    local lastErr = "timeout"
    for _ = 0, tries do
        local pkt = self:newPacket(ndst, port, body, { rq = true })
        local p = {}
        self.pending[pkt.id] = p
        self.outq.push(pkt)
        self:count("sent")
        self:wake()
        local timer = os.startTimer(timeout)
        while not p.done do
            local ev, a = os.pullEvent()
            if ev == "zn_reply" and a == pkt.id then
                break
            elseif ev == "timer" and a == timer then
                break
            end
        end
        if p.done then
            if p.err then
                if p.err ~= "timeout" then return nil, p.err end
                lastErr = p.err
            else
                return p.body, p.src
            end
        else
            self.pending[pkt.id] = nil
        end
    end
    return nil, lastErr
end

function Node:requestAsync(dst, port, body, cb, timeout)
    local pkt = self:newPacket(util.normAddress(dst) or dst, port, body, { rq = true })
    local p = { cb = cb }
    self.pending[pkt.id] = p
    self.outq.push(pkt)
    self:wake()
    self:after(timeout or 15, function()
        if self.pending[pkt.id] == p then self:failPending(pkt.id, "timeout") end
    end, "req-timeout")
    return pkt.id
end

function Node:reply(msg, body)
    if not msg or not msg.id then return nil, "bad message" end
    return self:send(msg.src, msg.port, body, { re = msg.id })
end

function Node:listen(port, handler)
    self.ports[port] = { handler = handler }
end

function Node:unlisten(port)
    self.ports[port] = nil
end

function Node:receive(port, timeout)
    local box = self.inboxes[port]
    if box and box.size() > 0 then return box.pop() end
    local timer = timeout and os.startTimer(timeout)
    while true do
        local ev, a = os.pullEvent()
        if ev == "zn_msg" and a == port then
            box = self.inboxes[port]
            if box and box.size() > 0 then return box.pop() end
        elseif ev == "timer" and timer and a == timer then
            return nil
        end
    end
end

function Node:sendHello()
    if self.isServer then return end
    local body = { name = self.name, role = self.role, prog = version.program, cid = self.myId, hops = self.parent and (self.parent.hops + 1) or nil }
    self:requestAsync(self.realm, "zn.hello", body, function(reply, err)
        if reply and reply.ok then
            local was = self.connected
            self.connected = true
            self.serverProg = reply.prog
            self.lastHelloOk = compat.now()
            if not was then
                self.log.info("connected to " .. self.realm)
                self:flushWaiting()
                self:resubscribe()
                self:emit("connected")
            end
        elseif reply and reply.err then
            self.log.warn("server refused hello: " .. tostring(reply.err))
        end
    end, 20)
end

function Node:resubscribe()
    for pattern in pairs(self.subs) do
        self:send(self.realm, "zn.ps", { op = "sub", topic = pattern })
    end
    for name in pairs(self.names) do
        self:send(self.realm, "zn.name", { op = "register", name = name })
    end
end

function Node:subscribe(topic, handler)
    if not util.validTopic(topic) then return nil, "bad topic" end
    self.subs[topic] = { handler = handler, t = compat.now() }
    if self.isServer then
        if self.localSubscribe then self.localSubscribe(topic) end
    else
        self:send(self.realm, "zn.ps", { op = "sub", topic = topic })
    end
    return true
end

function Node:unsubscribe(topic)
    self.subs[topic] = nil
    if self.isServer then
        if self.localUnsubscribe then self.localUnsubscribe(topic) end
    else
        self:send(self.realm, "zn.ps", { op = "unsub", topic = topic })
    end
end

function Node:publish(topic, data, opts)
    if not util.validTopic(topic) or topic:find("%*") then return nil, "bad topic" end
    local now = compat.now()
    local last = self.pubTimes[topic]
    if last and now - last < 1 then return nil, "rate_limited" end
    self.pubTimes[topic] = now
    local body = { op = "pub", topic = topic, data = data, retain = opts and opts.retain or nil }
    self:send(self.realm, "zn.ps", body)
    return true
end

function Node:register(name)
    local n = util.normName(name)
    if not n then return nil, "bad name" end
    local reply, err = self:request(self.realm, "zn.name", { op = "register", name = n })
    if not reply then return nil, err end
    if not reply.ok then return nil, reply.err or "refused" end
    self.names[n] = true
    return true
end

function Node:resolve(addr)
    local a = util.parseAddress(addr)
    if not a then return nil, "bad address" end
    if not a.name then return util.normAddress(addr) end
    local reply, err = self:request(a.realm, "zn.name", { op = "resolve", name = a.name })
    if not reply then return nil, err end
    if not reply.ok then return nil, reply.err or "unknown_node" end
    return reply.addr
end

function Node:ping(dst, timeout)
    local t0 = compat.now()
    local reply, err = self:request(dst, "zn.ping", { t = t0 }, timeout or 15, { retries = 0 })
    if not reply then return nil, err end
    return compat.now() - t0
end

function Node:isConnected()
    if self.isServer then return true end
    return self.connected and self.parent ~= nil
end

function Node:status()
    local linksList = {}
    for _, l in ipairs(self.links:list()) do
        linksList[#linksList + 1] = { id = l.id, kind = l.kind, wireless = l.wireless, open = l.open, tx = l.tx, rx = l.rx }
    end
    return {
        address = self.address, role = self.role, realm = self.realm, name = self.name,
        parent = self.parent and self.parent.id or nil, hops = self.parent and (self.parent.hops + 1) or (self.isServer and 0 or nil),
        connected = self:isConnected(), links = linksList, counters = util.copy(self.counters),
        uptime = compat.now() - self.started, serverId = self.serverId, prog = version.program,
    }
end

function Node:deviceTimers()
    local beacon = self.cfg.beaconInterval or 10
    self:every(beacon, function()
        local best = self:choosePair()
        self:setParent(best)
    end, "parent-check")
    self:every(self.cfg.keepalive or 120, function()
        if self.parent then self:sendHello() end
    end, "keepalive")
    self:every(240, function()
        if self.connected then self:resubscribe() end
    end, "renew")
    self:every(5, function()
        if self.parent and self.waitq.size() > 0 and self.connected then self:flushWaiting() end
        local now = compat.now()
        for cid, r in pairs(self.downRoutes) do
            if now - r.t > 600 then self.downRoutes[cid] = nil end
        end
    end, "housekeeping")
end

function Node:start()
    if self.startedLinks then return true end
    self.links:scan()
    if self.links:count() == 0 then
        self.log.warn("no modem or BitNet link found")
    end
    if not self.isServer then self:deviceTimers() end
    self.startedLinks = true
    return true
end

function Node:loop(mainFn, ...)
    self:start()
    self.running = true
    self:spawn(function() self:rxTask() end, "rx", { critical = true })
    self:spawn(function() self:workerTask() end, "worker", { critical = true })
    self:spawn(function() self:clockTask() end, "clock", { critical = true })
    local result
    if mainFn then
        local args = { ... }
        self:spawn(function() result = { mainFn(compat.unpack(args)) } end, "main", { main = true })
    end
    local ok, finished = pcall(self.runScheduler, self)
    self.running = false
    if not ok then error(finished, 0) end
    if finished and finished.error then error(finished.error, 0) end
    if result then return compat.unpack(result) end
end

function Node:close()
    self.links:closeAll()
end

return M
