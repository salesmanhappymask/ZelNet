local M = {}
local passed, failed = 0, 0
local current = "?"

local function show(v)
    if type(v) == "string" then return string.format("%q", v) end
    return tostring(v)
end

function M.eq(a, b, msg)
    if a ~= b then error((msg and (msg .. ": ") or "") .. "expected " .. show(b) .. ", got " .. show(a), 2) end
end

function M.neq(a, b, msg)
    if a == b then error((msg and (msg .. ": ") or "") .. "did not expect " .. show(b), 2) end
end

function M.ok(v, msg)
    if not v then error(msg or "expected truthy value", 2) end
end

function M.case(name, fn)
    current = name
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        io.write("PASS  " .. name .. "\n")
    else
        failed = failed + 1
        io.write("FAIL  " .. name .. "\n      " .. tostring(err) .. "\n")
    end
end

function M.finish()
    io.write(string.format("%d passed, %d failed\n", passed, failed))
    if failed > 0 then os.exit(1) end
end

return M
