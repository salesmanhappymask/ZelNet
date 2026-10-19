local M = {}

local floor = math.floor
local MOD = 4294967296
local HALF = 2147483648

local AND4, XOR4 = {}, {}
for a = 0, 15 do
    for b = 0, 15 do
        local x, y, r, s, p = a, b, 0, 0, 1
        for _ = 1, 4 do
            local xa, yb = x % 2, y % 2
            if xa == 1 and yb == 1 then r = r + p end
            if xa ~= yb then s = s + p end
            x = (x - xa) / 2
            y = (y - yb) / 2
            p = p * 2
        end
        AND4[a * 16 + b] = r
        XOR4[a * 16 + b] = s
    end
end

local AND8, XOR8 = {}, {}
for a = 0, 255 do
    local ah, al = floor(a / 16), a % 16
    for b = 0, 255 do
        local bh, bl = floor(b / 16), b % 16
        local k = a * 256 + b + 1
        AND8[k] = AND4[ah * 16 + bh] * 16 + AND4[al * 16 + bl]
        XOR8[k] = XOR4[ah * 16 + bh] * 16 + XOR4[al * 16 + bl]
    end
end

M.AND8 = AND8
M.XOR8 = XOR8
M.MOD = MOD

local function op32(T, a, b)
    local x0, y0 = a % 256, b % 256
    a, b = (a - x0) / 256, (b - y0) / 256
    local x1, y1 = a % 256, b % 256
    a, b = (a - x1) / 256, (b - y1) / 256
    local x2, y2 = a % 256, b % 256
    a, b = (a - x2) / 256, (b - y2) / 256
    return T[x0 * 256 + y0 + 1]
        + T[x1 * 256 + y1 + 1] * 256
        + T[x2 * 256 + y2 + 1] * 65536
        + T[a * 256 + b + 1] * 16777216
end

function M.band(a, b) return op32(AND8, a, b) end
function M.bxor(a, b) return op32(XOR8, a, b) end
function M.bor(a, b) return a + b - op32(AND8, a, b) end
function M.bnot(a) return MOD - 1 - a end
function M.xor8(a, b) return XOR8[a * 256 + b + 1] end

function M.lshift(a, n)
    n = n % 32
    return (a * 2 ^ n) % MOD
end

function M.rshift(a, n)
    n = n % 32
    return floor(a / 2 ^ n)
end

function M.arshift(a, n)
    n = n % 32
    local r = floor(a / 2 ^ n)
    if a >= HALF and n > 0 then r = r + MOD - 2 ^ (32 - n) end
    return r
end

local function slowCheck(v)
    if type(v) ~= "number" then
        if v == nil then error("too few arguments", 3) end
        error("number expected", 3)
    end
    if v % 1 ~= 0 or v ~= v then error("passed number is not an integer", 3) end
    if v >= MOD then error("number is too large (maximum allowed: 2^32-1)", 3) end
    if v < 0 then
        if v < -9223372036854775808 then return 0 end
        v = v % MOD
    end
    return v
end

function M.ccApi(onCall)
    local api = {}
    local band, bxor, lshift, rshift, arshift = M.band, M.bxor, M.lshift, M.rshift, M.arshift
    local function ok(v)
        return type(v) == "number" and v >= 0 and v < MOD and v % 1 == 0
    end
    api.bnot = function(a)
        if onCall then onCall() end
        if not ok(a) then a = slowCheck(a) end
        return MOD - 1 - a
    end
    api.band = function(a, b)
        if onCall then onCall() end
        if not ok(a) then a = slowCheck(a) end
        if not ok(b) then b = slowCheck(b) end
        return band(a, b)
    end
    api.bor = function(a, b)
        if onCall then onCall() end
        if not ok(a) then a = slowCheck(a) end
        if not ok(b) then b = slowCheck(b) end
        return a + b - band(a, b)
    end
    api.bxor = function(a, b)
        if onCall then onCall() end
        if not ok(a) then a = slowCheck(a) end
        if not ok(b) then b = slowCheck(b) end
        return bxor(a, b)
    end
    api.brshift = function(a, b)
        if onCall then onCall() end
        if not ok(a) then a = slowCheck(a) end
        if not ok(b) then b = slowCheck(b) end
        return arshift(a, b)
    end
    api.blshift = function(a, b)
        if onCall then onCall() end
        if not ok(a) then a = slowCheck(a) end
        if not ok(b) then b = slowCheck(b) end
        return lshift(a, b)
    end
    api.blogic_rshift = function(a, b)
        if onCall then onCall() end
        if not ok(a) then a = slowCheck(a) end
        if not ok(b) then b = slowCheck(b) end
        return rshift(a, b)
    end
    return api
end

return M
