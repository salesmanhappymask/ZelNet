local M = {}

function M.init(env, need)
    M.env = env
    M.need = need
    M.util = need("util")
    M.config = need("config")
    M.node = need("node")
    M.cipher = need("cipher")
    M.server = need("server")
    M.crypto = need("crypto")
    M.ports = {}
    return M
end

function M.reset()
    for side in pairs(M.ports) do M.env.setPeripheral(side, nil) end
    M.ports = {}
end

function M.fakeStorage()
    local data = {}
    local st = { data = data, isReady = true, writes = 0 }
    function st:ready() return self.isReady end
    function st:read(role, rel, default)
        local v = data[role .. "/" .. rel]
        if v == nil then return default end
        return M.util.deepCopy(v)
    end
    function st:write(role, rel, value)
        if not self.isReady then return nil, "storage offline" end
        self.writes = self.writes + 1
        data[role .. "/" .. rel] = M.util.deepCopy(value)
        return true
    end
    function st:audit() end
    return st
end

local function modemDef(port)
    return {
        type = "modem",
        methods = {
            isWireless = function() return true end,
            isOpen = function() return true end,
            open = function() end,
            close = function() end,
            closeAll = function() end,
            transmit = function(ch, rch, f)
                port.tx[#port.tx + 1] = M.util.deepCopy(f)
                if port.cut then return end
                for _, peer in ipairs(port.peers) do
                    local copy = M.util.deepCopy(f)
                    local got, linkId, dist = peer.node.links:decode("modem_message", peer.side, ch, rch, copy, peer.dist or 5)
                    if got then
                        peer.node.inq.push({ f = got, link = linkId, dist = dist })
                        peer.node:wake()
                    end
                end
            end,
        },
    }
end

function M.port(side)
    local p = M.ports[side]
    if not p then
        p = { side = side, peers = {}, tx = {}, cut = false }
        p.def = modemDef(p)
        M.ports[side] = p
    end
    return p
end

function M.connect(nodeA, sideA, nodeB, sideB)
    local pa, pb = M.port(sideA), M.port(sideB)
    pa.peers[#pa.peers + 1] = { node = nodeB, side = sideB }
    pb.peers[#pb.peers + 1] = { node = nodeA, side = sideA }
    return pa, pb
end

function M.attach(n, sides)
    for side, p in pairs(M.ports) do M.env.setPeripheral(side, nil) end
    for _, side in ipairs(sides) do M.env.setPeripheral(side, M.port(side).def) end
    n:start()
    for side, p in pairs(M.ports) do M.env.setPeripheral(side, p.def) end
end

function M.setId(n, id)
    n.myId = id
    n.links.myId = id
    if not n.isServer then n.address = n.realm .. ":" .. id end
end

function M.serverCfg(opts)
    local cfg = M.config.newServer({
        role = opts.role or "main", network = opts.network or "TestNet", realm = opts.realm,
        mainRealm = opts.mainRealm or opts.realm, backboneKey = opts.backboneKey,
    })
    cfg.allowSoftwareBackbone = true
    cfg.airlocks = false
    for k, v in pairs(opts.extra or {}) do cfg[k] = v end
    return cfg
end

function M.newServer(opts)
    local cfg = opts.cfg or M.serverCfg(opts)
    local n = M.node.new(cfg)
    M.setId(n, opts.id)
    M.attach(n, opts.sides or {})
    local ctx = {
        cfg = cfg, log = n.log, node = n, version = M.need("version"),
        cipher = opts.cipher or M.cipher.software(opts.cipherKey or cfg.backboneKey),
        storage = opts.storage,
    }
    ctx.emit = function(event, ...) n:emit(event, ...) end
    local srv = M.server.new(ctx)
    ctx.server = srv
    if opts.bridgeModule then srv.bb.bridgeModule = opts.bridgeModule end
    M.inCo(function() srv:start() end)
    return srv, n, ctx
end

function M.inCo(fn)
    local res
    M.env.run(function() res = { fn() } end, 60)
    return unpack(res)
end

function M.newDevice(srv, role, name, id, sides)
    local dcfg = assert(M.inCo(function() return srv:provision(role, name) end))
    dcfg = M.config.applyDefaults(dcfg)
    local n = M.node.new(dcfg)
    M.setId(n, id)
    M.attach(n, sides or {})
    return n, dcfg
end

function M.runAll(nodes, mainFn, maxSeconds)
    local result
    M.env.run(function()
        local first = nodes[1]
        result = { first:loop(function()
            for i = 2, #nodes do
                local other = nodes[i]
                first:spawn(function() other:loop() end, "node" .. i, { critical = true })
            end
            return mainFn()
        end) }
    end, maxSeconds or 20000)
    if result then return unpack(result) end
end

function M.waitFor(cond, timeout, step)
    local deadline = os.clock() + (timeout or 30)
    while os.clock() < deadline do
        if cond() then return true end
        sleep(step or 0.5)
    end
    return cond() and true or false
end

function M.framesOf(side, kind)
    local out = {}
    for _, f in ipairs(M.port(side).tx) do
        if not kind or f.k == kind then out[#out + 1] = f end
    end
    return out
end

function M.clearTx(side)
    M.port(side).tx = {}
end

return M
