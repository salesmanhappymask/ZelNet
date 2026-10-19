local zn = dofile("/zelnet")
assert(zn.open())

local ui = zn.uikit()
local util = zn.util

local MONITOR = nil

local reports = {}

local function surface()
    if MONITOR and peripheral.isPresent(MONITOR) then
        return ui.attachMonitor(MONITOR, 0.5)
    end
    return ui.surface(term)
end

local function pct(stored, capacity)
    if not capacity or capacity <= 0 then return 0 end
    return math.max(0, math.min(100, stored / capacity * 100))
end

local function rateText(rate, unit)
    local sign = rate > 0 and "+" or ""
    return sign .. util.fmtFixed(rate, 1) .. " " .. unit .. "/t"
end

local function draw(surf)
    local page = ui.page(surf)
    local c = page.c
    page:header("Power Across ZelNet")
    local realms = {}
    for realm in pairs(reports) do realms[#realms + 1] = realm end
    table.sort(realms)
    local y = 4
    if #realms == 0 then
        surf:field(2, y, surf.w - 2, "Waiting for power.* reports...", c.muted, c.bg)
    end
    for _, realm in ipairs(realms) do
        local r = reports[realm]
        for _, key in ipairs({ "cells", "solar" }) do
            local g = r.data[key]
            if g and g.devices and g.devices > 0 and y + 4 <= surf.h then
                local ix, iy, iw = page:card(2, y, surf.w - 2, 5, realm .. " " .. key, key == "cells" and colors.green or colors.orange, g.devices .. " devices")
                local p = pct(g.stored, g.capacity)
                page:bar(ix, iy, iw - 8, 1, p, p < 30 and c.bad or (p < 70 and c.warn or c.ok))
                surf:text(ix + iw - 6, iy, util.fmtFixed(p, 1) .. "%", c.text, c.inset)
                page:kv(ix, iy + 1, iw, util.fmtAmount(g.stored) .. " / " .. util.fmtAmount(g.capacity) .. " " .. g.unit, rateText(g.rate or 0, g.unit), (g.rate or 0) < 0 and c.bad or c.ok)
                y = y + 6
            end
        end
    end
    surf:flush()
end

zn.subscribe("power.*", function(topic, data, src)
    local realm = (src or "?"):match("^([^:]+)") or "?"
    reports[realm] = { data = data, src = src, at = os.clock() }
    os.queueEvent("power_update")
end)

zn.run(function()
    local surf = surface()
    draw(surf)
    local timer = os.startTimer(5)
    while true do
        local ev, a = os.pullEvent()
        if ev == "power_update" or (ev == "timer" and a == timer) then
            if ev == "timer" then timer = os.startTimer(5) end
            draw(surf)
        elseif ev == "monitor_resize" or ev == "term_resize" then
            surf:resize()
            draw(surf)
        end
    end
end)
