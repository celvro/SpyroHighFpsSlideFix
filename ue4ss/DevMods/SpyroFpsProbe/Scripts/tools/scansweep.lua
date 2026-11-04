-- Scan sweep (a scansweep.txt file in this mod folder): travels to every level in the game's own level
-- table and records a tour stop in front of every kind of character in each one (tools/scan.lua), so
-- the route the world tour plays is built without visiting all three games level by level by hand.
--
-- It is the step before a tour: the tour can only compare framerates at stops that exist, and recording
-- them was the part still done with a controller. There is no key for it, because a sweep takes hours
-- and every letter is already bound (main.lua): it is started by dropping the trigger file in, which is
-- also how a script can start one.
--
-- **One run covers one game.** Nothing in a running level can move Spyro into another one -- see
-- startLevel -- so Spyro 2 and 3 are swept by restarting into them:
--
--   close the game, put "LS201 1 0" in resume.txt (level, game index, save slot), run
--   tools\Restart-Game.ps1, then drop a scansweep.txt holding "restart game=2"
--
-- Spyro is never teleported, only travelled: each level is scanned from its own entry checkpoint, so the
-- characters it finds are the ones loaded within scan's RANGE of there. That misses the far side of a
-- big level; raise it with range= (levels sit on a 300000 grid, so up to about 150000 is still this
-- level, and past that a stop would be recorded against a neighbour the tour will not have streamed in).
--
-- A first visit plays the level's intro cutscene, which is pressed through before the scan, as the tour
-- does (lib/igc.lua).
--
--   scansweep.txt            starts a run; may hold options, one per line or space separated:
--                              restart     start from the first level instead of resuming the progress file
--                              game=2      only that game's levels (1 = LS1xx, 2 = LS2xx, 3 = LS3xx)
--                              level=LS205 only these levels (a comma list is allowed)
--                              new         skip levels that already have stops in routes.txt
--                              all         include the flight levels and speedways (SKIP below); a
--                                          level= list always includes what it names
--                              settle=8    seconds in the level before it is scanned
--                              range=60000 how far from the checkpoint characters are taken from
--                              switch      try "start game" to reach another game's levels. It does
--                                          nothing from inside a level (see startLevel), so without
--                                          this a run skips the other games and says how to sweep them
--   scansweep.stop           an empty file that stops a run that is already going
--   scansweep_progress.txt   the next level to scan and the options it was scanned with, so a crash or
--                            tools/Restart-Game.ps1 picks the run up where it stopped (drop the trigger
--                            file in again, without "restart"). A run with other filters starts over.
--   scansweep_<stamp>.txt    one line per level: the characters found, the stops written, the outcome
--   "scansweep" lines        the start and end of a run, and each level as it is done or skipped
--
-- Stops go to routes.txt in this mod folder. Copy them into the repo with tools\Sync-Routes.ps1 and
-- commit them: a reinstall seeds that file but never overwrites it, and nothing else keeps them.
local igc = require("lib.igc")
local levels = require("lib.levels")
local log = require("lib.log")
local paths = require("lib.paths")
local quicksave = require("tools.quicksave")
local routes = require("tools.routes")
local scan = require("tools.scan")
local util = require("lib.util")

local scansweep = {}

local TRIGGER = paths.modDir .. "\\scansweep.txt"
local STOP = paths.modDir .. "\\scansweep.stop"
local PROGRESS = paths.modDir .. "\\scansweep_progress.txt"
local REPORT = string.format("%s\\scansweep_%s.txt", paths.modDir, paths.stamp)

local SETTLE = 8.0          -- seconds in the level before the scan: its characters are still spawning
local SWITCH_TIMEOUT = 180  -- seconds for "start game" to land in the next game before its levels are skipped
local CLEAR_SECONDS = 30.0  -- waiting for an intro cutscene to be pressed through before the scan
local CLEAR_RETRY = 0.1     -- seconds between presses (lib/dialogue.lua spaces its own out)

