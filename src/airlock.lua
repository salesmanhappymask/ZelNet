local need = ...
local compat = need("compat")
local util = need("util")
local crypto = need("crypto")

local M = {}

M.ROLE = "system"
M.FILE = "airlocks.db"
M.POLL_INTERVAL = 300
M.OFFLINE_AFTER = 900
M.TICK = 30
M.DISCOVER_COUNT = 3
M.DISCOVER_GAP = 0.2
M.NAME_MAX = 32
M.MAX_NODES = 256
M.MODES = { seal = true, unseal = true, auto = true }
M.IGNORED = { alk_ack = true, alk_cmd = true, alk_poll = true, alk_discover = true, alk_peer = true, alk_dump = true, alk_update = true, alk_chunk = true }
M.RELAY_PORT = "zn.alk"
M.PATH_HOLD = 600
M.CONTAIN_MIN = 15
M.SETTLE = 8
M.CONTAIN_TICK = 1
M.LOSS_CONFIRM = 3
M.GRACE = 8
M.OPEN_GAP = 4
M.PROBE = 15
M.BACKOFF = 30
M.BACKOFF_MAX = 600
M.UNSTABLE_WINDOW = 120
M.UNSTABLE_DROPS = 3
M.UNSTABLE_SETTLE = 30
M.LOG_MAX = 800
M.LOG_FILE = "/zn_airlock.log"
M.LOG_CAP = 60000
M.LOG_FLUSH = 5
M.DUMP_WAIT = 4
M.DUMP_MAX = 6000
M.CHUNK = 3000
M.OFFER_GAP = 120
M.UPDATE_STALL = 180
M.PASTES = {
    { url = "https://paste.rs/", form = false },
    { url = "https://dpaste.com/api/v2/", form = true, suffix = ".txt" },
}
M.TRIP_WINDOW = 600
M.TRIP_LIMIT = 3

local Airlock = {}
Airlock.__index = Airlock

function M.groupInfo(name)
    local base, suffix = tostring(name or ""):match("^(.-)%-([%w]+)$")
    if base and base ~= "" then return base, suffix:upper() end
    return tostring(name or ""), nil
end

function M.stationOf(group)
    local g = tostring(group or "")
    local base = g:gsub("%d+$", "")
    if base == "" then return g end
    return base
end

function M.roomKey(name)
    if type(name) ~= "string" then return nil end
    local k = util.trim(name):lower()
    if k == "" then return nil end
    return k
end

function M.normalize(rec)
    if rec.role == "room" then
        rec.room = rec.room or rec.name
        rec.roomKey = M.roomKey(rec.room)
        rec.group = "room:" .. tostring(rec.roomKey)
        rec.suffix = nil
        return rec
    end
    if rec.role == "security" then
        rec.group = "security:" .. tostring(rec.name)
        rec.suffix = nil
        return rec
    end
    local g, suf = M.groupInfo(rec.name)
    rec.group = g
    rec.suffix = suf
    if rec.role ~= "sensor" and rec.role ~= "door" then
        rec.role = (suf == "C") and "sensor" or "door"
    end
    return rec
end

local function isHall(r)
    return r.role == "door" or r.role == "sensor"
end

local function cleanName(s)
    if type(s) ~= "string" then return "" end
    return util.trim(util.sanitize(s)):sub(1, M.NAME_MAX)
end

