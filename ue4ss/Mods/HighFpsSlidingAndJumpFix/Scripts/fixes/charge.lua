-- Charge turn slip fix
--
-- While charging, Spyro's facing turns at a framerate-independent rate (131 deg/s at full lock).
-- Each walking frame, CalcVelocity pulls velocity towards the facing by GroundFriction * dt of the
-- angle, and adding MaxAcceleration * dt along the facing closes a bit more. Velocity keeps
-- R = (1 - friction * dt) / (1 + accel * dt / speed) of its lag per frame, so a steady turn
-- leaves it w * dt * R / (1 - R) behind the facing. That is 9.4 deg at 30 FPS but 12.1 at
-- 144 FPS, so Spyro looks like he turns wider. While charging on the ground this raises
-- GroundFriction until that steady lag matches 30 FPS (friction 8 -> 10.7 at 144 FPS).
-- At 30 FPS or lower it changes nothing.
--
-- Mouse charge steering fix
--
-- With keyboard and mouse, the charge steers from the mouse X axis, which is the mouse movement
-- of that frame (CharacterInputComponent_Spyro.GetChargeMovementValueOnPC). Each frame turns
-- 6 * atan(min(0.5 * mouse, 1) * 0.7) deg/s, so the same hand movement split over 4.8x more
-- frames turns Spyro far less at 144 FPS. While charging (or charge jumping) with the mouse,
-- this replaces the stored axis value with the mouse movement of the last 1/30 s, which is
-- what 30 FPS sees. Mouse camera look doesn't use this value and is unaffected.
-- At 30 FPS or lower it changes nothing.

local config = require("config")
local engine = require("lib.engine")
local log = require("lib.log")
local lookup = require("lib.lookup")
local spyro = require("lib.spyro")
local util = require("lib.util")

local REFERENCE_FPS = util.REFERENCE_FPS
local MOVE_WALKING = util.MOVE_WALKING
local MOVE_FALLING = util.MOVE_FALLING

local CHARGE_MIN_WALK_SPEED = 350 -- charging sets MaxWalkSpeed 458.5, charge jumping 358; running is 268.5
local CHARGE_MIN_SPEED = 50       -- slower than this, acceleration dominates the turn; leave friction alone
local MOUSE_AXIS_FUNCTION = "/CharacterCommon/Components/CharacterInputComponent/CharacterInputComponent_Spyro.CharacterInputComponent_Spyro_C:InputAxis_RightStick_X"
local MOUSE_HISTORY = 64          -- mouse samples kept; must cover 1/30 s at the highest framerate

local fix = {
    name = "charge fixes",
    enabled = config.FIX_CHARGE_TURN_SLIP or config.FIX_MOUSE_CHARGE_STEERING,
}

local slip = nil -- { base, written }: GroundFriction without our override, and the value we wrote
local mouse = {
    values = {}, dts = {}, head = 0, count = 0, -- ring buffer of per-frame mouse X samples
    frame = -1,        -- engine.frame of the newest sample
    active = false,    -- replace the axis value this frame (charging with mouse steering)
    component = nil,   -- CharacterInputComponent_Spyro seen by the hook
    registered = false, failed = false, retryIn = 0, lookups = 1,
}
local chargeQueryErrorLogged = false

-- GroundFriction that leaves velocity the same steady angle behind a steadily turning facing at
-- this dt as `friction` does at 30 FPS. Per frame velocity keeps R = keepFriction * keepAccel of
-- that angle, and a facing turning at w per second leaves it w * dt * R / (1 - R) behind.
local function referenceFriction(friction, accel, speed, dt)
    local refDt = util.REFERENCE_DT
    local keepRef = (1 - math.min(friction * refDt, 1)) / (1 + accel * refDt / speed)
    local ratio = keepRef / (1 - keepRef) * refDt / dt -- R / (1 - R) that gives the 30 FPS lag
    local keep = ratio / (1 + ratio)
    return (1 - keep * (1 + accel * dt / speed)) / dt
end

-- Runs before each world tick, so a GroundFriction written here applies to the next frame's move;
-- that frame is assumed to be as long as the one that just finished.
local function fixChargeTurnSlip(cmc, dt, vel, charging)
    local speed = charging and math.sqrt(vel.X * vel.X + vel.Y * vel.Y) or 0
    charging = charging and speed >= CHARGE_MIN_SPEED
    if not charging and not slip then return end

    -- Something else wrote GroundFriction (an effect changing the attribute): that is the new base.
    if slip and cmc.GroundFriction ~= slip.written then slip = nil end
    if not charging then
        if slip then cmc.GroundFriction = slip.base end
        slip = nil
        return
    end
    local base = slip and slip.base or cmc.GroundFriction
    cmc.GroundFriction = math.max(base, referenceFriction(base, cmc.MaxAcceleration, speed, dt))
    slip = slip or { base = base }
    slip.written = cmc.GroundFriction -- read back: the property stores a float
end

