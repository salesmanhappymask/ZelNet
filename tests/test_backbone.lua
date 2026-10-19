package.path = "./?.lua;" .. package.path
local nativePcall = pcall
local env = require("tests.fakecc").install({ id = 1 })
rawset(_G, "__nativePcall", rawget(_G, "__nativePcall") or nativePcall)
local need = require("tools.devload").make(".")
local kit = require("tests.srvkit").init(env, need)
local seal = need("seal")
local frame = need("frame")
local util = need("util")
local crypto = need("crypto")
local codec = need("codec")
local cipher = need("cipher")
local version = need("version")
local t = require("tests.tiny")

local BKEY = crypto.newKey()

local function server(id, realm, role, sides, extra)
    local srv, n = kit.newServer({
        id = id, realm = realm, role = role, mainRealm = "EARTH", backboneKey = BKEY, sides = sides,
        storage = kit.fakeStorage(), bridgeModule = extra and extra.bridgeModule, cipher = extra and extra.cipher,
        extra = extra and extra.cfg,
    })
    return srv, n
end

local function hwCipher(tag)
    local obj = { kind = "hardware", name = "fake_cipher_" .. tag }
    function obj.encrypt(s) return tag .. "." .. crypto.b64encode(s) end
    function obj.decrypt(s)
        if type(s) ~= "string" or s:sub(1, #tag + 1) ~= tag .. "." then return nil, "decrypt failed" end
        return crypto.b64decode(s:sub(#tag + 2))
    end
    return obj
end

local function backbonePacket(src, dst, port, body, opts)
    opts = opts or {}
    return { v = 1, id = opts.id or util.newId(), src = src, dst = dst, port = port, ttl = opts.ttl or 24, rq = opts.rq, re = opts.re, body = body }
end

t.case("backbone sealing round trip with a software cipher", function()
    local sw = cipher.software(BKEY)
    local pkt = backbonePacket("MARS:4", "EARTH:7", "power", { stored = 12, text = "a \"quoted\" line\n" })
    local w = assert(seal.sealBackbone(sw, BKEY, pkt, "MARS"))
    t.ok(frame.validBackbone(w))
    t.eq(w.via, "MARS")
    t.ok(not w.ct:find("quoted"), "plaintext visible")
    t.ok(seal.verifyBackbone(BKEY, w))
    local back, nonce = assert(seal.openBackbone(sw, BKEY, w))
    t.eq(back.body.stored, 12)
    t.eq(back.body.text, "a \"quoted\" line\n")
    t.eq(back.src, "MARS:4")
    t.eq(#nonce, 32)
    local w2 = assert(seal.sealBackbone(sw, BKEY, pkt, "MARS"))
    t.neq(w2.ct, w.ct, "same plaintext gave same ciphertext")
    w.via = "PLUTO"
    t.ok(seal.verifyBackbone(BKEY, w), "via must not be covered")
    w.dst = "EARTH:8"
    t.ok(not seal.verifyBackbone(BKEY, w), "tampered dst accepted")
    t.eq(seal.openBackbone(sw, crypto.newKey(), w2), nil)
    local big = backbonePacket("MARS", "EARTH", "x", string.rep("a", 40000))
    local _, err = seal.sealBackbone(sw, BKEY, big, "MARS")
    t.eq(err, "too_large")
end)

t.case("received backbone frames: delivery, replay and bad mac", function()
    fs.delete("/.zelnet")
    kit.reset()
    local srv, n = server(1, "EARTH", "main", { "top" })
    local sw = cipher.software(BKEY)
    local got = {}
    kit.runAll({ n }, function()
        n:listen("inbox", function(msg) got[#got + 1] = msg end)
        local pkt = backbonePacket("MARS:4", "EARTH", "inbox", { n = 1 })
        local w = assert(seal.sealBackbone(sw, BKEY, pkt, "MARS"))
        local f = frame.make(n.cfg.netId, "x", 2, 1, w)
        n.inq.push({ f = util.deepCopy(f), link = "modem:top", dist = 5 })
        n:wake()
        kit.waitFor(function() return #got > 0 end, 5)
        t.eq(#got, 1)
        t.eq(got[1].src, "MARS:4")
        t.eq(got[1].data.n, 1)
        n.inq.push({ f = util.deepCopy(f), link = "modem:top", dist = 5 })
        n:wake()
        sleep(2)
        t.eq(#got, 1, "replay delivered")
        t.eq(srv.bb.counters.replays, 1)
        local w3 = assert(seal.sealBackbone(sw, BKEY, backbonePacket("MARS:4", "EARTH", "inbox", { n = 3 }), "MARS"))
        w3.mac = string.rep("0", 64)
        n.inq.push({ f = frame.make(n.cfg.netId, "x", 2, 1, w3), link = "modem:top", dist = 5 })
        n:wake()
        sleep(2)
        t.eq(#got, 1)
        t.eq(srv.bb.counters.badMac, 1)
        local wrongKey = assert(seal.sealBackbone(sw, crypto.newKey(), backbonePacket("MARS:4", "EARTH", "inbox", { n = 4 }), "MARS"))
        n.inq.push({ f = frame.make(n.cfg.netId, "x", 2, 1, wrongKey), link = "modem:top", dist = 5 })
        n:wake()
        sleep(2)
        t.eq(#got, 1)
        t.eq(srv.bb.counters.badMac, 2)
    end)
end)

t.case("distance vector routing across three servers, loss and store and forward", function()
    fs.delete("/.zelnet")
    kit.reset()
    local earth, en = server(1, "EARTH", "main", { "left" })
    local mars, mn = server(2, "MARS", "satellite", { "right", "back" })
    local venus, vn = server(3, "VENUS", "satellite", { "front" })
    kit.connect(en, "left", mn, "right")
    kit.connect(mn, "back", vn, "front")
    local ups, downs = {}, {}
    earth:on("realm_up", function(r) ups[#ups + 1] = r end)
    earth:on("realm_down", function(r) downs[#downs + 1] = r end)
    kit.runAll({ en, mn, vn }, function()
        vn:listen("echo", function(msg) vn:reply(msg, { from = "venus", data = msg.data }) end)
        t.ok(kit.waitFor(function() return earth.bb:reachable("VENUS") end, 90), "EARTH learned VENUS")
        t.eq(earth.bb:metricTo("MARS"), 1)
        t.eq(earth.bb:metricTo("VENUS"), 2)
        t.eq(venus.bb:metricTo("EARTH"), 2)
        local routes = earth:status().routes
        local byRealm = {}
        for _, r in ipairs(routes) do byRealm[r.realm] = r end
        t.eq(byRealm.VENUS.via, "MARS")
        t.eq(byRealm.VENUS.kind, "radio")
        local advToEarth = mars.bb:routesFor("radio:EARTH")
        t.eq(advToEarth.VENUS, 1)
        t.eq(advToEarth.MARS, 0)
        t.eq(advToEarth.EARTH, 16, "poisoned reverse")
        local advToMars = earth.bb:routesFor("radio:MARS")
        t.eq(advToMars.VENUS, 16, "split horizon")
        t.ok(util.contains(ups, "MARS") and util.contains(ups, "VENUS"))

        local body, src = en:request("VENUS", "echo", { hi = 1 }, 20)
        t.eq(src, "VENUS")
        t.eq(body and body.from, "venus")
        t.eq(body and body.data.hi, 1)
        t.ok(mars.bb.counters.forwarded >= 2, "MARS forwarded")

        local nb = earth:status().neighbors
        t.eq(#nb, 1)
        t.eq(nb[1].realm, "MARS")
        t.eq(nb[1].kind, "radio")
        t.eq(nb[1].id, 2)
        t.eq(nb[1].up, true)
        t.eq(nb[1].prog, version.program)

        kit.waitFor(function() return earth.dir.realms.VENUS ~= nil and mars.dir.realms.VENUS ~= nil end, 60)
        t.ok(earth.dir.realms.VENUS ~= nil, "VENUS registered with Main")
        t.eq(earth.dir.realms.VENUS.serverId, 3)
        t.ok(mars.dir.synced, "MARS received the directory")

        kit.port("back").cut = true
        kit.port("front").cut = true
        t.ok(kit.waitFor(function() return not earth.bb:reachable("VENUS") end, 200), "EARTH noticed VENUS loss")
        t.ok(util.contains(downs, "VENUS"))
        t.ok(earth.bb:reachable("MARS"))
        local _, err = en:request("VENUS", "echo", {}, 5, { retries = 0 })
        t.eq(err, "timeout")
        en:send("VENUS", "inbox", { stored = true })
        sleep(1)
        t.ok(earth.bb:queueSize() >= 1, "stored for later")
        t.eq(earth:status().queue.stored, earth.bb:queueSize())
        kit.port("back").cut = false
        kit.port("front").cut = false
        local msg = vn:receive("inbox", 200)
        t.ok(msg ~= nil, "stored packet delivered after the route came back")
        t.eq(msg and msg.data.stored, true)
        t.eq(msg and msg.src, "EARTH")
        t.eq(earth.bb:queueSize(), 0)
        local _, err2 = en:request("NOWHERE", "echo", {}, 5, { retries = 0 })
        t.eq(err2, "no_route")
    end, 20000)
end)

t.case("directory claims through Main and pub/sub flooding across realms", function()
    fs.delete("/.zelnet")
    kit.reset()
    local earth, en = server(1, "EARTH", "main", { "left" })
    local mars, mn = server(2, "MARS", "satellite", { "right", "back" })
    local venus, vn = server(3, "VENUS", "satellite", { "front" })
    kit.connect(en, "left", mn, "right")
    kit.connect(mn, "back", vn, "front")
    local earthGot, marsGot = {}, {}
    kit.runAll({ en, mn, vn }, function()
        t.ok(kit.waitFor(function() return venus.dir.synced and earth.dir.realms.VENUS ~= nil end, 120), "VENUS registered")
        t.eq(venus:claimUser("bob"), true)
        t.eq(earth:userHome("bob"), "VENUS")
        t.eq(venus:userHome("bob"), "VENUS")
        local ok, err = earth:claimUser("bob")
        t.eq(ok, nil)
        t.eq(err, "taken")
        ok, err = mars:claimUser("bob")
        t.eq(err, "taken")
        t.eq(earth:claimUser("alice"), true)
        t.ok(kit.waitFor(function() return mars:userHome("bob") == "VENUS" and mars:userHome("alice") == "EARTH" end, 30), "push reached MARS")
        ok, err = mars:releaseUser("bob")
        t.eq(err, "denied")
        t.eq(venus:renameUser("bob", "robert"), true)
        t.eq(earth:userHome("robert"), "VENUS")
        t.eq(earth:userHome("bob"), nil)
        t.eq(venus:userHome("robert"), "VENUS")
        t.eq(venus:releaseUser("robert"), true)
        t.eq(earth:userHome("robert"), nil)
        local list = earth:listUsers()
        t.eq(#list, 1)
        t.eq(list[1].name, "alice")
        t.eq(list[1].realm, "EARTH")
        local _, berr = venus:claimUser("X")
        t.eq(berr, "bad_name")

        en:subscribe("power.*", function(topic, data, src) earthGot[#earthGot + 1] = { topic, data, src } end)
        vn:publish("power.venus", { stored = 99 }, { retain = true })
        t.ok(kit.waitFor(function() return #earthGot > 0 end, 30), "flooded publish reached EARTH")
        t.eq(earthGot[1][1], "power.venus")
        t.eq(earthGot[1][2].stored, 99)
        t.eq(earthGot[1][3], "VENUS")
        t.ok(kit.waitFor(function() return mars.topics["power.venus"] ~= nil end, 10))
        t.eq(mars.topics["power.venus"].retained.data.stored, 99, "retained at MARS")
        mn:subscribe("power.venus", function(topic, data) marsGot[#marsGot + 1] = data end)
        t.ok(kit.waitFor(function() return #marsGot > 0 end, 10), "retained delivered to new local subscriber")
        t.eq(marsGot[1].stored, 99)
        sleep(5)
        t.eq(#earthGot, 1, "flood delivered twice")

        local realms = earth:realms()
        t.eq(#realms, 3)
        for _, r in ipairs(realms) do t.ok(r.reachable, r.realm .. " unreachable") end

        local st, serr = en:request("MARS", "zn.admin", { op = "status" }, 20)
        t.eq(serr, "MARS")
        t.eq(st and st.realm, "MARS")
        t.eq(st and st.ok, true)
        local denied = mn:request("VENUS", "zn.admin", { op = "status" }, 20)
        t.eq(denied and denied.err, "denied")
    end, 20000)
end)

t.case("cipher mismatch and protocol mismatch keep a neighbor down", function()
    fs.delete("/.zelnet")
    kit.reset()
    local earth, en = server(1, "EARTH", "main", { "left" }, { cipher = hwCipher("k1") })
    local mars, mn = server(2, "MARS", "satellite", { "right" }, { cipher = hwCipher("k2") })
    kit.connect(en, "left", mn, "right")
    kit.runAll({ en, mn }, function()
        sleep(45)
        t.ok(not earth.bb:reachable("MARS"), "mismatched neighbor used")
        local nb = earth:status().neighbors
        t.eq(#nb, 1)
        t.eq(nb[1].up, false)
        t.eq(nb[1].problem, "cipher items differ")
        local found = false
        for _, w in ipairs(earth:status().warnings) do
            if w:find("cipher items differ") then found = true end
        end
        t.ok(found, "warning shown")
        local d = { realm = "PLUTO", id = 9, main = false, ver = 2, prog = "9.0.0", seq = 1, fp = earth.bb.fp }
        d.mac = seal.helloMac(BKEY, d)
        en.inq.push({ f = frame.make(en.cfg.netId, "h", 9, nil, d), link = "modem:left", dist = 3 })
        en:wake()
        sleep(2)
        t.eq(earth.bb.neighbors["radio:PLUTO"].up, false)
        t.eq(earth.bb.neighbors["radio:PLUTO"].problem, "protocol 2")
        local forged = { realm = "VENUS", id = 8, main = false, ver = 1, seq = 1, fp = earth.bb.fp, mac = string.rep("a", 64) }
        en.inq.push({ f = frame.make(en.cfg.netId, "h", 8, nil, forged), link = "modem:left", dist = 3 })
        en:wake()
        sleep(2)
        t.eq(earth.bb.neighbors["radio:VENUS"], nil, "forged hello accepted")
    end, 2000)
end)

local function fakeBridgeModule()
    local mod = { channels = {}, objects = {} }
    function mod.new(bcfg, ctx)
        local obj = { peer = bcfg.peer, realm = ctx.cfg.realm, out = {}, sent = 0, received = 0, trips = 0 }
        mod.objects[obj.realm .. ">" .. obj.peer] = obj
        function obj:enqueue(wire)
            local text = codec.encode(wire)
            if not text then return nil, "encode" end
            self.out[#self.out + 1] = text
            return true
        end
        function obj:run(onReceive)
            while true do
                sleep(1)
                if #self.out > 0 then
                    local batch = self.out
                    self.out = {}
                    self.trips = self.trips + 1
                    self.sent = self.sent + #batch
                    local peerObj = mod.objects[self.peer .. ">" .. self.realm]
                    if peerObj then peerObj.inbox = peerObj.inbox or {} for _, s in ipairs(batch) do table.insert(peerObj.inbox, s) end end
                end
                if self.inbox and #self.inbox > 0 then
                    local frames = {}
                    for _, s in ipairs(self.inbox) do frames[#frames + 1] = codec.decode(s) end
                    self.inbox = {}
                    self.received = self.received + #frames
                    onReceive(frames)
                end
            end
        end
        function obj:status()
            return { peer = self.peer, state = "idle", queued = #self.out, sent = self.sent, received = self.received, trips = self.trips }
        end
        return obj
    end
    return mod
end

t.case("bridge neighbors carry hellos, adverts and packets with metric 4", function()
    fs.delete("/.zelnet")
    kit.reset()
    local mod = fakeBridgeModule()
    local earth, en = server(1, "EARTH", "main", {}, { bridgeModule = mod, cfg = { bridges = { { peer = "pluto" } } } })
    local pluto, pn = server(4, "PLUTO", "satellite", {}, { bridgeModule = mod, cfg = { bridges = { { peer = "EARTH" } } } })
    kit.runAll({ en, pn }, function()
        pn:listen("echo", function(msg) pn:reply(msg, { pong = msg.data }) end)
        t.ok(kit.waitFor(function() return earth.bb:reachable("PLUTO") and pluto.bb:reachable("EARTH") end, 120), "bridge route")
        t.eq(earth.bb:metricTo("PLUTO"), 4)
        local r = earth:status().routes[1]
        t.eq(r.kind, "bridge")
        local body = en:request("PLUTO", "echo", 5, 30)
        t.eq(body and body.pong, 5)
        local bs = earth:status().bridges
        t.eq(#bs, 1)
        t.eq(bs[1].peer, "PLUTO")
        t.eq(bs[1].up, true)
        t.ok(bs[1].trips >= 1)
        t.eq(#earth:bridges(), 1)
        t.ok(earth:removeBridge("pluto"))
        t.eq(#earth:bridges(), 0)
        t.ok(kit.waitFor(function() return not earth.bb:reachable("PLUTO") end, 10), "route removed with the bridge")
        local ok, err = earth:addBridge({ peer = "earth" })
        t.eq(ok, nil)
        t.eq(err, "peer is this realm")
        t.ok(earth:addBridge({ peer = "pluto" }))
        t.ok(kit.waitFor(function() return earth.bb:reachable("PLUTO") end, 120), "bridge re-added")
        t.eq(#earth.cfg.bridges, 1)
    end, 20000)
end)

t.case("ttl expiry while forwarding returns zn.err ttl", function()
    fs.delete("/.zelnet")
    kit.reset()
    local earth, en = server(1, "EARTH", "main", { "left" })
    local mars, mn = server(2, "MARS", "satellite", { "right", "back" })
    local venus, vn = server(3, "VENUS", "satellite", { "front" })
    kit.connect(en, "left", mn, "right")
    kit.connect(mn, "back", vn, "front")
    kit.runAll({ en, mn, vn }, function()
        t.ok(kit.waitFor(function() return earth.bb:reachable("VENUS") end, 90))
        local sw = cipher.software(BKEY)
        local pending = { }
        local pkt = backbonePacket("EARTH", "VENUS", "echo", {}, { ttl = 1, rq = true })
        en.pending[pkt.id] = pending
        pending.cb = function(body, err) pending.err = err end
        local w = assert(seal.sealBackbone(sw, BKEY, pkt, "EARTH"))
        mn.inq.push({ f = frame.make(mn.cfg.netId, "x", 1, 2, w), link = "modem:right", dist = 5 })
        mn:wake()
        t.ok(kit.waitFor(function() return pending.err ~= nil end, 20), "ttl error came back")
        t.eq(pending.err, "ttl")
    end, 2000)
end)

t.case("network update: offer, chunk download, install and device offers", function()
    fs.delete("/.zelnet")
    fs.delete("/zelnet")
    fs.delete("/zelnet.new")
    kit.reset()
    local earth, en = server(1, "EARTH", "main", { "left" }, { cfg = { updateReboot = false } })
    local mars, mn = server(2, "MARS", "satellite", { "right", "back" }, { cfg = { updateReboot = false } })
    kit.connect(en, "left", mn, "right")
    local dn, dcfg = kit.newDevice(mars, "endpoint", "probe", 42, { "front" })
    kit.connect(mn, "back", dn, "front")
    local lines = {}
    for i = 1, 1500 do lines[#lines + 1] = "v" .. (i % 50) .. " = " .. i end
    local text = table.concat(lines, "\n") .. "\nreturn 1\n"
    local offers = {}
    local installed = {}
    mars:on("update_installed", function(v) installed[#installed + 1] = v end)
    kit.runAll({ en, mn, dn }, function()
        dn:listen("zn.update", function(msg) offers[#offers + 1] = msg end)
        t.ok(kit.waitFor(function() return earth.bb:reachable("MARS") and dn:isConnected() end, 90), "network up")
        local ok, err = earth:pushUpdate("this is not lua (" .. string.rep(" x", 60), "1.0.1")
        t.eq(ok, nil)
        t.ok(err:find("does not compile"))
        t.eq(select(2, mars:pushUpdate(text, "1.0.1")), "only Main can update the network")
        local pok, perr = earth:pushUpdate(text, "1.0.1")
        t.eq(perr, nil)
        t.eq(pok, true)
        t.ok(kit.waitFor(function() return #installed > 0 end, 300), "satellite installed the update")
        t.eq(installed[1], "1.0.1")
        t.eq(util.readFile("/zelnet"), text)
        t.eq(mars.update.sha, crypto.sha256(text))
        t.ok(kit.waitFor(function() return #offers > 0 end, 30), "device got an offer")
        local o = offers[#offers].data
        t.eq(o.op, "offer")
        t.eq(o.version, "1.0.1")
        t.eq(o.size, #text)
        t.eq(o.chunks, 3)
        t.eq(o.mac, crypto.mac(dcfg.deviceKey, "zn.update|1.0.1|" .. #text .. "|" .. o.sha))
        local c2 = dn:request("MARS", "zn.update", { op = "chunk", sha = o.sha, i = 2 }, 20)
        t.eq(c2 and c2.ok, true)
        t.eq(c2 and c2.data, text:sub(6001, 12000))
        local bad = dn:request("MARS", "zn.update", { op = "chunk", sha = string.rep("0", 64), i = 1 }, 20)
        t.eq(bad and bad.err, "no_update")
        local forged = { op = "offer", version = "6.6.6", size = 10, sha = string.rep("1", 64), chunks = 1, mac = string.rep("2", 64) }
        mars:onUpdateMsg({ src = "EARTH", data = forged })
        local warned = false
        for _, w in ipairs(mars:status().warnings) do
            if w:find("bad signature") then warned = true end
        end
        t.ok(warned, "forged offer accepted")
    end, 20000)
end)

t.case("device to device across realms: requests, names, errors and pub/sub", function()
    fs.delete("/.zelnet")
    kit.reset()
    local earth, en = server(1, "EARTH", "main", { "left", "top" })
    local mars, mn = server(2, "MARS", "satellite", { "right", "back" })
    kit.connect(en, "left", mn, "right")
    local da = kit.newDevice(earth, "client", "alice", 42, { "bottom" })
    local db = kit.newDevice(mars, "endpoint", "probe", 43, { "front" })
    kit.connect(en, "top", da, "bottom")
    kit.connect(mn, "back", db, "front")
    kit.runAll({ en, mn, da, db }, function()
        db:listen("echo", function(msg) db:reply(msg, { back = msg.data, src = msg.src }) end)
        t.ok(kit.waitFor(function() return earth.bb:reachable("MARS") and da:isConnected() and db:isConnected() end, 120), "network up")
        local body, src = da:request("MARS:43", "echo", "hi", 40)
        t.eq(src, "MARS:43")
        t.eq(body and body.back, "hi")
        t.eq(body and body.src, "EARTH:42")
        t.eq(db:register("powermon"), true)
        body = da:request("mars:powermon", "echo", "named", 40)
        t.eq(body and body.back, "named")
        t.eq(da:resolve("MARS:powermon"), "MARS:43")
        local _, err = da:request("MARS:ghost", "echo", 1, 40)
        t.eq(err, "unknown_node")
        local _, err2 = da:request("NOWHERE:1", "echo", 1, 40)
        t.eq(err2, "no_route")
        local got
        da:subscribe("sensor.*", function(topic, data, from) got = { topic, data, from } end)
        sleep(2)
        db:publish("sensor.temp", { c = 21 }, { retain = true })
        t.ok(kit.waitFor(function() return got ~= nil end, 30), "publish crossed realms")
        t.eq(got[1], "sensor.temp")
        t.eq(got[2].c, 21)
        t.eq(got[3], "MARS:43")
        t.eq(earth.topics["sensor.temp"].retained.from, "MARS:43")
        t.ok(da:ping("MARS:43", 40) ~= nil, "cross realm ping")
        t.ok(mars.counters.routedDown >= 3)
        t.ok(earth.bb.counters.delivered >= 3)
    end, 20000)
end)

t.case("triangle: floods arrive once per realm and routes go around a cut link", function()
    fs.delete("/.zelnet")
    kit.reset()
    local earth, en = server(1, "EARTH", "main", { "left" })
    local mars, mn = server(2, "MARS", "satellite", { "right" })
    local venus, vn = server(3, "VENUS", "satellite", { "front" })
    kit.connect(en, "left", mn, "right")
    kit.connect(en, "left", vn, "front")
    kit.connect(mn, "right", vn, "front")
    local hits = { EARTH = 0, MARS = 0, VENUS = 0 }
    for realm, nd in pairs({ EARTH = en, MARS = mn, VENUS = vn }) do
        nd:listen("bcast", function() hits[realm] = hits[realm] + 1 end)
    end
    kit.runAll({ en, mn, vn }, function()
        mn:listen("echo", function(msg) mn:reply(msg, { ok = true }) end)
        t.ok(kit.waitFor(function()
            return earth.bb:metricTo("MARS") == 1 and earth.bb:metricTo("VENUS") == 1 and mars.bb:metricTo("VENUS") == 1
        end, 120), "full mesh")
        earth:broadcastRealms("bcast", { n = 1 })
        sleep(5)
        t.eq(hits.MARS, 1)
        t.eq(hits.VENUS, 1)
        t.eq(hits.EARTH, 0)
        kit.cutPair("left", "right", true)
        t.ok(kit.waitFor(function() return earth.bb:metricTo("MARS") == 2 end, 200), "rerouted through VENUS")
        local via
        for _, r in ipairs(earth:status().routes) do
            if r.realm == "MARS" then via = r.via end
        end
        t.eq(via, "VENUS")
        local body = en:request("MARS", "echo", 1, 40)
        t.eq(body and body.ok, true)
        t.ok(venus.bb.counters.forwarded >= 2)
        t.eq(earth.bb:routesFor("radio:VENUS").MARS, 16, "poisoned reverse towards the next hop")
        kit.cutPair("left", "right", false)
        t.ok(kit.waitFor(function() return earth.bb:metricTo("MARS") == 1 end, 200), "direct route back")
    end, 20000)
end)

t.case("replayed and older hellos are ignored", function()
    fs.delete("/.zelnet")
    kit.reset()
    local earth, en = server(1, "EARTH", "main", { "left" })
    kit.runAll({ en }, function()
        local d = { realm = "PLUTO", id = 9, main = false, ver = 1, prog = "1.0.0", seq = 100, fp = earth.bb.fp }
        d.mac = seal.helloMac(BKEY, d)
        local function push(data)
            en.inq.push({ f = frame.make(en.cfg.netId, "h", 9, nil, util.deepCopy(data)), link = "modem:left", dist = 3 })
            en:wake()
            sleep(1)
        end
        push(d)
        t.eq(earth.bb.neighbors["radio:PLUTO"].up, true)
        local hellos = earth.bb.counters.hellos
        push(d)
        local old = { realm = "PLUTO", id = 9, main = false, ver = 1, prog = "1.0.0", seq = 50, fp = earth.bb.fp }
        old.mac = seal.helloMac(BKEY, old)
        push(old)
        t.eq(earth.bb.counters.hellos, hellos, "replayed hello accepted")
        local spoofId = util.deepCopy(d)
        spoofId.seq = 101
        spoofId.mac = seal.helloMac(BKEY, spoofId)
        en.inq.push({ f = frame.make(en.cfg.netId, "h", 10, nil, spoofId), link = "modem:left", dist = 3 })
        en:wake()
        sleep(1)
        t.eq(earth.bb.counters.hellos, hellos, "hello relayed by another computer accepted")
        local names = {}
        for _, r in ipairs(earth:realms()) do names[#names + 1] = r.realm end
        t.ok(util.contains(names, "PLUTO"), "neighbor realm missing from realms()")
    end, 2000)
end)

local function bridgeWorld()
    local w = { drives = {}, tess = {}, order = {}, nextDisk = 100 }
    local function filesUnder(mount)
        local prefix = "/" .. mount .. "/"
        local out = {}
        for k, v in pairs(env.files()) do
            if k:sub(1, #prefix) == prefix then out[k:sub(#prefix + 1)] = v end
        end
        return out
    end
    local function writeFiles(mount, files)
        fs.makeDir("/" .. mount)
        for name, data in pairs(files) do
            local h = fs.open("/" .. mount .. "/" .. name, "w")
            h.write(data)
            h.close()
        end
    end
    function w.drive(name, mount)
        local d = { name = name, mount = mount }
        w.drives[name] = d
        env.setPeripheral(name, { type = "drive", methods = {
            isDiskPresent = function() return d.disk ~= nil end,
            getMountPath = function() if d.disk then return d.mount end return nil end,
            hasData = function() return d.disk ~= nil end,
            getDiskID = function() return d.disk and d.disk.id end,
            getDiskLabel = function() return d.disk and d.disk.label end,
            setDiskLabel = function(l) if d.disk then d.disk.label = l end end,
            ejectDisk = function() end,
        } })
    end
    function w.insert(driveName)
        w.nextDisk = w.nextDisk + 1
        w.drives[driveName].disk = { id = w.nextDisk }
        fs.makeDir("/" .. w.drives[driveName].mount)
    end
    function w.tesseract(name, freq, dir, driveName)
        local tt = { name = name, freq = freq, dir = dir, drive = w.drives[driveName] }
        w.tess[name] = tt
        w.order[#w.order + 1] = name
        env.setPeripheral(name, { type = "cofh_thermalexpansion_tesseract", methods = {
            pullItem = function(pdir)
                sleep(0.05)
                if pdir ~= tt.dir or not tt.drive.disk then return 0 end
                for _, other in ipairs(w.order) do
                    local o = w.tess[other]
                    if o ~= tt and o.freq == tt.freq and not o.drive.disk then
                        local files = filesUnder(tt.drive.mount)
                        pcall(fs.delete, "/" .. tt.drive.mount)
                        o.drive.disk = tt.drive.disk
                        tt.drive.disk = nil
                        writeFiles(o.drive.mount, files)
                        return 1
                    end
                end
                return 0
            end,
            pushItem = function() return 0 end,
            getFrequency = function() return tt.freq end,
        } })
    end
    function w.clear()
        for name in pairs(w.drives) do env.setPeripheral(name, nil) end
        for name in pairs(w.tess) do env.setPeripheral(name, nil) end
    end
    return w
end

t.case("the real bridge module carries backbone traffic between two servers", function()
    fs.delete("/.zelnet")
    for _, m in ipairs({ "/disk", "/disk2", "/disk3", "/disk4" }) do fs.delete(m) end
    kit.reset()
    local w = bridgeWorld()
    w.drive("drive_0", "disk")
    w.drive("drive_1", "disk2")
    w.drive("drive_2", "disk3")
    w.drive("drive_3", "disk4")
    w.tesseract("tesseract_0", 1, "east", "drive_0")
    w.tesseract("tesseract_1", 2, "up", "drive_1")
    w.tesseract("tesseract_2", 2, "west", "drive_2")
    w.tesseract("tesseract_3", 1, "down", "drive_3")
    w.insert("drive_0")
    w.insert("drive_2")
    local eb = { peer = "MARS", sendTess = "tesseract_0", sendDrive = "drive_0", sendDir = "east",
        recvTess = "tesseract_1", recvDrive = "drive_1", recvDir = "up", settle = 0.3, poll = 0.5 }
    local mb = { peer = "EARTH", sendTess = "tesseract_2", sendDrive = "drive_2", sendDir = "west",
        recvTess = "tesseract_3", recvDrive = "drive_3", recvDir = "down", settle = 0.3, poll = 0.5 }
    local earth, en = server(1, "EARTH", "main", {}, { cfg = { bridges = { eb } } })
    local mars, mn = server(2, "MARS", "satellite", {}, { cfg = { bridges = { mb } } })
    local ok, perr = pcall(function()
        kit.runAll({ en, mn }, function()
            mn:listen("echo", function(msg) mn:reply(msg, { pong = msg.data }) end)
            t.ok(kit.waitFor(function() return earth.bb:reachable("MARS") and mars.bb:reachable("EARTH") end, 300), "bridge route up")
            t.eq(earth.bb:metricTo("MARS"), 4)
            local body = en:request("MARS", "echo", "through the tesseract", 60)
            t.eq(body and body.pong, "through the tesseract")
            t.ok(kit.waitFor(function() return mars.dir.synced and earth.dir.realms.MARS ~= nil end, 120), "satellite registered over the bridge")
            t.eq(mars:claimUser("zed"), true)
            t.eq(earth:userHome("zed"), "MARS")
            local bs = earth:status().bridges[1]
            t.eq(bs.peer, "MARS")
            t.eq(bs.up, true)
            t.ok(bs.trips >= 2, "trips")
            t.ok(bs.sent >= 3, "sent")
            t.eq(bs.fault, nil)
            local nb = earth:status().neighbors[1]
            t.eq(nb.kind, "bridge")
            t.eq(nb.realm, "MARS")
        end, 20000)
    end)
    w.clear()
    if not ok then error(perr, 0) end
end)

t.finish()
