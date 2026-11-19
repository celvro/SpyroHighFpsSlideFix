-- The row sampled every frame: Spyro's movement, input, camera and charge state, plus values derived
-- from the previous row. Every tracker reads its measurements from these rows, and lib/trace.lua
-- writes them to the CSV.
--
-- The groups guarded by config.ROW_* below are reflection calls on the player's camera and input
-- component that only some trackers want, so they follow those trackers' switches. A group that is
-- off leaves its fields exactly as they come out when the object isn't there (NaN for numbers, nil
-- for the rest), which is a case every reader already handles.
local config = require("config")
local mouse = require("lib.mouse")
local util = require("lib.util")

local num, angleDiff, tryCall = util.num, util.angleDiff, util.tryCall

local CHARGE_WALK_SPEED = 450 -- GE_Spyro_Movement_Charging sets MaxWalkSpeed 458.5; used if the tag query fails
local NAN = 0 / 0
-- IGetIsCharging's out-param, reused. The UE4SS build in use (v3.0.1, 2026-09-20) never releases the registry
-- reference it takes on an out-param table, so a fresh table per frame was kept alive forever; a reused one
-- still leaks the registry slot, but not a table (docs/findings/frame-rate-ceiling.md).
local chargeOut = {}

local row = {}

function row.build(pc, pawn, cmc, statics, time, prev)
    local loc = pawn:K2_GetActorLocation()
    local rot = pawn:K2_GetActorRotation()
    local vel = cmc.Velocity
    local input = cmc:GetLastInputVector()
    local accel = cmc:GetCurrentAcceleration()
    local floor = cmc.CurrentFloor
    local ctrlRot = pc:GetControlRotation()
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
        mouseRaw = mouse.raw, -- stick_rx is the stored value, which the fix mod may replace
        ctrlYaw = ctrlRot.Yaw,
        -- config.ROW_STICKS
        stickX = NAN, stickY = NAN, stickRX = NAN, inputDt = NAN,
        -- config.ROW_CAMERA
        camYaw = NAN, camPitch = NAN, camDist = NAN, camHeight = NAN, camFov = NAN,
        camRadDefault = NAN, followCamYaw = NAN, camCtrInterp = NAN, camTransitioning = nil,
        -- config.ROW_CHARGE_TAG
        chargeTag = nil,
    }

    -- Raw axes from the Blueprint input component that steers the charge (see CLAUDE.md).
    if config.ROW_STICKS then
        local sticks = tryCall("CharacterInputComponent_Spyro axes", function()
            local ic = pc.CharacterInputComponent_Spyro
            return { ic.InputAxisLeftStickX, ic.InputAxisLeftStickY, ic.InputAxisRightStickX, ic.DeltaSeconds }
        end) or {}
        r.stickX, r.stickY = num(sticks[1]), num(sticks[2])
        r.stickRX, r.inputDt = num(sticks[3]), num(sticks[4])
    end

    if config.ROW_CAMERA then
        local camManager = pc.PlayerCameraManager
        local camRot = camManager:IsValid() and camManager:GetCameraRotation() or nil
        local camLoc = camManager:IsValid() and camManager:GetCameraLocation() or nil
        if camRot then r.camYaw, r.camPitch = camRot.Yaw, camRot.Pitch end
        if camLoc then
            r.camDist = math.sqrt((camLoc.X - loc.X) ^ 2 + (camLoc.Y - loc.Y) ^ 2 + (camLoc.Z - loc.Z) ^ 2)
            r.camHeight = camLoc.Z - loc.Z
        end
        r.camFov = num(tryCall("PlayerCameraManager:GetFOVAngle", function() return camManager:GetFOVAngle() end))
        r.camRadDefault = num(tryCall("FollowCamera.m_radDefault", function() return pawn.FollowCamera.m_radDefault end))
        r.followCamYaw = num(tryCall("FollowCamera:GetCameraYaw", function() return pawn.FollowCamera:GetCameraYaw() end))
        r.camTransitioning = tryCall("FollowCamera:IsTransitioning", function() return pawn.FollowCamera:IsTransitioning() end)
        -- Yaw centering FInterpTo speed; the camera centering fix raises it above 30 FPS.
        r.camCtrInterp = num(tryCall("FollowCamera.m_ctrInterp", function() return pawn.FollowCamera.m_ctrInterp end))
    end

    -- IGetIsCharging checks the Character.MoveState.Charging gameplay tag.
    if config.ROW_CHARGE_TAG then
        r.chargeTag = tryCall("IGetIsCharging", function()
            local out = chargeOut
            out.IsCharging = nil
            local ret = pawn:IGetIsCharging(out)
            if type(out.IsCharging) == "boolean" then return out.IsCharging end
            if type(ret) == "boolean" then return ret end
            error("no IsCharging result")
        end)
    end

    -- The charge dust effect the Blueprint spawned last (0 if none), and its CustomTimeDilation.
    if config.ROW_DUST then
        local dust = tryCall("Charge_GroundEffects", function()
            local effect = pawn.Charge_GroundEffects
            if not effect:IsValid() then return { 0 } end
            return { effect:GetAddress(), effect.CustomTimeDilation }
        end) or {}
        r.dustAddress, r.dustDilation = dust[1], dust[2]
    end

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
