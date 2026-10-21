local need = ...
local compat = need("compat")
local util = need("util")

local M = {}

function M.palette(isColor)
    local c = {}
    c.bg = colors.black
    c.header = isColor and colors.lightGray or colors.black
    c.div = isColor and colors.gray or colors.black
    c.inset = colors.black
    c.accent = isColor and colors.cyan or colors.white
    c.text = colors.white
    c.muted = isColor and colors.lightGray or colors.white
    c.dim = isColor and colors.gray or colors.white
    c.brand = isColor and colors.blue or colors.white
    c.ok = isColor and colors.lime or colors.white
    c.good = isColor and colors.green or colors.black
    c.warn = isColor and colors.yellow or colors.white
    c.bad = isColor and colors.red or colors.white
    c.orange = isColor and colors.orange or colors.white
    c.purple = isColor and colors.purple or colors.white
    c.headerText = isColor and colors.gray or colors.white
    c.selected = isColor and colors.blue or colors.white
    c.field = isColor and colors.gray or colors.black
    return c
end

local Surface = {}
Surface.__index = Surface

function M.surface(target, name)
    local self = setmetatable({}, Surface)
    self.target = target
    self.name = name
    self.isMonitor = name ~= nil
    self:resize()
    return self
end

function Surface:resize()
    local t = self.target
    self.isColor = (t.isColor and t.isColor()) or false
    self.c = M.palette(self.isColor)
    self.w, self.h = t.getSize()
    self.total = self.w * self.h
    self.fc, self.ff, self.fb = {}, {}, {}
    self.pc, self.pf, self.pb = {}, {}, {}
    self:begin()
end

function Surface:begin()
    local bg, fg = self.c.bg, self.c.text
    for i = 1, self.total do
        self.fc[i] = " "
        self.ff[i] = fg
        self.fb[i] = bg
    end
    self.cursor = nil
end

function Surface:rect(x, y, w, h, bg)
    if w <= 0 or h <= 0 then return end
    local x1, y1 = math.max(1, x), math.max(1, y)
    local x2, y2 = math.min(self.w, x + w - 1), math.min(self.h, y + h - 1)
    local fg = self.c.text
    for yy = y1, y2 do
        local base = (yy - 1) * self.w
        for xx = x1, x2 do
            local i = base + xx
            self.fc[i] = " "
            self.ff[i] = fg
            self.fb[i] = bg
        end
    end
end

function Surface:text(x, y, s, fg, bg)
    if y < 1 or y > self.h then return end
    s = tostring(s or "")
    local base = (y - 1) * self.w
    for n = 1, #s do
        local xx = x + n - 1
        if xx >= 1 and xx <= self.w then
            local i = base + xx
            self.fc[i] = s:sub(n, n)
            self.ff[i] = fg or self.c.text
            if bg then self.fb[i] = bg end
        end
    end
end

function Surface:field(x, y, w, s, fg, bg, align)
    if w <= 0 then return end
    s = util.fitText(util.sanitize(s), w)
    local pad = w - #s
    local left = 0
    if align == "right" then
        left = pad
    elseif align == "center" then
        left = math.floor(pad / 2)
    end
    self:text(x, y, string.rep(" ", left) .. s .. string.rep(" ", pad - left), fg, bg)
end

function Surface:setCursor(x, y)
    self.cursor = { x = x, y = y }
end

function Surface:invalidate()
    self.pc, self.pf, self.pb = {}, {}, {}
end