-- Mouse X movement over the last 1/30 s, from the per-frame samples (the oldest frame in the
-- window counts in proportion to how much of it falls inside).
local function mouseReferenceValue()
    local window = util.REFERENCE_DT
    local sum, covered = 0, 0
    for i = 0, mouse.count - 1 do
        local index = (mouse.head - i - 1) % MOUSE_HISTORY + 1
        local dt = mouse.dts[index]
        if covered + dt >= window then
            return sum + mouse.values[index] * (window - covered) / dt
        end
        sum, covered = sum + mouse.values[index], covered + dt
    end
    return sum
end

-- Hooked around InputAxis_RightStick_X, where the Blueprint stores the axis value for this frame.
-- It takes one raw sample per frame and, while mouse steering a charge, replaces the stored value.
local function onMouseAxis(context, axisValue)
    local raw = axisValue:get()
    if mouse.frame ~= engine.frame then
        mouse.frame = engine.frame
        mouse.head = mouse.head % MOUSE_HISTORY + 1
        mouse.values[mouse.head], mouse.dts[mouse.head] = raw, engine.dt
        mouse.count = math.min(mouse.count + 1, MOUSE_HISTORY)
        mouse.component = context:get()
    end
    if not mouse.active then return end
    local component = context:get()
    -- Only after the Blueprint stored this frame's value (it skips that while right-stick input is disabled).
    if component.InputAxisRightStickX == raw then
        component.InputAxisRightStickX = mouseReferenceValue()
    end
end

-- A hook error would repeat every frame, so the first one turns the mouse fix off (the slip fix,
-- which doesn't depend on the hook, keeps running).
local function onMouseAxisGuarded(context, axisValue)
    if mouse.failed then return end
    local ok, err = pcall(onMouseAxis, context, axisValue)
    if not ok then
        mouse.failed = true
        mouse.active = false
        log("mouse charge steering fix disabled after hook error: %s", tostring(err))
    end
end

local function registerMouseHook()
    -- Registered as both the pre and the post callback: whichever runs after the Blueprint stored
    -- the value replaces it (onMouseAxis checks the stored value first).
    lookup.registerBlueprintHook(mouse, MOUSE_AXIS_FUNCTION, onMouseAxisGuarded, onMouseAxisGuarded, "mouse charge steering")
end

-- CharacterInputComponent_Spyro.IsKeyboardMouseAndUsingMouseCheckingXAxis, the same test the
-- Blueprint uses to steer the charge with the mouse: keyboard/mouse input, mouse steering enabled
-- in the settings, and no keyboard steering this frame.
local function usingMouseSteering()
    local component = mouse.component
    if mouse.failed or not (component and component:IsValid()) then return false end
    local ok, result = pcall(function()
        local out = {}
        local ret = component:IsKeyboardMouseAndUsingMouseCheckingXAxis(out)
        if type(out["Is Using"]) == "boolean" then return out["Is Using"] end
        if type(ret) == "boolean" then return ret end
        error("IsKeyboardMouseAndUsingMouseCheckingXAxis returned no Is Using value")
    end)
    if ok then return result end
    mouse.failed = true
    log("mouse charge steering fix disabled: %s", tostring(result))
    return false
end

-- Both charge fixes only act above 30 FPS while charging: the slip fix on the ground, mouse
-- steering also during charge jumps (the Blueprint steers those the same way).
function fix.update(ctx)
    if config.FIX_MOUSE_CHARGE_STEERING then registerMouseHook() end

    local cmc, dt, mode = ctx.cmc, ctx.dt, ctx.mode
    local charging = (mode == MOVE_WALKING or mode == MOVE_FALLING) and util.aboveReferenceFps(dt)
        and cmc.MaxWalkSpeed >= CHARGE_MIN_WALK_SPEED
    if charging then
        -- Pawns other than Spyro may not implement IGetIsCharging: treat them as not charging.
        local ok, result = pcall(spyro.isCharging, ctx.pawn)
        if not ok and not chargeQueryErrorLogged then
            chargeQueryErrorLogged = true
            log("IGetIsCharging failed (treated as not charging): %s", tostring(result))
        end
        charging = ok and result
    end
    if config.FIX_CHARGE_TURN_SLIP then
        fixChargeTurnSlip(cmc, dt, ctx.vel, charging and mode == MOVE_WALKING)
    end
    mouse.active = config.FIX_MOUSE_CHARGE_STEERING and charging and usingMouseSteering()
end

function fix.reset()
    slip = nil
    mouse.active = false
end

-- Don't leave friction raised or the mouse axis replaced.
function fix.disable(ctx)
    mouse.active = false
    if slip then pcall(function() ctx.cmc.GroundFriction = slip.base end) end
    slip = nil
end

if config.FIX_MOUSE_CHARGE_STEERING then
    lookup.watch("/Script/Engine.BlueprintGeneratedClass", "CharacterInputComponent_Spyro_C", mouse)
end

return fix
