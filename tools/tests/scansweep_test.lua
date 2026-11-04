-- Drives the probe's tools/scansweep.lua against stubbed modules, so its state machine can be checked
-- without the game: every level scanned in order, the game= / level= / new= / settle= / range= options,
-- a travel that cannot start, one that never arrives, a game that cannot be reached, an intro cutscene
-- that will not end, and the stop file and the resume from scansweep_progress.txt.
--
-- The sweep is the one probe tool that can be tested this way: it talks to the game only through the
-- modules stubbed below, so it needs no UE4SS globals (unlike everything that reads an actor).
--
--   lua tools\tests\scansweep_test.lua
--
-- Exits non-zero on a failure, so it can go in front of a deploy.
local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\]tools[/\\]tests[/\\]") or "."
package.path = here .. "\\ue4ss\\DevMods\\SpyroFpsProbe\\Scripts\\?.lua;" .. package.path

local tmp = os.getenv("TEMP") .. "\\sweeptest"
os.execute('mkdir "' .. tmp .. '" 2>nul')
os.execute('del /q "' .. tmp .. '\\*" 2>nul')

local world = {
    current = "LS104",
    travelling = false,
    arriveIn = 0,
    travelTo = nil,
    travelFails = {},     -- level -> true: travel cannot be started
    neverArrives = {},    -- level -> true: travel starts but the level never comes up
    startGameFails = {},  -- game -> true
    scanned = {},
    cutsceneLevels = {},
}

package.preload["lib.log"] = function()
    return function(fmt, ...) print("[log] " .. string.format(fmt, ...)) end
end
package.preload["lib.paths"] = function()
    return { modDir = tmp, stamp = "test" }
end
package.preload["lib.igc"] = function()
    return {
        forget = function() end,
        active = function(level) return world.cutsceneLevels[level] or false end,
        close = function() end,
    }
end
package.preload["lib.levels"] = function()
    return {
        current = function() return world.current, { X = 0, Y = 0 } end,
        fixedNames = function() return { "LS101", "LS102" } end,
    }
end
package.preload["tools.quicksave"] = function()
    return {
        levelNames = function() return world.levelNames end,
        travel = function(_, level)
            if world.travelFails[level] then return false end
            world.travelling, world.travelTo, world.arriveIn = true, level, 2
            return true
        end,
        travelling = function() return world.travelling end,
        startGame = function(_, game)
            world.startGameCalls = (world.startGameCalls or 0) + 1
            if world.startGameFails[game] then return false end
            world.pendingGame = game
            world.gameIn = 2
            return true
        end,
    }
end
package.preload["tools.routes"] = function()
    return { levelNames = function() return world.covered or {} end }
