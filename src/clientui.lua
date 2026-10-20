local need = ...
local util = need("util")
local compat = need("compat")
local crypto = need("crypto")
local ui = need("ui")
local uichat = need("uichat")
local version = need("version")

local M = {}

M.PORT = "tekmail"
M.TIMEOUT = 35
M.POLL = 10
M.HELLO_RETRY = 15
M.TEXT_MAX = 1000
M.CHAT_MAX = 200
M.PASS_MIN = 4
M.NOTES_MAX = 30
M.PREVIEW = 60
M.PULSE = 0.3

M.MSG = {
    timeout = "The server did not answer. Check Network status and try again.",
    no_route = "No route to the server right now.",
    unknown_node = "The server is not known on this network.",
    denied = "Access denied.",
    too_large = "That request is too large.",
    bad_request = "Bad request.",
    bad_token = "Your session has expired. Please log in again.",
    unknown_user = "No such user.",
    taken = "That name is already taken.",
    bad_name = "Names are 3 to 16 characters of a-z, 0-9 and _, starting with a letter.",
    weak_password = "Passwords need at least 4 characters.",
    too_long = "That text is too long.",
    offline = "That realm cannot be reached right now.",
    storage = "Server storage is unavailable.",
    cancelled = "Cancelled.",
}

function M.errText(code)
    if type(code) ~= "string" then return "Unknown error." end
    if M.MSG[code] then return M.MSG[code] end
    if code:sub(1, 8) == "remote: " then return "Server error: " .. code:sub(9) end
    return "Error: " .. code
end

function M.checkName(v)
    local name = util.trim(tostring(v or "")):lower()
    if #name < 3 or #name > 16 or not name:match("^[a-z][a-z0-9_]*$") then
        return false, M.MSG.bad_name
    end
    return true, name
end

function M.isServerAddr(src)
    return type(src) == "string" and src ~= "" and not src:find(":", 1, true)
end

