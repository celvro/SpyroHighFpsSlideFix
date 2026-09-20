-- Every NPC and enemy (PhasmidCharacter): does it start moving when its movement asks it to? Spyro, Buzz
-- and Sheila stood still at high FPS because their first move from rest, MaxAcceleration·dt² per axis,
-- rounds to nothing on the 1/32 position grid far from the origin (docs/findings/sliding-walking.md,
-- buzz-charge-run.md, sheila-buzz-walk.md). This watches every character for the same symptom.
--
-- A "stretch" is a run of frames in Walking/NavWalking/Swimming/Flying/Custom where the character wants to
-- move: input acceleration is nonzero, or RequestedVelocity is nonzero and changed since the last frame (a
-- stale request stays set after a move ends), or it is in Custom mode. It ends after STRETCH_GAP without these.
--
--   stalls_<stamp>.csv  one row per stretch of MIN_STRETCH or longer: framerate, still frames (horizontal
--                       Velocity exactly 0), first move and time to 50% of the mode's max speed from the
--                       stretch start, speeds, MaxAcceleration, and whether it was flagged.
--   "stall" lines       flagged stretches, at most one per class per LOG_INTERVAL: it didn't move for
--                       STALL_TIME (and 5 frames), or (not in Custom mode) it reached 50% of max speed well after its
--                       acceleration allows (2x + 0.1 s).
--   "stallsummary"      per class on a pawn change (level load, respawn) and every SUMMARY_INTERVAL:
--                       stretches, stretches from rest, flagged ones, and the worst first move.
local levels = require("lib.levels")
local log = require("lib.log")
local paths = require("lib.paths")
local state = require("lib.state")
local util = require("lib.util")

local num = util.num

local stalls = { CLASS = "/Script/Phasmid.PhasmidCharacter" }

local STRETCH_GAP = 0.1      -- seconds without wanting to move that end a stretch
local MIN_STRETCH = 0.05     -- shorter stretches aren't written
local STALL_TIME = 0.05      -- seconds without moving from the stretch start that flag it
local FROM_REST = 1.0        -- start speed below which a stretch counts as starting from rest
local LOG_INTERVAL = 10      -- seconds between "stall" lines for one class
local SUMMARY_INTERVAL = 60
local LEVEL_INTERVAL = 5     -- seconds between current-level lookups (they walk every streaming level)
local LOOKUPS = util.NEW_OBJECT_LOOKUPS
-- Movement modes whose velocity is reset from the displacement after the move (UE 4.19), plus Custom (6,
-- the Phasmid spline and flee modes) to see how it behaves.
local WATCHED_MODES = { [1] = true, [2] = true, [4] = true, [5] = true, [6] = true }

local entries = {}      -- address -> { actor, cmc, class, name, rx, ry, run, lastWant }
local pending = {}      -- objects reported by NotifyOnNewObject, resolved on the next frame
local classes = {}      -- class -> { stretches, fromRest, flagged, worstFirstMove, lastLog }
local lookup = { lookups = LOOKUPS, nextLookup = 0 }
local level, nextLevelCheck = nil, 0
local nextSummary = SUMMARY_INTERVAL
local summaryDirty = false
local errorLogged = false
local file = nil

local ignored = {} -- addresses tools/spawntest.lua parked (frozen, kept only to hold their classes)

local function add(actor)
    if not actor:IsValid() then return end
    local address = actor:GetAddress()
    if entries[address] then return end
    if ignored[address] then return end
    local name = actor:GetFName():ToString()
    if name:match("^Default__") then return end
    entries[address] = { actor = actor, class = actor:GetClass():GetFName():ToString(), name = name }
end

local function maxSpeed(cmc, mode)
    if mode == 5 then return num(cmc.MaxFlySpeed) end
    if mode == 4 then return num(cmc.MaxSwimSpeed) end
    if mode == 6 then return num(cmc.MaxCustomMovementSpeed) end
    return num(cmc.MaxWalkSpeed)
end

local function classStats(class)
    local c = classes[class]
    if not c then
        c = { stretches = 0, fromRest = 0, flagged = 0, worstFirstMove = 0, neverMoved = 0, lastLog = -math.huge }
        classes[class] = c
    end
    return c
end

local function fmtTime(t)
    return t and string.format("%.3f", t) or "never"
end

