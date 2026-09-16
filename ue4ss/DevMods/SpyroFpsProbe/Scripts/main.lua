-- SpyroFpsProbe: records Spyro's movement every frame so jump, glide, sliding and charge
-- behaviour can be compared across framerates.
--
-- Keys (game window focused):
--   F5 / F6 / F7 / F8  set t.MaxFPS to 30 / 60 / 120 / 0 (uncapped)
--   F9                 dump Spyro's FollowCameraComponent properties to camdump_*_manual.txt
--
-- Output (in this mod folder, and the UE4SS console/log):
--   trace_<timestamp>.csv  one row per frame. "air" is the airborne segment id (0 on the ground),
--                          "drift" is the drift event id (0 when not drifting), "charge", "turn" and
--                          "camlock" are the ids of the charge measurements below (0 outside them).
--   "seg" log lines        summary of each airborne segment (leaving the ground until landing).
--   "drift" log lines      grounded, no movement input, but horizontal speed above DRIFT_SPEED
--                          (the high-framerate sliding bug).
--   "rise" log lines       every zero-gravity rise (the phase the jump height fix changes), with
--                          what it launched from: ground, water, glide-hover (a hover at the end of
--                          a glide) or air. apex is measured from the launch frame.
--   "charge" log lines     summary of each charge (while Spyro has the Character.MoveState.Charging tag).
--                          t400 is the time from the last untagged frame to 400 speed (charges that
--                          start below 150). mouseDist is the raw mouse X movement and yawPerMouse
--                          the yaw (while not keyboard/stick steering) per unit of it. dustSpawns counts
--                          new Charge_GroundEffects dust effects and dustRate is per grounded second
--                          (the Blueprint respawns it every frame). dustEmitRate only counts effects
--                          with CustomTimeDilation >= 0.5 (all of them unfixed; every 1/30 s with the
--                          dust fix, which nearly stops the rest), and dustDilationMax is the highest.
--   "turn" log lines       a grounded full-lock charge turn (|left stick x| >= STEER_FULL for at least
--                          TURN_MIN): yaw rate of Spyro, his velocity and the camera, turn radius, and
--                          how far the camera trails him. Averages skip the first TURN_WARMUP.
--                          Signed angles are positive into the turn (camLag: camera behind Spyro).
--   "camlock" log lines    how fast the camera swings in behind Spyro after a charge starts or a turn
--                          is released: t50/t90 are the times to close 50%/90% of the starting yaw
--                          offset (interpolated between frames), k50/k90 the matching exponential
--                          interp speeds (ln 2 / t50, ln 10 / t90). Only offsets >= CAM_MIN_OFFSET.
--                          Timing starts at the first frame with the tag, so up to one frame late.
--   "camtransition" lines  each camera settings transition (FollowCamera:IsTransitioning() true): its
--                          duration and m_ctrInterp at the start, after CAMTRANSITION_SAMPLES seconds
--                          and at the end, to see how the game blends it (the camera fix skips these).
--   "supercharge" lines    each super charge (Character.MoveState.SuperCharging tag): stage change
--                          times, speed thresholds (t<speed>) next to the ideal MaxAcceleration-per-second
--                          ramp, air time, then one "supercharge N stage S" line per stage with speed,
--                          friction, acceleration and camera averages (distance, height, pitch, FOV,
--                          yaw offset, m_ctrInterp, m_radDefault). Airborne "seg" lines that start
--                          during a super charge add the stage, takeoff speed, jump attributes and a
--                          gravity scale profile; "turn" lines add the stage and the slip/camera lag
--                          predicted at 30 FPS and at this framerate.
--   camdump_*.txt          every reflected property of Spyro's FollowCameraComponent (to find where
--                          the active camera settings live). Dumped once while idle, once mid-charge
--                          after the camera transition, and whenever F9 is pressed. After the charge
--                          dump, "camdump diff" log lines list what changed from idle.

local UEHelpers = require("UEHelpers")

local MOVE_MODE_NAMES = { [0] = "None", "Walking", "NavWalking", "Falling", "Swimming", "Flying", "Custom" }
local DEFAULT_SIM_STEP = 0.05 -- engine default MaxSimulationTimeStep; the game never changes it
local DRIFT_SPEED = 5      -- cm/s of horizontal speed that counts as drifting
local DRIFT_MIN_FRAMES = 5 -- shorter runs are not reported

local CHARGE_WALK_SPEED = 450 -- GE_Spyro_Movement_Charging sets MaxWalkSpeed 458.5; used if the tag query fails
local STEER_FULL = 0.9        -- |left stick x| at or above this is a full-lock charge turn
local STEER_ANY = 0.3         -- |left stick x| above this counts as steering (ends a camlock)
local TURN_WARMUP = 0.25      -- seconds at the start of a turn left out of its averages
local TURN_MIN = 0.5          -- shorter turns are not reported
local CAM_MIN_OFFSET = 10     -- degrees; smaller camera offsets don't start a camlock
local CHARGE_T400_MAX_START_SPEED = 150
local CAMTRANSITION_SAMPLES = { 0.05, 0.1, 0.25, 0.5, 1.0, 1.5, 2.0 }
local MOUSE_AXIS_FUNCTION = "/CharacterCommon/Components/CharacterInputComponent/CharacterInputComponent_Spyro.CharacterInputComponent_Spyro_C:InputAxis_RightStick_X"
local HOOK_RETRY_FRAMES = 60
local DRAGON_CLASS = "BP_CBS3012_FireDragon_C" -- Fireworks Factory's segmented fire dragons
local DRAGON_REPORT_INTERVAL = 1.0 -- seconds of game time per dragon line
local DRAGON_MIN_SPEED = 100       -- slower head frames are left out of the lag average

local CAMSTUCK_MIN_OFFSET = 45    -- degrees the camera must trail Spyro to count as stuck
local CAMSTUCK_GROWTH = 5         -- degrees the gap must grow over CAMSTUCK_WINDOW
local CAMSTUCK_WINDOW = 1.0       -- seconds
local CAMSTUCK_MAX_RATE = 170     -- deg/s; at the 180 deg/s centering cap the camera is working, just outpaced
local CAMSTUCK_NOLOCK_OFFSET = 20 -- degrees off Spyro's back, without steering, that should close
local CAMSTUCK_NOLOCK_KEEP = 0.7  -- "noLock" if more than this fraction of the gap is left after CAMSTUCK_WINDOW
local CAMSTUCK_NOLOCK_MAX_YAW_RATE = 30 -- deg/s; Spyro turning faster than this counts as steering
local CAMSTUCK_MAX_DUMPS = 3      -- "stuck" camdumps per session

