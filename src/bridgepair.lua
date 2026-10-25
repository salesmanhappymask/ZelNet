local need = ...
local compat = need("compat")
local util = need("util")
local codec = need("codec")
local crypto = need("crypto")

local M = {}

M.FILE = "zn_pair.dat"
M.FORMAT = 1
M.ANSWER_WAIT = 180
M.LISTEN_WAIT = 1800
M.POLL = 0.5
M.SETTLE = 0.4

local function rethrow(ok, err)
    if not ok and err == "Terminated" then error("Terminated", 0) end
    return ok, err
end

local function bridgeMod(opts)
    return (opts and opts.bridge) or need("bridge")
end

function M.usedGear(cfg)
    local used = {}
    local okP, prov = pcall(need, "provision")
    if okP and type(prov) == "table" and prov.excludeFor then used = prov.excludeFor(cfg) end
    for _, b in ipairs(type(cfg) == "table" and cfg.bridges or {}) do
        if type(b) == "table" then
            for _, k in ipairs({ "sendTess", "recvTess", "sendDrive", "recvDrive" }) do
                if type(b[k]) == "string" then used[b[k]] = true end
            end
        end
    end
    return used
end

M.SIDES = { top = true, bottom = true, left = true, right = true, front = true, back = true }

function M.freeGear(cfg, opts)
    if opts and opts.gear then return opts.gear end
    local gear = bridgeMod(opts).findGear(M.usedGear(cfg))
    local drives = {}
    for _, d in ipairs(gear.drives) do
        if not M.SIDES[d] then drives[#drives + 1] = d end
    end
    gear.drives = drives
    return gear
end

local function frequency(tess)
    local ok, f = rethrow(pcall(peripheral.call, tess, "getFrequency"))
    if ok then return f end
    return nil
end

local function aad(t)
    return table.concat({ "zp" .. M.FORMAT, tostring(t.op), tostring(t.from), tostring(t.to), tostring(t.network), tostring(t.nonce), tostring(t.channel) }, "|")
end

function M.sign(cfg, t)
    t.zp = M.FORMAT
    t.network = cfg.network
    t.mac = crypto.mac(cfg.backboneKey, aad(t))
    return t
end

function M.verify(cfg, t)
    if type(t) ~= "table" or t.zp ~= M.FORMAT then return false, "not a pairing message" end
    if t.network ~= cfg.network then return false, "it comes from the network " .. tostring(t.network) .. ", this server is in " .. tostring(cfg.network) end
    if type(t.mac) ~= "string" or not crypto.constEq(crypto.mac(cfg.backboneKey, aad(t)), t.mac) then
        return false, "its signature does not match this network's key"
    end
    if util.normRealm(t.from) == nil then return false, "it names no realm" end
    if util.normRealm(t.from) == util.normRealm(cfg.realm) then return false, "it comes from this server's own realm" end
    return true
end

local function mountOf(mod, drive)
    local m = mod.mountOf(drive)
    if not m then
        compat.sleep(0.2)
        m = mod.mountOf(drive)
    end
    return m
end

function M.readNote(mod, drive)
    local m = mountOf(mod, drive)
    if not m then return nil end
    local text = util.readFile(m .. "/" .. M.FILE)
    if not text then return nil end
    local ok, t = pcall(codec.decode, text)
    if ok and type(t) == "table" then return t end
    return nil
end

function M.writeNote(mod, drive, t)
    local m = mountOf(mod, drive)
    if not m then return false, drive .. " holds no pocket computer or floppy" end
    pcall(fs.delete, m .. "/" .. mod.FILE)
    return util.writeFile(m .. "/" .. M.FILE, codec.encode(t))
end

function M.clearNote(mod, drive)
    local m = mod.mountOf(drive)
    if m then pcall(fs.delete, m .. "/" .. M.FILE) end
end

local function pullAll(mod, tesses, watch, skip, settle, say)
    for _, tess in ipairs(tesses) do
        if not skip[tess] then
            for _, dir in ipairs(mod.DIRECTIONS) do
                local before = {}
                for _, d in ipairs(watch) do before[d] = mod.diskIn(d) end
                local ok, moved = rethrow(pcall(peripheral.call, tess, "pullItem", dir, 1, 1))
                local function left()
                    for _, d in ipairs(watch) do
                        if before[d] and mod.diskGone(d) then return d end
                    end
                    return nil
                end
                local d = left()
                if not d and ok and (tonumber(moved) or 0) > 0 then
                    compat.sleep(settle)
                    d = left()
                    if not d then
                        return nil, "the tesseract " .. tess .. " took something from its " .. dir .. " side but no disk left. Either it handed the disk back (the drive on the other side is busy, its chunk is not loaded, or no tesseract there shares the frequency " .. tostring(frequency(tess)) .. ") or another inventory touches that side."
                    end
                end
                if d then
                    if say then say(tess .. " " .. dir .. " sent the disk from " .. d) end
                    return { tess = tess, dir = dir, drive = d }
                end
            end
        end
    end
    return false
end

local function fail(mod, drives, text)
    for _, d in ipairs(drives) do M.clearNote(mod, d) end
    return nil, text
end

function M.initiate(cfg, opts)
    opts = opts or {}
    local mod = bridgeMod(opts)
    local say = opts.progress or function() end
    local cancelled = opts.cancelled or function() return false end
    local settle = opts.settle or M.SETTLE
    local wait = opts.wait or M.ANSWER_WAIT
    if type(cfg.backboneKey) ~= "string" or not util.normRealm(cfg.realm) then return nil, "this server has no realm or network key yet" end
    local gear = M.freeGear(cfg, opts)
    local loaded = {}
    for _, d in ipairs(gear.drives) do
        if mod.diskIn(d) then loaded[#loaded + 1] = d end
    end
    if #loaded ~= 2 then
        return nil, "put a blank pocket computer in each of the two new drives and leave the other free drives empty (found " .. #loaded .. " free drive(s) holding a disk)"
    end
    if #gear.tesseracts < 2 then return nil, "found " .. #gear.tesseracts .. " free tesseract(s); a bridge needs 2" end
    local nonce = crypto.randHex(8)
    local realm = util.normRealm(cfg.realm)
    for _, d in ipairs(loaded) do
        local ok, err = M.writeNote(mod, d, M.sign(cfg, { op = "hello", from = realm, nonce = nonce, channel = "hello" }))
        if not ok then return fail(mod, loaded, "cannot write to the disk in " .. d .. ": " .. tostring(err)) end
    end
    say("Sending the first pocket computer through the tesseracts...")
    local send, err = pullAll(mod, gear.tesseracts, loaded, {}, settle, say)
    if not send then
        return fail(mod, loaded, err or ("neither disk left through a free tesseract. Check that each drive touches its own tesseract, that the other server's tesseracts share these two frequencies and that its drives are empty."))
    end
    local other = send.drive == loaded[1] and loaded[2] or loaded[1]
    say("The first disk is across. Waiting for the other server to answer...")
    local peer
    local deadline = compat.now() + wait
    while compat.now() < deadline and not peer do
        if cancelled() then return fail(mod, { other }, "cancelled") end
        if mod.diskIn(send.drive) then
            local note = M.readNote(mod, send.drive)
            if note and note.op == "ack" and note.nonce == nonce and util.normRealm(note.to) == realm then
                local ok, why = M.verify(cfg, note)
                if not ok then return fail(mod, { send.drive, other }, "the answer was refused: " .. why) end
                M.clearNote(mod, send.drive)
                peer = util.normRealm(note.from)
            end
        end
        if not peer then compat.sleep(M.POLL) end
    end
    if not peer then
        return fail(mod, { other }, "the other server did not answer within " .. wait .. " seconds. Put it in setup mode (Bridges, Add, Wait for the other side), take the disk back out of its drive and run this again.")
    end
    say(peer .. " answered. Sending the second pocket computer...")
    local skip = { [send.tess] = true }
    local recv, rerr = pullAll(mod, gear.tesseracts, { other }, skip, settle, say)
    if not recv then
        return fail(mod, { other }, rerr or ("the disk in " .. other .. " did not leave through the other tesseract. Check that a tesseract touches " .. other .. " and that the other server's second drive is empty."))
    end
    return {
        peer = peer,
        sendTess = send.tess, sendDrive = send.drive, sendDir = send.dir,
        recvTess = recv.tess, recvDrive = recv.drive, recvDir = recv.dir,
    }, { freqSend = frequency(send.tess), freqRecv = frequency(recv.tess) }
end

function M.listen(cfg, opts)
    opts = opts or {}
    local mod = bridgeMod(opts)
    local say = opts.progress or function() end
    local cancelled = opts.cancelled or function() return false end
    local settle = opts.settle or M.SETTLE
    local wait = opts.wait or M.LISTEN_WAIT
    if type(cfg.backboneKey) ~= "string" or not util.normRealm(cfg.realm) then return nil, "this server has no realm or network key yet" end
    local gear = M.freeGear(cfg, opts)
    if #gear.drives < 2 then return nil, "found " .. #gear.drives .. " free drive(s); a bridge needs 2" end
    if #gear.tesseracts < 2 then return nil, "found " .. #gear.tesseracts .. " free tesseract(s); a bridge needs 2" end
    local realm = util.normRealm(cfg.realm)
    local st = {}
    local warned = {}
    say("Setup mode: waiting for a pocket computer in " .. table.concat(gear.drives, ", ") .. ".")
    local deadline = compat.now() + wait
    while compat.now() < deadline do
        if cancelled() then return nil, "cancelled" end
        for _, d in ipairs(gear.drives) do
            local note = mod.diskIn(d) and M.readNote(mod, d)
            if type(note) == "table" and note.op == "hello" then
                local ok, why = M.verify(cfg, note)
                if not ok then
                    if not warned[d] then
                        warned[d] = true
                        say("Ignored the disk in " .. d .. ": " .. why)
                    end
                elseif note.nonce ~= st.nonce or not st.recvTess then
                    st = { peer = util.normRealm(note.from), nonce = note.nonce }
                    local wok, werr = M.writeNote(mod, d, M.sign(cfg, { op = "ack", from = realm, to = st.peer, nonce = note.nonce, channel = "ack" }))
                    if not wok then return nil, "cannot write the answer to the disk in " .. d .. ": " .. tostring(werr) end
                    say("Answering " .. st.peer .. " through the tesseract next to " .. d .. "...")
                    local hit, err = pullAll(mod, gear.tesseracts, { d }, {}, settle, say)
                    if not hit then
                        M.clearNote(mod, d)
                        return nil, err or ("cannot send the disk in " .. d .. " back: no free tesseract touching it would take it")
                    end
                    st.recvDrive, st.recvTess, st.recvDir = d, hit.tess, hit.dir
                    say("Answered " .. st.peer .. ". Waiting for the second pocket computer...")
                elseif d ~= st.recvDrive then
                    M.clearNote(mod, d)
                    local others = {}
                    for _, t in ipairs(gear.tesseracts) do
                        if t ~= st.recvTess then others[#others + 1] = t end
                    end
                    if #others ~= 1 then
                        return nil, "more than two free tesseracts here and no way to tell which one touches " .. d .. "; disconnect the spare ones and try again"
                    end
                    return {
                        peer = st.peer,
                        sendTess = others[1], sendDrive = d,
                        recvTess = st.recvTess, recvDrive = st.recvDrive, recvDir = st.recvDir,
                    }
                end
            end
        end
        compat.sleep(M.POLL)
    end
    return nil, "no pocket computer arrived within " .. math.floor(wait / 60) .. " minutes"
end

return M
