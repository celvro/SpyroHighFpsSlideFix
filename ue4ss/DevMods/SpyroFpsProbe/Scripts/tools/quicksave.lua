-- Quicksave testing aid (V / B / L / N). Saving the game's own state needs a restart
-- (tools/Save-GameSnapshot.ps1), so this is the fast version:
--   V  remembers where Spyro stands (one spot, kept in spots.txt so it survives restarts and redeploys)
--   B  puts him back there, travelling to the spot's level first if he is elsewhere
--   L  reloads the current level's gameplay sublevels (respawning enemies, resetting mechanisms), then
--      teleports him to the spot if it belongs to this level
--   N  dumps the GlobalTransporter actor and lists the level data tables
-- Only position, facing and camera yaw are restored, not velocity or ability state: save while standing still.
-- The spot is kept relative to its level's LevelTransform: the same level streams in at a different offset
-- (a multiple of LEVEL_OFFSET) from one load to the next.
local dump = require("lib.dump")
local levels = require("lib.levels")
local log = require("lib.log")
local paths = require("lib.paths")
local util = require("lib.util")

local asString, tryCall, describeOut = util.asString, util.tryCall, util.describeOut

local RELOAD_TIMEOUT = 60 -- seconds before a stuck reload gives up and puts everything back
local RELOAD_SETTLE = 0.5 -- seconds after the sublevels are back (or the travel arrives) before Spyro is put down
local TRAVEL_TIMEOUT = 30 -- seconds before a travel that never arrives is given up on
local STREAM_DATA_TABLE = "/GameplayCommon/LevelMechanics/LevelStreaming/StreamingData/LevelStreams/Spyro1_StreamData.Spyro1_StreamData"
local LEVEL_OFFSET = 300000 -- GlobalTransporter LevelOffset: levels are placed on this grid
-- The sublevels L reloads. Art, lighting, audio and the Transport levels are left alone.
local RELOAD_SUFFIXES = { design = true, enemy = true, loot = true, cinematics = true }

local quicksave = {}

local spot = nil     -- the one saved spot
local travel = nil   -- a StartAtLevelCheckpoint travel in progress, waiting to teleport on arrival
local reload = nil   -- a level reload in progress, waiting to teleport back to the spot
local request = nil  -- "save", "load", "reload" or "transporter", set by a key and handled in the game thread

-- Loads the saved spot from spots.txt (at startup).
function quicksave.load()
    local file = io.open(paths.spots, "r")
    if not file then return end
    local line = file:read("l")
    file:close()
    local fields = {}
    for field in (line or ""):gmatch("[^|]+") do table.insert(fields, field) end
    if #fields < 9 then return end
    local x, y = tonumber(fields[2]), tonumber(fields[3])
    spot = {
        level = fields[1],
        x = x, y = y, z = tonumber(fields[4]),
        pitch = tonumber(fields[5]), yaw = tonumber(fields[6]), roll = tonumber(fields[7]),
        ctrlPitch = tonumber(fields[8]), ctrlYaw = tonumber(fields[9]),
        -- The level's LevelTransform when it was saved; older spots.txt files without it are on the grid.
        originX = tonumber(fields[10]) or math.floor(x / LEVEL_OFFSET + 0.5) * LEVEL_OFFSET,
        originY = tonumber(fields[11]) or math.floor(y / LEVEL_OFFSET + 0.5) * LEVEL_OFFSET,
    }
    log("quicksave spot: %s at (%.0f, %.0f, %.0f)", spot.level, spot.x, spot.y, spot.z)
end

local function writeSpot()
    local file = io.open(paths.spots, "w")
    if not file then
        log("could not write %s", paths.spots)
        return
    end
    local s = spot
    file:write(string.format("%s|%.3f|%.3f|%.3f|%.3f|%.3f|%.3f|%.3f|%.3f|%.1f|%.1f\n",
        s.level, s.x, s.y, s.z, s.pitch, s.yaw, s.roll, s.ctrlPitch, s.ctrlYaw, s.originX, s.originY))
    file:close()
