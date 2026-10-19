local bitops = require("sim.bitops")

local M = {}

local XOR8 = bitops.XOR8
local floor = math.floor
local byte, char, concat = string.byte, string.char, table.concat

local function x(a, b) return XOR8[a * 256 + b + 1] end

local function xtime(a)
    local r = (a * 2) % 256
    if a >= 128 then r = x(r, 0x1b) end
    return r
end

local EXP, LOG = {}, {}
do
    local v = 1
    for i = 0, 254 do
        EXP[i] = v
        LOG[v] = i
        v = x(v, xtime(v))
    end
end

local function gmul(a, b)
    if a == 0 or b == 0 then return 0 end
    return EXP[(LOG[a] + LOG[b]) % 255]
end

local function rotl8(b, n)
    return (b * 2 ^ n) % 256 + floor(b / 2 ^ (8 - n))
end

local SBOX, INV = {}, {}
for i = 0, 255 do
    local inv = 0
    if i ~= 0 then inv = EXP[(255 - LOG[i]) % 255] end
    local s = x(x(x(x(inv, rotl8(inv, 1)), rotl8(inv, 2)), rotl8(inv, 3)), rotl8(inv, 4))
    s = x(s, 0x63)
    SBOX[i] = s
    INV[s] = i
end

local M2, M3, M9, M11, M13, M14 = {}, {}, {}, {}, {}, {}
for i = 0, 255 do
    M2[i] = gmul(i, 2)
    M3[i] = gmul(i, 3)
    M9[i] = gmul(i, 9)
    M11[i] = gmul(i, 11)
    M13[i] = gmul(i, 13)
    M14[i] = gmul(i, 14)
end

local RCON = { 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36 }

function M.expandKey(key)
    local w = {}
    for i = 0, 15 do w[i] = key[i + 1] end
    local r = 1
    for i = 16, 175, 4 do
        local t0, t1, t2, t3 = w[i - 4], w[i - 3], w[i - 2], w[i - 1]
        if i % 16 == 0 then
            t0, t1, t2, t3 = x(SBOX[t1], RCON[r]), SBOX[t2], SBOX[t3], SBOX[t0]
            r = r + 1
        end
        w[i] = x(w[i - 16], t0)
        w[i + 1] = x(w[i - 15], t1)
        w[i + 2] = x(w[i - 14], t2)
        w[i + 3] = x(w[i - 13], t3)
    end
    return w
end

local SHIFT = {}
local INVSHIFT = {}
for c = 0, 3 do
    for r = 0, 3 do
        SHIFT[r + 4 * c] = r + 4 * ((c + r) % 4)
        INVSHIFT[r + 4 * ((c + r) % 4)] = r + 4 * c
    end
end

local function encryptBlock(s, w)
    local t = {}
    for i = 0, 15 do s[i] = x(s[i], w[i]) end
    for round = 1, 10 do
        for i = 0, 15 do t[i] = SBOX[s[SHIFT[i]]] end
        local base = round * 16
        if round < 10 then
            for c = 0, 12, 4 do
                local a0, a1, a2, a3 = t[c], t[c + 1], t[c + 2], t[c + 3]
                s[c] = x(x(x(M2[a0], M3[a1]), a2), a3)
                s[c + 1] = x(x(x(a0, M2[a1]), M3[a2]), a3)
                s[c + 2] = x(x(x(a0, a1), M2[a2]), M3[a3])
                s[c + 3] = x(x(x(M3[a0], a1), a2), M2[a3])
            end
        else
            for i = 0, 15 do s[i] = t[i] end
        end
        for i = 0, 15 do s[i] = x(s[i], w[base + i]) end
    end
    return s
end

local function decryptBlock(s, w)
    local t = {}
    for i = 0, 15 do s[i] = x(s[i], w[160 + i]) end
    for round = 9, 0, -1 do
        for i = 0, 15 do t[i] = INV[s[INVSHIFT[i]]] end
        local base = round * 16
        for i = 0, 15 do t[i] = x(t[i], w[base + i]) end
        if round > 0 then
            for c = 0, 12, 4 do
                local a0, a1, a2, a3 = t[c], t[c + 1], t[c + 2], t[c + 3]
                s[c] = x(x(x(M14[a0], M11[a1]), M13[a2]), M9[a3])
                s[c + 1] = x(x(x(M9[a0], M14[a1]), M11[a2]), M13[a3])
                s[c + 2] = x(x(x(M13[a0], M9[a1]), M14[a2]), M11[a3])
                s[c + 3] = x(x(x(M11[a0], M13[a1]), M9[a2]), M14[a3])
            end
        else
            for i = 0, 15 do s[i] = t[i] end
        end
    end
    return s
end

local function toBytes(str)
    local out = {}
    for i = 1, #str do out[i] = byte(str, i) end
    return out
end

