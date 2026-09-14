-- SpyroFpsProbe: records Spyro's movement every frame so jump, glide and sliding behaviour
-- can be compared across framerates.
--
-- Keys (game window focused):
--   F5 / F6 / F7 / F8  set t.MaxFPS to 30 / 60 / 120 / 0 (uncapped)
--
-- Output (in this mod folder, and the UE4SS console/log):
--   trace_<timestamp>.csv  one row per frame. "air" is the airborne segment id (0 on the ground),
--                          "drift" is the drift event id (0 when not drifting).
--   "seg" log lines        summary of each airborne segment (leaving the ground until landing).
--   "drift" log lines      grounded, no movement input, but horizontal speed above DRIFT_SPEED
--                          (the high-framerate sliding bug).

local UEHelpers = require("UEHelpers")

local MOVE_MODE_NAMES = { [0] = "None", "Walking", "NavWalking", "Falling", "Swimming", "Flying", "Custom" }
local DEFAULT_SIM_STEP = 0.05 -- engine default MaxSimulationTimeStep; the game never changes it
local DRIFT_SPEED = 5      -- cm/s of horizontal speed that counts as drifting
local DRIFT_MIN_FRAMES = 5 -- shorter runs are not reported

local modDir = debug.getinfo(1, "S").source:match("^@(.*)[/\\]Scripts[/\\]main%.lua$") or "."
local tracePath = string.format("%s\\trace_%s.csv", modDir, os.date("%Y%m%d_%H%M%S"))

local state = {
    fpsCap = nil,
    simStepChecked = false,
    segment = nil,
    segmentCount = 0,
    drift = nil,
    driftCount = 0,
    lastTime = nil,
    wasGrounded = true,
    prevRow = nil,
    errorLogged = false,
}

local traceFile = io.open(tracePath, "w")
if traceFile then
    traceFile:write("time,dt,fps_cap,sim_step,air,drift,x,y,z,yaw,vx,vy,vz,input_x,input_y,accel_x,accel_y,move_mode,custom_mode,gravity_scale,floor_walkable,floor_dist,floor_nz,root_motion,pressed_jump,jump_hold_time,jump_max_hold_time,jump_force_remaining\n")
end

local function log(fmt, ...)
    print(string.format("[SpyroFpsProbe] " .. fmt .. "\n", ...))
end

local function isGrounded(mode)
    return mode == 1 or mode == 2 or mode == 4
end

-- Properties missing from this build come back as non-number objects; log them as NaN.
local function num(v)
    return type(v) == "number" and v or 0 / 0
end

local function writeRow(r)
    if not traceFile then return end
    traceFile:write(string.format(
        "%.5f,%.5f,%s,%.5f,%d,%d,%.3f,%.3f,%.3f,%.2f,%.3f,%.3f,%.3f,%.3f,%.3f,%.2f,%.2f,%d,%d,%.4f,%s,%.3f,%.4f,%s,%s,%.4f,%.4f,%.4f\n",
        r.time, r.dt, tostring(state.fpsCap or ""), num(r.simStep),
        state.segment and state.segment.id or 0, state.drift and state.drift.id or 0,
        r.x, r.y, r.z, r.yaw, r.vx, r.vy, r.vz, r.inputX, r.inputY, r.accelX, r.accelY,
        r.mode, r.customMode, r.gravityScale, tostring(r.floorWalkable), r.floorDist, r.floorNz,
        tostring(r.rootMotion), tostring(r.pressedJump), num(r.jumpHoldTime), num(r.jumpMaxHoldTime), num(r.jumpForceRemaining)))
end

local function newStats(r)
    return { startTime = r.time, startX = r.x, startY = r.y, startZ = r.z, frames = 0, dtSum = 0, dtMin = math.huge, dtMax = 0 }
end

local function addFrame(s, r)
    s.frames = s.frames + 1
    s.dtSum = s.dtSum + r.dt
    s.dtMin = math.min(s.dtMin, r.dt)
    s.dtMax = math.max(s.dtMax, r.dt)
end

