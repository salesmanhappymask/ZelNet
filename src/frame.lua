local M = {}

M.KINDS = { b = true, p = true, x = true, h = true }

function M.make(netId, kind, from, to, data)
    return { zn = 1, net = netId, k = kind, f = from, t = to, d = data }
end

function M.valid(f, netId, myId)
    if type(f) ~= "table" or f.zn ~= 1 then return false end
    if f.net ~= netId then return false end
    if type(f.k) ~= "string" or not M.KINDS[f.k] then return false end
    if type(f.f) ~= "number" then return false end
    if f.t ~= nil and type(f.t) ~= "number" then return false end
    if f.t ~= nil and myId ~= nil and f.t ~= myId then return false end
    if type(f.d) ~= "table" then return false end
    return true
end

local function isStr(v, max)
    return type(v) == "string" and #v <= (max or 128)
end

function M.validAccess(d)
    if type(d) ~= "table" then return false end
    if d.v ~= 1 then return false end
    if not isStr(d.id, 32) or not isStr(d.src, 40) or not isStr(d.dst, 40) or not isStr(d.port, 24) then return false end
    if type(d.ttl) ~= "number" then return false end
    if d.dir ~= "u" and d.dir ~= "d" then return false end
    if not isStr(d.dev, 32) then return false end
    if d.re ~= nil and not isStr(d.re, 32) then return false end
    if d.rq ~= nil and d.rq ~= true then return false end
    if not isStr(d.n, 64) or not isStr(d.mac, 64) then return false end
    if type(d.ct) ~= "string" or #d.ct > 16384 then return false end
    return true
end

function M.validBackbone(d)
    if type(d) ~= "table" then return false end
    if d.v ~= 1 then return false end
    if not isStr(d.id, 32) or not isStr(d.src, 40) or not isStr(d.dst, 40) or not isStr(d.port, 24) then return false end
    if type(d.ttl) ~= "number" then return false end
    if d.re ~= nil and not isStr(d.re, 32) then return false end
    if d.rq ~= nil and d.rq ~= true then return false end
    if d.via ~= nil and not isStr(d.via, 16) then return false end
    if not isStr(d.mac, 64) then return false end
    if type(d.ct) ~= "string" or #d.ct > 65536 then return false end
    return true
end

function M.validBeacon(d)
    return type(d) == "table" and isStr(d.realm, 16) and type(d.root) == "number" and type(d.seq) == "number"
        and type(d.hops) == "number" and isStr(d.mac, 64)
end

function M.validHello(d)
    return type(d) == "table" and isStr(d.realm, 16) and type(d.id) == "number" and type(d.seq) == "number"
        and isStr(d.mac, 64)
end

return M
