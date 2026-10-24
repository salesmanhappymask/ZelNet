local need = ...
local compat = need("compat")
local util = need("util")
local codec = need("codec")

local M = {}

M.PROTOCOL = "zelnet"
M.PORT = "pub"
M.CONTROL = "zn.pub"
M.PREFIX = "pub."
M.MAX_DATA = 4096
M.RATE_COUNT = 10
M.RATE_WINDOW = 10
M.SEEN_REPORT = 60
M.MAX_TRACKED = 500
M.INBOX_MAX = 64
M.OPS = { hello = true, ping = true, send = true, publish = true, subscribe = true, unsubscribe = true }
M.ALK_PORT = "zn.alk"
M.ALK_FROM_NODE = { alk_register = true, alk_hello = true, alk_status = true, alk_status_reply = true, alk_log = true, alk_get = true }
M.ALK_MAX = 7000
M.ALK_RATE = 40
M.BROADCAST = 65535

function M.dataSize(data)
    if data == nil then return 0 end
    local ok, text = pcall(codec.encode, data)
    if not ok or type(text) ~= "string" then return nil end
    return #text
end

function M.publicTopic(topic)
    if type(topic) ~= "string" or topic == "" then return nil end
    local full = M.PREFIX .. topic
    if not util.validTopic(full) or full:find("*", 1, true) then return nil end
    return full
end