-- Flight levels and speedways, from the level tour that built the first route file (tools/tour.lua,
-- removed in 18de4c4): Spyro never walks in them, so a travel there never counts as arrived and costs
-- the whole 90 s timeout, and a crash ends on a Retry/Quit screen that nothing here can answer. There
-- is nothing to scan in them either -- they have no walking characters. "all" takes them anyway.
local SKIP = { LS105 = true, LS111 = true, LS117 = true, LS123 = true, LS129 = true,
               LS209 = true, LS220 = true, LS221 = true, LS228 = true,
               LS307 = true, LS316 = true, LS325 = true, LS334 = true }

local run = nil      -- the run in progress: levels, index, phase, options, counts
local nextPoll = 0
local warnedTouring = false -- the "a tour is running" note, said once rather than every frame

local function readOptions()
    local file = io.open(TRIGGER, "r")
    if not file then return nil end
    local text = util.stripBom(file:read("a") or "")
    file:close()
    os.remove(TRIGGER)
    local options = {}
    for word in text:gmatch("%S+") do
        local key, value = word:match("^(%w+)=(.*)$")
        if key then options[key] = value else options[word] = true end
    end
    return options
end

-- The trigger file between runs, the stop file during one: a sweep of a hundred levels has to be
-- stoppable from outside the game, and reading the trigger while one is going would restart it.
local function poll()
    if os.clock() < nextPoll then return end
    nextPoll = os.clock() + 1
    if run then
        local file = io.open(STOP, "r")
        if file then
            file:close()
            os.remove(STOP)
            run.stopping = true
        end
        return
    end
    local options = readOptions()
    if options then run = { options = options, phase = "begin" } end
end

-- The progress index counts the levels this run covers, not the whole table, so it only means anything
-- to a run with the same filters: the options that pick the levels go in the file with it, and a run
-- with different ones starts over rather than landing somewhere arbitrary.
local function signature(options)
    return string.format("game=%s level=%s all=%s new=%s",
        tostring(options.game), tostring(options.level),
        tostring(options.all or false), tostring(options.new or false))
end

local function saveIndex(index)
    local file = io.open(PROGRESS, "w")
    if not file then return end
    file:write(tostring(index), "\n", run.signature or "", "\n")
    file:close()
end

-- The saved index, or nil when the file is for a run with different filters (or there is no file).
local function savedIndex(sig)
    local file = io.open(PROGRESS, "r")
    if not file then return nil end
    local index = tonumber(file:read("l") or "")
    local saved = file:read("l")
    file:close()
    if not index then return nil end
    if (saved or "") ~= sig then
        log("scansweep: %s is for a run with other options (%s); starting from the first level",
            PROGRESS, saved or "none recorded")
        return nil
    end
    return index
end

local function report(line)
    local file = io.open(REPORT, "a")
    if not file then return end
    file:write(line, "\n")
    file:close()
end

