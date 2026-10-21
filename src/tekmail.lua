local need = ...
local compat = need("compat")
local util = need("util")
local crypto = need("crypto")
local codec = need("codec")
local version = need("version")

local M = {}

M.PORT = "tekmail"
M.FED = "tekmail.fed"
M.CONV_MAX = 200
M.CONV_BYTES = 30000
M.ROOM_MAX = 200
M.ROOM_BYTES = 30000
M.FETCH_MAX = 50
M.TEXT_MAX = 1000
M.CHAT_MAX = 200
M.PASS_MIN = 4
M.PASS_MAX = 64
M.TOKEN_IDLE = 21600
M.TOKENS_PER_USER = 4
M.SESSIONS_MAX = 400
M.REPLY_BUDGET = 7000
M.REPLY_MAX = 7800
M.OUTBOX_MAX = 100
M.OUTBOX_BYTES = 40000
M.OUTBOX_TRIES = 400
M.OUTBOX_MAX_WAIT = 259200
M.UNREACHABLE_RECHECK = 30
M.OUTBOX_PARALLEL = 6
M.RETRY_BASE = 10
M.RETRY_MAX = 600
M.PROXY_TIMEOUT = 30
M.DELIVER_TIMEOUT = 40
M.WATCH_TTL = 300
M.LOGIN_FAILS = 5
M.LOGIN_WINDOW = 60
M.CREATE_MAX = 3
M.CREATE_WINDOW = 600
M.CHAT_GAP = 1
M.PREVIEW = 40
M.NOTIFY_PREVIEW = 60
M.INDEX_CACHE = 32
M.STATS_TTL = 30
M.ROOM_SAVE_DELAY = 2
M.RESERVED = { console = true, system = true, server = true, zelnet = true, everyone = true, global = true, nobody = true }

M.MSG = {
    bad_request = "Bad request.",
    bad_token = "Your session has expired. Please log in again.",
    denied = "Access denied.",
    unknown_user = "No such user.",
    taken = "That name is already taken.",
    bad_name = "Names are 3 to 16 characters of a-z, 0-9 and _, starting with a letter.",
    weak_password = "Passwords need at least 4 characters.",
    too_long = "That text is too long.",
    offline = "That realm cannot be reached right now.",
    storage = "Server storage is unavailable.",
}

local PERMANENT = { unknown_user = true, bad_request = true, too_long = true, denied = true, bad_name = true }

local PUBLIC_OPS = { hello = "opHello", create = "opCreate", login = "opLogin" }

local SESSION_OPS = {
    logout = "opLogout", passwd = "opPasswd", whoami = "opWhoami", inbox = "opInbox", thread = "opThread",
    send = "opSend", unread = "opUnread", users = "opUsers", rooms = "opRooms", chat_get = "opChatGet",
    chat_post = "opChatPost", admin = "opAdmin",
}

local AUTHORITY_OPS = { users = true, rooms = true, chat_get = true, chat_post = true }

local FED_OPS = {
    proxy = "fedProxy", deliver = "fedDeliver", chat = "fedChat", admin = "fedAdmin",
    renamed = "fedRenamed", drop = "fedDrop",
}

local MANAGE_ACTIONS = { reset_pw = true, delete = true, rename = true, set_admin = true }

local TekMail = {}
TekMail.__index = TekMail

local USER_PATTERN = "^[a-z][a-z0-9_]*$"

function M.normUser(name)
    if type(name) ~= "string" then return nil end
    local u = util.trim(name):lower()
    if #u < 3 or #u > 16 or not u:match(USER_PATTERN) then return nil end
    return u
end

function M.displayName(raw, user)
    if type(raw) == "string" then
        local d = util.trim(raw)
        if d:lower() == user then return d end
    end
    return user
end

function M.fail(code, msg)
    return { ok = false, err = code, msg = msg or M.MSG[code] or code }
end
local fail = M.fail

function M.cleanText(s, max, oneLine)
    if type(s) ~= "string" then return nil, "bad_request" end
    if #s > max * 4 then return nil, "too_long" end
    s = s:gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("\t", " ")
    s = s:gsub("[%z\1-\9\11-\31\127-\255]", "?")
    if oneLine then s = s:gsub("\n", " ") end
    s = s:gsub("\n\n\n+", "\n\n"):gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then return nil, "bad_request" end
    if #s > max then return nil, "too_long" end
    return s
end

function M.passwordProblem(p)
    if type(p) ~= "string" then return "bad_request" end
    if #p < M.PASS_MIN then return "weak_password" end
    if #p > M.PASS_MAX then return "bad_request" end
    return nil
end

local function preview(s, n)
    return util.fitText((tostring(s or ""):gsub("\n", " ")), n or M.PREVIEW)
end

local function cost(t)
    local n = 4
    for k, v in pairs(t) do
        local kl = type(k) == "string" and #k or 6
        local tv = type(v)
        if tv == "string" then
            local _, esc = v:gsub("[%c\"\\]", "")
            n = n + kl + #v + 3 * esc + 4
        elseif tv == "number" then
            n = n + kl + 20
        else
            n = n + kl + 7
        end
    end
    return n
end

local function serverRealm(src)
    local a = util.parseAddress(src)
    if not a or a.id or a.name or a.realm == "*" then return nil end
    return a.realm
end

local function validId(id)
    return type(id) == "string" and #id >= 1 and #id <= 48 and id:match("^[%w_%-]+$") ~= nil
end

local function truthy(v)
    return v == true or v == 1 or v == "true" or v == "yes" or v == "on"
end

local function convRel(user, peer) return user .. "/" .. peer .. ".db" end
local function indexRel(user) return user .. "/index.db" end

function M.new(ctx)
    local self = setmetatable({}, TekMail)
    self.ctx = ctx
    self.cfg = ctx.cfg
    self.node = ctx.node
    self.log = ctx.log or (ctx.node and ctx.node.log) or util.newLogger(50)
    self.realm = ctx.cfg.realm
    self.mainRealm = util.normRealm(ctx.cfg.mainRealm) or ctx.cfg.realm
    self.accounts = {}
    self.accountsLoaded = false
    self.sess = {}
    self.proxies = {}
    self.sessLoaded = false
    self.outbox = {}
    self.outboxLoaded = false
    self.rooms = {}
    self.roomDirty = {}
    self.roomSavePending = false
    self.idx = {}
    self.convCounts = {}
    self.locks = {}
    self.fails = {}
    self.creates = {}
    self.watch = {}
    self.lastPost = {}
    self.chatSeen = util.newSeenSet(3600, 2000)
    self.inflight = 0
    self.dirty = {}
    self.statsCache = nil
    self.started = false
    return self
end

function TekMail:emit(event, ...)
    if self.ctx.emit then pcall(self.ctx.emit, event, ...) end
end

function TekMail:audit(actor, action, target, detail, ok)
    local st = self.ctx.storage
    if st and type(st.audit) == "function" then pcall(st.audit, st, actor, action, target, detail, ok) end
end

function TekMail:sread(role, rel, default)
    local st = self.ctx.storage
    if not st then return default end
    local ok, v = pcall(st.read, st, role, rel, default)
    if ok then return v end
    self.log.error("tekmail read " .. role .. "/" .. rel .. ": " .. tostring(v))
    return default
end

function TekMail:swrite(role, rel, value)
    local st = self.ctx.storage
    if not st then return true end
    local ok, res, err = pcall(st.write, st, role, rel, value)
    if not ok then return nil, tostring(res) end
    if not res then return nil, err or "write failed" end
    return true
end

function TekMail:sexists(role, rel)
    local st = self.ctx.storage
    if not st or type(st.exists) ~= "function" then return false end
    local ok, v = pcall(st.exists, st, role, rel)
    return ok and v == true
end

function TekMail:sready(role)
    local st = self.ctx.storage
    if not st then return true end
    if type(st.ready) ~= "function" then return true end
    local ok, v = pcall(st.ready, st, role)
    return ok and v == true
