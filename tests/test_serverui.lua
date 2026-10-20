package.path = "./?.lua;" .. package.path
local env = require("tests.fakecc").install({ id = 4 })
local ft = require("tests.faketerm")
local screen = ft.install(51, 19, true, env.queue)
local need = require("tools.devload").make(".")
local sui = need("serverui")
local util = need("util")
local config = need("config")
local codec = need("codec")
local prov = need("provision")
local t = require("tests.tiny")

_G.print = function() end

local function fakeDrive(name, mount, id)
    local d = { present = true, data = true, id = id }
    env.setPeripheral(name, { type = "drive", methods = {
        isDiskPresent = function() return d.present end,
        hasData = function() return d.present and d.data end,
        getMountPath = function() return mount end,
        getDiskLabel = function() return d.label end,
        setDiskLabel = function(l) d.label = l end,
        getDiskID = function() return d.id end,
    } })
    fs.makeDir("/" .. mount)
    return d
end

local function fakeCtx(cfg)
    local log = util.newLogger(50)
    local rec = { audit = {}, provisioned = {}, created = {}, removed = {} }
    local ctx = { cfg = cfg, log = log, configPath = "/.zelnet/config" }
    ctx.node = { log = log, running = false, spawn = function() end, ping = function() return 0.25 end }
    ctx.storage = {
        audit = function(_, actor, action, target, detail, ok)
            rec.audit[#rec.audit + 1] = { actor = actor, action = action, target = target, detail = detail, ok = ok }
        end,
        info = function() return { { role = "accounts", title = "Accounts", present = true, state = "local", files = 2, free = 50000 } } end,
        ready = function() return true end,
        auditTail = function() return {} end,
        problemList = function() return {} end,
    }
    ctx.server = {
        status = function()
            return {
                realm = cfg.realm, role = cfg.role, isMain = cfg.role == "main", serverId = 4, uptime = 65,
                devices = { total = 1, online = 1 }, neighbors = {}, routes = {}, bridges = {}, links = {},
                warnings = {}, cipher = { kind = "hardware", ok = true }, queue = { stored = 0 },
            }
        end,
        devices = function() return {} end,
        realms = function() return { { realm = cfg.realm, reachable = true, metric = 0, main = true } } end,
        provision = function(_, role, name)
            rec.provisioned[#rec.provisioned + 1] = role .. ":" .. name
            return config.newDevice(cfg, role, name, 4)
        end,
        removeDevice = function(_, name) rec.removed[#rec.removed + 1] = name return true end,
    }
    ctx.tekmail = {
        stats = function() return { users = #rec.created, sessions = 0, outbox = 0, chatMessages = 0 } end,
        listUsers = function()
            local out = {}
            for _, c in ipairs(rec.created) do out[#out + 1] = { name = c.name, realm = cfg.realm, admin = c.admin, ["local"] = true } end
            return out
        end,
        createUser = function(_, name, pw, opts)
            rec.created[#rec.created + 1] = { name = name:lower(), pw = pw, admin = opts.admin }
            return true
        end,
    }
    return ctx, rec
end

local function newCfg()
    local cfg = config.newServer({ realm = "EARTH", network = "TestNet" })
    sui.setPassword(cfg, "secret")
    cfg.lockAfter = 0
    return cfg
end

local function reset()
    ft.reset()
end

local MINE = function() return true end

local function hasAudit(rec, action, detail)
    for _, a in ipairs(rec.audit) do
        if a.action == action and (detail == nil or a.detail == detail) then return a end
    end
    return nil
end

t.case("console password hash and check", function()
    local cfg = {}
    sui.setPassword(cfg, "hunter2")
    t.ok(cfg.console.salt and cfg.console.hash)
    t.ok(cfg.console.hash ~= "hunter2")
    t.eq(sui.checkPassword(cfg, "hunter2"), true)
    t.eq(sui.checkPassword(cfg, "hunter3"), false)
    t.eq(sui.checkPassword(cfg, ""), false)
    t.eq(sui.checkPassword({}, "x"), false)
    t.eq(sui.passwordProblem("abc"), "Use at least 4 characters.")
    t.eq(sui.passwordProblem("abcd", "abce"), "The two passwords differ.")
    t.eq(sui.passwordProblem("abcd", "abcd"), nil)
end)

t.case("proximity scan reads distance, position and details", function()
    local prox = {
        getTargets = function()
            return {
                Gleeful = { Position = { X = 1, Y = 0, Z = 1 } },
                Other = { Distance = 1 },
                [7] = { Name = "Far", Distance = 30 },
            }
        end,
    }
    local near, note = sui.scanTargets(prox, "gleeful", 3)
    t.eq(near, true)
    t.ok(note:find("1.4", 1, true), note)
    near = sui.scanTargets(prox, "Far", 3)
    t.eq(near, false)
    near, note = sui.scanTargets(prox, "Nobody", 3)
    t.eq(near, false)
    t.ok(note:find("3 targets", 1, true), note)
    local detailed = {
        getTargets = function() return { abc = {} } end,
        getTargetDetails = function() return { Username = "Admin", Position = { X = 0, Y = 2, Z = 0 } } end,
    }
    t.eq((sui.scanTargets(detailed, "Admin", 3)), true)
    local broken = { getTargets = function() error("boom") end }
    near, note = sui.scanTargets(broken, "Admin", 3)
    t.eq(near, false)
    t.eq(note, "no sensor data")
    t.eq((sui.scanTargets(nil, "Admin", 3)), false)
end)

t.case("lock screen rejects a wrong password and accepts the right one", function()
    reset()
    local cfg = newCfg()
    local ctx, rec = fakeCtx(cfg)
    local con = sui.new(ctx, { noTasks = true })
    ft.line("nope")
    ft.line("secret")
    local res
    env.run(function() res = con:lockScreen() end, 30)
    t.eq(res, "password")
    t.eq(con.locked, false)
    t.ok(not hasAudit(rec, "unlock", "bad password"), "a single failed try is not audited")
    t.ok(hasAudit(rec, "unlock", "password"), "unlock audited")
end)

t.case("lock screen holds after three wrong passwords", function()
    reset()
    local cfg = newCfg()
    local ctx, rec = fakeCtx(cfg)
    local con = sui.new(ctx, { noTasks = true })
    ft.line("a1")
    ft.line("a2")
    ft.line("a3")
    ft.line("secret")
    ft.wait(1)
    ft.event("zn_probe")
    ft.wait(sui.FAIL_HOLD)
    ft.line("secret")
    local res, heldScreen
    local real = os.pullEvent
    os.pullEvent = function(f)
        local r = { real(f) }
        if r[1] == "zn_probe" then heldScreen = screen.has("Too many tries") end
        return unpack(r)
    end
    env.run(function() res = con:lockScreen() end, 60)
    os.pullEvent = real
    t.eq(res, "password")
    t.eq(heldScreen, true)
    local n = 0
    for _, a in ipairs(rec.audit) do if a.action == "unlock" and a.ok == false then n = n + 1 end end
    t.eq(n, 1, "three failures make one audit entry")
end)

t.case("proximity unlock needs the admin to leave after a lock", function()
    reset()
    local cfg = newCfg()
    cfg.adminPlayer = "Admin"
    local ctx, rec = fakeCtx(cfg)
    local con = sui.new(ctx, { noTasks = true })
    con.latch = true
    con.locked = true
    con:onSensorResult(true, "Admin at 1.0")
    t.eq(#env.queue(), 0, "latched: no unlock while standing there")
    con:onSensorResult(false, "watching")
    t.eq(con.latch, false)
    con:onSensorResult(true, "Admin at 1.0")
    local res
    env.run(function() res = con:lockScreen() end, 30)
    t.eq(res, "proximity")
    t.ok(hasAudit(rec, "unlock", "proximity"))
    con.unlockedBy = "proximity"
    for _ = 1, sui.SENSOR_MISSES do con:onSensorResult(false, "watching") end
    t.eq(con.lockReq, "left")
    t.ok(hasAudit(rec, "auto_lock"))
end)

t.case("console run: unlock, lock from the menu, unlock, reboot", function()
    reset()
    local cfg = newCfg()
    local ctx, rec = fakeCtx(cfg)
    ft.line("secret")
    ft.key("up", 3)
    ft.key("enter")
    ft.line("secret")
    ft.key("up")
    ft.key("enter")
    ft.key("enter")
    local res
    env.run(function() res = sui.run(ctx, { noTasks = true, ownThread = MINE }) end, 120)
    t.eq(res, "reboot")
    t.ok(hasAudit(rec, "lock", "manual"))
    t.ok(hasAudit(rec, "reboot"))
    local unlocks = 0
    for _, a in ipairs(rec.audit) do if a.action == "unlock" then unlocks = unlocks + 1 end end
    t.eq(unlocks, 2)
end)

t.case("console locks itself after the idle time", function()
    reset()
    local cfg = newCfg()
    cfg.lockAfter = 30
    local ctx, rec = fakeCtx(cfg)
    ft.line("secret")
    ft.wait(40)
    ft.line("secret")
    ft.key("up")
    ft.key("enter")
    ft.key("enter")
    local res
    env.run(function() res = sui.run(ctx, { noTasks = true, ownThread = MINE }) end, 600)
    t.eq(res, "reboot")
    local a = hasAudit(rec, "auto_lock")
    t.ok(a, "auto lock audited")
    t.eq(a.detail, "idle")
end)

t.case("exit to shell needs the password", function()
    reset()
    local cfg = newCfg()
    local ctx, rec = fakeCtx(cfg)
    ft.line("secret")
    ft.key("up", 2)
    ft.key("enter")
    ft.line("wrong")
    ft.key("enter")
    ft.key("enter")
    ft.line("secret")
    ft.key("enter")
    local res
    env.run(function() res = sui.run(ctx, { noTasks = true, ownThread = MINE }) end, 120)
    t.eq(res, "exit")
    t.ok(hasAudit(rec, "exit_shell", "bad password"))
end)

t.case("provisioning a client writes the disk", function()
    reset()
    fakeDrive("drive_7", "disk7", 70)
    for _, f in ipairs(fs.list("/disk7")) do fs.delete("/disk7/" .. f) end
    util.writeFile("/zelnet", "local __mods, __cache, __loading = {}, {}, {}\nlocal function need(n) return __mods[n](need) end\n__mods[\"main\"] = function(...)\n    return { start = function() return 1 end }\nend\nreturn need(\"main\").start({...}, getfenv(1))\n")
    prov.setProgramPath("/zelnet")
    local cfg = newCfg()
    local ctx, rec = fakeCtx(cfg)
    local con = sui.new(ctx, { noTasks = true })
    ft.key("enter")
    ft.line("Lab_One")
    ft.key("enter")
    ft.key("enter")
    ft.key("enter")
    env.run(function() con:newDevice() end, 60)
    t.eq(rec.provisioned[1], "client:lab_one")
    local dcfg = codec.decode(util.readFile("/disk7/zelnet.cfg"))
    t.eq(dcfg.name, "lab_one")
    t.eq(dcfg.role, "client")
    t.ok(fs.exists("/disk7/startup"))
    t.ok(fs.exists("/disk7/zelnet"))
    t.eq(peripheral.call("drive_7", "getDiskLabel"), "ZelNet client lab_one")
    t.ok(hasAudit(rec, "provision"))
    env.setPeripheral("drive_7", nil)
end)

t.case("accounts page creates an admin account", function()
    reset()
    local cfg = newCfg()
    local ctx, rec = fakeCtx(cfg)
    local con = sui.new(ctx, { noTasks = true })
    ft.typeText("n")
    ft.line("Alice")
    ft.line("pw1234")
    ft.line("pw1234")
    ft.key("backspace")
    ft.line("y")
    ft.key("enter")
    ft.key("leftCtrl")
    env.run(function() con:accounts() end, 60)
    t.eq(#rec.created, 1)
    t.eq(rec.created[1].name, "alice")
    t.eq(rec.created[1].admin, true)
    t.eq(rec.created[1].pw, "pw1234")
end)

t.case("every console page opens and closes", function()
    reset()
    local cfg = newCfg()
    local ctx, rec = fakeCtx(cfg)
    local recs = {
        { id = 11, name = "DOCK-A", group = "DOCK", suffix = "A", role = "door", online = true, sealed = true, oxygenated = true },
        { id = 12, name = "DOCK-C", group = "DOCK", suffix = "C", role = "sensor", online = true, oxygenated = false },
        { id = 13, name = "lab", group = "lab", role = "door", online = false, locked = true },
    }
    local calls = {}
    ctx.airlock = {
        enabled = true,
        list = function() return recs end,
        groups = function()
            return {
                { group = "DOCK", members = { recs[1], recs[2] }, total = 2, sealed = 1, hasSensor = true, chamberLow = true, grouped = true },
                { group = "lab", members = { recs[3] }, total = 1, sealed = 0, grouped = false },
            }
        end,
        stats = function() return { nodes = 3, sealed = 1, low = 1, offline = 1 } end,
        setManual = function(_, id, mode) calls[#calls + 1] = "manual:" .. id .. ":" .. mode return true end,
        setLocked = function(_, id, v) calls[#calls + 1] = "lock:" .. id .. ":" .. tostring(v) return true end,
        poll = function() calls[#calls + 1] = "poll" return 3 end,
        discover = function() calls[#calls + 1] = "discover" return true end,
    }
    ctx.tekmail.chatHistory = function() return { { seq = 1, user = "bob", realm = "EARTH", text = "hello", t = 30 } } end
    ctx.tekmail.roomList = function() return { "global", "EARTH" } end
    ctx.tekmail.sessions = function() return { { user = "bob", client = "EARTH:5", idle = 3 } } end
    ctx.server.devices = function() return { { name = "lab1", role = "client", status = "online", cid = 5, lastSeen = 10 } } end
    ctx.storage.auditTail = function() return { { s = 12, actor = "console", action = "unlock", ok = true } } end
    ctx.log.warn("something happened")
    local con = sui.new(ctx, { noTasks = true })
    local function back() ft.key("leftCtrl") end
    local function run(label, fn)
        local ok, err = pcall(env.run, fn, 30)
        if not ok then error(label .. ": " .. tostring(err) .. " left " .. #ft.script .. "\n" .. screen.text(), 0) end
    end
    back()
    run("dashboard", function() con:dashboard() end)
    back()
    run("devices", function() con:devices() end)
    ft.key("enter")
    ft.key("enter")
    ft.key("enter")
    back()
    run("devices", function() con:devices() end)
    back()
    run("accounts", function() con:accounts() end)
    ft.key("enter")
    back()
    run("chat", function() con:chat() end)
    for i = 1, 4 do
        ft.key("down", i - 1)
        ft.key("enter")
        back()
    end
    back()
    run("network", function() con:network() end)
    back()
    run("bridgesPage", function() con:bridgesPage() end)
    ft.key("enter")
    ft.key("enter")
    back()
    ft.typeText("r")
    ft.typeText("d")
    back()
    run("airlocks", function() con:airlocks() end)
    t.eq(calls[1], "manual:11:seal")
    t.eq(calls[2], "poll")
    t.eq(calls[3], "discover")
    back()
    run("storagePage", function() con:storagePage() end)
    back()
    run("auditPage", function() con:auditPage() end)
    ft.key("enter")
    ft.key("enter")
    back()
    run("eventLog", function() con:eventLog() end)
    back()
    run("settings", function() con:settings() end)
    back()
    reset()
    back()
    run("updatePage", function() con:updatePage() end)
    t.ok(screen.has("Download from the repo"), screen.text())
    reset()
    ft.key("enter")
    ft.key("enter")
    run("updatePage", function() con:updatePage() end)
    t.ok(screen.has("http API is turned off"), screen.text())
    cfg.role = "satellite"
    reset()
    ft.key("down")
    ft.key("enter")
    ft.key("enter")
    run("updatePage", function() con:updatePage() end)
    t.ok(screen.has("Update Status"), screen.text())
end)

t.case("bridge setup helper picks gear and probes the send side", function()
    reset()
    local d1 = fakeDrive("drive_21", "disk21", 1)
    local d2 = fakeDrive("drive_22", "disk22", 2)
    local pulls = {}
    local function tess(name, freq, drive)
        env.setPeripheral(name, { type = "tile_thermalexpansion_ender_tesseract_name", methods = {
            getFrequency = function() return freq end,
            pullItem = function(dir)
                pulls[#pulls + 1] = name .. ":" .. dir
                if dir == "east" then drive.present = false end
                return 1
            end,
        } })
    end
    tess("tesseract_1", 100, d1)
    tess("tesseract_2", 200, d2)
    local cfg = newCfg()
    ft.line("mars")
    ft.key("enter")
    ft.key("enter")
    ft.key("enter")
    ft.key("enter")
    ft.key("enter")
    ft.key("enter")
    ft.key("down", 5)
    ft.key("enter")
    ft.key("enter")
    local bcfg
    env.run(function() bcfg = sui.bridgeWizard(need("ui").surface(term), cfg) end, 120)
    t.ok(bcfg, "bridge config returned")
    t.eq(bcfg.peer, "MARS")
    t.eq(bcfg.sendTess, "tesseract_1")
    t.eq(bcfg.sendDrive, "drive_21")
    t.eq(bcfg.recvTess, "tesseract_2")
    t.eq(bcfg.recvDrive, "drive_22")
    t.eq(bcfg.sendDir, "east")
    t.eq(bcfg.recvDir, "up")
    t.ok(#pulls >= 3, "probe tried directions")
    for _, n in ipairs({ "drive_21", "drive_22", "tesseract_1", "tesseract_2" }) do env.setPeripheral(n, nil) end
end)

t.case("display monitors draw activity, console tabs and setup", function()
    local panels = need("panels")
    local mons = {}
    for name, size in pairs({ monitor_1 = { 121, 38 }, monitor_2 = { 121, 38 }, monitor_3 = { 15, 24 } }) do
        local m = ft.new(size[1], size[2], true)
        m.setTextScale = function() end
        env.setPeripheral(name, { type = "monitor", methods = m })
        mons[name] = m
    end
    local cfg = newCfg()
    cfg.displays = { activity = "monitor_1", console = "monitor_2", setup = "monitor_3" }
    local ctx = fakeCtx(cfg)
    ctx.node.traceRing = util.newRing(20)
    ctx.node.traceRing.push({ n = 1, t = 0, s = 30, kind = "in", text = "EARTH:5 > EARTH zm.mail" })
    ctx.node.tasks = { { name = "rx", filter = nil }, { name = "worker", filter = "zn_work" } }
    local con = sui.new(ctx, { noTasks = true })
    local p = panels.new(con)
    p:sample()
    p:drawAll()
    t.ok(mons.monitor_1.has("LIVE TRAFFIC"), mons.monitor_1.text())
    t.ok(mons.monitor_1.has("zm.mail"), mons.monitor_1.text())
    t.ok(mons.monitor_1.has("PROCESSES"))
    t.ok(mons.monitor_2.has("Overview"), mons.monitor_2.text())
    t.ok(mons.monitor_2.has("DEVICES"))
    t.ok(mons.monitor_3.has("locked."), mons.monitor_3.text())
    for _, tab in ipairs(panels.TABS) do
        p.tab = tab.id
        p:drawAll()
    end
    p.tab = "drives"
    p:drawAll()
    t.ok(mons.monitor_2.has("DISK DRIVES"), mons.monitor_2.text())
    con.locked = false
    p:drawAll()
    t.ok(mons.monitor_3.has("Client"), mons.monitor_3.text())
    t.ok(mons.monitor_3.has("Satellite"), "Main offers satellites")
    p:setupAction("role:router")
    p:drawAll()
    t.ok(mons.monitor_3.has("router1"), mons.monitor_3.text())
    p:setupAction("key:DEL")
    p:setupAction("key:x")
    t.eq(p.st.name, "routerx")
    p:setupAction("next")
    t.eq(p.st.screen, "name")
    t.eq(p.st.err, "No setup drive")
    for name in pairs(mons) do env.setPeripheral(name, nil) end
end)

t.case("setup wizard creates a Main server config", function()
    reset()
    fs.delete("/.zelnet")
    fs.delete("/startup")
    env.setPeripheral("cipher_0", { type = "cipher", methods = {
        encrypt = function(s) return "E" .. s:reverse() end,
        decrypt = function(s) return s:sub(2):reverse() end,
    } })
    ft.key("enter")
    ft.key("enter")
    ft.key("enter")
    ft.line("EARTH")
    ft.line("abcd")
    ft.line("abcd")
    ft.key("enter")
    ft.line("boss")
    ft.line("bosspw")
    ft.line("bosspw")
    ft.key("enter")
    ft.key("enter")
    ft.key("down")
    ft.key("enter")
    ft.key("enter")
    ft.line("Steve")
    ft.key("enter")
    ft.key("enter")
    ft.key("enter")
    ft.key("enter")
    local cfg, extra
    env.run(function() cfg, extra = sui.setup({}) end, 120)
    t.ok(cfg, "setup returned a config")
    t.eq(cfg.role, "main")
    t.eq(cfg.realm, "EARTH")
    t.eq(cfg.network, "ZelNet")
    t.eq(cfg.cipherName, "cipher_0")
    t.eq(cfg.adminPlayer, "Steve")
    t.ok(sui.checkPassword(cfg, "abcd"))
    t.eq(extra.admin.user, "boss")
    t.eq(extra.admin.pass, "bosspw")
    local saved = config.load()
    t.eq(saved.realm, "EARTH")
    t.ok(sui.checkPassword(saved, "abcd"))
    t.eq(util.readFile("/startup"), "shell.run(\"/zelnet\")\n")
    env.setPeripheral("cipher_0", nil)
end)

t.case("setup wizard finishes a satellite from a provisioned config", function()
    reset()
    fs.delete("/.zelnet")
    local main = config.newServer({ realm = "EARTH", network = "TestNet" })
    local scfg = config.newServer({ role = "satellite", network = "TestNet", realm = "MARS", mainRealm = "EARTH", backboneKey = main.backboneKey })
    local oldKey = scfg.dataKey
    ft.key("enter")
    ft.line("mars1")
    ft.line("mars1")
    ft.key("down")
    ft.key("enter")
    ft.key("down")
    ft.key("down")
    ft.key("enter")
    ft.key("enter")
    ft.key("down")
    ft.key("enter")
    ft.key("enter")
    ft.key("enter")
    ft.key("enter")
    ft.key("enter")
    ft.key("enter")
    ft.key("enter")
    local cfg
    env.run(function() cfg = sui.setup({ cfg = scfg }) end, 120)
    t.ok(cfg, "returned config")
    t.eq(cfg.role, "satellite")
    t.eq(cfg.realm, "MARS")
    t.eq(cfg.backboneKey, main.backboneKey)
    t.ok(cfg.dataKey ~= oldKey, "satellite makes its own data key")
    t.ok(sui.checkPassword(cfg, "mars1"))
    t.eq(config.load().realm, "MARS")
end)

t.case("cipher guide: exit to shell needs the console password", function()
    reset()
    local cfg = newCfg()
    ft.typeText("3")
    ft.line("wrong")
    ft.key("enter")
    ft.typeText("3")
    ft.line("secret")
    local res
    env.run(function() res = sui.cipherGuide(cfg, "no cipher block found", { wait = 600 }) end, 300)
    t.eq(res, "exit")
    reset()
    ft.typeText("3")
    ft.line("wrong")
    ft.key("enter")
    env.run(function() res = sui.cipherGuide(cfg, "no cipher block found", { wait = 20 }) end, 300)
    t.eq(res, "local", "a wrong password falls back to starting without the backbone")
    reset()
    local fresh = config.newServer({ realm = "EARTH" })
    ft.typeText("3")
    env.run(function() res = sui.cipherGuide(fresh, "no cipher block found", { wait = 600 }) end, 300)
    t.eq(res, "exit", "no console password yet: exit is free")
end)

t.finish()
