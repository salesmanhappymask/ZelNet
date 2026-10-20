local M = {}

function M.term(w, h, color)
    local t = { blink = false }
    t.getSize = function() return w, h end
    t.isColor = function() return color and true or false end
    t.setBackgroundColor = function() end
    t.setTextColor = function() end
    t.setCursorPos = function() end
    t.setCursorBlink = function(b) t.blink = b end
    t.write = function() end
    t.clear = function() end
    return t
end

function M.extendKeys()
    keys.delete = keys.delete or 211
    keys.home = keys.home or 199
    keys["end"] = keys["end"] or 207
    keys.pageUp = keys.pageUp or 201
    keys.pageDown = keys.pageDown or 209
end

function M.rows(surf)
    local out = {}
    for y = 1, surf.h do
        local chars = {}
        for x = 1, surf.w do chars[x] = surf.fc[(y - 1) * surf.w + x] end
        out[y] = table.concat(chars)
    end
    return out
end

function M.screen(surf)
    return table.concat(M.rows(surf), "\n")
end

function M.has(surf, text)
    return M.screen(surf):find(text, 1, true) ~= nil
end

function M.expect(surf, text, msg)
    if not M.has(surf, text) then
        error((msg or "screen") .. ": expected to see " .. string.format("%q", text) .. "\n" .. M.screen(surf), 2)
    end
end

function M.refute(surf, text, msg)
    if M.has(surf, text) then
        error((msg or "screen") .. ": did not expect " .. string.format("%q", text) .. "\n" .. M.screen(surf), 2)
    end
end

function M.makeNode(need, opts)
    opts = opts or {}
    local config = need("config")
    local node = need("node")
    local scfg = config.newServer({ realm = opts.realm or "MARS" })
    local cfg = config.applyDefaults(config.newDevice(scfg, opts.role or "client", opts.name or "cli", 3))
    local n = node.new(cfg)
    n.connected = true
    n.parent = { id = 3, hops = 0, link = "modem:top", seq = 1, root = 3 }
    n.setParent = function() end
    n.sendHello = function() end
    local calls = {}
    n.request = function(self, dst, port, body, timeout, ropts)
        local copy = {}
        for k, v in pairs(body) do copy[k] = v end
        calls[#calls + 1] = { dst = dst, port = port, body = copy, timeout = timeout, retries = ropts and ropts.retries }
        local lat = opts.latency
        if type(lat) == "function" then lat = lat(body) end
        sleep(lat or 0.1)
        if opts.handler then return opts.handler(body, dst, port) end
        return nil, "timeout"
    end
    n.ping = function(self, dst)
        sleep(0.1)
        if opts.pingFail then return nil, "timeout" end
        return 0.25
    end
    return n, calls
end

function M.drive(env, n, mainFn, steps, gap)
    n:spawn(function()
        sleep(0.5)
        for _, st in ipairs(steps) do
            if type(st) == "function" then
                st()
            elseif type(st) == "string" then
                for ch in st:gmatch(".") do os.queueEvent("char", ch) end
            elseif type(st) == "number" then
                sleep(st)
            else
                os.queueEvent(unpack(st))
            end
            sleep(gap or 0.3)
        end
        error("test-done", 0)
    end, "driver", { critical = true })
    local ok, err = pcall(env.run, function() n:loop(mainFn) end, 3600)
    if not ok and err ~= "test-done" then error(err, 0) end
    return ok
end

function M.find(calls, op, from)
    for i = from or 1, #calls do
        if calls[i].body.op == op then return calls[i], i end
    end
    return nil
end

function M.count(calls, op)
    local k = 0
    for _, c in ipairs(calls) do if c.body.op == op then k = k + 1 end end
    return k
end

return M
