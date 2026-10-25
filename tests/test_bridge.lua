package.path = "./?.lua;" .. package.path
local env = require("tests.fakecc").install({ id = 7 })
local need = require("tools.devload").make(".")
local bridge = need("bridge")
local codec = need("codec")
local crypto = need("crypto")
local config = need("config")
local util = need("util")
local t = require("tests.tiny")

local VALID = { north = true, south = true, east = true, west = true, up = true, down = true }

local function wipe(paths)
    for _, p in ipairs(paths) do pcall(fs.delete, p) end
end

local function newWorld()
    local w = { drives = {}, tess = {}, order = {}, nextDisk = 100, moves = 0, names = {} }

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
        local d = { name = name, mount = mount, disk = nil }
        w.drives[name] = d
        w.names[#w.names + 1] = name
        env.setPeripheral(name, { type = "drive", methods = {
            isDiskPresent = function() return d.disk ~= nil end,
            getMountPath = function() if d.disk and d.disk.floppy then return d.mount end return nil end,
            hasData = function() return d.disk ~= nil and d.disk.floppy end,
            getDiskID = function() return d.disk and d.disk.id end,
            getDiskLabel = function() return d.disk and d.disk.label end,
            setDiskLabel = function(l) if d.disk then d.disk.label = l end end,
            ejectDisk = function() end,
        } })
        return d
    end

    function w.insert(driveName, files, opts)
        local d = w.drives[driveName]
        assert(not d.disk, "drive already holds a disk")
        w.nextDisk = w.nextDisk + 1
        d.disk = { id = w.nextDisk, floppy = not (opts and opts.music) }
        if d.disk.floppy then writeFiles(d.mount, files or {}) end
        return d.disk.id
    end

    function w.remove(driveName)
        local d = w.drives[driveName]
        local files = filesUnder(d.mount)
        pcall(fs.delete, "/" .. d.mount)
        local disk = d.disk
        d.disk = nil
        return disk, files
    end

    function w.files(driveName)
        return filesUnder(w.drives[driveName].mount)
    end

    function w.move(src, dst)
        local files = filesUnder(src.mount)
        pcall(fs.delete, "/" .. src.mount)
        if w.corrupt and files[bridge.FILE] then
            files[bridge.FILE] = w.corrupt(files[bridge.FILE])
            if not w.corruptAlways then w.corrupt = nil end
        end
        dst.disk = src.disk
        src.disk = nil
        if dst.disk.floppy then writeFiles(dst.mount, files) end
        w.moves = w.moves + 1
    end

    function w.route(from)
        for _, name in ipairs(w.order) do
            local o = w.tess[name]
            if o ~= from and o.freq == from.freq then
                for _, dir in ipairs(bridge.DIRECTIONS) do
                    local dst = o.adj[dir]
                    if dst and dst.kind == nil and not dst.disk then return dst end
                end
            end
        end
        return nil
    end

    function w.tesseract(name, freq, adj)
        local tt = { name = name, freq = freq, adj = {}, pulls = {} }
        for dir, driveName in pairs(adj) do
            if type(driveName) == "table" then tt.adj[dir] = driveName else tt.adj[dir] = w.drives[driveName] end
        end
        w.tess[name] = tt
        w.order[#w.order + 1] = name
        env.setPeripheral(name, { type = "cofh_thermalexpansion_tesseract", methods = {
            pullItem = function(dir, slot, amount)
                if not VALID[dir] then error("Invalid direction", 0) end
                tt.pulls[#tt.pulls + 1] = dir
                sleep(0.05)
                local src = tt.adj[dir]
                if not src then return 0 end
                if src.kind == "chest" then
                    if src.items > 0 then
                        src.items = src.items - 1
                        return 1
                    end
                    return 0
                end
                if not src.disk then return 0 end
                if (w.bounces or 0) > 0 then
                    w.bounces = w.bounces - 1
                    return 1
                end
                if w.bounceRate and w.rand() < w.bounceRate then return 1 end
                if w.lose then
                    w.lose = false
                    w.remove(src.name)
                    return 1
                end
                local dst = w.route(tt)
                if not dst then return 0 end
                w.move(src, dst)
                return 1
            end,
            pushItem = function() return 0 end,
            getFrequency = function() return tt.freq end,
            setFrequency = function(f) tt.freq = f return true end,
        } })
        return tt
    end

    function w.clear()
        for _, n in ipairs(w.names) do env.setPeripheral(n, nil) end
        for _, n in ipairs(w.order) do env.setPeripheral(n, nil) end
    end

    return w
end

local function standardWorld(opts)
    opts = opts or {}
    wipe({ "/disk", "/disk2", "/disk3", "/disk4", "/earth", "/mars" })
    local w = newWorld()
    w.drive("drive_0", "disk")
    w.drive("drive_1", "disk2")
    w.drive("drive_2", "disk3")
    w.drive("drive_3", "disk4")
    w.tesseract("tesseract_0", 1, { east = "drive_0", south = opts.chest })
    w.tesseract("tesseract_1", 2, { up = "drive_1" })
    w.tesseract("tesseract_2", 2, { west = "drive_2" })
    w.tesseract("tesseract_3", 1, { down = "drive_3" })
    if not opts.noDisks then
        w.insert("drive_0")
        w.insert("drive_2")
    end
    return w
end

local function makeSide(realm, bcfg, path)
    local cfg = config.newServer({ realm = realm, network = "Test" })
    cfg.bridges = { bcfg }
    local side = { cfg = cfg, bcfg = bcfg, log = util.newLogger(300), got = {}, batches = 0, path = path }
    side.ctx = { cfg = cfg, log = side.log, configPath = path }
    side.b = bridge.new(bcfg, side.ctx)
    side.onReceive = function(frames)
        side.batches = side.batches + 1
        for _, f in ipairs(frames) do side.got[#side.got + 1] = f end
    end
    return side
end

local function earthCfg(over)
    local c = { peer = "MARS", sendTess = "tesseract_0", sendDrive = "drive_0", sendDir = "east",
        recvTess = "tesseract_1", recvDrive = "drive_1", recvDir = "up", settle = 0.3, poll = 0.5 }
    for k, v in pairs(over or {}) do c[k] = v end
    return c
end

local function marsCfg(over)
    local c = { peer = "EARTH", sendTess = "tesseract_2", sendDrive = "drive_2", sendDir = "west",
        recvTess = "tesseract_3", recvDrive = "drive_3", recvDir = "down", settle = 0.3, poll = 0.5 }
    for k, v in pairs(over or {}) do c[k] = v end
    return c
end

local function wire(i, src, pad)
    return { v = 1, id = "w" .. tostring(i), src = src or "EARTH:5", dst = "MARS:9", port = "test", ttl = 24,
        via = "EARTH", ct = string.rep("Q", pad or 40) .. tostring(i), mac = string.rep("a", 64) }
end

local function runWorld(sides, main, maxSeconds)
    env.run(function()
        local tasks = {}
        for _, s in ipairs(sides) do
            tasks[#tasks + 1] = { co = coroutine.create(function() s.b:run(s.onReceive) end) }
        end
        local mainTask = { co = coroutine.create(main) }
        tasks[#tasks + 1] = mainTask
        local ev = {}
        local first = true
        while true do
            for _, task in ipairs(tasks) do
                if coroutine.status(task.co) == "suspended" and (first or task.filter == nil or task.filter == ev[1]) then
                    local ok, f = coroutine.resume(task.co, unpack(ev))
                    if not ok then error(f, 0) end
                    task.filter = f
                end
                if coroutine.status(mainTask.co) == "dead" then
                    for _, s in ipairs(sides) do s.b:stop() end
                    return
                end
            end
            first = false
            ev = { os.pullEventRaw() }
        end
    end, maxSeconds or 600)
end

local function waitFor(cond, limit)
    local t0 = os.clock()
    while not cond() do
        if os.clock() - t0 > limit then return false end
        sleep(0.25)
    end
    return true
end

local function logHas(side, text)
    for _, e in ipairs(side.log.items) do
        if e.text:find(text, 1, true) then return true end
    end
    return false
end

t.case("batch format round trip and checksum", function()
    local frames = { wire(1), wire(2), { v = 1, id = "x", nested = { a = "b\n\"q\"" } } }
    local text, sum = bridge.packBatch("EARTH", "MARS", 7, frames)
    t.ok(text, "pack failed")
    local whole = codec.decode(text)
    t.eq(type(whole), "table", "file is not codec text")
    t.eq(whole.zb, 1)
    t.eq(whole.from, "EARTH")
    t.eq(whole.to, "MARS")
    t.eq(whole.seq, 7)
    t.eq(whole.sum, sum)
    t.eq(#whole.frames, 3)
    local texts = {}
    for i, f in ipairs(frames) do texts[i] = codec.encode(f) end
    t.eq(sum, crypto.adler32("{" .. table.concat(texts, ",") .. ",}"))
    local b, err = bridge.decodeBatch(text)
    t.ok(b, err)
    t.eq(b.seq, 7)
    t.eq(#b.frames, 3)
    t.eq(b.frames[2].id, "w2")
    t.eq(b.frames[3].nested.a, "b\n\"q\"")
    local at = text:find("QQQQ", 1, true)
    local bad = text:sub(1, at - 1) .. "R" .. text:sub(at + 1)
    local nb, nerr = bridge.decodeBatch(bad)
    t.eq(nb, nil)
    t.eq(nerr, "checksum mismatch")
    t.eq(select(2, bridge.decodeBatch(text:sub(1, 50))), "unreadable file")
    t.eq(select(2, bridge.decodeBatch("")), "empty file")
    t.eq(select(2, bridge.decodeBatch("{zb=9,from=\"A\",to=\"B\",sum=1,frames={},}")), "unknown format")
end)

t.case("contract literal file written by codec.encode is accepted", function()
    local frames = { "one", "two" }
    local literal = codec.encode({ zb = 1, from = "MARS", to = "EARTH", seq = 3, frames = frames, sum = crypto.adler32(codec.encode(frames)) })
    local b, err = bridge.decodeBatch(literal)
    t.ok(b, err)
    t.eq(b.seq, 3)
    t.eq(b.from, "MARS")
end)

t.case("findGear finds drives and tesseracts by methods", function()
    local w = standardWorld()
    env.setPeripheral("container_chest_0", { type = "container_chest", methods = { pullItem = function() return 0 end, getInventorySize = function() return 27 end } })
    env.setPeripheral("monitor_0", { type = "monitor", methods = { getSize = function() return 7, 5 end } })
    env.setPeripheral("odd_block_0", { type = "odd_block", methods = { pullItem = function() return 0 end, getFrequency = function() return 9 end } })
    local g = bridge.findGear()
    t.eq(table.concat(g.drives, ","), "drive_0,drive_1,drive_2,drive_3")
    t.eq(table.concat(g.tesseracts, ","), "odd_block_0,tesseract_0,tesseract_1,tesseract_2,tesseract_3")
    local g2 = bridge.findGear({ "drive_1", tesseract_3 = true })
    t.eq(table.concat(g2.drives, ","), "drive_0,drive_2,drive_3")
    t.eq(#g2.tesseracts, 4)
    env.setPeripheral("container_chest_0", nil)
    env.setPeripheral("monitor_0", nil)
    env.setPeripheral("odd_block_0", nil)
    w.clear()
end)

t.case("probe finds the direction and moves the floppy", function()
    local w = standardWorld()
    local dir, err, dir2, err2
    env.run(function()
        dir, err = bridge.probe("tesseract_0", "drive_0", 0.1)
        dir2, err2 = bridge.probe("tesseract_1", "drive_1", 0.1)
    end, 60)
    t.eq(dir, "east", err)
    t.eq(w.drives.drive_0.disk, nil)
    t.ok(w.drives.drive_3.disk ~= nil, "floppy did not arrive on the other side")
    t.eq(dir2, nil)
    t.ok(tostring(err2):find("put a blank pocket computer", 1, true), tostring(err2))
    local d3, e3
    env.run(function() d3, e3 = bridge.probe("nothing_here", "drive_1") end, 10)
    t.eq(d3, nil)
    t.eq(e3, "tesseract not found")
    w.clear()
end)

t.case("probe reports a floppy that cannot leave", function()
    local w = standardWorld()
    w.insert("drive_3")
    local dir, err
    env.run(function() dir, err = bridge.probe("tesseract_0", "drive_0", 0.1) end, 60)
    t.eq(dir, nil)
    t.ok(tostring(err):find("did not leave", 1, true), tostring(err))
    t.ok(w.drives.drive_0.disk ~= nil)
    w.clear()
end)

t.case("check reports setup problems", function()
    local w = standardWorld()
    local ok, problems = bridge.check(earthCfg(), { realm = "EARTH" })
    t.ok(ok, table.concat(problems or {}, "; "))
    ok, problems = bridge.check(earthCfg({ recvTess = "tesseract_0", recvDrive = "drive_9", sendDir = "sideways", peer = "earth" }), { realm = "EARTH" })
    t.eq(ok, false)
    local all = table.concat(problems, "; ")
    t.ok(all:find("two different blocks", 1, true), all)
    t.ok(all:find("drive_9 not found", 1, true), all)
    t.ok(all:find("send direction must be one of", 1, true), all)
    t.ok(all:find("own realm", 1, true), all)
    w.tess.tesseract_1.freq = 1
    ok, problems = bridge.check(earthCfg())
    t.eq(ok, false)
    t.ok(table.concat(problems, "; "):find("share frequency 1", 1, true), table.concat(problems, "; "))
    ok = bridge.check(earthCfg(), { quick = true })
    t.ok(ok, "quick check should skip the frequency test")
    w.tess.tesseract_1.freq = 2
    w.remove("drive_0")
    ok, problems = bridge.check(earthCfg(), { disks = true })
    t.eq(ok, false)
    t.ok(problems[1]:find("nothing in the send drive", 1, true), problems[1])
    local noTess = earthCfg({ maxBatch = 1500000 })
    noTess.sendTess = nil
    ok, problems = bridge.check(noTess)
    t.eq(ok, false)
    all = table.concat(problems, "; ")
    t.ok(all:find("send tesseract not chosen", 1, true), all)
    t.ok(all:find("maxBatch", 1, true), all)
    w.clear()
end)

t.case("enqueue limits", function()
    local w = standardWorld()
    local s = makeSide("EARTH", earthCfg({ maxBatch = 4096 }), "/earth/config")
    t.eq(select(2, s.b:enqueue("nope")), "bad packet")
    t.eq(select(2, s.b:enqueue(wire(1, nil, 5000))), "too_large")
    t.ok(s.b:enqueue(wire(2)))
    for i = 3, bridge.QUEUE_MAX + 1 do s.b:enqueue(wire(i)) end
    t.eq(s.b:status().queued, bridge.QUEUE_MAX)
    local ok, err = s.b:enqueue(wire(9999))
    t.eq(ok, nil)
    t.eq(err, "queue full")
    w.clear()
end)

t.case("unconfigured and missing gear states", function()
    local w = standardWorld()
    local s = makeSide("EARTH", earthCfg({ sendTess = "" }), "/earth/config")
    env.run(function() s.b:step() end, 10)
    t.eq(s.b:status().state, "unconfigured")
    t.ok(s.b:status().lastError:find("send tesseract not set", 1, true), s.b:status().lastError)
    t.eq(select(2, s.b:enqueue(wire(1))), "bridge unconfigured")
    local s2 = makeSide("EARTH", earthCfg({ recvTess = "tesseract_77" }), "/earth/config")
    env.run(function() s2.b:step() end, 10)
    t.eq(s2.b:status().state, "fault")
    t.ok(s2.b:status().fault:find("tesseract_77 not found", 1, true))
    w.clear()
end)

t.case("batch of several packets goes in one trip and the floppy returns", function()
    local w = standardWorld()
    local earth = makeSide("EARTH", earthCfg(), "/earth/config")
    local mars = makeSide("MARS", marsCfg(), "/mars/config")
    for i = 1, 6 do t.ok(earth.b:enqueue(wire(i))) end
    local returned
    runWorld({ earth, mars }, function()
        t.ok(waitFor(function() return #mars.got == 6 end, 60), "frames not delivered")
        returned = waitFor(function() return earth.b:status().trips == 1 and earth.b:status().state == "idle" end, 60)
    end)
    t.ok(returned, "floppy did not come back")
    t.eq(mars.batches, 1, "expected exactly one disk trip")
    for i = 1, 6 do t.eq(mars.got[i].id, "w" .. i) end
    local st = earth.b:status()
    t.eq(st.sent, 6)
    t.eq(st.queued, 0)
    t.eq(st.inflight, 0)
    t.eq(st.errors, 0, tostring(st.lastError))
    t.ok(st.lastTrip and st.lastTrip > 0, "lastTrip not recorded")
    t.eq(st.sendDisk, true)
    t.ok(w.drives.drive_0.disk ~= nil, "floppy not back in the send drive")
    t.eq(w.files("drive_0")[bridge.FILE], nil, "batch file left on the returned floppy")
    t.eq(w.drives.drive_3.disk, nil, "receive drive should be empty")
    t.eq(w.drives.drive_0.disk.label, "ZelNet EARTH>MARS")
    local ms = mars.b:status()
    t.eq(ms.received, 6)
    t.eq(ms.batchesIn, 1)
    t.eq(ms.errors, 0, tostring(ms.lastError))
    w.clear()
end)

t.case("both directions at once including the return trip", function()
    local w = standardWorld()
    local earth = makeSide("EARTH", earthCfg(), "/earth/config")
    local mars = makeSide("MARS", marsCfg(), "/mars/config")
    for i = 1, 2 do earth.b:enqueue(wire(i)) end
    for i = 1, 3 do mars.b:enqueue(wire(100 + i, "MARS:9")) end
    runWorld({ earth, mars }, function()
        t.ok(waitFor(function() return #mars.got == 2 and #earth.got == 3 end, 60), "frames not delivered")
        t.ok(waitFor(function() return earth.b:status().trips == 1 and mars.b:status().trips == 1 end, 60), "floppies did not return")
        sleep(1)
        mars.b:enqueue(wire(200, "MARS:9"))
        t.ok(waitFor(function() return #earth.got == 4 and mars.b:status().trips == 2 end, 60), "second trip failed")
    end)
    t.eq(earth.got[1].id, "w101")
    t.eq(earth.got[4].id, "w200")
    t.ok(w.drives.drive_0.disk and w.drives.drive_2.disk, "each send drive should hold its floppy again")
    t.eq(w.drives.drive_1.disk, nil)
    t.eq(w.drives.drive_3.disk, nil)
    t.eq(mars.b:status().sent, 4)
    t.eq(earth.b:status().received, 4)
    w.clear()
end)

t.case("maxBatch splits a large queue over several trips", function()
    local w = standardWorld()
    local earth = makeSide("EARTH", earthCfg({ maxBatch = 4096 }), "/earth/config")
    local mars = makeSide("MARS", marsCfg(), "/mars/config")
    for i = 1, 8 do t.ok(earth.b:enqueue(wire(i, nil, 1500))) end
    runWorld({ earth, mars }, function()
        t.ok(waitFor(function() return #mars.got == 8 and earth.b:status().state == "idle" end, 120), "not all delivered")
    end)
    for i = 1, 8 do t.eq(mars.got[i].id, "w" .. i) end
    t.eq(mars.batches, 4)
    t.eq(earth.b:status().trips, 4)
    t.eq(earth.b:status().sent, 8)
    w.clear()
end)

t.case("a pocket computer carries a whole backlog in one trip", function()
    local w = standardWorld()
    local earth = makeSide("EARTH", earthCfg(), "/earth/config")
    local mars = makeSide("MARS", marsCfg(), "/mars/config")
    for i = 1, 1500 do t.ok(earth.b:enqueue(wire(i, nil, 500))) end
    runWorld({ earth, mars }, function()
        t.ok(waitFor(function() return #mars.got == 1500 and earth.b:status().state == "idle" end, 300), "not all delivered")
    end)
    t.eq(mars.batches, 1, "the whole backlog should fit one pocket computer trip")
    t.eq(mars.got[1500].id, "w1500")
    t.ok(earth.b:status().bytesOut > 700000, "batch was " .. tostring(earth.b:status().bytesOut) .. " bytes")
    w.clear()
end)

t.case("wrong directions are corrected and saved", function()
    local w = standardWorld()
    local earth = makeSide("EARTH", earthCfg({ sendDir = "north" }), "/earth/config")
    local mars = makeSide("MARS", marsCfg({ recvDir = "up" }), "/mars/config")
    for i = 1, 3 do earth.b:enqueue(wire(i)) end
    runWorld({ earth, mars }, function()
        t.ok(waitFor(function() return #mars.got == 3 and earth.b:status().trips == 1 end, 60), "not delivered")
    end)
    t.eq(earth.bcfg.sendDir, "east")
    t.eq(earth.cfg.bridges[1].sendDir, "east")
    t.eq(mars.bcfg.recvDir, "down")
    local saved = config.load("/earth/config")
    t.ok(saved, "earth config not saved")
    t.eq(saved.bridges[1].sendDir, "east")
    t.eq(saved.bridges[1].recvDir, "up")
    local msaved = config.load("/mars/config")
    t.ok(msaved, "mars config not saved")
    t.eq(msaved.bridges[1].recvDir, "down")
    t.eq(earth.b:status().corrections, 1)
    t.eq(mars.b:status().corrections, 1)
    t.ok(logHas(earth, "send direction corrected from north to east"), "no log line for the correction")
    local pulls = table.concat(w.tess.tesseract_0.pulls, ",")
    t.eq(pulls, "north,south,east")
    w.clear()
end)

t.case("occupied receive drive faults without breaking the config, then recovers", function()
    local w = standardWorld()
    w.insert("drive_3", { ["notes.txt"] = "player stuff" })
    local earth = makeSide("EARTH", earthCfg(), "/earth/config")
    local mars = makeSide("MARS", marsCfg(), "/mars/config")
    for i = 1, 2 do earth.b:enqueue(wire(i)) end
    local midEarth, midMars, midErrors
    runWorld({ earth, mars }, function()
        sleep(20)
        midEarth = earth.b:status()
        midMars = mars.b:status()
        midErrors = midEarth.errors
        local _, files = w.remove("drive_3")
        t.eq(files["notes.txt"], "player stuff")
        t.ok(waitFor(function() return #mars.got == 2 and earth.b:status().state == "idle" end, 120), "did not recover")
        t.ok(waitFor(function() return mars.b:status().state == "idle" end, 60), "mars did not recover")
    end)
    t.eq(midEarth.state, "fault")
    t.ok(midEarth.lastError:find("did not leave drive_0", 1, true), midEarth.lastError)
    t.eq(midEarth.queued, 2)
    t.eq(midEarth.sendDir, "east")
    t.eq(midMars.state, "fault")
    t.ok(midMars.lastError:find("cannot return the bridge disk", 1, true), midMars.lastError)
    t.ok(midErrors <= 3, "fault should be reported once per new problem, got " .. tostring(midErrors))
    t.eq(#mars.got, 2)
    t.eq(earth.bcfg.sendDir, "east")
    t.eq(earth.b:status().corrections, 0)
    t.eq(mars.b:status().corrections, 0)
    t.eq(fs.exists("/earth/config"), false, "config must not be rewritten when no direction worked")
    w.clear()
end)

t.case("corrupted file is rejected, the floppy returned and the batch resent", function()
    local w = standardWorld()
    w.corrupt = function(text)
        local at = text:find("QQQQ", 1, true)
        return text:sub(1, at - 1) .. "Z" .. text:sub(at + 1)
    end
    local earth = makeSide("EARTH", earthCfg(), "/earth/config")
    local mars = makeSide("MARS", marsCfg(), "/mars/config")
    for i = 1, 4 do earth.b:enqueue(wire(i)) end
    local rejectedSeen = false
    runWorld({ earth, mars }, function()
        rejectedSeen = waitFor(function() return mars.b:status().rejected == 1 end, 60)
        t.ok(waitFor(function() return #mars.got == 4 and earth.b:status().state == "idle" end, 120), "resend failed")
    end)
    t.ok(rejectedSeen, "mars did not reject the corrupted file")
    local ms = mars.b:status()
    t.eq(ms.rejected, 1)
    t.ok(ms.lastError:find("checksum mismatch", 1, true), ms.lastError)
    t.eq(mars.batches, 1)
    for i = 1, 4 do t.eq(mars.got[i].id, "w" .. i) end
    t.eq(mars.got[1].ct, string.rep("Q", 40) .. "1")
    local es = earth.b:status()
    t.eq(es.trips, 2)
    t.eq(es.sent, 4)
    t.eq(es.resent, 4)
    t.ok(es.lastError:find("undelivered", 1, true), es.lastError)
    t.eq(w.drives.drive_3.disk, nil)
    t.ok(w.drives.drive_0.disk ~= nil)
    w.clear()
end)

t.case("a batch that keeps failing is dropped after MAX_TRIES", function()
    local w = standardWorld()
    w.corruptAlways = true
    w.corrupt = function(text) return text:sub(1, #text - 5) end
    local earth = makeSide("EARTH", earthCfg(), "/earth/config")
    local mars = makeSide("MARS", marsCfg(), "/mars/config")
    earth.b:enqueue(wire(1))
    earth.b:enqueue(wire(2))
    runWorld({ earth, mars }, function()
        t.ok(waitFor(function() return earth.b:status().dropped == 2 end, 120), "batch not dropped")
        sleep(2)
    end)
    local es = earth.b:status()
    t.eq(es.trips, bridge.MAX_TRIES)
    t.eq(es.queued, 0)
    t.eq(es.sent, 0)
    t.ok(es.lastError:find("dropped 2 packet", 1, true), es.lastError)
    t.eq(#mars.got, 0)
    t.eq(mars.b:status().rejected, bridge.MAX_TRIES)
    w.clear()
end)

t.case("unsent batch found on the send floppy after a reboot is sent again", function()
    local w = standardWorld({ noDisks = true })
    local text = bridge.packBatch("EARTH", "MARS", 41, { wire(1), wire(2) })
    w.insert("drive_0", { [bridge.FILE] = text })
    w.insert("drive_2")
    local earth = makeSide("EARTH", earthCfg(), "/earth/config")
    local mars = makeSide("MARS", marsCfg(), "/mars/config")
    runWorld({ earth, mars }, function()
        t.ok(waitFor(function() return #mars.got == 2 and earth.b:status().trips == 1 end, 60), "adopted batch not delivered")
    end)
    t.eq(mars.got[2].id, "w2")
    t.ok(logHas(earth, "found unsent batch 41"), "no adoption log line")
    w.clear()
end)

t.case("a peer batch already waiting in the receive drive at start is delivered", function()
    local w = standardWorld()
    local text = bridge.packBatch("EARTH", "MARS", 5, { wire(1), wire(2), wire(3) })
    local disk = w.remove("drive_0")
    w.insert("drive_3", { [bridge.FILE] = text })
    local earth = makeSide("EARTH", earthCfg(), "/earth/config")
    local mars = makeSide("MARS", marsCfg(), "/mars/config")
    earth.b:enqueue(wire(4))
    runWorld({ earth, mars }, function()
        t.ok(waitFor(function() return #mars.got == 4 end, 60), "not delivered")
    end)
    t.eq(mars.got[1].id, "w1")
    t.eq(mars.got[4].id, "w4")
    t.ok(disk ~= nil)
    w.clear()
end)

t.case("a different floppy in the send drive makes the batch go again", function()
    local w = standardWorld()
    local earth = makeSide("EARTH", earthCfg(), "/earth/config")
    earth.b:enqueue(wire(1))
    earth.b:enqueue(wire(2))
    local resentText
    runWorld({ earth }, function()
        t.ok(waitFor(function() return w.drives.drive_3.disk ~= nil end, 30), "first send failed")
        t.eq(earth.b:status().state, "waiting")
        t.eq(earth.b:status().inflight, 2)
        w.remove("drive_3")
        w.insert("drive_0")
        t.ok(waitFor(function() return w.drives.drive_3.disk ~= nil end, 30), "resend failed")
        resentText = w.files("drive_3")[bridge.FILE]
    end)
    local b, err = bridge.decodeBatch(resentText)
    t.ok(b, err)
    t.eq(#b.frames, 2)
    t.eq(b.seq, 2)
    t.ok(earth.b:status().lastError:find("different disk", 1, true))
    w.clear()
end)

t.case("stray empty floppy and non floppy items in the receive drive are returned", function()
    local w = standardWorld()
    w.remove("drive_2")
    w.insert("drive_1")
    local earth = makeSide("EARTH", earthCfg(), "/earth/config")
    runWorld({ earth }, function()
        t.ok(waitFor(function() return w.drives.drive_2.disk ~= nil end, 30), "stray floppy not returned")
        w.remove("drive_2")
        w.insert("drive_1", nil, { music = true })
        t.ok(waitFor(function() return w.drives.drive_2.disk ~= nil end, 30), "non floppy item not returned")
    end)
    t.eq(w.drives.drive_1.disk, nil)
    t.eq(earth.b:status().returned, 2)
    t.eq(earth.b:status().received, 0)
    w.clear()
end)

t.case("own batch looping back is rejected with a frequency hint", function()
    local w = standardWorld()
    local earth = makeSide("EARTH", earthCfg(), "/earth/config")
    local text = bridge.packBatch("EARTH", "MARS", 2, { wire(1) })
    w.remove("drive_2")
    w.insert("drive_1", { [bridge.FILE] = text })
    runWorld({ earth }, function()
        t.ok(waitFor(function() return w.drives.drive_2.disk ~= nil end, 30), "floppy not returned")
    end)
    t.eq(earth.b:status().rejected, 1)
    t.ok(earth.b:status().lastError:find("share a frequency", 1, true), earth.b:status().lastError)
    t.eq(w.files("drive_2")[bridge.FILE], text, "a rejected file must stay on the floppy")
    w.clear()
end)

t.case("a tesseract that hands the disk back is retried, not blacklisted", function()
    local w = standardWorld()
    local earth = makeSide("EARTH", earthCfg(), "/earth/config")
    local mars = makeSide("MARS", marsCfg(), "/mars/config")
    w.bounces = 3
    earth.b:enqueue(wire(1))
    runWorld({ earth, mars }, function()
        t.ok(waitFor(function() return #mars.got == 1 end, 200), "the packet never crossed after the bounces")
    end)
    t.eq(w.bounces, 0)
    t.ok(not logHas(earth, "that was not the bridge disk"), "a bounce was taken for a wrong item")
    t.eq(earth.bcfg.sendDir, earthCfg().sendDir, "the configured side must stay")
    t.ok((earth.b.stats.bounces or 0) >= 1, "bounces were not counted")
    w.clear()
end)

t.case("an occasional bounce is a quiet retry, not a problem", function()
    local w = standardWorld()
    local earth = makeSide("EARTH", earthCfg(), "/earth/config")
    local mars = makeSide("MARS", marsCfg(), "/mars/config")
    w.bounces = 2
    earth.b:enqueue(wire(1))
    runWorld({ earth, mars }, function()
        t.ok(waitFor(function() return #mars.got == 1 end, 200), "the packet never crossed after the bounces")
    end)
    local st = earth.b:status()
    t.eq(st.fault, nil)
    t.eq(st.errors, 0, "a bounce that cleared must not count as an error")
    t.eq(st.lastError, nil)
    t.eq(st.bounces, 2)
    w.clear()
end)

t.case("long two way traffic with random bounces never strands a disk", function()
    local w = standardWorld()
    local seed = 12345
    w.rand = function()
        seed = (seed * 1103515245 + 12345) % 2147483648
        return seed / 2147483648
    end
    w.bounceRate = 0.15
    local earth = makeSide("EARTH", earthCfg(), "/earth/config")
    local mars = makeSide("MARS", marsCfg(), "/mars/config")
    local N = 300
    local function unique(list)
        local seen, n = {}, 0
        for _, f in ipairs(list) do
            if not seen[f.id] then seen[f.id] = true n = n + 1 end
        end
        return n
    end
    runWorld({ earth, mars }, function()
        for i = 1, N do
            earth.b:enqueue(wire(i))
            local m = wire(i, "MARS:5")
            m.id = "m" .. i
            mars.b:enqueue(m)
            sleep(w.rand() * 4)
        end
        t.ok(waitFor(function() return unique(mars.got) == N and unique(earth.got) == N end, 1200),
            "lost packets: mars got " .. unique(mars.got) .. ", earth got " .. unique(earth.got))
        w.bounceRate = nil
        t.ok(waitFor(function()
            return w.drives.drive_0.disk ~= nil and w.drives.drive_2.disk ~= nil and earth.b.inflight == nil and mars.b.inflight == nil
        end, 300), "a disk did not come home: " .. tostring(earth.b:status().state) .. " / " .. tostring(mars.b:status().state))
    end, 20000)
    local es, ms = earth.b:status(), mars.b:status()
    t.eq(es.fault, nil, es.fault)
    t.eq(ms.fault, nil, ms.fault)
    t.eq(es.heals, 0, "earth needed the watchdog")
    t.eq(ms.heals, 0, "mars needed the watchdog")
    t.ok(es.bounces > 0 and ms.bounces > 0, "no bounces happened")
    w.clear()
end)

t.case("the bridge report shows the gear, the state and recent pulls", function()
    local w = standardWorld()
    local earth = makeSide("EARTH", earthCfg(), "/earth/config")
    local mars = makeSide("MARS", marsCfg(), "/mars/config")
    w.bounces = 1
    earth.b:enqueue(wire(1))
    local text
    runWorld({ earth, mars }, function()
        t.ok(waitFor(function() return #mars.got == 1 and w.drives.drive_0.disk ~= nil end, 200), "the packet never crossed")
        text = earth.b:report()
    end)
    t.ok(text:find("== bridge to MARS (from EARTH)", 1, true), text)
    t.ok(text:find("send tesseract tesseract_0 (cofh_thermalexpansion_tesseract): frequency 1", 1, true), text)
    t.ok(text:find("send drive drive_0 (drive): disk id", 1, true), text)
    t.ok(text:find("receive drive drive_1 (drive): empty", 1, true), text)
    t.ok(text:find("pull east tesseract_0 from drive_0: moved 1, disk left", 1, true), text)
    t.ok(text:find("handed it back", 1, true), text)
    w.clear()
end)

t.case("bounces that keep happening become a fault", function()
    local w = standardWorld()
    local earth = makeSide("EARTH", earthCfg(), "/earth/config")
    local mars = makeSide("MARS", marsCfg(), "/mars/config")
    w.bounces = 40
    earth.b:enqueue(wire(1))
    runWorld({ earth, mars }, function()
        t.ok(waitFor(function() return earth.b:status().fault ~= nil end, 200), "steady bounces never raised a fault")
    end)
    local st = earth.b:status()
    t.ok(st.fault:find("handed it back", 1, true), st.fault)
    t.ok(st.lastErrorAge ~= nil, "the error has no age")
    w.clear()
end)

t.case("a disk that never comes back is written off and its packets go again", function()
    local w = standardWorld()
    local earth = makeSide("EARTH", earthCfg(), "/earth/config")
    local mars = makeSide("MARS", marsCfg(), "/mars/config")
    w.lose = true
    earth.b:enqueue(wire(1))
    runWorld({ earth, mars }, function()
        t.ok(waitFor(function() return earth.b:status().heals >= 1 end, bridge.STALL + 60), "the stalled trip was never written off")
        t.eq(earth.b:status().inflight, 0, "the lost batch should be back in the queue")
        t.ok(logHas(earth, "no progress for"), "no snapshot in the log")
        w.insert("drive_0")
        t.ok(waitFor(function() return #mars.got == 1 end, 120), "the packet never crossed after a new disk went in")
    end)
    t.eq(mars.got[1].id, "w1")
    w.clear()
end)

t.case("recover from the console resets faults and keeps the queue", function()
    local w = standardWorld()
    local earth = makeSide("EARTH", earthCfg(), "/earth/config")
    earth.b:setFault("send", "test fault", true)
    earth.b.badDirs = { tesseract_0 = { north = true } }
    earth.b:enqueue(wire(1))
    local text = earth.b:reset(nil, "manual")
    t.ok(text:find("test fault", 1, true), text)
    t.eq(earth.b:status().fault, nil)
    t.eq(next(earth.b.badDirs), nil)
    t.eq(earth.b:status().queued, 1)
    t.ok(logHas(earth, "reset by the console"), "manual reset not logged")
    w.clear()
end)

t.case("a pull that grabs another item is reported", function()
    local chest = { kind = "chest", items = 5 }
    local w = standardWorld({ chest = chest })
    w.insert("drive_3")
    local earth = makeSide("EARTH", earthCfg({ sendDir = "north" }), "/earth/config")
    earth.b:enqueue(wire(1))
    runWorld({ earth }, function()
        sleep(40)
    end)
    t.eq(chest.items, 4, "a side that gave a wrong item must not be pulled again")
    t.ok(logHas(earth, "that was not the bridge disk"), "no warning about the wrong item")
    t.eq(earth.bcfg.sendDir, "north")
    w.clear()
end)

t.case("no floppy in the send drive becomes a fault after the grace time", function()
    local w = standardWorld({ noDisks = true })
    local earth = makeSide("EARTH", earthCfg(), "/earth/config")
    earth.b:enqueue(wire(1))
    local before
    runWorld({ earth }, function()
        sleep(5)
        before = earth.b:status().state
        sleep(bridge.NO_DISK_GRACE)
    end)
    t.eq(before, "waiting")
    t.eq(earth.b:status().state, "fault")
    t.ok(earth.b:status().fault:find("no pocket computer or floppy", 1, true))
    w.clear()
end)

t.case("receive handler errors do not stop the bridge", function()
    local w = standardWorld()
    local earth = makeSide("EARTH", earthCfg(), "/earth/config")
    local mars = makeSide("MARS", marsCfg(), "/mars/config")
    local calls = 0
    mars.onReceive = function() calls = calls + 1 error("boom") end
    earth.b:enqueue(wire(1))
    runWorld({ earth, mars }, function()
        t.ok(waitFor(function() return calls == 1 and earth.b:status().trips == 1 end, 60), "not delivered")
        earth.b:enqueue(wire(2))
        t.ok(waitFor(function() return calls == 2 end, 60), "second batch not delivered")
    end)
    t.ok(logHas(mars, "receive handler: ") and logHas(mars, "boom"), "handler error not logged")
    w.clear()
end)

t.case("bridges run as node tasks", function()
    local node = need("node")
    local w = standardWorld()
    local earth = makeSide("EARTH", earthCfg(), "/earth/config")
    local mars = makeSide("MARS", marsCfg(), "/mars/config")
    local n = node.new(earth.cfg, { log = earth.log })
    for i = 1, 5 do earth.b:enqueue(wire(i, nil, 3000)) end
    local done
    env.run(function()
        n:loop(function()
            n:spawn(function() earth.b:run(earth.onReceive) end, "bridge:MARS")
            n:spawn(function() mars.b:run(mars.onReceive) end, "bridge:EARTH")
            mars.b:enqueue(wire(50, "MARS:9"))
            done = waitFor(function() return #mars.got == 5 and #earth.got == 1 and earth.b:status().trips == 1 and mars.b:status().trips == 1 end, 60)
            earth.b:stop()
            mars.b:stop()
        end)
    end, 120)
    t.ok(done, "bridges did not finish under the node scheduler")
    t.eq(earth.b:status().errors, 0, tostring(earth.b:status().lastError))
    t.eq(mars.b:status().errors, 0, tostring(mars.b:status().lastError))
    w.clear()
end)

t.case("hostile long addresses in a batch file are refused", function()
    local frames = { "x" }
    local long = string.rep("A", 5000)
    local text = codec.encode({ zb = 1, from = long, to = "EARTH", seq = 1, frames = frames, sum = crypto.adler32(codec.encode(frames)) })
    local b, err = bridge.decodeBatch(text)
    t.eq(b, nil)
    t.eq(err, "bad address")
    local packed = bridge.packBatch("MARS", long, 1, frames)
    t.eq(select(2, bridge.decodeBatch(packed)), "bad address")
end)

t.case("a drive that vanishes during a pull is not taken as a sent floppy", function()
    local w = standardWorld()
    local earth = makeSide("EARTH", earthCfg({ sendDir = "north" }), "/earth/config")
    local pulls = {}
    env.setPeripheral("tesseract_0", { type = "cofh_thermalexpansion_tesseract", methods = {
        pullItem = function(dir)
            pulls[#pulls + 1] = dir
            if dir == "south" then env.setPeripheral("drive_0", nil) end
            return 0
        end,
        getFrequency = function() return 1 end,
    } })
    earth.b:enqueue(wire(1))
    local did
    env.run(function() did = earth.b:step() end, 60)
    local st = earth.b:status()
    t.eq(did, false)
    t.eq(earth.bcfg.sendDir, "north", "a wrong direction was saved")
    t.eq(st.corrections, 0)
    t.eq(st.inflight, 0)
    t.eq(st.queued, 1, "packet lost")
    t.eq(st.state, "fault")
    t.eq(pulls[1], "north")
    t.eq(pulls[2], "south")
    w.clear()
end)

t.case("probe ignores a drive that vanishes", function()
    local w = standardWorld()
    env.setPeripheral("tesseract_0", { type = "cofh_thermalexpansion_tesseract", methods = {
        pullItem = function(dir)
            if dir == "north" then env.setPeripheral("drive_0", nil) end
            return 0
        end,
        getFrequency = function() return 1 end,
    } })
    local dir, err
    env.run(function() dir, err = bridge.probe("tesseract_0", "drive_0", 0.1) end, 60)
    t.eq(dir, nil)
    t.ok(err ~= nil)
    w.clear()
end)

t.finish()
