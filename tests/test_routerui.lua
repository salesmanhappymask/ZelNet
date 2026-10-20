package.path = "./?.lua;" .. package.path
local env = require("tests.fakecc").install({ id = 21 })
local need = require("tools.devload").make(".")
local ui = need("ui")
local routerui = need("routerui")
local h = require("tests.uitest")
local t = require("tests.tiny")
h.extendKeys()

local ENTER, CTRL, TAB = { "key", 28 }, { "key", 29 }, { "key", 15 }

local function setup(role, opts)
    opts = opts or {}
    local n = h.makeNode(need, { role = role, name = role == "router" and "rt1" or "ep1", pingFail = opts.pingFail })
    n.cands = { [3] = { hops = 0, seq = 10, link = "modem:top", root = 3, t = 0 }, [8] = { hops = 1, seq = 10, link = "bitnet:bitnet_tower_0", root = 3, t = 0 } }
    n.downRoutes = { [30] = { via = 30, t = 0 }, [31] = { via = 30, t = 0 } }
    n.counters.forwarded = 42
    n.links.list = function()
        return { { id = "modem:top", kind = "modem", wireless = true, open = true, tx = 7, rx = 9 } }
    end
    local surf = ui.surface(h.term(opts.w or 51, opts.h or 19, true))
    return n, surf
end

t.case("router status shows realm, parent, hops, links, forwarded and uptime", function()
    local n, surf = setup("router")
    h.drive(env, n, function() routerui.run(n, { surface = surf, mode = "router" }) end, {
        function()
            h.expect(surf, "ZelNet Router")
            h.expect(surf, "MARS:21")
            h.expect(surf, "Realm")
            h.expect(surf, "connected")
            h.expect(surf, "computer 3, 1 hop via modem:top")
            h.expect(surf, "1 open, 2 beacon sources")
            h.expect(surf, "42 packets, 2 routes below")
            h.expect(surf, "Uptime")
            h.expect(surf, "Ping server")
            h.refute(surf, "Library")
        end,
    })
end)

t.case("tabs by keyboard, links and neighbors views", function()
    local n, surf = setup("router")
    h.drive(env, n, function() routerui.run(n, { surface = surf }) end, {
        TAB,
        function()
            h.expect(surf, "LINKS")
            h.expect(surf, "modem:top wireless")
            h.expect(surf, "tx 7 rx 9")
        end,
        TAB,
        function()
            h.expect(surf, "* computer 3, hops 0, modem:top")
            h.expect(surf, "  computer 8, hops 1, bitnet")
            h.expect(surf, "Downstream routes")
        end,
        { "char", "1" },
        function() h.expect(surf, "Forwarded") end,
    })
end)

t.case("log view follows n.log and scrolls", function()
    local n, surf = setup("router")
    h.drive(env, n, function() routerui.run(n, { surface = surf }) end, {
        { "char", "4" },
        function()
            for i = 1, 30 do n.log.info("event number " .. i) end
        end,
        function()
            h.expect(surf, "event number 30")
            h.refute(surf, "event number 5 ")
        end,
        { "key", keys.pageUp },
        function() h.refute(surf, "event number 30") end,
        function() n.log.warn("late arrival") end,
        function()
            h.refute(surf, "late arrival")
            h.expect(surf, "1 new")
        end,
        { "key", keys["end"] },
        function() h.expect(surf, "late arrival") end,
    })
end)

t.case("ping server does not block and shows the result", function()
    local n, surf = setup("router")
    h.drive(env, n, function() routerui.run(n, { surface = surf }) end, {
        { "char", "p" },
        0.5,
        function()
            h.expect(surf, "0.25 s round trip")
        end,
        { "char", "4" },
        function() h.expect(surf, "ping MARS: 0.25 s") end,
    })
end)

t.case("failed ping is shown", function()
    local n, surf = setup("router", { pingFail = true })
    h.drive(env, n, function() routerui.run(n, { surface = surf }) end, {
        ENTER, 0.5,
        function() h.expect(surf, "failed: timeout") end,
    })
end)

t.case("endpoint mode shows the library hint", function()
    local n, surf = setup("endpoint")
    h.drive(env, n, function() routerui.run(n, { surface = surf, mode = "endpoint" }) end, {
        function()
            h.expect(surf, "ZelNet Endpoint")
            h.expect(surf, "local zn = dofile(\"/zelnet\")")
            h.refute(surf, "Forwarded")
        end,
        { "char", "5" },
        function()
            h.expect(surf, "LIBRARY")
            h.expect(surf, "assert(zn.open())")
            h.expect(surf, "os.loadAPI")
        end,
    })
end)

t.case("Ctrl asks before exiting, Enter confirms and run returns", function()
    local n, surf = setup("router")
    local done = false
    n:spawn(function()
        sleep(0.5)
        os.queueEvent("key", keys.leftCtrl)
        sleep(0.3)
        assert(h.has(surf, "Stop the router"), "confirm shown")
        os.queueEvent("key", keys.backspace)
        sleep(0.3)
        assert(h.has(surf, "Realm"), "back on status")
        os.queueEvent("key", keys.rightCtrl)
        sleep(0.3)
        os.queueEvent("key", keys.enter)
    end, "driver", { critical = true })
    env.run(function()
        n:loop(function()
            routerui.run(n, { surface = surf })
            done = true
        end)
    end, 60)
    t.ok(done)
end)

t.case("narrow pocket screen renders", function()
    local n, surf = setup("endpoint", { w = 26, h = 20 })
    h.drive(env, n, function() routerui.run(n, { surface = surf }) end, {
        function()
            h.expect(surf, "Realm")
            h.expect(surf, "Ping server")
        end,
    })
end)

t.case("scrolled log stays anchored when a wrapped entry arrives", function()
    local n, surf = setup("router")
    local v = routerui.new(n, { surface = surf, mode = "router" })
    for i = 1, 40 do n.log.info("line " .. i) end
    v.tab = "log"
    v.active = true
    v:attachLog()
    v:draw()
    v:scroll(5)
    v:draw()
    local topBefore = h.rows(surf)[7]
    n.log.info(string.rep("long words here ", 12))
    v:draw()
    t.eq(h.rows(surf)[7], topBefore, "view did not move")
    t.eq(v.unseen, 1)
end)

t.finish()