local function fromBytes(arr, n)
    local parts = {}
    local chunk = 4096
    for i = 1, n or #arr, chunk do
        local j = math.min(i + chunk - 1, n or #arr)
        parts[#parts + 1] = char(unpack(arr, i, j))
    end
    return concat(parts)
end

function M.encryptBlockRaw(keyBytes, blockBytes)
    local w = M.expandKey(keyBytes)
    local s = {}
    for i = 0, 15 do s[i] = blockBytes[i + 1] end
    encryptBlock(s, w)
    local out = {}
    for i = 0, 15 do out[i + 1] = s[i] end
    return out
end

function M.cbcEncrypt(keyBytes, ivBytes, data)
    local w = M.expandKey(keyBytes)
    local n = #data
    local pad = 16 - n % 16
    local bytes = toBytes(data)
    for i = 1, pad do bytes[n + i] = pad end
    local prev = {}
    for i = 0, 15 do prev[i] = ivBytes[i + 1] end
    local out = {}
    local s = {}
    for off = 0, #bytes - 1, 16 do
        for i = 0, 15 do s[i] = x(bytes[off + i + 1], prev[i]) end
        encryptBlock(s, w)
        for i = 0, 15 do
            out[off + i + 1] = s[i]
            prev[i] = s[i]
        end
    end
    return fromBytes(out, #bytes)
end

function M.cbcDecrypt(keyBytes, ivBytes, data)
    local n = #data
    if n % 16 ~= 0 then return nil, "Input length must be multiple of 16 when decrypting with padded cipher" end
    if n == 0 then return "" end
    local w = M.expandKey(keyBytes)
    local bytes = toBytes(data)
    local prev = {}
    for i = 0, 15 do prev[i] = ivBytes[i + 1] end
    local out = {}
    local s = {}
    for off = 0, n - 1, 16 do
        local cur = {}
        for i = 0, 15 do
            s[i] = bytes[off + i + 1]
            cur[i] = s[i]
        end
        decryptBlock(s, w)
        for i = 0, 15 do out[off + i + 1] = x(s[i], prev[i]) end
        prev = cur
    end
    local pad = out[n]
    if pad < 1 or pad > 16 then return nil, "Given final block not properly padded" end
    for i = n - pad + 1, n do
        if out[i] ~= pad then return nil, "Given final block not properly padded" end
    end
    return fromBytes(out, n - pad)
end

local ALPHA = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local ENC, DEC = {}, {}
for i = 1, 64 do
    local c = ALPHA:sub(i, i)
    ENC[i - 1] = c
    DEC[byte(c)] = i - 1
end

function M.b64encode(data)
    local out = {}
    local n = #data
    for i = 1, n, 3 do
        local a, b, c = byte(data, i, i + 2)
        local v = a * 65536 + (b or 0) * 256 + (c or 0)
        local c1 = floor(v / 262144) % 64
        local c2 = floor(v / 4096) % 64
        local c3 = floor(v / 64) % 64
        local c4 = v % 64
        if c then
            out[#out + 1] = ENC[c1] .. ENC[c2] .. ENC[c3] .. ENC[c4]
        elseif b then
            out[#out + 1] = ENC[c1] .. ENC[c2] .. ENC[c3] .. "="
        else
            out[#out + 1] = ENC[c1] .. ENC[c2] .. "=="
        end
    end
    return concat(out)
end

local WHITE = { [9] = true, [10] = true, [12] = true, [13] = true, [32] = true }

function M.b64decode(s)
    local len = #s
    if len == 0 then return "" end
    if len < 4 then return nil, "Base64-encoded string must have at least four characters" end
    local out = {}
    local quad = {}
    local q = 0
    for i = 1, len do
        local b = byte(s, i)
        if WHITE[b] then
        elseif b == 61 or DEC[b] then
            q = q + 1
            quad[q] = b
            if q == 4 then
                local d1, d2 = DEC[quad[1]], DEC[quad[2]]
                if not d1 or not d2 then return nil, "Bad Base64 input character" end
                if quad[3] == 61 then
                    out[#out + 1] = char(floor((d1 * 262144 + d2 * 4096) / 65536) % 256)
                else
                    local d3 = DEC[quad[3]]
                    if quad[4] == 61 then
                        local v = d1 * 262144 + d2 * 4096 + d3 * 64
                        out[#out + 1] = char(floor(v / 65536) % 256, floor(v / 256) % 256)
                    else
                        local v = d1 * 262144 + d2 * 4096 + d3 * 64 + DEC[quad[4]]
                        out[#out + 1] = char(floor(v / 65536) % 256, floor(v / 256) % 256, v % 256)
                    end
                end
                q = 0
                if b == 61 then break end
            end
        else
            return nil, "Bad Base64 input character decimal " .. b .. " in array position " .. (i - 1)
        end
    end
    return concat(out)
end

M.toBytes = toBytes
M.fromBytes = fromBytes

return M
