-- NPC walk fix (requested moves from rest)
--
-- In Zephyr (Spyro 2, LS213) Sergeant Tub stands on the cannon at the level start. When his first
-- conversation ends, his controller (BP_LS213_TubController) sends him into his Move state, which walks
-- him off the cannon along PhasmidPatrolPath_1 so the next conversations happen down by the turret. His
-- AI requests each move directly, the same way as Sheila's (fixes/sheila.lua): RequestedVelocity with
-- bRequestedMoveUseAcceleration, accelerating at MaxAcceleration (2048) up to MaxWalkSpeed (100), in
-- Walking mode. The level sits on the 300,000 grid (1/32 position steps on both axes) and walking resets
-- Velocity to (displacement / dt), so at high FPS each frame's first step from rest rounds to nothing.
-- Measured (2026-11-18, his move started by the controller's MissionAlert, which is what the end of the
-- conversation sends):
--   30 FPS       100 units/s from the first half second, ~300 units in 3 s, then Idle at the bottom.
--   220-300 FPS  0-8 units/s, ~10 units in 4 s, then the Move state gives up and he is Idle on the
--                cannon for good.
-- Two things stop him, and this handles both, per actor, from the mod's tick:
--   rounding  While such an NPC walks, this keeps its unrounded velocity with the walking fix's model
--             (the requested move while its AI requests one, else input acceleration or braking) and
--             writes it back whenever the engine's velocity differs only by rounding, as the walking fix
--             does for Spyro.
--   the edge  Recorded frame by frame at 320 FPS (2026-11-18): after one 4.4-unit move he sat at exactly
--             the same position for 720 frames with his AI requesting the move all along, the front of
--             his 34-unit capsule at the edge of the turret's top. Every 0.03-unit move was blocked; a
--             30 FPS move of 2-3 units carries him over it. Rounding the velocity cannot help a move
--             the sweep refuses (in other runs he crept sideways along the edge one 1/32 step a frame
--             until his Move state gave up), so once a walker that has been asked to walk for 0.1 s
--             covers under a quarter of the asked speed for a few frames in a row, its time is given in
--             30 FPS portions -- the Skelos Badlands lizard's fix
--             (fixes/lizard.lua): CustomTimeDilation gives one tick in every 1/30 s a whole 30 FPS frame
--             of time and the ticks in between almost none, so it asks for the 30 FPS move, and the total
--             time it gets is unchanged. Each portion starts at the asked walking speed, as 30 FPS
--             arrives at the edge already walking. Normal time comes back as soon as its portions move it.
-- Frames of 1/30 s or longer are left alone.
--
-- WALKERS lists the classes it covers: Tub, and Stone Hill's rams (the same slow start from rest, without
-- an edge). Sheila keeps her own module (her jump is moved by script). Other NPCs with the same stall are
-- listed in docs/findings/npc-stalls.md; add a class here once a stall of that class has been measured --
-- a level replay plus tools/Compare-ReplayActors.ps1 shows it as a longer t90 at high FPS.

local config = require("config")
local engine = require("lib.engine")
local log = require("lib.log")
local movement = require("lib.movement")
local util = require("lib.util")

local MOVE_WALKING, MOVE_NAV_WALKING = util.MOVE_WALKING, util.MOVE_NAV_WALKING
local PHASMID_CHARACTER = "/Script/Phasmid.PhasmidCharacter" -- every NPC and enemy derives from this
local MIN_LOGGED_STINT = 0.05                                -- seconds; shorter stretches are not logged
-- The 30 FPS portions, as in fixes/lizard.lua.
local ASKED_BEFORE_JUDGING = 0.1 -- seconds of asking before slow progress counts (2048 reaches 100 in 0.05 s)
local BLOCKED_FRAMES = 3       -- slow frames in a row before the portions start
local SILENT_DILATION = 1e-3   -- time scale for the ticks in between (0 could divide by zero)
local MOVED_SHARE = 0.25       -- share of a 30 FPS move a portion must cover to count as moving
local GOOD_PORTIONS = 2        -- moving portions in a row that give normal time back
local JUDGE_FRAMES = 2         -- frames a portion is given to show up as displacement
local MAX_STEPPING = 10        -- seconds of portions before giving its time back anyway
-- How long an idle walker goes between looks: a quarter of a 30 FPS frame, so a move start is still
-- seen inside the 30 FPS frame it falls in. Frames of 1/30 s or longer are looked at every frame.
local IDLE_RECHECK = util.REFERENCE_DT / 4

local fix = { name = "NPC walk fix", enabled = config.FIX_NPC_WALK, failed = false }

