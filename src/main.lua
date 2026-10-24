local need = ...
local compat = need("compat")
local util = need("util")
local crypto = need("crypto")
local config = need("config")
local version = need("version")

local M = {}

M.PROGRAM_NAMES = { zelnet = true, ["zelnet.lua"] = true }
M.PROGRAM_PATH = "/zelnet"
M.CRASH_PATH = "/.zelnet/crash.txt"
M.CONNECT_WAIT = 20
M.UPDATE_DELAY = 5
M.CRASH_REBOOT = 15
M.ADMIN_RETRY = 20
M.ADMIN_TRIES = 15
M.ADMIN_FINAL = { taken = true, bad_name = true, weak_password = true }

M.out = function(text, color)
    if color and term and term.isColor and term.isColor() then term.setTextColor(color) end
    print(text)
    if color and term and term.isColor and term.isColor() then term.setTextColor(colors.white) end
end

local function say(text, color)
    return M.out(text, color)
end

local function packn(...)
    return { n = select("#", ...), ... }
end

local function tryNeed(name)
    local ok, mod = pcall(need, name)
    if ok then return mod end
    return nil, mod
end

function M.fileIsBundle(path)
    if type(path) ~= "string" or not fs.exists(path) or fs.isDir(path) then return nil end
    local h = fs.open(path, "r")
    if not h then return nil end
    local line = h.readLine()
    h.close()
    if type(line) ~= "string" then return false end
    return line:find("__mods", 1, true) ~= nil
end

function M.detectMode(env)
    env = env or {}
    local sh = env.shell
    if type(sh) ~= "table" or type(sh.getRunningProgram) ~= "function" then return "api" end
    local ok, prog = pcall(sh.getRunningProgram)
    if not ok or type(prog) ~= "string" or prog == "" then return "library" end
    local path = "/" .. prog:gsub("^/+", "")
    local name = (path:match("([^/]+)$") or path):lower()
    local bundle = M.fileIsBundle(path)
    if bundle == true then return "program", path end
    if M.PROGRAM_NAMES[name] then return "program", path end
    if name == "startup" and bundle == nil then return "program", path end
    return "library", path
end

function M.start(args, env)
    env = env or {}
    local mode, path = M.detectMode(env)
    local api = need("api")
    if mode == "api" then
        for k, v in pairs(api) do env[k] = v end
        return api
    end
    if mode == "library" then return api end
    compat.settle()
    local prov = tryNeed("provision")
    if prov and path and M.fileIsBundle(path) then prov.setProgramPath(path) end
    M.programPath = path
    return M.cli(args or {}, env)
end

function M.usage()
    say("ZelNet " .. version.program, colors.cyan)
    say("Usage:")
    say("  zelnet              start this computer's role")
    say("  zelnet setup        server setup wizard")
    say("  zelnet status       show this computer's ZelNet status")
    say("  zelnet send <addr> <port> <text>")
    say("  zelnet ping <addr>")
    say("  zelnet version")
    say("  zelnet update [url]  download the newest program from the repo")
    say("Programs load the library with dofile(\"/zelnet\").")
end

function M.cli(args, env)
    local cmd = type(args[1]) == "string" and args[1]:lower() or "run"
    if cmd == "help" or cmd == "-h" or cmd == "?" then
        M.usage()
        return
    elseif cmd == "version" then
        say("ZelNet " .. version.label() .. " (" .. version.full() .. ", protocol " .. version.protocol .. ")")
        return version.program
    elseif cmd == "setup" then
        return M.setupCommand(env)
    elseif cmd == "status" then
        return M.statusCommand()
    elseif cmd == "send" then
        local text = {}
        for i = 4, #args do text[#text + 1] = tostring(args[i]) end
        return M.sendCommand(args[2], args[3], table.concat(text, " "))
    elseif cmd == "ping" then
        return M.pingCommand(args[2])
    elseif cmd == "update" then
        return M.updateCommand(args[2])
    elseif cmd == "run" then
        return M.run({ env = env })
    end
    say("Unknown command: " .. tostring(args[1]), colors.red)
    M.usage()
end

