local need = ...
local util = need("util")

local M = {}

M.SCALE = 0.5
M.STATION = "Athena"
M.SIZE = 49
M.SIDE_MIN = 18
M.SIDE_MAX = 36
M.GAP = 3

M.ZONES = {
    { group = "Athena", label = "1", rects = { { -1, 9, 1, 29 } }, callout = { 6, 19 } },
    { group = "Athena2", label = "2", rects = { { -1, -29, 1, -9 } }, callout = { 6, -19 } },
    { group = "Athena3", label = "3", rects = { { -29, -1, -9, 1 } }, callout = { -19, -6 } },
    { group = "Athena4", label = "4", rects = { { 9, -1, 29, 1 } }, callout = { 19, -6 } },
    { group = "Athena5", label = "5", rects = { { 17, -41, 41, -39 }, { 39, -38, 41, -17 } }, callout = { 28, -33 } },
    { group = "Athena6", label = "6", rects = { { -41, 17, -39, 38 }, { -41, 39, -17, 41 } }, callout = { -28, 33 } },
    { group = "Athena7", label = "7", rects = { { 39, 17, 41, 38 }, { 17, 39, 41, 41 } }, callout = { 28, 33 } },
    { group = "Athena8", label = "8", rects = { { -41, -41, -17, -39 }, { -41, -38, -39, -17 } }, callout = { -28, -33 } },
}

M.COMMONS = {
    { id = "hub", name = "Hub", at = { 0, 0 }, doors = { "Athena-A", "Athena2-A", "Athena3-A", "Athena4-A" } },
    { id = "north", name = "North", at = { 0, -40 }, doors = { "Athena2-B", "Athena5-B", "Athena8-B" } },
    { id = "south", name = "South", at = { 0, 40 }, doors = { "Athena-B", "Athena6-A", "Athena7-A" } },
    { id = "west", name = "West", at = { -40, 0 }, doors = { "Athena3-B", "Athena6-B", "Athena8-A" } },
    { id = "east", name = "East", at = { 40, 0 }, doors = { "Athena4-B", "Athena5-A", "Athena7-B" } },
}

M.DOORS = {
    ["Athena-A"] = { 2, 9 }, ["Athena-B"] = { 2, 29 },
    ["Athena2-A"] = { -2, -9 }, ["Athena2-B"] = { -2, -29 },
    ["Athena3-A"] = { -9, 2 }, ["Athena3-B"] = { -29, 2 },
    ["Athena4-A"] = { 9, -2 }, ["Athena4-B"] = { 29, -2 },
    ["Athena5-A"] = { 42, -17 }, ["Athena5-B"] = { 17, -42 },
    ["Athena6-A"] = { -17, 42 }, ["Athena6-B"] = { -42, 17 },
    ["Athena7-A"] = { 17, 42 }, ["Athena7-B"] = { 42, 17 },
    ["Athena8-A"] = { -42, -17 }, ["Athena8-B"] = { -17, -42 },
}

local function rotate(x, z, k)
    for _ = 1, k % 4 do x, z = -z, x end
    return x, z
end

local geometry