local function cleanRooms(t)
    if type(t) ~= "table" then return nil end
    local out = {}
    for i = 1, 2 do
        local v = cleanName(t[i])
        if v ~= "" then out[#out + 1] = v end
    end
    if #out == 0 then return nil end
    return out
end

local function memberKey(r)
    if r.role == "sensor" then return "~" .. tostring(r.suffix or r.name) end
    return tostring(r.suffix or r.name)
end

function M.new(ctx)
    local self = setmetatable({}, Airlock)
    self.ctx = ctx
    self.cfg = ctx.cfg or {}
    self.node = ctx.node
    self.log = ctx.log or (ctx.node and ctx.node.log) or util.newLogger(50)
    self.enabled = self.cfg.airlocks ~= false
    self.nodes = {}
    self.loaded = false
    self.dirty = false
    self.urgent = false
    self.ver = 0
    self.opened = 0
    self.started = false
    self.counters = { reports = 0, acks = 0, commands = 0, polls = 0, ignored = 0 }
    self.contain = {}
    self.lastOpen = {}
    self.layouts = {}
    self.events = {}
    self.logBuf = {}
    self.areaSeen = {}
    self.areaDrops = {}
    self.dumps = {}
    self.containOn = self.cfg.containment == true
    return self
end

local function clockText()
    local day, t = 0, 0
    pcall(function() day = os.day() or 0 end)
    pcall(function() t = os.time() or 0 end)
    local h = math.floor(t)
    local m = math.floor((t - h) * 60)
    return string.format("d%d %02d:%02d", day, h, m)
end

function Airlock:event(text)
    local line = string.format("%s %8.1f %s", clockText(), compat.now(), tostring(text))
    local ev = self.events
    ev[#ev + 1] = line
    if #ev > M.LOG_MAX then table.remove(ev, 1) end
    self.logBuf[#self.logBuf + 1] = line
    if #self.logBuf > M.LOG_MAX then table.remove(self.logBuf, 1) end
end

function Airlock:flushLog()
    if #self.logBuf == 0 or not fs or type(fs.open) ~= "function" then return end
    local lines = self.logBuf
    self.logBuf = {}
    pcall(function()
        if fs.exists(M.LOG_FILE) and fs.getSize(M.LOG_FILE) > M.LOG_CAP then
            local old = M.LOG_FILE .. ".old"
            if fs.exists(old) then fs.delete(old) end
            fs.move(M.LOG_FILE, old)
        end
        local h = fs.open(M.LOG_FILE, fs.exists(M.LOG_FILE) and "a" or "w")
        if not h then return end
        h.write(table.concat(lines, "\n") .. "\n")
        h.close()
    end)
end

function Airlock:lockdownOf(rec)
    local c = self.contain[self:stationOfRec(rec)]
    return (c and (c.manual or c.hold)) and true or nil
end

function Airlock:noteAreas(station)
    local st = self:areaStates(station)
    for kind, map in pairs({ zone = st.zones, area = st.commons }) do
        for key, v in pairs(map) do
            local k = station .. ":" .. kind .. ":" .. tostring(key)
            local now = v or "none"
            if self.areaSeen[k] ~= now then
                if self.areaSeen[k] ~= nil then self:event("area " .. kind .. " " .. tostring(key) .. " " .. self.areaSeen[k] .. " -> " .. now) end
                self.areaSeen[k] = now
                if now == "lost" then
                    local t = compat.now()
                    local drops = {}
                    for _, at in ipairs(self.areaDrops[k] or {}) do
                        if t - at < M.UNSTABLE_WINDOW then drops[#drops + 1] = at end
                    end
                    drops[#drops + 1] = t
                    self.areaDrops[k] = drops
                    if #drops == M.UNSTABLE_DROPS then
                        self:event("area " .. kind .. " " .. tostring(key) .. " UNSTABLE: lost air " .. #drops .. " times in " .. M.UNSTABLE_WINDOW .. "s; doors into it now wait " .. M.UNSTABLE_SETTLE .. "s of steady air")
                    end
                end
            end
        end
    end
end

function Airlock:unstable(key, now)
    local n = 0
    for _, at in ipairs(self.areaDrops[key] or {}) do
        if now - at < M.UNSTABLE_WINDOW then n = n + 1 end
    end
    return n >= M.UNSTABLE_DROPS, n
end

function Airlock:program()
    if self.prog ~= nil then return self.prog or nil end
    self.prog = false
    local ok, text = pcall(need, "prog_airlock")
    if ok and type(text) == "string" and #text > 0 then
        local chunks = math.ceil(#text / M.CHUNK)
        local hashes = {}
        for i = 1, chunks do hashes[i] = crypto.sha256(text:sub((i - 1) * M.CHUNK + 1, i * M.CHUNK)) end
        local ver = text:match('local VERSION = "(%w+)"') or crypto.sha256(text):sub(1, 8)
        self.prog = { text = text, ver = ver, size = #text, chunks = chunks, hashes = hashes }
    end
    return self.prog or nil
end

function Airlock:maybeOffer(rec, msg)
    local prog = self:program()
    local key = self.cfg.airlockKey
    if not prog or type(key) ~= "string" or msg.keyed ~= true or type(msg.ver) ~= "string" then return false end
    local now = compat.now()
    local u = self.updating
    if msg.ver == prog.ver then
        if u and u.id == rec.id then
            self:event("update " .. tostring(rec.name) .. " now runs " .. prog.ver)
            self:audit("airlock", "airlock_updated", rec.name, prog.ver, true)
            self.updating = nil
        end
        return false
    end
    if self.contain[self:stationOfRec(rec)] then return false end
    if u and u.id ~= rec.id and now - u.at < M.UPDATE_STALL then return false end
    if rec.offerAt and now - rec.offerAt < M.OFFER_GAP then return false end
    rec.offerAt = now
    self.updating = { id = rec.id, at = now }
    self:rsend(rec.id, {
        type = "alk_update", ver = prog.ver, size = prog.size, chunks = prog.chunks, chunk = M.CHUNK, hashes = prog.hashes,
        mac = crypto.hmac(key, "alk_update|" .. prog.ver .. "|" .. prog.size .. "|" .. table.concat(prog.hashes, ",")),
    })
    self:event("update offered " .. prog.ver .. " to " .. tostring(rec.name) .. " (runs " .. msg.ver .. ")")
    return true
end

function Airlock:serveChunk(id, msg)
    local prog = self:program()
    local i = tonumber(msg.i)
    if not prog or msg.ver ~= prog.ver or not i or i < 1 or i > prog.chunks or i ~= math.floor(i) then return false end
    if self.updating and self.updating.id == id then self.updating.at = compat.now() end
    self:rsend(id, { type = "alk_chunk", ver = prog.ver, i = i, data = prog.text:sub((i - 1) * M.CHUNK + 1, i * M.CHUNK) })
    return true
end

function Airlock:requestLogs()
    self.dumps = {}
    self.dumpNonce = tostring(math.random(1, 999999999))
    local n = 0
    for _, rec in pairs(self.nodes) do
        self:rsend(rec.id, { type = "alk_dump", nonce = self.dumpNonce })
        n = n + 1
    end
    self:event("asked " .. n .. " airlocks for their logs")
    return n
end

function Airlock:logBundle(header)
    local now = compat.now()
    local out = {}
    local function add(s) out[#out + 1] = s end
    add("ZELNET AIRLOCK LOG BUNDLE")
    if header then add(header) end
    add("time " .. clockText() .. " uptime " .. string.format("%.0f", now) .. "s")
    local prog = self:program()
    add("airlock program " .. (prog and prog.ver or "none") .. ", update key " .. (type(self.cfg.airlockKey) == "string" and "set" or "not set"))
    add("")
    add("== containment and lockdown")
    local cs = self:containment()
    if #cs == 0 then add("none") end
    for _, c in ipairs(cs) do add(string.format("%s cause=%s hold=%s manual=%s age=%.0fs", c.station, tostring(c.cause), tostring(c.hold), tostring(c.manual), c.age or 0)) end
    add("")
    add("== areas")
    for _, station in ipairs(self:stations()) do
        local st = self:areaStates(station)
        local parts = {}
        local function tag(kind, k)
            local bad, n = self:unstable(station .. ":" .. kind .. ":" .. tostring(k), now)
            if bad then return " UNSTABLE(" .. n .. " drops)" end
            if n > 0 then return " (" .. n .. " drops)" end
            return ""
        end
        for k, v in pairs(st.zones) do parts[#parts + 1] = "zone " .. k .. "=" .. tostring(v) .. tag("zone", k) end
        for k, v in pairs(st.commons) do parts[#parts + 1] = "area " .. k .. "=" .. tostring(v) .. tag("area", k) end
        table.sort(parts)
        add(station .. ": " .. table.concat(parts, ", "))
    end
    add("")
    add("== airlocks (name id role room online o2 sealed lock interlock manual ver via age backoff why)")
    local list = {}
    for _, r in pairs(self.nodes) do list[#list + 1] = r end
    table.sort(list, function(a, b) return tostring(a.name) < tostring(b.name) end)
    for _, r in ipairs(list) do
        local why = ""
        if r.role ~= "sensor" and r.role ~= "room" then
            local ps = self.pendingSettle
            self:desired(r)
            self.pendingSettle = ps
            why = self.why or ""
        end
        local room = r.role == "security" and table.concat(r.rooms or {}, "/") or (r.room or (self:roomKeyOf(r) and ("(" .. self:roomKeyOf(r) .. ")")) or "-")
        add(string.format("%-11s %4s %-8s room=%-9s %-3s o2=%-5s sealed=%-5s lock=%-5s il=%-5s man=%-6s ver=%-12s via=%s age=%s bo=%s | %s",
            tostring(r.name), tostring(r.id), tostring(r.role), room, r.online and "on" or "OFF", tostring(r.oxygenated), tostring(r.sealed), tostring(r.locked == true),
            tostring(r.interlock == true), tostring(r.manual or "-"), tostring(r.ver or "?"), tostring(r.via or "direct"),
            r.lastSeen and string.format("%.0fs", now - r.lastSeen) or "?",
            r.backoffUntil and r.backoffUntil > now and string.format("%.0fs", r.backoffUntil - now) or "-", why))
    end
    add("")
    add("== server events (oldest first)")
    for _, line in ipairs(self.events) do add(line) end
    add("")
    local names = {}
    for key, d in pairs(self.dumps) do names[#names + 1] = { key = key, name = d.name or key } end
    table.sort(names, function(a, b) return tostring(a.name) < tostring(b.name) end)
    for _, rec in ipairs(list) do
        if not self.dumps[tostring(rec.id)] then add("== " .. tostring(rec.name) .. " (#" .. tostring(rec.id) .. ") sent no log") end
    end
    for _, n in ipairs(names) do
        add("")
        add("== " .. tostring(n.name) .. " (#" .. n.key .. ") local log")
        add(self.dumps[n.key].text)
    end
    return table.concat(out, "\n")
end

function M.upload(text)
    if type(http) ~= "table" or type(http.post) ~= "function" then return nil, "the http API is turned off on this Minecraft server" end
    local tried = {}
    for _, p in ipairs(M.PASTES) do
        local body = p.form and ("expiry_days=30&content=" .. textutils.urlEncode(text)) or text
        local ok, r = pcall(http.post, p.url, body)
        local url
        if ok and r then
            url = (r.readAll() or ""):match("https?://%S+")
            pcall(r.close)
        end
        if url then return url .. (p.suffix or "") end
        tried[#tried + 1] = p.url:match("https?://([^/]+)")
    end
    return nil, "upload refused by " .. table.concat(tried, " and ")
end

function Airlock:rednet()
    local r = rawget(_G, "rednet")
    if type(r) == "table" then return r end
    return nil
end

function Airlock:rsend(id, msg)
    local rec = self.nodes[tostring(id)]
    if rec and rec.via and self.node then
        self.node:send(rec.via, M.RELAY_PORT, { op = "deliver", cid = tonumber(id), msg = msg })
        return true
    end
    local r = self:rednet()
    if not r or type(r.send) ~= "function" then return false end
    local ok, err = pcall(r.send, tonumber(id) or id, msg)
    if not ok then self.log.debug("airlock send: " .. tostring(err)) end
    return ok
end

function Airlock:routers()
    local srv = self.ctx.server
    local out = {}
    if not srv or not srv.reg or type(srv.reg.devices) ~= "table" then return out end
    for name, rec in pairs(srv.reg.devices) do
        if rec.role == "router" and rec.cid and rec.status ~= "revoked" then
            local st = srv.reg.statusOf and srv.reg:statusOf(name)
            if st == nil or st == "online" then out[#out + 1] = rec.cid end
        end
    end
    return out
end

function Airlock:rbroadcast(msg)
    if self.node and self.cfg.realm then
        for _, cid in ipairs(self:routers()) do
            self.node:send(self.cfg.realm .. ":" .. cid, M.RELAY_PORT, { op = "broadcast", msg = msg })
        end
    end
    local r = self:rednet()
    if not r or type(r.broadcast) ~= "function" then return false end
    return (pcall(r.broadcast, msg))
end

function Airlock:onRelay(msg)
    local srv = self.ctx.server
    local dev = srv and srv.deviceFromSrc and srv:deviceFromSrc(msg.src)
    if not dev or dev.role ~= "router" then return end
    local b = msg.data
    if type(b) ~= "table" or type(b.msg) ~= "table" or not tonumber(b.cid) then return end
    self.counters.relayed = (self.counters.relayed or 0) + 1
    self:handleMessage(tonumber(b.cid), b.msg, msg.src)
end

function Airlock:choosePath(rec, via, now)
    if via then
        if rec.directAt and now - rec.directAt < M.PATH_HOLD then return false end
        if rec.via and rec.via ~= via and rec.viaAt and now - rec.viaAt < M.PATH_HOLD then return false end
        if rec.via ~= via then self:changed(rec, true) end
        rec.via = via
        rec.viaAt = now
    else
        if rec.via then self:changed(rec, true) end
        rec.via = nil
        rec.viaAt = nil
        rec.directAt = now
    end
    return true
end

function Airlock:openRednet()
    local r = self:rednet()
    if not r or type(r.open) ~= "function" then return 0 end
    local n = 0
    local names = peripheral.getNames and peripheral.getNames() or { "top", "bottom", "left", "right", "front", "back" }
    for _, name in ipairs(names) do
        if peripheral.getType(name) == "modem" then
            if pcall(r.open, name) then n = n + 1 end
        end
    end
    self.opened = n
    return n
end

function Airlock:audit(actor, action, target, detail, ok)
    local st = self.ctx.storage
    if st and type(st.audit) == "function" then pcall(st.audit, st, actor, action, target, detail, ok) end
end

function Airlock:changed(rec, urgent)
    self.ver = self.ver + 1
    self.dirty = true
    if urgent then self.urgent = true end
    if self.ctx.emit then pcall(self.ctx.emit, "airlock", rec and rec.id) end
end

function Airlock:storageReady()
    local st = self.ctx.storage
    if not st then return true end
    if type(st.ready) ~= "function" then return true end
    local ok, v = pcall(st.ready, st, M.ROLE)
    return ok and v == true
end

function Airlock:load()
    if self.loaded then return true end
    local st = self.ctx.storage
    if not st then
        self.loaded = true
        return true
    end
    if not self:storageReady() then return false end
    local ok, t = pcall(st.read, st, M.ROLE, M.FILE, nil)
    if not ok then return false end
    if t == nil and type(st.exists) == "function" and st:exists(M.ROLE, M.FILE) then return false end
    local now = compat.now()
    if type(t) == "table" and type(t.contain) == "table" then
        for station, c in pairs(t.contain) do
            if type(station) == "string" and type(c) == "table" and not self.contain[station] then
                self.contain[station] = { since = now, cause = cleanName(c.cause), hold = c.hold == true or nil, manual = c.manual == true or nil, trips = {} }
            end
        end
    end
    if type(t) == "table" and type(t.nodes) == "table" then
        for key, r in pairs(t.nodes) do
            local id = type(r) == "table" and tonumber(r.id)
            local live = id and tostring(id) == key and self.nodes[key]
            if live then
                self:mergeStored(live, r)
            elseif id and tostring(id) == key then
                local rec = {
                    id = id, name = cleanName(r.name) ~= "" and cleanName(r.name) or ("Airlock " .. key),
                    role = r.role, oxygenated = r.oxygenated, locked = r.locked == true or nil,
                    manual = (r.manual == "seal" or r.manual == "unseal") and r.manual or nil,
                    sealed = r.sealed == true, lockSync = r.lockSync, named = r.named == true or nil,
                    online = r.online ~= false, seen = tonumber(r.seen), lastSeen = now,
                    via = type(r.via) == "string" and r.via or nil, viaAt = type(r.via) == "string" and now or nil,
                    ver = type(r.ver) == "string" and r.ver or nil,
                    room = type(r.room) == "string" and cleanName(r.room) ~= "" and cleanName(r.room) or nil,
                    rooms = cleanRooms(r.rooms), roomSet = r.roomSet == true or nil,
                }
                if type(rec.oxygenated) ~= "boolean" then rec.oxygenated = nil end
                if rec.oxygenated == true then rec.oxyAt = now - M.SETTLE end
                if rec.oxygenated == false then rec.lowAt = now - M.GRACE end
                if type(rec.lockSync) ~= "boolean" then rec.lockSync = nil end
                self.nodes[key] = M.normalize(rec)
            end
        end
    end
    self.loaded = true
    return true
end

function Airlock:mergeStored(live, r)
    if r.locked == true and not live.locked then live.locked = true end
    if not live.manual and (r.manual == "seal" or r.manual == "unseal") then live.manual = r.manual end
    if r.named == true and not live.named and cleanName(r.name) ~= "" then
        live.name = cleanName(r.name)
        live.named = true
        live.role = nil
    end
    M.normalize(live)
    self:applyPolicy(live, true)
    self:applyGroup(live.group)
    self:changed(live, true)
end

function Airlock:snapshot()
    local out = {}
    for key, r in pairs(self.nodes) do
        out[key] = {
            id = r.id, name = r.name, role = r.role, oxygenated = r.oxygenated, locked = r.locked,
            manual = r.manual, sealed = r.sealed, lockSync = r.lockSync, named = r.named, online = r.online, seen = r.seen,
            via = r.via, ver = r.ver, room = r.room, rooms = r.rooms, roomSet = r.roomSet,
        }
    end
    local contain = {}
    for station, c in pairs(self.contain) do contain[station] = { cause = c.cause, hold = c.hold, manual = c.manual } end
    return { v = 1, nodes = out, contain = contain }
end

function Airlock:save()
    if not self.loaded and not self:load() then return false end
    local st = self.ctx.storage
    local ver = self.ver
    self.urgent = false
    if not st then
        self.dirty = false
        return true
    end
    local ok, res, err = pcall(st.write, st, M.ROLE, M.FILE, self:snapshot())
    if ok and res then
        if self.ver == ver then self.dirty = false end
        return true
    end
    self.log.debug("airlock save: " .. tostring(ok and err or res))
    return false
end

function Airlock:groupSensor(group)
    if not group then return nil end
    for _, r in pairs(self.nodes) do
        if r.group == group and r.suffix == "C" and r.role == "sensor" then return r end
    end
    return nil
end

function Airlock:roomKeyOf(r)
    if r.role == "room" then return r.roomKey end
    if r.role ~= "door" then return nil end
    if type(r.room) == "string" and r.room ~= "" then return M.roomKey(r.room) end
    local l = self:layout(M.stationOf(r.group))
    return l and type(r.name) == "string" and l[r.name:lower()] or nil
end

function Airlock:topology()
    if self.topo then return self.topo end
    local t = { roomStation = {}, station = {}, roomNames = {} }
    for _, r in pairs(self.nodes) do
        if r.role == "door" then
            local k = self:roomKeyOf(r)
            if k and not t.roomStation[k] then t.roomStation[k] = M.stationOf(r.group) end
        end
    end
    local okN, nav = pcall(need, "navmap")
    if okN and type(nav) == "table" and type(nav.COMMONS) == "table" then
        for _, c in ipairs(nav.COMMONS) do
            if not t.roomStation[c.id] then t.roomStation[c.id] = nav.STATION end
        end
    end
    local function roomStation(k)
        if not k then return nil end
        return t.roomStation[k] or ("Room " .. k)
    end
    for key, r in pairs(self.nodes) do
        local st
        if r.role == "room" then
            st = roomStation(r.roomKey)
        elseif r.role == "security" then
            for _, name in ipairs(r.rooms or {}) do
                st = st or (t.roomStation[M.roomKey(name)])
            end
            st = st or M.stationOf(r.name)
        else
            st = M.stationOf(r.group)
        end
        t.station[key] = st
        if r.role == "room" and r.room then t.roomNames[r.roomKey] = r.room end
        if r.role == "door" and type(r.room) == "string" and r.room ~= "" then
            local k = M.roomKey(r.room)
            t.roomNames[k] = t.roomNames[k] or r.room
        end
    end
    self.topo = t
    return t
end

function Airlock:stationOfRec(r)
    local st = self:topology().station[tostring(r.id)]
    if st then return st end
    if r.role == "room" then return "Room " .. tostring(r.roomKey) end
    return M.stationOf(r.group)
end

function Airlock:roomNames()
    local out = {}
    for _, name in pairs(self:topology().roomNames) do out[#out + 1] = name end
    local okN, nav = pcall(need, "navmap")
    if okN and type(nav) == "table" and type(nav.COMMONS) == "table" then
        local have = {}
        for _, n in ipairs(out) do have[n:lower()] = true end
        for _, c in ipairs(nav.COMMONS) do
            if not have[c.id] then out[#out + 1] = c.name end
        end
    end
    table.sort(out, function(a, b) return a:lower() < b:lower() end)
    return out
end

function Airlock:roomLabel(key)
    return self:topology().roomNames[key] or key
end

function Airlock:stable(r, now)
    if r.oxygenated == false then return false end
    if r.oxygenated == nil then return true end
    return r.oxyAt == nil or now - r.oxyAt >= M.SETTLE
end

function Airlock:layout(station)
    local l = self.layouts[station]
    if l ~= nil then return l or nil end
    l = false
    local ok, nav = pcall(need, "navmap")
    if ok and type(nav) == "table" and nav.STATION == station and type(nav.COMMONS) == "table" then
        l = {}
        for _, c in ipairs(nav.COMMONS) do
            for _, name in ipairs(c.doors) do l[name:lower()] = c.id end
        end
    end
    self.layouts[station] = l
    return l or nil
end

function Airlock:roomArea(key)
    local station = self:topology().roomStation[key] or ("Room " .. key)
    local area = { members = {}, doors = {}, key = station .. ":area:" .. key, label = "room " .. self:roomLabel(key) }
    local sensors, fallback = {}, {}
    for _, r in pairs(self.nodes) do
        if r.role == "room" and r.roomKey == key then
            if r.online ~= false then sensors[#sensors + 1] = r end
        elseif r.role == "door" and self:roomKeyOf(r) == key then
            area.doors[#area.doors + 1] = r
            fallback[#fallback + 1] = r
            local il = r.ilRoom
            if il == nil and r.ilHall == nil then il = false end
            if il and r.online ~= false and r.interlockAt and compat.now() - r.interlockAt >= M.LOSS_CONFIRM then area.interlocked = true end
        elseif r.role == "security" then
            for _, name in ipairs(r.rooms or {}) do
                if M.roomKey(name) == key then area.doors[#area.doors + 1] = r end
            end
        end
    end
    area.members = #sensors > 0 and sensors or fallback
    area.fromSensor = #sensors > 0
    return area
end

function Airlock:farArea(rec)
    local key = self:roomKeyOf(rec)
    if not key then return { members = { rec }, doors = { rec }, label = "far side" } end
    return self:roomArea(key)
end

function Airlock:zoneArea(group)
    local area = { members = {}, doors = {}, key = M.stationOf(group) .. ":zone:" .. tostring(group), label = "hallway " .. tostring(group) }
    for _, r in pairs(self.nodes) do
        if r.group == group and isHall(r) then
            if r.suffix == "C" and r.role == "sensor" then area.members[#area.members + 1] = r
            elseif r.role ~= "sensor" then
                area.doors[#area.doors + 1] = r
                local il = r.ilHall
                if il == nil then il = r.interlock end
                if il and r.online ~= false and r.interlockAt and compat.now() - r.interlockAt >= M.LOSS_CONFIRM then area.interlocked = true end
            end
        end
    end
    return area
end

function Airlock:areaState(area, now)
    local recent = false
    for _, d in ipairs(area.doors) do
        if d.openedAt and now - d.openedAt < M.GRACE then recent = true end
    end
    local settle = (area.key and self:unstable(area.key, now)) and M.UNSTABLE_SETTLE or M.SETTLE
    local lows, settling = 0, false
    for _, m in ipairs(area.members) do
        if m.oxygenated == false then lows = lows + 1
        elseif m.oxygenated == true and m.oxyAt and now - m.oxyAt < settle then settling = true end
    end
    if area.interlocked then return "lost" end
    local wait = (recent and lows < 2) and M.GRACE or M.LOSS_CONFIRM
    local known, confirmed = 0, 0
    for _, m in ipairs(area.members) do
        if m.oxygenated ~= nil then known = known + 1 end
        if m.oxygenated == false and now - (m.lowAt or -math.huge) >= wait then confirmed = confirmed + 1 end
    end
    if confirmed > 0 and (confirmed * 2 > known or known <= 2) then return "lost" end
    if lows > 0 or settling then return "pending" end
    return "holding"
end

function Airlock:desired(rec)
    local function out(v, why)
        self.why = why
        return v
    end
    if rec.role == "sensor" or rec.role == "room" then return out(false, "sensor") end
    if rec.locked then return out(true, "locked from the console") end
    if rec.manual == "seal" then return out(true, "manual seal") end
    if rec.manual == "unseal" then return out(false, "manual unseal") end
    local now = compat.now()
    if rec.interlock and (rec.sealed or now - (rec.interlockAt or now) >= M.LOSS_CONFIRM) then
        self.pendingSettle = true
        local key = self:roomKeyOf(rec)
        local what = (rec.ilRoom and key and ("room " .. self:roomLabel(key))) or (rec.ilHall and ("hallway " .. tostring(rec.group))) or "a sensor it listens to"
        return out(true, what .. ": no oxygen")
    end
    if rec.interlock then self.pendingSettle = true end
    local station = self:stationOfRec(rec)
    local c = self.contain[station]
    if c and c.manual then return out(true, "station lockdown") end
    if c and (c.hold or now - c.since < M.CONTAIN_MIN) then return out(true, "containment") end
    local areas = {}
    if rec.role == "security" then
        for _, name in ipairs(rec.rooms or {}) do
            local k = M.roomKey(name)
            if k then areas[#areas + 1] = self:roomArea(k) end
        end
    else
        areas[1] = self:zoneArea(rec.group)
        areas[2] = self:farArea(rec)
    end
    local states = {}
    for i, a in ipairs(areas) do states[i] = self:areaState(a, now) end
    for i, a in ipairs(areas) do
        if states[i] == "lost" then return out(true, a.label .. ": no oxygen") end
    end
    local calm = true
    local waitFor
    for i, a in ipairs(areas) do
        if states[i] ~= "holding" then
            calm = false
            waitFor = waitFor or a.label
        end
    end
    if rec.sealed ~= true then
        if not calm or (rec.openedAt and now - rec.openedAt < M.PROBE) then self.pendingSettle = true end
        return out(false, rec.role == "security" and "open" or "open: both sides hold air")
    end
    if not calm then
        self.pendingSettle = true
        return out(true, "waiting: " .. waitFor .. " settling")
    end
    if rec.role == "security" then return out(false, "open") end
    if rec.backoffUntil and now < rec.backoffUntil then
        self.pendingSettle = true
        return out(true, "retry in " .. math.ceil(rec.backoffUntil - now) .. "s (lost air after opening)")
    end
    local last = self.lastOpen[station]
    if last and now - last < M.OPEN_GAP then
        self.pendingSettle = true
        return out(true, "waiting its turn to open")
    end
    return out(false, "open: both sides hold air")
end

function Airlock:members(station)
    local out = {}
    for _, r in pairs(self.nodes) do
        if self:stationOfRec(r) == station then out[#out + 1] = r end
    end
    table.sort(out, function(a, b) return tostring(a.name) < tostring(b.name) end)
    return out
end

function Airlock:applyStation(station)
    for _, r in ipairs(self:members(station)) do
        if r.role ~= "sensor" and r.role ~= "room" then self:applyPolicy(r, true) end
    end
    self:noteAreas(station)
end

function Airlock:announceStation(station, why)
    for _, r in ipairs(self:members(station)) do
        if r.role ~= "sensor" and r.role ~= "room" then
            self:applyPolicy(r, false)
            r.lockSync = r.locked and true or false
        end
        self:sendCommand(r, why)
    end
    self:noteAreas(station)
end

function Airlock:startContainment(rec)
    if not self.containOn then return false end
    local station = self:stationOfRec(rec)
    local now = compat.now()
    local c = self.contain[station]
    local trips = c and c.trips or {}
    local kept = {}
    for _, at in ipairs(trips) do
        if now - at < M.TRIP_WINDOW then kept[#kept + 1] = at end
    end
    kept[#kept + 1] = now
    local hold = (c and c.hold) or (#kept >= M.TRIP_LIMIT) or nil
    self.contain[station] = { since = now, cause = rec.name, trips = kept, hold = hold }
    self:event("containment " .. station .. " started by " .. tostring(rec.name) .. (hold and " (held)" or ""))
    self:audit("airlock", hold and "containment_hold" or "containment", station, "oxygen lost at " .. tostring(rec.name), false)
    self:applyStation(station)
    self:changed(rec, true)
    return true
end

function Airlock:stations()
    local seen, out = {}, {}
    for _, r in pairs(self.nodes) do
        local st = self:stationOfRec(r)
        if st ~= "" and not seen[st] then
            seen[st] = true
            out[#out + 1] = st
        end
    end
    table.sort(out)
    return out
end

function Airlock:lockdown(station, actor)
    if type(station) ~= "string" or #self:members(station) == 0 then return nil, "Unknown station." end
    local c = self.contain[station]
    self.contain[station] = { since = compat.now(), cause = "lockdown", hold = true, manual = true, trips = c and c.trips or {} }
    self:event("LOCKDOWN " .. station .. " by " .. tostring(actor or "console"))
    self:announceStation(station, "station lockdown")
    self:changed(nil, true)
    self:save()
    self:audit(actor or "console", "lockdown", station, "every door sealed", true)
    return true
end

function Airlock:releaseContainment(station, actor)
    local c = self.contain[station]
    if not c then return nil, "No containment is active there." end
    self.contain[station] = nil
    self:event("release " .. station .. " by " .. tostring(actor or "console"))
    self:announceStation(station, "lockdown released")
    self:changed(nil, true)
    self:save()
    self:audit(actor or "console", "containment_release", station, c.cause and ("started at " .. c.cause) or nil, true)
    return true
end

function Airlock:containTick()
    local now = compat.now()
    self.pendingSettle = false
    for station, c in compat.spairs(self.contain) do
        if not c.hold and now - c.since >= M.CONTAIN_MIN then
            local clear = true
            for _, r in ipairs(self:members(station)) do
                if not self:stable(r, now) then clear = false break end
            end
            if clear then
                self.contain[station] = nil
                self:audit("airlock", "containment_clear", station, "every zone holds oxygen", true)
                self:event("containment " .. station .. " cleared")
                self:changed(nil, true)
            end
        end
    end
    for _, r in compat.spairs(self.nodes) do
        if r.role ~= "sensor" then self:applyPolicy(r, true) end
    end
    for _, station in ipairs(self:stations()) do self:noteAreas(station) end
    if self.urgent then self:save() end
end

function Airlock:areaStates(station)
    local now = compat.now()
    local out = { zones = {}, commons = {}, sources = {} }
    for _, r in ipairs(self:members(station)) do
        if isHall(r) and r.group and out.zones[r.group] == nil then
            local z = self:zoneArea(r.group)
            out.zones[r.group] = #z.members > 0 and self:areaState(z, now) or false
        end
        local key = self:roomKeyOf(r)
        if key and out.commons[key] == nil then
            local a = self:roomArea(key)
            out.commons[key] = #a.members > 0 and self:areaState(a, now) or false
            out.sources[key] = a.fromSensor and "sensor" or "doors"
        end
    end
    return out
end

function Airlock:setRoom(id, value, actor)
    local rec, err = self:find(id)
    if not rec then return nil, err end
    if rec.role == "door" then
        local v = cleanName(value)
        rec.room = v ~= "" and v or nil
    elseif rec.role == "security" then
        rec.rooms = cleanRooms(type(value) == "table" and value or { value })
    else
        return nil, "Only doors and security doors open into rooms."
    end
    rec.roomSet = true
    self.topo = nil
    self:applyPolicy(rec, false)
    self:sendCommand(rec, "room set from the console")
    rec.lockSync = rec.locked and true or false
    self:applyStation(self:stationOfRec(rec))
    self:changed(rec, true)
    self:save()
    local text = rec.role == "door" and tostring(rec.room or "none") or table.concat(rec.rooms or {}, " / ")
    self:event("room of " .. tostring(rec.name) .. " set to " .. text .. " by " .. tostring(actor or "console"))
    self:audit(actor or "console", "airlock_room", rec.name, text, true)
    return true
end

function Airlock:containment()
    local now = compat.now()
    local out = {}
    for station, c in pairs(self.contain) do
        out[#out + 1] = { station = station, cause = c.cause, hold = c.hold, manual = c.manual, age = now - c.since, trips = #(c.trips or {}) }
    end
    table.sort(out, function(a, b) return a.station < b.station end)
    return out
end

function Airlock:sendCommand(rec, why)
    self.counters.commands = self.counters.commands + 1
    local action = rec.sealed and "seal" or "unseal"
    self:event("cmd " .. tostring(rec.name) .. " " .. action .. (rec.locked and " locked" or "") .. (self:lockdownOf(rec) and " lockdown" or "") .. " (" .. tostring(why or self.why or "?") .. ")")
    self:rsend(rec.id, {
        type = "alk_cmd", action = action, locked = rec.locked and true or false, force = rec.manual == "unseal" or nil,
        lockdown = self:lockdownOf(rec), why = (rec.role == "door" or rec.role == "security") and (why or self.why) or nil,
        room = rec.role == "door" and rec.roomSet and (rec.room or false) or nil, rooms = rec.role == "security" and rec.roomSet and (rec.rooms or false) or nil,
    })
end

function Airlock:applyPolicy(rec, announce)
    local prev = rec.sealed
    local desired = self:desired(rec)
    if rec.role ~= "sensor" then
        local now = compat.now()
        if prev == true and desired == false then
            rec.openedAt = now
            self.lastOpen[self:stationOfRec(rec)] = now
        elseif prev == false and desired == true and rec.openedAt and now - rec.openedAt < M.PROBE and not rec.locked and not rec.manual and not rec.interlock then
            rec.backoffN = (rec.backoffN or 0) + 1
            rec.backoffUntil = now + math.min(M.BACKOFF_MAX, M.BACKOFF * 2 ^ (rec.backoffN - 1))
            self:audit("airlock", "door_retry", rec.name, "lost air right after opening; next try in " .. math.floor(rec.backoffUntil - now) .. "s", false)
            self:event("backoff " .. tostring(rec.name) .. " " .. math.floor(rec.backoffUntil - now) .. "s (try " .. rec.backoffN .. ")")
        elseif prev == false and desired == false and rec.openedAt and now - rec.openedAt >= M.PROBE then
            rec.backoffN = nil
        end
    end
    local lockFlag = rec.locked and true or false
    local changed = (rec.sealed ~= desired) or (rec.lockSync ~= lockFlag)
    if rec.sealed ~= desired then self:changed(rec) end
    rec.sealed = desired
    if announce and changed then
        self:sendCommand(rec)
        rec.lockSync = lockFlag
    end
    return desired, changed
end

function Airlock:applyGroup(group)
    if not group then return end
    for _, r in pairs(self.nodes) do
        if r.group == group and r.role ~= "sensor" then self:applyPolicy(r, true) end
    end
end

function Airlock:handleMessage(senderID, msg, via)
    if type(msg) ~= "table" or type(msg.type) ~= "string" or msg.type:sub(1, 4) ~= "alk_" then return false end
    if M.IGNORED[msg.type] then
        self.counters.ignored = self.counters.ignored + 1
        return false
    end
    local id = tonumber(senderID)
    if not id then return false end
    if not self.loaded then self:load() end
    local key = tostring(id)
    local rec = self.nodes[key]
    if msg.type == "alk_get" then
        if rec and via and rec.via ~= via then return false end
        return self:serveChunk(id, msg)
    end
    if msg.type == "alk_log" then
        if rec and msg.nonce == self.dumpNonce and type(msg.text) == "string" then
            self.dumps[key] = { name = rec.name, text = msg.text:sub(-M.DUMP_MAX) }
            return true
        end
        return false
    end
    local isNew = rec == nil
    if isNew and util.count(self.nodes) >= M.MAX_NODES then return false end
    rec = rec or { id = id }
    if not self:choosePath(rec, via, compat.now()) then
        self.counters.ignored = self.counters.ignored + 1
        return false
    end
    local wasOnline, oldOxy, oldName, oldRole, oldGroup = rec.online, rec.oxygenated, rec.name, rec.role, rec.group
    local oldSealed, oldIl = rec.sealed, rec.interlock
    local nm = cleanName(msg.name)
    if nm ~= "" and not rec.named then rec.name = nm end
    if not rec.name or rec.name == "" then rec.name = "Airlock " .. key end
    if msg.role == "sensor" or msg.role == "door" or msg.role == "room" or msg.role == "security" then
        if rec.role ~= msg.role then self.topo = nil end
        rec.role = msg.role
    end
    if not rec.roomSet then
        if rec.role == "door" and msg.room ~= nil then
            local v = cleanName(msg.room)
            v = v ~= "" and v or nil
            if v ~= rec.room then self.topo = nil end
            rec.room = v
        elseif rec.role == "room" and type(msg.room) == "string" then
            local v = cleanName(msg.room)
            if v ~= "" and v ~= rec.room then
                rec.room = v
                self.topo = nil
            end
        elseif rec.role == "security" and msg.rooms ~= nil then
            rec.rooms = cleanRooms(msg.rooms)
            self.topo = nil
        end
    end
    if rec.role == "door" or rec.role == "security" then
        if type(msg.ilHall) == "boolean" then rec.ilHall = msg.ilHall else rec.ilHall = nil end
        if type(msg.ilRoom) == "boolean" then rec.ilRoom = msg.ilRoom else rec.ilRoom = nil end
    end
    if type(msg.oxygenated) == "boolean" then
        if msg.oxygenated and rec.oxygenated ~= true then rec.oxyAt = isNew and (compat.now() - M.SETTLE) or compat.now() end
        if not msg.oxygenated and rec.oxygenated ~= false then rec.lowAt = isNew and (compat.now() - M.GRACE) or compat.now() end
        rec.oxygenated = msg.oxygenated
    end
    if type(msg.sealed) == "boolean" and msg.role ~= "sensor" then rec.sealed = msg.sealed end
    if msg.role ~= "sensor" then
        local il = msg.interlock == true or nil
        if il and not rec.interlock then rec.interlockAt = compat.now() end
        rec.interlock = il
    end
    rec.lastSeen = compat.now()
    rec.seen = compat.stamp()
    rec.online = true
    if isNew or oldName ~= rec.name then self.topo = nil end
    M.normalize(rec)
    self.nodes[key] = rec
    self.counters.reports = self.counters.reports + 1
    self:applyPolicy(rec, false)
    if oldGroup and oldGroup ~= rec.group then self:applyGroup(oldGroup) end
    if rec.oxygenated == false and oldOxy ~= false then
        self:startContainment(rec)
    end
    local why = self.why
    if type(msg.ver) == "string" then rec.ver = msg.ver:sub(1, 16) end
    if msg.type ~= "alk_hello" or oldOxy ~= rec.oxygenated or oldIl ~= rec.interlock or (msg.sealed ~= nil and msg.sealed ~= oldSealed) then
        self:event(string.format("rx %s %s o2=%s sealed=%s il=%s%s", tostring(rec.name), msg.type:sub(5), tostring(msg.oxygenated), tostring(msg.sealed), tostring(msg.interlock == true), via and (" via " .. via) or ""))
    end
    self:applyStation(self:stationOfRec(rec))
    self.counters.acks = self.counters.acks + 1
    rec.lockSync = rec.locked and true or false
    local command = (rec.role ~= "sensor" and rec.sealed) and "seal" or "unseal"
    if rec.role ~= "sensor" and msg.sealed ~= nil and (command == "seal") ~= msg.sealed then
        self:event("ack " .. tostring(rec.name) .. " " .. command .. " (" .. tostring(why) .. ")")
    end
    self:rsend(id, {
        type = "alk_ack", reqID = msg.reqID, name = rec.name, role = rec.role,
        command = command, locked = rec.locked and true or false,
        force = rec.manual == "unseal" or nil, lockdown = self:lockdownOf(rec),
        why = (rec.role == "door" or rec.role == "security") and why or nil,
        room = rec.role == "door" and (rec.room or false) or nil, rooms = rec.role == "security" and (rec.rooms or false) or nil,
        roomSet = rec.roomSet or nil, roomList = self:roomNames(),
    })
    self:maybeOffer(rec, msg)
    self:noteReport(rec, msg.type, isNew, wasOnline, oldOxy)
    local structural = isNew or wasOnline == false or oldOxy ~= rec.oxygenated or oldName ~= rec.name or oldRole ~= rec.role
    self:changed(rec, structural)
    if self.urgent then self:save() end
    return true
end

function Airlock:noteReport(rec, kind, isNew, wasOnline, oldOxy)
    local detail = "id " .. tostring(rec.id)
    if kind == "alk_register" and (isNew or wasOnline == false) then
        self:audit("airlock", "register", rec.name, detail, true)
    elseif isNew then
        self:audit("airlock", "discovered", rec.name, detail, true)
    elseif wasOnline == false then
        self:audit("airlock", "online", rec.name, detail, true)
    end
    if rec.oxygenated == false and oldOxy ~= false then
        self:audit("airlock", "depressurized", rec.name, detail, true)
    elseif oldOxy == false and rec.oxygenated == true then
        self:audit("airlock", "repressurized", rec.name, detail, true)
    end
end

function Airlock:checkOffline()
    local now = compat.now()
    local n = 0
    for _, rec in pairs(self.nodes) do
        if rec.online and rec.lastSeen and now - rec.lastSeen > M.OFFLINE_AFTER then
            rec.online = false
            n = n + 1
            self:audit("airlock", "offline", rec.name, "id " .. tostring(rec.id), false)
            self:changed(rec, true)
        end
    end
    return n
end

function Airlock:poll()
    if not self.enabled then return 0 end
    local n = 0
    for _, rec in pairs(self.nodes) do
        self:rsend(rec.id, { type = "alk_poll" })
        n = n + 1
    end
    self.counters.polls = self.counters.polls + 1
    self:checkOffline()
    if self.urgent then self:save() end
    return n
end

function Airlock:find(id)
    local rec = self.nodes[tostring(tonumber(id) or id)]
    if not rec then return nil, "Unknown airlock." end
    return rec
end

function Airlock:clearWait(rec)
    rec.backoffN = nil
    rec.backoffUntil = nil
    self.lastOpen[self:stationOfRec(rec)] = nil
end

function Airlock:setManual(id, mode, actor)
    local rec, err = self:find(id)
    if not rec then return nil, err end
    if not M.MODES[mode] then return nil, "Unknown mode." end
    if mode == "auto" then rec.manual = nil else rec.manual = mode end
    self:clearWait(rec)
    local desired = self:applyPolicy(rec, true)
    self:applyGroup(rec.group)
    self:changed(rec, true)
    self:save()
    self:audit(actor or "console", "airlock_" .. mode, rec.name, "id " .. tostring(rec.id), true)
    return true, desired
end

function Airlock:setLocked(id, locked, actor)
    local rec, err = self:find(id)
    if not rec then return nil, err end
    if rec.role == "sensor" then return nil, "Sensors have no door to lock." end
    rec.locked = locked and true or nil
    self:clearWait(rec)
    self:applyPolicy(rec, false)
    self:sendCommand(rec)
    rec.lockSync = rec.locked and true or false
    self:changed(rec, true)
    self:save()
    self:audit(actor or "console", rec.locked and "airlock_lock" or "airlock_unlock", rec.name, "id " .. tostring(rec.id), true)
    return true
end

function Airlock:rename(id, name, actor)
    local rec, err = self:find(id)
    if not rec then return nil, err end
    local newName = cleanName(name)
    if newName == "" then return nil, "Name is empty." end
    local oldGroup = rec.group
    rec.name = newName
    if rec.role == "room" then rec.room = newName elseif rec.role ~= "security" then rec.role = nil end
    rec.named = true
    self.topo = nil
    M.normalize(rec)
    self:applyGroup(oldGroup)
    self:applyGroup(rec.group)
    self:changed(rec, true)
    self:save()
    self:audit(actor or "console", "airlock_rename", rec.name, "id " .. tostring(rec.id), true)
    return true
end

function Airlock:remove(id, actor)
    local rec, err = self:find(id)
    if not rec then return nil, err end
    self.nodes[tostring(rec.id)] = nil
    self.topo = nil
    self:applyGroup(rec.group)
    self:changed(rec, true)
    self:save()
    self:audit(actor or "console", "airlock_remove", rec.name, "id " .. tostring(rec.id), true)
    return true
end

function Airlock:pollOne(id)
    local rec, err = self:find(id)
    if not rec then return nil, err end
    self:rsend(rec.id, { type = "alk_poll" })
    return true
end

function Airlock:discover()
    if not self.enabled then return false end
    os.queueEvent("zn_airlock_discover")
    return true
end

local function copyRec(r, now)
    local c = util.copy(r)
    c.age = r.lastSeen and (now - r.lastSeen) or nil
    c.lastSeen = nil
    return c
end

function Airlock:list()
    local now = compat.now()
    local out = {}
    for _, r in pairs(self.nodes) do out[#out + 1] = copyRec(r, now) end
    table.sort(out, function(a, b)
        if a.group ~= b.group then return tostring(a.group) < tostring(b.group) end
        return memberKey(a) < memberKey(b)
    end)
    return out
end

function Airlock:groups()
    local byGroup, order = {}, {}
    for _, r in ipairs(self:list()) do
        local g = r.group or tostring(r.name)
        if not byGroup[g] then
            byGroup[g] = {}
            order[#order + 1] = g
        end
        table.insert(byGroup[g], r)
    end
    table.sort(order)
    local out = {}
    for _, g in ipairs(order) do
        local mem = byGroup[g]
        local sensor, sealed, hasSuffix = nil, 0, false
        for _, r in ipairs(mem) do
            if r.suffix == "C" then sensor = r end
            if r.sealed then sealed = sealed + 1 end
            if r.suffix then hasSuffix = true end
        end
        out[#out + 1] = {
            group = g, members = mem, total = #mem, sealed = sealed, hasSensor = sensor ~= nil,
            chamberLow = sensor ~= nil and sensor.oxygenated == false, grouped = #mem > 1 or hasSuffix,
            contained = self.contain[M.stationOf(g)] ~= nil,
        }
    end
    return out
end

function Airlock:stats()
    local s = { nodes = 0, sealed = 0, low = 0, offline = 0, contained = util.count(self.contain) }
    for _, r in pairs(self.nodes) do
        s.nodes = s.nodes + 1
        if r.sealed then s.sealed = s.sealed + 1 end
        if r.oxygenated == false then s.low = s.low + 1 end
        if not r.online then s.offline = s.offline + 1 end
    end
    return s
end

function Airlock:tick()
    if not self.loaded then self:load() end
    self:checkOffline()
    if self.dirty then self:save() end
end

function Airlock:step(timers, ev, a, b)
    if ev == "rednet_message" then
        if type(b) == "table" and type(b.type) == "string" and b.type:sub(1, 4) == "alk_" then
            self:handleMessage(a, b)
        end
    elseif ev == "timer" then
        if a == timers.discover then
            self:rbroadcast({ type = "alk_discover" })
            timers.left = timers.left - 1
            timers.discover = timers.left > 0 and compat.quietTimer(M.DISCOVER_GAP) or nil
        elseif a == timers.poll then
            timers.poll = compat.quietTimer(M.POLL_INTERVAL)
            self:poll()
        elseif a == timers.tick then
            timers.tick = compat.quietTimer(M.TICK)
            self:tick()
        elseif a == timers.contain then
            timers.contain = nil
            self:containTick()
        elseif a == timers.flush then
            timers.flush = nil
            self:flushLog()
        end
    elseif ev == "zn_airlock_discover" then
        timers.left = M.DISCOVER_COUNT
        timers.discover = compat.quietTimer(0)
    elseif ev == "peripheral" then
        self:openRednet()
    end
    if not timers.contain and (next(self.contain) or self.pendingSettle) then timers.contain = compat.quietTimer(M.CONTAIN_TICK) end
    if not timers.flush and #self.logBuf > 0 then timers.flush = compat.quietTimer(M.LOG_FLUSH) end
end

function Airlock:run()
    self:openRednet()
    self:load()
    local timers = {
        left = M.DISCOVER_COUNT, discover = compat.quietTimer(0),
        poll = compat.quietTimer(M.POLL_INTERVAL), tick = compat.quietTimer(M.TICK),
    }
    while true do
        local ev, a, b = os.pullEventRaw()
        local ok, err = pcall(self.step, self, timers, ev, a, b)
        if not ok then self.log.error("airlock: " .. tostring(err)) end
    end
end

function Airlock:start()
    if self.started then return true end
    self.started = true
    if not self.enabled then
        self.log.info("airlocks disabled")
        return true
    end
    self:load()
    if self.node then
        self.node:listen(M.RELAY_PORT, function(msg) self:onRelay(msg) end)
        self.task = self.node:spawn(function() self:run() end, "airlock")
    end
    return true
end

M.Airlock = Airlock

return M