function M.updateCommand(url)
    local up = tryNeed("updater")
    if not up then
        say("This computer gets ZelNet updates from its server.", colors.yellow)
        return
    end
    local cfg = M.loadConfig()
    if cfg and cfg.role == "satellite" then
        say("Satellites run Main's version and update from Main by themselves.", colors.yellow)
        say("Update Main (" .. tostring(cfg.mainRealm) .. ") and this server follows within minutes.")
        return
    end
    local opts = cfg or {}
    if url then opts = { updateUrl = url } end
    say("ZelNet " .. version.label() .. " (" .. version.full() .. ") installed.")
    say("Downloading " .. up.url(opts) .. " ...")
    local got, err = up.fetch(opts)
    if not got then
        say(tostring(err), colors.red)
        return
    end
    if got.same then
        say("Already up to date (" .. got.label .. ").", colors.lime)
        return got.version
    end
    local path = (cfg and cfg.programPath) or M.PROGRAM_PATH
    local ok, ierr = up.install(got.text, path)
    if not ok then
        say("Cannot install: " .. tostring(ierr), colors.red)
        return
    end
    say("Installed ZelNet " .. got.label .. " (" .. util.fmtBytes(got.size) .. ") as " .. path .. ".", colors.lime)
    if cfg and cfg.role == "main" then
        say("After this server reboots, every satellite, router and client is brought to " .. got.label .. " by itself.")
    end
    say("Reboot or run zelnet to start it.")
    return got.version
end

function M.stage(text)
    if term and term.isColor and term.isColor() then term.setTextColor(colors.lightGray) end
    print("ZelNet: " .. text)
    if term and term.isColor and term.isColor() then term.setTextColor(colors.white) end
end

function M.loadConfig(path)
    return config.load(path or M.configPath)
end

function M.provisionHelp()
    say("This computer is not part of a ZelNet network yet.", colors.yellow)
    say("To add it as a client, router or endpoint:")
    say("  1. On a ZelNet server open Devices, New device.")
    say("  2. Put the disk in this computer's drive and reboot.")
    say("To make this computer a server run: zelnet setup")
end

function M.serverCapable()
    local cip = tryNeed("cipher")
    if not cip then return false end
    local ok, name = pcall(cip.findName)
    return ok and name ~= nil
end

function M.run(opts)
    opts = opts or {}
    M.stage("reading the config")
    local cfg, err = M.loadConfig(opts.path)
    if not cfg then
        if err == "not configured" then
            if M.serverCapable() and tryNeed("serverui") then return M.setupCommand(opts.env) end
            M.provisionHelp()
            return
        end
        say("ZelNet config problem: " .. tostring(err), colors.red)
        say("Servers: run zelnet setup. Devices: reinstall from a provisioning disk.")
        return
    end
    if config.isServer(cfg) then
        if type(cfg.console) ~= "table" then
            local sui = tryNeed("serverui")
            if not sui then
                say("This program copy has no server console. Install the full program.", colors.red)
                return
            end
            local scfg, extra = sui.setup({ cfg = cfg, path = opts.path or M.configPath })
            if not scfg then return end
            cfg = scfg
            opts.pendingAdmin = extra and extra.admin
        end
        M.stage("starting the " .. tostring(cfg.role) .. " server " .. tostring(cfg.realm))
        return M.runServer(cfg, opts)
    end
    return M.runDevice(cfg, opts)
end

function M.setupCommand(env)
    local sui, err = tryNeed("serverui")
    if not sui then
        say("This program copy is a device build without the server setup.", colors.red)
        say(tostring(err))
        return
    end
    local existing = M.loadConfig()
    if existing and not config.isServer(existing) then
        say("This computer is a ZelNet " .. tostring(existing.role) .. ".", colors.yellow)
        say("Delete /.zelnet/config first to turn it into a server.")
        return
    end
    local cfg, extra = sui.setup({ cfg = existing, path = M.configPath, programPath = M.programPath })
    if not cfg then return end
    if extra and extra.start == false then return cfg end
    return M.runServer(cfg, { pendingAdmin = extra and extra.admin, env = env })
end

function M.openCipher(cfg)
    local cip = need("cipher")
    local opts = { preferred = cfg.cipherName }
    if cfg.allowSoftwareBackbone then opts.softwareKey = cfg.backboneKey end
    return cip.open(opts)