function M.publicPattern(pattern)
    if type(pattern) ~= "string" or pattern == "" then return nil end
    local full = M.PREFIX .. pattern
    if not util.validTopic(full) then return nil end
    local star = full:find("*", 1, true)
    if star and (star ~= #full or full:sub(-2) ~= ".*") then return nil end
    return full
end

function M.stripTopic(topic)
    if type(topic) ~= "string" or topic:sub(1, #M.PREFIX) ~= M.PREFIX then return nil end
    return topic:sub(#M.PREFIX + 1)
end

function M.toPlain(pkt, isServerAddr)
    local body = pkt.body
    if pkt.port == M.PORT then
        return { type = "message", from = pkt.src, data = body }
    end
    if not isServerAddr then return nil end
    if pkt.port == "zn.ps" and type(body) == "table" and body.op == "msg" then
        local topic = M.stripTopic(body.topic)
        if not topic then return nil end
        return { type = "topic", topic = topic, data = body.data, from = body.from, retained = body.retained or nil }
    end
    if pkt.port == "zn.err" and type(body) == "table" then
        return { type = "error", error = tostring(body.code or "error"), message = body.msg }
    end
    return nil
end

local Gateway = {}
Gateway.__index = Gateway

function M.new(node, opts)
    opts = opts or {}
    local self = setmetatable({}, Gateway)
    self.n = node
    self.realm = node.realm
    self.myId = node.myId or (os.getComputerID and os.getComputerID()) or 0
    self.backend = opts.backend
    self.log = opts.log or node.log
    self.isOff = opts.isOff or function() return false end
    self.relay = opts.relay
    self.rate = {}
    self.alkRate = {}
    self.reported = {}
    self.sides = {}
    self.inbox = {}
    self.stats = { rx = 0, tx = 0, dropped = 0, relayed = 0 }
    self.hostname = "zelnet-" .. tostring(self.realm) .. "-" .. tostring(self.myId)
    return self
end

function Gateway:openModems()
    local rn = rawget(_G, "rednet")
    if type(rn) ~= "table" or type(rn.open) ~= "function" then return false end
    local sides = {}
    for _, l in ipairs(self.n.links:list()) do
        if l.kind == "modem" and l.wireless and l.present ~= false then
            local ok = pcall(rn.open, l.name)
            if ok then sides[#sides + 1] = l.name end
        end
    end
    self.sides = sides
    if #sides == 0 then return false end
    pcall(rn.host, M.PROTOCOL, self.hostname)
    return true
end

function Gateway:transmit(cid, msg, raw)
    cid = tonumber(cid)
    if not cid or #self.sides == 0 then return false end
    self.seq = (self.seq or 0) + 1
    local mid = (self.myId * 7919 + self.seq * 104729 + math.random(0, 65535)) % 2147483646 + 1
    local packet = { nMessageID = mid, nRecipient = cid, message = msg, sProtocol = (not raw) and M.PROTOCOL or nil }
    local sent = false
    for _, side in ipairs(self.sides) do
        if pcall(peripheral.call, side, "transmit", cid, self.myId, packet) then sent = true end
    end
    if sent then self.stats.tx = self.stats.tx + 1 end
    return sent
end

function Gateway:allow(cid)
    local now = compat.now()
    local r = self.rate[cid]
    if not r or now - r.start >= M.RATE_WINDOW then
        if not r and util.count(self.rate) >= M.MAX_TRACKED then self.rate = {} end
        r = { start = now, n = 0 }
        self.rate[cid] = r
    end
    r.n = r.n + 1
    return r.n <= M.RATE_COUNT
end

function Gateway:fail(cid, op, err, text)
    self.stats.dropped = self.stats.dropped + 1
    self:transmit(cid, { type = "error", op = op, error = err, message = text })
end

function Gateway:noteSeen(cid)
    local now = compat.now()
    local last = self.reported[cid]
    if last and now - last < M.SEEN_REPORT then return end
    if not last and util.count(self.reported) >= M.MAX_TRACKED then self.reported = {} end
    self.reported[cid] = now
    self.backend.seen(cid)
end

function Gateway:relayAirlock(cid, msg)
    cid = tonumber(cid)
    if not cid or not self.relay or type(msg) ~= "table" or not M.ALK_FROM_NODE[msg.type] then return end
    local size = M.dataSize(msg)
    if not size or size > M.ALK_MAX then return end
    local now = compat.now()
    local r = self.alkRate[cid]
    if not r or now - r.start >= M.RATE_WINDOW then
        if not r and util.count(self.alkRate) >= M.MAX_TRACKED then self.alkRate = {} end
        r = { start = now, n = 0 }
        self.alkRate[cid] = r
    end
    r.n = r.n + 1
    if r.n > M.ALK_RATE then
        self.stats.dropped = self.stats.dropped + 1
        return
    end
    self.stats.relayed = self.stats.relayed + 1
    self.relay(cid, msg)
end

function Gateway:handle(cid, msg)
    cid = tonumber(cid)
    if not cid or type(msg) ~= "table" then return end
    local op = msg.op
    if type(op) ~= "string" or not M.OPS[op] then
        self:fail(cid, tostring(op), "bad_request", "op must be hello, ping, send, publish, subscribe or unsubscribe")
        return
    end
    if self.isOff() then
        self:fail(cid, op, "off", "the public gateway is switched off")
        return
    end
    if self.backend.blocked(cid) then
        self.stats.dropped = self.stats.dropped + 1
        return
    end
    if not self:allow(cid) then
        self:fail(cid, op, "rate_limited", "at most " .. M.RATE_COUNT .. " messages every " .. M.RATE_WINDOW .. " seconds")
        return
    end
    self.stats.rx = self.stats.rx + 1
    self:noteSeen(cid)
    local from = self.realm .. ":" .. cid
    if op == "hello" or op == "ping" then
        self:transmit(cid, { type = op == "ping" and "pong" or "hello", realm = self.realm, address = from, gateway = self.hostname, connected = self.backend.connected() })
        return
    end
    if op == "send" then
        local to = util.normAddress(msg.to)
        local a = to and util.parseAddress(to)
        if not a or a.realm == "*" then
            self:fail(cid, op, "bad_address", "to must look like REALM:ID, for example EARTH:42")
            return
        end
        local size = M.dataSize(msg.data)
        if not size then return self:fail(cid, op, "bad_data", "data must be text, numbers, booleans or tables of them") end
        if size > M.MAX_DATA then return self:fail(cid, op, "too_large", "data must be " .. M.MAX_DATA .. " bytes or less") end
        self.backend.op({ op = "send", from = from, to = to, data = msg.data })
        return
    end
    if op == "publish" then
        local topic = M.publicTopic(msg.topic)
        if not topic then return self:fail(cid, op, "bad_topic", "topic must be words joined by dots, for example reactor.main") end
        local size = M.dataSize(msg.data)
        if not size then return self:fail(cid, op, "bad_data", "data must be text, numbers, booleans or tables of them") end
        if size > M.MAX_DATA then return self:fail(cid, op, "too_large", "data must be " .. M.MAX_DATA .. " bytes or less") end
        self.backend.op({ op = "publish", from = from, topic = topic, data = msg.data, retain = msg.retain ~= false })
        return
    end
    local pattern = M.publicPattern(msg.topic)
    if not pattern then return self:fail(cid, op, "bad_topic", "topic must be words joined by dots; end it with .* to match everything below it") end
    self.backend.op({ op = op, from = from, topic = pattern })
    if op == "subscribe" then self:transmit(cid, { type = "subscribed", topic = msg.topic }) end
end

function Gateway:run()
    while true do
        if self:openModems() then
            self.log.info("public gateway " .. self.hostname .. " on " .. table.concat(self.sides, ", "))
            while true do
                local ev, sender, message, protocol = os.pullEventRaw()
                local alk = ev == "rednet_message" and self.relay and protocol == nil and type(message) == "table" and M.ALK_FROM_NODE[message.type]
                if ev == "rednet_message" and (protocol == M.PROTOCOL or alk) then
                    if #self.inbox < M.INBOX_MAX then
                        self.inbox[#self.inbox + 1] = { sender, message, alk = alk and true or nil }
                        os.queueEvent("zn_gw")
                    else
                        self.stats.dropped = self.stats.dropped + 1
                    end
                elseif ev == "peripheral" or ev == "peripheral_detach" then
                    break
                end
            end
        else
            compat.sleep(30)
        end
    end
end

function Gateway:work()
    while true do
        while #self.inbox > 0 do
            local item = table.remove(self.inbox, 1)
            local ok, err = pcall(item.alk and self.relayAirlock or self.handle, self, item[1], item[2])
            if not ok then self.log.warn("public gateway: " .. tostring(err)) end
        end
        os.pullEventRaw("zn_gw")
    end
end

function Gateway:start()
    self.n:spawn(function() self:run() end, "public-gateway")
    self.n:spawn(function() self:work() end, "public-gateway-work")
end

function Gateway:status()
    return { hostname = self.hostname, sides = self.sides, rx = self.stats.rx, tx = self.stats.tx, dropped = self.stats.dropped, relayed = self.stats.relayed }
end

return M
