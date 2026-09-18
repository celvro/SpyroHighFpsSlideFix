-- Which level Spyro is in, from the streamed sublevels.
--
-- Every level streams into one shared persistent level (GlobalPersistentLevel) as runtime
-- LevelStreamingKismet instances placed by their LevelTransform, so the level itself is whichever
-- LS### package is streamed in (e.g. /LS107_PeacekeeperHome/Maps/LS107_design -> LS107).
local UEHelpers = require("UEHelpers")
local log = require("lib.log")
local util = require("lib.util")

local asString, tryCall = util.asString, util.tryCall

local levels = {}

-- Runtime LevelStreamingKismet instances have an empty PackageName; the package is on the loaded
-- ULevel then (e.g. Level /LS107_PeacekeeperHome/Maps/LS107_design.…).
local function streamingPackage(sl)
    local name = asString(sl.PackageNameToLoad)
    if name and name ~= "" and name ~= "None" then return name end
    name = asString(sl.PackageName)
    if name and name ~= "" and name ~= "None" then return name end
    local ok, full = pcall(function()
        local level = sl.LoadedLevel
        return level:IsValid() and level:GetFullName() or nil
    end)
    return (ok and full) and full:match("([^%s]+)%.[^%.]*$") or nil
end

-- Calls fn(streamingLevel, package) for every streaming level of the pawn's world.
function levels.each(pawn, fn)
    local world = pawn:GetWorld()
    if not world:IsValid() then return end
    world.StreamingLevels:ForEach(function(_, element)
        local sl = element:get()
        if sl:IsValid() then fn(sl, streamingPackage(sl)) end
    end)
end

-- The level prefix and sublevel suffix of a streamed package, e.g. /LS104_Townsquare/Maps/LS104_design
-- -> "LS104", "design". Anything that isn't an LS### sublevel (GlobalPersistentLevel, LS104_ART_MASTER)
-- comes back nil.
function levels.parts(package)
    local base = package and package:match("([^/]+)$")
    if not base then return nil end
    local prefix, suffix = base:match("^(.-)_([^_]+)$")
    if not prefix or not prefix:match("^%a%a%d+$") then return nil end
    return prefix, suffix
end

local function levelTranslation(sl)
    return tryCall("LevelStreaming.LevelTransform", function()
        local t = sl.LevelTransform.Translation
        return { X = t.X, Y = t.Y }
    end)
end

-- Which level Spyro is in. Neighbouring levels keep a visible LS###_Transport sublevel (a homeworld has
-- several), so "the first visible LS### level" picks the wrong one; each level instance is placed by its
-- LevelTransform, so the level Spyro is actually in is the one he is nearest.
function levels.current(pawn)
    local best, bestDist
    tryCall("World.StreamingLevels", function()
        local loc = pawn:K2_GetActorLocation()
        levels.each(pawn, function(sl, package)
            local prefix = levels.parts(package)
            if not prefix then return end
            if tryCall("LevelStreaming:IsLevelVisible", function() return sl:IsLevelVisible() end) == false then return end
            local t = levelTranslation(sl)
            if not t then return end
            local dist = (loc.X - t.X) ^ 2 + (loc.Y - t.Y) ^ 2
            if not bestDist or dist < bestDist then best, bestDist = prefix, dist end
        end)
    end)
    if best then return best end
    return asString(tryCall("GetCurrentLevelName", function()
        return UEHelpers.GetGameplayStatics():GetCurrentLevelName(pawn, true)
    end))
end

function levels.dump(pawn)
    local level = levels.current(pawn)
    log("streaming levels (current level %s):", tostring(level))
    local count = 0
    levels.each(pawn, function(sl, package)
        count = count + 1
        local loaded = tryCall("LevelStreaming:IsLevelLoaded", function() return sl:IsLevelLoaded() end)
        local visible = tryCall("LevelStreaming:IsLevelVisible", function() return sl:IsLevelVisible() end)
        local levelName = tryCall("LevelStreaming.LoadedLevel", function()
            local loadedLevel = sl.LoadedLevel
            return loadedLevel:IsValid() and loadedLevel:GetFullName() or "none"
        end)
        log("  %s loaded=%s visible=%s shouldBeLoaded=%s shouldBeVisible=%s level=%s",
            tostring(package), tostring(loaded), tostring(visible),
            tostring(sl.bShouldBeLoaded), tostring(sl.bShouldBeVisible), tostring(levelName))
    end)
    log("streaming levels: %d", count)
end

return levels
