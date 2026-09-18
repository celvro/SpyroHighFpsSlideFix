-- Glides and hovers, split into the phases that could depend on framerate: the wait before a glide
-- may start, the glide itself, the hover at its end (Spyro 2 and 3), and the distance covered.
--
-- GA_Spyro_Jump only lets a glide start after StartWaitForGlide(WaitDuration) finishes (an
-- AbilityTask_WaitDelay: 0.3 s after a jump, 0.85 after a super jump, 0.75 or 1.5 after a hover). A
-- glide requested earlier starts when the wait ends. GA_Spyro_Glide sets the initial velocity (facing
-- * min(hspeed, 385), vz = GlideDescentMultiplier * that) and a 0.4 s timer (MinGlideThresholdForHover)
-- before which a hover fails. A hover from a glide applies GE_SpyroHover (JumpZVelocity 160, hold
-- 0.15) or, when the glide ability reports a ledge, GE_SpyroLedgeHover (80, hold 0.1, plus a 0.25 s
-- root motion push of 200 forward). Times come from hooks on those Blueprint functions.
--
--   "glide" lines     one per glide: the wait it followed, when it was requested and started (seconds
--                     after takeoff), height above takeoff and speeds at the start, the steady glide speed
--                     (hAvg from Velocity, hPos from positions: straight line / time) and descent, when
--                     the hover threshold timer fired, duration, turning and how it ended.
--   "hover" lines     one per hover from a glide: kind (hover, ledge, fail), glide time before it, height
--                     and apex above the hover start.
--   "glideair" lines  each airborne segment that had a glide: air time, apex, and the horizontal distance
--                     (straight line from takeoff) where Spyro first dropped to 0/50/100/200/400 below his
--                     takeoff height, interpolated between frames, plus distance and height at landing.
local UEHelpers = require("UEHelpers")
local log = require("lib.log")
local state = require("lib.state")
local trace = require("lib.trace")
local util = require("lib.util")

local num = util.num

local JUMP_CLASS = "/CharacterCommon/AbilitySystem/GameplayAbilities/Spyro/GA_Spyro_Jump.GA_Spyro_Jump_C:"
local GLIDE_CLASS = "/CharacterCommon/AbilitySystem/GameplayAbilities/Spyro/GA_Spyro_Glide.GA_Spyro_Glide_C:"
local HOOKS = {
    { path = JUMP_CLASS .. "StartWaitForGlide", event = "wait" },
    { path = JUMP_CLASS .. "OnGlideRequested", event = "request" },
    { path = JUMP_CLASS .. "OnHoverFromGlide", event = "hover" },
    { path = GLIDE_CLASS .. "OnStartGlide", event = "start" },
    { path = GLIDE_CLASS .. "MinGlideThresholdForHover", event = "threshold" },
}
local HOOK_RETRY_FRAMES = 60
local FLYING = 5
local STEADY_AFTER = 0.3             -- seconds into a glide before its speed counts as steady
local DROPS = { 0, 50, 100, 200, 400 } -- heights below takeoff where the distance is recorded
local LEDGE_HOVER_MAGNITUDE = 100    -- OnHoverFromGlide GlideDuration above this is a ledge hover
local TELEPORT_STEP = 1000            -- a one-frame move longer than this is a teleport (quicksave B), not flight

local glide = {}

local retryIn = 0
local pending = {} -- hook events since the last sample: { event, time, value, x, y, z, vx, vy, vz }
local air, current, hover = nil, nil, nil
local airCount, glideCount, hoverCount = 0, 0, 0
local lastWait = nil -- { value, time } of the last StartWaitForGlide, which runs on the takeoff frame

local function horiz(r, a)
    return math.sqrt((r.x - a.x0) ^ 2 + (r.y - a.y0) ^ 2)
end

local function fmtTime(t) return t and string.format("%+.3fs", t) or "n/a" end

-- The hooked functions run after their body, on the game thread, so the owner's position and velocity
-- are the ones the event left behind.
local function onEvent(event, context, param)
    local ability = context:get()
    local character = ability.OwnerCharacter
    if not (character and character:IsValid()) or character:GetAddress() ~= state.pawnAddress then return end
    local e = { event = event, value = param and num(param:get()) or nil,
        time = UEHelpers.GetGameplayStatics():GetTimeSeconds(character) }
    local loc = character:K2_GetActorLocation()
    local vel = character.CharacterMovement.Velocity
    e.x, e.y, e.z, e.vx, e.vy, e.vz = loc.X, loc.Y, loc.Z, vel.X, vel.Y, vel.Z
    table.insert(pending, e)
