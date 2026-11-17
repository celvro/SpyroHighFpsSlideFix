-- Drives the probe's command channel (lib/cmd.lua) against stubbed modules: cmd.txt parsing (ids, a
-- BOM, comments, several lines), unknown verbs, `key` pressing recorded key binds, commands that wait
-- for Spyro (and give up), the started -> done commands (travel, replay, replay-record), trigger files
-- written without a BOM, and eval.
--
--   lua tools\tests\cmd_test.lua
--
-- Exits non-zero on a failure.
local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\]tools[/\\]tests[/\\]") or "."
package.path = here .. "\\ue4ss\\DevMods\\SpyroFpsProbe\\Scripts\\?.lua;" .. package.path

local tmp = os.getenv("TEMP") .. "\\cmdtest"
os.execute('mkdir "' .. tmp .. '" 2>nul')
os.execute('del /q "' .. tmp .. '\\*" 2>nul')

local now = 0
os.clock = function() return now end

local world = {
    pawn = true, level = "LS102", travelling = false, travelTo = nil,
    replayRunning = false, recording = false, saved = nil, playRequests = {},
}

-- ---------------------------------------------------------------- stubs

local function valid(t) t.IsValid = function() return true end return t end
local cmcStub = valid({ Velocity = nil })
local pawnStub = valid({ CharacterMovement = cmcStub, Name = "spyro" })
pawnStub.K2_GetActorRotation = function() return { Pitch = 0, Yaw = 90, Roll = 0 } end
pawnStub.K2_TeleportTo = function(_, loc, rot) world.teleported = { loc = loc, rot = rot } return true end
local pcStub = valid({})
setmetatable(pcStub, { __index = function(_, k)
    if k == "Pawn" then return world.pawn and pawnStub or { IsValid = function() return false end } end
end })

package.preload["UEHelpers"] = function()
    return { GetPlayerController = function() return pcStub end }
end
package.preload["lib.log"] = function()
    return function(fmt, ...) if os.getenv("CMDTEST_VERBOSE") then print("[log] " .. string.format(fmt, ...)) end end
end
package.preload["lib.paths"] = function() return { modDir = tmp, stamp = "test" } end
package.preload["lib.levels"] = function()
    return { current = function() return world.level, { X = 1000, Y = 2000 } end }
end
package.preload["tools.quicksave"] = function()
    return {
        travel = function(_, level) world.travelling, world.travelTo = true, level return true end,
        travelling = function() return world.travelling end,
        request = function(kind) world.quicksave = kind end,
        reloadLevel = function(_, onDone) world.reloadDone = onDone return true end,
    }
end
package.preload["lib.gameswap"] = function()
    return { running = function() return false end, begin = function(g) world.swap = g end,
             finished = function() local r = world.swapResult world.swapResult = nil return r end }
