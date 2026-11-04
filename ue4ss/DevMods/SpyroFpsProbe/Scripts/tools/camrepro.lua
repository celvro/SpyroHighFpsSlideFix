-- Stuck charge camera repro (R), restored on 2026-10-11 from commit ca9757f, where it lived in the
-- probe's main.lua before the split into modules. It is the controlled A/B that verified
-- FIX_STUCK_CAMERA (see docs/findings/charge-turn-camera.md): the stuck state depends on the camera
-- gap when centering starts, and setting that by hand is the only way to compare runs. Measuring it
-- in free play instead produced a wrong conclusion on 2026-10-10.
--
-- Native centering latches scale = min(|gap| / 90, 1) on the first centering frame of an episode
-- (exe 0x141EF6654, gated by the byte at +0xAA5) and never re-latches it, so if Spyro then turns away
-- faster than scale * 180 deg/s the gap grows and the camera crawls.
--
-- R cycles through the PRESETS below, logging which is armed and what the next press arms; a press
-- while one is armed cancels it. Two things vary:
--
--   rate  130.8 deg/s is full stick lock during a charge. The player's own runs steer by mouse and
--         reach ~210, which is harsher, and is what the 2026-10-10 complaint was about.
--   mode  "cold"    - hold Spyro `gap` degrees right of the camera, then turn once the charge starts.
--                     Centering starts fresh, so the latch sees exactly `gap`.
--         "restart" - turn through a first charge to build a trail, then wait for the player to stop
--                     and immediately re-charge, and turn again. The point is that centering may still
--                     be mid-episode when the second charge starts, in which case +0xAA5 is still set
--                     and the latch is skipped entirely, carrying the *previous* episode's scale over.
--                     That is a different state from a cold charge at the same gap, and it is the case
--                     the player reports as still broken. The gap at the restart is measured, not set.
--
-- **Press charge without touching the stick**, so the only rotation is the tool's.
-- Needs the camera tracker's row reads (ROW_CAMERA) for camYaw/camRate.
--
--   "camrepro" lines  the arm, the gap at each charge start, the gap at a restart, and on finish the
--                     gap and camera rate reached. Judge a run by the gap and camera rate at the end:
--                     `camlock` k50 is n/a here because the charge ends with the turn, before the lock
--                     can close half the gap.
local log = require("lib.log")
local util = require("lib.util")

local angleDiff = util.angleDiff

local STICK_RATE = 130.8    -- deg/s, full stick lock during a charge
local MOUSE_RATE = 210      -- deg/s, what mouse steering reaches (measured 2026-10-10)
local TURN_TIME = 3         -- seconds to keep turning once the charge starts
local FIRST_TURN_TIME = 1.5 -- "restart" mode: seconds of the first charge, to build a trail
local ARMED_TIMEOUT = 10    -- seconds to wait for the charge before giving up
local RESTART_WINDOW = 8    -- "restart" mode: seconds to wait for the stop-and-re-charge. Was 3 on
                            -- 2026-10-11 and both attempts were cancelled before the re-charge: with
                            -- one key, R is also cancel, so the window has to be long enough to stop
                            -- and press charge again without reaching for anything else.

-- The restart preset is first because it is the open question; the four cold cells below it are
-- measured (docs/findings/charge-turn-camera.md) and only need re-running to compare against a change.
local PRESETS = {
    { gap = nil, rate = MOUSE_RATE, mode = "restart", label = "stop and restart, mouse rate" },
    { gap = 12,  rate = STICK_RATE, mode = "cold",    label = "12 deg, stick rate" },
    { gap = 33,  rate = STICK_RATE, mode = "cold",    label = "33 deg, stick rate" },
    { gap = 12,  rate = MOUSE_RATE, mode = "cold",    label = "12 deg, mouse rate" },
    { gap = 33,  rate = MOUSE_RATE, mode = "cold",    label = "33 deg, mouse rate" },
}

local camrepro = {}