end
package.preload["tools.scan"] = function()
    return {
        RANGE = 30000,
        recordNow = function(_, _, range)
            world.scanned[#world.scanned + 1] = { level = world.current, range = range }
            return 7, 3, 2
        end,
    }
end

local scansweep = require("tools.scansweep")

local function trigger(text)
    local f = assert(io.open(tmp .. "\\scansweep.txt", "w"))
    f:write(text)
    f:close()
end

-- A trigger file as Windows PowerShell writes one: Set-Content -Encoding utf8 puts a byte order mark
-- in front, and those three bytes used to stick to the first option and stop it being read.
local function triggerBom(text)
    local f = assert(io.open(tmp .. "\\scansweep.txt", "wb"))
    f:write("\239\187\191" .. text)
    f:close()
end

local function progress()
    local f = io.open(tmp .. "\\scansweep_progress.txt", "r")
    if not f then return "(none)" end
    local v = f:read("l")
    f:close()
    return v
end

-- os.clock() is CPU time, which barely moves in a tight loop, and the sweep's poll and timeouts are
-- all in it: drive it by hand so a frame is a real second.
local fakeClock = 0
os.clock = function() return fakeClock end

-- One frame. The travel and the game switch resolve after a couple of them, as they do in game.
local function frame(dt)
    fakeClock = fakeClock + (dt or 1.0)
    if world.travelling then
        world.arriveIn = world.arriveIn - 1
        if world.arriveIn <= 0 then
            world.travelling = false
            if not world.neverArrives[world.travelTo] then world.current = world.travelTo end
        end
    end
    if world.pendingGame then
        world.gameIn = world.gameIn - 1
        if world.gameIn <= 0 then
            world.current = "LS" .. world.pendingGame .. "01"
            world.pendingGame = nil
        end
    end
    scansweep.update({}, {}, { dt = dt or 1.0 }, world.touring)
end

-- The first frame is what reads the trigger file and starts the run, so the break can only look at
-- whether a run that had started has ended.
local function run(frames, dt)
    local started = false
    for _ = 1, frames do
        frame(dt)
        if scansweep.running() then
            started = true
        elseif started then
            break
        end
    end
end

local function check(label, got, want)
    local ok = tostring(got) == tostring(want)
    print(string.format("%-58s %s (got %s, want %s)", label, ok and "PASS" or "**FAIL**",
        tostring(got), tostring(want)))
    return ok
end

local failures = 0
local function expect(...) if not check(...) then failures = failures + 1 end end

local function scannedList()
    local names = {}
    for _, s in ipairs(world.scanned) do names[#names + 1] = s.level end
    return table.concat(names, ",")
end

local function reset(levelNames)
    world.levelNames = levelNames
    world.scanned, world.travelling, world.pendingGame = {}, false, nil
    world.travelFails, world.neverArrives, world.startGameFails, world.cutsceneLevels = {}, {}, {}, {}
    world.covered, world.startGameCalls, world.touring = nil, 0, false
    os.remove(tmp .. "\\scansweep_progress.txt")
    os.remove(tmp .. "\\scansweep.stop")
end

print("=== 1. three levels in one game, from the level Spyro is already in")
reset({ "LS104", "LS106", "LS107" })
world.current = "LS104"
trigger("restart")
run(200)
expect("every level scanned", scannedList(), "LS104,LS106,LS107")
expect("run finished", scansweep.running(), false)
expect("progress past the end", progress(), "4")

print("\n=== 2. game= filter and a cross-game switch")
reset({ "LS104", "LS201", "LS202", "LS301" })
world.current = "LS104"
trigger("restart game=2 switch")
run(300)
expect("only Spyro 2 levels", scannedList(), "LS201,LS202")

print("\n=== 3. level= filter, a travel that cannot start, and one that never arrives")
reset({ "LS104", "LS106", "LS107", "LS108" })
world.current = "LS104"
world.travelFails["LS106"] = true
world.neverArrives["LS107"] = true
trigger("restart level=LS104,LS106,LS107,LS108")
run(400)
expect("the two bad levels skipped", scannedList(), "LS104,LS108")

print("\n=== 4. new= skips levels that already have stops")
reset({ "LS104", "LS106", "LS107" })
world.current = "LS104"
world.covered = { "LS106" }
trigger("restart new")
run(300)
expect("LS106 left out", scannedList(), "LS104,LS107")

print("\n=== 5. resume from the progress file, and the stop file")
reset({ "LS104", "LS106", "LS107" })
world.current = "LS104"
trigger("restart")
run(10)           -- long enough for LS104 (8 s settle), and the stop then lands mid-travel to LS106
local f = assert(io.open(tmp .. "\\scansweep.stop", "w")) f:write("") f:close()
run(60)
expect("stopped before the end", scansweep.running(), false)
local firstPass = scannedList()
local stopped = progress()
expect("first pass got LS104", firstPass, "LS104")
expect("progress points at LS106", stopped, "2")
world.scanned = {}
trigger("")       -- no restart: carries on from the progress file
run(300)
expect("resumed where it stopped, nothing done twice", scannedList(), "LS106,LS107")

print("\n=== 6. settle= and range= options, and a cutscene on arrival")
reset({ "LS104", "LS106" })
world.current = "LS104"
world.cutsceneLevels["LS106"] = true
trigger("restart settle=2 range=90000")
run(400, 0.5)
expect("both scanned despite the cutscene", scannedList(), "LS104,LS106")
expect("range passed through to the scan", world.scanned[1] and world.scanned[1].range, 90000)

print("\n=== 7. with switch=, a failing start game skips that game's levels")
reset({ "LS104", "LS201", "LS202", "LS106" })
world.current = "LS104"
world.startGameFails[2] = true
trigger("restart switch")
run(400)
expect("Spyro 2 skipped, Spyro 1 still done", scannedList(), "LS104,LS106")

print("\n=== 7b. without switch=, another game's levels are skipped at once")
reset({ "LS104", "LS201", "LS202", "LS106" })
world.current = "LS104"
trigger("restart")
run(400)
expect("only this game's levels", scannedList(), "LS104,LS106")
expect("start game was never called", world.startGameCalls or 0, 0)

print("\n=== 8. no levels match")
reset({ "LS104" })
trigger("restart game=3")
run(5)
expect("run did not start", scansweep.running(), false)

print("\n=== 9. flight levels and speedways are left out, and all= takes them")
reset({ "LS104", "LS105", "LS111", "LS106" })  -- LS105 and LS111 are flight levels
world.current = "LS104"
trigger("restart")
run(300)
expect("the flight levels left out", scannedList(), "LS104,LS106")
reset({ "LS104", "LS105", "LS111", "LS106" })
world.current = "LS104"
trigger("restart all")
run(400)
expect("all= takes them", scannedList(), "LS104,LS105,LS111,LS106")
reset({ "LS104", "LS105" })
world.current = "LS104"
trigger("restart level=LS105")
run(200)
expect("a level= list names one anyway", scannedList(), "LS105")

print("\n=== 10a. a resume whose options changed starts over instead of jumping")
reset({ "LS104", "LS106", "LS107", "LS108" })
world.current = "LS104"
trigger("restart")
run(20)           -- two levels in
local f10 = assert(io.open(tmp .. "\\scansweep.stop", "w")) f10:write("") f10:close()
run(60)
world.scanned = {}
trigger("game=1") -- a different filter: the saved index does not apply to it
run(400)
expect("started over under new options", scannedList(), "LS104,LS106,LS107,LS108")

print("\n=== 10b. a whole sweep of skipped levels unwinds without erroring")
local many = {}
for n = 101, 135 do many[#many + 1] = "LS" .. n end
reset(many)
world.current = "LS101"
world.covered = many
trigger("restart new")
run(400)
expect("nothing scanned, run ended cleanly", scannedList(), "")
expect("run finished", scansweep.running(), false)

print("\n=== 10c. a world tour and a sweep never run at once")
reset({ "LS104", "LS106", "LS107" })
world.current = "LS104"
world.touring = true
trigger("restart")
run(40)
expect("a sweep will not start under a tour", scannedList(), "")
world.touring = false
trigger("restart")
run(30)                 -- one level in, then a tour starts
world.touring = true
run(20)
expect("a sweep stops when a tour starts", scansweep.running(), false)
world.touring = false

print("\n=== 10d. a trigger file written by PowerShell (with a BOM) still parses")
reset({ "LS104", "LS201", "LS202", "LS106" })
world.current = "LS201"
triggerBom("restart game=2")
run(300)
expect("the first option survived the BOM", scannedList(), "LS201,LS202")

print("\n=== 10. the fixed list stands in for an unreadable level table")
reset(nil)
world.current = "LS101"
trigger("restart")
run(300)
expect("swept the fixed list", scannedList(), "LS101,LS102")

print(string.format("\n%s", failures == 0 and "ALL PASS" or (failures .. " FAILURE(S)")))
os.exit(failures == 0 and 0 or 1)