end

function M.guardPullEvent()
    local oldEvent, oldRaw = os.pullEvent, os.pullEventRaw
    local function guarded(filter)
        while true do
            local ev = packn(oldRaw(filter))
            if ev[1] ~= "terminate" then return compat.unpack(ev, 1, ev.n) end
        end
    end
    os.pullEventRaw = guarded
    os.pullEvent = guarded
    return function()
        os.pullEvent = oldEvent
        os.pullEventRaw = oldRaw
    end
end

function M.buildServer(cfg, opts)
    opts = opts or {}
    local node = need("node")
    local log = opts.log or util.newLogger(400)
    local n = node.new(cfg, { log = log })
    local ctx = {
        cfg = cfg, log = log, node = n, cipher = opts.cipher, version = version,
        configPath = opts.configPath or M.configPath,
        emit = function(event, ...) n:emit(event, ...) end,
    }
    local mods = opts.modules or {}
    local storage = mods.storage or need("storage")
    local server = mods.server or need("server")
    local tekmail = mods.tekmail or need("tekmail")
    local airlock = mods.airlock or need("airlock")
    ctx.storage = storage.new(ctx)
    ctx.server = server.new(ctx)
    ctx.tekmail = tekmail.new(ctx)
    ctx.airlock = airlock.new(ctx)
    local api = tryNeed("api")
    if api then api.attach(n) end
    return ctx
end

function M.startServer(ctx)
    M.stage("checking the storage drives")
    local okInit, problems = ctx.storage:init()
    if not okInit and type(problems) == "table" then
        for _, p in ipairs(problems) do ctx.log.warn("storage: " .. tostring(p)) end
    end
    M.stage("starting the network")
    ctx.server:start()
    ctx.tekmail:start()
    ctx.airlock:start()
    local n = ctx.node
    n:spawn(function()
        while true do
            local ev, side = os.pullEventRaw()
            if ev == "disk" or ev == "disk_eject" then
                local ok, err = pcall(ctx.storage.onDiskEvent, ctx.storage, ev, side)
                if not ok then ctx.log.error("disk event: " .. tostring(err)) end
                n:emit(ev, side)
            end
        end
    end, "disks")
    ctx.log.info("ZelNet " .. version.program .. " " .. ctx.cfg.role .. " " .. ctx.cfg.realm .. " running")
end

function M.createPendingAdmin(ctx, admin)
    if type(admin) ~= "table" or not admin.user or not admin.pass then return end
    ctx.node:spawn(function()
        local tries = 0
        while true do
            tries = tries + 1
            local ok, err = ctx.tekmail:createUser(admin.user, admin.pass, { admin = true, actor = "setup", display = admin.display })
            if ok then
                ctx.log.info("admin account " .. tostring(admin.user) .. " created")
                return
            end
            if M.ADMIN_FINAL[err] or tries >= M.ADMIN_TRIES then
                ctx.log.warn("could not create admin account " .. tostring(admin.user) .. ": " .. tostring(err) .. "; create it under Accounts")
                return
            end
            compat.sleep(M.ADMIN_RETRY)
        end
    end, "setup-admin")
end

function M.serverMain(ctx, opts)
    M.startServer(ctx)
    M.createPendingAdmin(ctx, opts.pendingAdmin)
    local sui = opts.console or need("serverui")
    return sui.run(ctx, opts.consoleOpts)
end

function M.serveGuarded(cfg, opts, log)
    M.stage("opening the cipher block")
    local cip, msg = M.openCipher(cfg)
    while not cip do
        log.warn(tostring(msg))
        local sui = tryNeed("serverui")
        local choice = sui and sui.cipherGuide(cfg, msg) or "local"
        if choice == "exit" then return "exit" end
        if choice == "local" then break end
        cip, msg = M.openCipher(cfg)
    end
    if cip and cip.kind == "software" then
        log.warn(tostring(msg or "using the software cipher"))
    elseif not cip then
        log.warn("no working cipher block: the backbone stays off, this realm works on its own")
    end
    M.stage("loading storage and services")
    local ctx = M.buildServer(cfg, { log = log, cipher = cip, configPath = opts.path, modules = opts.modules })
    M.stage("starting the console")
    return ctx.node:loop(function() return M.serverMain(ctx, opts) end)
