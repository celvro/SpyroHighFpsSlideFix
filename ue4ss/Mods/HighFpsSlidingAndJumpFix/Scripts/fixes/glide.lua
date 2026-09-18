-- Glide fixes: start timing (FIX_GLIDE_START) and distance (FIX_GLIDE_DISTANCE)
--
-- Glide start. GA_Spyro_Jump only lets a glide start once StartWaitForGlide's AbilityTask_WaitDelay
-- (0.3 s after a jump, 0.85 after a super jump, 0.75/1.5 after a hover) ends. OnGlideRequested (a
-- press) starts the glide at once if WaitForGlideElapsed is set, else sets GlideRequested; the wait's
-- end sets WaitForGlideElapsed and starts the glide if GlideRequested. The wait starts on the jump's
-- first frame, one frame after the jump began moving, and that frame is much longer at 30 FPS: an
-- early-pressed glide starts 0.3333 s after the jump at 30 FPS but ~0.303 s at 320. Spyro is still
-- rising then, so he starts gliding lower: +62.89 at 320 FPS against +67.99 at 30 for a full-hold
-- jump (docs/findings/jump-glide.md). A later press is also rounded up to the 1/30 s grid at 30 FPS.
-- Above 30 FPS this holds both flags off from the wait's start (clearing GlideRequested and
-- WaitForGlideElapsed each update, remembering what the game set), and starts the glide itself by
-- calling OnGlideRequested on the frame 30 FPS would. Moving Spyro up after an early start instead
-- makes a glide rise, which the game takes for a ledge: it cancels the glide into a ledge hover.
--
-- Glide distance. Levels sit ~300,000 units from the world origin, where float32 positions have a
-- 1/32 unit spacing. The glide's Velocity is exact (e.g. 367.74 forward, -114 down), but every
-- frame's move lands on that lattice. At 320 FPS a step of 0.7249 per axis becomes 23 or 24 lattice
-- steps, the same way every frame, so the glide really moves up to (1/32)/2 * 320 = 5 per axis faster
-- or slower than its velocity, depending on heading: measured 363.98 and 370.74 at 320 FPS against
-- 367.6-368.0 at 30. That is -1.0% to +0.7% of the glide distance. At 30 FPS the rounding is 10 times
-- smaller and it's left alone. While gliding above 30 FPS, this adds up the horizontal distance the
-- rounding lost or gained (velocity * dt minus the actual displacement) and, once it reaches half a
-- lattice step on an axis, moves Spyro by the whole steps it amounts to with a swept offset (never
-- up or down). Velocity is never touched, so the glide's own speed limit and braking run as usual. A
-- frame whose move differs from velocity * dt by more than rounding can explain (a wall, a script
-- moving him) starts the count again.

local config = require("config")
local engine = require("lib.engine")
local log = require("lib.log")
local lookup = require("lib.lookup")
local movement = require("lib.movement")
local util = require("lib.util")

local REFERENCE_FPS = util.REFERENCE_FPS
local REFERENCE_DT = util.REFERENCE_DT
local MOVE_WALKING = util.MOVE_WALKING
local MOVE_NAV_WALKING = 2
local MOVE_FLYING = 5
-- GE_SpyroGliding overrides these; surface swimming and flight levels also use MovementMode Flying.
local GLIDE_MAX_ACCELERATION = 850
local GLIDE_BRAKING_DECELERATION = 1000

local WAIT_FUNCTION = "/CharacterCommon/AbilitySystem/GameplayAbilities/Spyro/GA_Spyro_Jump.GA_Spyro_Jump_C:StartWaitForGlide"

local fix = { name = "glide fix", enabled = config.FIX_GLIDE_START or config.FIX_GLIDE_DISTANCE }

local last = nil -- distance fix: { x, y, ex, ey }, location after the last update and the rounding error carried
local announced = false

-- Glide start gate, from a StartWaitForGlide until the glide starts or Spyro lands:
-- { ability, jumpStart, waitEnd (30 FPS time the wait ends), fired (the game's wait ended),
--   pressedAt (30 FPS time of the first press, once there is one) }
local gate = nil
local pawnAddress = nil
local hook = { lookups = 3, retryIn = 0 }
local startFailed = false

local function isGliding(ctx)
    local cmc = ctx.cmc
    return ctx.mode == MOVE_FLYING and cmc.MaxAcceleration == GLIDE_MAX_ACCELERATION
        and cmc.BrakingDecelerationFlying == GLIDE_BRAKING_DECELERATION
        and not ctx.pawn:IsPlayingRootMotion()
end

-- Whole lattice steps of `err` once it reaches half a step, else 0.
local function wholeSteps(err, spacing)
    if math.abs(err) < spacing * 0.5 then return 0 end
    return math.floor(err / spacing + 0.5) * spacing
end

-- Rounds a time after the jump's start up to the 30 FPS frame grid that starts with the jump.
local function onReferenceGrid(jumpStart, time)
    return jumpStart + math.ceil((time - jumpStart) * REFERENCE_FPS - 1e-4) / REFERENCE_FPS
end

-- Runs after the body, in the frame the wait starts: the jump's (or hover's) first frame, whose move
-- began one frame (dt) earlier. At 30 FPS the wait starts 1/30 s after that and ends on its frame count.
local function onWait(context, duration)
    local ability = context:get()
    local character = ability.OwnerCharacter
    if not (character and character:IsValid()) or character:GetAddress() ~= pawnAddress then return end
    local statics = engine.getGameplayStatics()
    local dt = statics:GetWorldDeltaSeconds(character)
    if not util.aboveReferenceFps(dt) then gate = nil return end
    local jumpStart = statics:GetTimeSeconds(character) - dt
    gate = {
        ability = ability, jumpStart = jumpStart, fired = false, pressedAt = nil,
        waitEnd = jumpStart + REFERENCE_DT + math.ceil(duration:get() * REFERENCE_FPS - 1e-4) / REFERENCE_FPS,
    }
