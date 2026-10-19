local M = {}

local byte, char, concat, find, format = string.byte, string.char, table.concat, string.find, string.format
local floor = math.floor

function M.luajDecode(s)
    local len = #s
    local i, n = 1, 0
    while i <= len do
        local b = byte(s, i)
        i = i + 1
        if b >= 0xE0 then
            i = i + 2
        elseif b >= 0xC0 then
            i = i + 1
        end
        n = n + 1
    end
    local units = {}
    local k = 0
    i = 1
    while i <= len do
        local b = byte(s, i)
        i = i + 1
        local u
        if b < 0x80 or i > len then
            if b < 0x80 then u = b else u = 0xFF00 + b end
        elseif b < 0xE0 or i >= len then
            u = (b % 64) * 64 + byte(s, i) % 64
            i = i + 1
        else
            u = (b % 16) * 4096 + (byte(s, i) % 64) * 64 + byte(s, i + 1) % 64
            i = i + 2
        end
        k = k + 1
        units[k] = u
    end
    for x = k + 1, n do units[x] = 0 end
    return units, n
end

function M.luajEncode(units, n)
    n = n or #units
    local out = {}
    for i = 1, n do
        local c = units[i]
        if c < 0x80 then
            out[i] = char(c)
        elseif c < 0x800 then
            out[i] = char(0xC0 + floor(c / 64) % 32, 0x80 + c % 64)
        else
            out[i] = char(0xE0 + floor(c / 4096) % 16, 0x80 + floor(c / 64) % 64, 0x80 + c % 64)
        end
    end
    return concat(out)
end

local function isAscii(s)
    return not find(s, "[\128-\255]")
end
M.isAscii = isAscii

function M.jstr(s)
    if isAscii(s) then return s end
    return M.luajEncode(M.luajDecode(s))
end

