local function readFile(path)
    local f = assert(io.open(path, "rb"))
    local s = f:read("*a")
    f:close()
    return s
end

local function writeFile(path, s)
    local f = assert(io.open(path, "wb"))
    f:write(s)
    f:close()
end

local function listModules(manifestPath)
    local list = {}
    for line in readFile(manifestPath):gmatch("[^\r\n]+") do
        local name = line:match("^%s*([%w_]+)%s*$")
        if name then list[#list + 1] = name end
    end
    return list
end

local root = arg[1] or "."
local out = arg[2] or (root .. "/build/zelnet")
local modules = listModules(root .. "/src/MODULES")

local function checksum(text, a, b)
    for i = 1, #text do
        a = (a + text:byte(i)) % 65521
        b = (b + a) % 65521
    end
    return a, b
end

local sources = {}
local a, b = 1, 0
for _, name in ipairs(modules) do
    local src = readFile(root .. "/src/" .. name .. ".lua")
    sources[name] = src
    a, b = checksum(name .. "\n" .. src, a, b)
end
local buildId = string.format("%04x%04x", b, a)
sources.version = sources.version:gsub('build = "[%w]*"', 'build = "' .. buildId .. '"', 1)

local parts = {}
parts[#parts + 1] = "local __mods, __cache, __loading = {}, {}, {}\n"
parts[#parts + 1] = "local function need(name)\n"
parts[#parts + 1] = "    local c = __cache[name]\n"
parts[#parts + 1] = "    if c ~= nil then return c end\n"
parts[#parts + 1] = "    if __loading[name] then error(\"circular module dependency: \" .. name, 2) end\n"
parts[#parts + 1] = "    local f = __mods[name]\n"
parts[#parts + 1] = "    if not f then error(\"missing module: \" .. tostring(name), 2) end\n"
parts[#parts + 1] = "    __loading[name] = true\n"
parts[#parts + 1] = "    c = f(need)\n"
parts[#parts + 1] = "    __loading[name] = nil\n"
parts[#parts + 1] = "    if c == nil then c = true end\n"
parts[#parts + 1] = "    __cache[name] = c\n"
parts[#parts + 1] = "    return c\n"
parts[#parts + 1] = "end\n"

for _, name in ipairs(modules) do
    local src = sources[name]
    local fn, err = loadstring(src, "=" .. name)
    if not fn then error("compile error in " .. name .. ": " .. tostring(err)) end
    parts[#parts + 1] = "__mods[\"" .. name .. "\"] = function(...)\n"
    parts[#parts + 1] = src
    if src:sub(-1) ~= "\n" then parts[#parts + 1] = "\n" end
    parts[#parts + 1] = "end\n"
end

parts[#parts + 1] = "return need(\"main\").start({...}, getfenv(1))\n"

local bundle = table.concat(parts)
local fn, err = loadstring(bundle, "=zelnet")
if not fn then error("bundle compile error: " .. tostring(err)) end
os.execute("mkdir -p \"" .. out:match("^(.*)/[^/]*$") .. "\"")
writeFile(out, bundle)
io.write(string.format("built %s (%d modules, %d bytes, build %s)\n", out, #modules, #bundle, buildId))
