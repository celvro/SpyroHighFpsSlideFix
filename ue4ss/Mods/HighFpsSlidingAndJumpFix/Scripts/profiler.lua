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
-- Per-fix allocation accounting (GC_PROFILE): how much Lua garbage each fix and each hook makes, so
-- the KB/frame the whole mod allocates can be pinned on the code that allocates it. `names` keeps the
-- order the fixes ran in, so the log line is stable; `lost` counts frames where a collection landed
-- inside a measured section and made its delta negative (that section's allocation can't be seen).
local allocProfile = { kb = {}, names = {}, total = 0, lost = 0 }
-- Hook callbacks (profiler.wrapHook) run outside the tick, so they are timed separately: name ->
-- { calls, cost, maxCall }, folded into the same window.
local hookProfile = {}

local function describeTable(t)
    local parts = {}
    for k, v in pairs(t) do parts[#parts + 1] = tostring(k) .. "=" .. tostring(v) end
    return "{" .. table.concat(parts, ", ") .. "}"
end

-- Allocation profiling is a GC_PROFILE extra: it costs two collectgarbage("count") calls per fix per
-- frame, so it is only on when both switches are.
local allocOn = config.PROFILE and config.GC_PROFILE

-- Brackets a section of the frame (a fix's update, a hook callback) so what it allocates is charged
-- to `name`. Returns nil when allocation profiling is off, and endAlloc then does nothing.
function profiler.startAlloc()
    if not allocOn then return nil end
    return collectgarbage("count")
end

-- `outside` is for sections that run outside the tick (hook callbacks): their allocation isn't part
-- of the tick's own delta, so it is added to the mod's total here.
function profiler.endAlloc(name, before, outside)
    if not before then return end
    local kb = collectgarbage("count") - before
    if kb >= 0 and outside then allocProfile.total = allocProfile.total + kb end
    if kb < 0 then
        -- A collection ran inside the section: it freed more than the section allocated, so there is
        -- no allocation figure to charge. Count the frame instead of guessing.
        allocProfile.lost = allocProfile.lost + 1
        return
    end
    local totals = allocProfile.kb
    if not totals[name] then allocProfile.names[#allocProfile.names + 1] = name end
    totals[name] = (totals[name] or 0) + kb
end

-- "name X.XX" for every section that allocated, biggest first, plus what the tick allocated outside
-- them (reading ctx, the profiler's own tables).
local allocOrder = {}
local function allocSummary(frames)
    local totals, attributed = allocProfile.kb, 0
    local n = 0
    for _, name in ipairs(allocProfile.names) do
        if totals[name] > 0 then
            n = n + 1
            allocOrder[n] = name
            attributed = attributed + totals[name]
        end
    end
    for i = #allocOrder, n + 1, -1 do allocOrder[i] = nil end
    table.sort(allocOrder, function(a, b) return totals[a] > totals[b] end)
    local parts = {}
    for _, name in ipairs(allocOrder) do
        parts[#parts + 1] = string.format("%s %.2f", name, totals[name] / frames)
    end
    parts[#parts + 1] = string.format("other %.2f", math.max(0, allocProfile.total - attributed) / frames)
    return string.format("%.2f KB/frame (%s)%s", allocProfile.total / frames, table.concat(parts, ", "),
        allocProfile.lost > 0 and string.format(", %d frame(s) not attributed (a collection landed inside)", allocProfile.lost) or "")
end

local function resetAlloc()
    for _, name in ipairs(allocProfile.names) do allocProfile.kb[name] = 0 end
    allocProfile.total, allocProfile.lost = 0, 0
end

-- The clock's out-params, reused: three reads a frame times two tables each is garbage the
-- collector would have to sweep up, which is exactly what the GC lines below are measuring.
local secondsOut, partialOut = {}, {}

local function accurateSeconds(statics, context)
    -- UE4SS fills out-params into the passed tables keyed by parameter name. In practice the
    -- second out-param did not land in its own table, so accept either field from either table.
    local seconds, partial = secondsOut, partialOut
    seconds.Seconds, seconds.PartialSeconds = nil, nil -- reused: don't answer with the last read
    partial.Seconds, partial.PartialSeconds = nil, nil
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
            -- The whole tick's allocation, for the "other" share left after the per-fix sections.
            -- A frame a collection ran in is skipped, the same way endAlloc skips one.
            if delta >= 0 then allocProfile.total = allocProfile.total + delta end
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
                log("gc alloc: %s", allocSummary(n))
                resetAlloc()
                if config.GC_FULL_COLLECT then
                    -- Timed with the same clock as the tick: the hitch this costs is the answer to
                    -- what a collection of a heap this size would cost if it landed during play.
                    local before = collectgarbage("count")
                    local started = accurateSeconds(statics, pc)
                    collectgarbage("collect")
                    local after = collectgarbage("count")
                    log("gc full collect: %.1f KB -> %.1f KB (freed %.1f KB) in %.1f ms",
                        before, after, before - after, (accurateSeconds(statics, pc) - started) * 1000)
                end
            end
            for name, h in pairs(hookProfile) do
                if h.calls > 0 then
                    log("profile hook %s: %d calls, avg %.3f ms/frame (%.2f%% of frame), avg %.3f ms/call, max %.3f ms",
                        name, h.calls, h.cost / n * 1000, h.cost / profile.frameTime * 100, h.cost / h.calls * 1000, h.maxCall * 1000)
                end
                h.calls, h.cost, h.maxCall = 0, 0, 0
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

-- Wraps a hook callback so its cost shows up in the profile window as its own line. Returns the
-- callback unchanged when profiling is off. The clock needs a context object: the player controller.
function profiler.wrapHook(name, callback)
    if not config.PROFILE then return callback end
    local h = { calls = 0, cost = 0, maxCall = 0 }
    hookProfile[name] = h
    local allocName = "hook " .. name
    local failed = false
    return function(...)
        local pc = not failed and engine.getPlayerController()
        if not pc then return callback(...) end
        local statics = engine.getGameplayStatics()
        local ok, t0 = pcall(accurateSeconds, statics, pc)
        if not ok then
            failed = true
            log("hook profiling disabled for %s after error: %s", name, tostring(t0))
            return callback(...)
        end
        local t1 = accurateSeconds(statics, pc)
        -- Hooks run outside the tick, so their allocation is charged here rather than to "other".
        local allocBefore = profiler.startAlloc()
        callback(...)
        profiler.endAlloc(allocName, allocBefore, true)
        local t2 = accurateSeconds(statics, pc)
        local cost = math.max(0, (t2 - t1) - (t1 - t0))
        h.calls, h.cost, h.maxCall = h.calls + 1, h.cost + cost, math.max(h.maxCall, cost)
    end
end

return profiler