end

function M.runServer(cfg, opts)
    opts = opts or {}
    local log = opts.log or util.newLogger(400)
    local restore = M.guardPullEvent()
    local ok, res = pcall(M.serveGuarded, cfg, opts, log)
    if not ok then
        local cok, cres = pcall(M.crash, res, true, cfg)
        restore()
        return cok and cres or "crash"
    end
    restore()
    if res == "reboot" then
        say("Rebooting...")
        os.reboot()
    end
    if res == "exit" then
        if term and term.clear then
            term.setBackgroundColor(colors.black)
            term.setTextColor(colors.white)
            term.clear()
            term.setCursorPos(1, 1)
        end
        say("ZelNet server stopped. Run zelnet or reboot to start it again.", colors.yellow)
    end
    return res
end

function M.appFor(n, cfg)
    if cfg.role == "client" then
        local clientui = need("clientui")
        return function() return clientui.run(n) end
    end
    local routerui = need("routerui")
    local mode = cfg.role == "endpoint" and "endpoint" or "router"
    return function() return routerui.run(n, { mode = mode }) end
end

function M.attachGateway(n, cfg)
    local gateway = tryNeed("gateway")
    if not gateway then return nil end
    local function toServer(body) n:send(n.realm, gateway.CONTROL, body) end
    local gw = gateway.new(n, {
        isOff = function() return cfg.publicGateway == false end,
        relay = function(cid, msg) n:send(n.realm, gateway.ALK_PORT, { cid = cid, msg = msg }) end,
        backend = {
            seen = function(cid) toServer({ op = "seen", cid = cid }) end,
            blocked = function() return false end,
            connected = function() return n:isConnected() end,
            op = toServer,
        },
    })
    n:listen(gateway.CONTROL, function(msg)
        local a = util.parseAddress(msg.src)
        local b = msg.data
        if not a or a.realm ~= n.realm or a.id or a.name or type(b) ~= "table" then return end
        if b.op == "deliver" then gw:transmit(b.cid, b.msg) end
    end)
    n:listen(gateway.ALK_PORT, function(msg)
        local a = util.parseAddress(msg.src)
        local b = msg.data
        if not a or a.realm ~= n.realm or a.id or a.name or type(b) ~= "table" or type(b.msg) ~= "table" then return end
        if b.op == "deliver" then
            gw:transmit(b.cid, b.msg, true)
        elseif b.op == "broadcast" then
            gw:transmit(gateway.BROADCAST, b.msg, true)
        end
    end)
    gw:start()
    return gw
end

function M.runDevice(cfg, opts)
    opts = opts or {}
    local node = need("node")
    local log = opts.log or util.newLogger(300)
    local n = node.new(cfg, { log = log })
    local api = tryNeed("api")
    if api then api.attach(n) end
    M.attachUpdater(n, cfg, opts.update)
    if cfg.role == "router" then M.attachGateway(n, cfg) end
    local app = opts.app or M.appFor(n, cfg)
    local ok, err = pcall(function() return n:loop(app) end)
    pcall(n.close, n)
    if not ok then
        if tostring(err):find("Terminated", 1, true) then
            say("ZelNet stopped.", colors.yellow)
            return "terminated"
        end
        return M.crash(err, opts.restart ~= false)
    end
    return "exit"
end

