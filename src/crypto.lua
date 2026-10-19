local need = ...
local compat = need("compat")
local codec = need("codec")

local M = {}

local band, bor, bxor, bnot = compat.band, compat.bor, compat.bxor, compat.bnot
local rshift, lshift, rrot = compat.rshift, compat.lshift, compat.rrot
local bxor8 = compat.bxor8
local breathe = compat.breathe
local MOD = 4294967296

local HEX = "0123456789abcdef"

local function toHex8(n)
    local s = ""
    for _ = 1, 8 do
        local d = n % 16
        s = HEX:sub(d + 1, d + 1) .. s
        n = (n - d) / 16
    end
    return s
end

local K = {
    0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
    0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
    0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
    0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
    0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
    0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
    0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
    0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2,
}

local function sha256(msg)
    local h0, h1, h2, h3 = 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
    local h4, h5, h6, h7 = 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
    local bitLen = #msg * 8
    local pad = 64 - ((#msg + 9) % 64)
    if pad == 64 then pad = 0 end
    local hi = math.floor(bitLen / MOD)
    local lo = bitLen % MOD
    msg = msg .. "\128" .. string.rep("\0", pad)
        .. string.char(band(rshift(hi, 24), 255), band(rshift(hi, 16), 255), band(rshift(hi, 8), 255), band(hi, 255))
        .. string.char(band(rshift(lo, 24), 255), band(rshift(lo, 16), 255), band(rshift(lo, 8), 255), band(lo, 255))
    local w = {}
    for chunk = 1, #msg, 64 do
        for i = 0, 15 do
            local o = chunk + i * 4
            local b1, b2, b3, b4 = msg:byte(o, o + 3)
            w[i + 1] = ((b1 * 256 + b2) * 256 + b3) * 256 + b4
        end
        for i = 17, 64 do
            local x, y = w[i - 15], w[i - 2]
            local s0 = bxor(bxor(rrot(x, 7), rrot(x, 18)), rshift(x, 3))
            local s1 = bxor(bxor(rrot(y, 17), rrot(y, 19)), rshift(y, 10))
            w[i] = (w[i - 16] + s0 + w[i - 7] + s1) % MOD
        end
        local a, b, c, d, e, f, g, hh = h0, h1, h2, h3, h4, h5, h6, h7
        for i = 1, 64 do
            local S1 = bxor(bxor(rrot(e, 6), rrot(e, 11)), rrot(e, 25))
            local ch = bxor(band(e, f), band(bnot(e), g))
            local t1 = (hh + S1 + ch + K[i] + w[i]) % MOD
            local S0 = bxor(bxor(rrot(a, 2), rrot(a, 13)), rrot(a, 22))
            local mj = bxor(bxor(band(a, b), band(a, c)), band(b, c))
            local t2 = (S0 + mj) % MOD
            hh = g
            g = f
            f = e
            e = (d + t1) % MOD
            d = c
            c = b
            b = a
            a = (t1 + t2) % MOD
        end
        h0 = (h0 + a) % MOD
        h1 = (h1 + b) % MOD
        h2 = (h2 + c) % MOD
        h3 = (h3 + d) % MOD
        h4 = (h4 + e) % MOD
        h5 = (h5 + f) % MOD
        h6 = (h6 + g) % MOD
        h7 = (h7 + hh) % MOD
        breathe()
    end
    return toHex8(h0) .. toHex8(h1) .. toHex8(h2) .. toHex8(h3)
        .. toHex8(h4) .. toHex8(h5) .. toHex8(h6) .. toHex8(h7)
end

local HEXVAL = {}
for i = 0, 15 do
    HEXVAL[HEX:sub(i + 1, i + 1)] = i
    HEXVAL[HEX:sub(i + 1, i + 1):upper()] = i
end

local BYTEHEX = {}
for v = 0, 255 do
    BYTEHEX[v] = HEX:sub(math.floor(v / 16) + 1, math.floor(v / 16) + 1) .. HEX:sub(v % 16 + 1, v % 16 + 1)
end

local function fromHex(s)
    if type(s) ~= "string" or #s % 2 ~= 0 then return nil end
    local out = {}
    for i = 1, #s, 2 do
        local a, b = HEXVAL[s:sub(i, i)], HEXVAL[s:sub(i + 1, i + 1)]
        if not a or not b then return nil end
        out[#out + 1] = string.char(a * 16 + b)
        if i % 8192 == 1 and i > 1 then breathe() end
    end
    return table.concat(out)
end

local function toHex(s)
    local out = {}
    for i = 1, #s do
        out[i] = BYTEHEX[s:byte(i)]
        if i % 4096 == 0 then breathe() end
    end
    return table.concat(out)
end

local function sha256bin(msg)
    return fromHex(sha256(msg))
end

local function hmacBin(keyBin, msg)
    if #keyBin > 64 then keyBin = sha256bin(keyBin) end
    keyBin = keyBin .. string.rep("\0", 64 - #keyBin)
    local ipad, opad = {}, {}
    for i = 1, 64 do
        local kb = keyBin:byte(i)
        ipad[i] = string.char(bxor8(kb, 0x36))
        opad[i] = string.char(bxor8(kb, 0x5c))
    end
    local inner = sha256bin(table.concat(ipad) .. msg)
    return sha256(table.concat(opad) .. inner)
end

local function keyBinOf(keyHex)
    local k = fromHex(keyHex)
    if not k then error("crypto: key must be hex", 3) end
    return k
end

local function hmac(keyHex, msg)
    return hmacBin(keyBinOf(keyHex), msg)
end

local derivedCache = {}
local derivedOrder = {}

local function derive(keyHex, label)
    local ck = label .. ":" .. keyHex
    local v = derivedCache[ck]
    if v then return v end
    v = hmac(keyHex, "zn-" .. label)
    derivedCache[ck] = v
    derivedOrder[#derivedOrder + 1] = ck
    if #derivedOrder > 128 then
        derivedCache[table.remove(derivedOrder, 1)] = nil
    end
    return v
end

local function rc4(keyBin, data)
    local S = {}
    for i = 0, 255 do S[i] = i end
    local j, kl = 0, #keyBin
    for i = 0, 255 do
        j = (j + S[i] + keyBin:byte(i % kl + 1)) % 256
        S[i], S[j] = S[j], S[i]
    end
    local i = 0
    j = 0
    for _ = 1, 768 do
        i = (i + 1) % 256
        j = (j + S[i]) % 256
        S[i], S[j] = S[j], S[i]
    end
    local out = {}
    for p = 1, #data do
        i = (i + 1) % 256
        j = (j + S[i]) % 256
        local si, sj = S[j], S[i]
        S[i], S[j] = si, sj
        out[p] = string.char(bxor8(data:byte(p), S[(si + sj) % 256]))
        if p % 4096 == 0 then breathe(4) end
    end
    return table.concat(out)
end

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64CHR, B64VAL = {}, {}
for i = 0, 63 do
    local c = B64:sub(i + 1, i + 1)
    B64CHR[i] = c
    B64VAL[c] = i
end

local function b64encode(s)
    local out = {}
    local n = #s
    local i = 1
    while i <= n do
        local a, b, c = s:byte(i, i + 2)
        local v = a * 65536 + (b or 0) * 256 + (c or 0)
        local c1 = math.floor(v / 262144) % 64
        local c2 = math.floor(v / 4096) % 64
        local c3 = math.floor(v / 64) % 64
        local c4 = v % 64
        out[#out + 1] = B64CHR[c1] .. B64CHR[c2] .. (b and B64CHR[c3] or "=") .. (c and B64CHR[c4] or "=")
        i = i + 3
        if i % 6144 == 1 then breathe() end
    end
    return table.concat(out)
end

local function b64decode(s)
    if type(s) ~= "string" then return nil end
    s = s:gsub("[^%w%+/=]", "")
    if #s % 4 ~= 0 then return nil end
    local out = {}
    for i = 1, #s, 4 do
        local c1, c2, c3, c4 = s:sub(i, i), s:sub(i + 1, i + 1), s:sub(i + 2, i + 2), s:sub(i + 3, i + 3)
        local v1, v2 = B64VAL[c1], B64VAL[c2]
        if not v1 or not v2 then return nil end
        local v3 = c3 == "=" and 0 or B64VAL[c3]
        local v4 = c4 == "=" and 0 or B64VAL[c4]
        if not v3 or not v4 then return nil end
        local v = ((v1 * 64 + v2) * 64 + v3) * 64 + v4
        local b1 = math.floor(v / 65536) % 256
        local b2 = math.floor(v / 256) % 256
        local b3 = v % 256
        if c3 == "=" then
            out[#out + 1] = string.char(b1)
        elseif c4 == "=" then
            out[#out + 1] = string.char(b1, b2)
        else
            out[#out + 1] = string.char(b1, b2, b3)
        end
        if i % 8192 == 1 and i > 1 then breathe() end
    end
    return table.concat(out)
end

local function adler32(s)
    local a, b = 1, 0
    for i = 1, #s do
        a = (a + s:byte(i)) % 65521
        b = (b + a) % 65521
        if i % 16384 == 0 then breathe() end
    end
    return b * 65536 + a
end

local function constEq(x, y)
    if type(x) ~= "string" or type(y) ~= "string" or #x ~= #y then return false end
    local diff = 0
    for i = 1, #x do
        if x:byte(i) ~= y:byte(i) then diff = diff + 1 end
    end
    return diff == 0
end

local rngState = nil
local rngCounter = 0
local entropyPool = ""

local function seedRng()
    local parts = { tostring({}), tostring(math.random(1, 2147483646)), tostring(math.random(1, 2147483646)) }
    if type(os) == "table" then
        if os.clock then parts[#parts + 1] = tostring(os.clock()) end
        if os.time then parts[#parts + 1] = tostring(os.time()) end
        if os.day then parts[#parts + 1] = tostring(os.day()) end
        if os.getComputerID then parts[#parts + 1] = tostring(os.getComputerID()) end
    end
    rngState = sha256(table.concat(parts, "|") .. entropyPool)
end

local function addEntropy(s)
    entropyPool = sha256(entropyPool .. tostring(s) .. tostring(math.random(1, 2147483646)))
    if rngState then rngState = sha256(rngState .. entropyPool) end
end

local function randHex(nBytes)
    if not rngState then seedRng() end
    local out = {}
    local have = 0
    while have < nBytes * 2 do
        rngCounter = rngCounter + 1
        local clock = (type(os) == "table" and os.clock) and os.clock() or 0
        rngState = sha256(rngState .. "|" .. rngCounter .. "|" .. tostring(clock) .. "|" .. tostring(math.random(1, 2147483646)))
        local block = sha256("out|" .. rngState)
        out[#out + 1] = block
        have = have + #block
    end
    return table.concat(out):sub(1, nBytes * 2)
end

local function streamKey(keyHex, nonceHex)
    local encKey = fromHex(derive(keyHex, "enc"))
    local nonce = fromHex(nonceHex) or nonceHex
    return sha256bin(encKey .. nonce)
end

local function encrypt(keyHex, nonceHex, plain)
    return rc4(streamKey(keyHex, nonceHex), plain)
end

local function mac(keyHex, msg)
    return hmac(derive(keyHex, "mac"), msg)
end

local function sealString(keyHex, plain, aad)
    local n = randHex(16)
    local ct = b64encode(encrypt(keyHex, n, plain))
    local tag = mac(keyHex, (aad or "") .. "|" .. n .. "|" .. ct)
    return n, ct, tag
end

local function openString(keyHex, n, ct, tag, aad)
    if type(n) ~= "string" or type(ct) ~= "string" or type(tag) ~= "string" then return nil, "malformed" end
    local expect = mac(keyHex, (aad or "") .. "|" .. n .. "|" .. ct)
    if not constEq(expect, tag) then return nil, "bad mac" end
    local raw = b64decode(ct)
    if not raw then return nil, "bad encoding" end
    return encrypt(keyHex, n, raw)
end

local function serialize(v)
    return codec.encode(v)
end

local function unserialize(s)
    return (codec.decode(s))
end

local function sealTable(keyHex, value, aad)
    local plain, err = serialize(value)
    if not plain then return nil, err end
    local n, ct, tag = sealString(keyHex, plain, aad)
    return { z = 1, n = n, ct = ct, mac = tag }
end

local function openTable(keyHex, box, aad)
    if type(box) ~= "table" or box.z ~= 1 then return nil, "not sealed" end
    local plain, err = openString(keyHex, box.n, box.ct, box.mac, aad)
    if not plain then return nil, err end
    local v = unserialize(plain)
    if v == nil and plain ~= "nil" then return nil, "bad payload" end
    return v
end

local function newKey()
    return randHex(32)
end

local function passwordHash(saltHex, password)
    local h = hmac(saltHex, "pw|" .. tostring(password))
    for _ = 1, 3 do h = hmac(saltHex, h) end
    return h
end

M.sha256 = sha256
M.sha256bin = sha256bin
M.hmac = hmac
M.hmacBin = hmacBin
M.derive = derive
M.mac = mac
M.rc4 = rc4
M.encrypt = encrypt
M.toHex = toHex
M.fromHex = fromHex
M.b64encode = b64encode
M.b64decode = b64decode
M.adler32 = adler32
M.constEq = constEq
M.randHex = randHex
M.addEntropy = addEntropy
M.sealString = sealString
M.openString = openString
M.sealTable = sealTable
M.openTable = openTable
M.serialize = serialize
M.unserialize = unserialize
M.newKey = newKey
M.passwordHash = passwordHash
M.toHex8 = toHex8

return M
