-- High FPS Gameplay Fixes: runtime fixes for framerate-dependent gameplay bugs.
-- The folder and log prefix keep the original name (HighFpsSlidingAndJumpFix) so updates replace
-- older installs instead of loading alongside them.
--
-- Walking velocity fix (sliding and acceleration)
--   Levels sit ~300,000 units from the world origin, where float32 positions have a 1/32 unit
--   spacing. UE 4.19's PhysWalking resets Velocity to (actual displacement / dt) after every
--   move, so velocity is quantized to multiples of (1/32)/dt: 4.5 at 144 FPS, 0.94 at 30.
--     * braking: above ~80 FPS a frame's braking removes less than half of that step, the
--       rounded move restores the old speed, and Spyro slides forever at a constant low speed.
--     * accelerating: a frame's 1000 * dt (6.9 at 144 FPS) of acceleration lands on 4.5 or 9, so
--       speeding up (e.g. starting a charge) runs at ~650 or ~1300 per second instead of 1000.
--   While walking without root motion, this keeps the unquantized velocity (same formula as
--   UCharacterMovementComponent::CalcVelocity) and writes it back whenever the engine's value
--   only differs by quantization. At low framerates the difference is negligible.
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
--
-- Charge turn slip fix
--   While charging, Spyro's facing turns at a framerate-independent rate (131 deg/s at full lock).
--   Each walking frame, CalcVelocity pulls velocity towards the facing by GroundFriction * dt of the
--   angle, and adding MaxAcceleration * dt along the facing closes a bit more. Velocity keeps
--   R = (1 - friction * dt) / (1 + accel * dt / speed) of its lag per frame, so a steady turn
--   leaves it w * dt * R / (1 - R) behind the facing. That is 9.4 deg at 30 FPS but 12.1 at
--   144 FPS, so Spyro looks like he turns wider. While charging on the ground this raises
--   GroundFriction until that steady lag matches 30 FPS (friction 8 -> 10.7 at 144 FPS).
--   At 30 FPS or lower it changes nothing.
--
-- Mouse charge steering fix
--   With keyboard and mouse, the charge steers from the mouse X axis, which is the mouse movement
--   of that frame (CharacterInputComponent_Spyro.GetChargeMovementValueOnPC). Each frame turns
--   6 * atan(min(0.5 * mouse, 1) * 0.7) deg/s, so the same hand movement split over 4.8x more
--   frames turns Spyro far less at 144 FPS. While charging (or charge jumping) with the mouse,
--   this replaces the stored axis value with the mouse movement of the last 1/30 s, which is
--   what 30 FPS sees. Mouse camera look doesn't use this value and is unaffected.
--   At 30 FPS or lower it changes nothing.
--
-- Camera centering fix
--   The follow camera swings in behind Spyro with FInterpTo at speed m_ctrInterp (5 normally,
--   3.5 while charging), moving min(speed * dt, 1) of the remaining yaw each frame. Behind a
--   steadily turning Spyro it trails w * dt * (1 - f) / f with f = speed * dt: 33.0 deg at 30 FPS
--   but 36.5 at 144 during a full-lock charge turn, and it recenters ~5% slower. This raises
--   m_ctrInterp so the steady trail matches 30 FPS (3.5 -> 3.86, 5 -> 5.76 at 144 FPS), leaving
--   it alone while a camera settings transition is blending it. At 30 FPS or lower it changes nothing.
--
-- Camera centering switch and stuck camera fixes
--   Native FollowCameraComponent centering (exe VA 0x141EF6515-0x141EF6853) runs in two phases each
--   time centering starts. First it latches scale = min(|gap| / 90, 1) and turns the camera by
--   scale * (180 deg/s * dt * sign(gap) + Spyro's yaw change this frame). Once |gap| <= |Spyro's yaw
--   change this frame| * m_ctrDecelAngleTurnModifier (5) + scale * m_ctrDecelAngle (20), it blends
--   into FInterpTo at m_ctrInterp until centering stops.
--     * switch: the turn term uses the per-frame yaw change, so in a full-lock turn it is 21.8 deg at
--       30 FPS but 4.5 at 144 FPS. This scales m_ctrDecelAngleTurnModifier by (1/30) / dt so the
--       switch happens at the same gap as at 30 FPS. At 30 FPS or lower it changes nothing.
--     * stuck camera (at any framerate): if centering starts with a small gap, the latched speed is
--       tiny (5.4 deg -> 11 deg/s), and if Spyro turns away faster than that the gap grows and never
--       gets under the threshold; the camera crawls until the gap wraps through 0 (Spyro turns a full
--       circle) or centering stops. When the gap has grown GROWTH deg since its minimum, this sets
--       the turn modifier very high for one frame, which passes the check while Spyro is turning.
--       The property is only read by that check, so the override does nothing while centering is
--       off or already interpolating. This one also changes 30 FPS.
--
-- Charge dust fix
--   Every frame of a ground charge, Spyro's Blueprint (Charge_UpdateGroundEffects) deactivates the
--   dust trail effect and spawns a new one, so each effect only emits during its first tick. Its
--   emitters spawn 60 particles per second, and one 30 FPS tick adds up to one particle per side,
--   but one 60+ FPS tick adds up to less than one, so no dust appears at all. Once every 1/30 s
--   this stretches a new effect's only tick to 1/30 s (CustomTimeDilation), so it emits exactly
--   what a 30 FPS frame's effect does, and slows the effects spawned in between to almost a
--   standstill so they emit nothing. The next frame gives them normal time back for their
--   remaining particles. The shallow water splash takes the same path. At 30 FPS or lower it
--   changes nothing.
--
-- Green druid Energize fix
--   The green druids (e.g. Alpine Ridge's stairs, door and walkway) move their mechanism from an
--   Energize anim notify in their cast montage. AM_CES1035_GreenDruid_Casting_Up is 0.5 s long and
--   starts blending out at 0.25 s; that ends the druid's cast state, and the next state's montage
--   interrupts it, so later notifies never fire. Its Energize notify sits at 0.25089 s, so it only
--   fires when one frame steps from before 0.25 to past 0.25089: always at 30 FPS (0.233 -> 0.267),
--   never at 60, 120 or 144 FPS, which land exactly on 0.25. The druid only switches between its up
--   and down casts inside that notify, so it then repeats the up cast forever and the mechanism
--   never moves again. This moves the notify to 0.24986 s, where the casting-down montage
--   (AM_..._Casting_Out) has its own, which fires at every framerate. At 30 FPS it fires on the same
--   frame as before. It only acts where the montage is loaded, i.e. on the levels with green druids.
--
-- Fire dragon segment fix
--   Fireworks Factory's segmented dragons (BP_CBS3012_FireDragon) move their body in the head's
--   UpdatePrevActors, which calls the native DragonSineMovementComponent.MoveUpdate for each live
--   segment in order with FMax(DeltaTime, 0.033). MoveUpdate lerps the segment twice towards its
--   leader by 4 * delta (and its wave phase and amplitude by 2 * delta), so each segment keeps
--   (1 - 4 * delta)^2 of its distance per call and trails a steadily moving leader by
--   dt * R / (1 - R) of its speed. At 30 FPS that is 0.101 s per segment, but the clamped delta
--   pulls just as hard every frame, so at 144 FPS it is 0.021 s: the body is ~4.7x shorter and
--   bunched up behind the head. This keeps the segments' bAlive off, which turns the Blueprint's
--   calls into no-ops, and repeats the same calls with a delta whose steady trail matches 30 FPS.
--   At 30 FPS or lower it passes the Blueprint's own delta, so nothing changes.

local UEHelpers = require("UEHelpers")

local VERSION = "1.2.1" -- tools/Package-Release.ps1 names the release zip from this

local MIN_TICK_TIME = 1e-6
local BRAKE_TO_STOP_VELOCITY = 10
local MAX_BRAKING_STEP = 1 / 33
local MOVE_WALKING = 1
local MOVE_FALLING = 3
local REFERENCE_FPS = 30
local JUMP_VZ_EPSILON = 0.05
local EMULATE_RELEASE_ROUNDING = true -- also round early jump releases up to the 30 FPS grid
local FIX_WALKING_ACCELERATION = true -- set false to only fix braking (the original sliding fix)
local FIX_CHARGE_TURN_SLIP = true     -- set false to compare against the unfixed charge turn
local FIX_MOUSE_CHARGE_STEERING = true -- set false to compare against the unfixed mouse charge steering
local FIX_CAMERA_CENTERING = true     -- set false to compare against the unfixed camera centering
local FIX_CAMERA_CENTERING_SWITCH = true -- set false to compare against the per-frame centering switch threshold
local FIX_STUCK_CAMERA = true         -- set false to compare against the camera getting stuck while centering
local STUCK_CAMERA_GROWTH = 8         -- gap growth (deg) since its minimum that counts as the camera falling behind
local STUCK_CAMERA_RELEASE = 1e6      -- turn modifier that passes the centering switch check whenever Spyro turns
local STUCK_CAMERA_LOG_GAP = 45       -- log releases while charging at gaps of at least this (deg; a full-lock trail is 33); nil to stop logging
local DEFAULT_TURN_MODIFIER = 5       -- m_ctrDecelAngleTurnModifier, if the first value we see is our own override
local FIX_CHARGE_DUST = true          -- set false to compare against the missing charge dust
local CHARGE_MIN_WALK_SPEED = 350     -- charging sets MaxWalkSpeed 458.5, charge jumping 358; running is 268.5
local CHARGE_MIN_SPEED = 50           -- slower than this, acceleration dominates the turn; leave friction alone
local MOUSE_AXIS_FUNCTION = "/CharacterCommon/Components/CharacterInputComponent/CharacterInputComponent_Spyro.CharacterInputComponent_Spyro_C:InputAxis_RightStick_X"
local MOUSE_HISTORY = 64              -- mouse samples kept; must cover 1/30 s at the highest framerate
local CHARGE_DUST_FUNCTION = "/CPS1999_Spyro/Blueprints/BP_CPS1999_Playable.BP_CPS1999_Playable_C:Charge_UpdateGroundEffects"
local DUST_SILENT_DILATION = 1e-3     -- time scale for dust effects spawned between 30 FPS frames (0 could divide by zero)
local FIX_DRUID_ENERGIZE = true       -- set false to compare against druids that stop energizing
local DRUID_MONTAGE = "/CES1035_GreenDruid/Animations/Montages/AM_CES1035_GreenDruid_Casting_Up.AM_CES1035_GreenDruid_Casting_Up"
local DRUID_NOTIFY_TIME = 0.25089103  -- the montage's Energize notify time (skip the fix if the asset differs)
local DRUID_FIXED_NOTIFY_TIME = 0.24986279 -- AM_CES1035_GreenDruid_Casting_Out's Energize notify time
local FIX_DRAGON_SEGMENTS = true      -- set false to compare against the bunched-up fire dragons
local DRAGON_UPDATE_FUNCTION = "/CBS3012_FireDragon/Blueprints/BP_CBS3012_FireDragon.BP_CBS3012_FireDragon_C:UpdatePrevActors"
local DRAGON_MIN_DELTA = 0.033        -- UpdatePrevActors passes FMax(DeltaTime, 0.033) to MoveUpdate
local DRAGON_FOLLOW_RATE = 4          -- MoveUpdate lerps towards the leader by this * delta, twice
local DRAGON_MESH_LIFT = 20           -- UpdatePrevActors raises the head's mesh this much around its MoveUpdate calls
local HOOK_RETRY_FRAMES = 60          -- frames between looks for a (not yet loaded) hooked Blueprint or asset
local HOOK_MAX_FAILURES = 200         -- failed RegisterHook calls before giving up on a level Blueprint
local PROFILE = false        -- log the fixes' per-frame cost to UE4SS.log
local PROFILE_INTERVAL = 10           -- seconds between profile log lines
-- GC spike investigation (see CLAUDE.md "Frame spikes / Lua GC investigation"): only sampled while
-- PROFILE is also on. GC_COLLECTION_KB is a per-frame collectgarbage("count") drop big enough to
-- count as "a collection landed in this frame" rather than ordinary allocate/free noise.
local GC_PROFILE = false
local GC_COLLECTION_KB = 5
-- Switches the shared Lua state's collector at load, to A/B against the default incremental one.
-- "generational" is the only other mode Lua 5.4 offers; nil/false leaves whatever UE4SS started with.
local GC_MODE = nil

local tracked = nil -- { x, y, z } unquantized velocity carried from the previous frame
local jump = nil    -- zero-gravity jump rise being tracked or extended
local slip = nil    -- { base, written }: GroundFriction without our override, and the value we wrote
local mouse = {
    values = {}, dts = {}, head = 0, count = 0, -- ring buffer of per-frame mouse X samples
    frame = -1,        -- frameCounter of the newest sample
    active = false,    -- replace the axis value this frame (charging with mouse steering)
    component = nil,   -- CharacterInputComponent_Spyro seen by the hook
    registered = false, failed = false, retryIn = 0,
}
-- Spyro's Blueprint replaces Charge_GroundEffects in Charge_UpdateGroundEffects. With this UE4SS
-- build only the "pre" callback of a Blueprint function hook runs, and it runs after the body, so
-- one callback is registered as both: it only acts on an effect address it hasn't seen.
local dust = {
    pawn = nil,          -- address of the player's pawn this frame (other actors' calls are ignored)
    frame = -1,          -- frameCounter of the last callback
    frameStart = nil,    -- effect address when this frame started, before the Blueprint could replace it
    handled = nil,       -- address of the newest effect already given a time scale
    dilated = {},        -- effects with a changed CustomTimeDilation, reset on the next frame
    sinceDue = 0,        -- seconds since the last effect that emits, so they stay 1/30 s apart
    lastSpawnFrame = -1, -- frameCounter when a new effect was last seen (a gap means a new charge)
    registered = false, failed = false, retryIn = 0,
}
-- { address, base, written }: the FollowCameraComponent, its m_ctrInterp without our override
-- (nil while a transition blends it), and the value we wrote.
local camera = nil
local cameraFixFailed = false
-- { address, base, written, minGap }: the FollowCameraComponent, its m_ctrDecelAngleTurnModifier
-- without our changes, the value we wrote, and the smallest camera gap since the last release.
local switch = nil
local switchFixFailed = false
-- A StaticFindObject that finds nothing scans the whole object array (~10 ms, a visible hitch), so
-- lookups only run while `lookups` > 0: once at startup, and again for a while after NotifyOnNewObject
-- reports the Blueprint class or montage being created. A lookup that finds its object is ~free.
local NEW_OBJECT_LOOKUPS = 10
-- Druid Energize fix: failed after an error; frames until the next montage lookup; lookups left.
local druid = { failed = false, retryIn = 0, lookups = 1 }
local dragon = {
    hooked = nil,  -- address of the UpdatePrevActors function we hooked (it is reloaded with the level)
    heads = {},    -- address -> dragon head whose segments we took over, to hand back after an error
    failures = 0, failed = false, retryIn = 0, lookups = 1,
}
mouse.lookups = 1
dust.lookups = 1
-- Reused across calls (and dragons) so onDragonUpdate doesn't allocate a table every frame. Lua is
-- single-threaded and each call finishes using these before the next starts, so sharing is safe; the
-- lift/lower vectors' values never change, and the sweep result is an unread out-param either way.
local DRAGON_LIFT_VEC = { X = 0, Y = 0, Z = DRAGON_MESH_LIFT }
local DRAGON_LOWER_VEC = { X = 0, Y = 0, Z = -DRAGON_MESH_LIFT }
local DRAGON_SWEEP_HIT = {}
local frameCounter = 0 -- engine frames; the mouse hook uses it to take one sample per frame
local lastDt = 1 / 60
local brakingParamsLogged = false
local chargeQueryFailed = false
local chargeQueryErrorLogged = false
local errorLogged = false

local function log(fmt, ...)
    print(string.format("[HighFpsSlidingAndJumpFix] " .. fmt .. "\n", ...))
end

-- Spends one of `state`'s lookups every HOOK_RETRY_FRAMES frames. Returns the object when a lookup
-- finds it (the caller decides whether to keep `state.lookups` for another try), else nil.
local function lookUp(state, path)
    if state.lookups <= 0 then return nil end
    if state.retryIn > 0 then
        state.retryIn = state.retryIn - 1
        return nil
    end
    state.retryIn = HOOK_RETRY_FRAMES
    state.lookups = state.lookups - 1
    local object = StaticFindObject(path)
    if object and object:IsValid() then return object end
    return nil
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

-- FVector::IsExceedingMaxSpeed's 1% tolerance, on horizontal velocity.
local function exceedsSpeed(vx, vy, maxSpeed)
    maxSpeed = math.max(0, maxSpeed)
    return vx * vx + vy * vy > maxSpeed * maxSpeed * 1.01
end

-- Mirrors UCharacterMovementComponent::CalcVelocity (UE 4.19) for walking under player input
-- (no path following, RVO or fluid friction). PhysWalking zeroes Z beforehand, so this is 2D.
local function calcWalkingVelocity(cmc, vx, vy, ax, ay, dt)
    local zeroAccel = ax == 0 and ay == 0
    local accelSize = math.sqrt(ax * ax + ay * ay)
    local maxInputSpeed = 0
    if not zeroAccel then
        local maxAccel = cmc.MaxAcceleration
        local analogModifier = maxAccel > 1e-8 and math.min(accelSize / maxAccel, 1) or 0
        maxInputSpeed = cmc.MaxWalkSpeed * analogModifier
    end
    maxInputSpeed = math.max(maxInputSpeed, cmc.MinAnalogWalkSpeed)

    local overMax = exceedsSpeed(vx, vy, maxInputSpeed)
    if zeroAccel or overMax then
        local friction, deceleration = brakingParams(cmc)
        if not brakingParamsLogged then
            brakingParamsLogged = true
            log("braking params: friction=%.3f deceleration=%.3f", friction, deceleration)
        end
        local ox, oy = vx, vy
        vx, vy = applyBraking(vx, vy, 0, dt, friction, deceleration)
        -- Don't let braking take us below max speed if we started above it.
        if overMax and vx * vx + vy * vy < maxInputSpeed * maxInputSpeed and ax * ox + ay * oy > 0 then
            local scale = maxInputSpeed / math.sqrt(ox * ox + oy * oy)
            vx, vy = ox * scale, oy * scale
        end
    else
        -- Friction limits how fast velocity can change direction towards the acceleration.
        local blend = math.min(dt * math.max(0, cmc.GroundFriction), 1)
        local size = math.sqrt(vx * vx + vy * vy)
        vx = vx - (vx - ax / accelSize * size) * blend
        vy = vy - (vy - ay / accelSize * size) * blend
    end

    if not zeroAccel then
        local newMaxInputSpeed = exceedsSpeed(vx, vy, maxInputSpeed) and math.sqrt(vx * vx + vy * vy) or maxInputSpeed
        vx, vy = vx + ax * dt, vy + ay * dt
        local sizeSq = vx * vx + vy * vy
        if newMaxInputSpeed < 1e-4 then
            vx, vy = 0, 0
        elseif sizeSq > newMaxInputSpeed * newMaxInputSpeed then
            local scale = newMaxInputSpeed / math.sqrt(sizeSq)
            vx, vy = vx * scale, vy * scale
        end
    end
    return vx, vy
end

local STILL = { 0, 0, 0 } -- tracked velocity while standing; never modified

local function fixWalkingVelocity(pawn, cmc, dt, mode, vel)
    if mode ~= MOVE_WALKING then tracked = nil return end
    local vx, vy, vz = vel.X, vel.Y, vel.Z
    -- Standing still: skip the engine calls below. A move that starts here is predicted from zero.
    if vx == 0 and vy == 0 and vz == 0 then
        tracked = FIX_WALKING_ACCELERATION and STILL or nil
        return
    end
    local accel = cmc:GetCurrentAcceleration()
    local braking = accel.X == 0 and accel.Y == 0 and accel.Z == 0
    local handled = (braking or FIX_WALKING_ACCELERATION) and not pawn:IsPlayingRootMotion()

    if not handled or not tracked or dt < MIN_TICK_TIME then
        tracked = handled and { vx, vy, vz } or nil
        return
    end

    local bx, by = calcWalkingVelocity(cmc, tracked[1], tracked[2], accel.X, accel.Y, dt)
    local bz = 0

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
local function fixJumpHeight(pawn, cmc, dt, mode, vel)
    if not jump and mode ~= MOVE_FALLING then return end
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

-- IGetIsCharging (Blueprint) checks the Character.MoveState.Charging gameplay tag.
local function isCharging(pawn)
    local out = {}
    local ret = pawn:IGetIsCharging(out)
    if type(out.IsCharging) == "boolean" then return out.IsCharging end
    if type(ret) == "boolean" then return ret end
    error("IGetIsCharging returned no IsCharging value")
end

-- GroundFriction that leaves velocity the same steady angle behind a steadily turning facing at
-- this dt as `friction` does at 30 FPS. Per frame velocity keeps R = keepFriction * keepAccel of
-- that angle, and a facing turning at w per second leaves it w * dt * R / (1 - R) behind.
local function referenceFriction(friction, accel, speed, dt)
    local refDt = 1 / REFERENCE_FPS
    local keepRef = (1 - math.min(friction * refDt, 1)) / (1 + accel * refDt / speed)
    local ratio = keepRef / (1 - keepRef) * refDt / dt -- R / (1 - R) that gives the 30 FPS lag
    local keep = ratio / (1 + ratio)
    return (1 - keep * (1 + accel * dt / speed)) / dt
end

-- Runs before each world tick, so a GroundFriction written here applies to the next frame's move;
-- that frame is assumed to be as long as the one that just finished.
local function fixChargeTurnSlip(cmc, dt, vel, charging)
    local speed = charging and math.sqrt(vel.X * vel.X + vel.Y * vel.Y) or 0
    charging = charging and speed >= CHARGE_MIN_SPEED
    if not charging and not slip then return end

    -- Something else wrote GroundFriction (an effect changing the attribute): that is the new base.
    if slip and cmc.GroundFriction ~= slip.written then slip = nil end
    if not charging then
        if slip then cmc.GroundFriction = slip.base end
        slip = nil
        return
    end
    local base = slip and slip.base or cmc.GroundFriction
    cmc.GroundFriction = math.max(base, referenceFriction(base, cmc.MaxAcceleration, speed, dt))
    slip = slip or { base = base }
    slip.written = cmc.GroundFriction -- read back: the property stores a float
end

-- Mouse X movement over the last 1/30 s, from the per-frame samples (the oldest frame in the
-- window counts in proportion to how much of it falls inside).
local function mouseReferenceValue()
    local window = 1 / REFERENCE_FPS
    local sum, covered = 0, 0
    for i = 0, mouse.count - 1 do
        local index = (mouse.head - i - 1) % MOUSE_HISTORY + 1
        local dt = mouse.dts[index]
        if covered + dt >= window then
            return sum + mouse.values[index] * (window - covered) / dt
        end
        sum, covered = sum + mouse.values[index], covered + dt
    end
    return sum
end

-- Hooked around InputAxis_RightStick_X, where the Blueprint stores the axis value for this frame.
-- It takes one raw sample per frame and, while mouse steering a charge, replaces the stored value.
local function onMouseAxis(context, axisValue)
    local raw = axisValue:get()
    if mouse.frame ~= frameCounter then
        mouse.frame = frameCounter
        mouse.head = mouse.head % MOUSE_HISTORY + 1
        mouse.values[mouse.head], mouse.dts[mouse.head] = raw, lastDt
        mouse.count = math.min(mouse.count + 1, MOUSE_HISTORY)
        mouse.component = context:get()
    end
    if not mouse.active then return end
    local component = context:get()
    -- Only after the Blueprint stored this frame's value (it skips that while right-stick input is disabled).
    if component.InputAxisRightStickX == raw then
        component.InputAxisRightStickX = mouseReferenceValue()
    end
end

-- A hook error would repeat every frame, so the first one turns the fix off.
local function onMouseAxisGuarded(context, axisValue)
    if mouse.failed then return end
    local ok, err = pcall(onMouseAxis, context, axisValue)
    if not ok then
        mouse.failed = true
        mouse.active = false
        log("mouse charge steering fix disabled after hook error: %s", tostring(err))
    end
end

-- Blueprints load after the mods, so the hooked function is looked up once its class is created
-- (see watchNewObjects). `state` tracks the attempts; `name` is the fix named in the log.
local function registerBlueprintHook(state, path, pre, post, name)
    if state.registered or state.failed then return end
    if not lookUp(state, path) then return end
    local ok, err = pcall(RegisterHook, path, pre, post)
    if ok then
        state.registered = true
        log("%s hook registered", name)
    else
        state.failed = true
        log("%s fix disabled: RegisterHook failed: %s", name, tostring(err))
    end
end

local function registerMouseHook()
    -- Registered as both the pre and the post callback: whichever runs after the Blueprint stored
    -- the value replaces it (onMouseAxis checks the stored value first).
    registerBlueprintHook(mouse, MOUSE_AXIS_FUNCTION, onMouseAxisGuarded, onMouseAxisGuarded, "mouse charge steering")
end

-- CharacterInputComponent_Spyro.IsKeyboardMouseAndUsingMouseCheckingXAxis, the same test the
-- Blueprint uses to steer the charge with the mouse: keyboard/mouse input, mouse steering enabled
-- in the settings, and no keyboard steering this frame.
local function usingMouseSteering()
    local component = mouse.component
    if mouse.failed or not (component and component:IsValid()) then return false end
    local ok, result = pcall(function()
        local out = {}
        local ret = component:IsKeyboardMouseAndUsingMouseCheckingXAxis(out)
        if type(out["Is Using"]) == "boolean" then return out["Is Using"] end
        if type(ret) == "boolean" then return ret end
        error("IsKeyboardMouseAndUsingMouseCheckingXAxis returned no Is Using value")
    end)
    if ok then return result end
    mouse.failed = true
    log("mouse charge steering fix disabled: %s", tostring(result))
    return false
end

-- Both charge fixes only act above 30 FPS while charging: the slip fix on the ground, mouse
-- steering also during charge jumps (the Blueprint steers those the same way).
local function fixCharge(pawn, cmc, dt, mode, vel)
    local charging = (mode == MOVE_WALKING or mode == MOVE_FALLING) and dt >= MIN_TICK_TIME
        and dt < 1 / REFERENCE_FPS - 1e-4 and cmc.MaxWalkSpeed >= CHARGE_MIN_WALK_SPEED
    if charging then
        -- Pawns other than Spyro may not implement IGetIsCharging: treat them as not charging.
        local ok, result = pcall(isCharging, pawn)
        if not ok and not chargeQueryErrorLogged then
            chargeQueryErrorLogged = true
            log("IGetIsCharging failed (treated as not charging): %s", tostring(result))
        end
        charging = ok and result
    end
    if FIX_CHARGE_TURN_SLIP then fixChargeTurnSlip(cmc, dt, vel, charging and mode == MOVE_WALKING) end
    mouse.active = FIX_MOUSE_CHARGE_STEERING and charging and usingMouseSteering()
end

-- FInterpTo speed that leaves the same steady lag behind a steadily moving target at this dt as
-- `speed` does at 30 FPS. Each frame keeps (1 - speed * dt) of the gap, and a target moving at w
-- per second stays w * dt * (1 - f) / f ahead, with f = speed * dt.
local function referenceInterpSpeed(speed, dt)
    if speed <= 0 then return speed end
    local refDt = 1 / REFERENCE_FPS
    local refStep = math.min(speed * refDt, 1)
    local ratio = (1 - refStep) / refStep * refDt / dt -- (1 - f) / f that gives the 30 FPS lag
    return 1 / ((1 + ratio) * dt)
end

local function readFollowCamera(pawn)
    return pawn.FollowCamera
end

-- Runs before each world tick, so m_ctrInterp written here applies to the next frame's camera update.
local function fixCameraCentering(pawn, dt)
    -- Pawns other than Spyro (e.g. Spyro 3's other playable characters) may have no follow camera.
    local ok, component = pcall(readFollowCamera, pawn)
    if not (ok and component and component:IsValid()) then camera = nil return end
    local address = component:GetAddress()
    if camera and camera.address ~= address then camera = nil end -- new pawn or camera
    local current = component.m_ctrInterp

    -- A camera settings push, pop or transition changed the value: find the new base below.
    if camera and camera.written and current ~= camera.written then camera = nil end

    if dt < MIN_TICK_TIME or dt >= 1 / REFERENCE_FPS - 1e-4 then
        if camera and camera.written then component.m_ctrInterp = camera.base end
        camera = nil
        return
    end
    if not (camera and camera.written) then
        -- Only asked when the value changed under us (or at start), so this is rarely called.
        if component:IsTransitioning() then
            camera = { address = address }
            return
        end
        camera = { address = address, base = current }
    end
    component.m_ctrInterp = referenceInterpSpeed(camera.base, dt)
    camera.written = component.m_ctrInterp -- read back: the property stores a float
end

local function wrapDegrees(a)
    a = a % 360
    if a > 180 then a = a - 360 end
    return a
end

-- m_ctrDecelAngleTurnModifier is a component property only (not in FollowCameraSettings), so camera
-- settings pushes, pops and transitions don't blend it; a change we didn't make is a new base.
local function fixCameraCenteringSwitch(pc, pawn, dt)
    local ok, component = pcall(readFollowCamera, pawn)
    if not (ok and component and component:IsValid()) then switch = nil return end
    local address = component:GetAddress()
    if switch and switch.address ~= address then switch = nil end
    local current = component.m_ctrDecelAngleTurnModifier
    if not switch then
        switch = { address = address, base = current < STUCK_CAMERA_RELEASE / 2 and current or DEFAULT_TURN_MODIFIER }
    elseif current ~= switch.written and current < STUCK_CAMERA_RELEASE / 2 then
        switch.base = current
    end

    local value = switch.base
    if FIX_CAMERA_CENTERING_SWITCH and dt >= MIN_TICK_TIME and dt < 1 / REFERENCE_FPS - 1e-4 then
        value = switch.base / (REFERENCE_FPS * dt)
    end
    if FIX_STUCK_CAMERA then
        local gap = math.abs(wrapDegrees(pawn:K2_GetActorRotation().Yaw - pc:GetControlRotation().Yaw))
        if not switch.minGap or gap < switch.minGap then switch.minGap = gap end
        if gap - switch.minGap >= STUCK_CAMERA_GROWTH then
            value = STUCK_CAMERA_RELEASE
            -- Most releases happen while centering is off or already interpolating and do nothing;
            -- only log the ones that look like a stuck charge camera.
            if STUCK_CAMERA_LOG_GAP and gap >= STUCK_CAMERA_LOG_GAP then
                local chargeOk, charging = pcall(isCharging, pawn)
                if chargeOk and charging then
                    log("stuck camera release: gap %.1f deg, grew from %.1f", gap, switch.minGap)
                end
            end
            switch.minGap = gap
        end
    end
    if value ~= current then component.m_ctrDecelAngleTurnModifier = value end
    switch.written = component.m_ctrDecelAngleTurnModifier -- read back: the property stores a float
end

-- UEHelpers.GetPlayerController() runs FindAllOf("PlayerController") on every call, which is too
-- expensive to do every frame, so keep the controller until it becomes invalid (level change)
-- and only search again every CONTROLLER_RETRY_FRAMES frames while there is none.
local CONTROLLER_RETRY_FRAMES = 30
local cachedController = nil
local controllerRetryIn = 0
local cachedStatics = nil

local function getPlayerController()
    if cachedController and cachedController:IsValid() then return cachedController end
    cachedController = nil
    if controllerRetryIn > 0 then
        controllerRetryIn = controllerRetryIn - 1
        return nil
    end
    local pc = UEHelpers.GetPlayerController()
    if pc:IsValid() then
        cachedController = pc
    else
        controllerRetryIn = CONTROLLER_RETRY_FRAMES
    end
    return cachedController
end

local function getGameplayStatics()
    if not (cachedStatics and cachedStatics:IsValid()) then cachedStatics = UEHelpers.GetGameplayStatics() end
    return cachedStatics
end

-- Gives the dust effects we stretched or slowed normal time back. Runs on the next frame, after
-- their one tick before the Blueprint deactivates them, so their particles then age normally.
local function resetDustDilations()
    for i = #dust.dilated, 1, -1 do
        local effect = dust.dilated[i]
        dust.dilated[i] = nil
        if effect:IsValid() then effect.CustomTimeDilation = 1 end
    end
end

-- Both hook callbacks (pre and post) run this.
local function onDustHook(context)
    local pawn = context:get()
    if not dust.pawn or pawn:GetAddress() ~= dust.pawn then return end
    if dust.frame ~= frameCounter then
        dust.frame = frameCounter
        resetDustDilations()
    end
    local current = pawn.Charge_GroundEffects
    if not current:IsValid() then return end
    local address = current:GetAddress()
    -- Only an effect spawned this frame can still be changed before its first tick.
    if address == dust.frameStart or address == dust.handled then return end
    dust.handled = address

    local period = 1 / REFERENCE_FPS
    local continuing = dust.lastSpawnFrame == frameCounter - 1
    dust.lastSpawnFrame = frameCounter
    local dt = getGameplayStatics():GetWorldDeltaSeconds(pawn)
    if dt < MIN_TICK_TIME or dt >= period - 1e-4 then return end
    -- A new charge emits right away; after that, one effect every 1/30 s.
    dust.sinceDue = continuing and dust.sinceDue + dt or period
    if dust.sinceDue >= period - 1e-4 then
        dust.sinceDue = math.max(dust.sinceDue - period, 0)
        -- Its only tick then covers one 30 FPS frame, so every emitter spawns what it does at 30 FPS.
        current.CustomTimeDilation = period / dt
    else
        current.CustomTimeDilation = DUST_SILENT_DILATION
    end
    dust.dilated[#dust.dilated + 1] = current
end

-- A hook error would repeat every frame, so the first one turns the fix off.
local function disableDustFix(err)
    dust.failed = true
    pcall(resetDustDilations)
    log("charge dust fix disabled after hook error: %s", tostring(err))
end

local function onDustHookGuarded(context)
    if dust.failed then return end
    local ok, err = pcall(onDustHook, context)
    if not ok then disableDustFix(err) end
end

local function readDustEffectAddress(pawn)
    local effect = pawn.Charge_GroundEffects
    return effect and effect:IsValid() and effect:GetAddress() or nil
end

-- Runs before each world tick: remembers the pawn and its current effect for the hook callbacks.
local function prepareChargeDust(pawn)
    dust.pawn = pawn:GetAddress()
    local ok, address = pcall(readDustEffectAddress, pawn)
    dust.frameStart = ok and address or nil
    -- Callbacks stopped (pause, level change): don't leave effects slowed down.
    if dust.frame < frameCounter - 1 and #dust.dilated > 0 then resetDustDilations() end
    -- Registered as both the pre and the post callback (see the dust state above).
    registerBlueprintHook(dust, CHARGE_DUST_FUNCTION, onDustHookGuarded, onDustHookGuarded, "charge dust")
end

-- Moves the druid montage's Energize notify (see the header). Notify extraction reads the trigger
-- time live as the notify's time (LinkValue) plus TriggerTimeOffset, so only the offset changes.
-- Returns the new trigger time, or nil if this montage object is already patched.
local function patchDruidMontage(montage)
    local notifies = montage.Notifies
    for i = 1, notifies:GetArrayNum() do
        local notify = notifies[i]
        if notify.NotifyName:ToString() == "Energize" then
            local time = notify.LinkValue
            if math.abs(time - DRUID_NOTIFY_TIME) > 1e-4 then
                error(string.format("unexpected Energize notify time %.5f", time))
            end
            local offset = DRUID_FIXED_NOTIFY_TIME - time
            if math.abs(notify.TriggerTimeOffset - offset) < 1e-6 then return nil end
            notify.TriggerTimeOffset = offset
            local triggerTime = time + notify.TriggerTimeOffset -- read back
            if math.abs(triggerTime - DRUID_FIXED_NOTIFY_TIME) > 1e-6 then
                error(string.format("TriggerTimeOffset write didn't stick (trigger time %.5f)", triggerTime))
            end
            return triggerTime
        end
    end
    error("no Energize notify")
end

-- Only the druid levels' own assets reference the montage (LS113, LS114, LS115, LS118), so it is
-- looked up once it is created (see watchNewObjects), each time one of those levels loads.
local function fixDruidEnergize()
    local montage = lookUp(druid, DRUID_MONTAGE)
    if not montage then return end
    -- Created but not loaded yet: try again later (found lookups don't hitch).
    if montage.Notifies:GetArrayNum() == 0 then druid.lookups = math.max(druid.lookups, 1) return end
    druid.lookups = 0
    local triggerTime = patchDruidMontage(montage)
    if triggerTime then log("druid Energize notify moved to %.5f s", triggerTime) end
end

-- Seconds a segment trails its leader per unit of leader speed at 30 FPS (see the header).
local DRAGON_KEEP_30 = (1 - DRAGON_FOLLOW_RATE / REFERENCE_FPS) ^ 2
local DRAGON_TRAIL_30 = DRAGON_KEEP_30 / (1 - DRAGON_KEEP_30) / REFERENCE_FPS

-- The delta to pass MoveUpdate for a frame of dt seconds.
local function referenceDragonDelta(dt)
    -- Frames of 1/30 s or longer, and InitializeBody's call with 0, get the Blueprint's own delta.
    if dt >= 1 / REFERENCE_FPS - 1e-4 or dt < MIN_TICK_TIME then return math.max(dt, DRAGON_MIN_DELTA) end
    -- Keep the fraction K per call that trails by dt * K / (1 - K) = DRAGON_TRAIL_30.
    local keep = DRAGON_TRAIL_30 / (dt + DRAGON_TRAIL_30)
    return (1 - math.sqrt(keep)) / DRAGON_FOLLOW_RATE
end

-- Hands every segment we took over back to the Blueprint's own MoveUpdate calls.
local function releaseDragonSegments()
    for _, head in pairs(dragon.heads) do
        if head:IsValid() then
            local segments = head.BodySegments
            for i = 1, segments:GetArrayNum() do
                local segment = segments[i]
                if segment:IsValid() and segment.IsAlive_0 then segment.DragonSineMovement.bAlive = true end
            end
        end
    end
    dragon.heads = {}
end

-- Runs when the head's UpdatePrevActors runs (after its body with this UE4SS build, but it works
-- before it too). Repeats the Blueprint's loop: every valid, alive segment follows the previous one,
-- the first follows the head, with the head's mesh raised as the Blueprint has it.
local function onDragonUpdate(context, deltaTime)
    local head = context:get()
    dragon.heads[head:GetAddress()] = head
    local delta = referenceDragonDelta(deltaTime:get())
    local mesh = head.Mesh
    mesh:K2_AddRelativeLocation(DRAGON_LIFT_VEC, false, DRAGON_SWEEP_HIT, false)
    local leader = head
    local segments = head.BodySegments
    for i = 1, segments:GetArrayNum() do
        local segment = segments[i]
        if segment:IsValid() and segment.IsAlive_0 then
            local movement = segment.DragonSineMovement
            if movement.bAlive then
                -- New to us (a new dragon, or a grown segment): the Blueprint may already have moved
                -- it this frame, so only take it over. HandleDeath also clears bAlive, but together
                -- with IsAlive, so an alive segment with bAlive off is always one of ours.
                movement.bAlive = false
            else
                movement.bAlive = true
                movement:MoveUpdate(delta, leader)
                movement.bAlive = false
            end
            leader = segment
        end
    end
    mesh:K2_AddRelativeLocation(DRAGON_LOWER_VEC, false, DRAGON_SWEEP_HIT, false)
end

local function onDragonUpdateGuarded(context, deltaTime)
    if dragon.failed then return end
    local ok, err = pcall(onDragonUpdate, context, deltaTime)
    if not ok then
        -- Segments left with bAlive off would freeze, so give them back before giving up.
        dragon.failed = true
        pcall(releaseDragonSegments)
        log("fire dragon segment fix disabled after hook error: %s", tostring(err))
    end
end

-- The dragon Blueprint only loads with Fireworks Factory, and its function object is replaced when the
-- level loads again, so each time its class is created (see watchNewObjects) it is looked up and
-- hooked again. RegisterHook can fail while the level is still loading (UFunction::Func 0x0), so
-- failures are retried too.
local function registerDragonHook()
    if dragon.failed then return end
    local fn = lookUp(dragon, DRAGON_UPDATE_FUNCTION)
    if not fn then return end
    local address = fn:GetAddress()
    if address == dragon.hooked then dragon.lookups = 0 return end
    -- Found but not hooked: keep trying while the level finishes loading (failures are capped).
    dragon.lookups = math.max(dragon.lookups, 1)
    local ok, err = pcall(RegisterHook, DRAGON_UPDATE_FUNCTION, onDragonUpdateGuarded)
    if ok then
        dragon.hooked = address
        dragon.lookups = 0
        dragon.failures = 0
        log("fire dragon segment hook registered")
    else
        dragon.failures = dragon.failures + 1
        if dragon.failures >= HOOK_MAX_FAILURES then
            dragon.failed = true
            log("fire dragon segment fix disabled: RegisterHook failed: %s", tostring(err))
        end
    end
end

local function tick()
    local pc = getPlayerController()
    if not pc then return end
    if FIX_DRUID_ENERGIZE and not druid.failed then
        local ok, err = pcall(fixDruidEnergize)
        if not ok then
            druid.failed = true
            log("druid Energize fix disabled after error: %s", tostring(err))
        end
    end
    if FIX_DRAGON_SEGMENTS and not dragon.failed then
        local ok, err = pcall(registerDragonHook)
        if not ok then
            dragon.failed = true
            log("fire dragon segment fix disabled after error: %s", tostring(err))
        end
    end
    local pawn = pc.Pawn
    if not pawn:IsValid() then tracked = nil jump = nil slip = nil camera = nil switch = nil mouse.active = false return end
    local cmc = pawn.CharacterMovement
    if not cmc:IsValid() then tracked = nil jump = nil slip = nil camera = nil switch = nil mouse.active = false return end
    local dt = getGameplayStatics():GetWorldDeltaSeconds(pawn)
    lastDt = dt
    -- Read once and share: all fixes need the mode and velocity from the frame that just finished.
    local mode = cmc.MovementMode
    local vel = cmc.Velocity
    fixWalkingVelocity(pawn, cmc, dt, mode, vel)
    fixJumpHeight(pawn, cmc, dt, mode, vel)
    if FIX_MOUSE_CHARGE_STEERING then registerMouseHook() end
    if FIX_CHARGE_DUST and not dust.failed then
        local ok, err = pcall(prepareChargeDust, pawn)
        if not ok then disableDustFix(err) end
    end
    if (FIX_CHARGE_TURN_SLIP or FIX_MOUSE_CHARGE_STEERING) and not chargeQueryFailed then
        local ok, err = pcall(fixCharge, pawn, cmc, dt, mode, vel)
        if not ok then
            -- Don't retry a broken charge query every frame, and don't leave friction raised.
            chargeQueryFailed = true
            mouse.active = false
            if slip then pcall(function() cmc.GroundFriction = slip.base end) end
            slip = nil
            log("charge fixes disabled after error: %s", tostring(err))
        end
    end
    if FIX_CAMERA_CENTERING and not cameraFixFailed then
        local ok, err = pcall(fixCameraCentering, pawn, dt)
        if not ok then
            cameraFixFailed = true
            if camera and camera.written then
                pcall(function() pawn.FollowCamera.m_ctrInterp = camera.base end)
            end
            camera = nil
            log("camera centering fix disabled after error: %s", tostring(err))
        end
    end
    if (FIX_CAMERA_CENTERING_SWITCH or FIX_STUCK_CAMERA) and not switchFixFailed then
        local ok, err = pcall(fixCameraCenteringSwitch, pc, pawn, dt)
        if not ok then
            switchFixFailed = true
            if switch and switch.written then
                pcall(function() pawn.FollowCamera.m_ctrDecelAngleTurnModifier = switch.base end)
            end
            switch = nil
            log("camera centering switch and stuck camera fixes disabled after error: %s", tostring(err))
        end
    end
end

local function runTick()
    frameCounter = frameCounter + 1
    local ok, err = pcall(tick)
    if not ok and not errorLogged then
        errorLogged = true
        log("error: %s", tostring(err))
    end
end

-- Profiling: times each frame's fix work with the engine's high-resolution clock (os.clock only
-- has 1 ms resolution on Windows) and logs a summary every PROFILE_INTERVAL seconds.
local profile = { frames = 0, cost = 0, maxCost = 0, timerCost = 0, frameTime = 0, windowStart = nil }
-- GC investigation counters, folded into the same window. gcMinDelta is the most negative
-- collectgarbage("count") change seen in one frame (the biggest apparent collection); maxCostGcDelta
-- is that same delta but specifically on the frame that had the window's maxCost, to see whether the
-- worst-cost frame is also the frame a collection landed in.
local gcProfile = { collections = 0, minDelta = nil, maxCostGcDelta = nil, totalDelta = 0 }

local function describeTable(t)
    local parts = {}
    for k, v in pairs(t) do parts[#parts + 1] = tostring(k) .. "=" .. tostring(v) end
    return "{" .. table.concat(parts, ", ") .. "}"
end

local function accurateSeconds(statics, context)
    -- UE4SS fills out-params into the passed tables keyed by parameter name. In practice the
    -- second out-param did not land in its own table, so accept either field from either table.
    local seconds, partial = {}, {}
    statics:GetAccurateRealTime(context, seconds, partial)
    local whole = seconds.Seconds or partial.Seconds
    local fraction = partial.PartialSeconds or seconds.PartialSeconds
    if type(whole) ~= "number" or type(fraction) ~= "number" then
        error("GetAccurateRealTime out-params: seconds=" .. describeTable(seconds) .. " partial=" .. describeTable(partial))
    end
    return whole + fraction
end

local function profiledTick()
    local pc = getPlayerController()
    if not pc then return runTick() end
    local statics = getGameplayStatics()

    -- Two back-to-back clock reads measure the clock's own cost, which is subtracted from the
    -- measured tick (that interval also contains one clock call).
    local t0 = accurateSeconds(statics, pc)
    local t1 = accurateSeconds(statics, pc)
    local gcBefore = GC_PROFILE and collectgarbage("count") or nil
    runTick()
    local gcAfter = GC_PROFILE and collectgarbage("count") or nil
    local t2 = accurateSeconds(statics, pc)

    local timerCost = t1 - t0
    local cost = math.max(0, (t2 - t1) - timerCost)
    profile.frames = profile.frames + 1
    profile.cost = profile.cost + cost
    local isNewMax = cost > profile.maxCost
    profile.maxCost = math.max(profile.maxCost, cost)
    profile.timerCost = profile.timerCost + timerCost
    profile.frameTime = profile.frameTime + statics:GetWorldDeltaSeconds(pc)
    profile.windowStart = profile.windowStart or t0

    if GC_PROFILE then
        -- KB allocated this frame minus KB the collector reclaimed; negative means a collection ran
        -- and outpaced whatever we allocated (Lua's automatic collector runs synchronously inside
        -- whichever allocation crosses its threshold, so a big one shows up as extra cost above).
        local delta = gcAfter - gcBefore
        gcProfile.totalDelta = gcProfile.totalDelta + delta
        if delta <= -GC_COLLECTION_KB then gcProfile.collections = gcProfile.collections + 1 end
        gcProfile.minDelta = gcProfile.minDelta and math.min(gcProfile.minDelta, delta) or delta
        if isNewMax then gcProfile.maxCostGcDelta = delta end
    end

    if t2 - profile.windowStart >= PROFILE_INTERVAL then
        local n = profile.frames
        local avgFrame = profile.frameTime / n
        log("profile: %d frames (avg frame %.2f ms), fixes avg %.3f ms (%.2f%% of frame), max %.3f ms, clock overhead avg %.3f ms",
            n, avgFrame * 1000, profile.cost / n * 1000, profile.cost / profile.frameTime * 100,
            profile.maxCost * 1000, profile.timerCost / n * 1000)
        if GC_PROFILE then
            log("gc: %d frame(s) with a >=%.0f KB drop (%.2f/s), heap now %.1f KB, avg delta %.3f KB/frame, biggest drop %.1f KB, delta on max-cost frame %s",
                gcProfile.collections, GC_COLLECTION_KB, gcProfile.collections / (avgFrame * n),
                collectgarbage("count"), gcProfile.totalDelta / n, gcProfile.minDelta or 0,
                gcProfile.maxCostGcDelta and string.format("%.1f KB", gcProfile.maxCostGcDelta) or "n/a")
            gcProfile.collections, gcProfile.minDelta, gcProfile.maxCostGcDelta, gcProfile.totalDelta = 0, nil, nil, 0
        end
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

if GC_MODE then
    local ok, err = pcall(collectgarbage, GC_MODE)
    if ok then log("collectgarbage(%q) applied to the shared Lua state", GC_MODE)
    else log("collectgarbage(%q) failed: %s", GC_MODE, tostring(err)) end
end

-- Lookups for level objects start when their class or asset is created: a StaticFindObject that
-- finds nothing costs ~10 ms, so they must not poll. The callback only flags the state; the lookup
-- runs from the tick (on the game thread, after loading has had a chance to finish).
local function startLookups(state)
    if not state then return end
    state.lookups = NEW_OBJECT_LOOKUPS
    state.retryIn = 0
end
local function onNewObject(names, object)
    local ok, name = pcall(function() return object:GetFName():ToString() end)
    if ok then startLookups(names[name]) end
end
local classes, montages = {}, {}
if FIX_MOUSE_CHARGE_STEERING then classes["CharacterInputComponent_Spyro_C"] = mouse end
if FIX_CHARGE_DUST then classes["BP_CPS1999_Playable_C"] = dust end
if FIX_DRAGON_SEGMENTS then classes["BP_CBS3012_FireDragon_C"] = dragon end
if FIX_DRUID_ENERGIZE then montages["AM_CES1035_GreenDruid_Casting_Up"] = druid end
NotifyOnNewObject("/Script/Engine.BlueprintGeneratedClass", function(object) onNewObject(classes, object) end)
NotifyOnNewObject("/Script/Engine.AnimMontage", function(object) onNewObject(montages, object) end)

LoopInGameThreadAfterFrames(1, PROFILE and profiledLoop or runTick)

log("v%s loaded%s%s", VERSION, PROFILE and " (profiling on)" or "", GC_PROFILE and " (GC profiling on)" or "")
