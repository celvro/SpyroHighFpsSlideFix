-- Skelos Badlands lava lizard step fix
--
-- The lava lizards of the Skelos Badlands orb mission walk to the caveman babies in their WalkToGuy
-- state, which is Phasmid waypoint traversal: MovementMode 6 (Custom), MaxWalkSpeed 143, and the
-- traversal asks for that speed itself (RequestedVelocity and Acceleration stay 0). Two steps near the
-- end of the long route stopped the lizard that walks it at high FPS. Measured uncapped (≈208 FPS)
-- against 30 FPS, same route: 9.75 s with 3.01 s of it standing still, against 6.94 s with none.
-- At each step every frame's swept move blocked at Hit.Time 0 against the riser face (normal z 0.00):
-- 176 of 179 frames with no displacement at all in the first stall, 401 of 445 in the second, with 178
-- of 180 and 443 of 446 blocking hits at Time 0. MaxStepHeight is already 900 during that walk, so the
-- height is not the problem: the move is. The requested move is 143 * dt, which is 4.8 units at 30 FPS
-- but 0.45 at 320, and a step-up is only accepted once the forward part of the move is big enough. It
-- cleared the step on a 10 ms frame (1.4 units) and on 30-36 ms frames (4.8), never on the 4-5 ms
-- frames in between, so the lizard only got up on a hitch. See docs/findings/skelos-badlands.md.
--
-- A second run showed the stall has two shapes: in the first the lizard kept the full 143 in `Velocity`
-- all through it, in the second (12.7 s, 2006 of 2022 frames still, 2019 of 2022 hits at Time 0, and the
-- mission gave up on it) `Velocity` sat at exactly 0 and only reached 7.1 at its best, which is the
-- (1/32)/dt lock of a restart from rest against the wall (sliding-walking.md, buzz-charge-run.md). So
-- Velocity cannot be the test for "it is trying to walk": the trigger is MovementMode 6, no
-- displacement, and the FalconEnemy state being WalkToGuy.
--
-- The fix gives a blocked lizard its time in 30 FPS portions: once it has been blocked for a few
-- frames, its CustomTimeDilation is set so that one tick in every 1/30 s gets a whole 30 FPS frame of
-- time (REFERENCE_DT / dt) and the ticks in between get almost none, which is the same trick
-- fixes/dust.lua uses on a one-tick effect. The lizard then asks for 4.8 units in that one tick, the
-- engine steps it up exactly as it does at 30 FPS, and the total time it gets is unchanged. Normal time
-- comes back as soon as its slices are moving again. Frames of 1/30 s or longer, and any lizard the
-- game is already time-dilating itself, are left alone.

local config = require("config")
local engine = require("lib.engine")
local log = require("lib.log")
local lookup = require("lib.lookup")
local profiler = require("profiler")
local util = require("lib.util")

local fix = { name = "lava lizard step fix", enabled = config.FIX_LIZARD_STEPS, failed = false }

-- The lizards load with Skelos Badlands, so the function object is replaced every time the level
-- loads and the hook is registered again (lookup.hookLevelFunction).
local hook = {
    class = "BP_LavaLizard_C",
    path = "/CES2031_LavaLizard/Blueprints/BP_LavaLizard.BP_LavaLizard_C:ReceiveTick",
    hooked = nil, failures = 0, retryIn = 0, lookups = 1,
}

local MOVE_CUSTOM = 6          -- Phasmid spline and waypoint traversal, the only mode that stalls this way
local STILL = 1e-3             -- horizontal displacement that counts as not having moved
local WALK_STATE = "WalkToGuy"  -- the only state of this lizard that traverses waypoints
local BLOCKED_FRAMES = 3       -- blocked frames in a row before the portions start
local SILENT_DILATION = 1e-3   -- time scale for the ticks in between (0 could divide by zero)
local MOVED_SHARE = 0.25       -- share of a 30 FPS move a portion must cover to count as moving
local GOOD_PORTIONS = 2        -- moving portions in a row that give normal time back
local JUDGE_FRAMES = 2         -- frames a portion is given to show up as displacement
local MAX_STEPPING = 10        -- seconds of portions for one lizard before giving its time back anyway

local tracked = {}  -- lizard address -> { actor, x, y, blocked, stepping, owed, written, judge, good, ... }
local handled = {}  -- lizard address -> engine.frame of the tick already handled
local lastCallback = -1

local function logStint(e)
    log("%s: %s stepped for %.3fs, %d portions (%d moved) over %d frames, %s",
        fix.name, e.name or "?", e.steppingTime, e.portions, e.movedPortions, e.frames,
        e.good >= GOOD_PORTIONS and "cleared" or "given up")
end

-- Puts normal time back and forgets the stint. `keepEntry` keeps the position so the next frame can
-- carry on measuring displacement instead of spending a frame seeding it again.
local function release(address, e, keepEntry)
    if e and e.stepping then
        e.stepping = false
        local actor = e.actor
        -- Only put back what this fix wrote: if something else has taken the dilation over, leave it.
        if actor and actor:IsValid() and actor.CustomTimeDilation == e.written then
            actor.CustomTimeDilation = 1
        end
        logStint(e)
    end
    if not keepEntry then
        tracked[address] = nil
        return
    end
    if e then
        e.blocked, e.owed, e.judge, e.good, e.written = 0, 0, 0, 0, nil
    end
end

local function restoreAll()
    for address, e in pairs(tracked) do release(address, e, false) end
end

local function startStepping(e)
    e.stepping = true
    e.owed = util.REFERENCE_DT -- it has already lost BLOCKED_FRAMES frames: the first portion is due now
    e.judge, e.good, e.portions, e.movedPortions, e.steppingTime = 0, 0, 0, 0, 0
    e.frames = e.blocked
