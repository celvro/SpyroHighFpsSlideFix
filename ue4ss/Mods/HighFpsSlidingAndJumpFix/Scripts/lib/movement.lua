-- Lua mirrors of the UE 4.19 walking movement math (UCharacterMovementComponent), so the walking
-- velocity fix can work out what the engine's velocity would be without float32 quantization.
local log = require("lib.log")
local util = require("lib.util")

local MIN_TICK_TIME = util.MIN_TICK_TIME
local BRAKE_TO_STOP_VELOCITY = 10
local MAX_BRAKING_STEP = 1 / 33

local movement = {}
local brakingParamsLogged = false

-- Distance between adjacent float32 values at magnitude v.
function movement.floatSpacing(v)
    v = math.abs(v)
    if v < 1 then return 2 ^ -24 end
    -- UE4SS runs Lua 5.4, which has no math.frexp.
    local exp = math.floor(math.log(v, 2))
    if 2 ^ (exp + 1) <= v then exp = exp + 1 elseif 2 ^ exp > v then exp = exp - 1 end
    return 2 ^ (exp - 23)
end

-- Largest velocity error a rounded move can introduce this frame, with a little slack.
function movement.quantizationTolerance(pawn, dt)
    local loc = pawn:K2_GetActorLocation()
    local spacing = movement.floatSpacing
    return (math.max(spacing(loc.X), spacing(loc.Y), spacing(loc.Z)) / dt) * 1.01
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
function movement.calcWalkingVelocity(cmc, vx, vy, ax, ay, dt)
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

-- Mirrors CalcVelocity (UE 4.19) for walking under a path following request (ApplyRequestedMove), with
-- zero input acceleration. `request` is RequestedVelocity: the direction to the current path point,
-- scaled to reach it in one frame. Returns nil when the request is too small to be applied.
function movement.calcRequestedWalkingVelocity(cmc, vx, vy, request, dt)
    local rx, ry, rz = request.X, request.Y, request.Z
    local requestedSq = rx * rx + ry * ry + rz * rz
    if requestedSq < 1e-4 then return nil end
    local requested = math.sqrt(requestedSq)
    local dx, dy, dz = rx / requested, ry / requested, rz / requested
    local maxSpeed = cmc.MaxWalkSpeed
    local speed = cmc.bRequestedMoveWithMaxSpeed and maxSpeed or math.min(maxSpeed, requested)
    local mx, my, mz = dx * speed, dy * speed, dz * speed

    -- PhysWalking zeroes Z before CalcVelocity; the Z the request adds is flattened after the move.
    local vz = 0
    local ax, ay, az = 0, 0, 0
    if cmc.bRequestedMoveUseAcceleration and vx * vx + vy * vy < (speed * 1.01) ^ 2 then
        -- Turn in the same manner as with input acceleration, then accelerate towards the move velocity.
        local size = math.sqrt(vx * vx + vy * vy)
        local blend = math.min(dt * math.max(0, cmc.GroundFriction), 1)
        vx, vy, vz = vx - (vx - dx * size) * blend, vy - (vy - dy * size) * blend, vz - (vz - dz * size) * blend
        ax, ay, az = (mx - vx) / dt, (my - vy) / dt, (mz - vz) / dt
        local accelSize = math.sqrt(ax * ax + ay * ay + az * az)
        local maxAccel = cmc.MaxAcceleration
        if accelSize > maxAccel and accelSize > 0 then
            local scale = maxAccel / accelSize
            ax, ay, az = ax * scale, ay * scale, az * scale
        end
    else
        -- Decelerating: the engine sets the velocity directly so he doesn't slide past the destination.
        vx, vy, vz = mx, my, mz
    end

    -- Braking only when over the (requested) max speed: the request counts as acceleration.
    local limit = math.max(speed, cmc.MinAnalogWalkSpeed)
    if vx * vx + vy * vy + vz * vz > limit * limit * 1.01 then
        local friction, deceleration = brakingParams(cmc)
        vx, vy, vz = applyBraking(vx, vy, vz, dt, friction, deceleration)
    end

    if ax ~= 0 or ay ~= 0 or az ~= 0 then
        local sizeSq = vx * vx + vy * vy + vz * vz
        local newMax = sizeSq > speed * speed * 1.01 and math.sqrt(sizeSq) or speed
        vx, vy, vz = vx + ax * dt, vy + ay * dt, vz + az * dt
        sizeSq = vx * vx + vy * vy + vz * vz
        if sizeSq > newMax * newMax then
            local scale = newMax / math.sqrt(sizeSq)
            vx, vy = vx * scale, vy * scale
        end
    end
    return vx, vy
end

return movement