function M.geometry()
    if geometry then return geometry end
    local HUB, HALL, ROOM_HALF, ROOM_IN, ROOM_OUT, LINK = 7, 2, 15, 31, 49, 40
    local grid = {}
    local function addArm(x1, z1, x2, z2)
        for k = 0, 3 do
            local ax, az = rotate(x1, z1, k)
            local bx, bz = rotate(x2, z2, k)
            for x = math.min(ax, bx), math.max(ax, bx) do
                grid[x] = grid[x] or {}
                for z = math.min(az, bz), math.max(az, bz) do grid[x][z] = true end
            end
        end
    end
    addArm(-HUB, -HUB, HUB, HUB)
    addArm(-HALL, -ROOM_IN, HALL, -HUB)
    addArm(-ROOM_HALF, -ROOM_OUT, ROOM_HALF, -ROOM_IN)
    addArm(ROOM_HALF, -LINK - HALL, LINK + HALL, -LINK + HALL)
    addArm(LINK - HALL, -LINK - HALL, LINK + HALL, -ROOM_HALF)
    local function inside(x, z) return grid[x] ~= nil and grid[x][z] == true end
    local n = M.SIZE
    local cells = {}
    for z = -n, n do
        local row = {}
        for x = -n, n do
            local t = 0
            if inside(x, z) then
                t = 1
                for dx = -1, 1 do
                    for dz = -1, 1 do
                        if not inside(x + dx, z + dz) then t = 2 end
                    end
                end
            end
            row[x + n + 1] = t
        end
        cells[z + n + 1] = row
    end
    local area = {}
    for z = 1, 2 * n + 1 do area[z] = {} end
    local function setArea(x, z, id)
        local row = cells[z + n + 1]
        if row and row[x + n + 1] == 1 then area[z + n + 1][x + n + 1] = id end
    end
    for i, zone in ipairs(M.ZONES) do
        for _, r in ipairs(zone.rects) do
            for x = r[1], r[3] do
                for z = r[2], r[4] do setArea(x, z, "z" .. i) end
            end
        end
    end
    for _, c in ipairs(M.COMMONS) do
        local stack = { { c.at[1], c.at[2] } }
        while #stack > 0 do
            local p = table.remove(stack)
            local x, z = p[1], p[2]
            local row = cells[z + n + 1]
            if row and row[x + n + 1] == 1 and area[z + n + 1][x + n + 1] == nil then
                area[z + n + 1][x + n + 1] = c.id
                stack[#stack + 1] = { x + 1, z }
                stack[#stack + 1] = { x - 1, z }
                stack[#stack + 1] = { x, z + 1 }
                stack[#stack + 1] = { x, z - 1 }
            end
        end
    end
    geometry = { cells = cells, area = area, n = n, size = 2 * n + 1 }
    return geometry
end

function M.layout(mapW, mapH)
    local g = M.geometry()
    local size = g.size
    local out = {}
    for row = 1, mapH do
        local z0 = math.floor((row - 1) * size / mapH) + 1
        local z1 = math.max(z0, math.floor(row * size / mapH))
        local line = {}
        for col = 1, mapW do
            local x0 = math.floor((col - 1) * size / mapW) + 1
            local x1 = math.max(x0, math.floor(col * size / mapW))
            local walls, floors, counts, best, bestN = 0, 0, {}, nil, 0
            for z = z0, z1 do
                local crow, arow = g.cells[z], g.area[z]
                for x = x0, x1 do
                    local t = crow[x]
                    if t == 2 then
                        walls = walls + 1
                    elseif t == 1 then
                        floors = floors + 1
                        local id = arow[x]
                        if id then
                            local k = (counts[id] or 0) + 1
                            counts[id] = k
                            if k > bestN then best, bestN = id, k end
                        end
                    end
                end
            end
            if floors > 0 and floors > walls and best then
                line[col] = best
            elseif walls > 0 then
                line[col] = "#"
            else
                line[col] = false
            end
        end
        out[row] = line
    end
    return out
end

function M.toCell(x, z, mapW, mapH)
    local size = M.SIZE * 2 + 1
    local col = math.floor((x + M.SIZE + 0.5) * mapW / size) + 1
    local row = math.floor((z + M.SIZE + 0.5) * mapH / size) + 1
    return util.clamp(col, 1, mapW), util.clamp(row, 1, mapH)
end

local function zoneCenter(zone)
    local best, bestN = nil, -1
    for _, r in ipairs(zone.rects) do
        local n = (r[3] - r[1] + 1) * (r[4] - r[2] + 1)
        if n > bestN then best, bestN = r, n end
    end
    return math.floor((best[1] + best[3]) / 2), math.floor((best[2] + best[4]) / 2)
end

local function doorState(rec)
    if not rec then return "missing" end
    if not rec.online then return "offline" end
    if rec.locked then return "locked" end
    if rec.sealed then return "sealed" end
    return "open"
end

local ENGINE = { lost = "breach", pending = "settling", holding = "ok" }

function M.status(list, contain, areas)
    local by = {}
    for _, r in ipairs(list or {}) do
        if type(r.name) == "string" then by[r.name:lower()] = r end
    end
    local st = { zones = {}, commons = {}, doors = {}, counts = { open = 0, sealed = 0, locked = 0, offline = 0, missing = 0 }, alerts = {}, breach = 0, unknown = 0 }
    for i, zone in ipairs(M.ZONES) do
        local sensor = by[(zone.group .. "-C"):lower()]
        local s
        if not sensor or sensor.oxygenated == nil then
            s = "nodata"
        elseif sensor.oxygenated == false then
            s = "breach"
        elseif not sensor.online then
            s = "offline"
        else
            s = "ok"
        end
        local eng = areas and areas.zones and areas.zones[zone.group]
        if eng and s ~= "nodata" and s ~= "offline" then s = ENGINE[eng] or s end
        local shut = true
        for _, L in ipairs({ "A", "B" }) do
            local d = by[(zone.group .. "-" .. L):lower()]
            if not d or not (d.sealed or d.locked) then shut = false end
        end
        st.zones[i] = { state = s, shut = shut, sensor = sensor }
        if s == "breach" then
            st.breach = st.breach + 1
            st.alerts[#st.alerts + 1] = { text = "Zone " .. zone.label .. " no oxygen", kind = "breach" }
        elseif s ~= "ok" and s ~= "settling" then
            st.unknown = st.unknown + 1
        end
    end
    for i, c in ipairs(M.COMMONS) do
        local any, low, live = false, false, false
        for _, name in ipairs(c.doors) do
            local d = by[name:lower()]
            if d and d.oxygenated ~= nil then
                any = true
                if d.oxygenated == false then low = true end
                if d.online then live = true end
            end
        end
        local s = low and "breach" or (not any and "nodata") or (not live and "offline") or "ok"
        local eng = areas and areas.commons and areas.commons[c.id]
        if eng and s ~= "nodata" and s ~= "offline" then s = ENGINE[eng] or s end
        st.commons[i] = { state = s }
        if s == "breach" then
            st.breach = st.breach + 1
            st.alerts[#st.alerts + 1] = { text = c.name .. " no oxygen", kind = "breach" }
        elseif s ~= "ok" and s ~= "settling" then
            st.unknown = st.unknown + 1
        end
    end
    for name in pairs(M.DOORS) do
        local ds = doorState(by[name:lower()])
        st.doors[name] = ds
        st.counts[ds] = st.counts[ds] + 1
    end
    for _, zone in ipairs(M.ZONES) do
        for _, L in ipairs({ "A", "B", "C" }) do
            local nm = zone.group .. "-" .. L
            local r = by[nm:lower()]
            if r and not r.online then
                st.alerts[#st.alerts + 1] = { text = nm .. " offline", kind = "offline" }
            elseif not r then
                st.alerts[#st.alerts + 1] = { text = nm .. " missing", kind = "missing" }
            end
        end
    end
    local settling = false
    for _, z in ipairs(st.zones) do if z.state == "settling" then settling = true end end
    for _, c in ipairs(st.commons) do if c.state == "settling" then settling = true end end
    st.contain = nil
    for _, c in ipairs(contain or {}) do
        if c.station == M.STATION then st.contain = c end
    end
    if st.breach > 0 then
        st.overall = "breach"
    elseif st.contain and st.contain.manual then
        st.overall = "lockdown"
    elseif st.contain and st.contain.hold then
        st.overall = "held"
    elseif st.contain then
        st.overall = "contain"
    elseif settling then
        st.overall = "settling"
    elseif st.unknown > 0 then
        st.overall = "partial"
    else
        st.overall = "sealed"
    end
    return st
end

function M.colors(frame)
    return {
        outside = colors.black, wall = colors.gray, zone = colors.lime, common = colors.green,
        breach = frame == 1 and colors.orange or colors.red, nodata = colors.purple, offline = colors.lightGray, settling = colors.cyan,
        open = colors.white, sealed = colors.yellow, locked = colors.magenta, missing = colors.black,
        side = colors.black, head = colors.blue,
    }
end

local function areaColor(pal, kind, s)
    if s == "breach" then return pal.breach end
    if s == "nodata" then return pal.nodata end
    if s == "offline" then return pal.offline end
    if s == "settling" then return pal.settling end
    return kind == "zone" and pal.zone or pal.common
end

function M.frame(w, h)
    local mapW = math.min(math.floor(h * 1.5 + 0.5), w - M.SIDE_MIN)
    local spare = w - mapW
    local gap = spare >= M.SIDE_MIN + M.GAP and M.GAP or 0
    local sideW = math.min(M.SIDE_MAX, spare - gap)
    return { sideX = 1, sideW = sideW, mapX = w - mapW + 1, mapW = mapW }
end

local function shifted(surf, dx)
    return {
        h = surf.h,
        rect = function(_, x, ...) return surf:rect(x + dx, ...) end,
        text = function(_, x, ...) return surf:text(x + dx, ...) end,
        field = function(_, x, ...) return surf:field(x + dx, ...) end,
    }
end

local OVERALL = {
    sealed = { "ALL SEALED", "every area holds O2" },
    breach = { "BREACH", "zone sealed off" },
    contain = { "CONTAINMENT", "doors settling" },
    held = { "HELD SHUT", "release at console" },
    lockdown = { "LOCKDOWN", "release at console" },
    partial = { "SEALED", "some areas no data" },
    settling = { "SETTLING", "checking an area" },
}

local function fmtAge(s)
    s = math.floor(tonumber(s) or 0)
    if s < 60 then return s .. "s" end
    if s < 3600 then return math.floor(s / 60) .. "m" .. string.format("%02d", s % 60) .. "s" end
    return math.floor(s / 3600) .. "h" .. string.format("%02d", math.floor(s / 60) % 60) .. "m"
end

local function stateWord(s)
    if s == "ok" then return "SEALED" end
    if s == "breach" then return "BREACH" end
    if s == "offline" then return "OFFLINE" end
    if s == "settling" then return "SETTLING" end
    return "NO DATA"
end

function M.drawSide(surf, sideW, st, info, pal, frame)
    local h = surf.h
    surf:rect(1, 1, sideW, h, pal.side)
    surf:rect(1, 1, sideW, 2, pal.head)
    surf:field(1, 1, sideW, "STATION ATHENA", colors.white, pal.head, "center")
    surf:field(1, 2, sideW, "NAVMAP " .. tostring(info.release or ""), colors.lightBlue, pal.head, "center")
    local o = OVERALL[st.overall] or OVERALL.partial
    local bc = colors.green
    if st.overall == "breach" or st.overall == "held" or st.overall == "lockdown" then bc = pal.breach
    elseif st.overall == "contain" then bc = colors.orange
    elseif st.overall == "partial" then bc = colors.purple
    elseif st.overall == "settling" then bc = colors.cyan end
    surf:rect(1, 4, sideW, 5, bc)
    local fg = (bc == colors.orange or bc == colors.yellow) and colors.black or colors.white
    if st.overall == "breach" then
        surf:field(1, 5, sideW, frame == 1 and "!! !! !! !!" or " !! !! !! ", fg, bc, "center")
    end
    surf:field(1, 6, sideW, o[1], fg, bc, "center")
    surf:field(1, 7, sideW, o[2], fg, bc, "center")
    local y = 10
    if info.clock then
        surf:field(2, y, sideW - 2, info.clock, colors.lightGray, pal.side)
        y = y + 2
    end
    local function title(text)
        surf:field(1, y, sideW, " " .. text, colors.black, colors.lightGray)
        y = y + 1
    end
    local function line(left, right, color)
        if y > h then return end
        local rw = #right
        surf:field(2, y, sideW - 2 - rw, left, colors.white, pal.side)
        surf:field(sideW - rw, y, rw, right, color, pal.side)
        y = y + 1
    end
    local function stateColor(s)
        if s == "ok" then return colors.lime end
        if s == "breach" then return pal.breach end
        if s == "offline" then return colors.lightGray end
        if s == "settling" then return colors.cyan end
        return colors.purple
    end
    title("ZONES")
    for i, zone in ipairs(M.ZONES) do
        local z = st.zones[i]
        line(zone.label .. " " .. zone.group, stateWord(z.state), stateColor(z.state))
    end
    y = y + 1
    title("COMMON AREAS")
    for i, c in ipairs(M.COMMONS) do
        local s = st.commons[i].state
        line(c.name, stateWord(s), stateColor(s))
    end
    y = y + 1
    title("DOORS")
    line("Open", tostring(st.counts.open), colors.white)
    line("Sealed", tostring(st.counts.sealed), colors.yellow)
    line("Locked", tostring(st.counts.locked), colors.magenta)
    line("Offline", tostring(st.counts.offline + st.counts.missing), (st.counts.offline + st.counts.missing) > 0 and colors.orange or colors.lightGray)
    y = y + 1
    title("LOCKDOWN")
    if st.contain then
        line("Since", fmtAge(st.contain.age), colors.orange)
        line("Cause", util.fitText(tostring(st.contain.cause or "?"), sideW - 9), colors.orange)
        if st.contain.hold then line("Held", "console", pal.breach) end
    else
        line("Status", "clear", colors.lime)
    end
    y = y + 1
    local legendTop = h - 7
    title("ALERTS")
    local shown = 0
    for _, a in ipairs(st.alerts) do
        if y >= legendTop - 1 then break end
        local color = a.kind == "breach" and pal.breach or (a.kind == "offline" and colors.orange or colors.lightGray)
        surf:field(2, y, sideW - 2, a.text, color, pal.side)
        y = y + 1
        shown = shown + 1
    end
    if shown < #st.alerts and y < legendTop then
        surf:field(2, y, sideW - 2, "+" .. (#st.alerts - shown) .. " more", colors.lightGray, pal.side)
    elseif #st.alerts == 0 then
        surf:field(2, y, sideW - 2, "none", colors.lime, pal.side)
    end
    if legendTop > y then
        local items = {
            { pal.common, "area sealed" }, { pal.breach, "no oxygen" }, { colors.cyan, "settling" }, { colors.purple, "no data" },
            { colors.white, "door open" }, { colors.yellow, "door sealed" }, { colors.magenta, "door locked" },
        }
        for i, it in ipairs(items) do
            local yy = legendTop + i
            if yy <= h then
                surf:rect(2, yy, 2, 1, it[1])
                surf:field(5, yy, sideW - 5, it[2], colors.lightGray, pal.side)
            end
        end
    end
end

function M.drawMap(surf, x0, mapW, st, lay, pal, frame)
    local h = surf.h
    local zoneIx = {}
    for i in ipairs(M.ZONES) do zoneIx["z" .. i] = i end
    local commonIx = {}
    for i, c in ipairs(M.COMMONS) do commonIx[c.id] = i end
    local fills = {}
    for i in ipairs(M.ZONES) do fills["z" .. i] = areaColor(pal, "zone", st.zones[i].state) end
    for i, c in ipairs(M.COMMONS) do fills[c.id] = areaColor(pal, "common", st.commons[i].state) end
    for row = 1, h do
        local line = lay[row]
        for col = 1, mapW do
            local a = line[col]
            local bg
            if a == false then bg = pal.outside
            elseif a == "#" then bg = pal.wall
            else bg = fills[a] or pal.nodata end
            surf.fb[(row - 1) * surf.w + x0 + col - 1] = bg
        end
    end
    for name, pos in pairs(M.DOORS) do
        local col, row = M.toCell(pos[1], pos[2], mapW, h)
        local ds = st.doors[name]
        local bg = pal[ds] or pal.missing
        local ch = ds == "missing" and "?" or (ds == "offline" and "x" or " ")
        surf:text(x0 + col - 1, row, ch, colors.white, bg)
    end
    for i, zone in ipairs(M.ZONES) do
        local cx, cz = zoneCenter(zone)
        local col, row = M.toCell(cx, cz, mapW, h)
        local z = st.zones[i]
        local bg = fills["z" .. i]
        local fg = z.state == "breach" and colors.white or colors.black
        surf:text(x0 + col - 1, row, zone.label, fg, bg)
    end
    for i, c in ipairs(M.COMMONS) do
        local col, row = M.toCell(c.at[1], c.at[2], mapW, h)
        local s = st.commons[i].state
        local text = c.name:upper()
        local bg = fills[c.id]
        local fg = s == "breach" and colors.white or colors.black
        surf:text(x0 + col - 1 - math.floor(#text / 2), row, text, fg, bg)
        if s == "breach" and frame == 1 then
            surf:text(x0 + col - 1 - 3, row + 2, "BREACH", colors.white, bg)
        end
    end
    for i, zone in ipairs(M.ZONES) do
        if st.zones[i].state == "breach" then
            local col, row = M.toCell(zone.callout[1], zone.callout[2], mapW, h)
            local text = frame == 1 and (" ZONE " .. zone.label .. " BREACH ") or (" ! ZONE " .. zone.label .. " ! ")
            local w = 16
            local left = util.clamp(x0 + col - 1 - math.floor(w / 2), x0, x0 + mapW - w)
            local top = util.clamp(row - 1, 1, h - 2)
            local box = frame == 1 and colors.red or colors.white
            local fg = frame == 1 and colors.white or colors.red
            surf:rect(left, top, w, 3, box)
            surf:field(left, top + 1, w, text, fg, box, "center")
        end
    end
end

function M.draw(surf, list, contain, info)
    info = info or {}
    local areas = info.areas
    local frame = info.frame or 0
    surf:begin()
    if not surf.isColor then
        surf:field(1, 1, surf.w, "Navmap needs an advanced monitor.", colors.white, colors.black)
        return nil
    end
    local st = M.status(list, contain, areas)
    local pal = M.colors(frame)
    local fr = M.frame(surf.w, surf.h)
    local mapW = fr.mapW
    if mapW < 20 then
        surf:field(1, 1, surf.w, "Navmap needs a 6x5 monitor.", colors.white, colors.black)
        return st
    end
    if not surf.navLayout or surf.navLayout.w ~= mapW or surf.navLayout.h ~= surf.h then
        surf.navLayout = { w = mapW, h = surf.h, rows = M.layout(mapW, surf.h) }
    end
    M.drawSide(shifted(surf, fr.sideX - 1), fr.sideW, st, info, pal, frame)
    M.drawMap(surf, fr.mapX, mapW, st, surf.navLayout.rows, pal, frame)
    return st
end

return M