end

local function saveSpot(pawn, pc, r)
    local level, origin = levels.current(pawn)
    if not (level and origin) then
        log("quicksave: the level name or placement is unavailable")
        return
    end
    local rot = pawn:K2_GetActorRotation()
    local ctrl = pc:GetControlRotation()
    spot = {
        level = level, x = r.x, y = r.y, z = r.z,
        pitch = rot.Pitch, yaw = rot.Yaw, roll = rot.Roll,
        ctrlPitch = ctrl.Pitch, ctrlYaw = ctrl.Yaw,
        originX = origin.X, originY = origin.Y,
    }
    writeSpot()
    log("quicksave: %s at (%.0f, %.0f, %.0f) facing %.0f", level, r.x, r.y, r.z, rot.Yaw)
end

-- Puts Spyro on the saved spot. The caller makes sure its level is the one he is in (B travels first).
local function teleportToSpot(pawn, pc, cmc, what)
    if not spot then
        log("%s: nothing saved yet (press V to save a spot)", what)
        return false
    end
    -- Where the level is placed this time.
    local level, origin = levels.current(pawn)
    if level ~= spot.level or not origin then
        log("%s: can't place the %s spot (Spyro is in %s)", what, spot.level, tostring(level))
        return false
    end
    local x, y = spot.x - spot.originX + origin.X, spot.y - spot.originY + origin.Y
    -- K2_TeleportTo looks for room at the spot and returns false if it can't find any.
    local placed = pawn:K2_TeleportTo({ X = x, Y = y, Z = spot.z },
        { Pitch = spot.pitch, Yaw = spot.yaw, Roll = spot.roll })
    cmc.Velocity = { X = 0, Y = 0, Z = 0 }
    pc:SetControlRotation({ Pitch = spot.ctrlPitch, Yaw = spot.ctrlYaw, Roll = 0 })
    -- Without this the follow camera flies in from wherever it was; ResetBehind snaps it behind Spyro.
    if not tryCall("FollowCamera:ResetBehind", function() pawn.FollowCamera:ResetBehind(true) return true end) then
        tryCall("FollowCamera:SetCameraYaw", function() pawn.FollowCamera:SetCameraYaw(spot.yaw) return true end)
    end
    log("%s: %s at (%.0f, %.0f, %.0f)%s", what, spot.level, x, y, spot.z,
        placed == false and " (no room there; the engine moved him)" or "")
    return true
end

