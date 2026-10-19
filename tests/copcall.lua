local M = {}

local nativePcall = pcall
local nativeGetmetatable = getmetatable

function M.new(opts)
    opts = opts or {}
    local create = opts.create or coroutine.create
    local resume = opts.resume or coroutine.resume
    local yield = opts.yield or coroutine.yield
    local status = opts.status or coroutine.status
    local intercept = opts.intercept

    local performResume

    local function handleReturn(handler, co, ok, ...)
        if not ok then
            local err = (...)
            if intercept then intercept(err) end
            if handler then
                local hok, hres = nativePcall(handler, err)
                if hok then return false, hres end
                return false, "error in error handling"
            end
            return false, err
        end
        if status(co) == "suspended" then
            return performResume(handler, co, yield(...))
        end
        return true, ...
    end

    performResume = function(handler, co, ...)
        return handleReturn(handler, co, resume(co, ...))
    end

    local function callable(f)
        if type(f) == "function" then return f end
        local mt = nativeGetmetatable(f)
        if type(mt) == "table" and mt.__call ~= nil then
            return function(...) return f(...) end
        end
        return nil
    end

    local api = {}

    function api.pcall(f, ...)
        local fn = callable(f)
        if not fn then return nativePcall(f, ...) end
        return performResume(nil, create(fn), ...)
    end

    function api.xpcall(f, handler, ...)
        local fn = callable(f)
        if not fn then
            local ok, err = nativePcall(f)
            if handler then
                local hok, hres = nativePcall(handler, err)
                if hok then return false, hres end
                return false, "error in error handling"
            end
            return ok, err
        end
        return performResume(handler or function(e) return e end, create(fn), ...)
    end

    return api
end

local default = M.new()
M.pcall = default.pcall
M.xpcall = default.xpcall

function M.install(env)
    env = env or _G
    if env == _G then rawset(_G, "__nativePcall", rawget(_G, "__nativePcall") or nativePcall) end
    env.pcall = M.pcall
    env.xpcall = function(f, handler) return M.xpcall(f, handler) end
end

return M
