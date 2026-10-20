local need = ...
local util = need("util")
local codec = need("codec")
local crypto = need("crypto")
local version = need("version")

local M = {}

M.DIR = "/.zelnet"
M.PATH = "/.zelnet/config"
M.ROLES = { main = true, satellite = true, router = true, client = true, endpoint = true }
M.SERVER_ROLES = { main = true, satellite = true }

M.DEFAULTS = {
    channel = 4747,
    useWired = true,
    useBitnet = true,
    beaconInterval = 10,
    helloInterval = 20,
    routeInterval = 30,
    keepalive = 120,
    allowSoftwareBackbone = false,
    airlocks = true,
    monitorScale = 0.5,
}

function M.netIdFor(networkName)
    return crypto.sha256("zelnet-net|" .. tostring(networkName)):sub(1, 8)
end

function M.isServer(cfg)
    return cfg and M.SERVER_ROLES[cfg.role] == true
end

local function isHexKey(v)
    return type(v) == "string" and #v == 64 and v:match("^%x+$") ~= nil
end

function M.validate(cfg)
    if type(cfg) ~= "table" then return false, "config is not a table" end
    if cfg.zn ~= 1 then return false, "unknown config format" end
    if not M.ROLES[cfg.role] then return false, "unknown role: " .. tostring(cfg.role) end
    if type(cfg.network) ~= "string" or cfg.network == "" then return false, "missing network name" end
    if not util.normRealm(cfg.realm) then return false, "bad realm name" end
    if not isHexKey(cfg.realmKey) then return false, "missing realm key" end
    if M.isServer(cfg) then
        if not isHexKey(cfg.backboneKey) then return false, "missing backbone key" end
        if not util.normRealm(cfg.mainRealm) then return false, "missing main realm" end
    else
        if not isHexKey(cfg.deviceKey) then return false, "missing device key" end
        if not util.normName(cfg.name) then return false, "bad device name" end
    end
    return true
end

function M.applyDefaults(cfg)
    for k, v in pairs(M.DEFAULTS) do
        if cfg[k] == nil then cfg[k] = v end
    end
    cfg.realm = util.normRealm(cfg.realm) or cfg.realm
    cfg.netId = M.netIdFor(cfg.network)
    if M.isServer(cfg) then
        cfg.name = cfg.name or cfg.realm:lower()
        cfg.bridges = cfg.bridges or {}
        cfg.storage = cfg.storage or { drives = {} }
        cfg.displays = cfg.displays or {}
    end
    return cfg
end

function M.load(path)
    path = path or M.PATH
    local text = util.readFile(path)
    if not text then return nil, "not configured" end
    local cfg, err = codec.decode(text)
    if type(cfg) ~= "table" then return nil, "config unreadable: " .. tostring(err) end
    local ok, verr = M.validate(cfg)
    if not ok then return nil, verr end
    return M.applyDefaults(cfg)
end

function M.save(cfg, path)
    path = path or M.PATH
    local copy = util.copy(cfg)
    copy.netId = nil
    copy.version = version.program
    local text, err = codec.encode(copy)
    if not text then return false, err end
    return util.writeFile(path, text)
end

function M.newServer(opts)
    local cfg = {
        zn = 1,
        role = opts.role or "main",
        network = opts.network or "ZelNet",
        realm = util.normRealm(opts.realm),
        mainRealm = util.normRealm(opts.mainRealm or opts.realm),
        backboneKey = opts.backboneKey or crypto.newKey(),
        realmKey = opts.realmKey or crypto.newKey(),
        dataKey = opts.dataKey or crypto.newKey(),
        created = os.clock and os.clock() or 0,
    }
    return M.applyDefaults(cfg)
end

function M.newDevice(serverCfg, role, name, serverId)
    return {
        zn = 1,
        role = role,
        network = serverCfg.network,
        realm = serverCfg.realm,
        mainRealm = serverCfg.mainRealm,
        name = name,
        deviceKey = crypto.newKey(),
        realmKey = serverCfg.realmKey,
        channel = serverCfg.channel,
        authority = { realm = serverCfg.realm, id = serverId },
        useWired = serverCfg.useWired,
        useBitnet = serverCfg.useBitnet,
        provisionedBy = serverCfg.realm,
    }
end

return M
