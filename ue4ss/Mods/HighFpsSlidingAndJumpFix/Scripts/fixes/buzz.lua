-- Buzz charge run fix
--
-- Buzz (Spyro 3 boss, Buzz's Dungeon) runs at Spyro in his ChargeRun state (also RollAttack and
-- RollRetreat) with PhasmidCharacterMovement's native car movement: each frame his current Velocity
-- turns with his body and gains MaxAcceleration * dt (2048/s) along his facing, up to MaxWalkSpeed
-- (600). The direction is carried in Velocity, so rounding can lock it too: a first move rounded to
-- pure +Y stayed (0, 10) for 0.7 s while he faced 46 degrees. His arena sits near (-299,700, -299,800),
-- where float32 positions have a 1/32 spacing, and walking (NavWalking during ChargeRun, Walking during
-- the rolls) resets Velocity to (displacement / dt) after every move. From a standstill the
-- first move is 2048 * dt^2: 0.006 at 570 FPS, under half a step, so it rounds to nothing, Velocity
-- goes back to 0 and he plays the run montage in place. A long frame (a hitch) gets him going, but then
-- each move rounds to one step and his speed locks to (1/32) / dt (about 16) until the next hitch.
-- Measured uncapped: 0.15-0.54 s before the first move and 240-740 units per 2 s run; at 320 FPS one
-- run never moved and another crawled at 18/s; at 30 FPS every run moves on its second frame and
-- covers ~1000-1100 units.
-- While his car movement is on, this keeps the unrounded velocity (same model) and writes it back
-- whenever the engine's velocity differs from it only by that rounding, like the walking fix does
-- for Spyro. When the car movement ends (after a roll) he brakes normally, without input, and at high FPS
-- the last of that braking is under half a step: he slid on after rolls. So the same tracking carries on
-- through that braking (the walking fix's CalcVelocity model) until he stops or something else moves
-- him. Frames of 1/30 s or longer are left alone.

local config = require("config")
local engine = require("lib.engine")
local log = require("lib.log")
local lookup = require("lib.lookup")
local movement = require("lib.movement")
local profiler = require("profiler")
local util = require("lib.util")

local MOVE_WALKING, MOVE_NAV_WALKING = util.MOVE_WALKING, util.MOVE_NAV_WALKING

local fix = { name = "Buzz charge run fix", enabled = config.FIX_BUZZ_CHARGE_RUN, failed = false }

-- The Buzz Blueprint and its LS326 subclass, which overrides ReceiveTick. Each is looked up and
-- hooked again when its class is created, since the function object is replaced when the level loads.
local hooks = {
    { class = "BP_CBS3002_Buzz2_C",
      path = "/CBS3002_Buzz/Blueprints/BP_CBS3002_Buzz2.BP_CBS3002_Buzz2_C:ReceiveTick" },
    { class = "BP_CBS3002_Buzz2_LS326_C",
      path = "/CBS3002_Buzz/Blueprints/BP_CBS3002_Buzz2_LS326.BP_CBS3002_Buzz2_LS326_C:ReceiveTick" },
}
for _, hook in ipairs(hooks) do
    hook.hooked, hook.failures, hook.retryIn, hook.lookups = nil, 0, 0, 1
end

local tracked = {}   -- Buzz address -> { x, y, yaw, stats }: unrounded velocity and facing from the previous frame
local handled = {}   -- Buzz address -> engine.frame of the last correction (both hooks can fire)
local VELOCITY = { X = 0, Y = 0, Z = 0 }

local function endStint(address, t)
    if not t then return end
    tracked[address] = nil
    local s = t.stats
    if s.written + s.followed == 0 then return end
    log("%s: car movement %.2fs (%d frames), braking %.2fs (%d frames), %d written, %d followed the engine",
        fix.name, s.carTime, s.carFrames, s.brakeTime, s.brakeFrames, s.written, s.followed)
end

local function correct(buzz)
    local address = buzz:GetAddress()
    if handled[address] == engine.frame then return end
    handled[address] = engine.frame
    local t = tracked[address]
    local cmc = buzz.CharacterMovement
    local mode = cmc:IsValid() and cmc.MovementMode
    if mode ~= MOVE_WALKING and mode ~= MOVE_NAV_WALKING then return endStint(address, t) end
    local car = cmc.bEnableCarMovement
    local vel = cmc.Velocity
    local vx, vy, vz = vel.X, vel.Y, vel.Z
    if not car then
        -- Braking without input (after a roll): only predicted when nothing else moves him.
        if not t and vx == 0 and vy == 0 then return end
        local a = cmc:GetCurrentAcceleration()
        if a.X ~= 0 or a.Y ~= 0 or cmc.bHasRequestedVelocity or buzz:IsPlayingRootMotion() then
            return endStint(address, t)
        end
    end
    local yawDeg = buzz:K2_GetActorRotation().Yaw
    local dt = engine.worldDeltaSeconds(buzz) * buzz.CustomTimeDilation
    if not t then
        tracked[address] = { x = vx, y = vy, yaw = yawDeg,
            stats = { carTime = 0, carFrames = 0, brakeTime = 0, brakeFrames = 0, written = 0, followed = 0 } }
        return
    end
    local s = t.stats
    if car then
        s.carTime, s.carFrames = s.carTime + dt, s.carFrames + 1
    else
        s.brakeTime, s.brakeFrames = s.brakeTime + dt, s.brakeFrames + 1
    end
    if not util.aboveReferenceFps(dt) then
        t.x, t.y, t.yaw = vx, vy, yawDeg
        return
    end

    local px, py
    if car then
        -- The last move: the velocity turned with his body, then MaxAcceleration * dt along his facing,
        -- capped at MaxWalkSpeed.
        local yaw = math.rad(yawDeg)
        local turn = math.rad(util.wrapDegrees(yawDeg - t.yaw))
        local c, sn = math.cos(turn), math.sin(turn)
        local accel = cmc.MaxAcceleration * dt
        px = t.x * c - t.y * sn + accel * math.cos(yaw)
        py = t.x * sn + t.y * c + accel * math.sin(yaw)
        local speed, maxSpeed = math.sqrt(px * px + py * py), cmc.MaxWalkSpeed
        if speed > maxSpeed then px, py = px * maxSpeed / speed, py * maxSpeed / speed end
    else
        -- The engine's own braking (friction 16, deceleration 2048 for Buzz), as in the walking fix.
        px, py = movement.calcWalkingVelocity(cmc, t.x, t.y, 0, 0, dt)
    end

    local tolerance = movement.quantizationTolerance(buzz, dt)
    if math.abs(vx - px) <= tolerance and math.abs(vy - py) <= tolerance and math.abs(vz) <= tolerance then
        if vx ~= px or vy ~= py or vz ~= 0 then
            VELOCITY.X, VELOCITY.Y = px, py
            cmc.Velocity = VELOCITY
            s.written = s.written + 1
        end
        t.x, t.y = px, py
    else
        -- Something other than rounding changed his velocity (a wall, a hit): follow the engine.
        t.x, t.y = vx, vy
        s.followed = s.followed + 1
    end
    t.yaw = yawDeg
    if not car and t.x == 0 and t.y == 0 then endStint(address, t) end
end

-- Registered as both the pre and the post callback (this UE4SS build calls only one for Blueprints),
-- so it acts once per frame per Buzz. An error would repeat every frame, so the first one stops it.
local onTick = profiler.wrapHook("buzz", function(context)
    if fix.failed then return end
    local ok, err = pcall(correct, context:get())
    if not ok then
        fix.failed = true
        log("%s disabled after hook error: %s", fix.name, tostring(err))
    end
end)

-- RegisterHook can fail while the level is still loading (UFunction::Func 0x0), so failures are
-- retried, up to lookup.MAX_FAILURES.
local function registerHook(hook)
    local fn = lookup.find(hook, hook.path)
    if not fn then return end
    local address = fn:GetAddress()
    if address == hook.hooked then hook.lookups = 0 return end
    hook.lookups = math.max(hook.lookups, 1)
    local ok, err = pcall(RegisterHook, hook.path, onTick, onTick)
    if ok then
        hook.hooked, hook.lookups, hook.failures = address, 0, 0
        tracked, handled = {}, {}
        log("%s hook registered (%s)", fix.name, hook.class)
    else
        hook.failures = hook.failures + 1
        if hook.failures >= lookup.MAX_FAILURES then
            fix.failed = true
            log("%s disabled: RegisterHook failed: %s", fix.name, tostring(err))
        end
    end
end

function fix.update()
    for _, hook in ipairs(hooks) do registerHook(hook) end
end

if fix.enabled then
    for _, hook in ipairs(hooks) do
        lookup.watch("/Script/Engine.BlueprintGeneratedClass", hook.class, hook)
    end
end

return fix
