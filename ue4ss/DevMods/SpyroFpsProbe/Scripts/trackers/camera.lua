-- The follow camera during charges.
--
--   "camlock" lines        how fast the camera swings in behind Spyro after a charge starts or a turn is
--                          released: t50/t90 are the times to close 50%/90% of the starting yaw offset
--                          (interpolated between frames), k50/k90 the matching exponential interp speeds
--                          (ln 2 / t50, ln 10 / t90). Only offsets >= CAM_MIN_OFFSET. Timing starts at the
--                          first frame with the tag, so up to one frame late.
--   "camstuck" lines       a charge where the camera stops catching up (see updateStuck). A second line
--                          gives the native phase test's terms at the moment of detection.
--   "camphase" lines       each time a charge crosses the native centering phase test (exe 0x141EF670B):
--                          |gap| <= |yawChange this frame * m_ctrDecelAngleTurnModifier| + scale *
--                          m_ctrDecelAngle. Phase A caps the camera at scale * 180 deg/s and is where it
--                          gets stuck; phase B interpolates at m_ctrInterp and recovers. `scale` is
--                          latched once per episode by the game and frozen, so it is reconstructed from
--                          the gap at the charge's start (+0xC20 is not reflected). Edge triggered, so a
--                          charge that stays in one phase logs nothing, and capped per charge.
--   "camtransition" lines  each camera settings transition (FollowCamera:IsTransitioning() true): its
--                          duration and m_ctrInterp at the start, after CAMTRANSITION_SAMPLES seconds and
--                          at the end, to see how the game blends it (the camera fix skips these).
--   camdump_*.txt          every reflected property of Spyro's FollowCameraComponent (to find where the
--                          active camera settings live). Dumped once while idle, once mid-charge after the
--                          camera transition, when a charge camera gets stuck, and on F9. After the charge
--                          and stuck dumps, "camdump diff" lines list what changed.
local dump = require("lib.dump")
local levels = require("lib.levels")
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
local CAMSTUCK_MAX_DUMPS = 12     -- "stuck" camdumps per session (3 was spent in one world on
                                  -- 2026-10-10, before the run reached the next game)
local CAMPHASE_MAX_LINES = 20     -- "camphase" lines per charge, in case the phase oscillates
local CTR_SCALE_DIVISOR = 90      -- the native latch is min(|gap| / 90, 1), exe 0x141EF6647

local camera = {}

-- Dumps are lists of { path, value }.
local camDump = { idle = nil, charge = nil, requested = false, stuckRequested = false, stuckCount = 0 }

-- The level Spyro is in (LS101 = Spyro 1, LS2xx = 2, LS3xx = 3), so a `camstuck` line says which game
-- it came from: positions alone can't name a level, several sit near +/-300000. `levels.current` walks
-- every streaming level, so it is read once a second from updateDump (which already has the pawn) and
-- cached here rather than put in the per-frame row. A level change is logged as it happens.
local LEVEL_INTERVAL = 1.0
local level = { name = nil, checkedAt = nil }

-- The native centering phase test, rebuilt from the disassembly (see docs/findings/charge-turn-camera.md).
-- Each frame the game stays in phase A (camera capped at scale * 180 deg/s) unless
--     |gap| <= |yawChangeThisFrame * m_ctrDecelAngleTurnModifier| + scale * m_ctrDecelAngle
-- (exe 0x141EF670B). `scale` is latched once per centering episode from the gap at its start
-- (0x141EF6654, gated by the byte at +0xAA5) and then frozen, so it is reconstructed here from the
-- gap at the charge's start rather than read: +0xC20 is not a reflected property.
-- The two properties are read per charging frame because the centering switch fix rewrites the
-- modifier every frame from dt, so a cached value would not be the one the game just used.
local camComp = nil -- Spyro's FollowCameraComponent, cached by updateDump (which has the pawn)

-- Built once: a closure per charging frame would be garbage the collector has to sweep up.
local function readDecelProps()
    return camComp.m_ctrDecelAngle, camComp.m_ctrDecelAngleTurnModifier
end

