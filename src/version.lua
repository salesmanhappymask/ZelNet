local M = {
    program = "1.0.0",
    build = "dev",
    release = 0,
    protocol = 1,
    name = "ZelNet",
}

function M.full()
    return M.program .. "+" .. M.build
end

function M.label()
    if (tonumber(M.release) or 0) <= 0 then return "dev " .. tostring(M.build) end
    return "r" .. tostring(M.release)
end

function M.labelOf(prog, rel)
    rel = tonumber(rel)
    if rel and rel > 0 then return "r" .. rel end
    if type(prog) ~= "string" or prog == "" then return "?" end
    local b = prog:match("%+(%w+)$")
    if b and b ~= "dev" then return "old " .. b:sub(1, 6) end
    return "old " .. prog
end

return M
