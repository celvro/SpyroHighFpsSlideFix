-- Which stops a world tour covers, in what order and at which framerates, and how far through them it
-- has got.
--
-- A level is run at every framerate before the run moves on: all of LS301 at 30 FPS, the same stops and
-- the same inputs at 320, then LS302. The two passes of a level are minutes apart in one session rather
-- than hours apart either side of a restart, and stopping half way leaves whole levels measured at both
-- framerates instead of a 30 FPS pass with nothing to compare against. Stop numbers are the route's own
-- (tools/routes.lua), so segments of a run line up with each other in the CSVs.
--
-- Progress is written to autotest_progress.txt after every stop, so a crash or a restart
-- (tools/Restart-Game.ps1 with lib/resume.lua) picks the run up where it stopped.
local log = require("lib.log")
local paths = require("lib.paths")
local routes = require("tools.routes")
local scripts = require("tools.worldtour.scripts")

local plan = {}

local CAPS = { 30, 60, 144, 320 }
local REVIEW_CAPS = "30" -- a review is somebody watching, and what they judge is the spot, not the framerate
-- Spyro's own abilities, run once each at the start of every level at every framerate, on the first
-- stop's spot. Running them at every character instead measured the same thing fifty times a level and
-- was most of what a tour spent its hours on.
local LEAD_SCRIPTS = { "flame", "charge", "hop", "glide" }
local PROGRESS = paths.modDir .. "\\autotest_progress.txt"

-- "walk" or "walk,enterPlay": which scripts this run covers, so a route of a thousand stops can be cut
-- down to the ones worth the hours (the walks that start a chase, the dialogue that starts a minigame).
local function wantedScripts(text)
    if not text then return nil end
    local set = {}
    for name in tostring(text):gmatch("[^,]+") do set[(name:gsub("%s", ""))] = true end
    return set
end

-- Sparx fodder: the critters the game files prefix CFS, and the goats and sheep. 158 of the route's
-- stops stand in front of one, and what they do is a walk cycle and a death -- nothing a minigame or an
-- NPC does not already cover, and none of them is a character whose animations this is about.
local FODDER = { "CFS", "GoatSheep" }

local function fodder(note)
    for _, name in ipairs(FODDER) do
        if tostring(note):find(name, 1, true) then return true end
    end
    return false
end

-- The other playable characters. Walking into one starts its minigame and hands the controller over,
-- which is the only way into a subworld: the tour cannot record a stop inside one, because it is not
-- running when the level is scanned. The scan gave most of them a plain walk, which stops short of the
-- conversation, so they are promoted to enterPlay.
local SUBWORLD_ENTRIES = { "Sheila", "SgtByrd", "Bentley", "Agent9" }

local function subworldEntry(note)
    for _, name in ipairs(SUBWORLD_ENTRIES) do
        if tostring(note):find(name, 1, true) then return true end
    end
    return false
end

