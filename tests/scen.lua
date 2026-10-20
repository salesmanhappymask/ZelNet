package.path = "./?.lua;" .. package.path
local sim = require("sim.ccsim")
local need = require("tools.devload").make(".")
require("tests.shim").install()
local codec = need("codec")
local crypto = need("crypto")

local M = {}

M.ITEMS = { { id = 35, dmg = 1, qty = 3 }, { id = 1, dmg = 0, qty = 7 }, { id = 4, qty = 2 }, false, false, false }

local f = assert(io.open(os.getenv("ZN_PROGRAM") or "build/zelnet", "rb"))
M.program = f:read("*a")
f:close()

function M.world()
    local w = sim.newWorld({ romPath = "sim/rom", seed = 1 })
    M.keys = sim.keys("sim/rom")
    return w
end

function M.shot(c, title)
    print("---- " .. title .. " ----")
    print(c:screenText())
end

function M.errors(c, tag)
    for _, e in ipairs(c:errors()) do print("ERR " .. tag .. ": " .. tostring(e)) end
end

function M.serverCfg(realm, role, mainRealm, backbone, extra)
    local salt = crypto.randHex(16)
    local cfg = {
        zn = 1, role = role, network = "ZelNet", realm = realm, mainRealm = mainRealm,
        backboneKey = backbone, realmKey = crypto.newKey(), dataKey = crypto.newKey(),
        console = { salt = salt, hash = crypto.passwordHash(salt, "secret") },
        bridges = {}, storage = { drives = {} }, monitors = {}, airlocks = false,
    }
    for k, v in pairs(extra or {}) do cfg[k] = v end
    return cfg
end

function M.server(w, opts)
    local c = w:addComputer({ id = opts.id, label = opts.realm:lower(), dim = opts.dim, pos = opts.pos, color = true,
        files = { ["/zelnet"] = M.program, ["/.zelnet/config"] = codec.encode(opts.cfg) },
        startup = 'shell.run("/zelnet")' })
    c:attach("top", w:wirelessModem())
    if opts.cable then
        c:attach("back", w:wiredModem(opts.cable))
        w:connect(opts.cable, w:cipherBlock({ items = M.ITEMS }), "cipher_0")
    else
        c:attach("left", w:cipherBlock({ items = M.ITEMS }))
    end
    local drive = w:diskDrive()
    c:attach("bottom", drive)
    c.provDrive = drive
    c:boot()
    return c
end

function M.unlock(w, c)
    c:typeText("secret")
    c:pressKey(M.keys.enter)
    w:run(3)
end

function M.provision(w, c, roleKey, name)
    local fl = w:floppy({ label = "blank" })
    c.provDrive:insert(fl)
    w:run(1)
    c:typeText("2") w:run(2)
    c:typeText("n") w:run(2)
    c:typeText(roleKey) w:run(2)
    c:typeText(name) c:pressKey(M.keys.enter) w:run(3)
    c:pressKey(M.keys.enter) w:run(3)
    c:pressKey(M.keys.enter) w:run(30)
    local text = c:screenText()
    c:pressKey(M.keys.enter) w:run(1)
    c:pressKey(M.keys.leftCtrl) w:run(1)
    c:pressKey(M.keys.leftCtrl) w:run(1)
    local disk = c.provDrive:remove()
    return disk, text
end

function M.device(w, opts, disk)
    local c = w:addComputer({ id = opts.id, dim = opts.dim, pos = opts.pos, color = true, files = opts.files })
    c:attach("top", w:wirelessModem())
    local drive = w:diskDrive()
    c:attach("bottom", drive)
    drive:insert(disk)
    c:boot()
    w:run(opts.wait or 40)
    drive:remove()
    return c
end

function M.twoRealms(w, crypto, extraEarth, extraMars)
    local backbone = crypto.newKey()
    local eSend = w:tesseract({ frequency = 1 })
    local eRecv = w:tesseract({ frequency = 2 })
    local mSend = w:tesseract({ frequency = 2 })
    local mRecv = w:tesseract({ frequency = 1 })
    local eSendDrive, eRecvDrive, mSendDrive, mRecvDrive = w:diskDrive(), w:diskDrive(), w:diskDrive(), w:diskDrive()
    eSend:adjacent("north", eSendDrive)
    eRecv:adjacent("north", eRecvDrive)
    mSend:adjacent("north", mSendDrive)
    mRecv:adjacent("north", mRecvDrive)
    eSendDrive:insert(w:floppy({ label = "earth-mars" }))
    mSendDrive:insert(w:floppy({ label = "mars-earth" }))
    for _, set in ipairs({ { "earth", eSend, eRecv, eSendDrive, eRecvDrive }, { "mars", mSend, mRecv, mSendDrive, mRecvDrive } }) do
        w:connect(set[1], set[2], "tesseract_0")
        w:connect(set[1], set[3], "tesseract_1")
        w:connect(set[1], set[4], "drive_0")
        w:connect(set[1], set[5], "drive_1")
    end
    local function bridgeTo(peer)
        return { { peer = peer, sendTess = "tesseract_0", sendDrive = "drive_0", sendDir = "north", recvTess = "tesseract_1", recvDrive = "drive_1", recvDir = "north" } }
    end
    local ex1 = extraEarth or {}
    ex1.bridges = bridgeTo("MARS")
    local ex2 = extraMars or {}
    ex2.bridges = bridgeTo("EARTH")
    local earth = M.server(w, { id = 1, realm = "EARTH", dim = "overworld", pos = { 0, 70, 0 }, cable = "earth",
        cfg = M.serverCfg("EARTH", "main", "EARTH", backbone, ex1) })
    local mars = M.server(w, { id = 2, realm = "MARS", dim = "mars", pos = { 0, 70, 0 }, cable = "mars",
        cfg = M.serverCfg("MARS", "satellite", "EARTH", backbone, ex2) })
    w:run(10)
    M.unlock(w, earth)
    M.unlock(w, mars)
    return earth, mars
end

return M
