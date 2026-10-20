package.path = "./?.lua;" .. package.path

local sim = require("sim.ccsim")
local periph = require("sim.peripherals")

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
    if not ok then
        error("timed out waiting for " .. path .. " on computer " .. c.id .. ": " .. tostring(c:lastError()), 2)
    end
    return c:readFile(path)
end

local WRITE = [[
local function put(name, s) local h = fs.open(name, "w") h.write(s) h.close() end
]]

test("waitForAny with filtered pullEvent coroutines while modem messages arrive", function()
    local w = newWorld()
    local tx = w:addComputer{ id = 1, pos = { 0, 64, 0 }, startup = [[
local m = peripheral.wrap("top")
sleep(0.3)
for i = 1, 6 do
  m.transmit(4, 4, "msg" .. i)
  os.queueEvent("noise", i)
  if i % 2 == 0 then sleep(0.05) end
end
]] }
    local rx = w:addComputer{ id = 2, pos = { 5, 64, 0 }, startup = WRITE .. [[
local m = peripheral.wrap("top")
m.open(4)
local got, noise, timers = {}, 0, 0
local r = parallel.waitForAny(
  function()
    while #got < 6 do
      local _, side, ch, reply, msg = os.pullEvent("modem_message")
      got[#got + 1] = msg
    end
  end,
  function()
    while true do os.pullEvent("never_happens") end
  end,
  function()
    while true do
      local t = os.startTimer(0.1)
      local _, id = os.pullEvent("timer")
      if id == t then timers = timers + 1 end
    end
  end,
  function()
    sleep(5)
  end)
put("r", r .. "|" .. table.concat(got, ",") .. "|" .. tostring(timers > 0))
]] }
    tx:attach("top", w:wirelessModem())
    rx:attach("top", w:wirelessModem())
    tx:boot()
    rx:boot()
    eq(waitFile(w, rx, "r", 6), "1|msg1,msg2,msg3,msg4,msg5,msg6|true")
end)

test("rednet.receive timeout and protocol filter", function()
    local w = newWorld()
    local rx = w:addComputer{ id = 3, pos = { 0, 64, 0 }, startup = WRITE .. [[
rednet.open("left")
local t0 = os.clock()
local id, msg = rednet.receive(0.5)
local dt = os.clock() - t0
local id2, msg2, proto = rednet.receive("chat", 3)
put("r", tostring(id) .. "|" .. tostring(msg) .. "|" .. string.format("%.2f", dt) .. "|" .. tostring(id2) .. "|" .. tostring(msg2) .. "|" .. tostring(proto))
]] }
    local tx = w:addComputer{ id = 4, pos = { 3, 64, 0 }, startup = [[
rednet.open("right")
sleep(1)
rednet.send(3, "wrong protocol", "other")
rednet.send(3, "right protocol", "chat")
]] }
    rx:attach("left", w:wirelessModem())
    tx:attach("right", w:wirelessModem())
    rx:boot()
    tx:boot()
    eq(waitFile(w, rx, "r", 6), "nil|nil|0.55|4|right protocol|chat")
end)

test("os.queueEvent ordering and timer interleaving", function()
    local w = newWorld()
    local c = w:addComputer{ id = 5, startup = WRITE .. [[
local t = os.startTimer(0)
os.queueEvent("a", 1)
os.queueEvent("b", 2)
os.queueEvent("c", 3)
local out = {}
for i = 1, 4 do
  local ev, p = os.pullEvent()
  out[#out + 1] = ev .. tostring(p == t and "T" or p)
end
local ids = {}
for i = 1, 5 do ids[i] = os.startTimer(1) end
local distinct = true
for i = 2, 5 do if ids[i] == ids[i - 1] then distinct = false end end
put("q", table.concat(out, ",") .. "|" .. tostring(distinct))
]] }
    c:boot()
    eq(waitFile(w, c, "q", 3), "a1,b2,c3,timerT|true")
end)

test("textutils serialize round trip through modem and deep copies", function()
    local w = newWorld()
    local tx = w:addComputer{ id = 6, pos = { 0, 64, 0 }, startup = [[
local m = peripheral.wrap("back")
sleep(0.3)
local shared = { "s" }
local t = { 1, 2, 3, [10] = "ten", [1.5] = "frac", name = "n", nested = { deep = { deeper = { "x", y = true } } }, a = shared, b = shared, [-1] = "neg" }
local copy = {}
for k, v in pairs(t) do copy[k] = v end
copy.b = { "s" }
m.transmit(1, 1, textutils.serialize(copy))
m.transmit(1, 1, t)
t.nested.deep.deeper[1] = "mutated"
]] }
    local rx = w:addComputer{ id = 7, pos = { 1, 64, 0 }, startup = WRITE .. [[
local m = peripheral.wrap("back")
m.open(1)
local _, _, _, _, s = os.pullEvent("modem_message")
local _, _, _, _, raw = os.pullEvent("modem_message")
local u = textutils.unserialize(s)
local out = {}
out[#out + 1] = type(s)
out[#out + 1] = u[1] .. u[2] .. u[3] .. u[10] .. u[1.5] .. u.name .. u[-1]
out[#out + 1] = u.nested.deep.deeper[1] .. tostring(u.nested.deep.deeper.y)
out[#out + 1] = raw[1] .. raw[2] .. raw[3] .. raw[10] .. raw[1.5] .. raw.name .. raw[-1]
out[#out + 1] = raw.nested.deep.deeper[1] .. tostring(raw.nested.deep.deeper.y)
out[#out + 1] = tostring(#raw)
out[#out + 1] = tostring(raw.a[1]) .. tostring(raw.b[1])
local mt = 0
for k in pairs(raw) do mt = mt + 1 end
out[#out + 1] = tostring(mt)
put("r", table.concat(out, "|"))
]] }
    tx:attach("back", w:wirelessModem())
    rx:attach("back", w:wirelessModem())
    tx:boot()
    rx:boot()
    eq(waitFile(w, rx, "r", 4), "string|123tenfracnneg|xtrue|123tenfracnneg|xtrue|3|ss|10")
end)

test("queueEvent deep copies tables and drops functions", function()
    local w = newWorld()
    local c = w:addComputer{ id = 8, startup = WRITE .. [[
local t = { k = { 1, 2 }, f = function() end, [true] = "b" }
os.queueEvent("x", t, function() end, nil, 5)
t.k[1] = 99
local ev, a, f, n, five = os.pullEvent("x")
put("r", tostring(a == t) .. "|" .. a.k[1] .. "|" .. tostring(a.f) .. "|" .. tostring(a[true]) .. "|" .. tostring(f) .. "|" .. tostring(n) .. "|" .. tostring(five))
]] }
    c:boot()
    eq(waitFile(w, c, "r", 2), "false|1|nil|b|nil|nil|5")
end)

test("fs handle modes", function()
    local w = newWorld()
    local c = w:addComputer{ id = 9, startup = WRITE .. [[
local out = {}
out[#out + 1] = tostring(fs.open("missing", "r"))
local h = fs.open("newfile", "a") h.write("ap") h.close()
h = fs.open("newfile", "a") h.writeLine("pend") h.close()
h = fs.open("newfile", "r") out[#out + 1] = h.readAll() h.close()
fs.makeDir("dir")
out[#out + 1] = tostring(fs.open("dir", "w"))
out[#out + 1] = tostring(fs.open("dir", "r"))
out[#out + 1] = tostring(fs.open("rom/startup", "w"))
local ok, err = pcall(fs.open, "newfile", "x")
out[#out + 1] = tostring(ok) .. ":" .. tostring(err)
h = fs.open("newfile", "r") h.close()
out[#out + 1] = tostring(h.readLine())
h = fs.open("lines", "w") h.write("a\r\nb\nc\n") h.close()
h = fs.open("lines", "r")
out[#out + 1] = h.readLine() .. h.readLine() .. h.readLine() .. tostring(h.readLine())
h.close()
h = fs.open("w2", "w") h.write("abc") h.flush()
local r = fs.open("w2", "r") out[#out + 1] = r.readAll() r.close()
h.write("def") h.close()
r = fs.open("w2", "r") out[#out + 1] = r.readAll() r.close()
h = fs.open("w2", "w") h.close()
out[#out + 1] = tostring(fs.getSize("w2"))
h = fs.open("num", "w") h.write(1) h.write(2.5) h.write(true) h.close()
r = fs.open("num", "r") out[#out + 1] = r.readAll() r.close()
put("r", table.concat(out, "|"))
]] }
    c:boot()
    eq(waitFile(w, c, "r", 2), "nil|append|nil|nil|nil|false:Unsupported mode|nil|abcnil|abc|abcdef|0|1.02.5true")
end)

test("floppy free space fills up", function()
    local w = newWorld()
    local drive = w:diskDrive()
    local fl = w:floppy{ label = "small", capacity = 4096 }
    local c = w:addComputer{ id = 10, startup = WRITE .. [[
local out = {}
out[#out + 1] = fs.getFreeSpace("disk")
local h = fs.open("disk/a", "w") h.write(string.rep("x", 1000)) h.close()
out[#out + 1] = fs.getFreeSpace("disk")
h = fs.open("disk/b", "w")
for i = 1, 40 do h.write(string.rep("y", 100)) end
h.close()
out[#out + 1] = fs.getFreeSpace("disk")
out[#out + 1] = fs.getSize("disk/b")
h = fs.open("disk/c", "w")
local ok, err = pcall(h.write, string.rep("z", 20000))
h.close()
out[#out + 1] = tostring(ok) .. ":" .. tostring(err and err:match("Out of space"))
local ok2, err2 = pcall(fs.copy, "disk/a", "disk/a2")
out[#out + 1] = tostring(fs.getFreeSpace("disk") >= 0)
h = fs.open("disk/bin", "wb")
local okb, errb = pcall(function() for i = 1, 5000 do h.write(65) end end)
h.close()
out[#out + 1] = tostring(okb) .. ":" .. tostring(errb and errb:match("Out of space"))
out[#out + 1] = tostring(fs.getFreeSpace("rom"))
put("r", table.concat(out, "|"))
]] }
    c:attach("left", drive)
    drive:insert(fl)
    c:boot()
    local r = waitFile(w, c, "r", 3)
    local parts = {}
    for p in (r .. "|"):gmatch("([^|]*)|") do parts[#parts + 1] = p end
    eq(parts[1], "4096", "initial floppy free space")
    eq(parts[2], tostring(4096 - 1000), "after 1000 bytes, root not counted until remount")
    eq(parts[3], tostring(4096 - 1000 - 512), "buffered overflow should be discarded at close")
    eq(parts[4], "0", "overflowed small writes lost on close")
    eq(parts[5], "false:Out of space", "large write errors")
    eq(parts[7], "false:Out of space", "binary write errors")
    eq(parts[8], "0", "rom free space")
    drive:remove()
    drive:insert(fl)
    w:run(0.2)
    check(fl.mount.used >= 512 + 1000, "remount should count the root directory")
    eq(c:freeSpace("disk"), math.max(fl.mount.capacity - fl.mount.used, 0), "harness free space")
end)

test("monitor_touch goes to the right computers", function()
    local w = newWorld()
    local m1 = w:monitor{ w = 2, h = 2, color = true }
    local m2 = w:monitor{ w = 2, h = 2, color = true }
    local shared = w:monitor{ w = 2, h = 2, color = true }
    local prog = WRITE .. [[
local out = {}
local timer = os.startTimer(2)
while true do
  local ev = { os.pullEvent() }
  if ev[1] == "timer" and ev[2] == timer then break end
  if ev[1] == "monitor_touch" then out[#out + 1] = ev[2] .. "@" .. ev[3] .. "," .. ev[4] end
end
put("t", table.concat(out, ";"))
]]
    local a = w:addComputer{ id = 11, startup = prog }
    local b = w:addComputer{ id = 12, startup = prog }
    a:attach("left", m1)
    b:attach("right", m2)
    a:attach("back", w:wiredModem("mon"))
    b:attach("back", w:wiredModem("mon"))
    local name = w:connect("mon", shared)
    a:boot()
    b:boot()
    w:run(0.3)
    w:touch(m1, 1, 2)
    w:touch(m2, 3, 4)
    w:touch(shared, 5, 6)
    eq(waitFile(w, a, "t", 4), "left@1,2;" .. name .. "@5,6")
    eq(waitFile(w, b, "t", 4), "right@3,4;" .. name .. "@5,6")
end)

test("peripheral_detach for wired peripherals and removed modem", function()
    local w = newWorld()
    local d1, d2 = w:diskDrive(), w:diskDrive()
    local c = w:addComputer{ id = 13, startup = WRITE .. [[
sleep(0.2)
local names = peripheral.getNames()
table.sort(names)
local out = { table.concat(names, ",") }
local timer = os.startTimer(1.5)
while true do
  local ev = { os.pullEvent() }
  if ev[1] == "timer" and ev[2] == timer then break end
  if ev[1] == "peripheral_detach" then out[#out + 1] = ev[2] end
end
local after = peripheral.getNames()
table.sort(after)
out[#out + 1] = "[" .. table.concat(after, ",") .. "]"
out[#out + 1] = tostring(peripheral.isPresent("drive_1"))
put("r", table.concat(out, "|"))
]] }
    c:attach("back", w:wiredModem("lan"))
    local n1 = w:connect("lan", d1)
    local n2 = w:connect("lan", d2)
    c:boot()
    w:run(0.5)
    w:disconnect("lan", d1)
    w:run(0.3)
    c:detach("back")
    local r = waitFile(w, c, "r", 3)
    eq(r, "back," .. n1 .. "," .. n2 .. "|" .. n1 .. "|" .. n2 .. "|back|[]|false")
end)

test("os.reboot reruns startup with fresh state", function()
    local w = newWorld()
    local c = w:addComputer{ id = 14, startup = [[
local n = 0
if fs.exists("count") then local h = fs.open("count", "r") n = tonumber(h.readAll()) h.close() end
n = n + 1
local h = fs.open("count", "w") h.write(tostring(n)) h.close()
h = fs.open("clock" .. n, "w") h.write(string.format("%.2f", os.clock()) .. ":" .. tostring(_G.marker)) h.close()
_G.marker = "set"
if n < 3 then sleep(0.5) os.reboot() end
]] }
    c:boot()
    w:run(7)
    eq(c:readFile("count"), "3")
    eq(c:readFile("clock2"):match(":(.*)$"), "nil", "globals survive reboot")
    check(tonumber(c:readFile("clock3"):match("^(.-):")) < 0.2, "clock did not reset: " .. c:readFile("clock3"))
    check(c:isOn(), "computer should still be on")
end)

test("os.reboot waits 50 ticks after the previous start", function()
    local w = newWorld()
    local c = w:addComputer{ id = 40, startup = [[
local n = 0
if fs.exists("count") then local h = fs.open("count", "r") n = tonumber(h.readAll()) h.close() end
local h = fs.open("count", "w") h.write(tostring(n + 1)) h.close()
if n == 0 then os.reboot() end
]] }
    c:boot()
    w:runTicks(45)
    eq(c:readFile("count"), "1")
    eq(c:isOn(), false, "computer is off while the restart is pending")
    w:runTicks(10)
    eq(c:readFile("count"), "2")
    check(c:isOn(), "computer back on")
end)

test("wireless does not cross dimensions at the same coordinates", function()
    local w = newWorld()
    local rx = WRITE .. [[
local m = peripheral.wrap("top")
m.open(9)
local t = os.startTimer(1.5)
local got = "none"
while true do
  local ev = { os.pullEvent() }
  if ev[1] == "timer" and ev[2] == t then break end
  if ev[1] == "modem_message" then got = ev[5] end
end
put("r", got)
]]
    local a = w:addComputer{ id = 15, dim = 0, pos = { 10, 70, 10 }, startup = 'sleep(0.3) peripheral.call("top", "transmit", 9, 9, "hi")' }
    local b = w:addComputer{ id = 16, dim = 1, pos = { 10, 70, 10 }, startup = rx }
    local c = w:addComputer{ id = 17, dim = 0, pos = { 10, 70, 12 }, startup = rx }
    for _, x in ipairs({ a, b, c }) do
        x:attach("top", w:wirelessModem())
        x:boot()
    end
    eq(waitFile(w, b, "r", 3), "none")
    eq(waitFile(w, c, "r", 3), "hi")
end)

test("wireless delivery is immediate and in transmit order", function()
    local w = newWorld()
    local a = w:addComputer{ id = 18, pos = { 0, 64, 0 }, startup = [[
local m = peripheral.wrap("top")
sleep(0.3)
m.transmit(2, 2, "one")
m.transmit(2, 2, "two")
]] }
    local b = w:addComputer{ id = 19, pos = { 1, 64, 0 }, startup = WRITE .. [[
local m = peripheral.wrap("top")
m.open(2)
local _, _, _, _, x = os.pullEvent("modem_message")
local t1 = os.clock()
local _, _, _, _, y = os.pullEvent("modem_message")
put("r", x .. y)
]] }
    a:attach("top", w:wirelessModem())
    b:attach("top", w:wirelessModem())
    b:boot()
    a:boot()
    eq(waitFile(w, b, "r", 2), "onetwo")
end)

test("tesseract with occupied destination waits, other receiver free", function()
    local w = newWorld()
    local src = w:diskDrive()
    local busy, free = w:diskDrive(), w:diskDrive()
    local tS = w:tesseract{ frequency = 5, mode = "send" }
    local tBusy = w:tesseract{ frequency = 5, mode = "receive" }
    local tFree = w:tesseract{ frequency = 5, mode = "receive" }
    local tOther = w:tesseract{ frequency = 6, mode = "receive" }
    local otherDrive = w:diskDrive()
    tS:adjacent("up", src)
    tBusy:adjacent("down", busy)
    tFree:adjacent("down", free)
    tOther:adjacent("down", otherDrive)
    busy:insert(w:floppy{ label = "blocker" })
    local fl = w:floppy{ label = "cargo" }
    src:insert(fl)
    local c = w:addComputer{ id = 20, startup = WRITE .. [[
local t = peripheral.wrap("top")
local n = t.pullItem("up", 1)
local n2 = t.pullItem("up", 1)
put("n", n .. ":" .. n2 .. ":" .. tostring(t.canReceiveItems()) .. ":" .. tostring(t.canSendItems()))
]] }
    c:attach("top", tS)
    c:boot()
    eq(waitFile(w, c, "n", 2), "1:0:false:true")
    w:run(1)
    eq(free:disk(), fl, "item should go to free receiver")
    eq(otherDrive:disk(), nil, "wrong frequency received")
    eq(busy:disk().label, "blocker")
end)

test("bitnet out of range and incomplete tower does not receive or repeat", function()
    local w = newWorld()
    local a = w:bitnetTower{ dim = 0, pos = { 0, 64, 0 } }
    local far = w:bitnetTower{ dim = 0, pos = { 3001, 64, 0 } }
    local edge = w:bitnetTower{ dim = 0, pos = { 0, 64, 3000 } }
    local broken = w:bitnetTower{ dim = 0, pos = { 1500, 64, 0 }, complete = false }
    local beyond = w:bitnetTower{ dim = 0, pos = { 4400, 64, 0 } }
    local rx = WRITE .. [[
local t = os.startTimer(7)
local got = {}
while true do
  local ev = { os.pullEvent() }
  if ev[1] == "timer" and ev[2] == t then break end
  if ev[1] == "bitnet_message" then got[#got + 1] = tostring(ev[3]) .. "@" .. math.floor(ev[4]) end
end
put("b", table.concat(got, ","))
]]
    local s = w:addComputer{ id = 21, startup = 'sleep(0.3) peripheral.call("top", "transmit", "ping")' }
    local cf = w:addComputer{ id = 22, startup = rx }
    local ce = w:addComputer{ id = 23, startup = rx }
    local cb = w:addComputer{ id = 24, startup = rx }
    local cy = w:addComputer{ id = 25, startup = rx }
    s:attach("top", a)
    cf:attach("top", far)
    ce:attach("top", edge)
    cy:attach("top", beyond)
    cb:attach("top", broken)
    for _, x in ipairs({ s, cf, ce, cb, cy }) do x:boot() end
    eq(waitFile(w, cf, "b", 10), "", "3001 blocks should be out of range")
    eq(waitFile(w, ce, "b", 10), "ping@3000", "3000 blocks is in range")
    eq(waitFile(w, cb, "b", 10), "", "incomplete tower should not receive")
    eq(waitFile(w, cy, "b", 10), "", "beyond via incomplete tower")
    local w2 = newWorld()
    local s2 = w2:bitnetTower{ dim = 0, pos = { 0, 64, 0 } }
    w2:bitnetTower{ dim = 0, pos = { 1500, 64, 0 }, complete = false }
    local d2 = w2:bitnetTower{ dim = 0, pos = { 4400, 64, 0 } }
    local tx2 = w2:addComputer{ id = 26, startup = 'sleep(0.3) peripheral.call("top", "transmit", "ping")' }
    local rx2 = w2:addComputer{ id = 27, startup = rx }
    tx2:attach("top", s2)
    rx2:attach("top", d2)
    tx2:boot()
    rx2:boot()
    eq(waitFile(w2, rx2, "b", 10), "", "unattached incomplete tower must not repeat")
end)

test("cipher decrypt of tampered input", function()
    local w = newWorld()
    local cb = w:cipherBlock{ items = { { id = 5, count = 2 }, { id = 7, damage = 3 } } }
    local c = w:addComputer{ id = 28, startup = WRITE .. [[
local cph = peripheral.wrap("left")
local msg = string.rep("attack at dawn ", 4)
local enc = cph.encrypt(msg)
local out = {}
local flipped = enc:sub(1, 5) .. (enc:sub(6, 6) == "A" and "B" or "A") .. enc:sub(7)
local d = cph.decrypt(flipped)
out[#out + 1] = tostring(d ~= msg)
local lastBlock = enc:sub(1, #enc - 8) .. (enc:sub(#enc - 7, #enc - 7) == "A" and "B" or "A") .. enc:sub(#enc - 6)
out[#out + 1] = tostring(cph.decrypt(lastBlock) ~= msg)
out[#out + 1] = tostring(cph.decrypt(enc:sub(1, #enc - 4)))
out[#out + 1] = tostring(cph.decrypt(""))
out[#out + 1] = tostring(cph.decrypt("AAAA"))
out[#out + 1] = tostring(cph.decrypt(enc) == msg)
out[#out + 1] = tostring(cph.encrypt("") ~= nil)
out[#out + 1] = tostring(cph.decrypt(cph.encrypt("")))
local ok, err = pcall(cph.decrypt)
out[#out + 1] = tostring(ok)
put("r", table.concat(out, "|"))
]] }
    c:attach("left", cb)
    c:boot()
    eq(waitFile(w, c, "r", 3), "true|true|nil||nil|true|true||false")
end)

test("cpu heavy loops: yielding survives, busy loop killed, shell survives", function()
    local w = newWorld()
    local c = w:addComputer{ id = 29, budget = 3e6, startup = WRITE .. [[
local acc = 0
for round = 1, 200 do
  for i = 1, 5000 do acc = acc + i % 7 end
  os.queueEvent("tick")
  os.pullEvent("tick")
end
put("yield", tostring(acc))
local s = 0
for i = 1, 1e9 do s = s + i end
put("never", "x")
]] }
    c:boot()
    w:run(3)
    check(c:readFile("yield"), "yielding loop was killed: " .. tostring(c:lastError()))
    eq(c:readFile("never"), nil)
    check((c:lastError() or ""):find("Too long without yielding", 1, true), "expected yield error, got " .. tostring(c:lastError()))
    check(c:isOn(), "computer should stay on after a soft abort")
    c:typeLine("id")
    w:run(0.5)
    check(c:screenText():find("This is computer #29", 1, true), "shell not usable after abort: " .. c:screenText())
end)

test("busy loop inside pcall cannot swallow the hard abort", function()
    local w = newWorld()
    local c = w:addComputer{ id = 30, budget = 2e6, startup = WRITE .. [[
local caught = 0
while true do
  local ok = pcall(function() while true do end end)
  caught = caught + 1
  if caught > 100 then put("swallowed", tostring(caught)) break end
end
]] }
    c:boot()
    w:run(2)
    eq(c:readFile("swallowed"), nil, "pcall swallowed every abort")
    eq(c:isOn(), false, "computer should be shut down by the hard abort")
end)

test("os.time is shared across dimensions and advances with world time", function()
    local w = newWorld()
    w:setTime(18000)
    local prog = WRITE .. [[
local a = os.time()
sleep(5)
put("t", string.format("%.3f:%.3f:%d", a, os.time(), os.day()))
]]
    local o = w:addComputer{ id = 31, dim = 0, startup = prog }
    local n = w:addComputer{ id = 32, dim = -1, startup = prog }
    o:boot()
    n:boot()
    local ro = waitFile(w, o, "t", 7)
    local rn = waitFile(w, n, "t", 7)
    eq(ro, rn, "dimensions disagree on time")
    eq(ro, "0.000:0.101:2")
end)

test("alarm fires at the requested time", function()
    local w = newWorld()
    w:setTime(0)
    local c = w:addComputer{ id = 33, startup = WRITE .. [[
local a = os.setAlarm(6.2)
local _, id = os.pullEvent("alarm")
put("a", tostring(id == a) .. string.format(":%.2f", os.time()))
]] }
    c:boot()
    eq(waitFile(w, c, "a", 15), "true:6.20")
end)

test("bit API edge cases", function()
    local w = newWorld()
    local c = w:addComputer{ id = 34, startup = WRITE .. [[
local out = {}
out[#out + 1] = bit.blshift(1, 32)
out[#out + 1] = bit.blshift(1, 33)
out[#out + 1] = bit.brshift(-8, 1)
out[#out + 1] = bit.band(-1, 255)
out[#out + 1] = bit.bnot(-1)
out[#out + 1] = select(2, pcall(bit.band, 1.5, 1))
out[#out + 1] = select(2, pcall(bit.band, 2^32, 1))
put("r", table.concat(out, "|"))
]] }
    c:boot()
    local r = waitFile(w, c, "r", 2)
    local p = {}
    for x in (r .. "|"):gmatch("([^|]*)|") do p[#p + 1] = x end
    eq(p[1], "1")
    eq(p[2], "2")
    eq(p[3], "4294967292")
    eq(p[4], "255")
    eq(p[5], "0")
    check(p[6]:find("passed number is not an integer", 1, true), "non integer: " .. p[6])
    check(p[7]:find("number is too large", 1, true), "too large: " .. p[7])
end)

test("op call through wired modem waits a tick, parallel siblings keep events", function()
    local w = newWorld()
    local t = w:tesseract{ frequency = 42 }
    local c = w:addComputer{ id = 35, startup = WRITE .. [[
local names = {}
local freq
parallel.waitForAll(
  function()
    freq = peripheral.call(peripheral.getNames()[2] == "back" and peripheral.getNames()[1] or peripheral.getNames()[2], "getInventorySize")
  end,
  function()
    os.queueEvent("sib")
    local ev = os.pullEvent("sib")
    names[#names + 1] = ev
  end)
put("r", tostring(freq) .. "|" .. table.concat(names, ","))
]] }
    c:attach("back", w:wiredModem("x"))
    w:connect("x", t)
    c:boot()
    eq(waitFile(w, c, "r", 3), "1|sib")
end)

test("terminate during op call errors with Terminated", function()
    local w = newWorld()
    local t = w:tesseract{ frequency = 1 }
    local c = w:addComputer{ id = 36, startup = WRITE .. [[
local p = peripheral.wrap("left")
local ok, err = pcall(function()
  while true do p.getInventorySize() end
end)
put("r", tostring(ok) .. ":" .. tostring(err))
]] }
    c:attach("left", t)
    c:boot()
    w:run(0.3)
    c:terminate()
    local r = waitFile(w, c, "r", 2)
    check(r:match("^false:.*Terminated$"), "unexpected " .. r)
end)

test("disk events at boot and drive eject", function()
    local w = newWorld()
    local d = w:diskDrive()
    d:insert(w:floppy{ label = "boot", files = { hello = "hi" } })
    local c = w:addComputer{ id = 37, startup = WRITE .. [[
local out = { tostring(fs.exists("disk/hello")), tostring(disk.isPresent("top")) }
disk.eject("top")
local ev, side = os.pullEvent("disk_eject")
out[#out + 1] = ev .. ":" .. side .. ":" .. tostring(fs.exists("disk"))
put("r", table.concat(out, "|"))
]] }
    c:attach("top", d)
    c:boot()
    eq(waitFile(w, c, "r", 2), "true|true|disk_eject:top:false")
    eq(d:disk(), nil)
end)

test("tesseract frequency methods are immediate, inventory methods take a tick", function()
    local w = newWorld()
    local t = w:tesseract{ frequency = 9 }
    local c = w:addComputer{ id = 39, startup = WRITE .. [[
local p = peripheral.wrap("left")
os.queueEvent("kept")
local t0 = os.clock()
local f = p.getFrequency()
local ok = p.setFrequency(11)
local t1 = os.clock()
local n = p.getInventorySize()
local t2 = os.clock()
os.queueEvent("after")
local ev = os.pullEvent()
put("r", f .. ":" .. tostring(ok) .. ":" .. p.getFrequency() .. ":" .. string.format("%.2f:%.2f", t1 - t0, t2 - t1) .. ":" .. n .. ":" .. ev)
]] }
    c:attach("left", t)
    c:boot()
    eq(waitFile(w, c, "r", 2), "9:true:11:0.00:0.05:1:after")
end)

test("startTimer zero and sleep zero fire next tick", function()
    local w = newWorld()
    local c = w:addComputer{ id = 38, startup = WRITE .. [[
local t0 = os.clock()
sleep(0)
local t1 = os.clock()
local id = os.startTimer(0)
local _, got = os.pullEvent("timer")
put("r", string.format("%.2f", t1 - t0) .. ":" .. tostring(got == id))
]] }
    c:boot()
    eq(waitFile(w, c, "r", 2), "0.05:true")
end)

print("")
print(string.format("%d tests, %d passed, %d failed", #results, #results - failures, failures))
if failures > 0 then
    print("SIM ADVERSARIAL: FAIL")
    os.exit(1)
end
print("SIM ADVERSARIAL: PASS")
