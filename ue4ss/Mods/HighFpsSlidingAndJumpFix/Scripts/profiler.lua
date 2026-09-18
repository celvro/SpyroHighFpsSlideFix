-- Optional profiling (config.PROFILE): times each frame's fix work with the engine's
-- high-resolution clock (os.clock only has 1 ms resolution on Windows) and logs a summary every
-- config.PROFILE_INTERVAL seconds. This excludes UE4SS's own hook overhead; measure that externally
-- by comparing frame times with and without dwmapi.dll.
local config = require("config")
local engine = require("lib.engine")
local log = require("lib.log")

local profiler = {}

local profile = { frames = 0, cost = 0, maxCost = 0, timerCost = 0, frameTime = 0, windowStart = nil }
-- GC investigation counters, folded into the same window. minDelta is the most negative
-- collectgarbage("count") change seen in one frame (the biggest apparent collection); maxCostGcDelta
-- is that same delta but specifically on the frame that had the window's maxCost, to see whether the
-- worst-cost frame is also the frame a collection landed in.
local gcProfile = { collections = 0, minDelta = nil, maxCostGcDelta = nil, totalDelta = 0 }

local function describeTable(t)
    local parts = {}
    for k, v in pairs(t) do parts[#parts + 1] = tostring(k) .. "=" .. tostring(v) end
    return "{" .. table.concat(parts, ", ") .. "}"
end

local function accurateSeconds(statics, context)
    -- UE4SS fills out-params into the passed tables keyed by parameter name. In practice the
    -- second out-param did not land in its own table, so accept either field from either table.
    local seconds, partial = {}, {}
    statics:GetAccurateRealTime(context, seconds, partial)
    local whole = seconds.Seconds or partial.Seconds
    local fraction = partial.PartialSeconds or seconds.PartialSeconds
    if type(whole) ~= "number" or type(fraction) ~= "number" then
        error("GetAccurateRealTime out-params: seconds=" .. describeTable(seconds) .. " partial=" .. describeTable(partial))
    end
    return whole + fraction
end

-- Wraps the mod's tick in the timing above, falling back to the plain tick if profiling itself breaks.
function profiler.wrap(runTick)
    local function profiledTick()
        local pc = engine.getPlayerController()
        if not pc then return runTick() end
        local statics = engine.getGameplayStatics()

        -- Two back-to-back clock reads measure the clock's own cost, which is subtracted from the
        -- measured tick (that interval also contains one clock call).
        local t0 = accurateSeconds(statics, pc)
        local t1 = accurateSeconds(statics, pc)
        local gcBefore = config.GC_PROFILE and collectgarbage("count") or nil
        runTick()
        local gcAfter = config.GC_PROFILE and collectgarbage("count") or nil
        local t2 = accurateSeconds(statics, pc)

        local timerCost = t1 - t0
        local cost = math.max(0, (t2 - t1) - timerCost)
        profile.frames = profile.frames + 1
        profile.cost = profile.cost + cost
        local isNewMax = cost > profile.maxCost
        profile.maxCost = math.max(profile.maxCost, cost)
        profile.timerCost = profile.timerCost + timerCost
        profile.frameTime = profile.frameTime + statics:GetWorldDeltaSeconds(pc)
        profile.windowStart = profile.windowStart or t0

        if config.GC_PROFILE then
            -- KB allocated this frame minus KB the collector reclaimed; negative means a collection ran
            -- and outpaced whatever we allocated (Lua's automatic collector runs synchronously inside
            -- whichever allocation crosses its threshold, so a big one shows up as extra cost above).
            local delta = gcAfter - gcBefore
            gcProfile.totalDelta = gcProfile.totalDelta + delta
            if delta <= -config.GC_COLLECTION_KB then gcProfile.collections = gcProfile.collections + 1 end
            gcProfile.minDelta = gcProfile.minDelta and math.min(gcProfile.minDelta, delta) or delta
            if isNewMax then gcProfile.maxCostGcDelta = delta end
        end

        if t2 - profile.windowStart >= config.PROFILE_INTERVAL then
            local n = profile.frames
            local avgFrame = profile.frameTime / n
            log("profile: %d frames (avg frame %.2f ms), fixes avg %.3f ms (%.2f%% of frame), max %.3f ms, clock overhead avg %.3f ms",
                n, avgFrame * 1000, profile.cost / n * 1000, profile.cost / profile.frameTime * 100,
                profile.maxCost * 1000, profile.timerCost / n * 1000)
            if config.GC_PROFILE then
                log("gc: %d frame(s) with a >=%.0f KB drop (%.2f/s), heap now %.1f KB, avg delta %.3f KB/frame, biggest drop %.1f KB, delta on max-cost frame %s",
                    gcProfile.collections, config.GC_COLLECTION_KB, gcProfile.collections / (avgFrame * n),
                    collectgarbage("count"), gcProfile.totalDelta / n, gcProfile.minDelta or 0,
                    gcProfile.maxCostGcDelta and string.format("%.1f KB", gcProfile.maxCostGcDelta) or "n/a")
                gcProfile.collections, gcProfile.minDelta, gcProfile.maxCostGcDelta, gcProfile.totalDelta = 0, nil, nil, 0
            end
            profile.frames, profile.cost, profile.maxCost, profile.timerCost, profile.frameTime = 0, 0, 0, 0, 0
            profile.windowStart = t2
        end
    end

    local profilingFailed = false
    return function()
        if profilingFailed then return runTick() end
        local ok, err = pcall(profiledTick)
        if not ok then
            profilingFailed = true
            log("profiling disabled after error: %s", tostring(err))
        end
    end
end

return profiler
