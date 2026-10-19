local need = ...
local compat = need("compat")

local M = {}

local ESC = {}
for i = 0, 255 do
    local c = string.char(i)
    if i < 32 or i > 126 then
        local d = tostring(i)
        ESC[c] = "\\" .. string.rep("0", 3 - #d) .. d
    end
end
ESC["\\"] = "\\\\"
ESC["\""] = "\\\""

local function quote(s)
    return "\"" .. s:gsub("[%z\1-\31\"\\\127-\255]", ESC) .. "\""
end

local function numberText(v)
    if v ~= v then return "0/0" end
    if v == math.huge then return "1/0" end
    if v == -math.huge then return "-1/0" end
    if v == math.floor(v) and v > -1e15 and v < 1e15 then
        local s = tostring(v)
        if s:find("[eE%.]") then
            local neg = v < 0
            local a = math.abs(v)
            local digits = {}
            while a > 0 do
                local d = a % 10
                digits[#digits + 1] = tostring(d)
                a = (a - d) / 10
            end
            if #digits == 0 then digits[1] = "0" end
            local out = {}
            for i = #digits, 1, -1 do out[#out + 1] = digits[i] end
            s = (neg and "-" or "") .. table.concat(out)
        end
        return s
    end
    return tostring(v)
end

local KEYWORDS = {
    ["and"] = true, ["break"] = true, ["do"] = true, ["else"] = true, ["elseif"] = true, ["end"] = true,
    ["false"] = true, ["for"] = true, ["function"] = true, ["if"] = true, ["in"] = true, ["local"] = true,
    ["nil"] = true, ["not"] = true, ["or"] = true, ["repeat"] = true, ["return"] = true, ["then"] = true,
    ["true"] = true, ["until"] = true, ["while"] = true,
}

local function encode(v, out, seen, depth)
    local tp = type(v)
    if tp == "string" then
        out[#out + 1] = quote(v)
    elseif tp == "number" then
        out[#out + 1] = numberText(v)
    elseif tp == "boolean" then
        out[#out + 1] = v and "true" or "false"
    elseif tp == "nil" then
        out[#out + 1] = "nil"
    elseif tp == "table" then
        if seen[v] then error("codec: recursive table", 0) end
        if depth > 48 then error("codec: table too deep", 0) end
        seen[v] = true
        out[#out + 1] = "{"
        local n = #v
        for i = 1, n do
            encode(v[i], out, seen, depth + 1)
            out[#out + 1] = ","
        end
        for k, x in pairs(v) do
            local kt = type(k)
            local isArray = kt == "number" and k >= 1 and k <= n and math.floor(k) == k
            if not isArray and (kt == "string" or kt == "number" or kt == "boolean") then
                local xt = type(x)
                if xt == "string" or xt == "number" or xt == "boolean" or xt == "table" then
                    if kt == "string" and k:match("^[%a_][%w_]*$") and not KEYWORDS[k] then
                        out[#out + 1] = k
                    else
                        out[#out + 1] = "["
                        encode(k, out, seen, depth + 1)
                        out[#out + 1] = "]"
                    end
                    out[#out + 1] = "="
                    encode(x, out, seen, depth + 1)
                    out[#out + 1] = ","
                end
            end
        end
        out[#out + 1] = "}"
        seen[v] = nil
        if #out % 512 == 0 then compat.breathe() end
    else
        error("codec: cannot encode " .. tp, 0)
    end
end

function M.encode(v)
    local out = {}
    local ok, err = pcall(encode, v, out, {}, 0)
    if not ok then return nil, err end
    return table.concat(out)
end

local function parser(s)
    local p = { s = s, i = 1, n = #s, steps = 0 }

    local function fail(msg)
        error({ codec = true, msg = msg .. " at " .. p.i }, 0)
    end

    local function skip()
        while true do
            local c = s:sub(p.i, p.i)
            if c == " " or c == "\n" or c == "\r" or c == "\t" then
                p.i = p.i + 1
            elseif c == "-" and s:sub(p.i + 1, p.i + 1) == "-" then
                local e = s:find("\n", p.i, true)
                p.i = e and (e + 1) or (p.n + 1)
            else
                return c
            end
        end
    end

    local function readString(q)
        local buf = {}
        p.i = p.i + 1
        while true do
            if p.i > p.n then fail("unterminated string") end
            local c = s:sub(p.i, p.i)
            if c == q then
                p.i = p.i + 1
                break
            elseif c == "\\" then
                local nx = s:sub(p.i + 1, p.i + 1)
                if nx:match("%d") then
                    local digits = s:match("^%d%d?%d?", p.i + 1)
                    local code = tonumber(digits)
                    if code > 255 then fail("bad escape") end
                    buf[#buf + 1] = string.char(code)
                    p.i = p.i + 1 + #digits
                else
                    local map = { n = "\n", t = "\t", r = "\r", a = "\a", b = "\b", f = "\f", v = "\v", ["\\"] = "\\", ["\""] = "\"", ["'"] = "'", ["\n"] = "\n" }
                    local r = map[nx]
                    if not r then fail("bad escape") end
                    buf[#buf + 1] = r
                    p.i = p.i + 2
                end
            elseif c == "\n" then
                fail("newline in string")
            else
                local e = s:find("[\\\n" .. q .. "]", p.i)
                if not e then fail("unterminated string") end
                buf[#buf + 1] = s:sub(p.i, e - 1)
                p.i = e
            end
        end
        return table.concat(buf)
    end

    local function readNumber()
        local num = s:match("^-?%d+%.?%d*[eE][%+%-]?%d+", p.i)
            or s:match("^-?0[xX]%x+", p.i)
            or s:match("^-?%d+%.?%d*", p.i)
            or s:match("^-?%.%d+", p.i)
        if num then
            p.i = p.i + #num
            local special = s:sub(p.i, p.i + 1)
            if special == "/0" then
                p.i = p.i + 2
                local v = tonumber(num)
                if v == 0 then return 0 / 0 end
                if v > 0 then return math.huge end
                return -math.huge
            end
            local v = tonumber(num)
            if v == nil then fail("bad number") end
            return v
        end
        fail("bad number")
    end

    local value

    local function readTable(depth)
        if depth > 64 then fail("too deep") end
        p.i = p.i + 1
        local t = {}
        local n = 0
        while true do
            p.steps = p.steps + 1
            if p.steps % 2000 == 0 then compat.breathe() end
            local c = skip()
            if c == "}" then
                p.i = p.i + 1
                return t
            elseif c == "" then
                fail("unterminated table")
            end
            local key, val
            if c == "[" then
                p.i = p.i + 1
                skip()
                key = value(depth + 1)
                if skip() ~= "]" then fail("expected ]") end
                p.i = p.i + 1
                if skip() ~= "=" then fail("expected =") end
                p.i = p.i + 1
                skip()
                val = value(depth + 1)
                if key == nil or key ~= key then fail("bad key") end
                t[key] = val
            else
                local ident = s:match("^[%a_][%w_]*", p.i)
                local after = ident and s:match("^%s*=", p.i + #ident)
                if ident and after and not KEYWORDS[ident] then
                    p.i = p.i + #ident
                    skip()
                    p.i = p.i + 1
                    skip()
                    t[ident] = value(depth + 1)
                else
                    n = n + 1
                    t[n] = value(depth + 1)
                end
            end
            c = skip()
            if c == "," or c == ";" then
                p.i = p.i + 1
            elseif c ~= "}" then
                fail("expected , or }")
            end
        end
    end

    value = function(depth)
        local c = skip()
        if c == "{" then return readTable(depth or 0) end
        if c == "\"" or c == "'" then return readString(c) end
        if c == "-" or c == "." or c:match("%d") then return readNumber() end
        local word = s:match("^%a+", p.i)
        if word == "true" then p.i = p.i + 4 return true end
        if word == "false" then p.i = p.i + 5 return false end
        if word == "nil" then p.i = p.i + 3 return nil end
        if s:sub(p.i, p.i + 2) == "0/0" then p.i = p.i + 3 return 0 / 0 end
        fail("unexpected input")
    end

    p.value = value
    p.skip = skip
    return p
end

function M.decode(s)
    if type(s) ~= "string" then return nil, "not a string" end
    local p = parser(s)
    local ok, v = pcall(function()
        local r = p.value(0)
        if p.skip() ~= "" then error({ codec = true, msg = "trailing data at " .. p.i }, 0) end
        return r
    end)
    if not ok then
        if type(v) == "table" and v.codec then return nil, v.msg end
        return nil, tostring(v)
    end
    return v
end

M.quote = quote

return M
