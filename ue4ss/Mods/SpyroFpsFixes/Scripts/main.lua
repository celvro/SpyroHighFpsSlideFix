-- SpyroFpsFixes: runtime fixes for framerate-dependent movement bugs.
--
-- Braking slide fix
--   Levels sit ~300,000 units from the world origin, where float32 positions have a 1/32 unit
--   spacing. UE 4.19's PhysWalking resets Velocity to (actual displacement / dt) after every
--   move, so velocity is quantized to multiples of (1/32)/dt. Above ~80 FPS a frame's braking
--   removes less than half of that step, the rounded move restores the old speed, and Spyro
--   slides forever at a constant low speed.
--   While walking with zero acceleration, this keeps the unquantized braked velocity (same
--   formula as UCharacterMovementComponent::ApplyVelocityBraking) and writes it back whenever
--   the engine's value only differs by quantization. At low framerates this is a no-op.
--
-- Jump height fix
--   A jump (ground, water, charge) sets Z velocity and applies GE_SpyroJumpNoGravity, which
--   zeroes GravityScale for JumpMaxHoldTime (0.233 s). Measured in traces:
--     * full hold: gravity stays off for the frames until the effect's timer fires, plus one
--       extra frame, i.e. (ceil(H/dt) + 1) frames: 8/30 s at 30 FPS but only 35/144 s at 144 FPS.
--     * early release: gravity stays off for exactly the frames the button was held, so the
--       release is rounded up to the frame grid.
--   The game was tuned at 30 FPS, where both round to 1/30 s steps, so jumps are ~5 units higher
--   there. This keeps GravityScale at 0 after the engine restores it until the zero-gravity rise
--   time matches what 30 FPS would produce. At 30 FPS it never extends anything.

local UEHelpers = require("UEHelpers")

local VERSION = "1.0.0" -- tools/Package-Release.ps1 names the release zip from this

local MIN_TICK_TIME = 1e-6
local BRAKE_TO_STOP_VELOCITY = 10
local MAX_BRAKING_STEP = 1 / 33
local MOVE_WALKING = 1
local MOVE_FALLING = 3
local REFERENCE_FPS = 30
local JUMP_VZ_EPSILON = 0.05
local EMULATE_RELEASE_ROUNDING = true -- also round early jump releases up to the 30 FPS grid
local PROFILE = false                 -- log the fixes' per-frame cost to UE4SS.log
local PROFILE_INTERVAL = 10           -- seconds between profile log lines

local tracked = nil -- { x, y, z } unquantized velocity carried from the previous frame
local jump = nil    -- zero-gravity jump rise being tracked or extended
local brakingParamsLogged = false
local errorLogged = false

local function log(fmt, ...)
    print(string.format("[SpyroFpsFixes] " .. fmt .. "\n", ...))
end

-- Distance between adjacent float32 values at magnitude v.
local function floatSpacing(v)
    v = math.abs(v)
    if v < 1 then return 2 ^ -24 end
    -- UE4SS runs Lua 5.4, which has no math.frexp.
    local exp = math.floor(math.log(v, 2))
    if 2 ^ (exp + 1) <= v then exp = exp + 1 elseif 2 ^ exp > v then exp = exp - 1 end
    return 2 ^ (exp - 23)
end

-- Mirrors UCharacterMovementComponent::ApplyVelocityBraking (UE 4.19).
local function applyBraking(vx, vy, vz, dt, friction, deceleration)
    if (vx == 0 and vy == 0 and vz == 0) or dt < MIN_TICK_TIME then return vx, vy, vz end
    local zeroFriction = friction == 0
    local zeroBraking = deceleration == 0
    if zeroFriction and zeroBraking then return vx, vy, vz end

    local ox, oy, oz = vx, vy, vz
    local size = math.sqrt(vx * vx + vy * vy + vz * vz)
    local rx, ry, rz = 0, 0, 0
    if not zeroBraking then
        rx, ry, rz = -deceleration * vx / size, -deceleration * vy / size, -deceleration * vz / size
    end

    local remaining = dt
    while remaining >= MIN_TICK_TIME do
        local step = (remaining > MAX_BRAKING_STEP and not zeroFriction) and math.min(MAX_BRAKING_STEP, remaining * 0.5) or remaining
        remaining = remaining - step
        vx = vx + (-friction * vx + rx) * step
        vy = vy + (-friction * vy + ry) * step
        vz = vz + (-friction * vz + rz) * step
        if vx * ox + vy * oy + vz * oz <= 0 then return 0, 0, 0 end
    end

    local sizeSq = vx * vx + vy * vy + vz * vz
    if sizeSq <= 1e-4 or (not zeroBraking and sizeSq <= BRAKE_TO_STOP_VELOCITY ^ 2) then return 0, 0, 0 end
    return vx, vy, vz
end

