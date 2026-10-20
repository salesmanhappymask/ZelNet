local need = ...
local util = need("util")
local compat = need("compat")
local ui = need("ui")
local uichat = need("uichat")
local version = need("version")

local M = {}

M.PING_TIMEOUT = 10
M.LOG_LINES = 200

M.LIBRARY = {
    { text = "Programs on this computer load ZelNet as a library:" },
    { text = "local zn = dofile(\"/zelnet\")", code = true },
    { text = "assert(zn.open())", code = true },
    { text = "zn.run(function()", code = true },
    { text = "  zn.publish(\"power.mars\", 42)", code = true },
    { text = "  print(zn.request(\"MARS\", \"echo\", 1))", code = true },
    { text = "end)", code = true },
    { text = "os.loadAPI(\"/zelnet\") gives the global table zelnet." },
    { text = "Exit with Ctrl, then run your program, or start it from /startup." },
}

local View = {}
View.__index = View

function M.new(n, opts)
    opts = opts or {}
    local self = setmetatable({}, View)
    self.n = n
    self.mode = opts.mode or ((n.role == "endpoint") and "endpoint" or "router")
    self.surf = opts.surface or ui.surface(term)
    self.allowExit = opts.allowExit ~= false
    self.tab = "status"
    self.scrolls = {}
    self.logOffset = 0
    self.unseen = 0
    self.pingState = nil
    self.active = false
    self.dirty = true
    self.page = nil
    return self
end

