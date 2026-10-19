local root = arg[1] or "."

local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local FORBIDDEN = {
    { pattern = "term%.blit", why = "term.blit does not exist in CC 1.63" },
    { pattern = "%.blit%(", why = "blit does not exist in CC 1.63" },
    { pattern = "os%.epoch", why = "os.epoch does not exist in CC 1.63" },
    { pattern = "bit32", why = "bit32 does not exist in CC 1.63, use the bit API through the util shim" },
    { pattern = "table%.unpack", why = "table.unpack does not exist in Lua 5.1, use unpack" },
    { pattern = "%%%.%d+f", why = "string.format precision is unreliable on CC 1.63 LuaJ, use util.fmtFixed" },
    { pattern = "%f[%w]goto%f[%W]", why = "goto does not exist in Lua 5.1" },
    { pattern = "settings%.", why = "settings API does not exist in CC 1.63" },
    { pattern = "colors%.toBlit", why = "colors.toBlit does not exist in CC 1.63" },
    { pattern = "os%.date", why = "os.date does not exist in CC 1.63" },
    { pattern = "string%.pack", why = "string.pack does not exist in Lua 5.1" },
    { pattern = "%-%-", why = "house style: no comments in code" },
    { pattern = "\226\128\148", why = "house style: no em dashes" },
}

local failures = 0
local function report(file, line, msg)
    failures = failures + 1
    io.write(string.format("%s:%d: %s\n", file, line, msg))
end

local manifest = readFile(root .. "/src/MODULES") or ""
for name in manifest:gmatch("[%w_]+") do
    local path = root .. "/src/" .. name .. ".lua"
    local src = readFile(path)
    if not src then
        report(path, 0, "missing module file")
    else
        local fn, err = loadstring(src, "=" .. path)
        if not fn then report(path, 0, "compile: " .. tostring(err)) end
        local n = 0
        for line in (src .. "\n"):gmatch("([^\n]*)\n") do
            n = n + 1
            local code = line:gsub("\"[^\"]*\"", "\"\""):gsub("'[^']*'", "''")
            for _, rule in ipairs(FORBIDDEN) do
                if code:find(rule.pattern) then report(path, n, rule.why) end
            end
        end
    end
end

if failures > 0 then
    io.write(failures .. " problem(s)\n")
    os.exit(1)
end
io.write("check ok\n")