-- Which levels this run covers, from the game's own stream data table (LS101 ... LS337) in its order,
-- or lib/levels.lua's fixed list when the table cannot be read (as the old level tour did).
local function levelList(options)
    local names = quicksave.levelNames()
    if not names or #names == 0 then
        log("scansweep: the level table could not be read; using the fixed list")
        names = levels.fixedNames()
    end
    if not names or #names == 0 then return nil end
    local only = nil
    if options.level then
        only = {}
        for name in tostring(options.level):gmatch("[^,]+") do only[(name:gsub("%s", ""))] = true end
    end
    local game = tonumber(options.game)
    local picked = {}
    for _, name in ipairs(names) do
        local levelGame = tonumber(tostring(name):match("^LS(%d)"))
        local wanted = levelGame ~= nil
            and (not only or only[name])
            and (not game or game == levelGame)
            and (options.all or only or not SKIP[name])
        if wanted then picked[#picked + 1] = name end
    end
    return picked
end

-- The levels routes.txt already has stops in, for "new".
local function coveredLevels()
    local covered = {}
    for _, level in ipairs(routes.levelNames()) do covered[level] = true end
    return covered
end

local function finish(why)
    local elapsed = os.clock() - (run.started or os.clock())
    log("scansweep: %s after %d of %d level(s) in %.0f min: %d stops written, %d level(s) skipped",
        why, run.done or 0, #(run.levels or {}), elapsed / 60, run.written or 0, run.skipped or 0)
    report(string.format("# %s: %d level(s) scanned, %d stops, %d skipped",
        why, run.done or 0, run.written or 0, run.skipped or 0))
    run = nil
end

local function wait(seconds, after)
    run.phase, run.waiting, run.waitFor = "wait", seconds, after
end

local startLevel, scanLevel

-- On to the next level, writing the progress first: a crash between levels resumes on this one.
local function nextLevel(pawn, pc)
    run.index = run.index + 1
    saveIndex(run.index)
    if run.stopping then
        finish("stopped")
        return
    end
    startLevel(pawn, pc)
end

local function skip(pawn, pc, level, why)
    run.skipped = (run.skipped or 0) + 1
    log("scansweep: %s skipped, %s", level, why)
    report(string.format("%s|skipped|%s", level, why))
    nextLevel(pawn, pc)
end

-- Gets into the level this run is on: another game first if it belongs to one, then the travel, then
-- the settle. Called again after each of those, and works out what is left from where Spyro is.
startLevel = function(pawn, pc)
    local level = run.levels[run.index]
    if not level then
        finish("every level done")
        return
    end
    if run.options.new and run.covered[level] then
        run.skipped = (run.skipped or 0) + 1
        log("scansweep: %s already has stops (new)", level)
        nextLevel(pawn, pc)
        return
    end
    local want = tonumber(level:match("^LS(%d)"))
    local have = tonumber(tostring(levels.current(pawn)):match("^LS(%d)"))
    if want and have and want ~= have then
        if run.skipGame == want then
            skip(pawn, pc, level, string.format("Spyro %d could not be reached", want))
            return
        end
        -- **"start game" from inside a level does nothing** (measured 2026-11-04: a game=2 sweep from
        -- LS135 sat in LS135 for the whole 180 s timeout and skipped all 25 levels). The call goes
        -- through and Spyro stays where he is. What actually gets into another game is the menu the
        -- title screen offers, which lib/resume.lua drives after a restart -- it only falls back to
        -- this call when the game select never appears. So a sweep covers one game, and the next game
        -- is swept by restarting into it. "switch" tries the call anyway, for anyone investigating it.
        if not run.options.switch then
            run.skipGame = want
            skip(pawn, pc, level, string.format(
                "Spyro %d needs its own run: close the game, put \"%s %d 0\" in resume.txt, "
                .. "restart and sweep with game=%d", want, level, want - 1, want))
            return
        end
        igc.forget()
        if quicksave.startGame(pawn, want) then
            run.phase, run.switchTo, run.switchStarted = "switch", want, os.clock()
        else
            run.skipGame = want
            skip(pawn, pc, level, string.format("start game(Spyro %d) failed", want))
        end
        return
    end
    if levels.current(pawn) ~= level then
        igc.forget()
        if not quicksave.travel(pawn, level) then
            skip(pawn, pc, level, "travel could not be started")
            return
        end
        run.phase = "travel"
        return
    end
    wait(run.settle, "scan")
end

-- In the level and settled: press any intro cutscene through, then scan it.
scanLevel = function(pawn, pc)
    local level = run.levels[run.index]
    if igc.active(level) then
        local now = os.clock()
        if not run.clearing then
            run.clearing, run.nextClear = now + CLEAR_SECONDS, 0
            log("scansweep: %s is still playing a cutscene; pressing it through before the scan", level)
        end
        if now >= run.nextClear then
            run.nextClear = now + CLEAR_RETRY
            igc.close(pc, pawn, level)
        end
        if now < run.clearing then
            run.phase = "clearing"
            return
        end
        log("scansweep: the cutscene would not finish in %.0f s; scanning anyway", CLEAR_SECONDS)
    end
    run.clearing, run.nextClear = nil, nil
    local found, written = scan.recordNow(pawn, pc, run.range)
    if not found then
        skip(pawn, pc, level, "the scan could not run here")
        return
    end
    run.done = (run.done or 0) + 1
    run.written = (run.written or 0) + (written or 0)
    log("scansweep: %s done (%d of %d): %d character(s), %d new stop(s); %d stops so far",
        level, run.index, #run.levels, found, written or 0, run.written)
    report(string.format("%s|scanned|%d characters|%d stops", level, found, written or 0))
    nextLevel(pawn, pc)
end

local function begin(pawn, pc)
    local options = run.options
    local list = levelList(options)
    if not list then
        log("scansweep: the level table could not be read (travel to a level once first)")
        run = nil
        return
    end
    if #list == 0 then
        log("scansweep: no levels match those options")
        run = nil
        return
    end
    run.signature = signature(options)
    local index = options.restart and 1 or math.max(savedIndex(run.signature) or 1, 1)
    if index > #list then index = 1 end
    run.levels, run.index = list, index
    run.settle = tonumber(options.settle) or SETTLE
    run.range = tonumber(options.range) or scan.RANGE
    run.covered = coveredLevels()
    run.started, run.done, run.written, run.skipped = os.clock(), 0, 0, 0
    if options.restart then saveIndex(index) end
    log("scansweep: %d level(s), starting at %d (%s); %.0f s settle, %.0f range; stops go to routes.txt",
        #list, index, list[index], run.settle, run.range)
    report(string.format("# scansweep %s: %d level(s) from %s, settle %.0f, range %.0f",
        paths.stamp, #list, list[index], run.settle, run.range))
    startLevel(pawn, pc)
end

-- Called once per frame from main.lua's sample(), with a pawn in a level. `touring` is whether the
-- world tour is running: the two both travel Spyro around and must not run at once. On 2026-11-04 a
-- tour started in the middle of a sweep, the two fought over where he was, and the game died of an
-- access violation inside UE4SS.dll -- the tour had hit the cross-game "start game" no-op, skipped
-- every remaining stop as fast as it could step, and called setFpsCap (an ExecuteInGameThread each)
-- for all 2296 of them.
function scansweep.update(pawn, pc, r, touring)
    poll()
    if not run then
        if touring and not warnedTouring then
            warnedTouring = true
            log("scansweep: a world tour is running; stop it before starting a sweep (both travel Spyro)")
        end
        return
    end
    if touring then
        log("scansweep: a world tour started; stopping this sweep so the two do not fight over travel")
        finish("stopped for a world tour")
        return
    end
    local phase = run.phase
    -- A stop asked for mid-travel is taken when the level arrives (nextLevel), not here: giving up on
    -- a travel that is already going leaves the run's idea of where Spyro is behind the game's.
    if run.stopping and phase ~= "begin" and phase ~= "travel" and phase ~= "switch" then
        finish("stopped")
        return
    end
    local ok, err = pcall(function()
        if phase == "begin" then
            begin(pawn, pc)
        elseif phase == "travel" then
            if quicksave.travelling() then return end
            local level = run.levels[run.index]
            if levels.current(pawn) ~= level then
                skip(pawn, pc, level, "never arrived")
            else
                wait(run.settle, "scan")
            end
        elseif phase == "switch" then
            local here = tostring(levels.current(pawn))
            if here:match("^LS" .. run.switchTo) then
                log("scansweep: in Spyro %d (%s) after %.0f s", run.switchTo, here, os.clock() - run.switchStarted)
                wait(run.settle, "start")
            elseif os.clock() - run.switchStarted > SWITCH_TIMEOUT then
                run.skipGame = run.switchTo
                skip(pawn, pc, run.levels[run.index],
                    string.format("never got into Spyro %d (still in %s)", run.switchTo, here))
            end
        elseif phase == "wait" then
            run.waiting = run.waiting - (r.dt or 0)
            if run.waiting <= 0 then
                if run.waitFor == "start" then startLevel(pawn, pc) else scanLevel(pawn, pc) end
            end
        elseif phase == "clearing" then
            scanLevel(pawn, pc)
        end
    end)
    if not ok then
        log("scansweep error: %s", tostring(err))
        if run then finish("gave up after an error") end
    end
end

function scansweep.running()
    return run ~= nil
end

return scansweep
