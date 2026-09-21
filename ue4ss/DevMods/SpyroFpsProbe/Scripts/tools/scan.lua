-- Records a tour stop in front of every kind of character in the level (H, or an empty scan.txt file in
-- this mod folder), so the enemies do not have to be walked to one at a time.
--
-- It finds every PhasmidCharacter in the world (the class trackers/stalls.lua watches: enemies, NPCs and
-- the playable characters), skips the player and anything already covered, and writes a stop per class
-- and script: a few hundred units in front of the character, on ground the trace found, facing it.
--
-- The scripts are what brings out the character's animations, and which ones it gets comes from its class
-- name: CES and CBS are enemies and bosses, so the run walks into them (the chase or the attack), then
-- flames and charges them (the hit and death ones); CNS and CFS are NPCs and fauna, so it walks in and
-- then talks — and "enterPlay" carries on holding forward and jumping afterwards, which is how a
-- minigame's own animations are reached, since a stop can't be recorded inside a minigame that isn't
-- running when the level is scanned.
--
-- One stop per class, not per character: twenty of the same rhynoc in a level behave the same. Characters
-- further than RANGE from the player are left out, because a level streams its neighbours in too and
-- their enemies are loaded with them.
--
-- Stops go to routes.txt like the hand-recorded ones (tools/routes.lua), so they can be edited or
-- deleted afterwards, and scanning the same level twice doesn't duplicate them.
--
--   "scan" lines  what was found, what was written, and what was skipped
local ground = require("lib.ground")
local levels = require("lib.levels")
local log = require("lib.log")
local routes = require("tools.routes")

local scan = {}

local CLASS = "PhasmidCharacter"
local TRIGGER = require("lib.paths").modDir .. "\\scan.txt" -- same as pressing H, for driving it from outside
-- Units in front of the character the stop stands at, tried in turn: the spot has to have ground under it,
-- or the run teleports the character into the air over the edge of the level (the Save Fairy in LS104
-- stood near a drop, and the first run drowned there).
local APPROACH = { 400, 300, 200, 120 }
local UP = 150         -- the trace starts this far above the spot
local DOWN = 130       -- and ends this far below the character centre: deeper than that is the floor below
                       -- its ledge, not the ground it is standing on (LS104 traced 320 units down to the
                       -- water under the Save Fairy, 2026-09-20)
local CLEARANCE = 5    -- above the floor, so the teleport is not inside it
local MIN_GAP = 110    -- last resort: right next to the character, far enough that the capsules do not overlap
local RANGE = 30000    -- ignore characters further than this from the player (other levels enemies)
-- Scripts per kind of character, by the letter in its class name (BP_CES1015_Ram_C, BP_CNS3706_Hunter_C).
local ENEMY_SCRIPTS = { "walk", "flame", "charge" }
local NPC_SCRIPTS = { "walk", "enterPlay" }

local requested = false
local nextPoll = 0

local function className(actor)
    local ok, name = pcall(function() return actor:GetClass():GetFName():ToString() end)
    return ok and name or nil
end

-- Which class and script pairs this level already has a stop for, so scanning twice doesn't duplicate
-- anything and a second scan only adds the scripts that were missing.
local function covered(level)
    local seen = {}
    for _, stop in ipairs(routes.all()) do
        if stop.level == level then
            seen[stop.script .. " " .. (stop.note:match("^([^%s]+)") or stop.note)] = true
        end
    end
    return seen
end

-- An NPC (CNS) or a piece of fauna (CFS) is talked to; an enemy or boss (CES, CBS) is walked into, flamed
-- and charged. A class that doesn't follow the naming (SaveFairy_C, the playable characters,
-- level-specific Blueprints) is told apart by whether it has a Falcon enemy state component.
local function scriptsFor(actor, class)
    if class:find("CNS") or class:find("CFS") then return NPC_SCRIPTS end
    if class:find("CES") or class:find("CBS") then return ENEMY_SCRIPTS end
    local isEnemy = pcall(function() return actor.FalconEnemy:BP_GetCurrentStateName():ToString() end)
    return isEnemy and ENEMY_SCRIPTS or NPC_SCRIPTS
end

-- Ground under a spot (lib/ground.lua), or nil for thin air: the edge of the level, water, the far side
-- of a rooftop.
local function groundZ(pawn, x, y, z)
    return ground.zAt(pawn, x, y, z, UP, DOWN)
end

