-- Airborne segments, drifts and zero-gravity rises.
--
--   "seg" lines    each airborne segment, from leaving the ground until landing. Segments that start
--                  during a super charge add a "seg N supercharge" line with the stage, takeoff speed,
--                  jump attributes and a gravity scale profile.
--   "drift" lines  grounded, no movement input, but horizontal speed above DRIFT_SPEED (the
--                  high-framerate sliding bug). ~0.15-0.2 s is a normal stop; multi-second drifts are the bug.
--   "rise" lines   every zero-gravity rise (the phase the jump height fix changes), with what it launched
--                  from: ground, water, glide-hover (a hover at the end of a glide) or air. apex is
--                  measured from the launch frame.
local log = require("lib.log")
local state = require("lib.state")
local trace = require("lib.trace")
local util = require("lib.util")

local num, newStats, addFrame, MOVE_MODE_NAMES = util.num, util.newStats, util.addFrame, util.MOVE_MODE_NAMES

local DRIFT_SPEED = 5          -- cm/s of horizontal speed that counts as drifting
local DRIFT_MIN_FRAMES = 5     -- shorter runs are not reported
local GLIDE_SINK_SPEED = -50   -- average vz below this while Flying means gliding, not swimming
local GRAVITY_PROFILE_MAX = 8  -- gravity scale runs listed per super charge airborne segment

local movement = {}

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
        trace.flush()
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
            trace.flush()
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

function movement.update(r, grounded)
    updateDrift(r, grounded)
    updateSegment(r, grounded)
    updateRise(r)
end

return movement
