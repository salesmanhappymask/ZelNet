package.path = "./?.lua;" .. package.path
local env = require("tests.fakecc").install({ id = 7 })
require("tests.faketerm").install()
local need = require("tools.devload").make(".")
local prov = need("provision")
local codec = need("codec")
local config = need("config")
local util = need("util")
local t = require("tests.tiny")

_G.disk = {
    hasData = function(n) return peripheral.isPresent(n) and peripheral.call(n, "hasData") end,
    getMountPath = function(n) return peripheral.call(n, "getMountPath") end,
}
_G.print = function() end
_G.write = function() end

local function fakeDrive(name, mount, id)
    local d = { present = true, data = true, label = nil, id = id }
    env.setPeripheral(name, { type = "drive", methods = {
        isDiskPresent = function() return d.present end,
        hasData = function() return d.present and d.data end,
        getMountPath = function() if d.present and d.data then return mount end return nil end,
        getDiskLabel = function() return d.label end,
        setDiskLabel = function(l) d.label = l end,
        getDiskID = function() return d.id end,
    } })
    fs.makeDir("/" .. mount)
    return d
end

local function clearDir(dir)
    for _, f in ipairs(fs.list(dir)) do fs.delete(dir .. "/" .. f) end
end

local function fakeBundle(extra)
    local parts = {
        "local __mods, __cache, __loading = {}, {}, {}\n",
        "local function need(name)\n    return __mods[name](need)\nend\n",
        "__mods[\"util\"] = function(...)\n    local M = {}\n    function M.hi()\n        return \"hi `tick` [[x]]\"\n    end\n    return M\nend\n",
        "__mods[\"server\"] = function(...)\n    return { big = \"" .. string.rep("server code ", 20) .. "\" }\nend\n",
        "__mods[\"main\"] = function(...)\n    local M = {}\n    function M.start() return \"started\" end\n    M.pad = \"" .. (extra or "") .. "\"\n    return M\nend\n",
        "return need(\"main\").start({...}, getfenv(1))\n",
    }
    return table.concat(parts)
end

