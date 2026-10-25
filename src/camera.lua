local need = ...
local compat = need("compat")
local util = need("util")
local version = need("version")

local M = {}

M.PORT = "zn.cam"
M.LEASE = 30
M.POLL = 2
M.TIMEOUT = 40
M.MAX_W = 32
M.MAX_H = 16
M.ALPHABET = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
M.NONE = "."
M.STEP = 0.5

local function rethrow(ok, err)
    if not ok and err == "Terminated" then error("Terminated", 0) end
    return ok, err
end

local function hasDistance(name)
    local ok, methods = pcall(peripheral.getMethods, name)
    if not ok or type(methods) ~= "table" then return false end
    for _, m in ipairs(methods) do
        if m == "distance" then return true end
    end
    return false
end

function M.find()
    local names = peripheral.getNames and peripheral.getNames() or {}
    table.sort(names)
    for _, n in ipairs(names) do
        local tp = tostring(peripheral.getType(n) or "")
        if (tp:find("camera", 1, true) or n:find("camera", 1, true)) and hasDistance(n) then return n end
    end
    return nil
end

function M.encode(d)
    d = tonumber(d)
    if not d or d < 0 then return M.NONE end
    local i = math.min(#M.ALPHABET, math.floor(d / M.STEP) + 1)
    return M.ALPHABET:sub(i, i)
end

function M.decode(ch)
    if ch == nil or ch == M.NONE or ch == "" then return nil end
    local i = M.ALPHABET:find(ch, 1, true)
    if not i then return nil end
    return (i - 1) * M.STEP
end

function M.rayAt(col, row, w, h)
    local x = w > 1 and (-1 + 2 * (col - 1) / (w - 1)) or 0
    local y = h > 1 and (1 - 2 * (row - 1) / (h - 1)) or 0
    return x, y
end

function M.clampSize(w, h)
    w = util.clamp(math.floor(tonumber(w) or 24), 4, M.MAX_W)
    h = util.clamp(math.floor(tonumber(h) or 12), 3, M.MAX_H)
    return w, h
end

local Camera = {}
Camera.__index = Camera

function M.new(ctx)
    local self = setmetatable({}, Camera)
    self.ctx = ctx or {}
    self.log = self.ctx.log
    self.w, self.h = M.clampSize(24, 12)
    self.rows = {}
    self.row = 0
    self.frames = 0
    self.leaseUntil = 0
    self.view = nil
    return self
end

function Camera:name()
    if self.cam and peripheral.isPresent(self.cam) then return self.cam end
    self.cam = M.find()
    return self.cam
end

function Camera:captureRow(row)
    local name = self:name()
    if not name then return false end
    local out = {}
    for col = 1, self.w do
        local x, y = M.rayAt(col, row, self.w, self.h)
        local ok, d = rethrow(pcall(peripheral.call, name, "distance", x, y))
        out[col] = ok and M.encode(d) or M.NONE
    end
    self.rows[row] = table.concat(out)
    return true
end

function Camera:step(now)
    if now >= self.leaseUntil or not self:name() then return false end
    self.row = self.row % self.h + 1
    if self.row == 1 and self.frames > 0 then self.frameAt = now end
    local ok = self:captureRow(self.row)
    if ok and self.row == self.h then
        self.frames = self.frames + 1
        self.lastFrameAt = now
    end
    return ok
end

function Camera:lease(w, h)
    w, h = M.clampSize(w, h)
    if w ~= self.w or h ~= self.h then
        self.w, self.h = w, h
        self.rows = {}
        self.row = 0
    end
    self.leaseUntil = compat.now() + M.LEASE
end

function Camera:report()
    local srv = self.ctx.server
    local out = {
        realm = srv and srv.realm or nil,
        rel = version.label(),
        uptime = math.floor(compat.now()),
        stamp = compat.stamp(),
        camera = self:name(),
        frames = self.frames,
    }
    if srv and srv.reg and srv.reg.list then
        local ok, list = pcall(srv.reg.list, srv.reg)
        if ok and type(list) == "table" then
            local online = 0
            for _, d in ipairs(list) do
                if d.status == "online" then online = online + 1 end
            end
            out.devices, out.online = #list, online
        end
    end
    local name = out.camera
    if name then
        local ok, d = rethrow(pcall(peripheral.call, name, "distance"))
        if ok then out.ahead = tonumber(d) end
    end
    return out
end

function Camera:snapshot()
    local rows = {}
    for r = 1, self.h do rows[r] = self.rows[r] end
    return { ok = true, w = self.w, h = self.h, rows = rows, row = self.row, frames = self.frames, step = M.STEP, report = self:report() }
end

function Camera:handle(msg)
    local srv = self.ctx.server
    local n = self.ctx.node or (srv and srv.node)
    if not n or not msg.rq then return end
    if not (srv and srv.isServerAddress and srv:isServerAddress(msg.src)) then
        n:reply(msg, { ok = false, err = "denied" })
        return
    end
    local b = type(msg.data) == "table" and msg.data or {}
    if b.op ~= "view" then
        n:reply(msg, { ok = false, err = "bad_request" })
        return
    end
    if not self:name() then
        n:reply(msg, { ok = false, err = "no_camera", report = self:report() })
        return
    end
    self:lease(b.w, b.h)
    n:reply(msg, self:snapshot())
end

function Camera:start()
    local srv = self.ctx.server
    local n = self.ctx.node or (srv and srv.node)
    if not n then return end
    self.node = n
    n:listen(M.PORT, function(msg) self:handle(msg) end)
    n:spawn(function()
        while true do
            local did = false
            local ok, res = pcall(self.step, self, compat.now())
            if ok then did = res else
                if self.log then self.log.warn("camera: " .. tostring(res)) end
            end
            compat.sleep(did and 0 or 1)
        end
    end, "camera")
end

function Camera:fetch(realm, w, h)
    local srv = self.ctx.server
    if not realm or (srv and realm == srv.realm) then
        if not self:name() then return { ok = false, err = "no_camera", report = self:report() } end
        self:lease(w, h)
        return self:snapshot()
    end
    local reply, err = self.node:request(realm, M.PORT, { op = "view", w = w, h = h }, M.TIMEOUT, { retries = 0 })
    if type(reply) ~= "table" then return { ok = false, err = tostring(err or "no reply") } end
    return reply
end

function Camera:startView(realm, w, h)
    self:stopView()
    local view = { realm = realm, w = w, h = h, status = "connecting", started = compat.now(), polls = 0 }
    self.view = view
    local function redraw() os.queueEvent("zn_panel") end
    view.task = self.node:spawn(function()
        while self.view == view do
            local res = self:fetch(realm, view.w, view.h)
            if self.view ~= view then break end
            view.polls = view.polls + 1
            view.at = compat.now()
            if res.ok then
                view.frame = res
                view.status = "live"
                view.err = nil
            else
                view.err = tostring(res.err)
                view.status = res.err == "no_camera" and "no camera" or "no answer"
                if res.report then view.report = res.report end
            end
            if res.report then view.report = res.report end
            redraw()
            compat.sleep(M.POLL)
        end
    end, "camera-view")
    redraw()
    return true
end

function Camera:stopView()
    local v = self.view
    self.view = nil
    if v and v.task then v.task.dead = true end
    os.queueEvent("zn_panel")
end

return M
