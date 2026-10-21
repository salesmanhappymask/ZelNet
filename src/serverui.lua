local need = ...
local compat = need("compat")
local util = need("util")
local crypto = need("crypto")
local codec = need("codec")
local config = need("config")
local version = need("version")
local ui = need("ui")
local cipherMod = need("cipher")

local M = {}

M.LOCK_AFTER = 300
M.LOCK_SIGNAL = "zn_console_lock"
M.SENSOR_POLL = 1
M.SENSOR_WATCH = 2
M.SENSOR_MISSES = 3
M.SENSOR_RANGE = 3
M.SENSOR_RETRY = 10
M.MAX_FAILS = 3
M.FAIL_HOLD = 10
M.GUIDE_WAIT = 60
M.VIEW_TITLES = { realms = "Realms", routes = "Routes", neighbors = "Neighbors", links = "Links" }
M.ROLE_TITLES = { client = "Client", router = "Router", endpoint = "Endpoint", satellite = "Satellite server", main = "Main server" }
M.DIRECTIONS = { "north", "south", "east", "west", "up", "down" }
M.INPUT_EVENTS = { key = true, char = true, mouse_click = true, mouse_scroll = true, mouse_drag = true, paste = true }
M.STORAGE_ROLES = { "accounts", "mail", "chat", "audit", "system" }

M.ERR_TEXT = {
    taken = "That name is already taken.",
    bad_name = "Names use 3 to 16 lower case letters, digits or _ and start with a letter.",
    weak_password = "Passwords need at least 4 characters.",
    unknown_user = "There is no such user.",
    offline = "The home server of that user cannot be reached right now.",
    denied = "Not allowed.",
    storage = "Storage is offline. Check the drives under Storage.",
    bad_request = "The request was not valid.",
    timeout = "No answer in time.",
    no_route = "No route to that realm.",
}

M.CIPHER_GUIDE = {
    "Every ZelNet server needs a Computronics Cipher Block next to it (or on a wired modem).",
    "Put the same six item stacks, in the same slots, into the Cipher Block of every server. The items form the shared key; servers whose items differ cannot talk.",
    "Install OpenPeripheral as well: the tesseract bridges between dimensions need it.",
    "Without a working block this server serves its own realm only.",
}

local function packn(...)
    return { n = select("#", ...), ... }
end

local function errText(err)
    if err == nil then return "Unknown error." end
    return M.ERR_TEXT[err] or tostring(err)
end

M.errText = errText

function M.setPassword(cfg, pw)
    local salt = crypto.randHex(16)
    cfg.console = { salt = salt, hash = crypto.passwordHash(salt, tostring(pw)) }
    return cfg.console
end

function M.checkPassword(cfg, pw)
    local c = type(cfg) == "table" and cfg.console
    if type(c) ~= "table" or type(c.salt) ~= "string" or type(c.hash) ~= "string" then return false end
    if type(pw) ~= "string" or pw == "" then return false end
    return crypto.constEq(crypto.passwordHash(c.salt, pw), c.hash) == true
end

function M.passwordProblem(pw, again)
    if type(pw) ~= "string" or #pw < 4 then return "Use at least 4 characters." end
    if again ~= nil and pw ~= again then return "The two passwords differ." end
    return nil
end

local function getAny(t, list)
    if type(t) ~= "table" then return nil end
    for i = 1, #list do
        local v = t[list[i]]
        if v ~= nil then return v end
    end
    return nil
end

function M.distFromInfo(t)
    local d = tonumber(getAny(t, { "Distance", "distance" }))
    if d then return d end
    local pos = getAny(t, { "Position", "position", "Pos", "pos" })
    if type(pos) == "table" then
        local x = tonumber(getAny(pos, { "X", "x" }))
        local y = tonumber(getAny(pos, { "Y", "y" }))
        local z = tonumber(getAny(pos, { "Z", "z" }))
        if x and y and z then return math.sqrt(x * x + y * y + z * z) end
    end
    return nil
end

function M.targetNameAndDist(prox, k, basic)
    local uname = getAny(basic, { "Username", "username" }) or getAny(basic, { "Name", "name" })
    local dist = M.distFromInfo(basic)
    if (not uname or not dist) and type(prox) == "table" and prox.getTargetDetails then
        local details
        pcall(function()
            details = prox.getTargetDetails(k)
            if details == nil then details = prox.getTargetDetails(tostring(k)) end
        end)
        uname = uname or getAny(details, { "Username", "username" }) or getAny(details, { "Name", "name" })
        dist = dist or M.distFromInfo(details)
    end
    if not uname and type(k) == "string" and k ~= "" then uname = k end
    return uname, dist
end

