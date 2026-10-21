package.path = "./?.lua;" .. package.path
require("tests.shim").install()
local need = require("tools.devload").make(".")
local gateway = need("gateway")
local t = require("tests.tiny")

local function make(opts)
    opts = opts or {}
    local sent, ops, seen = {}, {}, {}
    local node = { realm = "EARTH", myId = 40, log = { info = function() end, warn = function() end }, links = { list = function() return {} end } }
    local gw = gateway.new(node, {
        isOff = function() return opts.off end,
        backend = {
            seen = function(cid) seen[#seen + 1] = cid end,
            blocked = function(cid) return cid == 13 end,
            connected = function() return true end,
            op = function(b) ops[#ops + 1] = b end,
        },
    })
    gw.transmit = function(_, cid, msg) sent[#sent + 1] = { cid = cid, msg = msg } return true end
    return gw, sent, ops, seen
end

t.case("topics are kept under the public prefix", function()
    t.eq(gateway.publicTopic("reactor.main"), "pub.reactor.main")
    t.eq(gateway.publicTopic("reactor.*"), nil)
    t.eq(gateway.publicTopic("bad topic"), nil)
    t.eq(gateway.publicPattern("reactor.*"), "pub.reactor.*")
    t.eq(gateway.publicPattern("re*ctor"), nil)
    t.eq(gateway.stripTopic("pub.reactor.main"), "reactor.main")
    t.eq(gateway.stripTopic("power.cell"), nil)
end)

t.case("ops reach the backend with the sender address", function()
    local gw, sent, ops, seen = make()
    gw:handle(61, { op = "publish", topic = "reactor.main", data = { heat = 1 } })
    gw:handle(61, { op = "send", to = "mars:60", data = "hi" })
    gw:handle(61, { op = "subscribe", topic = "reactor.*" })
    t.eq(#ops, 3)
    t.eq(ops[1].from, "EARTH:61")
    t.eq(ops[1].topic, "pub.reactor.main")
    t.eq(ops[2].to, "MARS:60")
    t.eq(ops[3].topic, "pub.reactor.*")
    t.eq(sent[1].msg.type, "subscribed")
    t.eq(seen[1], 61)
    t.eq(#seen, 1, "seen is reported once a minute, not per message")
end)

t.case("bad requests answer with an error", function()
    local gw, sent, ops = make()
    gw:handle(61, { op = "launch" })
    gw:handle(61, { op = "send", to = "nowhere at all", data = 1 })
    gw:handle(61, { op = "publish", topic = "x", data = string.rep("a", gateway.MAX_DATA + 10) })
    gw:handle(61, { op = "publish", topic = "x", data = function() end })
    t.eq(#ops, 0)
    t.eq(sent[1].msg.error, "bad_request")
    t.eq(sent[2].msg.error, "bad_address")
    t.eq(sent[3].msg.error, "too_large")
    t.eq(sent[4].msg.error, "bad_data")
end)

t.case("rate limit, blocked ids and the off switch", function()
    local gw, sent, ops = make()
    for _ = 1, gateway.RATE_COUNT + 3 do gw:handle(61, { op = "publish", topic = "x", data = 1 }) end
    t.eq(#ops, gateway.RATE_COUNT)
    t.eq(sent[#sent].msg.error, "rate_limited")
    gw:handle(13, { op = "ping" })
    t.eq(#sent, 3, "blocked ids get no answer")
    local off, offSent = make({ off = true })
    off:handle(61, { op = "ping" })
    t.eq(offSent[1].msg.error, "off")
end)

t.case("only public traffic reaches plain computers", function()
    local m = gateway.toPlain({ port = "pub", src = "MARS:60", body = "hi" }, false)
    t.eq(m.type, "message")
    t.eq(m.from, "MARS:60")
    m = gateway.toPlain({ port = "zn.ps", src = "MARS", body = { op = "msg", topic = "pub.reactor.main", data = 5, from = "MARS:60" } }, true)
    t.eq(m.topic, "reactor.main")
    t.eq(gateway.toPlain({ port = "zn.ps", src = "MARS", body = { op = "msg", topic = "power.cell", data = 5 } }, true), nil)
    t.eq(gateway.toPlain({ port = "zn.ps", src = "MARS:7", body = { op = "msg", topic = "pub.reactor.main", data = 5 } }, false), nil)
    t.eq(gateway.toPlain({ port = "zn.err", src = "MARS", body = { code = "no_route" } }, true).error, "no_route")
    t.eq(gateway.toPlain({ port = "tekmail", src = "MARS", body = {} }, true), nil)
end)

t.finish()
