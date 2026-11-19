-- Puts the level's characters back the way they were when a take was recorded, for a replay or a PgUp
-- reset (tools/replay.lua, config REPLAY_ACTOR_START).
--
-- The replay's sublevel reload brings every enemy and NPC back fresh: alive, on its spawn point. A take
-- recorded after some wandering and some fighting started from a different level: enemies already dead,
-- and wanderers somewhere else (take LS213_20261119_143909: 30 of 55 characters started 28-799 units
-- from where the recording had them, cowleks up to 799, Sergeant Tub back on his cannon). Revived enemies
-- get in the way, and displaced ones meet Spyro at other times, so the replay stops being the take.
--
-- The recording traces every character (lib/actortrace.lua, replay_<take>_ref_actors.csv): the "# actor"
-- list is who was in the level when it started and whether each was dead, and each one's first row is
-- where it stood. A killed enemy is not removed from the level: it stays as a dead actor (IsDead), which is
-- why the state is in the list (take LS213_20261119_145336: the birds killed before it were still listed,
-- revived by the reload, and bombed Spyro in the replay). So:
--   removeAbsent  after the reload: every character the recording did not have, or had dead, is destroyed.
--                 Matched by actor name; placed actors keep theirs through the reload.
--   place         when the take starts playing (or the reset has settled): every character the recording
--                 had alive is teleported to its first row (position, yaw where the take has it, velocity).
-- What cannot be put back is each one's AI state (its wander target, its timers), so a wanderer can still
-- choose differently later; tools/Compare-ReplayActors.ps1 shows when each one parts from the recording.
--
--   "replay: start state" lines  how many were removed and placed, and any the recording had that the
--                                level does not
local log = require("lib.log")
local paths = require("lib.paths")

local actorstart = {}

local function alive(object)
    if object == nil then return false end
    local ok, valid = pcall(function() return object:IsValid() end)
    return ok and valid == true
end

-- The recording's start state: { names = { [name] = class }, dead = { [name] = true }, first = { [name] = row },
-- count, dt }, or nil when the take has no character trace (takes recorded before 2026-11-19). Takes from
-- before the dead/alive field count everyone listed as alive.
function actorstart.read(takeId)
    local path = string.format("%s\\replay_%s_ref_actors.csv", paths.modDir, takeId)
    local file = io.open(path, "r")
    if not file then return nil end
    local names, dead, count, first, found = {}, {}, 0, {}, 0
    local t0, dt = nil, nil
    for line in file:lines() do
        if line:sub(1, 8) == "# actor," then
            local name, class, state = line:match("^# actor,([^,]*),([^,]*),?([^,]*)")
            if name then
                names[name], count = class, count + 1
                if state == "dead" then dead[name] = true end
            end
        elseif line:sub(1, 2) ~= "t," then
            local t, name, x, y, z, vx, vy, vz, mode, yaw =
                line:match("^([^,]*),([^,]*),([^,]*),([^,]*),([^,]*),([^,]*),([^,]*),([^,]*),([^,]*),?([^,]*)")
            t = tonumber(t)
            if t then
                t0 = t0 or t
                if t ~= t0 and not dt then dt = t - t0 end
            end
            if name and names[name] and not first[name] then
                first[name] = { x = tonumber(x), y = tonumber(y), z = tonumber(z), vx = tonumber(vx), vy = tonumber(vy),
                                vz = tonumber(vz), mode = tonumber(mode), yaw = tonumber(yaw) }
                found = found + 1
            end
            -- Every character's first row is in the first frame; the second frame's time gives its length.
            if found >= count and dt then break end
        end
    end
    file:close()
    if count == 0 then return nil end
    return { names = names, dead = dead, first = first, count = count, dt = dt or 0 }
end

local function characters(pawn)
    local skip = nil
    pcall(function() skip = pawn:GetAddress() end)
    local list = {}
    for _, actor in ipairs(FindAllOf("Character") or {}) do
        local ok, name = pcall(function()
            if not actor:IsValid() or actor:GetAddress() == skip then return nil end
            local n = actor:GetFName():ToString()
            if n:match("^Default__") then return nil end
            return n
        end)
        if ok and name then list[#list + 1] = { actor = actor, name = name } end
    end
    return list
end

-- Destroys every character the recording did not have, or had dead. Returns the names.
function actorstart.removeAbsent(start, pawn)
    local removed = {}
    for _, c in ipairs(characters(pawn)) do
        if (not start.names[c.name] or (start.dead and start.dead[c.name])) and alive(c.actor) then
            if pcall(function() c.actor:K2_DestroyActor() end) then removed[#removed + 1] = c.name end
        end
    end
    return removed
end

-- Teleports every character the recording had to its first row. `origin` is the level origin ({ x, y }).
-- Returns placed (count), missing (names the recording had and the level does not).
function actorstart.place(start, origin, pawn)
    local placed, seen = 0, {}
    for _, c in ipairs(characters(pawn)) do
        local row = not (start.dead and start.dead[c.name]) and start.first[c.name] or nil
        if row and alive(c.actor) then
            seen[c.name] = true
            local ok = pcall(function()
                local actor = c.actor
                local rot = actor:K2_GetActorRotation()
                local yaw = row.yaw or rot.Yaw
                -- The first row is where it was at the END of the recording's first frame, and the replay's
                -- first frame moves it on from here: so one recorded frame back along its velocity (a falcon at
                -- 347 units/s started 11.7 units ahead without this, a cowlek 1.8).
                local back = start.dt or 0
                local x = row.x - (row.vx or 0) * back
                local y = row.y - (row.vy or 0) * back
                local z = row.z - (row.vz or 0) * back
                -- A fresh table for the hit out-param every call (CLAUDE.md: a reused one comes back filled).
                actor:K2_SetActorLocationAndRotation({ X = x + origin.x, Y = y + origin.y, Z = z },
                    { Pitch = rot.Pitch, Yaw = yaw, Roll = rot.Roll }, false, {}, true)
                local cmc = actor.CharacterMovement
                if cmc and cmc:IsValid() then cmc.Velocity = { X = row.vx or 0, Y = row.vy or 0, Z = row.vz or 0 } end
            end)
            if ok then placed = placed + 1 end
        end
    end
    local missing = {}
    for name in pairs(start.first) do
        if not seen[name] and not (start.dead and start.dead[name]) then missing[#missing + 1] = name end
    end
    table.sort(missing)
    return placed, missing
end

-- Both for tools/replay.lua, with their log lines. Never raise.
function actorstart.removeAndLog(start, pawn, level)
    if not start then return end
    local ok, removed = pcall(actorstart.removeAbsent, start, pawn)
    if not ok then
        log("replay: start state: removing the characters dead at the take's start failed: %s", tostring(removed))
        return
    end
    log("replay: start state: %d character(s) dead or absent at the take's start removed in %s%s", #removed, tostring(level),
        #removed > 0 and (": " .. table.concat(removed, ", ")) or "")
end

function actorstart.placeAndLog(start, origin, pawn)
    if not start then return end
    local ok, placed, missing = pcall(actorstart.place, start, origin, pawn)
    if not ok then
        log("replay: start state: placing the characters failed: %s", tostring(placed))
        return
    end
    log("replay: start state: %d of %d character(s) put where the recording started them%s", placed, start.count,
        #missing > 0 and ("; not in the level: " .. table.concat(missing, ", ")) or "")
end

return actorstart