end

function TekMail:sdelete(role, rel)
    local st = self.ctx.storage
    if not st or type(st.delete) ~= "function" then return true end
    local ok, v = pcall(st.delete, st, role, rel)
    return ok and v
end

function TekMail:slist(role, rel)
    local st = self.ctx.storage
    if not st or type(st.list) ~= "function" then return {} end
    local ok, v = pcall(st.list, st, role, rel)
    if ok and type(v) == "table" then return v end
    return {}
end

function TekMail:lock(key)
    while self.locks[key] do os.pullEvent("zn_tm_unlock") end
    self.locks[key] = true
end

function TekMail:unlock(key)
    self.locks[key] = nil
    os.queueEvent("zn_tm_unlock")
end

function TekMail:locked(key, fn, ...)
    self:lock(key)
    local res = { pcall(fn, ...) }
    self:unlock(key)
    if not res[1] then error(res[2], 0) end
    return compat.unpack(res, 2, table.maxn(res))
end

function TekMail:job(fn, name)
    local run = function()
        local ok, err = pcall(fn)
        if not ok then self.log.error("tekmail job: " .. tostring(err)) end
    end
    local n = self.node
    if n and n.running then
        n:spawn(run, name or "tekmail-job")
    else
        run()
    end
end

function TekMail:dirHome(user)
    local srv = self.ctx.server
    if not srv or type(srv.userHome) ~= "function" then return nil end
    local ok, r = pcall(srv.userHome, srv, user)
    if ok and type(r) == "string" then return r end
    return nil
end

function TekMail:homeOf(user)
    if self.accounts[user] then return self.realm end
    return self:dirHome(user)
end

function TekMail:dirCall(method, ...)
    local srv = self.ctx.server
    if not srv or type(srv[method]) ~= "function" then return true end
    local ok, res, err = pcall(srv[method], srv, ...)
    if not ok then return nil, "offline", tostring(res) end
    if not res then return nil, err or "offline" end
    return true
end

function TekMail:dirList()
    local srv = self.ctx.server
    if not srv or type(srv.listUsers) ~= "function" then return {} end
    local ok, list = pcall(srv.listUsers, srv)
    if ok and type(list) == "table" then return list end
    return {}
end

function TekMail:reachable(realm)
    if realm == self.realm then return true end
    local srv = self.ctx.server
    if not srv or type(srv.realms) ~= "function" then return true end
    local ok, list = pcall(srv.realms, srv)
    if not ok or type(list) ~= "table" then return true end
    for _, r in ipairs(list) do
        if r.realm == realm then return r.reachable ~= false end
    end
    return false
end

function TekMail:broadcast(body)
    local srv = self.ctx.server
    if srv and type(srv.broadcastRealms) == "function" then
        local ok, err = pcall(srv.broadcastRealms, srv, M.FED, body)
        if not ok then self.log.warn("tekmail broadcast: " .. tostring(err)) end
        return
    end
    if self.node then self.node:send("*", M.FED, body) end
end

function TekMail:send(dst, body)
    if self.node then self.node:send(dst, M.PORT, body) end
end

function TekMail:loadAccounts()
    if self.accountsLoaded then return true end
    if not self:sready("accounts") then return false end
    local t = self:sread("accounts", "users.db", nil)
    if t == nil and self:sexists("accounts", "users.db") then return false end
    local out = {}
    if type(t) == "table" and type(t.users) == "table" then
        for name, a in pairs(t.users) do
            if M.normUser(name) == name and type(a) == "table" and type(a.salt) == "string" and type(a.hash) == "string" then
                a.name = name
                a.display = M.displayName(a.display, name)
                out[name] = a
            end
        end
    end
    for name, a in pairs(self.accounts) do
        if not out[name] then out[name] = a end
    end
    self.accounts = out
    self.accountsLoaded = true
    return true
end

function TekMail:saveAccounts()
    local ok, err = self:swrite("accounts", "users.db", { v = 1, users = self.accounts })
    if ok then self.dirty.accounts = nil end
    return ok, err
end

function TekMail:mutateAccounts(fn)
    if not self:loadAccounts() then return nil, "storage" end
    return self:locked("accounts", function()
        local snapshot = util.deepCopy(self.accounts)
        local changed, value = fn(self.accounts)
        if not changed then return false, value end
        local ok, err = self:saveAccounts()
        if not ok then
            self.accounts = snapshot
            self.log.error("tekmail: cannot save accounts: " .. tostring(err))
            return nil, "storage"
        end
        self.statsCache = nil
        return true, value
    end)
end

function TekMail:checkPass(acct, pass)
    if type(pass) ~= "string" or not acct then return false end
    return crypto.constEq(crypto.passwordHash(acct.salt, pass), acct.hash)
end