local function openFile()
    file = io.open(paths.stalls, "w")
    if file then
        file:write("time,level,class,name,mode,fps_cap,avg_fps,duration,frames,still_frames,longest_still,first_move,t50,"
            .. "expected_t50,start_speed,speed_max,avg_speed,max_speed,max_accel,req_speed_max,accel_input,x,y,flagged\n")
    end
end

local function finish(e, now)
    local run = e.run
    e.run = nil
    local duration = run.lastWant - run.start
    if duration < MIN_STRETCH or run.frames == 0 then return end
    local avgDt = run.dtSum / run.frames
    local expected = run.maxAccel > 0 and 0.5 * run.maxSpeed / run.maxAccel or math.huge
    local stalled = (run.firstMove or duration) > math.max(STALL_TIME, 5 * avgDt)
    -- Custom mode's MaxCustomMovementSpeed isn't the speed it runs at (bulls cruise at 205 under 600),
    -- so there only standing still counts.
    local slow = run.mode ~= 6 and run.maxSpeed > 0 and duration > 2 * expected + 0.1 and (run.t50 or duration) > 2 * expected + 0.1
    local fromRest = run.startSpeed < FROM_REST
    local flagged = stalled or slow
    local c = classStats(e.class)
    c.stretches = c.stretches + 1
    if fromRest then c.fromRest = c.fromRest + 1 end
    if flagged then c.flagged = c.flagged + 1 end
    if not run.firstMove then c.neverMoved = c.neverMoved + 1 end
    c.worstFirstMove = math.max(c.worstFirstMove, run.firstMove or duration)
    summaryDirty = true

    if not file then openFile() end
    if file then
        file:write(string.format("%.4f,%s,%s,%s,%d,%s,%.1f,%.4f,%d,%d,%.4f,%s,%s,%.3f,%.2f,%.2f,%.2f,%.1f,%.1f,%.1f,%s,%.2f,%.2f,%s\n",
            run.start, tostring(level or ""), e.class, e.name, run.mode, tostring(state.fpsCap or ""), run.frames / run.dtSum,
            duration, run.frames, run.stillFrames, run.longestStill, fmtTime(run.firstMove), fmtTime(run.t50),
            expected, run.startSpeed, run.speedMax, run.distance / run.dtSum, run.maxSpeed, run.maxAccel,
            run.reqMax, tostring(run.accelInput), run.x, run.y, flagged and (stalled and "stalled" or "slow") or ""))
    end
    if flagged and now - c.lastLog >= LOG_INTERVAL then
        c.lastLog = now
        log("stall %s (%s) level=%s mode=%s cap=%s avgFps=%.1f duration=%.3fs still=%d/%d (longest %.3fs) firstMove=%s t50=%s (expected %.3f) startSpeed=%.1f speedMax=%.1f maxSpeed=%.1f maxAccel=%.1f input=%s",
            e.class, e.name, tostring(level), util.MOVE_MODE_NAMES[run.mode] or tostring(run.mode),
            tostring(state.fpsCap or "?"), run.frames / run.dtSum, duration, run.stillFrames, run.frames,
            run.longestStill, fmtTime(run.firstMove), fmtTime(run.t50), expected, run.startSpeed, run.speedMax,
            run.maxSpeed, run.maxAccel, run.accelInput and "accel" or "request")
    end
end

