local M = {}

function M.new(w, h, color)
    w, h = w or 51, h or 19
    local t = { lines = {}, x = 1, y = 1, blink = false }
    local function clearAll()
        for y = 1, h do t.lines[y] = string.rep(" ", w) end
    end
    clearAll()
    function t.getSize() return w, h end
    function t.isColor() return color ~= false end
    function t.isColour() return color ~= false end
    function t.setBackgroundColor() end
    function t.setBackgroundColour() end
    function t.setTextColor() end
    function t.setTextColour() end
    function t.setCursorPos(x, y) t.x, t.y = x, y end
    function t.getCursorPos() return t.x, t.y end
    function t.setCursorBlink(b) t.blink = b end
    function t.clear() clearAll() end
    function t.clearLine() if t.lines[t.y] then t.lines[t.y] = string.rep(" ", w) end end
    function t.scroll() end
    function t.write(s)
        s = tostring(s)
        local line = t.lines[t.y]
        if line then
            local before = line:sub(1, t.x - 1)
            local after = line:sub(t.x + #s)
            t.lines[t.y] = (before .. s .. after):sub(1, w)
        end
        t.x = t.x + #s
    end
    function t.text()
        return table.concat(t.lines, "\n")
    end
    function t.has(s)
        return t.text():find(s, 1, true) ~= nil
    end
    return t
end

M.script = {}

local function feedNext(filter)
    local pending = 0
    if M.queueRef then pending = #M.queueRef() end
    if filter == nil and pending == 0 and #M.script > 0 then
        local nextEv = M.script[1]
        if nextEv.wait then
            if not M.waitUntil then M.waitUntil = os.clock() + nextEv.wait end
            if os.clock() >= M.waitUntil then
                table.remove(M.script, 1)
                M.waitUntil = nil
            end
        end
        nextEv = M.script[1]
        if nextEv and not nextEv.wait then
            table.remove(M.script, 1)
            os.queueEvent(unpack(nextEv))
        end
    end
end

function M.feeder()
    if M.feeding then return end
    M.feeding = true
    local base = os.pullEvent
    M.waitUntil = nil
    os.pullEvent = function(filter)
        feedNext(filter)
        return base(filter)
    end
end

function M.feedRaw()
    if M.feedingRaw then return end
    M.feedingRaw = true
    local base = os.pullEventRaw
    os.pullEventRaw = function(filter)
        feedNext(filter)
        return base(filter)
    end
end

function M.reset()
    M.script = {}
    M.waitUntil = nil
    if M.queueRef then
        local q = M.queueRef()
        for i = #q, 1, -1 do q[i] = nil end
    end
end

function M.wait(seconds)
    M.script[#M.script + 1] = { wait = seconds }
end

function M.event(...)
    M.script[#M.script + 1] = { ... }
end

function M.install(w, h, color, queueRef)
    M.queueRef = queueRef
    M.feeder()
    local t = M.new(w, h, color)
    _G.term = t
    _G.keys = _G.keys or {}
    local k = _G.keys
    k.enter = k.enter or 28
    k.backspace = k.backspace or 14
    k.tab = k.tab or 15
    k.up = k.up or 200
    k.down = k.down or 208
    k.left = k.left or 203
    k.right = k.right or 205
    k.leftCtrl = k.leftCtrl or 29
    k.rightCtrl = k.rightCtrl or 157
    return t
end

function M.typeText(s)
    for i = 1, #s do M.event("char", s:sub(i, i)) end
end

function M.key(name, n)
    for _ = 1, n or 1 do M.event("key", keys[name]) end
end

function M.line(s)
    M.typeText(s)
    M.key("enter")
end

return M
