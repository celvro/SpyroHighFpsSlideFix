-- Charges and the full-lock turns inside them.
--
--   "charge" lines  each charge (while Spyro has the Character.MoveState.Charging tag). t400 is the time
--                   from the last untagged frame to 400 speed (charges that start below 150). mouseDist is
--                   the raw mouse X movement and yawPerMouse the yaw (while not keyboard/stick steering)
--                   per unit of it. dustSpawns counts new Charge_GroundEffects dust effects and dustRate is
--                   per grounded second (the Blueprint respawns it every frame). dustEmitRate only counts
--                   effects with CustomTimeDilation >= 0.5 (all of them unfixed; every 1/30 s with the dust
--                   fix, which nearly stops the rest), and dustDilationMax is the highest.
--   "turn" lines    a grounded full-lock charge turn (|left stick x| >= STEER_FULL for at least TURN_MIN):
--                   yaw rate of Spyro, his velocity and the camera, turn radius, and how far the camera
--                   trails him. Averages skip the first TURN_WARMUP. Signed angles are positive into the
--                   turn (camLag: camera behind Spyro). During a super charge they add the stage and the
--                   slip/camera lag predicted at 30 FPS and at this framerate.
-- The camera measurements taken during a charge are in trackers/camera.lua.
local camera = require("trackers.camera")
local log = require("lib.log")
local state = require("lib.state")
local trace = require("lib.trace")
local util = require("lib.util")

local num, angleDiff, sign, isGrounded = util.num, util.angleDiff, util.sign, util.isGrounded
local newStats, addFrame, avgFps = util.newStats, util.addFrame, util.avgFps

local STEER_FULL = 0.9        -- |left stick x| at or above this is a full-lock charge turn
local TURN_WARMUP = 0.25      -- seconds at the start of a turn left out of its averages
local TURN_MIN = 0.5          -- shorter turns are not reported
local CHARGE_T400_MAX_START_SPEED = 150
-- Base GroundFriction by MaxAcceleration (the fix mod may raise the live value): super charge stages 0-3,
-- super charge Alt, normal charge.
local BASE_FRICTION_BY_ACCEL = { [150] = 25, [500] = 12, [1000] = 8 }

local charge = {}

-- Degrees velocity trails a facing turning at yawRate: per frame CalcVelocity keeps (1 - friction * dt)
-- of the angle, and MaxAcceleration along the facing keeps 1 / (1 + accel * dt / speed) of the rest.
local function slipModel(yawRate, friction, accel, speed, dt)
    if not (speed > 0 and dt > 0) then return 0 / 0 end
    local keep = (1 - math.min(friction * dt, 1)) / (1 + accel * dt / speed)
    return yawRate * dt * keep / (1 - keep)
end

-- Degrees the camera trails a steady turn with FInterpTo centering at ctrInterp (ignores the 180 deg/s cap).
local function camLagModel(yawRate, ctrInterp, dt)
    local f = math.min(ctrInterp * dt, 1)
    return f > 0 and yawRate * dt * (1 - f) / f or 0 / 0
end

local function finishTurn()
    local t = state.turn
    state.turn = nil
    if not t or t.lastTime - t.startTime < TURN_MIN or t.avgTime <= 0 then return end
    local dir = sign(t.yaw) -- +1 turning towards increasing yaw
    local velYawRate = math.abs(t.velYaw) / t.avgTime
    local speed = t.speed / t.avgTime
    local yawRate = math.abs(t.yaw) / t.avgTime
    local friction, accel, dt = t.friction / t.avgTime, t.maxAccel / t.avgTime, t.dtSum / t.frames
    local baseFriction = BASE_FRICTION_BY_ACCEL[math.floor(accel + 0.5)] or friction
    log("turn %s cap=%s avgFps=%.1f dur=%.3fs stick=%.2f yawRate=%.1f velYawRate=%.1f camYawRate=%.1f radius=%.1f speed=%.1f accelAngle=%+.2f slip=%+.2f groundFriction=%.2f camLag=%+.1f camLagMax=%.1f camLagEnd=%+.1f ctrInterp=%.3f super=%s maxAccel=%.0f slipModel30=%.2f slipModelHere=%.2f camLagModelHere=%.1f",
        t.id, tostring(state.fpsCap or "?"), avgFps(t), t.lastTime - t.startTime, t.stick / t.avgTime,
        yawRate, velYawRate, dir * t.camYaw / t.avgTime,
        velYawRate > 0 and speed / math.rad(velYawRate) or math.huge, speed,
        dir * t.accelAngle / t.avgTime, dir * t.slip / t.avgTime, friction,
        -dir * t.camLag / t.avgTime, t.camLagMax, -dir * t.camLagEnd, t.ctrInterp,
        tostring(t.super), accel, slipModel(yawRate, baseFriction, accel, speed, 1 / 30),
        slipModel(yawRate, friction, accel, speed, dt), camLagModel(yawRate, t.ctrInterp, dt))
end

