local M = {}

local function serializeImpl(t, tracking, indent)
    local tp = type(t)
    if tp == "table" then
        if tracking[t] then error("Cannot serialize table with recursive entries", 0) end
        tracking[t] = true
        if next(t) == nil then
            tracking[t] = nil
            return "{}"
        end
        local parts = { "{\n" }
        local sub = indent .. "  "
        local seen = {}
        for k, v in ipairs(t) do
            seen[k] = true
            parts[#parts + 1] = sub .. serializeImpl(v, tracking, sub) .. ",\n"
        end
        for k, v in pairs(t) do
            if not seen[k] then
                local key
                if type(k) == "string" and k:match("^[%a_][%a%d_]*$") then
                    key = k .. " = "
                else
                    key = "[ " .. serializeImpl(k, tracking, sub) .. " ] = "
                end
                parts[#parts + 1] = sub .. key .. serializeImpl(v, tracking, sub) .. ",\n"
            end
        end
        parts[#parts + 1] = indent .. "}"
        tracking[t] = nil
        return table.concat(parts)
    elseif tp == "string" then
        return string.format("%q", t)
    elseif tp == "number" or tp == "boolean" or tp == "nil" then
        return tostring(t)
    end
    error("Cannot serialize type " .. tp, 0)
end

function M.install()
    _G.textutils = _G.textutils or {
        serialize = function(t) return serializeImpl(t, {}, "") end,
        unserialize = function(s)
            local fn = loadstring("return " .. s)
            if fn then
                setfenv(fn, {})
                local ok, v = pcall(fn)
                if ok then return v end
            end
            return nil
        end,
    }
end

return M
