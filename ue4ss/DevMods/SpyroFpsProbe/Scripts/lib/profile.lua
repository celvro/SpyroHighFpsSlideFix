-- Optional per-tracker profiling (config.PROFILE): times each tracker's share of the frame and logs
-- a ranked summary every config.PROFILE_INTERVAL seconds, so the switches in config.lua can be set
-- from measurements rather than guesses.
--
-- The engine's clock is used rather than os.clock, which only has 1 ms resolution on Windows - a
-- whole frame at 320 FPS is 3.1 ms. Each timed call costs two clock reads, and the frame's own clock
-- cost is measured and subtracted, so the numbers are the trackers' and not the timer's. It is still
-- a measurement run: leave PROFILE off for anything that cares about the framerate it is measuring.
--
-- The window covers the sampled part of the frame: the registration calls at the top of sample()
-- (mouse, hits, glide, resume, dumpstate) run before the clock starts, so they are not in the total.
local config = require("config")
local log = require("lib.log")

local profile = {}

if not config.PROFILE then
    local function off() end
    profile.beginFrame, profile.endFrame = off, off
    function profile.wrap(_, module) return module end
    return profile
end

local buckets, order = {}, {} -- name -> { calls, cost }, and the order they were first wrapped in
local frames, frameTime, probeCost, maxCost, windowStart = 0, 0, 0, 0, nil
local frameStart, framePairs, clockCost = nil, 0, 0
local statics, context, failed

-- UE4SS fills out-params into the passed tables keyed by parameter name; in practice the second one
-- does not always land in its own table, so accept either field from either (as the fix mod's
-- profiler does). Reused at module level: two tables a read is garbage this is trying to measure.
local secondsOut, partialOut = {}, {}
local function accurateSeconds()
    secondsOut.Seconds, secondsOut.PartialSeconds = nil, nil
    partialOut.Seconds, partialOut.PartialSeconds = nil, nil
    statics:GetAccurateRealTime(context, secondsOut, partialOut)
    local whole = secondsOut.Seconds or partialOut.Seconds
    local fraction = partialOut.PartialSeconds or secondsOut.PartialSeconds
    if type(whole) ~= "number" or type(fraction) ~= "number" then
        error("GetAccurateRealTime gave no number")
    end
    return whole + fraction
end

local sorted = {}
local function logWindow(now)
    local n = frames
    local avgFrame = frameTime / n
    log("profile: %d frames (avg frame %.2f ms, %.0f FPS), probe avg %.3f ms/frame (%.1f%% of frame), max %.3f ms",
        n, avgFrame * 1000, n / (now - windowStart), probeCost / n * 1000,
        frameTime > 0 and probeCost / frameTime * 100 or 0, maxCost * 1000)
    local count = 0
    for _, name in ipairs(order) do
        if buckets[name].calls > 0 then
            count = count + 1
            sorted[count] = name
        end
    end
    for i = #sorted, count + 1, -1 do sorted[i] = nil end
    table.sort(sorted, function(a, b) return buckets[a].cost > buckets[b].cost end)
    local parts = {}
    for i, name in ipairs(sorted) do
        local b = buckets[name]
        parts[i] = string.format("%s %.3f", name, b.cost / n * 1000)
    end
    log("profile ms/frame: %s", table.concat(parts, ", "))
    for _, b in pairs(buckets) do b.calls, b.cost = 0, 0 end
    frames, frameTime, probeCost, maxCost, windowStart = 0, 0, 0, 0, now
end

-- Called at the top of a sampled frame, before any timed call: the clock needs a UObject context,
-- and two back-to-back reads give this frame's cost for one read.
function profile.beginFrame(pc, gameplayStatics)
    if failed then return end
    context, statics = pc, gameplayStatics
    local ok, t0 = pcall(accurateSeconds)
    if not ok then
        failed = true
        frameStart = nil
        log("profiling disabled after error: %s", tostring(t0))
        return
    end
    local t1 = accurateSeconds()
    clockCost = t1 - t0
    frameStart, framePairs = t1, 0
end

-- Called at the end of a sampled frame with the frame's delta time.
function profile.endFrame(dt)
    if failed or not frameStart then return end
    local now = accurateSeconds()
    -- Everything the probe did this frame, less the clock reads made inside it (two per timed call,
    -- plus this one).
    local cost = math.max(0, (now - frameStart) - clockCost * (framePairs * 2 + 1))
    frames, probeCost = frames + 1, probeCost + cost
    frameTime = frameTime + (type(dt) == "number" and dt or 0)
    if cost > maxCost then maxCost = cost end
    windowStart = windowStart or frameStart
    frameStart = nil
    if now - windowStart >= config.PROFILE_INTERVAL and frames > 0 then logWindow(now) end
end

-- Returns a stand-in for `module` whose functions are timed into one bucket named `name`. Returns at
-- most three values (trackers return none or, for supercharge.stage, two), and copies everything
-- that isn't a function straight across, so constants like stalls.CLASS still read as themselves.
function profile.wrap(name, module)
    local bucket = { calls = 0, cost = 0 }
    buckets[name] = bucket
    order[#order + 1] = name
    local wrapped = {}
    for key, value in pairs(module) do
        if type(value) == "function" then
            wrapped[key] = function(...)
                if failed or not frameStart then return value(...) end
                local t0 = accurateSeconds()
                local a, b, c = value(...)
                local t1 = accurateSeconds()
                bucket.calls = bucket.calls + 1
                bucket.cost = bucket.cost + math.max(0, (t1 - t0) - clockCost)
                framePairs = framePairs + 1
                return a, b, c
            end
        else
            wrapped[key] = value
        end
    end
    return wrapped
end

return profile