end
local finishListeners = {}
package.preload["tools.replay"] = function()
    return {
        running = function() return world.replayRunning end,
        recording = function() return world.recording end,
        lastSaved = function() return world.saved end,
        takes = function() return { { id = "LS102_b" }, { id = "LS102_a" } } end,
        requestPlay = function(id) world.playRequests[#world.playRequests + 1] = id or "newest" end,
        requestReset = function() world.resetRequested = true end,
        requestReplay = function() world.endPressed = true end,
        requestRecord = function() world.recordToggled = true end,
        onFinish = function(fn) finishListeners[#finishListeners + 1] = fn end,
    }
end
local function finishReplay(summary)
    for _, fn in ipairs(finishListeners) do fn(summary) end
end

Key = { F5 = 116, END = 35, O = 79 }
ModifierKey = { CONTROL = 162 }
local realBinds = {}
RegisterKeyBind = function(key, a, b) realBinds[#realBinds + 1] = key end

local cmd = require("lib.cmd")
local state = require("lib.state")
state.fpsCap = 30
local capsSet = {}
-- Like main.lua's: state.fpsCap changes only once the queued game-thread call runs (next frames()).
local queuedCap = nil
local function setFpsCap(cap) capsSet[#capsSet + 1] = cap queuedCap = cap end

-- Bound after cmd loads, the way main.lua does it.
local pressed = {}
RegisterKeyBind(Key.F5, function() pressed[#pressed + 1] = "F5" end)
RegisterKeyBind(Key.END, function() pressed[#pressed + 1] = "END" end)
RegisterKeyBind(Key.O, { ModifierKey.CONTROL }, function() pressed[#pressed + 1] = "CTRL+O" end)

-- ---------------------------------------------------------------- helpers

local failures = 0
local function check(cond, what)
    if cond then print("ok   " .. what) else failures = failures + 1 print("FAIL " .. what) end
end

local function write(text)
    local f = assert(io.open(tmp .. "\\cmd.txt", "wb"))
    f:write(text)
    f:close()
end

local function frames(n, dt)
    for _ = 1, n or 10 do
        now = now + (dt or 0.1)
        if queuedCap then state.fpsCap, queuedCap = queuedCap, nil end
        cmd.update(setFpsCap)
    end
end

local function results()
    local list = {}
    local f = io.open(tmp .. "\\cmd_result.txt", "r")
    if not f then return list end
    for line in f:lines() do
        local id, status, text = line:match("^([^\t]*)\t([^\t]*)\t(.*)$")
        list[#list + 1] = { id = id, status = status, text = text }
    end
    f:close()
    return list
end

local function resultsFor(id)
    local list = {}
    for _, r in ipairs(results()) do if r.id == id then list[#list + 1] = r end end
    return list
end

local function last(id)
    local list = resultsFor(id)
    return list[#list] or {}
end

local function exists(path)
    local f = io.open(path, "r")
    if f then f:close() return true end
    return false
end

-- ---------------------------------------------------------------- cases

-- Parsing: a BOM on the first line, an id, a comment, a blank line, an id-less line.
write("\239\187\191@a1 ping\n# a comment\n\n   cap 144  \n")
frames(9)
check(#results() == 0, "cmd.txt is not read before POLL_FRAMES frames")
frames(1)
check(not exists(tmp .. "\\cmd.txt") and not exists(tmp .. "\\cmd.taken"), "cmd.txt is taken and the taken copy removed")
check(last("a1").status == "ok" and last("a1").text:match("^pong"), "ping through a BOM answers ok")
check(last("n1").status == "ok" and capsSet[#capsSet] == 144, "an id-less line gets n1 and cap sets 144")
check(#results() == 2, "the comment and the blank line make no result")

write("@u1 frobnicate\n@c1 cap\n")
frames(10)
check(last("u1").status == "error" and last("u1").text:match("unknown command"), "an unknown verb is an error")
check(last("c1").status == "error", "cap without a number is an error")

-- Keys recorded on the way through RegisterKeyBind; the real one still ran.
check(#realBinds == 3, "the real RegisterKeyBind still runs for each bind")
write("@k1 key f5 End\n@k2 key ctrl+o\n@k3 key Q\n@k4 keys\n")
frames(10)
check(last("k1").status == "ok" and pressed[1] == "F5" and pressed[2] == "END", "key F5 End calls both binds in order")
check(last("k2").status == "ok" and pressed[3] == "CTRL+O", "a modifier bind is pressed as CTRL+O")
check(last("k3").status == "error", "a key the probe does not bind is an error")
check(last("k4").text:match("F5") and last("k4").text:match("CONTROL%+O"), "keys lists the binds")

-- A pawn command waits for Spyro, runs when he is back, and gives up after PAWN_WAIT.
world.pawn = false
write("@s1 state\n")
frames(10)
check(#resultsFor("s1") == 0, "state waits while there is no Spyro")
world.pawn = true
frames(1)
check(last("s1").status == "ok" and last("s1").text:match("level=LS102"), "state runs once Spyro is back")
world.pawn = false
write("@s2 teleport 1 2 3\n")
frames(10)
now = now + 121
frames(1)
check(last("s2").status == "error" and last("s2").text:match("no Spyro"), "a pawn command gives up after PAWN_WAIT")
world.pawn = true

write("@t1 teleport 10 20 30 yaw=45 rel\n")
frames(10)
check(last("t1").status == "ok" and world.teleported.loc.X == 1010 and world.teleported.loc.Y == 2020
      and world.teleported.rot.Yaw == 45, "teleport rel adds the level origin and takes yaw=")

-- travel: started, then done when the travel ends in the right level.
write("@v1 travel ls104\n@v2 travel LS201\n")
frames(10)
check(resultsFor("v1")[1].status == "started" and world.travelTo == "LS104", "travel starts the travel")
check(last("v2").status == "error" and last("v2").text:match("swap 2"), "travel to another game says to swap first")
frames(3)
check(#resultsFor("v1") == 1, "travel stays started while travelling")
world.travelling, world.level = false, "LS104"
frames(1)
check(last("v1").status == "done", "travel is done once Spyro is in the level")
world.level = "LS102"

-- replay: started, then done with the finish summary; a run that never starts is an error.
write("@r1 replay take=LS102_a cap=320\n")
frames(10)
check(world.playRequests[1] == "LS102_a" and capsSet[#capsSet] == 320, "replay asks for the take and sets the cap")
check(state.fpsCap == 320, "replay cap= is in state.fpsCap at once, before the queued console command runs")
world.replayRunning = true
frames(20)
check(last("r1").status == "started", "replay stays started while running")
world.replayRunning = false
finishReplay({ id = "LS102_a", cap = 320, reason = "completed", elapsed = 12.5, length = 12, path = "x.csv" })
frames(1)
check(last("r1").status == "done" and last("r1").text:match("trace=x.csv"), "replay is done with the trace path")

write("@r2 replay\n")
frames(10)
check(world.playRequests[2] == "newest", "replay without a take asks for the newest")
frames(60)
check(last("r2").status == "error" and last("r2").text:match("did not start"), "a replay that never starts is an error")

write("@r3 replay take=LS102_zzz\n")
frames(10)
finishReplay({ id = "LS102_zzz", reason = "unknown take", failed = true })
frames(1)
check(last("r3").status == "error" and last("r3").text:match("unknown take"), "an unknown take is an error")

-- replay-record stop answers with the saved take.
world.recording = true
write("@w1 replay-record stop\n")
frames(10)
check(world.recordToggled and last("w1").status == "started", "replay-record stop presses Home")
world.recording, world.saved = false, { id = "LS102_c", frames = 300, seconds = 10 }
frames(1)
check(last("w1").status == "done" and last("w1").text:match("take=LS102_c"), "replay-record stop is done with the take id")

-- trigger writes the tool's own file without a BOM.
write("@g1 trigger scansweep game=2 restart\n@g2 trigger evil\n")
frames(10)
local f = io.open(tmp .. "\\scansweep.txt", "rb")
local text = f and f:read("a")
if f then f:close() end
check(last("g1").status == "ok" and text == "game=2 restart", "trigger writes scansweep.txt with its options and no BOM")
check(last("g2").status == "error", "trigger refuses a tool it does not know")

-- eval
write("@e1 eval 1 + 2, pawn.Name\n@e2 eval state.fpsCap = 99\n@e3 eval (\n")
frames(10)
check(last("e1").status == "ok" and last("e1").text == "3, spyro", "eval returns its values")
check(last("e2").status == "ok" and state.fpsCap == 99, "eval runs a statement")
check(last("e3").status == "error", "a syntax error is an error")

-- help lists every verb
write("@h1 help\n")
frames(10)
check(last("h1").text:match("replay%-record") and last("h1").text:match("eval"), "help lists the verbs")

os.execute('rmdir /s /q "' .. tmp .. '" 2>nul')
print(failures == 0 and "all passed" or (failures .. " failure(s)"))
os.exit(failures == 0 and 0 or 1)
