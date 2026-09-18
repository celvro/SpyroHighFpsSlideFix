-- Spyro 1 flight levels (LS105 Sunny, LS111 Night, LS117 Crystal, LS123 Wild Flight): Spyro flies in
-- MovementMode Flying the whole level, driven natively (GA_Spyro_Fly only swaps effects, montages and
-- camera settings; GE_SpyroFlightSpeedControl overrides the MaxFlySpeed attribute).
--
--   "flight" lines      one per second of flying: 3D speed from position (path / time) and from Velocity
--                       (avg, min, max), horizontal speed, vz range, CMC MaxFlySpeed / MaxAcceleration /
--                       BrakingDecelerationFlying, yaw rate, and the share of frames with each input.
--   "flightramp" lines  after MaxFlySpeed jumps (boost, brake; pitch moves it smoothly), how long the
--                       velocity takes to get within RAMP_TOLERANCE of the new value: t50, t90, settle.
--   "flightrun" lines   each stretch of flying in a flight level: duration, path length, average speed.
local levels = require("lib.levels")
local log = require("lib.log")
local state = require("lib.state")
local util = require("lib.util")

local num = util.num

local FLIGHT_LEVELS = { LS105 = true, LS111 = true, LS117 = true, LS123 = true }
local FLYING = 5
local WINDOW = 1.0          -- seconds per "flight" line
local TELEPORT_STEP = 1000  -- a single-frame step longer than this is a respawn/teleport, not flight
local RAMP_JUMP = 20        -- MaxFlySpeed change in one frame that starts a ramp (pitch moves it ~1 a frame)
local RAMP_TOLERANCE = 0.02 -- fraction of the MaxFlySpeed change left when the ramp counts as settled
local RAMP_TIMEOUT = 5      -- seconds before a ramp that never settles is reported anyway
local LEVEL_CHECK = 2.0     -- seconds between level lookups (they walk World.StreamingLevels)

local flight = {}

local level, nextLevelCheck = nil, 0
local window, run, ramp = nil, nil, nil
local runCount, rampCount = 0, 0
local lastMaxFly = nil
local errorLogged = false

local function speed3(r)
    return math.sqrt(r.vx * r.vx + r.vy * r.vy + r.vz * r.vz)
end

local function newWindow(r)
    local w = util.newStats(r)
    w.path, w.vMin, w.vMax, w.vSum, w.hSum, w.vzMin, w.vzMax = 0, math.huge, 0, 0, 0, math.huge, -math.huge
    w.yawAbs, w.charge, w.jump, w.stick, w.teleports = 0, 0, 0, 0, 0
    w.flyMin, w.flyMax = math.huge, -math.huge
    return w
end

local function pct(n, w) return w.frames > 0 and 100 * n / w.frames or 0 end

local function logWindow(w, r, cmc)
    local t = r.time - w.startTime
    if t <= 0 or w.frames == 0 then return end
    log("flight %s cap=%s avgFps=%.1f dt=%.1f-%.1fms t=%.2fs speedPos=%.1f speedVel=%.1f (%.1f-%.1f) hspeed=%.1f vz=%.1f..%.1f maxFly=%.1f (%.1f-%.1f) maxAccel=%.1f brakeFly=%.1f yawRate=%.1f charge=%.0f%% jump=%.0f%% stick=%.0f%% teleports=%d",
        level or "?", tostring(state.fpsCap or "?"), util.avgFps(w), w.dtMin * 1000, w.dtMax * 1000, t,
        w.path / t, w.vSum / w.frames, w.vMin, w.vMax, w.hSum / w.frames, w.vzMin, w.vzMax,
        num(cmc.MaxFlySpeed), w.flyMin, w.flyMax, num(cmc.MaxAcceleration), num(cmc.BrakingDecelerationFlying),
        w.yawAbs / t, pct(w.charge, w), pct(w.jump, w), pct(w.stick, w), w.teleports)
end

local function finishRamp(p, r, how)
    local function at(t) return t and string.format("%.3f", t - p.start) or "n/a" end
    log("flightramp %d cap=%s avgFps=%.1f maxFly %.1f->%.1f speed0=%.1f t50=%s t90=%s settle=%s end=%.1f endedBy=%s",
        p.id, tostring(state.fpsCap or "?"), util.avgFps(p), p.from, p.to, p.speed0, at(p.t50), at(p.t90), at(p.settle),
        speed3(r), how)
    ramp = nil
