local need = ...
local compat = need("compat")
local util = need("util")
local ui = need("ui")
local version = need("version")
local navmap = need("navmap")

local M = {}

M.SCALE = 0.5
M.POCKET_MIN = 200000
M.DRIVE_CACHE = 5
M.HISTORY = 60
M.HEAL_EVERY = 60
M.COLLECT_EVERY = 2
M.CONSOLE_EVERY = 2
M.SETUP_EVERY = 5
M.ROLES = {
    { role = "client", label = "Client" },
    { role = "router", label = "Router" },
    { role = "endpoint", label = "Endpoint" },
    { role = "airlock", label = "Airlock" },
    { role = "satellite", label = "Satellite" },
}
M.ROLE_TITLES = { client = "Client", router = "Router", endpoint = "Endpoint", satellite = "Satellite", airlock = "Airlock" }
M.TABS = {
    { id = "overview", label = "Overview", bg = colors.blue, fg = colors.white },
    { id = "devices", label = "Devices", bg = colors.green, fg = colors.white },
    { id = "accounts", label = "Accounts", bg = colors.purple, fg = colors.white },
    { id = "network", label = "Network", bg = colors.cyan, fg = colors.black },
    { id = "bridges", label = "Bridges", bg = colors.orange, fg = colors.black },
    { id = "drives", label = "Drives", bg = colors.brown, fg = colors.white },
    { id = "airlocks", label = "Airlocks", bg = colors.red, fg = colors.white },
    { id = "log", label = "Log", bg = colors.magenta, fg = colors.black },
}
M.BACK_BG = colors.lightBlue
M.BACK_FG = colors.black
M.KINDS = {
    ["in"] = { "IN", "ok" }, out = { "OUT", "accent" }, bb = { "BKBN", "purple" }, flood = { "FLOOD", "orange" },
    info = { "INFO", "muted" }, warn = { "WARN", "warn" }, error = { "ERROR", "bad" }, debug = { "DEBUG", "dim" },
    pkt = { "PKT", "text" },
}
M.PACKET_KINDS = { ["in"] = true, out = true, bb = true, flood = true, pkt = true }
M.WAITS = {
    timer = "sleeping", zn_work = "idle", zn_reply = "awaiting reply", zn_msg = "awaiting message",
    zn_breathe = "working", zn_console_job = "waiting job", key = "awaiting input", char = "awaiting input", rednet_message = "listening", modem_message = "listening",
}
M.NAME_KEYS = {
    "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r", "s", "t",
    "u", "v", "w", "x", "y", "z", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "_", "-", "DEL", "CLR",
}

local Panels = {}
Panels.__index = Panels

function M.normPeripheral(prefix, value)
    local v = util.trim(value or "")
    if v == "" then return nil end
    if v:match("^%d+$") then return prefix .. "_" .. v end
    return v
end

function M.displayNames(cfg)
    local d = type(cfg) == "table" and type(cfg.displays) == "table" and cfg.displays or {}
    return d
end

function M.validateDisplays(values, cfg)
    local out = {}
    local seen = {}
    local order = {
        { "activity", "monitor", "Activity monitor" },
        { "console", "monitor", "Console monitor" },
        { "setup", "monitor", "Setup monitor" },
        { "drive", "drive", "Setup drive" },
    }
    for _, o in ipairs(order) do
        local key, kind, label = o[1], o[2], o[3]
        local name = M.normPeripheral(kind, values[key])
        if name then
            if not peripheral.isPresent(name) then return nil, label .. ": " .. name .. " is not attached." end
            if peripheral.getType(name) ~= kind then return nil, label .. ": " .. name .. " is not a " .. (kind == "drive" and "disk drive" or "monitor") .. "." end
            if seen[name] then return nil, label .. ": " .. name .. " is already the " .. seen[name] .. "." end
            seen[name] = label:lower()
            out[key] = name
        end
    end
    if out.drive and type(cfg) == "table" then
        for role, d in pairs(((cfg.storage or {}).drives) or {}) do
            if d == out.drive then return nil, "Setup drive: " .. out.drive .. " stores " .. tostring(role) .. " data." end
        end
        for _, b in ipairs(cfg.bridges or {}) do
            if type(b) == "table" and (b.sendDrive == out.drive or b.recvDrive == out.drive) then
                return nil, "Setup drive: " .. out.drive .. " belongs to the bridge to " .. tostring(b.peer) .. "."
            end
        end
    end
    local old = M.displayNames(cfg)
    out.scale = old.scale
    out.setupScale = old.setupScale
    if type(old.navmap) == "string" and not seen[old.navmap] then out.navmap = old.navmap end
    return out
end

function M.validateNavmap(value, cfg)
    local name = M.normPeripheral("monitor", value)
    if not name then return false end
    if not peripheral.isPresent(name) then return nil, name .. " is not attached." end
    if peripheral.getType(name) ~= "monitor" then return nil, name .. " is not a monitor." end
    local d = M.displayNames(cfg)
    for _, key in ipairs({ "activity", "console", "setup" }) do
        if d[key] == name then return nil, name .. " is already the " .. key .. " monitor." end
    end
    return name
end

