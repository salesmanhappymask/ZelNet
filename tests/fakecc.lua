local M = {}

function M.install(opts)
    opts = opts or {}
    require("tests.shim").install()
    require("tests.copcall").install()
    local files, dirs = {}, { ["/"] = true }
    local clock = 0
    local queue = {}
    local timers = {}
    local nextTimer = 0
    local id = opts.id or 1
    local periph = opts.peripherals or {}

    local function norm(p)
        p = "/" .. tostring(p):gsub("^/+", "")
        p = p:gsub("/+$", "")
        if p == "" then p = "/" end
        return p
    end

    local function parent(p)
        return p:match("^(.*)/[^/]*$") or "/"
    end

    local function mkdirs(p)
        p = norm(p)
        while p ~= "/" and p ~= "" do
            dirs[p] = true
            p = parent(p)
            if p == "" then p = "/" end
        end
    end

    _G.fs = {
        exists = function(p) p = norm(p) return files[p] ~= nil or dirs[p] ~= nil end,
        isDir = function(p) return dirs[norm(p)] ~= nil end,
        makeDir = function(p) mkdirs(p) end,
        delete = function(p)
            p = norm(p)
            files[p] = nil
            dirs[p] = nil
            for _, t in ipairs({ files, dirs }) do
                local gone = {}
                for k in pairs(t) do if k:sub(1, #p + 1) == p .. "/" then gone[#gone + 1] = k end end
                for _, k in ipairs(gone) do t[k] = nil end
            end
        end,
        move = function(a, b)
            a, b = norm(a), norm(b)
            if files[b] or dirs[b] then error("File exists", 0) end
            mkdirs(parent(b))
            files[b] = files[a]
            files[a] = nil
        end,
        copy = function(a, b)
            a, b = norm(a), norm(b)
            mkdirs(parent(b))
            files[b] = files[a]
        end,
        list = function(p)
            p = norm(p)
            local out = {}
            local prefix = p == "/" and "/" or (p .. "/")
            for k in pairs(files) do
                local rest = k:sub(#prefix + 1)
                if k:sub(1, #prefix) == prefix and not rest:find("/") then out[#out + 1] = rest end
            end
            for k in pairs(dirs) do
                local rest = k:sub(#prefix + 1)
                if k ~= p and k:sub(1, #prefix) == prefix and rest ~= "" and not rest:find("/") then out[#out + 1] = rest end
            end
            table.sort(out)
            return out
        end,
        getName = function(p) return norm(p):match("([^/]*)$") end,
        getDir = function(p) return parent(norm(p)):gsub("^/", "") end,
        combine = function(a, b) return (norm(a .. "/" .. b):gsub("^/", "")) end,
        getSize = function(p) return #(files[norm(p)] or "") end,
        getFreeSpace = function() return opts.freeSpace or 1000000 end,
        isReadOnly = function() return false end,
        open = function(p, mode)
            p = norm(p)
            if mode == "r" then
                local data = files[p]
                if not data then return nil end
                local pos = 1
                return {
                    readAll = function() local s = data:sub(pos) pos = #data + 1 return s end,
                    readLine = function()
                        if pos > #data then return nil end
                        local e = data:find("\n", pos, true)
                        local line
                        if e then line = data:sub(pos, e - 1) pos = e + 1 else line = data:sub(pos) pos = #data + 1 end
                        return line
                    end,
                    close = function() end,
                }
            end
            mkdirs(parent(p))
            local buf = {}
            if mode == "a" then buf[1] = files[p] or "" end
            files[p] = files[p] or ""
            return {
                write = function(s) buf[#buf + 1] = tostring(s) end,
                writeLine = function(s) buf[#buf + 1] = tostring(s) .. "\n" end,
                flush = function() files[p] = table.concat(buf) end,
                close = function() files[p] = table.concat(buf) end,
            }
        end,
    }

    _G.os.clock = function() return clock end
    _G.os.time = function() return (clock / 50) % 24 end
    _G.os.day = function() return math.floor(clock / 1200) end
    _G.os.getComputerID = function() return id end
    _G.os.getComputerLabel = function() return opts.label end
    _G.os.setComputerLabel = function() end
    _G.os.startTimer = function(t)
        nextTimer = nextTimer + 1
        timers[nextTimer] = clock + (t or 0)
        return nextTimer
    end
    _G.os.cancelTimer = function(t) timers[t] = nil end
    _G.os.queueEvent = function(...) queue[#queue + 1] = { ... } end
    _G.os.pullEventRaw = function(filter) return coroutine.yield(filter) end
    _G.os.pullEvent = function(filter)
        local ev = { coroutine.yield(filter) }
        if ev[1] == "terminate" then error("Terminated", 0) end
        return unpack(ev)
    end
    _G.sleep = function(t)
        local timer = os.startTimer(t)
        repeat
            local _, a = os.pullEvent("timer")
        until a == timer
    end

    _G.colors = _G.colors or {}
    local cnames = { "white", "orange", "magenta", "lightBlue", "yellow", "lime", "pink", "gray", "lightGray", "cyan", "purple", "blue", "brown", "green", "red", "black" }
    for i, n in ipairs(cnames) do colors[n] = 2 ^ (i - 1) end
    _G.keys = _G.keys or { enter = 28, backspace = 14, tab = 15, up = 200, down = 208, left = 203, right = 205, leftCtrl = 29, rightCtrl = 157 }

    _G.peripheral = {
        isPresent = function(n) return periph[n] ~= nil end,
        getType = function(n) return periph[n] and periph[n].type end,
        getMethods = function(n)
            local p = periph[n]
            if not p then return nil end
            local out = {}
            for k, v in pairs(p.methods or {}) do if type(v) == "function" then out[#out + 1] = k end end
            return out
        end,
        call = function(n, m, ...)
            local p = periph[n]
            if not p then error("No peripheral " .. tostring(n), 0) end
            local f = p.methods and p.methods[m]
            if not f then error("No such method " .. tostring(m), 0) end
            return f(...)
        end,
        wrap = function(n)
            local p = periph[n]
            if not p then return nil end
            return p.methods
        end,
        getNames = function()
            local out = {}
            for k in pairs(periph) do out[#out + 1] = k end
            table.sort(out)
            return out
        end,
    }

    local env = {}

    function env.files() return files end
    function env.setPeripheral(name, p) periph[name] = p end
    function env.advance(seconds) clock = clock + seconds end
    function env.clock() return clock end
    function env.queue() return queue end

    function env.run(fn, maxSeconds)
        maxSeconds = maxSeconds or 60
        local co = coroutine.create(fn)
        local ok, filter = coroutine.resume(co)
        if not ok then error(filter, 0) end
        local deadline = clock + maxSeconds
        while coroutine.status(co) ~= "dead" do
            local ev
            if #queue > 0 then
                ev = table.remove(queue, 1)
            else
                local best, bestT
                for t, at in pairs(timers) do
                    if not bestT or at < bestT then best, bestT = t, at end
                end
                if not best then error("deadlock: no events and no timers", 0) end
                if bestT > deadline then error("timeout", 0) end
                clock = math.max(clock, bestT)
                timers[best] = nil
                ev = { "timer", best }
            end
            if filter == nil or filter == ev[1] or ev[1] == "terminate" then
                ok, filter = coroutine.resume(co, unpack(ev))
                if not ok then error(filter, 0) end
            end
        end
    end

    return env
end

return M
