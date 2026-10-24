local need = ...
local util = need("util")
local version = need("version")

local M = {}

M.URL = "https://raw.githubusercontent.com/salesmanhappymask/ZelNet/HEAD/dist/zelnet"
M.TIMEOUT = 60
M.MIN_SIZE = 1000
M.HINT = "In config/ComputerCraft.cfg set http_enable=true and add *githubusercontent.com to http_whitelist, then restart Minecraft."

function M.url(cfg)
    if type(cfg) == "table" and type(cfg.updateUrl) == "string" and cfg.updateUrl ~= "" then return cfg.updateUrl end
    return M.URL
end

function M.versionOf(text)
    if type(text) ~= "string" then return nil end
    local p = text:match('program%s*=%s*"(%d[%w%.%-_]*)"')
    if not p then return nil end
    local b = text:match('build%s*=%s*"(%w+)"')
    if b and b ~= "dev" then return p .. "+" .. b end
    return p
end

function M.normalize(text)
    return (text:gsub("[\r\n]+$", "")) .. "\n"
end

function M.download(url, timeout)
    if type(http) ~= "table" or type(http.request) ~= "function" then
        return nil, "The http API is turned off on this Minecraft server. " .. M.HINT
    end
    local ok, err = pcall(http.request, url)
    if not ok then
        local why = tostring(err):gsub("^.-:%d+: ", "")
        return nil, "Cannot reach " .. tostring(url:match("^%a+://([^/]+)") or url) .. " (" .. why .. "). " .. M.HINT
    end
    local timer = os.startTimer(timeout or M.TIMEOUT)
    while true do
        local ev, a, b = os.pullEvent()
        if ev == "http_success" and a == url then
            local text = b.readAll()
            pcall(b.close)
            return text
        elseif ev == "http_failure" and a == url then
            return nil, "The download failed. Check that the address is right and that GitHub is reachable."
        elseif ev == "timer" and a == timer then
            return nil, "GitHub did not answer within " .. tostring(timeout or M.TIMEOUT) .. " seconds."
        end
    end
end

function M.check(text)
    if type(text) ~= "string" or #text < M.MIN_SIZE then return nil, "The download is empty or cut off." end
    if not text:find("__mods", 1, true) then return nil, "The download is not a ZelNet program." end
    local fn, err = loadstring(text, "=zelnet")
    if not fn then return nil, "The download does not compile: " .. tostring(err) end
    local ver = M.versionOf(text)
    if not ver then return nil, "The download has no version number." end
    return ver
end

function M.fetch(cfg, timeout)
    local url = M.url(cfg)
    local text, err = M.download(url, timeout)
    if not text then return nil, err end
    text = M.normalize(text)
    local ver, cerr = M.check(text)
    if not ver then return nil, cerr end
    local rel = tonumber(text:match("release = (%d+)"))
    return { text = text, version = ver, rel = rel, label = version.labelOf(ver, rel), url = url, size = #text, current = version.full(), currentLabel = version.label(), same = ver == version.full() }
end

function M.install(text, path)
    path = path or "/zelnet"
    local ok, err = util.replaceFile(path, text)
    if not ok then return nil, "cannot write " .. path .. ": " .. tostring(err) end
    return true
end

return M
