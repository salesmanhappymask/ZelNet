local M = {}

local MOD32 = 4294967296

local function norm32(x)
    x = x % MOD32
    if x < 0 then x = x + MOD32 end
    return x
end

local XT, AT = {}, {}
for na = 0, 15 do
    XT[na] = {}
    AT[na] = {}
    for nc = 0, 15 do
        local x, y, xr, ar, p = na, nc, 0, 0, 1
        for _ = 1, 4 do
            local xb, yb = x % 2, y % 2
            if xb ~= yb then xr = xr + p end
            if xb == 1 and yb == 1 then ar = ar + p end
            x = (x - xb) / 2
            y = (y - yb) / 2
            p = p * 2
        end
        XT[na][nc] = xr
        AT[na][nc] = ar
    end
end

local function pureCombine(tbl, a, c)
    local res, mult = 0, 1
    for _ = 1, 8 do
        local an, cn = a % 16, c % 16
        res = res + tbl[an][cn] * mult
        a = (a - an) / 16
        c = (c - cn) / 16
        mult = mult * 16
    end
    return res
end

local nativeBit = rawget(_G, "bit")
if type(nativeBit) == "table" and type(nativeBit.band) == "function" and type(nativeBit.bxor) == "function" then
    local b = nativeBit
    M.band = function(a, c) return norm32(b.band(norm32(a), norm32(c))) end
    M.bor = function(a, c) return norm32(b.bor(norm32(a), norm32(c))) end
    M.bxor = function(a, c) return norm32(b.bxor(norm32(a), norm32(c))) end
    M.bnot = function(a) return MOD32 - 1 - norm32(a) end
    M.backend = "bit"
else
    M.band = function(a, c) return pureCombine(AT, norm32(a), norm32(c)) end
    M.bxor = function(a, c) return pureCombine(XT, norm32(a), norm32(c)) end
    M.bor = function(a, c)
        a = norm32(a)
        c = norm32(c)
        return a + c - pureCombine(AT, a, c)
    end
    M.bnot = function(a) return MOD32 - 1 - norm32(a) end
    M.backend = "pure"
end

function M.rshift(a, n)
    if n <= 0 then return norm32(a) end
    if n >= 32 then return 0 end
    return math.floor(norm32(a) / (2 ^ n))
end

function M.lshift(a, n)
    if n <= 0 then return norm32(a) end
    if n >= 32 then return 0 end
    return (norm32(a) * (2 ^ n)) % MOD32
end

function M.rrot(x, n)
    x = norm32(x)
    return (math.floor(x / (2 ^ n)) + (x * (2 ^ (32 - n))) % MOD32) % MOD32
end

M.norm32 = norm32
M.MOD32 = MOD32

local BXOR8 = nil

local function buildXor8()
    BXOR8 = {}
    for a = 0, 255 do
        local row = {}
        for c = 0, 255 do row[c] = pureCombine(XT, a, c) end
        BXOR8[a] = row
    end
end

if M.backend == "bit" then
    local bxor = nativeBit.bxor
    M.bxor8 = function(a, c) return bxor(a, c) end
else
    M.bxor8 = function(a, c)
        if not BXOR8 then buildXor8() end
        return BXOR8[a][c]
    end
end

M.unpack = rawget(_G, "unpack") or rawget(table, "unpack")

function M.isCC()
    return type(rawget(_G, "os")) == "table" and type(os.queueEvent) == "function" and type(os.pullEvent) == "function"
end

function M.now()
    if type(os) == "table" and type(os.clock) == "function" then return os.clock() end
    return 0
end

function M.stamp()
    local day, t = 0, 0
    if type(os) == "table" then
        if type(os.day) == "function" then day = os.day() or 0 end
        if type(os.time) == "function" then t = os.time() or 0 end
    end
    return day * 24 + t
end

local breathCount = 0
local breathEvery = 40

function M.setBreathEvery(n)
    breathEvery = math.max(1, n)
end

local settled = false

function M.yieldNow()
    if not M.isCC() or not coroutine.running() then return end
    local timer = not settled and type(os.startTimer) == "function" and os.startTimer(0) or nil
    os.queueEvent("zn_breathe")
    while true do
        local ev, a = os.pullEventRaw()
        if ev == "zn_breathe" then
            settled = true
            return
        end
        if timer and ev == "timer" and a == timer then return end
        if ev == "terminate" then error("Terminated", 0) end
    end
end

function M.settle()
    if settled or not M.isCC() or not coroutine.running() or type(os.startTimer) ~= "function" then return end
    local timer = os.startTimer(0)
    while true do
        local ev, a = os.pullEventRaw()
        if ev == "timer" and a == timer then break end
        if ev == "terminate" then error("Terminated", 0) end
    end
    settled = true
end

function M.breathe(weight)
    breathCount = breathCount + (weight or 1)
    if breathCount >= breathEvery then
        breathCount = 0
        M.yieldNow()
    end
end

return M
