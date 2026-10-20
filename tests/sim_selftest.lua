package.path = "./?.lua;" .. package.path

local sim = require("sim.ccsim")

local results = {}
local failures = 0

local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        results[#results + 1] = "PASS " .. name
    else
        failures = failures + 1
        results[#results + 1] = "FAIL " .. name .. ": " .. tostring(err)
    end
    print(results[#results])
end

local function check(cond, msg)
    if not cond then error(msg or "check failed", 2) end
end

local function eq(a, b, msg)
    if a ~= b then error((msg or "values differ") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end

local function newWorld(opts)
    opts = opts or {}
    opts.romPath = opts.romPath or "sim/rom"
    return sim.newWorld(opts)
end

local function waitFile(w, c, path, secs)
    local ok = w:runUntil(function() return c:readFile(path) ~= nil end, secs or 10)
    if not ok and c:lastError() then print("  computer " .. c.id .. " error: " .. c:lastError()) end
    return ok
end

test("boot to shell", function()
    local w = newWorld()
    local c = w:addComputer{ id = 1 }
    c:boot()
    w:run(1)
    local lines = c:screenLines()
    check(lines[1]:find("CraftOS 1.6", 1, true), "banner missing: " .. lines[1])
    check(c:screenText():find("\n>$"), "prompt missing")
    check(c:isOn(), "computer not running")
    eq(#lines, 19, "screen height")
    eq(#lines[1], 51, "screen width")
end)

test("startup file runs and output captured", function()
    local w = newWorld()
    local c = w:addComputer{ id = 2, label = "box", startup = [[
print("hello from startup")
local f = fs.open("result", "w")
f.write(os.getComputerID() .. ":" .. tostring(os.getComputerLabel()))
f.close()
]] }
    c:boot()
    check(waitFile(w, c, "result"), "no result file")
    eq(c:readFile("result"), "2:box")
    check(c:output():find("hello from startup", 1, true), "output not captured")
    check(c:screenText():find("hello from startup", 1, true), "screen missing text")
end)

test("typed input runs a program", function()
    local w = newWorld()
    local c = w:addComputer{ id = 3, files = { hello = 'print("typed ok")' } }
    c:boot()
    w:run(1)
    c:typeLine("hello")
    w:run(1)
    check(c:screenText():find("typed ok", 1, true), "program output missing: " .. c:screenText())
end)

test("mouse click and colors on advanced computer", function()
    local w = newWorld()
    local c = w:addComputer{ id = 4, color = true, startup = [[
term.setTextColor(colors.red)
term.setBackgroundColor(colors.blue)
term.setCursorPos(1, 1)
term.write("R")
local ev, b, x, y = os.pullEvent("mouse_click")
local f = fs.open("click", "w") f.write(b .. "," .. x .. "," .. y) f.close()
]] }
    c:boot()
    w:run(0.5)
    local ch, fg, bg = c:cell(1, 1)
    eq(ch, "R")
    eq(fg, 16384, "text colour")
    eq(bg, 2048, "background colour")
    c:click(5, 7)
    check(waitFile(w, c, "click", 2), "click not received")
    eq(c:readFile("click"), "1,5,7")
end)

test("timers, sleep, clock and world time", function()
    local w = newWorld()
    local c = w:addComputer{ id = 5, startup = [[
local t0 = os.clock()
sleep(2)
local t1 = os.clock()
local a = os.startTimer(0.5)
local b = os.startTimer(1)
os.cancelTimer(a)
local _, id = os.pullEvent("timer")
local f = fs.open("t", "w")
f.write(string.format("%.2f %s %.3f %d", t1 - t0, tostring(id == b), os.time(), os.day()))
f.close()
]] }
    c:boot()
    check(waitFile(w, c, "t", 6), "no timer result")
    local dt, which, tod, day = c:readFile("t"):match("^(%S+) (%S+) (%S+) (%S+)$")
    dt = tonumber(dt)
    check(dt >= 1.95 and dt <= 2.1, "sleep duration " .. dt)
    eq(which, "true", "cancelled timer fired")
    check(tonumber(tod) > 6 and tonumber(tod) < 6.1, "time of day " .. tod)
    eq(day, "1", "day")
end)

test("parallel API", function()
    local w = newWorld()
    local c = w:addComputer{ id = 6, startup = [[
local log = {}
parallel.waitForAll(
  function() sleep(0.2) log[#log + 1] = "a" end,
  function() log[#log + 1] = "b" sleep(0.5) log[#log + 1] = "c" end)
local r = parallel.waitForAny(function() sleep(5) end, function() sleep(0.1) end)
local f = fs.open("p", "w") f.write(table.concat(log) .. r) f.close()
]] }
    c:boot()
    check(waitFile(w, c, "p", 5), "parallel did not finish")
    eq(c:readFile("p"), "bac2")
end)

test("yield-safe pcall, error values and levels", function()
    local w = newWorld()
    local c = w:addComputer{ id = 7, startup = [[
local out = {}
local ok, v = pcall(function()
  return pcall(function()
    local e = os.pullEvent("go")
    return e .. "!"
  end)
end)
out[#out + 1] = tostring(ok) .. tostring(v)
local ok2, e2 = pcall(function() error({ code = 42 }) end)
out[#out + 1] = tostring(ok2) .. type(e2) .. tostring(e2.code)
local ok3, e3 = pcall(function() error("lvl", 0) end)
out[#out + 1] = e3
local function thrower() error("where", 2) end
local ok4, e4 = pcall(function() thrower() end)
out[#out + 1] = tostring(e4:find("startup") ~= nil)
local ok5, e5 = xpcall(function() sleep(0.1) error("x", 0) end, function(m) return "h:" .. m end)
out[#out + 1] = e5
local f = fs.open("e", "w") f.write(table.concat(out, "|")) f.close()
]] }
    c:boot()
    w:run(0.3)
    c:queueEvent("go")
    check(waitFile(w, c, "e", 3), "no result")
    eq(c:readFile("e"), "truetrue|falsetable42|lvl|true|h:x")
end)

local function rednetWorld()
    local w = newWorld()
    local receiver = [[
rednet.open("top")
local got = {}
while true do
  local id, msg, proto = rednet.receive(3)
  if not id then break end
  got[#got + 1] = id .. "=" .. tostring(msg)
end
local f = fs.open("got", "w") f.write(table.concat(got, ",")) f.close()
]]
    local a = w:addComputer{ id = 10, pos = { 0, 64, 0 }, startup = [[
rednet.open("top")
sleep(0.5)
rednet.send(11, "direct")
rednet.broadcast("all")
]] }
    local b = w:addComputer{ id = 11, pos = { 40, 64, 0 }, startup = receiver }
    local far = w:addComputer{ id = 12, pos = { 200, 64, 0 }, startup = receiver }
    local nether = w:addComputer{ id = 13, dim = -1, pos = { 0, 64, 0 }, startup = receiver }
    for _, c in ipairs({ a, b, far, nether }) do
        c:attach("top", w:wirelessModem())
        c:boot()
    end
    return w, a, b, far, nether
end

test("rednet send and broadcast with real ROM rednet", function()
    local w, a, b, far, nether = rednetWorld()
    check(waitFile(w, b, "got", 10), "receiver did not finish")
    eq(b:readFile("got"), "10=direct,10=all")
    check(waitFile(w, far, "got", 10), "far receiver did not finish")
    eq(far:readFile("got"), "", "out of range computer received")
    check(waitFile(w, nether, "got", 10), "nether receiver did not finish")
    eq(nether:readFile("got"), "", "cross dimension delivery")
end)

test("wireless storm range and altitude", function()
    local w = newWorld()
    local rx = [[
local m = peripheral.wrap("top")
m.open(7)
local _, side, ch, reply, msg, dist = os.pullEvent("modem_message")
local f = fs.open("m", "w") f.write(msg .. "@" .. math.floor(dist)) f.close()
]]
    local tx = [[
local m = peripheral.wrap("top")
sleep(0.5)
m.transmit(7, 8, "ping")
]]
    local a = w:addComputer{ id = 20, pos = { 0, 64, 0 }, startup = tx }
    local b = w:addComputer{ id = 21, pos = { 30, 64, 0 }, startup = rx }
    a:attach("top", w:wirelessModem())
    b:attach("top", w:wirelessModem())
    w:setStorm(0, true)
    a:boot()
    b:boot()
    w:run(2)
    eq(b:readFile("m"), nil, "storm range should block 30 blocks")
    w:setStorm(0, false)
    a:reboot()
    check(waitFile(w, b, "m", 3), "no message after storm")
    eq(b:readFile("m"), "ping@30")
    local w2 = newWorld()
    local hi = w2:addComputer{ id = 22, pos = { 0, 255, 0 }, startup = tx }
    local lo = w2:addComputer{ id = 23, pos = { 300, 255, 0 }, startup = rx }
    hi:attach("top", w2:wirelessModem())
    lo:attach("top", w2:wirelessModem())
    hi:boot()
    lo:boot()
    check(waitFile(w2, lo, "m", 3), "high altitude message missing")
end)

test("raw modem channels and message copying", function()
    local w = newWorld()
    local a = w:addComputer{ id = 30, pos = { 0, 64, 0 }, startup = [[
local m = peripheral.wrap("left")
sleep(0.5)
m.transmit(5, 6, { a = 1, f = function() end, t = { "x", "y" } })
m.transmit(9, 6, "closed channel")
]] }
    local b = w:addComputer{ id = 31, pos = { 10, 64, 0 }, startup = [[
local m = peripheral.wrap("right")
m.open(5)
local out = {}
local timer = os.startTimer(2)
while true do
  local ev = { os.pullEvent() }
  if ev[1] == "timer" and ev[2] == timer then break end
  if ev[1] == "modem_message" then
    local msg = ev[5]
    out[#out + 1] = ev[2] .. ":" .. ev[3] .. ":" .. ev[4] .. ":" .. tostring(msg.a) .. ":" .. tostring(msg.f) .. ":" .. msg.t[2] .. ":" .. ev[6]
  end
end
local f = fs.open("r", "w") f.write(table.concat(out, ";") .. "|" .. tostring(m.isOpen(5)) .. tostring(m.isOpen(9))) f.close()
]] }
    a:attach("left", w:wirelessModem())
    b:attach("right", w:wirelessModem())
    a:boot()
    b:boot()
    check(waitFile(w, b, "r", 5), "no result")
    eq(b:readFile("r"), "right:5:6:1:nil:y:10|truefalse")
end)

test("wired modem remote peripherals and getNames", function()
    local w = newWorld()
    local mon = w:monitor{ w = 2, h = 1, color = true }
    local cell = w:energyCell{ stored = 1234, max = 5000 }
    local drive = w:diskDrive()
    local c = w:addComputer{ id = 40, startup = [[
sleep(0.2)
local names = peripheral.getNames()
table.sort(names)
local cellName = peripheral.find and nil
local out = { table.concat(names, ",") }
out[#out + 1] = peripheral.getType("monitor_0")
out[#out + 1] = tostring(peripheral.call("cofh_thermalexpansion_energycell_0", "getEnergyStored", "north"))
local m = peripheral.wrap("monitor_0")
m.write("wired!")
local x, y = m.getSize()
out[#out + 1] = x .. "x" .. y
local modem = peripheral.wrap("back")
out[#out + 1] = tostring(modem.isWireless())
out[#out + 1] = tostring(modem.isPresentRemote("drive_0"))
local f = fs.open("w", "w") f.write(table.concat(out, "|")) f.close()
local ev, name = os.pullEvent("peripheral_detach")
f = fs.open("d", "w") f.write(ev .. ":" .. name) f.close()
local ev2, name2 = os.pullEvent("peripheral")
f = fs.open("a", "w") f.write(ev2 .. ":" .. name2) f.close()
]] }
    c:attach("back", w:wiredModem("net"))
    w:connect("net", mon)
    w:connect("net", cell)
    w:connect("net", drive)
    c:boot()
    check(waitFile(w, c, "w", 3), "no result")
    eq(c:readFile("w"), "back,cofh_thermalexpansion_energycell_0,drive_0,monitor_0|monitor|1234|18x5|false|true")
    eq(mon:screenLines()[1]:sub(1, 6), "wired!")
    w:disconnect("net", drive)
    check(waitFile(w, c, "d", 2), "no detach event")
    eq(c:readFile("d"), "peripheral_detach:drive_0")
    w:connect("net", w:diskDrive())
    check(waitFile(w, c, "a", 2), "no attach event")
    eq(c:readFile("a"), "peripheral:drive_1")
end)

test("wired modem messages stay on their cable", function()
    local w = newWorld()
    local rx = [[
local m = peripheral.wrap("back")
m.open(3)
local timer = os.startTimer(1.5)
local out = {}
while true do
  local ev = { os.pullEvent() }
  if ev[1] == "timer" and ev[2] == timer then break end
  if ev[1] == "modem_message" then out[#out + 1] = ev[5] end
end
local f = fs.open("x", "w") f.write(table.concat(out, ",")) f.close()
]]
    local a = w:addComputer{ id = 45, pos = { 0, 64, 0 }, startup = 'sleep(0.3) peripheral.call("back", "transmit", 3, 3, "wire")' }
    local b = w:addComputer{ id = 46, pos = { 5000, 64, 0 }, startup = rx }
    local c = w:addComputer{ id = 47, pos = { 1, 64, 0 }, startup = rx }
    a:attach("back", w:wiredModem("lan1"))
    b:attach("back", w:wiredModem("lan1"))
    c:attach("back", w:wiredModem("lan2"))
    a:boot() b:boot() c:boot()
    check(waitFile(w, b, "x", 3) and waitFile(w, c, "x", 3), "no results")
    eq(b:readFile("x"), "wire")
    eq(c:readFile("x"), "")
end)

test("monitor size formula, scale, touch and resize", function()
    local w = newWorld()
    local m1 = w:monitor{ w = 1, h = 1 }
    local m3 = w:monitor{ w = 3, h = 3, color = true }
    local m8 = w:monitor{ w = 8, h = 6, color = true }
    local c = w:addComputer{ id = 41, startup = [[
local out = {}
local a = peripheral.wrap("left")
out[#out + 1] = table.concat({ a.getSize() }, "x")
local b = peripheral.wrap("right")
b.setTextScale(0.5)
out[#out + 1] = table.concat({ b.getSize() }, "x")
local r = os.pullEvent("monitor_resize")
out[#out + 1] = r
local d = peripheral.wrap("top")
d.setTextScale(0.5)
out[#out + 1] = table.concat({ d.getSize() }, "x")
d.setCursorPos(3, 2)
d.write("touch me")
local f = fs.open("m", "w") f.write(table.concat(out, "|")) f.close()
local _, side, x, y = os.pullEvent("monitor_touch")
f = fs.open("t", "w") f.write(side .. ":" .. x .. ":" .. y) f.close()
]] }
    c:attach("left", m1)
    c:attach("right", m3)
    c:attach("top", m8)
    c:boot()
    check(waitFile(w, c, "m", 3), "no result")
    eq(c:readFile("m"), "7x5|57x38|monitor_resize|164x81")
    eq(m8:screenLines()[2]:sub(1, 10), "  touch me")
    w:touch(m8, 4, 2)
    check(waitFile(w, c, "t", 2), "no touch")
    eq(c:readFile("t"), "top:4:2")
    eq(w:touch(m1, 1, 1), false, "basic monitor should not be touchable")
end)

test("disk drive mount, files, label and free space", function()
    local w = newWorld()
    local drive = w:diskDrive()
    local fl = w:floppy{ label = "data", files = { ["readme"] = "on disk" } }
    local c = w:addComputer{ id = 50, startup = [[
local out = {}
out[#out + 1] = tostring(disk.isPresent("left"))
local _, side = os.pullEvent("disk")
out[#out + 1] = side
out[#out + 1] = disk.getMountPath("left")
out[#out + 1] = disk.getLabel("left")
local h = fs.open("disk/readme", "r") out[#out + 1] = h.readAll() h.close()
h = fs.open("disk/new.txt", "w") h.write(string.rep("a", 1000)) h.close()
out[#out + 1] = tostring(fs.getFreeSpace("disk"))
out[#out + 1] = tostring(fs.getFreeSpace("/") > 990000)
disk.setLabel("left", "relabel")
out[#out + 1] = tostring(disk.getID("left"))
local f = fs.open("r", "w") f.write(table.concat(out, "|")) f.close()
os.pullEvent("disk_eject")
f = fs.open("ej", "w") f.write(tostring(fs.exists("disk"))) f.close()
]] }
    c:attach("left", drive)
    c:boot()
    w:run(0.5)
    drive:insert(fl)
    check(waitFile(w, c, "r", 3), "no result")
    eq(c:readFile("r"), "false|left|disk|data|on disk|" .. (125000 - 512 - 512 - 1000) .. "|true|" .. fl.diskId)
    eq(fl:readFile("new.txt"), string.rep("a", 1000))
    eq(fl.label, "relabel")
    local out = drive:remove()
    eq(out, fl)
    check(waitFile(w, c, "ej", 2), "no eject")
    eq(c:readFile("ej"), "false")
    local d2 = w:diskDrive()
    local c2 = w:addComputer{ id = 51 }
    c2:attach("bottom", w:diskDrive())
    c2:attach("top", d2)
    c2:boot()
    c2.sides.bottom:insert(w:floppy{})
    d2:insert(fl)
    w:run(0.2)
    eq(c2:readFile("disk2/new.txt"), string.rep("a", 1000))
end)

test("tesseract floppy shuttle across dimensions", function()
    local w = newWorld()
    local driveA, driveB = w:diskDrive(), w:diskDrive()
    local tA = w:tesseract{ frequency = 7, mode = "both" }
    local tB = w:tesseract{ frequency = 7, mode = "both" }
    tA:adjacent("north", driveA)
    tB:adjacent("south", driveB)
    local fl = w:floppy{ label = "pkt", files = { payload = "cargo" } }
    driveA:insert(fl)
    local a = w:addComputer{ id = 60, dim = 0, startup = [[
local t = peripheral.wrap("right")
local s = peripheral.getType("right") .. "|" .. t.getFrequency() .. "|" .. t.getInventorySize() .. "|" .. t.pullItem("north", 1)
local f = fs.open("ra", "w")
f.write(s)
f.close()
]] }
    local b = w:addComputer{ id = 61, dim = 1, startup = [[
local _, side = os.pullEvent("disk")
local h = fs.open("disk/payload", "r") local data = h.readAll() h.close()
h = fs.open("disk/reply", "w") h.write("back:" .. data) h.close()
local t = peripheral.wrap("left")
local n = t.pullItem("south", 1)
local f = fs.open("rb", "w") f.write(side .. "|" .. data .. "|" .. n) f.close()
]] }
    a:attach("right", tA)
    a:attach("front", driveA)
    b:attach("left", tB)
    b:attach("bottom", driveB)
    a:boot()
    b:boot()
    check(waitFile(w, a, "ra", 3), "A did not pull")
    eq(a:readFile("ra"), "tile_thermalexpansion_tesseract_name|7|1|1")
    check(waitFile(w, b, "rb", 3), "B did not receive")
    eq(b:readFile("rb"), "bottom|cargo|1")
    check(w:runUntil(function() return driveA:disk() == fl end, 3), "disk did not return to A")
    eq(fl:readFile("reply"), "back:cargo")
    eq(driveB:disk(), nil)
end)

test("tesseract failure cases: occupied drive and no receiver", function()
    local w = newWorld()
    local src, dst = w:diskDrive(), w:diskDrive()
    local tA = w:tesseract{ frequency = 3 }
    local tB = w:tesseract{ frequency = 3, mode = "receive" }
    tA:adjacent("up", src)
    tB:adjacent("down", dst)
    local blocker = w:floppy{ label = "blocker" }
    dst:insert(blocker)
    local fl = w:floppy{ label = "x" }
    src:insert(fl)
    local c = w:addComputer{ id = 62, startup = [[
local t = peripheral.wrap("top")
local n = t.pullItem("up", 1)
local f = fs.open("n", "w") f.write(tostring(n)) f.close()
]] }
    c:attach("top", tA)
    c:boot()
    check(waitFile(w, c, "n", 2), "no pull")
    eq(c:readFile("n"), "1")
    w:run(1)
    eq(tA:getStack(1), fl, "item should wait in tesseract buffer")
    dst:remove()
    w:run(0.5)
    eq(dst:disk(), fl, "item should be delivered after drive empties")
    local lone = w:tesseract{ frequency = 99 }
    local d3 = w:diskDrive()
    lone:adjacent("east", d3)
    d3:insert(w:floppy{})
    eq(require("sim.peripherals").moveItem(d3, 0, lone, 0, 64), 1)
    w:run(1)
    check(lone:getStack(1) ~= nil, "no receiver: item stays in buffer")
end)

test("op calls take a tick and drop other events", function()
    local w = newWorld()
    local cell = w:tesseract{ frequency = 1 }
    local c = w:addComputer{ id = 63, startup = [[
local t = peripheral.wrap("left")
os.queueEvent("lost")
local t0 = os.clock()
t.getInventorySize()
local t1 = os.clock()
os.queueEvent("kept")
local ev = os.pullEvent()
local f = fs.open("o", "w") f.write(ev .. "|" .. tostring(t1 - t0 >= 0.05)) f.close()
]] }
    c:attach("left", cell)
    c:boot()
    check(waitFile(w, c, "o", 2), "no result")
    eq(c:readFile("o"), "kept|true")
end)

local bitnetRx = [[
local out = {}
local timer = os.startTimer(%d)
while true do
  local ev = { os.pullEvent() }
  if ev[1] == "timer" and ev[2] == timer then break end
  if ev[1] == "bitnet_message" then
    out[#out + 1] = ev[2] .. ":" .. tostring(ev[3]) .. ":" .. math.floor(ev[4]) .. ":" .. string.format("%%.2f", os.clock())
  end
end
local f = fs.open("b", "w") f.write(table.concat(out, ";")) f.close()
]]

test("bitnet tower delay and direct delivery", function()
    local w = newWorld()
    local t1 = w:bitnetTower{ dim = 0, pos = { 0, 64, 0 } }
    local t2 = w:bitnetTower{ dim = 0, pos = { 900, 64, 0 } }
    local tx = w:addComputer{ id = 70, startup = [[
local t = peripheral.wrap("bottom")
sleep(1)
local ok = t.transmit("hello")
local f = fs.open("s", "w") f.write(tostring(ok) .. ":" .. tostring(t.isTowerComplete()) .. string.format(":%.2f", os.clock())) f.close()
]] }
    local rx = w:addComputer{ id = 71, startup = string.format(bitnetRx, 4) }
    tx:attach("bottom", t1)
    rx:attach("bottom", t2)
    tx:boot()
    rx:boot()
    check(waitFile(w, rx, "b", 6), "no rx result")
    local sent = tonumber(tx:readFile("s"):match(":(%d+%.%d+)$"))
    local side, payload, dist, at = rx:readFile("b"):match("^(%w+):(%w+):(%d+):(%d+%.%d+)$")
    eq(side, "bottom")
    eq(payload, "hello")
    eq(dist, "900")
    local delay = tonumber(at) - sent
    check(delay >= 1.35 - 0.001 and delay <= 1.45, "delay " .. delay)
    local inc = w:bitnetTower{ dim = 0, pos = { 5, 64, 5 }, complete = false }
    local c3 = w:addComputer{ id = 72, startup = [[
local t = peripheral.wrap("top")
local ok, err = t.transmit("x")
local f = fs.open("i", "w") f.write(tostring(ok) .. ":" .. tostring(err)) f.close()
]] }
    c3:attach("top", inc)
    c3:boot()
    check(waitFile(w, c3, "i", 2), "no incomplete result")
    eq(c3:readFile("i"), "false:BitNet Communications Tower incomplete.")
end)

test("bitnet auto repeat, echo, storm range, dimensions", function()
    local w = newWorld()
    local tA = w:bitnetTower{ dim = 0, pos = { 0, 64, 0 } }
    w:bitnetTower{ dim = 0, pos = { 2000, 64, 0 } }
    local tC = w:bitnetTower{ dim = 0, pos = { 4000, 64, 0 } }
    local tN = w:bitnetTower{ dim = -1, pos = { 10, 64, 0 } }
    local a = w:addComputer{ id = 80, startup = [[
local t = peripheral.wrap("back")
sleep(0.5)
t.transmit({ id = "m1" })
]] .. string.format(bitnetRx, 12):gsub("tostring%(ev%[3%]%)", "ev[3].id") }
    local cC = w:addComputer{ id = 81, startup = string.format(bitnetRx, 12):gsub("tostring%(ev%[3%]%)", "ev[3].id") }
    local cN = w:addComputer{ id = 82, dim = -1, startup = string.format(bitnetRx, 12) }
    a:attach("back", tA)
    cC:attach("back", tC)
    cN:attach("back", tN)
    a:boot()
    cC:boot()
    cN:boot()
    check(waitFile(w, cC, "b", 15), "no result C")
    local got = cC:readFile("b")
    check(got:match("^back:m1:4000:"), "repeat to C failed: " .. got)
    check(not got:find(";"), "C should get exactly one copy: " .. got)
    check(waitFile(w, a, "b", 15), "no result A")
    check(a:readFile("b"):match("^back:m1:4000:"), "echo to sender expected: " .. a:readFile("b"))
    check(waitFile(w, cN, "b", 15), "no result N")
    eq(cN:readFile("b"), "", "cross dimension bitnet")

    local w2 = newWorld()
    local s1 = w2:bitnetTower{ dim = 0, pos = { 0, 64, 0 } }
    local s2 = w2:bitnetTower{ dim = 0, pos = { 2700, 64, 0 } }
    local snd = w2:addComputer{ id = 90, startup = [[
local t = peripheral.wrap("top")
sleep(0.5)
t.transmit("calm")
sleep(5)
t.transmit("storm")
]] }
    local rcv = w2:addComputer{ id = 91, startup = string.format(bitnetRx, 9) }
    snd:attach("top", s1)
    rcv:attach("top", s2)
    snd:boot()
    rcv:boot()
    w2:run(3)
    w2:setStorm(0, true)
    check(waitFile(w2, rcv, "b", 10), "no storm result")
    local r = rcv:readFile("b")
    check(r:match("^top:calm:2700:"), "calm message missing: " .. r)
    check(not r:find("storm", 1, true), "storm message should be out of range: " .. r)
end)

test("bitnet mini antenna range", function()
    local w = newWorld()
    local tw = w:bitnetTower{ dim = 0, pos = { 0, 64, 0 } }
    local near = w:bitnetAntenna{ dim = 0, pos = { 600, 64, 0 } }
    local far = w:bitnetAntenna{ dim = 0, pos = { 700, 64, 0 } }
    local s = w:addComputer{ id = 95, startup = 'sleep(0.5) peripheral.call("top", "transmit", "hi")' }
    local r1 = w:addComputer{ id = 96, startup = string.format(bitnetRx, 3) }
    local r2 = w:addComputer{ id = 97, startup = string.format(bitnetRx, 3) }
    s:attach("top", tw)
    r1:attach("top", near)
    r2:attach("top", far)
    s:boot() r1:boot() r2:boot()
    check(waitFile(w, r1, "b", 5) and waitFile(w, r2, "b", 5), "no antenna results")
    check(r1:readFile("b"):match("^top:hi:600:"), "near antenna missed: " .. r1:readFile("b"))
    eq(r2:readFile("b"), "", "far antenna should be out of range")
end)

test("cipher block round trip and wrong key", function()
    local w = newWorld()
    local items = { { id = 35, damage = 4, count = 3 }, { id = 1 }, nil, { id = 264, count = 2 }, nil, { id = 35, damage = 14, count = 64 } }
    local good = w:cipherBlock{ items = items }
    local twin = w:cipherBlock{ items = items }
    local other = w:cipherBlock{ items = { { id = 35, damage = 4, count = 4 }, { id = 1 } } }
    local c = w:addComputer{ id = 100, startup = [[
local g = peripheral.wrap("left")
local t = peripheral.wrap("right")
local o = peripheral.wrap("top")
local out = {}
local enc = g.encrypt("secret message")
out[#out + 1] = tostring(enc == g.encrypt("secret message"))
out[#out + 1] = tostring(enc:match("^[A-Za-z0-9+/=]+$") ~= nil)
out[#out + 1] = g.decrypt(enc)
out[#out + 1] = t.decrypt(enc)
out[#out + 1] = tostring(o.decrypt(enc) ~= "secret message")
out[#out + 1] = tostring(g.decrypt("!!notbase64!!"))
out[#out + 1] = tostring(g.getInventorySize())
out[#out + 1] = tostring(g.getStackInSlot(4).id)
local f = fs.open("c", "w") f.write(table.concat(out, "|")) f.close()
]] }
    c:attach("left", good)
    c:attach("right", twin)
    c:attach("top", other)
    c:boot()
    check(waitFile(w, c, "c", 3), "no cipher result: " .. tostring(c:lastError()))
    eq(c:readFile("c"), "true|true|secret message|secret message|true|nil|6|264")
    local enc = good:encrypt("abc")
    eq(#enc, 24, "one AES block base64")
    local nils = 0
    for i = 1, 40 do
        if other:decrypt(good:encrypt("probe " .. i)) == nil then nils = nils + 1 end
    end
    check(nils >= 35, "wrong key should mostly return nil, got " .. nils)
end)

test("too long without yielding", function()
    local w = newWorld()
    local c = w:addComputer{ id = 110, budget = 2e6, startup = [[
local f = fs.open("before", "w") f.write("x") f.close()
while true do end
]] }
    c:boot()
    w:run(1)
    check(c:readFile("before"), "startup did not run")
    local err = c:lastError() or ""
    check(err:find("Too long without yielding", 1, true), "expected yield error, got " .. err)
    check(c:screenText():find("Too long without yielding", 1, true), "error not on screen")
    local c2 = w:addComputer{ id = 111, budget = 2e6, startup = [[
local co = coroutine.create(function() while true do end end)
local ok, e = coroutine.resume(co)
local f = fs.open("co", "w") f.write(tostring(ok) .. ":" .. tostring(e)) f.close()
]] }
    c2:boot()
    w:run(1)
    eq(c2:readFile("co"), "false:Too long without yielding")
    local c3 = w:addComputer{ id = 112, budget = 2e6, startup = [[
local __st = os.startTimer(0) repeat local _, __i = os.pullEvent("timer") until __i == __st
local n = 0
for i = 1, 60 do
  for j = 1, 20000 do n = n + j end
  os.queueEvent("y") os.pullEvent("y")
end
local f = fs.open("ok", "w") f.write("done") f.close()
]] }
    c3:boot()
    check(waitFile(w, c3, "ok", 5), "yielding program was aborted: " .. tostring(c3:lastError()))
end)

test("os.queueEvent before the first yield at boot is dropped", function()
    local w = newWorld()
    local c = w:addComputer{ id = 121, startup = [[
os.queueEvent("early")
local t = os.startTimer(0.2)
local got = {}
while true do
  local ev, a = os.pullEvent()
  if ev == "timer" and a == t then break end
  got[#got + 1] = ev
end
os.queueEvent("late")
local ev = os.pullEvent("late")
local f = fs.open("q", "w") f.write(table.concat(got, ",") .. "|" .. ev) f.close()
]] }
    c:boot()
    check(waitFile(w, c, "q", 3), "no result")
    eq(c:readFile("q"), "|late")
end)

test("event queue overflow drops beyond 256", function()
    local w = newWorld()
    local c = w:addComputer{ id = 120, startup = [[
local __st = os.startTimer(0) repeat local _, __i = os.pullEvent("timer") until __i == __st
for i = 1, 300 do os.queueEvent("e", i) end
local timer = os.startTimer(0.2)
local n, last = 0, 0
while true do
  local ev, a = os.pullEvent()
  if ev == "timer" and a == timer then break end
  if ev == "e" then n = n + 1 last = a end
end
local f = fs.open("q", "w") f.write(n .. ":" .. last) f.close()
]] }
    c:boot()
    check(waitFile(w, c, "q", 3), "no result")
    eq(c:readFile("q"), "256:256")
    check(c.dropped >= 44, "dropped count " .. c.dropped)
end)

test("bit API and fs basics", function()
    local w = newWorld()
    local c = w:addComputer{ id = 130, startup = [[
local out = {}
out[#out + 1] = bit.band(0xF0F0, 0xFF00)
out[#out + 1] = bit.bor(1, 2)
out[#out + 1] = bit.bxor(5, 3)
out[#out + 1] = bit.bnot(0)
out[#out + 1] = bit.blshift(1, 31)
out[#out + 1] = bit.brshift(0x80000000, 4)
out[#out + 1] = bit.blogic_rshift(0x80000000, 4)
fs.makeDir("a/b")
local h = fs.open("a/b/c", "w") h.writeLine("one") h.write("two") h.close()
h = fs.open("a/b/c", "a") h.write("3") h.close()
h = fs.open("a/b/c", "r") out[#out + 1] = h.readLine() out[#out + 1] = h.readLine() h.close()
out[#out + 1] = table.concat(fs.find("a/*/c"), ",")
out[#out + 1] = tostring(fs.isReadOnly("rom"))
out[#out + 1] = fs.getDrive("rom") .. "," .. fs.getDrive("a")
h = fs.open("bin", "wb") h.write(200) h.write(7) h.close()
h = fs.open("bin", "rb") out[#out + 1] = h.read() .. "," .. h.read() h.close()
local f = fs.open("r", "w") f.write(table.concat(out, "|")) f.close()
]] }
    c:boot()
    check(waitFile(w, c, "r", 2), "no result: " .. tostring(c:lastError()))
    eq(c:readFile("r"), "61440|3|6|4294967295|2147483648|4160749568|134217728|one|two3|a/b/c|true|rom,hdd|200,7")
end)

test("shutdown and reboot", function()
    local w = newWorld()
    local c = w:addComputer{ id = 140, startup = [[
if fs.exists("booted") then
  local h = fs.open("booted", "a") h.write("x") h.close()
  os.shutdown()
else
  local h = fs.open("booted", "w") h.write("x") h.close()
  os.reboot()
end
]] }
    c:boot()
    w:run(4)
    eq(c:readFile("booted"), "xx")
    eq(c:isOn(), false)
end)

print("")
print(string.format("%d tests, %d passed, %d failed", #results, #results - failures, failures))
if failures > 0 then
    print("SIM SELFTEST: FAIL")
    os.exit(1)
end
print("SIM SELFTEST: PASS")