function View:tabs()
    local t = {
        { id = "status", label = "Status" },
        { id = "links", label = "Links" },
        { id = "neighbors", label = "Nodes" },
        { id = "log", label = "Log" },
    }
    if self.mode == "endpoint" then t[#t + 1] = { id = "library", label = "Library" } end
    return t
end

function View:tabIndex()
    for i, t in ipairs(self:tabs()) do
        if t.id == self.tab then return i end
    end
    return 1
end

function View:setTab(i)
    local list = self:tabs()
    i = ((i - 1) % #list) + 1
    self.tab = list[i].id
    self.dirty = true
end

function View:attachLog()
    local log = self.n.log
    if not log or not log.listen or self.logHooked then return end
    self.logHooked = true
    log.listen(function(entry)
        if not self.active then return end
        if self.logOffset > 0 then
            self.unseen = self.unseen + 1
            self.logOffset = self.logOffset + self:entryRows(entry)
        end
        self.dirty = true
        if not self.logPending then
            self.logPending = true
            os.queueEvent("zn_ui_log")
        end
    end)
end

function View:entryRows(entry)
    local w = self.logWidth
    if not w or type(entry) ~= "table" then return 1 end
    return #uichat.wrap(entry.text, w - 8, w - 8)
end

function View:startPing()
    if self.pingState and self.pingState.running then return end
    local n = self.n
    local dst = n.realm
    self.pingState = { running = true, text = "pinging " .. tostring(dst) .. "..." }
    self.dirty = true
    n:spawn(function()
        local ok, rtt, err = pcall(n.ping, n, dst, M.PING_TIMEOUT)
        local st
        if ok and rtt then
            st = { ok = true, text = util.fmtFixed(rtt, 2) .. " s round trip" }
            n.log.info("ping " .. tostring(dst) .. ": " .. util.fmtFixed(rtt, 2) .. " s")
        else
            local why = ok and tostring(err or "timeout") or tostring(rtt)
            st = { ok = false, text = "failed: " .. why }
            n.log.warn("ping " .. tostring(dst) .. " failed: " .. why)
        end
        self.pingState = st
        self.dirty = true
        os.queueEvent("zn_ui_ping")
    end, "routerui-ping")
end

function View:neighborRows()
    local n = self.n
    local now = compat.now()
    local out = {}
    local ids = {}
    for id in pairs(n.cands or {}) do ids[#ids + 1] = id end
    table.sort(ids, function(a, b) return tostring(a) < tostring(b) end)
    for _, id in ipairs(ids) do
        local cnd = n.cands[id]
        local isParent = n.parent and n.parent.id == id
        out[#out + 1] = {
            id = id, parent = isParent, hops = cnd.hops, seq = cnd.seq, link = cnd.link,
            age = now - (cnd.t or now), root = cnd.root,
        }
    end
    return out
end

function View:downCount()
    local count = 0
    for _ in pairs(self.n.downRoutes or {}) do count = count + 1 end
    return count
end

function View:statusRows(c)
    local n = self.n
    local st = n:status()
    local k = st.counters or {}
    local rows = {}
    rows[#rows + 1] = { "Realm", tostring(st.realm) }
    rows[#rows + 1] = { "Address", tostring(st.address) .. (st.name and (" (" .. st.name .. ")") or "") }
    rows[#rows + 1] = { "State", st.connected and "connected" or (st.parent and "waiting for server" or "searching"), st.connected and c.ok or c.warn }
    local parentText = "none"
    if st.parent then
        parentText = "computer " .. tostring(st.parent) .. ", " .. tostring(st.hops) .. " hop" .. (st.hops == 1 and "" or "s")
        if n.parent and n.parent.link then parentText = parentText .. " via " .. tostring(n.parent.link) end
    end
    rows[#rows + 1] = { "Parent", parentText, st.parent and c.text or c.warn }
    rows[#rows + 1] = { "Server", st.serverId and ("computer " .. tostring(st.serverId) .. (n.serverProg and (", v" .. tostring(n.serverProg)) or "")) or "unknown" }
    local open = 0
    for _, l in ipairs(st.links or {}) do if l.open then open = open + 1 end end
    rows[#rows + 1] = { "Links", open .. " open, " .. #self:neighborRows() .. " beacon source" .. (#self:neighborRows() == 1 and "" or "s"), open > 0 and c.text or c.bad }
    if self.mode == "router" then
        rows[#rows + 1] = { "Forwarded", tostring(k.forwarded or 0) .. " packets, " .. self:downCount() .. " routes below" }
    end
    rows[#rows + 1] = { "Packets", "sent " .. tostring(k.sent or 0) .. ", got " .. tostring(k.delivered or 0) .. ", dropped " .. tostring(k.dropped or 0) }
    if (k.badMac or 0) > 0 then rows[#rows + 1] = { "Rejected", tostring(k.badMac) .. " bad MAC", c.bad } end
    rows[#rows + 1] = { "Uptime", util.fmtDuration(st.uptime or 0) }
    if self.pingState then
        rows[#rows + 1] = { "Ping", self.pingState.text, self.pingState.running and c.muted or (self.pingState.ok and c.ok or c.bad) }
    end
    rows[#rows + 1] = { "Version", tostring(st.prog or version.program) }
    return rows
end

function View:logLines(width, c)
    local entries = self.n.log and self.n.log.last and self.n.log.last(M.LOG_LINES) or {}
    local out = {}
    local colorsByLevel = { error = c.bad, warn = c.warn, info = c.text, debug = c.dim }
    for _, e in ipairs(entries) do
        local _, hm = uichat.splitStamp(e.s)
        local head = "[" .. (hm or "??:??") .. "] "
        local wrapped = uichat.wrap(e.text, width - #head, width - #head)
        for i, l in ipairs(wrapped) do
            out[#out + 1] = { head = i == 1 and head or string.rep(" ", #head), text = l, color = colorsByLevel[e.level] or c.text }
        end
    end
    return out
end

function View:drawRows(page, rows, x, y, w, h)
    local key = self.tab
    local maxOff = math.max(0, #rows - h)
    local off = util.clamp(self.scrolls[key] or 0, 0, maxOff)
    self.scrolls[key] = off
    for i = 1, h do
        local r = rows[off + i]
        if r then
            if r.kv then
                page:kv(x, y + i - 1, w, r[1], r[2], r[3])
            else
                page.s:field(x, y + i - 1, w, r.text, r.color or page.c.text, page.c.inset)
            end
        end
    end
    if #rows > h then
        local pos = h > 1 and math.floor((h - 1) * off / math.max(1, maxOff)) or 0
        page.s:rect(x + w, y, 1, h, page.c.div)
        page.s:rect(x + w, y + pos, 1, 1, page.c.accent)
    end
end

function View:drawStatus(page, x, y, w, h)
    local c = page.c
    local rows = {}
    for _, r in ipairs(self:statusRows(c)) do rows[#rows + 1] = { kv = true, r[1], r[2], r[3] } end
    if self.mode == "endpoint" then
        rows[#rows + 1] = { text = "" }
        rows[#rows + 1] = { text = "Library: local zn = dofile(\"/zelnet\")", color = c.accent }
        rows[#rows + 1] = { text = "See the Library tab for an example.", color = c.muted }
    end
    if #rows < h - 2 then
        rows[#rows + 1] = { text = "" }
        local lines = self:logLines(w, c)
        local room = h - #rows
        for i = math.max(1, #lines - room + 1), #lines do
            local l = lines[i]
            rows[#rows + 1] = { text = l.head .. l.text, color = c.muted }
        end
    end
    self:drawRows(page, rows, x, y, w - 1, h)
end

function View:drawLinks(page, x, y, w, h)
    local c = page.c
    local rows = {}
    local st = self.n:status()
    for _, l in ipairs(st.links or {}) do
        local kind = l.kind == "bitnet" and "BitNet" or (l.wireless and "wireless" or "wired")
        rows[#rows + 1] = { kv = true, tostring(l.id) .. " " .. kind, (l.open and "" or "closed ") .. "tx " .. tostring(l.tx or 0) .. " rx " .. tostring(l.rx or 0), l.open and c.text or c.bad }
    end
    if #rows == 0 then rows[1] = { text = "No modem or BitNet tower attached.", color = c.bad } end
    self:drawRows(page, rows, x, y, w - 1, h)
end

function View:drawNeighbors(page, x, y, w, h)
    local c = page.c
    local rows = {}
    for _, nb in ipairs(self:neighborRows()) do
        local text = (nb.parent and "* " or "  ") .. "computer " .. tostring(nb.id) .. ", hops " .. tostring(nb.hops) .. ", " .. tostring(nb.link or "?")
        rows[#rows + 1] = { kv = true, text, util.fmtDuration(nb.age) .. " ago", nb.parent and c.ok or c.text }
    end
    if #rows == 0 then rows[1] = { text = "No beacons heard yet. Is a server or router in range?", color = c.warn } end
    if self.mode == "router" then
        rows[#rows + 1] = { text = "" }
        rows[#rows + 1] = { kv = true, "Downstream routes", tostring(self:downCount()) }
    end
    rows[#rows + 1] = { text = "* = parent (path to the server)", color = c.muted }
    self:drawRows(page, rows, x, y, w - 1, h)
end

function View:drawLog(page, x, y, w, h)
    local c = page.c
    self.logWidth = w - 1
    local lines = self:logLines(w - 1, c)
    local maxOff = math.max(0, #lines - h)
    self.logOffset = util.clamp(self.logOffset, 0, maxOff)
    if self.logOffset == 0 then self.unseen = 0 end
    local last = #lines - self.logOffset
    for i = 1, h do
        local l = lines[last - h + i]
        if l then
            page.s:text(x, y + i - 1, l.head, c.dim, c.inset)
            page.s:text(x + #l.head, y + i - 1, util.fitText(l.text, math.max(0, w - 1 - #l.head)), l.color, c.inset)
        end
    end
    if #lines == 0 then page.s:field(x, y, w - 1, "The log is empty.", c.muted, c.inset) end
    if #lines > h then
        local pos = h > 1 and math.floor((h - 1) * (maxOff - self.logOffset) / math.max(1, maxOff)) or 0
        page.s:rect(x + w - 1, y, 1, h, c.div)
        page.s:rect(x + w - 1, y + pos, 1, 1, c.accent)
    end
end

function View:drawLibrary(page, x, y, w, h)
    local c = page.c
    local rows = {}
    for _, line in ipairs(M.LIBRARY) do
        if line.code then
            rows[#rows + 1] = { text = line.text, color = c.accent }
        else
            for _, l in ipairs(uichat.wrap(line.text, w - 1, w - 1)) do
                rows[#rows + 1] = { text = l, color = c.text }
            end
        end
    end
    self:drawRows(page, rows, x, y, w - 1, h)
end

function View:draw()
    local s = self.surf
    local page = ui.page(s)
    self.page = page
    local c = page.c
    local title = self.mode == "endpoint" and "ZelNet Endpoint" or "ZelNet Router"
    page:header(title, tostring(self.n.address))
    page:tabs(2, 3, s.w - 2, self:tabs(), self.tab)
    local right
    if self.tab == "log" and self.unseen > 0 then right = self.unseen .. " new" end
    local label
    for _, t in ipairs(self:tabs()) do if t.id == self.tab then label = t.label end end
    local ix, iy, iw, ih = page:card(2, 5, s.w - 2, math.max(4, s.h - 4), label, self.n:isConnected() and c.accent or c.warn, right)
    if not ix then
        s:flush()
        self.dirty = false
        return
    end
    local bodyH = math.max(1, ih - 1)
    if self.tab == "status" then
        self:drawStatus(page, ix, iy, iw, bodyH)
    elseif self.tab == "links" then
        self:drawLinks(page, ix, iy, iw, bodyH)
    elseif self.tab == "neighbors" then
        self:drawNeighbors(page, ix, iy, iw, bodyH)
    elseif self.tab == "log" then
        self:drawLog(page, ix, iy, iw, bodyH)
    elseif self.tab == "library" then
        self:drawLibrary(page, ix, iy, iw, bodyH)
    end
    local fy = iy + ih - 1
    local left = self.allowExit and { label = "Exit", action = "exit" } or nil
    ui.footerButtons(page, ix, fy, iw, left, { label = "Ping server", action = "ping" })
    local hintX = ix + (left and 7 or 0)
    local hintW = iw - (left and 7 or 0) - 14
    if hintW > 8 then
        local hint = hintW >= 18 and "Tab: view  P: ping" or "Tab: view"
        s:field(hintX, fy, hintW, hint, c.dim, c.inset, "center")
    end
    s:flush()
    self.dirty = false
end

function View:scroll(delta)
    if self.tab == "log" then
        self.logOffset = math.max(0, self.logOffset + delta)
        if self.logOffset == 0 then self.unseen = 0 end
    else
        self.scrolls[self.tab] = math.max(0, (self.scrolls[self.tab] or 0) - delta)
    end
    self.dirty = true
end

function View:pageSize()
    return math.max(1, self.surf.h - 9)
end

function View:confirmExit()
    local text
    if self.mode == "router" then
        text = "Stop the router and exit to the shell? This computer stops relaying packets until ZelNet runs again."
    else
        text = "Exit to the shell? Programs that use ZelNet open their own connection with zn.open()."
    end
    local ok = ui.confirm(self.surf, "Exit", text, { yes = "Exit", no = "Stay", danger = self.mode == "router" })
    self.dirty = true
    return ok
end

function View:onKey(k)
    if ui.isCtrl(k) then
        if self.allowExit and self:confirmExit() then return "exit" end
        return nil
    end
    if k == keys.tab or k == keys.right then
        self:setTab(self:tabIndex() + 1)
    elseif k == keys.left then
        self:setTab(self:tabIndex() - 1)
    elseif k == keys.up then
        self:scroll(1)
    elseif k == keys.down then
        self:scroll(-1)
    elseif keys.pageUp and k == keys.pageUp then
        self:scroll(self:pageSize())
    elseif keys.pageDown and k == keys.pageDown then
        self:scroll(-self:pageSize())
    elseif keys["end"] and k == keys["end"] then
        self.logOffset = 0
        self.scrolls[self.tab] = 1000000
        self.dirty = true
    elseif keys.home and k == keys.home then
        self.logOffset = 1000000
        self.scrolls[self.tab] = 0
        self.dirty = true
    elseif k == keys.enter then
        self:startPing()
    end
    return nil
end

function View:onChar(ch)
    local num = tonumber(ch)
    if num and self:tabs()[num] then
        self:setTab(num)
    elseif ch == "p" or ch == "P" then
        self:startPing()
    end
end

function View:handle(ev, a, b, c)
    if ev == "key" then return self:onKey(a) end
    if ev == "char" then
        self:onChar(a)
        return nil
    end
    if ev == "zn_ui_log" then
        self.logPending = false
        return nil
    end
    if ev == "term_resize" or (ev == "monitor_resize" and a == self.surf.name) then
        self.surf:resize()
        self.dirty = true
        return nil
    end
    local px, py, kind, btn = self.surf:pointer(ev, a, b, c)
    if px then
        if kind == "scroll" then
            self:scroll(-(btn or 0))
        else
            local act = self.page and self.page:hit(px, py)
            if act == "ping" then
                self:startPing()
            elseif act == "exit" then
                if self:confirmExit() then return "exit" end
            elseif act then
                local id = tostring(act):match("^tab:(.+)$")
                if id then
                    self.tab = id
                    self.dirty = true
                end
            end
        end
    end
    return nil
end

function View:run()
    self.active = true
    self:attachLog()
    local timer = os.startTimer(1)
    local ok, err = pcall(function()
        while true do
            if self.dirty then self:draw() end
            local ev, a, b, c = os.pullEvent()
            if ev == "timer" and a == timer then
                timer = os.startTimer(1)
                self.dirty = true
            elseif self:handle(ev, a, b, c) == "exit" then
                return
            end
        end
    end)
    self.active = false
    local t = self.surf.target
    if not self.surf.isMonitor and t.clear then
        if t.setBackgroundColor then t.setBackgroundColor(colors.black) end
        if t.setTextColor then t.setTextColor(colors.white) end
        t.clear()
        if t.setCursorPos then t.setCursorPos(1, 1) end
    end
    if not ok then error(err, 0) end
end

M.View = View

function M.run(n, opts)
    local v = M.new(n, opts)
    if n.running then return v:run() end
    return n:loop(function() return v:run() end)
end

return M
