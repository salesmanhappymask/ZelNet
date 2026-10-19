local M = {}

function M.make(root)
    root = root or "."
    local cache, loading = {}, {}
    local function need(name)
        local c = cache[name]
        if c ~= nil then return c end
        if loading[name] then error("circular module dependency: " .. name, 2) end
        local fn, err = loadfile(root .. "/src/" .. name .. ".lua")
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
