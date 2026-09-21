-- Level tour (T, or a tour.txt trigger file): travels through every level in the stream data table
-- (LS101 ... LS337), starting at the one Spyro is in, and stays DWELL seconds uncapped in each while
-- trackers/stalls.lua watches the NPCs and enemies. Spyro just stands at the level start, so it catches
-- patrols and wanderers, not characters that only move once he is close. T again stops it, as does an
-- empty tour.stop file. On arriving in each level it also runs tools/scan.lua, which records a
-- scripted-tour stop in front of every kind of character there, so one tour builds the route file for
-- tools/autotest.lua.
--
-- tour.txt may hold options, one per line or space separated:
--   dwell=3          seconds in each level instead of DWELL. Use a short one when the point of the tour
--                    is only to build the route file; the stall tracker needs the full 25.
--
--   "tour" lines  start/stop, each level (arrived, or skipped when the travel timed out), then a
--                 stallsummary for that level.
local levels = require("lib.levels")
local invuln = require("lib.invuln")
local log = require("lib.log")
local paths = require("lib.paths")
local quicksave = require("tools.quicksave")
local scan = require("tools.scan")

local DWELL = 25 -- seconds in each level after arriving
local TRIGGER = paths.modDir .. "\\tour.txt"
local STOP = paths.modDir .. "\\tour.stop" -- an empty file that stops a tour that is already going
-- Flight levels and speedways: Spyro never walks there (so travel never counts as arrived), and a crash
-- ends on a Retry/Quit screen that stops the tour.
local SKIP = { LS105 = true, LS111 = true, LS117 = true, LS123 = true, LS129 = true,
               LS209 = true, LS220 = true, LS221 = true, LS228 = true,
               LS307 = true, LS316 = true, LS325 = true, LS334 = true }

local tour = {}

local requested = false
local s = nil -- { names, index, dwell, phase = "travel" | "wait" | "dwell", until }
local options = nil -- from tour.txt, read on the next start
local nextPoll = 0

function tour.toggle()
    requested = true
end

-- The trigger file between tours, the stop file during one, so a tour can be driven from outside the
-- game the same way the spawn test and the montage sweep are.
local function poll()
    if os.clock() < nextPoll then return end
    nextPoll = os.clock() + 1
    local file = io.open(s and STOP or TRIGGER, "r")
    if not file then return end
    local text = file:read("a") or ""
    file:close()
    os.remove(s and STOP or TRIGGER)
    options = {}
    for word in text:gmatch("%S+") do
        local key, value = word:match("^(%w+)=(.*)$")
        if key then options[key] = value else options[word] = true end
    end
    requested = true
end

local function nextLevel(pawn)
    s.index = s.index + 1
    local level = s.names[s.index]
    if not level then
        log("tour: done, %d levels", #s.names)
        s = nil
        invuln.clear(pawn)
        return
    end
    if SKIP[level] then
        log("tour: %s skipped (flight level or speedway)", level)
        s.level, s.phase = level, "next"
        return
    end
    log("tour: %s (%d/%d)", level, s.index, #s.names)
    s.level = level
    if level == levels.current(pawn) then
        s.phase, s.dwellUntil = "dwell", os.clock() + s.dwell
        scan.request() -- while it is here anyway: a stop in front of each kind of character (tools/scan.lua)
    elseif quicksave.travel(pawn, level) then
        s.phase = "travel"
    else
        log("tour: %s skipped, travel failed", level)
        s.phase = "next"
    end
end

-- setFpsCap(cap) is main.lua's F-key handler; stalls is trackers/stalls.lua (for its per-level summary).
function tour.update(pawn, setFpsCap, stalls)
    poll()
    if requested then
        requested = false
        if s then
            log("tour: stopped at %s", tostring(s.level))
            s = nil
            invuln.clear(pawn)
            return
        end
        local names = quicksave.levelNames()
        if not names or #names == 0 then
            log("tour: can't read the level table, using the fixed list")
            names = levels.fixedNames()
        end
        -- From the level Spyro is in, round to the ones before it: starting in the middle of the table
        -- used to leave the earlier levels out of the tour altogether.
        local current = levels.current(pawn)
        local start = 0
        for i, name in ipairs(names) do
            if name == current then start = i - 1 end
        end
        local ordered = {}
        for i = start + 1, #names do ordered[#ordered + 1] = names[i] end
        for i = 1, start do ordered[#ordered + 1] = names[i] end
        local dwell = tonumber(options and options.dwell) or DWELL
        s = { names = ordered, index = 0, dwell = dwell }
        log("tour: starting at %s, %d levels, %d s each", tostring(ordered[1]), #ordered, dwell)
        setFpsCap(0)
        nextLevel(pawn)
        return
    end
    if not s then return end
    invuln.update(pawn)
    if s.phase == "travel" then
        if quicksave.travelling() then return end
        if levels.current(pawn) ~= s.level then
            log("tour: %s skipped, never arrived", s.level)
            s.phase = "next"
        else
            s.phase, s.dwellUntil = "dwell", os.clock() + s.dwell
            scan.request() -- while it is here anyway: a stop in front of each kind of character (tools/scan.lua)
        end
    end
    if s.phase == "dwell" and os.clock() >= s.dwellUntil then
        stalls.summary("tour " .. s.level)
        s.phase = "next"
    end
    if s.phase == "next" then nextLevel(pawn) end
end

return tour
