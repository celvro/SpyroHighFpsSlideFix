-- Getting onto a stop: into its game and its level, out of whatever conversation the last stop left
-- open, and teleported onto the spot facing the character it was recorded in front of. play.lua takes
-- it from there ("settle").
--
-- Phases: "travel" (a level load, tools/quicksave.lua's BP_LoadIntoLevel), "switch" (into another game),
-- "grace" (the level settling after either) and "clearing" (a conversation being pressed through before
-- the teleport).
--
-- Travelling live from LS135 into LS201 sets the game index, streams the level in and then leaves Spyro
-- falling in a black void, because the checkpoint it starts at belongs to the game he was in. So a run
-- that reaches another game's stops goes through the game state's "start game" first, as picking the game
-- on the menu does (switchGame), and travels on from wherever that lands him.
local UEHelpers = require("UEHelpers")
local anim = require("lib.anim")
local igc = require("lib.igc")
local levels = require("lib.levels")
local log = require("lib.log")
local subworld = require("lib.subworld")
local quicksave = require("tools.quicksave")
local routes = require("tools.routes")
local drive = require("tools.worldtour.drive")

local arrive = {}

local TRAVEL_GRACE = 5     -- seconds after a travel arrives before the teleport (the level is still settling)
local SWITCH_TIMEOUT = 180 -- seconds for "start game" to land him in the next game before its stops are skipped
local CLEAR_SECONDS = 30.0 -- waiting for a conversation to be pressed through before a teleport
local CLEAR_RETRY = 0.1    -- seconds between checks (lib/dialogue.lua spaces the presses itself)
arrive.LOCKED_STOPS = 2    -- stops in a row that could not move (or a failed check, play.lua) before
                           -- the level is loaded again
local MAX_RELOADS = 2      -- but no more than this per level: past that the spots are the problem

-- Lets go of the stop's character and of the cinematics listed for this level before the level goes
-- away: reloading destroys everything in it, and a held reference to an actor that is being torn down is
-- a pointer into freed memory.
local function letGo(run)
    anim.release(run.targetHeld)
    run.targetHeld, run.targetOrigin, run.target = nil, nil, nil
    igc.forget()
end

-- Loads the level he is in again, which closes whatever had hold of him and always hands the controller
-- back to Spyro. False when the load could not be started.
local function reload(run, pawn, level)
    letGo(run)
    if not quicksave.travel(pawn, level) then return false end
    run.phase = "travel"
    return true
end

-- Into another game (Spyro 1, 2 or 3) the way the menu does it: the game state's "start game"(game
-- index, save slot), which is what picking a game on the game select screen calls (lib/frontend.lua).
-- Travelling straight into another game's level sets the index but starts him at a checkpoint of the
-- game he was in, falling through a black void; "start game" loads the new game's own level first, and
-- the normal travel goes on from there.
local function switchGame(pawn, game)
    local ok, err = pcall(function()
        local statics = StaticFindObject("/Script/Falcon.Default__FalconGameplayStatics")
        local slot = statics:GetActiveSaveSlotIndex(pawn)
        local gs = UEHelpers.GetGameplayStatics():GetGameState(pawn)
        gs["start game"](gs, game - 1, slot)
    end)
    log("autotest: switching to Spyro %d with start game (%s)", game, ok and "ok" or tostring(err))
    return ok
end

