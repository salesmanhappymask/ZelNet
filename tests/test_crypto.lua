package.path = "./?.lua;" .. package.path
local shim = require("tests.shim")
shim.install()
local need = require("tools.devload").make(".")
local crypto = need("crypto")
local t = require("tests.tiny")

t.case("sha256 NIST vectors", function()
    t.eq(crypto.sha256(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    t.eq(crypto.sha256("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    t.eq(crypto.sha256("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
        "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    t.eq(crypto.sha256(string.rep("a", 1000)), "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
    for len = 50, 70 do
        t.eq(#crypto.sha256(string.rep("x", len)), 64)
    end
end)

t.case("hmac RFC 4231", function()
    t.eq(crypto.hmac(string.rep("0b", 20), "Hi There"),
        "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")
    t.eq(crypto.hmacBin("Jefe", "what do ya want for nothing?"),
        "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
    t.eq(crypto.hmac(string.rep("aa", 131), "Test Using Larger Than Block-Size Key - Hash Key First"),
        "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54")
end)

t.case("base64 round trip", function()
    t.eq(crypto.b64encode(""), "")
    t.eq(crypto.b64encode("f"), "Zg==")
    t.eq(crypto.b64encode("fo"), "Zm8=")
    t.eq(crypto.b64encode("foo"), "Zm9v")
    t.eq(crypto.b64encode("foobar"), "Zm9vYmFy")
    local all = {}
    for i = 0, 255 do all[#all + 1] = string.char(i) end
    local s = table.concat(all) .. table.concat(all)
    t.eq(crypto.b64decode(crypto.b64encode(s)), s)
    t.eq(crypto.b64decode("Zm9v!"), "foo")
    t.eq(crypto.b64decode("Zm9"), nil)
end)

t.case("hex round trip", function()
    t.eq(crypto.toHex("\0\1\254\255"), "0001feff")
    t.eq(crypto.fromHex("0001FEff"), "\0\1\254\255")
    t.eq(crypto.fromHex("abc"), nil)
    t.eq(crypto.fromHex("zz"), nil)
end)

t.case("rc4 known vector and symmetry", function()
    t.eq(crypto.toHex(crypto.rc4("Key", string.rep("\0", 8))), "d51c266be56d4551")
    local k = crypto.newKey()
    local plain = "hello world " .. string.rep("z", 5000)
    local ct = crypto.encrypt(k, "00112233445566778899aabbccddeeff", plain)
    t.neq(ct, plain)
    t.eq(crypto.encrypt(k, "00112233445566778899aabbccddeeff", ct), plain)
    t.neq(crypto.encrypt(k, "ffffffffffffffffffffffffffffffff", plain), ct)
end)

t.case("seal and open tables", function()
    local k = crypto.newKey()
    t.eq(#k, 64)
    local box = crypto.sealTable(k, { a = 1, b = { "x", "y" }, s = "str" }, "aad1")
    local v = crypto.openTable(k, box, "aad1")
    t.eq(v.a, 1)
    t.eq(v.b[2], "y")
    local _, err = crypto.openTable(k, box, "aad2")
    t.eq(err, "bad mac")
    local tampered = { z = 1, n = box.n, ct = box.ct:sub(2) .. "A", mac = box.mac }
    local _, err2 = crypto.openTable(k, tampered, "aad1")
    t.eq(err2, "bad mac")
    local _, err3 = crypto.openTable(crypto.newKey(), box, "aad1")
    t.eq(err3, "bad mac")
    local b2 = crypto.sealTable(k, { a = 1, b = { "x", "y" }, s = "str" }, "aad1")
    t.neq(b2.ct, box.ct)
end)

t.case("random and helpers", function()
    local seen = {}
    for _ = 1, 50 do
        local r = crypto.randHex(8)
        t.eq(#r, 16)
        t.ok(not seen[r], "duplicate random")
        seen[r] = true
    end
    t.ok(crypto.constEq("abc", "abc"))
    t.ok(not crypto.constEq("abc", "abd"))
    t.ok(not crypto.constEq("abc", "ab"))
    t.eq(crypto.adler32("Wikipedia"), 300286872)
    local salt = crypto.randHex(16)
    t.eq(crypto.passwordHash(salt, "pw"), crypto.passwordHash(salt, "pw"))
    t.neq(crypto.passwordHash(salt, "pw"), crypto.passwordHash(salt, "pw2"))
end)

t.finish()
