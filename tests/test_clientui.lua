package.path = "./?.lua;" .. package.path
local env = require("tests.fakecc").install({ id = 12 })
local need = require("tools.devload").make(".")
local ui = need("ui")
local clientui = need("clientui")
local h = require("tests.uitest")
local t = require("tests.tiny")
h.extendKeys()

local ENTER, CTRL, DOWN, UP, TAB = { "key", 28 }, { "key", 29 }, { "key", 208 }, { "key", 200 }, { "key", 15 }

local function fakeServer()
    local S = {
        accounts = {
            alice = { pass = "pw12", display = "Alice", admin = false },
            bob = { pass = "bobpw", display = "Bob", admin = false },
            root = { pass = "rootpw", display = "Root", admin = true },
        },
        tokens = {},
        convs = {},
        rooms = { global = { seq = 0, msgs = {} }, MARS = { seq = 0, msgs = {} } },
        nextTok = 0,
    }
    local function conv(a, b)
        local key = a < b and (a .. "|" .. b) or (b .. "|" .. a)
        S.convs[key] = S.convs[key] or { seq = 0, msgs = {} }
        return S.convs[key]
    end
    function S.addMail(from, to, text, t)
        local c = conv(from, to)
        c.seq = c.seq + 1
        c.msgs[#c.msgs + 1] = { id = "m" .. c.seq, seq = c.seq, from = from, to = to, text = text, t = t or 30, readBy = {} }
        return c.seq
    end
    function S.addChat(room, user, text)
        local r = S.rooms[room]
        r.seq = r.seq + 1
        r.msgs[#r.msgs + 1] = { seq = r.seq, user = user, realm = "MARS", text = text, t = 31 }
    end
    local function unreadFor(user, peer)
        local c = conv(user, peer)
        local k = 0
        for _, m in ipairs(c.msgs) do if m.to == user and not m.readBy[user] then k = k + 1 end end
        return k
    end
    function S.handle(b)
        if b.op == "hello" then return { ok = true, realm = "MARS", motd = "Welcome to Mars", rooms = { "global", "MARS" }, prog = "1.0.0" } end
        if b.op == "login" or b.op == "create" then
            local name = tostring(b.user):lower()
            if b.op == "create" then
                if S.accounts[name] then return { ok = false, err = "taken", msg = "That name is already taken." } end
                S.accounts[name] = { pass = b.pass, display = b.user }
            end
            local a = S.accounts[name]
            if not a or a.pass ~= b.pass then return { ok = false, err = "denied", msg = "Wrong user name or password." } end
            S.nextTok = S.nextTok + 1
            local tok = "tok" .. S.nextTok
            S.tokens[tok] = name
            return { ok = true, token = tok, user = name, display = a.display, admin = a.admin == true, home = "MARS" }
        end
        local me = S.tokens[b.token]
        if not me or S.expireAll then return { ok = false, err = "bad_token", msg = "Your session has expired. Please log in again." } end
        if b.op == "logout" then
            S.tokens[b.token] = nil
            return { ok = true }
        elseif b.op == "unread" then
            local k = 0
            for peer in pairs(S.accounts) do if peer ~= me then k = k + unreadFor(me, peer) end end
            return { ok = true, count = k }
        elseif b.op == "inbox" then
            local convs, total = {}, 0
            for peer, a in pairs(S.accounts) do
                local c = conv(me, peer)
                if peer ~= me and #c.msgs > 0 then
                    local last = c.msgs[#c.msgs]
                    local u = unreadFor(me, peer)
                    total = total + u
                    convs[#convs + 1] = { peer = peer, display = a.display, unread = u, count = #c.msgs, lastT = last.t, lastFrom = last.from, lastText = last.text }
                end
            end
            table.sort(convs, function(x, y) return x.peer < y.peer end)
            return { ok = true, convs = convs, unread = total }
        elseif b.op == "thread" then
            if not S.accounts[b.peer] then return { ok = false, err = "unknown_user", msg = "No such user." } end
            local c = conv(me, b.peer)
            local out = {}
            for _, m in ipairs(c.msgs) do
                if m.seq > (b.since or 0) and (not b.before or m.seq < b.before) then
                    out[#out + 1] = { id = m.id, seq = m.seq, from = m.from, to = m.to, text = m.text, t = m.t, read = m.readBy[me] or false }
                end
                if m.to == me then m.readBy[me] = true end
            end
            return { ok = true, messages = out, seq = c.seq, peer = b.peer }
        elseif b.op == "send" then
            if not S.accounts[b.to] then return { ok = false, err = "unknown_user", msg = "No such user." } end
            S.addMail(me, b.to, b.text)
            return { ok = true, queued = S.queueSends or false }
        elseif b.op == "users" then
            local out = {}
            for name, a in pairs(S.accounts) do out[#out + 1] = { name = name, display = a.display, realm = "MARS" } end
            table.sort(out, function(x, y) return x.name < y.name end)
            return { ok = true, users = out }
        elseif b.op == "chat_get" then
            local r = S.rooms[b.room]
            local out = {}
            for _, m in ipairs(r.msgs) do if m.seq > (b.since or 0) then out[#out + 1] = m end end
            return { ok = true, room = b.room, messages = out, seq = r.seq }
        elseif b.op == "chat_post" then
            S.addChat(b.room, me, b.text)
            return { ok = true, seq = S.rooms[b.room].seq }
        elseif b.op == "passwd" then
            if S.accounts[me].pass ~= b.old then return { ok = false, err = "denied", msg = "The old password is wrong." } end
            S.accounts[me].pass = b.new
            return { ok = true }
        elseif b.op == "admin" then
            if not S.accounts[me].admin then return { ok = false, err = "denied", msg = "Admin rights are required." } end
            if b.action == "reset_pw" then
                S.accounts[b.target].pass = b.value
                return { ok = true, action = "reset_pw", target = b.target }
            elseif b.action == "list" then
                return { ok = true, users = { { name = "alice", display = "Alice", realm = "MARS", admin = false } } }
            end
            return { ok = false, err = "bad_request", msg = "Unknown admin action." }
        end
        return { ok = false, err = "bad_request", msg = "Bad request." }
    end
    return S
end

local function setup(opts)
    opts = opts or {}
    local S = fakeServer()
    local n, calls = h.makeNode(need, { handler = S.handle, latency = opts.latency })
    local surf = ui.surface(h.term(opts.w or 51, opts.h or 19, opts.color ~= false))
    return S, n, calls, surf
end

local function login(user, pass)
    return { ENTER, user, TAB, pass, ENTER, 0.5 }
end

local function steps(...)
    local out = {}
    for _, part in ipairs({ ... }) do
        if type(part) == "table" and part.seq then
            for _, x in ipairs(part.seq) do out[#out + 1] = x end
        else
            out[#out + 1] = part
        end
    end
    return out
end

local function seq(list) return { seq = list } end

t.case("welcome, bad login shows error, good login reaches main menu with unread badge", function()
    local S, n, calls, surf = setup()
    S.addMail("bob", "alice", "hello alice, this is the start of a long message that keeps going")
    local seen = {}
    h.drive(env, n, function() clientui.run(n, { surface = surf }) end, steps(
        function()
            h.expect(surf, "Login")
            h.expect(surf, "Create account")
            h.expect(surf, "Welcome to Mars")
            h.expect(surf, "Server MARS: connected")
        end,
        seq(login("alice", "nope")),
        function() h.expect(surf, "Wrong user name or password.") end,
        CTRL,
        seq(login("Alice", "pw12")),
        1,
        function()
            h.expect(surf, "Logged in as Alice")
            h.expect(surf, "(alice@MARS).")
            h.expect(surf, "(1)")
            h.expect(surf, "You have 1 unread")
            seen.main = true
        end
    ))
    t.ok(seen.main, "reached main menu")
    local first = h.find(calls, "login")
    t.eq(first.body.user, "alice")
    t.eq(first.body.token, nil, "no token on login")
    local good = h.find(calls, "login", select(2, h.find(calls, "login")) + 1)
    t.eq(good.body.user, "Alice", "typed case is sent, server lowercases")
    local un = h.find(calls, "unread")
    t.eq(un.body.token, "tok1")
end)

t.case("inbox shows preview from the start and unread marker, thread view sends and gets pushes", function()
    local S, n, calls, surf = setup()
    S.addMail("bob", "alice", "hello alice, this is the start of a long message that keeps going on and on")
    local state = {}
    h.drive(env, n, function() clientui.run(n, { surface = surf }) end, steps(
        seq(login("alice", "pw12")),
        { "char", "1" },
        0.5,
        function()
            h.expect(surf, "* Bob: hello alice, this is")
            h.expect(surf, "1 new")
        end,
        ENTER,
        0.5,
        function()
            h.expect(surf, "DM: Bob")
            h.expect(surf, "Bob: hello alice")
            h.expect(surf, "[You]: ")
        end,
        "hi bob",
        function() h.expect(surf, "[You]: hi bob") end,
        ENTER,
        0.6,
        function()
            h.expect(surf, "You: hi bob")
            h.refute(surf, "(sending)")
            local c = h.find(calls, "send")
            t.eq(c.body.to, "bob")
            t.eq(c.body.text, "hi bob")
            t.eq(c.retries, 1, "sends retry once, deduplicated by mid")
            t.ok(type(c.body.mid) == "string" and #c.body.mid <= 24 and c.body.mid:match("^[%w_%-]+$") ~= nil, "send carries a valid mid")
            state.threadCalls = h.count(calls, "thread")
        end,
        function()
            S.addMail("bob", "alice", "pushed reply")
            n:dispatch("tekmail", { src = "MARS", port = "tekmail", data = { op = "notify", kind = "mail", from = "bob", text = "pushed reply" } })
        end,
        0.6,
        function()
            h.expect(surf, "Bob: pushed reply")
            local last
            for _, c in ipairs(calls) do if c.body.op == "thread" then last = c end end
            t.eq(last.body.since, 2, "incremental fetch uses the since cursor")
        end,
        function()
            n:dispatch("tekmail", { src = "EARTH:5", port = "tekmail", data = { op = "notify", kind = "mail", from = "bob", text = "spoof" } })
        end,
        0.4,
        function() t.eq(h.count(calls, "thread"), state.threadCalls + 1, "notify from a non server address is ignored") end,
        CTRL,
        0.5,
        function()
            h.expect(surf, "Inbox")
            h.refute(surf, "* Bob")
            h.expect(surf, "Bob: pushed reply")
        end,
        CTRL,
        0.3,
        function() h.expect(surf, "Logged in as") end
    ))
end)

t.case("typing is never blocked while a send is slow", function()
    local S, n, calls, surf = setup({ latency = function(b) return b.op == "send" and 4 or 0.1 end })
    S.addMail("bob", "alice", "hey")
    h.drive(env, n, function() clientui.run(n, { surface = surf }) end, steps(
        seq(login("alice", "pw12")),
        { "char", "1" }, 0.5, ENTER, 0.5,
        "first", ENTER,
        "second line",
        function()
            h.expect(surf, "[You]: second line")
            h.expect(surf, "You: first (sending)")
        end,
        5,
        function()
            h.refute(surf, "(sending)")
            h.expect(surf, "[You]: second line")
        end
    ))
end)

t.case("new message validates the name and unknown users show an error", function()
    local S, n, calls, surf = setup()
    h.drive(env, n, function() clientui.run(n, { surface = surf }) end, steps(
        seq(login("alice", "pw12")),
        { "char", "2" },
        "X!", ENTER,
        function() h.expect(surf, "Names are 3 to 16 characters") end,
        { "key", 14 }, { "key", 14 }, "zed", ENTER,
        0.5,
        function()
            h.expect(surf, "DM: zed")
            h.expect(surf, "No such user: zed")
        end,
        "hello", ENTER,
        function()
            h.expect(surf, "No such user: zed")
            t.eq(h.find(calls, "send"), nil, "no send to unknown user")
        end
    ))
end)

t.case("chatroom uses chat_get with since, posts and refreshes on notify and slow poll", function()
    local S, n, calls, surf = setup()
    S.addChat("global", "bob", "anyone here?")
    local polls
    h.drive(env, n, function() clientui.run(n, { surface = surf }) end, steps(
        seq(login("alice", "pw12")),
        { "char", "3" },
        function()
            h.expect(surf, "Global chat")
            h.expect(surf, "MARS chat")
        end,
        ENTER, 0.5,
        function() h.expect(surf, "bob: anyone here?") end,
        "yes", ENTER, 0.6,
        function()
            h.expect(surf, "You: yes")
            local post = h.find(calls, "chat_post")
            t.eq(post.body.room, "global")
        end,
        function()
            S.addChat("global", "carol", "hi all")
            n:dispatch("tekmail", { src = "MARS", port = "tekmail", data = { op = "notify", kind = "chat", room = "global", from = "carol", text = "hi all" } })
        end,
        0.5,
        function()
            h.expect(surf, "carol: hi all")
            local last
            for _, c in ipairs(calls) do if c.body.op == "chat_get" then last = c end end
            t.eq(last.body.since, 2)
            polls = h.count(calls, "chat_get")
        end,
        11,
        function()
            t.ok(h.count(calls, "chat_get") >= polls + 1, "slow poll")
            t.ok(h.count(calls, "chat_get") <= polls + 2, "poll is slow, not 4 per second")
        end
    ))
end)

t.case("logout clears the session and the next user sees nothing of the previous one", function()
    local S, n, calls, surf = setup()
    S.addMail("bob", "alice", "secret for alice")
    h.drive(env, n, function() clientui.run(n, { surface = surf }) end, steps(
        seq(login("alice", "pw12")),
        { "char", "1" }, 0.5,
        function() h.expect(surf, "secret for alice") end,
        CTRL, 0.3,
        CTRL, 0.3,
        function() h.expect(surf, "Log out of TekMail?") end,
        ENTER, 0.5,
        function() h.expect(surf, "Create account") end,
        seq(login("root", "rootpw")),
        { "char", "1" }, 0.5,
        function()
            h.refute(surf, "secret for alice")
            h.expect(surf, "No conversations yet")
        end
    ))
    local lo = h.find(calls, "logout")
    t.eq(lo.body.token, "tok1")
    local _, i = h.find(calls, "logout")
    for k = i + 1, #calls do
        t.ok(calls[k].body.token ~= "tok1", "old token never reused")
    end
end)

t.case("expired session returns to the welcome screen with a notice", function()
    local S, n, calls, surf = setup()
    h.drive(env, n, function() clientui.run(n, { surface = surf }) end, steps(
        seq(login("alice", "pw12")),
        function() S.expireAll = true end,
        { "char", "4" }, 1,
        function()
            h.expect(surf, "Your session has")
            h.expect(surf, "Create account")
        end
    ))
end)

t.case("directory lists users and opens a DM", function()
    local S, n, calls, surf = setup()
    h.drive(env, n, function() clientui.run(n, { surface = surf }) end, steps(
        seq(login("alice", "pw12")),
        { "char", "4" }, 0.5,
        function()
            h.expect(surf, "Alice (you)")
            h.expect(surf, "Bob")
            h.expect(surf, "3 accounts")
        end,
        { "char", "2" }, 0.5,
        function() h.expect(surf, "DM: Bob") end
    ))
    local th = h.find(calls, "thread")
    t.eq(th.body.peer, "bob")
    t.eq(th.body.since, 0)
end)

t.case("admin tools reset a password, change password checks confirmation", function()
    local S, n, calls, surf = setup()
    h.drive(env, n, function() clientui.run(n, { surface = surf }) end, steps(
        seq(login("root", "rootpw")),
        function() h.expect(surf, "Admin tools") end,
        { "char", "5" },
        function() h.expect(surf, "Administrative actions") end,
        { "char", "2" },
        "bob", TAB, "newpw", ENTER, 0.5,
        function() h.expect(surf, "The password of bob was reset.") end,
        ENTER, CTRL,
        { "char", "6" },
        "rootpw", TAB, "abcd", TAB, "abce", ENTER,
        function() h.expect(surf, "The new passwords do not match.") end,
        CTRL
    ))
    t.eq(S.accounts.bob.pass, "newpw")
    local c = h.find(calls, "admin")
    t.eq(c.body.action, "reset_pw")
    t.eq(c.body.target, "bob")
    t.eq(h.find(calls, "passwd"), nil)
end)

t.case("network status and ping work without logging in", function()
    local S, n, calls, surf = setup()
    h.drive(env, n, function() clientui.run(n, { surface = surf }) end, steps(
        { "char", "3" },
        function()
            h.expect(surf, "Network Status")
            h.expect(surf, "MARS:12")
            h.expect(surf, "connected")
        end,
        ENTER, 0.5,
        function() h.expect(surf, "Round trip: 0.25 s") end,
        ENTER, CTRL,
        { "char", "4" }, 0.5,
        function() h.expect(surf, "The server MARS answered.") end,
        ENTER,
        { "char", "5" }
    ))
end)

t.case("exit from the welcome screen ends run", function()
    local S, n, calls, surf = setup()
    local finished = false
    n:spawn(function()
        sleep(0.5)
        os.queueEvent("char", "5")
    end, "driver")
    env.run(function()
        n:loop(function()
            clientui.run(n, { surface = surf })
            finished = true
        end)
    end, 60)
    t.ok(finished)
end)

t.case("monochrome computer works with keyboard only", function()
    local S, n, calls, surf = setup({ color = false })
    S.addMail("bob", "alice", "mono hello")
    h.drive(env, n, function() clientui.run(n, { surface = surf }) end, steps(
        function() h.expect(surf, ">1 Login") end,
        DOWN,
        function() h.expect(surf, ">2 Create account") end,
        UP,
        seq(login("alice", "pw12")),
        ENTER, 0.5,
        ENTER, 0.5,
        function() h.expect(surf, "Bob: mono hello") end
    ))
end)

t.case("mail notify pulses redstone on the configured side", function()
    local S, n, calls, surf = setup()
    local outputs = {}
    _G.redstone = { setOutput = function(side, on) outputs[#outputs + 1] = side .. "=" .. tostring(on) end }
    h.drive(env, n, function() clientui.run(n, { surface = surf, pulseSide = "top" }) end, steps(
        seq(login("alice", "pw12")),
        function()
            n:dispatch("tekmail", { src = "MARS", port = "tekmail", data = { op = "notify", kind = "mail", from = "bob", text = "ding" } })
        end,
        1,
        function()
            h.expect(surf, "Latest from bob: ding")
            t.eq(h.count(calls, "unread") >= 2, true, "push triggers an unread refresh")
        end
    ))
    _G.redstone = nil
    t.eq(outputs[1], "top=true")
    t.eq(outputs[2], "top=false")
end)

t.case("notify from the home realm server of a proxied user is accepted", function()
    local S, n, calls, surf = setup()
    S.addMail("bob", "alice", "hey")
    local before
    h.drive(env, n, function() clientui.run(n, { surface = surf }) end, steps(
        seq(login("alice", "pw12")),
        { "char", "1" }, 0.5, ENTER, 0.5,
        function()
            h.expect(surf, "Bob: hey")
            before = h.count(calls, "thread")
            S.addMail("bob", "alice", "from earth home")
            n:dispatch("tekmail", { src = "EARTH", port = "tekmail", data = { op = "notify", kind = "mail", from = "bob", text = "from earth home" } })
        end,
        0.6,
        function()
            t.ok(h.count(calls, "thread") > before, "notify from another server triggers a fetch")
            h.expect(surf, "Bob: from earth home")
        end
    ))
end)

t.case("replies from a non server address are rejected", function()
    local S = fakeServer()
    local n, calls = h.makeNode(need, { handler = function(b, dst, port)
        local r = S.handle(b)
        if b.op == "login" then return r, "MARS:66" end
        return r, "MARS"
    end })
    local surf = ui.surface(h.term(51, 19, true))
    h.drive(env, n, function() clientui.run(n, { surface = surf }) end, steps(
        seq(login("alice", "pw12")),
        function()
            h.expect(surf, "Access denied.")
            h.refute(surf, "Logged in as")
        end
    ))
end)

t.case("malformed server replies do not crash the client", function()
    local S = fakeServer()
    local n, calls = h.makeNode(need, { handler = function(b)
        if b.op == "inbox" then return { ok = true, convs = { 5, "x", { peer = { 1 }, display = 7, unread = "z", lastT = "q", lastText = { } } }, unread = "a" } end
        if b.op == "thread" then return { ok = true, messages = "nope", seq = "x" } end
        if b.op == "users" then return { ok = true, users = { 1, { name = 5, display = {} } } } end
        return S.handle(b)
    end })
    local surf = ui.surface(h.term(51, 19, true))
    local alive = false
    h.drive(env, n, function() clientui.run(n, { surface = surf }) end, steps(
        seq(login("alice", "pw12")),
        { "char", "1" }, 0.5,
        function() h.expect(surf, "Inbox") end,
        CTRL, 0.3,
        { "char", "2" }, "bobby", ENTER, 0.5,
        function() h.expect(surf, "DM: bobby") end,
        CTRL, 0.3,
        { "char", "4" }, 0.5,
        function()
            h.expect(surf, "Directory")
            alive = true
        end
    ))
    t.ok(alive, "client survived")
end)

t.finish()