local function logSummary(why)
    if not summaryDirty then return end
    summaryDirty = false
    local names = {}
    for class in pairs(classes) do names[#names + 1] = class end
    table.sort(names)
    log("stallsummary (%s, level %s, cap %s): %d classes", why, tostring(level), tostring(state.fpsCap or "?"), #names)
    for _, class in ipairs(names) do
        local c = classes[class]
        log("stallsummary %s stretches=%d fromRest=%d flagged=%d neverMoved=%d worstFirstMove=%.3fs",
            class, c.stretches, c.fromRest, c.flagged, c.neverMoved, c.worstFirstMove)
    end
    if file then file:flush() end
end

local function updateEntry(e, r, dt, pawnAddress)
    local actor = e.actor
    if not actor:IsValid() then return false end
    if not e.cmc then
        local cmc = actor.CharacterMovement
        if not cmc or not cmc:IsValid() then return true end
        e.cmc = cmc
    end
    local cmc = e.cmc
    if not cmc:IsValid() then return false end
    if actor:GetAddress() == pawnAddress then return true end -- Spyro (or whoever the player controls)

    local mode = cmc.MovementMode
    local req = cmc.RequestedVelocity
    local rx, ry = req.X, req.Y
    local changed = rx ~= e.rx or ry ~= e.ry
    e.rx, e.ry = rx, ry
    if not WATCHED_MODES[mode] then
        if e.run then finish(e, r.time) end
        return true
    end
    local acc = cmc.Acceleration
    local ax, ay = acc.X, acc.Y
    local accelInput = ax ~= 0 or ay ~= 0
    -- Custom (6) is Phasmid's spline and flee traversal, which may not go through either: count all of it.
    local want = accelInput or ((rx ~= 0 or ry ~= 0) and changed) or mode == 6

    local run = e.run
    if run and (mode ~= run.mode or (not want and r.time - run.lastWant > STRETCH_GAP)) then
        finish(e, r.time)
        run = nil
    end
    if not want and not run then return true end

    local vel = cmc.Velocity
    local speed = math.sqrt(vel.X * vel.X + vel.Y * vel.Y)
    if not run then
        local loc = actor:K2_GetActorLocation()
        run = { mode = mode, start = r.time, lastWant = r.time, startSpeed = speed, frames = 0, dtSum = 0,
                stillFrames = 0, still = 0, longestStill = 0, speedMax = 0, distance = 0, reqMax = 0,
                maxSpeed = maxSpeed(cmc, mode), maxAccel = num(cmc.MaxAcceleration), accelInput = accelInput,
                x = loc.X, y = loc.Y }
        e.run = run
        return true -- the first frame's velocity is from before the request
    end
    if want then run.lastWant = r.time end
    run.accelInput = run.accelInput or accelInput
    run.frames, run.dtSum = run.frames + 1, run.dtSum + dt
    run.distance = run.distance + speed * dt
    run.speedMax = math.max(run.speedMax, speed)
    run.reqMax = math.max(run.reqMax, math.sqrt(rx * rx + ry * ry))
    if speed == 0 then
        run.stillFrames = run.stillFrames + 1
        run.still = run.still + dt
        run.longestStill = math.max(run.longestStill, run.still)
    else
        run.still = 0
        if not run.firstMove then run.firstMove = r.time - run.start end
    end
    if not run.t50 and run.maxSpeed > 0 and speed >= 0.5 * run.maxSpeed then run.t50 = r.time - run.start end
    return true
end

local function update(r, prev, pawn)
    for i = #pending, 1, -1 do
        pcall(add, pending[i])
        pending[i] = nil
    end
    if util.lookupDue(lookup, r.time) then
        for _, actor in ipairs(FindAllOf("PhasmidCharacter") or {}) do add(actor) end
    end
    if r.time >= nextLevelCheck then
        nextLevelCheck = r.time + LEVEL_INTERVAL
        level = levels.current(pawn)
    end
    local dt = prev and r.time - prev.time or 0
    if dt <= 0 then return end
    local pawnAddress = pawn:GetAddress()
    for address, e in pairs(entries) do
        local ok, keep = pcall(updateEntry, e, r, dt, pawnAddress)
        if not ok then
            if not errorLogged then
                errorLogged = true
                log("stalls error (%s): %s", e.name, tostring(keep))
            end
            keep = false
        end
        if not keep then
            if e.run then pcall(finish, e, r.time) end
            entries[address] = nil
        end
    end
    if r.time >= nextSummary then
        nextSummary = r.time + SUMMARY_INTERVAL
        logSummary("periodic")
    end
end

function stalls.update(r, prev, pawn)
    local ok, err = pcall(update, r, prev, pawn)
    if not ok and not errorLogged then
        errorLogged = true
        log("stalls error: %s", tostring(err))
    end
end

-- NotifyOnNewObject runs while the object is being constructed: just queue it.
function stalls.onNewObject(object)
    pending[#pending + 1] = object
end

-- A new pawn usually means a new level: summarize the old one, then look for the new level's characters.
function stalls.pawnChanged()
    logSummary("pawn changed")
    classes = {}
    lookup.lookups, lookup.nextLookup, nextLevelCheck = LOOKUPS, 0, 0
end

-- Stop watching an actor for good (the spawn test's parked types): reading them every frame costs framerate.
function stalls.ignore(actor)
    local address = actor:GetAddress()
    ignored[address] = true
    entries[address] = nil
end

function stalls.summary(why)
    summaryDirty = true
    logSummary(why)
end

return stalls