local function randomText(n, seed)
    math.randomseed(seed)
    local words = { "local ", "function ", "end\n", "self.", "return ", "`", "``", "if ", "then ", "x", "y", "=", " ", "\n", "{}", "util.fmt" }
    local out = {}
    local len = 0
    while len < n do
        local w = words[math.random(#words)]
        if math.random() < 0.2 then w = string.char(math.random(32, 126)) end
        out[#out + 1] = w
        len = len + #w
    end
    return table.concat(out)
end

local function serverCfg()
    return config.newServer({ realm = "EARTH", network = "TestNet" })
end

t.case("pack and unpack round trip, including backticks", function()
    for seed = 1, 6 do
        local s = randomText(20000 + seed * 1000, seed)
        local p = prov.pack(s)
        t.eq(prov.unpack(p), s, "seed " .. seed)
        t.ok(not p:find("[^\n -~]"), "packed text is printable ASCII")
    end
    t.eq(prov.unpack(prov.pack("")), "")
    t.eq(prov.unpack(prov.pack("`")), "`")
    local rep = string.rep("abcdefghij", 3000)
    local p = prov.pack(rep)
    t.ok(#p < #rep / 10, "repetitive text compresses")
    t.eq(prov.unpack(p), rep)
end)

t.case("unpack rejects corrupt data", function()
    t.eq(prov.unpack("abc`"), nil)
    t.eq(prov.unpack("`$$$"), nil)
end)

t.case("minify strips indentation but keeps long strings", function()
    local src = "local a = 1\n\n    local b = [==[\n  keep  \n]==]\n        return a\n"
    local m = prov.minify(src)
    t.eq(m, "local a = 1\nlocal b = [==[\n  keep  \n]==]\nreturn a\n")
end)

t.case("deviceBuild drops server modules and still compiles", function()
    local b = fakeBundle()
    local d = prov.deviceBuild(b)
    t.ok(not d:find("server code", 1, true), "server module removed")
    t.ok(d:find("__mods[\"util\"]", 1, true), "util kept")
    t.ok(d:find("__mods[\"main\"]", 1, true), "main kept")
    local fn = assert(loadstring(d))
    t.eq(fn(), "started")
    t.ok(prov.isBundle(d))
    t.eq(prov.splitBundle("not a bundle"), nil)
end)

t.case("drives lists drives with disk state and honours exclusions", function()
    local d1 = fakeDrive("drive_1", "disk", 11)
    local d2 = fakeDrive("drive_2", "disk2", 12)
    clearDir("/disk")
    clearDir("/disk2")
    util.writeFile("/disk2/notes.txt", "hello")
    local list = prov.drives()
    t.eq(#list, 2)
    t.eq(list[1].name, "drive_1")
    t.eq(list[1].empty, true)
    t.eq(list[2].foreign, 1)
    local cfg = serverCfg()
    cfg.storage.drives.mail = "drive_2"
    local ex = prov.excludeFor(cfg)
    t.eq(#prov.drives(ex), 1)
    d2.present = false
    local l2 = prov.drives({ "drive_1" })
    t.eq(#l2, 1)
    t.eq(l2[1].present, false)
    d2.present = true
    t.ok(d1)
end)

t.case("writeDisk writes program, config, installer and label", function()
    fakeDrive("drive_1", "disk", 11)
    clearDir("/disk")
    local scfg = serverCfg()
    local dcfg = config.newDevice(scfg, "client", "bob", 7)
    local ok, info = prov.writeDisk("drive_1", dcfg, { programText = fakeBundle() })
    t.ok(ok, tostring(info))
    t.eq(info.parts, 1)
    t.ok(fs.exists("/disk/zelnet"), "program")
    t.ok(fs.exists("/disk/startup"), "installer")
    local back = codec.decode(util.readFile("/disk/zelnet.cfg"))
    t.eq(back.name, "bob")
    t.eq(back.deviceKey, dcfg.deviceKey)
    t.eq(peripheral.call("drive_1", "getDiskLabel"), "ZelNet client bob")
    t.ok(loadstring(util.readFile("/disk/startup")) ~= nil, "installer compiles")
    t.eq(util.readFile("/disk/zelnet"), prov.deviceBuild(fakeBundle()))
end)

t.case("writeDisk refuses a disk with foreign files unless told to wipe", function()
    fakeDrive("drive_1", "disk", 11)
    clearDir("/disk")
    util.writeFile("/disk/game", "print(1)")
    local dcfg = config.newDevice(serverCfg(), "router", "r1", 7)
    local ok, err = prov.writeDisk("drive_1", dcfg, { programText = fakeBundle() })
    t.eq(ok, nil)
    t.ok(tostring(err):find("other file"), tostring(err))
    ok = prov.writeDisk("drive_1", dcfg, { programText = fakeBundle(), wipe = true })
    t.ok(ok)
    t.ok(not fs.exists("/disk/game"), "wiped")
    local bad, berr = prov.writeDisk("nodrive", dcfg, { programText = fakeBundle() })
    t.eq(bad, nil)
    t.ok(berr)
end)

local function runInstaller(mount, opts)
    opts = opts or {}
    local src = util.readFile("/" .. mount .. "/startup")
    local fn = assert(loadstring(src, "=installer"))
    local state = { rebooted = false, ran = {}, label = opts.label }
    local envT = setmetatable({
        shell = {
            getRunningProgram = function() return mount .. "/startup" end,
            run = function(p) state.ran[#state.ran + 1] = p return true end,
        },
        print = function() end,
    }, { __index = _G })
    local oldReboot, oldLabel, oldSet = os.reboot, os.getComputerLabel, os.setComputerLabel
    os.reboot = function() state.rebooted = true end
    os.getComputerLabel = function() return state.label end
    os.setComputerLabel = function(l) state.label = l end
    setfenv(fn, envT)
    env.run(fn, 600)
    os.reboot, os.getComputerLabel, os.setComputerLabel = oldReboot, oldLabel, oldSet
    return state
end

local function resetComputer()
    for _, p in ipairs({ "/zelnet", "/startup", "/startup.old", "/.zelnet" }) do fs.delete(p) end
end

t.case("installer installs a client and reboots", function()
    resetComputer()
    fakeDrive("drive_1", "disk", 11)
    clearDir("/disk")
    util.writeFile("/startup", "print('old')")
    local dcfg = config.newDevice(serverCfg(), "client", "bob", 7)
    assert(prov.writeDisk("drive_1", dcfg, { programText = fakeBundle() }))
    local cfgText = util.readFile("/disk/zelnet.cfg")
    local st = runInstaller("disk")
    t.eq(util.readFile("/zelnet"), prov.deviceBuild(fakeBundle()))
    t.eq(util.readFile("/.zelnet/config"), cfgText)
    t.eq(util.readFile("/startup"), "shell.run(\"/zelnet\")\n")
    t.eq(util.readFile("/startup.old"), "print('old')")
    t.ok(not fs.exists("/disk/zelnet.cfg"), "disk config erased")
    t.eq(st.label, "bob")
    t.ok(st.rebooted, "rebooted")
    local loaded = config.load()
    t.eq(loaded.role, "client")
    t.eq(loaded.name, "bob")
    local again = runInstaller("disk")
    t.eq(again.ran[1], "/zelnet")
    t.eq(again.rebooted, false)
end)

t.case("installer for an endpoint writes no startup and does not reboot", function()
    resetComputer()
    fakeDrive("drive_1", "disk", 11)
    clearDir("/disk")
    local dcfg = config.newDevice(serverCfg(), "endpoint", "sensor1", 7)
    assert(prov.writeDisk("drive_1", dcfg, { programText = fakeBundle() }))
    local st = runInstaller("disk", { label = "keep" })
    t.ok(fs.exists("/zelnet"))
    t.ok(not fs.exists("/startup"), "no startup for endpoints")
    t.eq(st.rebooted, false)
    t.eq(st.label, "keep")
end)

t.case("installer refuses to overwrite a server", function()
    resetComputer()
    fakeDrive("drive_1", "disk", 11)
    clearDir("/disk")
    local scfg = serverCfg()
    config.save(scfg)
    util.writeFile("/zelnet", "server program")
    local dcfg = config.newDevice(scfg, "client", "bob", 7)
    assert(prov.writeDisk("drive_1", dcfg, { programText = fakeBundle() }))
    local st = runInstaller("disk")
    t.eq(util.readFile("/zelnet"), "server program")
    t.eq(config.load().role, "main")
    t.ok(fs.exists("/disk/zelnet.cfg"), "disk left alone")
    t.eq(st.ran[1], "/zelnet")
end)

t.case("packed multi disk set installs from two drives", function()
    resetComputer()
    local big = fakeBundle(randomText(60000, 99):gsub("[\"\\\n]", "q"))
    fakeDrive("drive_1", "disk", 11)
    fakeDrive("drive_2", "disk2", 12)
    clearDir("/disk")
    clearDir("/disk2")
    local realFree = fs.getFreeSpace
    fs.getFreeSpace = function() return 30000 end
    local oldPart = prov.PART_SIZE
    prov.PART_SIZE = 25000
    local scfg = serverCfg()
    local dcfg = config.newDevice(scfg, "router", "relay", 7)
    local ok, info = prov.writeDisk("drive_1", dcfg, { programText = big })
    t.ok(ok, tostring(info))
    t.ok(info.parts >= 2, "needs more than one disk, got " .. tostring(info.parts))
    t.ok(fs.exists("/disk/zelnet.z"))
    local same, serr = prov.writePart("drive_1", info.plan, 2)
    t.eq(same, nil)
    t.ok(serr)
    local mounts = { "disk2" }
    for i = 2, info.parts do
        local name = "drive_" .. i
        if i > 2 then
            fakeDrive(name, "disk" .. i, 10 + i)
            clearDir("/disk" .. i)
            mounts[#mounts + 1] = "disk" .. i
        end
        local pok, perr = prov.writePart(name, info.plan, i)
        t.ok(pok, tostring(perr))
    end
    fs.getFreeSpace = realFree
    prov.PART_SIZE = oldPart
    local st = runInstaller("disk")
    t.eq(util.readFile("/zelnet"), prov.deviceBuild(big))
    t.ok(not fs.exists("/disk/zelnet.cfg"))
    t.ok(st.rebooted)
    t.eq(peripheral.call("drive_2", "getDiskLabel"), "ZelNet router relay 2/" .. info.parts)
end)

t.case("installer waits for the next disk", function()
    resetComputer()
    local big = fakeBundle(randomText(40000, 5):gsub("[\"\\\n]", "q"))
    fakeDrive("drive_1", "disk", 11)
    local d2 = fakeDrive("drive_2", "disk2", 12)
    clearDir("/disk")
    clearDir("/disk2")
    local realFree = fs.getFreeSpace
    fs.getFreeSpace = function() return 30000 end
    local oldPart = prov.PART_SIZE
    prov.PART_SIZE = 60000
    local dcfg = config.newDevice(serverCfg(), "client", "amy", 7)
    local ok, info = prov.writeDisk("drive_1", dcfg, { programText = big, forcePack = true })
    t.ok(ok)
    t.eq(info.parts, 2)
    assert(prov.writePart("drive_2", info.plan, 2))
    fs.getFreeSpace = realFree
    prov.PART_SIZE = oldPart
    d2.present = false
    os.queueEvent("disk", "drive_2")
    local hook = os.queueEvent
    local fired = false
    local realPull = os.pullEvent
    os.pullEvent = function(f)
        if not fired and not d2.present then
            fired = true
            d2.present = true
        end
        return realPull(f)
    end
    local st = runInstaller("disk")
    os.pullEvent = realPull
    t.ok(hook)
    t.eq(util.readFile("/zelnet"), prov.deviceBuild(big))
    t.ok(st.rebooted)
end)

t.finish()
