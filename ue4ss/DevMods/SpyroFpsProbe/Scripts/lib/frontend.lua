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

-- True while the front end is still drawn over the level. Not just the title screen: a travel that
-- takes a while (LS321 to LS305 took 108 s) leaves the menu on a different screen by the time anyone
-- gets round to closing it, and a close that only knows about UI_Title_C then reports success with the
-- menu still sitting there eating button presses. The container is what is actually on the screen.
function frontend.open()
    if titleScreen() then return true end
    return container() ~= nil
end

-- Closes it. Returns true once nothing of the front end is on the screen.
function frontend.close(worldContext)
    if not frontend.open() then return true end
    local title = titleScreen()
    local removed, detached = false, false
    local box = container()
    if title and box then
        removed = pcall(function() box:RemoveScreen(title:GetClass(), true) end)
    end
    if titleScreen() then
        detached = pcall(function() title:RemoveFromParent() end)
    end
    -- Whatever screen it is on now, the container is the widget in the viewport: take it out.
    local closed = false
    box = container()
    if box then
        closed = pcall(function() box:RemoveFromParent() end)
    end
    local unpaused = pcall(function()
        local gs = UEHelpers.GetGameplayStatics():GetGameState(worldContext)
        gs["pause game for menu"](gs, false, true)
    end)
    local stillUp = frontend.open()
    log("frontend: RemoveScreen=%s RemoveFromParent=%s container=%s unpause=%s -> %s", tostring(removed),
        tostring(detached), tostring(closed), tostring(unpaused), stillUp and "still on screen" or "closed")
    return not stillUp
end

return frontend
