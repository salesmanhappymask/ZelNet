local S = require("tests.scen")
local w = S.world()
local c = w:addComputer({ id = 1, label = "main", dim = "overworld", pos = { 0, 70, 0 }, color = true, files = { ["/zelnet"] = S.program } })
c:attach("top", w:wirelessModem())
c:attach("left", w:cipherBlock({ items = S.ITEMS }))
c:attach("bottom", w:diskDrive())
c:boot()
w:run(2)
c:typeLine("zelnet")
w:run(5)
for i = 1, 20 do
    S.shot(c, "WIZARD " .. i)
    local t = c:screenText()
    if t:find("Server Console") or t:find("Server Locked") then break end
    local title = (c:screenLines()[1] or ""):match("^%s*(.-)%s*ZelOS") or ""
    if title == "Server Role" then c:typeText("1")
    elseif title == "New Network" then c:pressKey(S.keys.tab) c:typeText("EARTH") c:pressKey(S.keys.enter)
    elseif title == "Console Password" then c:typeText("secret") c:pressKey(S.keys.tab) c:typeText("secret") c:pressKey(S.keys.enter)
    elseif title == "Admin Account" and t:find("Create an admin") then c:typeText("1")
    elseif title == "Admin Account" then c:typeText("admin") c:pressKey(S.keys.tab) c:typeText("secret1") c:pressKey(S.keys.tab) c:typeText("secret1") c:pressKey(S.keys.enter)
    elseif title == "Storage" then c:typeText("1")
    elseif title == "Bridges" then c:typeText("2")
    else c:pressKey(S.keys.enter) end
    w:run(5)
end
S.errors(c, "wizard")
print("config exists:", c:exists("/.zelnet/config"), "startup:", tostring(c:readFile("/startup")))
