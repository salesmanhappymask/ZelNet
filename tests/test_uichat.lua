package.path = "./?.lua;" .. package.path
local env = require("tests.fakecc").install({ id = 9 })
local need = require("tools.devload").make(".")
local ui = need("ui")
local uichat = need("uichat")
local h = require("tests.uitest")
local t = require("tests.tiny")
h.extendKeys()

local function newView(w, hgt, opts)
    local surf = ui.surface(h.term(w or 51, hgt or 19, true))
    return uichat.new(surf, opts or { title = "DM: Bob", maxLen = 50 }), surf
end

t.case("wrap breaks long words and uses separate first width", function()
    local lines = uichat.wrap("hello wonderful world", 6, 10)
    t.eq(lines[1], "hello")
    t.eq(lines[2], "wonderful")
    t.eq(lines[3], "world")
    local long = uichat.wrap("abcdefghijkl", 5, 4)
    t.eq(long[1], "abcde")
    t.eq(long[2], "fghi")
    t.eq(long[3], "jkl")
    local paras = uichat.wrap("a\nb", 10, 10)
    t.eq(#paras, 2)
    t.eq(paras[2], "b")
end)

t.case("messages render with time, name and hanging indent", function()
    local v, surf = newView()
    v:setMessages({
        { who = "Bob", t = 24 + 8.5, text = "hello alice" },
        { who = "You", t = 24 + 9, text = string.rep("word ", 20) },
    })
    v:draw()
    h.expect(surf, "Day 1")
    h.expect(surf, "[08:30] Bob: hello alice")
    h.expect(surf, "[09:00] You: word word")
    local rows = h.rows(surf)
    local found
    for i, r in ipairs(rows) do
        if r:find("[09:00] You:", 1, true) then found = i end
    end
    t.ok(found, "own message row")
    local cont = rows[found + 1]
    t.eq(cont:sub(3, 3 + 12), string.rep(" ", 13), "hanging indent")
    t.eq(cont:sub(16, 19), "word", "continuation starts after the indent")
    t.ok(cont:find("word", 1, true), "continuation has text")
    h.expect(surf, "[You]: ")
    h.expect(surf, "Back")
end)

t.case("keyboard input, send, back and editing", function()
    local v, surf = newView()
    for ch in ("hi bob"):gmatch(".") do v:handle("char", ch) end
    for _ = 1, 4 do v:handle("key", keys.left) end
    v:handle("char", "!")
    t.eq(v.input, "hi! bob")
    v:handle("key", keys.backspace)
    t.eq(v.input, "hi bob")
    v:handle("key", keys.home)
    v:handle("key", keys.delete)
    t.eq(v.input, "i bob")
    local act, text = v:handle("key", keys.enter)
    t.eq(act, "send")
    t.eq(text, "i bob")
    t.eq(v:handle("key", keys.leftCtrl), "back")
    t.eq(v:handle("key", keys.rightCtrl), "back")
    v:clearInput()
    t.eq(v:handle("key", keys.enter), true, "empty input does not send")
    for _ = 1, 60 do v:handle("char", "x") end
    t.eq(#v.input, 50, "max length")
end)

t.case("scrolling keeps position when new messages arrive", function()
    local v, surf = newView()
    local list = {}
    for i = 1, 40 do list[i] = { who = "Bob", t = 30, text = "line " .. i } end
    v:setMessages(list)
    v:draw()
    h.expect(surf, "line 40")
    v:handle("key", keys.up)
    v:handle("key", keys.up)
    v:draw()
    h.refute(surf, "line 40")
    h.expect(surf, "line 38")
    v:add({ who = "Bob", t = 30, text = "line 41" })
    v:draw()
    h.expect(surf, "line 38")
    h.expect(surf, "1 new")
    v:handle("key", keys.pageDown)
    v:draw()
    h.expect(surf, "line 41")
    t.eq(v.offset, 0)
end)

t.case("scrolling past the top asks for older messages", function()
    local v = newView()
    v:setMessages({ { who = "Bob", t = 30, text = "only" } })
    v:setMore(true)
    v:draw()
    t.eq(v:handle("key", keys.up), "older")
end)

t.case("mouse back button and run loop", function()
    local v, surf = newView()
    local sent = {}
    local result
    env.run(function()
        os.queueEvent("char", "y")
        os.queueEvent("char", "o")
        os.queueEvent("key", keys.enter)
        os.queueEvent("custom_event", 1)
        os.queueEvent("mouse_click", 1, surf.w - 2, surf.h)
        result = v:run({
            onSend = function(text) sent[#sent + 1] = text end,
            onEvent = function(ev) if ev == "custom_event" then v:setStatus("got custom", colors.red) end end,
        })
    end, 10)
    t.eq(result, "back")
    t.eq(sent[1], "yo")
    t.eq(v.input, "")
    t.eq(v.status, "got custom")
end)

t.case("narrow pocket screen still renders", function()
    local v, surf = newView(26, 20)
    v:setMessages({ { who = "SomebodyLong", t = 30, text = "a fairly long message for a pocket computer" } })
    v:draw()
    h.expect(surf, "SomebodyLong:")
    h.expect(surf, "> ")
    h.refute(surf, "[06:00]")
end)

t.case("message list is capped when following the bottom and keeps scrolled views intact", function()
    local v = newView(51, 8, { title = "Chat", maxMsgs = 10 })
    local list = {}
    for i = 1, 15 do list[i] = { key = "k" .. i, seq = i, who = "Bob", text = "m" .. i } end
    v:setMessages(list)
    local dropped = v:trim()
    t.eq(#dropped, 5)
    t.eq(#v.msgs, 10)
    t.eq(v.msgs[1].key, "k6")
    t.ok(v.more, "trim marks older messages available")
    v:scroll(3)
    v:addMany({ { key = "k16", who = "Bob", text = "m16" } })
    t.eq(v:trim(), nil, "no trim while scrolled up")
    t.eq(#v.msgs, 11)
end)

t.finish()
