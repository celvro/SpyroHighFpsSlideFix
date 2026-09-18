-- Small helpers shared by the trackers: number and angle handling, the per-measurement stats
-- every summary line is built from, and the guarded call used for game functions that may not
-- exist in this build.
local log = require("lib.log")

local util = {}

util.MOVE_MODE_NAMES = { [0] = "None", "Walking", "NavWalking", "Falling", "Swimming", "Flying", "Custom" }

-- FindAllOf scans the whole object array, so a lookup only runs for a while after NotifyOnNewObject
-- reports the class loading (or the pawn changes): NEW_OBJECT_LOOKUPS lookups, LOOKUP_INTERVAL apart.
util.NEW_OBJECT_LOOKUPS = 15
util.LOOKUP_INTERVAL = 1.0

function util.isGrounded(mode)
    return mode == 1 or mode == 2 or mode == 4
end

-- Properties missing from this build come back as non-number objects; log them as NaN.
function util.num(v)
    return type(v) == "number" and v or 0 / 0
end

function util.csvValue(v)
    return v == nil and "" or tostring(v)
end

-- a - b in degrees, wrapped to [-180, 180).
function util.angleDiff(a, b)
    return (a - b + 180) % 360 - 180
end

function util.sign(v)
    return v < 0 and -1 or 1
end

function util.vecDist(a, b)
    local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
    return math.sqrt(dx * dx + dy * dy + dz * dz), math.sqrt(dx * dx + dy * dy)
end

-- UE4SS returns FString and FName as objects, not Lua strings; tostring() gives "FString: <address>".
function util.asString(v)
    if type(v) == "string" then return v end
    if v == nil then return nil end
    local ok, s = pcall(function() return v:ToString() end)
    return (ok and type(s) == "string") and s or nil
end

-- Describes an out-param table, for the errors of calls whose out-params land in unexpected places.
function util.describeOut(t)
    local parts = {}
    for k, v in pairs(t) do
        local x = type(v) ~= "number" and (pcall(function() return v.X end) and v.X) or nil
        table.insert(parts, string.format("%s=%s%s", tostring(k), tostring(v), x and string.format(" (X %s)", tostring(x)) or ""))
    end
    return "{" .. table.concat(parts, ", ") .. "}"
end

-- An FVector out-param: UE4SS may store it under the parameter name in any of the passed tables, or
-- write X/Y/Z into the table passed for it.
function util.outVector(tables, own, key)
    for _, t in ipairs(tables) do
        local v = t[key]
        if v ~= nil and type(v.X) == "number" then return v end
    end
    if type(own.X) == "number" then return own end
    return nil
end

local optional = {} -- per call name: true once it has worked, false if its first call failed

-- Calls a game function that may not exist or may not work from Lua. Returns nil on failure; the
-- first failure is logged, and a call that has never worked is not tried again.
function util.tryCall(name, fn)
    local known = optional[name]
    if known == false then return nil end
    local ok, value = pcall(fn)
    if ok then
        optional[name] = true
        return value
    end
    if known == nil then
        optional[name] = false
        log("%s unavailable: %s", name, tostring(value))
    end
    return nil
end

-- True when a FindAllOf lookup for `s` (a table with lookups/nextLookup) should run now.
function util.lookupDue(s, time)
    if s.lookups <= 0 or time < s.nextLookup then return false end
    s.lookups, s.nextLookup = s.lookups - 1, time + util.LOOKUP_INTERVAL
    return true
end

-- Every measurement (segment, drift, charge, turn, ...) accumulates these, so its summary line can
-- report the framerate it ran at next to what it measured.
function util.newStats(r)
    return { startTime = r.time, startX = r.x, startY = r.y, startZ = r.z, frames = 0, dtSum = 0, dtMin = math.huge, dtMax = 0 }
end

function util.addFrame(s, r)
    s.frames = s.frames + 1
    s.dtSum = s.dtSum + r.dt
    s.dtMin = math.min(s.dtMin, r.dt)
    s.dtMax = math.max(s.dtMax, r.dt)
end

function util.avgFps(s)
    return s.dtSum > 0 and s.frames / s.dtSum or 0 / 0
end

return util