local function updateSegment(r, grounded)
    local s = state.segment
    if not grounded then
        if not s then
            state.segmentCount = state.segmentCount + 1
            -- Measure from the last grounded frame: the first airborne frame has already risen by
            -- one frame of jump speed, which is 7 units at 30 FPS but only 1.5 at 144.
            s = newStats(state.prevRow or r)
            s.id = state.segmentCount
            s.maxZ, s.maxVz, s.minVz, s.horiz = r.z, r.vz, r.vz, 0
            s.lastX, s.lastY, s.modes = s.startX, s.startY, {}
            state.segment = s
        end
        addFrame(s, r)
        s.maxZ = math.max(s.maxZ, r.z)
        s.maxVz = math.max(s.maxVz, r.vz)
        s.minVz = math.min(s.minVz, r.vz)
        s.horiz = s.horiz + math.sqrt((r.x - s.lastX) ^ 2 + (r.y - s.lastY) ^ 2)
        s.lastX, s.lastY = r.x, r.y
        s.modes[r.mode == 6 and ("Custom" .. r.customMode) or (MOVE_MODE_NAMES[r.mode] or tostring(r.mode))] = true
        if s.noGravEnd == nil and r.gravityScale > 0.001 then s.noGravEnd = r.time - s.startTime end
    elseif s then
        local modes = {}
        for k in pairs(s.modes) do modes[#modes + 1] = k end
        table.sort(modes)
        log("seg %d cap=%s avgFps=%.1f dt=%.1f-%.1fms simStep=%.4f air=%.3fs apex=%+.2f landDz=%+.2f horiz=%.1f vzMax=%.1f vzMin=%.1f noGravFor=%s modes=%s",
            s.id, tostring(state.fpsCap or "?"), s.frames / s.dtSum, s.dtMin * 1000, s.dtMax * 1000,
            num(r.simStep), r.time - s.startTime, s.maxZ - s.startZ, r.z - s.startZ, s.horiz,
            s.maxVz, s.minVz, s.noGravEnd and string.format("%.3fs", s.noGravEnd) or "n/a", table.concat(modes, "+"))
        state.segment = nil
        if traceFile then traceFile:flush() end
    end
end

local function updateDrift(r, grounded)
    local speed = math.sqrt(r.vx * r.vx + r.vy * r.vy)
    local noInput = math.abs(r.inputX) + math.abs(r.inputY) < 0.01
    local d = state.drift
    if grounded and noInput and speed > DRIFT_SPEED then
        if not d then
            state.driftCount = state.driftCount + 1
            d = newStats(r)
            d.id, d.maxSpeed, d.pathLen, d.lastX, d.lastY, d.floorNz, d.rootMotionFrames = state.driftCount, 0, 0, r.x, r.y, r.floorNz, 0
            state.drift = d
        end
        addFrame(d, r)
        d.maxSpeed = math.max(d.maxSpeed, speed)
        d.pathLen = d.pathLen + math.sqrt((r.x - d.lastX) ^ 2 + (r.y - d.lastY) ^ 2)
        d.lastX, d.lastY = r.x, r.y
        if r.rootMotion then d.rootMotionFrames = d.rootMotionFrames + 1 end
    elseif d then
        if d.frames >= DRIFT_MIN_FRAMES then
            log("drift %d cap=%s avgFps=%.1f dt=%.1f-%.1fms dur=%.3fs net=%.1f path=%.1f maxSpeed=%.1f floorNz=%.3f rootMotionFrames=%d/%d mode=%d",
                d.id, tostring(state.fpsCap or "?"), d.frames / d.dtSum, d.dtMin * 1000, d.dtMax * 1000, r.time - d.startTime,
                math.sqrt((r.x - d.startX) ^ 2 + (r.y - d.startY) ^ 2), d.pathLen, d.maxSpeed, d.floorNz,
                d.rootMotionFrames, d.frames, r.mode)
            if traceFile then traceFile:flush() end
        end
        state.drift = nil
    end
end

local function sample()
    local pc = UEHelpers.GetPlayerController()
    if not pc:IsValid() then return end
    local pawn = pc.Pawn
    if not pawn:IsValid() then return end
    local cmc = pawn.CharacterMovement
    if not cmc:IsValid() then return end

    local statics = UEHelpers.GetGameplayStatics()
    local time = statics:GetTimeSeconds(pawn)
    if state.lastTime == time then return end -- paused or same frame
    state.lastTime = time

    local loc = pawn:K2_GetActorLocation()
    local rot = pawn:K2_GetActorRotation()
    local vel = cmc.Velocity
    local input = cmc:GetLastInputVector()
    local accel = cmc:GetCurrentAcceleration()
    local floor = cmc.CurrentFloor
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
        floorWalkable = floor.bWalkableFloor,
        floorDist = floor.FloorDist,
        floorNz = floor.HitResult.ImpactNormal.Z,
        rootMotion = pawn:IsPlayingRootMotion(),
        pressedJump = pawn.bPressedJump,
        jumpHoldTime = pawn.JumpKeyHoldTime,
        jumpMaxHoldTime = pawn.JumpMaxHoldTime,
        jumpForceRemaining = pawn.JumpForceTimeRemaining,
    }

    -- Older probe builds could shrink the substep for experiments; substeps smaller than a frame
    -- reproduce the high-FPS quantization bugs at any framerate, so always restore the default.
    if not state.simStepChecked then
        state.simStepChecked = true
        if math.abs(r.simStep - DEFAULT_SIM_STEP) > 1e-6 then
            cmc.MaxSimulationTimeStep = DEFAULT_SIM_STEP
            log("MaxSimulationTimeStep was %.4f; restored engine default %.2f", r.simStep, DEFAULT_SIM_STEP)
        end
    end

    local grounded = isGrounded(r.mode)
    updateDrift(r, grounded)
    updateSegment(r, grounded)
    writeRow(r)
    state.wasGrounded = grounded
    state.prevRow = r
end


local function setFpsCap(cap)
    ExecuteInGameThread(function()
        local pc = UEHelpers.GetPlayerController()
        if not pc:IsValid() then return end
        UEHelpers.GetKismetSystemLibrary():ExecuteConsoleCommand(pc, "t.MaxFPS " .. cap, pc)
        state.fpsCap = cap
        log("t.MaxFPS %d", cap)
    end)
end

RegisterKeyBind(Key.F5, function() setFpsCap(30) end)
RegisterKeyBind(Key.F6, function() setFpsCap(60) end)
RegisterKeyBind(Key.F7, function() setFpsCap(120) end)
RegisterKeyBind(Key.F8, function() setFpsCap(0) end)

if not EngineTickAvailable then
    log("EngineTick hook unavailable; per-frame sampling disabled")
    return
end

LoopInGameThreadAfterFrames(1, function()
    local ok, err = pcall(sample)
    if not ok and not state.errorLogged then
        state.errorLogged = true
        log("sample error: %s", tostring(err))
    end
end)

log("loaded; writing %s", tracePath)