-- Starts the current step's stop: whichever of the phases above it needs first, or straight onto the
-- spot when he is already in its level with nothing running.
function arrive.start(run, pawn, pc, cmc)
    local entry = run.step and run.step.entry
    if not entry then return end
    local stop = entry.stop
    if run.skipLevel == stop.level then
        run.phase = "next"
        return
    end
    run.skipLevel = nil
    -- Out of a subworld (play.lua sets forceReload): the level is loaded again, whatever the reload
    -- count. A next stop in another level gets that from the travel below anyway.
    if run.forceReload then
        run.forceReload = nil
        if levels.current(pawn) == stop.level and reload(run, pawn, stop.level) then return end
    end
    -- Several stops in a row that could not move: load the level again, which closes whatever had hold
    -- of him. Travelling to the level he is already in is the cheapest reset available.
    -- but only so many times in one level. A stop teleported hard against a wall never moves from its
    -- first frame, which looks exactly like being held, and reloading does not help it: LS321 spent 13
    -- reloads on an ice wall, a coal pit and a boxing arena. Two is enough to clear a conversation that
    -- really is stuck; past that the level is telling us the spots are the problem, not the game.
    if run.reloadLevel ~= stop.level then
        run.reloadLevel, run.reloads, run.reloadsNoted = stop.level, 0, nil
    end
    local locked = (run.lockedStops or 0) >= arrive.LOCKED_STOPS
    if locked and run.reloads >= MAX_RELOADS then
        run.lockedStops = 0
        if not run.reloadsNoted then
            run.reloadsNoted = true
            log("autotest: %s has had its %d reloads; the stops that cannot move here are the spots",
                stop.level, MAX_RELOADS)
        end
    elseif locked then
        run.lockedStops, run.reloads = 0, run.reloads + 1
        log("autotest: %d stops in a row could not move, loading %s again to clear it (%d of %d)",
            arrive.LOCKED_STOPS, stop.level, run.reloads, MAX_RELOADS)
        if reload(run, pawn, stop.level) then return end
    end
    -- Another game: through "start game" first (switchGame), then the travel below from its level.
    local want = tonumber(stop.level:match("^LS(%d)"))
    local have = tonumber(tostring(levels.current(pawn)):match("^LS(%d)"))
    if want and have and want ~= have then
        if run.skipGame == want then
            run.phase = "next"
            return
        end
        letGo(run)
        if switchGame(pawn, want) then
            run.phase, run.switchTo, run.switchStarted = "switch", want, os.clock()
        else
            run.skipGame, run.phase = want, "next"
        end
        return
    end
    if levels.current(pawn) ~= stop.level then
        letGo(run)
        if not quicksave.travel(pawn, stop.level) then
            run.skipLevel = stop.level
            log("autotest: %s skipped, travel failed (the rest of the level too)", stop.level)
            run.phase = "next"
            return
        end
        run.phase = "travel"
        return
    end
    -- Never teleport out of a conversation. A cinematic holds the camera and the input, and it keeps
    -- holding them wherever he is put next, so the stop after this one is lost as well -- which is how
    -- one NPC used to cost a whole run. Finish it first and only then move him.
    if igc.active(stop.level) then
        local now = os.clock()
        if not run.clearing then
            run.clearing, run.nextClear = now + CLEAR_SECONDS, 0
            log("autotest: a conversation is still running; finishing it before the teleport")
        end
        -- Continue is pressed on its text box until it closes by itself (lib/dialogue.lua spaces the
        -- presses out); a cutscene with no text box is left to end on its own.
        if now >= run.nextClear then
            run.nextClear = now + CLEAR_RETRY
            igc.close(pc, pawn, stop.level)
        end
        if now < run.clearing then
            run.phase = "clearing"
            return
        end
        log("autotest: the conversation would not finish in %.0f s; teleporting anyway", CLEAR_SECONDS)
    end
    run.clearing, run.nextClear = nil, nil
    local _, origin = levels.current(pawn)
    local x, y = routes.place(stop, origin)
    run.target = drive.findTarget(pawn, stop, x, y)
    local ok, why, spot = drive.place(pawn, pc, cmc, stop, drive.yawTo(run.target, x, y))
    if not ok then
        log("autotest: %s stop %d skipped, can't place it (%s)", stop.level, entry.id, tostring(why))
        run.phase = "next"
        return
    end
    run.phase, run.settled, run.elapsed, run.samples, run.nextSample = "settle", 0, 0, 0, 0
    run.arrived, run.everMoved, run.talking = nil, nil, nil
    run.character, run.inSubworld = subworld.character(pawn), nil
    run.spot = spot
end

-- "travel": true while the load is still going. Arriving goes on to "grace" in the same frame; a level
-- that never arrives is given up on, with the rest of its stops.
function arrive.travel(run, pawn)
    if quicksave.travelling() then return true end
    local level = run.step.entry.stop.level
    if levels.current(pawn) ~= level then
        -- A level that can't be travelled to can't be travelled to for any of its stops, and each
        -- attempt costs the whole travel timeout. Give up on the level, not on one stop at a time:
        -- LS201 cost 90 s a stop for every stop in it before this.
        run.skipLevel = level
        log("autotest: %s skipped, never arrived (the rest of the level too)", level)
        run.phase = "next"
    else
        run.phase, run.grace = "grace", TRAVEL_GRACE
    end
    return false
end

-- "switch": waiting for "start game" to put him in a level of the game it was asked for.
function arrive.switch(run, pawn)
    local here = tostring(levels.current(pawn))
    if here:match("^LS" .. run.switchTo) then
        log("autotest: in Spyro %d (%s) after %.0f s", run.switchTo, here, os.clock() - run.switchStarted)
        run.phase, run.grace = "grace", TRAVEL_GRACE
    elseif os.clock() - run.switchStarted > SWITCH_TIMEOUT then
        log("autotest: never got into Spyro %d (still in %s); skipping its stops", run.switchTo, here)
        run.skipGame, run.phase = run.switchTo, "next"
    end
end

-- "grace": the level has arrived, but give it a moment before anything is teleported.
function arrive.grace(run, pawn, pc, cmc, r)
    run.grace = run.grace - r.dt
    if run.grace <= 0 then arrive.start(run, pawn, pc, cmc) end
end

return arrive
