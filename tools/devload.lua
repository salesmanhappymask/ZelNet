local M = {}

local function stampVersion(text)
    local a, b = 1, 0
    for i = 1, #text do
        a = (a + text:byte(i)) % 65521
        b = (b + a) % 65521
    end
    return (text:gsub('local VERSION = "dev"', string.format('local VERSION = "%04x%04x"', b, a), 1))
end

function M.make(root)
    root = root or "."
    local cache, loading = {}, {}
    local function need(name)
        local c = cache[name]
        if c ~= nil then return c end
        if loading[name] then error("circular module dependency: " .. name, 2) end
        local fn, err
        local prog = name:match("^prog_([%w_]+)$")
        if prog then
            local f = io.open(root .. "/programs/" .. prog .. ".lua", "rb")
            if not f then error("missing program " .. prog, 2) end
            local text = stampVersion(f:read("*a"))
            f:close()
            fn = function() return text end
        else
            fn, err = loadfile(root .. "/src/" .. name .. ".lua")
        end
        if not fn then error(err, 2) end
        loading[name] = true
        c = fn(need)
        loading[name] = nil
        if c == nil then c = true end
        cache[name] = c
        return c
    end
    return need
end

return M
