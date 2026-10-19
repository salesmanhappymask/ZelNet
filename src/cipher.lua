local need = ...
local crypto = need("crypto")

local M = {}

local function hasMethods(name, list)
    local ok, methods = pcall(peripheral.getMethods, name)
    if not ok or type(methods) ~= "table" then return false end
    local set = {}
    for _, m in ipairs(methods) do set[m] = true end
    for _, m in ipairs(list) do
        if not set[m] then return false end
    end
    return true
end

local function candidateNames()
    local names = {}
    local seen = {}
    local function add(n)
        if not seen[n] then
            seen[n] = true
            names[#names + 1] = n
        end
    end
    for _, side in ipairs({ "top", "bottom", "left", "right", "front", "back" }) do
        if peripheral.isPresent(side) then add(side) end
    end
    if peripheral.getNames then
        for _, n in ipairs(peripheral.getNames()) do add(n) end
    end
    return names
end

function M.findName(preferred)
    if preferred and peripheral.isPresent(preferred) and hasMethods(preferred, { "encrypt", "decrypt" }) then
        return preferred
    end
    local fallback
    for _, name in ipairs(candidateNames()) do
        local t = peripheral.getType(name) or ""
        if hasMethods(name, { "encrypt", "decrypt" }) and not hasMethods(name, { "createKeySet" }) then
            if t:lower():find("cipher") then return name end
            fallback = fallback or name
        end
    end
    return fallback
end

local function hardware(name)
    local obj = { kind = "hardware", name = name, calls = 0, errors = 0 }
    function obj.encrypt(text)
        obj.calls = obj.calls + 1
        local ok, res = pcall(peripheral.call, name, "encrypt", text)
        if ok and type(res) == "string" then return res end
        obj.errors = obj.errors + 1
        return nil, tostring(res)
    end
    function obj.decrypt(text)
        obj.calls = obj.calls + 1
        local ok, res = pcall(peripheral.call, name, "decrypt", text)
        if ok and type(res) == "string" then return res end
        obj.errors = obj.errors + 1
        return nil, "decrypt failed"
    end
    function obj.present()
        return peripheral.isPresent(name)
    end
    return obj
end

local function software(keyHex)
    local obj = { kind = "software", name = "software", calls = 0, errors = 0 }
    function obj.encrypt(text)
        obj.calls = obj.calls + 1
        local n = crypto.randHex(16)
        return n .. crypto.b64encode(crypto.encrypt(keyHex, n, text))
    end
    function obj.decrypt(text)
        obj.calls = obj.calls + 1
        if type(text) ~= "string" or #text < 33 then
            obj.errors = obj.errors + 1
            return nil, "decrypt failed"
        end
        local raw = crypto.b64decode(text:sub(33))
        if not raw then
            obj.errors = obj.errors + 1
            return nil, "decrypt failed"
        end
        return crypto.encrypt(keyHex, text:sub(1, 32), raw)
    end
    function obj.present()
        return true
    end
    return obj
end

function M.selfTest(obj)
    if not obj then return false, "no cipher" end
    local sample = "zelnet-selftest|" .. crypto.randHex(8) .. "|\"quoted\"|end"
    local ct, err = obj.encrypt(sample)
    if not ct then return false, "encrypt failed: " .. tostring(err) end
    if ct == sample then return false, "cipher returned plaintext" end
    local back, err2 = obj.decrypt(ct)
    if back ~= sample then return false, "round trip failed: " .. tostring(err2) end
    return true
end

function M.fingerprint(obj)
    if not obj then return nil end
    local ct = obj.encrypt("zelnet-fingerprint-v1")
    if not ct then return nil end
    if obj.kind == "software" then
        return crypto.sha256("sw|" .. obj.decrypt(ct)):sub(1, 12)
    end
    return crypto.sha256("hw|" .. ct):sub(1, 12)
end

function M.open(opts)
    opts = opts or {}
    local name = M.findName(opts.preferred)
    if name then
        local obj = hardware(name)
        local ok, err = M.selfTest(obj)
        if ok then return obj end
        if not opts.softwareKey then return nil, "cipher block failed self test: " .. tostring(err) end
    end
    if opts.softwareKey then
        local obj = software(opts.softwareKey)
        return obj, name and "cipher block failed, using software cipher" or "no cipher block, using software cipher"
    end
    return nil, "no cipher block found"
end

M.software = software
M.hardware = hardware

return M
