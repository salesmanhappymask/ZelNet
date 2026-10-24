local STATE_FILE = "/airlock.dat"
local SILENT_AFTER = 960
local SEARCH_EVERY = 60
local PEER_DELAY = 2

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
}

local monitor = nil
local lastHeard = nil

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
    return state.role == "sensor"
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

local function applyCommand(cmd, locked)
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
        put(2, 1, sensor and "OXYGEN SENSOR" or "AIRLOCK", C_BRAND, C_HEAD)
        local nm = state.name or "unnamed"
        put(math.max(2, w - #nm), 1, nm, C_BG, C_HEAD)
    end

    local bannerCol = danger and C_ERR or C_OK
    local bannerTxt
    if locked then
        bannerCol = C_LOCK
        bannerTxt = compact and "LOCKED" or "LOCKED BY CONTROL"
    elseif compact then
        bannerTxt = danger and "VENT!" or "SAFE"
    elseif sensor then
        bannerTxt = danger and "CHAMBER VENTED" or "CHAMBER OK"
    else
        bannerTxt = danger and "!! DEPRESSURIZED !!" or "AREA SEALED - SAFE"
    end
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
    if compact then
        put(1, sy, centerText(w, "O2:" .. (state.oxygenated and "PRESENT" or "NONE")),
            state.oxygenated and C_OK or C_ERR, C_BG)
        if sensor then
            put(1, sy + 1, centerText(w, "Sensor"), C_MUTED, C_BG)
        else
            put(1, sy + 1, centerText(w, "Door:" .. (locked and "LOCK" or (state.sealed and "SEAL" or "OPEN"))),
                locked and C_LOCK or (state.sealed and C_ERR or C_OK), C_BG)
        end
        put(1, sy + 2, centerText(w, "Srv:" .. serverText(true)), linked() and C_MUTED or C_LOCK, C_BG)
    else
        put(2, sy, "Oxygen  : " .. (state.oxygenated and "PRESENT" or "NONE"),
            state.oxygenated and C_OK or C_ERR, C_BG)
        if sensor then
            put(2, sy + 1, "Role    : oxygen sensor", C_MUTED, C_BG)
        else
            put(2, sy + 1, "Bulkhead: " .. (locked and "LOCKED" or (state.sealed and "SEALED" or "OPEN")),
                locked and C_LOCK or (state.sealed and C_ERR or C_OK), C_BG)
        end
        put(2, sy + 2, "Server  : " .. serverText(false), linked() and C_MUTED or C_LOCK, C_BG)
        if sensor then
            put(2, sy + 3, "Detect " .. state.detectorSide, C_MUTED, C_BG)
        else
            put(2, sy + 3, "Detect " .. state.detectorSide .. " / Door " .. state.airlockSide, C_MUTED, C_BG)
        end
    end
    if isTerm and h >= 2 then
        put(1, h, centerText(w, "S: setup"), C_MUTED, C_BG)
    end
end

local function render()
    paint(term, true)
    if monitor then pcall(paint, monitor, false) end
end

local function message(kind)
    return {
        type = kind,
        name = state.name,
        role = state.role,
        oxygenated = state.oxygenated,
        sealed = state.sealed,
        locked = state.locked,
        reqID = newReqID(),
    }
end

local function sendStatus(kind)
    if linked() then
        rednet.send(state.serverId, message(kind))
    else
        rednet.broadcast(message(state.registered and "alk_hello" or "alk_register"))
    end
end

local function announce()
    sendStatus(state.registered and "alk_hello" or "alk_register")
end

local function tellPeers()
    local group = nameBase(state.name)
    if isSensor() and group then
        pcall(rednet.broadcast, { type = "alk_peer", group = group, oxygenated = state.oxygenated })
    end
end

local function adopt(id)
    if state.serverId ~= id then
        state.serverId = id
        saveState()
    end
    lastHeard = os.clock()
end

local function onAck(id, msg)
    adopt(id)
    if not state.registered then state.registered = true end
    applyCommand(msg.command, msg.locked)
    saveState()
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

local function runSetup()
    state.role = askChoice("What is this computer?", "Pick its job:", {
        { label = "Bulkhead door (opens and seals)", value = "door" },
        { label = "Oxygen sensor (no door)", value = "sensor" },
    }, state.role)
    local suggestion = state.name
    if not suggestion then suggestion = isSensor() and "dock-C" or "dock-A" end
    local hint = isSensor() and "Same name as its doors, ending in -C (dock-C):" or "Doors of one airlock share a name: dock-A, dock-B:"
    state.name = askText("Name", hint, suggestion)
    state.detectorSide = askChoice("Oxygen detector", "Which side gets the detector's redstone?", sideOptions(), state.detectorSide)
    if isSensor() then
        state.sealed = false
    else
        state.airlockSide = askChoice("Door output", "Which side drives the airlock door?", sideOptions(), state.airlockSide)
        state.failsafe = askChoice("Failsafe", "Seal by itself if the air goes and the server is silent?", {
            { label = "Yes (recommended)", value = true },
            { label = "No", value = false },
        }, state.failsafe)
    end
    state.displayWidth = askChoice("Monitor", "How many blocks wide is the monitor (if any)?", {
        { label = "1 wide (compact)", value = 1 },
        { label = "2 wide", value = 2 },
        { label = "3 wide", value = 3 },
    }, state.displayWidth)
    state.oxygenated = readOxygen()
    applyPhysical(state.sealed)
    saveState()
    findMonitor()
    bootHandshake()
end

local function runtimeLoop()
    local failsafeTimer = nil
    local peerTimer = nil
    local searchTimer = os.startTimer(SEARCH_EVERY)
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
                state.oxygenated = o2
                saveState()
                sendStatus("alk_status")
                tellPeers()
                render()
                if (not o2) and state.failsafe and not state.sealed and not isSensor() then
                    failsafeTimer = os.startTimer(state.failsafeDelay)
                elseif o2 then
                    failsafeTimer = nil
                end
            end

        elseif e == "timer" then
            if failsafeTimer and ev[2] == failsafeTimer then
                failsafeTimer = nil
                if (not state.oxygenated) and not state.sealed then
                    applyPhysical(true)
                    saveState()
                    sendStatus("alk_status")
                    render()
                end
            elseif peerTimer and ev[2] == peerTimer then
                peerTimer = nil
                if not state.sealed then
                    applyPhysical(true)
                    saveState()
                    sendStatus("alk_status")
                    render()
                end
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
                    if not isSensor() and nameBase(state.name) ~= nil and msg.group == nameBase(state.name) then
                        if msg.oxygenated == false and state.failsafe and not state.sealed then
                            peerTimer = peerTimer or os.startTimer(PEER_DELAY)
                        elseif msg.oxygenated == true then
                            peerTimer = nil
                        end
                    end
                elseif msg.type == "alk_ack" and (id == state.serverId or not linked()) then
                    onAck(id, msg)
                    render()
                elseif id == state.serverId then
                    lastHeard = os.clock()
                    if msg.type == "alk_poll" then
                        sendStatus("alk_status_reply")
                    elseif msg.type == "alk_cmd" then
                        applyCommand(msg.action, msg.locked)
                        saveState()
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
findMonitor()
state.oxygenated = readOxygen()

if not state.name then
    runSetup()
else
    applyPhysical(state.sealed)
    bootHandshake()
end

runtimeLoop()
