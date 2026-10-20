package.path = "./?.lua;" .. package.path
local nativePcall = pcall
local env = require("tests.fakecc").install({ id = 7 })
rawset(_G, "__nativePcall", rawget(_G, "__nativePcall") or nativePcall)
local need = require("tools.devload").make(".")
local util = need("util")
local config = need("config")
local node = need("node")
local storage = need("storage")
local tekmail = need("tekmail")
local version = need("version")
local t = require("tests.tiny")

local function fakeServer(dir, realm)
    local srv = { realm = realm, broadcasts = {}, calls = {} }
    function srv:userHome(u) return dir.users[u] end
    function srv:claimUser(u)
        self.calls[#self.calls + 1] = "claim:" .. u
        if dir.offline then return nil, "offline" end
        local cur = dir.users[u]
        if cur and cur ~= realm then return nil, "taken" end
        dir.users[u] = realm
        return true
    end
    function srv:releaseUser(u)
        if dir.offline then return nil, "offline" end
        if not dir.users[u] then return nil, "unknown_user" end
        dir.users[u] = nil
        return true
    end
    function srv:renameUser(o, n)
        if dir.offline then return nil, "offline" end
        if dir.users[n] then return nil, "taken" end
        dir.users[n] = dir.users[o]
        dir.users[o] = nil
        return true
    end
    function srv:listUsers()
        local out = {}
        for _, u in ipairs(util.sortedKeys(dir.users)) do out[#out + 1] = { name = u, realm = dir.users[u] } end
        return out
    end
    function srv:broadcastRealms(port, body)
        self.broadcasts[#self.broadcasts + 1] = { port = port, body = util.deepCopy(body) }
        if dir.onBroadcast then dir.onBroadcast(realm, port, body) end
        return true
    end
    function srv:realms()
        local out = {}
        for r, up in pairs(dir.reach) do out[#out + 1] = { realm = r, reachable = up } end
        out[#out + 1] = { realm = realm, reachable = true }
        return out
    end
    return srv
end

local function newDir()
    return { users = {}, reach = { EARTH = true, MARS = true, VENUS = false } }
end

local function mkRealm(realm, dir, opts)
    opts = opts or {}
    local cfg = opts.cfg or config.newServer({ role = realm == "EARTH" and "main" or "satellite", realm = realm, mainRealm = "EARTH", network = "T" })
    cfg.storage = { dir = "/data_" .. realm:lower(), drives = {} }
    if opts.plain then cfg.dataKey = nil end
    local n = node.new(cfg)
    local ctx = { cfg = cfg, log = n.log, node = n, version = version }
    ctx.emit = function(ev, ...) n:emit(ev, ...) end
    ctx.storage = storage.new(ctx)
    ctx.storage:init()
    ctx.server = fakeServer(dir, realm)
    local tm = tekmail.new(ctx)
    ctx.tekmail = tm
    tm:start()
    return { n = n, tm = tm, ctx = ctx, srv = ctx.server, realm = realm }
end

local function drain(n)
    local out = {}
    while true do
        local p = n.outq.pop()
        if not p then break end
        out[#out + 1] = p
    end
    return out
end

local function wipe()
    for path in pairs(env.files()) do env.files()[path] = nil end
end

local function c(r, client, body) return r.tm:handleClient(client, body) end

local function run(fn)
    return function() env.run(fn, 1000000) end
end

local function account(r, client, user, pass)
    local res = c(r, client, { op = "create", user = user, pass = pass or "secret" })
    assert(res.ok, "create " .. user .. ": " .. tostring(res.err))
    return res.token
end

t.case("name and text rules", function()
    t.eq(tekmail.normUser("Alice"), "alice")
    t.eq(tekmail.normUser("  bob_1 "), "bob_1")
    t.eq(tekmail.normUser("ab"), nil)
    t.eq(tekmail.normUser("1abc"), nil)
    t.eq(tekmail.normUser("abc-d"), nil)
    t.eq(tekmail.normUser(string.rep("a", 17)), nil)
    t.eq(tekmail.displayName("Alice", "alice"), "Alice")
    t.eq(tekmail.displayName("Other", "alice"), "alice")
    t.eq(tekmail.passwordProblem("abc"), "weak_password")
    t.eq(tekmail.passwordProblem("abcd"), nil)
    t.eq(tekmail.passwordProblem({}), "bad_request")
    local s = tekmail.cleanText("  hi\r\nthere\t\1 ", 100)
    t.eq(s, "hi\nthere ?")
    t.eq(select(2, tekmail.cleanText(string.rep("x", 1001), 1000)), "too_long")
    t.eq(select(2, tekmail.cleanText("   ", 1000)), "bad_request")
    t.eq(tekmail.cleanText("a\nb", 10, true), "a b")
end)

t.case("create, login, whoami, token binding and logout", run(function()
    wipe()
    local dir = newDir()
    local r = mkRealm("MARS", dir)
    local hello = c(r, "MARS:10", { op = "hello" })
    t.ok(hello.ok)
    t.eq(hello.realm, "MARS")
    t.eq(hello.rooms[1], "global")
    t.eq(hello.rooms[2], "MARS")
    t.eq(hello.prog, version.program)
    local res = c(r, "MARS:10", { op = "create", user = "Alice", pass = "pw12" })
    t.ok(res.ok, tostring(res.err))
    t.eq(res.user, "alice")
    t.eq(res.display, "Alice")
    t.eq(res.home, "MARS")
    t.eq(dir.users.alice, "MARS")
    t.eq(c(r, "MARS:10", { op = "create", user = "alice", pass = "pw12" }).err, "taken")
    t.eq(c(r, "MARS:10", { op = "create", user = "a!", pass = "pw12" }).err, "bad_name")
    t.eq(c(r, "MARS:10", { op = "create", user = "console", pass = "pw12" }).err, "bad_name")
    t.eq(c(r, "MARS:11", { op = "create", user = "weakling", pass = "pw" }).err, "weak_password")
    dir.users.zed = "EARTH"
    t.eq(c(r, "MARS:11", { op = "create", user = "zed", pass = "pw12" }).err, "taken")
    local who = c(r, "MARS:10", { op = "whoami", token = res.token })
    t.ok(who.ok)
    t.eq(who.user, "alice")
    t.eq(who.admin, false)
    t.eq(c(r, "MARS:99", { op = "whoami", token = res.token }).err, "bad_token")
    t.eq(c(r, "MARS:10", { op = "whoami", token = "nope" }).err, "bad_token")
    t.eq(c(r, "MARS:10", { op = "whoami" }).err, "bad_token")
    local li = c(r, "MARS:12", { op = "login", user = "ALICE", pass = "pw12" })
    t.ok(li.ok)
    t.eq(c(r, "MARS:12", { op = "login", user = "alice", pass = "bad1" }).err, "denied")
    t.eq(c(r, "MARS:12", { op = "login", user = "ghost", pass = "bad1" }).err, "unknown_user")
    t.ok(c(r, "MARS:12", { op = "logout", token = li.token }).ok)
    t.eq(c(r, "MARS:12", { op = "whoami", token = li.token }).err, "bad_token")
    t.eq(c(r, "MARS:12", { op = "frob", token = li.token }).err, "bad_request")
    t.eq(c(r, "MARS:12", "junk").err, "bad_request")
end))

t.case("password change, session limit and login throttling", run(function()
    wipe()
    local r = mkRealm("MARS", newDir())
    local tok = account(r, "MARS:1", "bob", "first")
    local tokens = {}
    for i = 1, 5 do
        local li = c(r, "MARS:" .. (20 + i), { op = "login", user = "bob", pass = "first" })
        t.ok(li.ok)
        tokens[i] = li.token
        env.advance(1)
    end
    local live = 0
    for _, s in ipairs(r.tm:sessions()) do if s.user == "bob" then live = live + 1 end end
    t.eq(live, 4)
    t.eq(c(r, "MARS:1", { op = "whoami", token = tok }).err, "bad_token", "oldest session dropped")
    t.eq(c(r, "MARS:25", { op = "passwd", token = tokens[5], old = "wrong", new = "second" }).err, "denied")
    t.eq(c(r, "MARS:25", { op = "passwd", token = tokens[5], old = "first", new = "x" }).err, "weak_password")
    t.ok(c(r, "MARS:25", { op = "passwd", token = tokens[5], old = "first", new = "second" }).ok)
    t.ok(c(r, "MARS:25", { op = "whoami", token = tokens[5] }).ok, "current session kept")
    t.eq(c(r, "MARS:24", { op = "whoami", token = tokens[4] }).err, "bad_token", "other sessions dropped")
    t.ok(c(r, "MARS:30", { op = "login", user = "bob", pass = "second" }).ok)
    for _ = 1, 5 do c(r, "MARS:31", { op = "login", user = "bob", pass = "nope" }) end
    local blocked = c(r, "MARS:31", { op = "login", user = "bob", pass = "second" })
    t.eq(blocked.err, "denied")
    t.ok(blocked.msg:find("Too many"))
    env.advance(61)
    t.ok(c(r, "MARS:31", { op = "login", user = "bob", pass = "second" }).ok)
end))

t.case("token expires after six hours idle", run(function()
    wipe()
    local r = mkRealm("MARS", newDir())
    local tok = account(r, "MARS:1", "carl")
    env.advance(3600)
    t.ok(c(r, "MARS:1", { op = "unread", token = tok }).ok)
    env.advance(tekmail.TOKEN_IDLE - 10)
    t.ok(c(r, "MARS:1", { op = "unread", token = tok }).ok, "use refreshes idle timer")
    env.advance(tekmail.TOKEN_IDLE + 1)
    t.eq(c(r, "MARS:1", { op = "unread", token = tok }).err, "bad_token")
end))

t.case("local mail: send, notify, inbox, thread with incremental fetch", run(function()
    wipe()
    local r = mkRealm("MARS", newDir())
    local ta = account(r, "MARS:1", "alice")
    local tb = account(r, "MARS:2", "Bob")
    drain(r.n)
    local s1 = c(r, "MARS:1", { op = "send", token = ta, to = "bob", text = "hello bob" })
    t.ok(s1.ok, tostring(s1.err))
    t.eq(s1.queued, false)
    local out = drain(r.n)
    t.eq(#out, 1)
    t.eq(out[1].dst, "MARS:2")
    t.eq(out[1].port, "tekmail")
    t.eq(out[1].body.op, "notify")
    t.eq(out[1].body.kind, "mail")
    t.eq(out[1].body.from, "alice")
    c(r, "MARS:1", { op = "send", token = ta, to = "bob", text = "second" })
    t.eq(c(r, "MARS:2", { op = "unread", token = tb }).count, 2)
    local inbox = c(r, "MARS:2", { op = "inbox", token = tb })
    t.ok(inbox.ok)
    t.eq(inbox.unread, 2)
    t.eq(#inbox.convs, 1)
    t.eq(inbox.convs[1].peer, "alice")
    t.eq(inbox.convs[1].unread, 2)
    t.eq(inbox.convs[1].lastText, "second")
    t.eq(inbox.convs[1].lastFrom, "alice")
    local th = c(r, "MARS:2", { op = "thread", token = tb, peer = "alice" })
    t.ok(th.ok)
    t.eq(#th.messages, 2)
    t.eq(th.seq, 2)
    t.eq(th.messages[1].text, "hello bob")
    t.eq(th.messages[1].read, false, "read state before this fetch")
    t.eq(c(r, "MARS:2", { op = "unread", token = tb }).count, 0)
    c(r, "MARS:2", { op = "send", token = tb, to = "Alice", text = "hi back" })
    local th2 = c(r, "MARS:2", { op = "thread", token = tb, peer = "alice", since = th.seq })
    t.eq(#th2.messages, 1)
    t.eq(th2.messages[1].from, "bob")
    t.eq(th2.messages[1].read, true)
    t.eq(th2.seq, 3)
    t.eq(#c(r, "MARS:2", { op = "thread", token = tb, peer = "alice", since = 3 }).messages, 0)
    local ainbox = c(r, "MARS:1", { op = "inbox", token = ta })
    t.eq(ainbox.convs[1].peer, "bob")
    t.eq(ainbox.convs[1].display, "Bob")
    t.eq(ainbox.unread, 1)
    t.eq(c(r, "MARS:1", { op = "send", token = ta, to = "nobody", text = "x" }).err, "unknown_user")
    t.eq(c(r, "MARS:1", { op = "send", token = ta, to = "alice", text = "x" }).err, "bad_request")
    t.eq(c(r, "MARS:1", { op = "send", token = ta, to = "bob", text = string.rep("y", 1001) }).err, "too_long")
    t.eq(c(r, "MARS:1", { op = "thread", token = ta, peer = "ghost" }).err, "unknown_user")
    local dup1 = c(r, "MARS:1", { op = "send", token = ta, to = "bob", text = "once", mid = "m1" })
    local dup2 = c(r, "MARS:1", { op = "send", token = ta, to = "bob", text = "once", mid = "m1" })
    t.ok(dup1.ok and dup2.ok and dup2.dup, "retried send with the same mid is ignored")
    t.eq(c(r, "MARS:2", { op = "unread", token = tb }).count, 1)
end))

t.case("lists are bounded: 50 per fetch, 200 per conversation, reply size", run(function()
    wipe()
    local r = mkRealm("MARS", newDir(), { plain = true })
    local ta = account(r, "MARS:1", "alice")
    local tb = account(r, "MARS:2", "bob")
    for i = 1, 210 do
        local res = c(r, "MARS:1", { op = "send", token = ta, to = "bob", text = "m" .. i })
        assert(res.ok, res.err)
    end
    local th = c(r, "MARS:2", { op = "thread", token = tb, peer = "alice" })
    t.eq(#th.messages, 50)
    t.eq(th.messages[50].text, "m210")
    t.eq(th.messages[1].text, "m161")
    t.ok(th.more)
    local older = c(r, "MARS:2", { op = "thread", token = tb, peer = "alice", before = th.messages[1].seq })
    t.eq(older.messages[50].text, "m160")
    local conv = r.ctx.storage:read("mail", "bob/alice.db")
    t.eq(#conv.msgs, 200)
    t.eq(conv.msgs[1].text, "m11")
    for i = 1, 12 do c(r, "MARS:1", { op = "send", token = ta, to = "bob", text = string.rep("z", 990) .. i }) end
    local big = c(r, "MARS:2", { op = "thread", token = tb, peer = "alice", since = 210 })
    t.ok(#big.messages < 12 and #big.messages > 0, "byte budget limits a fetch")
    t.ok(#need("codec").encode(big) <= tekmail.REPLY_MAX)
    t.eq(big.messages[#big.messages].text, string.rep("z", 990) .. "12")
end))

t.case("send to another realm uses the outbox and clears pending on ack", run(function()
    wipe()
    local dir = newDir()
    local r = mkRealm("MARS", dir)
    local ta = account(r, "MARS:1", "alice")
    dir.users.carol = "EARTH"
    drain(r.n)
    local res = c(r, "MARS:1", { op = "send", token = ta, to = "carol", text = "hi carol" })
    t.ok(res.ok)
    t.eq(res.queued, false)
    local out = drain(r.n)
    t.eq(#out, 1)
    local pkt = out[1]
    t.eq(pkt.dst, "EARTH")
    t.eq(pkt.port, "tekmail.fed")
    t.ok(pkt.rq)
    t.eq(pkt.body.op, "deliver")
    t.eq(pkt.body.item.from, "alice")
    t.eq(pkt.body.item.fromRealm, "MARS")
    t.eq(pkt.body.item.to, "carol")
    t.eq(#r.tm.outbox, 1)
    local stored = r.ctx.storage:read("system", "outbox.db")
    t.eq(#stored.items, 1, "outbox persisted")
    local th = c(r, "MARS:1", { op = "thread", token = ta, peer = "carol" })
    t.eq(th.messages[1].pending, true)
    r.n:deliver({ v = 1, id = util.newId(), src = "EARTH", dst = "MARS", port = "tekmail.fed", re = pkt.id, body = { ok = true } })
    t.eq(#r.tm.outbox, 0)
    t.eq(#r.ctx.storage:read("system", "outbox.db").items, 0)
    th = c(r, "MARS:1", { op = "thread", token = ta, peer = "carol" })
    t.eq(th.messages[1].pending, nil)
    dir.users.vic = "VENUS"
    local q = c(r, "MARS:1", { op = "send", token = ta, to = "vic", text = "anyone?" })
    t.eq(q.queued, true, "unreachable realm reports queued")
end))

t.case("outbox retries after timeout, survives restart, fails permanently on unknown user", run(function()
    wipe()
    local dir = newDir()
    local r = mkRealm("MARS", dir)
    local ta = account(r, "MARS:1", "alice")
    dir.users.dave = "EARTH"
    drain(r.n)
    c(r, "MARS:1", { op = "send", token = ta, to = "dave", text = "ping" })
    local first = drain(r.n)[1]
    t.ok(first)
    r.n:failPending(first.id, "timeout")
    t.eq(#r.tm.outbox, 1)
    t.eq(r.tm.outbox[1].tries, 1)
    r.tm:pumpOutbox()
    t.eq(#drain(r.n), 0, "backoff holds the retry")
    env.advance(tekmail.RETRY_BASE + 1)
    r.tm:pumpOutbox()
    local second = drain(r.n)
    t.eq(#second, 1)
    t.eq(second[1].body.item.id, first.body.item.id, "same message id on retry")
    r.tm:flush()
    local r2 = mkRealm("MARS", dir, { cfg = r.ctx.cfg })
    t.eq(#r2.tm.outbox, 1, "outbox reloaded after restart")
    env.advance(30)
    r2.tm:pumpOutbox()
    local third = drain(r2.n)
    t.eq(#third, 1)
    r2.n:deliver({ v = 1, id = util.newId(), src = "EARTH", dst = "MARS", port = "tekmail.fed", re = third[1].id, body = { ok = false, err = "unknown_user" } })
    t.eq(#r2.tm.outbox, 0)
    local notes = drain(r2.n)
    local th = r2.ctx.storage:read("mail", "alice/dave.db")
    t.ok(th.msgs[1].failed, "message marked failed")
    t.eq(#notes, 1, "sender notified through the restored session")
    t.eq(notes[1].dst, "MARS:1")
    t.eq(notes[1].body.failed, true)
end))

t.case("federated delivery from another realm with dedupe and checks", run(function()
    wipe()
    local dir = newDir()
    local r = mkRealm("MARS", dir)
    local tb = account(r, "MARS:2", "bob")
    dir.users.erin = "EARTH"
    drain(r.n)
    local item = { id = "abc123", from = "erin", fromRealm = "EARTH", to = "bob", text = "from earth", t = 5, display = "Erin" }
    r.tm:onFed({ src = "EARTH", data = { op = "deliver", item = item }, rq = true, id = util.newId(), port = "tekmail.fed" })
    local out = drain(r.n)
    local reply, note
    for _, p in ipairs(out) do
        if p.dst == "EARTH" then reply = p.body end
        if p.dst == "MARS:2" then note = p.body end
    end
    t.ok(reply and reply.ok)
    t.eq(note.kind, "mail")
    t.eq(note.from, "erin")
    r.tm:onFed({ src = "EARTH", data = { op = "deliver", item = item }, rq = true, id = util.newId(), port = "tekmail.fed" })
    out = drain(r.n)
    t.eq(#out, 1, "duplicate acked without a second notify")
    t.ok(out[1].body.ok and out[1].body.dup)
    local inbox = c(r, "MARS:2", { op = "inbox", token = tb })
    t.eq(inbox.convs[1].peer, "erin")
    t.eq(inbox.convs[1].display, "Erin")
    t.eq(inbox.convs[1].count, 1)
    r.tm:onFed({ src = "VENUS", data = { op = "deliver", item = { id = "x1", from = "erin", fromRealm = "VENUS", to = "bob", text = "spoof" } }, rq = true, id = util.newId(), port = "tekmail.fed" })
    t.eq(drain(r.n)[1].body.err, "denied", "sender home must match the source realm")
    r.tm:onFed({ src = "EARTH", data = { op = "deliver", item = { id = "x2", from = "erin", fromRealm = "EARTH", to = "nobody", text = "?" } }, rq = true, id = util.newId(), port = "tekmail.fed" })
    t.eq(drain(r.n)[1].body.err, "unknown_user")
    r.tm:onFed({ src = "MARS:9", data = { op = "deliver", item = item }, rq = true, id = util.newId(), port = "tekmail.fed" })
    t.eq(#drain(r.n), 0, "devices cannot use the federation port")
end))

t.case("chat rooms with since cursor, flooding, replication, limits", run(function()
    wipe()
    local dir = newDir()
    local r = mkRealm("MARS", dir)
    local ta = account(r, "MARS:1", "alice")
    local tb = account(r, "MARS:2", "bob")
    t.eq(c(r, "MARS:1", { op = "rooms", token = ta }).rooms[2], "MARS")
    local g0 = c(r, "MARS:2", { op = "chat_get", token = tb, room = "global" })
    t.ok(g0.ok)
    t.eq(#g0.messages, 0)
    drain(r.n)
    local p1 = c(r, "MARS:1", { op = "chat_post", token = ta, room = "global", text = "hello all" })
    t.ok(p1.ok)
    t.eq(p1.seq, 1)
    local b = r.srv.broadcasts[#r.srv.broadcasts]
    t.eq(b.port, "tekmail.fed")
    t.eq(b.body.op, "chat")
    t.eq(b.body.room, "global")
    t.eq(b.body.msg.user, "alice")
    t.eq(b.body.msg.realm, "MARS")
    local notes = drain(r.n)
    t.eq(#notes, 1, "watching client notified")
    t.eq(notes[1].dst, "MARS:2")
    t.eq(notes[1].body.kind, "chat")
    t.eq(notes[1].body.room, "global")
    t.eq(c(r, "MARS:1", { op = "chat_post", token = ta, room = "global", text = "again" }).err, "denied", "rate limited")
    env.advance(1.5)
    t.ok(c(r, "MARS:1", { op = "chat_post", token = ta, room = "mars", text = "local only" }).ok)
    t.eq(#r.srv.broadcasts, 1, "realm room is not flooded")
    r.tm:onFed({ src = "EARTH", data = { op = "chat", room = "global", msg = { id = "e1", user = "erin", realm = "EARTH", text = "hi from earth" } }, id = util.newId() })
    r.tm:onFed({ src = "EARTH", data = { op = "chat", room = "global", msg = { id = "e1", user = "erin", realm = "EARTH", text = "hi from earth" } }, id = util.newId() })
    local g1 = c(r, "MARS:2", { op = "chat_get", token = tb, room = "global", since = 1 })
    t.eq(#g1.messages, 1)
    t.eq(g1.messages[1].user, "erin")
    t.eq(g1.messages[1].realm, "EARTH")
    t.eq(g1.messages[1].seq, 2)
    t.eq(g1.seq, 2)
    t.eq(#c(r, "MARS:2", { op = "chat_get", token = tb, room = "global", since = 2 }).messages, 0)
    t.eq(c(r, "MARS:2", { op = "chat_get", token = tb, room = "EARTH" }).err, "bad_request")
    t.eq(c(r, "MARS:2", { op = "chat_post", token = tb, room = "global", text = string.rep("q", 201) }).err, "too_long")
    for i = 1, 205 do
        r.tm:postChat("MARS", "bob", "MARS", "line " .. i, "id" .. i)
    end
    r.tm:saveRooms()
    local hist = r.tm:chatHistory("MARS", 500)
    t.eq(#hist, 200)
    t.eq(hist[200].text, "line 205")
    local stored = r.ctx.storage:read("chat", "MARS.db")
    t.eq(#stored.msgs, 200)
    local page = c(r, "MARS:2", { op = "chat_get", token = tb, room = "MARS" })
    t.eq(#page.messages, 50)
    t.eq(page.seq, 206)
end))

t.case("admin actions, denial and audit", run(function()
    wipe()
    local dir = newDir()
    local r = mkRealm("MARS", dir)
    t.ok(r.tm:createUser("Root", "rootpw", { admin = true }))
    local tr = c(r, "MARS:1", { op = "login", user = "root", pass = "rootpw" }).token
    local tu = account(r, "MARS:2", "user1")
    account(r, "MARS:3", "user2")
    local denied = c(r, "MARS:2", { op = "admin", token = tu, action = "delete", target = "user2" })
    t.eq(denied.err, "denied")
    local tail = r.ctx.storage:auditTail(1)
    t.eq(tail[1].actor, "user1")
    t.eq(tail[1].ok, false)
    local list = c(r, "MARS:1", { op = "admin", token = tr, action = "list" })
    t.ok(list.ok)
    t.eq(#list.users, 3)
    t.eq(list.users[1].name, "root")
    t.eq(list.users[1].admin, true)
    t.ok(c(r, "MARS:1", { op = "admin", token = tr, action = "reset_pw", target = "user2", value = "newpw" }).ok)
    t.ok(c(r, "MARS:9", { op = "login", user = "user2", pass = "newpw" }).ok)
    t.eq(c(r, "MARS:1", { op = "admin", token = tr, action = "reset_pw", target = "user2", value = "x" }).err, "weak_password")
    t.ok(c(r, "MARS:1", { op = "admin", token = tr, action = "set_admin", target = "user1", value = true }).ok)
    t.eq(c(r, "MARS:2", { op = "whoami", token = tu }).admin, true)
    t.eq(c(r, "MARS:1", { op = "admin", token = tr, action = "delete", target = "root" }).err, "denied", "no self delete")
    t.eq(c(r, "MARS:1", { op = "admin", token = tr, action = "set_admin", target = "root", value = false }).err, "denied")
    c(r, "MARS:2", { op = "send", token = tu, to = "user2", text = "keep me" })
    local ren = c(r, "MARS:1", { op = "admin", token = tr, action = "rename", target = "user2", value = "User3" })
    t.ok(ren.ok, tostring(ren.err))
    t.eq(ren.target, "user3")
    t.eq(dir.users.user3, "MARS")
    t.eq(dir.users.user2, nil)
    t.ok(c(r, "MARS:9", { op = "login", user = "user3", pass = "newpw" }).ok)
    local inbox1 = c(r, "MARS:2", { op = "inbox", token = tu })
    t.eq(inbox1.convs[1].peer, "user3", "peer renamed in other mailboxes")
    local t3 = c(r, "MARS:9", { op = "login", user = "user3", pass = "newpw" }).token
    local th3 = c(r, "MARS:9", { op = "thread", token = t3, peer = "user1" })
    t.eq(th3.messages[1].to, "user3", "own mailbox moved and rewritten")
    t.eq(c(r, "MARS:1", { op = "admin", token = tr, action = "rename", target = "user3", value = "user1" }).err, "taken")
    t.ok(c(r, "MARS:1", { op = "admin", token = tr, action = "delete", target = "user3" }).ok)
    t.eq(dir.users.user3, nil)
    t.eq(c(r, "MARS:9", { op = "whoami", token = t3 }).err, "bad_token")
    t.ok(not r.ctx.storage:exists("mail", "user3/index.db"))
    t.ok(r.ctx.storage:exists("mail", "user1/user3.db"), "other side keeps its history")
    local aud = c(r, "MARS:1", { op = "admin", token = tr, action = "audit", value = 5 })
    t.ok(aud.ok)
    t.eq(#aud.entries, 5)
    t.eq(aud.entries[1].action, "delete")
    t.eq(aud.entries[1].actor, "root")
    dir.users.faraway = "EARTH"
    local far = c(r, "MARS:1", { op = "admin", token = tr, action = "reset_pw", target = "faraway", value = "abcd" })
    t.eq(far.err, "denied", "satellite admins cannot manage other realms")
    t.eq(c(r, "MARS:1", { op = "admin", token = tr, action = "explode" }).err, "bad_request")
end))

t.case("console Lua API", run(function()
    wipe()
    local dir = newDir()
    local r = mkRealm("MARS", dir)
    t.ok(r.tm:createUser("Ann", "pass1", {}))
    t.ok(r.tm:createUser("ben", "pass2", { admin = true }))
    local ok, err = r.tm:createUser("ann", "pass1")
    t.eq(ok, nil)
    t.eq(err, "taken")
    dir.users.zoe = "EARTH"
    local users = r.tm:listUsers()
    t.eq(#users, 3)
    t.eq(users[1].name, "ann")
    t.eq(users[1].display, "Ann")
    t.eq(users[1].realm, "MARS")
    t.eq(users[3].name, "zoe")
    t.eq(users[3].realm, "EARTH")
    t.ok(r.tm:setAdmin("ann", true))
    t.eq(r.tm.accounts.ann.admin, true)
    t.ok(r.tm:resetPassword("ann", "pass9"))
    t.ok(c(r, "MARS:1", { op = "login", user = "ann", pass = "pass9" }).ok)
    t.eq(#r.tm:sessions(), 1)
    t.eq(r.tm:sessions()[1].user, "ann")
    t.ok(r.tm:renameUser("ann", "anna"))
    t.eq(r.tm:sessions()[1].user, "anna")
    t.ok(r.tm:deleteUser("anna"))
    t.eq(r.tm:deleteUser("anna"), nil)
    local tb = c(r, "MARS:2", { op = "login", user = "ben", pass = "pass2" }).token
    c(r, "MARS:2", { op = "chat_post", token = tb, room = "global", text = "hey" })
    local hist = r.tm:chatHistory("global", 10)
    t.eq(#hist, 1)
    t.eq(hist[1].user, "ben")
    local st = r.tm:stats()
    t.eq(st.users, 1)
    t.eq(st.chatMessages, 1)
    t.eq(st.sessions, 1)
    t.eq(st.outbox, 0)
    local acts = {}
    for _, e in ipairs(r.ctx.storage:auditTail(20)) do acts[#acts + 1] = e.action end
    t.ok(util.contains(acts, "create_user"))
    t.ok(util.contains(acts, "reset_pw"))
    t.ok(util.contains(acts, "rename"))
    t.ok(util.contains(acts, "delete"))
    t.ok(util.contains(acts, "set_admin"))
    dir.offline = true
    local cok, cerr = r.tm:createUser("cid", "pass3")
    t.eq(cok, nil)
    t.eq(cerr, "offline")
    t.eq(r.tm.accounts.cid, nil)
end))

t.case("storage offline gives storage errors and keeps data", run(function()
    wipe()
    local dir = newDir()
    local r = mkRealm("MARS", dir)
    local ta = account(r, "MARS:1", "alice")
    account(r, "MARS:2", "bob")
    local st = r.ctx.storage
    st.roles.mail.state = "offline"
    st.roles.mail.drive = "drive_x"
    r.tm.idx = {}
    t.eq(c(r, "MARS:1", { op = "inbox", token = ta }).err, "storage")
    t.eq(c(r, "MARS:1", { op = "send", token = ta, to = "bob", text = "x" }).err, "storage")
    st.roles.mail = st:checkRole("mail")
    t.ok(c(r, "MARS:1", { op = "send", token = ta, to = "bob", text = "x" }).ok)
end))

t.case("sessions persist across a restart", run(function()
    wipe()
    local dir = newDir()
    local r = mkRealm("MARS", dir)
    local ta = account(r, "MARS:1", "alice")
    r.tm:flush()
    local r2 = mkRealm("MARS", dir, { cfg = r.ctx.cfg })
    t.ok(c(r2, "MARS:1", { op = "whoami", token = ta }).ok)
    local r3 = mkRealm("MARS", dir)
    t.eq(c(r3, "MARS:1", { op = "whoami", token = ta }).err, "bad_token", "new data key cannot read old files")
    t.ok(fs.exists("/data_mars/system/sessions.db.bad"), "unreadable file quarantined")
end))

local function linkRealms(realms)
    local inbox = {}
    for name, r in pairs(realms) do
        r.n:setRouter(function(pkt)
            local a = util.parseAddress(pkt.dst)
            if pkt.dst == "*" then return end
            if not a then return end
            if a.id or a.name then
                inbox[pkt.dst] = inbox[pkt.dst] or {}
                table.insert(inbox[pkt.dst], util.deepCopy(pkt))
                return
            end
            local target = realms[a.realm]
            if target and a.realm ~= name then
                target.n.inq.push({ deliver = util.deepCopy(pkt) })
                target.n:wake()
            end
        end)
    end
    return inbox
end

local function call(r, inbox, client, body)
    local id = util.newId()
    r.n.inq.push({ deliver = { v = 1, id = id, src = client, dst = r.realm, port = "tekmail", ttl = 24, rq = true, body = body } })
    r.n:wake()
    for _ = 1, 600 do
        for i, p in ipairs(inbox[client] or {}) do
            if p.re == id then
                table.remove(inbox[client], i)
                return p.body
            end
        end
        sleep(0.1)
    end
    return nil
end

local function notes(inbox, client)
    local out = {}
    for _, p in ipairs(inbox[client] or {}) do
        if type(p.body) == "table" and p.body.op == "notify" then out[#out + 1] = p.body end
    end
    return out
end

t.case("two realms over node loops: proxy login, mail both ways, global chat, admin from main", function()
    wipe()
    local dir = newDir()
    local mars = mkRealm("MARS", dir)
    local earth = mkRealm("EARTH", dir)
    local realms = { MARS = mars, EARTH = earth }
    local inbox = linkRealms(realms)
    dir.onBroadcast = function(from, port, body)
        for name, r in pairs(realms) do
            if name ~= from then
                r.n.inq.push({ deliver = { v = 1, id = util.newId(), src = from, dst = "*", port = port, ttl = 24, body = util.deepCopy(body) } })
                r.n:wake()
            end
        end
    end
    local results = {}
    env.run(function()
        mars.n:loop(function()
            mars.n:spawn(function() earth.n:loop() end, "earth", { critical = true })
            local c1 = call(earth, inbox, "EARTH:5", { op = "create", user = "Erin", pass = "erinpw" })
            results.create = c1
            local c2 = call(mars, inbox, "MARS:8", { op = "create", user = "mike", pass = "mikepw" })
            results.mike = c2
            local li = call(mars, inbox, "MARS:9", { op = "login", user = "erin", pass = "erinpw" })
            results.proxyLogin = li
            results.hadProxy = li and li.token and mars.tm.proxies[li.token] ~= nil
            results.who = call(mars, inbox, "MARS:9", { op = "whoami", token = li.token })
            results.send = call(mars, inbox, "MARS:9", { op = "send", token = li.token, to = "mike", text = "hello mike from erin" })
            sleep(3)
            results.mikeInbox = call(mars, inbox, "MARS:8", { op = "inbox", token = c2.token })
            results.mikeSend = call(mars, inbox, "MARS:8", { op = "send", token = c2.token, to = "erin", text = "hi erin" })
            sleep(3)
            results.erinThread = call(mars, inbox, "MARS:9", { op = "thread", token = li.token, peer = "mike" })
            results.mikeThread = call(mars, inbox, "MARS:8", { op = "thread", token = c2.token, peer = "erin" })
            call(earth, inbox, "EARTH:5", { op = "chat_get", token = c1.token, room = "global" })
            results.post = call(mars, inbox, "MARS:8", { op = "chat_post", token = c2.token, room = "global", text = "global hello" })
            sleep(3)
            results.earthChat = call(earth, inbox, "EARTH:5", { op = "chat_get", token = c1.token, room = "global" })
            results.proxyChat = call(mars, inbox, "MARS:9", { op = "chat_get", token = li.token, room = "global" })
            earth.tm:createUser("boss", "bosspw", { admin = true })
            local boss = call(earth, inbox, "EARTH:6", { op = "login", user = "boss", pass = "bosspw" })
            results.remoteAdmin = call(earth, inbox, "EARTH:6", { op = "admin", token = boss.token, action = "reset_pw", target = "mike", value = "newmike" })
            results.mikeRelogin = call(mars, inbox, "MARS:8", { op = "login", user = "mike", pass = "newmike" })
            results.logout = call(mars, inbox, "MARS:9", { op = "logout", token = li.token })
            results.afterLogout = call(mars, inbox, "MARS:9", { op = "whoami", token = li.token })
            results.foreign = call(mars, inbox, "EARTH:5", { op = "hello" })
        end)
    end, 2000)
    t.ok(results.create.ok)
    t.eq(dir.users.erin, "EARTH")
    t.ok(results.mike.ok)
    t.ok(results.proxyLogin.ok, tostring(results.proxyLogin.err))
    t.eq(results.proxyLogin.home, "EARTH")
    t.ok(results.hadProxy, "authority remembers token home")
    t.eq(results.who.user, "erin")
    t.eq(results.who.home, "EARTH")
    t.ok(results.send.ok)
    t.eq(results.mikeInbox.unread, 1)
    t.eq(results.mikeInbox.convs[1].peer, "erin")
    t.eq(results.mikeInbox.convs[1].display, "Erin")
    t.ok(results.mikeSend.ok)
    t.eq(results.erinThread.messages[2].text, "hi erin")
    t.eq(results.mikeThread.messages[1].text, "hello mike from erin")
    local erinNotes = notes(inbox, "MARS:9")
    t.ok(#erinNotes >= 1 and erinNotes[1].from == "mike", "home server notifies the proxied client")
    t.ok(results.post.ok)
    t.eq(results.earthChat.messages[1].text, "global hello")
    t.eq(results.earthChat.messages[1].realm, "MARS")
    t.eq(results.proxyChat.messages[1].user, "mike")
    local earthNotes = notes(inbox, "EARTH:5")
    t.ok(#earthNotes >= 1 and earthNotes[#earthNotes].kind == "chat", "watchers on other realms notified")
    t.ok(results.remoteAdmin and results.remoteAdmin.ok, "main admin manages a satellite user")
    t.ok(results.mikeRelogin.ok)
    t.ok(results.logout.ok)
    t.eq(results.afterLogout.err, "bad_token")
    t.eq(mars.tm.proxies[results.proxyLogin.token], nil)
    t.eq(results.foreign.err, "denied")
    local marsAudit = mars.ctx.storage:auditTail(5)
    local found = false
    for _, e in ipairs(marsAudit) do
        if e.action == "reset_pw" and e.actor == "boss@EARTH" then found = true end
    end
    t.ok(found, "target realm audits the remote admin action")
end)

t.case("federation guards: admin, proxy, rename and drop", run(function()
    wipe()
    local dir = newDir()
    local r = mkRealm("MARS", dir)
    account(r, "MARS:2", "bob")
    account(r, "MARS:3", "cara")
    c(r, "MARS:2", { op = "send", token = c(r, "MARS:2", { op = "login", user = "bob", pass = "secret" }).token, to = "cara", text = "hi" })
    drain(r.n)
    local function fed(src, body)
        r.tm:onFed({ src = src, data = body, rq = true, id = util.newId(), port = "tekmail.fed" })
        local out = drain(r.n)
        for _, p in ipairs(out) do
            if p.dst == src then return p.body end
        end
        return nil, out
    end
    t.eq(fed("VENUS", { op = "admin", actor = "eve", action = "reset_pw", target = "bob", value = "hack" }).err, "denied", "only main may send admin")
    local ok = fed("EARTH", { op = "admin", actor = "boss", action = "reset_pw", target = "bob", value = "fromearth" })
    t.ok(ok and ok.ok)
    t.ok(c(r, "MARS:4", { op = "login", user = "bob", pass = "fromearth" }).ok)
    t.eq(r.ctx.storage:auditTail(1)[1].actor, "boss@EARTH")
    t.eq(fed("EARTH", { op = "admin", actor = "boss", action = "list" }).err, "bad_request")
    dir.users.zara = "VENUS"
    t.eq(fed("EARTH", { op = "admin", actor = "boss", action = "delete", target = "zara" }).err, "unknown_user", "no second hop")
    local req = { op = "login", user = "bob", pass = "fromearth" }
    t.eq(fed("EARTH", { op = "proxy", req = req, client = "EARTH:5", via = "VENUS" }).err, "denied", "via must match source")
    t.eq(fed("EARTH", { op = "proxy", req = req, client = "VENUS:5", via = "EARTH" }).err, "denied", "client must be in the source realm")
    t.eq(fed("EARTH", { op = "proxy", req = { op = "create", user = "x1x", pass = "abcd" }, client = "EARTH:5", via = "EARTH" }).err, "bad_request")
    local pl = fed("EARTH", { op = "proxy", req = req, client = "EARTH:5", via = "EARTH" })
    t.ok(pl.ok and pl.home == "MARS")
    t.eq(c(r, "EARTH:5", { op = "whoami", token = pl.token }).err, "bad_token", "proxied token only works through its realm")
    local who = fed("EARTH", { op = "proxy", req = { op = "whoami", token = pl.token }, client = "EARTH:5", via = "EARTH" })
    t.eq(who.user, "bob")
    dir.users.dan = "EARTH"
    r.tm:onFed({ src = "EARTH", data = { op = "deliver", item = { id = "d1", from = "dan", fromRealm = "EARTH", to = "cara", text = "yo" } }, rq = true, id = util.newId(), port = "tekmail.fed" })
    drain(r.n)
    dir.users.dan = nil
    dir.users.daniel = "EARTH"
    fed("VENUS", { op = "renamed", old = "dan", new = "daniel" })
    local tc = c(r, "MARS:3", { op = "login", user = "cara", pass = "secret" }).token
    local peers = {}
    for _, cv in ipairs(c(r, "MARS:3", { op = "inbox", token = tc }).convs) do peers[cv.peer] = true end
    t.ok(not peers.daniel, "rename from a realm that does not own the name is ignored")
    fed("EARTH", { op = "renamed", old = "dan", new = "daniel", display = "Daniel" })
    peers = {}
    for _, cv in ipairs(c(r, "MARS:3", { op = "inbox", token = tc }).convs) do peers[cv.peer] = cv end
    t.ok(peers.daniel and not peers.dan, "peer renamed in local mailboxes")
    t.eq(peers.daniel.display, "Daniel")
    local th = c(r, "MARS:3", { op = "thread", token = tc, peer = "daniel" })
    t.eq(th.messages[1].from, "daniel")
    r.tm.proxies.tok1 = { token = "tok1", home = "EARTH", user = "dan", client = "MARS:7", last = 0 }
    r.tm.proxies.tok2 = { token = "tok2", home = "VENUS", user = "zz", client = "MARS:8", last = 0 }
    fed("EARTH", { op = "drop", tokens = { "tok1", "tok2" } })
    t.eq(r.tm.proxies.tok1, nil)
    t.ok(r.tm.proxies.tok2 ~= nil, "a realm can only drop its own tokens")
    t.eq(fed("EARTH", { op = "bogus" }).err, "bad_request")
end))

t.case("create needs main for the name claim and rejects reserved names", run(function()
    wipe()
    local dir = newDir()
    local r = mkRealm("MARS", dir)
    dir.offline = true
    local res = c(r, "MARS:2", { op = "create", user = "nora", pass = "abcd" })
    t.eq(res.err, "offline")
    t.eq(r.tm.accounts.nora, nil)
    dir.offline = false
    t.eq(c(r, "MARS:2", { op = "create", user = "global", pass = "abcd" }).err, "bad_name")
    t.eq(c(r, "MARS:2", { op = "create", user = "Nora", pass = "abc" }).err, "weak_password")
    local ok = c(r, "MARS:2", { op = "create", user = "Nora", pass = "abcd" })
    t.ok(ok.ok)
    t.eq(ok.user, "nora")
    t.eq(ok.display, "Nora")
    t.eq(ok.home, "MARS")
    t.eq(dir.users.nora, "MARS")
    t.eq(r.tm:handleClient("EARTH:2", { op = "create", user = "olga", pass = "abcd" }, "EARTH").err, "bad_request", "create through a proxy is refused")
    drain(r.n)
    r.tm:onClient({ src = "EARTH:2", data = { op = "hello" }, rq = true, id = util.newId(), port = "tekmail" })
    local out = drain(r.n)
    t.eq(out[1].body.err, "denied", "clients of another realm must use their own server")
end))

t.case("review: seen set stays bounded", function()
    local set = util.newSeenSet(300, 10)
    for i = 1, 5000 do set.check("k" .. i) end
    t.ok(util.count(set.map) <= 11, "map size " .. util.count(set.map))
    t.ok(set.check("k5000"), "recent ids are still known")
    t.eq(set.check("k1"), false, "old ids were pruned")
end)

t.case("review: global chat cannot speak for users of other realms", run(function()
    wipe()
    local dir = newDir()
    local r = mkRealm("MARS", dir)
    dir.users.erin = "EARTH"
    dir.users.vic = "VENUS"
    local function chat(src, id, user, realm)
        r.tm:onFed({ src = src, data = { op = "chat", room = "global", msg = { id = id, user = user, realm = realm, text = "x" } }, id = util.newId() })
    end
    chat("VENUS", "s2", "erin", "VENUS")
    chat("VENUS", "s3", "ghost", "EARTH")
    t.eq(#r.tm:chatHistory("global", 10), 0, "spoofed chat lines are dropped")
    chat("EARTH", "ok1", "erin", "EARTH")
    chat("EARTH", "ok2", "vic", "VENUS")
    chat("VENUS", "ok3", "console", "VENUS")
    chat("VENUS", "ok4", "erin", "EARTH")
    local hist = r.tm:chatHistory("global", 10)
    t.eq(#hist, 4, "own users, users relayed by an authority, and the console are accepted")
end))

t.case("review: delivery from a sender unknown to the directory is retried, not stored", run(function()
    wipe()
    local dir = newDir()
    local r = mkRealm("MARS", dir)
    local tb = account(r, "MARS:2", "bob")
    drain(r.n)
    local item = { id = "u1", from = "fake", fromRealm = "EARTH", to = "bob", text = "who am i" }
    r.tm:onFed({ src = "EARTH", data = { op = "deliver", item = item }, rq = true, id = util.newId(), port = "tekmail.fed" })
    local reply = drain(r.n)[1].body
    t.eq(reply.ok, false)
    t.eq(reply.err, "offline", "a retryable error, the outbox tries again later")
    t.eq(#c(r, "MARS:2", { op = "inbox", token = tb }).convs, 0)
    dir.users.fake = "EARTH"
    r.tm:onFed({ src = "EARTH", data = { op = "deliver", item = item }, rq = true, id = util.newId(), port = "tekmail.fed" })
    local ack
    for _, pk in ipairs(drain(r.n)) do if pk.dst == "EARTH" then ack = pk.body end end
    t.ok(ack and ack.ok)
end))

t.case("review: rename keeps the old mailbox when the copy fails", run(function()
    wipe()
    local dir = newDir()
    local r = mkRealm("MARS", dir)
    local ta = account(r, "MARS:1", "alice")
    account(r, "MARS:2", "bob")
    t.ok(c(r, "MARS:1", { op = "send", token = ta, to = "bob", text = "hello" }).ok)
    local real = r.tm.swrite
    r.tm.swrite = function(self, role, rel, value)
        if role == "mail" and rel:sub(1, 6) == "alicia" then return nil, "disk full" end
        return real(self, role, rel, value)
    end
    t.ok(r.tm:renameUser("alice", "alicia"))
    r.tm.swrite = real
    t.ok(r.ctx.storage:exists("mail", "alice/bob.db"), "old copy kept")
end))

t.case("review: stats count conversations without loading every index each time", run(function()
    wipe()
    local dir = newDir()
    local r = mkRealm("MARS", dir)
    local ta = account(r, "MARS:1", "alice")
    account(r, "MARS:2", "bob")
    account(r, "MARS:3", "carl")
    c(r, "MARS:1", { op = "send", token = ta, to = "bob", text = "1" })
    c(r, "MARS:1", { op = "send", token = ta, to = "carl", text = "2" })
    r.tm.idx = {}
    t.eq(r.tm:stats().conversations, 4)
    local reads = 0
    local real = r.tm.sread
    r.tm.sread = function(...)
        reads = reads + 1
        return real(...)
    end
    r.tm.statsCache = nil
    t.eq(r.tm:stats().conversations, 4)
    t.eq(reads, 0, "counts are cached")
    r.tm.sread = real
    env.advance(1.5)
    c(r, "MARS:2", { op = "send", token = c(r, "MARS:2", { op = "login", user = "bob", pass = "secret" }).token, to = "carl", text = "3" })
    r.tm.statsCache = nil
    t.eq(r.tm:stats().conversations, 6, "a new conversation is counted")
end))

t.finish()