-- RestartLevel drops to the title screen in this game (tested 2026-09-17), and the persistent level is
-- shared by every level, so L reloads the current level's gameplay sublevels instead: it clears their
-- bShouldBeLoaded/bShouldBeVisible, waits for the engine to stream them out, sets the flags again and
-- waits for them back. Spyro is held in Flying (the ground under him goes away with LS###_design) and
-- teleported to the spot at the end.
local function reloadTargets(pawn, level)
    local targets = {}
    levels.each(pawn, function(sl, package)
        local prefix, suffix = levels.parts(package)
        if prefix == level and suffix and RELOAD_SUFFIXES[suffix:lower()] then
            table.insert(targets, { streaming = sl, package = package })
        end
    end)
    return targets
end

-- Streamed level instances are placed by LevelTransform; if a reload comes back with a different one,
-- everything in that sublevel (enemies, gems, the floor) lands away from the art levels.
local function logTargets(targets, when)
    for _, t in ipairs(targets) do
        local name = tryCall("LevelStreaming:GetFName", function() return t.streaming:GetFName():ToString() end)
        local translation = tryCall("LevelStreaming.LevelTransform", function()
            local tr = t.streaming.LevelTransform.Translation
            return string.format("(%.1f, %.1f, %.1f)", tr.X, tr.Y, tr.Z)
        end)
        log("  %s %s: instance=%s packageName=%s toLoad=%s transform=%s", when,
            (t.package:match("([^/]+)$")), tostring(name),
            tostring(asString(t.streaming.PackageName)), tostring(asString(t.streaming.PackageNameToLoad)),
            tostring(translation))
    end
end

local function setStreamingWanted(targets, wanted)
    for _, t in ipairs(targets) do
        t.streaming.bShouldBeLoaded = wanted
        t.streaming.bShouldBeVisible = wanted
    end
end

local function streamingAll(targets, read, want)
    for _, t in ipairs(targets) do
        local ok, value = pcall(read, t.streaming)
        if not ok or value ~= want then return false end
    end
    return true
end

local function requestReload(pawn)
    local level = levels.current(pawn)
    local targets = level and reloadTargets(pawn, level) or {}
    if #targets == 0 then
        log("reload: no gameplay sublevels found for %s", tostring(level))
        levels.dump(pawn)
        return
    end
    reload = { level = level, targets = targets, stage = "unloading", started = os.clock() }
    setStreamingWanted(targets, false)
    local names = {}
    for _, t in ipairs(targets) do table.insert(names, (t.package:match("([^/]+)$"))) end
    log("reload: streaming out %s", table.concat(names, ", "))
    logTargets(targets, "before")
end

-- Runs every frame while a reload is in progress: keeps Spyro up, waits out each streaming stage,
-- and puts him back on the ground at the end.
local function updateReload(pawn, pc, cmc, r)
    local s = reload
    if not s then return end
    local elapsed = os.clock() - s.started

    -- LS###_design holds the floor, so keep him flying in place until it is back.
    if r.mode ~= 5 then cmc:SetMovementMode(5, 0) end
    cmc.Velocity = { X = 0, Y = 0, Z = 0 }

    local function finish(what)
        setStreamingWanted(s.targets, true)
        reload = nil
        cmc:SetMovementMode(1, 0)
        log("reload: %s after %.1f s", what, elapsed)
        logTargets(s.targets, "after")
        -- Only put him on the spot if it belongs to this level; otherwise leave him where he reloaded.
        if spot and spot.level == s.level then teleportToSpot(pawn, pc, cmc, "reload") end
    end

    if elapsed > RELOAD_TIMEOUT then
        finish("gave up waiting")
        return
    end
    if s.stage == "unloading" then
        setStreamingWanted(s.targets, false) -- in case the game's own streaming re-enables them
        if streamingAll(s.targets, function(sl) return sl:IsLevelLoaded() end, false) then
            s.stage = "loading"
            setStreamingWanted(s.targets, true)
            log("reload: streamed out after %.1f s; streaming back in", elapsed)
        end
    elseif s.stage == "loading" then
        setStreamingWanted(s.targets, true)
        if streamingAll(s.targets, function(sl) return sl:IsLevelVisible() end, true) then
            s.stage, s.settled = "settling", 0
        end
    else
        s.settled = s.settled + r.dt
        if s.settled >= RELOAD_SETTLE then finish("done") end
    end
end

-- Travelling between levels goes through the GlobalTransporter actor: QueueStream(LevelStreamingRecord,
-- TransportType, RecordType) -> ConvertStreamData -> the native latent QueueTransport, which loads the
-- level's sublevels, unloads the current ones and moves the player. N dumps the actor (and its level
-- data table rows) so the record's real field names and a level row can be read.
local function dumpTransporter()
    local transporter = FindFirstOf("GlobalTransporter_C")
    if not transporter or not transporter:IsValid() then
        log("transporter: no GlobalTransporter_C found")
        return
    end
    log("transporter: %s", transporter:GetFullName())
    dump.write("transporter", dump.object(transporter))
    local tables = FindAllOf("DataTable") or {}
    for _, dt in ipairs(tables) do
        local ok, name = pcall(function() return dt:GetFullName() end)
        if ok and name:lower():match("level") then log("transporter: data table %s", name) end
    end
end

-- FindFirstOf can hand back the class default object, which would take the call and do nothing.
local function findTransporter()
    local instances = FindAllOf("GlobalTransporter_C") or {}
    for _, obj in ipairs(instances) do
        local ok, name = pcall(function() return obj:GetFullName() end)
        if ok and obj:IsValid() and not name:match("Default__") then return obj, name end
    end
    return nil
