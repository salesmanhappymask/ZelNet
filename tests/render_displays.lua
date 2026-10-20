package.path = "./?.lua;" .. package.path
local env = require("tests.fakecc").install({ id = 4 })
local ft = require("tests.faketerm")
ft.install(51, 19, true, env.queue)
local termlib = require("sim.term")
local need = require("tools.devload").make(".")
local sui = need("serverui")
local util = need("util")
local config = need("config")
local panels = need("panels")

local OUT = arg[1] or "build/screens"
os.execute("mkdir -p " .. OUT)

local sizes = {
    monitor_1 = { termlib.monitorSize(6, 3, 0.5) },
    monitor_2 = { termlib.monitorSize(6, 3, 0.5) },
    monitor_3 = { termlib.monitorSize(1, 2, 0.5) },
}
local terms = {}
for name, size in pairs(sizes) do
    local t = termlib.Terminal.new(size[1], size[2], true)
    terms[name] = t
    local methods = termlib.methods(function() return t end)
    methods.setTextScale = function() end
    env.setPeripheral(name, { type = "monitor", methods = methods })
end

local function dump(name, mon)
    local t = terms[mon]
    local f = assert(io.open(OUT .. "/" .. name .. ".scr", "w"))
    f:write("# " .. t.w .. " " .. t.h .. "\n")
    for y = 1, t.h do f:write(t.text[y - 1] .. "\n") end
    for y = 1, t.h do f:write(t:textColours(y) .. "\n") end
    for y = 1, t.h do f:write(t:backgroundColours(y) .. "\n") end
    f:close()
end

local disks = {}
local function drive(name, mount, kind, files, label)
    local d = { present = kind ~= nil, label = label }
    disks[name] = d
    if mount then
        fs.makeDir("/" .. mount)
        for p, text in pairs(files or {}) do
            local h = fs.open("/" .. mount .. "/" .. p, "w")
            h.write(text)
            h.close()
        end
        d.cap = kind == "pocket" and 1000000 or 125000
    end
    env.setPeripheral(name, { type = "drive", methods = {
        isDiskPresent = function() return d.present end,
        hasData = function() return d.present and mount ~= nil end,
        getMountPath = function() return mount end,
        getDiskLabel = function() return d.label end,
        setDiskLabel = function(l) d.label = l end,
        getDiskID = function() return kind == "floppy" and 7 or nil end,
    } })
    return d
end

local function usedOf(path)
    local total = 0
    for _, n in ipairs(fs.list(path)) do
        local p = path .. "/" .. n
        if fs.isDir(p) then total = total + usedOf(p) else total = total + fs.getSize(p) end
    end
    return total
end
local mountCap = {}
fs.getFreeSpace = function(p)
    p = "/" .. tostring(p):gsub("^/+", "")
    local root = p:match("^/[^/]+") or "/"
    local cap = mountCap[root] or 1000000
    return cap - usedOf(root)
end

local function addDrive(name, mount, kind, files, label)
    local d = drive(name, mount, kind, files, label)
    if mount then mountCap["/" .. mount] = d.cap end
    return d
end

addDrive("drive_0", "disk", "pocket", { ["zn_accounts/users.db"] = string.rep("x", 182000) }, "ZelNet accounts")
addDrive("drive_1", "disk2", "pocket", { ["zn_mail/a.db"] = string.rep("x", 640000) }, "ZelNet mail")
addDrive("drive_2", "disk3", "pocket", { ["zn_chat/c.db"] = string.rep("x", 930000) }, "ZelNet chat")
addDrive("drive_3", "disk4", "floppy", { ["zn_audit/a.log"] = string.rep("x", 30000) }, "ZelNet audit")
addDrive("drive_4", nil, nil)
addDrive("drive_5", "disk6", "floppy", {}, nil)
addDrive("drive_7", "disk7", "pocket", { ["startup"] = "print(1)", ["games/worm"] = string.rep("y", 5000), ["notes.txt"] = "hi" }, "Steve's pocket")
addDrive("drive_10", "disk10", "floppy", { ["zelnet_batch"] = "x" }, "earth-mars")
addDrive("drive_11", nil, nil)

local cfg = config.newServer({ realm = "EARTH", network = "TestNet" })
sui.setPassword(cfg, "secret")
cfg.lockAfter = 0
cfg.displays = { activity = "monitor_1", console = "monitor_2", setup = "monitor_3", drive = "drive_7" }
cfg.storage = { drives = { accounts = "drive_0", mail = "drive_1", chat = "drive_2", audit = "drive_3" } }
cfg.bridges = {
    { peer = "MARS", sendTess = "tesseract_0", sendDrive = "drive_10", sendDir = "north", recvTess = "tesseract_1", recvDrive = "drive_11", recvDir = "up" },
    { peer = "VENUS", sendTess = "tesseract_2", sendDrive = "drive_12", sendDir = "east", recvTess = "tesseract_3", recvDrive = "drive_13", recvDir = "west" },
}