function M.list(v)
    if type(v) ~= "table" then return {} end
    local out = {}
    for _, item in ipairs(v) do
        if type(item) == "table" then out[#out + 1] = item end
    end
    return out
end

function M.str(v, default)
    if type(v) == "string" or type(v) == "number" then return tostring(v) end
    return default
end

function M.preview(text, n)
    local s = util.sanitize(tostring(text or "")):gsub("%s+", " ")
    s = util.trim(s)
    return util.fitText(s, n or M.PREVIEW)
end

function M.newMid(k)
    return crypto.randHex(8) .. "-" .. tostring(k % 100000)
end

local App = {}
App.__index = App

function M.new(n, opts)
    opts = opts or {}
    local self = setmetatable({}, App)
    self.n = n
    self.cfg = n.cfg or {}
    self.realm = self.cfg.realm or n.realm
    self.server = opts.server or self.realm
    self.surf = opts.surface or ui.surface(term)
    self.results = {}
    self.dropped = {}
    self.jobSeq = 0
    self.notes = {}
    self.noteSeq = 0
    self.session = nil
    self.info = nil
    self.notice = nil
    self.pulseSide = opts.pulseSide or self.cfg.mailPulseSide
    return self
end

function App:job(fn, name, forget)
    self.jobSeq = self.jobSeq + 1
    local id = self.jobSeq
    local sess = self.session
    if forget then self.dropped[id] = true end
    self.n:spawn(function()
        local res = { pcall(fn) }
        if self.dropped[id] then
            self.dropped[id] = nil
            return
        end
        self.results[id] = { res = res, sess = sess }
        os.queueEvent("tm_reply", id)
    end, name or "tekmail-job")
    return id
end

function App:async(body, opts)
    opts = opts or {}
    if opts.auth ~= false and self.session then body.token = self.session.token end
    local n, dst = self.n, self.server
    local timeout, retries = opts.timeout or M.TIMEOUT, opts.retries or 0
    return self:job(function()
        return n:request(dst, M.PORT, body, timeout, { retries = retries })
    end, "tekmail:" .. tostring(body.op), opts.forget)
end

function App:ready(id)
    return id ~= nil and self.results[id] ~= nil
end

function App:forget(id)
    if id == nil then return end
    if self.results[id] then
        self.results[id] = nil
    else
        self.dropped[id] = true
    end
end

function App:takeRaw(id)
    local r = self.results[id]
    if not r then return nil end
    self.results[id] = nil
    return r
end

function App:take(id)
    local r = self:takeRaw(id)
    if not r then return nil, "No answer yet.", "pending" end
    if not r.res[1] then return nil, "Error: " .. tostring(r.res[2]), "error" end
    local reply, err = r.res[2], r.res[3]
    if type(reply) ~= "table" then return nil, M.errText(err), err or "timeout" end
    if type(err) == "string" and not M.isServerAddr(err) then return nil, M.errText("denied"), "denied" end
    if reply.ok then return reply end
    if reply.err == "bad_token" and r.sess ~= nil and r.sess == self.session then self:expire() end
    return nil, util.sanitize(reply.msg or M.errText(reply.err)), reply.err or "error"
end

function App:wait(id, title, text)
    ui.busy(self.surf, title or "TekMail", (text or "Contacting the server...") .. " (Ctrl: cancel)")
    while not self:ready(id) do
        local ev, a = os.pullEvent()
        if ev == "key" and ui.isCtrl(a) then
            self:forget(id)
            return false
        end
    end
    return true
end

function App:call(body, title, text, opts)
    local id = self:async(body, opts)
    if not self:wait(id, title, text) then return nil, M.MSG.cancelled, "cancelled" end
    return self:take(id)
end

function App:expire()
    self.session = nil
    self.notice = M.MSG.bad_token
end

function App:onPush(msg)
    if type(msg) ~= "table" or not M.isServerAddr(msg.src) then return end
    local d = msg.data
    if type(d) ~= "table" or d.op ~= "notify" or not self.session then return end
    local kind = d.kind == "chat" and "chat" or "mail"
    self.noteSeq = self.noteSeq + 1
    local note = {
        seq = self.noteSeq, kind = kind, from = type(d.from) == "string" and util.sanitize(d.from) or nil,
        room = type(d.room) == "string" and d.room or nil, text = M.preview(M.str(d.text, ""), M.PREVIEW),
        failed = d.failed and true or nil, sess = self.session,
    }
    self.notes[#self.notes + 1] = note
    while #self.notes > M.NOTES_MAX do table.remove(self.notes, 1) end
    if kind == "mail" and not note.failed then
        self.session.unread = (self.session.unread or 0) + 1
        self.session.unreadStale = true
    end
    os.queueEvent("tm_notify", kind)
    if kind == "mail" and not note.failed then self:pulse() end
end

function App:pulse()
    local side = self.pulseSide
    local rsApi = rawget(_G, "redstone") or rawget(_G, "rs")
    if type(side) ~= "string" or type(rsApi) ~= "table" or not rsApi.setOutput then return end
    pcall(rsApi.setOutput, side, true)
    sleep(M.PULSE)
    pcall(rsApi.setOutput, side, false)
end

function App:notesAfter(cursor)
    local out = {}
    for _, note in ipairs(self.notes) do
        if note.seq > cursor and note.sess == self.session then out[#out + 1] = note end
    end
    return out, self.noteSeq
end

function App:beginSession(reply, typed)
    local user = type(reply.user) == "string" and util.sanitize(reply.user):lower() or util.trim(typed):lower()
    self.session = {
        token = reply.token,
        user = user,
        display = util.sanitize(M.str(reply.display, user)),
        admin = reply.admin == true,
        home = M.str(reply.home, self.realm),
        unread = 0,
        unreadStale = true,
    }
    self.notice = nil
end

function App:endSession()
    local s = self.session
    if not s then return end
    self:async({ op = "logout" }, { forget = true, timeout = 10 })
    self.session = nil
    self.notes = {}
end

function App:connectionText()
    local n = self.n
    local ok = n.isConnected and n:isConnected()
    if ok then return "connected", self.surf.c.ok end
    if n.parent then return "contacting server", self.surf.c.warn end
    return "searching for network", self.surf.c.warn
end

function App:splitMenu(o)
    local surf = self.surf
    local sel = o.selected or 1
    local offset = 0
    local timer = os.startTimer(o.interval or 1)
    while true do
        if o.update then
            local r = o.update()
            if r ~= nil then return r end
        end
        local items = o.items()
        if sel > #items then sel = #items end
        if sel < 1 then sel = 1 end
        local page = ui.page(surf)
        local c = page.c
        local ix, iy, iw, ih = page:container(o.title, o.subtitle)
        local split = iw >= 34
        local splitX = ix + iw
        if split then
            splitX = util.clamp(ix + math.floor(iw / 2) - 2, ix + 14, ix + iw - 12)
            surf:rect(splitX, iy, 1, ih, c.div)
        end
        local leftW = split and (splitX - ix - 1) or iw
        local avail = math.max(1, ih - 1)
        local spacing, rows = 2, #items
        if #items * 2 - 1 > avail then spacing, rows = 1, avail end
        if sel > offset + rows then offset = sel - rows end
        if sel <= offset then offset = sel - 1 end
        offset = util.clamp(offset, 0, math.max(0, #items - rows))
        for r = 1, rows do
            local i = offset + r
            local it = items[i]
            if it then
                local y = iy + (r - 1) * spacing
                local on = i == sel
                local bg = on and c.selected or (it.bg or c.good)
                local label = (on and not surf.isColor and ">" or "") .. (i <= 9 and (i .. " ") or "") .. it.label
                surf:field(ix, y, leftW - 1, label, c.text, bg)
                if it.badge then
                    local b = util.fitText(it.badge, math.max(0, leftW - 4))
                    surf:text(ix + leftW - 1 - #b, y, b, it.badgeColor or c.warn, bg)
                end
                page:hotspot(ix, y, leftW, 1, "item:" .. i)
            end
        end
        if offset > 0 then surf:text(ix + leftW - 1, iy, "^", c.bad, c.inset) end
        if offset + rows < #items then surf:text(ix + leftW - 1, iy + (rows - 1) * spacing, "v", c.bad, c.inset) end
        if split and o.help then
            local rx = splitX + 2
            local rw = ix + iw - rx
            local y = iy
            for _, part in ipairs(o.help()) do
                if y > iy + ih - 1 then break end
                local text, color = part, c.text
                if type(part) == "table" then text, color = part.text, part.color or c.text end
                if text == "" then
                    y = y + 1
                else
                    y = y + page:wrapped(rx, y, rw, iy + ih - y, text, color, c.inset)
                end
            end
        end
        local hint = o.hint or ((o.back == false) and "Arrows, Enter" or "Ctrl: back")
        surf:field(ix, iy + ih - 1, leftW - 1, hint, c.dim, c.inset)
        surf:flush()
        local ev, a, b, cc = os.pullEvent()
        local px, py, kind, btn = surf:pointer(ev, a, b, cc)
        local pick
        if px then
            if kind == "scroll" then
                sel = util.clamp(sel + (btn or 0), 1, math.max(1, #items))
            else
                local act = page:hit(px, py)
                pick = act and tonumber(tostring(act):match("^item:(%d+)$"))
            end
        elseif ev == "key" then
            if ui.isCtrl(a) and o.back ~= false then return nil end
            if a == keys.up then
                sel = sel > 1 and sel - 1 or #items
            elseif a == keys.down or a == keys.tab then
                sel = sel < #items and sel + 1 or 1
            elseif a == keys.enter then
                pick = sel
            end
        elseif ev == "char" then
            local num = tonumber(a)
            if num and items[num] then pick = num end
        elseif ev == "timer" and a == timer then
            timer = os.startTimer(o.interval or 1)
            if o.tick then o.tick() end
        elseif o.onEvent then
            local r = o.onEvent(ev, a, b, cc)
            if r ~= nil then return r end
        end
        if pick and items[pick] then
            sel = pick
            o.selected = pick
            return pick, items[pick]
        end
    end
end

function App:run()
    self.n:listen(M.PORT, function(msg) self:onPush(msg) end)
    self.helloId = self:async({ op = "hello" }, { auth = false, timeout = 10, retries = 0 })
    self.helloAt = compat.now()
    local ok, err = pcall(self.welcome, self)
    self:endSession()
    self.n:unlisten(M.PORT)
    self:clear()
    if not ok then error(err, 0) end
end

function App:clear()
    local t = self.surf.target
    if self.surf.isMonitor then return end
    if t.setCursorBlink then t.setCursorBlink(false) end
    if t.setBackgroundColor then t.setBackgroundColor(colors.black) end
    if t.setTextColor then t.setTextColor(colors.white) end
    if t.clear then t.clear() end
    if t.setCursorPos then t.setCursorPos(1, 1) end
end

function App:pollHello()
    if self:ready(self.helloId) then
        local reply = self:take(self.helloId)
        self.helloId = nil
        if reply then self.info = reply end
        self.helloAt = compat.now()
        return true
    end
    if not self.info and not self.helloId and compat.now() - (self.helloAt or 0) >= M.HELLO_RETRY then
        self.helloId = self:async({ op = "hello" }, { auth = false, timeout = 10, retries = 0 })
        self.helloAt = compat.now()
    end
    return false
end

function App:welcomeHelp()
    local c = self.surf.c
    local out = {}
    if self.notice then
        out[#out + 1] = { text = self.notice, color = c.warn }
        out[#out + 1] = ""
    end
    out[#out + 1] = "Welcome to TekMail, mail, direct messages and chat across every realm of the network."
    out[#out + 1] = ""
    if self.info and self.info.motd then
        out[#out + 1] = { text = util.sanitize(self.info.motd), color = c.accent }
        out[#out + 1] = ""
    end
    local state, color = self:connectionText()
    out[#out + 1] = { text = "Server " .. tostring(self.server) .. ": " .. state, color = color }
    out[#out + 1] = { text = "New here? Create an account first.", color = c.muted }
    return out
end

function App:welcome()
    local items = {
        { label = "Login", key = "login" },
        { label = "Create account", key = "create" },
        { label = "Network status", key = "status" },
        { label = "Ping server", key = "ping" },
        { label = "Exit", key = "exit", bg = self.surf.c.div },
    }
    local menu = {
        title = "TekMail " .. version.program, back = false, hint = "Arrows, 1-5, Enter",
        items = function() return items end,
        help = function() return self:welcomeHelp() end,
        update = function()
            self:pollHello()
            return nil
        end,
    }
    while true do
        local _, it = self:splitMenu(menu)
        local key = it and it.key
        if key == "exit" then return end
        if key == "login" or key == "create" then
            if self:loginForm(key == "create") then self:mainMenu() end
            self:endSession()
        elseif key == "status" then
            self:networkStatus()
        elseif key == "ping" then
            self:pingServer()
        end
    end
end

function App:loginForm(create)
    local title = create and "Create Account" or "Login"
    local typed, errMsg = "", nil
    while true do
        local fields = {
            { label = "Username:", key = "user", value = typed, required = true, maxLen = 16,
              hint = create and "3 to 16 of a-z 0-9 _" or nil, validate = function(v) return M.checkName(v) end },
            { label = "Password:", key = "pass", mask = true, required = true, maxLen = 64 },
        }
        if create then fields[3] = { label = "Confirm:", key = "pass2", mask = true, required = true, maxLen = 64 } end
        local v = ui.form(self.surf, {
            title = title, fields = fields, error = errMsg,
            intro = create and "Pick a user name and a password. Names are unique across the whole network." or "Enter your login information.",
            submit = create and "Create" or "Login",
        })
        if not v then return false end
        typed = v.user
        errMsg = nil
        if create and #v.pass < M.PASS_MIN then
            errMsg = M.MSG.weak_password
        elseif create and v.pass ~= v.pass2 then
            errMsg = "The passwords do not match."
        else
            local body = { op = create and "create" or "login", user = util.trim(v.user), pass = v.pass }
            local reply, msg = self:call(body, title, create and "Creating your account..." or "Logging in...", { auth = false })
            if reply and type(reply.token) == "string" then
                self:beginSession(reply, v.user)
                return true
            end
            errMsg = msg or "Login failed."
        end
    end
end

function App:pollUnread()
    local s = self.session
    if not s then return end
    if self:ready(self.unreadId) then
        local reply = self:take(self.unreadId)
        self.unreadId = nil
        if reply and self.session == s then
            s.unread = tonumber(reply.count) or 0
            s.unreadStale = false
        end
    end
    if self.session and not self.unreadId and (s.unreadStale or compat.now() - (s.unreadAt or 0) >= M.POLL) then
        s.unreadAt = compat.now()
        s.unreadStale = false
        self.unreadId = self:async({ op = "unread" }, { timeout = 15, retries = 0 })
    end
end

function App:mainItems()
    local s = self.session
    local c = self.surf.c
    local items = {}
    local unread = s and s.unread or 0
    items[#items + 1] = { label = "Inbox", key = "inbox", badge = unread > 0 and ("(" .. unread .. ")") or nil, badgeColor = c.warn }
    items[#items + 1] = { label = "New message", key = "new" }
    items[#items + 1] = { label = "Chatroom", key = "chat" }
    items[#items + 1] = { label = "Directory", key = "dir" }
    if s and s.admin then items[#items + 1] = { label = "Admin tools", key = "admin", bg = self.surf.isColor and c.orange or nil } end
    items[#items + 1] = { label = "Change password", key = "passwd" }
    items[#items + 1] = { label = "Network status", key = "status" }
    items[#items + 1] = { label = "Log out", key = "logout", bg = c.div }
    return items
end

function App:mainHelp()
    local s = self.session
    local c = self.surf.c
    local out = {}
    if not s then return out end
    out[#out + 1] = { text = "Logged in as " .. s.display .. " (" .. s.user .. "@" .. tostring(s.home) .. ").", color = c.text }
    out[#out + 1] = ""
    if (s.unread or 0) > 0 then
        out[#out + 1] = { text = "You have " .. s.unread .. " unread message" .. (s.unread == 1 and "" or "s") .. ".", color = c.warn }
    else
        out[#out + 1] = { text = "No unread messages.", color = c.muted }
    end
    local last = self.notes[#self.notes]
    if last and last.sess == s and last.kind == "mail" and last.from then
        out[#out + 1] = { text = (last.failed and "Notice: " or "Latest from ") .. last.from .. ": " .. (last.text or ""), color = c.muted }
    end
    out[#out + 1] = ""
    local state, color = self:connectionText()
    out[#out + 1] = { text = "Server " .. tostring(self.server) .. ": " .. state, color = color }
    return out
end

function App:mainMenu()
    local menu = {
        title = "TekMail " .. version.program,
        items = function() return self:mainItems() end,
        help = function() return self:mainHelp() end,
        update = function()
            if not self.session then return "expired" end
            self:pollUnread()
            return nil
        end,
    }
    while self.session do
        local idx, it = self:splitMenu(menu)
        if idx == "expired" or not self.session then return end
        local key = it and it.key
        if idx == nil then
            if ui.confirm(self.surf, "Log out", "Log out of TekMail?", { yes = "Log out", no = "Stay" }) then return end
        elseif key == "logout" then
            return
        elseif key == "inbox" then
            self:inbox()
        elseif key == "new" then
            self:newMessage()
        elseif key == "chat" then
            self:chatrooms()
        elseif key == "dir" then
            self:directory()
        elseif key == "admin" then
            self:adminTools()
        elseif key == "passwd" then
            self:changePassword()
        elseif key == "status" then
            self:networkStatus()
        end
        if self.session then self.session.unreadStale = true end
    end
end

function App:convItems(convs)
    local c = self.surf.c
    local me = self.session and self.session.user
    local items = {}
    for _, cv in ipairs(M.list(convs)) do
        local unread = tonumber(cv.unread) or 0
        local who = (cv.lastFrom == me) and "You: " or ""
        local hint
        if unread > 0 then
            hint = unread .. " new"
        elseif tonumber(cv.lastT) then
            hint = util.fmtStamp(cv.lastT)
        end
        local room = math.max(10, self.surf.w - 12 - (hint and (#hint + 1) or 0))
        local peer = M.str(cv.peer)
        local display = util.sanitize(M.str(cv.display, peer or "?"))
        local label = util.fitText((unread > 0 and "* " or "  ") .. display .. ": " .. who .. M.preview(M.str(cv.lastText, ""), M.PREVIEW), room)
        items[#items + 1] = { label = label, hint = hint, color = unread > 0 and c.ok or c.text, hintColor = unread > 0 and c.warn or c.muted, peer = peer, display = display }
    end
    return items
end

function App:inbox()
    local st = { convs = nil, err = nil, total = 0, cursor = self.noteSeq }
    local items = {}
    local function fill()
        local fresh = self:convItems(st.convs)
        for i = #items, 1, -1 do items[i] = nil end
        for i, it in ipairs(fresh) do items[i] = it end
    end
    local function reload()
        if not st.id then st.id = self:async({ op = "inbox" }, { retries = 1 }) end
    end
    local function pump()
        if self:ready(st.id) then
            local reply, msg = self:take(st.id)
            st.id = nil
            if reply then
                st.convs = M.list(reply.convs)
                st.total = tonumber(reply.unread) or 0
                st.err = nil
                st.more = reply.more
                if self.session then
                    self.session.unread = st.total
                    self.session.unreadStale = false
                end
                fill()
            else
                st.err = msg
            end
            return true
        end
        return false
    end
    reload()
    local timer = os.startTimer(M.POLL)
    local sel = 1
    while self.session do
        pump()
        local idx, it = ui.menu(self.surf, {
            title = "Inbox", items = items, selected = sel,
            draw = function(page, ix, iy, iw)
                if st.err then
                    page.s:field(ix, iy, iw, st.err, page.c.bad, page.c.inset)
                    return 2
                end
                if not st.convs then
                    page.s:field(ix, iy, iw, "Loading conversations...", page.c.muted, page.c.inset)
                    return 2
                end
                if #st.convs == 0 then
                    page:wrapped(ix, iy, iw, 3, "No conversations yet. Choose New message on the main menu, or pick someone in the Directory.", page.c.muted)
                    return 4
                end
                local summary = #st.convs .. " conversation" .. (#st.convs == 1 and "" or "s") .. ", " .. st.total .. " unread" .. (st.more and ", more on the server" or "")
                page.s:field(ix, iy, iw, summary, st.total > 0 and page.c.warn or page.c.muted, page.c.inset)
                return 2
            end,
            footer = "Enter: open",
            onEvent = function(ev, a)
                if not self.session then return "expired" end
                if ev == "timer" and a == timer then
                    timer = os.startTimer(M.POLL)
                    reload()
                elseif ev == "tm_notify" then
                    local notes
                    notes, st.cursor = self:notesAfter(st.cursor)
                    for _, note in ipairs(notes) do
                        if note.kind == "mail" then reload() end
                    end
                end
                pump()
                return nil
            end,
        })
        if idx == "expired" or idx == nil or not self.session then break end
        if type(idx) == "number" then
            sel = idx
            if it and it.peer then
                self:thread(it.peer, it.display)
                st.cursor = self.noteSeq
                reload()
            end
        end
    end
    self:forget(st.id)
end

function App:newMessage()
    local errMsg
    local typed = ""
    while self.session do
        local v = ui.form(self.surf, {
            title = "New Message", error = errMsg, submit = "Open",
            intro = "Who do you want to write to? User names are the same in every realm.",
            fields = { { label = "To:", key = "to", value = typed, required = true, maxLen = 16, validate = function(x) return M.checkName(x) end } },
        })
        if not v then return end
        typed = v.to
        local _, name = M.checkName(v.to)
        if name == self.session.user then
            errMsg = "That is you."
        else
            self:thread(name, name)
            return
        end
    end
end

local Feed = {}
Feed.__index = Feed

function App:newFeed(kind, target, display)
    local f = setmetatable({}, Feed)
    f.app = self
    f.kind = kind
    f.target = target
    f.display = display or target
    f.since = 0
    f.seen = {}
    f.sends = {}
    f.localN = 0
    f.cursor = self.noteSeq
    f.firstSeq = nil
    f.loaded = false
    return f
end

function Feed:me()
    return self.app.session and self.app.session.user
end

function Feed:body(since, before)
    if self.kind == "dm" then
        return { op = "thread", peer = self.target, since = since, before = before }
    end
    return { op = "chat_get", room = self.target, since = since, before = before }
end

function Feed:fetch()
    if self.fetchId then
        self.again = true
        return
    end
    self.gen = (self.gen or 0) + 1
    self.fetchGen = self.gen
    local from = self.since
    for seq, flag in pairs(self.flags or {}) do
        if flag == "p" and seq - 1 < from then from = seq - 1 end
    end
    self.fetchId = self.app:async(self:body(from), { retries = 1 })
end

function Feed:older()
    if self.olderId or not self.firstSeq then return end
    self.olderId = self.app:async(self:body(0, self.firstSeq), { retries = 1 })
    self.view:setStatus("Loading older messages...", self.app.surf.c.muted)
end

function Feed:entry(m)
    local c = self.app.surf.c
    local me = self:me()
    local s = self.app.session
    local e = { key = "s" .. tostring(m.seq), seq = m.seq, t = tonumber(m.t), text = util.sanitize(M.str(m.text, "")) }
    if self.kind == "dm" then
        local mine = m.from == me
        e.who = mine and "You" or self.display
        e.whoColor = mine and c.ok or c.accent
        if m.failed then
            e.note, e.noteColor = "(not delivered)", c.bad
        elseif m.pending then
            e.note, e.noteColor = "(queued)", c.warn
        end
    else
        local mine = m.user == me and (m.realm == nil or s == nil or m.realm == s.home)
        local who = util.sanitize(M.str(m.user, "?"))
        if self.target == "global" and m.realm and (s == nil or m.realm ~= s.home) then who = who .. "@" .. util.sanitize(M.str(m.realm, "?")) end
        e.who = mine and "You" or who
        e.whoColor = mine and c.ok or c.accent
    end
    return e
end

function Feed:merge(list)
    local fresh = {}
    for _, m in ipairs(M.list(list)) do
        local seq = tonumber(m.seq)
        if seq and not self.seen[seq] then
            self.seen[seq] = true
            self.flags = self.flags or {}
            self.flags[seq] = (m.failed and "f") or (m.pending and "p") or ""
            m.seq = seq
            fresh[#fresh + 1] = m
        elseif seq and self.flags then
            local flag = (m.failed and "f") or (m.pending and "p") or ""
            if self.flags[seq] ~= nil and self.flags[seq] ~= flag then
                self.flags[seq] = flag
                m.seq = seq
                local e = self:entry(m)
                self.view:update(e.key, { note = e.note or false, noteColor = e.noteColor })
            end
        end
    end
    table.sort(fresh, function(a, b) return a.seq < b.seq end)
    return fresh
end

function Feed:onFetch(reply, msg, code)
    local view = self.view
    local c = self.app.surf.c
    if not reply then
        if code == "unknown_user" and self.kind == "dm" and not self.loaded then
            view:setStatus("No such user: " .. self.target, c.bad)
            self.dead = true
        else
            view:setStatus(msg, c.bad)
        end
        return
    end
    local gen = self.doneGen or 0
    view:removeWhere(function(m) return m.confirmedGen ~= nil and m.confirmedGen <= gen end)
    local fresh = self:merge(reply.messages)
    local entries = {}
    for _, m in ipairs(fresh) do
        entries[#entries + 1] = self:entry(m)
        if m.seq > self.since then self.since = m.seq end
    end
    if tonumber(reply.seq) and tonumber(reply.seq) > self.since then self.since = tonumber(reply.seq) end
    if not self.loaded then
        self.loaded = true
        self.firstSeq = fresh[1] and fresh[1].seq or nil
        self.more = reply.more and true or false
        view:setMore(self.more)
        local pend = {}
        for _, m in ipairs(view.msgs) do pend[#pend + 1] = m end
        for _, m in ipairs(pend) do entries[#entries + 1] = m end
        view:setMessages(entries)
        self:trimView()
    else
        local locals = {}
        view:removeWhere(function(m)
            if m.localMsg then
                locals[#locals + 1] = m
                return true
            end
            return false
        end)
        for _, m in ipairs(locals) do entries[#entries + 1] = m end
        view:addMany(entries)
        self:trimView()
    end
    if view.status and view.statusColor ~= c.bad and view.statusColor ~= c.warn then view:setStatus(nil) end
end

function Feed:trimView()
    local dropped = self.view:trim()
    if not dropped then return end
    for _, m in ipairs(dropped) do
        if m.seq then self.seen[m.seq] = nil end
    end
    for _, m in ipairs(self.view.msgs) do
        if m.seq then
            self.firstSeq = m.seq
            break
        end
    end
    self.more = true
end

function Feed:onOlder(reply, msg)
    local view = self.view
    if not reply then
        view:setStatus(msg, self.app.surf.c.bad)
        return
    end
    local fresh = self:merge(reply.messages)
    local entries = {}
    for _, m in ipairs(fresh) do entries[#entries + 1] = self:entry(m) end
    if fresh[1] then self.firstSeq = fresh[1].seq end
    self.more = reply.more and #fresh > 0 or false
    view:setMore(self.more)
    view:prepend(entries)
    view:setStatus(#fresh > 0 and nil or "No older messages.", self.app.surf.c.muted)
end

function Feed:onSent(key, reply, msg)
    local view = self.view
    local c = self.app.surf.c
    if not reply then
        view:update(key, { note = "(not sent)", noteColor = c.bad, localMsg = false, failed = true })
        view:setStatus(msg, c.bad)
        return
    end
    view:update(key, { confirmedGen = (self.gen or 0) + 1, note = false })
    if reply.queued then
        view:setStatus("Queued. It will be delivered when " .. self.display .. "'s realm can be reached.", c.warn)
    end
    self:fetch()
end

function Feed:send(text)
    local c = self.app.surf.c
    if self.dead then
        self.view:setStatus("No such user: " .. self.target, c.bad)
        return false
    end
    local limit = self.kind == "dm" and M.TEXT_MAX or M.CHAT_MAX
    if #text > limit then
        self.view:setStatus("Too long: at most " .. limit .. " characters.", c.bad)
        return false
    end
    self.localN = self.localN + 1
    local key = "l" .. self.localN
    self.view:add({ key = key, localMsg = true, who = "You", whoColor = c.ok, t = compat.stamp(), text = text, note = "(sending)", noteColor = c.dim })
    local body, retries
    if self.kind == "dm" then
        self.app.midSeq = (self.app.midSeq or 0) + 1
        body = { op = "send", to = self.target, text = text, mid = M.newMid(self.app.midSeq) }
        retries = 1
    else
        body = { op = "chat_post", room = self.target, text = text }
        retries = 0
    end
    self.sends[self.app:async(body, { retries = retries })] = key
    return true
end

function Feed:pump()
    local app = self.app
    if app:ready(self.fetchId) then
        local reply, msg, code = app:take(self.fetchId)
        self.fetchId = nil
        self.doneGen = self.fetchGen
        if app.session then self:onFetch(reply, msg, code) end
        if self.again then
            self.again = false
            self:fetch()
        end
    end
    if app:ready(self.olderId) then
        local reply, msg = app:take(self.olderId)
        self.olderId = nil
        if app.session then self:onOlder(reply, msg) end
    end
    for id, key in compat.spairs(self.sends) do
        if app:ready(id) then
            local reply, msg = app:take(id)
            self.sends[id] = nil
            if app.session then self:onSent(key, reply, msg) end
        end
    end
end

function Feed:onNotes()
    local app = self.app
    local notes
    notes, self.cursor = app:notesAfter(self.cursor)
    local c = app.surf.c
    for _, note in ipairs(notes) do
        if self.kind == "dm" and note.kind == "mail" and note.from == self.target then
            self:fetch()
        elseif self.kind == "chat" and note.kind == "chat" and note.room == self.target then
            self:fetch()
        elseif note.kind == "mail" and note.from then
            self.view:setStatus((note.failed and "Notice: " or "New message from ") .. note.from .. ": " .. (note.text or ""), c.warn)
        end
    end
end

function Feed:close()
    local app = self.app
    app:forget(self.fetchId)
    app:forget(self.olderId)
    for id in pairs(self.sends) do app:forget(id) end
    self.sends = {}
end

function Feed:run(view)
    self.view = view
    self:fetch()
    local timer = os.startTimer(M.POLL)
    view:setStatus("Loading...", self.app.surf.c.muted)
    local result = view:run({
        update = function()
            if not self.app.session then return "exit" end
            self:pump()
            return nil
        end,
        onSend = function(text) return self:send(text) end,
        onOlder = function() self:older() end,
        onEvent = function(ev, a)
            if ev == "timer" and a == timer then
                timer = os.startTimer(M.POLL)
                self:fetch()
            elseif ev == "tm_notify" then
                self:onNotes()
            end
            return nil
        end,
    })
    self:close()
    return result
end

function App:thread(peer, display)
    if not self.session then return end
    local feed = self:newFeed("dm", peer, util.sanitize(display or peer))
    local view = uichat.new(self.surf, {
        title = "DM: " .. feed.display, left = self.session.user, maxLen = M.TEXT_MAX,
        empty = "No messages with " .. feed.display .. " yet. Type below and press Enter to send.",
    })
    feed:run(view)
end

function App:chatroom(room)
    if not self.session then return end
    local label = room == "global" and "Global chat" or (room .. " chat")
    local feed = self:newFeed("chat", room, label)
    local view = uichat.new(self.surf, {
        title = label, left = self.session.user, maxLen = M.CHAT_MAX,
        empty = "Nobody has said anything yet. Say hello!",
    })
    feed:run(view)
end

function App:roomList()
    local rooms = (self.info and type(self.info.rooms) == "table") and self.info.rooms or nil
    if rooms and #rooms > 0 then return rooms end
    local reply = self:call({ op = "rooms" }, "Chatroom", "Loading rooms...", { retries = 1, timeout = 20 })
    if reply and type(reply.rooms) == "table" and #reply.rooms > 0 then
        local clean = {}
        for _, r in ipairs(reply.rooms) do
            if type(r) == "string" then clean[#clean + 1] = r end
        end
        reply.rooms = #clean > 0 and clean or { "global", self.realm }
        self.info = self.info or {}
        self.info.rooms = reply.rooms
        return reply.rooms
    end
    return { "global", self.realm }
end

function App:chatrooms()
    local rooms = self:roomList()
    if not self.session then return end
    local items = {}
    for _, r in ipairs(rooms) do
        local room = tostring(r)
        if room == "global" then
            items[#items + 1] = { label = "Global chat", hint = "every realm", room = room }
        else
            items[#items + 1] = { label = room .. " chat", hint = "this realm", room = room }
        end
    end
    while self.session do
        local idx, it = ui.menu(self.surf, { title = "Chatroom", subtitle = "Pick a room", items = items })
        if not idx or not it then return end
        self:chatroom(it.room)
    end
end

function App:directory()
    local reply, msg = self:call({ op = "users" }, "Directory", "Loading the user directory...", { retries = 1 })
    if not self.session then return end
    if not reply then
        ui.message(self.surf, "Directory", { { text = msg, color = self.surf.c.bad } })
        return
    end
    local me = self.session.user
    local items = {}
    for _, u in ipairs(M.list(reply.users)) do
        local name = M.str(u.name)
        local mine = name == me
        local display = util.sanitize(M.str(u.display, name or "?"))
        items[#items + 1] = {
            label = display .. (mine and " (you)" or ""),
            hint = util.sanitize(M.str(u.realm, "?")), name = name, display = display,
            color = mine and self.surf.c.muted or nil,
        }
    end
    if #items == 0 then
        ui.message(self.surf, "Directory", "No accounts found.")
        return
    end
    local sel = 1
    while self.session do
        local idx, it = ui.menu(self.surf, {
            title = "Directory", items = items, selected = sel, footer = "Enter: message",
            subtitle = #items .. " account" .. (#items == 1 and "" or "s") .. (reply.more and " (list truncated)" or ""),
        })
        if not idx or not it then return end
        sel = idx
        if it.name and it.name ~= me then self:thread(it.name, it.display) end
    end
end

function App:changePassword()
    local errMsg
    while self.session do
        local v = ui.form(self.surf, {
            title = "Change Password", error = errMsg, submit = "Change",
            fields = {
                { label = "Old password:", key = "old", mask = true, required = true, maxLen = 64 },
                { label = "New password:", key = "new", mask = true, required = true, maxLen = 64 },
                { label = "Confirm:", key = "new2", mask = true, required = true, maxLen = 64 },
            },
        })
        if not v then return end
        if #v.new < M.PASS_MIN then
            errMsg = M.MSG.weak_password
        elseif v.new ~= v.new2 then
            errMsg = "The new passwords do not match."
        else
            local reply, msg = self:call({ op = "passwd", old = v.old, new = v.new }, "Change Password", "Changing your password...")
            if reply then
                ui.message(self.surf, "Change Password", { { text = "Your password was changed.", color = self.surf.c.ok } })
                return
            end
            errMsg = msg
        end
    end
end

function App:adminResult(title, reply, msg, okText)
    local c = self.surf.c
    if reply then
        ui.message(self.surf, title, { { text = okText, color = c.ok } })
    else
        ui.message(self.surf, title, { { text = msg or "Failed.", color = c.bad } })
    end
end

function App:askTarget(title, intro, extra)
    local fields = { { label = "User:", key = "target", required = true, maxLen = 16, validate = function(x) return M.checkName(x) end } }
    if extra then fields[2] = extra end
    local v = ui.form(self.surf, { title = title, intro = intro, fields = fields, submit = "Next" })
    if not v then return nil end
    local _, name = M.checkName(v.target)
    return name, v
end

function App:adminList()
    local reply, msg = self:call({ op = "admin", action = "list" }, "Accounts", "Loading accounts...", { retries = 1 })
    if not reply then return self:adminResult("Accounts", nil, msg) end
    local c = self.surf.c
    local lines = {}
    for _, u in ipairs(M.list(reply.users)) do
        local text = util.padRight(util.sanitize(M.str(u.display, M.str(u.name, "?"))), 17) .. util.padRight(util.sanitize(M.str(u.realm, "?")), 13) .. (u.admin and "admin " or "") .. (tonumber(u.lastLogin) and ("last " .. util.fmtStamp(u.lastLogin)) or "never")
        lines[#lines + 1] = { text = text, color = u.admin and c.orange or c.text }
    end
    if #lines == 0 then lines[1] = "No accounts." end
    if reply.more then lines[#lines + 1] = { text = "(list truncated)", color = c.muted } end
    ui.message(self.surf, "Accounts", lines, { button = "Back" })
end

function App:adminAudit()
    local reply, msg = self:call({ op = "admin", action = "audit", value = 40 }, "Audit Log", "Loading the audit log...", { retries = 1 })
    if not reply then return self:adminResult("Audit Log", nil, msg) end
    local c = self.surf.c
    local lines = {}
    for _, e in ipairs(M.list(reply.entries)) do
        local text = util.fmtStamp(e.s) .. " " .. M.str(e.actor, "?") .. " " .. M.str(e.action, "?") .. " " .. M.str(e.target, "") .. (e.detail ~= nil and (" (" .. M.str(e.detail, "?") .. ")") or "")
        lines[#lines + 1] = { text = text, color = e.ok == false and c.bad or c.text }
    end
    if #lines == 0 then lines[1] = "The audit log is empty." end
    ui.message(self.surf, "Audit Log", lines, { button = "Back" })
end

function App:adminAction(action)
    if action == "reset_pw" then
        local target, v = self:askTarget("Reset Password", "Set a new password for a user.", { label = "New password:", key = "value", mask = true, required = true, maxLen = 64 })
        if not target then return end
        if #v.value < M.PASS_MIN then return self:adminResult("Reset Password", nil, M.MSG.weak_password) end
        local reply, msg = self:call({ op = "admin", action = "reset_pw", target = target, value = v.value }, "Reset Password", "Resetting the password...")
        self:adminResult("Reset Password", reply, msg, "The password of " .. target .. " was reset.")
    elseif action == "rename" then
        local target, v = self:askTarget("Rename User", "Give a user a new name. Their mail moves with them.", { label = "New name:", key = "value", required = true, maxLen = 16, validate = function(x) return M.checkName(x) end })
        if not target then return end
        local reply, msg = self:call({ op = "admin", action = "rename", target = target, value = util.trim(v.value) }, "Rename User", "Renaming...")
        self:adminResult("Rename User", reply, msg, target .. " is now " .. tostring(reply and reply.target or util.trim(v.value):lower()) .. ".")
    elseif action == "delete" then
        local target = self:askTarget("Delete User", "Delete an account and all of its mail.")
        if not target then return end
        if not ui.confirm(self.surf, "Delete User", "Delete the account " .. target .. " and all of its mail? This cannot be undone.", { yes = "Delete", danger = true }) then return end
        local reply, msg = self:call({ op = "admin", action = "delete", target = target }, "Delete User", "Deleting...")
        self:adminResult("Delete User", reply, msg, "The account " .. target .. " was deleted.")
    elseif action == "set_admin" then
        local target = self:askTarget("Admin Rights", "Grant or revoke admin rights.")
        if not target then return end
        local idx = ui.menu(self.surf, { title = "Admin Rights", subtitle = target, items = { { label = "Grant admin rights" }, { label = "Revoke admin rights" } } })
        if not idx then return end
        local grant = idx == 1
        local reply, msg = self:call({ op = "admin", action = "set_admin", target = target, value = grant }, "Admin Rights", "Saving...")
        self:adminResult("Admin Rights", reply, msg, target .. (grant and " is now an admin." or " is no longer an admin."))
    end
end

function App:adminTools()
    local items = {
        { label = "List accounts", key = "list" },
        { label = "Reset password", key = "reset_pw" },
        { label = "Rename user", key = "rename" },
        { label = "Delete user", key = "delete", color = self.surf.c.bad },
        { label = "Admin rights", key = "set_admin" },
        { label = "Audit log", key = "audit" },
    }
    local sel = 1
    while self.session and self.session.admin do
        local idx, it = ui.menu(self.surf, { title = "Admin Tools", subtitle = "Administrative actions", items = items, selected = sel })
        if not idx or not it then return end
        sel = idx
        if it.key == "list" then
            self:adminList()
        elseif it.key == "audit" then
            self:adminAudit()
        else
            self:adminAction(it.key)
        end
    end
end

function M.statusRows(n, c)
    local st = n:status()
    local rows = {}
    rows[#rows + 1] = { "Address", tostring(st.address) }
    rows[#rows + 1] = { "Server", tostring(st.realm) .. (st.serverId and (" (computer " .. st.serverId .. ")") or "") }
    rows[#rows + 1] = { "State", st.connected and "connected" or "not connected", st.connected and c.ok or c.warn }
    rows[#rows + 1] = { "Parent", st.parent and (tostring(st.parent) .. ", " .. tostring(st.hops) .. " hop" .. (st.hops == 1 and "" or "s")) or "none" }
    local up = 0
    for _, l in ipairs(st.links or {}) do if l.open then up = up + 1 end end
    rows[#rows + 1] = { "Links", up .. " open of " .. #(st.links or {}), up > 0 and c.text or c.bad }
    for _, l in ipairs(st.links or {}) do
        rows[#rows + 1] = { "  " .. tostring(l.id), "tx " .. tostring(l.tx or 0) .. " rx " .. tostring(l.rx or 0), l.open and c.muted or c.bad }
    end
    local k = st.counters or {}
    rows[#rows + 1] = { "Packets", "sent " .. tostring(k.sent or 0) .. " got " .. tostring(k.delivered or 0) .. " drop " .. tostring(k.dropped or 0) }
    rows[#rows + 1] = { "Uptime", util.fmtDuration(st.uptime or 0) }
    rows[#rows + 1] = { "Version", tostring(st.prog or version.program) }
    return rows
end

function App:networkStatus()
    local items = { { label = "Ping server" } }
    while true do
        local idx = ui.menu(self.surf, {
            title = "Network Status", items = items, interval = 1,
            refresh = function() return nil end,
            draw = function(page, ix, iy, iw, ih)
                local rows = M.statusRows(self.n, page.c)
                local maxRows = math.max(0, ih - 4)
                local shown = math.min(#rows, maxRows)
                for i = 1, shown do
                    local r = rows[i]
                    page:kv(ix, iy + i - 1, iw - 1, r[1], r[2], r[3])
                end
                return shown + 1
            end,
        })
        if not idx then return end
        self:pingServer()
    end
end

function App:pingServer()
    local n, dst = self.n, self.server
    local id = self:job(function() return n:ping(dst, 15) end, "tekmail-ping")
    if not self:wait(id, "Ping Server", "Pinging " .. tostring(dst) .. "...") then return end
    local r = self:takeRaw(id)
    local c = self.surf.c
    local ok, rtt, err = r.res[1], r.res[2], r.res[3]
    local lines
    if ok and rtt then
        lines = {
            { text = "The server " .. tostring(dst) .. " answered.", color = c.ok },
            "Round trip: " .. util.fmtFixed(rtt, 2) .. " s",
        }
    else
        lines = {
            { text = "No answer from " .. tostring(dst) .. ".", color = c.bad },
            M.errText(ok and err or tostring(rtt)),
        }
    end
    local st = n:status()
    lines[#lines + 1] = ""
    lines[#lines + 1] = { text = "Parent: " .. (st.parent and (tostring(st.parent) .. ", " .. tostring(st.hops) .. " hops") or "none"), color = c.muted }
    ui.message(self.surf, "Ping Server", lines)
end

M.App = App
M.Feed = Feed

function M.run(n, opts)
    local app = M.new(n, opts)
    if n.running then return app:run() end
    return n:loop(function() return app:run() end)
end

return M
