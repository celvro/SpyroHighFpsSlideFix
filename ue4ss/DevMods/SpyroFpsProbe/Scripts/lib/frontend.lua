-- Getting through the front-end menu the way a player does (lib/resume.lua after a restart).
--
-- How the menu is built (AssetDump --code of GameHud, UI_Title and UI_Main, 2026-09-22):
--   GameHud creates ONE UI_GenericFullScreenContainer_C, its "hud widget", and AddToViewport(5)s it.
--   Every screen goes inside it: the title, the game select, the pause menu, the gameplay HUD and the
--   NPC text boxes.
--   Title:        Confirm runs "handle activate"(the focused button); the first button is Continue
--                 whenever a save slot is in use, and it is the one focused when the title comes up.
--                 Continue removes the title and calls GameHud."Show Main Menu"(true).
--   Game select:  a game's button runs UI_Main."handle activate"(game index), gated on active and not
--                 GameChosen, which calls the game state's "start game"(game, active slot).
--
-- Nothing here removes, hides or re-adds a widget. It used to close the menu by taking the container out
-- of the viewport, and "a container is in the viewport" was its test for the menu being open -- after the
-- level loads, that container is the gameplay HUD. With it gone an NPC's text box was created and never
-- drawn. Pressed through like this the menu goes away by itself.
--
--   "frontend" lines  each button pressed
local log = require("lib.log")

local frontend = {}

local SCREENS = { "UI_Title_C", "UI_Main_C", "UI_SelectFile_C" }

local function valid(obj)
    local ok, yes = pcall(function() return obj:IsValid() end)
    if not (ok and yes) then return false end
    local name = ""
    pcall(function() name = obj:GetFName():ToString() end)
    return not name:match("^Default__")
end

-- A screen of this class that is in the container and drawn.
local function shown(class)
    for _, widget in ipairs(FindAllOf(class) or {}) do
        if valid(widget) then
            local ok, drawn = pcall(function()
                local parent = widget:GetParent()
                return parent and parent:IsValid() and widget:IsVisible() == true
            end)
            if ok and drawn then return widget end
        end
    end
    return nil
end

-- The title screen, while it is up.
function frontend.title() return shown("UI_Title_C") end

-- The game select (Spyro 1/2/3) screen, while it is up.
function frontend.main() return shown("UI_Main_C") end

-- Presses Continue on the title, once it is ready for a press. Returns true once pressed.
function frontend.continue()
    local title = frontend.title()
    if not title then return false end
    local active = false
    pcall(function() active = title.active == true end)
    if not active then return false end
    local button
    pcall(function() button = title.VerticalBox_0:GetChildAt(0) end)
    if not (button and valid(button)) then return false end
    local ok, err = pcall(function() title["handle activate"](title, button) end)
    log("frontend: pressed Continue on the title (%s)", ok and "ok" or tostring(err))
    return ok
end

-- Picks a game on the game select screen, once it is ready for it. Returns true once the pick is made.
function frontend.pickGame(game)
    local main = frontend.main()
    if not main then return false end
    local active, chosen = false, false
    pcall(function() active = main.active == true end)
    pcall(function() chosen = main.GameChosen == true end)
    if chosen then return true end
    if not active then return false end
    local ok, err = pcall(function() main["handle activate"](main, game) end)
    pcall(function() chosen = main.GameChosen == true end)
    log("frontend: picked game %d (%s)%s", game, ok and "ok" or tostring(err), chosen and "" or ", not taken yet")
    return chosen
end

-- True while a front-end screen is still drawn.
function frontend.open()
    for _, class in ipairs(SCREENS) do
        if shown(class) then return true end
    end
    return false
end

return frontend
