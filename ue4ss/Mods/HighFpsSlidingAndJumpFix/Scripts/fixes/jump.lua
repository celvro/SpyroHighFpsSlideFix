-- Jump height fix
--
-- A jump (ground, water, charge) sets Z velocity and applies GE_SpyroJumpNoGravity, which
-- zeroes GravityScale for JumpMaxHoldTime (0.233 s). Measured in traces:
--   * full hold: gravity stays off for the frames until the effect's timer fires, plus one
--     extra frame, i.e. (ceil(H/dt) + 1) frames: 8/30 s at 30 FPS but only 35/144 s at 144 FPS.
--   * early release: gravity stays off for exactly the frames the button was held, so the
--     release is rounded up to the frame grid.
-- The game was tuned at 30 FPS, where both round to 1/30 s steps, so jumps are ~5 units higher
-- there. This keeps GravityScale at 0 after the engine restores it until the zero-gravity rise
-- time matches what 30 FPS would produce. At 30 FPS it never extends anything.

local util = require("lib.util")

local REFERENCE_FPS = util.REFERENCE_FPS
local MOVE_FALLING = util.MOVE_FALLING

local JUMP_VZ_EPSILON = 0.05
local EMULATE_RELEASE_ROUNDING = true -- also round early jump releases up to the 30 FPS grid

local fix = { name = "jump height fix", enabled = true }

local jump = nil -- zero-gravity jump rise being tracked or extended

-- Zero-gravity rise time (seconds) that 30 FPS produces when the no-gravity effect times out.
-- The effect's timer is checked after each frame's move, so the rise lasts ceil(H * 30) frames,
-- plus `lagFrames` when the timer started counting a frame after the jump's first move (usual).
local function referenceTimeoutRise(holdTime, lagFrames)
    return (math.ceil(holdTime * REFERENCE_FPS - 1e-4) + lagFrames) / REFERENCE_FPS
end

-- Zero-gravity rise time that 30 FPS produces for a release at `releaseTime` after takeoff.
local function referenceReleaseRise(releaseTime)
    return math.ceil(releaseTime * REFERENCE_FPS - 1e-4) / REFERENCE_FPS
end

-- Frames of lag between the jump's first move and the no-gravity timer starting (0 or 1), or nil
-- if gravity didn't come back when a JumpMaxHoldTime-long timer would have fired.
local function timeoutLagFrames(j, holdTime, dt)
    for lag = 1, 0, -1 do
        local elapsed = j.rise - (lag == 1 and j.firstDt or 0)
        if elapsed >= holdTime - 1e-4 and elapsed - dt < holdTime - 1e-4 then return lag end
    end
    return nil
end

-- Gives gravity back without touching velocity (used when something else interrupts the rise).
local function abandonJump(cmc)
    if jump and jump.extending and cmc.GravityScale == 0 then
        cmc.GravityScale = jump.restoreGravity
    end
    jump = nil
end

-- Ends a rise that reached its 30 FPS target. The rise can only end on a frame boundary, so the
-- leftover time is folded into the upward speed to give exactly the 30 FPS apex height:
-- vz'^2 = vz^2 + 2 * g * jumpVz * leftover.
local function finishJump(cmc)
    local j = jump
    abandonJump(cmc)
    local leftover = j.target - j.rise
    if math.abs(leftover) < 1e-5 then return end
    local g = -cmc:GetGravityZ()
    local vel = cmc.Velocity
    local vz2 = vel.Z * vel.Z + 2 * g * j.vz * leftover
    if g <= 0 or vel.Z <= 0 or vz2 <= 0 then return end
    cmc.Velocity = { X = vel.X, Y = vel.Y, Z = math.sqrt(vz2) }
end

-- Runs before each world tick, so the values read describe the frame that just finished and any
-- GravityScale written here applies to the next frame's move.
function fix.update(ctx)
    local mode = ctx.mode
    if not jump and mode ~= MOVE_FALLING then return end
    local pawn, cmc, dt, vel = ctx.pawn, ctx.cmc, ctx.dt, ctx.vel
    local vz = vel.Z
    local gravity = cmc.GravityScale

    if jump and jump.extending then
        -- The last frame moved under our zero-gravity override. Hand control back if anything else
        -- took over: landing, gliding, another effect changing gravity, or velocity changing.
        if mode ~= MOVE_FALLING or gravity ~= 0 or math.abs(vz - jump.vz) > JUMP_VZ_EPSILON then
            abandonJump(cmc)
            return
        end
        jump.rise = jump.rise + dt
        if jump.rise + dt * 0.5 >= jump.target then finishJump(cmc) end
        return
    end

    if not jump then
        if mode == MOVE_FALLING and gravity == 0 and vz > 0 then
            -- First frame of a zero-gravity rise: it already moved at full jump speed.
            jump = { vz = vz, rise = dt, firstDt = dt }
        end
        return
    end

    if mode ~= MOVE_FALLING then jump = nil return end

    local released = math.abs(vz - jump.vz) > JUMP_VZ_EPSILON
    if released then
        -- Gravity was already back for this frame's move: the jump button was released.
        if gravity == 0 or not EMULATE_RELEASE_ROUNDING then jump = nil return end
        jump.target = referenceReleaseRise(jump.rise - dt * 0.5)
    else
        jump.rise = jump.rise + dt
        if gravity == 0 then return end
        -- Gravity came back after a full-speed frame: the no-gravity effect timed out.
        local holdTime = pawn.JumpMaxHoldTime
        local lag = type(holdTime) == "number" and timeoutLagFrames(jump, holdTime, dt) or nil
        if not lag then jump = nil return end -- some other effect; leave it alone
        jump.target = referenceTimeoutRise(holdTime, lag)
    end

    if jump.rise + dt * 0.5 >= jump.target then
        -- Already on the right frame count; only the apex residual needs correcting.
        finishJump(cmc)
        return
    end

    jump.extending = true
    jump.restoreGravity = gravity
    cmc.GravityScale = 0
    if released then
        cmc.Velocity = { X = vel.X, Y = vel.Y, Z = jump.vz }
    end
end

function fix.reset()
    jump = nil
end

-- Never leave a rise we extended with gravity switched off.
function fix.disable(ctx)
    abandonJump(ctx.cmc)
end

return fix