function M.crash(err, isServer, cfg)
    local text = tostring(err)
    pcall(util.writeFile, M.CRASH_PATH, "ZelNet " .. version.program .. " stopped at " .. util.fmtStamp(compat.stamp()) .. "\n" .. text .. "\n")
    if term and term.setBackgroundColor then
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.white)
        term.setCursorBlink(false)
        term.clear()
        term.setCursorPos(1, 1)
    end
    say("ZelNet stopped with an error:", colors.red)
    say(text)
    say("Saved to " .. M.CRASH_PATH)
    if not isServer then return "crash" end
    local guard = type(cfg) == "table" and type(cfg.console) == "table" and cfg.console or nil
    if guard then
        say("Rebooting in " .. M.CRASH_REBOOT .. " seconds. Type the console password and Enter to stay in the shell.", colors.yellow)
    else
        say("Rebooting in " .. M.CRASH_REBOOT .. " seconds. Press any key to stay in the shell.", colors.yellow)
    end
    local timer = os.startTimer(M.CRASH_REBOOT)
    local typed = ""
    while true do
        local ev, a = os.pullEventRaw()
        if ev == "timer" and a == timer then
            os.reboot()
            return "crash"
        elseif not guard then
            if ev == "key" or ev == "char" then return "crash" end
        elseif ev == "char" and #typed < 64 then
            typed = typed .. a
            if term and term.write then term.write("*") end
        elseif ev == "key" and a == keys.backspace then
            typed = typed:sub(1, -2)
        elseif ev == "key" and a == keys.enter and typed ~= "" then
            if M.consolePassword(guard, typed) then return "crash" end
            typed = ""
            print("")
            say("Wrong password.", colors.red)
        end
    end
end

function M.consolePassword(c, pw)
    if type(c) ~= "table" or type(c.salt) ~= "string" or type(c.hash) ~= "string" or type(pw) ~= "string" then return false end
    return crypto.constEq(crypto.passwordHash(c.salt, pw), c.hash) == true
end

function M.updateAad(ver, size, sha)
    return "zn.update|" .. tostring(ver) .. "|" .. tostring(size) .. "|" .. tostring(sha)
end

function M.validOffer(b)
    return type(b) == "table" and b.op == "offer" and type(b.version) == "string" and #b.version <= 24
        and type(b.sha) == "string" and #b.sha == 64 and type(b.size) == "number" and b.size > 0 and b.size < 2000000
        and type(b.chunks) == "number" and b.chunks == math.ceil(b.size / 6000) and type(b.mac) == "string"
end

function M.attachUpdater(n, cfg, opts)
    local state = { busy = false, done = nil, path = (opts and opts.path) or cfg.programPath or M.PROGRAM_PATH, opts = opts or {} }
    n:listen("zn.update", function(msg) M.onDeviceUpdate(n, cfg, msg, state) end)
    return state
end

function M.fetchUpdate(n, authority, b)
    local parts = {}
    for i = 1, b.chunks do
        local reply, err = n:request(authority, "zn.update", { op = "chunk", sha = b.sha, i = i }, 30, { retries = 2 })
        if type(reply) ~= "table" or not reply.ok or type(reply.data) ~= "string" then
            return nil, "download failed: " .. tostring(err or (type(reply) == "table" and reply.err) or "bad reply")
        end
        parts[i] = reply.data
    end
    local text = table.concat(parts)
    if #text ~= b.size or crypto.sha256(text) ~= b.sha then return nil, "checksum mismatch" end
    local fn, cerr = loadstring(text, "=zelnet")
    if not fn then return nil, "does not compile: " .. tostring(cerr) end
    return text
end

function M.replaceFile(path, text)
    local tmp = path .. ".dl"
    local ok, err = util.writeFile(tmp, text)
    if not ok then
        pcall(fs.delete, tmp)
        return nil, err
    end
    if fs.exists(path) then fs.delete(path) end
    fs.move(tmp, path)
    return true
end

function M.onDeviceUpdate(n, cfg, msg, state)
    local b = msg.data
    if not M.validOffer(b) then return end
    local authority = (type(cfg.authority) == "table" and cfg.authority.realm) or cfg.realm
    if msg.src ~= authority then return end
    if type(cfg.deviceKey) ~= "string" then return end
    local want = crypto.mac(cfg.deviceKey, M.updateAad(b.version, b.size, b.sha))
    if not crypto.constEq(want, b.mac) then
        n.log.warn("rejected an update offer with a bad signature")
        return
    end
    if b.version == version.full() or state.busy or state.done == b.sha then return end
    state.busy = true
    n.log.info("downloading update " .. version.labelOf(b.version, b.rel))
    local text, err = M.fetchUpdate(n, authority, b)
    if not text then
        state.busy = false
        n.log.warn("update " .. b.version .. ": " .. tostring(err))
        return
    end
    local prov = tryNeed("provision")
    local build = text
    local full = prov and prov.expand and prov.expand(text) or text
    if prov and full and prov.isBundle(full) then
        local okB, trimmed = pcall(prov.deviceBuild, full)
        if okB and type(trimmed) == "string" and loadstring(trimmed, "=zelnet") then build = trimmed end
    end
    full = nil
    local ok, werr = M.replaceFile(state.path, build)
    state.busy = false
    if not ok then
        n.log.warn("cannot install update " .. b.version .. ": " .. tostring(werr))
        return
    end
    state.done = b.sha
    n.log.warn("update " .. version.labelOf(b.version, b.rel) .. " installed, rebooting")
    n:emit("update_installed", b.version)
    if state.opts.noReboot then return true end
    compat.sleep(state.opts.delay or M.UPDATE_DELAY)
    os.reboot()
    return true