-- Classes whose walks are corrected (exact class names).
fix.WALKERS = {
    CNS2140_SergeantTub_C = true, -- Zephyr, walking off the cannon after his first conversation
    -- Spyro 1 rams (Stone Hill): MaxAcceleration 512, MaxWalkSpeed 180, NavWalking on the 300,000 grid.
    -- Time to 90% of walking speed from rest: 30 FPS 0.33 s, ~250 FPS 0.44-0.46 s unfixed, 0.32 s with
    -- this (2026-11-19, docs/findings/npc-stalls.md).
    BP_CES1015_Ram_C = true,
    -- Spyro 2 boss Gulp (Gulp's Overlook): MaxAcceleration 500, MaxWalkSpeed 530 (ramped up to ~800 by his
    -- own Blueprint during a charge), Walking on the 300,000 grid. From a fresh level load (2026-11-19):
    -- 30 FPS 1445 units of walking and charging in 30 s; ~400 FPS 126 units, then 35 s standing still
    -- with his AI requesting a move every frame (docs/findings/npc-stalls.md).
    BP_CBS2002_Gulp_C = true,
}

local entries = {} -- actor address -> { actor, class, tracked = { x, y, stats } | nil, last = { X, Y, Z } }
local pending = {} -- characters reported by NotifyOnNewObject, resolved on the tick
local VELOCITY = { X = 0, Y = 0, Z = 0 }

local function endStint(e)
    local tracked = e.tracked
    if not tracked then return end
    e.tracked = nil
    local s = tracked.stats
    if s.written + s.followed == 0 or s.time < MIN_LOGGED_STINT then return end
    log("%s: %s walked %.2fs (%d frames, %d moving), %d written, %d followed the engine",
        fix.name, e.class, s.time, s.frames, s.requested, s.written, s.followed)
end

-- RequestedVelocity while the NPC's AI is moving it, else nil. The AI requests the move every frame,
-- aimed to reach the next path point in one frame, so a live request changes every frame; a request
-- equal to last frame's is left over.
local function liveRequest(e, cmc)
    local request = cmc.RequestedVelocity
    local x, y, z = request.X, request.Y, request.Z
    local last = e.last
    local changed = x ~= last.X or y ~= last.Y or z ~= last.Z
    last.X, last.Y, last.Z = x, y, z
    if not changed or (x == 0 and y == 0 and z == 0) then return nil end
    return request
end

-- The speed a requested move asks for: MaxWalkSpeed, or less when the request itself is shorter
-- (UE 4.19 ApplyRequestedMove without bRequestedMoveWithMaxSpeed).
local function requestedSpeed(cmc, request)
    local size = math.sqrt(request.X * request.X + request.Y * request.Y)
    return math.min(cmc.MaxWalkSpeed, size)
end

-- The speed 30 FPS would have reached by now: the asked speed, or less while it is still accelerating
-- from rest at MaxAcceleration. Both the "blocked" test and a portion's starting speed use it. Without the
-- cap, Gulp (500 / 530, ~1 s to full speed) counted as blocked on every start, since after 0.1 s he is
-- meant to be at only 50, and each portion then launched him at full speed: 530-600 from the first frame
-- against 30 FPS's 0.4-1.0 s to 200-440 (2026-11-19). Tub (2048 / 100) is at full speed by 0.05 s, so the
-- cap never bites for him.
local function expectedSpeed(asked, cmc, speed)
    return math.min(speed, cmc.MaxAcceleration * math.max(asked, util.REFERENCE_DT))
end

-- Normal time back, if this fix is the one that set it (something else may have taken it over).
local function release(e)
    local s = e.stepping
    if not s then return end
    e.stepping = nil
    if e.actor:IsValid() and e.actor.CustomTimeDilation == s.written then e.actor.CustomTimeDilation = 1 end
    log("%s: %s stepped for %.3fs, %d portions (%d moved), %s", fix.name, e.class, s.time, s.portions,
        s.moved, s.good >= GOOD_PORTIONS and "cleared" or "given up")
end