end

function glide.register()
    if retryIn > 0 then
        retryIn = retryIn - 1
        return
    end
    local waiting = false
    for _, h in ipairs(HOOKS) do
        if not (h.registered or h.failed) then
            -- The ability classes load with Spyro, so this only misses before the first pawn exists.
            local fn = StaticFindObject(h.path)
            if fn and fn:IsValid() then
                local errorLogged = false
                local function guarded(context, param)
                    local ok, err = pcall(onEvent, h.event, context, param)
                    if not ok and not errorLogged then
                        errorLogged = true
                        log("glide hook %s error: %s", h.event, tostring(err))
                    end
                end
                -- A Blueprint hook here only calls the pre callback (after the body), so register it as both.
                local ok, err = pcall(RegisterHook, h.path, guarded, guarded)
                if ok then
                    h.registered = true
                else
                    h.failed = true
                    log("glide hook %s unavailable: %s", h.event, tostring(err))
                end
            else
                waiting = true
            end
        end
    end
    retryIn = waiting and HOOK_RETRY_FRAMES or math.huge
    if not waiting then log("glide hooks registered") end
end

local function finishHover(r)
    local h = hover
    hover = nil
    if not h then return end
    log("hover %d air=%d cap=%s kind=%s gliding=%s magnitude=%.0f at=%s startDz=%+.2f apex=%+.2f hspeed0=%.1f",
        h.id, air and air.id or 0, tostring(state.fpsCap or "?"), h.kind,
        h.glideTime and string.format("%.3fs", h.glideTime) or "n/a", h.magnitude, fmtTime(h.at),
        h.z - (air and air.z0 or h.z), h.apexZ - h.z, h.hspeed0)
end

local function finishGlide(r, reason)
    local g = current
    current = nil
    state.glide = nil
    if not g then return end
    local steady = g.steadyFrames > 0
    -- Speed from positions, which is what position rounding (and the glide distance fix) changes.
    local f, l = g.steadyFirst, g.steadyLast
    local posTime = (f and l) and l.time - f.time or 0
    local hPos = posTime > 0 and string.format("%.2f", math.sqrt((l.x - f.x) ^ 2 + (l.y - f.y) ^ 2) / posTime) or "n/a"
    log("glide %d air=%d cap=%s avgFps=%.1f wait=%s waited=%s request=%s start=%s startDz=%+.2f startH=%.1f startVz=%.1f hAvg=%s hPos=%s vzAvg=%s dur=%.3fs hoverGate=%s yawTurn=%.1f input=%.2f end=%s",
        g.id, air and air.id or 0, tostring(state.fpsCap or "?"), util.avgFps(g),
        g.wait and string.format("%.2f", g.wait) or "n/a",
        g.waited and string.format("%.4fs", g.waited) or "n/a", fmtTime(g.request), fmtTime(g.start), g.startDz,
        g.startH, g.startVz,
        steady and string.format("%.2f", g.hSum / g.steadyFrames) or "n/a", hPos,
        steady and string.format("%.1f", g.vzSum / g.steadyFrames) or "n/a",
        r.time - g.startTime, g.threshold and string.format("%.3fs", g.threshold) or "n/a",
        g.yawAbs, g.frames > 0 and g.inputSum / g.frames or 0, reason)
    trace.flush()
end

