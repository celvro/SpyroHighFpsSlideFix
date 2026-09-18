-- The follow camera during charges.
--
--   "camlock" lines        how fast the camera swings in behind Spyro after a charge starts or a turn is
--                          released: t50/t90 are the times to close 50%/90% of the starting yaw offset
--                          (interpolated between frames), k50/k90 the matching exponential interp speeds
--                          (ln 2 / t50, ln 10 / t90). Only offsets >= CAM_MIN_OFFSET. Timing starts at the
--                          first frame with the tag, so up to one frame late.
--   "camstuck" lines       a charge where the camera stops catching up (see updateStuck).
--   "camtransition" lines  each camera settings transition (FollowCamera:IsTransitioning() true): its
--                          duration and m_ctrInterp at the start, after CAMTRANSITION_SAMPLES seconds and
--                          at the end, to see how the game blends it (the camera fix skips these).
--   camdump_*.txt          every reflected property of Spyro's FollowCameraComponent (to find where the
--                          active camera settings live). Dumped once while idle, once mid-charge after the
--                          camera transition, when a charge camera gets stuck, and on F9. After the charge
--                          and stuck dumps, "camdump diff" lines list what changed.
local dump = require("lib.dump")
local log = require("lib.log")
local state = require("lib.state")
local util = require("lib.util")

local newStats, addFrame, avgFps, isGrounded = util.newStats, util.addFrame, util.avgFps, util.isGrounded

local STEER_ANY = 0.3             -- |left stick x| above this counts as steering (ends a camlock)
local CAM_MIN_OFFSET = 10         -- degrees; smaller camera offsets don't start a camlock
local CAMTRANSITION_SAMPLES = { 0.05, 0.1, 0.25, 0.5, 1.0, 1.5, 2.0 }
local CAMDUMP_CHARGE_DELAY = 0.75 -- seconds into a charge before its camera dump (and not transitioning)

local CAMSTUCK_MIN_OFFSET = 45    -- degrees the camera must trail Spyro to count as stuck
local CAMSTUCK_GROWTH = 5         -- degrees the gap must grow over CAMSTUCK_WINDOW
local CAMSTUCK_WINDOW = 1.0       -- seconds
local CAMSTUCK_MAX_RATE = 170     -- deg/s; at the 180 deg/s centering cap the camera is working, just outpaced
local CAMSTUCK_NOLOCK_OFFSET = 20 -- degrees off Spyro's back, without steering, that should close
local CAMSTUCK_NOLOCK_KEEP = 0.7  -- "noLock" if more than this fraction of the gap is left after CAMSTUCK_WINDOW
local CAMSTUCK_NOLOCK_MAX_YAW_RATE = 30 -- deg/s; Spyro turning faster than this counts as steering
local CAMSTUCK_MAX_DUMPS = 3      -- "stuck" camdumps per session

local camera = {}

-- Dumps are lists of { path, value }.
local camDump = { idle = nil, charge = nil, requested = false, stuckRequested = false, stuckCount = 0 }

function camera.finishLock(endedBy)
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

-- The camera swinging in behind Spyro while he isn't steering. Runs during a charge.
function camera.updateLock(r)
    local c = state.charge
    local l = state.camLock
    if math.abs(r.stickX) > STEER_ANY then
        c.needsLock = true
        if l then camera.finishLock("steer") end
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
    if l.t90 then camera.finishLock("settled") end
end

-- A charge where the camera stops catching up. Seen twice charging up slopes at 144 FPS; once traced:
-- the camera turned at a constant 123.6 deg/s behind a Spyro turning at 130.8 for the rest of the
-- charge. Two detectors (see below): "growing" and "noLock". Detection logs a "camstuck" line and
-- requests a "stuck" camdump (diffed against the normal charge dump); the episode's end logs its duration.
function camera.updateStuck(r)
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
        camDump.stuckRequested = true
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

-- One camera settings transition, from the first frame IsTransitioning() is true until it's false.
function camera.updateTransition(r, prev)
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

-- F9.
function camera.requestDump()
    camDump.requested = true
end

-- Dumps the FollowCameraComponent once while idle, once mid-charge, when a charge camera gets
-- stuck (updateStuck), and on F9.
function camera.updateDump(pawn, r)
    local d = camDump
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

    local ok, entries = pcall(dump.object, pawn.FollowCamera)
    if not ok then
        log("camdump %s failed: %s", label, tostring(entries))
        entries = {}
    else
        dump.write(label, entries)
    end
    if label == "manual" then return end
    if label == "stuck" then
        -- Compare with a normal charge if one was dumped, otherwise with idle.
        local base, baseLabel = d.charge, "charge"
        if not (base and #base > 0) then base, baseLabel = d.idle, "idle" end
        if base and #base > 0 and #entries > 0 then dump.logDiff(base, entries, baseLabel .. " -> stuck") end
        return
    end
    d[label] = entries
    if label == "charge" and #d.idle > 0 and #entries > 0 then dump.logDiff(d.idle, entries, "idle -> charge") end
end

return camera