-- A grounded run of full-lock steering while charging.
local function updateTurn(r, prev)
    local t = state.turn
    if not (isGrounded(r.mode) and math.abs(r.stickX) >= STEER_FULL) then
        if t then finishTurn() end
        return
    end
    if not t then
        local c = state.charge
        c.turnCount = c.turnCount + 1
        t = newStats(r)
        t.id = string.format("%d.%d", c.id, c.turnCount)
        t.lastTime, t.camLagEnd = r.time, r.camOffset
        t.avgTime, t.yaw, t.velYaw, t.camYaw, t.speed, t.stick, t.accelAngle, t.slip, t.camLag, t.camLagMax = 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        t.friction, t.maxAccel, t.super = 0, 0, r.superStage
        state.turn = t
        return
    end
    t.lastTime, t.camLagEnd, t.ctrInterp = r.time, r.camOffset, r.camCtrInterp
    if r.time - t.startTime <= TURN_WARMUP then return end
    local step = r.time - prev.time
    if step <= 0 then return end
    addFrame(t, r) -- only averaged frames, so avgFps and the models' dt match the averages
    t.avgTime = t.avgTime + step
    t.maxAccel = t.maxAccel + num(r.maxAccel) * step
    if r.superStage and not t.super then t.super = r.superStage end
    t.yaw = t.yaw + angleDiff(r.yaw, prev.yaw)
    t.velYaw = t.velYaw + angleDiff(r.velYaw, prev.velYaw)
    t.camYaw = t.camYaw + angleDiff(r.camYaw, prev.camYaw)
    t.speed = t.speed + r.speed * step
    t.stick = t.stick + math.abs(r.stickX) * step
    t.accelAngle = t.accelAngle + angleDiff(r.accelYaw, r.yaw) * step
    t.slip = t.slip + angleDiff(r.yaw, r.velYaw) * step
    -- May be read before or after the fix mod's write this frame; it's steady during a held turn.
    t.friction = t.friction + num(r.groundFriction) * step
    t.camLag = t.camLag + r.camOffset * step
    t.camLagMax = math.max(t.camLagMax, math.abs(r.camOffset))
end

-- One charge, from the first frame with the Charging tag until it clears.
function charge.update(r, prev)
    local c = state.charge
    if not r.charging then
        if not c then return end
        finishTurn()
        camera.finishLock("chargeEnd")
        log("charge %d cap=%s avgFps=%.1f dt=%.1f-%.1fms dur=%.3fs startSpeed=%.1f t400=%s speedAvg=%.1f speedMax=%.1f yawChange=%+.1f camOffset0=%+.1f turns=%d mouseDist=%.2f yawPerMouse=%s dustSpawns=%d dustRate=%.1f/s dustEmitRate=%.1f/s dustDilationMax=%.2f detectedBy=%s",
            c.id, tostring(state.fpsCap or "?"), avgFps(c), c.dtMin * 1000, c.dtMax * 1000, r.time - c.startTime,
            c.startSpeed, c.t400 and string.format("%.3fs", c.t400) or "n/a",
            c.dtSum > 0 and c.speedSum / c.dtSum or 0 / 0, c.maxSpeed, c.yaw, c.camOffset0, c.turnCount,
            c.mouseDist, c.mouseDist > 0 and string.format("%.2f", c.mouseYaw / c.mouseDist) or "n/a",
            c.dustSpawns, c.dustGroundTime > 0 and c.dustSpawns / c.dustGroundTime or 0 / 0,
            c.dustGroundTime > 0 and c.dustEmitting / c.dustGroundTime or 0 / 0, c.dustDilationMax,
            r.chargeTag == nil and "maxWalkSpeed" or "tag")
        state.charge = nil
        trace.flush()
        return
    end
    if not c then
        state.chargeCount = state.chargeCount + 1
        c = newStats(r)
        c.id, c.camOffset0, c.needsLock = state.chargeCount, r.camOffset, true
        c.speedSum, c.maxSpeed, c.yaw, c.turnCount, c.lockCount = 0, 0, 0, 0, 0
        c.mouseDist, c.mouseYaw = 0, 0
        c.dustSpawns, c.dustEmitting, c.dustGroundTime, c.dustDilationMax, c.lastDust = 0, 0, 0, 0, r.dustAddress
        -- Speed-up timing starts at the last frame before the tag: this frame already accelerated.
        local start = prev or r
        c.startSpeed, c.speedUpFrom = start.speed, start.time
        state.charge = c
    elseif prev then
        addFrame(c, r)
        c.speedSum = c.speedSum + r.speed * r.dt
        c.maxSpeed = math.max(c.maxSpeed, r.speed)
        local yawStep = angleDiff(r.yaw, prev.yaw)
        c.yaw = c.yaw + yawStep
        if r.mouseRaw == r.mouseRaw then c.mouseDist = c.mouseDist + math.abs(r.mouseRaw) end -- skips NaN
        if not (math.abs(r.stickX) >= 0.05) then c.mouseYaw = c.mouseYaw + math.abs(yawStep) end
        if r.mode == 1 then c.dustGroundTime = c.dustGroundTime + r.dt end
        if r.dustAddress and r.dustAddress ~= 0 and r.dustAddress ~= c.lastDust then
            c.dustSpawns = c.dustSpawns + 1
            if num(r.dustDilation) >= 0.5 then c.dustEmitting = c.dustEmitting + 1 end
            c.dustDilationMax = math.max(c.dustDilationMax, num(r.dustDilation))
        end
        c.lastDust = r.dustAddress
    end
    if prev and not c.t400 and c.startSpeed < CHARGE_T400_MAX_START_SPEED and r.speed >= 400 then
        local f = r.speed > prev.speed and (400 - prev.speed) / (r.speed - prev.speed) or 1
        c.t400 = prev.time + (r.time - prev.time) * math.min(math.max(f, 0), 1) - c.speedUpFrom
    end
    updateTurn(r, prev)
    camera.updateLock(r)
    camera.updateStuck(r)
end

return charge