end

-- Travelling to another level: GlobalTransporter's StartAtLevelCheckpoint(Start Level, isRestart,
-- transitionType, checkpoint) is the game's own load-a-save path. It reads the level row (LevelMapPath
-- plus the LLxxx sublevel table), builds a record with UnloadCurrentLevels, and calls native StartAtLevel,
-- so lighting, music and game state follow. Rows in Spyro1_StreamData are named like our level keys (LS102).
local function travelToLevel(level)
    local transporter, transporterName = findTransporter()
    if not transporter then
        log("travel: no GlobalTransporter_C instance found")
        return false
    end
    local streamData = StaticFindObject(STREAM_DATA_TABLE)
    if not streamData or not streamData:IsValid() then
        log("travel: %s not found", STREAM_DATA_TABLE)
        return false
    end
    -- Does the table read back from Lua, and does it have this level's row?
    local rows = tryCall("DataTableFunctionLibrary:GetDataTableRowNames", function()
        local lib = StaticFindObject("/Script/Engine.Default__DataTableFunctionLibrary")
        local out = {}
        lib:GetDataTableRowNames(streamData, out)
        local names = out.OutRowNames or out.RowNames
        local count, found = 0, false
        if names then
            for _, n in ipairs(names) do
                count = count + 1
                if asString(n) == level then found = true end
            end
        end
        return { count = count, found = found, keys = describeOut(out) }
    end)
    log("travel: %s, table rows=%s row %s found=%s", tostring(transporterName),
        rows and tostring(rows.count) or "?", level, rows and tostring(rows.found) or "?")
    local ok, err = pcall(function()
        transporter:StartAtLevelCheckpoint({ DataTable = streamData, RowName = FName(level) }, false, 0, "")
    end)
    if not ok then
        log("travel: StartAtLevelCheckpoint failed: %s", tostring(err))
        return false
    end
    travel = { level = level, started = os.clock(), settled = 0 }
    log("travel: loading %s", level)
    return true
end

-- Once the target level is up and Spyro has control, put him on the saved spot.
local function updateTravel(pawn, pc, cmc, r)
    local s = travel
    if not s then return end
    if os.clock() - s.started > TRAVEL_TIMEOUT then
        travel = nil
        log("travel: %s never loaded (still in %s); StartAtLevelCheckpoint did nothing",
            s.level, tostring(levels.current(pawn)))
        return
    end
    if levels.current(pawn) ~= s.level then return end
    s.settled = (r.mode == 1 and not r.rootMotion) and s.settled + r.dt or 0
    if s.settled < RELOAD_SETTLE then return end
    travel = nil
    log("travel: arrived in %s after %.1f s", s.level, os.clock() - s.started)
    teleportToSpot(pawn, pc, cmc, "quickload")
end

-- V / B / L / N: the request is handled on the next sampled frame, in the game thread.
function quicksave.request(kind)
    request = kind
end

local function update(pawn, pc, cmc, r, kind)
    if kind == "save" then
        saveSpot(pawn, pc, r)
    elseif kind == "load" then
        -- B always goes to the saved spot, travelling to its level first when Spyro is elsewhere.
        if spot and spot.level ~= levels.current(pawn) then
            travelToLevel(spot.level)
        else
            teleportToSpot(pawn, pc, cmc, "quickload")
        end
    elseif kind == "reload" then
        requestReload(pawn)
    elseif kind == "transporter" then
        dumpTransporter()
    end
    updateReload(pawn, pc, cmc, r)
    updateTravel(pawn, pc, cmc, r)
end

function quicksave.update(pawn, pc, cmc, r)
    local kind = request
    request = nil
    local ok, err = pcall(update, pawn, pc, cmc, r, kind)
    if not ok then
        reload = nil
        log("quicksave error: %s", tostring(err))
    end
end

return quicksave
