local M = {}

local nativePcall = pcall
local select, unpack, type, error, tostring = select, unpack, type, error, tostring
local floor = math.floor

function M.pack(...)
    return { n = select("#", ...), ... }
end

local function pack(...)
    return { n = select("#", ...), ... }
end

function M.native(fn)
    return function(...)
        local r = pack(nativePcall(fn, ...))
        if r[1] then return unpack(r, 2, r.n) end
        error(r[2], 2)
    end
end

function M.fail(msg)
    error(msg, 0)
end

function M.toInt(d)
    if d ~= d then return 0 end
    if d >= 2147483647 then return 2147483647 end
    if d <= -2147483648 then return -2147483648 end
    if d >= 0 then return floor(d) end
    return -floor(-d)
end

function M.copy(t)
    local out = {}
    for k, v in pairs(t) do out[k] = v end
    return out
end

function M.deepcopy(v, seen)
    if type(v) ~= "table" then return v end
    seen = seen or {}
    if seen[v] then return seen[v] end
    local out = {}
    seen[v] = out
    for k, x in pairs(v) do out[M.deepcopy(k, seen)] = M.deepcopy(x, seen) end
    return out
end

function M.sortedKeys(t)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    return keys
end

function M.dist(a, b)
    local dx, dy, dz = a[1] - b[1], a[2] - b[2], a[3] - b[3]
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

function M.vec(p)
    if not p then return { 0, 0, 0 } end
    return { p[1] or p.x or 0, p[2] or p.y or 0, p[3] or p.z or 0 }
end

return M
