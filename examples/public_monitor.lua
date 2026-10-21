local TOPIC = "reactor.*"
local MODEM = "top"

rednet.open(MODEM)
local gw = rednet.lookup("zelnet")
while not gw do
    print("No ZelNet gateway in range, trying again...")
    sleep(10)
    gw = rednet.lookup("zelnet")
end
rednet.send(gw, { op = "subscribe", topic = TOPIC }, "zelnet")

local timer = os.startTimer(3600)
while true do
    local ev, a, b, c = os.pullEvent()
    if ev == "rednet_message" and c == "zelnet" and type(b) == "table" then
        if b.type == "topic" then
            term.clear()
            term.setCursorPos(1, 1)
            print(b.topic .. " from " .. tostring(b.from))
            if type(b.data) == "table" then
                for k, v in pairs(b.data) do print("  " .. tostring(k) .. ": " .. tostring(v)) end
            else
                print("  " .. tostring(b.data))
            end
        elseif b.type == "error" then
            print("Gateway error: " .. tostring(b.error) .. " " .. tostring(b.message or ""))
        end
    elseif ev == "timer" and a == timer then
        rednet.send(gw, { op = "subscribe", topic = TOPIC }, "zelnet")
        timer = os.startTimer(3600)
    end
end