-- The stops this run covers, { stop, id } each, in level order so each level is travelled to once.
-- routes.txt is read again, so edits made to it between runs count.
function plan.stops(options)
    routes.load()
    local all, picked, promoted, skipped = routes.all(), {}, 0, 0
    local only = wantedScripts(options.script)
    local game = tonumber(options.game)
    -- A walk stop in front of a character that also has an enterPlay stop does the same thing twice:
    -- enterPlay opens by walking into that character for two and a half seconds. 332 of the route's 707
    -- walks are those, and they are also the stops most likely to open a conversation and cost the run a
    -- level reload. The enterPlay stop covers the walk-in, so the walk on its own is dropped.
    local alsoTalks = {}
    for _, stop in ipairs(all) do
        if stop.script == "enterPlay" then alsoTalks[stop.level .. "|" .. stop.note] = true end
    end
    for index, stop in ipairs(all) do
        local duplicateWalk = stop.script == "walk" and alsoTalks[stop.level .. "|" .. stop.note]
            and not subworldEntry(stop.note)
        -- Zoe, the save fairies and Moneybags used to be watched from where they stood rather than
        -- walked into: their prompt pauses the world, and a paused world stopped this mod before it
        -- could press anything. main.lua now presses Continue while paused (lib/dialogue.lua), so they
        -- are walked into and talked to like everybody else.
        local script = stop.script
        if script == "walk" and subworldEntry(stop.note) then script = "enterPlay" end
        local wanted = (not options.level or stop.level == options.level)
            and (not game or stop.level:match("^LS(%d)") == tostring(game))
            and (not only or only[stop.script])
            and not duplicateWalk
        if wanted and fodder(stop.note) then
            wanted, skipped = false, skipped + 1
        end
        if wanted then
            if scripts.exists(script) then
                if script ~= stop.script then
                    local copy = {}
                    for key, value in pairs(stop) do copy[key] = value end
                    copy.script = script
                    stop = copy
                    promoted = promoted + 1
                end
                picked[#picked + 1] = { stop = stop, id = index }
            else
                log("autotest: stop %d (%s) has no script %q, skipped", index, stop.level, tostring(script))
            end
        end
    end
    if skipped > 0 then log("autotest: %d fodder stop(s) skipped", skipped) end
    if promoted > 0 then log("autotest: %d walk stop(s) in front of a minigame character played as enterPlay", promoted) end
    -- A review judges the spot -- how close he gets, which way he faces, whether the conversation
    -- opens -- and a spot's flame and charge stops stand on exactly the same one. So a review keeps one
    -- stop per spot, the one that walks in: enterPlay where the character has one, walk otherwise.
    if options.review and not options.all then
        local rank = { enterPlay = 1, walk = 2, flame = 3, charge = 4 }
        local best, order = {}, {}
        for _, entry in ipairs(picked) do
            local s = entry.stop
            local key = string.format("%s|%.0f|%.0f|%s", s.level, s.x or 0, s.y or 0, tostring(s.note))
            local have = best[key]
            if not have then
                best[key] = entry
                order[#order + 1] = key
            elseif (rank[s.script] or 9) < (rank[have.stop.script] or 9) then
                best[key] = entry
            end
        end
        local before = #picked
        picked = {}
        for _, key in ipairs(order) do picked[#picked + 1] = best[key] end
        log("autotest: review keeps one stop per spot, %d of %d", #picked, before)
    end
    table.sort(picked, function(a, b)
        if a.stop.level ~= b.stop.level then return a.stop.level < b.stop.level end
        return a.id < b.id
    end)
    return picked
end

-- The framerates a run plays each level at: caps=30,144 (0 is uncapped), else 30 for a review and all
-- of CAPS for anything else.
function plan.caps(options)
    local caps = {}
    for value in tostring(options.caps or (options.review and REVIEW_CAPS or "")):gmatch("[^,]+") do
        local n = tonumber(value)
        if n then caps[#caps + 1] = n end
    end
    return #caps > 0 and caps or CAPS
end

-- Every (stop, cap) in run order, { entry = { stop, id }, cap, measure } each: one level at a time, at
-- every framerate, before the next. measure is true on the lead stops at the head of each level.
function plan.build(stops, caps, noLead)
    local steps = {}
    local index = 1
    while index <= #stops do
        local level = stops[index].stop.level
        local last = index
        while last < #stops and stops[last + 1].stop.level == level do last = last + 1 end
        for _, cap in ipairs(caps) do
            -- Spyro's own abilities, once each at the start of the level, on the first stop's spot:
            -- flame, charge, a short hop and a glide. These are what the camera and jump trackers are
            -- for, and they belong to the level rather than to whichever character is standing there,
            -- so they are run once instead of at every stop. They come first, before any stop can walk
            -- into an NPC and start a conversation that would eat the inputs.
            -- A review is about the characters' spots, so it leaves these out (noLead).
            for _, script in ipairs(noLead and {} or LEAD_SCRIPTS) do
                local stop = {}
                for key, value in pairs(stops[index].stop) do stop[key] = value end
                stop.script = script
                stop.note = "Spyro " .. script
                steps[#steps + 1] = { entry = { stop = stop, id = stops[index].id }, cap = cap, measure = true }
            end
            for i = index, last do
                steps[#steps + 1] = { entry = stops[i], cap = cap }
            end
        end
        index = last + 1
    end
    return steps
end

-- The file's first number is left over from when a run did one framerate at a time; only the index
-- into the steps is read back.
function plan.saveProgress(index)
    local file = io.open(PROGRESS, "w")
    if not file then return end
    file:write(string.format("%d %d\n", 1, index))
    file:close()
end

function plan.savedIndex()
    local file = io.open(PROGRESS, "r")
    if not file then return 0 end
    local line = file:read("l") or ""
    file:close()
    return tonumber(line:match("^%d+%s+(%d+)")) or 0
end

function plan.forgetProgress()
    os.remove(PROGRESS)
end

return plan
