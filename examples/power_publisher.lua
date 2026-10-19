local zn = dofile("/zelnet")
assert(zn.open())

local TOPIC = "power." .. zn.realm():lower()
local INTERVAL = 10

local STORED = { "getEnergyStored", "getEUStored", "getEnergy", "getStored" }
local CAPACITY = { "getMaxEnergyStored", "getEUCapacity", "getMaxEnergy", "getCapacity" }

local function readNumber(name, list)
    local methods = {}
    for _, m in ipairs(peripheral.getMethods(name) or {}) do methods[m] = true end
    for _, m in ipairs(list) do
        if methods[m] then
            for _, args in ipairs({ {}, { "unknown" } }) do
                local ok, v = pcall(peripheral.call, name, m, unpack(args))
                if ok and type(v) == "number" then return v end
            end
        end
    end
    return nil
end

local GROUPS = {
    { key = "cells", prefix = "cofh_thermalexpansion_energycell", unit = "RF" },
    { key = "solar", prefix = "advanced_solar_generator", unit = "EU" },
}

local last = {}

local function sample()
    local now = os.clock()
    local report = { t = os.day() * 24 + os.time() }
    for _, g in ipairs(GROUPS) do
        local stored, capacity, count = 0, 0, 0
        for _, name in ipairs(peripheral.getNames()) do
            local ptype = peripheral.getType(name) or ""
            if ptype:sub(1, #g.prefix) == g.prefix or name:sub(1, #g.prefix) == g.prefix then
                local s, c = readNumber(name, STORED), readNumber(name, CAPACITY)
                if s and c then
                    stored = stored + s
                    capacity = capacity + c
                    count = count + 1
                end
            end
        end
        local prev = last[g.key]
        local rate = 0
        if prev and now > prev.t then rate = (stored - prev.stored) / ((now - prev.t) * 20) end
        last[g.key] = { t = now, stored = stored }
        report[g.key] = { stored = stored, capacity = capacity, rate = rate, devices = count, unit = g.unit }
    end
    return report
end

zn.run(function()
    pcall(zn.register, "powermon")
    print("Publishing " .. TOPIC .. " every " .. INTERVAL .. " s from " .. zn.address())
    while true do
        local report = sample()
        local ok, err = zn.publish(TOPIC, report, { retain = true })
        if not ok then print("publish failed: " .. tostring(err)) end
        sleep(INTERVAL)
    end
end)
