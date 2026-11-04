-- Swapping to another game (Spyro 1, 2 or 3) from inside a level, the way a player does it: quit to the
-- title, then pick the game on the game select screen.
--
-- **Why not "start game"(index, slot).** That is what the game select button itself calls, and calling it
-- from inside a loaded level does nothing at all: measured 2026-11-04, a world tour in LS211 and a scan
-- sweep in LS135 both called it, both sat where they were for the whole 180 s timeout, and both gave up
-- on the game they were trying to reach. lib/resume.lua only gets away with it as a fallback because it
-- runs at the title screen, where there is no level to leave.
--
-- **What the pause menu does instead** (AssetDump --code of UI_Pause, 2026-11-04). The Quit to Title
-- button runs "quit to title", which sets `go to title from question menu` and shows a yes/no question.
-- Answering yes runs ExecuteUbergraph_UI_Pause(4009), and the branch at 4793 makes one call:
--
--     Interface(FalconGameStateOnlineInterface).ReturnToTitle(false)
--
-- so that is the whole of leaving a level -- no widget to find, no button to press. The title and the
-- game select afterwards are lib/frontend.lua's, the same screens lib/resume.lua presses through after a
-- restart.
--
-- Most of a swap happens with no pawn and no level, so this is ticked from main.lua before the pawn
-- checks, like lib/resume.lua. Callers start one with begin() and watch finished().
--
--   "gameswap" lines  each step, and the swap finishing or giving up
local UEHelpers = require("UEHelpers")
local frontend = require("lib.frontend")
local levels = require("lib.levels")
local log = require("lib.log")

local gameswap = {}

local STEP_SECONDS = 0.5 -- between attempts at a screen, so a menu that is not ready yet is not hammered
local TIMEOUT = 300      -- for the whole swap: a first load of another game plays its intro

local state = nil   -- { game, phase, started, since }
local result = nil  -- "done" or why it could not, read once by finished()

local function finish(outcome, format, ...)
    log("gameswap: " .. format, ...)
    state, result = nil, outcome
end

-- Leaves the level. The pause menu's own path, without the pause menu.
local function returnToTitle()
    local ok, err = pcall(function()
        local pc = UEHelpers.GetPlayerController()
        local gs = UEHelpers.GetGameplayStatics():GetGameState(pc)
        gs:ReturnToTitle(false)
    end)
    if not ok then log("gameswap: ReturnToTitle failed: %s", tostring(err)) end
    return ok
end

-- Starts a swap to game 1, 2 or 3. finished() reports how it went.
function gameswap.begin(game)
    state = { game = game, phase = "quit", started = os.clock(), since = 0 }
    result = nil
    log("gameswap: swapping to Spyro %d through the title screen", game)
end

function gameswap.running()
    return state ~= nil
end

-- "done", a reason it could not, or nil while it is still going. Reading a result clears it.
function gameswap.finished()
    local r = result
    result = nil
    return r
end

function gameswap.update()
    if not state then return end
    local now = os.clock()
    if now - state.started > TIMEOUT then
        finish("timed out", "gave up on Spyro %d after %.0f s in phase %s",
            state.game, now - state.started, state.phase)
        return
    end
    if now - state.since < STEP_SECONDS then return end
    state.since = now

    if state.phase == "quit" then
        if not returnToTitle() then
            finish("ReturnToTitle failed", "could not leave the level; Spyro %d not reached", state.game)
            return
        end
        state.phase = "title"
        log("gameswap: left the level, waiting for the title screen")
        return
    end

    -- The title: Continue, which is what opens the game select (lib/frontend.lua).
    if state.phase == "title" then
        if not frontend.title() then return end
        if frontend.continue() then state.phase = "select" end
        return
    end

    -- The game select: the button's own handler, with the game's index.
    if state.phase == "select" then
        if not frontend.main() then return end
        if frontend.pickGame(state.game - 1) then
            state.phase, state.startedLoad = "loading", now
            log("gameswap: picked Spyro %d, waiting for its level", state.game)
        end
        return
    end

    if state.phase == "loading" then
        local pc = UEHelpers.GetPlayerController()
        local pawn = pc:IsValid() and pc.Pawn or nil
        if not (pawn and pawn:IsValid()) then return end
        local here = tostring(levels.current(pawn))
        if here:match("^LS" .. state.game) then
            finish("done", "in Spyro %d (%s) after %.0f s", state.game, here, now - state.started)
        end
        return
    end
end

return gameswap
