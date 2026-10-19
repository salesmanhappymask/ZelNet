local M = {}

local create, resume, yield, status = coroutine.create, coroutine.resume, coroutine.yield, coroutine.status
local nativePcall = pcall

local performResume

local function handleReturn(handler, co, ok, ...)
    if not ok then
        return false, handler((...))
    end
    if status(co) == "suspended" then
        return performResume(handler, co, yield(...))
    end
    return true, ...
end

performResume = function(handler, co, ...)
    return handleReturn(handler, co, resume(co, ...))
end

function M.xpcall(f, handler, ...)
    if type(f) ~= "function" then
        local ok, err = nativePcall(f)
        return ok, err
    end
    local args = { ... }
    local n = select("#", ...)
    local co = create(function() return f(unpack(args, 1, n)) end)
    return performResume(handler or function(e) return e end, co)
end

function M.pcall(f, ...)
    if type(f) ~= "function" then
        return nativePcall(f, ...)
    end
    local args = { ... }
    local n = select("#", ...)
    local co = create(function() return f(unpack(args, 1, n)) end)
    return performResume(function(e) return e end, co)
end

function M.install(env)
    env = env or _G
    if env == _G then rawset(_G, "__nativePcall", rawget(_G, "__nativePcall") or nativePcall) end
    env.pcall = M.pcall
    env.xpcall = function(f, handler) return M.xpcall(f, handler) end
end

return M
