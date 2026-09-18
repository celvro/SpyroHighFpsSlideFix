-- Camera centering fix
--
-- The follow camera swings in behind Spyro with FInterpTo at speed m_ctrInterp (5 normally,
-- 3.5 while charging), moving min(speed * dt, 1) of the remaining yaw each frame. Behind a
-- steadily turning Spyro it trails w * dt * (1 - f) / f with f = speed * dt: 33.0 deg at 30 FPS
-- but 36.5 at 144 during a full-lock charge turn, and it recenters ~5% slower. This raises
-- m_ctrInterp so the steady trail matches 30 FPS (3.5 -> 3.86, 5 -> 5.76 at 144 FPS), leaving
-- it alone while a camera settings transition is blending it. At 30 FPS or lower it changes nothing.
--
-- Camera centering switch and stuck camera fixes
--
-- Native FollowCameraComponent centering (exe VA 0x141EF6515-0x141EF6853) runs in two phases each
-- time centering starts. First it latches scale = min(|gap| / 90, 1) and turns the camera by
-- scale * (180 deg/s * dt * sign(gap) + Spyro's yaw change this frame). Once |gap| <= |Spyro's yaw
-- change this frame| * m_ctrDecelAngleTurnModifier (5) + scale * m_ctrDecelAngle (20), it blends
-- into FInterpTo at m_ctrInterp until centering stops.
--   * switch: the turn term uses the per-frame yaw change, so in a full-lock turn it is 21.8 deg at
--     30 FPS but 4.5 at 144 FPS. This scales m_ctrDecelAngleTurnModifier by (1/30) / dt so the
--     switch happens at the same gap as at 30 FPS. At 30 FPS or lower it changes nothing.
--   * stuck camera (at any framerate): if centering starts with a small gap, the latched speed is
--     tiny (5.4 deg -> 11 deg/s), and if Spyro turns away faster than that the gap grows and never
--     gets under the threshold; the camera crawls until the gap wraps through 0 (Spyro turns a full
--     circle) or centering stops. When the gap has grown GROWTH deg since its minimum, this sets
--     the turn modifier very high for one frame, which passes the check while Spyro is turning.
--     The property is only read by that check, so the override does nothing while centering is
--     off or already interpolating. This one also changes 30 FPS.

local config = require("config")
local log = require("lib.log")
local spyro = require("lib.spyro")
local util = require("lib.util")

local STUCK_CAMERA_GROWTH = 8    -- gap growth (deg) since its minimum that counts as the camera falling behind
local STUCK_CAMERA_RELEASE = 1e6 -- turn modifier that passes the centering switch check whenever Spyro turns
local STUCK_CAMERA_LOG_GAP = 45  -- log releases while charging at gaps of at least this (deg; a full-lock trail is 33); nil to stop logging
local DEFAULT_TURN_MODIFIER = 5  -- m_ctrDecelAngleTurnModifier, if the first value we see is our own override

-- { address, base, written }: the FollowCameraComponent, its m_ctrInterp without our override
-- (nil while a transition blends it), and the value we wrote.
local camera = nil
-- { address, base, written, minGap }: the FollowCameraComponent, its m_ctrDecelAngleTurnModifier
-- without our changes, the value we wrote, and the smallest camera gap since the last release.
local switch = nil

local centeringFix = { name = "camera centering fix", enabled = config.FIX_CAMERA_CENTERING }
local switchFix = {
    name = "camera centering switch and stuck camera fixes",
    enabled = config.FIX_CAMERA_CENTERING_SWITCH or config.FIX_STUCK_CAMERA,
}

-- FInterpTo speed that leaves the same steady lag behind a steadily moving target at this dt as
-- `speed` does at 30 FPS. Each frame keeps (1 - speed * dt) of the gap, and a target moving at w
-- per second stays w * dt * (1 - f) / f ahead, with f = speed * dt.
local function referenceInterpSpeed(speed, dt)
    if speed <= 0 then return speed end
    local refDt = util.REFERENCE_DT
    local refStep = math.min(speed * refDt, 1)
    local ratio = (1 - refStep) / refStep * refDt / dt -- (1 - f) / f that gives the 30 FPS lag
    return 1 / ((1 + ratio) * dt)
end

-- Runs before each world tick, so m_ctrInterp written here applies to the next frame's camera update.
function centeringFix.update(ctx)
    local component = spyro.followCamera(ctx.pawn)
    if not component then camera = nil return end
    local address = component:GetAddress()
    if camera and camera.address ~= address then camera = nil end -- new pawn or camera
    local current = component.m_ctrInterp

    -- A camera settings push, pop or transition changed the value: find the new base below.
    if camera and camera.written and current ~= camera.written then camera = nil end

    if not util.aboveReferenceFps(ctx.dt) then
        if camera and camera.written then component.m_ctrInterp = camera.base end
        camera = nil
        return
    end
    if not (camera and camera.written) then
        -- Only asked when the value changed under us (or at start), so this is rarely called.
        if component:IsTransitioning() then
            camera = { address = address }
            return
        end
        camera = { address = address, base = current }
    end
    component.m_ctrInterp = referenceInterpSpeed(camera.base, ctx.dt)
    camera.written = component.m_ctrInterp -- read back: the property stores a float
end

function centeringFix.reset()
    camera = nil
end

function centeringFix.disable(ctx)
    if camera and camera.written then
        pcall(function() ctx.pawn.FollowCamera.m_ctrInterp = camera.base end)
    end
    camera = nil
end

-- m_ctrDecelAngleTurnModifier is a component property only (not in FollowCameraSettings), so camera
-- settings pushes, pops and transitions don't blend it; a change we didn't make is a new base.
function switchFix.update(ctx)
    local pawn, dt = ctx.pawn, ctx.dt
    local component = spyro.followCamera(pawn)
    if not component then switch = nil return end
    local address = component:GetAddress()
    if switch and switch.address ~= address then switch = nil end
    local current = component.m_ctrDecelAngleTurnModifier
    if not switch then
        switch = { address = address, base = current < STUCK_CAMERA_RELEASE / 2 and current or DEFAULT_TURN_MODIFIER }
    elseif current ~= switch.written and current < STUCK_CAMERA_RELEASE / 2 then
        switch.base = current
    end

    local value = switch.base
    if config.FIX_CAMERA_CENTERING_SWITCH and util.aboveReferenceFps(dt) then
        value = switch.base / (util.REFERENCE_FPS * dt)
    end
    if config.FIX_STUCK_CAMERA then
        local gap = math.abs(util.wrapDegrees(pawn:K2_GetActorRotation().Yaw - ctx.pc:GetControlRotation().Yaw))
        if not switch.minGap or gap < switch.minGap then switch.minGap = gap end
        if gap - switch.minGap >= STUCK_CAMERA_GROWTH then
            value = STUCK_CAMERA_RELEASE
            -- Most releases happen while centering is off or already interpolating and do nothing;
            -- only log the ones that look like a stuck charge camera.
            if STUCK_CAMERA_LOG_GAP and gap >= STUCK_CAMERA_LOG_GAP then
                local chargeOk, charging = pcall(spyro.isCharging, pawn)
                if chargeOk and charging then
                    log("stuck camera release: gap %.1f deg, grew from %.1f", gap, switch.minGap)
                end
            end
            switch.minGap = gap
        end
    end
    if value ~= current then component.m_ctrDecelAngleTurnModifier = value end
    switch.written = component.m_ctrDecelAngleTurnModifier -- read back: the property stores a float
end

function switchFix.reset()
    switch = nil
end

function switchFix.disable(ctx)
    if switch and switch.written then
        pcall(function() ctx.pawn.FollowCamera.m_ctrDecelAngleTurnModifier = switch.base end)
    end
    switch = nil
end

return { centering = centeringFix, switch = switchFix }
