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
--   "thief" log lines      once a second per chasing or moving thief (actors with a ChaseSpeedManager, e.g. the
--                          Gnorc egg thieves): speed (from position) and velocity next to the MaxWalkSpeed the
--                          manager sets, % of time at it, observed acceleration vs MaxAcceleration, distance
--                          to Spyro vs the desired distance, chase time, enemy state and predicted laughs.
--   thieves_<timestamp>.csv one row per frame per active thief.
--   "flame" log lines      each flame breath (PS_VFX_Flame_Breath or _Rage component active): the particle
--                          system's world bounds measured along Spyro's facing: reach (farthest forward from
--                          the component), halfWidth (half the extent across, and its sideways centre),
--                          halfHeight, and the SP_Flames_* trace parameters the native flame actor sets.
--                          Bounds are a world axis-aligned box, so the across extent also picks up some of the
--                          flame's length unless Spyro faces along a world axis; "aligned" repeats the numbers
--                          for frames within FLAME_ALIGNED_DEG of one. Compare breaths with the same heading.
--                          "tail" is the widest the lingering particles got in FLAME_TAIL after deactivation.
--   flames_<timestamp>.csv one row per frame per active (or lingering) flame.
--   F10                    rescan for flame particle components (if a flame isn't picked up automatically)
--   K                      flame experiment: cycle normal / noHardMuzzle / velocity30 on the flame's
--                          hard muzzle emitter (see FLAME_EXPERIMENTS; logged)
--                          The world bounds turned out unusable (empty emitters stretch them to the world
--                          origin, and otherwise particle size padding dominates), so judge the experiment by eye.
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
-- Chasing thieves (Gnorc egg thieves and their S2/S3 counterparts) get their MaxWalkSpeed from this component.
local THIEF_SPEED_MANAGER_CLASSES = { ChaseSpeedManager_C = true, ChaseSpeedManager_S3_C = true }
local THIEF_REPORT_INTERVAL = 1.0 -- seconds of game time per thief line
local THIEF_MOVING_SPEED = 1      -- thieves slower than this that aren't chasing are left out
local THIEF_LAUGH_DROP = 150      -- ChaseSpeedManager laughs when Spyro's horizontal speed drops more than this in one tick
local THIEF_LAUGH_COOLDOWN = 3    -- seconds (the laugh's Delay)
-- Flame breath effects SpyroFlameBreathActor (FireAttackActorTrace_C) spawns; see "flame" lines.
local FLAME_TEMPLATES = { PS_VFX_Flame_Breath = "flame", PS_VFX_Flame_Breath_Rage = "rage" }
local FLAME_PARAMETERS = { "SP_Flames_C", "SP_Flames_L1", "SP_Flames_R1", "SP_Flames_L2", "SP_Flames_R2" }
local FLAME_PENDING_FRAMES = 30 -- frames a new ParticleSystemComponent may take to get its template
local FLAME_TAIL = 1.0          -- seconds a deactivated flame's lingering particles stay in the CSV and the tail max
local FLAME_ALIGNED_DEG = 5     -- headings within this of a world axis count as "aligned" (world AABB ~ flame box)
local FLAME_TEMPLATE_PATHS = {
    "/VFX_Spryo/Shared/Particles/Characters/Spyro/FlameThrower/PS_VFX_Flame_Breath.PS_VFX_Flame_Breath",
    "/VFX_Spryo/Shared/Particles/Characters/Spyro/FlameThrower/PS_VFX_Flame_Breath_Rage.PS_VFX_Flame_Breath_Rage",
}
-- K experiment modes. Cause (particle capture and experiments 2026-09-16): hard_flames_velocity_muzzle is a
-- local-space, velocity-aligned (PSA_Velocity) sprite emitter moving only ~9 units/s, so at high FPS a frame
-- moves its particles ~0.02 units. The sprite direction comes from that per-frame move, which becomes
-- unstable, and the long thin sprites point straight up or sideways. Switching the emitter off removes them.
--   noHardMuzzle: the emitter's LOD bEnabled off
--   velocity30:   its StartVelocity scaled by (1/30)/dt so a frame moves it as far as at 30 FPS (candidate fix;
--                 the particles drift ~k times farther forward than the ~2 units they drift at 30 FPS)
local FLAME_EXPERIMENTS = { "normal", "noHardMuzzle", "velocity30" }
local FLAME_HARD_MUZZLE_EMITTER = "hard_flames_velocity_muzzle"
local FLAME_VELOCITY_RESCALE = 0.05 -- velocity30 re-applies when the scale for the current FPS differs this much
-- Particle module classes whose default object address (and so vtable) is logged at startup, for disassembly.
local PARTICLE_MODULE_CDOS = { "ParticleModule", "ParticleModuleAttractorPoint", "ParticleModuleAccelerationDrag",
                               "ParticleModuleAccelerationConstant", "ParticleModuleVelocityInheritParent",
                               "ParticleModuleVelocity", "ParticleModuleSize", "ParticleModuleLifetime" }
-- FindAllOf scans the whole object array, so it only runs for a while after NotifyOnNewObject reports
-- the class loading (or the pawn changes): NEW_OBJECT_LOOKUPS lookups, LOOKUP_INTERVAL seconds apart.
local NEW_OBJECT_LOOKUPS = 15
local LOOKUP_INTERVAL = 1.0

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
local traceStamp = os.date("%Y%m%d_%H%M%S")
local tracePath = string.format("%s\\trace_%s.csv", modDir, traceStamp)
local thiefTracePath = string.format("%s\\thieves_%s.csv", modDir, traceStamp) -- created with the first active thief
local flameTracePath = string.format("%s\\flames_%s.csv", modDir, traceStamp) -- created with the first flame

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
    dragon = { heads = {}, lookups = 1, nextLookup = 0, classSeen = false, stats = {} }, -- stats: head address -> accumulated dragon line values
    -- managers: ChaseSpeedManager components; entries: thief address -> { prevLoc, lastLaugh, stats }
    thief = { managers = {}, lookups = 1, nextLookup = 0, classSeen = false, entries = {}, errorLogged = false },
    -- pending: new ParticleSystemComponents whose template isn't known yet ({ component, frames });
    -- tracked: component address -> { component, kind, breath }; scan: FindAllOf rescan requested (startup, F10)
    flame = { pending = {}, tracked = {}, count = 0, scan = true, errorLogged = false },
    pawnAddress = nil,
    superCharge = nil,
    superChargeCount = 0,
    asc = nil, -- { pawn = address, component = AbilitySystemComponent }
    walkin = { component = nil, class = nil }, -- the controller's PathFollowingComponent (freed dragon walk-in)
    walkinEvent = nil,
    walkinCount = 0,
    walkinErrorLogged = false,
    spot = nil,      -- the one saved quicksave spot (V/B/L), loaded from spots.txt at startup
    travel = nil,    -- a StartAtLevelCheckpoint travel in progress, waiting to teleport on arrival
    spotRequest = nil, -- "save", "load" or "reload", set by a key and handled in the game thread
    reload = nil,    -- a level reload in progress, waiting to teleport back to the spot
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
        -- num(): a property read during a pawn change once came back as light userdata.
        num(r.x), num(r.y), num(r.z), num(r.yaw), num(r.vx), num(r.vy), num(r.vz), num(r.inputX), num(r.inputY),
        num(r.accelX), num(r.accelY), num(r.mode), num(r.customMode), num(r.gravityScale), tostring(r.floorWalkable),
        num(r.floorDist), num(r.floorNz),
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

-- True when a FindAllOf lookup for `s` should run now (see NEW_OBJECT_LOOKUPS).
local function lookupDue(s, time)
    if s.lookups <= 0 or time < s.nextLookup then return false end
    s.lookups, s.nextLookup = s.lookups - 1, time + LOOKUP_INTERVAL
    return true
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
    if lookupDue(d, time) then d.heads = FindAllOf(DRAGON_CLASS) or {} end
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

local thiefFile = nil

local function newThiefStats(time)
    return { start = time, frames = 0, dtSum = 0, activeTime = 0, speedSum = 0, speedMax = 0, velSpeedSum = 0,
             maxWalkSum = 0, maxWalkMin = math.huge, maxWalkMax = 0, maxAccel = 0 / 0, atMaxTime = 0,
             desiredSpeedSum = 0, desiredDistSum = 0, distSum = 0, spyroSpeedSum = 0, chaseTime = 0 / 0, chasingTime = 0,
             accelGain = 0, accelTime = 0, laughs = 0, states = {} }
end

local function logThief(name, s)
    local t = s.activeTime
    local function avg(key) return s[key] / t end
    local topState, topTime = "?", -1
    for stateName, stateTime in pairs(s.states) do
        if stateTime > topTime then topState, topTime = stateName, stateTime end
    end
    log("thief %s cap=%s avgFps=%.1f active=%.2fs chasing=%.2fs chaseTime=%.1fs state=%s speed=%.1f (velocity %.1f, max %.1f) maxWalkSpeed=%.1f (%.1f-%.1f) atMaxWalkSpeed=%.0f%% desiredSpeed=%.1f accelObserved=%s maxAccel=%.0f distance=%.1f desiredDistance=%.1f spyroSpeed=%.1f laughs=%d",
        name, tostring(state.fpsCap or "?"), s.frames / s.dtSum, t, s.chasingTime, s.chaseTime, topState,
        avg("speedSum"), avg("velSpeedSum"), s.speedMax, avg("maxWalkSum"), s.maxWalkMin, s.maxWalkMax,
        100 * s.atMaxTime / t, avg("desiredSpeedSum"),
        -- Speed gained per second on grounded frames that sped up below MaxWalkSpeed (compare with maxAccel).
        s.accelTime > 0 and string.format("%.1f", s.accelGain / s.accelTime) or "n/a",
        s.maxAccel, avg("distSum"), avg("desiredDistSum"), avg("spyroSpeedSum"), s.laughs)
end

-- Per chasing thief (anything with a ChaseSpeedManager): its speed next to the MaxWalkSpeed the manager
-- sets. The manager's tick: DesiredDistance lerps 300 -> 120 over 40 s of ChaseTime, DesiredSpeed =
-- MapRangeClamped(DesiredDistance - distance to Spyro, -50..50 -> 290..700), MaxWalkSpeed =
-- Lerp(MaxWalkSpeed, DesiredSpeed, dt * 0.7). It laughs (sound only, 3 s cooldown) when Spyro's
-- horizontal speed dropped by more than 150 since its last tick, which is per frame, so "laughs" counts
-- those drops. Sampled before the world tick, like the dragons.
local function updateThieves(r, prev)
    local th = state.thief
    if lookupDue(th, r.time) then
        th.managers = {}
        for className in pairs(THIEF_SPEED_MANAGER_CLASSES) do
            for _, manager in ipairs(FindAllOf(className) or {}) do th.managers[#th.managers + 1] = manager end
        end
    end
    local dt = prev and r.time - prev.time or 0
    if dt <= 0 then return end
    for _, manager in ipairs(th.managers) do
        local thief = manager:IsValid() and manager:GetOwner() or nil
        if thief and thief:IsValid() then
            local address = thief:GetAddress()
            local loc = thief:K2_GetActorLocation()
            local e = th.entries[address]
            if not e or r.time < e.stats.start then -- new thief, or a reloaded world reusing the address
                e = { prevLoc = loc, lastLaugh = -math.huge, stats = newThiefStats(r.time), name = thief:GetFName():ToString() }
                th.entries[address] = e
            else
                local cmc = thief.CharacterMovement
                local vel = cmc.Velocity
                local speed = math.sqrt((loc.X - e.prevLoc.X) ^ 2 + (loc.Y - e.prevLoc.Y) ^ 2) / dt
                local velSpeed = math.sqrt(vel.X * vel.X + vel.Y * vel.Y)
                local prevSpeed = e.prevSpeed
                e.prevLoc, e.prevSpeed = loc, speed
                local chasing = manager.ChaseIsOn == true
                local s = e.stats
                if chasing or speed > THIEF_MOVING_SPEED then
                    local maxWalk, mode = num(cmc.MaxWalkSpeed), cmc.MovementMode
                    local desiredSpeed, desiredDist = num(manager.CurrentDesiredSpeed), num(manager.CurrentDesiredDistance)
                    local distance = math.sqrt((loc.X - r.x) ^ 2 + (loc.Y - r.y) ^ 2 + (loc.Z - r.z) ^ 2)
                    local stateName = tryCall("thief FalconEnemy:BP_GetCurrentStateName", function()
                        return thief.FalconEnemy:BP_GetCurrentStateName():ToString()
                    end) or "?"
                    s.frames, s.dtSum = s.frames + 1, s.dtSum + dt
                    s.activeTime = s.activeTime + dt
                    s.speedSum = s.speedSum + speed * dt
                    s.speedMax = math.max(s.speedMax, speed)
                    s.velSpeedSum = s.velSpeedSum + velSpeed * dt
                    s.maxWalkSum = s.maxWalkSum + maxWalk * dt
                    s.maxWalkMin, s.maxWalkMax = math.min(s.maxWalkMin, maxWalk), math.max(s.maxWalkMax, maxWalk)
                    s.maxAccel = num(cmc.MaxAcceleration)
                    if speed >= maxWalk - 1 then s.atMaxTime = s.atMaxTime + dt end
                    s.desiredSpeedSum = s.desiredSpeedSum + desiredSpeed * dt
                    s.desiredDistSum = s.desiredDistSum + desiredDist * dt
                    s.distSum = s.distSum + distance * dt
                    s.spyroSpeedSum = s.spyroSpeedSum + r.speed * dt
                    s.states[stateName] = (s.states[stateName] or 0) + dt
                    if chasing then
                        s.chasingTime = s.chasingTime + dt
                        s.chaseTime = num(manager.ChaseTime)
                        if prev.speed - r.speed > THIEF_LAUGH_DROP and r.time - e.lastLaugh >= THIEF_LAUGH_COOLDOWN then
                            e.lastLaugh = r.time
                            s.laughs = s.laughs + 1
                        end
                    end
                    if isGrounded(mode) and prevSpeed and speed > prevSpeed and speed < maxWalk - 1 then
                        s.accelGain = s.accelGain + (speed - prevSpeed)
                        s.accelTime = s.accelTime + dt
                    end
                    if not thiefFile then
                        thiefFile = io.open(thiefTracePath, "w")
                        if thiefFile then
                            thiefFile:write("time,dt,fps_cap,thief,x,y,z,speed,vel_speed,vz,move_mode,max_walk_speed,max_accel,chase_on,chase_time,desired_distance,desired_speed,distance,spyro_speed,state\n")
                        end
                    end
                    if thiefFile then
                        thiefFile:write(string.format("%.5f,%.5f,%s,%s,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%d,%.3f,%.1f,%s,%.3f,%.2f,%.2f,%.2f,%.3f,%s\n",
                            r.time, dt, tostring(state.fpsCap or ""), e.name, loc.X, loc.Y, loc.Z, speed, velSpeed, vel.Z,
                            mode, maxWalk, s.maxAccel, tostring(chasing), num(manager.ChaseTime), desiredDist, desiredSpeed,
                            distance, r.speed, stateName))
                    end
                end
                if r.time - s.start >= THIEF_REPORT_INTERVAL then
                    if s.activeTime > 0 then
                        logThief(e.name, s)
                        if thiefFile then thiefFile:flush() end
                    end
                    e.stats = newThiefStats(r.time)
                end
            end
        end
    end
end

local flameFile = nil

local function describeOut(t)
    local parts = {}
    for k, v in pairs(t) do
        local x = type(v) ~= "number" and (pcall(function() return v.X end) and v.X) or nil
        table.insert(parts, string.format("%s=%s%s", tostring(k), tostring(v), x and string.format(" (X %s)", tostring(x)) or ""))
    end
    return "{" .. table.concat(parts, ", ") .. "}"
end

-- An FVector out-param: UE4SS may store it under the parameter name in any of the passed tables, or
-- write X/Y/Z into the table passed for it.
local function outVector(tables, own, key)
    for _, t in ipairs(tables) do
        local v = t[key]
        if v ~= nil and type(v.X) == "number" then return v end
    end
    if type(own.X) == "number" then return own end
    return nil
end

-- A component's world bounds (origin, extent, sphere radius) from KismetSystemLibrary:GetComponentBounds.
local function componentBounds(ksl, component)
    local o, e, sr = {}, {}, {}
    local ret = ksl:GetComponentBounds(component, o, e, sr)
    local tables = { o, e, sr }
    local origin, extent = outVector(tables, o, "Origin"), outVector(tables, e, "BoxExtent")
    local radius = sr.SphereRadius or o.SphereRadius or e.SphereRadius
    if not origin or not extent then
        error(string.format("GetComponentBounds out-params: return=%s origin=%s extent=%s radius=%s",
            tostring(ret), describeOut(o), describeOut(e), describeOut(sr)))
    end
    return origin, extent, num(radius)
end

local function trackFlameComponent(component)
    if not component:IsValid() then return true end
    local template = component.Template
    if not template:IsValid() then return false end
    local kind = FLAME_TEMPLATES[template:GetFName():ToString()]
    local address = component:GetAddress()
    if kind and not state.flame.tracked[address] then
        state.flame.tracked[address] = { component = component, kind = kind }
        -- The address lets tools/Capture-FlameParticles.ps1 read the component's particles from memory.
        log("flame component found: %s (%s) at 0x%X", component:GetFullName(), kind, address)
    end
    return true
end

-- SP_Flames_* parameter values (name -> value) from the component's InstanceParameters.
local function flameParameters(component)
    local values = {}
    local params = component.InstanceParameters
    for i = 1, params:GetArrayNum() do
        local p = params[i]
        values[p.Name:ToString()] = p.Scalar
    end
    return values
end

local function newFlameBreath(r, kind)
    state.flame.count = state.flame.count + 1
    local b = { id = state.flame.count, kind = kind, start = r.time, yaw = r.yaw, frames = 0, dtSum = 0, speedSum = 0,
                reachMax = 0, widthSum = 0, widthMax = 0, centerSum = 0, heightSum = 0, heightMax = 0,
                alignedFrames = 0, alignedReachMax = 0, alignedWidthSum = 0, alignedWidthMax = 0, tailWidthMax = 0,
                paramSum = {}, paramMin = {}, paramFrames = 0 }
    for _, name in ipairs(FLAME_PARAMETERS) do b.paramSum[name], b.paramMin[name] = 0, math.huge end
    return b
end

local function logFlameBreath(b)
    local n = math.max(b.frames, 1)
    local params = {}
    for _, name in ipairs(FLAME_PARAMETERS) do
        local short = name:sub(#"SP_Flames_" + 1)
        if b.paramFrames > 0 then
            table.insert(params, string.format("%s %.3f (min %.3f)", short, b.paramSum[name] / b.paramFrames, b.paramMin[name]))
        end
    end
    local aligned = b.alignedFrames > 0
        and string.format("aligned %d frames: reach %.1f, halfWidth avg %.1f max %.1f", b.alignedFrames, b.alignedReachMax,
            b.alignedWidthSum / b.alignedFrames, b.alignedWidthMax)
        or "aligned 0 frames"
    log("flame %d %s: fps %.1f, active %.3f s, yaw %.1f, speed %.1f, reach %.1f, halfWidth avg %.1f max %.1f (centre %+.1f), halfHeight avg %.1f max %.1f, tail halfWidth max %.1f; %s; params %s",
        b.id, b.kind, b.dtSum > 0 and b.frames / b.dtSum or 0 / 0, b.activeTime or (b.dtSum), b.yaw, b.speedSum / n,
        b.reachMax, b.widthSum / n, b.widthMax, b.centerSum / n, b.heightSum / n, b.heightMax, b.tailWidthMax, aligned,
        #params > 0 and table.concat(params, ", ") or "unavailable")
    if flameFile then flameFile:flush() end
end

-- Spyro's flame breath: the particle system component's world bounds, measured along his facing, and the
-- trace parameters that set its emitters' lifetimes. One "flame" line per activation.
local function updateFlames(r, dt)
    local f = state.flame
    if dt > 0 then f.dtAvg = f.dtAvg and (f.dtAvg * 0.95 + dt * 0.05) or dt end
    for i = #f.pending, 1, -1 do
        local e = f.pending[i]
        e.frames = e.frames + 1
        if trackFlameComponent(e.component) or e.frames >= FLAME_PENDING_FRAMES then table.remove(f.pending, i) end
    end
    if f.scan then
        f.scan = false
        for _, component in ipairs(FindAllOf("ParticleSystemComponent") or {}) do trackFlameComponent(component) end
    end

    local ksl = UEHelpers.GetKismetSystemLibrary()
    local yawRad = math.rad(r.yaw)
    local c, s = math.cos(yawRad), math.sin(yawRad)
    local aligned = math.min(math.abs(c), math.abs(s)) <= math.sin(math.rad(FLAME_ALIGNED_DEG))
    for address, t in pairs(f.tracked) do
      local ok, err = pcall(function()
        local component = t.component
        if not component:IsValid() then
            if t.breath then logFlameBreath(t.breath) end
            f.tracked[address] = nil
        else
            local active = component:IsActive()
            local b = t.breath
            if active and (not b or b.activeTime) then
                if b then logFlameBreath(b) end
                b = newFlameBreath(r, t.kind)
                t.breath = b
            end
            if b and not active and not b.activeTime then b.activeTime = r.time - b.start end
            if b and b.activeTime and r.time - b.start - b.activeTime > FLAME_TAIL then
                logFlameBreath(b)
                t.breath, b = nil, nil
            end
            if b and dt > 0 then
                local loc = component:K2_GetComponentLocation()
                -- Without bounds (logged once as unavailable) the parameters are still recorded; sizes read 0.
                local bounds = tryCall("GetComponentBounds", function() return { componentBounds(ksl, component) } end)
                    or { loc, { X = 0, Y = 0, Z = 0 }, 0 / 0 }
                local origin, extent, radius = bounds[1], bounds[2], bounds[3]
                local dx, dy = origin.X - loc.X, origin.Y - loc.Y
                local forwardCenter, lateralCenter = dx * c + dy * s, -dx * s + dy * c
                local forwardHalf = math.abs(c) * extent.X + math.abs(s) * extent.Y
                local lateralHalf = math.abs(s) * extent.X + math.abs(c) * extent.Y
                local reach = forwardCenter + forwardHalf
                local values = tryCall("ParticleSystemComponent.InstanceParameters", function() return flameParameters(component) end) or {}
                if active then
                    b.frames, b.dtSum = b.frames + 1, b.dtSum + dt
                    b.speedSum = b.speedSum + r.speed
                    b.reachMax = math.max(b.reachMax, reach)
                    b.widthSum, b.widthMax = b.widthSum + lateralHalf, math.max(b.widthMax, lateralHalf)
                    b.centerSum = b.centerSum + lateralCenter
                    b.heightSum, b.heightMax = b.heightSum + extent.Z, math.max(b.heightMax, extent.Z)
                    if aligned then
                        b.alignedFrames = b.alignedFrames + 1
                        b.alignedReachMax = math.max(b.alignedReachMax, reach)
                        b.alignedWidthSum = b.alignedWidthSum + lateralHalf
                        b.alignedWidthMax = math.max(b.alignedWidthMax, lateralHalf)
                    end
                    if values.SP_Flames_C then
                        b.paramFrames = b.paramFrames + 1
                        for _, name in ipairs(FLAME_PARAMETERS) do
                            -- A parameter can be missing on some frames; count it at its default of 1.
                            local v = type(values[name]) == "number" and values[name] or 1
                            b.paramSum[name] = b.paramSum[name] + v
                            b.paramMin[name] = math.min(b.paramMin[name], v)
                        end
                    end
                else
                    b.tailWidthMax = math.max(b.tailWidthMax, lateralHalf)
                end
                if not flameFile then
                    flameFile = io.open(flameTracePath, "w")
                    if flameFile then
                        flameFile:write("time,dt,fps_cap,breath,kind,active,spyro_speed,yaw,comp_x,comp_y,comp_z,origin_x,origin_y,origin_z,extent_x,extent_y,extent_z,radius,"
                            .. "forward_center,lateral_center,forward_half,lateral_half,reach,aligned,p_c,p_l1,p_r1,p_l2,p_r2\n")
                    end
                end
                if flameFile then
                    flameFile:write(string.format("%.5f,%.5f,%s,%d,%s,%s,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%s,%.4f,%.4f,%.4f,%.4f,%.4f\n",
                        r.time, dt, tostring(state.fpsCap or ""), b.id, b.kind, tostring(active), r.speed, r.yaw,
                        loc.X, loc.Y, loc.Z, origin.X, origin.Y, origin.Z, extent.X, extent.Y, extent.Z, radius,
                        forwardCenter, lateralCenter, forwardHalf, lateralHalf, reach, tostring(aligned),
                        num(values.SP_Flames_C), num(values.SP_Flames_L1), num(values.SP_Flames_R1),
                        num(values.SP_Flames_L2), num(values.SP_Flames_R2)))
                end
            end
        end
      end)
      if not ok and not f.componentErrorLogged then
          f.componentErrorLogged = true
          log("flame component error: %s", tostring(err))
      end
    end
end

-- Applies the K experiment to hard_flames_velocity_muzzle in the loaded flame templates (see FLAME_EXPERIMENTS);
-- other modes restore the asset's own values. New flame components pick the settings up when created, so
-- judge the next breath after switching. Returns the velocity scale applied (1 outside velocity30).
local function applyFlameExperiment(quiet)
    local f = state.flame
    local mode = FLAME_EXPERIMENTS[f.experiment or 1]
    f.original = f.original or {} -- "address.property[index]" -> original value
    local scale = 1
    if mode == "velocity30" and f.dtAvg and f.dtAvg > 0 then scale = math.max(1, (1 / 30) / f.dtAvg) end
    local changed, templates, emitters = 0, 0, 0
    local function set(obj, key, get, put, value)
        key = string.format("%X.%s", obj:GetAddress(), key)
        if f.original[key] == nil then f.original[key] = get() end
        if value == nil then value = f.original[key] end
        if get() ~= value then
            put(value)
            changed = changed + 1
        end
    end
    for _, path in ipairs(FLAME_TEMPLATE_PATHS) do
        local template = StaticFindObject(path)
        if template and template:IsValid() then
            templates = templates + 1
            local list = template.Emitters
            for i = 1, list:GetArrayNum() do
                local emitter = list[i]
                if emitter.EmitterName:ToString() == FLAME_HARD_MUZZLE_EMITTER then
                    emitters = emitters + 1
                    local lods = emitter.LODLevels
                    for j = 1, lods:GetArrayNum() do
                        local lod = lods[j]
                        set(lod, "bEnabled", function() return lod.bEnabled end, function(v) lod.bEnabled = v end,
                            mode == "noHardMuzzle" and false or nil)
                        local modules = lod.Modules
                        for k = 1, modules:GetArrayNum() do
                            local module = modules[k]
                            if module:IsValid() and module:GetClass():GetFName():ToString() == "ParticleModuleVelocity" then
                                -- Cooked distributions are read from the lookup table (Distribution is null).
                                local values = module.StartVelocity.Table.Values
                                for n = 1, values:GetArrayNum() do
                                    local key = "StartVelocity[" .. n .. "]"
                                    local original = f.original[string.format("%X.%s", module:GetAddress(), key)]
                                    if original == nil then original = values[n] end
                                    set(module, key, function() return values[n] end, function(v) values[n] = v end,
                                        original * scale)
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    f.appliedScale = scale
    if not quiet or changed > 0 then
        log("flame experiment %d: %s (%d templates loaded, %d hard muzzle emitters, velocity scale %.2f, %d values changed)",
            f.experiment or 1, mode, templates, emitters, scale, changed)
    end
end

local function logParticleModuleAddresses()
    for _, name in ipairs(PARTICLE_MODULE_CDOS) do
        local cdo = StaticFindObject(string.format("/Script/Engine.Default__%s", name))
        if cdo and cdo:IsValid() then
            log("particle module CDO %s at 0x%X", name, cdo:GetAddress())
        else
            log("particle module CDO %s not found", name)
        end
    end
end

-- Quicksave spot (V save, B teleport back) and level reload (L). Saving the game's own state needs a
-- restart (tools/Save-GameSnapshot.ps1), so this is the fast version: V remembers where Spyro stands,
-- B puts him back, and L reloads the level (respawning enemies and resetting mechanisms) and then
-- teleports him to the spot once the level is up. Spots are per level and kept in spots.txt, so they
-- survive a restart. Only position, facing and camera yaw are restored, not velocity or ability state:
-- save while standing still.
local SPOT_FILE = modDir .. "\\spots.txt"
local RELOAD_TIMEOUT = 60 -- seconds before a stuck reload gives up and puts everything back
local RELOAD_SETTLE = 0.5 -- seconds after the sublevels are back before Spyro is put down

-- UE4SS returns FString and FName as objects, not Lua strings; tostring() gives "FString: <address>".
local function asString(v)
    if type(v) == "string" then return v end
    if v == nil then return nil end
    local ok, s = pcall(function() return v:ToString() end)
    return (ok and type(s) == "string") and s or nil
end

-- The persistent level is GlobalPersistentLevel for every level, so the level itself is whichever
-- LS### package is streamed in (e.g. /LS107_PeacekeeperHome/Maps/LS107_design -> LS107).
-- The game streams levels in as runtime LevelStreamingKismet instances, whose PackageName is empty;
-- the package is on the loaded ULevel (e.g. Level /LS107_PeacekeeperHome/Maps/LS107_design.…).
local function streamingPackage(sl)
    local name = asString(sl.PackageNameToLoad)
    if name and name ~= "" and name ~= "None" then return name end
    name = asString(sl.PackageName)
    if name and name ~= "" and name ~= "None" then return name end
    local ok, full = pcall(function()
        local level = sl.LoadedLevel
        return level:IsValid() and level:GetFullName() or nil
    end)
    return (ok and full) and full:match("([^%s]+)%.[^%.]*$") or nil
end

local function eachStreamingLevel(pawn, fn)
    local world = pawn:GetWorld()
    if not world:IsValid() then return end
    world.StreamingLevels:ForEach(function(_, element)
        local sl = element:get()
        if sl:IsValid() then fn(sl, streamingPackage(sl)) end
    end)
end

-- The level prefix and sublevel suffix of a streamed package, e.g. /LS104_Townsquare/Maps/LS104_design
-- -> "LS104", "design". Anything that isn't an LS### sublevel (GlobalPersistentLevel, LS104_ART_MASTER)
-- comes back nil.
local function levelParts(package)
    local base = package and package:match("([^/]+)$")
    if not base then return nil end
    local prefix, suffix = base:match("^(.-)_([^_]+)$")
    if not prefix or not prefix:match("^%a%a%d+$") then return nil end
    return prefix, suffix
end

local function levelTranslation(sl)
    return tryCall("LevelStreaming.LevelTransform", function()
        local t = sl.LevelTransform.Translation
        return { X = t.X, Y = t.Y }
    end)
end

-- Which level Spyro is in. Neighbouring levels keep a visible LS###_Transport sublevel (a homeworld has
-- several), so "the first visible LS### level" picks the wrong one; each level instance is placed by its
-- LevelTransform, so the level Spyro is actually in is the one he is nearest.
local function currentLevel(pawn)
    local best, bestDist
    tryCall("World.StreamingLevels", function()
        local loc = pawn:K2_GetActorLocation()
        eachStreamingLevel(pawn, function(sl, package)
            local prefix = levelParts(package)
            if not prefix then return end
            if tryCall("LevelStreaming:IsLevelVisible", function() return sl:IsLevelVisible() end) == false then return end
            local t = levelTranslation(sl)
            if not t then return end
            local dist = (loc.X - t.X) ^ 2 + (loc.Y - t.Y) ^ 2
            if not bestDist or dist < bestDist then best, bestDist = prefix, dist end
        end)
    end)
    if best then return best end
    return asString(tryCall("GetCurrentLevelName", function()
        return UEHelpers.GetGameplayStatics():GetCurrentLevelName(pawn, true)
    end))
end

local function dumpStreamingLevels(pawn)
    local level = currentLevel(pawn)
    log("streaming levels (current level %s):", tostring(level))
    local count = 0
    eachStreamingLevel(pawn, function(sl, package)
        count = count + 1
        local loaded = tryCall("LevelStreaming:IsLevelLoaded", function() return sl:IsLevelLoaded() end)
        local visible = tryCall("LevelStreaming:IsLevelVisible", function() return sl:IsLevelVisible() end)
        local levelName = tryCall("LevelStreaming.LoadedLevel", function()
            local level = sl.LoadedLevel
            return level:IsValid() and level:GetFullName() or "none"
        end)
        log("  %s loaded=%s visible=%s shouldBeLoaded=%s shouldBeVisible=%s level=%s",
            tostring(package), tostring(loaded), tostring(visible),
            tostring(sl.bShouldBeLoaded), tostring(sl.bShouldBeVisible), tostring(levelName))
    end)
    log("streaming levels: %d", count)
end

local function readSpot()
    local file = io.open(SPOT_FILE, "r")
    if not file then return end
    local line = file:read("l")
    file:close()
    local fields = {}
    for field in (line or ""):gmatch("[^|]+") do table.insert(fields, field) end
    if #fields < 9 then return end
    state.spot = {
        level = fields[1],
        x = tonumber(fields[2]), y = tonumber(fields[3]), z = tonumber(fields[4]),
        pitch = tonumber(fields[5]), yaw = tonumber(fields[6]), roll = tonumber(fields[7]),
        ctrlPitch = tonumber(fields[8]), ctrlYaw = tonumber(fields[9]),
    }
    log("quicksave spot: %s at (%.0f, %.0f, %.0f)", state.spot.level, state.spot.x, state.spot.y, state.spot.z)
end

local function writeSpot()
    local file = io.open(SPOT_FILE, "w")
    if not file then
        log("could not write %s", SPOT_FILE)
        return
    end
    local s = state.spot
    file:write(string.format("%s|%.3f|%.3f|%.3f|%.3f|%.3f|%.3f|%.3f|%.3f\n",
        s.level, s.x, s.y, s.z, s.pitch, s.yaw, s.roll, s.ctrlPitch, s.ctrlYaw))
    file:close()
end

local function saveSpot(pawn, pc, r)
    local level = currentLevel(pawn)
    if not level then
        log("quicksave: the level name is unavailable")
        return
    end
    local rot = pawn:K2_GetActorRotation()
    local ctrl = pc:GetControlRotation()
    state.spot = {
        level = level, x = r.x, y = r.y, z = r.z,
        pitch = rot.Pitch, yaw = rot.Yaw, roll = rot.Roll,
        ctrlPitch = ctrl.Pitch, ctrlYaw = ctrl.Yaw,
    }
    writeSpot()
    log("quicksave: %s at (%.0f, %.0f, %.0f) facing %.0f", level, r.x, r.y, r.z, rot.Yaw)
end

-- Puts Spyro on the saved spot. The caller makes sure its level is the one he is in (B travels first).
local function teleportToSpot(pawn, pc, cmc, what)
    local spot = state.spot
    if not spot then
        log("%s: nothing saved yet (press V to save a spot)", what)
        return false
    end
    -- K2_TeleportTo looks for room at the spot and returns false if it can't find any.
    local placed = pawn:K2_TeleportTo({ X = spot.x, Y = spot.y, Z = spot.z },
        { Pitch = spot.pitch, Yaw = spot.yaw, Roll = spot.roll })
    cmc.Velocity = { X = 0, Y = 0, Z = 0 }
    pc:SetControlRotation({ Pitch = spot.ctrlPitch, Yaw = spot.ctrlYaw, Roll = 0 })
    -- Without this the follow camera flies in from wherever it was; ResetBehind snaps it behind Spyro.
    if not tryCall("FollowCamera:ResetBehind", function() pawn.FollowCamera:ResetBehind(true) return true end) then
        tryCall("FollowCamera:SetCameraYaw", function() pawn.FollowCamera:SetCameraYaw(spot.yaw) return true end)
    end
    log("%s: %s at (%.0f, %.0f, %.0f)%s", what, spot.level, spot.x, spot.y, spot.z,
        placed == false and " (no room there; the engine moved him)" or "")
    return true
end

-- RestartLevel drops to the title screen in this game (tested 2026-09-17), and the persistent level is
-- shared by every level, so L reloads the current level's gameplay sublevels instead: it clears their
-- bShouldBeLoaded/bShouldBeVisible, waits for the engine to stream them out, sets the flags again and
-- waits for them back. Art, lighting, audio and the Transport levels are left alone. Spyro is held in
-- Flying (the ground under him goes away with LS###_design) and teleported to the spot at the end.
local RELOAD_SUFFIXES = { design = true, enemy = true, loot = true, cinematics = true }

local function reloadTargets(pawn, level)
    local targets = {}
    eachStreamingLevel(pawn, function(sl, package)
        local prefix, suffix = levelParts(package)
        if prefix == level and suffix and RELOAD_SUFFIXES[suffix:lower()] then
            table.insert(targets, { streaming = sl, package = package })
        end
    end)
    return targets
end

-- Streamed level instances are placed by LevelTransform; if a reload comes back with a different one,
-- everything in that sublevel (enemies, gems, the floor) lands away from the art levels.
local function logTargets(targets, when)
    for _, t in ipairs(targets) do
        local name = tryCall("LevelStreaming:GetFName", function() return t.streaming:GetFName():ToString() end)
        local translation = tryCall("LevelStreaming.LevelTransform", function()
            local tr = t.streaming.LevelTransform.Translation
            return string.format("(%.1f, %.1f, %.1f)", tr.X, tr.Y, tr.Z)
        end)
        log("  %s %s: instance=%s packageName=%s toLoad=%s transform=%s", when,
            (t.package:match("([^/]+)$")), tostring(name),
            tostring(asString(t.streaming.PackageName)), tostring(asString(t.streaming.PackageNameToLoad)),
            tostring(translation))
    end
end

local function setStreamingWanted(targets, wanted)
    for _, t in ipairs(targets) do
        t.streaming.bShouldBeLoaded = wanted
        t.streaming.bShouldBeVisible = wanted
    end
end

local function streamingAll(targets, read, want)
    for _, t in ipairs(targets) do
        local ok, value = pcall(read, t.streaming)
        if not ok or value ~= want then return false end
    end
    return true
end

-- Travelling between levels goes through the GlobalTransporter actor: QueueStream(LevelStreamingRecord,
-- TransportType, RecordType) -> ConvertStreamData -> the native latent QueueTransport, which loads the
-- level's sublevels, unloads the current ones and moves the player. N dumps the actor (and its level
-- data table rows) so the record's real field names and a level row can be read.
local function dumpTransporter()
    local transporter = FindFirstOf("GlobalTransporter_C")
    if not transporter or not transporter:IsValid() then
        log("transporter: no GlobalTransporter_C found")
        return
    end
    log("transporter: %s", transporter:GetFullName())
    writeCamDump("transporter", dumpObject(transporter))
    local tables = FindAllOf("DataTable") or {}
    for _, dt in ipairs(tables) do
        local ok, name = pcall(function() return dt:GetFullName() end)
        if ok and name:lower():match("level") then log("transporter: data table %s", name) end
    end
end

-- Travelling to another level: GlobalTransporter's StartAtLevelCheckpoint(Start Level, isRestart,
-- transitionType, checkpoint) is the game's own load-a-save path. It reads the level row (LevelMapPath
-- plus the LLxxx sublevel table), builds a record with UnloadCurrentLevels, and calls native StartAtLevel,
-- so lighting, music and game state follow. Rows in Spyro1_StreamData are named like our level keys (LS102).
local STREAM_DATA_TABLE = "/GameplayCommon/LevelMechanics/LevelStreaming/StreamingData/LevelStreams/Spyro1_StreamData.Spyro1_StreamData"
local TRAVEL_TIMEOUT = 30 -- seconds before a travel that never arrives is given up on

-- FindFirstOf can hand back the class default object, which would take the call and do nothing.
local function findTransporter()
    local instances = FindAllOf("GlobalTransporter_C") or {}
    for _, obj in ipairs(instances) do
        local ok, name = pcall(function() return obj:GetFullName() end)
        if ok and obj:IsValid() and not name:match("Default__") then return obj, name end
    end
    return nil
end

local function travelToLevel(level)
    local transporter, transporterName = findTransporter()
    if not transporter then
        log("travel: no GlobalTransporter_C instance found")
        return false
    end
    local streamData = StaticFindObject(STREAM_DATA_TABLE)
    if not streamData or not streamData:IsValid() then
        log("travel: %s not found", STREAM_DATA_TABLE)
        return false
    end
    -- Does the table read back from Lua, and does it have this level's row?
    local rows = tryCall("DataTableFunctionLibrary:GetDataTableRowNames", function()
        local lib = StaticFindObject("/Script/Engine.Default__DataTableFunctionLibrary")
        local out = {}
        lib:GetDataTableRowNames(streamData, out)
        local names = out.OutRowNames or out.RowNames
        local count, found = 0, false
        if names then
            for _, n in ipairs(names) do
                count = count + 1
                if asString(n) == level then found = true end
            end
        end
        return { count = count, found = found, keys = describeOut(out) }
    end)
    log("travel: %s, table rows=%s row %s found=%s", tostring(transporterName),
        rows and tostring(rows.count) or "?", level, rows and tostring(rows.found) or "?")
    local ok, err = pcall(function()
        transporter:StartAtLevelCheckpoint({ DataTable = streamData, RowName = FName(level) }, false, 0, "")
    end)
    if not ok then
        log("travel: StartAtLevelCheckpoint failed: %s", tostring(err))
        return false
    end
    state.travel = { level = level, started = os.clock(), settled = 0 }
    log("travel: loading %s", level)
    return true
end

-- Once the target level is up and Spyro has control, put him on the saved spot.
local function updateTravel(pawn, pc, cmc, r)
    local s = state.travel
    if not s then return end
    if os.clock() - s.started > TRAVEL_TIMEOUT then
        state.travel = nil
        log("travel: %s never loaded (still in %s); StartAtLevelCheckpoint did nothing",
            s.level, tostring(currentLevel(pawn)))
        return
    end
    if currentLevel(pawn) ~= s.level then return end
    s.settled = (r.mode == 1 and not r.rootMotion) and s.settled + r.dt or 0
    if s.settled < RELOAD_SETTLE then return end
    state.travel = nil
    log("travel: arrived in %s after %.1f s", s.level, os.clock() - s.started)
    teleportToSpot(pawn, pc, cmc, "quickload")
end

local function requestReload(pawn, pc)
    local level = currentLevel(pawn)
    local targets = level and reloadTargets(pawn, level) or {}
    if #targets == 0 then
        log("reload: no gameplay sublevels found for %s", tostring(level))
        dumpStreamingLevels(pawn)
        return
    end
    state.reload = { level = level, targets = targets, stage = "unloading", started = os.clock() }
    setStreamingWanted(targets, false)
    local names = {}
    for _, t in ipairs(targets) do table.insert(names, (t.package:match("([^/]+)$"))) end
    log("reload: streaming out %s", table.concat(names, ", "))
    logTargets(targets, "before")
end

-- Runs every frame while a reload is in progress: keeps Spyro up, waits out each streaming stage,
-- and puts him back on the ground at the end.
local function updateReload(pawn, pc, cmc, r)
    local s = state.reload
    if not s then return end
    local elapsed = os.clock() - s.started

    -- LS###_design holds the floor, so keep him flying in place until it is back.
    if r.mode ~= 5 then cmc:SetMovementMode(5, 0) end
    cmc.Velocity = { X = 0, Y = 0, Z = 0 }

    local function finish(what)
        setStreamingWanted(s.targets, true)
        state.reload = nil
        cmc:SetMovementMode(1, 0)
        log("reload: %s after %.1f s", what, elapsed)
        logTargets(s.targets, "after")
        -- Only put him on the spot if it belongs to this level; otherwise leave him where he reloaded.
        if state.spot and state.spot.level == s.level then teleportToSpot(pawn, pc, cmc, "reload") end
    end

    if elapsed > RELOAD_TIMEOUT then
        finish("gave up waiting")
        return
    end
    if s.stage == "unloading" then
        setStreamingWanted(s.targets, false) -- in case the game's own streaming re-enables them
        if streamingAll(s.targets, function(sl) return sl:IsLevelLoaded() end, false) then
            s.stage = "loading"
            setStreamingWanted(s.targets, true)
            log("reload: streamed out after %.1f s; streaming back in", elapsed)
        end
    elseif s.stage == "loading" then
        setStreamingWanted(s.targets, true)
        if streamingAll(s.targets, function(sl) return sl:IsLevelVisible() end, true) then
            s.stage, s.settled = "settling", 0
        end
    else
        s.settled = s.settled + r.dt
        if s.settled >= RELOAD_SETTLE then finish("done") end
    end
end

-- Freed dragon walk-in (Collectable_Dragon): SimpleMoveToLocation walks Spyro to `Walk to Target Point`,
-- Delay 1 s, then while he's < 50 away (3D) StopMovement and the turn montage (after 0.2 s); otherwise it
-- re-checks every 0.25 s. Its Level Sequence plays alongside and later hides and teleports him. One
-- `walkin` line per path following move: timing from the move request, the walk, the wait after arrival,
-- how it ended (turn, teleport, input, timeout), frame hitches, and the sequence position at each step.
local WALKIN_TURN_RATE = 30   -- deg/s of yaw change while standing that counts as the turn starting
local WALKIN_TELEPORT = 50    -- units moved in one frame that count as the cutscene teleport
local WALKIN_TIMEOUT = 5      -- seconds after arrival before giving up on a turn or teleport
local WALKIN_HITCH = 0.05     -- frames longer than this count as hitches

local function pathMoveActive(pc, cmc)
    local request = cmc.RequestedVelocity
    if request.X == 0 and request.Y == 0 and request.Z == 0 then return false end
    local w = state.walkin
    if not (w.component and w.component:IsValid()) then
        w.class = w.class or StaticFindObject("/Script/AIModule.PathFollowingComponent")
        local component = pc:GetComponentByClass(w.class)
        w.component = (component and component:IsValid()) and component or nil
    end
    -- EPathFollowingAction: 0 Error, 1 NoMove (idle), 2 DirectMove, 3 PartialPath, 4 PathToGoal.
    return w.component ~= nil and w.component:GetPathActionType() >= 2
end

-- The Collectable_Dragon running its walk-in (CutsceneActive), nearest to Spyro. FindAllOf scans the object
-- array, so this only runs once per walk-in.
local function findWalkinDragon(r)
    local best, bestDist
    for _, dragon in ipairs(FindAllOf("Collectable_Dragon_C") or {}) do
        if dragon:IsValid() and dragon.CutsceneActive then
            local loc = dragon:K2_GetActorLocation()
            local d = (loc.X - r.x) ^ 2 + (loc.Y - r.y) ^ 2
            if not bestDist or d < bestDist then best, bestDist = dragon, d end
        end
    end
    return best
end

local function walkinTarget(e)
    local target = e.dragon and e.dragon:IsValid() and e.dragon["Walk to Target Point"]
    return (target and target:IsValid()) and target:K2_GetActorLocation() or nil
end

local function walkinSequencePosition(e)
    local ok, pos = pcall(function() return e.dragon.Level_Sequence.SequencePlayer:GetPlaybackPosition() end)
    return ok and type(pos) == "number" and pos or 0 / 0
end

local function finishWalkin(e, endedBy, r)
    local target = e.target
    local function dist(x, y, z)
        if not target or not x then return "n/a", "n/a" end
        return string.format("%.1f", math.sqrt((x - target.X) ^ 2 + (y - target.Y) ^ 2 + (z - target.Z) ^ 2)),
            string.format("%.1f", math.sqrt((x - target.X) ^ 2 + (y - target.Y) ^ 2))
    end
    local start3, start2 = dist(e.startX, e.startY, e.startZ)
    local arrive3, arrive2 = dist(e.arriveX, e.arriveY, e.arriveZ)
    local function since(t) return t and string.format("%.3f", t - e.start) or "n/a" end
    log("walkin %d cap=%s avgFps=%.1f maxDt=%.1fms hitches=%d (%.3fs) dragon=%s startDist=%s (2D %s) moveAt=%s arriveAt=%s walked=%.1f maxSpeed=%.1f stalledFrames=%d reissued=%d arriveDist=%s (2D %s) wait=%s endedBy=%s at=%s seqPos start=%.3f arrive=%.3f end=%.3f",
        state.walkinCount, tostring(state.fpsCap or "?"), e.frames / math.max(e.dtSum, 1e-9), e.maxDt * 1000,
        e.hitches, e.hitchTime, e.dragonName or "?", start3, start2, since(e.moveAt), since(e.arriveAt), e.walked, e.maxSpeed,
        e.stalledFrames, e.restarts or 0, arrive3, arrive2, e.arriveAt and string.format("%.3f", r.time - e.arriveAt) or "n/a",
        endedBy, since(r.time), e.seqStart, e.seqArrive or 0 / 0, walkinSequencePosition(e))
    state.walkinEvent = nil
end

local function updateWalkin(pc, cmc, r, prev)
    local active = pathMoveActive(pc, cmc)
    local e = state.walkinEvent
    local dt = prev and r.time - prev.time or 0
    if not e then
        if not active then return end
        state.walkinCount = state.walkinCount + 1
        e = { start = r.time, startX = r.x, startY = r.y, startZ = r.z, frames = 0, dtSum = 0, maxDt = 0, hitches = 0,
              hitchTime = 0, walked = 0, maxSpeed = 0, stalledFrames = 0 }
        local ok, dragon = pcall(findWalkinDragon, r)
        if ok and dragon then
            e.dragon, e.dragonName = dragon, dragon:GetFName():ToString()
            local okTarget, target = pcall(walkinTarget, e)
            e.target = okTarget and target and { X = target.X, Y = target.Y, Z = target.Z } or nil
        elseif not ok then
            log("walkin dragon lookup error: %s", tostring(dragon))
        end
        e.seqStart = walkinSequencePosition(e)
        state.walkinEvent = e
        log("walkin %d path move started", state.walkinCount)
        return
    end
    e.frames, e.dtSum, e.maxDt = e.frames + 1, e.dtSum + r.dt, math.max(e.maxDt, r.dt)
    if r.dt > WALKIN_HITCH then e.hitches, e.hitchTime = e.hitches + 1, e.hitchTime + r.dt end
    local step = prev and math.sqrt((r.x - prev.x) ^ 2 + (r.y - prev.y) ^ 2 + (r.z - prev.z) ^ 2) or 0
    if step > WALKIN_TELEPORT then return finishWalkin(e, "teleport", r) end
    if active then
        e.walked = e.walked + step
        e.maxSpeed = math.max(e.maxSpeed, r.speed)
        if r.speed > 1 and not e.moveAt then e.moveAt = r.time end
        if active and r.speed == 0 then e.stalledFrames = e.stalledFrames + 1 end
    end
    if active then
        if e.arriveAt then
            -- The Blueprint re-issues the move every 0.25 s while he's still >= 50 away.
            e.arriveAt, e.arriveX, e.seqArrive = nil, nil, nil
            e.restarts = (e.restarts or 0) + 1
        end
        return
    end
    if not e.arriveAt then
        e.arriveAt, e.arriveX, e.arriveY, e.arriveZ = r.time, r.x, r.y, r.z
        e.seqArrive = walkinSequencePosition(e)
        log("walkin %d path move ended after %.3fs", state.walkinCount, r.time - e.start)
        return
    end
    if math.abs(r.accelX) + math.abs(r.accelY) > 1e-3 then return finishWalkin(e, "input", r) end
    if r.speed < 1 and math.abs(r.yawRate) > WALKIN_TURN_RATE then return finishWalkin(e, "turn", r) end
    if r.time - e.arriveAt > WALKIN_TIMEOUT then return finishWalkin(e, "timeout", r) end
end

local function sample()
    registerMouseHook()
    if not state.flame.cdosLogged then
        state.flame.cdosLogged = true
        tryCall("particle module CDO addresses", logParticleModuleAddresses)
    end
    if state.flame.experimentRequested then
        state.flame.experimentRequested = false
        tryCall("flame experiment", function() applyFlameExperiment(false) end)
    end
    -- velocity30 follows the framerate (e.g. after F5/F8).
    local flame = state.flame
    if FLAME_EXPERIMENTS[flame.experiment or 1] == "velocity30" and flame.dtAvg then
        local want = math.max(1, (1 / 30) / flame.dtAvg)
        if math.abs(want - (flame.appliedScale or 1)) > FLAME_VELOCITY_RESCALE * want then
            tryCall("flame experiment", function() applyFlameExperiment(true) end)
        end
    end
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
    -- The first call succeeds on every level without dragons, so log errors here rather than via tryCall.
    local dragonOk, dragonErr = pcall(updateDragons, r.time, prev and r.time - prev.time or 0)
    if not dragonOk and not state.dragon.errorLogged then
        state.dragon.errorLogged = true
        log("fire dragon stats error: %s", tostring(dragonErr))
    end
    -- A new pawn (level load, respawn) may come with new thieves or dragons; look again if their class has loaded.
    local pawnAddress = pawn:GetAddress()
    if pawnAddress ~= state.pawnAddress then
        state.pawnAddress = pawnAddress
        for _, target in ipairs({ state.dragon, state.thief }) do
            if target.classSeen then target.lookups, target.nextLookup = NEW_OBJECT_LOOKUPS, 0 end
        end
        state.flame.scan = true
    end
    local thiefOk, thiefErr = pcall(updateThieves, r, prev)
    if not thiefOk and not state.thief.errorLogged then
        state.thief.errorLogged = true
        log("thief stats error: %s", tostring(thiefErr))
    end
    local flameOk, flameErr = pcall(updateFlames, r, prev and r.time - prev.time or 0)
    if not flameOk and not state.flame.errorLogged then
        state.flame.errorLogged = true
        log("flame stats error: %s", tostring(flameErr))
    end
    local request = state.spotRequest
    state.spotRequest = nil
    local spotOk, spotErr = pcall(function()
        if request == "save" then
            saveSpot(pawn, pc, r)
        elseif request == "load" then
            -- B always goes to the saved spot, travelling to its level first when Spyro is elsewhere.
            local spot = state.spot
            if spot and spot.level ~= currentLevel(pawn) then
                travelToLevel(spot.level)
            else
                teleportToSpot(pawn, pc, cmc, "quickload")
            end
        elseif request == "reload" then
            requestReload(pawn, pc)
        elseif request == "transporter" then
            dumpTransporter()
        end
        updateReload(pawn, pc, cmc, r)
        updateTravel(pawn, pc, cmc, r)
    end)
    if not spotOk then
        state.reload = nil
        log("quicksave error: %s", tostring(spotErr))
    end
    local walkinOk, walkinErr = pcall(updateWalkin, pc, cmc, r, prev)
    if not walkinOk then
        state.walkinEvent = nil
        if not state.walkinErrorLogged then
            state.walkinErrorLogged = true
            log("walkin error: %s", tostring(walkinErr))
        end
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
RegisterKeyBind(Key.F10, function() state.flame.scan = true end)
-- Not F11 (the game toggles fullscreen) and nothing the game's DefaultInput.ini binds.
RegisterKeyBind(Key.V, function() state.spotRequest = "save" end)
RegisterKeyBind(Key.B, function() state.spotRequest = "load" end)
RegisterKeyBind(Key.L, function() state.spotRequest = "reload" end)
RegisterKeyBind(Key.N, function() state.spotRequest = "transporter" end)
RegisterKeyBind(Key.K, function()
    local f = state.flame
    f.experiment = (f.experiment or 1) % #FLAME_EXPERIMENTS + 1
    f.experimentRequested = true
end)

-- Flame breath components may be created at any time; their template is checked from the tick (see updateFlames).
NotifyOnNewObject("/Script/Engine.ParticleSystemComponent", function(object)
    local pending = state.flame.pending
    if #pending < 1000 then table.insert(pending, { component = object, frames = 0 }) end
end)

-- Level Blueprint classes load with their level; look for their instances for a while afterwards.
NotifyOnNewObject("/Script/Engine.BlueprintGeneratedClass", function(object)
    local ok, name = pcall(function() return object:GetFName():ToString() end)
    if not ok then return end
    local target = name == DRAGON_CLASS and state.dragon or THIEF_SPEED_MANAGER_CLASSES[name] and state.thief or nil
    if not target then return end
    target.lookups, target.nextLookup, target.classSeen = NEW_OBJECT_LOOKUPS, 0, true
end)

if not EngineTickAvailable then
    log("EngineTick hook unavailable; per-frame sampling disabled")
    return
end

readSpot()

LoopInGameThreadAfterFrames(1, function()
    local ok, err = pcall(sample)
    if not ok and not state.errorLogged then
        state.errorLogged = true
        log("sample error: %s", tostring(err))
    end
end)

log("loaded; writing %s", tracePath)
