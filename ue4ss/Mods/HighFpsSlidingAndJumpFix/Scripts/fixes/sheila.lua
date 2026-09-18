-- Sheila walk fix (Buzz fight)
--
-- In the Buzz fight (Spyro 3) Sheila patrols the arena (PatrolMoveIn/Out) and, once Buzz is set on
-- fire, walks up to him (SeekBurningBuzz) to jump and stomp him into the lava. Her AI requests each
-- move directly (RequestedVelocity with bRequestedMoveUseAcceleration, i.e. UE 4.19's
-- ApplyRequestedMove), which accelerates her at MaxAcceleration (2048) towards the target up to
-- MaxWalkSpeed (400). The arena sits ~300,000 from the origin (1/32 position steps) and walking
-- resets Velocity to (displacement / dt), so above ~250 FPS her first move from a standstill rounds to
-- nothing and she stands still until a frame hitch, then crawls on the rounding lanes. Measured
-- uncapped (400-530 FPS): first move after 0.08-0.24 s, 90% of her speed after 0.4-1.1 s or never,
-- short patrol moves covering 5-60 units instead of 100-250, and SeekBurningBuzz starting from a
-- standstill on the far side of the arena. At 30 FPS she moves on the first frame and reaches 400 in 0.2 s.
-- While she walks (not during her scripted jump, which moves her with SetActorLocation), this keeps
-- her unrounded velocity with the walking fix's model (requested move while her AI requests one, else
-- input acceleration or braking) and writes it back whenever the engine's
-- velocity differs only by rounding. Frames of 1/30 s or longer are left alone.

local config = require("config")
local engine = require("lib.engine")
local log = require("lib.log")
local lookup = require("lib.lookup")
local movement = require("lib.movement")
local profiler = require("profiler")
local util = require("lib.util")

local MOVE_WALKING, MOVE_NAV_WALKING = util.MOVE_WALKING, util.MOVE_NAV_WALKING

local fix = { name = "Sheila walk fix", enabled = config.FIX_SHEILA_BUZZ_WALK, failed = false }

local hook = {
    class = "BP_Sheila_SP3NPC_Buzz_C",
    path = "/CPS3339_Sheila/Blueprints/BP_Sheila_SP3NPC_Buzz.BP_Sheila_SP3NPC_Buzz_C:ReceiveTick",
    hooked = nil, failures = 0, retryIn = 0, lookups = 1,
}

local tracked = nil      -- { x, y, stats }: unrounded velocity from the previous frame
local handledFrame = nil -- engine.frame of the last correction (pre and post both call the hook)
local lastRequest = { X = 0, Y = 0, Z = 0 } -- RequestedVelocity seen last frame
local MIN_LOGGED_STINT = 0.05              -- seconds; shorter stretches (braking tails) are not logged
local VELOCITY = { X = 0, Y = 0, Z = 0 }

local function endStint()
    if not tracked then return end
    local s = tracked.stats
    tracked = nil
    if s.written + s.followed == 0 or s.time < MIN_LOGGED_STINT then return end
    log("%s: walking %.2fs (%d frames, %d moving), %d written, %d followed the engine",
        fix.name, s.time, s.frames, s.requested, s.written, s.followed)
end

-- RequestedVelocity while her AI is moving her, else nil. Her state logic requests the move directly
-- every frame (not through her controller's path following, which stays idle), aimed to reach the
-- target in one frame, so a live request changes every frame. It is 0 while she stands; a request
-- equal to last frame's is left over. Measured: nonzero and changed on all ~5,600 walking frames.
local function liveRequest(cmc)
    local request = cmc.RequestedVelocity
    local x, y, z = request.X, request.Y, request.Z
    local changed = x ~= lastRequest.X or y ~= lastRequest.Y or z ~= lastRequest.Z
    lastRequest.X, lastRequest.Y, lastRequest.Z = x, y, z
    if not changed or (x == 0 and y == 0 and z == 0) then return nil end
    return request
end

local function correct(sheila)
    if handledFrame == engine.frame then return end
    handledFrame = engine.frame
    local cmc = sheila.CharacterMovement
    local mode = cmc:IsValid() and cmc.MovementMode
    if (mode ~= MOVE_WALKING and mode ~= MOVE_NAV_WALKING) or not cmc:IsComponentTickEnabled()
        or sheila:IsPlayingRootMotion() then
        return endStint()
    end
    local vel = cmc.Velocity
    local vx, vy, vz = vel.X, vel.Y, vel.Z
    local request = liveRequest(cmc)
    local accel = not request and cmc:GetCurrentAcceleration() or nil
    local ax, ay = accel and accel.X or 0, accel and accel.Y or 0
    if not tracked then
        -- Standing still: start from zero, so a move that starts here is predicted from its first frame.
        if vx == 0 and vy == 0 and not request and ax == 0 and ay == 0 then return end
        tracked = { x = vx, y = vy, stats = { time = 0, frames = 0, requested = 0, written = 0, followed = 0 } }
        if vx ~= 0 or vy ~= 0 then return end
    end
    local dt = engine.worldDeltaSeconds(sheila) * sheila.CustomTimeDilation
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

    local tolerance = movement.quantizationTolerance(sheila, dt)
    if math.abs(vx - px) <= tolerance and math.abs(vy - py) <= tolerance and math.abs(vz) <= tolerance then
        if vx ~= px or vy ~= py or vz ~= 0 then
            VELOCITY.X, VELOCITY.Y = px, py
            cmc.Velocity = VELOCITY
            s.written = s.written + 1
        end
        tracked.x, tracked.y = px, py
    else
        -- Something other than rounding changed her velocity (a wall, a script): follow the engine.
        tracked.x, tracked.y = vx, vy
        s.followed = s.followed + 1
    end
    if px == 0 and py == 0 and not request and ax == 0 and ay == 0 then endStint() end
end

-- Registered as both the pre and the post callback (this UE4SS build calls only one for Blueprints),
-- so it acts once per frame. An error would repeat every frame, so the first one stops it.
local onTick = profiler.wrapHook("sheila", function(context)
    if fix.failed then return end
    local ok, err = pcall(correct, context:get())
    if not ok then
        fix.failed = true
        log("%s disabled after hook error: %s", fix.name, tostring(err))
    end
end)

function fix.update()
    local result = lookup.hookLevelFunction(hook, onTick, fix.name)
    if result == "hooked" then tracked = nil end
    if result == "failed" then fix.failed = true end
end

if fix.enabled then
    lookup.watch("/Script/Engine.BlueprintGeneratedClass", hook.class, hook)
end

return fix
