-- Scripted glide from a standstill (G): the same glide every time, for comparing framerates.
--
-- Puts Spyro TEST_HEIGHT above the quicksave spot (V), facing the saved way, with zero velocity, and
-- starts a glide by sending Character.Event.Glide.Start (GA_Spyro_Glide's trigger). The glide starts
-- at speed 0 and speeds up at MaxAcceleration 850 along the glide line (forward, GlideDescentMultiplier
-- down); CharacterInputComponent_Spyro pushes forward every frame, so no input is needed (don't steer).
--
--   "glidetest" lines  one per test glide: framerate, time to reach 50/90/99% of the glide's horizontal
--                      speed (367.74), then the distance along the ground and the drop at fixed times
--                      after the start ("t0.5=dist/drop"), and the distance and time where the drop
--                      reaches fixed heights ("d100=dist/time"), both interpolated between frames.
--
-- PhysFlying moves each frame with the velocity after that frame's acceleration, so while speeding up
-- a 30 FPS glide runs ahead of a high-FPS one by about speedGained * (1/30 - dt) / 2 (~5.8 units at
-- 320 FPS), along the glide line. If that is all, the distance at each drop matches and only the
-- times differ.
local log = require("lib.log")
local quicksave = require("tools.quicksave")
local state = require("lib.state")

local TEST_HEIGHT = 600
local GLIDE_SPEED = 367.74      -- steady horizontal glide speed (MaxFlySpeed 385 along the glide line)
local TIMES = { 0.25, 0.5, 1.0, 2.0, 3.0 }
local DROPS = { 50, 100, 200, 400 }
local TIMEOUT = 6
local FLYING = 5

local glidetest = {}

local requested = false
local test = nil
local testCount = 0

function glidetest.request()
    requested = true
end

-- Sends the glide's trigger event, as GA_Spyro_Jump does (EventMagnitude = current Z velocity, 0 here).
local function startGlide(pawn)
    local library = StaticFindObject("/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary")
    if not (library and library:IsValid()) then error("AbilitySystemBlueprintLibrary not found") end
    local tag = { TagName = FName("Character.Event.Glide.Start") }
    library:SendGameplayEventToActor(pawn, tag, { EventTag = tag, EventMagnitude = 0 })
end

local function begin(pawn, pc, cmc, r)
    if not quicksave.teleportAbove(pawn, pc, cmc, TEST_HEIGHT) then return end
    local loc = pawn:K2_GetActorLocation()
    startGlide(pawn)
    testCount = testCount + 1
    -- The glide's first move is the next frame's, so its clock starts at this sample.
    test = {
        id = testCount, t0 = r.time, x0 = loc.X, y0 = loc.Y, z0 = loc.Z, started = false,
        prev = { elapsed = 0, dist = 0, drop = 0 },
        frames = 0, dtSum = 0, reach = {}, atTime = {}, atDrop = {},
    }
    log("glidetest %d: started at (%.0f, %.0f, %.0f)", test.id, loc.X, loc.Y, loc.Z)
end

local function fmt(values, keys, prefix, a, b)
    local parts = {}
    for _, k in ipairs(keys) do
        local v = values[k]
        parts[#parts + 1] = string.format("%s%g=%s", prefix, k, v and string.format(a .. "/" .. b, v[1], v[2]) or "n/a")
    end
    return table.concat(parts, " ")
end

local function finish(reason)
    local t = test
    test = nil
    local reach = {}
    for _, p in ipairs({ 50, 90, 99 }) do
        reach[#reach + 1] = string.format("v%d=%s", p, t.reach[p] and string.format("%.4fs", t.reach[p]) or "n/a")
    end
    log("glidetest %d cap=%s avgFps=%.1f %s %s %s end=%s", t.id, tostring(state.fpsCap or "?"),
        t.dtSum > 0 and t.frames / t.dtSum or 0, table.concat(reach, " "),
        fmt(t.atTime, TIMES, "t", "%.2f", "%.2f"), fmt(t.atDrop, DROPS, "d", "%.2f", "%.4fs"), reason)
end

local function sampleTest(r)
    local t = test
    local elapsed = r.time - t.t0
    local dist = math.sqrt((r.x - t.x0) ^ 2 + (r.y - t.y0) ^ 2)
    local drop = t.z0 - r.z
    if r.mode ~= FLYING then
        if t.started or elapsed > 0.5 then finish("mode " .. tostring(r.mode)) end
        return
    end
    t.started = true
    t.frames, t.dtSum = t.frames + 1, t.dtSum + r.dt
    for _, p in ipairs({ 50, 90, 99 }) do
        if not t.reach[p] and r.speed >= GLIDE_SPEED * p / 100 then t.reach[p] = elapsed end
    end
    local p = t.prev
    if p then
        for _, at in ipairs(TIMES) do
            if not t.atTime[at] and p.elapsed < at and elapsed >= at then
                local f = (at - p.elapsed) / (elapsed - p.elapsed)
                t.atTime[at] = { p.dist + (dist - p.dist) * f, p.drop + (drop - p.drop) * f }
            end
        end
        for _, d in ipairs(DROPS) do
            if not t.atDrop[d] and p.drop < d and drop >= d then
                local f = (d - p.drop) / (drop - p.drop)
                t.atDrop[d] = { p.dist + (dist - p.dist) * f, p.elapsed + (elapsed - p.elapsed) * f }
            end
        end
    end
    t.prev = { elapsed = elapsed, dist = dist, drop = drop }
    if elapsed > TIMEOUT then finish("timeout") end
end

function glidetest.update(pawn, pc, cmc, r)
    if requested then
        requested = false
        if test then finish("restarted") end
        local ok, err = pcall(begin, pawn, pc, cmc, r)
        if not ok then
            test = nil
            log("glidetest error: %s", tostring(err))
        end
        return
    end
    if test then sampleTest(r) end
end

return glidetest
