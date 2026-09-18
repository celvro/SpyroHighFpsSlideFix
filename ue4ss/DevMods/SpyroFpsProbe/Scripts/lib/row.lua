-- The row sampled every frame: Spyro's movement, input, camera and charge state, plus values derived
-- from the previous row. Every tracker reads its measurements from these rows, and lib/trace.lua
-- writes them to the CSV.
local mouse = require("lib.mouse")
local util = require("lib.util")

local num, angleDiff, tryCall = util.num, util.angleDiff, util.tryCall

local CHARGE_WALK_SPEED = 450 -- GE_Spyro_Movement_Charging sets MaxWalkSpeed 458.5; used if the tag query fails

local row = {}

function row.build(pc, pawn, cmc, statics, time, prev)
    local loc = pawn:K2_GetActorLocation()
    local rot = pawn:K2_GetActorRotation()
    local vel = cmc.Velocity
    local input = cmc:GetLastInputVector()
    local accel = cmc:GetCurrentAcceleration()
    local floor = cmc.CurrentFloor
    local camManager = pc.PlayerCameraManager
    local camRot = camManager:IsValid() and camManager:GetCameraRotation() or nil
    local camLoc = camManager:IsValid() and camManager:GetCameraLocation() or nil
    local ctrlRot = pc:GetControlRotation()
    -- Raw axes from the Blueprint input component that steers the charge (see CLAUDE.md).
    local sticks = tryCall("CharacterInputComponent_Spyro axes", function()
        local ic = pc.CharacterInputComponent_Spyro
        return { ic.InputAxisLeftStickX, ic.InputAxisLeftStickY, ic.InputAxisRightStickX, ic.DeltaSeconds }
    end) or {}
    local r = {
        time = time,
        dt = statics:GetWorldDeltaSeconds(pawn),
        x = loc.X, y = loc.Y, z = loc.Z, yaw = rot.Yaw,
        vx = vel.X, vy = vel.Y, vz = vel.Z,
        inputX = input.X, inputY = input.Y,
        accelX = accel.X, accelY = accel.Y,
        mode = cmc.MovementMode,
        customMode = cmc.CustomMovementMode,
        gravityScale = cmc.GravityScale,
        simStep = cmc.MaxSimulationTimeStep,
        maxWalkSpeed = cmc.MaxWalkSpeed,
        groundFriction = cmc.GroundFriction, -- the charge turn slip fix raises this while charging
        maxAccel = cmc.MaxAcceleration,
        jumpZVelocity = cmc.JumpZVelocity,
        fallingLateralFriction = cmc.FallingLateralFriction,
        floorWalkable = floor.bWalkableFloor,
        floorDist = floor.FloorDist,
        floorNz = floor.HitResult.ImpactNormal.Z,
        rootMotion = pawn:IsPlayingRootMotion(),
        pressedJump = pawn.bPressedJump,
        jumpHoldTime = pawn.JumpKeyHoldTime,
        jumpMaxHoldTime = pawn.JumpMaxHoldTime,
        jumpForceRemaining = pawn.JumpForceTimeRemaining,
        stickX = num(sticks[1]), stickY = num(sticks[2]), stickRX = num(sticks[3]), inputDt = num(sticks[4]),
        mouseRaw = mouse.raw, -- stick_rx is the stored value, which the fix mod may replace

        camYaw = camRot and camRot.Yaw or 0 / 0,
        camPitch = camRot and camRot.Pitch or 0 / 0,
        camDist = camLoc and math.sqrt((camLoc.X - loc.X) ^ 2 + (camLoc.Y - loc.Y) ^ 2 + (camLoc.Z - loc.Z) ^ 2) or 0 / 0,
        camHeight = camLoc and camLoc.Z - loc.Z or 0 / 0,
        camFov = num(tryCall("PlayerCameraManager:GetFOVAngle", function() return camManager:GetFOVAngle() end)),
        camRadDefault = num(tryCall("FollowCamera.m_radDefault", function() return pawn.FollowCamera.m_radDefault end)),
        ctrlYaw = ctrlRot.Yaw,
        followCamYaw = num(tryCall("FollowCamera:GetCameraYaw", function() return pawn.FollowCamera:GetCameraYaw() end)),
        camTransitioning = tryCall("FollowCamera:IsTransitioning", function() return pawn.FollowCamera:IsTransitioning() end),
        -- Yaw centering FInterpTo speed; the camera centering fix raises it above 30 FPS.
        camCtrInterp = num(tryCall("FollowCamera.m_ctrInterp", function() return pawn.FollowCamera.m_ctrInterp end)),
        -- IGetIsCharging checks the Character.MoveState.Charging gameplay tag.
        chargeTag = tryCall("IGetIsCharging", function()
            local out = {}
            local ret = pawn:IGetIsCharging(out)
            if type(out.IsCharging) == "boolean" then return out.IsCharging end
            if type(ret) == "boolean" then return ret end
            error("no IsCharging result")
        end),
    }
    -- The charge dust effect the Blueprint spawned last (0 if none), and its CustomTimeDilation.
    local dust = tryCall("Charge_GroundEffects", function()
        local effect = pawn.Charge_GroundEffects
        if not effect:IsValid() then return { 0 } end
        return { effect:GetAddress(), effect.CustomTimeDilation }
    end) or {}
    r.dustAddress, r.dustDilation = dust[1], dust[2]
    if r.chargeTag ~= nil then
        r.charging = r.chargeTag
    else
        r.charging = num(r.maxWalkSpeed) >= CHARGE_WALK_SPEED
    end

    r.speed = math.sqrt(r.vx * r.vx + r.vy * r.vy)
    r.velYaw = r.speed > 1 and math.deg(math.atan(r.vy, r.vx)) or r.yaw
    r.accelYaw = math.abs(r.accelX) + math.abs(r.accelY) > 1e-3 and math.deg(math.atan(r.accelY, r.accelX)) or r.yaw
    r.camOffset = angleDiff(r.camYaw, r.yaw)
    r.camRate = (prev and r.time > prev.time) and angleDiff(r.camYaw, prev.camYaw) / (r.time - prev.time) or 0
    r.yawRate = (prev and r.time > prev.time) and angleDiff(r.yaw, prev.yaw) / (r.time - prev.time) or 0
    return r
end

return row