local function finishAir(r)
    local a = air
    if current then finishGlide(r, "land") end
    finishHover(r)
    air = nil
    if not (a and a.glides > 0) then return end
    local drops = {}
    for _, d in ipairs(DROPS) do
        local c = a.crossings[d]
        drops[#drops + 1] = string.format("dist@-%d=%s", d, c and string.format("%.1f/%.3fs", c.dist, c.time) or "n/a")
    end
    log("glideair %d cap=%s avgFps=%.1f air=%.3fs apex=%+.2f glides=%d hovers=%d land=%.1f/%+.2f %s",
        a.id, tostring(state.fpsCap or "?"), util.avgFps(a), r.time - a.startTime, a.maxZ - a.z0, a.glides,
        a.hovers, horiz(r, a), r.z - a.z0, table.concat(drops, " "))
    trace.flush()
end

local function startGlide(e, r)
    if current then finishGlide(r, "restart") end
    finishHover(r)
    glideCount = glideCount + 1
    air.glides = air.glides + 1
    local hspeed = math.sqrt(e.vx * e.vx + e.vy * e.vy)
    current = util.newStats(r)
    current.id, current.startTime = glideCount, e.time
    current.request = air.request and air.request - air.startTime
    -- Wait duration and how long after the wait started the glide actually began.
    current.wait, current.waited = air.wait and air.wait.value, air.wait and e.time - air.wait.time
    current.start, current.startDz, current.startH, current.startVz = e.time - air.startTime, e.z - air.z0, hspeed, e.vz
    current.hSum, current.vzSum, current.steadyFrames, current.yawAbs, current.inputSum = 0, 0, 0, 0, 0
    air.request = nil
    state.glide = current
end

local function handleEvent(e, r)
    if e.event == "wait" then
        lastWait = { value = e.value, time = e.time }
        if air then air.wait = lastWait end
    elseif not air then
        return
    elseif e.event == "request" then
        air.request = air.request or e.time -- the first press counts; later ones are repeats
    elseif e.event == "start" then
        startGlide(e, r)
    elseif e.event == "threshold" then
        if current and not current.threshold then current.threshold = e.time - current.startTime end
    elseif e.event == "hover" then
        local glideTime = current and e.time - current.startTime or nil
        local magnitude = e.value or 0 / 0
        local kind = magnitude > LEDGE_HOVER_MAGNITUDE and "ledge" or (magnitude > 0 and "hover" or "fail")
        if current then finishGlide(r, kind == "fail" and "hoverfail" or kind) end
        finishHover(r)
        hoverCount = hoverCount + 1
        air.hovers = air.hovers + 1
        hover = { id = hoverCount, kind = kind, magnitude = magnitude, glideTime = glideTime,
            at = e.time - air.startTime, z = e.z, apexZ = e.z, hspeed0 = math.sqrt(e.vx * e.vx + e.vy * e.vy) }
    end
end

function glide.update(r, prev, grounded)
    local teleported = prev and math.abs(r.x - prev.x) + math.abs(r.y - prev.y) + math.abs(r.z - prev.z) > TELEPORT_STEP
    if grounded or teleported then
        if air then finishAir(teleported and prev or r) end
        for _, e in ipairs(pending) do
            if e.event == "wait" then handleEvent(e, r) end
        end
        pending = {}
        return
    end
    if not air then
        -- Measure from the last grounded frame, like the "seg" lines.
        local base = prev or r
        airCount = airCount + 1
        air = util.newStats(base)
        air.id, air.x0, air.y0, air.z0, air.maxZ = airCount, base.x, base.y, base.z, base.z
        air.glides, air.hovers, air.crossings = 0, 0, {}
        -- Only a wait started on (or just before) this takeoff belongs to it; ledge walk-offs start none.
        air.wait = lastWait and lastWait.time >= base.time - 0.1 and lastWait or nil
    end
    util.addFrame(air, r)

    -- A press after the wait starts the glide inside OnGlideRequested, so its hook (after the body) comes
    -- after OnStartGlide's: handle presses first.
    for _, e in ipairs(pending) do
        if e.event == "request" then handleEvent(e, r) end
    end
    for _, e in ipairs(pending) do
        if e.event ~= "request" then handleEvent(e, r) end
    end
    pending = {}

    air.maxZ = math.max(air.maxZ, r.z)
    if prev then
        for _, d in ipairs(DROPS) do
            local level = air.z0 - d
            if not air.crossings[d] and prev.z > level and r.z <= level then
                local f = (prev.z - level) / (prev.z - r.z)
                local px, py = prev.x + (r.x - prev.x) * f, prev.y + (r.y - prev.y) * f
                air.crossings[d] = { dist = math.sqrt((px - air.x0) ^ 2 + (py - air.y0) ^ 2),
                    time = prev.time + (r.time - prev.time) * f - air.startTime }
            end
        end
    end

    if hover then hover.apexZ = math.max(hover.apexZ, r.z) end
    local g = current
    if g then
        if r.mode ~= FLYING and r.time > g.startTime then
            finishGlide(r, util.MOVE_MODE_NAMES[r.mode] or tostring(r.mode))
        else
            util.addFrame(g, r)
            if r.time - g.startTime >= STEADY_AFTER then
                g.hSum, g.vzSum, g.steadyFrames = g.hSum + r.speed, g.vzSum + r.vz, g.steadyFrames + 1
                g.steadyFirst = g.steadyFirst or r
                g.steadyLast = r
            end
            if prev then g.yawAbs = g.yawAbs + math.abs(util.angleDiff(r.yaw, prev.yaw)) end
            g.inputSum = g.inputSum + math.sqrt(r.inputX * r.inputX + r.inputY * r.inputY)
        end
    end
end

return glide
