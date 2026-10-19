local need = ...
local compat = need("compat")
local crypto = need("crypto")

local M = {}

function M.clamp(n, a, b)
    if n < a then return a end
    if n > b then return b end
    return n
end

function M.fmtFixed(n, digits)
    n = tonumber(n) or 0
    digits = math.max(0, math.floor(tonumber(digits) or 0))
    if n ~= n or n == math.huge or n == -math.huge then return "0" end
    local scale = 1
    for _ = 1, digits do scale = scale * 10 end
    local scaled
    if n >= 0 then
        scaled = math.floor(n * scale + 0.5)
    else
        scaled = math.ceil(n * scale - 0.5)
    end
    local negative = scaled < 0
    if negative then scaled = -scaled end
    local whole = math.floor(scaled / scale)
    local sign = negative and "-" or ""
    if digits == 0 then return sign .. tostring(whole) end
    local frac = math.floor(scaled - whole * scale)
    local fracText = tostring(frac)
    while #fracText < digits do fracText = "0" .. fracText end
    return sign .. tostring(whole) .. "." .. fracText
end

function M.fmtTrim(n, digits)
    local s = M.fmtFixed(n, digits)
    if s:find("%.") then s = s:gsub("0+$", ""):gsub("%.$", "") end
    return s
end

function M.fmtBytes(n)
    n = tonumber(n) or 0
    if n >= 1048576 then return M.fmtTrim(n / 1048576, 1) .. "M" end
    if n >= 1024 then return M.fmtTrim(n / 1024, 1) .. "K" end
    return tostring(math.floor(n)) .. "B"
end

function M.fmtAmount(n)
    n = tonumber(n) or 0
    local a = math.abs(n)
    local units = { { 1e12, "T" }, { 1e9, "G" }, { 1e6, "M" }, { 1e3, "K" } }
    for _, u in ipairs(units) do
        if a >= u[1] then
            local v = n / u[1]
            if math.abs(v) >= 100 then return M.fmtFixed(v, 0) .. u[2] end
            if math.abs(v) >= 10 then return M.fmtTrim(v, 1) .. u[2] end
            return M.fmtTrim(v, 2) .. u[2]
        end
    end
    if a >= 10 then return M.fmtFixed(n, 0) end
    return M.fmtTrim(n, 1)
end

function M.fmtDuration(seconds)
    seconds = math.max(0, math.floor((tonumber(seconds) or 0) + 0.5))
    local d = math.floor(seconds / 86400)
    local h = math.floor((seconds % 86400) / 3600)
    local m = math.floor((seconds % 3600) / 60)
    local s = seconds % 60
    if d > 0 then return d .. "d " .. h .. "h" end
    if h > 0 then return h .. "h " .. m .. "m" end
    if m > 0 then return m .. "m " .. s .. "s" end
    return s .. "s"
end

function M.fmtStamp(stamp)
    stamp = tonumber(stamp) or 0
    local day = math.floor(stamp / 24)
    local t = stamp - day * 24
    local hh = math.floor(t)
    local mm = math.floor((t - hh) * 60)
    local ms = tostring(mm)
    if #ms < 2 then ms = "0" .. ms end
    local hs = tostring(hh)
    if #hs < 2 then hs = "0" .. hs end
    return "D" .. day .. " " .. hs .. ":" .. ms
end

function M.trim(s)
    s = tostring(s or "")
    return (s:match("^%s*(.-)%s*$") or "")
end