local function brakingParams(cmc)
    local friction = cmc.bUseSeparateBrakingFriction and cmc.BrakingFriction or cmc.GroundFriction
    friction = math.max(0, friction * math.max(0, cmc.BrakingFrictionFactor))
    return friction, math.max(0, cmc.BrakingDecelerationWalking)
end

local function fixBrakingSlide(pawn, cmc, dt)
    local accel = cmc:GetCurrentAcceleration()
    local braking = cmc.MovementMode == MOVE_WALKING
        and accel.X == 0 and accel.Y == 0 and accel.Z == 0
        and not pawn:IsPlayingRootMotion()
    local vel = cmc.Velocity
    local vx, vy, vz = vel.X, vel.Y, vel.Z

    if not braking or not tracked or dt < MIN_TICK_TIME then
        tracked = braking and { vx, vy, vz } or nil
        return
    end

    local friction, deceleration = brakingParams(cmc)
    if not brakingParamsLogged then
        brakingParamsLogged = true
        log("braking params: friction=%.3f deceleration=%.3f", friction, deceleration)
    end
    local bx, by, bz = applyBraking(tracked[1], tracked[2], tracked[3], dt, friction, deceleration)

    -- Largest velocity error a rounded move can introduce this frame, with a little slack.
    local loc = pawn:K2_GetActorLocation()
    local tolerance = (math.max(floatSpacing(loc.X), floatSpacing(loc.Y), floatSpacing(loc.Z)) / dt) * 1.01

    if math.abs(vx - bx) <= tolerance and math.abs(vy - by) <= tolerance and math.abs(vz - bz) <= tolerance then
        if vx ~= bx or vy ~= by or vz ~= bz then
            cmc.Velocity = { X = bx, Y = by, Z = bz }
        end
        tracked = (bx == 0 and by == 0 and bz == 0) and nil or { bx, by, bz }
    else
        -- Something other than quantization changed the velocity (collision, script): follow the engine.
        tracked = { vx, vy, vz }
    end
end

-- Zero-gravity rise time (seconds) that 30 FPS produces when the no-gravity effect times out.
-- The effect's timer is checked after each frame's move, so the rise lasts ceil(H * 30) frames,
-- plus `lagFrames` when the timer started counting a frame after the jump's first move (usual).
local function referenceTimeoutRise(holdTime, lagFrames)
    return (math.ceil(holdTime * REFERENCE_FPS - 1e-4) + lagFrames) / REFERENCE_FPS
end

-- Zero-gravity rise time that 30 FPS produces for a release at `releaseTime` after takeoff.
local function referenceReleaseRise(releaseTime)
    return math.ceil(releaseTime * REFERENCE_FPS - 1e-4) / REFERENCE_FPS
end

-- Frames of lag between the jump's first move and the no-gravity timer starting (0 or 1), or nil
-- if gravity didn't come back when a JumpMaxHoldTime-long timer would have fired.
local function timeoutLagFrames(j, holdTime, dt)
    for lag = 1, 0, -1 do
        local elapsed = j.rise - (lag == 1 and j.firstDt or 0)
        if elapsed >= holdTime - 1e-4 and elapsed - dt < holdTime - 1e-4 then return lag end
    end
    return nil
end

-- Gives gravity back without touching velocity (used when something else interrupts the rise).
local function abandonJump(cmc)
    if jump and jump.extending and cmc.GravityScale == 0 then
        cmc.GravityScale = jump.restoreGravity
    end
    jump = nil
end

-- Ends a rise that reached its 30 FPS target. The rise can only end on a frame boundary, so the
-- leftover time is folded into the upward speed to give exactly the 30 FPS apex height:
-- vz'^2 = vz^2 + 2 * g * jumpVz * leftover.
local function finishJump(cmc)
    local j = jump
    abandonJump(cmc)
    local leftover = j.target - j.rise
    if math.abs(leftover) < 1e-5 then return end
    local g = -cmc:GetGravityZ()
    local vel = cmc.Velocity
    local vz2 = vel.Z * vel.Z + 2 * g * j.vz * leftover
    if g <= 0 or vel.Z <= 0 or vz2 <= 0 then return end
    cmc.Velocity = { X = vel.X, Y = vel.Y, Z = math.sqrt(vz2) }
end