end

local function updateRamp(r, maxFly)
    if lastMaxFly and math.abs(maxFly - lastMaxFly) > RAMP_JUMP then
        if ramp then finishRamp(ramp, r, "retarget") end
        rampCount = rampCount + 1
        local prev = state.prevRow or r
        ramp = util.newStats(prev)
        ramp.id, ramp.start, ramp.from, ramp.to, ramp.speed0 = rampCount, prev.time, lastMaxFly, maxFly, speed3(prev)
    end
    lastMaxFly = maxFly
    local p = ramp
    if not p then return end
    util.addFrame(p, r)
    local span = p.to - p.speed0
    local done = math.abs(span) > 1e-3 and (speed3(r) - p.speed0) / span or 1
    if not p.t50 and done >= 0.5 then p.t50 = r.time end
    if not p.t90 and done >= 0.9 then p.t90 = r.time end
    if not p.settle and math.abs(speed3(r) - p.to) <= RAMP_TOLERANCE * math.max(math.abs(p.to - p.from), 1) then
        p.settle = r.time
        return finishRamp(p, r, "settled")
    end
    if r.time - p.start > RAMP_TIMEOUT then finishRamp(p, r, "timeout") end
end

local function endRun(r, cmc)
    if window then logWindow(window, r, cmc) end
    if ramp then finishRamp(ramp, r, "stopped") end
    if run then
        local t = r.time - run.startTime
        log("flightrun %d %s cap=%s avgFps=%.1f dur=%.2fs path=%.1f avgSpeed=%.1f teleports=%d",
            run.id, level or "?", tostring(state.fpsCap or "?"), util.avgFps(run), t, run.path,
            t > 0 and run.path / t or 0 / 0, run.teleports)
    end
    window, run, ramp, lastMaxFly = nil, nil, nil, nil
end

local function update(pawn, cmc, r, prev)
    if r.time >= nextLevelCheck then
        nextLevelCheck = r.time + LEVEL_CHECK
        level = levels.current(pawn)
    end
    local active = FLIGHT_LEVELS[level or ""] and r.mode == FLYING
    if not active then
        if run then endRun(prev or r, cmc) end
        return
    end
    if not run then
        runCount = runCount + 1
        run = util.newStats(r)
        run.id, run.path, run.teleports = runCount, 0, 0
        window = newWindow(r)
        return
    end
    local step = prev and math.sqrt((r.x - prev.x) ^ 2 + (r.y - prev.y) ^ 2 + (r.z - prev.z) ^ 2) or 0
    local teleport = step > TELEPORT_STEP
    local w = window
    util.addFrame(w, r)
    util.addFrame(run, r)
    if teleport then
        w.teleports, run.teleports = w.teleports + 1, run.teleports + 1
    else
        w.path, run.path = w.path + step, run.path + step
    end
    local v = speed3(r)
    w.vSum, w.hSum = w.vSum + v, w.hSum + r.speed
    w.vMin, w.vMax = math.min(w.vMin, v), math.max(w.vMax, v)
    w.vzMin, w.vzMax = math.min(w.vzMin, r.vz), math.max(w.vzMax, r.vz)
    if prev then w.yawAbs = w.yawAbs + math.abs(util.angleDiff(r.yaw, prev.yaw)) end
    if r.charging then w.charge = w.charge + 1 end
    if r.pressedJump then w.jump = w.jump + 1 end
    if math.abs(num(r.stickX)) + math.abs(num(r.stickY)) > 0.1 then w.stick = w.stick + 1 end
    local maxFly = num(cmc.MaxFlySpeed)
    w.flyMin, w.flyMax = math.min(w.flyMin, maxFly), math.max(w.flyMax, maxFly)
    updateRamp(r, maxFly)
    if r.time - w.startTime >= WINDOW then
        logWindow(w, r, cmc)
        window = newWindow(r)
    end
end

function flight.update(pawn, cmc, r, prev)
    local ok, err = pcall(update, pawn, cmc, r, prev)
    if not ok then
        window, run, ramp = nil, nil, nil
        if not errorLogged then
            errorLogged = true
            log("flight error: %s", tostring(err))
        end
    end
end

return flight
