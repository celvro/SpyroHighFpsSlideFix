-- The tour's stops: places to stand, with the input script to play there (tools/scripts.lua).
--
-- Stops are recorded in game with M (stand where the test should start, facing the way it should run,
-- then press M) and kept in routes.txt in this mod folder, one per line:
--
--   level|x|y|z|yaw|ctrlPitch|ctrlYaw|originX|originY|script|note
--
-- M records the spot with the "walk" script; open routes.txt and change that word to any script name in
-- tools/scripts.lua ("jump", "glide", "charge", "enterPlay", ...), and the note to whatever the stop is
-- ("in front of Hunter"). One place can have several lines with different scripts.
--
-- Positions are stored relative to the level's own LevelTransform, like the quicksave spot, because a
-- level streams in at a different offset each load (see tools/quicksave.lua).
local levels = require("lib.levels")
local log = require("lib.log")
local paths = require("lib.paths")

local routes = {}

local FILE = paths.modDir .. "\\routes.txt"
local LEVEL_OFFSET = 300000
local DEFAULT_SCRIPT = "walk"

local stops = {}
local loaded = false

local function parse(line)
    local f = {}
    for field in line:gmatch("[^|]+") do f[#f + 1] = field end
    if #f < 9 then return nil end
    local x, y = tonumber(f[2]), tonumber(f[3])
    if not (x and y) then return nil end
    return {
        level = f[1], x = x, y = y, z = tonumber(f[4]),
        yaw = tonumber(f[5]) or 0, ctrlPitch = tonumber(f[6]) or 0, ctrlYaw = tonumber(f[7]) or 0,
        originX = tonumber(f[8]) or math.floor(x / LEVEL_OFFSET + 0.5) * LEVEL_OFFSET,
        originY = tonumber(f[9]) or math.floor(y / LEVEL_OFFSET + 0.5) * LEVEL_OFFSET,
        script = (f[10] or DEFAULT_SCRIPT):gsub("%s+$", ""),
        note = (f[11] or ""):gsub("%s+$", ""),
    }
end

function routes.load()
    stops, loaded = {}, true
    local file = io.open(FILE, "r")
    if not file then return stops end
    for line in file:lines() do
        if not line:match("^%s*#") and line:match("%S") then
            local stop = parse(line)
            if stop then stops[#stops + 1] = stop else log("routes: can't read %q", line) end
        end
    end
    file:close()
    log("routes: %d stops in routes.txt", #stops)
    return stops
end

local function append(stop)
    local file = io.open(FILE, "a")
    if not file then
        log("routes: could not write %s", FILE)
        return false
    end
    file:write(string.format("%s|%.3f|%.3f|%.3f|%.3f|%.3f|%.3f|%.1f|%.1f|%s|%s\n",
        stop.level, stop.x, stop.y, stop.z, stop.yaw, stop.ctrlPitch, stop.ctrlYaw,
        stop.originX, stop.originY, stop.script, stop.note))
    file:close()
    return true
end

-- M: records where the character stands now. Call from the game thread.
function routes.record(pawn, pc, r)
    local level, origin = levels.current(pawn)
    if not (level and origin) then
        log("routes: the level name or placement is unavailable here")
        return
    end
    if not loaded then routes.load() end
    local rot = pawn:K2_GetActorRotation()
    local ctrl = pc:GetControlRotation()
    local stop = {
        level = level, x = r.x, y = r.y, z = r.z, yaw = rot.Yaw,
        ctrlPitch = ctrl.Pitch, ctrlYaw = ctrl.Yaw, originX = origin.X, originY = origin.Y,
        script = DEFAULT_SCRIPT, note = string.format("stop %d", #stops + 1),
    }
    if not append(stop) then return end
    stops[#stops + 1] = stop
    log("routes: recorded %s stop %d at (%.0f, %.0f, %.0f) facing %.0f, script %s (edit routes.txt to change it)",
        level, #stops, stop.x, stop.y, stop.z, stop.yaw, stop.script)
end

-- Adds a stop straight from its fields (tools/scan.lua builds them from the characters in the level).
function routes.add(stop)
    if not loaded then routes.load() end
    if not append(stop) then return false end
    stops[#stops + 1] = stop
    return true
end

-- Every stop, in the order they were recorded.
function routes.all()
    if not loaded then routes.load() end
    return stops
end

-- The levels that have stops, in level order.
function routes.levelNames()
    local seen, names = {}, {}
    for _, stop in ipairs(routes.all()) do
        if not seen[stop.level] then
            seen[stop.level] = true
            names[#names + 1] = stop.level
        end
    end
    table.sort(names)
    return names
end

-- Where a stop is in the level as it is placed right now.
function routes.place(stop, origin)
    return stop.x - stop.originX + origin.X, stop.y - stop.originY + origin.Y, stop.z
end

return routes
