package.path = "./?.lua;" .. package.path
require("tests.shim").install()
local need = require("tools.devload").make(".")
local seal = need("seal")
local cipher = need("cipher")
local crypto = need("crypto")
local frame = need("frame")
local t = require("tests.tiny")

local function fakeHardware(keyHex)
    local obj = { kind = "hardware", name = "fake", calls = 0 }
    function obj.encrypt(text)
        return "H" .. crypto.b64encode(crypto.encrypt(keyHex, "00000000000000000000000000000000", "OK" .. text))
    end
    function obj.decrypt(text)
        local raw = crypto.b64decode(text:sub(2))
        if not raw then return nil, "bad" end
        local p = crypto.encrypt(keyHex, "00000000000000000000000000000000", raw)
        if p:sub(1, 2) ~= "OK" then return nil, "Given final block not properly padded" end
        return p:sub(3)
    end
    return obj
end

local pkt = { id = "0011223344556677", src = "MARS:42", dst = "EARTH:7", port = "power", ttl = 24, rq = true, body = { stored = 123, note = "h\195\169llo" } }

t.case("access seal round trip", function()
    local key = crypto.newKey()
    local w = assert(seal.sealAccess(key, pkt, "u", "powermon"))
    t.ok(frame.validAccess(w))
    local back = assert(seal.openAccess(key, w))
    t.eq(back.body.stored, 123)
    t.eq(back.body.note, "h\195\169llo")
    t.eq(back.rq, true)
    w.ttl = 3
    t.ok(seal.openAccess(key, w), "ttl change must not break mac")
    w.dst = "EARTH:8"
    local _, err = seal.openAccess(key, w)
    t.eq(err, "bad mac")
end)

t.case("access seal rejects other key and big bodies", function()
    local w = assert(seal.sealAccess(crypto.newKey(), pkt, "u", "x"))
    t.eq(seal.openAccess(crypto.newKey(), w), nil)
    local big = { id = "a", src = "A", dst = "B", port = "p", body = string.rep("x", 9000) }
    local r, err = seal.sealAccess(crypto.newKey(), big, "u", "x")
    t.eq(r, nil)
    t.eq(err, "too_large")
end)

t.case("backbone seal with hardware style cipher", function()
    local bb = crypto.newKey()
    local c = fakeHardware(crypto.newKey())
    local w = assert(seal.sealBackbone(c, bb, pkt, "MARS"))
    t.ok(frame.validBackbone(w))
    local back, nonce = seal.openBackbone(c, bb, w)
    t.ok(back, tostring(nonce))
    t.eq(back.body.stored, 123)
    t.eq(#nonce, 32)
    w.via = "EARTH"
    w.ttl = 5
    t.ok(seal.openBackbone(c, bb, w), "via and ttl not covered")
    local _, err = seal.openBackbone(c, crypto.newKey(), w)
    t.eq(err, "bad mac")
    local other = fakeHardware(crypto.newKey())
    local _, err2 = seal.openBackbone(other, bb, w)
    t.ok(err2 and err2:find("cipher"), tostring(err2))
    local w2 = assert(seal.sealBackbone(c, bb, pkt, "MARS"))
    t.neq(w2.ct, w.ct)
end)

t.case("software cipher and self test", function()
    local sw = cipher.software(crypto.newKey())
    t.ok(cipher.selfTest(sw))
    t.ok(cipher.selfTest(fakeHardware(crypto.newKey())))
    local key = crypto.newKey()
    t.eq(cipher.fingerprint(fakeHardware(key)), cipher.fingerprint(fakeHardware(key)))
    t.neq(cipher.fingerprint(fakeHardware(key)), cipher.fingerprint(fakeHardware(crypto.newKey())))
end)

t.case("store seal modes", function()
    local value = { users = { "a", "b" }, n = 5 }
    local hw = fakeHardware(crypto.newKey())
    local s1 = assert(seal.storeSeal(hw, nil, value))
    t.eq(seal.storeOpen(hw, nil, s1).n, 5)
    local dk = crypto.newKey()
    local s2 = assert(seal.storeSeal(nil, dk, value))
    t.eq(seal.storeOpen(nil, dk, s2).users[2], "b")
    t.eq(seal.storeOpen(nil, crypto.newKey(), s2), nil)
    local s3 = assert(seal.storeSeal(nil, nil, value))
    t.eq(seal.storeOpen(nil, nil, s3).n, 5)
    local _, err = seal.storeOpen(fakeHardware(crypto.newKey()), nil, s1)
    t.ok(err)
end)

t.case("beacon and hello macs", function()
    local rk = crypto.newKey()
    local d = { realm = "MARS", root = 12, seq = 5, hops = 0 }
    d.mac = seal.beaconMac(rk, d)
    t.ok(frame.validBeacon(d))
    d.hops = 3
    t.eq(seal.beaconMac(rk, d), d.mac)
    d.seq = 6
    t.neq(seal.beaconMac(rk, d), d.mac)
end)

t.finish()