local log = util.newLogger(80)
local node = { log = log, traceRing = util.newRing(150), traceSeq = 0, running = false, timers = {}, counters = {} }
function node.trace(self, kind, text)
    self.traceSeq = self.traceSeq + 1
    self.traceRing.push({ n = self.traceSeq, t = 0, s = 30 + self.traceSeq / 50, kind = kind, text = text })
end
log.listen(function(e) node:trace(e.level, e.text) end)
node.tasks = {
    { name = "rx" }, { name = "worker", filter = "zn_work" }, { name = "clock", filter = "timer" },
    { name = "bridge:MARS", filter = "timer" }, { name = "bridge:VENUS", filter = "timer" },
    { name = "port:tekmail", filter = "zn_reply" }, { name = "port:tekmail", filter = "zn_reply" },
    { name = "console", filter = "key" }, { name = "console-sensor", filter = "timer" }, { name = "console-displays" },
    { name = "airlock-rx", filter = "rednet_message" }, { name = "setup-write", filter = "zn_breathe" },
}
node.timers = { { name = "beacon", next = 4 }, { name = "hello", next = 12 }, { name = "housekeeping", next = 61 } }
local kinds = { "in", "out", "bb", "in", "flood", "out" }
local ports = { "tekmail.send", "zn.ps", "tekmail.inbox", "zn.name", "power.mars", "zn.ping" }
for i = 1, 60 do
    node:trace(kinds[i % #kinds + 1], "EARTH:" .. (10 + i % 9) .. " > " .. ({ "MARS:outpost_relay_7", "EARTH", "VENUS:dashboard", "*" })[i % 4 + 1] .. " " .. ports[i % #ports + 1] .. ((i % 5 == 0) and " reply" or ""))
    if i % 13 == 0 then log.warn("bridge MARS: the floppy in drive_10 is full (2048 bytes free), waiting for the other side to empty it before sending more") end
    if i % 17 == 0 then log.info("device online: client" .. i) end
end
log.error("storage: write to drive_3 failed: disk full")

local function status()
    return {
        realm = "EARTH", role = "main", isMain = true, serverId = 4, uptime = 93784, mainRealm = "EARTH", prog = "1.0.0",
        devices = { total = 9, online = 6 },
        neighbors = {
            { realm = "MARS", kind = "bridge", up = true, age = 4, prog = "1.0.0" },
            { realm = "VENUS", kind = "bridge", up = false, problem = "fault: gear missing" },
            { realm = "MOON", kind = "bitnet", up = true, age = 12, prog = "1.0.0" },
        },
        routes = { { realm = "MARS", via = "MARS", kind = "bridge", metric = 4 }, { realm = "MOON", via = "MOON", kind = "bitnet", metric = 2 }, { realm = "PLUTO", via = "MOON", kind = "bitnet", metric = 6 } },
        bridges = {
            { peer = "MARS", state = "idle", up = true, queued = 3, inflight = 0, sent = 1234, received = 1199, bytesOut = 512345, bytesIn = 498000, trips = 801, lastTrip = 6.25 },
            { peer = "VENUS", state = "fault", up = false, queued = 41, inflight = 0, sent = 12, received = 9, bytesOut = 4000, bytesIn = 3000, trips = 7, fault = "tesseract_2 is not attached; check the wired modem next to it and the OpenPeripheral install" },
        },
        links = { { id = "top", wireless = true, open = true, tx = 4123, rx = 9876 }, { id = "bitnet_tower_0", open = true, tx = 120, rx = 98 }, { id = "back", open = false, tx = 0, rx = 0 } },
        warnings = { "neighbor VENUS uses a different cipher fingerprint (its Cipher Block holds other items)", "storage role system is on this computer" },
        cipher = { kind = "hardware", name = "cipher_0", ok = true, fingerprint = "9f3a77c2" },
        queue = { stored = 2, backbone = 44 },
        counters = { errors = 1, dropped = 3 },
        directory = { ver = 18, users = 5, realms = 4, synced = true },
    }
end

local devices = {
    { name = "client1", role = "client", status = "online", cid = 12, hops = 1, lastSeen = 1201.5, prog = "1.0.0", parent = 4 },
    { name = "mars_lab_terminal", role = "client", status = "online", cid = 140, hops = 3, parent = 61, lastSeen = 1201.2, prog = "1.0.0" },
    { name = "relay_north", role = "router", status = "online", cid = 61, hops = 2, parent = 4, lastSeen = 1201.1, prog = "1.0.0" },
    { name = "powermon", role = "endpoint", status = "pending", lastSeen = nil },
    { name = "oldbox", role = "client", status = "revoked", cid = 7, hops = 1, lastSeen = 900 },
    { name = "reactor_feed", role = "endpoint", status = "offline", cid = 88, hops = 1, lastSeen = 1100, prog = "0.9.4" },
}
for i = 1, 30 do devices[#devices + 1] = { name = "bulk" .. i, role = "client", status = "online", cid = 200 + i, hops = 1, lastSeen = 1201, prog = "1.0.0" } end

local users = {
    { name = "boss", display = "Boss", realm = "EARTH", admin = true, ["local"] = true },
    { name = "alice", display = "Alice of Mars", realm = "MARS", ["local"] = false },
    { name = "bob", display = "bob", realm = "EARTH", ["local"] = true },
    { name = "averyveryverylon", display = "A Very Very Long Display Name", realm = "VENUS", ["local"] = false },
}

local ctx = { cfg = cfg, log = log, node = node, configPath = "/.zelnet/config" }
ctx.server = {
    status = status,
    devices = function() return devices end,
    realms = function() return { { realm = "EARTH", main = true, reachable = true, metric = 0, prog = "1.0.0" }, { realm = "MARS", reachable = true, metric = 4, prog = "1.0.0" }, { realm = "VENUS", reachable = false }, { realm = "MOON", reachable = true, metric = 2 } } end,
    provision = function(_, role, name) return config.newDevice(cfg, role, name, 4) end,
    removeDevice = function() return true end,
}
ctx.storage = {
    info = function()
        return {
            { role = "accounts", title = "Accounts", drive = "drive_0", present = true, state = "online", files = 12, free = 818000, used = 182000 },
            { role = "audit", title = "Audit", drive = "drive_3", present = false, state = "offline" },
        }
    end,
    ready = function() return false end,
    audit = function() end,
}
ctx.tekmail = {
    stats = function() return { users = 4, sessions = 2, outbox = 3, chatMessages = 120 } end,
    listUsers = function() return users end,
}
ctx.airlock = {
    enabled = true,
    stats = function() return { nodes = 7, sealed = 5, low = 1, offline = 1 } end,
    groups = function()
        return {
            { grouped = true, group = "dock", sealed = 2, total = 3, hasSensor = true, chamberLow = true, members = {
                { name = "dockA", suffix = "A", online = true, oxygenated = true, sealed = true, locked = false },
                { name = "dockB", suffix = "B", online = true, oxygenated = false, sealed = false, locked = true },
                { name = "dockC", suffix = "C", role = "sensor", online = false },
            } },
            { grouped = false, members = { { name = "lab_door", online = true, oxygenated = true, sealed = true } } },
        }
    end,
}

local con = sui.new(ctx, { noTasks = true })
con.locked = true
local p = panels.new(con)
for _ = 1, 40 do
    p.history[#p.history + 1] = math.random(0, 14)
end
p:sample()

p:drawAll()
dump("activity", "monitor_1")
for _, tab in ipairs(panels.TABS) do
    p.tab = tab.id
    p.offsets = {}
    p:drawAll()
    dump("console_" .. tab.id, "monitor_2")
end
p.tab = "devices"
p:consoleAction("down")
p:drawAll()
dump("console_devices_scrolled", "monitor_2")
p.tab = "log"
p:consoleAction("down")
p:drawAll()
dump("console_log_scrolled", "monitor_2")

dump("setup_locked", "monitor_3")
con.locked = false
p:drawAll()
dump("setup_home", "monitor_3")
disks.drive_7.present = false
p.drivesAt = -100
p:drawAll()
dump("setup_home_empty", "monitor_3")
p:setupAction("role:client")
p:setupAction("next")
p:drawAll()
dump("setup_home_err", "monitor_3")
disks.drive_7.present = true
p:setupAction("role:client")
p:drawAll()
dump("setup_name", "monitor_3")
p:setupAction("role:satellite")
p:setupAction("key:m")
p:setupAction("key:a")
p:drawAll()
dump("setup_name_sat", "monitor_3")
p:setupAction("next")
p:drawAll()
dump("setup_name_sat_err", "monitor_3")
p:setupAction("key:r")
p:setupAction("key:s")
p:setupAction("next")
p:drawAll()
dump("setup_confirm", "monitor_3")
p.st.screen = "busy"
p.st.note = "Writing Satellite MARS"
p:drawAll()
dump("setup_busy", "monitor_3")
p.st.screen = "part"
p.st.part, p.st.parts = 2, 2
p.st.err = "this is disk 1; insert another disk"
p:drawAll()
dump("setup_part", "monitor_3")
p.st = { screen = "done", role = "client", name = "client7", parts = 1 }
p:drawAll()
dump("setup_done", "monitor_3")
p.st = { screen = "error", err = "Could not write: not enough space on the disk in drive_7" }
p:drawAll()
dump("setup_error", "monitor_3")
p.st = { screen = "home" }
p:setupAction("role:client")
p:setupAction("next")
env.run(function() p:setupAction("write") end, 300)
p:drawAll()
dump("setup_after_write", "monitor_3")
print("rendered to " .. OUT)
