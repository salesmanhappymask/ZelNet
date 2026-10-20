package.path = "./?.lua;" .. package.path
require("tests.fakecc").install({})
local need = require("tools.devload").make(".")
local provision = need("provision")
local f = assert(io.open("build/zelnet", "rb")) local text = f:read("*a") f:close()
local out = provision.serverBuild(text)
assert(loadstring(out, "=zelnet"))
local packed = provision.pack(out)
assert(provision.unpack(packed) == out)
local level = 1
while packed:find("]" .. string.rep("=", level) .. "]", 1, true) do level = level + 1 end
local eq = string.rep("=", level)
local STUB = [==[
local P = [@@[
%PACKED%]@@]
local V = {}
do
local k = 0
for c = 36, 126 do
if c ~= 96 then V[c] = k k = k + 1 end
end
end
local function breathe()
os.queueEvent("zn_unpack")
os.pullEvent("zn_unpack")
end
local function U(s)
local out, n = {}, 0
local pos, len = 1, #s
local mark = 0
while pos <= len do
local q = string.find(s, "`", pos, true)
local stop = len
if q then stop = q - 1 end
for k = pos, stop do
n = n + 1
out[n] = string.sub(s, k, k)
end
if not q then break end
local c2 = string.byte(s, q + 1)
if c2 == 96 then
n = n + 1
out[n] = "`"
pos = q + 2
else
local v = V[c2]
local a = V[string.byte(s, q + 2) or 0]
local b = V[string.byte(s, q + 3) or 0]
local ln, dist
if v < 45 then
ln = v + 5
dist = a * 90 + b
pos = q + 4
else
local c = V[string.byte(s, q + 4) or 0]
ln = v - 39
dist = a * 8100 + b * 90 + c
pos = q + 5
end
local from = n - dist
for k = 1, ln do
n = n + 1
out[n] = out[from + k]
end
end
if n - mark > 20000 then
mark = n
breathe()
end
end
return table.concat(out)
end
print("Unpacking ZelNet...")
local prog = U(P)
P = nil
if #prog ~= %LEN% then error("ZelNet did not unpack correctly; download it again", 0) end
local fn, err = loadstring(prog, "=zelnet")
if not fn then error(err, 0) end
local path = shell and shell.getRunningProgram and shell.getRunningProgram()
if path and fs.exists("/" .. path) and not fs.isReadOnly("/" .. path) then
local h = fs.open("/" .. path, "w")
if h then
h.write(prog)
h.close()
end
end
setfenv(fn, getfenv(1))
return fn(...)
]==]
local stub = STUB:gsub("@@", eq):gsub("%%LEN%%", tostring(#out))
local i = stub:find("%PACKED%", 1, true)
stub = stub:sub(1, i - 1) .. packed .. stub:sub(i + #"%PACKED%")
assert(loadstring(stub, "=zelnet"))
os.execute("mkdir -p dist")
local o = assert(io.open("dist/zelnet", "wb")) o:write(stub) o:close()
print("dist/zelnet", #stub .. " bytes (" .. #out .. " unpacked)")