end

local function onWaitGuarded(context, duration)
    if startFailed then return end
    local ok, err = pcall(onWait, context, duration)
    if not ok then
        startFailed = true
        gate = nil
        log("glide start fix disabled after hook error: %s", tostring(err))
    end
end

-- Hands the flags back as the game left them (the wait's end, a press) and lets it carry on.
local function release(g, startNow)
    gate = nil
    local ability = g.ability
    if not ability:IsValid() then return end
    if startNow or (g.fired and g.pressedAt) then
        ability.WaitForGlideElapsed = true
        ability:OnGlideRequested()
    else
        ability.WaitForGlideElapsed = g.fired
        ability.GlideRequested = g.pressedAt ~= nil
    end
end

local function updateStart(ctx, gliding)
    if not config.FIX_GLIDE_START or startFailed then return end
    -- Registered as both the pre and the post callback: this UE4SS build only calls one for Blueprints.
    lookup.registerBlueprintHook(hook, WAIT_FUNCTION, onWaitGuarded, onWaitGuarded, "glide wait")
    pawnAddress = ctx.pawn:GetAddress()
    local g = gate
    if not g then return end
    local ability = g.ability
    if ctx.mode == MOVE_WALKING or ctx.mode == MOVE_NAV_WALKING or gliding or not ability:IsValid() then
        -- Landed, or a glide started some other way: the jump ability resets the flags on its next jump.
        gate = nil
        return
    end
    if not util.aboveReferenceFps(ctx.dt) then release(g, false) return end

    -- The frame that just finished: note what the game set, then hold both flags off again.
    local now = engine.getGameplayStatics():GetTimeSeconds(ctx.pawn)
    if ability.WaitForGlideElapsed then
        g.fired = true
        ability.WaitForGlideElapsed = false
    end
    if ability.GlideRequested then
        -- Handled at the start of the frame that just finished, so pressed during the one before.
        g.pressedAt = g.pressedAt or onReferenceGrid(g.jumpStart, now - ctx.dt * 1.5)
        ability.GlideRequested = false
    end

    if not g.pressedAt then return end
    -- 30 FPS starts the glide at the later of the wait's end and the press. The glide's first move is
    -- the next frame's, so start it on the update nearest that time.
    local startAt = math.max(g.waitEnd, g.pressedAt)
    if now >= startAt - ctx.dt * 0.5 then release(g, true) end
end

local function updateDistance(ctx, gliding)
    local dt = ctx.dt
    if not config.FIX_GLIDE_DISTANCE or not gliding or not util.aboveReferenceFps(dt) then
        last = nil
        return
    end
    local pawn = ctx.pawn
    local loc = pawn:K2_GetActorLocation()
    local x, y = loc.X, loc.Y
    if not last then
        last = { x = x, y = y, ex = 0, ey = 0 }
        if not announced then
            announced = true
            log("glide distance fix active")
        end
        return
    end

    local sx, sy = movement.floatSpacing(x), movement.floatSpacing(y)
    local vel = ctx.vel
    local rx, ry = vel.X * dt - (x - last.x), vel.Y * dt - (y - last.y)
    -- More than rounding can explain: something else moved him. Count from here.
    if math.abs(rx) > sx * 1.01 or math.abs(ry) > sy * 1.01 then
        last.x, last.y, last.ex, last.ey = x, y, 0, 0
        return
    end
    local ex, ey = last.ex + rx, last.ey + ry
    local ox, oy = wholeSteps(ex, sx), wholeSteps(ey, sy)
    if ox ~= 0 or oy ~= 0 then
        pawn:K2_AddActorWorldOffset({ X = ox, Y = oy, Z = 0 }, true, {}, false)
        local moved = pawn:K2_GetActorLocation()
        local mx, my = moved.X - x, moved.Y - y
        -- A blocked sweep moves less than asked: drop the carried error rather than push into the wall.
        if math.abs(mx - ox) > sx * 0.5 or math.abs(my - oy) > sy * 0.5 then
            last.x, last.y, last.ex, last.ey = moved.X, moved.Y, 0, 0
            return
        end
        x, y, ex, ey = moved.X, moved.Y, ex - mx, ey - my
    end
    last.x, last.y, last.ex, last.ey = x, y, ex, ey
end

function fix.update(ctx)
    local gliding = isGliding(ctx)
    updateDistance(ctx, gliding)
    updateStart(ctx, gliding)
end

function fix.reset()
    last, gate = nil, nil
end

-- Never leave a jump with its glide held off.
function fix.disable(ctx)
    local g = gate
    if g then pcall(release, g, false) end
end

return fix
