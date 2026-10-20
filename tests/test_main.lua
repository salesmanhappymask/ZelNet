package.path = "./?.lua;" .. package.path
local env = require("tests.fakecc").install({ id = 9 })
require("tests.faketerm").install()
local need = require("tools.devload").make(".")
local main = need("main")
local api = need("api")
local util = need("util")
local compat = need("compat")
local crypto = need("crypto")
local config = need("config")
local version = need("version")
local t = require("tests.tiny")

local printed = {}
_G.print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    printed[#printed + 1] = table.concat(parts, " ")
end

local function shellFor(path)
    return { getRunningProgram = function() return path end, run = function() return true end }
end

t.case("mode detection: os.loadAPI, dofile and program runs", function()
    t.eq(main.detectMode({}), "api")
    t.eq(main.detectMode({ shell = shellFor("zelnet") }), "program")
    t.eq(main.detectMode({ shell = shellFor("zelnet.lua") }), "program")
    t.eq(main.detectMode({ shell = shellFor("mylogger") }), "library")
    t.eq(main.detectMode({ shell = shellFor("startup") }), "program")
    util.writeFile("/startup", "local zn = dofile(\"/zelnet\")\n")
    t.eq(main.detectMode({ shell = shellFor("startup") }), "library")
    util.writeFile("/startup", "local __mods, __cache, __loading = {}, {}, {}\n")
    t.eq(main.detectMode({ shell = shellFor("startup") }), "program")
    util.writeFile("/tools/zn", "local __mods, __cache, __loading = {}, {}, {}\n")
    t.eq(main.detectMode({ shell = shellFor("tools/zn") }), "program")
    fs.delete("/startup")
end)

t.case("start exports the api for os.loadAPI and returns it for dofile", function()
    local e = {}
    local r = main.start({}, e)
    t.eq(r, api)
    t.eq(e.send, api.send)
    t.eq(e.version, api.version)
    local r2 = main.start({}, { shell = shellFor("myprog") })
    t.eq(r2, api)
end)

t.case("cli version and help", function()
    printed = {}
    t.eq(main.start({ "version" }, { shell = shellFor("zelnet") }), version.program)
    t.ok(printed[1]:find(version.program, 1, true))
    printed = {}
    main.cli({ "help" }, {})
    t.ok(#printed > 3)
end)

t.case("run without config prints provisioning help on a device", function()
    fs.delete("/.zelnet")
    printed = {}
    main.run({})
    local all = table.concat(printed, "\n")
    t.ok(all:find("provision", 1, true) or all:find("New device", 1, true), all)
end)

local function fakeNode(chunks)
    local n = { log = util.newLogger(20), emitted = {}, requests = 0 }
    function n:request(dst, port, body)
        self.requests = self.requests + 1
        self.lastDst = dst
        if body.op ~= "chunk" then return nil, "bad" end
        local data = chunks[body.i]
        if not data then return { ok = false, err = "no_update" } end
        return { ok = true, i = body.i, data = data }
    end
    function n:emit(ev, ...) self.emitted[#self.emitted + 1] = ev end
    function n:listen(port, fn) self.listener = fn end
    return n
end

local function offerFor(cfg, text, ver)
    local sha = crypto.sha256(text)
    local chunks = {}
    for i = 1, math.ceil(#text / 6000) do chunks[i] = text:sub((i - 1) * 6000 + 1, i * 6000) end
    local offer = {
        op = "offer", version = ver, size = #text, sha = sha, chunks = #chunks,
        mac = crypto.mac(cfg.deviceKey, main.updateAad(ver, #text, sha)),
    }
    return offer, chunks
end

t.case("device update: verified, downloaded and installed", function()
    local scfg = config.newServer({ realm = "MARS" })
    local cfg = config.newDevice(scfg, "client", "bob", 3)
    local text = "return " .. string.format("%q", string.rep("x", 13000))
    local offer, chunks = offerFor(cfg, text, "9.9.9")
    local n = fakeNode(chunks)
    local state = main.attachUpdater(n, cfg, { path = "/zelnet", noReboot = true })
    t.ok(n.listener, "listener registered")
    local res
    env.run(function() res = main.onDeviceUpdate(n, cfg, { src = "MARS", data = offer }, state) end, 60)
    t.eq(res, true)
    t.eq(util.readFile("/zelnet"), text)
    t.eq(n.requests, 3)
    t.eq(n.lastDst, "MARS")
    t.eq(n.emitted[1], "update_installed")
    n.requests = 0
    env.run(function() main.onDeviceUpdate(n, cfg, { src = "MARS", data = offer }, state) end, 60)
    t.eq(n.requests, 0, "same update not fetched twice")
end)

t.case("device update: bad mac, wrong source and bad checksum are refused", function()
    local scfg = config.newServer({ realm = "MARS" })
    local cfg = config.newDevice(scfg, "router", "r1", 3)
    util.writeFile("/zelnet", "old")
    local text = "return 1 " .. string.rep(" ", 100)
    local offer, chunks = offerFor(cfg, text, "9.9.8")
    local n = fakeNode(chunks)
    local state = main.attachUpdater(n, cfg, { noReboot = true })
    local forged = util.copy(offer)
    forged.mac = crypto.mac(crypto.newKey(), main.updateAad("9.9.8", #text, offer.sha))
    env.run(function() main.onDeviceUpdate(n, cfg, { src = "MARS", data = forged }, state) end, 60)
    t.eq(n.requests, 0)
    env.run(function() main.onDeviceUpdate(n, cfg, { src = "EARTH", data = offer }, state) end, 60)
    t.eq(n.requests, 0)
    local same = util.copy(offer)
    same.version = version.program
    same.mac = crypto.mac(cfg.deviceKey, main.updateAad(same.version, #text, offer.sha))
    env.run(function() main.onDeviceUpdate(n, cfg, { src = "MARS", data = same }, state) end, 60)
    t.eq(n.requests, 0, "current version ignored")
    chunks[1] = "return 2 " .. string.rep(" ", 100)
    env.run(function() main.onDeviceUpdate(n, cfg, { src = "MARS", data = offer }, state) end, 60)
    t.eq(util.readFile("/zelnet"), "old")
    t.eq(state.busy, false)
end)

local function fakeModules(order)
    local function mod(name, extra)
        return {
            new = function(ctx)
                local o = { ctx = ctx }
                function o:init() order[#order + 1] = name .. ".init" return true end
                function o:start() order[#order + 1] = name .. ".start" return true end
                function o:onDiskEvent(ev, side) order[#order + 1] = name .. "." .. ev .. ":" .. tostring(side) end
                for k, v in pairs(extra or {}) do o[k] = v end
                return o
            end,
        }
    end
    return {
        storage = mod("storage"),
        server = mod("server"),
        tekmail = mod("tekmail", {
            createUser = function(self, user, pass, opts)
                order[#order + 1] = "createUser:" .. user .. ":" .. tostring(opts.admin)
                return true
            end,
        }),
        airlock = mod("airlock"),
    }
end

t.case("server start order, admin creation, disk events and pullEvent guard", function()
    local order = {}
    local cfg = config.newServer({ realm = "EARTH" })
    local ctx = main.buildServer(cfg, { modules = fakeModules(order), cipher = nil })
    t.ok(ctx.storage and ctx.server and ctx.tekmail and ctx.airlock)
    t.eq(ctx.storage.ctx, ctx)
    local before = os.pullEvent
    local restore = main.guardPullEvent()
    t.eq(os.pullEvent, os.pullEventRaw)
    local console = {
        run = function(c)
            t.eq(c, ctx)
            os.queueEvent("disk", "drive_4")
            sleep(0.5)
            return "exit"
        end,
    }
    local res
    env.run(function()
        res = ctx.node:loop(function()
            return main.serverMain(ctx, { console = console, pendingAdmin = { user = "boss", pass = "pw12" } })
        end)
    end, 30)
    restore()
    t.eq(os.pullEvent, before)
    t.eq(res, "exit")
    t.eq(order[1], "storage.init")
    t.eq(order[2], "server.start")
    t.eq(order[3], "tekmail.start")
    t.eq(order[4], "airlock.start")
    local all = table.concat(order, " ")
    t.ok(all:find("createUser:boss:true", 1, true), all)
    t.ok(all:find("storage.disk:drive_4", 1, true), all)
end)

t.case("runServer with a working cipher block runs the console", function()
    env.setPeripheral("cipher_0", { type = "cipher", methods = {
        encrypt = function(s) return "E" .. s:reverse() end,
        decrypt = function(s) return s:sub(2):reverse() end,
    } })
    local cfg = config.newServer({ realm = "EARTH" })
    local order = {}
    local seen
    local res
    env.run(function()
        res = main.runServer(cfg, {
            modules = fakeModules(order),
            console = { run = function(ctx) seen = ctx.cipher return "stay" end },
        })
    end, 30)
    t.eq(res, "stay")
    t.ok(seen and seen.kind == "hardware", "hardware cipher passed to ctx")
    env.setPeripheral("cipher_0", nil)
end)

t.case("real server modules boot under the console and create an account", function()
    local ft = require("tests.faketerm")
    ft.install(51, 19, true, env.queue)
    ft.reset()
    env.setPeripheral("cipher_0", { type = "cipher", methods = {
        encrypt = function(s) return "E" .. s:reverse() end,
        decrypt = function(s) return s:sub(2):reverse() end,
    } })
    local sui = need("serverui")
    local cfg = config.newServer({ realm = "EARTH" })
    sui.setPassword(cfg, "secret")
    cfg.lockAfter = 0
    local cip = need("cipher").open({})
    local ctx = main.buildServer(cfg, { cipher = cip })
    ft.line("secret")
    ft.key("enter")
    ft.wait(2)
    ft.key("leftCtrl")
    ft.key("down", 2)
    ft.key("enter")
    ft.typeText("n")
    ft.line("alice")
    ft.line("pw1234")
    ft.line("pw1234")
    ft.line("")
    ft.key("enter")
    ft.key("leftCtrl")
    ft.key("up", 3)
    ft.key("enter")
    ft.key("enter")
    local res
    local ok, err = pcall(env.run, function()
        res = ctx.node:loop(function()
            return main.serverMain(ctx, { consoleOpts = { ownThread = function() return true end } })
        end)
    end, 300)
    if not ok then error(tostring(err) .. " script left " .. #ft.script .. "\n" .. term.text(), 0) end
    t.eq(res, "reboot")
    local names = {}
    for _, u in ipairs(ctx.tekmail:listUsers()) do names[#names + 1] = u.name end
    t.eq(table.concat(names, ","), "alice")
    for _, e in ipairs(ctx.log.last(200)) do
        t.ok(e.level ~= "error", "logged error: " .. tostring(e.text))
    end
    env.setPeripheral("cipher_0", nil)
end)

t.case("crash handler writes the crash file", function()
    local r = main.crash("boom", false)
    t.eq(r, "crash")
    t.ok(util.readFile(main.CRASH_PATH):find("boom", 1, true))
end)

t.case("Ctrl+T cannot stop a guarded server", function()
    local order = {}
    local cfg = config.newServer({ realm = "EARTH" })
    local ctx = main.buildServer(cfg, { modules = fakeModules(order), cipher = nil })
    local restore = main.guardPullEvent()
    local console = {
        run = function()
            os.queueEvent("terminate")
            sleep(0.5)
            os.queueEvent("terminate")
            compat.yieldNow()
            os.queueEvent("zn_test")
            local ev = os.pullEvent("zn_test")
            return ev
        end,
    }
    local res
    local ok, err = pcall(env.run, function()
        os.queueEvent("terminate")
        res = ctx.node:loop(function()
            os.queueEvent("terminate")
            return main.serverMain(ctx, { console = console })
        end)
    end, 30)
    restore()
    t.ok(ok, tostring(err))
    t.eq(res, "zn_test")
end)

t.case("server crash screen needs the console password for the shell", function()
    local sui = need("serverui")
    local ft = require("tests.faketerm")
    ft.feedRaw()
    local cfg = config.newServer({ realm = "EARTH" })
    sui.setPassword(cfg, "pw12")
    local reboots = 0
    local realReboot = os.reboot
    os.reboot = function() reboots = reboots + 1 end
    local res
    ft.reset()
    ft.event("terminate")
    ft.key("enter")
    ft.line("x")
    ft.line("pw12")
    env.run(function() res = main.crash("boom", true, cfg) end, 60)
    t.eq(res, "crash")
    t.eq(reboots, 0, "right password keeps the shell")
    ft.reset()
    ft.event("terminate")
    ft.line("x")
    env.run(function() res = main.crash("boom", true, cfg) end, 60)
    t.eq(reboots, 1, "wrong password and Ctrl+T end in a reboot")
    ft.reset()
    res = nil
    ft.typeText("q")
    env.run(function() res = main.crash("boom", true, config.newServer({ realm = "EARTH" })) end, 60)
    t.eq(res, "crash")
    t.eq(reboots, 1, "no console password yet: any key gives the shell")
    ft.reset()
    os.reboot = realReboot
end)

t.case("pending admin creation retries while Main is offline", function()
    local cfg = config.newServer({ realm = "MARS" })
    local log = util.newLogger(20)
    local n = need("node").new(cfg, { log = log })
    local tries = 0
    local ctx = { log = log, node = n, tekmail = { createUser = function(_, user, pass, opts)
        tries = tries + 1
        if tries < 3 then return nil, "offline" end
        return true
    end } }
    env.run(function()
        n:loop(function()
            main.createPendingAdmin(ctx, { user = "boss", pass = "pw12" })
            sleep(main.ADMIN_RETRY * 3)
        end)
    end, main.ADMIN_RETRY * 4)
    t.eq(tries, 3)
    tries = -100
    local calls = 0
    ctx.tekmail.createUser = function() calls = calls + 1 return nil, "taken" end
    env.run(function()
        n:loop(function()
            main.createPendingAdmin(ctx, { user = "boss", pass = "pw12" })
            sleep(main.ADMIN_RETRY * 2)
        end)
    end, main.ADMIN_RETRY * 4)
    t.eq(calls, 1, "a taken name is not retried")
end)

t.finish()