-- A spot in front of the character with ground under it: the approach distances are tried in turn, so a
-- character standing near an edge gets a closer stop instead of one over the drop. If none of them has
-- ground, the stop goes right next to the character, MIN_GAP away so the two capsules don't overlap:
-- it is standing on something, so that spot has ground by definition.
local function groundedSpot(pawn, loc, forward, halfHeight, actorHalfHeight)
    -- A capsule stands on its centre, so the stop is half a capsule above the floor: teleporting to the
    -- floor itself puts him inside it, and the engine drops him from wherever it pushes him out to.
    local stand = halfHeight + CLEARANCE
    for _, distance in ipairs(APPROACH) do
        local x, y = loc.X + forward.X * distance, loc.Y + forward.Y * distance
        local z = groundZ(pawn, x, y, loc.Z)
        if z then return { x = x, y = y, z = z + stand, distance = distance } end
    end
    -- Beside it, on the floor it is standing on itself.
    return { x = loc.X + forward.X * MIN_GAP, y = loc.Y + forward.Y * MIN_GAP,
             z = loc.Z - actorHalfHeight + stand, distance = MIN_GAP, beside = true }
end

local function halfHeightOf(actor)
    local ok, half = pcall(function() return actor.CapsuleComponent:GetScaledCapsuleHalfHeight() end)
    return (ok and type(half) == "number") and half or 50
end

local function consider(actor, pawn, level, origin, here, seen, playerHalf)
    local class = className(actor)
    local loc = actor:K2_GetActorLocation()
    local dist = math.sqrt((loc.X - here.X) ^ 2 + (loc.Y - here.Y) ^ 2)
    if not class or dist > RANGE then return 0 end
    local wanted = {}
    for _, script in ipairs(scriptsFor(actor, class)) do
        if not seen[script .. " " .. class] then wanted[#wanted + 1] = script end
    end
    if #wanted == 0 then return 0 end
    -- In front of it, facing it: every script starts by walking straight in.
    local spot = groundedSpot(pawn, loc, actor:GetActorForwardVector(), playerHalf, halfHeightOf(actor))
    local rot = actor:K2_GetActorRotation()
    local written = 0
    for _, script in ipairs(wanted) do
        seen[script .. " " .. class] = true
        local stop = {
            level = level, x = spot.x, y = spot.y, z = spot.z,
            yaw = rot.Yaw + 180, ctrlPitch = 0, ctrlYaw = rot.Yaw + 180,
            originX = origin.X, originY = origin.Y,
            script = script, note = class,
        }
        if routes.add(stop) then written = written + 1 end
    end
    if written > 0 then
        log("scan: %s %d stops (%s) %.0f units in front of it%s at (%.0f, %.0f, %.0f), %.0f units from the player",
            class, written, table.concat(wanted, ", "), spot.distance,
            spot.beside and " (no ground further out, so right next to it)" or "",
            spot.x, spot.y, spot.z, dist)
    end
    return written
end

local function record(pawn, pc)
    local level, origin = levels.current(pawn)
    if not (level and origin) then
        log("scan: the level name or placement is unavailable here")
        return
    end
    local seen = covered(level)
    local playerAddress = pawn:GetAddress()
    local found, written, skipped = 0, 0, 0
    local here = pawn:K2_GetActorLocation()
    local playerHalf = halfHeightOf(pawn)

    for _, actor in ipairs(FindAllOf(CLASS) or {}) do
        local ok = pcall(function() return actor:IsValid() end) and actor:IsValid()
        local name = ok and actor:GetFName():ToString() or nil
        if ok and name and not name:match("^Default__") and actor:GetAddress() ~= playerAddress then
            found = found + 1
            local okConsider, result = pcall(consider, actor, pawn, level, origin, here, seen, playerHalf)
            if okConsider and (result or 0) > 0 then
                written = written + result
            else
                skipped = skipped + 1
            end
        end
    end
    log("scan: %s: %d characters, %d new stops, %d characters skipped (already covered, out of range or no ground)",
        level, found, written, skipped)
end

function scan.request()
    requested = true
end

-- Called once per frame from main.lua's sample().
function scan.update(pawn, pc)
    if os.clock() >= nextPoll then
        nextPoll = os.clock() + 1
        local f = io.open(TRIGGER, "r")
        if f then
            f:close()
            os.remove(TRIGGER)
            requested = true
        end
    end
    if not requested then return end
    requested = false
    local ok, err = pcall(record, pawn, pc)
    if not ok then log("scan error: %s", tostring(err)) end
end

return scan
