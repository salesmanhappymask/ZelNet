local TOPIC = "reactor.main"
local MODEM = "top"
local DEVICE = "back"
local INTERVAL = 10

rednet.open(MODEM)
local gw = rednet.lookup("zelnet")
while not gw do
    print("No ZelNet gateway in range, trying again...")
    sleep(10)
    gw = rednet.lookup("zelnet")
end
print("Publishing " .. TOPIC .. " through gateway " .. gw)

local function reading()
    local dev = peripheral.wrap(DEVICE)
    if not dev then return { online = false } end
    local data = { online = true }
    for _, name in ipairs({ "getHeat", "getEnergyStored", "getMaxEnergyStored", "getEnergyProducedLastTick", "getActive" }) do
        if dev[name] then
            local ok, value = pcall(dev[name])
            if ok then data[name] = value end
        end
    end
    return data
end

while true do
    rednet.send(gw, { op = "publish", topic = TOPIC, data = reading() }, "zelnet")
    sleep(INTERVAL)
end