function M.findSensor()
    if not rawget(_G, "sensor") and fs.exists("ocs/apis/sensor") and os.loadAPI then
        pcall(os.loadAPI, "ocs/apis/sensor")
    end
    local api = rawget(_G, "sensor")
    local seen, candidates = {}, {}
    local names = peripheral.getNames and peripheral.getNames() or {}
    for _, side in ipairs({ "left", "right", "top", "bottom", "front", "back" }) do names[#names + 1] = side end
    for _, name in ipairs(names) do
        if not seen[name] and peripheral.isPresent(name) and peripheral.getType(name) == "sensor" then
            seen[name] = true
            candidates[#candidates + 1] = name
        end
    end
    for _, name in ipairs(candidates) do
        local p
        if type(api) == "table" and api.wrap then
            local ok, wrapped = pcall(api.wrap, name)
            if ok then p = wrapped end
        end
        if not (type(p) == "table" and p.getTargets) then
            local raw = peripheral.wrap(name)
            if type(raw) == "table" and raw.getTargets then p = raw end
        end
        if type(p) == "table" and p.getTargets then return p, name end
    end
    return nil
end

M.PLAYERS_MAX = 120

function M.playerList(v)
    local out, seen = {}, {}
    local function add(name)
        name = tostring(name):match("^%s*(.-)%s*$")
        if name ~= "" and not seen[name:lower()] then
            seen[name:lower()] = true
            out[#out + 1] = name
        end
    end
    if type(v) == "table" then
        for _, name in ipairs(v) do add(name) end
    elseif type(v) == "string" then
        for name in v:gmatch("[^,]+") do add(name) end
    end
    return out
end

function M.playerText(v)
    return table.concat(M.playerList(v), ", ")
end

function M.scanTargets(prox, players, range)
    if type(prox) ~= "table" then return false, "no sensor attached" end
    local list = M.playerList(players)
    if #list == 0 then return false, "no player set" end
    range = tonumber(range) or M.SENSOR_RANGE
    local ok, targets = pcall(function() return prox.getTargets() end)
    if not ok or type(targets) ~= "table" then return false, "no sensor data" end
    local want = {}
    for _, name in ipairs(list) do want[name:lower()] = name end
    local count, best, bestName, seenNoPos = 0, nil, nil, nil
    for k, basic in pairs(targets) do
        count = count + 1
        local uname, dist = M.targetNameAndDist(prox, k, basic)
        local name = type(uname) == "string" and want[uname:lower()] or nil
        if name then
            if dist == nil then
                seenNoPos = seenNoPos or name
            elseif best == nil or dist < best then
                best, bestName = dist, name
            end
        end
    end
    if best ~= nil then
        return best <= range, bestName .. " at " .. util.fmtFixed(best, 1) .. " (needs " .. util.fmtFixed(range, 1) .. " or less)", bestName
    end
    if seenNoPos then return false, seenNoPos .. " seen, no position data" end
    return false, "watching (" .. count .. " targets)"
end

local Console = {}
Console.__index = Console

function M.new(ctx, opts)
    opts = opts or {}
    local self = setmetatable({}, Console)
    self.ctx = ctx
    self.cfg = ctx.cfg
    self.n = ctx.node
    self.log = ctx.log or (ctx.node and ctx.node.log) or util.newLogger(50)
    self.surf = opts.surface or ui.surface(term)
    self.noLock = 0
    self.locked = true
    self.latch = false
    self.lockReq = nil
    self.near = false
    self.misses = 0
    self.sensorNote = nil
    self.lastInput = compat.now()
    self.snap = nil
    self.snapAt = -100
    self.fails = 0
    self.holdUntil = 0
    self.unlockedBy = nil
    self.noTasks = opts.noTasks
    self.ownThread = opts.ownThread
    return self
end

function Console:try(fn, ...)
    if type(fn) ~= "function" then return nil end
    local r = packn(pcall(fn, ...))
    if not r[1] then return nil, r[2] end
    return compat.unpack(r, 2, r.n)
end

function Console:call(obj, method, ...)
    if type(obj) ~= "table" or type(obj[method]) ~= "function" then return nil, "not available" end
    return self:try(obj[method], obj, ...)
end

function Console:audit(action, target, detail, ok)
    local st = self.ctx.storage
    if st and st.audit then pcall(st.audit, st, "console", action, target, detail, ok ~= false) end
end

function Console:lockAfter()
    local v = tonumber(self.cfg.lockAfter)
    if v == nil then return M.LOCK_AFTER end
    return v
end

function Console:installHook()
    if self.hookBase then return end
    local base = os.pullEvent
    self.hookBase = base
    self.co = coroutine.running()
    local me = self
    os.pullEvent = function(filter)
        local ev = packn(base(filter))
        if me:isMine() then me:onEvent(ev[1]) end
        return compat.unpack(ev, 1, ev.n)
    end
end

function Console:isMine()
    if self.ownThread then return self.ownThread() end
    return coroutine.running() == self.co
end

function Console:removeHook()
    if self.hookBase then
        os.pullEvent = self.hookBase
        self.hookBase = nil
    end
end

function Console:onEvent(ev)
    local now = compat.now()
    if M.INPUT_EVENTS[ev] then self.lastInput = now end
    if self.locked or self.noLock > 0 then return end
    if not self.lockReq then
        local limit = self:lockAfter()
        if limit > 0 and now - self.lastInput >= limit then self.lockReq = "idle" end
    end
    if self.lockReq then error(M.LOCK_SIGNAL, 0) end
end

function Console:requestLock(reason)
    if self.locked then return end
    self.lockReq = reason or "request"
    os.queueEvent("zn_console_wake")
end

function Console:protect(fn, ...)
    local r = packn(pcall(fn, ...))
    if r[1] then return compat.unpack(r, 2, r.n) end
    if r[2] == M.LOCK_SIGNAL then error(M.LOCK_SIGNAL, 0) end
    self.log.error("console: " .. tostring(r[2]))
    self.noLock = 0
    ui.message(self.surf, "Error", { { text = tostring(r[2]), color = self.surf.c.bad } })
    return nil
end

function Console:busy(title, text, fn, ...)
    self.noLock = self.noLock + 1
    ui.busy(self.surf, title, text or "Working...")
    local r = packn(pcall(fn, ...))
    self.noLock = math.max(0, self.noLock - 1)
    if not r[1] then return nil, tostring(r[2]) end
    return compat.unpack(r, 2, r.n)
end

function Console:inTask(title, text, fn)
    local job = { done = false }
    local n = self.n
    if not n or not n.running then return self:busy(title, text, fn) end
    self.noLock = self.noLock + 1
    n:spawn(function()
        job.r = packn(pcall(fn))
        job.done = true
        os.queueEvent("zn_console_job")
    end, "console-job")
    ui.busy(self.surf, title, text or "Working...")
    while not job.done do os.pullEvent() end
    self.noLock = math.max(0, self.noLock - 1)
    if not job.r[1] then return nil, tostring(job.r[2]) end
    return compat.unpack(job.r, 2, job.r.n)
end

function Console:say(title, lines, color)
    if type(lines) == "string" then lines = { lines } end
    local out = {}
    for _, l in ipairs(lines) do
        if type(l) == "table" then out[#out + 1] = l else out[#out + 1] = { text = l, color = color } end
    end
    ui.message(self.surf, title, out)
end

function Console:result(title, ok, err, okText)
    if ok then
        self:say(title, okText or "Done.", self.surf.c.ok)
    else
        self:say(title, errText(err), self.surf.c.bad)
    end
    return ok
end

function Console:save()
    local ok, err = config.save(self.cfg, self.ctx.configPath)
    if not ok then self:say("Settings", "Could not save the config: " .. tostring(err), self.surf.c.bad) end
    return ok
end

function Console:snapshot(force)
    local now = compat.now()
    if not force and self.snap and now - self.snapAt < 1 then return self.snap end
    local ctx = self.ctx
    local s = {}
    s.status = self:call(ctx.server, "status") or {}
    s.storage = self:call(ctx.storage, "info") or {}
    s.ready = self:call(ctx.storage, "ready")
    s.mail = self:call(ctx.tekmail, "stats")
    if ctx.airlock and ctx.airlock.enabled ~= false then s.air = self:call(ctx.airlock, "stats") end
    s.t = now
    self.snap = s
    self.snapAt = now
    return s
end

function M.cards(c, snap, cfg)
    local st = snap.status or {}
    local out = {}
    local roleText = st.isMain and "Main" or ((st.role or cfg.role) == "main" and "Main" or "Satellite")
    out[#out + 1] = {
        title = "Realm " .. tostring(st.realm or cfg.realm), accent = c.brand,
        lines = {
            { "Role", roleText }, { "Uptime", util.fmtDuration(st.uptime or 0) },
            { "Computer", tostring(st.serverId or os.getComputerID()) }, { "Version", tostring(st.prog or version.program) },
        },
    }
    local dev = st.devices or {}
    out[#out + 1] = {
        title = "Devices", accent = c.ok,
        lines = {
            { "Online", tostring(dev.online or 0) .. "/" .. tostring(dev.total or 0), (dev.online or 0) > 0 and c.ok or c.muted },
            { "Links", tostring(#(st.links or {})) },
        },
    }
    local nUp, nAll = 0, 0
    for _, nb in ipairs(st.neighbors or {}) do
        nAll = nAll + 1
        if nb.up then nUp = nUp + 1 end
    end
    local cip = st.cipher or {}
    out[#out + 1] = {
        title = "Backbone", accent = cip.ok and c.accent or c.bad,
        lines = {
            { "Cipher", cip.ok and tostring(cip.kind) or "off", cip.ok and c.ok or c.bad },
            { "Neighbors", nUp .. "/" .. nAll, nUp > 0 and c.ok or c.muted },
            { "Routes", tostring(#(st.routes or {})) },
            { "Queued", tostring((st.queue and st.queue.stored) or 0) },
        },
    }
    local offline, files = {}, 0
    for _, r in ipairs(snap.storage or {}) do
        if r.present == false then offline[#offline + 1] = r.role end
        files = files + (tonumber(r.files) or 0)
    end
    out[#out + 1] = {
        title = "Storage", accent = #offline == 0 and c.ok or c.bad,
        lines = {
            { "State", #offline == 0 and "ready" or ("offline: " .. table.concat(offline, " ")), #offline == 0 and c.ok or c.bad },
            { "Files", tostring(files) },
        },
    }
    local mail = snap.mail or {}
    out[#out + 1] = {
        title = "TekMail", accent = c.purple,
        lines = {
            { "Users", tostring(mail.users or 0) }, { "Sessions", tostring(mail.sessions or 0) },
            { "Outbox", tostring(mail.outbox or 0), (mail.outbox or 0) > 0 and c.warn or nil },
            { "Chat", tostring(mail.chatMessages or 0) },
        },
    }
    if snap.air then
        local a = snap.air
        out[#out + 1] = {
            title = "Airlocks", accent = (a.low or 0) > 0 and c.bad or c.orange,
            lines = {
                { "Nodes", tostring(a.nodes or 0) }, { "Sealed", tostring(a.sealed or 0) },
                { "Low O2", tostring(a.low or 0), (a.low or 0) > 0 and c.bad or nil },
                { "Offline", tostring(a.offline or 0), (a.offline or 0) > 0 and c.warn or nil },
            },
        }
    end
    return out
end

function M.drawCards(page, x, y, w, h, cards)
    local cols = 1
    if w >= 48 then cols = 2 end
    if w >= 78 then cols = 3 end
    local rowsN = math.ceil(#cards / cols)
    local cardH = rowsN > 0 and math.floor(h / rowsN) or h
    while cardH < 4 and rowsN > 1 do
        rowsN = rowsN - 1
        cardH = math.floor(h / rowsN)
    end
    local cardW = math.floor((w - (cols - 1)) / cols)
    local shown = math.min(#cards, rowsN * cols)
    for i = 1, shown do
        local card = cards[i]
        local col = (i - 1) % cols
        local row = math.floor((i - 1) / cols)
        local cx = x + col * (cardW + 1)
        local cy = y + row * cardH
        local ix, iy, iw, ih = page:card(cx, cy, cardW, cardH, card.title, card.accent)
        if ix then
            for k = 1, math.min(ih, #card.lines) do
                local l = card.lines[k]
                page:kv(ix, iy + k - 1, iw, l[1], l[2], l[3])
            end
        end
    end
    return rowsN * cardH
end

function Console:footer(page, x, y, w, actions, backLabel)
    local c = page.c
    local bl = backLabel or "Back"
    page:button(x, y, #bl + 2, 1, bl, c.div, c.text, "back")
    local rx = x + w
    for i, a in ipairs(actions or {}) do
        local label = a.key and (a.label .. " (" .. a.key .. ")") or a.label
        local bw = #label + 2
        if rx - bw < x + #bl + 3 then break end
        rx = rx - bw
        page:button(rx, y, bw, 1, label, a.bg or c.brand, c.text, "act:" .. i)
        rx = rx - 1
    end
end

function Console:listView(o)
    local sel, offset = 1, 0
    local rows = o.rows() or {}
    local interval = o.interval or 2
    local timer = os.startTimer(interval)
    local surf = self.surf
    while true do
        local page = ui.page(surf)
        local sub = type(o.subtitle) == "function" and o.subtitle() or o.subtitle
        local ix, iy, iw, ih = page:container(o.title, sub)
        local top = iy
        if o.draw then top = top + (o.draw(page, ix, iy, iw) or 0) end
        local listH = math.max(1, iy + ih - 2 - top)
        if #rows == 0 then
            page:wrapped(ix, top, iw, listH, o.empty or "Nothing here yet.", page.c.muted)
        else
            sel = util.clamp(sel, 1, #rows)
            if o.onSelect then
                if sel > offset + listH then offset = sel - listH end
                if sel <= offset then offset = sel - 1 end
            end
            offset = page:list(ix, top, iw - 1, listH, rows, offset, o.onSelect and sel or nil, o.onSelect and "item:" or nil)
        end
        self:footer(page, ix, iy + ih - 1, iw, o.actions)
        surf:flush()
        local ev, a, b, c = compat.pullUI()
        local action
        local px, py, kind, btn = surf:pointer(ev, a, b, c)
        if px then
            if kind == "scroll" then
                if o.onSelect then sel = util.clamp(sel + btn, 1, math.max(1, #rows)) else offset = math.max(0, offset + btn) end
            else
                action = page:hit(px, py)
            end
        elseif ev == "key" then
            if ui.isCtrl(a) or a == keys.backspace then
                action = "back"
            elseif a == keys.up then
                if o.onSelect then sel = math.max(1, sel - 1) else offset = math.max(0, offset - 1) end
            elseif a == keys.down then
                if o.onSelect then sel = math.min(math.max(1, #rows), sel + 1) else offset = offset + 1 end
            elseif a == keys.enter and o.onSelect and #rows > 0 then
                action = "item:" .. sel
            end
        elseif ev == "char" then
            for i, act in ipairs(o.actions or {}) do
                if act.key and act.key == a:lower() then action = "act:" .. i end
            end
        elseif ev == "timer" and a == timer then
            timer = os.startTimer(interval)
            rows = o.rows() or rows
        elseif ev == "term_resize" then
            surf:resize()
        end
        if action == "back" then return nil end
        if action then
            local r
            local idx = tonumber(tostring(action):match("^item:(%d+)$"))
            local k = tonumber(tostring(action):match("^act:(%d+)$"))
            if idx and rows[idx] and o.onSelect then
                sel = idx
                r = o.onSelect(rows[idx], idx)
            elseif k and o.actions and o.actions[k] then
                r = o.actions[k].run()
            end
            if r == "back" then return nil end
            if r == "exit" or r == "reboot" or r == "lock" then return r end
            rows = o.rows() or rows
            timer = os.startTimer(interval)
        end
    end
end

function Console:choose(title, subtitle, choices, opts)
    opts = opts or {}
    local items = {}
    for i, ch in ipairs(choices) do items[i] = { label = ch.label, hint = ch.hint, color = ch.color } end
    if #items == 0 then return nil end
    local idx = ui.menu(self.surf, { title = title, subtitle = subtitle, items = items, draw = opts.draw })
    if not idx then return nil end
    return choices[idx].value, choices[idx]
end

function Console:askPassword(title, intro)
    local r = ui.form(self.surf, {
        title = title, intro = intro, submit = "OK",
        fields = { { label = "Password:", key = "pw", mask = true, required = true, trim = false } },
    })
    if not r then return nil end
    return r.pw
end

function Console:changePassword(requireOld)
    local errMsg
    while true do
        local fields = {}
        if requireOld then fields[#fields + 1] = { label = "Current:", key = "old", mask = true, required = true, trim = false } end
        fields[#fields + 1] = { label = "New:", key = "pw", mask = true, required = true, trim = false }
        fields[#fields + 1] = { label = "Repeat:", key = "again", mask = true, required = true, trim = false }
        local r = ui.form(self.surf, {
            title = "Console Password", intro = "The console password unlocks this server's screen and is needed to exit to the shell.",
            fields = fields, submit = "Save", error = errMsg,
        })
        if not r then return false end
        if requireOld and not M.checkPassword(self.cfg, r.old) then
            errMsg = "The current password is wrong."
        else
            local p = M.passwordProblem(r.pw, r.again)
            if p then
                errMsg = p
            else
                M.setPassword(self.cfg, r.pw)
                self:save()
                self:audit("console_password", nil, nil, true)
                self:say("Console Password", "The new password is saved.", self.surf.c.ok)
                return true
            end
        end
    end
end

function Console:drawLock(pw, errMsg)
    local surf = self.surf
    local page = ui.page(surf)
    local c = page.c
    local cfg = self.cfg
    local ix, iy, iw, ih = page:container("Server Locked", "ZelNet " .. tostring(cfg.realm) .. " " .. (M.ROLE_TITLES[cfg.role] or cfg.role))
    local y = iy
    surf:field(ix, y, iw, "This console is locked.", c.text, c.inset)
    y = y + 1
    if #M.playerList(cfg.adminPlayer) > 0 then
        local note = self.sensorNote or "starting sensor"
        surf:field(ix, y, iw, "Proximity: " .. note, c.muted, c.inset)
        y = y + 1
        if self.latch and self.near then
            surf:field(ix, y, iw, "Step away and come back, or type the password.", c.warn, c.inset)
            y = y + 1
        end
    end
    y = y + 1
    surf:field(ix, y, iw, "Console password:", c.text, c.inset)
    page:inputBox(ix, y + 1, iw, pw, true, true)
    if errMsg then surf:field(ix, y + 3, iw, errMsg, c.bad, c.inset) end
    surf:field(ix, iy + ih - 1, iw, "Enter unlocks", c.dim, c.inset, "center")
    surf:flush()
end

function Console:lockScreen()
    self.locked = true
    self.lockReq = nil
    self.misses = 0
    local pw, errMsg = "", nil
    while true do
        self:drawLock(pw, errMsg)
        local ev, a = compat.pullUI()
        if ev == "char" then
            if #pw < 64 then pw = pw .. a end
            errMsg = nil
        elseif ev == "paste" and type(a) == "string" then
            pw = (pw .. a):sub(1, 64)
        elseif ev == "key" then
            if a == keys.backspace then
                pw = pw:sub(1, -2)
            elseif a == keys.enter then
                local now = compat.now()
                if now < self.holdUntil then
                    errMsg = "Too many tries. Wait " .. math.ceil(self.holdUntil - now) .. " s."
                elseif M.checkPassword(self.cfg, pw) then
                    self.fails = 0
                    self:unlock("password")
                    return "password"
                else
                    self.fails = self.fails + 1
                    errMsg = "Wrong password."
                    if self.fails >= M.MAX_FAILS then
                        self:audit("unlock", nil, M.MAX_FAILS .. " bad passwords", false)
                        self.fails = 0
                        self.holdUntil = now + M.FAIL_HOLD
                        errMsg = "Wrong password. Locked for " .. M.FAIL_HOLD .. " s."
                    end
                end
                pw = ""
            end
        elseif ev == "zn_prox_unlock" then
            if self.near and not self.latch then
                self:unlock("proximity")
                return "proximity"
            end
        elseif ev == "term_resize" then
            self.surf:resize()
        end
    end
end

function Console:unlock(method)
    self.locked = false
    self.lockReq = nil
    self.unlockedBy = method
    self.misses = 0
    self.lastInput = compat.now()
    if self.surf.target.setCursorBlink then self.surf.target.setCursorBlink(false) end
    local how = method
    if method == "proximity" and self.nearWho then how = "proximity (" .. self.nearWho .. ")" end
    self:audit("unlock", nil, how, true)
    self.log.info("console unlocked by " .. how)
end

function Console:onSensorResult(near, note, who)
    if self.locked and note ~= self.sensorNote then os.queueEvent("zn_console_wake") end
    self.near = near and true or false
    self.sensorNote = note
    self.nearWho = self.near and who or nil
    if not self.near then self.latch = false end
    if self.locked then
        if self.near and not self.latch then os.queueEvent("zn_prox_unlock") end
    elseif self.unlockedBy == "proximity" then
        if self.near then
            self.misses = 0
        else
            self.misses = self.misses + 1
            if self.misses >= M.SENSOR_MISSES then
                self:audit("auto_lock", nil, "no listed player in sensor range", true)
                self:requestLock("left")
            end
        end
    end
end

function Console:sensorTask()
    local prox
    while true do
        local players = M.playerList(self.cfg.adminPlayer)
        if #players == 0 then
            self.sensorNote = nil
            compat.sleep(M.SENSOR_RETRY)
        else
            if not prox then
                prox = M.findSensor()
                if not prox then self.sensorNote = "no sensor attached" end
            end
            if prox then
                local near, note, who = M.scanTargets(prox, players, self.cfg.adminRange)
                if note == "no sensor data" then prox = nil end
                self:onSensorResult(near, note, who)
                compat.sleep(self.locked and M.SENSOR_POLL or M.SENSOR_WATCH)
            else
                self:onSensorResult(false, "no sensor attached")
                compat.sleep(M.SENSOR_RETRY)
            end
        end
    end
end

function Console:dashboard()
    local surf = self.surf
    local timer = os.startTimer(1)
    while true do
        local snap = self:snapshot()
        local page = ui.page(surf)
        local c = page.c
        page:header("Dashboard", tostring(self.cfg.realm))
        local used = M.drawCards(page, 1, 3, surf.w, surf.h - 4, M.cards(c, snap, self.cfg))
        local warn = (snap.status.warnings or {})[1]
        if warn then surf:field(2, 3 + used, surf.w - 2, "! " .. warn, c.warn, c.bg) end
        surf:field(1, surf.h, surf.w, "Ctrl or Backspace: back", c.dim, c.bg, "center")
        page:hotspot(1, 1, surf.w, surf.h, "back")
        surf:flush()
        local ev, a, b, cc = compat.pullUI()
        if ev == "timer" and a == timer then
            timer = os.startTimer(1)
        elseif ev == "key" and (ui.isCtrl(a) or a == keys.backspace or a == keys.enter) then
            return
        elseif ev == "term_resize" then
            surf:resize()
        elseif surf:pointer(ev, a, b, cc) then
            local px, py, kind = surf:pointer(ev, a, b, cc)
            if kind ~= "scroll" and page:hit(px, py) == "back" then return end
        end
    end
end

function Console:mainItems()
    local isMain = self.cfg.role == "main"
    local items = {
        { label = "Dashboard", run = function() return self:dashboard() end },
        { label = "Devices", run = function() return self:devices() end },
        { label = "Accounts", run = function() return self:accounts() end },
        { label = "Chat", run = function() return self:chat() end },
        { label = "Network", run = function() return self:network() end },
        { label = "Bridges", run = function() return self:bridgesPage() end },
        { label = "Airlocks", run = function() return self:airlocks() end },
        { label = "Storage", run = function() return self:storagePage() end },
        { label = "Audit log", run = function() return self:auditPage() end },
        { label = "Event log", run = function() return self:eventLog() end },
        { label = "Settings", run = function() return self:settings() end },
        { label = isMain and "Update network" or "Update", run = function() return self:updatePage() end },
        { label = "Lock", run = function() return "lock" end },
        { label = "Exit to shell", run = function() return self:exitToShell() end },
        { label = "Reboot", run = function() return self:rebootFlow() end },
    }
    return items
end

function Console:refreshHints(items)
    local snap = self:snapshot()
    local st = snap.status or {}
    local c = self.surf.c
    local dev = st.devices or {}
    items[1].hint = (#(st.warnings or {}) > 0) and (#st.warnings .. " warn") or "ok"
    items[1].hintColor = (#(st.warnings or {}) > 0) and c.warn or c.ok
    items[2].hint = tostring(dev.online or 0) .. "/" .. tostring(dev.total or 0)
    items[3].hint = snap.mail and (tostring(snap.mail.users or 0) .. " users") or nil
    local up = 0
    for _, nb in ipairs(st.neighbors or {}) do if nb.up then up = up + 1 end end
    items[5].hint = up .. " up"
    items[6].hint = tostring(#(st.bridges or {}))
    if snap.air then
        items[7].hint = (snap.air.low or 0) > 0 and ((snap.air.low) .. " LOW") or tostring(snap.air.nodes or 0)
        items[7].hintColor = (snap.air.low or 0) > 0 and c.bad or nil
    else
        items[7].hint = "off"
    end
    items[8].hint = snap.ready == false and "OFFLINE" or "ok"
    items[8].hintColor = snap.ready == false and c.bad or c.ok
end

function Console:mainMenu()
    local items = self:mainItems()
    local sel = 1
    while true do
        self:refreshHints(items)
        local st = self:snapshot().status or {}
        local sub = tostring(self.cfg.realm) .. " " .. (M.ROLE_TITLES[self.cfg.role] or "") .. ", up " .. util.fmtDuration(st.uptime or 0)
        local idx = ui.menu(self.surf, {
            title = "Server Console", subtitle = sub, items = items, selected = sel, back = false,
            refresh = function()
                self:refreshHints(items)
                return nil
            end,
            interval = 5,
            footer = "ZelNet " .. version.program,
        })
        if idx then
            sel = idx
            local r = self:protect(items[idx].run)
            if r == "lock" or r == "exit" or r == "reboot" then return r end
        end
    end
end

function Console:exitToShell()
    local pw = self:askPassword("Exit to Shell", "The server stops serving while you are in the shell. Type the console password to continue.")
    if not pw then return nil end
    if not M.checkPassword(self.cfg, pw) then
        self:audit("exit_shell", nil, "bad password", false)
        self:say("Exit to Shell", "Wrong password.", self.surf.c.bad)
        return nil
    end
    if not ui.confirm(self.surf, "Exit to Shell", "Stop ZelNet and open the shell? Run zelnet or reboot to start it again.", { yes = "Exit", danger = true }) then return nil end
    self:audit("exit_shell", nil, nil, true)
    self:flushAll()
    return "exit"
end

function Console:rebootFlow()
    if not ui.confirm(self.surf, "Reboot", "Reboot this server now? Devices reconnect by themselves.", { yes = "Reboot", danger = true }) then return nil end
    self:audit("reboot", nil, nil, true)
    self:flushAll()
    return "reboot"
end

function Console:flushAll()
    local ctx = self.ctx
    if ctx.server and ctx.server.flushState then pcall(ctx.server.flushState, ctx.server, true) end
    if ctx.tekmail and ctx.tekmail.flush then pcall(ctx.tekmail.flush, ctx.tekmail) end
    if ctx.airlock and ctx.airlock.save then pcall(ctx.airlock.save, ctx.airlock) end
    if ctx.storage and ctx.storage.flush then pcall(ctx.storage.flush, ctx.storage) end
end

function Console:startTasks()
    if self.tasksStarted or self.noTasks or not self.n then return end
    self.tasksStarted = true
    self.n:spawn(function() self:sensorTask() end, "console-sensor")
    local okP, panels = pcall(need, "panels")
    if okP and panels then
        self.panels = panels.new(self)
        self.n:spawn(function() self.panels:run() end, "console-displays")
    end
end

function Console:run()
    self:installHook()
    self:startTasks()
    local ok, res = pcall(function()
        if type(self.cfg.console) ~= "table" then
            self.locked = false
            self.noLock = self.noLock + 1
            while type(self.cfg.console) ~= "table" do
                self:say("Console Password", "This server has no console password yet. Choose one now.", self.surf.c.warn)
                self:changePassword(false)
            end
            self.noLock = self.noLock - 1
        end
        while true do
            self:lockScreen()
            local okMenu, r = pcall(self.mainMenu, self)
            if okMenu then
                if r == "exit" or r == "reboot" then return r end
                self:audit("lock", nil, "manual", true)
                self.latch = true
            elseif r == M.LOCK_SIGNAL then
                self.noLock = 0
                self:audit("auto_lock", nil, tostring(self.lockReq), true)
                self.latch = true
            else
                error(r, 0)
            end
        end
    end)
    self:removeHook()
    if self.surf.target.setCursorBlink then self.surf.target.setCursorBlink(false) end
    if not ok then error(res, 0) end
    return res
end

function M.run(ctx, opts)
    local con = M.new(ctx, opts)
    return con:run()
end

function Console:statusColor(status)
    local c = self.surf.c
    if status == "online" then return c.ok end
    if status == "pending" then return c.warn end
    if status == "revoked" then return c.bad end
    return c.muted
end

function Console:deviceRows()
    local list = self:call(self.ctx.server, "devices") or {}
    local rows = {}
    for _, d in ipairs(list) do
        rows[#rows + 1] = {
            text = tostring(d.name) .. " (" .. tostring(d.role) .. ")",
            right = tostring(d.status) .. (d.cid and (" #" .. tostring(d.cid)) or ""),
            color = self:statusColor(d.status), dev = d,
        }
    end
    return rows
end

function Console:devices()
    return self:listView({
        title = "Devices",
        subtitle = function()
            local st = self:snapshot().status or {}
            local d = st.devices or {}
            return tostring(d.online or 0) .. " of " .. tostring(d.total or 0) .. " online"
        end,
        rows = function() return self:deviceRows() end,
        empty = "No devices yet. Press n to provision a client, router or endpoint onto a pocket computer or disk.",
        onSelect = function(row) return self:deviceMenu(row.dev) end,
        actions = { { label = "New", key = "n", run = function() return self:newDevice() end } },
    })
end

function Console:deviceDetails(d)
    local lines = {
        "Name: " .. tostring(d.name),
        "Role: " .. tostring(M.ROLE_TITLES[d.role] or d.role),
        "Status: " .. tostring(d.status),
        "Computer: " .. (d.cid and ("#" .. tostring(d.cid)) or "not bound yet"),
        "Address: " .. (d.cid and (tostring(self.cfg.realm) .. ":" .. tostring(d.cid)) or "-"),
        "Last seen: " .. (d.lastSeen and util.fmtStamp(d.lastSeen) or "never"),
        "Program: " .. tostring(d.prog or "?"),
        "Hops: " .. tostring(d.hops or "?") .. (d.parent and (" via " .. tostring(d.parent)) or ""),
        "Provisioned: " .. (d.created and util.fmtStamp(d.created) or "?"),
    }
    if d.aliases and #d.aliases > 0 then lines[#lines + 1] = "Names: " .. table.concat(d.aliases, ", ") end
    self:say("Device " .. tostring(d.name), lines)
end

function Console:deviceMenu(d)
    local choice = self:choose("Device " .. tostring(d.name), tostring(d.role) .. ", " .. tostring(d.status), {
        { label = "Details", value = "details" },
        { label = "Reset binding", hint = "new computer", value = "reset" },
        { label = "Revoke", hint = "block it", value = "revoke", color = self.surf.c.warn },
        { label = "Remove", hint = "forget it", value = "remove", color = self.surf.c.bad },
    })
    local srv = self.ctx.server
    if choice == "details" then
        self:deviceDetails(d)
    elseif choice == "reset" then
        if ui.confirm(self.surf, "Reset Binding", "Let " .. d.name .. " bind to the next computer that uses its disk config? Use this when the device moved to a new computer.") then
            local ok, err = self:call(srv, "resetBinding", d.name)
            self:audit("device_reset", d.name, err, ok)
            self:result("Reset Binding", ok, err, d.name .. " binds again on first contact.")
        end
    elseif choice == "revoke" then
        if ui.confirm(self.surf, "Revoke Device", "Revoke " .. d.name .. "? The server ignores it until it is provisioned again.", { yes = "Revoke", danger = true }) then
            local ok, err = self:call(srv, "revoke", d.name)
            self:audit("device_revoke", d.name, err, ok)
            self:result("Revoke Device", ok, err, d.name .. " is revoked.")
        end
    elseif choice == "remove" then
        if ui.confirm(self.surf, "Remove Device", "Remove " .. d.name .. " from this realm? Its key stops working and the name is free again.", { yes = "Remove", danger = true }) then
            local ok, err = self:call(srv, "removeDevice", d.name)
            self:audit("device_remove", d.name, err, ok)
            self:result("Remove Device", ok, err, d.name .. " is removed.")
        end
    end
    return nil
end

function Console:provisionModule()
    local ok, prov = pcall(need, "provision")
    if ok then return prov end
    return nil
end

function Console:driveRows(prov, exclude)
    local rows = {}
    local c = self.surf.c
    for _, d in ipairs(prov.drives(exclude)) do
        local state, color
        if not d.present then
            state, color = "no disk", c.muted
        elseif not d.hasData then
            state, color = "not a disk", c.muted
        elseif (d.foreign or 0) > 0 then
            state, color = d.foreign .. " files", c.warn
        elseif d.zelnet then
            state, color = "old ZelNet disk", c.accent
        else
            state, color = "empty", c.ok
        end
        local right = state
        if d.free then right = right .. ", " .. util.fmtBytes(d.free) end
        rows[#rows + 1] = { text = d.name .. (d.label and (" " .. d.label) or ""), right = right, color = color, drive = d }
    end
    return rows
end

function Console:pickDrive(title, exclude)
    local prov = self:provisionModule()
    if not prov then return nil end
    local chosen
    self:listView({
        title = title or "Choose a Drive",
        subtitle = "Put a pocket computer or disk in a drive, then pick it",
        rows = function() return self:driveRows(prov, exclude) end,
        empty = "No free disk drive. Attach a disk drive to this computer (directly or with a wired modem). Drives used for storage or bridges are not listed.",
        onSelect = function(row)
            local d = row.drive
            if not d.present or not d.hasData then
                self:say("Drive", "Put a pocket computer or disk into " .. d.name .. " first.", self.surf.c.warn)
                return nil
            end
            if (d.foreign or 0) > 0 then
                if not ui.confirm(self.surf, "Erase Disk", "The disk in " .. d.name .. " holds " .. d.foreign .. " other file(s). Erase them?", { yes = "Erase", danger = true }) then return nil end
                chosen = { name = d.name, wipe = true }
            else
                chosen = { name = d.name, wipe = false }
            end
            return "back"
        end,
        actions = { { label = "Refresh", key = "r", run = function() return nil end } },
    })
    return chosen
end

function Console:newDevice()
    local srv = self.ctx.server
    if not srv then return nil end
    if self.provBusy then
        self:say("New Device", "The setup monitor is writing a disk right now. Try again when it is done.", self.surf.c.warn)
        return nil
    end
    local roles = {
        { label = "Client", hint = "TekMail", value = "client" },
        { label = "Router", hint = "relay", value = "router" },
        { label = "Endpoint", hint = "programs", value = "endpoint" },
    }
    if self.cfg.role == "main" then roles[#roles + 1] = { label = "Satellite server", hint = "new realm", value = "satellite" } end
    local role = self:choose("New Device", "What should the new computer be?", roles)
    if not role then return nil end
    local isSat = role == "satellite"
    local r = ui.form(self.surf, {
        title = "New " .. M.ROLE_TITLES[role],
        intro = isSat and "Realm name of the new satellite, for example MARS (letters, digits, _; up to 12)." or "Device name, for example mars_lab (lower case letters, digits, _ or -; up to 16).",
        fields = { {
            label = isSat and "Realm:" or "Name:", key = "name", required = true, maxLen = isSat and 12 or 16,
            validate = function(v)
                if isSat then
                    if not util.normRealm(v) then return false, "Use A-Z, 0-9 and _, starting with a letter." end
                elseif not util.normName(v) then
                    return false, "Use a-z, 0-9, _ or -, starting with a letter."
                end
                return true
            end,
        } },
    })
    if not r then return nil end
    local name = isSat and util.normRealm(r.name) or util.normName(r.name)
    local prov = self:provisionModule()
    if not prov then
        self:say("New Device", "The provisioning module is missing from this program copy.", self.surf.c.bad)
        return nil
    end
    local drive = self:pickDrive("Disk for " .. name, prov.excludeFor(self.cfg, true))
    if not drive then return nil end
    local intro = "Write a " .. M.ROLE_TITLES[role] .. " disk for " .. name .. " in " .. drive.name .. "?"
    if isSat then intro = intro .. " On floppy disks the satellite program needs 2 disks; a pocket computer holds it all." end
    if not ui.confirm(self.surf, "New Device", intro, { yes = "Write" }) then return nil end
    return self:writeDevice(role, name, drive, prov)
end

function Console:writeDevice(role, name, drive, prov)
    self.provBusy = "terminal"
    local r = packn(pcall(self.writeDeviceNow, self, role, name, drive, prov))
    self.provBusy = nil
    if not r[1] then error(r[2], 0) end
    return compat.unpack(r, 2, r.n)
end

function Console:writeDeviceNow(role, name, drive, prov)
    local srv = self.ctx.server
    local dcfg, err = self:busy("New Device", "Creating keys...", function() return srv:provision(role, name) end)
    if type(dcfg) ~= "table" then
        self:audit("provision", name, tostring(err), false)
        return self:result("New Device", false, err)
    end
    local ok, info = self:busy("New Device", "Writing the disk. Packing the program can take a minute...", function()
        return prov.writeDisk(drive.name, dcfg, { wipe = drive.wipe })
    end)
    if not ok then
        if role ~= "satellite" then pcall(srv.removeDevice, srv, name) end
        self:audit("provision", name, tostring(info), false)
        return self:result("New Device", false, "Could not write the disk: " .. tostring(info))
    end
    local parts = type(info) == "table" and info.parts or 1
    for i = 2, parts do
        local done = false
        while not done do
            local go = ui.confirm(self.surf, "Disk " .. i .. " of " .. parts,
                "Take disk " .. (i - 1) .. " out of " .. drive.name .. " and put an empty disk in for disk " .. i .. " of " .. parts .. ".",
                { yes = "Write", no = "Stop" })
            if not go then
                self:say("New Device", "The disk set is incomplete. Remove the device and provision it again.", self.surf.c.bad)
                self:audit("provision", name, "incomplete set", false)
                return nil
            end
            local pok, perr = self:busy("Disk " .. i .. " of " .. parts, "Writing...", function()
                return prov.writePart(drive.name, info.plan, i, { wipe = true })
            end)
            if pok then done = true else self:say("Disk " .. i, tostring(perr), self.surf.c.bad) end
        end
    end
    self:audit("provision", name, role .. " on " .. drive.name, true)
    local lines = {
        { text = M.ROLE_TITLES[role] .. " " .. name .. " is ready.", color = self.surf.c.ok },
        "Disks written: " .. parts,
        "1. Put disk 1 into a disk drive next to the new computer.",
        "2. Reboot the new computer (hold Ctrl+R) to run the installer.",
    }
    if parts > 1 then lines[#lines + 1] = "3. The installer asks for the other disks in order." end
    if role == "satellite" then
        lines[#lines + 1] = "The satellite computer needs a Cipher Block with the same items as this server."
    elseif role == "endpoint" then
        lines[#lines + 1] = "Programs on the endpoint load ZelNet with dofile(\"/zelnet\")."
    end
    lines[#lines + 1] = "The installer erases the keys from disk 1 when it is done."
    self:say("New Device", lines)
    return nil
end

function Console:accountRows()
    local tm = self.ctx.tekmail
    local list = self:call(tm, "listUsers") or {}
    local rows = {}
    for _, u in ipairs(list) do
        local right = tostring(u.realm or "?")
        if u.admin then right = "admin " .. right end
        rows[#rows + 1] = {
            text = tostring(u.name) .. ((u.display and u.display:lower() ~= u.name) and (" (" .. u.display .. ")") or ""),
            right = right, color = u["local"] and self.surf.c.text or self.surf.c.muted, user = u,
        }
    end
    return rows
end

function Console:accounts()
    local tm = self.ctx.tekmail
    if not tm then
        self:say("Accounts", "TekMail is not running on this server.", self.surf.c.bad)
        return nil
    end
    return self:listView({
        title = "Accounts",
        subtitle = function()
            local s = self:call(tm, "stats") or {}
            return tostring(s.users or 0) .. " users, " .. tostring(s.sessions or 0) .. " sessions"
        end,
        rows = function() return self:accountRows() end,
        interval = 5,
        empty = "No accounts yet. Press n to create one.",
        onSelect = function(row) return self:accountMenu(row.user) end,
        actions = {
            { label = "New", key = "n", run = function() return self:createAccount() end },
            { label = "Sessions", key = "s", run = function() return self:sessionsView() end },
        },
    })
end

function Console:createAccount()
    local tm = self.ctx.tekmail
    local errMsg
    local values = {}
    while true do
        local r = ui.form(self.surf, {
            title = "New Account", error = errMsg, submit = "Create",
            intro = "Usernames are unique across the whole network.",
            fields = {
                { label = "Username:", key = "user", required = true, maxLen = 16, value = values.user },
                { label = "Password:", key = "pw", mask = true, required = true, trim = false },
                { label = "Repeat:", key = "again", mask = true, required = true, trim = false },
                { label = "Admin (y/n):", key = "admin", value = values.admin or "n", maxLen = 3 },
            },
        })
        if not r then return nil end
        values = r
        local p = M.passwordProblem(r.pw, r.again)
        if p then
            errMsg = p
        else
            local admin = tostring(r.admin):lower():sub(1, 1) == "y"
            local ok, err = self:busy("New Account", "Claiming the name with Main...", function()
                return tm:createUser(r.user, r.pw, { admin = admin, actor = "console" })
            end)
            if ok then
                self:say("New Account", "Account " .. tostring(r.user):lower() .. " created" .. (admin and " as admin." or "."), self.surf.c.ok)
                return nil
            end
            errMsg = errText(err)
        end
    end
end

function Console:accountMenu(u)
    local tm = self.ctx.tekmail
    local name = u.name
    local choice = self:choose("Account " .. name, "Home realm " .. tostring(u.realm), {
        { label = "Reset password", value = "pw" },
        { label = "Rename", value = "rename" },
        { label = u.admin and "Remove admin rights" or "Make admin", value = "admin" },
        { label = "Delete", value = "delete", color = self.surf.c.bad },
    })
    if choice == "pw" then
        local r = ui.form(self.surf, {
            title = "Reset Password", intro = "New password for " .. name .. ".",
            fields = {
                { label = "Password:", key = "pw", mask = true, required = true, trim = false },
                { label = "Repeat:", key = "again", mask = true, required = true, trim = false },
            },
        })
        if not r then return nil end
        local p = M.passwordProblem(r.pw, r.again)
        if p then return self:result("Reset Password", false, p) end
        local ok, err = self:busy("Reset Password", "Working...", function() return tm:resetPassword(name, r.pw, "console") end)
        self:result("Reset Password", ok, err, "Password changed for " .. name .. ".")
    elseif choice == "rename" then
        local new = ui.ask(self.surf, "Rename Account", "New name:", { intro = "New username for " .. name .. ". Mail and chat history move along." })
        if not new or new == "" then return nil end
        local ok, err = self:busy("Rename Account", "Working...", function() return tm:renameUser(name, new, "console") end)
        self:result("Rename Account", ok, err, name .. " is now " .. new:lower() .. ".")
    elseif choice == "admin" then
        local ok, err = self:busy("Admin Rights", "Working...", function() return tm:setAdmin(name, not u.admin, "console") end)
        self:result("Admin Rights", ok, err, u.admin and (name .. " is no longer an admin.") or (name .. " is now an admin."))
    elseif choice == "delete" then
        local typed = ui.ask(self.surf, "Delete Account", "Type the name:", { intro = "Delete " .. name .. " with all mail? Type the username to confirm." })
        if typed and typed:lower() == name then
            local ok, err = self:busy("Delete Account", "Working...", function() return tm:deleteUser(name, "console") end)
            self:result("Delete Account", ok, err, name .. " is deleted.")
        end
    end
    return nil
end

function Console:sessionsView()
    local tm = self.ctx.tekmail
    return self:listView({
        title = "Sessions",
        rows = function()
            local rows = {}
            for _, s in ipairs(self:call(tm, "sessions") or {}) do
                rows[#rows + 1] = {
                    text = tostring(s.user) .. " " .. tostring(s.client),
                    right = (s.kind == "proxy" and ("via " .. tostring(s.home) .. " ") or "") .. "idle " .. util.fmtDuration(s.idle or 0),
                }
            end
            return rows
        end,
        empty = "Nobody is logged in.",
    })
end

function Console:chatRooms()
    local tm = self.ctx.tekmail
    local rooms = self:call(tm, "roomList")
    if type(rooms) ~= "table" or #rooms == 0 then rooms = { "global", tostring(self.cfg.realm) } end
    return rooms
end

function Console:postChat(room, text)
    local tm = self.ctx.tekmail
    text = util.trim(util.sanitize(text)):sub(1, 200)
    if text == "" then return nil end
    local id = util.newId()
    local m = tm:postChat(room, "console", self.cfg.realm, text, id)
    if m and room == "global" then
        if tm.chatSeen then pcall(tm.chatSeen.check, id) end
        pcall(tm.broadcast, tm, { op = "chat", room = "global", msg = { id = id, user = "console", realm = self.cfg.realm, text = text } })
    end
    self:audit("chat_post", room, nil, m ~= nil)
    return m
end

function Console:chat()
    local tm = self.ctx.tekmail
    if not tm then
        self:say("Chat", "TekMail is not running on this server.", self.surf.c.bad)
        return nil
    end
    local choices = {}
    for _, r in ipairs(self:chatRooms()) do choices[#choices + 1] = { label = r == "global" and "Global (all realms)" or r, value = r } end
    local room = self:choose("Chat", "Pick a room", choices)
    if not room then return nil end
    local okMod, uichat = pcall(need, "uichat")
    if not okMod then return nil end
    local view = uichat.new(self.surf, { title = "Chat " .. room, left = tostring(self.cfg.realm), showTime = true, prompt = "console> ", maxLen = 200 })
    local lastSeq, lastPoll = -1, -100
    local function load(force)
        local now = compat.now()
        if not force and now - lastPoll < 2 then return end
        lastPoll = now
        local list = self:call(tm, "chatHistory", room, 100) or {}
        local top = list[#list]
        local seq = top and top.seq or 0
        if seq == lastSeq then return end
        lastSeq = seq
        local msgs = {}
        for _, m in ipairs(list) do
            msgs[#msgs + 1] = {
                key = m.seq, who = tostring(m.user) .. (m.realm and m.realm ~= self.cfg.realm and ("@" .. m.realm) or ""),
                text = m.text, t = m.t, whoColor = m.user == "console" and self.surf.c.warn or nil,
            }
        end
        view:setMessages(msgs)
    end
    local timer = os.startTimer(2)
    view:run({
        update = function() load(false) end,
        onSend = function(text)
            local ok = self:try(self.postChat, self, room, text)
            load(true)
            return ok ~= nil
        end,
        onEvent = function(ev, a)
            if ev == "timer" and a == timer then timer = os.startTimer(2) end
        end,
    })
    return nil
end

function Console:network()
    local srv = self.ctx.server
    while true do
        local choice = self:choose("Network", tostring(self.cfg.network) .. ", realm " .. tostring(self.cfg.realm), {
            { label = "Realms", value = "realms" },
            { label = "Routes", value = "routes" },
            { label = "Neighbors", value = "neighbors" },
            { label = "Links", value = "links" },
            { label = "Bridges", value = "bridges" },
            { label = "Ping a realm", value = "ping" },
        })
        if not choice then return nil end
        if choice == "ping" then
            self:pingFlow()
        elseif choice == "bridges" then
            self:bridgesPage()
        else
            self:listView({
                title = M.VIEW_TITLES[choice] or (choice:sub(1, 1):upper() .. choice:sub(2)),
                rows = function() return self:networkRows(choice, srv) end,
                interval = 2,
                empty = "Nothing to show.",
            })
        end
    end
end

function Console:networkRows(kind, srv, status, realms)
    local c = self.surf.c
    local st = status or self:snapshot().status or {}
    local rows = {}
    if kind == "realms" then
        for _, r in ipairs(realms or self:call(srv, "realms") or {}) do
            local here = r.realm == self.cfg.realm
            rows[#rows + 1] = {
                text = r.realm .. (r.main and " Main" or "") .. (r.prog and (" v" .. tostring(r.prog)) or ""),
                right = here and "this server" or (r.reachable and ("metric " .. tostring(r.metric)) or "unreachable"),
                color = (here or r.reachable) and c.ok or c.bad,
            }
        end
    elseif kind == "routes" then
        for _, r in ipairs(st.routes or {}) do
            rows[#rows + 1] = { text = tostring(r.realm) .. " via " .. tostring(r.via), right = tostring(r.kind or "") .. " " .. tostring(r.metric) }
        end
    elseif kind == "neighbors" then
        for _, nb in ipairs(st.neighbors or {}) do
            rows[#rows + 1] = {
                text = tostring(nb.realm) .. " " .. tostring(nb.kind) .. (nb.prog and (" v" .. tostring(nb.prog)) or ""),
                right = nb.up and ("up" .. (nb.age and (" " .. util.fmtDuration(nb.age)) or "")) or tostring(nb.problem or "down"),
                color = nb.up and c.ok or c.bad,
            }
        end
    elseif kind == "links" then
        for _, l in ipairs(st.links or {}) do
            rows[#rows + 1] = {
                text = M.linkTitle(l),
                right = l.complete == false and "INCOMPLETE" or ("tx " .. tostring(l.tx or 0) .. " rx " .. tostring(l.rx or 0)),
                color = l.open == false and c.bad or c.text,
            }
        end
    end
    return rows
end

function M.linkTitle(l)
    if l.kind == "bitnet" then
        local what = l.sub == "antenna" and "BitNet antenna " or "BitNet tower "
        return what .. tostring(l.name or l.id)
    end
    return tostring(l.id) .. (l.wireless and " wireless" or "")
end

function Console:pingFlow()
    local target = ui.ask(self.surf, "Ping", "Address:", { intro = "Realm or address to ping, for example MARS or MARS:12." })
    if not target or target == "" then return nil end
    local addr = util.normAddress(target)
    if not addr then return self:result("Ping", false, "That is not a valid address.") end
    local t, err = self:busy("Ping", "Waiting for " .. addr .. "...", function() return self.n:ping(addr, 20) end)
    if t then
        self:say("Ping", "Reply from " .. addr .. " in " .. util.fmtFixed(t, 2) .. " s.", self.surf.c.ok)
    else
        self:say("Ping", "No reply from " .. addr .. ": " .. errText(err), self.surf.c.bad)
    end
end

function Console:bridgeModule()
    local ok, b = pcall(need, "bridge")
    if ok then return b end
    return nil
end

function Console:bridgesPage()
    local srv = self.ctx.server
    local c = self.surf.c
    return self:listView({
        title = "Bridges",
        subtitle = "Tesseract disk bridges to other dimensions",
        rows = function()
            local rows = {}
            for _, b in ipairs((self:snapshot(true).status or {}).bridges or {}) do
                local bad = b.state == "fault" or b.state == "unconfigured"
                rows[#rows + 1] = {
                    text = tostring(b.peer) .. (b.up and " up" or " down"),
                    right = tostring(b.state) .. " q" .. tostring(b.queued or 0) .. " trips " .. tostring(b.trips or 0),
                    color = bad and c.bad or (b.up and c.ok or c.warn), bridge = b,
                }
            end
            return rows
        end,
        empty = "No bridges. Press a to set one up with two tesseracts and two disk drives.",
        onSelect = function(row) return self:bridgeMenu(row.bridge) end,
        actions = { { label = "Add", key = "a", run = function() return self:addBridgeFlow() end } },
    })
end

function Console:bridgeCfg(peer)
    for _, b in ipairs(self.cfg.bridges or {}) do
        if util.normRealm(b.peer) == peer then return b end
    end
    return nil
end

function Console:bridgeMenu(b)
    local srv = self.ctx.server
    local choice = self:choose("Bridge " .. tostring(b.peer), tostring(b.state), {
        { label = "Details", value = "details" },
        { label = "Test the gear", value = "test" },
        { label = "Remove", value = "remove", color = self.surf.c.bad },
    })
    if choice == "details" then
        local lines = {}
        for _, k in ipairs({ "state", "up", "queued", "inflight", "sent", "received", "trips", "errors", "lastError", "fault", "sendDisk", "recvDisk", "sendDir", "recvDir", "restarts" }) do
            if b[k] ~= nil then lines[#lines + 1] = k .. ": " .. tostring(b[k]) end
        end
        if b.lastTrip then lines[#lines + 1] = "lastTrip: " .. util.fmtFixed(b.lastTrip, 1) .. " s" end
        self:say("Bridge " .. tostring(b.peer), lines)
    elseif choice == "test" then
        local mod = self:bridgeModule()
        local bcfg = self:bridgeCfg(b.peer)
        if not mod or not bcfg then return self:result("Test", false, "No settings for this bridge.") end
        local ok, problems = self:inTask("Test Bridge", "Checking the tesseracts and drives...", function()
            return mod.check(bcfg, { realm = self.cfg.realm, disks = true })
        end)
        if ok then
            self:say("Test Bridge", "The gear of the bridge to " .. tostring(b.peer) .. " looks right.", self.surf.c.ok)
        else
            local lines = { { text = "Problems:", color = self.surf.c.bad } }
            for _, p in ipairs(type(problems) == "table" and problems or { tostring(problems) }) do lines[#lines + 1] = "- " .. tostring(p) end
            self:say("Test Bridge", lines)
        end
    elseif choice == "remove" then
        if ui.confirm(self.surf, "Remove Bridge", "Remove the bridge to " .. tostring(b.peer) .. "? Packets queued for it are dropped.", { yes = "Remove", danger = true }) then
            local ok, err = self:call(srv, "removeBridge", b.peer)
            self:audit("bridge_remove", tostring(b.peer), err, ok)
            self:result("Remove Bridge", ok, err, "Bridge removed.")
        end
    end
    return nil
end

function Console:addBridgeFlow()
    local mod = self:bridgeModule()
    if not mod then return self:result("Add Bridge", false, "The bridge module is missing.") end
    local bcfg = M.bridgeWizard(self.surf, self.cfg, function(title, text, fn) return self:inTask(title, text, fn) end, mod)
    if not bcfg then return nil end
    local ok, err = self:call(self.ctx.server, "addBridge", bcfg)
    self:audit("bridge_add", tostring(bcfg.peer), err, ok)
    self:result("Add Bridge", ok, err, "The bridge to " .. tostring(bcfg.peer) .. " is running. The other side needs its own bridge back to " .. tostring(self.cfg.realm) .. ".")
    return nil
end

local function pickName(surf, title, subtitle, names, used, hintFn)
    local choices = {}
    for _, nme in ipairs(names) do
        if not used[nme] then choices[#choices + 1] = { label = nme, hint = hintFn and hintFn(nme) or nil, value = nme } end
    end
    if #choices == 0 then return nil end
    local items = {}
    for i, ch in ipairs(choices) do items[i] = { label = ch.label, hint = ch.hint } end
    local idx = ui.menu(surf, { title = title, subtitle = subtitle, items = items })
    if not idx then return nil end
    return choices[idx].value
end

local function pickDirection(surf, title, run, mod, tess, drive, label)
    local items = { { label = "Find it automatically", hint = "probe" } }
    for _, d in ipairs(M.DIRECTIONS) do items[#items + 1] = { label = d } end
    while true do
        local idx = ui.menu(surf, {
            title = title, subtitle = "Side of " .. tess .. " that faces the other dimension", items = items,
            draw = function(page, ix, iy, iw)
                return page:wrapped(ix, iy, iw, 3, "The probe moves the floppy in " .. drive .. " through " .. tess .. ". It reaches the " .. label .. " on the other side and comes back once that bridge runs.", page.c.muted) + 1
            end,
        })
        if not idx then return nil end
        if idx > 1 then return M.DIRECTIONS[idx - 1] end
        local dir, err = run("Probe", "Testing the six sides of " .. tess .. "...", function() return mod.probe(tess, drive) end)
        if dir then
            ui.message(surf, "Probe", { { text = "Found: " .. tostring(dir), color = surf.c.ok } })
            return dir
        end
        ui.message(surf, "Probe", { { text = tostring(err), color = surf.c.bad } })
    end
end

function M.bridgeWizard(surf, cfg, run, mod)
    mod = mod or need("bridge")
    run = run or function(_, _, fn) return fn() end
    local r = ui.form(surf, {
        title = "New Bridge",
        intro = "A bridge needs two tesseracts and two disk drives on each side, one pair for each direction, and a floppy in each send drive.",
        fields = { {
            label = "Peer realm:", key = "peer", required = true, maxLen = 12,
            validate = function(v)
                local p = util.normRealm(v)
                if not p then return false, "Use A-Z, 0-9 and _." end
                if p == util.normRealm(cfg.realm) then return false, "That is this server's realm." end
                return true
            end,
        } },
    })
    if not r then return nil end
    local peer = util.normRealm(r.peer)
    local prov = select(2, pcall(need, "provision"))
    local used = {}
    if type(prov) == "table" and prov.excludeFor then used = prov.excludeFor(cfg) end
    for _, b in ipairs(cfg.bridges or {}) do
        if type(b) == "table" then
            if b.sendTess then used[b.sendTess] = true end
            if b.recvTess then used[b.recvTess] = true end
        end
    end
    local gear
    while true do
        gear = mod.findGear(used)
        if #gear.tesseracts >= 2 and #gear.drives >= 2 then break end
        local again = ui.confirm(surf, "New Bridge", "Found " .. #gear.tesseracts .. " tesseract(s) and " .. #gear.drives .. " free disk drive(s); a bridge needs 2 of each. Connect them with wired modems or place them next to this computer. Tesseracts only show up with OpenPeripheral installed.", { yes = "Retry", no = "Cancel" })
        if not again then return nil end
    end
    local bcfg = { peer = peer }
    bcfg.sendTess = pickName(surf, "Send Tesseract", "Carries disks to " .. peer, gear.tesseracts, used)
    if not bcfg.sendTess then return nil end
    used[bcfg.sendTess] = true
    bcfg.sendDrive = pickName(surf, "Send Drive", "Drive touching " .. bcfg.sendTess, gear.drives, used)
    if not bcfg.sendDrive then return nil end
    used[bcfg.sendDrive] = true
    bcfg.recvTess = pickName(surf, "Receive Tesseract", "Brings disks from " .. peer, gear.tesseracts, used)
    if not bcfg.recvTess then return nil end
    used[bcfg.recvTess] = true
    bcfg.recvDrive = pickName(surf, "Receive Drive", "Drive touching " .. bcfg.recvTess, gear.drives, used)
    if not bcfg.recvDrive then return nil end
    bcfg.sendDir = pickDirection(surf, "Send Direction", run, mod, bcfg.sendTess, bcfg.sendDrive, "receive drive")
    if not bcfg.sendDir then return nil end
    bcfg.recvDir = pickDirection(surf, "Receive Direction", run, mod, bcfg.recvTess, bcfg.recvDrive, "send drive")
    if not bcfg.recvDir then return nil end
    local ok, problems = run("New Bridge", "Checking the gear...", function() return mod.check(bcfg, { realm = cfg.realm }) end)
    if not ok then
        local text = "Problems found: "
        for i, p in ipairs(type(problems) == "table" and problems or { tostring(problems) }) do
            text = text .. (i > 1 and "; " or "") .. tostring(p)
        end
        if not ui.confirm(surf, "New Bridge", text .. ". Save the bridge anyway?", { yes = "Save", no = "Cancel" }) then return nil end
    end
    return bcfg
end

function Console:airlockRows()
    local al = self.ctx.airlock
    local rows = {}
    for _, g in ipairs(self:call(al, "groups") or {}) do
        if g.grouped then
            rows[#rows + 1] = { header = true, group = g }
            for _, rec in ipairs(g.members) do rows[#rows + 1] = { rec = rec, indent = true } end
        else
            rows[#rows + 1] = { rec = g.members[1], indent = false }
        end
    end
    return rows
end

function M.airlockLine(row, w)
    if row.header then
        local g = row.group
        local sum
        if g.chamberLow then
            sum = "CHAMBER VENT"
        elseif g.hasSensor then
            sum = "chamber ok"
        else
            sum = tostring(g.sealed) .. "/" .. tostring(g.total) .. " sealed"
        end
        local name = util.fitText(tostring(g.group), math.max(4, w - #sum - 1))
        return name .. string.rep(" ", math.max(1, w - #name - #sum)) .. sum
    end
    local rec = row.rec
    local dot = rec.online and "*" or "x"
    local o2 = rec.oxygenated == false and "LOW" or "OK "
    local label = row.indent and tostring(rec.suffix or rec.name) or tostring(rec.name)
    local pre = row.indent and "  " or ""
    local state
    if rec.role == "sensor" then
        state = "[sensor]"
    else
        state = rec.locked and "LOCK" or (rec.sealed and "SEAL" or "OPEN")
    end
    return pre .. dot .. " " .. util.padRight(util.fitText(label, 8), 8) .. " O2:" .. o2 .. " " .. state
end

function Console:airlockBg(row, selected)
    local c = self.surf.c
    if row.header then return row.group.chamberLow and c.bad or c.brand end
    local rec = row.rec
    if selected then return c.accent end
    if rec.oxygenated == false then return c.bad end
    if rec.locked then return c.orange end
    if rec.role == "sensor" then return c.div end
    return c.good
end

function Console:airlocks()
    local al = self.ctx.airlock
    if not al or al.enabled == false then
        self:say("Airlocks", "Airlock control is turned off. Turn it on under Settings, then reboot.", self.surf.c.warn)
        return nil
    end
    local surf = self.surf
    local sel, scroll = 1, 0
    local timer = os.startTimer(1)
    while true do
        local rows = self:airlockRows()
        local recRows = {}
        for i, row in ipairs(rows) do if row.rec then recRows[#recRows + 1] = i end end
        sel = util.clamp(sel, 1, math.max(1, #recRows))
        local page = ui.page(surf)
        local c = page.c
        local s = self:call(al, "stats") or {}
        local ix, iy, iw, ih = page:container("Sealing Manager", "Nodes " .. tostring(s.nodes or 0) .. "  Sealed " .. tostring(s.sealed or 0) .. "  Low " .. tostring(s.low or 0) .. "  Off " .. tostring(s.offline or 0))
        local viewH = math.max(1, ih - 2)
        local selRow = recRows[sel] or 1
        if selRow < scroll + 1 then scroll = selRow - 1 end
        if selRow > scroll + viewH then scroll = selRow - viewH end
        scroll = util.clamp(scroll, 0, math.max(0, #rows - viewH))
        if #rows == 0 then page:wrapped(ix, iy, iw, viewH, "No airlocks registered yet. Press d to search for airlock controllers.", c.muted) end
        for r = 1, viewH do
            local ridx = scroll + r
            local row = rows[ridx]
            if row then
                local isSel = row.rec ~= nil and recRows[sel] == ridx
                local bg = self:airlockBg(row, isSel)
                local text = M.airlockLine(row, iw)
                if isSel and not surf.isColor then text = ">" .. text end
                surf:field(ix, iy + r - 1, iw, text, c.text, surf.isColor and bg or c.inset)
                if row.rec then page:hotspot(ix, iy + r - 1, iw, 1, "rec:" .. ridx) end
            end
        end
        self:footer(page, ix, iy + ih - 1, iw, {
            { label = "Poll", key = "r" }, { label = "Find", key = "d" },
        })
        surf:flush()
        local ev, a, b, cc = compat.pullUI()
        local action
        local px, py, kind, btn = surf:pointer(ev, a, b, cc)
        if px then
            if kind == "scroll" then sel = util.clamp(sel + btn, 1, math.max(1, #recRows)) else action = page:hit(px, py) end
        elseif ev == "key" then
            if ui.isCtrl(a) or a == keys.backspace then
                action = "back"
            elseif a == keys.up then
                sel = math.max(1, sel - 1)
            elseif a == keys.down then
                sel = math.min(math.max(1, #recRows), sel + 1)
            elseif a == keys.enter and recRows[sel] then
                action = "rec:" .. recRows[sel]
            end
        elseif ev == "char" then
            if a == "r" or a == "R" then action = "act:1" elseif a == "d" or a == "D" then action = "act:2" end
        elseif ev == "timer" and a == timer then
            timer = os.startTimer(1)
        elseif ev == "term_resize" then
            surf:resize()
        end
        if action == "back" then return nil end
        if action == "act:1" then
            self:call(al, "poll")
        elseif action == "act:2" then
            self:call(al, "discover")
        elseif action then
            local ridx = tonumber(tostring(action):match("^rec:(%d+)$"))
            if ridx and rows[ridx] and rows[ridx].rec then
                for i, rr in ipairs(recRows) do if rr == ridx then sel = i end end
                self:airlockMenu(rows[ridx].rec.id)
                timer = os.startTimer(1)
            end
        end
    end
end

function Console:findAirlock(id)
    for _, r in ipairs(self:call(self.ctx.airlock, "list") or {}) do
        if tostring(r.id) == tostring(id) then return r end
    end
    return nil
end

function Console:airlockMenu(id)
    local al = self.ctx.airlock
    local c = self.surf.c
    while true do
        local rec = self:findAirlock(id)
        if not rec then return nil end
        local isSensor = rec.role == "sensor"
        local items, acts = {}, {}
        local function add(label, act, color)
            items[#items + 1] = { label = label, color = color }
            acts[#acts + 1] = act
        end
        if not isSensor then
            add("Seal", "seal")
            add("Unseal", "unseal")
            add("Automatic", "auto")
            add(rec.locked and "Unlock bulkhead" or "Lock bulkhead", "lock", c.orange)
        end
        add("Rename", "rename")
        add("Poll now", "poll")
        add("Remove from manager", "remove", c.bad)
        local idx = ui.menu(self.surf, {
            title = (isSensor and "Sensor: " or "Airlock: ") .. util.fitText(tostring(rec.name), 17),
            items = items,
            draw = function(page, ix, iy, iw) return self:drawAirlockInfo(page, ix, iy, iw, rec) end,
            refresh = function() return nil end, interval = 2,
        })
        if not idx then return nil end
        local act = acts[idx]
        local ok, err
        if act == "seal" or act == "unseal" or act == "auto" then
            ok, err = self:call(al, "setManual", rec.id, act, "console")
        elseif act == "lock" then
            ok, err = self:call(al, "setLocked", rec.id, not rec.locked, "console")
        elseif act == "rename" then
            local nm = ui.ask(self.surf, "Rename", "New name:", { value = rec.name, intro = "Names like DOCK-A group doors; the suffix C marks the chamber sensor." })
            if nm and util.trim(nm) ~= "" then ok, err = self:call(al, "rename", rec.id, nm, "console") else ok = true end
        elseif act == "poll" then
            ok, err = self:call(al, "pollOne", rec.id)
        elseif act == "remove" then
            if ui.confirm(self.surf, "Remove", "Remove " .. tostring(rec.name) .. " from the manager? It comes back when it reports again.", { yes = "Remove", danger = true }) then
                ok, err = self:call(al, "remove", rec.id, "console")
                if ok then return nil end
            else
                ok = true
            end
        end
        if not ok then self:result("Airlock", false, err) end
    end
end

function Console:drawAirlockInfo(page, ix, iy, iw, rec)
    local s, c = page.s, page.c
    s:field(ix, iy, iw, "ID " .. tostring(rec.id) .. "  " .. (rec.online and "online" or "OFFLINE"), c.muted, c.inset)
    if rec.role == "sensor" then
        s:field(ix, iy + 1, iw, rec.oxygenated == false and "CHAMBER VENTED" or "Chamber oxygen OK", rec.oxygenated == false and c.bad or c.ok, c.inset)
        return 3
    end
    local mode = rec.locked and "SERVER LOCK" or (rec.manual and ("Override: " .. tostring(rec.manual)) or "Mode: auto")
    s:field(ix, iy, iw, "ID " .. tostring(rec.id) .. "  " .. (rec.online and "" or "OFFLINE  ") .. mode, rec.locked and c.orange or c.muted, c.inset)
    s:field(ix, iy + 1, iw, rec.oxygenated == false and "AREA DEPRESSURIZED" or "Area oxygen OK", rec.oxygenated == false and c.bad or c.ok, c.inset)
    local door = rec.locked and "Bulkhead LOCKED by control" or (rec.sealed and "Bulkhead SEALED" or "Bulkhead OPEN")
    s:field(ix, iy + 2, iw, door, rec.sealed and c.bad or c.ok, c.inset)
    return 4
end

function Console:storageRows()
    local c = self.surf.c
    local rows = {}
    for _, r in ipairs(self:call(self.ctx.storage, "info") or {}) do
        local right = tostring(r.state or (r.present and "online" or "offline"))
        if r.files then right = right .. " " .. tostring(r.files) .. "f" end
        if r.free then right = right .. " " .. util.fmtBytes(r.free) end
        rows[#rows + 1] = {
            text = tostring(r.title or r.role) .. ": " .. tostring(r.drive or "computer"),
            right = right, color = r.present == false and c.bad or c.text, info = r,
        }
    end
    return rows
end

function Console:storagePage()
    local st = self.ctx.storage
    if not st then return nil end
    return self:listView({
        title = "Storage",
        subtitle = "Where each kind of data lives",
        rows = function() return self:storageRows() end,
        onSelect = function(row) return self:assignStorage(row.info) end,
        actions = { { label = "Problems", key = "p", run = function() return self:storageProblems() end } },
    })
end

function Console:storageProblems()
    local lines = {}
    for _, p in ipairs(self:call(self.ctx.storage, "problemList") or {}) do
        lines[#lines + 1] = (p.s and (util.fmtStamp(p.s) .. " ") or "") .. tostring(p.text)
    end
    if #lines == 0 then lines[1] = "No storage problems." end
    self:say("Storage Problems", lines)
end

function Console:assignStorage(info)
    local prov = self:provisionModule()
    local exclude = {}
    if type(self.cfg.displays) == "table" and self.cfg.displays.drive then exclude[self.cfg.displays.drive] = true end
    for _, b in ipairs(self.cfg.bridges or {}) do
        if b.sendDrive then exclude[b.sendDrive] = true end
        if b.recvDrive then exclude[b.recvDrive] = true end
    end
    local drives = (self.cfg.storage or {}).drives or {}
    for role, d in pairs(drives) do
        if role ~= info.role and type(d) == "string" then exclude[d] = true end
    end
    local choices = { { label = "This computer", hint = "local", value = "local" } }
    if prov then
        for _, d in ipairs(prov.drives(exclude)) do
            if d.present and d.hasData then
                choices[#choices + 1] = { label = d.name, hint = (d.label or "disk") .. (d.free and (" " .. util.fmtBytes(d.free)) or ""), value = d.name }
            end
        end
    end
    local pick = self:choose("Store " .. tostring(info.title or info.role), "Now on " .. tostring(info.drive or "this computer"), choices)
    if not pick then return nil end
    local ok, err = self:busy("Storage", "Moving " .. tostring(info.role) .. " data...", function()
        return self.ctx.storage:assign(info.role, pick)
    end)
    self:result("Storage", ok, err, tostring(info.role) .. " is now stored on " .. (pick == "local" and "this computer" or pick) .. ".")
    return nil
end

function Console:auditPage()
    local c = self.surf.c
    return self:listView({
        title = "Audit Log",
        rows = function()
            local rows = {}
            for _, e in ipairs(self:call(self.ctx.storage, "auditTail", 150) or {}) do
                rows[#rows + 1] = {
                    text = util.fmtStamp(e.s or 0) .. " " .. tostring(e.actor) .. " " .. tostring(e.action) .. (e.target and (" " .. tostring(e.target)) or ""),
                    color = e.ok == false and c.bad or c.text, entry = e,
                }
            end
            return rows
        end,
        interval = 5,
        empty = "The audit log is empty.",
        onSelect = function(row)
            local e = row.entry
            self:say("Audit Entry", {
                "Time: " .. util.fmtStamp(e.s or 0), "Actor: " .. tostring(e.actor), "Action: " .. tostring(e.action),
                "Target: " .. tostring(e.target or "-"), "Detail: " .. tostring(e.detail or "-"), "Result: " .. (e.ok == false and "failed" or "ok"),
            })
        end,
    })
end

function Console:eventLog()
    local c = self.surf.c
    local levelColors = { error = c.bad, warn = c.warn, debug = c.dim }
    return self:listView({
        title = "Event Log",
        rows = function()
            local rows = {}
            local items = self.log.last and self.log.last(200) or {}
            for i = #items, 1, -1 do
                local e = items[i]
                rows[#rows + 1] = { text = util.fmtStamp(e.s or 0):sub(-5) .. " " .. tostring(e.text), color = levelColors[e.level] or c.text, entry = e }
            end
            return rows
        end,
        interval = 2,
        empty = "No events yet.",
        onSelect = function(row)
            local e = row.entry
            self:say("Event", { util.fmtStamp(e.s or 0) .. " " .. tostring(e.level), tostring(e.text) })
        end,
    })
end

function M.proximityHint(cfg)
    local list = M.playerList(cfg.adminPlayer)
    if #list == 0 then return "off" end
    if #list == 1 then return list[1] end
    return list[1] .. " +" .. (#list - 1)
end

function Console:settings()
    while true do
        local cfg = self.cfg
        local choice = self:choose("Settings", "Changes are saved to the config", {
            { label = "Displays", hint = M.displayHint(cfg), value = "displays" },
            { label = "Proximity unlock", hint = M.proximityHint(cfg), value = "sensor" },
            { label = "Lock timeout", hint = self:lockAfter() > 0 and util.fmtDuration(self:lockAfter()) or "never", value = "lock" },
            { label = "Intervals", hint = "beacon " .. tostring(cfg.beaconInterval) .. " hello " .. tostring(cfg.helloInterval), value = "intervals" },
            { label = "Message of the day", value = "motd" },
            { label = "Airlock control", hint = cfg.airlocks == false and "off" or "on", value = "airlocks" },
            { label = "Console password", value = "password" },
        })
        if not choice then return nil end
        if choice == "displays" then
            self:displaySettings()
        elseif choice == "sensor" then
            local r = ui.form(self.surf, {
                title = "Proximity Unlock",
                intro = "An OpenCCSensors proximity sensor unlocks the console when any of these players stands close. Separate names with commas. Leave it empty to turn it off.",
                fields = {
                    { label = "Players:", key = "player", value = M.playerText(cfg.adminPlayer), maxLen = M.PLAYERS_MAX },
                    { label = "Range:", key = "range", value = tostring(cfg.adminRange or M.SENSOR_RANGE), numeric = true },
                },
            })
            if r then
                local text = M.playerText(r.player)
                cfg.adminPlayer = text ~= "" and text or nil
                cfg.adminRange = util.clamp(tonumber(r.range) or M.SENSOR_RANGE, 1, 16)
                if self:save() then self:audit("settings", "sensor", tostring(cfg.adminPlayer), true) end
            end
        elseif choice == "lock" then
            local r = ui.form(self.surf, {
                title = "Lock Timeout", intro = "Lock the console after this many idle seconds. 0 means never.",
                fields = { { label = "Seconds:", key = "s", value = tostring(self:lockAfter()), numeric = true, required = true } },
            })
            if r then
                local v = math.floor(tonumber(r.s) or M.LOCK_AFTER)
                if v ~= 0 then v = util.clamp(v, 30, 86400) end
                cfg.lockAfter = v
                if self:save() then self:audit("settings", "lock", tostring(v), true) end
            end
        elseif choice == "intervals" then
            local r = ui.form(self.surf, {
                title = "Intervals", intro = "Seconds between beacons (devices) and hellos (servers). Applies after a reboot.",
                fields = {
                    { label = "Beacon:", key = "b", value = tostring(cfg.beaconInterval or 10), numeric = true, required = true },
                    { label = "Hello:", key = "h", value = tostring(cfg.helloInterval or 20), numeric = true, required = true },
                },
            })
            if r then
                cfg.beaconInterval = util.clamp(math.floor(r.b), 5, 60)
                cfg.helloInterval = util.clamp(math.floor(r.h), 10, 120)
                if self:save() then self:audit("settings", "intervals", cfg.beaconInterval .. "/" .. cfg.helloInterval, true) end
            end
        elseif choice == "motd" then
            local v = ui.ask(self.surf, "Message of the Day", "Text:", { value = cfg.motd or "", intro = "Clients show this after they connect." })
            if v then
                cfg.motd = v ~= "" and util.sanitize(v):sub(1, 120) or nil
                if self:save() then self:audit("settings", "motd", nil, true) end
            end
        elseif choice == "airlocks" then
            cfg.airlocks = cfg.airlocks == false
            if self:save() then
                self:audit("settings", "airlocks", tostring(cfg.airlocks), true)
                self:say("Airlock Control", "Airlock control is " .. (cfg.airlocks and "on" or "off") .. " after the next reboot.")
            end
        elseif choice == "password" then
            self:changePassword(true)
        end
    end
end

M.DISPLAY_ROLES = {
    { key = "activity", label = "Activity monitor:", hint = "6x3, live traffic" },
    { key = "console", label = "Console monitor:", hint = "6x3, console tabs" },
    { key = "setup", label = "Setup monitor:", hint = "1x2, device setup" },
    { key = "drive", label = "Setup drive:", hint = "the drive's own name, drive_N" },
}

function M.displayHint(cfg)
    local d = type(cfg.displays) == "table" and cfg.displays or {}
    local n = 0
    for _, r in ipairs(M.DISPLAY_ROLES) do if d[r.key] then n = n + 1 end end
    return n .. " of " .. #M.DISPLAY_ROLES
end

function M.displayForm(surf, cfg)
    local okP, panels = pcall(need, "panels")
    if not okP then return nil end
    local names = ui.findMonitors()
    local d = type(cfg.displays) == "table" and cfg.displays or {}
    local roleOf = {}
    for _, r in ipairs(M.DISPLAY_ROLES) do
        if d[r.key] and r.key ~= "drive" then roleOf[d[r.key]] = r.label:gsub(":$", "") end
    end
    panels.identify(names, roleOf)
    local fields = {}
    for _, r in ipairs(M.DISPLAY_ROLES) do
        fields[#fields + 1] = { label = r.label, key = r.key, value = d[r.key] or "", hint = r.hint, maxLen = 24 }
    end
    local errMsg
    local result
    while true do
        local r = ui.form(surf, {
            title = "Displays", error = errMsg, submit = "Save",
            intro = "Monitors show their names now. Type 12 or monitor_12; the drive is drive_N.",
            fields = fields,
        })
        if not r then break end
        for _, f in ipairs(fields) do f.value = r[f.key] or "" end
        local out, err = panels.validateDisplays(r, cfg)
        if out then
            result = out
            break
        end
        errMsg = err
    end
    panels.clearMonitors(names)
    return result
end

function Console:displaySettings()
    local out = M.displayForm(self.surf, self.cfg)
    if not out then return nil end
    self.cfg.displays = out
    if self.panels then self.panels:reset() end
    if self:save() then self:audit("settings", "displays", M.displayHint(self.cfg), true) end
    os.queueEvent("zn_panel")
    return nil
end

function M.programVersion(text)
    local okU, up = pcall(need, "updater")
    if okU and up then return up.versionOf(text) end
    if type(text) ~= "string" then return nil end
    return text:match("program%s*=%s*\"(%d[%w%.%-_]*)\"")
end

function Console:updatePage()
    local isMain = self.cfg.role == "main"
    local okU, up = pcall(need, "updater")
    local items = {}
    if okU and up then items[#items + 1] = { label = "Download from the repo", hint = "GitHub", value = "repo" } end
    if isMain then
        items[#items + 1] = { label = "Send a program file", hint = "from disk", value = "file" }
    else
        items[#items + 1] = { label = "Update status", value = "status" }
    end
    local choice = self:choose(isMain and "Update Network" or "Update", "This server runs ZelNet " .. version.full(), items)
    if choice == "repo" then
        return self:repoUpdate(up)
    elseif choice == "file" then
        return self:fileUpdate()
    elseif choice == "status" then
        return self:updateStatus()
    end
    return nil
end

function Console:updateStatus()
    local st = self:snapshot(true).status or {}
    local lines = {
        "This server runs ZelNet " .. version.full() .. ".",
        "Updates come from Main (" .. tostring(self.cfg.mainRealm) .. ") over the backbone; this server installs them and reboots by itself.",
    }
    if st.update then lines[#lines + 1] = "Last update seen: " .. tostring(st.update.version) .. ", " .. util.fmtBytes(st.update.size or 0) end
    self:say("Update Status", lines)
    return nil
end

function Console:repoUpdate(up)
    local url = up.url(self.cfg)
    local got, err = self:inTask("Download", "Downloading the newest ZelNet from " .. url, function() return up.fetch(self.cfg) end)
    if type(got) ~= "table" then
        self:audit("update_download", url, tostring(err), false)
        return self:result("Download", false, err)
    end
    self:audit("update_download", got.version, nil, true)
    local isMain = self.cfg.role == "main"
    local intro = "The repo has ZelNet " .. got.version .. " (" .. util.fmtBytes(got.size) .. "). This server runs " .. got.current .. "."
    if got.same then intro = intro .. " They are the same build." end
    local items = {}
    if isMain then items[#items + 1] = { label = "Install here and update the network", value = "network" } end
    items[#items + 1] = { label = "Install on this server only", value = "local" }
    local pick = ui.menu(self.surf, {
        title = "Download", items = (function()
            local out = {}
            for k, it in ipairs(items) do out[k] = { label = it.label } end
            return out
        end)(),
        draw = function(page, ix, iy, iw) return page:wrapped(ix, iy, iw, 4, intro, page.c.muted) + 1 end,
    })
    if not pick then return nil end
    local mode = items[pick].value
    local ok, ierr = self:busy("Install", "Writing the new program...", function() return up.install(got.text, self.ctx.server and self.ctx.server:programPath() or "/zelnet") end)
    self:audit("update_install", got.version, ierr, ok)
    if not ok then return self:result("Install", false, ierr) end
    if mode == "network" then
        local pok, perr = self:busy("Update Network", "Signing and offering the update...", function() return self.ctx.server:pushUpdate(got.text, got.version) end)
        self:audit("update_network", got.version, perr, pok)
        if not pok then return self:result("Update Network", false, perr) end
        self:say("Update Network", {
            { text = "ZelNet " .. got.version .. " is installed here and offered to the network.", color = self.surf.c.ok },
            "Satellites and devices download it, install it and reboot by themselves.",
            "This server runs the new version after its next reboot. Wait until the satellites show " .. got.version .. " under Network, Realms, then use Reboot in the main menu.",
        })
        return nil
    end
    if ui.confirm(self.surf, "Install", "ZelNet " .. got.version .. " is installed. Reboot now to run it?", { yes = "Reboot", no = "Later" }) then
        self:flushAll()
        return "reboot"
    end
    return nil
end

function Console:fileUpdate()
    local srv = self.ctx.server
    local r = ui.form(self.surf, {
        title = "Update Network",
        intro = "Give the path of the new program, on this computer or on a disk (for example /disk/zelnet.new). It is checked, signed and sent to every realm and device.",
        fields = { { label = "File:", key = "path", value = "/zelnet.new", required = true } },
    })
    if not r then return nil end
    local text = util.readFile(r.path)
    if not text then return self:result("Update Network", false, "Cannot read " .. r.path .. ".") end
    local fn, cerr = loadstring(text, "=zelnet")
    if not fn then return self:result("Update Network", false, "The file does not compile: " .. tostring(cerr)) end
    local ver = M.programVersion(text)
    if not ver then
        ver = ui.ask(self.surf, "Update Network", "Version:", { intro = "No version found in the file. Type the version number." })
        if not ver or ver == "" then return nil end
    end
    local typed = ui.ask(self.surf, "Update Network", "Type YES:", {
        intro = "Send ZelNet " .. ver .. " (" .. util.fmtBytes(#text) .. ") to every server and device? They install it and reboot.",
    })
    if typed ~= "YES" then return nil end
    local ok, err = self:busy("Update Network", "Signing and offering the update...", function() return srv:pushUpdate(text, ver) end)
    self:audit("update_network", ver, err, ok)
    self:result("Update Network", ok, err, "Update " .. ver .. " is offered. Servers fetch it in chunks, install it and reboot; devices follow.")
    return nil
end

function M.cipherGuide(cfg, msg, opts)
    opts = opts or {}
    local surf = opts.surface or ui.surface(term)
    local deadline = compat.now() + (opts.wait or M.GUIDE_WAIT)
    local lines = M.CIPHER_GUIDE
    while true do
        local result = M.cipherMenu(surf, cfg, msg, deadline, lines)
        if result == 1 or result == "retry" then return "retry" end
        if result ~= 3 then return "local" end
        if type(cfg.console) ~= "table" then return "exit" end
        local pw = ui.ask(surf, "Exit to Shell", "Password:", { mask = true, intro = "Type the console password to stop ZelNet and open the shell." })
        if pw and M.checkPassword(cfg, pw) then return "exit" end
        if pw then ui.message(surf, "Exit to Shell", { { text = "Wrong password.", color = surf.c.bad } }) end
    end
end

function M.cipherMenu(surf, cfg, msg, deadline, lines)
    return ui.menu(surf, {
        title = "Cipher Block Needed",
        subtitle = tostring(msg or "no cipher block found"),
        back = false,
        items = {
            { label = "Retry now" },
            { label = "Start without the backbone" },
            { label = "Exit to shell" },
        },
        draw = function(page, ix, iy, iw)
            local used = 0
            for _, l in ipairs(lines) do used = used + page:wrapped(ix, iy + used, iw, 3, l, page.c.muted) end
            local left = math.max(0, math.ceil(deadline - compat.now()))
            page.s:field(ix, iy + used, iw, "Starting without the backbone in " .. left .. " s", page.c.warn, page.c.inset)
            return used + 2
        end,
        refresh = function()
            if compat.now() >= deadline then return "local" end
            if math.floor(compat.now()) % 5 == 0 then
                local obj = cipherMod.open({ preferred = cfg.cipherName })
                if obj then return "retry" end
            end
            return nil
        end,
        interval = 1,
    })
end

local Wizard = {}
Wizard.__index = Wizard

M.SETUP_STEPS = {
    fresh = { "intro", "role", "network", "password", "admin", "cipher", "displays", "storage", "bridges", "sensor", "finish" },
    satellite = { "intro", "password", "admin", "cipher", "displays", "storage", "bridges", "sensor", "finish" },
    reconfigure = { "intro", "password", "cipher", "displays", "storage", "bridges", "sensor", "finish" },
}

function M.validUser(v)
    if type(v) ~= "string" then return nil end
    local u = util.trim(v):lower()
    if #u < 3 or #u > 16 or not u:match("^[a-z][a-z0-9_]*$") then return nil end
    return u
end

function M.findSatelliteDisk()
    local ok, prov = pcall(need, "provision")
    if not ok then return nil end
    for _, d in ipairs(prov.drives()) do
        if d.mount then
            local path = "/" .. d.mount:gsub("^/+", "") .. "/zelnet.cfg"
            local text = util.readFile(path)
            local cfg = text and codec.decode(text)
            if type(cfg) == "table" and cfg.role == "satellite" and config.validate(cfg) then
                return config.applyDefaults(cfg), path
            end
        end
    end
    return nil
end

function M.setup(opts)
    opts = opts or {}
    local w = setmetatable({}, Wizard)
    w.surf = opts.surface or ui.surface(term)
    w.path = opts.path
    w.programPath = opts.programPath
    w.extra = {}
    w.opts = opts
    local ex = opts.cfg
    if type(ex) == "table" and config.isServer(ex) and type(ex.console) == "table" then
        w.mode = "reconfigure"
        w.cfg = util.deepCopy(ex)
    elseif type(ex) == "table" and config.isServer(ex) then
        w.mode = "satellite"
        w.cfg = util.deepCopy(ex)
        w.fromDisk = true
    else
        w.mode = "fresh"
    end
    return w:run()
end

function Wizard:run()
    local steps = M.SETUP_STEPS[self.mode]
    local i, dir = 1, 1
    while i <= #steps do
        local name = steps[i]
        local r = self[name](self)
        if r == "quit" then return nil end
        if r == "done" then break end
        if r == "back" then
            dir = -1
            if i == 1 then
                if ui.confirm(self.surf, "ZelNet Setup", "Leave the setup? Nothing is saved.", { yes = "Leave", no = "Stay" }) then return nil end
            else
                i = i - 1
            end
        elseif r == "skip" then
            i = math.max(1, i + dir)
        else
            dir = 1
            i = i + 1
        end
    end
    if not self.saved then return nil end
    return config.applyDefaults(self.cfg), self.extra
end

function Wizard:say(title, lines, color)
    if type(lines) == "string" then lines = { lines } end
    local out = {}
    for _, l in ipairs(lines) do out[#out + 1] = type(l) == "table" and l or { text = l, color = color } end
    ui.message(self.surf, title, out)
end

function Wizard:choose(title, subtitle, choices, draw)
    local items = {}
    for i, ch in ipairs(choices) do items[i] = { label = ch.label, hint = ch.hint, color = ch.color } end
    local idx = ui.menu(self.surf, { title = title, subtitle = subtitle, items = items, draw = draw })
    if not idx then return nil end
    return choices[idx].value
end

function Wizard:intro()
    local text
    if self.mode == "reconfigure" then
        text = "Change the local settings of server " .. tostring(self.cfg.realm) .. ". The network keys and the realm name stay the same. To start a new network delete /.zelnet/config first."
    elseif self.mode == "satellite" then
        text = "Set up satellite " .. tostring(self.cfg.realm) .. " of network " .. tostring(self.cfg.network) .. " (Main is " .. tostring(self.cfg.mainRealm) .. "). The network keys came on the disk; only local settings are left."
    else
        text = "Welcome to ZelNet " .. version.program .. ". This wizard turns this computer into a ZelNet server: the Main server of a new network, or a satellite for another dimension."
    end
    if not ui.confirm(self.surf, "ZelNet Setup", text, { yes = "Start", no = "Cancel" }) then return "quit" end
    return "next"
end

function Wizard:role()
    while true do
        local role = self:choose("Server Role", "What is this server?", {
            { label = "Main server", hint = "new network", value = "main" },
            { label = "Satellite server", hint = "disk from Main", value = "satellite" },
        })
        if not role then return "back" end
        if role == "main" then
            if self.cfg and self.cfg.role ~= "main" then self.cfg = nil end
            self.isSatellite = false
            return "next"
        end
        local cfg = M.findSatelliteDisk()
        if cfg then
            self.cfg = util.deepCopy(cfg)
            self.isSatellite = true
            self:say("Satellite", "Found satellite " .. tostring(cfg.realm) .. " of network " .. tostring(cfg.network) .. " on a disk.", self.surf.c.ok)
            return "next"
        end
        self:say("Satellite", {
            "No satellite disk found.",
            "On the Main server open Devices, New device, Satellite server and write the disks.",
            "Then put disk 1 into a drive of this computer and reboot it, or choose Satellite again.",
        }, nil)
    end
end

function Wizard:network()
    if self.isSatellite then return "skip" end
    local errMsg
    while true do
        local r = ui.form(self.surf, {
            title = "New Network", error = errMsg, submit = "Next",
            intro = "The network name is shared by all servers and devices. The realm names this server's dimension, for example EARTH.",
            fields = {
                { label = "Network:", key = "network", value = self.cfg and self.cfg.network or "ZelNet", required = true, maxLen = 24 },
                { label = "Realm:", key = "realm", value = self.cfg and self.cfg.realm or "", required = true, maxLen = 12 },
            },
        })
        if not r then return "back" end
        local realm = util.normRealm(r.realm)
        if not realm then
            errMsg = "Realm: A-Z, 0-9 and _, starting with a letter, up to 12."
        elseif util.sanitize(r.network) ~= r.network then
            errMsg = "Network: plain letters and digits only."
        else
            if not self.cfg or self.cfg.realm ~= realm or self.cfg.network ~= r.network then
                self.cfg = config.newServer({ role = "main", network = r.network, realm = realm })
            end
            return "next"
        end
    end
end

function Wizard:password()
    if self.mode == "reconfigure" then
        local keep = self:choose("Console Password", "The console password is set", {
            { label = "Keep the current password", value = "keep" },
            { label = "Change it", value = "change" },
        })
        if not keep then return "back" end
        if keep == "keep" then return "next" end
    end
    local errMsg
    while true do
        local r = ui.form(self.surf, {
            title = "Console Password", error = errMsg, submit = "Next",
            intro = "This password unlocks the server console and is needed to exit to the shell.",
            fields = {
                { label = "Password:", key = "pw", mask = true, required = true, trim = false },
                { label = "Repeat:", key = "again", mask = true, required = true, trim = false },
            },
        })
        if not r then return "back" end
        errMsg = M.passwordProblem(r.pw, r.again)
        if not errMsg then
            M.setPassword(self.cfg, r.pw)
            return "next"
        end
    end
end

function Wizard:admin()
    local pick = self:choose("Admin Account", "A TekMail account with admin rights", {
        { label = "Create an admin account", value = "create" },
        { label = "Skip", hint = "later under Accounts", value = "skip" },
    })
    if not pick then return "back" end
    if pick == "skip" then
        self.extra.admin = nil
        return "next"
    end
    local errMsg
    while true do
        local r = ui.form(self.surf, {
            title = "Admin Account", error = errMsg, submit = "Next",
            intro = "Created when the server starts. Admins manage accounts from any client.",
            fields = {
                { label = "Username:", key = "user", required = true, maxLen = 16 },
                { label = "Password:", key = "pw", mask = true, required = true, trim = false },
                { label = "Repeat:", key = "again", mask = true, required = true, trim = false },
            },
        })
        if not r then return "back" end
        local user = M.validUser(r.user)
        if not user then
            errMsg = M.ERR_TEXT.bad_name
        else
            errMsg = M.passwordProblem(r.pw, r.again)
            if not errMsg then
                self.extra.admin = { user = user, pass = r.pw, display = util.trim(r.user) }
                return "next"
            end
        end
    end
end

function Wizard:cipher()
    while true do
        local obj, err = cipherMod.open({ preferred = self.cfg.cipherName })
        if obj and obj.kind == "hardware" then
            self.cfg.cipherName = obj.name
            local fp = cipherMod.fingerprint(obj)
            self:say("Cipher Block", {
                { text = "Cipher Block found: " .. tostring(obj.name), color = self.surf.c.ok },
                "Fingerprint: " .. tostring(fp),
                "Every server must show this same fingerprint on its dashboard. If one differs, its Cipher Block holds other items.",
            })
            return "next"
        end
        local pick = self:choose("Cipher Block", tostring(err or "no cipher block found"), {
            { label = "Retry", value = "retry" },
            { label = "Use the software cipher", hint = "testing only", value = "software" },
            { label = "Continue without backbone", value = "none" },
        }, function(page, ix, iy, iw)
            local used = 0
            for _, l in ipairs(M.CIPHER_GUIDE) do used = used + page:wrapped(ix, iy + used, iw, 2, l, page.c.muted) end
            return used + 1
        end)
        if not pick then return "back" end
        if pick == "software" then
            self.cfg.allowSoftwareBackbone = true
            self:say("Cipher Block", "The software cipher is on. Every server of the network must use it too. Turn it off once real Cipher Blocks are in place.", self.surf.c.warn)
            return "next"
        elseif pick == "none" then
            self.cfg.allowSoftwareBackbone = false
            return "next"
        end
    end
end

function Wizard:storage()
    self.cfg.storage = self.cfg.storage or {}
    self.cfg.storage.drives = self.cfg.storage.drives or {}
    local pick = self:choose("Storage", "Where should accounts, mail and logs live?", {
        { label = "On this computer", hint = "simple", value = "local" },
        { label = "On disk drives", hint = "one per kind", value = "drives" },
    })
    if not pick then return "back" end
    if pick == "local" then
        self.cfg.storage.drives = {}
        return "next"
    end
    local ok, prov = pcall(need, "provision")
    if not ok then return "next" end
    local exclude = {}
    if type(self.cfg.displays) == "table" and self.cfg.displays.drive then exclude[self.cfg.displays.drive] = true end
    for _, b in ipairs(self.cfg.bridges or {}) do
        if b.sendDrive then exclude[b.sendDrive] = true end
        if b.recvDrive then exclude[b.recvDrive] = true end
    end
    local drives = {}
    for _, role in ipairs(M.STORAGE_ROLES) do
        local choices = { { label = "This computer", value = "local" } }
        for _, d in ipairs(prov.drives(exclude)) do
            if d.present and d.hasData then
                choices[#choices + 1] = { label = d.name, hint = (d.label or "disk") .. (d.free and (" " .. util.fmtBytes(d.free)) or ""), value = d.name }
            end
        end
        local title = role:sub(1, 1):upper() .. role:sub(2)
        local choice = self:choose("Storage: " .. title, "Put a pocket computer in each drive to use", choices)
        if not choice then return "back" end
        if choice ~= "local" then
            drives[role] = choice
            exclude[choice] = true
        end
    end
    self.cfg.storage.drives = drives
    return "next"
end

function Wizard:bridges()
    local okMod, mod = pcall(need, "bridge")
    if not okMod then return "next" end
    self.cfg.bridges = self.cfg.bridges or {}
    while true do
        local choices = {}
        for i, b in ipairs(self.cfg.bridges) do
            choices[#choices + 1] = { label = "Bridge to " .. tostring(b.peer), hint = "remove", value = i }
        end
        choices[#choices + 1] = { label = "Add a bridge", value = "add" }
        choices[#choices + 1] = { label = "Continue", value = "next" }
        local pick = self:choose("Bridges", "Tesseract bridges to other dimensions", choices)
        if not pick then return "back" end
        if pick == "next" then return "next" end
        if pick == "add" then
            local bcfg = M.bridgeWizard(self.surf, self.cfg, nil, mod)
            if bcfg then self.cfg.bridges[#self.cfg.bridges + 1] = bcfg end
        elseif type(pick) == "number" then
            local b = self.cfg.bridges[pick]
            if ui.confirm(self.surf, "Bridges", "Remove the bridge to " .. tostring(b.peer) .. "?", { yes = "Remove", danger = true }) then
                table.remove(self.cfg.bridges, pick)
            end
        end
    end
end

function Wizard:displays()
    if #ui.findMonitors() == 0 then return "skip" end
    local out = M.displayForm(self.surf, self.cfg)
    if not out then return "back" end
    self.cfg.displays = out
    return "next"
end

function Wizard:sensor()
    local r = ui.form(self.surf, {
        title = "Console Lock",
        intro = "The console locks after the idle time. An OpenCCSensors proximity sensor can unlock it when a listed player stands close. Separate names with commas; leave it empty to skip.",
        submit = "Next",
        fields = {
            { label = "Idle lock (s):", key = "lock", value = tostring(self.cfg.lockAfter or M.LOCK_AFTER), numeric = true, required = true },
            { label = "Players:", key = "player", value = M.playerText(self.cfg.adminPlayer), maxLen = M.PLAYERS_MAX },
            { label = "Range:", key = "range", value = tostring(self.cfg.adminRange or M.SENSOR_RANGE), numeric = true },
        },
    })
    if not r then return "back" end
    local v = math.floor(tonumber(r.lock) or M.LOCK_AFTER)
    if v ~= 0 then v = util.clamp(v, 30, 86400) end
    self.cfg.lockAfter = v
    local text = M.playerText(r.player)
    self.cfg.adminPlayer = text ~= "" and text or nil
    self.cfg.adminRange = util.clamp(tonumber(r.range) or M.SENSOR_RANGE, 1, 16)
    return "next"
end

function M.writeStartup()
    local old = util.readFile("/startup")
    if old and old:find("shell.run(\"/zelnet\")", 1, true) then return true end
    if old then
        if fs.exists("/startup.old") then fs.delete("/startup.old") end
        fs.move("/startup", "/startup.old")
    end
    return util.writeFile("/startup", "shell.run(\"/zelnet\")\n")
end

function M.installProgram(fromPath)
    if type(fromPath) ~= "string" or fromPath == "/zelnet" or not fs.exists(fromPath) then return true end
    local text = util.readFile(fromPath)
    if not text or not text:find("__mods", 1, true) then return true end
    return util.writeFile("/zelnet", text)
end

function Wizard:summary()
    local cfg = self.cfg
    local drives = {}
    for role, d in pairs((cfg.storage or {}).drives or {}) do drives[#drives + 1] = role .. "=" .. d end
    table.sort(drives)
    local lines = {
        "Role: " .. (M.ROLE_TITLES[cfg.role] or cfg.role),
        "Network: " .. tostring(cfg.network),
        "Realm: " .. tostring(cfg.realm) .. (cfg.role == "satellite" and (" (Main " .. tostring(cfg.mainRealm) .. ")") or ""),
        "Cipher: " .. (cfg.cipherName or (cfg.allowSoftwareBackbone and "software" or "none")),
        "Storage: " .. (#drives > 0 and table.concat(drives, " ") or "this computer"),
        "Bridges: " .. #(cfg.bridges or {}),
        "Displays: " .. M.displayHint(cfg),
        "Admin account: " .. (self.extra.admin and self.extra.admin.user or "none"),
    }
    return lines
end

function Wizard:finish()
    local cfg = self.cfg
    local text = table.concat(self:summary(), "; ")
    if not ui.confirm(self.surf, "Save Setup", text .. ".", { yes = "Save", no = "Back" }) then return "back" end
    local auto = ui.confirm(self.surf, "Autostart", "Start ZelNet every time this computer boots? (Writes /startup; an old one is kept as /startup.old.)", { yes = "Yes", no = "No" })
    if (self.mode == "satellite" or self.isSatellite) and not cfg.ownDataKey then
        cfg.dataKey = crypto.newKey()
        cfg.ownDataKey = true
    end
    cfg.setupAt = compat.stamp()
    local ok, err = M.installProgram(self.programPath)
    if ok then ok, err = config.save(cfg, self.path) end
    if ok and auto then ok, err = M.writeStartup() end
    if not ok then
        self:say("Save Setup", "Could not save: " .. tostring(err), self.surf.c.bad)
        return "back"
    end
    if self.fromDisk or self.isSatellite then
        local _, diskPath = M.findSatelliteDisk()
        if diskPath then pcall(fs.delete, diskPath) end
    end
    self.saved = true
    self:say("ZelNet Setup", { { text = "Setup saved. Starting the server.", color = self.surf.c.ok } })
    return "done"
end

M.Console = Console

return M
