-- One-shot diagnostic (an empty dumpstate.txt in this mod folder): what is on screen and what could close
-- it. Written for the title screen that stays drawn over a level loaded with FalconGameState "start game"
-- (lib/resume.lua, and tools/traveltest.lua step F saw the same thing).
--
-- It logs every UserWidget that is in the viewport (class, name, visibility), the game state's current
-- state value, and the function names of the game state, the player controller and those widgets that look
-- like they end or close something, so the right call can be picked without guessing.
--
--   "dumpstate" lines  the widgets and the candidate functions
--   camdump_*_gamestate.txt  every reflected property of the game state
local UEHelpers = require("UEHelpers")
local dump = require("lib.dump")
local log = require("lib.log")
local paths = require("lib.paths")

local dumpstate = {}

local TRIGGER = paths.modDir .. "\\dumpstate.txt"
-- Function names worth calling to get rid of a menu.
local INTERESTING = { "close", "hide", "remove", "exit", "dismiss", "end", "start", "title", "menu",
                      "screen", "transition", "resume", "play", "game state", "loading",
                      "inventory", "life", "lives", "died", "death", "respawn", "health" }

local nextPoll = 0

local function name(obj)
    local ok, n = pcall(function() return obj:GetFName():ToString() end)
    return ok and n or "?"
end

local function className(obj)
    local ok, n = pcall(function() return obj:GetClass():GetFName():ToString() end)
    return ok and n or "?"
end

local function interesting(fn)
    local lower = fn:lower()
    for _, word in ipairs(INTERESTING) do
        if lower:find(word, 1, true) then return true end
    end
    return false
end

-- A function's parameters, so a call can be written without guessing: "(bool Show, out int Result)".
local function signature(fn)
    local parts = {}
    local ok = pcall(function()
        fn:ForEachProperty(function(prop)
            local kind = prop:GetClass():GetFName():ToString():gsub("Property$", "")
            parts[#parts + 1] = kind .. " " .. prop:GetFName():ToString()
        end)
    end)
    if not ok then return "(?)" end
    return "(" .. table.concat(parts, ", ") .. ")"
end

-- The function names of an object's class chain that look like they could close a menu.
local function logFunctions(obj, label)
    local shown, class = {}, obj:GetClass()
    while class and class:IsValid() do
        local ok = pcall(function()
            class:ForEachFunction(function(fn)
                local n = name(fn)
                if interesting(n) and not shown[n] then
                    shown[n] = true
                    log("dumpstate %s function: %s%s (%s)", label, n, signature(fn), name(class))
                end
            end)
        end)
        if not ok then log("dumpstate %s: can't list functions of %s", label, name(class)) end
        class = class:GetSuperStruct()
    end
end

local function run()
    local pc = UEHelpers.GetPlayerController()
    if not pc:IsValid() then
        log("dumpstate: no player controller")
        return
    end

    local widgets = FindAllOf("UserWidget") or {}
    local onScreen = 0
    for _, w in ipairs(widgets) do
        local ok = pcall(function() return w:IsValid() end) and w:IsValid()
        if ok and not name(w):match("^Default__") then
            local inViewport = nil
            pcall(function() inViewport = w:IsInViewport() end)
            if inViewport then
                onScreen = onScreen + 1
                local visibility
                pcall(function() visibility = w.Visibility end)
                log("dumpstate widget %d: %s (%s) visibility=%s", onScreen, className(w), name(w), tostring(visibility))
                if onScreen <= 4 then
                    logFunctions(w, "widget " .. className(w))
                    pcall(function() dump.write("widget_" .. className(w), dump.object(w)) end)
                end
            end
        end
    end
    log("dumpstate: %d widgets, %d in the viewport", #widgets, onScreen)

    -- The front-end screens live inside the container, so they are not "in the viewport" themselves:
    -- list every widget that has a parent and a name that sounds like a screen, with its visibility.
    local screens = 0
    for _, w in ipairs(widgets) do
        local ok = pcall(function() return w:IsValid() end) and w:IsValid()
        local cls = ok and className(w) or ""
        if ok and not name(w):match("^Default__") and
           (cls:lower():find("title") or cls:lower():find("menu") or cls:lower():find("screen") or cls:lower():find("frontend")) then
            local parent, visibility, visible = nil, nil, nil
            pcall(function() parent = w:GetParent() end)
            pcall(function() visibility = w.Visibility end)
            pcall(function() visible = w:IsVisible() end)
            screens = screens + 1
            if screens <= 25 then
                log("dumpstate screen: %s (%s) parent=%s visibility=%s visible=%s", cls, name(w),
                    (parent and parent:IsValid()) and className(parent) or "none",
                    tostring(visibility), tostring(visible))
            end
        end
    end
    log("dumpstate: %d screen-looking widgets", screens)

    local gs = UEHelpers.GetGameplayStatics():GetGameState(pc)
    if gs and gs:IsValid() then
        local state
        pcall(function() state = gs.theCurrentGameState end)
        log("dumpstate: game state %s (%s), theCurrentGameState=%s", className(gs), name(gs), tostring(state))
        logFunctions(gs, "gamestate")
        pcall(function() dump.write("gamestate", dump.object(gs)) end)
    else
        log("dumpstate: no game state")
    end
    logFunctions(pc, "controller")

    -- The inventory calls take an item-type enum ("set player inventory item count"(item type, count,
    -- updateSettings)), and the value for lives is only knowable by name, so list the enum's entries.
    if gs and gs:IsValid() then
        local ok, err = pcall(function()
            local fn = nil
            gs:GetClass():ForEachFunction(function(candidate)
                if name(candidate) == "set player inventory item count" then fn = candidate end
            end)
            if not (fn and fn:IsValid()) then
                log("dumpstate: no 'set player inventory item count' on the game state")
                return
            end
            fn:ForEachProperty(function(prop)
                if prop:GetClass():GetFName():ToString() ~= "EnumProperty" then return end
                local enum = prop:GetEnum()
                local shown = {}
                for value = 0, 63 do
                    local okName, entry = pcall(function() return enum:GetNameByValue(value):ToString() end)
                    if okName and entry and entry ~= "" and not entry:find("MAX") then
                        shown[#shown + 1] = value .. "=" .. entry
                    end
                end
                log("dumpstate inventory enum %s: %s", name(enum), table.concat(shown, " "))
            end)
        end)
        if not ok then log("dumpstate: can't list the inventory enum: %s", tostring(err)) end
    end
end

-- Called every frame from main.lua, before the pawn checks: the title screen may have no pawn.
function dumpstate.update()
    if os.clock() < nextPoll then return end
    nextPoll = os.clock() + 1
    local f = io.open(TRIGGER, "r")
    if not f then return end
    f:close()
    os.remove(TRIGGER)
    local ok, err = pcall(run)
    if not ok then log("dumpstate error: %s", tostring(err)) end
end

return dumpstate
