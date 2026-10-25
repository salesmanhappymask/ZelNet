package.path = "./?.lua;" .. package.path
require("tests.fakecc").install({ id = 3 })
local need = require("tools.devload").make(".")
local camera = need("camera")
local t = require("tests.tiny")

t.case("distances survive the encoding to a hundredth of a block", function()
    t.eq(camera.encode(-1), camera.NONE)
    t.eq(camera.decode(camera.NONE), nil)
    for _, d in ipairs({ 0, 0.4, 1, 7.3, 15.5, 30 }) do
        local back = camera.decode(camera.encode(d))
        t.ok(math.abs(back - d) <= camera.STEP, d .. " came back as " .. tostring(back))
    end
    t.eq(#camera.encode(3), 2)
    t.ok(camera.decode(camera.encode(500)) > 32, "the top of the scale must cover the camera range")
    t.eq(camera.decode("4"), 2, "one character codes from r52 servers still read")
    local f = { w = 2, h = 1, cw = 2, rows = { camera.encode(3) .. camera.UNSEEN } }
    local grid = camera.filled(f)
    t.ok(math.abs(grid[1][1] - 3) < 0.01)
    t.eq(grid[1][2], 3, "an unscanned cell takes its coarse neighbor's value")
end)

t.case("rays cover the whole view, top row looking up", function()
    local x1, y1 = camera.rayAt(1, 1, 26, 16)
    local x2, y2 = camera.rayAt(26, 16, 26, 16)
    t.eq(x1, -1)
    t.eq(y1, 1)
    t.eq(x2, 1)
    t.eq(y2, -1)
    t.eq(camera.rayAt(1, 1, 1, 1), 0)
end)

t.case("requested sizes are kept within the scan limits", function()
    local w, h = camera.clampSize(500, 500)
    t.eq(w, camera.MAX_W)
    t.eq(h, camera.MAX_H)
    w, h = camera.clampSize(0, 0)
    t.eq(w, 4)
    t.eq(h, 3)
end)

t.finish()