function M.javaEncodeUtf8(units, n)
    n = n or #units
    local out = {}
    local i = 1
    while i <= n do
        local c = units[i]
        if c < 0x80 then
            out[#out + 1] = char(c)
        elseif c < 0x800 then
            out[#out + 1] = char(0xC0 + floor(c / 64), 0x80 + c % 64)
        elseif c >= 0xD800 and c <= 0xDBFF then
            local d = units[i + 1]
            if i < n and d and d >= 0xDC00 and d <= 0xDFFF then
                local cp = 0x10000 + (c - 0xD800) * 1024 + (d - 0xDC00)
                out[#out + 1] = char(0xF0 + floor(cp / 262144), 0x80 + floor(cp / 4096) % 64, 0x80 + floor(cp / 64) % 64, 0x80 + cp % 64)
                i = i + 1
            else
                out[#out + 1] = "?"
            end
        elseif c >= 0xDC00 and c <= 0xDFFF then
            out[#out + 1] = "?"
        else
            out[#out + 1] = char(0xE0 + floor(c / 4096), 0x80 + floor(c / 64) % 64, 0x80 + c % 64)
        end
        i = i + 1
    end
    return concat(out)
end

function M.javaDecodeUtf8(s)
    local units, n = {}, 0
    local len = #s
    local i = 1
    local function cont(p)
        local b = byte(s, p)
        return b and b >= 0x80 and b < 0xC0 and b
    end
    while i <= len do
        local b = byte(s, i)
        if b < 0x80 then
            n = n + 1
            units[n] = b
            i = i + 1
        elseif b >= 0xC2 and b < 0xE0 then
            local c1 = cont(i + 1)
            if c1 then
                n = n + 1
                units[n] = (b - 0xC0) * 64 + (c1 - 0x80)
                i = i + 2
            else
                n = n + 1
                units[n] = 0xFFFD
                i = i + 1
            end
        elseif b >= 0xE0 and b < 0xF0 then
            local c1 = cont(i + 1)
            local okc1 = c1 and not (b == 0xE0 and c1 < 0xA0) and not (b == 0xED and c1 >= 0xA0)
            if not okc1 then
                n = n + 1
                units[n] = 0xFFFD
                i = i + 1
            else
                local c2 = cont(i + 2)
                if not c2 then
                    n = n + 1
                    units[n] = 0xFFFD
                    i = i + 2
                else
                    n = n + 1
                    units[n] = (b - 0xE0) * 4096 + (c1 - 0x80) * 64 + (c2 - 0x80)
                    i = i + 3
                end
            end
        elseif b >= 0xF0 and b < 0xF5 then
            local c1 = cont(i + 1)
            local okc1 = c1 and not (b == 0xF0 and c1 < 0x90) and not (b == 0xF4 and c1 >= 0x90)
            if not okc1 then
                n = n + 1
                units[n] = 0xFFFD
                i = i + 1
            else
                local c2 = cont(i + 2)
                if not c2 then
                    n = n + 1
                    units[n] = 0xFFFD
                    i = i + 2
                else
                    local c3 = cont(i + 3)
                    if not c3 then
                        n = n + 1
                        units[n] = 0xFFFD
                        i = i + 3
                    else
                        local cp = (b - 0xF0) * 262144 + (c1 - 0x80) * 4096 + (c2 - 0x80) * 64 + (c3 - 0x80)
                        cp = cp - 0x10000
                        n = n + 1
                        units[n] = 0xD800 + floor(cp / 1024)
                        n = n + 1
                        units[n] = 0xDC00 + cp % 1024
                        i = i + 4
                    end
                end
            end
        else
            n = n + 1
            units[n] = 0xFFFD
            i = i + 1
        end
    end
    return units, n
end

function M.textToFileBytes(s)
    if isAscii(s) then return s end
    return M.javaEncodeUtf8(M.luajDecode(s))
end

function M.fileBytesToText(s)
    if isAscii(s) then return s end
    return M.luajEncode(M.javaDecodeUtf8(s))
end

function M.toJava(v, seen)
    local t = type(v)
    if t == "string" then
        if isAscii(v) then return v end
        return M.jstr(v)
    elseif t == "number" or t == "boolean" then
        return v
    elseif t == "table" then
        seen = seen or {}
        local done = seen[v]
        if done then return done end
        local out = {}
        seen[v] = out
        for k, x in next, v do
            local jk = M.toJava(k, seen)
            local jx = M.toJava(x, seen)
            if jk ~= nil and jx ~= nil then out[jk] = jx end
        end
        return out
    end
    return nil
end

function M.fromJava(v, seen)
    if type(v) ~= "table" then return v end
    seen = seen or {}
    local done = seen[v]
    if done then return done end
    local out = {}
    seen[v] = out
    for k, x in next, v do
        out[M.fromJava(k, seen)] = M.fromJava(x, seen)
    end
    return out
end

function M.packJava(...)
    local n = select("#", ...)
    local args = { ... }
    local seen = {}
    for i = 1, n do args[i] = M.toJava(args[i], seen) end
    return args, n
end

function M.javaDouble(d)
    if d ~= d then return "NaN" end
    if d == math.huge then return "Infinity" end
    if d == -math.huge then return "-Infinity" end
    if d == 0 then
        if 1 / d < 0 then return "-0.0" end
        return "0.0"
    end
    local m, e
    for p = 0, 16 do
        local str = format("%." .. p .. "e", d)
        if tonumber(str) == d then
            m, e = str:match("^(-?[%d%.]+)e([-+]%d+)$")
            break
        end
    end
    if not m then
        m, e = format("%.16e", d):match("^(-?[%d%.]+)e([-+]%d+)$")
    end
    local neg = m:sub(1, 1) == "-"
    if neg then m = m:sub(2) end
    local digits = m:gsub("%.", "")
    digits = digits:gsub("0+$", "")
    if digits == "" then digits = "0" end
    e = tonumber(e)
    local a = math.abs(d)
    local out
    if a >= 1e-3 and a < 1e7 then
        if e >= 0 then
            local intPart = digits:sub(1, e + 1)
            if #intPart < e + 1 then intPart = intPart .. string.rep("0", e + 1 - #intPart) end
            local frac = digits:sub(e + 2)
            if frac == "" then frac = "0" end
            out = intPart .. "." .. frac
        else
            out = "0." .. string.rep("0", -e - 1) .. digits
        end
    else
        local frac = digits:sub(2)
        if frac == "" then frac = "0" end
        out = digits:sub(1, 1) .. "." .. frac .. "E" .. e
    end
    if neg then out = "-" .. out end
    return out
end

function M.javaToString(v, seen)
    local t = type(v)
    if t == "string" then return v end
    if t == "number" then return M.javaDouble(v) end
    if t == "boolean" then return tostring(v) end
    if t == "table" then
        seen = seen or {}
        if seen[v] then return "(this Map)" end
        seen[v] = true
        local parts = {}
        for k, x in next, v do
            parts[#parts + 1] = M.javaToString(k, seen) .. "=" .. M.javaToString(x, seen)
        end
        seen[v] = nil
        return "{" .. concat(parts, ", ") .. "}"
    end
    return "null"
end

return M
