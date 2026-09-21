-- The subworlds: the minigames the other playable characters are in (Sheila's, Sgt Byrd's, Bentley's,
-- Agent 9's). Walking into the character who runs one starts a conversation and then hands control to
-- them, in a sublevel streamed into the level that is already loaded -- so the level name never changes
-- and nothing about the tour notices. It just plays its script out as whoever it is now holding, and
-- teleports away mid-minigame.
--
-- Getting out again is the part with no obvious call. There is no "leave subworld" function: the player
-- does it from the pause menu, and so does this. From the disassembly of UI_Pause's ubergraph, the Exit
-- Area button opens a confirmation and the yes lands at offset 15:
--
--      15: HandleAreaExit()
--     147: broadcast OnQuestAreaExitRequested(this.exit area)   -- on FalconGameStateBase
--     315: pause game for menu(false, false)
--
-- and "exit area" is not something to work out and set: the menu computes it for itself when it opens
--
--    3324: this.exit area = GetExitAreaTitle()
--
-- so opening the menu and reading that byte is also the answer to "is this a subworld at all". Zero
-- means there is nothing to exit, which is what an ordinary level says.
--
-- GameHud_C holds the widget in "pause widget" and shows it with ShowPauseMenu(show), the same call the
-- Start button ends up at -- Start itself is no use here, as it is bound on the player controller rather
-- than on the character input component the tour drives.
--
--   "subworld" lines  which character took over, and each step of getting back out
local log = require("lib.log")

local subworld = {}

local state = nil -- { step, since } while an exit is in progress
local STEP_SECONDS = 0.5 -- between steps: the menu takes a moment to build itself
local GIVE_UP = 8.0
local PAUSE = "UI_Pause_C"

-- The pawn's class name, e.g. BP_CPS3340_Bentley_LS326_C. Every playable character is a CPS####, so a
-- name that is not the one the run started with is somebody else holding the controller.
function subworld.character(pawn)
    if not (pawn and pawn:IsValid()) then return nil end
    local name
    pcall(function() name = pawn:GetClass():GetFName():ToString() end)
    return name
end

local function hudOf(pc)
    if not (pc and pc:IsValid()) then return nil end
    local hud
    pcall(function() hud = pc:GetHUD() end)
    if hud and hud:IsValid() then return hud end
    return nil
end

-- GameHud_C keeps it in "pause widget", but reading it back gives a TrivialObject that answers every
-- question and takes no call -- the same unreliable property read that made every actor in LS321 look
-- like a cinematic. Ask the object system for the widget instead, the way lib/frontend.lua finds the
-- title screen, and take the one that is actually parented into the HUD.
local function pauseWidget()
    for _, widget in ipairs(FindAllOf(PAUSE) or {}) do
        local ok = pcall(function() return widget:IsValid() end)
        if ok and widget:IsValid() and not widget:GetFName():ToString():match("^Default__") then
            local parent
            pcall(function() parent = widget:GetParent() end)
            if parent and parent:IsValid() then return widget end
        end
    end
    return nil
end

-- Starts an exit. Call subworld.updateExit every frame after this until it returns a result.
function subworld.beginExit()
    state = { step = "open", since = os.clock(), started = os.clock() }
end

function subworld.exiting()
    return state ~= nil
end

-- Drives the exit one step per call. Returns nil while it is still going, or "exited", "not a subworld"
-- or a reason it could not.
function subworld.updateExit(pc)
    if not state then return "not started" end
    local now = os.clock()
    if now - state.started > GIVE_UP then
        state = nil
        return "the pause menu never answered"
    end
    if now - state.since < STEP_SECONDS then return nil end
    state.since = now

    local hud = hudOf(pc)
    if not hud then state = nil; return "no HUD" end

    if state.step == "open" then
        local ok = pcall(function() hud:ShowPauseMenu(true) end)
        if not ok then state = nil; return "could not open the pause menu" end
        state.step = "take"
        return nil
    end

    if state.step == "take" then
        local widget = pauseWidget()
        if not widget then return nil end -- still building; GIVE_UP catches a menu that never comes
        -- What the menu worked out for itself. Logged, not trusted: reading a property off an object in
        -- this UE4SS build is not reliable enough to decide on (every actor in LS321 answered SkipCheck
        -- when only three had it), and the first attempt here read this byte as 0 while standing in
        -- Sheila's minigame with the menu open. Whether this is a subworld at all is already known from
        -- who is holding the controller, so the byte only has to be looked at, not believed.
        local area
        pcall(function() area = widget["exit area"] end)
        log("subworld: pause menu up, exit area = %s (%s); pressing Exit Area", tostring(area), type(area))
        -- Press the button, the same one the player presses. "area quit" puts up the confirmation;
        -- answering it is a separate step, because the question menu takes a moment to appear.
        state.pressed = pcall(function() widget["area quit"](widget) end)
        state.step = "confirm"
        return nil
    end

    if state.step == "confirm" then
        local widget = pauseWidget()
        if not widget then state = nil; return "the pause menu went away" end
        -- Button 0 of the confirmation is the yes. From UI_Pause's ubergraph, that is the path that
        -- reaches offset 15 and the area exit, as long as "do restart" is false, which it is unless the
        -- menu was opened by the restart button.
        local answered = pcall(function() widget["question menu - response"](widget, 0) end)
        log("subworld: Exit Area pressed=%s, confirmed=%s", tostring(state.pressed), tostring(answered))
        if not (state.pressed and answered) then
            pcall(function() hud:ShowPauseMenu(false) end)
            state = nil
            return "the menu would not take the exit"
        end
        state.step = "close"
        return nil
    end

    if state.step == "close" then
        -- The exit unpauses by itself; this only takes the menu off the screen if it is still there.
        pcall(function() hud:ShowPauseMenu(false) end)
        state = nil
        return "exited"
    end
    state = nil
    return "lost track of the exit"
end

return subworld
