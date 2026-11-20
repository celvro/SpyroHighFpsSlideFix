-- Frozen Altars roof lasers (Spyro 3, LS321): enemies die about 8 times too fast at high FPS
--
-- BP_LS321_RoofLaser_C traces its beam in ReceiveTick and, every tick it hits one of its targets, calls
-- that target's OnReceiveLaserTowerDamage once: a whole hit per frame, with no DeltaSeconds in it. The
-- targets count hits per call too:
--   Hot Coal Rhynoc, Tiny Mammoth, Clubber Rhynoc  LaserDamage += 1, dead at 30, and their own tick
--                                                  takes 1 back per tick while the beam is off them
--   Snowman                                        CurrentModelScale -= 0.01 per call, dead below 0.25
--   Ice Wall                                       melts by 1 per tick of its own while BeingLasered
-- The laser's aim already scales by DeltaSeconds * 30, so it alone was tuned for frame time.
--
-- Measured 2026-11-19 (laser 0 held on a Clubber Rhynoc, Spyro beside it): from the first hit to
-- LaserDamage 30 took 0.80 and 0.97 s at 30 FPS, 0.121 s at ~300 FPS.
--
-- Fix: while frames are shorter than 1/30 s, these actors get an actor tick interval of 1/30 s, so their
-- Blueprint ReceiveTick -- the beam trace, the hit calls, the emitters it spawns, the targets' recovery
-- and melting -- runs exactly as often as at 30 FPS, with the accumulated DeltaSeconds. Their movement and
-- animation are other components with their own ticks, so they stay smooth; the beam's end point is set
-- in the laser's tick, so it follows the aim 30 times a second. Frames of 1/30 s or longer get the
-- interval this set taken back off (0, every frame).
--
-- The game slows far actors down to a 0.1 s interval and puts near ones back to 0, which would undo
-- this, so every tracked actor is looked at again: the lasers every frame, the targets a few per frame.
-- An interval above 1/30 (a far actor's 0.1) is left alone.

local config = require("config")
local engine = require("lib.engine")
local log = require("lib.log")
local lookup = require("lib.lookup")
local util = require("lib.util")

local fix = { name = "Frozen Altars laser fix", enabled = config.FIX_ROOF_LASER, failed = false }

local LASER_CLASS = "BP_LS321_RoofLaser_C"
local PHASMID_CHARACTER = "/Script/Phasmid.PhasmidCharacter"
local TARGETS = {
    BP_CES3352_HotCoalRhynoc_C = true,
    BP_CES3353_TinyMammoth_C = true,
    BP_CES3354_ClubberRhynoc_C = true,
    BP_CES3054_Snowman_C = true,
    BP_LS321_IceWall_C = true,
}
local TARGETS_PER_FRAME = 4 -- targets looked at per frame (round robin); lasers are looked at every frame
local SEARCH_FRAMES = 60    -- frames between searches for the lasers once their class has loaded

local INTERVAL = util.REFERENCE_DT
local laserSearch = { retryIn = 0, lookups = 0 } -- lookups granted when the laser class is created
local lasers = {}    -- list of laser actors
local targets = {}   -- list of target actors (a target only matters while a laser exists)
local pending = {}   -- characters reported by NotifyOnNewObject, resolved on the tick
local nextTarget = 1
local logged = false

-- Raises a short interval to 1/30 s above 30 FPS; takes back its own 1/30 at or below it.
local function apply(actor, fast)
    local interval = actor:GetActorTickInterval()
    if fast then
        if interval < INTERVAL - 1e-6 then actor:SetActorTickInterval(INTERVAL) end
    elseif math.abs(interval - INTERVAL) < 1e-6 then
        actor:SetActorTickInterval(0)
    end
end

local function searchLasers()
    if laserSearch.lookups <= 0 then return end
    if laserSearch.retryIn > 0 then
        laserSearch.retryIn = laserSearch.retryIn - 1
        return
    end
    laserSearch.retryIn = SEARCH_FRAMES
    laserSearch.lookups = laserSearch.lookups - 1
    local found = FindAllOf(LASER_CLASS)
    if found and #found > 0 then
        lasers = found
        laserSearch.lookups = 0
        log("%s: %d roof lasers found", fix.name, #found)
    end
end

local function resolve()
    for i = #pending, 1, -1 do
        local actor = pending[i]
        pending[i] = nil
        if actor:IsValid() and TARGETS[actor:GetClass():GetFName():ToString()] then
            targets[#targets + 1] = actor
        end
    end
end

-- Drops freed actors (IsValid is the only safe question to ask a dead wrapper).
local function prune(list)
    for i = #list, 1, -1 do
        if not list[i]:IsValid() then table.remove(list, i) end
    end
end

function fix.update(ctx)
    if #pending > 0 then resolve() end
    searchLasers()
    if #lasers == 0 and #targets == 0 then return end
    prune(lasers)
    if #lasers == 0 then
        -- Out of Frozen Altars: the targets' classes appear in other levels too, and are left alone.
        -- Kept while a search is still due: the targets can spawn before the lasers are found.
        if laserSearch.lookups <= 0 then targets, nextTarget = {}, 1 end
        return
    end
    local pc = ctx and ctx.pc
    if not (pc and pc:IsValid()) then return end
    local fast = util.aboveReferenceFps(engine.worldDeltaSeconds(pc))
    for _, laser in ipairs(lasers) do apply(laser, fast) end
    prune(targets)
    for _ = 1, math.min(TARGETS_PER_FRAME, #targets) do
        if nextTarget > #targets then nextTarget = 1 end
        apply(targets[nextTarget], fast)
        nextTarget = nextTarget + 1
    end
    if fast and not logged then
        logged = true
        log("%s: %d lasers and %d targets tick at 30 FPS", fix.name, #lasers, #targets)
    end
end

-- Gives every tracked actor its every-frame tick back.
function fix.disable()
    for _, list in ipairs({ lasers, targets }) do
        for _, actor in ipairs(list) do
            if actor:IsValid() then pcall(apply, actor, false) end
        end
    end
    lasers, targets, pending = {}, {}, {}
end

if fix.enabled then
    lookup.watch("/Script/Engine.BlueprintGeneratedClass", LASER_CLASS, laserSearch)
    NotifyOnNewObject(PHASMID_CHARACTER, function(object)
        if not fix.failed then pending[#pending + 1] = object end
    end)
end

return fix