function TekMail:newSession(user, client, via)
    local now = compat.now()
    local mine = {}
    for token, s in pairs(self.sess) do
        if s.user == user then mine[#mine + 1] = s end
    end
    table.sort(mine, function(a, b) return a.last < b.last end)
    while #mine >= M.TOKENS_PER_USER do
        self.sess[table.remove(mine, 1).token] = nil
    end
    if util.count(self.sess) >= M.SESSIONS_MAX then
        local oldest
        for _, s in pairs(self.sess) do
            if not oldest or s.last < oldest.last then oldest = s end
        end
        if oldest then self.sess[oldest.token] = nil end
    end
    local s = { token = crypto.randHex(16), user = user, client = client, via = via, home = self.realm, since = compat.stamp(), last = now }
    self.sess[s.token] = s
    self.dirty.sessions = true
    return s
end

function TekMail:dropSessions(user, keep)
    local byVia = {}
    for token, s in compat.spairs(self.sess) do
        if s.user == user and token ~= keep then
            self.sess[token] = nil
            if s.via then
                byVia[s.via] = byVia[s.via] or {}
                table.insert(byVia[s.via], token)
            end
        end
    end
    for via, tokens in pairs(byVia) do
        if self.node then self.node:send(via, M.FED, { op = "drop", tokens = tokens }) end
    end
    self.dirty.sessions = true
end

function TekMail:resolve(client, token, via)
    local now = compat.now()
    local s = self.sess[token]
    if s then
        if s.client ~= client or s.via ~= via then return nil end
        if now - s.last > M.TOKEN_IDLE or not self.accounts[s.user] then
            self.sess[token] = nil
            self.dirty.sessions = true
            return nil
        end
        s.last = now
        return "local", s
    end
    if via then return nil end
    local p = self.proxies[token]
    if p and p.client == client then
        if now - p.last > M.TOKEN_IDLE then
            self.proxies[token] = nil
            self.dirty.sessions = true
            return nil
        end
        p.last = now
        return "proxy", p
    end
    return nil
end

function TekMail:throttled(client)
    local f = self.fails[client]
    if not f then return false end
    if compat.now() - f.t > M.LOGIN_WINDOW then
        self.fails[client] = nil
        return false
    end
    return f.n >= M.LOGIN_FAILS
end

function TekMail:noteFail(client)
    local now = compat.now()
    local f = self.fails[client]
    if not f or now - f.t > M.LOGIN_WINDOW then
        f = { n = 0, t = now }
        self.fails[client] = f
    end
    f.n = f.n + 1
end

function TekMail:handleClient(client, req, via)
    if type(req) ~= "table" or type(req.op) ~= "string" then return fail("bad_request") end
    local pub = PUBLIC_OPS[req.op]
    if pub then return self[pub](self, client, req, via) end
    local name = SESSION_OPS[req.op]
    if not name then return fail("bad_request", "Unknown request " .. util.sanitize(req.op):sub(1, 16) .. ".") end
    if type(req.token) ~= "string" then return fail("bad_token") end
    if not self:loadAccounts() then return fail("storage") end
    local kind, s = self:resolve(client, req.token, via)
    if not kind then return fail("bad_token") end
    if kind == "proxy" and not AUTHORITY_OPS[req.op] then return self:proxyOp(s, client, req) end
    return self[name](self, s, req, kind)
end

function TekMail:proxyRequest(home, client, req)
    if not self.node then return nil, "offline" end
    local body = { op = "proxy", req = req, client = client, via = self.realm }
    local reply, err = self.node:request(home, M.FED, body, M.PROXY_TIMEOUT, { retries = 0 })
    if type(reply) ~= "table" then return nil, err or "offline" end
    return reply
end

function TekMail:proxyOp(p, client, req)
    local reply = self:proxyRequest(p.home, client, req)
    if not reply then return fail("offline", "Your home realm " .. p.home .. " cannot be reached right now.") end
    if reply.err == "bad_token" or req.op == "logout" then
        self.proxies[req.token] = nil
        self.dirty.sessions = true
    end
    return reply
end

function TekMail:opHello(client, req, via)
    return {
        ok = true, realm = self.realm, prog = version.program, rooms = self:roomList(),
        motd = type(self.cfg.motd) == "string" and self.cfg.motd or ("Welcome to TekMail on " .. self.realm .. "."),
    }
end

function TekMail:windowCount(tbl, key, window)
    local now = compat.now()
    local w = tbl[key]
    if not w or now - w.t > window then
        w = { n = 0, t = now }
        tbl[key] = w
    end
    w.n = w.n + 1
    return w.n
end

function TekMail:opCreate(client, req, via)
    if via then return fail("bad_request", "Accounts are created on the server of your own realm.") end
    local c = self.creates[client]
    if c and c.n >= M.CREATE_MAX and compat.now() - c.t <= M.CREATE_WINDOW then
        return fail("denied", "Too many new accounts from this computer. Try again later.")
    end
    local acct, err, msg = self:createAccount(req.user, req.pass, { display = req.user })
    if not acct then return fail(err, msg) end
    self:windowCount(self.creates, client, M.CREATE_WINDOW)
    self:audit(acct.name, "create", acct.name, client, true)
    local s = self:newSession(acct.name, client, nil)
    acct.lastLogin = compat.stamp()
    self.dirty.accounts = true
    return { ok = true, user = acct.name, token = s.token, display = acct.display, admin = acct.admin == true, home = self.realm }
end

function TekMail:createAccount(name, pass, opts)
    opts = opts or {}
    local user = M.normUser(name)
    if not user or M.RESERVED[user] then return nil, "bad_name" end
    local perr = M.passwordProblem(pass)
    if perr then return nil, perr end
    if not self:loadAccounts() then return nil, "storage" end
    if self.accounts[user] then return nil, "taken" end
    local home = self:dirHome(user)
    if home and home ~= self.realm then return nil, "taken" end
    local cok, cerr, cmsg = self:dirCall("claimUser", user)
    if not cok then
        if cerr == "taken" or cerr == "bad_name" then return nil, cerr end
        return nil, "offline", "The main server cannot be reached to register the name" .. (cmsg and (": " .. cmsg) or ".")
    end
    local salt = crypto.randHex(16)
    local acct = {
        name = user, display = M.displayName(opts.display or name, user), salt = salt,
        hash = crypto.passwordHash(salt, pass), admin = opts.admin == true, created = compat.stamp(),
    }
    local res, err = self:mutateAccounts(function(accts)
        if accts[user] then return false, "taken" end
        accts[user] = acct
        return true
    end)
    if res == false then return nil, "taken" end
    if not res then
        self:dirCall("releaseUser", user)
        return nil, err or "storage"
    end
    self.log.info("tekmail account created: " .. user)
    return acct
end

function TekMail:opLogin(client, req, via)
    local user = M.normUser(req.user)
    if not user then return fail("unknown_user") end
    if type(req.pass) ~= "string" then return fail("bad_request") end
    if self:throttled(client) then return fail("denied", "Too many failed logins. Wait a minute and try again.") end
    if not self:loadAccounts() then return fail("storage") end
    local acct = self.accounts[user]
    if not acct then
        if not via then
            local home = self:dirHome(user)
            if home and home ~= self.realm then return self:proxyLogin(home, client, req) end
        end
        self:noteFail(client)
        return fail("unknown_user")
    end
    if not self:checkPass(acct, req.pass) then
        self:noteFail(client)
        return fail("denied", "Wrong user name or password.")
    end
    self.fails[client] = nil
    local s = self:newSession(user, client, via)
    acct.lastLogin = compat.stamp()
    self.dirty.accounts = true
    return { ok = true, token = s.token, user = user, display = acct.display, admin = acct.admin == true, home = self.realm }
end

function TekMail:proxyLogin(home, client, req)
    local reply = self:proxyRequest(home, client, req)
    if not reply then return fail("offline", "The home realm " .. home .. " of that user cannot be reached right now.") end
    if reply.ok and type(reply.token) == "string" then
        local count = 0
        local oldest
        for _, p in pairs(self.proxies) do
            count = count + 1
            if not oldest or p.last < oldest.last then oldest = p end
        end
        if count >= M.SESSIONS_MAX and oldest then self.proxies[oldest.token] = nil end
        self.proxies[reply.token] = {
            token = reply.token, home = home, user = M.normUser(reply.user) or M.normUser(req.user),
            client = client, last = compat.now(), since = compat.stamp(),
        }
        self.dirty.sessions = true
    end
    return reply
end

function TekMail:opLogout(s, req)
    self.sess[s.token] = nil
    self.dirty.sessions = true
    return { ok = true }
end

function TekMail:opWhoami(s)
    local a = self.accounts[s.user]
    return { ok = true, user = s.user, display = a and a.display or s.user, admin = a and a.admin == true, home = self.realm }
end

function TekMail:opPasswd(s, req)
    local a = self.accounts[s.user]
    if not self:checkPass(a, req.old) then return fail("denied", "The old password is wrong.") end
    local perr = M.passwordProblem(req.new)
    if perr then return fail(perr) end
    local res, err = self:setPassword(s.user, req.new)
    if not res then return fail(err or "storage") end
    self:dropSessions(s.user, s.token)
    self:audit(s.user, "passwd", s.user, nil, true)
    return { ok = true }
end

function TekMail:setPassword(user, pass)
    return self:mutateAccounts(function(accts)
        local a = accts[user]
        if not a then return false, "unknown_user" end
        a.salt = crypto.randHex(16)
        a.hash = crypto.passwordHash(a.salt, pass)
        return true
    end)
end

function TekMail:loadIndex(user)
    local idx = self.idx[user]
    if idx then return idx end
    if not self:sready("mail") then return nil end
    local t = self:sread("mail", indexRel(user), nil)
    if t == nil and self:sexists("mail", indexRel(user)) then return nil end
    if type(t) ~= "table" or type(t.peers) ~= "table" then t = { n = 0, peers = {} } end
    t.n = tonumber(t.n) or 0
    if util.count(self.idx) >= M.INDEX_CACHE then self.idx = {} end
    self.idx[user] = t
    return t
end

function TekMail:loadConv(user, peer)
    if not self:sready("mail") then return nil, "storage" end
    local rel = convRel(user, peer)
    local t = self:sread("mail", rel, nil)
    if t == nil then
        if self:sexists("mail", rel) then return nil, "storage" end
        return { seq = 0, msgs = {} }
    end
    if type(t) ~= "table" or type(t.msgs) ~= "table" then return { seq = 0, msgs = {} } end
    t.seq = tonumber(t.seq) or #t.msgs
    return t
end

local function trimList(list, maxN, maxBytes)
    local bytes = 0
    for _, m in ipairs(list) do bytes = bytes + #(m.text or "") + 60 end
    while #list > 0 and (#list > maxN or bytes > maxBytes) do
        local m = table.remove(list, 1)
        bytes = bytes - #(m.text or "") - 60
    end
end

function TekMail:refreshEntry(idx, peer, conv, display)
    local e = idx.peers[peer] or { peer = peer, unread = 0 }
    local last = conv.msgs[#conv.msgs]
    e.count = #conv.msgs
    e.seq = conv.seq
    if last then
        e.lastT = last.t
        e.lastFrom = last.from
        e.lastText = preview(last.text)
    end
    if display then e.display = display end
    idx.peers[peer] = e
    return e
end

function TekMail:appendLocked(owner, peer, m, opts)
    local idx = self:loadIndex(owner)
    if not idx then return nil, "storage" end
    local conv, err = self:loadConv(owner, peer)
    if not conv then return nil, err end
    for i = #conv.msgs, 1, -1 do
        if conv.msgs[i].id == m.id then return conv.msgs[i], "dup" end
    end
    conv.seq = conv.seq + 1
    local rec = {
        id = m.id, seq = conv.seq, from = m.from, to = m.to, text = m.text, t = compat.stamp(),
        read = opts.read == true, pending = opts.pending or nil,
    }
    conv.msgs[#conv.msgs + 1] = rec
    trimList(conv.msgs, M.CONV_MAX, M.CONV_BYTES)
    local ok, werr = self:swrite("mail", convRel(owner, peer), conv)
    if not ok then
        self.log.error("tekmail: cannot store mail for " .. owner .. ": " .. tostring(werr))
        return nil, "storage"
    end
    idx.n = idx.n + 1
    if not idx.peers[peer] then self.convCounts[owner] = nil end
    local e = self:refreshEntry(idx, peer, conv, opts.display)
    e.n = idx.n
    if not rec.read then e.unread = (e.unread or 0) + 1 end
    if not self:swrite("mail", indexRel(owner), idx) then self.idx[owner] = nil end
    self.statsCache = nil
    return rec
end

function TekMail:appendMail(owner, peer, m, opts)
    return self:locked("mail:" .. owner, self.appendLocked, self, owner, peer, m, opts or {})
end

function TekMail:notifyUser(user, body)
    local sent = {}
    for _, s in pairs(self.sess) do
        if s.user == user and not sent[s.client] then
            sent[s.client] = true
            self:send(s.client, body)
        end
    end
end

function TekMail:deliverLocal(item)
    if not self:loadAccounts() then return nil, "storage" end
    if not self.accounts[item.to] then return nil, "unknown_user" end
    local rec, err = self:appendMail(item.to, item.from, item, { read = false, display = item.display })
    if not rec then return nil, err or "storage" end
    if err ~= "dup" then
        self:notifyUser(item.to, { op = "notify", kind = "mail", from = item.from, text = preview(item.text, M.NOTIFY_PREVIEW) })
        self:emit("mail", item.to)
    end
    return true, err
end

function TekMail:outboxBytes()
    local n = 0
    for _, e in ipairs(self.outbox) do n = n + #(e.item.text or "") + 120 end
    return n
end

function TekMail:opSend(s, req)
    local to = M.normUser(req.to)
    if not to then return fail("unknown_user") end
    if to == s.user then return fail("bad_request", "You cannot send a message to yourself.") end
    local text, terr = M.cleanText(req.text, M.TEXT_MAX)
    if not text then return fail(terr) end
    local home = self:homeOf(to)
    if not home then return fail("unknown_user") end
    local remote = home ~= self.realm
    if remote and (#self.outbox >= M.OUTBOX_MAX or self:outboxBytes() + #text > M.OUTBOX_BYTES) then
        return fail("offline", "The outbox is full. Try again later.")
    end
    local acct = self.accounts[s.user]
    local id = validId(req.mid) and #req.mid <= 24 and (s.user .. "-" .. req.mid) or util.newId()
    local item = { id = id, from = s.user, fromRealm = self.realm, to = to, text = text, t = compat.stamp(), display = acct and acct.display or s.user }
    local peerDisplay = self.accounts[to] and self.accounts[to].display or nil
    local delivered = false
    if not remote then delivered = self:deliverLocal(item) == true end
    local rec, err = self:appendMail(s.user, to, item, { read = true, pending = not delivered, display = peerDisplay })
    if not rec then return fail(err or "storage") end
    if err == "dup" then return { ok = true, queued = rec.pending == true, id = id, dup = true } end
    if delivered then return { ok = true, queued = false, id = id } end
    self:enqueue(item, home)
    return { ok = true, queued = not self:reachable(home), id = id }
end

function TekMail:enqueue(item, home)
    local e = { id = item.id, item = item, home = home, tries = 0, created = compat.stamp(), next = 0 }
    self.outbox[#self.outbox + 1] = e
    self:saveOutbox()
    self:pumpOutbox()
    return e
end

function TekMail:outboxSnapshot()
    local list = {}
    for _, e in ipairs(self.outbox) do
        list[#list + 1] = { id = e.id, item = e.item, home = e.home, tries = e.tries, created = e.created, waited = e.waited }
    end
    return { v = 1, items = list }
end

function TekMail:saveOutbox()
    if not self.outboxLoaded then self:loadOutbox() end
    self.dirty.outbox = nil
    local ok, err = self:locked("outbox", function() return self:swrite("system", "outbox.db", self:outboxSnapshot()) end)
    if not ok then
        self.dirty.outbox = true
        self.log.warn("tekmail: cannot save outbox: " .. tostring(err))
    end
    return ok
end

function TekMail:loadOutbox()
    if self.outboxLoaded then return true end
    if not self:sready("system") then return false end
    local t = self:sread("system", "outbox.db", nil)
    if t == nil and self:sexists("system", "outbox.db") then return false end
    local have = {}
    for _, e in ipairs(self.outbox) do have[e.id] = true end
    if type(t) == "table" and type(t.items) == "table" then
        for i, e in ipairs(t.items) do
            if type(e) == "table" and validId(e.id) and type(e.item) == "table" and not have[e.id] and util.normRealm(e.home) then
                self.outbox[#self.outbox + 1] = {
                    id = e.id, item = e.item, home = e.home, tries = tonumber(e.tries) or 0, waited = tonumber(e.waited),
                    created = tonumber(e.created) or compat.stamp(), next = compat.now() + 2 + i,
                }
                have[e.id] = true
            end
        end
    end
    self.outboxLoaded = true
    return true
end

function TekMail:pumpOutbox()
    local now = compat.now()
    local list = {}
    for i, e in ipairs(self.outbox) do list[i] = e end
    for _, e in ipairs(list) do
        if self.inflight >= M.OUTBOX_PARALLEL then return end
        if not e.busy and (e.next or 0) <= now then self:attempt(e) end
    end
end

function TekMail:attempt(e)
    local home = self:homeOf(e.item.to) or e.home
    if home ~= self.realm and not self:reachable(home) then
        local now = compat.now()
        e.waited = (e.waited or 0) + math.max(0, now - (e.checked or now))
        e.checked = now
        e.next = now + M.UNREACHABLE_RECHECK
        if e.waited > M.OUTBOX_MAX_WAIT then self:finishOutbox(e, "failed", "expired") end
        return
    end
    e.checked = nil
    e.busy = true
    if home == self.realm then
        self:job(function()
            local ok, err = self:deliverLocal(e.item)
            e.busy = false
            if ok then
                self:finishOutbox(e, "delivered")
            elseif err == "unknown_user" then
                self:finishOutbox(e, "failed", err)
            else
                self:retryLater(e)
            end
        end, "tekmail-local")
        return
    end
    if not self.node then
        e.busy = false
        return
    end
    e.home = home
    self.inflight = self.inflight + 1
    self.node:requestAsync(home, M.FED, { op = "deliver", item = e.item }, function(body, err)
        self.inflight = math.max(0, self.inflight - 1)
        e.busy = false
        self:onDeliverReply(e, body, err)
    end, M.DELIVER_TIMEOUT)
end

function TekMail:onDeliverReply(e, body, err)
    if type(body) == "table" and body.ok then
        self:finishOutbox(e, "delivered")
    elseif type(body) == "table" and PERMANENT[body.err] then
        self:finishOutbox(e, "failed", body.err)
    else
        self:retryLater(e)
    end
end

function TekMail:retryLater(e)
    e.tries = (e.tries or 0) + 1
    if e.tries >= M.OUTBOX_TRIES then
        self:finishOutbox(e, "failed", "expired")
        return
    end
    local delay = M.RETRY_BASE * (2 ^ math.min(e.tries - 1, 6))
    e.next = compat.now() + math.min(M.RETRY_MAX, delay)
    self.dirty.outbox = true
end

function TekMail:finishOutbox(e, status, err)
    for i, x in ipairs(self.outbox) do
        if x == e then
            table.remove(self.outbox, i)
            break
        end
    end
    self.dirty.outbox = true
    self:job(function()
        self:saveOutbox()
        self:markSent(e.item, status, err)
    end, "tekmail-sent")
end

function TekMail:markSent(item, status, err)
    if not self.accounts[item.from] then return end
    self:locked("mail:" .. item.from, function()
        local conv = self:loadConv(item.from, item.to)
        if not conv then return end
        for i = #conv.msgs, 1, -1 do
            local m = conv.msgs[i]
            if m.id == item.id then
                m.pending = nil
                if status == "failed" then m.failed = err or true end
                self:swrite("mail", convRel(item.from, item.to), conv)
                return
            end
        end
    end)
    if status == "failed" then
        self:notifyUser(item.from, { op = "notify", kind = "mail", from = item.to, failed = true, text = "Not delivered to " .. item.to .. " (" .. tostring(err) .. ")" })
        self:emit("mail", item.from)
    end
end

function TekMail:kickRealm(realm)
    for _, e in ipairs(self.outbox) do
        if e.home == realm then e.next = 0 end
    end
    self:pumpOutbox()
end

local function pickNewest(list, since, before, max)
    local out, used, more = {}, 0, false
    for i = #list, 1, -1 do
        local m = list[i]
        if (m.seq or 0) <= since then break end
        if not before or m.seq < before then
            local c = cost(m)
            if #out >= max or used + c > M.REPLY_BUDGET then
                more = true
                break
            end
            out[#out + 1] = m
            used = used + c
        end
    end
    local rev = {}
    for i = #out, 1, -1 do rev[#rev + 1] = out[i] end
    return rev, more
end

function M.fitReply(reply, key, fromFront)
    local list = reply[key]
    while true do
        local text = codec.encode(reply)
        if not text or #text <= M.REPLY_MAX or #list == 0 then return reply end
        if fromFront then table.remove(list, 1) else table.remove(list) end
        reply.more = true
    end
end

function TekMail:opInbox(s)
    local idx = self:loadIndex(s.user)
    if not idx then return fail("storage") end
    local list, total = {}, 0
    for peer, e in pairs(idx.peers) do
        total = total + (e.unread or 0)
        list[#list + 1] = e
    end
    table.sort(list, function(a, b) return (a.n or 0) > (b.n or 0) end)
    local convs, used = {}, 0
    for _, e in ipairs(list) do
        local row = {
            peer = e.peer, display = e.display or e.peer, unread = e.unread or 0, count = e.count or 0,
            lastT = e.lastT, lastFrom = e.lastFrom, lastText = e.lastText,
        }
        used = used + cost(row)
        if used > M.REPLY_BUDGET then break end
        convs[#convs + 1] = row
    end
    return M.fitReply({ ok = true, convs = convs, unread = total, more = #convs < #list or nil }, "convs", false)
end

function TekMail:opUnread(s)
    local idx = self:loadIndex(s.user)
    if not idx then return fail("storage") end
    local total = 0
    for _, e in pairs(idx.peers) do total = total + (e.unread or 0) end
    return { ok = true, count = total }
end

function TekMail:userExists(user)
    return self.accounts[user] ~= nil or self:dirHome(user) ~= nil
end

function TekMail:threadLocked(user, peer, since, before)
    local conv, err = self:loadConv(user, peer)
    if not conv then return fail(err or "storage") end
    if #conv.msgs == 0 and not self:userExists(peer) then return fail("unknown_user") end
    local picked, more = pickNewest(conv.msgs, since, before, M.FETCH_MAX)
    local out = {}
    for _, m in ipairs(picked) do
        out[#out + 1] = { id = m.id, seq = m.seq, from = m.from, to = m.to, text = m.text, t = m.t, read = m.read == true, pending = m.pending, failed = m.failed }
    end
    local changed = false
    for _, m in ipairs(conv.msgs) do
        if m.to == user and not m.read then
            m.read = true
            changed = true
        end
    end
    if changed then self:swrite("mail", convRel(user, peer), conv) end
    local idx = self:loadIndex(user)
    if idx and (changed or (idx.peers[peer] and (idx.peers[peer].unread or 0) > 0)) then
        local e = self:refreshEntry(idx, peer, conv)
        e.unread = 0
        e.n = e.n or idx.n
        self:swrite("mail", indexRel(user), idx)
    end
    return M.fitReply({ ok = true, messages = out, seq = conv.seq, peer = peer, more = more or nil }, "messages", true)
end

function TekMail:opThread(s, req)
    local peer = M.normUser(req.peer)
    if not peer then return fail("unknown_user") end
    local since = math.max(0, math.floor(tonumber(req.since) or 0))
    local before = tonumber(req.before)
    return self:locked("mail:" .. s.user, self.threadLocked, self, s.user, peer, since, before)
end

function TekMail:opUsers(s)
    local list = self:listUsers()
    local out, used = {}, 0
    for _, u in ipairs(list) do
        local row = { name = u.name, display = u.display, realm = u.realm }
        used = used + cost(row)
        if used > M.REPLY_BUDGET then break end
        out[#out + 1] = row
    end
    return M.fitReply({ ok = true, users = out, more = #out < #list or nil }, "users", false)
end

function TekMail:roomList()
    return { "global", self.realm }
end

function TekMail:roomName(name)
    if type(name) ~= "string" then return nil end
    local n = util.trim(name)
    if n:lower() == "global" then return "global" end
    if util.normRealm(n) == self.realm then return self.realm end
    return nil
end

function TekMail:opRooms()
    return { ok = true, rooms = self:roomList() }
end

function TekMail:room(name)
    local r = self.rooms[name]
    if r then return r end
    if not self:sready("chat") then return nil end
    local rel = name .. ".db"
    local t = self:sread("chat", rel, nil)
    if t == nil and self:sexists("chat", rel) then return nil end
    if type(t) ~= "table" or type(t.msgs) ~= "table" then t = { seq = 0, msgs = {} } end
    t.seq = tonumber(t.seq) or 0
    self.rooms[name] = t
    return t
end

function TekMail:scheduleRoomSave()
    local n = self.node
    if n and n.running then
        if self.roomSavePending then return end
        self.roomSavePending = true
        n:after(M.ROOM_SAVE_DELAY, function()
            self.roomSavePending = false
            self:job(function() self:saveRooms() end, "tekmail-chat")
        end, "tekmail-chat-save")
    else
        self:saveRooms()
    end
end

function TekMail:saveRooms()
    for name in compat.spairs(self.roomDirty) do
        local r = self.rooms[name]
        self.roomDirty[name] = nil
        if r then
            local ok = self:locked("chat:" .. name, function() return self:swrite("chat", name .. ".db", r) end)
            if not ok then self.roomDirty[name] = true end
        end
    end
end

function TekMail:postChat(roomName, user, realm, text, id, exceptClient)
    local r = self:room(roomName)
    if not r then return nil end
    for i = #r.msgs, math.max(1, #r.msgs - 50), -1 do
        if r.msgs[i].id == id then return r.msgs[i], "dup" end
    end
    r.seq = r.seq + 1
    local m = { seq = r.seq, id = id, user = user, realm = realm, text = text, t = compat.stamp() }
    r.msgs[#r.msgs + 1] = m
    trimList(r.msgs, M.ROOM_MAX, M.ROOM_BYTES)
    self.roomDirty[roomName] = true
    self.statsCache = nil
    self:scheduleRoomSave()
    self:notifyWatchers(roomName, m, exceptClient)
    self:emit("chat", roomName)
    return m
end

function TekMail:notifyWatchers(roomName, m, exceptClient)
    local now = compat.now()
    local body = { op = "notify", kind = "chat", room = roomName, from = m.user, text = preview(m.text, M.NOTIFY_PREVIEW), seq = m.seq }
    for client, w in compat.spairs(self.watch) do
        if now - w.t > M.WATCH_TTL then
            self.watch[client] = nil
        elseif w.room == roomName and client ~= exceptClient then
            self:send(client, body)
        end
    end
end

function TekMail:opChatGet(s, req)
    local name = self:roomName(req.room)
    if not name then return fail("bad_request", "Unknown chat room.") end
    local r = self:room(name)
    if not r then return fail("storage") end
    self.watch[s.client] = { room = name, t = compat.now() }
    local since = math.max(0, math.floor(tonumber(req.since) or 0))
    local picked, more = pickNewest(r.msgs, since, tonumber(req.before), M.FETCH_MAX)
    local out = {}
    for _, m in ipairs(picked) do
        out[#out + 1] = { seq = m.seq, user = m.user, realm = m.realm, text = m.text, t = m.t }
    end
    return M.fitReply({ ok = true, room = name, messages = out, seq = r.seq, more = more or nil }, "messages", true)
end

function TekMail:opChatPost(s, req)
    local name = self:roomName(req.room)
    if not name then return fail("bad_request", "Unknown chat room.") end
    local text, terr = M.cleanText(req.text, M.CHAT_MAX, true)
    if not text then return fail(terr) end
    local now = compat.now()
    local last = self.lastPost[s.user]
    if last and now - last < M.CHAT_GAP then return fail("denied", "You are posting too fast.") end
    self.lastPost[s.user] = now
    local id = util.newId()
    local home = s.home or self.realm
    local m = self:postChat(name, s.user, home, text, id, s.client)
    if not m then return fail("storage") end
    if name == "global" then
        self.chatSeen.check(id)
        self:broadcast({ op = "chat", room = "global", msg = { id = id, user = s.user, realm = home, text = text } })
    end
    self.watch[s.client] = { room = name, t = now }
    return { ok = true, seq = m.seq }
end

function TekMail:opAdmin(s, req)
    local a = self.accounts[s.user]
    local action = type(req.action) == "string" and req.action or "?"
    if not a or not a.admin then
        self:audit(s.user, "admin_" .. util.sanitize(action):sub(1, 16), type(req.target) == "string" and req.target or nil, "denied", false)
        return fail("denied", "Admin rights are required.")
    end
    if action == "list" then
        local list = self:listUsers()
        local out, used = {}, 0
        for _, u in ipairs(list) do
            local row = { name = u.name, display = u.display, realm = u.realm, admin = u.admin, lastLogin = u.lastLogin }
            used = used + cost(row)
            if used > M.REPLY_BUDGET then break end
            out[#out + 1] = row
        end
        return M.fitReply({ ok = true, users = out, more = #out < #list or nil }, "users", false)
    end
    if action == "audit" then
        local st = self.ctx.storage
        local n = math.min(60, math.max(1, math.floor(tonumber(req.value) or 30)))
        local entries = (st and type(st.auditTail) == "function") and st:auditTail(n) or {}
        return M.fitReply({ ok = true, entries = entries }, "entries", false)
    end
    if not MANAGE_ACTIONS[action] then return fail("bad_request", "Unknown admin action.") end
    local target = M.normUser(req.target)
    if target == s.user and (action == "delete" or (action == "set_admin" and not truthy(req.value))) then
        return fail("denied", "You cannot do that to your own account.")
    end
    return self:manage(action, req.target, req.value, s.user)
end

function TekMail:manage(action, target, value, actor, noForward)
    local user = M.normUser(target)
    if not user then return fail("unknown_user") end
    if not self:loadAccounts() then return fail("storage") end
    if not self.accounts[user] then
        local home = self:dirHome(user)
        if noForward or not home or home == self.realm then return fail("unknown_user") end
        if self.realm ~= self.mainRealm then
            self:audit(actor, action, user, "denied, home " .. home, false)
            return fail("denied", "Only admins of the main realm can manage users of " .. home .. ".")
        end
        return self:forwardAdmin(home, action, user, value, actor)
    end
    local ok, err, extra = self:applyLocal(action, user, value)
    local detail
    if action == "rename" then detail = "to " .. tostring(extra or value) end
    if action == "set_admin" then detail = tostring(truthy(value)) end
    if not ok then detail = (detail and (detail .. ", ") or "") .. tostring(err) end
    self:audit(actor, action, user, detail, ok and true or false)
    if not ok then return fail(err) end
    return { ok = true, action = action, target = extra or user }
end

function TekMail:forwardAdmin(home, action, user, value, actor)
    if not self.node then return fail("offline") end
    local body = { op = "admin", actor = actor, action = action, target = user, value = value }
    local reply, err = self.node:request(home, M.FED, body, M.PROXY_TIMEOUT, { retries = 0 })
    if type(reply) ~= "table" then
        self:audit(actor, action, user, "via " .. home .. ", " .. tostring(err), false)
        return fail("offline", "The realm " .. home .. " cannot be reached right now.")
    end
    self:audit(actor, action, user, "via " .. home, reply.ok == true)
    return reply
end

function TekMail:applyLocal(action, user, value)
    if action == "reset_pw" then
        local perr = M.passwordProblem(value)
        if perr then return nil, perr end
        local ok, err = self:setPassword(user, value)
        if not ok then return nil, err or "storage" end
        self:dropSessions(user)
        return true
    elseif action == "set_admin" then
        local flag = truthy(value)
        local ok, err = self:mutateAccounts(function(accts)
            if not accts[user] then return false, "unknown_user" end
            accts[user].admin = flag
            return true
        end)
        if ok == nil then return nil, err end
        return true
    elseif action == "delete" then
        return self:doDelete(user)
    elseif action == "rename" then
        return self:doRename(user, value)
    end
    return nil, "bad_request"
end

function TekMail:doDelete(user)
    local ok, err = self:dirCall("releaseUser", user)
    if not ok and err ~= "unknown_user" then return nil, err == "denied" and "denied" or "offline" end
    local res, merr = self:mutateAccounts(function(accts)
        if not accts[user] then return false end
        accts[user] = nil
        return true
    end)
    if res == nil then return nil, merr end
    self:locked("mail:" .. user, function() self:sdelete("mail", user) end)
    self.idx[user] = nil
    self.convCounts[user] = nil
    self:dropSessions(user)
    self.log.info("tekmail account deleted: " .. user)
    return true
end

local function renameIn(conv, old, new)
    for _, m in ipairs(conv.msgs or {}) do
        if m.from == old then m.from = new end
        if m.to == old then m.to = new end
    end
end

function TekMail:doRename(old, raw)
    local new = M.normUser(raw)
    if not new or M.RESERVED[new] then return nil, "bad_name" end
    local display = M.displayName(raw, new)
    if new == old then
        local ok, err = self:mutateAccounts(function(accts)
            accts[old].display = display
            return true
        end)
        if ok == nil then return nil, err end
        return true, nil, new
    end
    if self.accounts[new] or self:dirHome(new) then return nil, "taken" end
    local ok, err = self:dirCall("renameUser", old, new)
    if not ok then return nil, (err == "taken" or err == "bad_name" or err == "denied") and err or "offline" end
    local res, merr = self:mutateAccounts(function(accts)
        local a = accts[old]
        if not a or accts[new] then return false end
        accts[old] = nil
        a.name = new
        a.display = display
        accts[new] = a
        return true
    end)
    if not res then
        self:dirCall("renameUser", new, old)
        return nil, merr or "taken"
    end
    self:moveMailbox(old, new)
    for _, s in pairs(self.sess) do
        if s.user == old then s.user = new end
    end
    self.dirty.sessions = true
    for _, e in ipairs(self.outbox) do
        if e.item.from == old then e.item.from = new end
    end
    self:renamePeer(old, new, display)
    self:broadcast({ op = "renamed", old = old, new = new, display = display })
    self.log.info("tekmail account renamed: " .. old .. " to " .. new)
    return true, nil, new
end

function TekMail:moveMailbox(old, new)
    local first, second = old, new
    if second < first then first, second = second, first end
    self:locked("mail:" .. first, function()
        self:locked("mail:" .. second, function()
            local copied = true
            for _, name in ipairs(self:slist("mail", old)) do
                if name:sub(-3) == ".db" then
                    local v = self:sread("mail", old .. "/" .. name, nil)
                    if type(v) == "table" then
                        if name ~= "index.db" then renameIn(v, old, new) end
                        if name == "index.db" and type(v.peers) == "table" then
                            for _, e in pairs(v.peers) do
                                if e.lastFrom == old then e.lastFrom = new end
                            end
                        end
                        if not self:swrite("mail", new .. "/" .. name, v) then copied = false end
                    elseif self:sexists("mail", old .. "/" .. name) then
                        copied = false
                    end
                end
            end
            if copied then
                self:sdelete("mail", old)
            else
                self.log.error("tekmail: mailbox of " .. old .. " could not be fully moved to " .. new .. "; the old copy is kept")
            end
            self.idx[old] = nil
            self.idx[new] = nil
            self.convCounts[old] = nil
            self.convCounts[new] = nil
        end)
    end)
end

function TekMail:renamePeer(old, new, display)
    for i, user in ipairs(util.sortedKeys(self.accounts)) do
        if i % 8 == 0 then compat.yieldNow() end
        if user ~= new then
            local probe = self:loadIndex(user)
            if probe and probe.peers[old] then
                self:locked("mail:" .. user, function()
                    local idx = self:loadIndex(user)
                    if not idx or not idx.peers[old] then return end
                    self.convCounts[user] = nil
                    local conv = self:sread("mail", convRel(user, old), nil)
                    if type(conv) == "table" then
                        renameIn(conv, old, new)
                        if self:swrite("mail", convRel(user, new), conv) then self:sdelete("mail", convRel(user, old)) end
                    end
                    local e = idx.peers[old]
                    idx.peers[old] = nil
                    e.peer = new
                    e.display = display or new
                    if e.lastFrom == old then e.lastFrom = new end
                    idx.peers[new] = e
                    self:swrite("mail", indexRel(user), idx)
                end)
            end
        end
    end
    for _, e in ipairs(self.outbox) do
        if e.item.to == old then e.item.to = new end
    end
    for _, p in pairs(self.proxies) do
        if p.user == old then
            p.user = new
            self.dirty.sessions = true
        end
    end
end

function TekMail:onClient(msg)
    local b = msg.data
    if type(b) == "table" and b.op == "notify" then return end
    local a = util.parseAddress(msg.src)
    local reply
    if not a or a.realm ~= self.realm or (not a.id and not a.name) then
        reply = fail("denied", "Use the TekMail server of your own realm.")
    else
        local ok, res = pcall(self.handleClient, self, msg.src, b, nil)
        if ok then
            reply = res
        else
            self.log.error("tekmail: " .. tostring(res))
            reply = fail("storage", "Internal server error.")
        end
    end
    if msg.rq and self.node then self.node:reply(msg, reply) end
end

function TekMail:onFed(msg)
    local srcRealm = serverRealm(msg.src)
    if not srcRealm or srcRealm == self.realm then return end
    local b = msg.data
    local fn = type(b) == "table" and FED_OPS[b.op]
    local reply
    if not fn then
        reply = fail("bad_request")
    else
        local ok, res = pcall(self[fn], self, srcRealm, b, msg)
        if ok then
            reply = res
        else
            self.log.error("tekmail fed " .. tostring(b.op) .. ": " .. tostring(res))
            reply = fail("storage", "Internal server error.")
        end
    end
    if msg.rq and reply ~= nil and self.node then self.node:reply(msg, reply) end
end

function TekMail:fedProxy(srcRealm, b)
    if b.via ~= srcRealm then return fail("denied") end
    local a = util.parseAddress(b.client)
    if not a or a.realm ~= srcRealm or (not a.id and not a.name) then return fail("denied") end
    if type(b.req) ~= "table" or b.req.op == "create" then return fail("bad_request") end
    return self:handleClient(util.normAddress(b.client), b.req, srcRealm)
end

function M.cleanItem(item)
    if type(item) ~= "table" or not validId(item.id) then return nil end
    local from, to = M.normUser(item.from), M.normUser(item.to)
    local realm = util.normRealm(item.fromRealm)
    local text = M.cleanText(item.text, M.TEXT_MAX)
    if not from or not to or not realm or not text then return nil end
    local display = type(item.display) == "string" and M.displayName(item.display, from) or from
    return { id = item.id, from = from, to = to, fromRealm = realm, text = text, t = tonumber(item.t), display = display }
end

function TekMail:fedDeliver(srcRealm, b)
    local item = M.cleanItem(b.item)
    if not item then return fail("bad_request") end
    if item.fromRealm ~= srcRealm then return fail("denied") end
    local claimed = self:dirHome(item.from)
    if claimed and claimed ~= srcRealm then return fail("denied") end
    if not claimed then return fail("offline", "The sender is not in the directory of " .. self.realm .. " yet.") end
    local ok, err = self:deliverLocal(item)
    if not ok then return fail(err == "unknown_user" and err or "storage") end
    return { ok = true, dup = err == "dup" or nil }
end

function TekMail:fedChat(srcRealm, b)
    if b.room ~= "global" or type(b.msg) ~= "table" then return nil end
    local m = b.msg
    if not validId(m.id) then return nil end
    local user, realm = M.normUser(m.user), util.normRealm(m.realm)
    local text = M.cleanText(m.text, M.CHAT_MAX, true)
    if not user or not realm or not text then return nil end
    local home = self:dirHome(user)
    if home and home ~= realm then return nil end
    if realm ~= srcRealm and home ~= realm then return nil end
    if self.chatSeen.check(m.id) then return nil end
    self:postChat("global", user, realm, text, m.id)
    return nil
end

function TekMail:fedAdmin(srcRealm, b)
    if srcRealm ~= self.mainRealm then return fail("denied") end
    if not MANAGE_ACTIONS[b.action] then return fail("bad_request") end
    local actor = util.sanitize(tostring(b.actor or "admin")):sub(1, 16) .. "@" .. srcRealm
    return self:manage(b.action, b.target, b.value, actor, true)
end

function TekMail:fedRenamed(srcRealm, b)
    local old, new = M.normUser(b.old), M.normUser(b.new)
    if not old or not new or self.accounts[old] or self.accounts[new] then return nil end
    local h1, h2 = self:dirHome(old), self:dirHome(new)
    if h1 ~= srcRealm and h2 ~= srcRealm then return nil end
    self:renamePeer(old, new, type(b.display) == "string" and M.displayName(b.display, new) or new)
    return nil
end

function TekMail:fedDrop(srcRealm, b)
    if type(b.tokens) ~= "table" then return nil end
    for _, token in ipairs(b.tokens) do
        local p = type(token) == "string" and self.proxies[token]
        if p and p.home == srcRealm then
            self.proxies[token] = nil
            self.dirty.sessions = true
        end
    end
    return nil
end

function TekMail:loadSessions()
    if self.sessLoaded then return true end
    if not self:sready("system") then return false end
    local t = self:sread("system", "sessions.db", nil)
    self.sessLoaded = true
    if type(t) ~= "table" then return true end
    local now = compat.now()
    for _, s in ipairs(type(t.s) == "table" and t.s or {}) do
        if type(s) == "table" and type(s.token) == "string" and M.normUser(s.user) and type(s.client) == "string" and not self.sess[s.token] then
            local idle = tonumber(s.idle) or 0
            if idle < M.TOKEN_IDLE then
                self.sess[s.token] = { token = s.token, user = s.user, client = s.client, via = util.normRealm(s.via), home = self.realm, since = tonumber(s.since), last = now - idle }
            end
        end
    end
    for _, p in ipairs(type(t.p) == "table" and t.p or {}) do
        if type(p) == "table" and type(p.token) == "string" and util.normRealm(p.home) and type(p.client) == "string" and not self.proxies[p.token] then
            local idle = tonumber(p.idle) or 0
            if idle < M.TOKEN_IDLE then
                self.proxies[p.token] = { token = p.token, home = p.home, user = M.normUser(p.user), client = p.client, since = tonumber(p.since), last = now - idle }
            end
        end
    end
    return true
end

function TekMail:saveSessions()
    if not self.sessLoaded then self:loadSessions() end
    self.dirty.sessions = nil
    local now = compat.now()
    local out = { v = 1, s = {}, p = {} }
    for _, s in pairs(self.sess) do
        out.s[#out.s + 1] = { token = s.token, user = s.user, client = s.client, via = s.via, since = s.since, idle = now - s.last }
    end
    for _, p in pairs(self.proxies) do
        out.p[#out.p + 1] = { token = p.token, home = p.home, user = p.user, client = p.client, since = p.since, idle = now - p.last }
    end
    local ok = self:locked("sessions", function() return self:swrite("system", "sessions.db", out) end)
    if not ok then self.dirty.sessions = true end
    return ok
end

function TekMail:housekeeping()
    local now = compat.now()
    for token, s in compat.spairs(self.sess) do
        if now - s.last > M.TOKEN_IDLE then
            self.sess[token] = nil
            self.dirty.sessions = true
        end
    end
    for token, p in compat.spairs(self.proxies) do
        if now - p.last > M.TOKEN_IDLE then
            self.proxies[token] = nil
            self.dirty.sessions = true
        end
    end
    for client, w in compat.spairs(self.watch) do
        if now - w.t > M.WATCH_TTL then self.watch[client] = nil end
    end
    for client, f in compat.spairs(self.fails) do
        if now - f.t > M.LOGIN_WINDOW then self.fails[client] = nil end
    end
    for client, c in compat.spairs(self.creates) do
        if now - c.t > M.CREATE_WINDOW then self.creates[client] = nil end
    end
    for user, t in compat.spairs(self.lastPost) do
        if now - t > 60 then self.lastPost[user] = nil end
    end
    local d = self.dirty
    local needLoad = not self.accountsLoaded or not self.outboxLoaded or not self.sessLoaded
    if needLoad or d.accounts or d.outbox or d.sessions or next(self.roomDirty) then
        self:job(function() self:flush() end, "tekmail-flush")
    end
end

function TekMail:flush()
    self:loadAccounts()
    self:loadOutbox()
    self:loadSessions()
    if self.dirty.accounts and self.accountsLoaded then self:locked("accounts", function() self:saveAccounts() end) end
    if self.dirty.outbox and self.outboxLoaded then self:saveOutbox() end
    if self.dirty.sessions and self.sessLoaded then self:saveSessions() end
    if next(self.roomDirty) then self:saveRooms() end
end

function TekMail:start()
    if self.started then return true end
    self.started = true
    self:loadAccounts()
    self:loadSessions()
    self:loadOutbox()
    local n = self.node
    if n then
        n:listen(M.PORT, function(msg) self:onClient(msg) end)
        n:listen(M.FED, function(msg) self:onFed(msg) end)
        n:every(5, function() self:pumpOutbox() end, "tekmail-outbox")
        n:every(30, function() self:housekeeping() end, "tekmail-house")
        n:on("realm_up", function(r) self:kickRealm(r) end)
        n:on("storage_online", function() self.idx = {} end)
        n:on("storage_offline", function() self.idx = {} end)
    end
    self.log.info("tekmail ready: " .. util.count(self.accounts) .. " accounts, " .. #self.outbox .. " queued")
    return true
end

function TekMail:listUsers()
    self:loadAccounts()
    local out, seen = {}, {}
    for name, a in pairs(self.accounts) do
        seen[name] = true
        out[#out + 1] = {
            name = name, display = a.display or name, realm = self.realm, admin = a.admin == true,
            created = a.created, lastLogin = a.lastLogin, ["local"] = true,
        }
    end
    for _, u in ipairs(self:dirList()) do
        if type(u) == "table" and type(u.name) == "string" and not seen[u.name] then
            seen[u.name] = true
            out[#out + 1] = { name = u.name, display = u.name, realm = u.realm }
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

function TekMail:createUser(name, password, opts)
    opts = opts or {}
    local acct, err = self:createAccount(name, password, { admin = opts.admin, display = opts.display or name })
    self:audit(opts.actor or "console", "create_user", M.normUser(name) or tostring(name), opts.admin and "admin" or err, acct ~= nil)
    if not acct then return nil, err end
    return true
end

local function result(r)
    if r.ok then return true end
    return nil, r.err, r.msg
end

function TekMail:resetPassword(name, password, actor)
    return result(self:manage("reset_pw", name, password, actor or "console"))
end

function TekMail:renameUser(old, new, actor)
    return result(self:manage("rename", old, new, actor or "console"))
end

function TekMail:deleteUser(name, actor)
    return result(self:manage("delete", name, nil, actor or "console"))
end

function TekMail:setAdmin(name, flag, actor)
    return result(self:manage("set_admin", name, flag and true or false, actor or "console"))
end

function TekMail:chatHistory(room, n)
    local name = self:roomName(room or "global")
    if not name then return {} end
    local r = self:room(name)
    if not r then return {} end
    n = math.max(1, math.floor(tonumber(n) or 50))
    local out = {}
    for i = math.max(1, #r.msgs - n + 1), #r.msgs do out[#out + 1] = util.copy(r.msgs[i]) end
    return out
end

function TekMail:sessions()
    local now = compat.now()
    local out = {}
    for _, s in pairs(self.sess) do
        out[#out + 1] = { user = s.user, client = s.client, since = s.since, lastSeen = s.last, idle = now - s.last, via = s.via, home = self.realm, kind = "local" }
    end
    for _, p in pairs(self.proxies) do
        out[#out + 1] = { user = p.user, client = p.client, since = p.since, lastSeen = p.last, idle = now - p.last, home = p.home, kind = "proxy" }
    end
    table.sort(out, function(a, b) return a.idle < b.idle end)
    return out
end

function TekMail:conversationCount()
    local n, reads = 0, 0
    for _, user in ipairs(util.sortedKeys(self.accounts)) do
        local c = self.convCounts[user]
        if not c then
            local idx = self.idx[user]
            if not idx then
                reads = reads + 1
                if reads % 8 == 0 then compat.yieldNow() end
                local t = self:sread("mail", indexRel(user), nil)
                idx = type(t) == "table" and type(t.peers) == "table" and t or nil
            end
            if idx then
                c = util.count(idx.peers)
                self.convCounts[user] = c
            end
        end
        n = n + (c or 0)
    end
    for user in compat.spairs(self.convCounts) do
        if not self.accounts[user] then self.convCounts[user] = nil end
    end
    return n
end

function TekMail:stats()
    local now = compat.now()
    local c = self.statsCache
    if c and now - c.t < M.STATS_TTL then
        c.outbox = #self.outbox
        c.sessions = util.count(self.sess) + util.count(self.proxies)
        return util.copy(c)
    end
    local chat = 0
    for _, name in ipairs(self:roomList()) do
        local r = self:room(name)
        if r then chat = chat + #r.msgs end
    end
    c = {
        t = now, users = util.count(self.accounts), conversations = self:conversationCount(), chatMessages = chat,
        outbox = #self.outbox, sessions = util.count(self.sess) + util.count(self.proxies),
    }
    self.statsCache = c
    return util.copy(c)
end

M.TekMail = TekMail

return M
