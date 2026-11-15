-- Test room: a flat floor in the empty sky above the level Spyro is in, with nothing else on it, for
-- measuring one character away from everything a level does to it (slopes, walls, water, the other
-- enemies, the triggers it was placed next to). tools/animtest.lua's "spawn=" option uses it: Spyro is
-- put on the floor, the character is spawned in the middle of it facing him, and its montages are played
-- from there.
--
-- The game ships no empty map (the only non-level maps in the paks are Engine/Maps/Entry and the
-- persistent level), so the room is made: one StaticMeshActor with the engine's 100-unit cube
-- (/Engine/BasicShapes/Cube, which is cooked into pakchunk0 and has box collision), scaled to
-- SIZE x SIZE x THICKNESS. It stays over Spyro's own X and Y, so the float32 position grid there is the
-- level's own (docs/findings/sliding-walking.md) and only Z is new.
--
-- The height is the first one, from LIFT above Spyro upwards, where line traces over the footprint hit
-- nothing between the floor and HEADROOM above it: a level's towers and mountains reach well above where
-- he stands.
--
--   "testroom" lines   where the floor went, what was spawned on it, and why either failed
local UEHelpers = require("UEHelpers")
local ground = require("lib.ground")
local log = require("lib.log")
local list = require("tools.spawnlist")

local testroom = {}

local FLOOR_MESH = "/Engine/BasicShapes/Cube.Cube"
local FLOOR_CLASS = "/Script/Engine.StaticMeshActor"
local MESH_SIZE = 100       -- the cube's edge
local SIZE = 8000           -- floor edge: Spyro's longest root motion is 834 units (LoopEntrance)
local THICKNESS = 100
local LIFT = 8000           -- first height tried above where Spyro stands
local LIFT_STEP = 4000
local LIFT_TRIES = 5
local HEADROOM = 2000       -- clear air wanted above the floor
local DISTANCE = 600        -- Spyro stands this far from the middle, where the character goes
local CLEARANCE = 2         -- a character is put this far above the floor (as tools/spawntest.lua)
local MOVABLE = 2           -- EComponentMobility::Movable
local ALWAYS_SPAWN = 2      -- ESpawnActorCollisionHandlingMethod::AdjustIfPossibleButAlwaysSpawn

local function loadObject(path)
    local object = StaticFindObject(path)
    if object and object:IsValid() then return object end
    -- The package's asset name (no _C) first: LoadAsset on a class path loads nothing (tools/spawntest.lua).
    pcall(LoadAsset, (path:gsub("_C$", "")))
    object = StaticFindObject(path)
    if object and object:IsValid() then return object end
    pcall(LoadAsset, path)
    object = StaticFindObject(path)
    if object and object:IsValid() then return object end
    error("not found after LoadAsset: " .. path)
end

