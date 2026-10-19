package.path = "./?.lua;" .. package.path
local shim = require("tests.shim")
shim.install()
local need = require("tools.devload").make(".")
local codec = need("codec")
local t = require("tests.tiny")

local function roundTrip(v)
    local s = assert(codec.encode(v))
    local back, err = codec.decode(s)
    if back == nil and v ~= nil then error("decode failed: " .. tostring(err) .. " for " .. s) end
    return back, s
end

t.case("scalars", function()
    t.eq(roundTrip(1), 1)
    t.eq(roundTrip(-42), -42)
    t.eq(roundTrip(3.25), 3.25)
    t.eq(roundTrip(1e20), 1e20)
    t.eq(roundTrip(123456789012), 123456789012)
    t.eq(roundTrip(true), true)
    t.eq(roundTrip(false), false)
    t.eq(roundTrip("hi"), "hi")
    t.eq(roundTrip(math.huge), math.huge)
    t.eq(roundTrip(-math.huge), -math.huge)
    local nan = roundTrip(0 / 0)
    t.ok(nan ~= nan)
end)

t.case("binary strings are ASCII safe", function()
    local all = {}
    for i = 0, 255 do all[#all + 1] = string.char(i) end
    local s = table.concat(all) .. "123"
    local back, enc = roundTrip(s)
    t.eq(back, s)
    t.ok(not enc:find("[\128-\255]"), "non ASCII in output")
    t.ok(not enc:find("[%z\1-\31]"), "control chars in output")
    t.eq(roundTrip("\0011"), "\0011")
    t.eq(roundTrip("a\nb\"c\\d"), "a\nb\"c\\d")
end)

t.case("tables", function()
    local v = { 1, 2, "three", { nested = true, list = { 4, 5 } }, key = "value", ["with space"] = 7, [10] = "sparse", [false] = 1, ["end"] = 2 }
    local back = roundTrip(v)
    t.eq(back[3], "three")
    t.eq(back[4].nested, true)
    t.eq(back[4].list[2], 5)
    t.eq(back.key, "value")
    t.eq(back["with space"], 7)
    t.eq(back[10], "sparse")
    t.eq(back[false], 1)
    t.eq(back["end"], 2)
    t.eq(roundTrip({}).x, nil)
end)

t.case("rejects code and junk", function()
    t.eq(codec.decode("(function() while true do end end)()"), nil)
    t.eq(codec.decode("os.shutdown()"), nil)
    t.eq(codec.decode("{ x = function() end }"), nil)
    t.eq(codec.decode("{1,2"), nil)
    t.eq(codec.decode("\"unterminated"), nil)
    t.eq(codec.decode("{} extra"), nil)
    t.eq(codec.decode(string.rep("{", 100) .. string.rep("}", 100)), nil)
    local r, err = codec.decode("{ [nil] = 1 }")
    t.eq(r, nil)
    t.ok(err)
end)

t.case("reads textutils output", function()
    local src = textutils.serialize({ a = 1, b = { "x", "y" }, ["k k"] = true, [5] = 3 })
    local back = assert(codec.decode(src))
    t.eq(back.a, 1)
    t.eq(back.b[2], "y")
    t.eq(back["k k"], true)
    t.eq(back[5], 3)
end)

t.case("refuses recursion and functions", function()
    local r = {}
    r.self = r
    t.eq(codec.encode(r), nil)
    t.eq(codec.encode(print), nil)
    local s = codec.encode({ a = 1, f = print })
    t.eq(codec.decode(s).f, nil)
end)

t.finish()
