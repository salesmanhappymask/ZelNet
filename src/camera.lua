local need = ...
local compat = need("compat")
local util = need("util")
local version = need("version")

local M = {}

M.PORT = "zn.cam"
M.LEASE = 30
M.POLL = 2
M.TIMEOUT = 40
M.MAX_W = 48
M.MAX_H = 30
M.UNSEEN = "__"
M.STRIDES = { 8, 4, 2, 1 }
M.BATCH = 8
M.ALPHABET = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
M.NONE = ".."
M.STEP = 0.01
M.OLD_STEP = 0.5
M.CW = 2

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
    local n = #M.ALPHABET
    local i = math.min(n * n - 1, math.floor(d / M.STEP + 0.5))
    local hi, lo = math.floor(i / n) + 1, i % n + 1
    return M.ALPHABET:sub(hi, hi) .. M.ALPHABET:sub(lo, lo)
end

function M.decode(code)
    if type(code) ~= "string" or code == "" or code:find("^[%._]+$") then return nil end
    if #code == 1 then
        local i = M.ALPHABET:find(code, 1, true)
        return i and (i - 1) * M.OLD_STEP or nil
    end
    local hi, lo = M.ALPHABET:find(code:sub(1, 1), 1, true), M.ALPHABET:find(code:sub(2, 2), 1, true)
    if not hi or not lo then return nil end
    return ((hi - 1) * #M.ALPHABET + (lo - 1)) * M.STEP
end

function M.rayAt(col, row, w, h)
    local x = w > 1 and (-1 + 2 * (col - 1) / (w - 1)) or 0
    local y = h > 1 and (1 - 2 * (row - 1) / (h - 1)) or 0
    return x, y
end

function M.scanOrder(w, h)
    local order, seen = {}, {}
    for _, st in ipairs(M.STRIDES) do
        for r = 1, h, st do
            for c = 1, w, st do
                local k = (r - 1) * w + c
                if not seen[k] then
                    seen[k] = true
                    order[#order + 1] = k
                end
            end
        end
    end
    return order
end

function M.passOf(w, h, pos)
    local count, seen = 0, {}
    for _, st in ipairs(M.STRIDES) do
        for r = 1, h, st do
            for c = 1, w, st do
                local k = (r - 1) * w + c
                if not seen[k] then
                    seen[k] = true
                    count = count + 1
                end
            end
        end
        if pos <= count then return st end
    end
    return 1
end

function M.cellAt(f, c, r)
    local cw = tonumber(f.cw) or 1
    local line = f.rows and f.rows[r]
    local ch = line and line:sub((c - 1) * cw + 1, c * cw) or ""
    if ch == "" or ch:find("^_+$") then return nil end
    return ch
end

local function valueAt(f, c, r)
    local ch = M.cellAt(f, c, r)
    if not ch then return nil end
    return M.decode(ch) or -1
end

function M.filled(f)
    local grid = {}
    local real = {}
    local any = false
    for r = 1, f.h do
        local row = {}
        real[r] = {}
        for c = 1, f.w do
            local v = valueAt(f, c, r)
            if v ~= nil then
                real[r][c] = true
            else
                local near
                for k = #M.STRIDES - 1, 1, -1 do
                    local st = M.STRIDES[k]
                    local ac, ar = math.floor((c - 1) / st) * st + 1, math.floor((r - 1) / st) * st + 1
                    local v00 = valueAt(f, ac, ar)
                    if v00 ~= nil then
                        near = near or v00
                        local bc, br = math.min(f.w, ac + st), math.min(f.h, ar + st)
                        local v10, v01, v11 = valueAt(f, bc, ar), valueAt(f, ac, br), valueAt(f, bc, br)
                        if v10 ~= nil and v01 ~= nil and v11 ~= nil then
                            v = v00
                            if v00 >= 0 and v10 >= 0 and v01 >= 0 and v11 >= 0 then
                                local lo = math.min(v00, v10, v01, v11)
                                local hi = math.max(v00, v10, v01, v11)
                                if hi - lo <= math.max(1.5, lo * 0.5) then
                                    local tx = bc > ac and (c - ac) / (bc - ac) or 0
                                    local ty = br > ar and (r - ar) / (br - ar) or 0
                                    v = (v00 * (1 - tx) + v10 * tx) * (1 - ty) + (v01 * (1 - tx) + v11 * tx) * ty
                                end
                            end
                            break
                        end
                    end
                end
                if v == nil then v = near end
            end
            if v ~= nil then
                any = true
                row[c] = v
            else
                row[c] = false
            end
        end
        grid[r] = row
    end
    grid.real = real
    return grid, any
end

local function norm(x, y, z)
    local n = math.sqrt(x * x + y * y + z * z)
    if n == 0 then return 0, 0, 0 end
    return x / n, y / n, z / n
end

M.LIGHT = { norm(0.3, 0.85, -0.45) }
M.LEVELS = 10

local function jump(d, q, o, thr)
    if not q then return false end
    local dq = math.abs(q[4] - d)
    if dq <= thr then return false end
    if not o then return true end
    return dq > 2.5 * math.abs(d - o[4]) + thr * 0.5
end

function M.shade(grid, w, h)
    local pts = {}
    for r = 1, h do
        pts[r] = {}
        for c = 1, w do
            local d = grid[r][c]
            if d and d >= 0 then
                local x, y = M.rayAt(c, r, w, h)
                local dx, dy, dz = norm(x, y, 1)
                pts[r][c] = { dx * d, dy * d, dz * d, d }
            end
        end
    end
    local function at(c, r)
        local row = pts[r]
        return row and row[c]
    end
    local lx, ly, lz = M.LIGHT[1], M.LIGHT[2], M.LIGHT[3]
    local out = {}
    for r = 1, h do
        out[r] = {}
        for c = 1, w do
            local p = pts[r][c]
            local g = grid[r][c]
            if g == false then
                out[r][c] = false
            elseif not p then
                out[r][c] = -1
            else
                local d = p[4]
                local thr = math.max(0.6, d * 0.06)
                local R, L, U, D = at(c + 1, r), at(c - 1, r), at(c, r - 1), at(c, r + 1)
                local edge = false
                local real = grid.real
                local here = not real or real[r][c]
                for _, pair in ipairs({ { R, L, c + 1, r }, { L, R, c - 1, r }, { U, D, c, r - 1 }, { D, U, c, r + 1 } }) do
                    local q, o = pair[1], pair[2]
                    local qg = grid[pair[4]] and grid[pair[4]][pair[3]]
                    local both = here and (not real or (real[pair[4]] and real[pair[4]][pair[3]]))
                    if both and q and q[4] > d and jump(d, q, o, thr) then edge = true end
                    if both and not q and qg ~= nil and qg ~= false then edge = true end
                end
                local pr, pl = R, L
                if pr and jump(d, pr, pl, thr) then pr = nil end
                if pl and jump(d, pl, pr, thr) then pl = nil end
                local pu, pd = U, D
                if pu and jump(d, pu, pd, thr) then pu = nil end
                if pd and jump(d, pd, pu, thr) then pd = nil end
                local nx, ny, nz = 0, 0, 0
                if (pr or pl) and (pu or pd) then
                    local a1, a2 = pr or p, pl or p
                    local b1, b2 = pu or p, pd or p
                    local ax, ay, az = a1[1] - a2[1], a1[2] - a2[2], a1[3] - a2[3]
                    local bx, by, bz = b1[1] - b2[1], b1[2] - b2[2], b1[3] - b2[3]
                    nx, ny, nz = norm(ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx)
                end
                local vx, vy, vz = norm(-p[1], -p[2], -p[3])
                if nx == 0 and ny == 0 and nz == 0 then nx, ny, nz = vx, vy, vz end
                if nx * vx + ny * vy + nz * vz < 0 then nx, ny, nz = -nx, -ny, -nz end
                local top = math.max(0, nx * lx + ny * ly + nz * lz)
                local facing = math.max(0, nx * vx + ny * vy + nz * vz)
                local fog = 1 - 0.55 * math.min(1, d / 32)
                local sky = (1 + ny) / 2
                local b = (0.06 + 0.42 * top + 0.3 * facing + 0.24 * sky) * fog
                local level = util.clamp(math.floor(b * M.LEVELS), 0, M.LEVELS - 1)
                if edge then level = 0 end
                out[r][c] = level
            end
        end
    end
    return out
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
    self.cells = {}
    self.order = M.scanOrder(self.w, self.h)
    self.pos = 0
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

function Camera:capture(k)
    local name = self:name()
    if not name then return false end
    local c = (k - 1) % self.w + 1
    local r = math.floor((k - 1) / self.w) + 1
    local x, y = M.rayAt(c, r, self.w, self.h)
    local ok, d = rethrow(pcall(peripheral.call, name, "distance", x, y))
    self.cells[k] = ok and M.encode(d) or M.NONE
    return true
end

function Camera:step(now)
    if now >= self.leaseUntil or not self:name() then return false end
    for _ = 1, M.BATCH do
        if self.pos >= #self.order then
            self.pos = 0
            self.frames = self.frames + 1
            self.lastFrameAt = now
        end
        self.pos = self.pos + 1
        if not self:capture(self.order[self.pos]) then return false end
        if compat.now() >= self.leaseUntil then break end
    end
    return true
end

function Camera:lease(w, h)
    w, h = M.clampSize(w, h)
    if w ~= self.w or h ~= self.h then
        self.w, self.h = w, h
        self.cells = {}
        self.order = M.scanOrder(w, h)
        self.pos = 0
        self.frames = 0
    end
    self.leaseUntil = compat.now() + M.LEASE
end

function Camera:rowsText()
    local rows = {}
    for r = 1, self.h do
        local out = {}
        local base = (r - 1) * self.w
        for c = 1, self.w do out[c] = self.cells[base + c] or M.UNSEEN end
        rows[r] = table.concat(out)
    end
    return rows
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
    local total = #self.order
    local done = self.frames > 0 and total or self.pos
    return {
        ok = true, w = self.w, h = self.h, rows = self:rowsText(), frames = self.frames, step = M.STEP, cw = M.CW,
        done = done, total = total, pass = M.passOf(self.w, self.h, math.max(1, self.pos)), report = self:report(),
    }
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

function Camera:startView(realm, mode)
    self:stopView()
    local view = { realm = realm, mode = mode or "scene", status = "connecting", started = compat.now(), polls = 0 }
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