local SUPERCHARGE_TAG = "Character.MoveState.SuperCharging"
local SUPERCHARGE_STAGE_TAGS = { -- GA_Spyro_Charge's SuperChargeLevel for each stage effect's tag
    { 3, "Character.MoveState.SuperCharging.StageThree" },
    { 2, "Character.MoveState.SuperCharging.StageTwo" },
    { 1, "Character.MoveState.SuperCharging.StageOne" },
    { -1, "Character.MoveState.SuperCharging.StageAlt" },
}
-- t<speed> thresholds, just under the stage 0-2 (750) and stage 3 (1025) MaxWalkSpeed so rounding still reaches them.
local SUPERCHARGE_SPEEDS = { 550, 650, 745, 850, 950, 1020 }
local SUPERCHARGE_BASE_WALK_SPEED = 750   -- GE_Spyro_Movement_SuperCharging_S0-S2 (Alt: 850)
local SUPERCHARGE_STAGE3_WALK_SPEED = 1025 -- GE_Spyro_Movement_SuperCharging_S3
local GRAVITY_PROFILE_MAX = 8 -- gravity scale runs listed per airborne segment
-- Base GroundFriction by MaxAcceleration (the fix mod may raise the live value): super charge stages 0-3,
-- super charge Alt, normal charge.
local BASE_FRICTION_BY_ACCEL = { [150] = 25, [500] = 12, [1000] = 8 }

local CAMDUMP_CHARGE_DELAY = 0.75 -- seconds into a charge before its camera dump (and not transitioning)
local CAMDUMP_MAX_DEPTH = 4       -- struct/array nesting levels to expand
local CAMDUMP_MAX_ELEMENTS = 16   -- array elements to expand
local CAMDUMP_MAX_DIFF_LINES = 80
local CAMDUMP_STOP_CLASSES = { SceneComponent = true, ActorComponent = true, Object = true }
local CAMDUMP_SKIP_TYPES = {
    DelegateProperty = true, MulticastDelegateProperty = true, MulticastInlineDelegateProperty = true,
    MulticastSparseDelegateProperty = true, MapProperty = true, SetProperty = true, InterfaceProperty = true,
    WeakObjectProperty = true, LazyObjectProperty = true, SoftObjectProperty = true, SoftClassProperty = true,
}

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
    recent = {},   -- last RECENT_FRAMES rows, oldest first
    rise = nil,
    riseCount = 0,
    charge = nil,
    chargeCount = 0,
    turn = nil,
    camLock = nil,
    camDump = { idle = nil, charge = nil, requested = false, stuckRequested = false, stuckCount = 0 }, -- dumps are lists of { path, value }
    camTransition = nil,
    camTransitionCount = 0,
    mouseHook = { registered = false, failed = false, retryIn = 0, raw = 0 / 0 }, -- raw: last InputAxis_RightStick_X argument
    dragon = { heads = {}, findIn = 0, stats = {} }, -- stats: head address -> accumulated dragon line values
    superCharge = nil,
    superChargeCount = 0,
    asc = nil, -- { pawn = address, component = AbilitySystemComponent }
    optional = {}, -- per optional call: true once it has worked, false if its first call failed
    errorLogged = false,
}

local RECENT_FRAMES = 10
local GLIDE_SINK_SPEED = -50 -- average vz below this while Flying means gliding, not swimming

local traceFile = io.open(tracePath, "w")
if traceFile then
    traceFile:write("time,dt,fps_cap,sim_step,air,drift,x,y,z,yaw,vx,vy,vz,input_x,input_y,accel_x,accel_y,move_mode,custom_mode,gravity_scale,floor_walkable,floor_dist,floor_nz,root_motion,pressed_jump,jump_hold_time,jump_max_hold_time,jump_force_remaining,"
        .. "charge,turn,camlock,charging,charge_tag,max_walk_speed,stick_x,stick_y,stick_rx,input_dt,vel_yaw,cam_yaw,cam_pitch,cam_offset,cam_rate,ctrl_yaw,follow_cam_yaw,cam_transitioning,ground_friction,mouse_raw,cam_ctr_interp,"
        .. "sc,sc_stage,max_accel,jump_z_velocity,falling_lateral_friction,cam_dist,cam_height,cam_fov,cam_rad_default\n")
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

local function csvValue(v)
    return v == nil and "" or tostring(v)
end

-- a - b in degrees, wrapped to [-180, 180).
local function angleDiff(a, b)
    return (a - b + 180) % 360 - 180
end

local function sign(v)
    return v < 0 and -1 or 1
end

-- Calls a game function that may not exist or may not work from Lua. Returns nil on failure; the
-- first failure is logged, and a call that has never worked is not tried again.
local function tryCall(name, fn)
    local known = state.optional[name]
    if known == false then return nil end
    local ok, value = pcall(fn)
    if ok then
        state.optional[name] = true
        return value
    end
    if known == nil then
        state.optional[name] = false
        log("%s unavailable: %s", name, tostring(value))
    end
    return nil
end

local function writeRow(r)
    if not traceFile then return end
    traceFile:write(string.format(
        "%.5f,%.5f,%s,%.5f,%d,%d,%.3f,%.3f,%.3f,%.2f,%.3f,%.3f,%.3f,%.3f,%.3f,%.2f,%.2f,%d,%d,%.4f,%s,%.3f,%.4f,%s,%s,%.4f,%.4f,%.4f,",
        r.time, r.dt, tostring(state.fpsCap or ""), num(r.simStep),
        state.segment and state.segment.id or 0, state.drift and state.drift.id or 0,
        r.x, r.y, r.z, r.yaw, r.vx, r.vy, r.vz, r.inputX, r.inputY, r.accelX, r.accelY,
        r.mode, r.customMode, r.gravityScale, tostring(r.floorWalkable), r.floorDist, r.floorNz,
        tostring(r.rootMotion), tostring(r.pressedJump), num(r.jumpHoldTime), num(r.jumpMaxHoldTime), num(r.jumpForceRemaining)))
    traceFile:write(string.format(
        "%s,%s,%s,%s,%s,%.1f,%.3f,%.3f,%.3f,%.5f,%.2f,%.3f,%.3f,%.3f,%.1f,%.3f,%.3f,%s,%.4f,%.4f,%.4f,",
        csvValue(state.charge and state.charge.id or 0), csvValue(state.turn and state.turn.id or 0),
        csvValue(state.camLock and state.camLock.id or 0), tostring(r.charging), csvValue(r.chargeTag),
        num(r.maxWalkSpeed), r.stickX, r.stickY, r.stickRX, r.inputDt, r.velYaw, r.camYaw, r.camPitch,
        r.camOffset, r.camRate, r.ctrlYaw, r.followCamYaw, csvValue(r.camTransitioning), num(r.groundFriction),
        r.mouseRaw, r.camCtrInterp))
    traceFile:write(string.format("%d,%s,%.1f,%.1f,%.2f,%.2f,%.2f,%.3f,%.1f\n",
        state.superCharge and state.superCharge.id or 0, csvValue(r.superStage), num(r.maxAccel),
        num(r.jumpZVelocity), num(r.fallingLateralFriction), r.camDist, r.camHeight, r.camFov, r.camRadDefault))
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