function Surface:flush(force)
    local t = self.target
    local mono = not self.isColor
    local curFg, curBg, curX, curY
    for y = 1, self.h do
        local x = 1
        local base = (y - 1) * self.w
        while x <= self.w do
            local i = base + x
            if force or self.pc[i] ~= self.fc[i] or self.pf[i] ~= self.ff[i] or self.pb[i] ~= self.fb[i] then
                local fg, bg = self.ff[i], self.fb[i]
                local startX = x
                local chars = {}
                while x <= self.w do
                    local j = base + x
                    local changed = force or self.pc[j] ~= self.fc[j] or self.pf[j] ~= self.ff[j] or self.pb[j] ~= self.fb[j]
                    if not changed or self.ff[j] ~= fg or self.fb[j] ~= bg then break end
                    chars[#chars + 1] = self.fc[j]
                    self.pc[j], self.pf[j], self.pb[j] = self.fc[j], self.ff[j], self.fb[j]
                    x = x + 1
                end
                if mono then fg, bg = colors.white, colors.black end
                if bg ~= curBg then
                    t.setBackgroundColor(bg)
                    curBg = bg
                end
                if fg ~= curFg then
                    t.setTextColor(fg)
                    curFg = fg
                end
                if curX ~= startX or curY ~= y then t.setCursorPos(startX, y) end
                t.write(table.concat(chars))
                curX, curY = x, y
            else
                x = x + 1
            end
        end
    end
    if self.cursor and not self.isMonitor then
        t.setCursorPos(self.cursor.x, self.cursor.y)
        t.setTextColor(colors.white)
        t.setCursorBlink(true)
    elseif not self.isMonitor then
        t.setCursorBlink(false)
    end
end

function Surface:pointer(ev, a, b, c)
    if self.isMonitor then
        if ev == "monitor_touch" and a == self.name then return b, c, "touch" end
        return nil
    end
    if ev == "mouse_click" then return b, c, "click", a end
    if ev == "mouse_scroll" then return b, c, "scroll", a end
    return nil
end

local Page = {}
Page.__index = Page

function M.page(surf)
    local self = setmetatable({}, Page)
    self.s = surf
    self.c = surf.c
    self.hot = {}
    surf:begin()
    return self
end

function Page:hotspot(x, y, w, h, action)
    self.hot[#self.hot + 1] = { x1 = x, y1 = y, x2 = x + w - 1, y2 = y + h - 1, action = action }
end

function Page:hit(x, y)
    for i = #self.hot, 1, -1 do
        local h = self.hot[i]
        if x >= h.x1 and x <= h.x2 and y >= h.y1 and y <= h.y2 then return h.action end
    end
    return nil
end

function Page:header(title, left, right)
    local s, c = self.s, self.c
    s:rect(1, 1, s.w, 1, c.header)
    s:rect(1, 2, s.w, 1, c.div)
    s:field(1, 1, s.w, title, c.text, c.header, "center")
    local brand = right or "ZelOS"
    s:text(s.w - #brand, 1, brand, c.brand, c.header)
    if left then s:text(2, 1, util.fitText(left, math.max(0, math.floor(s.w / 2) - #title / 2 - 3)), c.headerText, c.header) end
end

function Page:card(x, y, w, h, title, accent, right)
    local s, c = self.s, self.c
    if w < 4 or h < 3 then return end
    s:rect(x, y, w, h, c.div)
    s:rect(x + 1, y + 1, w - 2, h - 2, c.inset)
    s:rect(x + 1, y + 1, 1, h - 2, accent or c.accent)
    local avail = w - 5
    if right and right ~= "" then
        right = util.fitText(right, math.max(0, avail - 4))
        s:text(x + 3 + avail - #right, y, right, c.muted, c.div)
        avail = avail - #right - 2
    end
    if title then s:field(x + 3, y, math.max(0, avail), string.upper(title), c.text, c.div) end
    return x + 3, y + 2, w - 5, h - 3
end

function Page:container(title, subtitle)
    local s = self.s
    self:header(title)
    local y = 3
    if subtitle then
        s:field(2, 3, s.w - 2, subtitle, self.c.muted, self.c.bg)
        y = 4
    end
    y = y + 1
    local h = math.max(6, s.h - y)
    return self:card(2, y, s.w - 2, h, nil, self.c.accent)
end

function Page:bar(x, y, w, h, pct, color)
    if w <= 0 then return end
    pct = util.clamp(tonumber(pct) or 0, 0, 100)
    local filled = math.floor(w * pct / 100 + 0.5)
    if pct > 0 and filled == 0 then filled = 1 end
    if pct < 100 and filled == w and w > 1 then filled = w - 1 end
    if self.s.isColor then
        if filled > 0 then self.s:rect(x, y, filled, h, color or self.c.ok) end
        if w - filled > 0 then self.s:rect(x + filled, y, w - filled, h, self.c.div) end
    else
        for r = 0, h - 1 do
            self.s:text(x, y + r, string.rep("#", filled) .. string.rep(".", w - filled), self.c.text, self.c.inset)
        end
    end
end

function Page:kv(x, y, w, label, value, color)
    if w <= 0 then return end
    value = util.sanitize(value)
    if #value > w then value = util.fitText(value, w) end
    local labelW = w - #value - 1
    if labelW > 0 then self.s:field(x, y, labelW, label, self.c.muted, self.c.inset) end
    self.s:text(x + w - #value, y, value, color or self.c.text, self.c.inset)
end

function Page:button(x, y, w, h, label, bg, fg, action)
    if w <= 0 or h <= 0 then return end
    bg = bg or self.c.brand
    self.s:rect(x, y, w, h, bg)
    self.s:field(x, y + math.floor(h / 2), w, label, fg or self.c.text, bg, "center")
    if action ~= nil then self:hotspot(x, y, w, h, action) end
end

function Page:pill(x, y, label, bg, fg)
    local s = self.s.isColor and (" " .. label .. " ") or ("[" .. label .. "]")
    self.s:text(x, y, s, self.s.isColor and (fg or colors.white) or self.c.text, self.s.isColor and bg or self.c.inset)
    return #s
end

function Page:tabs(x, y, w, items, active, h)
    h = h or 1
    local gap = 1
    local n = #items
    if n == 0 then return end
    local each = math.floor((w - gap * (n - 1)) / n)
    local extra = w - gap * (n - 1) - each * n
    local cx = x
    for i, it in ipairs(items) do
        local ww = each + ((i <= extra) and 1 or 0)
        local on = it.id == active
        local label = it.label
        if on and not self.s.isColor then label = ">" .. label .. "<" end
        self:button(cx, y, ww, h, label, on and (it.color or self.c.brand) or self.c.div, on and self.c.text or self.c.muted, "tab:" .. it.id)
        cx = cx + ww + gap
    end
end

function Page:wrapped(x, y, w, maxRows, text, fg, bg)
    if w <= 0 or maxRows <= 0 then return 0 end
    local lines = util.wrapText(util.sanitize(text), w)
    local n = math.min(#lines, maxRows)
    for i = 1, n do
        local line = lines[i]
        if i == maxRows and #lines > maxRows then line = util.fitText(line .. "...", w) end
        self.s:field(x, y + i - 1, w, line, fg or self.c.text, bg or self.c.inset)
    end
    return n
end

function Page:list(x, y, w, h, rows, offset, selected, actionPrefix)
    offset = util.clamp(offset or 0, 0, math.max(0, #rows - h))
    for r = 1, h do
        local i = offset + r
        local row = rows[i]
        if row then
            local text = type(row) == "table" and row.text or row
            local fg = type(row) == "table" and row.color or self.c.text
            local bg = self.c.inset
            if selected and selected == i then
                bg = self.c.selected
                fg = self.c.text
            end
            if selected and not self.s.isColor then text = ((selected == i) and ">" or " ") .. tostring(text or "") end
            local rt = type(row) == "table" and row.right and util.fitText(util.sanitize(row.right), math.max(0, w - 2)) or nil
            local leftW = w
            if rt and #rt > 0 then leftW = math.max(1, w - #rt - 1) end
            self.s:field(x, y + r - 1, w, "", fg, bg)
            self.s:field(x, y + r - 1, leftW, text, fg, bg)
            if rt and #rt > 0 then
                self.s:text(x + w - #rt, y + r - 1, rt, row.rightColor or self.c.muted, bg)
            end
            if actionPrefix then self:hotspot(x, y + r - 1, w, 1, actionPrefix .. i) end
        else
            self.s:field(x, y + r - 1, w, "", self.c.text, self.c.inset)
        end
    end
    if #rows > h then
        local pos = h > 1 and math.floor((h - 1) * offset / math.max(1, #rows - h)) or 0
        self.s:rect(x + w, y, 1, h, self.c.div)
        self.s:rect(x + w, y + pos, 1, 1, self.c.accent)
    end
    return offset, math.max(0, #rows - h)
end

function Page:inputBox(x, y, w, value, mask, focused)
    local shown = mask and string.rep("*", #value) or value
    if #shown > w - 1 then shown = shown:sub(#shown - w + 2) end
    local bg = focused and self.c.field or self.c.inset
    if not self.s.isColor then bg = colors.black end
    self.s:rect(x, y, w, 1, bg)
    self.s:text(x, y, shown, self.c.text, bg)
    if focused then self.s:setCursor(x + #shown, y) end
end

local function isBack(action)
    return action == "back"
end

local function isCtrlKey(k)
    return k ~= nil and (k == keys.leftCtrl or k == keys.rightCtrl)
end

M.isCtrl = isCtrlKey

function M.footerButtons(page, x, y, w, left, right)
    if right then
        local rw = #right.label + 2
        page:button(x + w - rw, y, rw, 1, right.label, right.bg or page.c.brand, page.c.text, right.action)
    end
    if left then
        local lw = #left.label + 2
        page:button(x, y, lw, 1, left.label, left.bg or page.c.div, page.c.text, left.action)
    end
end

function M.form(surf, opts)
    local fields = opts.fields
    for _, f in ipairs(fields) do f.value = f.value or "" end
    local focus = 1
    local errMsg = opts.error
    while true do
        local page = M.page(surf)
        local ix, iy, iw, ih = page:container(opts.title, opts.subtitle)
        local y = iy
        if opts.intro then
            local room = math.min(4, ih - 4 - 2 * (#fields - 1))
            if room > 0 then
                local n = page:wrapped(ix, y, iw, room, opts.intro, page.c.muted)
                y = y + n + 1
            end
        end
        local labelW = 0
        for _, f in ipairs(fields) do labelW = math.max(labelW, #f.label) end
        labelW = math.min(labelW, math.floor(iw / 2))
        for i, f in ipairs(fields) do
            if y > iy + ih - 3 then break end
            surf:field(ix, y, labelW, f.label, page.c.text, page.c.inset)
            page:inputBox(ix + labelW + 1, y, iw - labelW - 1, f.value, f.mask, i == focus)
            page:hotspot(ix, y, iw, 1, "field:" .. i)
            if f.hint and i == focus then surf:field(ix + labelW + 1, y + 1, iw - labelW - 1, f.hint, page.c.dim, page.c.inset) end
            y = y + 2
        end
        local by = iy + ih - 1
        if errMsg then surf:field(ix, by - 1, iw, errMsg, page.c.bad, page.c.inset) end
        M.footerButtons(page, ix, by, iw, { label = opts.backLabel or "Back", action = "back" }, { label = opts.submit or "OK", action = "submit" })
        surf:flush()
        local ev, a, b, c = compat.pullUI()
        local action
        local px, py = surf:pointer(ev, a, b, c)
        if px then action = page:hit(px, py) end
        if ev == "char" then
            local f = fields[focus]
            if not f.maxLen or #f.value < f.maxLen then f.value = f.value .. a end
            errMsg = nil
        elseif ev == "key" then
            if isCtrlKey(a) then
                action = "back"
            elseif a == keys.backspace then
                fields[focus].value = fields[focus].value:sub(1, -2)
            elseif a == keys.tab or a == keys.down then
                focus = focus % #fields + 1
            elseif a == keys.up then
                focus = (focus - 2) % #fields + 1
            elseif a == keys.enter then
                if focus < #fields then focus = focus + 1 else action = "submit" end
            end
        end
        if action then
            if isBack(action) then
                surf.target.setCursorBlink(false)
                return nil
            elseif action == "submit" then
                local values = {}
                local bad
                for i, f in ipairs(fields) do
                    local v = f.trim == false and f.value or util.trim(f.value)
                    if f.required and v == "" then bad = bad or { i, f.label:gsub(":%s*$", "") .. " is required." } end
                    if f.numeric and v ~= "" and not tonumber(v) then bad = bad or { i, f.label:gsub(":%s*$", "") .. " must be a number." } end
                    if f.validate and v ~= "" then
                        local ok, msg = f.validate(v)
                        if not ok then bad = bad or { i, msg } end
                    end
                    values[f.key or i] = f.numeric and tonumber(v) or v
                end
                if bad then
                    focus = bad[1]
                    errMsg = bad[2]
                else
                    surf.target.setCursorBlink(false)
                    return values
                end
            else
                local idx = tonumber(tostring(action):match("^field:(%d+)$"))
                if idx then focus = idx end
            end
        end
    end
end

function M.ask(surf, title, label, opts)
    opts = opts or {}
    local r = M.form(surf, {
        title = title, intro = opts.intro, submit = opts.submit, subtitle = opts.subtitle,
        fields = { { label = label, mask = opts.mask, value = opts.value, required = opts.required } },
    })
    if not r then return nil end
    return r[1]
end

function M.menu(surf, opts)
    local items = opts.items
    local sel = opts.selected or 1
    local offset = 0
    local timer = opts.refresh and os.startTimer(opts.interval or 1)
    while true do
        local page = M.page(surf)
        local ix, iy, iw, ih = page:container(opts.title, opts.subtitle)
        local listTop = iy
        if opts.draw then
            local used = opts.draw(page, ix, iy, iw, ih) or 0
            listTop = iy + used
        end
        local rows = {}
        for i, it in ipairs(items) do
            rows[i] = { text = (opts.numbered == false and "" or (i .. ". ")) .. it.label, right = it.hint, color = it.color, rightColor = it.hintColor }
        end
        local listH = math.max(1, iy + ih - 2 - listTop)
        if sel > offset + listH then offset = sel - listH end
        if sel <= offset then offset = sel - 1 end
        offset = page:list(ix, listTop, iw - 1, listH, rows, offset, sel, "item:")
        if opts.back ~= false then
            M.footerButtons(page, ix, iy + ih - 1, iw, { label = opts.backLabel or "Back", action = "back" }, opts.footerRight)
        elseif opts.footerRight then
            M.footerButtons(page, ix, iy + ih - 1, iw, nil, opts.footerRight)
        end
        if opts.footer then surf:field(ix + 8, iy + ih - 1, iw - 16, opts.footer, page.c.muted, page.c.inset, "center") end
        surf:flush()
        local ev, a, b, c = compat.pullUI()
        local action
        local px, py, kind, btn = surf:pointer(ev, a, b, c)
        if px then
            if kind == "scroll" then
                sel = util.clamp(sel + btn, 1, #items)
            else
                action = page:hit(px, py)
            end
        end
        if ev == "key" then
            if a == keys.up then
                sel = sel > 1 and sel - 1 or #items
            elseif a == keys.down then
                sel = sel < #items and sel + 1 or 1
            elseif a == keys.enter then
                action = "item:" .. sel
            elseif (a == keys.backspace or isCtrlKey(a)) and opts.back ~= false then
                action = "back"
            end
        elseif ev == "char" then
            local n = tonumber(a)
            if n and items[n] then action = "item:" .. n end
        elseif ev == "timer" and a == timer then
            timer = os.startTimer(opts.interval or 1)
            if opts.refresh then
                local r = opts.refresh()
                if r ~= nil then return r end
            end
        elseif opts.onEvent then
            local r = opts.onEvent(ev, a, b, c)
            if r ~= nil then return r end
        end
        if action then
            if action == "back" then return nil end
            local idx = tonumber(tostring(action):match("^item:(%d+)$"))
            if idx then
                if sel == idx or kind ~= nil or ev ~= "key" or a == keys.enter then
                    sel = idx
                    if opts.keepOpen then
                        local r = items[idx].action and items[idx].action(idx)
                        if r == "exit" then return nil end
                    else
                        return idx, items[idx]
                    end
                end
            elseif opts.onAction then
                local r = opts.onAction(action)
                if r ~= nil then return r end
            end
        end
    end
end

function M.message(surf, title, lines, opts)
    opts = opts or {}
    if type(lines) == "string" then lines = { lines } end
    local offset = 0
    while true do
        local page = M.page(surf)
        local ix, iy, iw, ih = page:container(title, opts.subtitle)
        local flat = {}
        for _, l in ipairs(lines) do
            local color = opts.color
            local text = l
            if type(l) == "table" then text, color = l.text, l.color end
            for _, w in ipairs(util.wrapText(util.sanitize(text), iw - 1)) do
                flat[#flat + 1] = { text = w, color = color }
            end
        end
        offset = page:list(ix, iy, iw - 1, ih - 2, flat, offset)
        M.footerButtons(page, ix, iy + ih - 1, iw, nil, { label = opts.button or "OK", action = "ok" })
        surf:flush()
        local ev, a, b, c = compat.pullUI()
        local px, py, kind, btn = surf:pointer(ev, a, b, c)
        if px then
            if kind == "scroll" then
                offset = math.max(0, offset + btn)
            elseif page:hit(px, py) == "ok" then
                return true
            end
        elseif ev == "key" then
            if a == keys.enter or a == keys.backspace or isCtrlKey(a) then return true end
            if a == keys.down then offset = offset + 1 end
            if a == keys.up then offset = math.max(0, offset - 1) end
        end
    end
end

function M.confirm(surf, title, text, opts)
    opts = opts or {}
    while true do
        local page = M.page(surf)
        local ix, iy, iw, ih = page:container(title)
        page:wrapped(ix, iy, iw, ih - 3, text, opts.color or page.c.text)
        local bw = math.min(12, math.floor((iw - 2) / 2))
        page:button(ix, iy + ih - 1, bw, 1, opts.no or "Cancel", page.c.div, page.c.text, "no")
        page:button(ix + iw - bw, iy + ih - 1, bw, 1, opts.yes or "Confirm", opts.danger and page.c.bad or page.c.brand, page.c.text, "yes")
        surf:flush()
        local ev, a, b, c = compat.pullUI()
        local px, py = surf:pointer(ev, a, b, c)
        if px then
            local act = page:hit(px, py)
            if act == "yes" then return true end
            if act == "no" then return false end
        elseif ev == "key" then
            if a == keys.enter then return true end
            if a == keys.backspace or isCtrlKey(a) then return false end
        elseif ev == "char" then
            if a == "y" or a == "Y" then return true end
            if a == "n" or a == "N" then return false end
        end
    end
end

function M.busy(surf, title, text)
    local page = M.page(surf)
    local ix, iy, iw, ih = page:container(title)
    page:wrapped(ix, iy + math.floor(ih / 2) - 1, iw, 3, text, page.c.muted)
    surf:flush()
end

function M.attachMonitor(name, scale)
    if not name or not peripheral.isPresent(name) or peripheral.getType(name) ~= "monitor" then return nil end
    local m = peripheral.wrap(name)
    if scale then pcall(m.setTextScale, scale) end
    return M.surface(m, name)
end

function M.findMonitors()
    local out = {}
    if not peripheral.getNames then return out end
    for _, n in ipairs(peripheral.getNames()) do
        if peripheral.getType(n) == "monitor" then out[#out + 1] = n end
    end
    table.sort(out)
    return out
end

return M
