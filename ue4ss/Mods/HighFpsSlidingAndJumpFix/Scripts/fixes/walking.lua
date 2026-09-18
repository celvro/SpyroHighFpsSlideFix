-- Walking velocity fix (sliding and acceleration)
--
-- Levels sit ~300,000 units from the world origin, where float32 positions have a 1/32 unit
-- spacing. UE 4.19's PhysWalking resets Velocity to (actual displacement / dt) after every
-- move, so velocity is quantized to multiples of (1/32)/dt: 4.5 at 144 FPS, 0.94 at 30.
--   * braking: above ~80 FPS a frame's braking removes less than half of that step, the
--     rounded move restores the old speed, and Spyro slides forever at a constant low speed.
--   * accelerating: a frame's 1000 * dt (6.9 at 144 FPS) of acceleration lands on 4.5 or 9, so
--     speeding up (e.g. starting a charge) runs at ~650 or ~1300 per second instead of 1000.
--   * scripted walks: path following (SimpleMoveToLocation, e.g. walking Spyro up to a freed
--     dragon) accelerates him through RequestedVelocity with no input. At ~500 FPS its first step
--     rounds to nothing and the walk starts late, then crawls at 100-200 instead of 268.
-- While walking without root motion, this keeps the unquantized velocity (same formula as
-- UCharacterMovementComponent::CalcVelocity, including ApplyRequestedMove while the controller's
-- PathFollowingComponent is moving) and writes it back whenever the engine's value only differs
-- by quantization. At low framerates the difference is negligible.
--
-- Wall slide (FIX_WALL_SLIDE)
--
-- Sliding along a wall at high FPS, a frame's move is under a unit, and rounding it to the 1/32
-- lattice can leave the move and its slide both pointing into the wall: every sweep blocks at the
-- start, the displacement is 0, and PhysWalking sets Velocity to 0. From 0, each move is too short to
-- get anywhere, so Spyro stalls or locks against the wall until he turns away (charging, 2.3-35% of
-- wall frames at 320 FPS, none at 30). At 30 FPS the same move slides along the wall and keeps the
-- velocity's component along it. So above 30 FPS, when the engine leaves him slower than the predicted
-- velocity projected along the walls he hit this frame (from a ReceiveHit hook), that projection is
-- written instead.

local config = require("config")
local log = require("lib.log")
local lookup = require("lib.lookup")
local movement = require("lib.movement")
local util = require("lib.util")

local MIN_TICK_TIME = util.MIN_TICK_TIME
local MOVE_WALKING = util.MOVE_WALKING
local HIT_FUNCTION = "/CharacterCommon/BaseClasses/BP_Base_Playable.BP_Base_Playable_C:ReceiveHit"
local MAX_WALL_HITS = 8     -- wall normals kept per frame
local WALL_MAX_NZ = 0.7     -- steeper than this counts as a wall (walkable floors are nz >= ~0.71)

local fix = { name = "walking velocity fix", enabled = true }

-- Walls Spyro's own moves hit since the last update: 2D unit normals, as flat x1, y1, x2, y2, ...
local walls = {
    normals = {}, count = 0,
    pawn = nil,        -- address of the pawn being fixed; hits on other actors are ignored
    registered = false, failed = false, retryIn = 0, lookups = 1,
}

local tracked = nil -- { x, y, z } unquantized velocity carried from the previous frame
local STILL = { 0, 0, 0 } -- tracked velocity while standing; never modified
-- Path following (scripted walks): the controller's PathFollowingComponent and its class, whether a move
-- was active last frame (for the log), and failed after an error.
local path = { component = nil, class = nil, active = false, failed = false }

-- RequestedVelocity while the player controller's path following is moving Spyro (SimpleMoveToLocation,
-- e.g. walking him up to a freed dragon), else nil. The engine leaves RequestedVelocity set after the
-- move ends, so the path status decides; it's only queried while RequestedVelocity is nonzero.
local function readPathRequest(pc, cmc)
    local request = cmc.RequestedVelocity
    if request.X == 0 and request.Y == 0 and request.Z == 0 then return nil end
    if not (path.component and path.component:IsValid()) then
        path.class = path.class or StaticFindObject("/Script/AIModule.PathFollowingComponent")
        local component = pc:GetComponentByClass(path.class)
        path.component = (component and component:IsValid()) and component or nil
    end
    -- EPathFollowingAction: 0 Error, 1 NoMove (idle), 2 DirectMove, 3 PartialPath, 4 PathToGoal.
    if not path.component or path.component:GetPathActionType() < 2 then return nil end
    return { X = request.X, Y = request.Y, Z = request.Z }
end

local function pathRequest(pc, cmc)
    if path.failed then return nil end
    -- Called every frame without input (including standing still), so no closure per call.
    local ok, result = pcall(readPathRequest, pc, cmc)
    if not ok then
        path.failed = true
        log("path following moves aren't predicted after error: %s", tostring(result))
        return nil
    end
    if (result ~= nil) ~= path.active then
        path.active = result ~= nil
        log("walking fix: path following move %s", path.active and "started" or "ended")
    end
    return result
end

