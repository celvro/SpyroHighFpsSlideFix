-- The front-end menu: getting through it the way a player does, and getting it off the screen if it is
-- still there over a loaded level (tools/traveltest.lua and lib/resume.lua need both).
--
-- How the menu is built (AssetDump --code of GameHud, UI_Title and UI_Main, 2026-09-22):
--   GameHud creates ONE UI_GenericFullScreenContainer_C, its "hud widget", and AddToViewport(5)s it.
--   Every screen goes inside it: the title, the game select, the pause menu, the gameplay HUD and the
--   NPC text boxes (UI_DialogueFrame_C / UI_Dialogue_C).
--   Title, "Continue":  RemoveFromParent() on itself, then GameHud."Show Main Menu"(true)
--   UI_Main, a game:    "handle activate"(game index): gated on active and not GameChosen, it calls the
--                       game state's "start game"(game, active slot) and "pause game for menu"(true, false)
--
-- This used to take the CONTAINER out of the viewport to close the menu. That also takes out everything a
-- level puts in it later: after it, a seal's text box was created (UI_DialogueFrame_C x1) but never drawn,
-- and the gems counter was gone too. Worse, "a container is in the viewport" was the test for "the menu is
-- open", and once the level has loaded that container is the gameplay HUD. So now only front-end SCREENS
-- are ever removed, and repairHud() puts the container back if something did take it out.
--
--   "frontend" lines  what was found, what was called, and whether the screen went away
local UEHelpers = require("UEHelpers")
local log = require("lib.log")

local frontend = {}

local HUD_ZORDER = 5 -- GameHud: this.hud widget.AddToViewport(5)
local SCREENS = { "UI_Title_C", "UI_Main_C", "UI_SelectFile_C" }

local function valid(obj)
    local ok, yes = pcall(function() return obj:IsValid() end)
    if not (ok and yes) then return false end
    local name = ""
    pcall(function() name = obj:GetFName():ToString() end)
    return not name:match("^Default__")
end

local function parentOf(widget)
    local ok, parent = pcall(function() return widget:GetParent() end)
    if ok and parent and parent:IsValid() then return parent end
    return nil
end

-- A screen of this class that is in the container and drawn.
local function shown(class)
    for _, widget in ipairs(FindAllOf(class) or {}) do
        if valid(widget) and parentOf(widget) then
            local ok, visible = pcall(function() return widget:IsVisible() end)
            if ok and visible then return widget end
        end
    end
    return nil
end

local function hud(pc)
    local h
    pcall(function() h = pc:GetHUD() end)
    if h and valid(h) then return h end
    return nil
end

-- The title screen, while it is up.
function frontend.title() return shown("UI_Title_C") end

-- The game select (Spyro 1/2/3) screen, while it is up.
function frontend.main() return shown("UI_Main_C") end

-- The title's "Continue": what the button does, minus the button.
function frontend.continue(pc)
    local title = frontend.title()
    local h = hud(pc)
    if not (title and h) then return false end
    local removed = pcall(function() title:RemoveFromParent() end)
    local opened = pcall(function() h["Show Main Menu"](h, true) end)
    log("frontend: Continue -- title removed=%s, Show Main Menu=%s", tostring(removed), tostring(opened))
    return opened
end

-- Picking a game on the game select screen, once it is ready for it. Returns true once the pick is made.
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

-- The container is GameHud's whole UI. If it is not in the viewport nothing a level shows is drawn
-- (text boxes, gem counter, pause menu), so put it back. Returns true when it had to.
function frontend.repairHud(pc)
    local h = hud(pc)
    if not h then return false end
    local box
    pcall(function() box = h["hud widget"] end)
    if not (box and valid(box)) then return false end
    local inViewport = true
    pcall(function() inViewport = box:IsInViewport() end)
    if inViewport then return false end
    local ok = pcall(function() box:AddToViewport(HUD_ZORDER) end)
    log("frontend: the HUD container was out of the viewport; put it back (%s)", ok and "ok" or "failed")
    return ok
end

-- Takes any front-end screen still drawn over the level off the screen, leaving the container (the
-- gameplay HUD) alone. Returns true once nothing of the front end is on the screen.
function frontend.close(worldContext)
    local pc = UEHelpers.GetPlayerController()
    frontend.repairHud(pc)
    if not frontend.open() then return true end
    local removed = {}
    for _, class in ipairs(SCREENS) do
        local screen = shown(class)
        if screen and pcall(function() screen:RemoveFromParent() end) then removed[#removed + 1] = class end
    end
    -- The menu pauses the game for itself ("pause game for menu"(true, false) in UI_Main).
    local unpaused = pcall(function()
        local gs = UEHelpers.GetGameplayStatics():GetGameState(worldContext)
        gs["pause game for menu"](gs, false, true)
    end)
    local stillUp = frontend.open()
    log("frontend: removed %s, unpause=%s -> %s", #removed > 0 and table.concat(removed, ", ") or "nothing",
        tostring(unpaused), stillUp and "still on screen" or "closed")
    return not stillUp
end

return frontend
