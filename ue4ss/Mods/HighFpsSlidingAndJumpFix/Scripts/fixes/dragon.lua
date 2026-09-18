-- Fire dragon segment fix
--
-- Fireworks Factory's segmented dragons (BP_CBS3012_FireDragon) move their body in the head's
-- UpdatePrevActors, which calls the native DragonSineMovementComponent.MoveUpdate for each live
-- segment in order with FMax(DeltaTime, 0.033). MoveUpdate lerps the segment twice towards its
-- leader by 4 * delta (and its wave phase and amplitude by 2 * delta), so each segment keeps
-- (1 - 4 * delta)^2 of its distance per call and trails a steadily moving leader by
-- dt * R / (1 - R) of its speed. At 30 FPS that is 0.101 s per segment, but the clamped delta
-- pulls just as hard every frame, so at 144 FPS it is 0.021 s: the body is ~4.7x shorter and
-- bunched up behind the head. This keeps the segments' bAlive off, which turns the Blueprint's
-- calls into no-ops, and repeats the same calls with a delta whose steady trail matches 30 FPS.
-- At 30 FPS or lower it passes the Blueprint's own delta, so nothing changes.

local config = require("config")
local log = require("lib.log")
local lookup = require("lib.lookup")
local util = require("lib.util")

local REFERENCE_FPS = util.REFERENCE_FPS

local DRAGON_UPDATE_FUNCTION = "/CBS3012_FireDragon/Blueprints/BP_CBS3012_FireDragon.BP_CBS3012_FireDragon_C:UpdatePrevActors"
local DRAGON_MIN_DELTA = 0.033 -- UpdatePrevActors passes FMax(DeltaTime, 0.033) to MoveUpdate
local DRAGON_FOLLOW_RATE = 4   -- MoveUpdate lerps towards the leader by this * delta, twice
local DRAGON_MESH_LIFT = 20    -- UpdatePrevActors raises the head's mesh this much around its MoveUpdate calls

-- Reused across calls (and dragons) so onDragonUpdate doesn't allocate a table every frame. Lua is
-- single-threaded and each call finishes using these before the next starts, so sharing is safe; the
-- lift/lower vectors' values never change, and the sweep result is an unread out-param either way.
local LIFT_VEC = { X = 0, Y = 0, Z = DRAGON_MESH_LIFT }
local LOWER_VEC = { X = 0, Y = 0, Z = -DRAGON_MESH_LIFT }
local SWEEP_HIT = {}

local fix = {
    name = "fire dragon segment fix",
    enabled = config.FIX_DRAGON_SEGMENTS,
    failed = false,
    hooked = nil,   -- address of the UpdatePrevActors function we hooked (it is reloaded with the level)
    heads = {},     -- address -> dragon head whose segments we took over, to hand back after an error
    failures = 0, retryIn = 0, lookups = 1,
}

-- Seconds a segment trails its leader per unit of leader speed at 30 FPS (see the header).
local KEEP_30 = (1 - DRAGON_FOLLOW_RATE / REFERENCE_FPS) ^ 2
local TRAIL_30 = KEEP_30 / (1 - KEEP_30) / REFERENCE_FPS

-- The delta to pass MoveUpdate for a frame of dt seconds.
local function referenceDragonDelta(dt)
    -- Frames of 1/30 s or longer, and InitializeBody's call with 0, get the Blueprint's own delta.
    if not util.aboveReferenceFps(dt) then return math.max(dt, DRAGON_MIN_DELTA) end
    -- Keep the fraction K per call that trails by dt * K / (1 - K) = TRAIL_30.
    local keep = TRAIL_30 / (dt + TRAIL_30)
    return (1 - math.sqrt(keep)) / DRAGON_FOLLOW_RATE
end

-- Hands every segment we took over back to the Blueprint's own MoveUpdate calls.
local function releaseDragonSegments()
    for _, head in pairs(fix.heads) do
        if head:IsValid() then
            local segments = head.BodySegments
            for i = 1, segments:GetArrayNum() do
                local segment = segments[i]
                if segment:IsValid() and segment.IsAlive_0 then segment.DragonSineMovement.bAlive = true end
            end
        end
    end
    fix.heads = {}
end

-- Runs when the head's UpdatePrevActors runs (after its body with this UE4SS build, but it works
-- before it too). Repeats the Blueprint's loop: every valid, alive segment follows the previous one,
-- the first follows the head, with the head's mesh raised as the Blueprint has it.
local function onDragonUpdate(context, deltaTime)
    local head = context:get()
    fix.heads[head:GetAddress()] = head
    local delta = referenceDragonDelta(deltaTime:get())
    local mesh = head.Mesh
    mesh:K2_AddRelativeLocation(LIFT_VEC, false, SWEEP_HIT, false)
    local leader = head
    local segments = head.BodySegments
    for i = 1, segments:GetArrayNum() do
        local segment = segments[i]
        if segment:IsValid() and segment.IsAlive_0 then
            local movement = segment.DragonSineMovement
            if movement.bAlive then
                -- New to us (a new dragon, or a grown segment): the Blueprint may already have moved
                -- it this frame, so only take it over. HandleDeath also clears bAlive, but together
                -- with IsAlive, so an alive segment with bAlive off is always one of ours.
                movement.bAlive = false
            else
                movement.bAlive = true
                movement:MoveUpdate(delta, leader)
                movement.bAlive = false
            end
            leader = segment
        end
    end
    mesh:K2_AddRelativeLocation(LOWER_VEC, false, SWEEP_HIT, false)
end

local function onDragonUpdateGuarded(context, deltaTime)
    if fix.failed then return end
    local ok, err = pcall(onDragonUpdate, context, deltaTime)
    if not ok then
        -- Segments left with bAlive off would freeze, so give them back before giving up.
        fix.failed = true
        pcall(releaseDragonSegments)
        log("fire dragon segment fix disabled after hook error: %s", tostring(err))
    end
end

-- The dragon Blueprint only loads with Fireworks Factory, and its function object is replaced when the
-- level loads again, so each time its class is created (see lookup.watch) it is looked up and
-- hooked again. RegisterHook can fail while the level is still loading (UFunction::Func 0x0), so
-- failures are retried too.
function fix.update()
    local fn = lookup.find(fix, DRAGON_UPDATE_FUNCTION)
    if not fn then return end
    local address = fn:GetAddress()
    if address == fix.hooked then fix.lookups = 0 return end
    -- Found but not hooked: keep trying while the level finishes loading (failures are capped).
    fix.lookups = math.max(fix.lookups, 1)
    local ok, err = pcall(RegisterHook, DRAGON_UPDATE_FUNCTION, onDragonUpdateGuarded)
    if ok then
        fix.hooked = address
        fix.lookups = 0
        fix.failures = 0
        log("fire dragon segment hook registered")
    else
        fix.failures = fix.failures + 1
        if fix.failures >= lookup.MAX_FAILURES then
            fix.failed = true
            log("fire dragon segment fix disabled: RegisterHook failed: %s", tostring(err))
        end
    end
end

if fix.enabled then
    lookup.watch("/Script/Engine.BlueprintGeneratedClass", "BP_CBS3012_FireDragon_C", fix)
end

return fix
