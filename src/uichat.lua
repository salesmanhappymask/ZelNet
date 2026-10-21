local need = ...
local compat = need("compat")
local util = need("util")
local ui = need("ui")

local M = {}

local Chat = {}
Chat.__index = Chat

M.NAME_MAX = 16
M.MAX_MSGS = 300

function M.wrap(text, firstW, restW)
    firstW = math.max(1, math.floor(firstW))
    restW = math.max(1, math.floor(restW))
    local out = {}
    local width = firstW
    local line = ""
    local firstPara = true
    text = tostring(text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
    for para in (text .. "\n"):gmatch("([^\n]*)\n") do
        if not firstPara then
            out[#out + 1] = line
            line = ""
            width = restW
        end
        firstPara = false
        for word in util.sanitize(para):gmatch("%S+") do
            while word ~= "" do
                local size = (line == "") and #word or (#line + 1 + #word)
                if size <= width then
                    line = (line == "") and word or (line .. " " .. word)
                    word = ""
                elseif line ~= "" then
                    out[#out + 1] = line
                    line = ""
                    width = restW
                else
                    out[#out + 1] = word:sub(1, width)
                    word = word:sub(width + 1)
                    width = restW
                end
            end
        end
    end
    out[#out + 1] = line
    return out
end

function M.splitStamp(t)
    if type(t) ~= "number" then return nil, nil end
    local s = util.fmtStamp(t)
    return s:match("^(%S+)"), s:match("%s(%S+)$")
end

function M.new(surf, opts)
    opts = opts or {}
    local self = setmetatable({}, Chat)
    self.surf = surf
    self.title = opts.title or "Chat"
    self.left = opts.left
    self.prompt = opts.prompt
    self.maxLen = opts.maxLen or 200
    self.hint = opts.hint
    self.empty = opts.empty or "No messages yet."
    self.showTime = opts.showTime
    self.maxMsgs = opts.maxMsgs or M.MAX_MSGS
    self.msgs = {}
    self.input = ""
    self.pos = 0
    self.offset = 0
    self.unseen = 0
    self.lines = nil
    self.dirty = true
    self.more = false
    self.page = nil
    return self
end

function Chat:invalidate()
    self.lines = nil
    self.dirty = true
end

function Chat:geometry()
    local s = self.surf
    return 3, 3, math.max(1, s.w - 3), math.max(1, s.h - 5)
end

function Chat:timeShown()
    if self.showTime ~= nil then return self.showTime end
    return self.surf.w >= 30
end

function Chat:buildLines(width)
    local c = self.surf.c
    local out = {}
    local lastDay
    local withTime = self:timeShown()
    for _, m in ipairs(self.msgs) do
        local day, hm = M.splitStamp(m.t)
        if day and day ~= lastDay then
            out[#out + 1] = { center = true, segs = { { " Day " .. day:sub(2) .. " ", c.muted } } }
            lastDay = day
        end
        if m.system then
            for _, l in ipairs(M.wrap(m.text, width, width)) do
                out[#out + 1] = { segs = { { l, m.color or c.dim } } }
            end
        else
            local head = {}
            local headLen = 0
            if withTime and hm then
                head[#head + 1] = { "[" .. hm .. "] ", c.dim }
                headLen = headLen + #hm + 3
            end
            local who = util.fitText(util.sanitize(m.who or "?"), M.NAME_MAX) .. ": "
            head[#head + 1] = { who, m.whoColor or c.accent }
            headLen = headLen + #who
            if headLen > width - 4 then
                head = { { util.fitText(who, math.max(1, width - 4)), m.whoColor or c.accent } }
                headLen = #head[1][1]
            end
            local text = m.text or ""
            if m.note then text = text .. " " .. m.note end
            local indent = math.min(headLen, math.floor(width / 3))
            local wrapped = M.wrap(text, width - headLen, width - indent)
            for i, l in ipairs(wrapped) do
                local segs = {}
                if i == 1 then
                    for _, h in ipairs(head) do segs[#segs + 1] = h end
                else
                    segs[#segs + 1] = { string.rep(" ", indent), c.text }
                end
                if m.note and i == #wrapped and #l > #m.note and l:sub(-#m.note) == m.note then
                    local body = l:sub(1, #l - #m.note)
                    segs[#segs + 1] = { body, m.color or c.text }
                    segs[#segs + 1] = { m.note, m.noteColor or c.dim }
                else
                    segs[#segs + 1] = { l, m.color or c.text }
                end
                out[#out + 1] = { segs = segs }
            end
        end
    end
    return out
end

function Chat:layout()
    local _, _, w = self:geometry()
    if not self.lines or self.linesW ~= w then
        self.lines = self:buildLines(w)
        self.linesW = w
    end
    return self.lines
end

function Chat:lineCount()
    return #self:layout()
end

function Chat:afterChange(before, appended)
    local after = #self:layout()
    if self.offset > 0 and appended then
        self.offset = self.offset + math.max(0, after - before)
        self.unseen = self.unseen + appended
    end
    self.dirty = true
end

function Chat:setMessages(list)
    self.msgs = {}
    for _, m in ipairs(list or {}) do self.msgs[#self.msgs + 1] = m end
    self.offset = 0
    self.unseen = 0
    self:invalidate()
end

function Chat:add(m)
    return self:addMany({ m })
end

function Chat:addMany(list)
    if not list or #list == 0 then return end
    local before = #self:layout()
    for _, m in ipairs(list) do self.msgs[#self.msgs + 1] = m end
    self:invalidate()
    self:afterChange(before, #list)
end

function Chat:trim()
    local extra = #self.msgs - self.maxMsgs
    if extra <= 0 or self.offset > 0 then return nil end
    local dropped, keep = {}, {}
    for i, m in ipairs(self.msgs) do
        if i <= extra then dropped[#dropped + 1] = m else keep[#keep + 1] = m end
    end
    self.msgs = keep
    self.more = true
    self:invalidate()
    return dropped
end

function Chat:prepend(list)
    if not list or #list == 0 then return end
    local merged = {}
    for _, m in ipairs(list) do merged[#merged + 1] = m end
    for _, m in ipairs(self.msgs) do merged[#merged + 1] = m end
    self.msgs = merged
    self:invalidate()
end

function Chat:find(key)
    for i, m in ipairs(self.msgs) do
        if m.key == key then return m, i end
    end
    return nil
end

function Chat:update(key, fields)
    local m = self:find(key)
    if not m then return false end
    for k, v in pairs(fields) do
        if v == false and (k == "note" or k == "noteColor") then m[k] = nil else m[k] = v end
    end
    self:invalidate()
    return true
end

function Chat:remove(key)
    local _, i = self:find(key)
    if not i then return false end
    table.remove(self.msgs, i)
    self:invalidate()
    return true
end

function Chat:removeWhere(fn)
    local keep, removed = {}, 0
    for _, m in ipairs(self.msgs) do
        if fn(m) then removed = removed + 1 else keep[#keep + 1] = m end
    end
    if removed > 0 then
        self.msgs = keep
        self:invalidate()
    end
    return removed
end

function Chat:setStatus(text, color)
    if self.status ~= text or self.statusColor ~= color then
        self.status = text
        self.statusColor = color
        self.dirty = true
    end
end

function Chat:setTitle(title, left)
    self.title = title or self.title
    self.left = left
    self.dirty = true
end

function Chat:setMore(more)
    self.more = more and true or false
    self.dirty = true
end

function Chat:clearInput()
    self.input = ""
    self.pos = 0
    self.dirty = true
end

function Chat:setInput(text)
    self.input = tostring(text or ""):sub(1, self.maxLen)
    self.pos = #self.input
    self.dirty = true
end

function Chat:maxOffset()
    local _, _, _, h = self:geometry()
    return math.max(0, self:lineCount() - h)
end

function Chat:scroll(delta)
    local before = self.offset
    self.offset = util.clamp(self.offset + delta, 0, self:maxOffset())
    if self.offset == 0 then self.unseen = 0 end
    self.dirty = true
    if delta > 0 and before == self.offset and self.more then return "older" end
    return true
end

function Chat:promptText()
    if self.prompt then return self.prompt end
    if self.surf.w < 30 then return "> " end
    return "[You]: "
end

function Chat:draw()
    local s = self.surf
    local c = s.c
    local w, h = s.w, s.h
    local page = ui.page(s)
    self.page = page
    page:header(self.title, self.left)
    s:rect(1, 3, w, h - 2, c.div)
    local lx, ly, lw, lh = self:geometry()
    s:rect(2, ly, w - 2, lh, c.inset)
    s:rect(2, ly, 1, lh, c.accent)
    local lines = self:layout()
    self.offset = util.clamp(self.offset, 0, math.max(0, #lines - lh))
    if self.offset == 0 then self.unseen = 0 end
    if #lines == 0 then
        page:wrapped(lx, ly + math.max(0, math.floor(lh / 2) - 1), lw, 3, self.empty, c.muted, c.inset)
    end
    local last = #lines - self.offset
    local first = last - lh + 1
    for row = 1, lh do
        local line = lines[first + row - 1]
        if line then
            local y = ly + row - 1
            if line.center then
                local t = line.segs[1][1]
                s:rect(lx, y, lw, 1, c.inset)
                local x = lx + math.max(0, math.floor((lw - #t) / 2))
                s:text(x, y, util.fitText(t, lw), line.segs[1][2], c.inset)
            else
                local x = lx
                for _, seg in ipairs(line.segs) do
                    local t = seg[1]
                    if x + #t > lx + lw then t = t:sub(1, math.max(0, lx + lw - x)) end
                    s:text(x, y, t, seg[2], c.inset)
                    x = x + #t
                end
            end
        end
    end
    page:hotspot(lx, ly, lw, lh, "list")
    self:drawStatus(page, first > 1)
    self:drawInput(page)
    self:drawFooter(page)
    s:flush()
    self.dirty = false
end

function Chat:drawStatus(page, hasAbove)
    local s, c = self.surf, self.surf.c
    local w, y = s.w, s.h - 2
    local right = ""
    if self.offset > 0 then
        right = self.unseen > 0 and ("v " .. self.unseen .. " new") or "v more"
    elseif hasAbove or self.more then
        right = "^ older"
    end
    if #self.input > self.maxLen * 0.8 then
        right = #self.input .. "/" .. self.maxLen .. (right ~= "" and ("  " .. right) or "")
    end
    local rightColor = (self.offset > 0 and self.unseen > 0) and c.warn or c.muted
    if right ~= "" then
        right = util.fitText(right, math.max(0, w - 4))
        s:text(w - #right, y, right, rightColor, c.div)
    end
    if self.status then
        local avail = w - 3 - (right ~= "" and (#right + 2) or 0)
        s:field(2, y, math.max(0, avail), self.status, self.statusColor or c.text, c.div)
    end
end

function Chat:drawInput(page)
    local s, c = self.surf, self.surf.c
    local w, y = s.w, s.h - 1
    s:rect(2, y, w - 2, 1, c.inset)
    local prompt = self:promptText()
    s:text(3, y, prompt, c.ok, c.inset)
    local x0 = 3 + #prompt
    local avail = math.max(1, w - x0)
    local start = 0
    if self.pos > avail - 1 then start = self.pos - avail + 1 end
    local shown = self.input:sub(start + 1, start + avail)
    s:text(x0, y, shown, c.text, c.inset)
    s:setCursor(math.min(w - 1, x0 + self.pos - start), y)
    page:hotspot(2, y, w - 2, 1, "input")
end

function Chat:drawFooter(page)
    local s, c = self.surf, self.surf.c
    local w, y = s.w, s.h
    local bw = math.min(8, w)
    page:button(w - bw + 1, y, bw, 1, "Back", c.brand, c.text, "back")
    local hint = self.hint
    if not hint then
        if w >= 44 then
            hint = "Enter: send  Up/Down: scroll  Ctrl: back"
        else
            hint = "Ctrl: back"
        end
    end
    s:field(2, y, math.max(0, w - bw - 2), hint, c.muted, c.div)
end

function Chat:insert(ch)
    if #self.input + #ch > self.maxLen then
        ch = ch:sub(1, math.max(0, self.maxLen - #self.input))
        if ch == "" then return true end
    end
    self.input = self.input:sub(1, self.pos) .. ch .. self.input:sub(self.pos + 1)
    self.pos = self.pos + #ch
    self.dirty = true
    return true
end

function Chat:onKey(k)
    local _, _, _, lh = self:geometry()
    if ui.isCtrl(k) then return "back" end
    if k == keys.enter then
        local text = util.trim(self.input)
        if text == "" then return true end
        return "send", text
    elseif k == keys.backspace then
        if self.pos > 0 then
            self.input = self.input:sub(1, self.pos - 1) .. self.input:sub(self.pos + 1)
            self.pos = self.pos - 1
        end
    elseif keys.delete and k == keys.delete then
        self.input = self.input:sub(1, self.pos) .. self.input:sub(self.pos + 2)
    elseif k == keys.left then
        self.pos = math.max(0, self.pos - 1)
    elseif k == keys.right then
        self.pos = math.min(#self.input, self.pos + 1)
    elseif keys.home and k == keys.home then
        self.pos = 0
    elseif keys["end"] and k == keys["end"] then
        self.pos = #self.input
    elseif k == keys.up then
        return self:scroll(1)
    elseif k == keys.down then
        return self:scroll(-1)
    elseif keys.pageUp and k == keys.pageUp then
        return self:scroll(math.max(1, lh - 1))
    elseif keys.pageDown and k == keys.pageDown then
        return self:scroll(-math.max(1, lh - 1))
    else
        return true
    end
    self.dirty = true
    return true
end

function Chat:handle(ev, a, b, c)
    if ev == "char" then return self:insert(a) end
    if ev == "paste" and type(a) == "string" then return self:insert(util.sanitize(a)) end
    if ev == "key" then return self:onKey(a) end
    if ev == "term_resize" or (ev == "monitor_resize" and a == self.surf.name) then
        self.surf:resize()
        self:invalidate()
        return nil
    end
    local px, py, kind, btn = self.surf:pointer(ev, a, b, c)
    if px then
        if kind == "scroll" then return self:scroll(-(btn or 0)) end
        local act = self.page and self.page:hit(px, py)
        if act == "back" then return "back" end
        return true
    end
    return nil
end

function Chat:leave()
    self.surf.cursor = nil
    if not self.surf.isMonitor and self.surf.target.setCursorBlink then self.surf.target.setCursorBlink(false) end
end

function Chat:run(hooks)
    hooks = hooks or {}
    self.dirty = true
    while true do
        if hooks.update then
            local r = hooks.update(self)
            if r == "exit" then
                self:leave()
                return "exit"
            end
        end
        if self.dirty then self:draw() end
        local ev, a, b, c = compat.pullUI()
        local act, arg = self:handle(ev, a, b, c)
        if act == "back" then
            self:leave()
            return "back"
        elseif act == "send" then
            local keep = hooks.onSend and hooks.onSend(arg, self)
            if keep ~= false then self:clearInput() end
        elseif act == "older" then
            if hooks.onOlder then hooks.onOlder(self) end
        elseif act == nil and hooks.onEvent then
            local r = hooks.onEvent(ev, a, b, c, self)
            if r == "exit" then
                self:leave()
                return "exit"
            end
        end
    end
end

return M
