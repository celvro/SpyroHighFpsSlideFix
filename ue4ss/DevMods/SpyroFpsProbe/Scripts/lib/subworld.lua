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
local UEHelpers = require("UEHelpers")
local log = require("lib.log")

local subworld = {}

local state = nil -- { step, since } while an exit is in progress
local STEP_SECONDS = 0.5 -- between steps: the menu takes a moment to build itself
local GIVE_UP = 8.0
local PAUSE = "UI_Pause_C"        -- the screen with the Exit Area button (MenuScreens)
local PAUSE_HOST = "UI_PauseMenu_C" -- what GameHud actually creates, which opens that screen

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

-- Why ShowPauseMenu did nothing. GameHud routes it to "open pause menu", which gives up unless the
-- game state is 3, the game is not already paused and the HUD is visible; any of the three closing
-- means no widget is ever built and the call returns quite happily having done nothing. Rather than
-- guess which, ask. Functions are asked wherever there is one, because a property read in this build
-- can hand back a TrivialObject that answers anything.
function subworld.diagnose(pc)
    local hud = hudOf(pc)
    local hudName = "none"
    if hud then pcall(function() hudName = hud:GetClass():GetFName():ToString() end) end
    local paused
    pcall(function() paused = UEHelpers.GetGameplayStatics():IsGamePaused(pc) end)
    local visible
    pcall(function() visible = hud:GetHudVisibility() end)
    log("subworld: HUD %s, IsGamePaused %s, GetHudVisibility %s (%s)", hudName, tostring(paused),
        tostring(visible), type(visible))
    local gs
    pcall(function() gs = UEHelpers.GetGameplayStatics():GetGameState(pc) end)
    if gs and gs:IsValid() then
        local gsName, st = "?", nil
        pcall(function() gsName = gs:GetClass():GetFName():ToString() end)
        pcall(function() st = gs.theCurrentGameState end)
        log("subworld: GameState %s, theCurrentGameState %s (%s)", gsName, tostring(st), type(st))
    end
    local all = FindAllOf(PAUSE) or {}
    log("subworld: %d %s object(s) exist", #all, PAUSE)
    for i, widget in ipairs(all) do
        if i > 3 then break end
        local name, parent = "?", nil
        pcall(function() name = widget:GetFullName() end)
        pcall(function() parent = widget:GetParent() end)
        log("subworld:   %s (parent %s)", name, parent and parent:IsValid() and "yes" or "no")
    end
end

-- Starts an exit. Call subworld.updateExit every frame after this until it returns a result.
function subworld.beginExit(pc)
    pcall(subworld.diagnose, pc)
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
        -- The gate that was shut. "open pause menu" wants the game state to be 3 (it is), the game not
        -- already paused (it is not) and GetHudVisibility to say yes -- and that last one is true only
        -- when the HUD widget's visibility is exactly 4, which a minigame's own HUD takes away. With it
        -- shut, ShowPauseMenu returns perfectly happily having built no widget at all, which is why the
        -- first three attempts at pressing a button found nothing to press. SetHudVisibility(true) sets
        -- that same 4 back.
        pcall(function() hud:SetHudVisibility(true) end)
        local ok = pcall(function() hud:ShowPauseMenu(true) end)
        if not ok then state = nil; return "could not open the pause menu" end
        state.step = "take"
        return nil
    end

    if state.step == "take" then
        local widget = pauseWidget()
        if not widget then
            -- Say once what did and did not appear after the call, rather than sitting here for eight
            -- seconds and reporting only that nothing did.
            -- GameHud creates UI_PauseMenu_C and parents it, but that host only pauses the game in its
            -- Construct; the screen with the Exit Area button on it is opened separately, from the
            -- host's ShowScreen. Nothing has called that, so call it.
            if not state.shown then
                state.shown = true
                for _, host in ipairs(FindAllOf(PAUSE_HOST) or {}) do
                    local ok = pcall(function() return host:IsValid() end)
                    if ok and host:IsValid() and not host:GetFName():ToString():match("^Default__") then
                        local shown = pcall(function() host:ShowScreen() end)
                        log("subworld: asked %s to show its screen: %s", PAUSE_HOST, tostring(shown))
                    end
                end
            end
            if not state.looked then
                state.looked = true
                local visible
                pcall(function() visible = hud:GetHudVisibility() end)
                log("subworld: after ShowPauseMenu -- %d %s, %d %s, GetHudVisibility %s",
                    #(FindAllOf(PAUSE_HOST) or {}), PAUSE_HOST, #(FindAllOf(PAUSE) or {}), PAUSE,
                    tostring(visible))
            end
            return nil -- still building; GIVE_UP catches a menu that never comes
        end
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
