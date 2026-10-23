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

local function longString(text)
    local eq = ""
    while text:find("]" .. eq .. "]", 1, true) do eq = eq .. "=" end
    return "[" .. eq .. "[\n" .. text .. "]" .. eq .. "]"
end

local function moduleSource(name)
    local prog = name:match("^prog_([%w_]+)$")
    if prog then return "return " .. longString(readFile(root .. "/programs/" .. prog .. ".lua")) .. "\n" end
    return readFile(root .. "/src/" .. name .. ".lua")
end

local sources = {}
local a, b = 1, 0
for _, name in ipairs(modules) do
    local src = moduleSource(name)
    sources[name] = src
    a, b = checksum(name .. "\n" .. src, a, b)
end
local buildId = string.format("%04x%04x", b, a)

local function shell(cmd)
    local p = io.popen(cmd .. " 2>/dev/null")
    if not p then return nil end
    local text = p:read("*a")
    p:close()
    return text
end

local function releaseNumber()
    local count = tonumber((shell("git -C \"" .. root .. "\" rev-list --count HEAD") or ""):match("%d+"))
    if not count then return 0 end
    local head = shell("git -C \"" .. root .. "\" show HEAD:dist/zelnet | head -c 200") or ""
    if head:find('build = "' .. buildId .. '"', 1, true) then
        local rel = tonumber(head:match("release = (%d+)"))
        if rel then return rel end
        return count
    end
    return count + 1
end

local release = tonumber(os.getenv("ZN_RELEASE") or "") or releaseNumber()
sources.version = sources.version:gsub('build = "[%w]*"', 'build = "' .. buildId .. '"', 1)
sources.version = sources.version:gsub("release = %d+", "release = " .. release, 1)

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
io.write(string.format("built %s (%d modules, %d bytes, build %s, release r%d)\n", out, #modules, #bundle, buildId, release))