-- Runs before each world tick, so the values read describe the frame that just finished and any
-- GravityScale written here applies to the next frame's move.
local function fixJumpHeight(pawn, cmc, dt)
    local mode = cmc.MovementMode
    local vel = cmc.Velocity
    local vz = vel.Z
    local gravity = cmc.GravityScale

    if jump and jump.extending then
        -- The last frame moved under our zero-gravity override. Hand control back if anything else
        -- took over: landing, gliding, another effect changing gravity, or velocity changing.
        if mode ~= MOVE_FALLING or gravity ~= 0 or math.abs(vz - jump.vz) > JUMP_VZ_EPSILON then
            abandonJump(cmc)
            return
        end
        jump.rise = jump.rise + dt
        if jump.rise + dt * 0.5 >= jump.target then finishJump(cmc) end
        return
    end

    if not jump then
        if mode == MOVE_FALLING and gravity == 0 and vz > 0 then
            -- First frame of a zero-gravity rise: it already moved at full jump speed.
            jump = { vz = vz, rise = dt, firstDt = dt }
        end
        return
    end

    if mode ~= MOVE_FALLING then jump = nil return end

    local released = math.abs(vz - jump.vz) > JUMP_VZ_EPSILON
    if released then
        -- Gravity was already back for this frame's move: the jump button was released.
        if gravity == 0 or not EMULATE_RELEASE_ROUNDING then jump = nil return end
        jump.target = referenceReleaseRise(jump.rise - dt * 0.5)
    else
        jump.rise = jump.rise + dt
        if gravity == 0 then return end
        -- Gravity came back after a full-speed frame: the no-gravity effect timed out.
        local holdTime = pawn.JumpMaxHoldTime
        local lag = type(holdTime) == "number" and timeoutLagFrames(jump, holdTime, dt) or nil
        if not lag then jump = nil return end -- some other effect; leave it alone
        jump.target = referenceTimeoutRise(holdTime, lag)
    end

    if jump.rise + dt * 0.5 >= jump.target then
        -- Already on the right frame count; only the apex residual needs correcting.
        finishJump(cmc)
        return
    end

    jump.extending = true
    jump.restoreGravity = gravity
    cmc.GravityScale = 0
    if released then
        cmc.Velocity = { X = vel.X, Y = vel.Y, Z = jump.vz }
    end
end

local function tick()
    local pc = UEHelpers.GetPlayerController()
    if not pc:IsValid() then return end
    local pawn = pc.Pawn
    if not pawn:IsValid() then tracked = nil jump = nil return end
    local cmc = pawn.CharacterMovement
    if not cmc:IsValid() then tracked = nil jump = nil return end
    local dt = UEHelpers.GetGameplayStatics():GetWorldDeltaSeconds(pawn)
    fixBrakingSlide(pawn, cmc, dt)
    fixJumpHeight(pawn, cmc, dt)
end

local function runTick()
    local ok, err = pcall(tick)
    if not ok and not errorLogged then
        errorLogged = true
        log("error: %s", tostring(err))
    end
end

-- Profiling: times each frame's fix work with the engine's high-resolution clock (os.clock only
-- has 1 ms resolution on Windows) and logs a summary every PROFILE_INTERVAL seconds.
local profile = { frames = 0, cost = 0, maxCost = 0, timerCost = 0, frameTime = 0, windowStart = nil }

local function accurateSeconds(statics, context)
    local seconds, partial = {}, {}
    statics:GetAccurateRealTime(context, seconds, partial)
    return seconds.Seconds + partial.PartialSeconds
end

local function profiledTick()
    local pc = UEHelpers.GetPlayerController()
    if not pc:IsValid() then return runTick() end
    local statics = UEHelpers.GetGameplayStatics()

    -- Two back-to-back clock reads measure the clock's own cost, which is subtracted from the
    -- measured tick (that interval also contains one clock call).
    local t0 = accurateSeconds(statics, pc)
    local t1 = accurateSeconds(statics, pc)
    runTick()
    local t2 = accurateSeconds(statics, pc)

    local timerCost = t1 - t0
    local cost = math.max(0, (t2 - t1) - timerCost)
    profile.frames = profile.frames + 1
    profile.cost = profile.cost + cost
    profile.maxCost = math.max(profile.maxCost, cost)
    profile.timerCost = profile.timerCost + timerCost
    profile.frameTime = profile.frameTime + statics:GetWorldDeltaSeconds(pc)
    profile.windowStart = profile.windowStart or t0

    if t2 - profile.windowStart >= PROFILE_INTERVAL then
        local n = profile.frames
        local avgFrame = profile.frameTime / n
        log("profile: %d frames (avg frame %.2f ms), fixes avg %.3f ms (%.2f%% of frame), max %.3f ms, clock overhead avg %.3f ms",
            n, avgFrame * 1000, profile.cost / n * 1000, profile.cost / profile.frameTime * 100,
            profile.maxCost * 1000, profile.timerCost / n * 1000)
        profile.frames, profile.cost, profile.maxCost, profile.timerCost, profile.frameTime = 0, 0, 0, 0, 0
        profile.windowStart = t2
    end
end

-- If profiling itself breaks, drop back to plain ticking so the fixes keep running.
local profilingFailed = false
local function profiledLoop()
    if profilingFailed then return runTick() end
    local ok, err = pcall(profiledTick)
    if not ok then
        profilingFailed = true
        log("profiling disabled after error: %s", tostring(err))
    end
end

if not EngineTickAvailable then
    log("EngineTick hook unavailable; fixes disabled")
    return
end

LoopInGameThreadAfterFrames(1, PROFILE and profiledLoop or runTick)

log("v%s loaded%s", VERSION, PROFILE and " (profiling on)" or "")
