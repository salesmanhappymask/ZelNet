local marshal = require("sim.marshal")
local util = require("sim.util")

local M = {}

local fail = util.fail
local floor = math.floor
local sub, rep, byte, char, concat = string.sub, string.rep, string.byte, string.char, table.concat

local HEX = "0123456789abcdef"

local Terminal = {}
Terminal.__index = Terminal
M.Terminal = Terminal

function Terminal.new(w, h, color)
    local self = setmetatable({ w = w, h = h, color = color and true or false }, Terminal)
    self:reset()
    return self
end

function Terminal:reset()
    self.x, self.y = 0, 0
    self.blink = false
    self.fg, self.bg = 0, 15
    self.text, self.tc, self.bc = {}, {}, {}
    for y = 0, self.h - 1 do self:blankLine(y) end
    self.changed = true
end

function Terminal:blankLine(y)
    self.text[y] = rep(" ", self.w)
    self.tc[y] = rep(sub(HEX, self.fg + 1, self.fg + 1), self.w)
    self.bc[y] = rep(sub(HEX, self.bg + 1, self.bg + 1), self.w)
end

function Terminal:resize(w, h)
    if w == self.w and h == self.h then return false end
    local oldText, oldTc, oldBc, oldH = self.text, self.tc, self.bc, self.h
    self.w, self.h = w, h
    self.text, self.tc, self.bc = {}, {}, {}
    for y = 0, h - 1 do
        self:blankLine(y)
        if y < oldH then
            local t, a, b = oldText[y], oldTc[y], oldBc[y]
            if #t >= w then
                self.text[y], self.tc[y], self.bc[y] = sub(t, 1, w), sub(a, 1, w), sub(b, 1, w)
            else
                self.text[y] = t .. sub(self.text[y], #t + 1)
                self.tc[y] = a .. sub(self.tc[y], #a + 1)
                self.bc[y] = b .. sub(self.bc[y], #b + 1)
            end
        end
    end
    self.changed = true
    return true
end

local function toCells(text)
    if not text:find("[\128-\255]") then return text end
    local units, n = marshal.luajDecode(text)
    local out = {}
    for i = 1, n do
        local u = units[i]
        if u < 256 then out[i] = char(u) else out[i] = "?" end
    end
    return concat(out)
end

function Terminal:write(text)
    text = toCells(text)
    local len = #text
    local y = self.y
    if y >= 0 and y < self.h then
        local x = self.x
        local w = self.w
        local spaceLeft = w - x
        if spaceLeft <= w + len then
            local writeX = x
            local t = text
            if spaceLeft > w then
                writeX = 0
                t = sub(t, spaceLeft - w + 1)
                spaceLeft = w
            end
            t = t:gsub("\t", " ")
            if spaceLeft > 0 and #t > 0 then
                local n = math.min(#t, spaceLeft)
                t = sub(t, 1, n)
                local line = self.text[y]
                self.text[y] = sub(line, 1, writeX) .. t .. sub(line, writeX + n + 1)
                local fc = rep(sub(HEX, self.fg + 1, self.fg + 1), n)
                local bc = rep(sub(HEX, self.bg + 1, self.bg + 1), n)
                self.tc[y] = sub(self.tc[y], 1, writeX) .. fc .. sub(self.tc[y], writeX + n + 1)
                self.bc[y] = sub(self.bc[y], 1, writeX) .. bc .. sub(self.bc[y], writeX + n + 1)
                self.changed = true
            end
        end
    end
    self.x = self.x + len
end

function Terminal:scroll(n)
    if n == 0 then return end
    local text, tc, bc = {}, {}, {}
    for y = 0, self.h - 1 do
        local oy = y + n
        if oy >= 0 and oy < self.h then
            text[y], tc[y], bc[y] = self.text[oy], self.tc[oy], self.bc[oy]
        else
            text[y] = rep(" ", self.w)
            tc[y] = rep(sub(HEX, self.fg + 1, self.fg + 1), self.w)
            bc[y] = rep(sub(HEX, self.bg + 1, self.bg + 1), self.w)
        end
    end
    self.text, self.tc, self.bc = text, tc, bc
    self.changed = true
end

function Terminal:clear()
    for y = 0, self.h - 1 do self:blankLine(y) end
    self.changed = true
end

function Terminal:clearLine()
    if self.y >= 0 and self.y < self.h then
        self:blankLine(self.y)
        self.changed = true
    end
end

function Terminal:lines()
    local out = {}
    for y = 0, self.h - 1 do out[y + 1] = self.text[y] end
    return out
end

function Terminal:textColours(y)
    return self.tc[y - 1]
end

function Terminal:backgroundColours(y)
    return self.bc[y - 1]
end

function Terminal:cell(x, y)
    local line = self.text[y - 1]
    if not line or x < 1 or x > self.w then return nil end
    local f = tonumber(sub(self.tc[y - 1], x, x), 16)
    local b = tonumber(sub(self.bc[y - 1], x, x), 16)
    return sub(line, x, x), 2 ^ f, 2 ^ b
end

function Terminal:screenText()
    local out = {}
    for y = 0, self.h - 1 do out[y + 1] = (self.text[y]:gsub("%s+$", "")) end
    local last = #out
    while last > 0 and out[last] == "" do last = last - 1 end
    return concat(out, "\n", 1, last)
end

local function highestBit(v)
    local bit = 0
    while v > 0 do
        v = floor(v / 2)
        bit = bit + 1
    end
    return bit
end

function M.parseColour(args, n, color)
    local c = args[1]
    if n ~= 1 or type(c) ~= "number" then fail("Expected number") end
    local v = util.toInt(c)
    if v <= 0 then fail("Colour out of range") end
    local idx = 16 - highestBit(v)
    if idx < 0 or idx > 15 then fail("Colour out of range") end
    if not color and idx ~= 0 and idx ~= 15 then fail("Colour not supported") end
    return 15 - idx
end

local function textOf(v)
    if v == nil then return "" end
    if type(v) == "string" then return v end
    return marshal.javaToString(marshal.toJava(v))
end

function M.methods(getTerm, hooks)
    local m = {}
    hooks = hooks or {}
    m.write = function(...)
        local t = getTerm()
        local text = textOf((...))
        if hooks.write then hooks.write(text, t) end
        t:write(text)
    end
    m.scroll = function(...)
        local n = (...)
        if select("#", ...) < 1 or type(n) ~= "number" then fail("Expected number") end
        local t = getTerm()
        if hooks.scroll then hooks.scroll(n, t) end
        t:scroll(util.toInt(n))
    end
    m.setCursorPos = function(...)
        local x, y = ...
        if select("#", ...) < 2 or type(x) ~= "number" or type(y) ~= "number" then fail("Expected number, number") end
        local t = getTerm()
        local nx, ny = util.toInt(x) - 1, util.toInt(y) - 1
        if hooks.move then hooks.move(nx, ny, t) end
        t.x, t.y = nx, ny
        t.changed = true
    end
    m.setCursorBlink = function(...)
        local b = ...
        if select("#", ...) < 1 or type(b) ~= "boolean" then fail("Expected boolean") end
        getTerm().blink = b
    end
    m.getCursorPos = function()
        local t = getTerm()
        return t.x + 1, t.y + 1
    end
    m.getSize = function()
        local t = getTerm()
        return t.w, t.h
    end
    m.clear = function()
        getTerm():clear()
    end
    m.clearLine = function()
        getTerm():clearLine()
    end
    m.setTextColour = function(...)
        local t = getTerm()
        t.fg = M.parseColour({ ... }, select("#", ...), t.color)
    end
    m.setTextColor = m.setTextColour
    m.setBackgroundColour = function(...)
        local t = getTerm()
        t.bg = M.parseColour({ ... }, select("#", ...), t.color)
    end
    m.setBackgroundColor = m.setBackgroundColour
    m.isColour = function()
        return getTerm().color
    end
    m.isColor = m.isColour
    return m
end

M.TERM_METHODS = { "write", "scroll", "setCursorPos", "setCursorBlink", "getCursorPos", "getSize", "clear", "clearLine", "setTextColour", "setTextColor", "setBackgroundColour", "setBackgroundColor", "isColour", "isColor" }

function M.makeApi(getTerm, hooks)
    local raw = M.methods(getTerm, hooks)
    local api = {}
    for _, name in ipairs(M.TERM_METHODS) do api[name] = util.native(raw[name]) end
    return api
end

function M.monitorSize(blocksW, blocksH, scale)
    local w = floor((blocksW - 0.3125) / (scale * 6 * 0.015625) + 0.5)
    local h = floor((blocksH - 0.3125) / (scale * 9 * 0.015625) + 0.5)
    return math.max(w, 1), math.max(h, 1)
end

return M
