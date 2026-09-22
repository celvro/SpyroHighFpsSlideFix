-- Getting back into the game by itself after a restart, so a long test run can be driven from outside
-- the game (tools/Restart-Game.ps1 kills it, arms the resume and starts it again).
--
-- The game only writes its own save at an autosave or when it is quit from the menus, so closing it with
-- Alt+F4 (or killing the process) loses which level was loaded. This keeps its own note instead:
-- resume.txt in this mod folder, rewritten every WRITE_INTERVAL seconds with the level, the game index
-- and the save slot the player is in.
--
-- If resume.go exists at startup, the probe drives the title screen itself: it waits for the menu, picks
-- Continue and then the game (lib/frontend.lua; "start game" directly only if the menu never gets there,
-- tools/traveltest.lua step F), waits for a pawn, then travels to the noted level. resume.go is deleted
-- as soon as the resume starts, so a crash in the middle doesn't loop.
--
--   "resume" lines  what was noted, and each step of getting back in (or why it gave up)
local UEHelpers = require("UEHelpers")
local frontend = require("lib.frontend")
local levels = require("lib.levels")
local log = require("lib.log")
local paths = require("lib.paths")
local quicksave = require("tools.quicksave")

local resume = {}

local NOTE = paths.modDir .. "\\resume.txt"
local FLAG = paths.modDir .. "\\resume.go"
local WRITE_INTERVAL = 5 -- seconds between notes
local MENU_WAIT = 8      -- seconds at the title screen before Continue is pressed
local MENU_PICK_TIMEOUT = 20 -- seconds of menu before falling back to calling "start game" directly
local TIMEOUT = 300      -- seconds before the whole resume gives up
local CLOSE_TRIES = 20   -- checks that the menu has gone from over the loaded level, 0.5 s apart

local nextWrite = 0
local state = nil -- { level, game, slot, phase, started } while resuming
local checked = false

local function statics()
    return StaticFindObject("/Script/Falcon.Default__FalconGameplayStatics")
end

local function readNote()
    local file = io.open(NOTE, "r")
    if not file then return nil end
    local line = file:read("l") or ""
    file:close()
    -- A note written by hand rather than by writeNote can carry a UTF-8 BOM (PowerShell's -Encoding utf8
    -- writes one), and "\239\187\191LS301" is not a level name: the resume then gets as far as starting
    -- the game, fails the travel, and leaves the title screen sitting over the level it did load.
    line = line:gsub("^\239\187\191", "")
    local level, game, slot = line:match("^(%S+)%s+(%-?%d+)%s+(%-?%d+)")
    if not level then return nil end
    return { level = level, game = tonumber(game), slot = tonumber(slot) }
end

local function writeNote(pawn)
    local level = levels.current(pawn)
    if not (level and level:match("^LS%d+$")) then return end
    local ok, game, slot = pcall(function()
        local s = statics()
        return s:GetActiveGameIndex(pawn), s:GetActiveSaveSlotIndex(pawn)
    end)
    if not ok then return end
    local file = io.open(NOTE, "w")
    if not file then return end
    file:write(string.format("%s %d %d\n", level, game or 0, slot or 0))
    file:close()
end

-- Runs every frame, before the pawn checks: most of a resume happens with no pawn at all.
function resume.update()
    if not checked then
        checked = true
        local flag = io.open(FLAG, "r")
        if flag then
            flag:close()
            os.remove(FLAG)
            local note = readNote()
            if note then
                state = { level = note.level, game = note.game, slot = note.slot,
                          phase = "menu", started = os.clock() }
                log("resume: armed for %s (game %d, slot %d)", note.level, note.game, note.slot)
            else
                log("resume: resume.go is set but resume.txt has no level noted")
            end
        end
    end

    local pc = UEHelpers.GetPlayerController()
    local pawn = pc:IsValid() and pc.Pawn or nil
    local hasPawn = pawn and pawn:IsValid()

    if not state then
        if hasPawn and os.clock() >= nextWrite then
            nextWrite = os.clock() + WRITE_INTERVAL
            pcall(writeNote, pawn)
        end
        return
    end

    if os.clock() - state.started > TIMEOUT then
        log("resume: gave up after %.0f s in phase %s", os.clock() - state.started, state.phase)
        state = nil
        return
    end
    if state.phase == "menu" then
        -- Through the menu the way a player goes: Continue on the title, then the game on the game
        -- select screen (lib/frontend.lua). Calling "start game" on its own also loads the game but skips
        -- what the menu does around it, and closing what it left behind by hand took the HUD down with it.
        -- The title takes a while to be ready; the world has no pawn yet.
        if os.clock() - state.started < MENU_WAIT or not pc:IsValid() then return end
        state.menuStarted = state.menuStarted or os.clock()
        if frontend.title() and not state.continued then
            state.continued = frontend.continue()
            return
        end
        if frontend.pickGame(state.game) then
            log("resume: picked game %d from the menu", state.game)
            state.phase, state.startedLoad = "loading", os.clock()
            return
        end
        if os.clock() - state.menuStarted < MENU_PICK_TIMEOUT then return end
        -- The menu never got to the game select: call what it would have called.
        local ok, err = pcall(function()
            local gs = UEHelpers.GetGameplayStatics():GetGameState(pc)
            gs["start game"](gs, state.game, state.slot)
        end)
        if not ok then
            log("resume: start game(%d, %d) failed: %s", state.game, state.slot, tostring(err))
            state = nil
            return
        end
        log("resume: the menu never offered the game select; start game(%d, %d) called", state.game, state.slot)
        state.phase, state.startedLoad = "loading", os.clock()
        return
    end
    if state.phase == "loading" then
        if not hasPawn then return end
        local here = levels.current(pawn)
        if here == state.level then
            log("resume: back in %s after %.0f s", state.level, os.clock() - state.started)
            state.phase, state.closeTries, state.nextClose = "closing", 0, 0
            return
        end
        -- In the game but in the wrong level (the save's own level): travel the rest of the way.
        if os.clock() - state.startedLoad < 10 then return end
        if quicksave.travel(pawn, state.level) then
            log("resume: travelling from %s to %s", tostring(here), state.level)
            state.phase = "travel"
        else
            log("resume: can't travel to %s from %s; staying in %s",
                state.level, tostring(here), tostring(here))
            state.level = here
            state.phase, state.closeTries, state.nextClose = "closing", 0, 0
        end
        return
    end
    if state.phase == "travel" then
        if quicksave.travelling() then return end
        log("resume: %s after %.0f s (now in %s)",
            levels.current(pawn) == state.level and "arrived" or "travel ended elsewhere",
            os.clock() - state.started, tostring(hasPawn and levels.current(pawn) or "no pawn"))
        state.phase, state.closeTries, state.nextClose = "closing", 0, 0
        return
    end
    -- The menu goes away by itself once the level is in. Nothing is removed by hand (lib/frontend.lua):
    -- this only waits, and says so if it is still up.
    if state.phase == "closing" then
        if os.clock() < state.nextClose then return end
        state.nextClose = os.clock() + 0.5
        state.closeTries = state.closeTries + 1
        if not frontend.open() then
            log("resume: the menu is gone; %s is playable after %.0f s", state.level, os.clock() - state.started)
            state = nil
        elseif state.closeTries >= CLOSE_TRIES then
            log("resume: the menu is still up after %d checks; press through it by hand", state.closeTries)
            state = nil
        end
    end
end

-- True while the probe is still finding its way back in, so a test tool can wait.
function resume.busy()
    return state ~= nil
end

return resume