-- Hooked on BP_Base_Playable's ReceiveHit, which the engine calls for every blocking hit of a move
-- (the move itself, step-up and slide sweeps). Only records wall normals; the update uses them.
local function onHit(context, myComp, other, otherComp, selfMoved, hitLocation, hitNormal)
    if walls.count >= MAX_WALL_HITS or not selfMoved:get() then return end
    if context:get():GetAddress() ~= walls.pawn then return end
    local n = hitNormal:get()
    local nx, ny, nz = n.X, n.Y, n.Z
    if nz >= WALL_MAX_NZ then return end
    local size = math.sqrt(nx * nx + ny * ny)
    if size < 1e-3 then return end
    local i = walls.count * 2
    walls.normals[i + 1], walls.normals[i + 2] = nx / size, ny / size
    walls.count = walls.count + 1
end

-- A hook error would repeat every frame, so the first one turns the wall slide off.
local function onHitGuarded(...)
    if walls.failed then return end
    local ok, err = pcall(onHit, ...)
    if not ok then
        walls.failed = true
        walls.count = 0
        log("wall slide disabled after hook error: %s", tostring(err))
    end
end

-- The predicted velocity with its component into each wall hit this frame removed, the way
-- SlideAlongSurface redirects a move. Still into an earlier wall afterwards means a corner: 0.
local function slideAlongWalls(vx, vy, count)
    local normals = walls.normals
    for i = 1, count * 2, 2 do
        local into = vx * normals[i] + vy * normals[i + 1]
        if into < 0 then vx, vy = vx - into * normals[i], vy - into * normals[i + 1] end
    end
    for i = 1, count * 2, 2 do
        if vx * normals[i] + vy * normals[i + 1] < -1e-3 then return 0, 0 end
    end
    return vx, vy
end

function fix.update(ctx)
    local pawn, cmc, dt = ctx.pawn, ctx.cmc, ctx.dt
    -- Hits since the last update belong to the move that produced ctx.vel; start collecting afresh.
    local wallCount = walls.count
    walls.count = 0
    walls.pawn = pawn:GetAddress()
    if config.FIX_WALL_SLIDE then
        -- Registered as both the pre and the post callback: this UE4SS build only calls one for Blueprints.
        lookup.registerBlueprintHook(walls, HIT_FUNCTION, onHitGuarded, onHitGuarded, "wall slide")
    end
    if ctx.mode ~= MOVE_WALKING then tracked = nil return end
    local vel = ctx.vel
    local vx, vy, vz = vel.X, vel.Y, vel.Z
    local stopped = vx == 0 and vy == 0 and vz == 0
    -- Standing still without input: skip the engine calls below. A move that starts here is predicted from zero.
    if stopped and not config.FIX_WALKING_ACCELERATION then
        tracked = nil
        return
    end
    local accel = cmc:GetCurrentAcceleration()
    local braking = accel.X == 0 and accel.Y == 0 and accel.Z == 0
    -- Path following moves Spyro through RequestedVelocity with zero input acceleration, which isn't braking:
    -- predicting braking held him in place (at 144 FPS the first step is 4.5 per axis, within the tolerance
    -- of 0). The engine's own path move breaks down at high FPS too: at ~550 FPS its first step rounds to
    -- nothing and its velocity locks to the position lattice, so predict it like input acceleration.
    local request = braking and config.FIX_WALKING_ACCELERATION and pathRequest(ctx.pc, cmc) or nil
    -- Zero velocity with input still has to be predicted: above ~250 FPS the first frame's move
    -- (MaxAcceleration * dt^2) rounds to nothing, the engine resets velocity to 0, and Spyro never starts moving.
    if stopped and braking and not request then
        tracked = STILL
        return
    end
    local handled = (braking or config.FIX_WALKING_ACCELERATION) and not pawn:IsPlayingRootMotion()

    if not handled or not tracked or dt < MIN_TICK_TIME then
        tracked = handled and { vx, vy, vz } or nil
        return
    end

    local bx, by
    if request then
        bx, by = movement.calcRequestedWalkingVelocity(cmc, tracked[1], tracked[2], request, dt)
    end
    if not bx then
        bx, by = movement.calcWalkingVelocity(cmc, tracked[1], tracked[2], accel.X, accel.Y, dt)
    end
    local bz = 0

    local tolerance = movement.quantizationTolerance(pawn, dt)

    -- Hit a wall above 30 FPS: slide the prediction along it, and keep that unless the engine's
    -- velocity is already faster (a hit late in the frame, which moved him most of the way).
    if wallCount > 0 and config.FIX_WALL_SLIDE and util.aboveReferenceFps(dt) then
        local sx, sy = slideAlongWalls(bx, by, wallCount)
        local slower = vx * vx + vy * vy < sx * sx + sy * sy
        if slower or (math.abs(vx - sx) <= tolerance and math.abs(vy - sy) <= tolerance and math.abs(vz) <= tolerance) then
            if vx ~= sx or vy ~= sy or vz ~= 0 then
                cmc.Velocity = { X = sx, Y = sy, Z = 0 }
            end
            tracked = (sx == 0 and sy == 0) and nil or { sx, sy, 0 }
            return
        end
    end

    if math.abs(vx - bx) <= tolerance and math.abs(vy - by) <= tolerance and math.abs(vz - bz) <= tolerance then
        if vx ~= bx or vy ~= by or vz ~= bz then
            cmc.Velocity = { X = bx, Y = by, Z = bz }
        end
        tracked = (bx == 0 and by == 0 and bz == 0) and nil or { bx, by, bz }
    else
        -- Something other than quantization changed the velocity (collision, script): follow the engine.
        tracked = { vx, vy, vz }
    end
end

function fix.reset()
    tracked = nil
end

return fix
