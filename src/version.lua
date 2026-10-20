local M = {
    program = "1.0.0",
    build = "dev",
    protocol = 1,
    name = "ZelNet",
}

function M.full()
    return M.program .. "+" .. M.build
end

return M