local function phase(r, c)
    if not camComp then return nil end
    local ok, decelAngle, modifier = pcall(readDecelProps)
    if not ok or not decelAngle or not modifier then return nil end
    -- Frozen at the charge's first frame, the closest proxy we have for the centering episode's start.
    local scale = math.min(math.abs(c.camOffset0 or 0) / CTR_SCALE_DIVISOR, 1)
    local turnTerm = math.abs(r.yawRate * r.dt) * modifier
    local angleTerm = scale * decelAngle
    local threshold = turnTerm + angleTerm
    return {
        threshold = threshold, turnTerm = turnTerm, angleTerm = angleTerm,
        scale = scale, modifier = modifier, decelAngle = decelAngle,
        -- true = the game should be in phase B (FInterpTo at m_ctrInterp), i.e. not stuck
        phaseB = math.abs(r.camOffset) <= threshold,
    }
end

-- Logs only when the phase flips, so a charge that sits in one phase costs nothing in the log.
local function updatePhase(r, c)
    local p = phase(r, c)
    if not p then return end
    if c.phaseB == nil then c.phaseB, c.phaseLines = p.phaseB, 0 end
    if p.phaseB == c.phaseB then return end
    c.phaseB = p.phaseB
    if c.phaseLines >= CAMPHASE_MAX_LINES then return end
    c.phaseLines = c.phaseLines + 1
    log("camphase %d -> %s level=%s cap=%s t=%.2fs into charge: gap %.1f vs threshold %.1f "
        .. "(turn %.1f = |%.1f deg/frame| * %.2f, angle %.1f = scale %.3f * %.1f) "
        .. "yawRate=%.1f camRate=%.1f dt=%.2fms transitioning=%s",
        c.id, p.phaseB and "B (interp, should recover)" or "A (capped at scale*180 = "
            .. string.format("%.0f deg/s)", p.scale * 180),
        tostring(level.name or "?"), tostring(state.fpsCap or "?"), r.time - c.startTime,
        math.abs(r.camOffset), p.threshold,
        p.turnTerm, r.yawRate * r.dt, p.modifier, p.angleTerm, p.scale, p.decelAngle,
        r.yawRate, r.camRate, r.dt * 1000, tostring(r.camTransitioning))
end

local function updateLevel(pawn, r)
    if level.checkedAt and r.time - level.checkedAt < LEVEL_INTERVAL then return end
    level.checkedAt = r.time
    local ok, name = pcall(levels.current, pawn)
    if not ok or not name then return end
    if name ~= level.name then
        log("camlevel %s (was %s)", tostring(name), tostring(level.name))
        level.name = name
        state.level = name
    end
end

function camera.finishLock(endedBy)
    local l = state.camLock
    state.camLock = nil
    if not l then return end
    local function seconds(t) return t and string.format("%.3fs", t) or "n/a" end
    local function speed(logRatio, t) return t and t > 0 and string.format("%.2f", logRatio / t) or "n/a" end
    log("camlock %s cause=%s level=%s cap=%s avgFps=%.1f offset0=%.1f t50=%s t90=%s k50=%s k90=%s camRateMax=%.0f ctrInterp=%.3f endedBy=%s",
        l.id, l.cause, tostring(level.name or "?"), tostring(state.fpsCap or "?"), avgFps(l), l.offset0, seconds(l.t50), seconds(l.t90),
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
    updatePhase(r, c) -- before the early return: the phase matters most while an episode is running
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
        local p = phase(r, c)
        if p then
            log("camstuck %d.%d phase=%s gap %.1f vs threshold %.1f (turn %.1f, angle %.1f = scale %.3f * %.1f, "
                .. "modifier %.2f) scale*180=%.0f deg/s against yawRate %.1f",
                c.id, s.count, p.phaseB and "B" or "A", offset, p.threshold, p.turnTerm, p.angleTerm,
                p.scale, p.decelAngle, p.modifier, p.scale * 180, r.yawRate)
        end
        log("camstuck %d.%d kind=%s level=%s cap=%s dt=%.2fms t=%.2fs into charge: offset %.1f -> %.1f in %.2fs camRate=%.1f spyroYawRate=%.1f ctrInterp=%.3f transitioning=%s pos=(%.0f, %.0f, %.1f) floorNz=%.4f stick=(%.2f, %.2f) mouse=%.3f",
            c.id, s.count, kind, tostring(level.name or "?"), tostring(state.fpsCap or "?"), r.dt * 1000, r.time - c.startTime, refOffset, offset, r.time - refTime,
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
    updateLevel(pawn, r)
    -- Cached for phase(): updateStuck runs from the charge tracker and has no pawn. Re-read each
    -- frame because the component is replaced with the pawn on a level load or respawn.
    local okCam, comp = pcall(function() return pawn.FollowCamera end)
    camComp = (okCam and comp and comp:IsValid()) and comp or nil
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
