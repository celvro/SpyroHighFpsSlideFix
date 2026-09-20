-- Closing the title screen the game leaves over a level the probe loaded itself.
--
-- FalconGameState's "Start Game"(game index, slot index) loads the level but leaves the title screen drawn
-- over it: the menu normally closes itself when the player picks the slot (tools/traveltest.lua step F saw
-- the same thing, and lib/resume.lua hit it after every restart).
--
-- What is on screen (tools/dumpstate.lua, 2026-09-20): one widget in the viewport,
-- UI_GenericFullScreenContainer_C, holding the front-end screens as children; the title screen is
-- UI_Title_C, visible, inside its CanvasPanel. The container's own HideScreen(immediate) did nothing
-- visible, so this removes that screen from the container the way the menu does:
-- RemoveScreen(Class inScreenClass, Bool immediate), falling back to the widget's own RemoveFromParent.
-- The menu also pauses the game for itself, so "pause game for menu"(do pause, ForceUnpause) is called
-- to let gameplay run again.
--
--   "frontend" lines  what was found, what was called, and whether the screen went away
local UEHelpers = require("UEHelpers")
local log = require("lib.log")

local frontend = {}

local CONTAINER = "UI_GenericFullScreenContainer_C"
local TITLE = "UI_Title_C"

local function valid(obj)
    local ok = pcall(function() return obj:IsValid() end)
    return ok and obj:IsValid() and not obj:GetFName():ToString():match("^Default__")
end

local function parentOf(widget)
    local ok, parent = pcall(function() return widget:GetParent() end)
    if ok and parent and parent:IsValid() then return parent end
    return nil
end

-- The title screen widget, if one is still in a container.
local function titleScreen()
    for _, widget in ipairs(FindAllOf(TITLE) or {}) do
        if valid(widget) and parentOf(widget) then return widget end
    end
    return nil
end

-- The front-end container that is in the viewport.
local function container()
    for _, widget in ipairs(FindAllOf(CONTAINER) or {}) do
        if valid(widget) then
            local ok, inViewport = pcall(function() return widget:IsInViewport() end)
            if ok and inViewport then return widget end
        end
    end
    return nil
end

-- True while the title screen is still up.
function frontend.open()
    return titleScreen() ~= nil
end

-- Closes it. Returns true once the title screen is gone.
function frontend.close(worldContext)
    local title = titleScreen()
    if not title then return true end
    local removed = false
    local box = container()
    if box then
        removed = pcall(function() box:RemoveScreen(title:GetClass(), true) end)
    end
    local detached = false
    if titleScreen() then
        detached = pcall(function() title:RemoveFromParent() end)
    end
    local unpaused = pcall(function()
        local gs = UEHelpers.GetGameplayStatics():GetGameState(worldContext)
        gs["pause game for menu"](gs, false, true)
    end)
    local stillUp = frontend.open()
    log("frontend: %s RemoveScreen=%s RemoveFromParent=%s unpause=%s -> %s", TITLE, tostring(removed),
        tostring(detached), tostring(unpaused), stillUp and "still on screen" or "closed")
    return not stillUp
end

return frontend
