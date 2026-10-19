local need = ...
local crypto = need("crypto")
local codec = need("codec")

local M = {}

M.ACCESS_BODY_MAX = 8192
M.BACKBONE_BODY_MAX = 32768

local function accessAad(w)
    return table.concat({ tostring(w.v), w.id, w.src, w.dst, w.port, w.dir, w.dev, w.re or "", w.rq and "1" or "" }, "|")
end

local function backboneAad(w)
    return table.concat({ tostring(w.v), w.id, w.src, w.dst, w.port, w.re or "", w.rq and "1" or "" }, "|")
end

function M.sealAccess(deviceKey, pkt, dir, dev)
    local body, err = codec.encode(pkt.body)
    if not body then return nil, err end
    if #body > M.ACCESS_BODY_MAX then return nil, "too_large" end
    local w = {
        v = 1, id = pkt.id, src = pkt.src, dst = pkt.dst, port = pkt.port, ttl = pkt.ttl or 24,
        dir = dir, dev = dev, re = pkt.re, rq = pkt.rq,
    }
    local n, ct, tag = crypto.sealString(deviceKey, body, accessAad(w))
    w.n, w.ct, w.mac = n, ct, tag
    return w
end

function M.openAccess(deviceKey, w)
    local plain, err = crypto.openString(deviceKey, w.n, w.ct, w.mac, accessAad(w))
    if not plain then return nil, err end
    local body, derr = codec.decode(plain)
    if body == nil and plain ~= "nil" then return nil, "bad body: " .. tostring(derr) end
    return {
        v = w.v, id = w.id, src = w.src, dst = w.dst, port = w.port, ttl = w.ttl,
        re = w.re, rq = w.rq, body = body,
    }
end

function M.sealBackbone(cipherObj, backboneKey, pkt, via)
    local body, err = codec.encode({ n = crypto.randHex(16), t = os.clock(), b = pkt.body })
    if not body then return nil, err end
    if #body > M.BACKBONE_BODY_MAX then return nil, "too_large" end
    local ct, cerr = cipherObj.encrypt(body)
    if not ct then return nil, "cipher: " .. tostring(cerr) end
    local w = {
        v = 1, id = pkt.id, src = pkt.src, dst = pkt.dst, port = pkt.port, ttl = pkt.ttl or 24,
        re = pkt.re, rq = pkt.rq, via = via, ct = ct,
    }
    w.mac = crypto.mac(backboneKey, backboneAad(w) .. "|" .. ct)
    return w
end

function M.verifyBackbone(backboneKey, w)
    local expect = crypto.mac(backboneKey, backboneAad(w) .. "|" .. w.ct)
    return crypto.constEq(expect, w.mac)
end

function M.openBackbone(cipherObj, backboneKey, w)
    if not M.verifyBackbone(backboneKey, w) then return nil, "bad mac" end
    local plain, err = cipherObj.decrypt(w.ct)
    if not plain then return nil, "cipher: " .. tostring(err) end
    local inner = codec.decode(plain)
    if type(inner) ~= "table" or type(inner.n) ~= "string" then return nil, "bad inner" end
    return {
        v = w.v, id = w.id, src = w.src, dst = w.dst, port = w.port, ttl = w.ttl,
        re = w.re, rq = w.rq, body = inner.b,
    }, inner.n
end

function M.beaconMac(realmKey, d)
    return crypto.mac(realmKey, "b|" .. d.realm .. "|" .. tostring(d.root) .. "|" .. tostring(d.seq))
end

function M.helloMac(backboneKey, d)
    return crypto.mac(backboneKey, "h|" .. d.realm .. "|" .. tostring(d.id) .. "|" .. tostring(d.seq) .. "|" .. tostring(d.fp or ""))
end

function M.storeSeal(cipherObj, dataKey, value)
    local plain, err = codec.encode(value)
    if not plain then return nil, err end
    if cipherObj and cipherObj.kind == "hardware" then
        local ct, cerr = cipherObj.encrypt(plain)
        if not ct then return nil, cerr end
        return codec.encode({ zs = 2, c = ct, s = crypto.adler32(plain) })
    end
    if dataKey then
        local n, ct, tag = crypto.sealString(dataKey, plain, "store")
        return codec.encode({ zs = 1, n = n, c = ct, m = tag })
    end
    return codec.encode({ zs = 0, p = plain })
end

function M.storeOpen(cipherObj, dataKey, text)
    local box = codec.decode(text)
    if type(box) ~= "table" then return nil, "corrupt" end
    local plain
    if box.zs == 2 then
        if not cipherObj or cipherObj.kind ~= "hardware" then return nil, "needs cipher block" end
        local p, err = cipherObj.decrypt(box.c)
        if not p then return nil, "decrypt failed: " .. tostring(err) end
        if crypto.adler32(p) ~= box.s then return nil, "checksum mismatch" end
        plain = p
    elseif box.zs == 1 then
        if not dataKey then return nil, "needs data key" end
        local p, err = crypto.openString(dataKey, box.n, box.c, box.m, "store")
        if not p then return nil, err end
        plain = p
    elseif box.zs == 0 then
        plain = box.p
    else
        return nil, "unknown format"
    end
    local v, derr = codec.decode(plain)
    if v == nil and plain ~= "nil" then return nil, "bad payload: " .. tostring(derr) end
    return v
end

return M