-- { preset, phase = "armed"|"first"|"waiting"|"turning", t, released }
local run = nil
local nextPreset = 1

function camrepro.arm()
    if run then
        run = nil
        log("camrepro cancelled")
        return
    end
    local p = PRESETS[nextPreset]
    nextPreset = nextPreset % #PRESETS + 1
    run = { preset = p, phase = "armed", t = 0 }
    log("camrepro armed: %s (%s mode, %.1f deg/s%s); press charge (no stick) within %d s. Next press arms: %s.",
        p.label, p.mode, p.rate, p.gap and string.format(", gap %.0f deg right of the camera", p.gap) or "",
        ARMED_TIMEOUT, PRESETS[nextPreset].label)
end

local function setYaw(pawn, yaw)
    local rot = pawn:K2_GetActorRotation()
    pawn:K2_SetActorRotation({ Pitch = rot.Pitch, Yaw = yaw, Roll = rot.Roll }, false)
end

local function finish(c, r, why)
    log("camrepro done (%s) after %.2f s: gap %.1f deg, camera rate %.1f deg/s",
        why, c.t, angleDiff(r.yaw, r.camYaw), r.camRate)
    run = nil
end

local function update(pawn, r)
    local c = run
    if not c then return end
    local p = c.preset
    c.t = c.t + r.dt

    if c.phase == "armed" then
        if r.charging then
            c.phase, c.t = p.mode == "restart" and "first" or "turning", 0
            log("camrepro charge started: gap %.1f deg (camera %.1f, Spyro %.1f); turning right at %.1f deg/s%s",
                angleDiff(r.yaw, r.camYaw), r.camYaw, r.yaw, p.rate,
                p.mode == "restart" and string.format(" for %.1f s, then stop and re-charge", FIRST_TURN_TIME) or "")
            return
        end
        if c.t > ARMED_TIMEOUT then
            run = nil
            log("camrepro timed out without a charge")
        elseif p.gap then
            setYaw(pawn, r.camYaw + p.gap) -- hold the exact starting gap until the charge begins
        end
        return
    end

    -- "restart": turn through a first charge, then wait for the player to stop and re-charge.
    if c.phase == "first" then
        if not r.charging then
            c.phase, c.t, c.released = "waiting", 0, true
            log("camrepro first charge ended: gap %.1f deg, camera rate %.1f deg/s. NOW: press charge again (not R, which cancels). %d s",
                angleDiff(r.yaw, r.camYaw), r.camRate, RESTART_WINDOW)
            return
        end
        if c.t >= FIRST_TURN_TIME then
            log("camrepro first turn done: gap %.1f deg, camera rate %.1f deg/s. NOW: let go of charge, then press charge again (not R, which cancels). %d s",
                angleDiff(r.yaw, r.camYaw), r.camRate, RESTART_WINDOW)
            c.phase, c.t = "waiting", 0
            return
        end
        setYaw(pawn, r.yaw + p.rate * r.dt)
        return
    end

    if c.phase == "waiting" then
        if not r.charging then c.released = true end
        if c.released and r.charging then
            -- The gap here is whatever the recentering left, and is the number this mode is for.
            log("camrepro restarted: gap %.1f deg at the second charge, camera rate %.1f deg/s; turning right for %.1f s",
                angleDiff(r.yaw, r.camYaw), r.camRate, TURN_TIME)
            c.phase, c.t = "turning", 0
            return
        end
        if c.t > RESTART_WINDOW then
            finish(c, r, "no restart in time")
        end
        return
    end

    if not r.charging then finish(c, r, "charge ended") return end
    if c.t >= TURN_TIME then finish(c, r, "turn complete") return end
    setYaw(pawn, r.yaw + p.rate * r.dt)
end

-- Guarded: this drives Spyro's rotation, so an error must not leave him being turned every frame.
function camrepro.update(pawn, r)
    if not run then return end
    local ok, err = pcall(update, pawn, r)
    if not ok then
        run = nil
        log("camrepro error: %s", tostring(err))
    end
end

return camrepro