end

local stateCheckFailed = false

-- Is this lizard walking its waypoint route? Only asked on a frame that is already blocked, so the call
-- costs nothing while the lizards walk normally. If it does not work in this build the fix goes ahead on
-- the movement mode alone and says so once.
local function walkingState(lizard)
    if stateCheckFailed then return true end
    local ok, name = pcall(function() return lizard.FalconEnemy:BP_GetCurrentStateName():ToString() end)
    if not ok then
        stateCheckFailed = true
        log("%s: BP_GetCurrentStateName unavailable (%s); going by the movement mode alone",
            fix.name, tostring(name))
        return true
    end
    return name == WALK_STATE
end

local function correct(lizard)
    local address = lizard:GetAddress()
    if handled[address] == engine.frame then return end
    handled[address] = engine.frame
    lastCallback = engine.frame
    local e = tracked[address]

    local cmc = lizard.CharacterMovement
    if not cmc:IsValid() then return release(address, e, false) end
    -- Cheap scalar reads first: only a lizard walking a waypoint route can be in this stall, and
    -- only frames shorter than a 30 FPS frame have anything to fix.
    if cmc.MovementMode ~= MOVE_CUSTOM then return release(address, e, false) end
    -- The real length of the frame, not the lizard's own dilated tick time, because that is what the
    -- portions are counted against (fixes/buzz.lua wants the dilated one and multiplies).
    local dt = engine.worldDeltaSeconds(lizard)
    if not util.aboveReferenceFps(dt) then return release(address, e, true) end
    local dilation = lizard.CustomTimeDilation

    local loc = lizard:K2_GetActorLocation()
    if not e then
        -- Something else is already dilating this lizard (the game, or another mod): stay out of it.
        if dilation ~= 1 then return end
        tracked[address] = { actor = lizard, name = lizard:GetFName():ToString(), x = loc.X, y = loc.Y,
                             blocked = 0, stepping = false, owed = 0, judge = 0, good = 0 }
        return
    end
    e.actor = lizard
    local dx, dy = loc.X - e.x, loc.Y - e.y
    local moved = math.sqrt(dx * dx + dy * dy)
    e.x, e.y = loc.X, loc.Y

    if not e.stepping then
        if dilation ~= 1 then return end
        if moved > STILL then
            e.blocked, e.waiting = 0, false
            return
        end
        e.blocked = e.blocked + 1
        if e.blocked < BLOCKED_FRAMES or e.waiting then return end
        -- Velocity is no use as the "it is trying to walk" test: one stall left it at 0.00 for 12.7 s
        -- while another kept the full 143 throughout, so the state decides. A lizard that is just
        -- standing about is asked once and then left alone until it moves again.
        if not walkingState(lizard) then
            e.waiting = true
            return
        end
        startStepping(e)
    elseif dilation ~= e.written then
        -- Something else took the dilation over while a stint was running.
        e.stepping = false
        logStint(e)
        return release(address, e, true)
    else
        e.steppingTime = e.steppingTime + dt
        e.frames = e.frames + 1
        -- Did the last portion move it? It is the tick after the portion was written that spends it,
        -- so the displacement is looked for over the next JUDGE_FRAMES frames.
        if e.judge > 0 then
            if moved >= MOVED_SHARE * util.REFERENCE_DT * cmc.MaxWalkSpeed then
                e.judge, e.good, e.movedPortions = 0, e.good + 1, e.movedPortions + 1
                if e.good >= GOOD_PORTIONS then return release(address, e, true) end
            else
                e.judge = e.judge - 1
                if e.judge == 0 then e.good = 0 end
            end
        end
        if e.steppingTime > MAX_STEPPING then return release(address, e, true) end
    end

    -- One tick in every 1/30 s gets a whole 30 FPS frame of time; the ones in between get almost none,
    -- so the lizard moves in the portions the engine's step-up can act on.
    e.owed = e.owed + dt
    if e.owed >= util.REFERENCE_DT - 1e-4 then
        e.owed = math.max(e.owed - util.REFERENCE_DT, 0)
        e.written = util.REFERENCE_DT / dt
        e.portions, e.judge = e.portions + 1, JUDGE_FRAMES
    else
        e.written = SILENT_DILATION
    end
    lizard.CustomTimeDilation = e.written
    -- Read back what the float property kept, so the "has something else taken it over" test below and
    -- the restore in release compare exactly instead of against the unrounded double.
    e.written = lizard.CustomTimeDilation
end

-- Registered as both the pre and the post callback (this UE4SS build calls only one for Blueprints),
-- so it acts once per frame per lizard. An error would repeat every frame, so the first one stops it.
local onTick = profiler.wrapHook("lizard", function(context)
    if fix.failed then return end
    local ok, err = pcall(correct, context:get())
    if not ok then
        fix.failed = true
        pcall(restoreAll)
        log("%s disabled after hook error: %s", fix.name, tostring(err))
    end
end)

function fix.update()
    local result = lookup.hookLevelFunction(hook, onTick, fix.name)
    if result == "hooked" then tracked, handled = {}, {} end
    if result == "failed" then fix.failed = true end
    -- Callbacks stopped (a pause, a level change): don't leave a lizard almost frozen.
    if lastCallback < engine.frame - 1 and next(tracked) then
        restoreAll()
        lastCallback = engine.frame
    end
end

function fix.disable()
    pcall(restoreAll)
end

if fix.enabled then
    lookup.watch("/Script/Engine.BlueprintGeneratedClass", hook.class, hook)
end

return fix