function M.split(s, sep)
    local out = {}
    s = tostring(s or "")
    local pattern = "([^" .. (sep or "%s") .. "]+)"
    for part in s:gmatch(pattern) do out[#out + 1] = part end
    return out
end

function M.startsWith(s, prefix)
    return type(s) == "string" and s:sub(1, #prefix) == prefix
end

function M.fitText(s, width)
    s = tostring(s or "")
    if width <= 0 then return "" end
    if #s <= width then return s end
    if width <= 3 then return s:sub(1, width) end
    return s:sub(1, width - 3) .. "..."
end

function M.padRight(s, width)
    s = M.fitText(s, width)
    return s .. string.rep(" ", width - #s)
end

function M.center(s, width)
    s = M.fitText(s, width)
    local left = math.floor((width - #s) / 2)
    return string.rep(" ", left) .. s .. string.rep(" ", width - #s - left)
end

function M.sanitize(s)
    s = tostring(s or "")
    local out = {}
    for i = 1, #s do
        local c = s:byte(i)
        if c == 9 or c == 10 or c == 13 then
            out[#out + 1] = " "
        elseif c >= 32 and c <= 126 then
            out[#out + 1] = string.char(c)
        else
            out[#out + 1] = "?"
        end
    end
    return table.concat(out)
end

function M.wrapText(text, width)
    width = math.max(1, math.floor(tonumber(width) or 1))
    local lines = {}
    text = tostring(text or "")
    for paragraph in (text .. "\n"):gmatch("(.-)\n") do
        if paragraph == "" then
            lines[#lines + 1] = ""
        else
            local line = ""
            for word in paragraph:gmatch("%S+") do
                while #word > width do
                    if line ~= "" then
                        lines[#lines + 1] = line
                        line = ""
                    end
                    lines[#lines + 1] = word:sub(1, width)
                    word = word:sub(width + 1)
                end
                if word ~= "" then
                    if line == "" then
                        line = word
                    elseif #line + 1 + #word <= width then
                        line = line .. " " .. word
                    else
                        lines[#lines + 1] = line
                        line = word
                    end
                end
            end
            if line ~= "" then lines[#lines + 1] = line end
        end
    end
    if #lines == 0 then lines[1] = "" end
    return lines
end

function M.copy(t)
    local out = {}
    for k, v in pairs(t or {}) do out[k] = v end
    return out
end

function M.deepCopy(v, seen)
    if type(v) ~= "table" then return v end
    seen = seen or {}
    if seen[v] then return seen[v] end
    local out = {}
    seen[v] = out
    for k, x in pairs(v) do out[M.deepCopy(k, seen)] = M.deepCopy(x, seen) end
    return out
end

function M.count(t)
    local n = 0
    for _ in pairs(t or {}) do n = n + 1 end
    return n
end

function M.sortedKeys(t)
    local keys = {}
    for k in pairs(t or {}) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    return keys
end

function M.contains(list, value)
    for _, v in ipairs(list or {}) do
        if v == value then return true end
    end
    return false
end

M.serialize = crypto.serialize
M.unserialize = crypto.unserialize

function M.readFile(path)
    if not fs.exists(path) or fs.isDir(path) then return nil end
    local h = fs.open(path, "r")
    if not h then return nil end
    local s = h.readAll()
    h.close()
    return s
end

function M.parentDir(path)
    local dir = path:match("^(.*)/[^/]*$")
    if dir == nil or dir == "" then return "/" end
    return dir
end

function M.writeFile(path, data)
    local dir = M.parentDir(path)
    if dir ~= "/" and not fs.exists(dir) then
        local ok = pcall(fs.makeDir, dir)
        if not ok then return false, "cannot create " .. dir end
    end
    local tmp = path .. ".tmp"
    local ok, err = pcall(function()
        local h = fs.open(tmp, "w")
        if not h then error("cannot open " .. tmp, 0) end
        local wok, werr = pcall(h.write, data)
        h.close()
        if not wok then error(werr, 0) end
    end)
    if not ok then
        pcall(fs.delete, tmp)
        return false, tostring(err)
    end
    if fs.exists(path) then fs.delete(path) end
    fs.move(tmp, path)
    return true
end

function M.readTable(path, default)
    local s = M.readFile(path)
    if not s then return default end
    local v = M.unserialize(s)
    if type(v) ~= "table" then return default end
    return v
end

function M.writeTable(path, t)
    local s, err = M.serialize(t)
    if not s then return false, err end
    return M.writeFile(path, s)
end

function M.newId()
    return crypto.randHex(8)
end

function M.newRing(size)
    local ring = { size = size or 100, items = {} }
    function ring.push(item)
        ring.items[#ring.items + 1] = item
        while #ring.items > ring.size do table.remove(ring.items, 1) end
    end
    function ring.last(n)
        local out = {}
        local start = math.max(1, #ring.items - (n or #ring.items) + 1)
        for i = start, #ring.items do out[#out + 1] = ring.items[i] end
        return out
    end
    function ring.clear()
        ring.items = {}
    end
    return ring
end

function M.newLogger(size)
    local log = M.newRing(size or 200)
    log.listeners = {}
    function log.write(level, text)
        local entry = { t = compat.now(), s = compat.stamp(), level = level, text = M.sanitize(text) }
        log.push(entry)
        for _, fn in ipairs(log.listeners) do pcall(fn, entry) end
        return entry
    end
    function log.info(text) return log.write("info", text) end
    function log.warn(text) return log.write("warn", text) end
    function log.error(text) return log.write("error", text) end
    function log.debug(text) return log.write("debug", text) end
    function log.listen(fn) log.listeners[#log.listeners + 1] = fn end
    return log
end

function M.newSeenSet(ttl, maxSize)
    local set = { ttl = ttl or 300, max = maxSize or 2000, map = {}, order = {}, head = 1 }
    function set.prune()
        local now = compat.now()
        while set.head <= #set.order do
            local item = set.order[set.head]
            if now - item.t <= set.ttl and (#set.order - set.head + 1) <= set.max then break end
            if set.map[item.k] == item.t then set.map[item.k] = nil end
            set.order[set.head] = nil
            set.head = set.head + 1
        end
        if set.head > 512 and set.head > #set.order / 2 then
            local fresh = {}
            for i = set.head, #set.order do fresh[#fresh + 1] = set.order[i] end
            set.order = fresh
            set.head = 1
        end
    end
    function set.check(k)
        set.prune()
        if set.map[k] then return true end
        local now = compat.now()
        set.map[k] = now
        set.order[#set.order + 1] = { k = k, t = now }
        return false
    end
    function set.has(k)
        set.prune()
        return set.map[k] ~= nil
    end
    return set
end

function M.newQueue()
    local q = { first = 1, last = 0, items = {} }
    function q.push(v)
        q.last = q.last + 1
        q.items[q.last] = v
    end
    function q.pop()
        if q.first > q.last then return nil end
        local v = q.items[q.first]
        q.items[q.first] = nil
        q.first = q.first + 1
        return v
    end
    function q.size()
        return q.last - q.first + 1
    end
    function q.peek()
        return q.items[q.first]
    end
    return q
end

local REALM_PATTERN = "^[A-Z][A-Z0-9_]*$"
local NAME_PATTERN = "^[a-z][a-z0-9_%-]*$"

function M.normRealm(s)
    if type(s) ~= "string" then return nil end
    s = M.trim(s):upper()
    if #s < 1 or #s > 12 or not s:match(REALM_PATTERN) then return nil end
    return s
end

function M.normName(s)
    if type(s) ~= "string" then return nil end
    s = M.trim(s):lower()
    if #s < 1 or #s > 16 or not s:match(NAME_PATTERN) then return nil end
    return s
end

function M.parseAddress(addr)
    if type(addr) ~= "string" then return nil, "bad address" end
    if addr == "*" then return { realm = "*" } end
    local realm, node = addr:match("^([^:]+):(.+)$")
    if not realm then realm = addr end
    local r = M.normRealm(realm)
    if not r then return nil, "bad realm" end
    if not node then return { realm = r } end
    local id = tonumber(node)
    if id and id >= 0 and math.floor(id) == id then return { realm = r, id = id } end
    local name = M.normName(node)
    if not name then return nil, "bad node" end
    return { realm = r, name = name }
end

function M.formatAddress(realm, node)
    if node == nil then return realm end
    return realm .. ":" .. tostring(node)
end

function M.normAddress(addr)
    local a, err = M.parseAddress(addr)
    if not a then return nil, err end
    if a.realm == "*" then return "*" end
    return M.formatAddress(a.realm, a.id or a.name)
end

function M.validPort(port)
    return type(port) == "string" and #port >= 1 and #port <= 24 and not port:find("[%c]")
end

function M.validTopic(topic)
    return type(topic) == "string" and #topic >= 1 and #topic <= 48 and topic:match("^[%w%._%-%*]+$") ~= nil
end

function M.topicMatches(pattern, topic)
    if pattern == topic then return true end
    if pattern:sub(-2) == ".*" then
        local prefix = pattern:sub(1, -2)
        return topic:sub(1, #prefix) == prefix
    end
    return false
end

return M