end

function M.withDevice(fn, wait)
    local cfg, err = M.loadConfig()
    if not cfg then
        if err == "not configured" then M.provisionHelp() else say("ZelNet config problem: " .. tostring(err), colors.red) end
        return nil
    end
    if config.isServer(cfg) then
        say("This computer is a ZelNet server. Use its console.", colors.yellow)
        return nil
    end
    local node = need("node")
    local n = node.new(cfg, { log = util.newLogger(50) })
    local result = n:loop(function()
        local t0 = compat.now()
        while not n:isConnected() and compat.now() - t0 < (wait or M.CONNECT_WAIT) do sleep(0.5) end
        return fn(n, n:isConnected())
    end)
    pcall(n.close, n)
    return result
end

function M.statusCommand()
    local cfg, err = M.loadConfig()
    if not cfg then
        if err == "not configured" then M.provisionHelp() else say("ZelNet config problem: " .. tostring(err), colors.red) end
        return
    end
    say("ZelNet " .. version.program .. " " .. cfg.role, colors.cyan)
    say("Network: " .. tostring(cfg.network) .. "  Realm: " .. tostring(cfg.realm))
    if config.isServer(cfg) then
        say("Main realm: " .. tostring(cfg.mainRealm))
        local d = cfg.displays or {}
        say("Bridges: " .. #(cfg.bridges or {}) .. "  Setup drive: " .. tostring(d.drive or "none"))
        say("Console password: " .. (type(cfg.console) == "table" and "set" or "not set, run zelnet setup"))
        return cfg.role
    end
    say("Device: " .. tostring(cfg.name) .. "  Computer: " .. tostring(os.getComputerID()))
    return M.withDevice(function(n, connected)
        local st = n:status()
        if connected then
            say("Connected as " .. tostring(st.address) .. ", " .. tostring(st.hops) .. " hops via " .. tostring(st.parent), colors.lime)
        else
            say("Not connected to " .. tostring(cfg.realm) .. " (no beacon or no answer)", colors.red)
        end
        for _, l in ipairs(st.links or {}) do say("  link " .. tostring(l.id) .. (l.open and "" or " (closed)")) end
        return connected
    end, 12)
end

function M.sendCommand(addr, port, text)
    if not addr or not port then
        say("Usage: zelnet send <addr> <port> <text>")
        return
    end
    return M.withDevice(function(n, connected)
        if not connected then
            say("Not connected; the packet waits until the network is back.", colors.yellow)
        end
        local id, err = n:send(addr, port, text)
        if not id then
            say("Send failed: " .. tostring(err), colors.red)
            return nil
        end
        sleep(1)
        say("Sent " .. tostring(id) .. " to " .. tostring(addr) .. " port " .. tostring(port), colors.lime)
        return id
    end)
end

function M.pingCommand(addr)
    return M.withDevice(function(n, connected)
        local target = addr or n.realm
        if not connected then
            say("Not connected to " .. tostring(n.realm), colors.red)
            return nil
        end
        local t, err = n:ping(target, 15)
        if t then
            say("Reply from " .. tostring(target) .. " in " .. util.fmtFixed(t, 2) .. " s", colors.lime)
        else
            say("No reply from " .. tostring(target) .. ": " .. tostring(err), colors.red)
        end
        return t
    end)
end

return M