-- While stepping: judge the last portion, then write the next tick's time scale.
local function step(e, actor, cmc, moved, dt)
    local s = e.stepping
    if actor.CustomTimeDilation ~= s.written then
        s.written = nil -- someone else's now: leave it to them
        return release(e)
    end
    s.time = s.time + dt
    -- It is the tick after a portion was written that spends it, so the displacement is looked for over
    -- the next JUDGE_FRAMES frames.
    if s.judge > 0 then
        if moved >= MOVED_SHARE * util.REFERENCE_DT * cmc.MaxWalkSpeed then
            s.judge, s.good, s.moved = 0, s.good + 1, s.moved + 1
            if s.good >= GOOD_PORTIONS then return release(e) end
        else
            s.judge = s.judge - 1
            if s.judge == 0 then s.good = 0 end
        end
    end
    if s.time > MAX_STEPPING then return release(e) end
    s.owed = s.owed + dt
    local scale = SILENT_DILATION
    if s.owed >= util.REFERENCE_DT - 1e-4 then
        s.owed = math.max(s.owed - util.REFERENCE_DT, 0)
        scale = util.REFERENCE_DT / dt
        s.portions, s.judge = s.portions + 1, JUDGE_FRAMES
        -- A portion from a standstill covers only MaxAcceleration * (1/30)^2 (2.3 units for Tub), while
        -- 30 FPS reaches the obstacle already walking (3.3): a run whose 211 portions all started from 0
        -- never got past the turret's edge (2026-11-18). So each portion starts at the asked speed, in
        -- the direction of the AI's last request, which is what 30 FPS carries there.
        local rx, ry = e.last.X, e.last.Y
        local size = math.sqrt(rx * rx + ry * ry)
        if size > 0 then
            -- Asked time from when the portions began, plus the time since: on the near-frozen ticks in
            -- between, the AI's request can look unchanged, which resets e.asked.
            local speed = expectedSpeed(s.asked + s.time, cmc, math.min(cmc.MaxWalkSpeed, size))
            VELOCITY.X, VELOCITY.Y = rx / size * speed, ry / size * speed
            cmc.Velocity = VELOCITY
        end
    end
    actor.CustomTimeDilation = scale
    -- Read back what the float property kept, so the takeover test compares exactly.
    s.written = actor.CustomTimeDilation
end

-- The walker's CharacterMovement, kept once it is settled: the object property read costs ~1 us and
-- some garbage per walker per frame. Not from the first frame: a Tub streamed back in by a probe reset
-- had his component replaced after he was registered, and the one read on his first frame stayed valid
-- at mode 0 with no velocity, so he looked idle for good and never left the cannon (2026-11-19). So the
-- property is read every frame until the walker has existed for CMC_SETTLE and the component has a
-- movement mode.
local CMC_SETTLE = 0.5 -- seconds

local function movementOf(e, realDt)
    local cmc = e.cmc
    if cmc and cmc:IsValid() then return cmc end
    cmc = e.actor.CharacterMovement
    e.age = e.age + realDt
    if e.age >= CMC_SETTLE and cmc:IsValid() and cmc.MovementMode ~= 0 then e.cmc = cmc end
    return cmc
end

