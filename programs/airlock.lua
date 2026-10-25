local VERSION = "dev"
local STATE_FILE = "/airlock.dat"
local SILENT_AFTER = 960
local SEARCH_EVERY = 60
local PEER_DELAY = 5
local OPEN_GRACE = 10
local PEER_EVERY = 10
local PEER_STALE = 60
local HEARTBEAT = 30
local RETRY_EVERY = 1
local RETRY_MAX = 5
local PEER_CONFIRM = 3
local LOG_FILE = "/airlock.log"
local LOG_CAP = 16000
local LOG_KEEP = 150
local DUMP_MAX = 5500
local KEY_FILE = "/airlock.key"
local CHUNK_WAIT = 3
local CHUNK_TRIES = 5
local FLASH = 0.5

local SIDES = { "top", "bottom", "left", "right", "front", "back" }

local C_BG = colors.black
local C_HEAD = colors.lightGray
local C_BRAND = colors.blue
local C_TEXT = colors.white
local C_MUTED = colors.lightGray
local C_OK = colors.green
local C_ERR = colors.red
local C_ACCENT = colors.cyan
local C_LOCK = colors.orange

local state = {
    name = nil,
    role = "door",
    registered = false,
    serverId = nil,
    detectorSide = "back",
    airlockSide = "top",
    failsafe = true,
    failsafeDelay = 5,
    displayWidth = 2,
    locked = false,
    sealed = false,
    oxygenated = true,
    lightSide = "none",
    lockdown = false,
    room = nil,
    rooms = nil,
    knownRooms = {},
    why = nil,
}

local monitor = nil
local lastHeard = nil
local unsealedAt = nil
local peers = {}
local pending = nil
local upd = nil
local flashOn = false
local KEY = nil

local MOD = 4294967296
local function n32(x)
    x = x % MOD
    if x < 0 then x = x + MOD end
    return x
end
local function band(a, c) return n32(bit.band(n32(a), n32(c))) end
local function bxor(a, c) return n32(bit.bxor(n32(a), n32(c))) end
local function bnot(a) return MOD - 1 - n32(a) end
local function rshift(a, n) return math.floor(n32(a) / (2 ^ n)) end
local function rrot(x, n)
    x = n32(x)
    return (math.floor(x / (2 ^ n)) + (x * (2 ^ (32 - n))) % MOD) % MOD
end
local K = {
    0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
    0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
    0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
    0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
    0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
    0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
    0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
    0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2,
}
local function hex8(n)
    return string.format("%08x", n32(n))
