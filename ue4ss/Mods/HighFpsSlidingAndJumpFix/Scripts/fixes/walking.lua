-- Walking velocity fix (sliding and acceleration)
--
-- Levels sit ~300,000 units from the world origin, where float32 positions have a 1/32 unit
-- spacing. UE 4.19's PhysWalking resets Velocity to (actual displacement / dt) after every
-- move, so velocity is quantized to multiples of (1/32)/dt: 4.5 at 144 FPS, 0.94 at 30.
--   * braking: above ~80 FPS a frame's braking removes less than half of that step, the
--     rounded move restores the old speed, and Spyro slides forever at a constant low speed.
--   * accelerating: a frame's 1000 * dt (6.9 at 144 FPS) of acceleration lands on 4.5 or 9, so
--     speeding up (e.g. starting a charge) runs at ~650 or ~1300 per second instead of 1000.
--   * scripted walks: path following (SimpleMoveToLocation, e.g. walking Spyro up to a freed
--     dragon) accelerates him through RequestedVelocity with no input. At ~500 FPS its first step
--     rounds to nothing and the walk starts late, then crawls at 100-200 instead of 268.
-- While walking without root motion, this keeps the unquantized velocity (same formula as
-- UCharacterMovementComponent::CalcVelocity, including ApplyRequestedMove while the controller's
-- PathFollowingComponent is moving) and writes it back whenever the engine's value only differs
-- by quantization. At low framerates the difference is negligible.

local config = require("config")
local log = require("lib.log")
local movement = require("lib.movement")
local util = require("lib.util")

local MIN_TICK_TIME = util.MIN_TICK_TIME
local MOVE_WALKING = util.MOVE_WALKING

local fix = { name = "walking velocity fix", enabled = true }

local tracked = nil -- { x, y, z } unquantized velocity carried from the previous frame
local STILL = { 0, 0, 0 } -- tracked velocity while standing; never modified
-- Path following (scripted walks): the controller's PathFollowingComponent and its class, whether a move
-- was active last frame (for the log), and failed after an error.
local path = { component = nil, class = nil, active = false, failed = false }

-- RequestedVelocity while the player controller's path following is moving Spyro (SimpleMoveToLocation,
-- e.g. walking him up to a freed dragon), else nil. The engine leaves RequestedVelocity set after the
-- move ends, so the path status decides; it's only queried while RequestedVelocity is nonzero.
local function readPathRequest(pc, cmc)
    local request = cmc.RequestedVelocity
    if request.X == 0 and request.Y == 0 and request.Z == 0 then return nil end
    if not (path.component and path.component:IsValid()) then
        path.class = path.class or StaticFindObject("/Script/AIModule.PathFollowingComponent")
        local component = pc:GetComponentByClass(path.class)
        path.component = (component and component:IsValid()) and component or nil
    end
    -- EPathFollowingAction: 0 Error, 1 NoMove (idle), 2 DirectMove, 3 PartialPath, 4 PathToGoal.
    if not path.component or path.component:GetPathActionType() < 2 then return nil end
    return { X = request.X, Y = request.Y, Z = request.Z }
end

local function pathRequest(pc, cmc)
    if path.failed then return nil end
    -- Called every frame without input (including standing still), so no closure per call.
    local ok, result = pcall(readPathRequest, pc, cmc)
    if not ok then
        path.failed = true
        log("path following moves aren't predicted after error: %s", tostring(result))
        return nil
    end
    if (result ~= nil) ~= path.active then
        path.active = result ~= nil
        log("walking fix: path following move %s", path.active and "started" or "ended")
    end
    return result
end

function fix.update(ctx)
    local pawn, cmc, dt = ctx.pawn, ctx.cmc, ctx.dt
    if ctx.mode ~= MOVE_WALKING then tracked = nil return end
    local vel = ctx.vel
    local vx, vy, vz = vel.X, vel.Y, vel.Z
    local stopped = vx == 0 and vy == 0 and vz == 0
    -- Standing still without input: skip the engine calls below. A move that starts here is predicted from zero.
    if stopped and not config.FIX_WALKING_ACCELERATION then
        tracked = nil
        return
    end
    local accel = cmc:GetCurrentAcceleration()
    local braking = accel.X == 0 and accel.Y == 0 and accel.Z == 0
    -- Path following moves Spyro through RequestedVelocity with zero input acceleration, which isn't braking:
    -- predicting braking held him in place (at 144 FPS the first step is 4.5 per axis, within the tolerance
    -- of 0). The engine's own path move breaks down at high FPS too: at ~550 FPS its first step rounds to
    -- nothing and its velocity locks to the position lattice, so predict it like input acceleration.
    local request = braking and config.FIX_WALKING_ACCELERATION and pathRequest(ctx.pc, cmc) or nil
    -- Zero velocity with input still has to be predicted: above ~250 FPS the first frame's move
    -- (MaxAcceleration * dt^2) rounds to nothing, the engine resets velocity to 0, and Spyro never starts moving.
    if stopped and braking and not request then
        tracked = STILL
        return
    end
    local handled = (braking or config.FIX_WALKING_ACCELERATION) and not pawn:IsPlayingRootMotion()

    if not handled or not tracked or dt < MIN_TICK_TIME then
        tracked = handled and { vx, vy, vz } or nil
        return
    end

    local bx, by
    if request then
        bx, by = movement.calcRequestedWalkingVelocity(cmc, tracked[1], tracked[2], request, dt)
    end
    if not bx then
        bx, by = movement.calcWalkingVelocity(cmc, tracked[1], tracked[2], accel.X, accel.Y, dt)
    end
    local bz = 0

    local tolerance = movement.quantizationTolerance(pawn, dt)

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

function fix.reset()
    tracked = nil
end

return fix