local function avgFps(s)
    return s.dtSum > 0 and s.frames / s.dtSum or 0 / 0
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
            local takeoff = state.prevRow or r
            s.super = takeoff.superStage or r.superStage
            if s.super then
                s.hspeed0, s.vz0, s.gravity = takeoff.speed or r.speed, r.vz, {}
                s.jumpZ, s.lateralFriction, s.holdTime = num(r.jumpZVelocity), num(r.fallingLateralFriction), num(r.jumpMaxHoldTime)
            end
            state.segment = s
        end
        addFrame(s, r)
        if s.super then
            -- Runs of equal gravity scale: the no-gravity jump phase, ramp assist and ramp fail effects.
            local g, last = s.gravity, s.gravity[#s.gravity]
            if last and math.abs(last.scale - r.gravityScale) < 1e-4 then
                last.time = last.time + r.dt
            elseif #g < GRAVITY_PROFILE_MAX then
                g[#g + 1] = { scale = r.gravityScale, time = r.dt }
            end
        end
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
        if s.super then
            local profile = {}
            for _, run in ipairs(s.gravity) do profile[#profile + 1] = string.format("%.2fx%.3fs", run.scale, run.time) end
            log("seg %d supercharge stage=%d hspeed0=%.1f vz0=%.1f jumpZVelocity=%.0f jumpMaxHoldTime=%.3f fallingLateralFriction=%.1f landSpeed=%.1f gravity=%s",
                s.id, s.super, s.hspeed0, s.vz0, s.jumpZ, s.holdTime, s.lateralFriction, r.speed, table.concat(profile, " "))
        end
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

-- Surface swimming and gliding both use MovementMode Flying; a glide sinks steadily, a swim is level.
local function launchKind(prev)
    if prev.mode == 1 or prev.mode == 2 then return "ground" end
    if prev.mode == 3 then return "air" end
    if prev.mode == 5 then
        local sum, n = 0, 0
        for _, row in ipairs(state.recent) do
            if row.mode == 5 then sum, n = sum + row.vz, n + 1 end
        end
        return (n > 0 and sum / n < GLIDE_SINK_SPEED) and "glide-hover" or "water"
    end
    return MOVE_MODE_NAMES[prev.mode] or tostring(prev.mode)
end

local function isZeroGravityRise(row)
    return row.mode == 3 and row.gravityScale == 0 and row.vz > 0
end

-- Tracks a zero-gravity rise from its launch frame until Spyro starts falling or changes mode.
local function updateRise(r)
    local rise = state.rise
    if not rise then
        local prev = state.prevRow
        if not (prev and isZeroGravityRise(r) and not isZeroGravityRise(prev)) then return end
        state.riseCount = state.riseCount + 1
        rise = {
            id = state.riseCount, kind = launchKind(prev), launchTime = prev.time, launchZ = prev.z,
            vz0 = r.vz, hspeed0 = math.sqrt(r.vx * r.vx + r.vy * r.vy), apexZ = r.z,
            fullSpeed = 0, fullSpeedDone = false, gravityOff = 0, frames = 0, dtSum = 0,
            holdTime = num(r.jumpMaxHoldTime),
        }
        state.rise = rise
    end

    rise.frames = rise.frames + 1
    rise.dtSum = rise.dtSum + r.dt
    rise.apexZ = math.max(rise.apexZ, r.z)
    -- Time at launch speed: the frames that moved with gravity off (ends when the speed first changes).
    if not rise.fullSpeedDone and math.abs(r.vz - rise.vz0) <= 0.05 then
        rise.fullSpeed = rise.fullSpeed + r.dt
    else
        rise.fullSpeedDone = true
    end
    if r.gravityScale == 0 then rise.gravityOff = rise.gravityOff + r.dt end

    if r.mode ~= 3 or r.vz <= 0 then
        log("rise %d kind=%s cap=%s avgFps=%.1f vz0=%.1f hspeed0=%.1f atLaunchSpeedFor=%.4fs gravityOffFor=%.4fs apex=%+.2f jumpMaxHoldTime=%.3f endMode=%s",
            rise.id, rise.kind, tostring(state.fpsCap or "?"), rise.frames / rise.dtSum, rise.vz0, rise.hspeed0,
            rise.fullSpeed, rise.gravityOff, rise.apexZ - rise.launchZ, rise.holdTime,
            MOVE_MODE_NAMES[r.mode] or tostring(r.mode))
        state.rise = nil
    end
end

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

local function finishCamLock(endedBy)
    local l = state.camLock
    state.camLock = nil
    if not l then return end
    local function seconds(t) return t and string.format("%.3fs", t) or "n/a" end
    local function speed(logRatio, t) return t and t > 0 and string.format("%.2f", logRatio / t) or "n/a" end
    log("camlock %s cause=%s cap=%s avgFps=%.1f offset0=%.1f t50=%s t90=%s k50=%s k90=%s camRateMax=%.0f ctrInterp=%.3f endedBy=%s",
        l.id, l.cause, tostring(state.fpsCap or "?"), avgFps(l), l.offset0, seconds(l.t50), seconds(l.t90),
        speed(math.log(2), l.t50), speed(math.log(10), l.t90), l.camRateMax, l.ctrInterp, endedBy)
end

-- Seconds from the camlock start until the offset first fell to fraction * offset0, interpolated
-- between the previous frame and this one. nil while it is still above.
local function crossingTime(l, r, offset, fraction)
    local threshold = l.offset0 * fraction
    if not (offset <= threshold) then return nil end
    local f = l.lastOffset > offset and (l.lastOffset - threshold) / (l.lastOffset - offset) or 1
    return l.lastTime + (r.time - l.lastTime) * math.min(math.max(f, 0), 1) - l.startTime
end

-- The camera swinging in behind Spyro while he isn't steering.
local function updateCamLock(r)
    local c = state.charge
    local l = state.camLock
    if math.abs(r.stickX) > STEER_ANY then
        c.needsLock = true
        if l then finishCamLock("steer") end
        return
    end
    if not l then
        if not c.needsLock then return end
        c.needsLock = false
        local offset = math.abs(r.camOffset)
        if not (offset >= CAM_MIN_OFFSET) then return end
        c.lockCount = c.lockCount + 1
        l = newStats(r)
        l.id = string.format("%d.%d", c.id, c.lockCount)
        l.cause = r.time == c.startTime and "start" or "turn"
        l.offset0, l.lastOffset, l.lastTime, l.camRateMax = offset, offset, r.time, 0
        l.ctrInterp = r.camCtrInterp
        state.camLock = l
        return
    end
    addFrame(l, r)
    l.camRateMax = math.max(l.camRateMax, math.abs(r.camRate))
    local offset = math.abs(r.camOffset)
    l.t50 = l.t50 or crossingTime(l, r, offset, 0.5)
    l.t90 = l.t90 or crossingTime(l, r, offset, 0.1)
    l.lastOffset, l.lastTime = offset, r.time
    if l.t90 then finishCamLock("settled") end
end

-- A charge where the camera stops catching up. Seen twice charging up slopes at 144 FPS; once traced:
-- the camera turned at a constant 123.6 deg/s behind a Spyro turning at 130.8 for the rest of the
-- charge. Two detectors (see below): "growing" and "noLock". Detection logs a "camstuck" line and
-- requests a "stuck" camdump (diffed against the normal charge dump); the episode's end logs its duration.
local function updateCamStuck(r)
    local c = state.charge
    local offset = math.abs(r.camOffset)
    local s = c.stuck
    if s and s.active then
        s.offsetMax = math.max(s.offsetMax, offset)
        if offset < s.endBelow then
            log("camstuck %d.%d ended after %.2fs: offset %.1f (max %.1f) camRate=%.1f", c.id, s.count, r.time - s.since, offset, s.offsetMax, r.camRate)
            s.active = false
        end
        return
    end
    s = s or { count = 0 }
    c.stuck = s

    local function detect(kind, refTime, refOffset, endBelow)
        s.count, s.active, s.since, s.offsetMax, s.endBelow = s.count + 1, true, r.time, offset, endBelow
        log("camstuck %d.%d kind=%s cap=%s dt=%.2fms t=%.2fs into charge: offset %.1f -> %.1f in %.2fs camRate=%.1f spyroYawRate=%.1f ctrInterp=%.3f transitioning=%s pos=(%.0f, %.0f, %.1f) floorNz=%.4f stick=(%.2f, %.2f) mouse=%.3f",
            c.id, s.count, kind, tostring(state.fpsCap or "?"), r.dt * 1000, r.time - c.startTime, refOffset, offset, r.time - refTime,
            r.camRate, r.yawRate, r.camCtrInterp, tostring(r.camTransitioning), r.x, r.y, r.z, r.floorNz,
            r.stickX, r.stickY, r.mouseRaw)
        state.camDump.stuckRequested = true
    end

    -- "growing": the gap widens while the camera turns below its cap (the 13 s episode in camera_fix.csv).
    if not s.refTime or r.time - s.refTime > CAMSTUCK_WINDOW * 2 then
        s.refTime, s.refOffset = r.time, offset -- (re)start the window
    elseif r.time - s.refTime >= CAMSTUCK_WINDOW then
        local rate = math.abs(r.camRate)
        if offset >= CAMSTUCK_MIN_OFFSET and offset - s.refOffset >= CAMSTUCK_GROWTH and rate > 1 and rate < CAMSTUCK_MAX_RATE then
            detect("growing", s.refTime, s.refOffset, CAMSTUCK_MIN_OFFSET)
            return
        end
        s.refTime, s.refOffset = r.time, offset
    end

    -- "noLock": not steering, yet the camera stays off Spyro's back instead of swinging in (normally
    -- half the gap closes in ~0.2 s, or the 180 deg/s cap closes large gaps within a second).
    -- Spyro's own turn rate also counts, in case the input isn't visible (mouse steering at 210 deg/s
    -- outruns the 180 deg/s camera cap).
    local steering = math.abs(r.stickX) > STEER_ANY or (r.mouseRaw == r.mouseRaw and r.mouseRaw ~= 0)
        or math.abs(r.yawRate) > CAMSTUCK_NOLOCK_MAX_YAW_RATE
    if steering or offset < CAMSTUCK_NOLOCK_OFFSET or (s.lockTime and r.time - s.lockTime > CAMSTUCK_WINDOW * 2) then
        s.lockTime = nil
    end
    if steering or offset < CAMSTUCK_NOLOCK_OFFSET then return end
    if not s.lockTime then
        s.lockTime, s.lockOffset = r.time, offset
    elseif r.time - s.lockTime >= CAMSTUCK_WINDOW then
        if offset > s.lockOffset * CAMSTUCK_NOLOCK_KEEP then
            detect("noLock", s.lockTime, s.lockOffset, CAMSTUCK_NOLOCK_OFFSET)
        end
        s.lockTime = nil
    end
end

-- One charge, from the first frame with the Charging tag until it clears.
local function updateCharge(r, prev)
    local c = state.charge
    if not r.charging then
        if not c then return end
        finishTurn()
        finishCamLock("chargeEnd")
        log("charge %d cap=%s avgFps=%.1f dt=%.1f-%.1fms dur=%.3fs startSpeed=%.1f t400=%s speedAvg=%.1f speedMax=%.1f yawChange=%+.1f camOffset0=%+.1f turns=%d mouseDist=%.2f yawPerMouse=%s dustSpawns=%d dustRate=%.1f/s dustEmitRate=%.1f/s dustDilationMax=%.2f detectedBy=%s",
            c.id, tostring(state.fpsCap or "?"), avgFps(c), c.dtMin * 1000, c.dtMax * 1000, r.time - c.startTime,
            c.startSpeed, c.t400 and string.format("%.3fs", c.t400) or "n/a",
            c.dtSum > 0 and c.speedSum / c.dtSum or 0 / 0, c.maxSpeed, c.yaw, c.camOffset0, c.turnCount,
            c.mouseDist, c.mouseDist > 0 and string.format("%.2f", c.mouseYaw / c.mouseDist) or "n/a",
            c.dustSpawns, c.dustGroundTime > 0 and c.dustSpawns / c.dustGroundTime or 0 / 0,
            c.dustGroundTime > 0 and c.dustEmitting / c.dustGroundTime or 0 / 0, c.dustDilationMax,
            r.chargeTag == nil and "maxWalkSpeed" or "tag")
        state.charge = nil
        if traceFile then traceFile:flush() end
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
    updateCamLock(r)
    updateCamStuck(r)
end

-- One camera settings transition, from the first frame IsTransitioning() is true until it's false.
local function updateCamTransition(r, prev)
    local t = state.camTransition
    if r.camTransitioning == true then
        if not t then
            state.camTransitionCount = state.camTransitionCount + 1
            t = newStats(r)
            t.id = state.camTransitionCount
            t.chargingAtStart = r.charging
            -- The previous frame's value is the one before the transition moved it.
            t.before = prev and prev.camCtrInterp or 0 / 0
            t.firstValue, t.samples, t.nextSample = r.camCtrInterp, {}, 1
            state.camTransition = t
        end
        addFrame(t, r)
        local elapsed = r.time - t.startTime
        while CAMTRANSITION_SAMPLES[t.nextSample] and elapsed >= CAMTRANSITION_SAMPLES[t.nextSample] do
            t.samples[#t.samples + 1] = string.format("%.2fs:%.3f", elapsed, r.camCtrInterp)
            t.nextSample = t.nextSample + 1
        end
    elseif t then
        log("camtransition %d cap=%s avgFps=%.1f dur=%.3fs charging=%s->%s ctrInterp before=%.3f first=%.3f %s end=%.3f",
            t.id, tostring(state.fpsCap or "?"), avgFps(t), r.time - t.startTime, tostring(t.chargingAtStart),
            tostring(r.charging), t.before, t.firstValue, table.concat(t.samples, " "), r.camCtrInterp)
        state.camTransition = nil
    end
end

local function finishSuperCharge(r)
    local sc = state.superCharge
    state.superCharge = nil
    local stages = {}
    for _, s in ipairs(sc.stageOrder) do stages[#stages + 1] = string.format("%d@%.3f", s.stage, s.at) end
    local speeds = {}
    for _, thr in ipairs(SUPERCHARGE_SPEEDS) do
        local t = sc.tSpeed[thr]
        if t then
            -- Ideal: speed grows by MaxAcceleration per second from the start (or from stage 3 above 750).
            local ideal
            if not (sc.accel and sc.accel > 0) then
                ideal = nil
            elseif thr <= SUPERCHARGE_BASE_WALK_SPEED then
                ideal = sc.startSpeed < thr and (thr - sc.startSpeed) / sc.accel or nil
            elseif sc.fastAt then
                ideal = sc.fastAt + math.max(thr - sc.fastSpeed, 0) / sc.accel
            end
            speeds[#speeds + 1] = string.format("t%d=%.3fs(ideal %s)", thr, t, ideal and string.format("%.3f", ideal) or "n/a")
        end
    end
    log("supercharge %d cap=%s avgFps=%.1f dt=%.1f-%.1fms dur=%.3fs startSpeed=%.1f attrDelay=%s stage3SpeedAt=%s speedMax=%.1f air=%.3fs airSegments=%d stages=%s %s detectedBy=%s",
        sc.id, tostring(state.fpsCap or "?"), avgFps(sc), sc.dtMin * 1000, sc.dtMax * 1000, r.time - sc.origin,
        sc.startSpeed, sc.attrDelay and string.format("%.3fs", sc.attrDelay) or "n/a",
        sc.fastAt and string.format("%.3fs", sc.fastAt) or "n/a",
        sc.maxSpeed, sc.airTime, sc.airSegments, table.concat(stages, ","), table.concat(speeds, " "), sc.detectedBy)
    for _, entry in ipairs(sc.stageOrder) do
        local st = sc.stats[entry.stage]
        local g = st.groundTime
        local function avg(key) return g > 0 and st[key] / g or 0 / 0 end
        log("supercharge %d stage %d: time=%.3fs grounded=%.3fs speedAvg=%.1f speedMax=%.1f accelObserved=%s groundFriction=%.2f maxAccel=%.0f maxWalkSpeed=%.0f camDist=%.1f camHeight=%.1f camPitch=%.2f camFov=%.2f camOffsetAbs=%.1f ctrInterp=%.3f radDefault=%.1f",
            sc.id, entry.stage, st.time, g, avg("speed"), st.maxSpeed,
            -- Speed gained per second on grounded frames below MaxWalkSpeed (compare with maxAccel).
            st.accelTime > 0 and string.format("%.1f", st.accelGain / st.accelTime) or "n/a",
            avg("friction"), avg("maxAccel"), avg("maxWalk"), avg("camDist"), avg("camHeight"), avg("camPitch"),
            avg("camFov"), avg("camOffset"), avg("ctrInterp"), avg("radDefault"))
    end
    if traceFile then traceFile:flush() end
end

-- One super charge, from the first frame with a super charge stage until it ends.
local function updateSuperCharge(r, prev)
    local sc = state.superCharge
    if r.superStage == nil then
        if sc then finishSuperCharge(r) end
        return
    end
    if not sc then
        state.superChargeCount = state.superChargeCount + 1
        local start = prev or r -- as for t400: this frame already moved with the super charge attributes
        sc = newStats(r)
        sc.id, sc.origin, sc.startSpeed, sc.maxSpeed, sc.detectedBy = state.superChargeCount, start.time, start.speed, r.speed, r.superDetectedBy
        sc.stageOrder, sc.stats, sc.tSpeed, sc.airTime, sc.airSegments = {}, {}, {}, 0, 0
        state.superCharge = sc
    end
    local elapsed = r.time - sc.origin
    -- Speed timing starts at the last frame before the super charge MaxWalkSpeed, which may lag the tag.
    if not sc.accel and num(r.maxWalkSpeed) >= SUPERCHARGE_BASE_WALK_SPEED - 1 then
        local start = (prev and prev.time < r.time) and prev or r
        sc.accel, sc.speedOrigin, sc.startSpeed = num(r.maxAccel), start.time, start.speed
        sc.attrDelay = start.time - sc.origin
    end
    local stage = r.superStage
    local st = sc.stats[stage]
    if not st then
        st = { time = 0, groundTime = 0, maxSpeed = 0, speed = 0, friction = 0, maxAccel = 0, maxWalk = 0, camDist = 0,
               camHeight = 0, camPitch = 0, camFov = 0, camOffset = 0, ctrInterp = 0, radDefault = 0, accelGain = 0, accelTime = 0 }
        sc.stats[stage] = st
        sc.stageOrder[#sc.stageOrder + 1] = { stage = stage, at = elapsed }
    end
    if sc.speedOrigin and not sc.fastAt and num(r.maxWalkSpeed) >= SUPERCHARGE_STAGE3_WALK_SPEED - 1 then
        local start = (prev and prev.time < r.time) and prev or r
        sc.fastAt, sc.fastSpeed = start.time - sc.speedOrigin, start.speed
    end
    if not prev or prev.time >= r.time then return end
    local step = r.time - prev.time
    addFrame(sc, r)
    sc.maxSpeed = math.max(sc.maxSpeed, r.speed)
    st.time = st.time + step
    st.maxSpeed = math.max(st.maxSpeed, r.speed)
    if not isGrounded(r.mode) then
        sc.airTime = sc.airTime + step
        if isGrounded(prev.mode) then sc.airSegments = sc.airSegments + 1 end
    else
        st.groundTime = st.groundTime + step
        local function add(key, v) if v == v then st[key] = st[key] + v * step end end -- skips NaN
        add("speed", r.speed)
        add("friction", num(r.groundFriction))
        add("maxAccel", num(r.maxAccel))
        add("maxWalk", num(r.maxWalkSpeed))
        add("camDist", r.camDist)
        add("camHeight", r.camHeight)
        add("camPitch", r.camPitch)
        add("camFov", r.camFov)
        add("camOffset", math.abs(r.camOffset))
        add("ctrInterp", r.camCtrInterp)
        add("radDefault", r.camRadDefault)
        if isGrounded(prev.mode) and prev.speed < num(r.maxWalkSpeed) - 1 and r.speed < num(r.maxWalkSpeed) - 1 then
            st.accelGain = st.accelGain + (r.speed - prev.speed)
            st.accelTime = st.accelTime + step
        end
    end
    for _, thr in ipairs(SUPERCHARGE_SPEEDS) do
        if sc.speedOrigin and not sc.tSpeed[thr] and r.speed >= thr and prev.speed < thr then
            local f = (thr - prev.speed) / (r.speed - prev.speed)
            sc.tSpeed[thr] = prev.time + step * f - sc.speedOrigin
        end
    end
end

-- The super charge stage (-1 Alt, 0-3) or nil when not super charging, and how it was detected.
-- Prefers the gameplay tags GA_Spyro_Charge applies; falls back on the movement attributes of
-- GE_Spyro_Movement_SuperCharging_S0-S3 / _Alt (stages 0-2 share them, so those read as 0).
local function superChargeStage(pawn, r)
    local asc = tryCall("GetAbilitySystemComponent", function()
        local address = pawn:GetAddress()
        if state.asc and state.asc.pawn == address and state.asc.component:IsValid() then return state.asc.component end
        local lib = StaticFindObject("/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary")
        local component = lib:GetAbilitySystemComponent(pawn)
        if not (component and component:IsValid()) then error("no AbilitySystemComponent") end
        state.asc = { pawn = address, component = component }
        return component
    end)
    if asc then
        local stage = tryCall("HasMatchingGameplayTag", function()
            local function has(tag)
                local v = asc:HasMatchingGameplayTag({ TagName = FName(tag) })
                if type(v) ~= "boolean" then error("returned " .. tostring(v)) end
                return v
            end
            if not has(SUPERCHARGE_TAG) then return false end
            for _, entry in ipairs(SUPERCHARGE_STAGE_TAGS) do
                if has(entry[2]) then return entry[1] end
            end
            return 0
        end)
        if stage ~= nil then return stage ~= false and stage or nil, "tag" end
    end
    local accel, walk = num(r.maxAccel), num(r.maxWalkSpeed)
    if accel == 150 and walk >= SUPERCHARGE_BASE_WALK_SPEED then return walk >= SUPERCHARGE_STAGE3_WALK_SPEED - 1 and 3 or 0, "attributes" end
    if accel == 500 and walk == 850 then return -1, "attributes" end
    local prev = state.prevRow
    -- Jumps swap the movement effect; stay in the super charge until he lands.
    if prev and prev.superStage and not isGrounded(r.mode) then return prev.superStage, "attributes" end
    return nil, "attributes"
end

local function describeValue(v)
    local kind = type(v)
    if kind == "number" then return string.format("%.6g", v) end
    if kind ~= "userdata" then return tostring(v) end
    local ok, valid = pcall(function() return v:IsValid() end)
    if ok and valid == false then return "<null>" end
    for _, method in ipairs({ "GetFullName", "ToString" }) do
        local ok, text = pcall(function() return v[method](v) end)
        if ok and text ~= nil then return tostring(text) end
    end
    return tostring(v)
end

local dumpValue

-- Appends { path, value } for every reflected property of `struct` read from `container`.
local function dumpStruct(struct, container, prefix, depth, out, seen)
    struct:ForEachProperty(function(prop)
        local name = prop:GetFName():ToString()
        if seen then
            if seen[name] then return end
            seen[name] = true
        end
        local ok, err = pcall(function() dumpValue(prop, container[name], prefix .. name, depth, out) end)
        if not ok then out[#out + 1] = { prefix .. name, "<error: " .. tostring(err) .. ">" } end
    end)
end

function dumpValue(prop, value, path, depth, out)
    local kind = prop:GetClass():GetFName():ToString()
    if CAMDUMP_SKIP_TYPES[kind] then
        out[#out + 1] = { path, "<" .. kind .. ">" }
    elseif kind == "StructProperty" and depth < CAMDUMP_MAX_DEPTH then
        dumpStruct(prop:GetStruct(), value, path .. ".", depth + 1, out)
    elseif kind == "ArrayProperty" and depth < CAMDUMP_MAX_DEPTH then
        out[#out + 1] = { path .. ".Num", tostring(value:GetArrayNum()) }
        local inner = prop:GetInner()
        value:ForEach(function(index, element)
            if index > CAMDUMP_MAX_ELEMENTS then return true end
            dumpValue(inner, element:get(), string.format("%s[%d]", path, index), depth + 1, out)
        end)
    else
        out[#out + 1] = { path, describeValue(value) }
    end
end

-- Every reflected property of the component, from its own class up to (not including) SceneComponent.
local function dumpObject(obj)
    local out, seen = {}, {}
    local class = obj:GetClass()
    while class and class:IsValid() do
        local className = class:GetFName():ToString()
        if CAMDUMP_STOP_CLASSES[className] then break end
        out[#out + 1] = { "# class", className }
        dumpStruct(class, obj, "", 0, out, seen)
        class = class:GetSuperStruct()
    end
    return out
end

local function writeCamDump(label, entries)
    local path = string.format("%s\\camdump_%s_%s.txt", modDir, os.date("%Y%m%d_%H%M%S"), label)
    local file = io.open(path, "w")
    if file then
        for _, e in ipairs(entries) do file:write(e[1], " = ", e[2], "\n") end
        file:close()
    end
    log("camdump %s: %d values -> %s", label, #entries, path)
end

local function logCamDumpDiff(before, after, label)
    local old = {}
    for _, e in ipairs(before) do old[e[1]] = e[2] end
    local changed = {}
    for _, e in ipairs(after) do
        if e[1] ~= "# class" and old[e[1]] ~= e[2] then
            changed[#changed + 1] = string.format("%s: %s -> %s", e[1], tostring(old[e[1]]), e[2])
        end
    end
    log("camdump diff %s: %d values changed%s", label, #changed,
        #changed > CAMDUMP_MAX_DIFF_LINES and string.format(" (first %d shown)", CAMDUMP_MAX_DIFF_LINES) or "")
    for i = 1, math.min(#changed, CAMDUMP_MAX_DIFF_LINES) do log("camdump diff %s", changed[i]) end
end

-- Dumps the FollowCameraComponent once while idle, once mid-charge, when a charge camera gets
-- stuck (updateCamStuck), and on F9.
local function updateCamDump(pawn, r)
    local d = state.camDump
    local label
    local stuck = d.stuckRequested and d.stuckCount < CAMSTUCK_MAX_DUMPS
    d.stuckRequested = false
    if stuck then
        d.stuckCount = d.stuckCount + 1
        label = "stuck"
    elseif d.requested then
        label = "manual"
    elseif not d.idle and not r.charging and isGrounded(r.mode) then
        label = "idle"
    elseif d.idle and not d.charge and state.charge and r.camTransitioning ~= true
        and r.time - state.charge.startTime >= CAMDUMP_CHARGE_DELAY then
        label = "charge"
    end
    if not label then return end
    if label == "manual" then d.requested = false end

    local ok, entries = pcall(dumpObject, pawn.FollowCamera)
    if not ok then
        log("camdump %s failed: %s", label, tostring(entries))
        entries = {}
    else
        writeCamDump(label, entries)
    end
    if label == "manual" then return end
    if label == "stuck" then
        -- Compare with a normal charge if one was dumped, otherwise with idle.
        local base, baseLabel = d.charge, "charge"
        if not (base and #base > 0) then base, baseLabel = d.idle, "idle" end
        if base and #base > 0 and #entries > 0 then logCamDumpDiff(base, entries, baseLabel .. " -> stuck") end
        return
    end
    d[label] = entries
    if label == "charge" and #d.idle > 0 and #entries > 0 then logCamDumpDiff(d.idle, entries, "idle -> charge") end
end

-- Records the raw mouse/right-stick X argument before the fix mod can replace the stored value.
-- The input Blueprint loads after the mods, so keep looking for it.
local function registerMouseHook()
    local h = state.mouseHook
    if h.registered or h.failed then return end
    if h.retryIn > 0 then
        h.retryIn = h.retryIn - 1
        return
    end
    h.retryIn = HOOK_RETRY_FRAMES
    local fn = StaticFindObject(MOUSE_AXIS_FUNCTION)
    if not (fn and fn:IsValid()) then return end
    local ok, err = pcall(RegisterHook, MOUSE_AXIS_FUNCTION, function(context, axisValue)
        local okGet, raw = pcall(function() return axisValue:get() end)
        if okGet and type(raw) == "number" then h.raw = raw end
    end)
    if ok then
        h.registered = true
        log("mouse axis hook registered")
    else
        h.failed = true
        log("mouse axis hook unavailable: %s", tostring(err))
    end
end

local function vecDist(a, b)
    local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
    return math.sqrt(dx * dx + dy * dy + dz * dz), math.sqrt(dx * dx + dy * dy)
end

-- Seconds a DragonSineMovement segment trails a steadily moving leader when MoveUpdate gets `delta`
-- once per frame of dt: it keeps K = (1 - 4 * delta)^2 of its distance per call.
local function dragonTrail(dt, delta)
    local keep = (1 - 4 * delta) ^ 2
    return dt * keep / (1 - keep)
end

local function logDragon(s, name)
    local lag = s.lagFrames > 0 and s.lagSum / s.lagFrames or 0 / 0
    local avgDt = s.dtSum / s.frames
    log("dragon %s: fps %.1f, speed %.1f, segments %d (managed %d), link %.1f (horiz %.1f, first %.1f), body %.1f, lag %.4f s/link (30 FPS 0.1006, unfixed here %.4f)",
        name, s.frames / s.dtSum, s.speedSum / s.frames, s.segments, s.managed, s.linkSum / math.max(s.links, 1),
        s.linkHSum / math.max(s.links, 1), s.firstSum / s.frames, s.bodySum / s.frames, lag,
        dragonTrail(avgDt, math.max(avgDt, 0.033)))
end

-- Per dragon: head speed and the distance from each live segment to the one it follows (the head for
-- the first). "managed" counts live segments with DragonSineMovement.bAlive off, i.e. taken over by
-- the fire dragon segment fix. Sampled before the world tick, so all positions are from the same frame.
local function updateDragons(time, dt)
    local d = state.dragon
    if d.findIn <= 0 then
        d.findIn = HOOK_RETRY_FRAMES
        d.heads = FindAllOf(DRAGON_CLASS) or {}
    else
        d.findIn = d.findIn - 1
    end
    if dt <= 0 then return end
    for _, head in ipairs(d.heads) do
        if head:IsValid() and not head.bIsDead then
            local address = head:GetAddress()
            local loc = head:K2_GetActorLocation()
            local s = d.stats[address]
            if not s or not s.prevLoc then
                s = { prevLoc = loc, start = time, frames = 0, dtSum = 0, speedSum = 0, links = 0, linkSum = 0,
                      linkHSum = 0, firstSum = 0, bodySum = 0, lagSum = 0, lagFrames = 0, segments = 0, managed = 0 }
                d.stats[address] = s
            else
                local speed = vecDist(loc, s.prevLoc) / dt
                s.prevLoc = loc
                local leaderLoc, segments, managed, links, linkSum, body = loc, 0, 0, 0, 0, 0
                local first = 0
                local bodySegments = head.BodySegments
                for i = 1, bodySegments:GetArrayNum() do
                    local segment = bodySegments[i]
                    if segment:IsValid() and segment.IsAlive_0 then
                        local segLoc = segment:K2_GetActorLocation()
                        local link, linkH = vecDist(segLoc, leaderLoc)
                        if segments == 0 then first = link end
                        segments = segments + 1
                        if not segment.DragonSineMovement.bAlive then managed = managed + 1 end
                        links = links + 1
                        linkSum = linkSum + link
                        s.linkHSum = s.linkHSum + linkH
                        body = body + link
                        leaderLoc = segLoc
                    end
                end
                if segments > 0 then
                    s.frames = s.frames + 1
                    s.dtSum = s.dtSum + dt
                    s.speedSum = s.speedSum + speed
                    s.links = s.links + links
                    s.linkSum = s.linkSum + linkSum
                    s.firstSum = s.firstSum + first
                    s.bodySum = s.bodySum + body
                    s.segments, s.managed = segments, managed
                    if speed >= DRAGON_MIN_SPEED then
                        s.lagSum = s.lagSum + linkSum / links / speed
                        s.lagFrames = s.lagFrames + 1
                    end
                end
                if time - s.start >= DRAGON_REPORT_INTERVAL then
                    if s.frames > 0 then
                        local name = head:GetFName():ToString()
                        logDragon(s, name:find("Purple") and "purple" or name:find("Red") and "red" or name)
                    end
                    d.stats[address] = { prevLoc = loc, start = time, frames = 0, dtSum = 0, speedSum = 0, links = 0, linkSum = 0,
                        linkHSum = 0, firstSum = 0, bodySum = 0, lagSum = 0, lagFrames = 0, segments = 0, managed = 0 }
                end
            end
        end
    end
end

-- Stuck camera repro (J / H, see CLAUDE.md "Stuck charge camera"). Centering latches its speed from the
-- camera gap on the charge's first centering frame, and sticks if Spyro then turns away from the camera
-- faster than that speed before the gap passes the switch check. Armed: every frame until a charge starts,
-- Spyro is turned to face `gap` degrees right of the camera. Once charging: he is turned right at the
-- full-lock charge rate for CAM_REPRO_TURN_TIME, as if steering full right. Press charge without the stick.
local CAM_REPRO_TURN_RATE = 130.8 -- deg/s, full stick lock during a charge
local CAM_REPRO_TURN_TIME = 3
local CAM_REPRO_ARMED_TIMEOUT = 10

local function armCamRepro(gap)
    if state.camRepro then
        state.camRepro = nil
        log("camrepro cancelled")
        return
    end
    state.camRepro = { gap = gap, phase = "armed", t = 0 }
    log("camrepro armed: gap %.0f deg right of the camera; press charge (no stick) within %d s", gap, CAM_REPRO_ARMED_TIMEOUT)
end

local function setYaw(pawn, yaw)
    local rot = pawn:K2_GetActorRotation()
    pawn:K2_SetActorRotation({ Pitch = rot.Pitch, Yaw = yaw, Roll = rot.Roll }, false)
end

local function updateCamRepro(pawn, r)
    local c = state.camRepro
    if not c then return end
    c.t = c.t + r.dt
    if c.phase == "armed" then
        if r.charging then
            c.phase, c.t = "turning", 0
            log("camrepro charge started: gap %.1f deg (camera %.1f, Spyro %.1f); turning right for %.1f s",
                angleDiff(r.yaw, r.camYaw), r.camYaw, r.yaw, CAM_REPRO_TURN_TIME)
        elseif c.t > CAM_REPRO_ARMED_TIMEOUT then
            state.camRepro = nil
            log("camrepro timed out without a charge")
            return
        else
            setYaw(pawn, r.camYaw + c.gap)
            return
        end
    end
    if not r.charging or c.t >= CAM_REPRO_TURN_TIME then
        log("camrepro done after %.2f s: gap %.1f deg, camera rate %.1f deg/s", c.t, angleDiff(r.yaw, r.camYaw), r.camRate)
        state.camRepro = nil
        return
    end
    setYaw(pawn, r.yaw + CAM_REPRO_TURN_RATE * r.dt)
end

local function sample()
    registerMouseHook()
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
        mouseRaw = state.mouseHook.raw, -- stick_rx is the stored value, which the fix mod may replace

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
    r.superStage, r.superDetectedBy = superChargeStage(pawn, r)
    if r.chargeTag ~= nil then
        r.charging = r.chargeTag
    else
        r.charging = num(r.maxWalkSpeed) >= CHARGE_WALK_SPEED
    end

    local prev = state.prevRow
    r.speed = math.sqrt(r.vx * r.vx + r.vy * r.vy)
    r.velYaw = r.speed > 1 and math.deg(math.atan(r.vy, r.vx)) or r.yaw
    r.accelYaw = math.abs(r.accelX) + math.abs(r.accelY) > 1e-3 and math.deg(math.atan(r.accelY, r.accelX)) or r.yaw
    r.camOffset = angleDiff(r.camYaw, r.yaw)
    r.camRate = (prev and r.time > prev.time) and angleDiff(r.camYaw, prev.camYaw) / (r.time - prev.time) or 0
    r.yawRate = (prev and r.time > prev.time) and angleDiff(r.yaw, prev.yaw) / (r.time - prev.time) or 0

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
    updateRise(r)
    updateSuperCharge(r, prev)
    updateCharge(r, prev)
    updateCamTransition(r, prev)
    updateCamDump(pawn, r)
    local reproOk, reproErr = pcall(updateCamRepro, pawn, r)
    if not reproOk then
        state.camRepro = nil
        log("camrepro error: %s", tostring(reproErr))
    end
    -- The first call succeeds on every level without dragons, so log errors here rather than via tryCall.
    local dragonOk, dragonErr = pcall(updateDragons, r.time, prev and r.time - prev.time or 0)
    if not dragonOk and not state.dragon.errorLogged then
        state.dragon.errorLogged = true
        log("fire dragon stats error: %s", tostring(dragonErr))
    end
    writeRow(r)
    state.wasGrounded = grounded
    state.prevRow = r
    table.insert(state.recent, r)
    if #state.recent > RECENT_FRAMES then table.remove(state.recent, 1) end
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
RegisterKeyBind(Key.F9, function() state.camDump.requested = true end)
RegisterKeyBind(Key.J, function() ExecuteInGameThread(function() armCamRepro(33) end) end)
RegisterKeyBind(Key.H, function() ExecuteInGameThread(function() armCamRepro(12) end) end)

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
