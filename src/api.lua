local need = ...
local config = need("config")
local node = need("node")
local util = need("util")
local version = need("version")

local M = {}

local state = { node = nil }

local function current()
    if not state.node then error("zelnet: call zn.open() first", 3) end
    return state.node
end

function M.attach(n)
    state.node = n
end

function M.node()
    return state.node
end

function M.open(opts)
    opts = opts or {}
    if state.node then return true end
    local cfg, err = config.load(opts.config)
    if not cfg then return nil, err end
    if config.isServer(cfg) and not opts.allowServer then
        return nil, "this computer is a ZelNet server; use its console or run your program on an endpoint"
    end
    state.node = node.new(cfg, { log = opts.log })
    state.node:start()
    return true
end

function M.run(fn, ...)
    return current():loop(fn, ...)
end

function M.loop()
    return current():loop()
end

function M.close()
    if state.node then state.node:close() end
    state.node = nil
end

function M.send(dst, port, data)
    return current():send(dst, port, data)
end

function M.request(dst, port, data, timeout)
    return current():request(dst, port, data, timeout)
end

function M.receive(port, timeout)
    return current():receive(port, timeout)
end

function M.reply(msg, data)
    return current():reply(msg, data)
end

function M.listen(port, handler)
    return current():listen(port, handler)
end

function M.unlisten(port)
    return current():unlisten(port)
end

function M.publish(topic, data, opts)
    return current():publish(topic, data, opts)
end

function M.subscribe(topic, handler)
    return current():subscribe(topic, handler)
end

function M.unsubscribe(topic)
    return current():unsubscribe(topic)
end

function M.register(name)
    return current():register(name)
end

function M.resolve(addr)
    return current():resolve(addr)
end

function M.ping(dst, timeout)
    return current():ping(dst, timeout)
end

function M.address()
    return current().address
end

function M.realm()
    return current().realm
end

function M.isConnected()
    return current():isConnected()
end

function M.status()
    return current():status()
end

function M.on(event, fn)
    return current():on(event, fn)
end

function M.version()
    return version.program, version.protocol
end

function M.uikit()
    return need("ui")
end

M.util = {
    parseAddress = util.parseAddress,
    normAddress = util.normAddress,
    fmtFixed = util.fmtFixed,
    fmtTrim = util.fmtTrim,
    fmtAmount = util.fmtAmount,
    fmtDuration = util.fmtDuration,
    fmtStamp = util.fmtStamp,
    fitText = util.fitText,
    wrapText = util.wrapText,
}

return M