-- The class path for what the trigger file asked for: a full path as it is
-- (/CES1015_Ram/Blueprints/BP_CES1015_Ram.BP_CES1015_Ram_C, or just the package and the asset name is
-- filled in), otherwise a class from tools/spawnlist.lua by name ("BP_CES1015_Ram_C", "CES1015_Ram") or
-- by the one entry containing it ("Cowlek"). Returns nil and the reason when it names none or several.
function testroom.resolve(name)
    if name:find("/", 1, true) then
        if not name:find(".", 1, true) then
            local asset = name:match("([^/]+)$")
            return name .. "." .. asset .. "_C"
        end
        return name:match("_C$") and name or (name .. "_C")
    end
    local wanted = name:lower()
    local partial = {}
    for _, entry in ipairs(list) do
        local class = entry.class:lower()
        if class == wanted or class == wanted .. "_c" or class == "bp_" .. wanted .. "_c" then return entry.path end
        if class:find(wanted, 1, true) then partial[#partial + 1] = entry.class end
    end
    if #partial == 1 then
        for _, entry in ipairs(list) do
            if entry.class == partial[1] then return entry.path end
        end
    end
    if #partial == 0 then
        return nil, "no class in tools/spawnlist.lua contains it; give the full path, /<Plugin>/Blueprints/<Asset>.<Asset>_C"
    end
    local shown = {}
    for index = 1, math.min(#partial, 12) do shown[index] = partial[index] end
    return nil, string.format("%d classes contain it (%s%s); name one exactly", #partial, table.concat(shown, ", "),
        #partial > #shown and ", ..." or "")
end

-- Is the air clear over the footprint of a floor whose top is at `top`?
local function clear(pawn, cx, cy, top)
    local half = SIZE / 2 - 100
    for ix = -1, 1 do
        for iy = -1, 1 do
            local hit = ground.zAt(pawn, cx + ix * half, cy + iy * half, top, HEADROOM, THICKNESS + 100)
            if hit then return false end
        end
    end
    return true
end

local function spawnFloor(pawn, cx, cy, top)
    local mesh = loadObject(FLOOR_MESH)
    local class = StaticFindObject(FLOOR_CLASS)
    if not class or not class:IsValid() then error("no " .. FLOOR_CLASS) end
    local scale = { X = SIZE / MESH_SIZE, Y = SIZE / MESH_SIZE, Z = THICKNESS / MESH_SIZE }
    local transform = {
        Rotation = { X = 0, Y = 0, Z = 0, W = 1 },
        Translation = { X = cx, Y = cy, Z = top - THICKNESS / 2 },
        Scale3D = scale,
    }
    local statics = UEHelpers.GetGameplayStatics()
    local floor = statics:BeginDeferredActorSpawnFromClass(pawn, class, transform, ALWAYS_SPAWN, nil)
    if not floor or not floor:IsValid() then error("the floor did not spawn") end
    local ok, err = pcall(function()
        local component = floor.StaticMeshComponent
        -- A static mesh component is Static by default, and one that is refuses a new mesh once
        -- registered. SetMobility is not reflected in this build ("attempt to call a TrivialObject
        -- value", 2026-11-14), so the property is written instead.
        component.Mobility = MOVABLE
        if not component:SetStaticMesh(mesh) then error("SetStaticMesh refused the cube") end
        statics:FinishSpawningActor(floor, transform)
    end)
    if not ok then
        pcall(function() floor:K2_DestroyActor() end)
        error(err, 0)
    end
    local component = floor.StaticMeshComponent
    pcall(function() floor:SetActorScale3D(scale) end)
    pcall(function() component:SetCollisionProfileName(FName("BlockAll")) end)
    return floor
end

-- The level's own ground instead of the sky floor ("arena=level"): the character is put DISTANCE in
-- front of Spyro where he stands. The navmesh is baked into each level (NavigationSystem
-- bAutoCreateNavigationData=False, no runtime generation), so a character that finds its way by navmesh
-- has none on the sky floor and stands still in the free phase; here it has the level's. Stand Spyro on
-- open flat ground facing open ground, as tools/spawntest.lua asks.
local function buildOnGround(pawn, pc, loc, rot, yaw, halfHeight)
    local rad = math.rad(yaw)
    local cx, cy = loc.X + math.cos(rad) * DISTANCE, loc.Y + math.sin(rad) * DISTANCE
    local feet = loc.Z - halfHeight
    local top = ground.zAt(pawn, cx, cy, feet, 300, 1000) or feet
    local room = {
        top = top, yaw = yaw, distance = DISTANCE, arena = "level",
        centre = { X = cx, Y = cy },
        spyro = { X = loc.X, Y = loc.Y, Z = loc.Z },
        home = { X = loc.X, Y = loc.Y, Z = loc.Z },
        homeRotation = { Pitch = 0, Yaw = rot.Yaw, Roll = 0 },
    }
    log("testroom: level ground, the character goes %d in front of Spyro (ground there %.0f against his feet at %.0f)",
        DISTANCE, top, feet)
    return room
end

-- Builds the floor and puts Spyro on it (arena "sky", the default), or uses the ground he stands on
-- (arena "level"). Returns the room: { floor, top, centre, yaw, distance, arena, spyro, home,
-- homeRotation }. Errors (to be caught by the caller) when the floor cannot be made.
function testroom.build(pawn, pc, arena)
    local loc, rot = pawn:K2_GetActorLocation(), pawn:K2_GetActorRotation()
    local yaw = pc:GetControlRotation().Yaw
    local halfHeight = pawn.CapsuleComponent:GetScaledCapsuleHalfHeight()
    if arena == "level" then return buildOnGround(pawn, pc, loc, rot, yaw, halfHeight) end
    local top, cleared = nil, false
    for try = 0, LIFT_TRIES - 1 do
        top = loc.Z + LIFT + try * LIFT_STEP
        if clear(pawn, loc.X, loc.Y, top) then
            cleared = true
            break
        end
    end
    if not cleared then log("testroom: nothing clear up to %.0f above him; using the highest", top - loc.Z) end
    local floor = spawnFloor(pawn, loc.X, loc.Y, top)
    local rad = math.rad(yaw)
    local room = {
        floor = floor, top = top, yaw = yaw, distance = DISTANCE, arena = "sky",
        centre = { X = loc.X, Y = loc.Y },
        spyro = { X = loc.X - math.cos(rad) * DISTANCE, Y = loc.Y - math.sin(rad) * DISTANCE,
                  Z = top + halfHeight + CLEARANCE },
        home = { X = loc.X, Y = loc.Y, Z = loc.Z },
        homeRotation = { Pitch = 0, Yaw = rot.Yaw, Roll = 0 },
    }
    pawn:K2_TeleportTo(room.spyro, { Pitch = 0, Yaw = yaw, Roll = 0 })
    pcall(function() pawn.CharacterMovement.Velocity = { X = 0, Y = 0, Z = 0 } end)
    log("testroom: floor %d x %d at Z %.0f (%.0f above (%.0f, %.0f, %.0f)), Spyro %d from the middle",
        SIZE, SIZE, top, top - loc.Z, loc.X, loc.Y, loc.Z, DISTANCE)
    return room
end

-- Is Spyro still on the floor? A floor that never got its collision drops him back into the level.
function testroom.standing(pawn, room)
    local loc = pawn:K2_GetActorLocation()
    if room.arena == "level" then return math.abs(loc.Z - room.spyro.Z) < 300 end
    return math.abs(loc.Z - room.spyro.Z) < 200
        and math.abs(loc.X - room.centre.X) < SIZE / 2 and math.abs(loc.Y - room.centre.Y) < SIZE / 2
end

-- Spawns the class at `path` in the middle of the floor, standing on it and facing Spyro, with an AI
-- controller as a placed one would have. Returns the actor and the spot and facing it was given, which
-- is where every one of its montages should start from.
function testroom.spawn(pawn, room, path)
    local class = loadObject(path)
    local face = math.rad(room.yaw + 180) / 2
    local spot = { X = room.centre.X, Y = room.centre.Y, Z = room.top + 100 + CLEARANCE }
    local transform = {
        Rotation = { X = 0, Y = 0, Z = math.sin(face), W = math.cos(face) },
        Translation = spot,
        Scale3D = { X = 1, Y = 1, Z = 1 },
    }
    local statics = UEHelpers.GetGameplayStatics()
    local actor = statics:BeginDeferredActorSpawnFromClass(pawn, class, transform, ALWAYS_SPAWN, nil)
    if not actor or not actor:IsValid() then error("BeginDeferredActorSpawnFromClass returned nothing") end
    -- Now its capsule size is known: stand it on the floor.
    local ok, half = pcall(function() return actor.CapsuleComponent:GetScaledCapsuleHalfHeight() end)
    if ok and type(half) == "number" then spot.Z = room.top + half + CLEARANCE end
    statics:FinishSpawningActor(actor, transform)
    pcall(function()
        if not actor.Controller:IsValid() then actor:SpawnDefaultController() end
    end)
    room.actor = actor
    log("testroom: spawned %s in the middle, %d in front of Spyro", path:match("([^%.]+)$") or path, DISTANCE)
    return actor, spot, { Pitch = 0, Yaw = room.yaw + 180, Roll = 0 }
end

-- Destroys what was spawned, puts Spyro back where he was and takes the floor away.
function testroom.leave(pawn, room)
    if not room then return end
    local actor = room.actor
    if actor and actor:IsValid() then pcall(function() actor:K2_DestroyActor() end) end
    room.actor = nil
    if pawn and pawn:IsValid() then
        pcall(function()
            pawn:K2_TeleportTo(room.home, room.homeRotation)
            pawn.CharacterMovement.Velocity = { X = 0, Y = 0, Z = 0 }
        end)
    end
    local floor = room.floor
    if floor and floor:IsValid() then pcall(function() floor:K2_DestroyActor() end) end
    room.floor = nil
    if room.arena == "level" then
        log("testroom: done, Spyro back at (%.0f, %.0f, %.0f)", room.home.X, room.home.Y, room.home.Z)
        return
    end
    log("testroom: gone, Spyro back at (%.0f, %.0f, %.0f)", room.home.X, room.home.Y, room.home.Z)
end

return testroom