end
local function sha256(msg)
    local h = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 }
    local bits = #msg * 8
    local pad = 64 - ((#msg + 9) % 64)
    if pad == 64 then pad = 0 end
    local hi, lo = math.floor(bits / MOD), bits % MOD
    msg = msg .. "\128" .. string.rep("\0", pad)
        .. string.char(band(rshift(hi, 24), 255), band(rshift(hi, 16), 255), band(rshift(hi, 8), 255), band(hi, 255))
        .. string.char(band(rshift(lo, 24), 255), band(rshift(lo, 16), 255), band(rshift(lo, 8), 255), band(lo, 255))
    local w = {}
    for chunk = 1, #msg, 64 do
        for i = 0, 15 do
            local b1, b2, b3, b4 = msg:byte(chunk + i * 4, chunk + i * 4 + 3)
            w[i + 1] = ((b1 * 256 + b2) * 256 + b3) * 256 + b4
        end
        for i = 17, 64 do
            local x, y = w[i - 15], w[i - 2]
            local s0 = bxor(bxor(rrot(x, 7), rrot(x, 18)), rshift(x, 3))
            local s1 = bxor(bxor(rrot(y, 17), rrot(y, 19)), rshift(y, 10))
            w[i] = (w[i - 16] + s0 + w[i - 7] + s1) % MOD
        end
        local a, b, c, d, e, f, g, hh = h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8]
        for i = 1, 64 do
            local S1 = bxor(bxor(rrot(e, 6), rrot(e, 11)), rrot(e, 25))
            local ch = bxor(band(e, f), band(bnot(e), g))
            local t1 = (hh + S1 + ch + K[i] + w[i]) % MOD
            local S0 = bxor(bxor(rrot(a, 2), rrot(a, 13)), rrot(a, 22))
            local mj = bxor(bxor(band(a, b), band(a, c)), band(b, c))
            local t2 = (S0 + mj) % MOD
            hh, g, f, e, d, c, b, a = g, f, e, (d + t1) % MOD, c, b, a, (t1 + t2) % MOD
        end
        h[1], h[2], h[3], h[4] = (h[1] + a) % MOD, (h[2] + b) % MOD, (h[3] + c) % MOD, (h[4] + d) % MOD
        h[5], h[6], h[7], h[8] = (h[5] + e) % MOD, (h[6] + f) % MOD, (h[7] + g) % MOD, (h[8] + hh) % MOD
    end
    return hex8(h[1]) .. hex8(h[2]) .. hex8(h[3]) .. hex8(h[4]) .. hex8(h[5]) .. hex8(h[6]) .. hex8(h[7]) .. hex8(h[8])
end
local function fromHex(s)
    if type(s) ~= "string" or #s % 2 ~= 0 or s:find("[^%x]") then return nil end
    return (s:gsub("%x%x", function(x) return string.char(tonumber(x, 16)) end))
end
local function hmac(keyHex, msg)
    local key = fromHex(keyHex)
    if not key then return nil end
    if #key > 64 then key = fromHex(sha256(key)) end
    key = key .. string.rep("\0", 64 - #key)
    local ipad, opad = {}, {}
    for i = 1, 64 do
        local kb = key:byte(i)
        ipad[i] = string.char(bxor(kb, 0x36))
        opad[i] = string.char(bxor(kb, 0x5c))
    end
    return sha256(table.concat(opad) .. fromHex(sha256(table.concat(ipad) .. msg)))
end

local logLines = {}
local function log(text)
    local day, t = 0, 0
    pcall(function() day = os.day() or 0 end)
    pcall(function() t = os.time() or 0 end)
    local hr = math.floor(t)
    local line = string.format("d%d %02d:%02d %7.1f %s", day, hr, math.floor((t - hr) * 60), os.clock(), tostring(text))
    logLines[#logLines + 1] = line
    if #logLines > LOG_KEEP then table.remove(logLines, 1) end
    pcall(function()
        if fs.exists(LOG_FILE) and fs.getSize(LOG_FILE) > LOG_CAP then
            if fs.exists(LOG_FILE .. ".old") then fs.delete(LOG_FILE .. ".old") end
            fs.move(LOG_FILE, LOG_FILE .. ".old")
        end
        local h = fs.open(LOG_FILE, fs.exists(LOG_FILE) and "a" or "w")
        if h then
            h.write(line .. "\n")
            h.close()
        end
    end)
end

local function readText(path)
    if not fs.exists(path) or fs.isDir(path) then return nil end
    local h = fs.open(path, "r")
    if not h then return nil end
    local t = h.readAll()
    h.close()
    return t
end

local function logTail()
    local text = (readText(LOG_FILE .. ".old") or "") .. (readText(LOG_FILE) or "")
    if #text > DUMP_MAX then text = text:sub(-DUMP_MAX) end
    return text
end

local function programPath()
    local p = shell and shell.getRunningProgram and shell.getRunningProgram()
    if type(p) == "string" and p ~= "" then return "/" .. p end
    return "/startup"
end

local function loadKey()
    local k = readText(KEY_FILE)
    k = k and k:match("^%s*(%x+)%s*$")
    if k and #k >= 32 then KEY = k:lower() else KEY = nil end
end

local function trim(s)
    s = tostring(s or "")
    return (s:match("^%s*(.-)%s*$") or "")
end

local function nameBase(name)
    local base = tostring(name or ""):match("^(.-)%-[%w]+$")
    if base and base ~= "" then return base:lower() end
    return nil
end

local function nameSuffix(name)
    local base, suffix = tostring(name or ""):match("^(.-)%-([%w]+)$")
    if base and base ~= "" then return suffix:upper() end
    return nil
end

local function scaleForWidth(w)
    if w == 1 then return 0.5 end
    return 1
end

local function isSensor()
    return state.role == "sensor" or state.role == "room"
end

local function isSecurity()
    return state.role == "security"
end

local function roomKey(name)
    if type(name) ~= "string" then return nil end
    local k = trim(name):lower()
    if k == "" then return nil end
    return k
end

local function peerKeys()
    local keys = {}
    if state.role == "door" then
        local g = nameBase(state.name)
        if g then keys[#keys + 1] = { key = "g:" .. g, kind = "hall", label = "Hallway" } end
        local r = roomKey(state.room)
        if r then keys[#keys + 1] = { key = "r:" .. r, kind = "room", label = state.room } end
    elseif state.role == "security" then
        for _, name in ipairs(state.rooms or {}) do
            local r = roomKey(name)
            if r then keys[#keys + 1] = { key = "r:" .. r, kind = "room", label = name } end
        end
    end
    return keys
end

local function newReqID()
    return string.format("%d-%d-%s", os.getComputerID(), math.random(1, 1000000), tostring(os.clock()))
end

local function saveState()
    local f = fs.open(STATE_FILE, "w")
    if not f then return false end
    f.write(textutils.serialize(state))
    f.close()
    return true
end

local function loadState()
    if not (fs.exists(STATE_FILE) and not fs.isDir(STATE_FILE)) then return end
    local f = fs.open(STATE_FILE, "r")
    if not f then return end
    local c = f.readAll()
    f.close()
    local t = textutils.unserialize(c)
    if type(t) == "table" then
        for k, v in pairs(t) do state[k] = v end
    end
end

local function openModems()
    local n = 0
    for _, side in ipairs(SIDES) do
        if peripheral.getType(side) == "modem" then
            if pcall(rednet.open, side) then n = n + 1 end
        end
    end
    return n > 0
end

local function findMonitor()
    monitor = nil
    local scale = scaleForWidth(state.displayWidth)
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "monitor" then
            monitor = peripheral.wrap(name)
            pcall(function() monitor.setTextScale(scale) end)
            return
        end
    end
end

local function readOxygen()
    if isSecurity() then return true end
    local ok, val = pcall(redstone.getInput, state.detectorSide)
    if not ok then return state.oxygenated end
    return val and true or false
end

local function applyPhysical(sealed)
    if isSensor() then
        state.sealed = false
        return
    end
    pcall(redstone.setOutput, state.airlockSide, not sealed)
    state.sealed = sealed
end

local function peerLow(key)
    local p = peers[key]
    if p == nil or not p.low or os.clock() - p.at >= PEER_STALE then return false end
    local afterOpen = unsealedAt ~= nil and p.since >= unsealedAt and p.since - unsealedAt < OPEN_GRACE
    return not afterOpen or os.clock() - p.since >= PEER_CONFIRM
end

local function interlockOf(kind)
    for _, k in ipairs(peerKeys()) do
        if (kind == nil or k.kind == kind) and peerLow(k.key) then return true end
    end
    return false
end

local function interlocked()
    return interlockOf(nil)
end

local function peerText(key)
    local p = peers[key]
    if p == nil or os.clock() - p.at >= PEER_STALE then return "--", C_MUTED end
    if p.low then return "NO AIR", C_ERR end
    return "air ok", C_OK
end

local function applyCommand(cmd, locked, force)
    if cmd == "lock" then
        state.locked = true
    elseif cmd == "unlock" then
        state.locked = false
    elseif type(locked) == "boolean" then
        state.locked = locked
    end
    if state.locked then
        applyPhysical(true)
    elseif cmd == "seal" then
        applyPhysical(true)
    elseif cmd == "unseal" then
        if interlocked() and not force and state.sealed then
            return "refused"
        end
        if state.sealed then unsealedAt = os.clock() end
        applyPhysical(false)
    end
end

local function linked()
    return state.serverId ~= nil and lastHeard ~= nil and os.clock() - lastHeard < SILENT_AFTER
end

local function serverText(short)
    if linked() then
        return short and ("#" .. state.serverId) or ("#" .. state.serverId .. " linked")
    end
    return short and "--" or "searching"
end

local function centerText(w, s)
    s = tostring(s)
    if #s > w then s = s:sub(1, w) end
    local pad = math.floor((w - #s) / 2)
    return string.rep(" ", math.max(0, pad)) .. s
end

local flashTimer = nil

local function flashing()
    if state.lockdown then return true end
    if isSensor() then return false end
    return state.locked == true or state.sealed == true
end

local function setLight()
    local side = state.lightSide
    if type(side) == "string" and side ~= "none" then pcall(redstone.setOutput, side, flashing() and flashOn) end
end

local function paint(dev, isTerm)
    local ok, w, h = pcall(dev.getSize)
    if not ok then return end
    local sensor = isSensor()
    local compact = (w < 26)
    local danger
    if sensor then danger = (not state.oxygenated) else danger = (not state.oxygenated) or state.sealed end
    local locked = state.locked and not sensor

    local function bg(c) dev.setBackgroundColor(c) end
    local function fg(c) dev.setTextColor(c) end
    local function bar(y, c) bg(c); dev.setCursorPos(1, y); dev.write(string.rep(" ", w)) end
    local function put(x, y, s, f, b)
        if y < 1 or y > h then return end
        if b then bg(b) end
        if f then fg(f) end
        dev.setCursorPos(x, y)
        dev.write(tostring(s):sub(1, math.max(0, w - x + 1)))
    end

    bg(C_BG); fg(C_TEXT); dev.clear()

    bar(1, C_HEAD)
    if compact then
        put(2, 1, centerText(w - 2, state.name or (sensor and "SENSOR" or "AIRLOCK")), C_BRAND, C_HEAD)
    else
        put(2, 1, state.role == "room" and "ROOM SENSOR" or (sensor and "HALLWAY SENSOR" or (isSecurity() and "SECURITY DOOR" or "AIRLOCK")), C_BRAND, C_HEAD)
        local nm = state.name or "unnamed"
        put(math.max(2, w - #nm), 1, nm, C_BG, C_HEAD)
    end

    local bannerCol = danger and C_ERR or C_OK
    local bannerTxt
    if state.lockdown then
        bannerCol = C_ERR
        bannerTxt = compact and "LOCKDOWN" or "STATION LOCKDOWN"
    elseif locked then
        bannerCol = C_LOCK
        bannerTxt = compact and "LOCKED" or "LOCKED BY CONTROL"
    elseif compact then
        if sensor then bannerTxt = danger and "VENT!" or "SAFE"
        elseif not state.oxygenated then bannerTxt = "NO O2!"
        else bannerTxt = state.sealed and "SEALED" or "OPEN" end
    elseif state.role == "room" then
        bannerTxt = danger and "ROOM VENTED" or "ROOM AIR OK"
    elseif sensor then
        bannerTxt = danger and "CHAMBER VENTED" or "CHAMBER OK"
    elseif isSecurity() then
        bannerTxt = state.sealed and "SECURITY DOOR CLOSED" or "SECURITY DOOR OPEN"
    elseif not state.oxygenated then
        bannerTxt = "!! NO OXYGEN !!"
    else
        bannerTxt = state.sealed and "DOOR SEALED" or "AIR OK - DOOR OPEN"
    end
    if flashing() then bannerCol = flashOn and C_ERR or C_BG end
    local bTop = 3
    local bBot = math.min(h - (compact and 4 or 6), bTop + 4)
    if bBot < bTop then bBot = bTop end
    for y = bTop, bBot do bar(y, bannerCol) end
    local mid = math.floor((bTop + bBot) / 2)

    if (bBot - bTop) >= 3 then
        if locked then
            put(1, mid - 1, centerText(w, "  ___  "), C_TEXT, bannerCol)
            put(1, mid, centerText(w, " |_o_| "), C_TEXT, bannerCol)
        else
            put(1, mid - 1, centerText(w, danger and "  /\\  " or "  ()  "), C_TEXT, bannerCol)
            put(1, mid, centerText(w, danger and " /!!\\ " or " \\/ "), C_TEXT, bannerCol)
        end
        put(1, mid + 1, centerText(w, bannerTxt), C_TEXT, bannerCol)
    else
        put(1, mid, centerText(w, bannerTxt), C_TEXT, bannerCol)
    end

    local sy = bBot + 2
    local doorText = locked and "LOCKED" or (state.sealed and "SEALED" or "OPEN")
    local doorCol = locked and C_LOCK or (state.sealed and C_ERR or C_OK)
    if compact then
        if state.role == "room" then
            put(1, sy, centerText(w, tostring(state.room or "room")), C_TEXT, C_BG)
            put(1, sy + 1, centerText(w, "O2:" .. (state.oxygenated and "PRESENT" or "NONE")), state.oxygenated and C_OK or C_ERR, C_BG)
        elseif sensor then
            put(1, sy, centerText(w, "O2:" .. (state.oxygenated and "PRESENT" or "NONE")), state.oxygenated and C_OK or C_ERR, C_BG)
            put(1, sy + 1, centerText(w, "Sensor"), C_MUTED, C_BG)
        else
            put(1, sy, centerText(w, "Door:" .. doorText), doorCol, C_BG)
            local y = sy + 1
            for _, k in ipairs(peerKeys()) do
                local t, c = peerText(k.key)
                put(1, y, centerText(w, (k.kind == "hall" and "Hall" or tostring(k.label)):sub(1, 7) .. ":" .. t), c, C_BG)
                y = y + 1
            end
        end
        put(1, h - (isTerm and 1 or 0), centerText(w, "Srv:" .. serverText(true)), linked() and C_MUTED or C_LOCK, C_BG)
    else
        local y = sy
        local function line(label, text, col)
            put(2, y, string.format("%-9s: %s", label, text), col or C_TEXT, C_BG)
            y = y + 1
        end
        if state.role == "room" then
            line("Room", tostring(state.room or "?"), C_TEXT)
            line("Oxygen", state.oxygenated and "PRESENT" or "NONE", state.oxygenated and C_OK or C_ERR)
        elseif sensor then
            line("Oxygen", state.oxygenated and "PRESENT" or "NONE", state.oxygenated and C_OK or C_ERR)
            line("Role", "hallway sensor", C_MUTED)
        else
            line(isSecurity() and "Door" or "Bulkhead", doorText, doorCol)
            for _, k in ipairs(peerKeys()) do
                local t, c = peerText(k.key)
                if k.kind == "hall" then line("Hallway", t, c) else line("Room", tostring(k.label) .. ": " .. t, c) end
            end
            if not isSecurity() then line("Detector", state.oxygenated and "oxygen" or "NO OXYGEN", state.oxygenated and C_OK or C_ERR) end
            if state.sealed and state.why then line("Why", state.why, C_LOCK) end
        end
        line("Server", serverText(false), linked() and C_MUTED or C_LOCK)
    end
    if isTerm and h >= 2 then
        put(1, h, centerText(w, "S: setup"), C_MUTED, C_BG)
    end
end

local function render()
    if flashing() then
        if not flashTimer then flashTimer = os.startTimer(FLASH) end
    else
        flashOn = false
    end
    setLight()
    paint(term, true)
    if monitor then pcall(paint, monitor, false) end
end

local function message(kind)
    local m = {
        type = kind,
        name = state.name,
        role = state.role,
        oxygenated = state.oxygenated,
        sealed = state.sealed,
        locked = state.locked,
        interlock = (not isSensor()) and interlocked() or nil,

        room = (state.role == "door" or state.role == "room") and (state.room or false) or nil,
        rooms = isSecurity() and (state.rooms or false) or nil,
        ver = VERSION,
        keyed = KEY ~= nil,
        reqID = newReqID(),
    }
    if not isSensor() then
        m.ilHall = interlockOf("hall")
        m.ilRoom = interlockOf("room")
    end
    return m
end

local function sendStatus(kind)
    if linked() then
        local m = message(kind)
        rednet.send(state.serverId, m)
        if kind == "alk_status" then
            pending = { reqID = m.reqID, tries = 1, timer = os.startTimer(RETRY_EVERY) }
        end
    else
        rednet.broadcast(message(state.registered and "alk_hello" or "alk_register"))
    end
end

local function announce()
    sendStatus(state.registered and "alk_hello" or "alk_register")
end

local function tellPeers()
    if state.role == "sensor" then
        local group = nameBase(state.name)
        if group then pcall(rednet.broadcast, { type = "alk_peer", group = group, oxygenated = state.oxygenated }) end
    elseif state.role == "room" then
        local r = roomKey(state.room)
        if r then pcall(rednet.broadcast, { type = "alk_peer", room = r, oxygenated = state.oxygenated }) end
    end
end

local function noteServerInfo(msg)
    if type(msg.why) == "string" then state.why = msg.why:sub(1, 60) elseif msg.why == nil and not state.sealed then state.why = nil end
    if type(msg.roomList) == "table" then
        local list = {}
        for i = 1, math.min(#msg.roomList, 16) do
            if type(msg.roomList[i]) == "string" then list[#list + 1] = msg.roomList[i]:sub(1, 32) end
        end
        state.knownRooms = list
    end
    if state.role == "door" and msg.room ~= nil then
        local r = msg.room or nil
        if type(r) == "string" and r ~= state.room then
            log("room set by the server: " .. r)
            state.room = r
            peers = {}
        elseif r == nil and msg.roomSet and state.room ~= nil then
            log("room cleared by the server")
            state.room = nil
        end
    elseif isSecurity() and msg.rooms ~= nil and msg.roomSet then
        local r = type(msg.rooms) == "table" and msg.rooms or nil
        state.rooms = r
        log("rooms set by the server: " .. (r and table.concat(r, " / ") or "none"))
        peers = {}
    end
end

local function adopt(id)
    if state.serverId ~= id then
        log("linked to server #" .. tostring(id))
        state.serverId = id
        saveState()
    end
    lastHeard = os.clock()
end

local function noteLockdown(flag)
    flag = flag == true
    if flag ~= (state.lockdown == true) then
        state.lockdown = flag
        log(flag and "station lockdown" or "lockdown released")
    end
end

local function onAck(id, msg)
    adopt(id)
    if not state.registered then state.registered = true end
    if pending and msg.reqID == pending.reqID then pending = nil end
    noteLockdown(msg.lockdown)
    noteServerInfo(msg)
    local wasSealed = state.sealed
    local res = applyCommand(msg.command, msg.locked, msg.force)
    if res == "refused" then
        log("refused unseal from #" .. tostring(id) .. ": zone sensor reads no oxygen")
    elseif wasSealed ~= state.sealed then
        log("ack from #" .. tostring(id) .. ": " .. tostring(msg.command) .. (msg.force and " (forced)" or ""))
    end
    saveState()
    return res
end

local function bootHandshake()
    for _ = 1, 4 do
        local msg = message(state.registered and "alk_hello" or "alk_register")
        if state.serverId then
            rednet.send(state.serverId, msg)
        else
            rednet.broadcast(msg)
        end
        local deadline = os.clock() + 3
        while os.clock() < deadline do
            local id, reply = rednet.receive(deadline - os.clock())
            if id == nil then break end
            if type(reply) == "table" and reply.type == "alk_ack" then
                onAck(id, reply)
                return true
            end
        end
        if state.serverId then
            rednet.broadcast(message(state.registered and "alk_hello" or "alk_register"))
        end
    end
    return false
end

local function header(w, title)
    term.setBackgroundColor(C_BG)
    term.setTextColor(C_TEXT)
    term.clear()
    term.setBackgroundColor(C_HEAD)
    term.setCursorPos(1, 1)
    term.write(string.rep(" ", w))
    term.setTextColor(C_BRAND)
    term.setCursorPos(2, 1)
    term.write("AIRLOCK SETUP")
    term.setBackgroundColor(C_BG)
    term.setTextColor(C_ACCENT)
    term.setCursorPos(2, 3)
    term.write(title)
end

local function askText(title, label, default)
    local value = default or ""
    while true do
        local w = term.getSize()
        header(w, title)
        term.setTextColor(C_TEXT)
        term.setCursorPos(2, 5)
        term.write(label)
        term.setCursorPos(2, 7)
        term.setBackgroundColor(colors.gray)
        term.write(string.rep(" ", w - 2))
        term.setCursorPos(2, 7)
        term.write(value)
        term.setBackgroundColor(C_BG)
        term.setTextColor(C_MUTED)
        term.setCursorPos(2, 9)
        term.write("Enter: OK")
        term.setTextColor(C_TEXT)
        term.setCursorBlink(true)
        term.setCursorPos(2 + #value, 7)
        local ev, a = os.pullEvent()
        if ev == "char" then
            value = value .. a
        elseif ev == "key" then
            if a == keys.enter then
                term.setCursorBlink(false)
                value = trim(value)
                if value ~= "" then return value end
            elseif a == keys.backspace then
                value = value:sub(1, -2)
            end
        end
    end
end

local function askChoice(title, label, options, current)
    local sel = 1
    for i, opt in ipairs(options) do
        if opt.value == current then sel = i end
    end
    while true do
        local w = term.getSize()
        header(w, title)
        term.setTextColor(C_TEXT)
        term.setCursorPos(2, 4)
        term.write(label)
        local hbs = {}
        for i, opt in ipairs(options) do
            local y = 6 + i - 1
            local bg = (i == sel) and C_ACCENT or colors.gray
            term.setBackgroundColor(bg)
            term.setTextColor(C_TEXT)
            term.setCursorPos(2, y)
            local line = string.format(" %d %s", i, opt.label)
            term.write(line .. string.rep(" ", math.max(0, (w - 3) - #line)))
            hbs[#hbs + 1] = { i = i, y = y, x1 = 2, x2 = w - 2 }
        end
        term.setBackgroundColor(C_BG)
        term.setTextColor(C_MUTED)
        term.setCursorPos(2, 6 + #options + 1)
        term.write("Arrows or number, Enter: OK")
        local ev, a, b, c = os.pullEvent()
        if ev == "key" then
            if a == keys.up then sel = (sel > 1) and sel - 1 or #options
            elseif a == keys.down then sel = (sel < #options) and sel + 1 or 1
            elseif a == keys.enter then return options[sel].value end
        elseif ev == "char" then
            local n = tonumber(a)
            if n and options[n] then return options[n].value end
        elseif ev == "mouse_click" then
            for _, hb in ipairs(hbs) do
                if c == hb.y and b >= hb.x1 and b <= hb.x2 then return options[hb.i].value end
            end
        end
    end
end

local function sideOptions()
    local o = {}
    for _, s in ipairs(SIDES) do o[#o + 1] = { label = s, value = s } end
    return o
end

local function fetchRooms()
    if state.knownRooms and #state.knownRooms > 0 then return end
    local msg = message(state.registered and "alk_hello" or "alk_register")
    if state.serverId then rednet.send(state.serverId, msg) else rednet.broadcast(msg) end
    local deadline = os.clock() + 2
    while os.clock() < deadline do
        local id, reply = rednet.receive(math.max(0.05, deadline - os.clock()))
        if id == nil then return end
        if type(reply) == "table" and reply.type == "alk_ack" then
            onAck(id, reply)
            return
        end
    end
end

local function pickRoom(title, label, current, allowNone)
    local opts = {}
    local seen = {}
    for _, name in ipairs(state.knownRooms or {}) do
        opts[#opts + 1] = { label = name, value = name }
        seen[name:lower()] = true
    end
    if type(current) == "string" and not seen[current:lower()] then opts[#opts + 1] = { label = current, value = current } end
    opts[#opts + 1] = { label = "Type a room name", value = "__type" }
    if allowNone then opts[#opts + 1] = { label = "None", value = "__none" } end
    local pick = askChoice(title, label, opts, current or (allowNone and "__none" or nil))
    if pick == "__none" then return nil end
    if pick == "__type" then return askText(title, "Room name (Hub, North, South, East, West show on the navmap):", current or "") end
    return pick
end

local function runSetup()
    state.role = askChoice("What is this computer?", "Pick its job:", {
        { label = "Hallway door (opens and seals)", value = "door" },
        { label = "Hallway sensor (no door)", value = "sensor" },
        { label = "Room sensor (no door)", value = "room" },
        { label = "Security door (between rooms)", value = "security" },
    }, state.role)
    if state.role == "room" then
        state.room = askText("Room", "Room name (Hub, North, South, East, West show on the navmap):", state.room or state.name or "Hub")
        state.name = state.room
    elseif state.role == "security" then
        state.name = askText("Name", "Name of this security door:", (state.name and not nameSuffix(state.name)) and state.name or "Vault")
    else
        local suggestion = state.name
        if not suggestion or state.role ~= "door" and state.role ~= "sensor" then suggestion = isSensor() and "dock-C" or "dock-A" end
        local hint = isSensor() and "Same name as its doors, ending in -C (dock-C):" or "Doors of one hallway share a name: dock-A, dock-B:"
        state.name = askText("Name", hint, suggestion)
    end
    if state.role == "door" or state.role == "security" then fetchRooms() end
    if state.role == "door" then
        state.room = pickRoom("Room", "Which room does this door open into?", state.room, true)
        state.rooms = nil
    elseif state.role == "security" then
        local cur = state.rooms or {}
        local a = pickRoom("Room on one side", "Which room is on one side?", cur[1], true)
        local b = pickRoom("Room on the other side", "Which room is on the other side?", cur[2], true)
        local list = {}
        if a then list[#list + 1] = a end
        if b then list[#list + 1] = b end
        state.rooms = #list > 0 and list or nil
        state.room = nil
    elseif state.role == "sensor" then
        state.room = nil
        state.rooms = nil
    end
    peers = {}
    if not isSecurity() then
        state.detectorSide = askChoice("Oxygen detector", "Which side gets the detector's redstone?", sideOptions(), state.detectorSide)
    end
    if isSensor() then
        state.sealed = false
    else
        state.airlockSide = askChoice("Door output", "Which side drives the airlock door?", sideOptions(), state.airlockSide)
        if not isSecurity() then
            state.failsafe = askChoice("Failsafe", "Seal by itself if the air goes and the server is silent?", {
                { label = "Yes (recommended)", value = true },
                { label = "No", value = false },
            }, state.failsafe)
        else
            state.failsafe = true
        end
    end
    state.displayWidth = askChoice("Monitor", "How many blocks wide is the monitor (if any)?", {
        { label = "1 wide (compact)", value = 1 },
        { label = "2 wide", value = 2 },
        { label = "3 wide", value = 3 },
    }, state.displayWidth)
    local lights = { { label = "none", value = "none" } }
    for _, o in ipairs(sideOptions()) do lights[#lights + 1] = o end
    if type(state.lightSide) == "string" and state.lightSide ~= "none" then pcall(redstone.setOutput, state.lightSide, false) end
    state.lightSide = askChoice("Warning light", "Side that pulses a lamp while sealed or locked down:", lights, state.lightSide or "none")
    log("setup: " .. tostring(state.name) .. " " .. tostring(state.role) .. " room " .. tostring(state.room or (state.rooms and table.concat(state.rooms, "/")) or "-") .. " detector " .. tostring(state.detectorSide) .. " door " .. tostring(state.airlockSide) .. " light " .. tostring(state.lightSide))
    state.oxygenated = readOxygen()
    applyPhysical(state.sealed)
    saveState()
    findMonitor()
    bootHandshake()
end

local function requestChunk()
    rednet.send(upd.from, { type = "alk_get", ver = upd.ver, i = upd.i })
    upd.timer = os.startTimer(CHUNK_WAIT)
end

local function startUpdate(id, msg)
    if upd or not KEY or type(msg.ver) ~= "string" or msg.ver == VERSION then return end
    if type(msg.size) ~= "number" or type(msg.chunks) ~= "number" or msg.chunks < 1 or msg.chunks > 200 then return end
    if type(msg.hashes) ~= "table" or #msg.hashes ~= msg.chunks then return end
    local want = hmac(KEY, "alk_update|" .. msg.ver .. "|" .. msg.size .. "|" .. table.concat(msg.hashes, ","))
    if want ~= msg.mac then
        log("rejected an update offer from #" .. tostring(id) .. ": bad signature")
        return
    end
    log("update " .. msg.ver .. " offered by #" .. tostring(id) .. ", downloading " .. msg.chunks .. " parts")
    upd = { from = id, ver = msg.ver, size = msg.size, hashes = msg.hashes, chunks = msg.chunks, parts = {}, i = 1, tries = 0 }
    requestChunk()
end

local function finishUpdate()
    local text = table.concat(upd.parts)
    local u = upd
    upd = nil
    if #text ~= u.size then
        log("update " .. u.ver .. " has the wrong size")
        return
    end
    if not loadstring(text, "=airlock") then
        log("update " .. u.ver .. " does not compile")
        return
    end
    local path = programPath()
    local tmp = path .. ".new"
    local ok = pcall(function()
        local h = fs.open(tmp, "w")
        h.write(text)
        h.close()
    end)
    local back = ok and readText(tmp)
    if not back or back:gsub("[\r\n]+$", "") ~= text:gsub("[\r\n]+$", "") then
        pcall(fs.delete, tmp)
        log("update " .. u.ver .. " could not be written; is the computer full?")
        return
    end
    fs.delete(path)
    fs.move(tmp, path)
    saveState()
    log("update " .. u.ver .. " installed, rebooting")
    os.reboot()
end

local function onChunk(id, msg)
    if not upd or id ~= upd.from or msg.ver ~= upd.ver or msg.i ~= upd.i or type(msg.data) ~= "string" then return end
    if sha256(msg.data) ~= upd.hashes[upd.i] then
        log("update part " .. upd.i .. " failed its checksum")
        return
    end
    upd.parts[upd.i] = msg.data
    upd.i = upd.i + 1
    upd.tries = 0
    if upd.i > upd.chunks then finishUpdate() else requestChunk() end
end

local function runtimeLoop()
    local failsafeTimer = nil
    local peerTimer = nil
    local searchTimer = os.startTimer(SEARCH_EVERY)
    local beatTimer = os.startTimer(HEARTBEAT)
    local peerBeat = os.startTimer(PEER_EVERY)
    if (not state.oxygenated) and state.failsafe and not state.sealed and not isSensor() then
        failsafeTimer = os.startTimer(state.failsafeDelay)
    end
    tellPeers()
    render()
    while true do
        local ev = { os.pullEvent() }
        local e = ev[1]

        if e == "redstone" then
            local o2 = readOxygen()
            if o2 ~= state.oxygenated then
                log("detector: " .. (o2 and "oxygen" or "NO OXYGEN"))
                state.oxygenated = o2
                saveState()
                sendStatus("alk_status")
                tellPeers()
                if isSensor() then peerBeat = os.startTimer(1) end
                render()
                if (not o2) and state.failsafe and not state.sealed and not isSensor() then
                    local justOpened = unsealedAt ~= nil and os.clock() - unsealedAt < OPEN_GRACE
                    failsafeTimer = os.startTimer(state.failsafeDelay + (justOpened and OPEN_GRACE or 0))
                elseif o2 then
                    failsafeTimer = nil
                end
            end

        elseif e == "timer" then
            if failsafeTimer and ev[2] == failsafeTimer then
                failsafeTimer = nil
                if (not state.oxygenated) and not state.sealed then
                    log("failsafe: own detector has no oxygen, sealing")
                    applyPhysical(true)
                    saveState()
                    sendStatus("alk_status")
                    render()
                end
            elseif peerTimer and ev[2] == peerTimer then
                peerTimer = nil
                if not state.sealed then
                    log("a sensor it listens to reports no oxygen, sealing")
                    applyPhysical(true)
                    saveState()
                    sendStatus("alk_status")
                    render()
                end
            elseif pending and ev[2] == pending.timer then
                if pending.tries >= RETRY_MAX then
                    log("server did not answer " .. RETRY_MAX .. " status reports")
                    pending = nil
                elseif linked() then
                    local m = message("alk_status")
                    rednet.send(state.serverId, m)
                    pending = { reqID = m.reqID, tries = pending.tries + 1, timer = os.startTimer(RETRY_EVERY) }
                end
            elseif flashTimer and ev[2] == flashTimer then
                flashTimer = nil
                if flashing() then
                    flashOn = not flashOn
                    flashTimer = os.startTimer(FLASH)
                else
                    flashOn = false
                end
                render()
            elseif upd and ev[2] == upd.timer then
                upd.tries = upd.tries + 1
                if upd.tries > CHUNK_TRIES then
                    log("update " .. upd.ver .. " stopped: no answer for part " .. upd.i)
                    upd = nil
                else
                    requestChunk()
                end
            elseif ev[2] == beatTimer then
                beatTimer = os.startTimer(HEARTBEAT)
                if linked() then rednet.send(state.serverId, message("alk_hello")) end
            elseif ev[2] == peerBeat then
                peerBeat = os.startTimer(PEER_EVERY)
                tellPeers()
            elseif ev[2] == searchTimer then
                searchTimer = os.startTimer(SEARCH_EVERY)
                if not linked() then
                    announce()
                    render()
                end
            end

        elseif e == "rednet_message" then
            local id, msg = ev[2], ev[3]
            if type(msg) == "table" and type(msg.type) == "string" then
                if msg.type == "alk_discover" then
                    adopt(id)
                    announce()
                    render()
                elseif msg.type == "alk_peer" then
                    local key
                    if type(msg.group) == "string" then key = "g:" .. msg.group elseif type(msg.room) == "string" then key = "r:" .. msg.room end
                    local mine
                    for _, k in ipairs(peerKeys()) do if k.key == key then mine = k end end
                    if mine and type(msg.oxygenated) == "boolean" then
                        local was = interlocked()
                        local low = not msg.oxygenated
                        local p = peers[key]
                        if not p or p.low ~= low then log((mine.kind == "hall" and "hallway sensor" or ("room " .. tostring(mine.label))) .. ": " .. (low and "NO OXYGEN" or "oxygen")) end
                        peers[key] = { low = low, at = os.clock(), since = (low and p and p.low) and p.since or os.clock() }
                        if was ~= interlocked() then
                            log(interlocked() and "interlock on: will not open" or "interlock off")
                            sendStatus("alk_status")
                        end
                        render()
                        local justOpened = unsealedAt ~= nil and os.clock() - unsealedAt < OPEN_GRACE
                        local anyLow = false
                        for _, k in ipairs(peerKeys()) do
                            local q = peers[k.key]
                            if q and q.low and os.clock() - q.at < PEER_STALE then anyLow = true end
                        end
                        if anyLow and state.failsafe and not state.sealed and not justOpened then
                            peerTimer = peerTimer or os.startTimer(PEER_DELAY)
                        elseif not anyLow then
                            peerTimer = nil
                        end
                    end
                elseif msg.type == "alk_update" then
                    startUpdate(id, msg)
                elseif msg.type == "alk_chunk" then
                    onChunk(id, msg)
                elseif msg.type == "alk_dump" and (id == state.serverId or not linked()) then
                    rednet.send(id, { type = "alk_log", nonce = msg.nonce, text = logTail() })
                elseif msg.type == "alk_ack" and (id == state.serverId or not linked()) then
                    if onAck(id, msg) == "refused" then sendStatus("alk_status") end
                    render()
                elseif id == state.serverId then
                    lastHeard = os.clock()
                    if msg.type == "alk_poll" then
                        sendStatus("alk_status_reply")
                    elseif msg.type == "alk_cmd" then
                        noteLockdown(msg.lockdown)
                        noteServerInfo(msg)
                        local wasSealed = state.sealed
                        local res = applyCommand(msg.action, msg.locked, msg.force)
                        log("cmd from #" .. tostring(id) .. ": " .. tostring(msg.action) .. (msg.locked and " locked" or "") .. (msg.force and " forced" or "") .. (res == "refused" and " REFUSED (zone sensor no oxygen)" or (wasSealed ~= state.sealed and "" or " (no change)")))
                        saveState()
                        sendStatus("alk_status")
                        render()
                    end
                end
            end

        elseif e == "key" then
            if ev[2] == keys.s then
                term.setCursorBlink(false)
                runSetup()
                render()
            end

        elseif e == "monitor_resize" or e == "peripheral" or e == "peripheral_detach" or e == "term_resize" then
            if e == "peripheral" then openModems() end
            findMonitor()
            render()
        end
    end
end

if not openModems() then
    print("No modem attached. Add a wireless or wired modem and reboot.")
    return
end

loadState()
loadKey()
findMonitor()
state.oxygenated = readOxygen()
log("boot " .. tostring(state.name) .. " (" .. tostring(state.role) .. ") version " .. VERSION .. (KEY and ", update key present" or ", no update key") .. ", detector " .. (state.oxygenated and "oxygen" or "NO OXYGEN") .. ", door " .. (state.sealed and "sealed" or "open"))

if not state.name then
    runSetup()
else
    applyPhysical(state.sealed)
    bootHandshake()
end

runtimeLoop()