function M.identify(names, extra)
    extra = extra or {}
    for _, name in ipairs(names or ui.findMonitors()) do
        pcall(function()
            local m = peripheral.wrap(name)
            if not m then return end
            local label = name
            local role = extra[name]
            local scale = 5
            while scale > 0.5 do
                m.setTextScale(scale)
                local w, h = m.getSize()
                if w >= #label + 2 and h >= (role and 3 or 1) then break end
                scale = scale - 0.5
            end
            m.setTextScale(scale)
            local w, h = m.getSize()
            local isColor = m.isColor and m.isColor()
            m.setBackgroundColor(isColor and colors.blue or colors.black)
            m.setTextColor(colors.white)
            m.clear()
            local mid = math.max(1, math.floor((h + 1) / 2) - (role and 1 or 0))
            local shown = util.fitText(label, w)
            m.setCursorPos(math.max(1, math.floor((w - #shown) / 2) + 1), mid)
            m.write(shown)
            if role and mid + 2 <= h then
                local r = util.fitText(role, w)
                if isColor then m.setTextColor(colors.lightBlue) end
                m.setCursorPos(math.max(1, math.floor((w - #r) / 2) + 1), mid + 2)
                m.write(r)
            end
        end)
    end
end

function M.clearMonitors(names)
    for _, name in ipairs(names or ui.findMonitors()) do
        pcall(function()
            local m = peripheral.wrap(name)
            m.setTextScale(M.SCALE)
            m.setBackgroundColor(colors.black)
            m.clear()
        end)
    end
end

function M.new(con)
    local self = setmetatable({}, Panels)
    self.con = con
    self.cfg = con.cfg
    self.n = con.n
    self.surfs = {}
    self.tab = "overview"
    self.offsets = {}
    self.maxOffset = 0
    self.history = {}
    self.lastSeq = 0
    self.st = { screen = "home" }
    self.drivesAt = -100
    self.drivesCache = {}
    self.errors = {}
    self.data = { snap = {}, devices = {}, realms = {}, users = {}, air = {} }
    self.healAt = 0
    return self
end

function Panels:collect()
    local con = self.con
    local ctx = con.ctx
    local d = {}
    d.snap = con:snapshot(true) or {}
    d.devices = con:call(ctx.server, "devices") or {}
    d.realms = con:call(ctx.server, "realms") or {}
    if self:names().console then
        d.users = con:call(ctx.tekmail, "listUsers") or {}
        if ctx.airlock and ctx.airlock.enabled ~= false then
            local ok, rows = pcall(con.airlockRows, con)
            d.air = ok and rows or {}
        end
        local st = d.snap.status or {}
        d.network = {}
        for _, kind in ipairs({ "realms", "neighbors", "routes", "links" }) do
            local ok, rows = pcall(con.networkRows, con, kind, ctx.server, st, d.realms)
            d.network[kind] = ok and rows or {}
        end
    end
    self.data = d
end

function Panels:heal(force)
    local now = compat.now()
    local locked = self.con.locked
    if force or locked ~= self.lastLocked or now - self.healAt >= M.HEAL_EVERY then
        self.healAt = now
        self.lastLocked = locked
        for _, s in pairs(self.surfs) do s:invalidate() end
        return true
    end
    return false
end

function Panels:tick()
    self.ticks = (self.ticks or 0) + 1
    local n = self.ticks
    local healed = self:heal()
    if n == 1 or healed or n % M.COLLECT_EVERY == 0 then
        local ok, err = pcall(self.collect, self)
        if not ok then
            local text = "display data: " .. tostring(err)
            if self.errors.collect ~= text then
                self.errors.collect = text
                self.con.log.warn(text)
            end
        else
            self.errors.collect = nil
        end
    end
    self:sample()
    local all = n == 1 or healed
    local d = self:names()
    if d.activity then self:guard("activity", self.drawActivity) end
    if d.console and (all or n % M.CONSOLE_EVERY == 0) then self:guard("console", self.drawConsole) end
    if d.setup and (all or n % M.SETUP_EVERY == 0) then self:guard("setup", self.drawSetup) end
    if d.navmap then self:guard("navmap", self.drawNavmap) end
end

function Panels:drawNavmap()
    local s = self:surface("navmap")
    if not s then return end
    local al = self.con.ctx.airlock
    local list, contain, areas = {}, {}, nil
    if al and al.enabled ~= false then
        list = self.con:call(al, "list") or {}
        contain = self.con:call(al, "containment") or {}
        areas = self.con:call(al, "areaStates", navmap.STATION)
    end
    local clock
    pcall(function() clock = "Day " .. os.day() .. "  " .. textutils.formatTime(os.time(), true) end)
    navmap.draw(s, list, contain, { frame = (self.ticks or 0) % 2, release = version.label(), clock = clock, areas = areas })
    s:flush()
end

function Panels:names()
    return M.displayNames(self.cfg)
end

function Panels:anyPresent()
    local d = self:names()
    for _, key in ipairs({ "activity", "console", "setup", "navmap" }) do
        local name = d[key]
        if type(name) == "string" and peripheral.isPresent(name) then return true end
    end
    return false
end

function Panels:reset()
    self.surfs = {}
end

function Panels:surface(key)
    local name = self:names()[key]
    if type(name) ~= "string" then return nil end
    local s = self.surfs[key]
    if s and (s.name ~= name or not peripheral.isPresent(name)) then s = nil end
    if not s then
        local d = self:names()
        local scale = key == "setup" and (d.setupScale or M.SCALE) or (key == "navmap" and navmap.SCALE) or (d.scale or M.SCALE)
        s = ui.attachMonitor(name, scale)
        self.surfs[key] = s
    end
    if s then
        local w, h = s.target.getSize()
        if w ~= s.w or h ~= s.h then
            s:resize()
            s:invalidate()
        end
    end
    return s
end

function Panels:guard(key, fn)
    local ok, err = pcall(fn, self)
    if ok then
        self.errors[key] = nil
        return true
    end
    local text = key .. " display: " .. tostring(err)
    if self.errors[key] ~= text then
        self.errors[key] = text
        self.con.log.warn(text)
    end
    local s = self.surfs[key]
    if s and peripheral.isPresent(s.name) then s:invalidate() else self.surfs[key] = nil end
    return false
end

function Panels:sample()
    local ring = self.n and self.n.traceRing
    local count = 0
    if ring then
        for _, e in ipairs(ring.items) do
            if e.n > self.lastSeq and M.PACKET_KINDS[e.kind] then count = count + 1 end
        end
        local last = ring.items[#ring.items]
        if last then self.lastSeq = last.n end
    end
    self.history[#self.history + 1] = count
    while #self.history > M.HISTORY do table.remove(self.history, 1) end
end

function Panels:drawAll()
    if self:names().activity then self:guard("activity", self.drawActivity) end
    if self:names().console then self:guard("console", self.drawConsole) end
    if self:names().setup then self:guard("setup", self.drawSetup) end
    if self:names().navmap then self:guard("navmap", self.drawNavmap) end
end

function Panels:run()
    local due = 0
    local timer = compat.quietTimer(0)
    while true do
        local ev, a, b, c = os.pullEvent()
        if ev == "monitor_touch" then
            self:touch(a, b, c)
        elseif ev == "monitor_resize" or ev == "peripheral" or ev == "peripheral_detach" then
            self.surfs = {}
            due = 0
        elseif ev == "disk" or ev == "disk_eject" then
            self.drivesAt = -100
            if a == self:names().drive then self:guard("setup", self.drawSetup) end
        elseif ev == "zn_panel" then
            due = 0
            self:guard("setup", self.drawSetup)
        end
        local now = compat.now()
        if now >= due and not self:anyPresent() then
            due = math.huge
        elseif now >= due then
            due = now + 1
            self:tick()
            timer = compat.quietTimer(1)
        elseif ev == "timer" and a == timer then
            timer = compat.quietTimer(math.max(0.05, due - now))
        end
    end
end

function Panels:touch(name, x, y)
    local d = self:names()
    if name == d.activity then
        local view, cam = self:cameraView()
        if view then
            cam:stopView()
            self:guard("activity", self.drawActivity)
        end
    elseif name == d.console then
        local s = self.surfs.console
        local act = s and self.consolePage and self.consolePage:hit(x, y)
        if act then
            self:consoleAction(act)
            self:guard("console", self.drawConsole)
        end
    elseif name == d.setup then
        local s = self.surfs.setup
        local act = s and self.setupPage and self.setupPage:hit(x, y)
        if not self.con.locked then self.con.lastInput = compat.now() end
        if act then
            self:setupAction(act)
            self:guard("setup", self.drawSetup)
        end
    end
end

local function header(page, title, left)
    local s, c = page.s, page.c
    if s.w >= #title + 16 then
        page:header(title, left)
        return
    end
    s:rect(1, 1, s.w, 1, c.header)
    s:rect(1, 2, s.w, 1, c.div)
    s:field(1, 1, s.w, title, c.text, c.header, "center")
end

local function kindInfo(page, kind)
    local k = M.KINDS[kind] or M.KINDS.pkt
    return k[1], page.c[k[2]] or page.c.text
end

local function timeOf(stamp)
    local text = util.fmtStamp(stamp)
    return text:match("(%d%d:%d%d)$") or text
end

function M.feedLines(entries, w, page)
    local out = {}
    local textW = math.max(4, w - 12)
    for _, e in ipairs(entries) do
        local label, color = kindInfo(page, e.kind)
        local wrapped = util.wrapText(e.text or "", textW)
        for i, line in ipairs(wrapped) do
            out[#out + 1] = { time = i == 1 and timeOf(e.s) or "", label = i == 1 and label or "", color = color, text = line, kind = e.kind }
        end
    end
    return out
end

function M.table(page, x, y, w, h, cols, rows, offset)
    local s, c = page.s, page.c
    local list = {}
    for _, col in ipairs(cols) do list[#list + 1] = col end
    local function fixed()
        local sum, flex = 0, 0
        for _, col in ipairs(list) do
            if col.w then sum = sum + col.w else flex = flex + 1 end
        end
        return sum + (#list - 1), flex
    end
    while #list > 1 do
        local sum, flex = fixed()
        if w - sum >= (flex > 0 and 6 or 0) then break end
        table.remove(list)
    end
    local sum, flex = fixed()
    local free = math.max(0, w - sum)
    local widths = {}
    local seen = 0
    for i, col in ipairs(list) do
        if col.w then
            widths[i] = col.w
        else
            seen = seen + 1
            local each = math.floor(free / flex)
            widths[i] = seen == flex and (free - each * (flex - 1)) or each
        end
    end
    if flex == 0 and #list > 0 then widths[#list] = widths[#list] + free end
    local cx = x
    for i, col in ipairs(list) do
        s:field(cx, y, widths[i], col.label, c.muted, c.inset, col.align)
        cx = cx + widths[i] + 1
    end
    s:text(x, y + 1, string.rep("-", w), c.dim, c.inset)
    local bodyH = h - 2
    local maxOff = math.max(0, #rows - bodyH)
    offset = util.clamp(offset or 0, 0, maxOff)
    for r = 1, bodyH do
        local row = rows[offset + r]
        local ry = y + 1 + r
        s:rect(x, ry, w, 1, c.inset)
        if row then
            cx = x
            for i, col in ipairs(list) do
                local v = row[col.key]
                local color = (row.colors and row.colors[col.key]) or row.color or c.text
                s:field(cx, ry, widths[i], v == nil and "" or tostring(v), color, c.inset, col.align)
                cx = cx + widths[i] + 1
            end
        end
    end
    return offset, maxOff
end

M.CAM_RAMP = { colors.white, colors.lightGray, colors.yellow, colors.orange, colors.red, colors.magenta, colors.purple, colors.blue, colors.gray }
M.CAM_CHARS = "@%#*+=-:."
M.CAM_RANGE = 32

function M.camShade(d, isColor)
    local n = isColor and #M.CAM_RAMP or #M.CAM_CHARS
    local i = util.clamp(math.floor(math.sqrt(math.max(0, d) / M.CAM_RANGE) * n) + 1, 1, n)
    if isColor then return " ", M.CAM_RAMP[i] end
    return M.CAM_CHARS:sub(i, i), colors.black
end

function Panels:cameraView()
    local cam = self.con.ctx and self.con.ctx.camera
    return cam and cam.view, cam
end

function Panels:drawCamera(s, view)
    local page = ui.page(s)
    local c = page.c
    header(page, "Camera " .. tostring(view.realm), "ZelNet " .. tostring(self.cfg.realm))
    local W, H = s.w, s.h
    local rightW = util.clamp(math.floor(W * 0.32), 18, 30)
    if W < 50 then rightW = 0 end
    local leftW = W - 2 - (rightW > 0 and rightW + 1 or 0)
    local foot = H
    local ix, iy, iw, ih = page:card(2, 3, leftW, H - 3, "View from " .. tostring(view.realm), c.accent, tostring(view.status))
    if ix then
        local ch = ih
        local cw = math.min(iw, math.max(4, math.floor(ch * 1.6 + 0.5)))
        if cw < ch * 1.6 then ch = math.max(3, math.floor(cw / 1.6 + 0.5)) end
        local mod0 = need("camera")
        local capH = math.min(ch, mod0.MAX_H)
        view.w, view.h = mod0.clampSize(math.floor(capH * 1.6 + 0.5), capH)
        local f = view.frame
        local ox = ix + math.floor((iw - cw) / 2)
        local oy = iy + math.floor((ih - ch) / 2)
        if f and f.w and f.h then
            local mod = need("camera")
            local sx, sy = cw / f.w, ch / f.h
            for y = 1, ch do
                local fr = math.min(f.h, math.floor((y - 1) / sy) + 1)
                local line = f.rows and f.rows[fr]
                for x = 1, cw do
                    local fc = math.min(f.w, math.floor((x - 1) / sx) + 1)
                    local code = line and line:sub(fc, fc) or ""
                    if code == "" then
                        s:text(ox + x - 1, oy + y - 1, ".", c.dim, c.inset)
                    else
                        local d = mod.decode(code)
                        if d == nil then
                            s:text(ox + x - 1, oy + y - 1, " ", c.text, colors.black)
                        else
                            local chr, bg = M.camShade(d, s.isColor)
                            s:text(ox + x - 1, oy + y - 1, chr, colors.white, bg)
                        end
                    end
                end
            end
            if f.row and f.row >= 1 and f.row < f.h and (f.frames or 0) == 0 then
                local yy = oy + math.floor((f.row - 1) * sy)
                s:text(ox + cw, yy, "<", c.warn, c.bg)
            end
        else
            page:wrapped(ix, iy, iw, ih, view.err and ("No picture: " .. view.err) or "Waiting for the first rows from " .. tostring(view.realm) .. "...", view.err and c.bad or c.muted)
        end
    end
    if rightW > 0 then
        local rx = 2 + leftW + 1
        local px, py, pw, ph = page:card(rx, 3, rightW, H - 3, "Report", c.purple)
        if px then
            local r = view.report or (view.frame and view.frame.report) or {}
            local f = view.frame or {}
            local lines = {
                { "Realm", tostring(r.realm or view.realm) },
                { "Status", tostring(view.status), view.err and c.bad or c.ok },
                { "Camera", r.camera and ("camera " .. (tostring(r.camera):match("(%d+)$") or "")) or "none" },
                { "Ahead", r.ahead and r.ahead >= 0 and (util.fmtFixed(r.ahead, 1) .. " blocks") or "open" },
                { "Frames", tostring(f.frames or 0) .. (f.row and f.h and (" row " .. f.row .. "/" .. f.h) or "") },
                { "Size", f.w and (f.w .. "x" .. f.h) or "-" },
                { "Release", tostring(r.rel or "?") },
                { "Uptime", r.uptime and util.fmtDuration(r.uptime) or "?" },
                { "Devices", r.devices and (tostring(r.online or 0) .. "/" .. tostring(r.devices) .. " online") or "?" },
                { "Updated", view.at and (util.fmtDuration(compat.now() - view.at) .. " ago") or "never" },
            }
            local row = py
            for _, l in ipairs(lines) do
                if row >= py + ph - 3 then break end
                page:kv(px, row, pw, l[1], l[2], l[3])
                row = row + 1
            end
            local ly = py + ph - 3
            if ly > row then
                s:text(px, ly, "near", c.muted, c.inset)
                local n = s.isColor and #M.CAM_RAMP or #M.CAM_CHARS
                local bx = px + 5
                local bw = math.max(1, pw - 9)
                for k = 0, bw - 1 do
                    local d = ((k + 0.5) / bw) ^ 2 * M.CAM_RANGE
                    local chr, bg = M.camShade(d, s.isColor)
                    s:text(bx + k, ly, chr, colors.white, bg)
                end
                s:text(bx + bw, ly, " far", c.muted, c.inset)
                if n > 0 then s:field(px, ly + 1, pw, "black = nothing in 32", c.dim, c.inset) end
                s:field(px, ly + 2, pw, "Right click to close", c.warn, c.inset)
            end
        end
    else
        s:field(1, foot, W, "Right click to close", c.warn, c.bg, "center")
    end
    s:flush()
end

function Panels:drawActivity()
    local s = self:surface("activity")
    if not s then return end
    local view = self:cameraView()
    if view then return self:drawCamera(s, view) end
    local page = ui.page(s)
    local c = page.c
    local snap = self.data.snap
    local st = snap.status or {}
    header(page, "Activity", "ZelNet " .. tostring(self.cfg.realm))
    local W, H = s.w, s.h
    local tiles = self:activityTiles(c, st)
    local tileW = 18
    local nTiles = math.max(1, math.min(#tiles, math.floor((W - 1) / (tileW + 1))))
    tileW = math.floor((W - 2 - (nTiles - 1)) / nTiles)
    local tx = 2
    for i = 1, nTiles do
        local t = tiles[i]
        local ix, iy, iw = page:card(tx, 3, tileW, 4, t.title, t.color)
        if ix then
            s:field(ix, iy, iw, t.value, t.color or c.text, c.inset)
        end
        tx = tx + tileW + 1
    end
    local top = 8
    local bodyH = H - top + 1
    local rightW = W >= 90 and math.max(30, math.floor((W - 3) * 0.34)) or 0
    local leftW = W - 2 - (rightW > 0 and rightW + 1 or 0)
    local ix, iy, iw, ih = page:card(2, top, leftW, bodyH, "Live traffic", c.accent, "newest at the bottom")
    if ix then self:drawFeed(page, ix, iy, iw, ih) end
    if rightW > 0 then
        local rx = 2 + leftW + 1
        local chartH = math.min(11, math.floor(bodyH / 2))
        local cx, cy, cw, ch = page:card(rx, top, rightW, chartH, "Packets per second", c.ok)
        if cx then self:drawChart(page, cx, cy, cw, ch) end
        local px, py, pw, phh = page:card(rx, top + chartH, rightW, bodyH - chartH, "Processes", c.purple, tostring(self:taskCount()) .. " tasks")
        if px then self:drawProcesses(page, px, py, pw, phh) end
    end
    s:flush()
end

function Panels:taskCount()
    local n = self.n
    if not n or not n.tasks then return 0 end
    local count = 0
    for _, t in ipairs(n.tasks) do if not t.dead then count = count + 1 end end
    return count
end

function Panels:activityTiles(c, st)
    local dev = st.devices or {}
    local realms, reach = 0, 0
    local list = self.data.realms
    if type(list) == "table" then
        for _, r in ipairs(list) do
            realms = realms + 1
            if r.reachable or r.realm == st.realm then reach = reach + 1 end
        end
    end
    local now = self.history[#self.history] or 0
    local q = st.queue or {}
    local queued = (q.stored or 0) + (q.backbone or 0)
    local counters = st.counters or {}
    local problems = (counters.errors or 0) + (counters.dropped or 0) + (counters.badMac or 0) + (counters.accessBad or 0)
    return {
        { title = "Packets/s", value = tostring(now), color = now > 0 and c.ok or c.muted },
        { title = "Devices on", value = tostring(dev.online or 0) .. " of " .. tostring(dev.total or 0), color = c.ok },
        { title = "Realms up", value = tostring(reach) .. " of " .. tostring(realms), color = reach == realms and c.ok or c.warn },
        { title = "Queued", value = queued .. " packet" .. (queued == 1 and "" or "s"), color = queued > 0 and c.warn or c.muted },
        { title = "Uptime", value = util.fmtDuration(st.uptime or 0), color = c.accent },
        { title = "Problems", value = tostring(problems), color = problems > 0 and c.bad or c.muted },
    }
end

function Panels:drawFeed(page, x, y, w, h)
    local s, c = page.s, page.c
    local ring = self.n and self.n.traceRing
    local entries = ring and ring.last(h) or {}
    local lines = M.feedLines(entries, w, page)
    local start = math.max(1, #lines - h + 1)
    while start <= #lines and lines[start].label == "" do start = start + 1 end
    if #lines == 0 then
        page:wrapped(x, y, w, h, "Waiting for traffic. Packets from devices, other realms and this server show here as they pass.", c.muted)
        return
    end
    local row = 0
    for i = start, #lines do
        local l = lines[i]
        local ry = y + row
        s:field(x, ry, 5, l.time, c.dim, c.inset)
        s:field(x + 6, ry, 5, l.label, l.color, c.inset)
        s:field(x + 12, ry, w - 12, l.text, M.PACKET_KINDS[l.kind] and c.text or l.color, c.inset)
        row = row + 1
    end
end

function Panels:drawChart(page, x, y, w, h)
    local s, c = page.s, page.c
    local barsH = math.max(1, h - 1)
    local hist = self.history
    local n = math.min(#hist, w)
    local peak = 1
    for i = #hist - n + 1, #hist do
        if hist[i] and hist[i] > peak then peak = hist[i] end
    end
    for col = 1, w do
        local v = hist[#hist - w + col]
        if v then
            local bh = v > 0 and math.max(1, math.floor(v * barsH / peak + 0.5)) or 0
            if bh > 0 then
                if s.isColor then
                    s:rect(x + col - 1, y + barsH - bh, 1, bh, c.ok)
                else
                    for r = 0, bh - 1 do s:text(x + col - 1, y + barsH - 1 - r, "#", c.text, c.inset) end
                end
            end
        end
    end
    local now = hist[#hist] or 0
    local label = "now " .. now .. "/s  peak " .. peak .. "/s"
    s:field(x, y + barsH, w, label, c.muted, c.inset)
    local span = "last " .. math.min(#hist, w) .. "s"
    if #label + #span + 1 <= w then s:text(x + w - #span, y + barsH, span, c.dim, c.inset) end
end

function Panels:processRows()
    local n = self.n
    local rows, index = {}, {}
    if n and n.tasks then
        local list = {}
        for _, t in ipairs(n.tasks) do list[#list + 1] = t end
        for _, t in ipairs(n.starting or {}) do list[#list + 1] = t end
        for _, t in ipairs(list) do
            if not t.dead then
                local name = tostring(t.name or "task")
                local state = t.filter == nil and "any event" or (M.WAITS[t.filter] or t.filter)
                local r = index[name]
                if r then
                    r.count = r.count + 1
                else
                    r = { name = name, count = 1, state = state }
                    index[name] = r
                    rows[#rows + 1] = r
                end
            end
        end
    end
    if n and n.timers then
        local now = compat.now()
        for _, tm in ipairs(n.timers) do
            rows[#rows + 1] = { name = tostring(tm.name), count = 1, state = "timer in " .. util.fmtDuration(math.max(0, (tm.next or now) - now)), timer = true }
        end
    end
    return rows
end

function Panels:drawProcesses(page, x, y, w, h)
    local s, c = page.s, page.c
    local rows = self:processRows()
    local stateW = math.min(16, math.max(8, math.floor(w * 0.45)))
    local nameW = w - stateW - 1
    for i = 1, math.min(h, #rows) do
        local r = rows[i]
        local ry = y + i - 1
        local name = r.name .. (r.count > 1 and (" x" .. r.count) or "")
        if i == h and #rows > h then
            s:field(x, ry, w, "+" .. (#rows - h + 1) .. " more", c.dim, c.inset)
        else
            s:field(x, ry, nameW, name, r.timer and c.muted or c.text, c.inset)
            s:field(x + nameW + 1, ry, stateW, r.state, r.state == "any event" and c.ok or c.dim, c.inset, "right")
        end
    end
end

function Panels:pushLogs()
    if self.logBusy then return end
    local al = self.con.ctx.airlock
    local okA, mod = pcall(need, "airlock")
    if not al or not okA then return end
    self.logBusy = true
    self.logStatus = { text = "Collecting airlock logs...", kind = "warn" }
    local function job()
        local ok, err = pcall(function()
            local n = self.con:call(al, "requestLogs") or 0
            self.logStatus = { text = "Collecting logs from " .. n .. " airlocks...", kind = "warn" }
            compat.sleep(mod.DUMP_WAIT)
            local header = "server " .. tostring(self.cfg.realm) .. " #" .. tostring(os.getComputerID and os.getComputerID() or "?") .. " " .. version.label()
            local text = self.con:call(al, "logBundle", header)
            if type(text) ~= "string" then error("could not build the bundle", 0) end
            util.writeFile("/airlock_logs.txt", text)
            self.logStatus = { text = "Uploading " .. #text .. " characters...", kind = "warn" }
            local url, uerr = mod.upload(text)
            if url then
                self.con:call(al, "event", "logs pushed: " .. url)
                self.con:audit("airlock_logs", url, #text .. " bytes", true)
                self.logStatus = { text = "Logs: " .. url, kind = "ok" }
            else
                self.logStatus = { text = "Upload failed (" .. tostring(uerr) .. "); saved /airlock_logs.txt", kind = "bad" }
            end
        end)
        if not ok then self.logStatus = { text = "Push logs failed: " .. tostring(err), kind = "bad" } end
        self.logBusy = false
        os.queueEvent("zn_panel")
    end
    if self.n and self.n.spawn then self.n:spawn(job, "airlock-logs") else job() end
end

function Panels:pushBridgeReport()
    if self.bridgeBusy then return end
    local srv = self.con.ctx.server
    local okA, mod = pcall(need, "airlock")
    if not srv or not okA then return end
    self.bridgeBusy = true
    self.bridgeStatus = { text = "Building the bridge report...", kind = "warn" }
    local function job()
        local ok, err = pcall(function()
            local body = self.con:call(srv, "bridgeReport")
            if type(body) ~= "string" then error("could not build the report", 0) end
            local text = "ZELNET BRIDGE REPORT\nserver " .. tostring(self.cfg.realm) .. " #" .. tostring(os.getComputerID and os.getComputerID() or "?") .. " " .. version.label() .. " at " .. tostring(compat.stamp()) .. "\n" .. body
            util.writeFile("/bridge_report.txt", text)
            self.bridgeStatus = { text = "Uploading " .. #text .. " characters...", kind = "warn" }
            local url, uerr = mod.upload(text)
            if url then
                self.con:audit("bridge_report", url, #text .. " bytes", true)
                self.bridgeStatus = { text = "Report: " .. url, kind = "ok" }
            else
                self.bridgeStatus = { text = "Upload failed (" .. tostring(uerr) .. "); saved /bridge_report.txt", kind = "bad" }
            end
        end)
        if not ok then self.bridgeStatus = { text = "Bridge report failed: " .. tostring(err), kind = "bad" } end
        self.bridgeBusy = false
        os.queueEvent("zn_panel")
    end
    if self.n and self.n.spawn then self.n:spawn(job, "bridge-report") else job() end
end

function Panels:consoleAction(act)
    if act == "airlock:logs" then return self:pushLogs() end
    if act == "bridge:report" then return self:pushBridgeReport() end
    local tab = act:match("^tab:(.+)$")
    if tab then
        self.tab = tab
        return
    end
    local off = self.offsets[self.tab] or 0
    local step = math.max(1, (self.pageRows or 10) - 1)
    if act == "up" then
        self.offsets[self.tab] = math.max(0, off - step)
    elseif act == "down" then
        self.offsets[self.tab] = math.min(self.maxOffset or 0, off + step)
    end
end

function Panels:drawConsole()
    local s = self:surface("console")
    if not s then return end
    local page = ui.page(s)
    local c = page.c
    self.consolePage = page
    header(page, "Server Console", "ZelNet " .. tostring(self.cfg.realm))
    local W, H = s.w, s.h
    local tabH = H >= 30 and 3 or 1
    M.drawTabs(page, 2, 3, W - 2, tabH, self.tab)
    local top = 3 + tabH + 1
    local footY = H
    local area = { x = 2, y = top, w = W - 2, h = footY - top - 1 }
    self.maxOffset = 0
    self.pageRows = area.h
    local fn = self["tab_" .. self.tab] or self.tab_overview
    fn(self, page, area)
    local locked = self.con.locked
    local note = (locked and "Console locked" or "Console unlocked") .. ". Read only; change settings on the terminal."
    local btnW = 8
    local hasScroll = self.maxOffset > 0
    local textW = W - 2 - (hasScroll and (btnW * 2 + 2) or 0)
    s:field(2, footY, textW, note, locked and c.dim or c.muted, c.bg)
    if hasScroll then
        page:button(W - btnW * 2, footY, btnW, 1, "Up", M.BACK_BG, M.BACK_FG, "up")
        page:button(W - btnW + 1, footY, btnW, 1, "Down", M.BACK_BG, M.BACK_FG, "down")
    end
    s:flush()
end

function M.drawTabs(page, x, y, w, h, active)
    local s = page.s
    local n = #M.TABS
    local each = math.floor((w - (n - 1)) / n)
    local extra = w - (n - 1) - each * n
    local cx = x
    for i, tab in ipairs(M.TABS) do
        local tw = each + ((i <= extra) and 1 or 0)
        local on = tab.id == active
        local bg, fg = tab.bg, tab.fg
        if on then bg, fg = colors.white, colors.black end
        local label = tab.label
        if not s.isColor then
            bg, fg = page.c.inset, page.c.text
            if on then label = ">" .. label .. "<" end
        end
        page:button(cx, y, tw, h, label, bg, fg, "tab:" .. tab.id)
        if on and s.isColor and h > 1 then s:rect(cx, y + h - 1, tw, 1, tab.bg) end
        cx = cx + tw + 1
    end
end

function Panels:listCard(page, area, title, accent, right, cols, rows, empty)
    local ix, iy, iw, ih = page:card(area.x, area.y, area.w, area.h, title, accent, right)
    if not ix then return end
    if #rows == 0 then
        page:wrapped(ix, iy, iw, ih, empty or "Nothing to show.", page.c.muted)
        return
    end
    local off, maxOff = M.table(page, ix, iy, iw, ih, cols, rows, self.offsets[self.tab])
    self.offsets[self.tab] = off
    self.maxOffset = maxOff
    self.pageRows = ih - 2
end

function Panels:tab_overview(page, area)
    local s, c = page.s, page.c
    local sui = need("serverui")
    local snap = self.data.snap
    local cardsH = math.min(area.h - 10, 16)
    local used = sui.drawCards(page, area.x, area.y, area.w, cardsH, sui.cards(c, snap, self.cfg))
    local y = area.y + used
    local restH = area.h - used
    if restH < 4 then return end
    local st = snap.status or {}
    local cols = area.w >= 90 and 3 or 2
    local colW = math.floor((area.w - (cols - 1)) / cols)
    local lastW = area.w - (colW + 1) * (cols - 1)
    local halfW = colW
    local wx, wy, ww, wh = page:card(area.x, y, colW, restH, "Warnings", c.warn, tostring(#(st.warnings or {})))
    if wx then
        local row = 0
        for _, text in ipairs(st.warnings or {}) do
            if row >= wh then break end
            row = row + page:wrapped(wx, wy + row, ww, wh - row, text, c.warn) + 1
        end
        if row == 0 then s:field(wx, wy, ww, "No warnings.", c.ok, c.inset) end
    end
    local cip = st.cipher or {}
    local dir = st.directory or {}
    local kx, ky, kw, kh = page:card(area.x + halfW + 1, y, cols == 3 and colW or lastW, restH, "Network", c.accent, tostring(self.cfg.network))
    if kx then
        local lines = {
            { "Main realm", tostring(st.mainRealm or self.cfg.mainRealm) },
            { "Cipher", (cip.ok and tostring(cip.kind) or "off") .. (cip.name and (" on " .. tostring(cip.name)) or ""), cip.ok and c.ok or c.bad },
            { "Fingerprint", tostring(cip.fingerprint or "-") },
            { "Directory", "v" .. tostring(dir.ver or 0) .. ", " .. tostring(dir.users or 0) .. " users, " .. (dir.synced and "synced" or "syncing"), dir.synced and c.ok or c.warn },
            { "Program", "ZelNet " .. version.label() .. " (" .. version.full() .. ")" },
        }
        for i = 1, math.min(kh, #lines) do page:kv(kx, ky + i - 1, kw, lines[i][1], lines[i][2], lines[i][3]) end
    end
    if cols == 3 then
        local ex, ey, ew, eh = page:card(area.x + (colW + 1) * 2, y, lastW, restH, "Recent events", c.purple, "Log tab has more")
        if ex then
            local log = self.con.log
            local entries = log and log.last and log.last(eh) or {}
            local colorOf = { warn = c.warn, error = c.bad, debug = c.dim }
            local row = 0
            for i = #entries, 1, -1 do
                if row >= eh then break end
                local e = entries[i]
                row = row + page:wrapped(ex, ey + row, ew, eh - row, e.text, colorOf[e.level] or c.text)
            end
            if row == 0 then s:field(ex, ey, ew, "Nothing yet.", c.muted, c.inset) end
        end
    end
end

function Panels:tab_devices(page, area)
    local c = page.c
    local list = self.data.devices or {}
    local rows = {}
    local colorOf = { online = c.ok, pending = c.warn, revoked = c.bad }
    for _, d in ipairs(list) do
        rows[#rows + 1] = {
            name = d.name, role = M.ROLE_TITLES[d.role] or d.role, status = d.status,
            cid = d.cid and ("#" .. tostring(d.cid)) or "unbound",
            path = (d.hops and (tostring(d.hops) .. " hop" .. (d.hops == 1 and "" or "s")) or "-") .. (d.parent and (" via " .. tostring(d.parent)) or ""),
            seen = d.lastSeen and util.fmtStamp(d.lastSeen) or "never",
            prog = d.prog or "?",
            colors = { status = colorOf[d.status] or c.muted },
        }
    end
    local st = self.data.snap.status or {}
    local dv = st.devices or {}
    self:listCard(page, area, "Devices", c.ok, tostring(dv.online or 0) .. " of " .. tostring(dv.total or 0) .. " online", {
        { key = "name", label = "Name", w = 18 }, { key = "role", label = "Role", w = 10 }, { key = "status", label = "Status", w = 9 },
        { key = "cid", label = "Computer", w = 9 }, { key = "path", label = "Path", w = 18 }, { key = "seen", label = "Last seen", w = 10 },
        { key = "prog", label = "Program" },
    }, rows, "No devices yet. Use the setup monitor or Devices on the terminal to provision one.")
end

function Panels:tab_accounts(page, area)
    local c = page.c
    local tm = self.con.ctx.tekmail
    local list = self.data.users or {}
    local rows = {}
    for _, u in ipairs(list) do
        rows[#rows + 1] = {
            name = u.name, display = u.display or u.name, realm = u.realm or "?",
            rights = u.admin and "admin" or "user", here = u["local"] and "yes" or "no",
            color = u["local"] and c.text or c.muted, colors = { rights = u.admin and c.warn or nil },
        }
    end
    self:listCard(page, area, "Accounts", c.purple, tostring(#rows) .. " accounts", {
        { key = "name", label = "User", w = 18 }, { key = "display", label = "Display name", w = 20 }, { key = "realm", label = "Home realm", w = 12 },
        { key = "rights", label = "Rights", w = 8 }, { key = "here", label = "Lives here" },
    }, rows, tm and "No accounts yet." or "TekMail is not running on this server.")
end

function Panels:tab_network(page, area)
    local c = page.c
    local quads = {
        { "Realms", "realms", c.brand }, { "Neighbors", "neighbors", c.accent },
        { "Routes", "routes", c.purple }, { "Links", "links", c.orange },
    }
    local halfW = math.floor((area.w - 1) / 2)
    local halfH = math.floor(area.h / 2)
    for i, q in ipairs(quads) do
        local col = (i - 1) % 2
        local row = math.floor((i - 1) / 2)
        local x = area.x + col * (halfW + 1)
        local y = area.y + row * halfH
        local w = col == 0 and halfW or (area.w - halfW - 1)
        local h = row == 0 and halfH or (area.h - halfH)
        local rows = (self.data.network or {})[q[2]] or {}
        local ix, iy, iw, ih = page:card(x, y, w, h, q[1], q[3], tostring(#rows))
        if ix then
            if #rows == 0 then
                page:wrapped(ix, iy, iw, ih, "None yet.", c.muted)
            else
                local shown = {}
                for k = 1, math.min(#rows, ih) do shown[k] = rows[k] end
                if #rows > ih then shown[ih] = { text = "+" .. (#rows - ih + 1) .. " more on the terminal", color = c.dim } end
                page:list(ix, iy, iw, ih, shown, 0)
            end
        end
    end
end

function Panels:tab_bridges(page, area)
    local c = page.c
    local st = self.data.snap.status or {}
    local list = st.bridges or {}
    if #list == 0 then
        local ix, iy, iw, ih = page:card(area.x, area.y, area.w, area.h, "Bridges", c.accent)
        if ix then page:wrapped(ix, iy, iw, ih, "No tesseract bridges. Add one under Bridges on the terminal.", c.muted) end
        return
    end
    local cfgOf = {}
    for _, b in ipairs(self.cfg.bridges or {}) do if type(b) == "table" then cfgOf[b.peer] = b end end
    local cards = {}
    for _, b in ipairs(list) do
        local bc = cfgOf[b.peer] or {}
        local bad = b.state == "fault" or b.state == "unconfigured" or b.fault
        local problem, pcolor = b.fault or (bad and b.lastError) or nil, c.bad
        if not problem and b.lastError and b.lastErrorAge and b.lastErrorAge < 600 then
            problem, pcolor = util.fmtDuration(b.lastErrorAge) .. " ago, recovered since: " .. b.lastError, c.warn
        end
        local quiet = "none"
        if (b.bounces or 0) > 0 then quiet = "none, " .. tostring(b.bounces) .. " handed back and retried" end
        cards[#cards + 1] = {
            title = "Bridge to " .. tostring(b.peer), accent = bad and c.bad or (b.up and c.ok or c.warn),
            lines = {
                { "State", tostring(b.state) .. (b.up and ", link up" or ", link down"), bad and c.bad or (b.up and c.ok or c.warn) },
                { "Queued", tostring(b.queued or 0) .. " packets, " .. tostring(b.inflight or 0) .. " moving" },
                { "Sent", tostring(b.sent or 0) .. " (" .. util.fmtBytes(b.bytesOut or 0) .. ")" },
                { "Received", tostring(b.received or 0) .. " (" .. util.fmtBytes(b.bytesIn or 0) .. ")" },
                { "Trips", tostring(b.trips or 0) .. (b.lastTrip and (", last " .. util.fmtFixed(b.lastTrip, 1) .. "s") or "") },
                { "Send", tostring(bc.sendTess or "?") .. " " .. tostring(bc.sendDrive or "?") .. " " .. tostring(bc.sendDir or "?") },
                { "Receive", tostring(bc.recvTess or "?") .. " " .. tostring(bc.recvDrive or "?") .. " " .. tostring(bc.recvDir or "?") },
            },
            problem = problem,
            problemColor = pcolor,
            quiet = quiet,
        }
    end
    local foot = area.y + area.h - 1
    local label = self.bridgeBusy and " Working... " or " Push report "
    page:button(area.x, foot, #label, 1, label, self.bridgeBusy and c.div or c.brand, c.text, "bridge:report")
    local bst = self.bridgeStatus
    if bst then page.s:field(area.x + #label + 1, foot, area.w - #label - 1, bst.text, c[bst.kind] or c.text, c.bg) end
    area = { x = area.x, y = area.y, w = area.w, h = area.h - 2 }
    local cols = area.w >= 78 and 2 or 1
    local cardW = math.floor((area.w - (cols - 1)) / cols)
    local cardH = 14
    local perPage = cols * math.max(1, math.floor(area.h / cardH))
    local off = util.clamp(self.offsets.bridges or 0, 0, math.max(0, #cards - perPage))
    self.offsets.bridges = off
    self.maxOffset = math.max(0, #cards - perPage)
    self.pageRows = perPage + 1
    for i = 1, math.min(perPage, #cards - off) do
        local card = cards[off + i]
        local col = (i - 1) % cols
        local row = math.floor((i - 1) / cols)
        local ix, iy, iw, ih = page:card(area.x + col * (cardW + 1), area.y + row * cardH, cardW, cardH, card.title, card.accent)
        if ix then
            for k = 1, math.min(ih, #card.lines) do
                local l = card.lines[k]
                page:kv(ix, iy + k - 1, iw, l[1], l[2], l[3])
            end
            local py = iy + #card.lines
            if py < iy + ih then
                page:kv(ix, py, iw, "Problem", card.problem and "" or card.quiet, c.muted)
                if card.problem then page:wrapped(ix, py + 1, iw, iy + ih - py - 1, card.problem, card.problemColor) end
            end
        end
    end
end

local function usedBytes(path, depth)
    local total = 0
    local ok, names = pcall(fs.list, path)
    if not ok or type(names) ~= "table" then return 0 end
    for _, n in ipairs(names) do
        local p = path .. "/" .. n
        if fs.isDir(p) then
            if (depth or 0) < 8 then total = total + usedBytes(p, (depth or 0) + 1) end
        else
            local sok, size = pcall(fs.getSize, p)
            if sok and tonumber(size) then total = total + tonumber(size) end
        end
    end
    return total
end

function M.mediaInfo(d)
    local info = { name = d.name, label = d.label, present = d.present }
    if not d.present then
        info.kind = "none"
        return info
    end
    if not d.hasData or not d.mount then
        info.kind = "other"
        return info
    end
    local mount = "/" .. tostring(d.mount):gsub("^/+", "")
    info.mount = mount
    info.used = usedBytes(mount)
    info.free = d.free or 0
    info.capacity = info.used + info.free
    info.kind = info.capacity >= M.POCKET_MIN and "pocket" or "floppy"
    info.files = d.files or 0
    info.foreign = d.foreign or 0
    info.zelnet = d.zelnet
    return info
end

function M.mediaTitle(kind)
    if kind == "pocket" then return "pocket computer" end
    if kind == "floppy" then return "floppy disk" end
    if kind == "other" then return "not a disk" end
    return "empty"
end

function Panels:driveList()
    local now = compat.now()
    if now - self.drivesAt < M.DRIVE_CACHE then return self.drivesCache end
    local ok, prov = pcall(need, "provision")
    local out = {}
    if ok and prov then
        for _, d in ipairs(prov.drives()) do out[#out + 1] = M.mediaInfo(d) end
    end
    table.sort(out, function(a, b)
        local pa, na = tostring(a.name):match("^(.-)(%d*)$")
        local pb, nb = tostring(b.name):match("^(.-)(%d*)$")
        if pa ~= pb then return pa < pb end
        return (tonumber(na) or -1) < (tonumber(nb) or -1)
    end)
    self.drivesCache = out
    self.drivesAt = now
    return out
end

function Panels:driveUses()
    local uses = {}
    for role, d in pairs(((self.cfg.storage or {}).drives) or {}) do
        if type(d) == "string" then uses[d] = "storage: " .. tostring(role) end
    end
    for _, b in ipairs(self.cfg.bridges or {}) do
        if type(b) == "table" then
            if b.sendDrive then uses[b.sendDrive] = "bridge send to " .. tostring(b.peer) end
            if b.recvDrive then uses[b.recvDrive] = "bridge receive from " .. tostring(b.peer) end
        end
    end
    local d = self:names().drive
    if d then uses[d] = "setup drive" end
    return uses
end

function Panels:tab_drives(page, area)
    local c = page.c
    local uses = self:driveUses()
    local rows = {}
    for _, d in ipairs(self:driveList()) do
        local pct = d.capacity and d.capacity > 0 and math.floor(d.used * 100 / d.capacity + 0.5) or nil
        local barW = 10
        local bar = ""
        if pct then
            local filled = math.floor(barW * pct / 100 + 0.5)
            bar = string.rep("#", filled) .. string.rep(".", barW - filled) .. " " .. pct .. "%"
        end
        rows[#rows + 1] = {
            name = d.name, media = M.mediaTitle(d.kind), label = d.label or "-",
            use = uses[d.name] or "free", files = d.files and tostring(d.files) or "-",
            space = d.capacity and (util.fmtBytes(d.used) .. " of " .. util.fmtBytes(d.capacity)) or "-",
            bar = bar,
            colors = {
                media = (d.kind == "none" or d.kind == "other") and c.muted or c.text,
                use = uses[d.name] and c.accent or c.dim,
                bar = pct and (pct >= 90 and c.bad or (pct >= 70 and c.warn or c.ok)) or c.dim,
            },
        }
    end
    local storageInfo = self.data.snap.storage or {}
    local offline = 0
    for _, r in ipairs(storageInfo) do if r.present == false then offline = offline + 1 end end
    self:listCard(page, area, "Disk drives", c.orange, #rows .. " drives" .. (offline > 0 and (", " .. offline .. " storage offline") or ""), {
        { key = "name", label = "Drive", w = 10 }, { key = "media", label = "Media", w = 15 }, { key = "label", label = "Label" },
        { key = "use", label = "Used for", w = 24 }, { key = "files", label = "Files", w = 5, align = "right" },
        { key = "space", label = "Space", w = 18 }, { key = "bar", label = "Full", w = 15 },
    }, rows, "No disk drives found.")
end

function Panels:tab_airlocks(page, area)
    local c = page.c
    local al = self.con.ctx.airlock
    if not al or al.enabled == false then
        local ix, iy, iw, ih = page:card(area.x, area.y, area.w, area.h, "Airlocks", c.orange)
        if ix then page:wrapped(ix, iy, iw, ih, "Airlock control is off. Turn it on under Settings on the terminal.", c.muted) end
        return
    end
    local rows = {}
    for _, r in ipairs(self.data.air or {}) do
        if r.header then
            local g = r.group
            rows[#rows + 1] = {
                name = tostring(g.group), kind = "group", online = "",
                o2 = g.chamberLow and "VENTED" or (g.hasSensor and "chamber ok" or ""),
                state = tostring(g.sealed or 0) .. "/" .. tostring(g.total or 0) .. " sealed",
                color = g.chamberLow and c.bad or c.accent,
            }
        else
            local rec = r.rec
            local state = rec.role == "sensor" and "sensor" or (rec.locked and "locked" or (rec.sealed and "sealed" or "open"))
            rows[#rows + 1] = {
                name = (r.indent and "  " or "") .. tostring(r.indent and (rec.suffix or rec.name) or rec.name),
                kind = tostring(rec.role or "door"), online = rec.online and "online" or "offline",
                o2 = rec.oxygenated == false and "LOW" or "ok", state = state,
                colors = {
                    online = rec.online and c.ok or c.bad, o2 = rec.oxygenated == false and c.bad or c.ok,
                    state = rec.locked and c.orange or (rec.sealed and c.ok or c.warn),
                },
            }
        end
    end
    local foot = area.y + area.h - 1
    local list = { x = area.x, y = area.y, w = area.w, h = area.h - 2 }
    self:listCard(page, list, "Airlocks", c.orange, tostring(#rows), {
        { key = "name", label = "Name", w = 24 }, { key = "kind", label = "Kind", w = 10 }, { key = "online", label = "Link", w = 8 },
        { key = "o2", label = "Oxygen", w = 12 }, { key = "state", label = "State" },
    }, rows, "No airlock controllers have registered yet.")
    local label = self.logBusy and " Working... " or " Push logs "
    page:button(area.x, foot, #label, 1, label, self.logBusy and c.div or c.brand, c.text, "airlock:logs")
    local st = self.logStatus
    if st then page.s:field(area.x + #label + 1, foot, area.w - #label - 1, st.text, c[st.kind] or c.text, c.bg) end
end

function Panels:tab_log(page, area)
    local c = page.c
    local s = page.s
    local log = self.con.log
    local entries = log and log.last and log.last() or {}
    local ix, iy, iw, ih = page:card(area.x, area.y, area.w, area.h, "Event log", c.accent, #entries .. " entries")
    if not ix then return end
    local lines = {}
    local textW = math.max(4, iw - 17)
    local colorOf = { warn = c.warn, error = c.bad, debug = c.dim, info = c.text }
    for i = #entries, 1, -1 do
        local e = entries[i]
        local wrapped = util.wrapText(e.text or "", textW)
        for k, line in ipairs(wrapped) do
            lines[#lines + 1] = { s = k == 1 and util.fmtStamp(e.s) or "", level = k == 1 and string.upper(tostring(e.level)) or "", text = line, color = colorOf[e.level] or c.text }
        end
    end
    if #lines == 0 then
        page:wrapped(ix, iy, iw, ih, "The log is empty.", c.muted)
        return
    end
    local maxOff = math.max(0, #lines - ih)
    local off = util.clamp(self.offsets.log or 0, 0, maxOff)
    self.offsets.log = off
    self.maxOffset = maxOff
    self.pageRows = ih
    for r = 1, ih do
        local l = lines[off + r]
        if l then
            s:field(ix, iy + r - 1, 10, l.s, c.dim, c.inset)
            s:field(ix + 11, iy + r - 1, 5, l.level, l.color, c.inset)
            s:field(ix + 17, iy + r - 1, iw - 17, l.text, l.color, c.inset)
        end
    end
end

function Panels:setupDrive()
    local name = self:names().drive
    if not name then return nil end
    local ok, prov = pcall(need, "provision")
    if not ok then return nil end
    for _, d in ipairs(prov.drives()) do
        if d.name == name then return M.mediaInfo(d) end
    end
    return { name = name, kind = "missing" }
end

function Panels:defaultName(role)
    if role == "satellite" then return "" end
    local taken = {}
    for _, d in ipairs(self.data.devices or {}) do taken[tostring(d.name)] = true end
    local k = 1
    while taken[role .. k] do k = k + 1 end
    return role .. k
end

function Panels:roles()
    local out = {}
    for _, r in ipairs(M.ROLES) do
        if r.role ~= "satellite" or self.cfg.role == "main" then out[#out + 1] = r end
    end
    return out
end

local function wrapAt(page, x, y, w, maxRows, text, color)
    return page:wrapped(x, y, w, maxRows, text, color, page.c.bg)
end

function Panels:drawSetup()
    local s = self:surface("setup")
    if not s then return end
    local page = ui.page(s)
    self.setupPage = page
    local st = self.st
    if st.screen ~= "busy" and st.screen ~= "done" and st.screen ~= "part" and st.screen ~= "error" and self.con.locked then
        st.screen = "home"
        self:drawSetupLocked(page)
    else
        local fn = self["setup_" .. st.screen] or self.setup_home
        fn(self, page)
    end
    s:flush()
end

function Panels:mediaLines(info)
    local c = self.con.surf.c
    if not info then return "No drive", { { "No drive set", c.bad }, { "See Settings", c.muted } } end
    if info.kind == "missing" then return info.name, { { "Not attached", c.bad } } end
    if info.kind == "none" then return info.name, { { "Insert a", c.warn }, { "pocket PC", c.warn } } end
    if info.kind == "other" then return info.name, { { "Not a disk", c.bad } } end
    local lines = { { info.kind == "pocket" and "Pocket PC" or "Floppy disk", c.ok }, { util.fmtBytes(info.free) .. " free", c.muted } }
    if (info.files or 0) > 0 then lines[#lines + 1] = { info.files .. " file" .. (info.files == 1 and "" or "s") .. " on it", c.warn } end
    return info.name, lines
end

function Panels:drawMediaBox(page, y)
    local s, c = page.s, page.c
    local name, lines = self:mediaLines(self:setupDrive())
    s:rect(1, y, s.w, 5, c.inset)
    s:field(1, y, s.w, "MEDIA", c.muted, c.div, "center")
    s:field(2, y + 1, s.w - 2, name, c.text, c.inset, "center")
    for i = 1, math.min(3, #lines) do
        s:field(2, y + 1 + i, s.w - 2, lines[i][1], lines[i][2], c.inset, "center")
    end
    return y + 5
end

function Panels:drawSetupLocked(page)
    local s, c = page.s, page.c
    header(page, "Device Setup")
    local y = self:drawMediaBox(page, 3) + 1
    y = y + wrapAt(page, 2, y, s.w - 2, 4, "Console locked.", c.warn) + 1
    wrapAt(page, 2, y, s.w - 2, s.h - y, "Unlock the server terminal to set up devices here.", c.muted)
end

function Panels:setup_home(page)
    local s, c = page.s, page.c
    header(page, "Device Setup")
    local y = self:drawMediaBox(page, 3) + 1
    local roles = self:roles()
    local btnH = s.h >= 22 and (#roles >= 5 and 2 or 3) or 1
    for _, r in ipairs(roles) do
        if y + btnH - 1 > s.h - 1 then break end
        page:button(2, y, s.w - 2, btnH, r.label, c.brand, c.text, "role:" .. r.role)
        y = y + btnH + 1
    end
    if self.st.err and y <= s.h then
        wrapAt(page, 1, y, s.w, s.h - y + 1, self.st.err, c.bad)
    elseif y <= s.h then
        s:field(1, s.h, s.w, "Tap a role", c.dim, c.bg, "center")
    end
end

function Panels:setup_name(page)
    local s, c = page.s, page.c
    local st = self.st
    local isSat = st.role == "satellite"
    header(page, "New " .. (M.ROLE_TITLES[st.role] or st.role))
    s:field(1, 3, s.w, isSat and "Realm name:" or "Device name:", c.muted, c.bg)
    s:rect(1, 4, s.w, 1, c.field)
    local shown = st.name
    if #shown > s.w - 1 then shown = shown:sub(#shown - s.w + 2) end
    s:text(1, 4, shown .. "_", c.text, c.field)
    if st.err then
        s:field(1, 5, s.w, st.err, c.bad, c.bg)
    else
        s:field(1, 5, s.w, isSat and "A-Z 0-9 _" or "a-z 0-9 _ -", c.dim, c.bg)
    end
    local keyW = math.floor(s.w / 5)
    local keyH = s.h >= 24 and 2 or 1
    local y0 = 6
    for i, k in ipairs(M.NAME_KEYS) do
        local col = (i - 1) % 5
        local row = math.floor((i - 1) / 5)
        local label = k
        if #k == 1 and isSat then label = k:upper() end
        local bad = isSat and k == "-"
        local even = (col + row) % 2 == 0
        local bg = bad and c.bg or (even and colors.blue or colors.cyan)
        local fg = even and colors.white or colors.black
        if k == "DEL" then bg, fg = c.orange, colors.white end
        if k == "CLR" then bg, fg = c.bad, colors.white end
        if not s.isColor then bg, fg = c.inset, c.text end
        local x = 1 + col * keyW
        local y = y0 + row * keyH
        local w = col == 4 and (s.w - x + 1) or keyW
        if not bad then
            s:rect(x, y, w, keyH, bg)
            s:field(x, y + math.floor((keyH - 1) / 2), w, label, fg, bg, "center")
            page:hotspot(x, y, w, keyH, "key:" .. k)
        end
    end
    local by = y0 + 8 * keyH + (s.h - (y0 + 8 * keyH) >= 3 and 1 or 0)
    local bh = math.max(1, math.min(2, s.h - by + 1))
    local half = math.floor((s.w - 1) / 2)
    page:button(1, by, half, bh, "Back", M.BACK_BG, M.BACK_FG, "back")
    page:button(half + 2, by, s.w - half - 1, bh, "Next", c.ok, colors.black, "next")
end

function Panels:setup_confirm(page)
    local s, c = page.s, page.c
    local st = self.st
    header(page, "Confirm")
    local info = self:setupDrive()
    local y = 3
    local lines = {
        { st.role == "airlock" and "Airlock program" or (M.ROLE_TITLES[st.role] .. " " .. st.name), c.ok },
        { "onto the " .. M.mediaTitle(info and info.kind) .. " in " .. tostring(info and info.name) .. ".", c.text },
    }
    if info and (info.files or 0) > 0 then lines[#lines + 1] = { "This erases the " .. info.files .. " file(s) on it.", c.warn } end
    if info and info.kind == "floppy" and st.role == "satellite" then lines[#lines + 1] = { "A satellite needs 2 floppies.", c.warn } end
    if st.err then lines[#lines + 1] = { st.err, c.bad } end
    for _, l in ipairs(lines) do
        if y > s.h - 4 then break end
        y = y + wrapAt(page, 1, y, s.w, s.h - 4 - y + 1, l[1], l[2]) + 1
    end
    local half = math.floor((s.w - 1) / 2)
    page:button(1, s.h - 2, half, 3, "Back", M.BACK_BG, M.BACK_FG, "back")
    page:button(half + 2, s.h - 2, s.w - half - 1, 3, "Write", c.ok, colors.black, "write")
end

function Panels:setup_busy(page)
    local s, c = page.s, page.c
    header(page, "Writing")
    local dots = string.rep(".", math.floor(compat.now() * 2) % 4)
    local y = 4
    y = y + wrapAt(page, 1, y, s.w, 6, tostring(self.st.note or "Working") .. dots, c.text) + 1
    wrapAt(page, 1, y, s.w, s.h - y, "Leave the media in the drive until this is done.", c.muted)
end

function Panels:setup_part(page)
    local s, c = page.s, page.c
    local st = self.st
    header(page, "Disk " .. st.part .. " of " .. st.parts)
    local y = 3
    local text = "Take disk " .. (st.part - 1) .. " out and put an empty disk in for disk " .. st.part .. "."
    y = y + wrapAt(page, 1, y, s.w, 8, text, c.text) + 1
    if st.err then wrapAt(page, 1, y, s.w, s.h - 4 - y, st.err, c.bad) end
    local half = math.floor((s.w - 1) / 2)
    page:button(1, s.h - 2, half, 3, "Stop", c.bad, c.text, "stop")
    page:button(half + 2, s.h - 2, s.w - half - 1, 3, "Write", c.ok, colors.black, "writepart")
end

function Panels:setup_done(page)
    local s, c = page.s, page.c
    local st = self.st
    header(page, "Ready")
    local y = 3
    local steps = {
        { (M.ROLE_TITLES[st.role] or "") .. " " .. tostring(st.name) .. " is ready.", c.ok },
        { "1. Take it out of the drive.", c.text },
        { "2. Put it in a disk drive next to the new computer.", c.text },
        { "3. Reboot that computer.", c.text },
    }
    if st.role == "airlock" then
        steps = {
            { "Airlock disk ready.", c.ok },
            { "1. Put it in a drive by the airlock computer.", c.text },
            { "2. Reboot that computer.", c.text },
            { "3. Pick door or oxygen sensor.", c.text },
        }
    end
    if (st.parts or 1) > 1 then steps[#steps + 1] = { "The installer asks for the other disks.", c.muted } end
    for _, l in ipairs(steps) do
        if y > s.h - 4 then break end
        y = y + wrapAt(page, 1, y, s.w, s.h - 4 - y + 1, l[1], l[2]) + 1
    end
    page:button(1, s.h - 2, s.w, 3, "OK", c.brand, c.text, "home")
end

function Panels:setup_error(page)
    local s, c = page.s, page.c
    header(page, "Problem")
    wrapAt(page, 1, 3, s.w, s.h - 6, tostring(self.st.err or "Something went wrong."), c.bad)
    page:button(1, s.h - 2, s.w, 3, "OK", c.brand, c.text, "home")
end

function Panels:nameProblem()
    local st = self.st
    if st.role == "satellite" then
        local r = util.normRealm(st.name)
        if not r then return "Use A-Z 0-9 _" end
        if r == util.normRealm(self.cfg.realm) then return "That is this realm" end
        return nil, r
    end
    local n = util.normName(st.name)
    if not n then return "Start with a-z" end
    return nil, n
end

function Panels:mediaProblem()
    local info = self:setupDrive()
    if not info then return "No setup drive" end
    if info.kind == "missing" then return "Drive missing" end
    if info.kind == "none" then return "Insert media" end
    if info.kind == "other" then return "Not a disk" end
    return nil, info
end

function Panels:setupAction(act)
    local st = self.st
    if st.screen == "busy" then return end
    if act == "home" then
        self.st = { screen = "home" }
        return
    end
    if self.con.locked and st.screen ~= "part" then
        self.st = { screen = "home" }
        return
    end
    local role = act:match("^role:(.+)$")
    if role == "airlock" then
        self.st = { screen = "confirm", role = role, name = "airlock" }
        local merr = self:mediaProblem()
        if merr then
            self.st = { screen = "home", err = merr }
        end
        return
    elseif role then
        self.st = { screen = "name", role = role, name = self:defaultName(role) }
        return
    end
    local key = act:match("^key:(.+)$")
    if key then
        st.err = nil
        if key == "DEL" then
            st.name = st.name:sub(1, -2)
        elseif key == "CLR" then
            st.name = ""
        elseif #st.name < (st.role == "satellite" and 12 or 16) then
            st.name = st.name .. (st.role == "satellite" and key:upper() or key)
        end
        return
    end
    if act == "back" then
        if st.screen == "confirm" and st.role ~= "airlock" then
            st.screen = "name"
            st.err = nil
        else
            self.st = { screen = "home" }
        end
    elseif act == "next" then
        local err, name = self:nameProblem()
        if err then
            st.err = err
            return
        end
        st.name = name
        st.err = nil
        local merr = self:mediaProblem()
        if merr then
            st.err = merr
            return
        end
        st.screen = "confirm"
    elseif act == "write" then
        local merr, info = self:mediaProblem()
        if merr then
            st.err = merr
            return
        end
        self:startJob(function() return self:writeJob(st.role, st.name, info) end)
    elseif act == "writepart" then
        self:startJob(function() return self:partJob() end)
    elseif act == "stop" then
        local name = st.name
        self.st = { screen = "error", err = "The disk set for " .. tostring(name) .. " is incomplete. Remove the device on the terminal and set it up again." }
        self.con:audit("provision", name, "incomplete set", false)
    end
end

function Panels:startJob(fn)
    local st = self.st
    if self.con.provBusy then
        st.err = "The terminal is writing a disk. Try again soon."
        return
    end
    self.con.provBusy = "setup"
    st.err = nil
    st.back = st.screen
    st.screen = "busy"
    st.note = "Working"
    local me = self
    local function finish(ok, res)
        me.con.provBusy = nil
        if not ok then
            st.screen = "error"
            st.err = tostring(res)
        end
        os.queueEvent("zn_panel")
    end
    if self.n and self.n.running then
        self.n:spawn(function() finish(pcall(fn)) end, "setup-write")
    else
        finish(pcall(fn))
    end
end

function Panels:writeJob(role, name, info)
    local st = self.st
    local srv = self.con.ctx.server
    local prov = need("provision")
    if role == "airlock" then
        st.note = "Writing the airlock program"
        local ok, res = prov.writeAirlock(info.name, { wipe = true, key = self.con:airlockKey() })
        self.con:audit("provision", "airlock", ok and (info.name .. " (setup monitor)") or tostring(res), ok and true or false)
        if not ok then
            st.screen = "error"
            st.err = "Could not write: " .. tostring(res)
            return
        end
        st.parts = 1
        st.drive = info.name
        self.drivesAt = -100
        st.screen = "done"
        return
    end
    st.note = "Creating keys"
    local dcfg, err = srv:provision(role, name)
    if type(dcfg) ~= "table" then
        self.con:audit("provision", name, tostring(err), false)
        local sui = need("serverui")
        st.screen = "error"
        st.err = (sui.ERR_TEXT and sui.ERR_TEXT[err]) or tostring(err)
        return
    end
    st.note = "Writing " .. M.ROLE_TITLES[role] .. " " .. name
    local ok, res = prov.writeDisk(info.name, dcfg, { wipe = true })
    if not ok then
        if role ~= "satellite" then pcall(srv.removeDevice, srv, name) end
        self.con:audit("provision", name, tostring(res), false)
        st.screen = "error"
        st.err = "Could not write: " .. tostring(res)
        return
    end
    st.plan = res.plan
    st.parts = res.parts or 1
    st.drive = info.name
    self.drivesAt = -100
    if st.parts > 1 then
        st.part = 2
        st.screen = "part"
        return
    end
    self.con:audit("provision", name, role .. " on " .. info.name .. " (setup monitor)", true)
    st.screen = "done"
end

function Panels:partJob()
    local st = self.st
    local prov = need("provision")
    st.note = "Writing disk " .. st.part .. " of " .. st.parts
    local ok, err = prov.writePart(st.drive, st.plan, st.part, { wipe = true })
    if not ok then
        st.screen = "part"
        st.err = tostring(err)
        return
    end
    st.err = nil
    if st.part < st.parts then
        st.part = st.part + 1
        st.screen = "part"
        return
    end
    self.con:audit("provision", st.name, st.role .. " on " .. st.drive .. " (setup monitor)", true)
    st.screen = "done"
end

M.Panels = Panels

return M