-- One NPC, once per frame. The rounding model and thresholds are fixes/sheila.lua's correct().
-- realDt is the frame's world delta, read once for every walker (they share the world).
local function correct(e, realDt)
    local actor = e.actor
    local cmc = movementOf(e, realDt)
    local mode = cmc:IsValid() and cmc.MovementMode
    if mode ~= MOVE_WALKING and mode ~= MOVE_NAV_WALKING then
        release(e)
        e.x, e.idleWait = nil, 0
        return endStint(e)
    end
    -- Standing still with nothing going on, which is most walkers most of the time: property reads only
    -- (~2.5 us), before the UFunction calls below (5-12 us each, ~38 us a frame in all, measured
    -- 2026-11-19 in docs/findings/frame-rate-ceiling.md). The outcome is the same as the full path's
    -- "standing still" return: no request, no velocity, no input acceleration (the Acceleration property
    -- holds what GetCurrentAcceleration returns).
    local request, requestRead = nil, false
    if not e.tracked and not e.stepping and e.blocked == 0 then
        -- Each struct read is a new Lua table (~260 B), so an idle walker is only looked at again every
        -- IDLE_RECHECK: 8 idle rams read every frame were still 6.2 KB of garbage a frame at 320 FPS.
        if e.idleWait > 0 then
            e.idleWait = e.idleWait - realDt
            return
        end
        local vel = cmc.Velocity
        if vel.X == 0 and vel.Y == 0 then
            request, requestRead = liveRequest(e, cmc), true
            if not request then
                local accel = cmc.Acceleration
                if accel.X == 0 and accel.Y == 0 then
                    e.asked, e.x = 0, nil
                    -- Counting this frame, so a frame of IDLE_RECHECK or longer looks again next frame.
                    e.idleWait = IDLE_RECHECK - realDt
                    return
                end
            end
        end
    end
    if not cmc:IsComponentTickEnabled() or actor:IsPlayingRootMotion() then
        release(e)
        e.x = nil
        return endStint(e)
    end
    local loc = actor:K2_GetActorLocation()
    local moved = e.x and math.sqrt((loc.X - e.x) ^ 2 + (loc.Y - e.y) ^ 2) or nil
    e.x, e.y = loc.X, loc.Y
    if not requestRead then request = liveRequest(e, cmc) end
    -- How long its AI has been asking it to walk without a break (accelerating from rest is slow at first).
    e.asked = request and e.asked + realDt or 0

    if e.stepping then
        if not util.aboveReferenceFps(realDt) then return release(e) end
        step(e, actor, cmc, moved or 0, realDt)
        if e.stepping then return end
        e.tracked = nil -- carry on from whatever velocity the engine has now
    elseif request and util.aboveReferenceFps(realDt) and actor.CustomTimeDilation == 1 and moved
        and e.asked > ASKED_BEFORE_JUDGING and moved < MOVED_SHARE * expectedSpeed(e.asked, cmc, requestedSpeed(cmc, request)) * realDt then
        -- Asked to walk for a while, and covering under a quarter of the asked speed: count it; a few
        -- in a row start the portions. Not "no displacement at all": at the turret's edge he crept
        -- sideways one 1/32 step a frame (vy -9) until his Move state timed out (2026-11-18).
        e.blocked = e.blocked + 1
        if e.blocked >= BLOCKED_FRAMES then
            e.blocked = 0
            endStint(e)
            -- It has already lost BLOCKED_FRAMES frames: the first portion is due now.
            e.stepping = { owed = util.REFERENCE_DT, judge = 0, good = 0, portions = 0, moved = 0, time = 0, written = 1,
                asked = e.asked }
            step(e, actor, cmc, 0, realDt)
            return
        end
    else
        e.blocked = 0
    end

    local vel = cmc.Velocity
    local vx, vy, vz = vel.X, vel.Y, vel.Z
    local accel = not request and cmc:GetCurrentAcceleration() or nil
    local ax, ay = accel and accel.X or 0, accel and accel.Y or 0
    if not e.tracked then
        -- Standing still: start from zero, so a move that starts here is predicted from its first frame.
        if vx == 0 and vy == 0 and not request and ax == 0 and ay == 0 then return end
        e.tracked = { x = vx, y = vy, stats = { time = 0, frames = 0, requested = 0, written = 0, followed = 0 } }
        if vx ~= 0 or vy ~= 0 then return end
    end
    local tracked = e.tracked
    local dt = realDt * actor.CustomTimeDilation
    local s = tracked.stats
    s.time, s.frames = s.time + dt, s.frames + 1
    if request then s.requested = s.requested + 1 end
    if not util.aboveReferenceFps(dt) then
        tracked.x, tracked.y = vx, vy
        return
    end

    local px, py
    if request then px, py = movement.calcRequestedWalkingVelocity(cmc, tracked.x, tracked.y, request, dt) end
    if not px then px, py = movement.calcWalkingVelocity(cmc, tracked.x, tracked.y, ax, ay, dt) end

    local tolerance = movement.quantizationTolerance(actor, dt)
    if math.abs(vx - px) <= tolerance and math.abs(vy - py) <= tolerance and math.abs(vz) <= tolerance then
        if vx ~= px or vy ~= py or vz ~= 0 then
            VELOCITY.X, VELOCITY.Y = px, py
            cmc.Velocity = VELOCITY
            s.written = s.written + 1
        end
        tracked.x, tracked.y = px, py
    else
        -- Something other than rounding changed its velocity (a wall, a script): follow the engine.
        tracked.x, tracked.y = vx, vy
        s.followed = s.followed + 1
    end
    if px == 0 and py == 0 and not request and ax == 0 and ay == 0 then endStint(e) end
end

-- New characters are only queued by the notification (the engine is still building them); the class
-- is checked on the tick, once per character.
local function resolve()
    for i = #pending, 1, -1 do
        local actor = pending[i]
        pending[i] = nil
        if actor:IsValid() then
            local class = actor:GetClass():GetFName():ToString()
            if fix.WALKERS[class] then
                entries[actor:GetAddress()] = { actor = actor, class = class, last = { X = 0, Y = 0, Z = 0 }, blocked = 0, asked = 0, idleWait = 0, age = 0 }
            end
        end
    end
end

function fix.update(ctx)
    if #pending > 0 then resolve() end
    -- The frame's world delta, read once from the player controller, which lives in the persistent
    -- level. Not from the first walker: after a probe reset the streamed-out Tub stayed valid for a
    -- while with a world delta of 0, and sharing that 0 held the new Tub's idle wait for good, so he
    -- never left the cannon (2026-11-19). Without a controller, each walker reads its own.
    local pc = ctx and ctx.pc
    local shared = pc and pc:IsValid() and engine.worldDeltaSeconds(pc) or nil
    for address, e in pairs(entries) do
        -- A level unload frees the actor; IsValid is the only safe question to ask a dead wrapper.
        if e.actor:IsValid() then
            correct(e, shared or engine.worldDeltaSeconds(e.actor))
        else
            entries[address] = nil
        end
    end
end

-- Velocity writes need no undoing (the engine recomputes it every frame), but a time scale does. The
-- NPCs are dropped so a disabled fix stops holding them.
function fix.disable()
    for _, e in pairs(entries) do pcall(release, e) end
    entries, pending = {}, {}
end

if fix.enabled then
    NotifyOnNewObject(PHASMID_CHARACTER, function(object)
        if not fix.failed then pending[#pending + 1] = object end
    end)
end

return fix
