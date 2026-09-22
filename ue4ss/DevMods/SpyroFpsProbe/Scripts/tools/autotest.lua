-- Scripted tour (O, or create autotest.txt in this mod folder): drives the game itself through every
-- recorded stop (tools/routes.lua) and plays a preset input script there (tools/scripts.lua), so the
-- same gameplay can be compared frame for frame between framerates.
--
-- A level is run at every framerate before the run moves on: all of LS301 at 30 FPS, the same stops and
-- the same inputs at 320, then LS302. The two passes of a level are minutes apart in one session rather
-- than hours apart either side of a restart, and stopping half way leaves whole levels measured at both
-- framerates instead of a 30 FPS pass with nothing to compare against. Each stop starts from the same
-- teleport, facing the same way, at a standstill, so the passes line up; tools/Compare-Autotest.ps1 and
-- tools/Compare-Anims.ps1 join them on (level, stop, script, t).
--
-- Each level starts with Spyro on his own: a flame, a charge, a short hop and a glide, once each, before
-- any stop walks into a character. Those are what the camera and jump trackers measure, and they belong
-- to the level rather than to each of its fifty characters. They run first so no conversation is open.
--
-- Each stop is: travel to its level (unless already there), teleport onto it, wait SETTLE seconds for
-- the camera and the ground check, then play the script while sampling every SAMPLE seconds.
--
--   autotest_<stamp>.csv  one row per sample: cap, level, stop, script, t, position and camera
--   autotest_anims_<stamp>.csv  two rows per sample: what the played character and the character the stop
--                         was recorded in front of are animating (montage, how far into it, section,
--                         enemy state, where they have moved to). Compared with tools/Compare-Anims.ps1.
--   "autotest" lines      start/stop, each cap, each stop (or why it was skipped), and the run total
--
-- A stop that ends "could not move" is one where he was held forward and stayed put with nothing near
-- him to explain it. Walking into the character he was sent at is not that: a character has collision
-- and he stops against it further out than ARRIVE, which reads as arriving, not as being stuck. What is
-- left is a spot facing a rock, or the rarer case of the game taking input away. The next stop then
-- starts by pushing forward for a moment, and if he still cannot move the level is loaded again.
--
-- autotest.txt may hold options, one per line or space separated:
--   restart          start from the beginning instead of resuming autotest_progress.txt
--   caps=30,144      run these framerate caps (0 is uncapped)
--   level=LS102      only stops in this level
--   game=2           only stops in that game's levels (1 = LS1xx, 2 = LS2xx, 3 = LS3xx)
--   script=jump      only stops with this script (a comma list is allowed: script=walk,enterPlay)
--   review           a pass for somebody watching: F3 says a stop looks fine, F4 says it is wrong (and
--                    holds the tour on it until F3, so it can be described), each written to
--                    review_<stamp>.txt. One stop per spot (the walk-in: enterPlay if the character has
--                    one, else walk), since the verdict is about the spot; at 30 FPS unless caps= is given
--   all              with review: every script at every spot, not just the walk-in
-- review.txt starts a review the same way, "review restart" implied, other options as above.
--
-- Travelling live from LS135 into LS201 sets the game index, streams the level in and then leaves Spyro
-- falling in a black void, because the checkpoint it starts at belongs to the game he was in. So a run
-- that reaches another game's stops goes through the game state's "start game" first, as picking the game
-- on the menu does (switchGame), and travels on from wherever that lands him. game=N still runs one
-- game only. Stop numbers are the route's own, so segments line up with each other in the CSVs.
--
-- An empty autotest.stop file stops a run that is already going (the trigger file is only read between
-- runs, so dropping autotest.txt again would start a second one).
--
-- Progress is written to autotest_progress.txt after every stop, so a crash or a restart
-- (tools/Restart-Game.ps1 with lib/resume.lua) picks the run up where it stopped.
local UEHelpers = require("UEHelpers")
local ground = require("lib.ground")
local igc = require("lib.igc")
local subworld = require("lib.subworld")
local invuln = require("lib.invuln")
local input = require("lib.input")
local anim = require("lib.anim")
local levels = require("lib.levels")
local log = require("lib.log")
local paths = require("lib.paths")
local quicksave = require("tools.quicksave")
local routes = require("tools.routes")
local scripts = require("tools.scripts")

local autotest = {}

local CAPS = { 30, 60, 144, 320 }
local SAMPLE = 0.1   -- seconds of game time between CSV rows
local SETTLE = 1.0   -- seconds standing still after the teleport, before the script starts
local SETTLE_MAX = 4.0 -- but a fall from the teleport is given this long to land before the stop is dropped
local TRAVEL_GRACE = 5 -- seconds after a travel arrives before the teleport (the level is still settling)
local LOOK_AHEAD = 260     -- how far ahead the walk looks for ground before stepping there
local DROP_AHEAD = 180     -- a drop deeper than this ahead of him counts as an edge, not a step down
local FELL_HEIGHT = 90     -- below the stop AND falling: put him back before the water kills him. Walking
                           -- down steps and slopes is not falling, so it does not count.
local DEATH_SETTLE = 1.0    -- seconds on his feet again after a death before the run carries on
local ARRIVE = 100         -- distance to the stop target at which the walk stops (it has been reached).
                           -- 170 stopped him short of the range an NPC starts talking at, so the stops
                           -- meant to open a dialogue never opened one.
local TALK_ARRIVE = 40     -- the same for a stop that is meant to open a conversation: 100 was still
                           -- short of some NPCs (2026-09-22), so it walks on until it touches them
                           -- (BLOCKED_BY_TARGET) or the conversation opens, and this is only a floor.
local STEER_FROM = 60      -- steer at the character while further than this, so a target that stands
                           -- off the recorded line (or wanders) is still walked into, not past
local BLOCKED_BY_TARGET = 300 -- but a character has collision, and he stops against it further out than
                           -- ARRIVE. Standing still this close to the one he was sent at is arriving,
                           -- not being stuck: without this he pushes into it for the whole stop and the
                           -- stop is thrown away as one where the game took input off him.
local BLOCKED_AFTER = 1.0  -- seconds of walking before that counts, so a standing start is not "blocked"
-- Dialogue is an in-game cinematic (Spyro_IGC_Base has SkipCheck and StartSkipTimer) and it takes input
-- away until it closes. Holding each face button to skip one was tried and measured: 29 of 32 attempts
-- failed, at six and a half seconds each, so the holds are gone. Loading the level again is what works.
local VERIFY_SECONDS = 0.6 -- pushing forward at the next stop, to see whether he is still held
-- Spyro's own abilities, run once each at the start of every level at every framerate, on the first
-- stop's spot. Running them at every character instead measured the same thing fifty times a level and
-- was most of what a tour spent its hours on.
local LEAD_SCRIPTS = { "flame", "charge", "hop", "glide" }
local LOST_HEIGHT = 1000   -- drop from the stop that means he is out of the level, not playing the script
local LOST_DISTANCE = 5000 -- and the same sideways (a respawn puts him at the level entrance)
local LOCKED_SPEED = 5     -- below this while being told to walk, he is not walking at all
local LOCKED_SECONDS = 2.0 -- held forward for this long without moving: the game has taken input away
local LOCKED_STOPS = 2     -- that many stops in a row, or a failed check, and the level is loaded again
local TALK_SECONDS = 25.0  -- longest a stop waits for a conversation it started to finish
local SUBWORLD_SECONDS = 12.0 -- how long to play as whoever a subworld handed the controller to
local CLEAR_SECONDS = 30.0 -- waiting for a conversation to be pressed through before a teleport
local CLEAR_RETRY = 0.1    -- seconds between checks (lib/dialogue.lua spaces the presses itself)
local MAX_RELOADS = 2      -- but no more than this per level: past that the spots are the problem
local SWITCH_TIMEOUT = 180  -- seconds for "start game" to land him in the next game before its stops are skipped
local TRIGGER = paths.modDir .. "\\autotest.txt"
local STOP = paths.modDir .. "\\autotest.stop" -- an empty file that stops a run that is already going
local REVIEW_TRIGGER = paths.modDir .. "\\review.txt" -- a review run (options as in autotest.txt)
local PROGRESS = paths.modDir .. "\\autotest_progress.txt"
local DEATHS = paths.modDir .. "\\autotest_deaths.txt" -- one line per death: the stop and the character
-- review mode: one line per F3 (looks fine) or F4 (wrong), numbered so a wrong one can be talked about
local REVIEW = string.format("%s\\review_%s.txt", paths.modDir, paths.stamp)
local CSV = string.format("%s\\autotest_%s.csv", paths.modDir, paths.stamp)
local HEADER = "cap,level,stop,script,note,t,tActual,x,y,z,yaw,speed,mode,camYaw,camPitch,camDist,camHeight\n"
-- What the two characters that matter are animating at each sample: the one being played and the one the
-- stop was recorded in front of. The scripted walk into an enemy is what starts its chase or attack, so
-- this is where the animations the player actually sees are compared between framerates.
local ANIM_CSV = string.format("%s\\autotest_anims_%s.csv", paths.modDir, paths.stamp)
local ANIM_HEADER = "cap,level,stop,script,note,t,who,class,montage,montagePos,section,rate,rootMotion,"
    .. "state,stateTime,x,y,z,yaw,speed,mode\n"

local requested = false
local run = nil      -- { caps, stops, plan, index, phase, ... }; plan is every (stop, cap) in run order
local pendingRating = nil -- "fine" or "wrong", from F3/F4 in review mode, handled on the next update
local csv, animCsv = nil, nil
local nextPoll = 0
local NO_AXES = {}   -- sticks centred, reused so driving a frame allocates nothing
local STEER = { leftX = 0, leftY = 0 } -- the stick pointed at the target, reused the same way
local FORWARD = { leftY = 1 } -- the same, for the check at the start of a stop after a locked one
local PLAYER_ORIGIN = { x = 0, y = 0, z = 0 } -- where the played character stood when the script started

local function openCsv()
    if csv then return csv end
    csv = io.open(CSV, "a")
    if not csv then
        log("autotest: could not write %s", CSV)
        return nil
    end
    if csv:seek("end") == 0 then csv:write(HEADER) end
    return csv
end

local function openAnimCsv()
    if animCsv then return animCsv end
    animCsv = io.open(ANIM_CSV, "a")
    if not animCsv then
        log("autotest: could not write %s", ANIM_CSV)
        return nil
    end
    if animCsv:seek("end") == 0 then animCsv:write(ANIM_HEADER) end
    return animCsv
end

local function writeProgress()
    local file = io.open(PROGRESS, "w")
    if not file then return end
    file:write(string.format("%d %d\n", 1, run.index))
    file:close()
end

local function readProgress()
    local file = io.open(PROGRESS, "r")
    if not file then return 1, 0 end
    local line = file:read("l") or ""
    file:close()
    local cap, index = line:match("^(%d+)%s+(%d+)")
    return tonumber(cap) or 1, tonumber(index) or 0
end

local function readOptions()
    -- review.txt is autotest.txt with "review restart" already in it (the review mode below).
    local path, text = TRIGGER, nil
    local file = io.open(TRIGGER, "r")
    if not file then
        path, file = REVIEW_TRIGGER, io.open(REVIEW_TRIGGER, "r")
        if not file then return nil end
    end
    text = file:read("a") or ""
    file:close()
    os.remove(path)
    if path == REVIEW_TRIGGER then text = text .. " review restart" end
    local options = {}
    for word in text:gmatch("%S+") do
        local key, value = word:match("^(%w+)=(.*)$")
        if key then options[key] = value else options[word] = true end
    end
    return options
end

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

-- The stops this run covers, in level order so each level is travelled to once.
local function buildStops(options)
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

-- One level at a time, at every framerate, rather than the whole route at 30 and then the whole route
-- again at 320. The two passes of a level are then minutes apart in the same session instead of hours
-- apart either side of a restart, and a run that is stopped half way leaves whole levels measured at
-- both framerates rather than a 30 FPS pass with nothing to compare it against.
local function buildPlan(stops, caps, noLead)
    local plan = {}
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
                plan[#plan + 1] = { entry = { stop = stop, id = stops[index].id }, cap = cap, measure = true }
            end
            for i = index, last do
                plan[#plan + 1] = { entry = stops[i], cap = cap }
            end
        end
        index = last + 1
    end
    return plan
end

local function currentEntry()
    local step = run.plan[run.index]
    return step and step.entry
end

-- True on the lead stops at the head of a level: Spyro performing his own abilities, rather than a stop
-- aimed at a character.
local function currentlyMeasuring()
    local step = run.plan and run.plan[run.index]
    return step ~= nil and step.measure == true
end

local function currentCap()
    local step = run.plan[run.index]
    return step and step.cap or 0
end

local function parseCaps(text)
    local caps = {}
    for value in tostring(text):gmatch("[^,]+") do
        local n = tonumber(value)
        if n then caps[#caps + 1] = n end
    end
    return #caps > 0 and caps or CAPS
end

local findTarget -- defined below, used by startStop

local function stopFinished(pawn, pc, reason)
    local entry = currentEntry()
    input.clear(pawn, pc)
    anim.release(run.targetHeld)
    run.targetHeld, run.targetOrigin = nil, nil
    -- A locked Spyro stays locked, so count the stops in a row that could not move: one is bad luck
    -- (he was against a wall), several in a row is the conversation still being open, and the level has
    -- to be loaded again to clear it.
    if run.lockedFor and run.lockedFor >= LOCKED_SECONDS then
        run.lockedStops = (run.lockedStops or 0) + 1
    elseif scripts.walks(entry.stop.script) then
        run.lockedStops = 0
    end -- a script that never pushes the stick proves nothing either way, so it leaves the count alone
    local locked = (run.lockedStops or 0) > 0
    run.lockedFor = 0
    log("autotest %d FPS %s stop %d (%s, %s): %s after %.1f s, %d samples",
        currentCap(), entry.stop.level, entry.id, entry.stop.script, entry.stop.note,
        reason, run.elapsed or 0, run.samples or 0)
    -- Move along whatever conversation this stop opened, whether or not it went wrong: a stop that ends in a
    -- text box takes the next one with it, and the last one leaves the game sitting in it. This presses
    -- Continue once; the clearing phase before the next teleport keeps pressing until it closes.
    igc.close(pc, pawn, entry.stop.level)
    run.checkNext = locked or nil
    run.phase = "next"
    if run.hold then
        run.hold, run.phase = nil, "held"
        log("review: held at %s stop %d; F3 carries on", entry.stop.level, entry.id)
    end
    writeProgress()
end

-- Puts the character on the stop, still, facing the recorded way, with the camera behind him. Walking
-- follows the control rotation, so that is what decides where the script walks.
local function place(pawn, pc, cmc, stop, yaw)
    local level, origin = levels.current(pawn)
    if level ~= stop.level or not origin then return false, "in " .. tostring(level) end
    local x, y, z = routes.place(stop, origin)
    yaw = yaw or stop.yaw
    pawn:K2_TeleportTo({ X = x, Y = y, Z = z }, { Pitch = 0, Yaw = yaw, Roll = 0 })
    cmc.Velocity = { X = 0, Y = 0, Z = 0 }
    pc:SetControlRotation({ Pitch = stop.ctrlPitch, Yaw = yaw, Roll = 0 })
    pcall(function() pawn.FollowCamera:ResetBehind(true) end)
    return true, nil, { x = x, y = y, z = z }
end

-- The yaw from the stop to the character it was recorded in front of. Characters walk about between the
-- scan and the run, and the recorded facing is the one they had then, so this is worked out fresh: without
-- it the script sometimes walked away from the target instead of into it.
local function yawTo(target, x, y)
    if not (target and pcall(function() return target:IsValid() end) and target:IsValid()) then return nil end
    local ok, loc = pcall(function() return target:K2_GetActorLocation() end)
    if not ok then return nil end
    local dx, dy = loc.X - x, loc.Y - y
    if dx * dx + dy * dy < 1 then return nil end
    return math.deg(math.atan(dy, dx))
end

-- Into another game (Spyro 1, 2 or 3) the way the menu does it: the game state's "start game"(game
-- index, save slot), which is what picking a game on the game select screen calls (lib/frontend.lua).
-- Travelling straight into another game's level sets the index but starts him at a checkpoint of the
-- game he was in, falling through a black void; "start game" loads the new game's own level first, and
-- the normal travel goes on from there.
local function switchGame(pawn, game)
    local ok, err = pcall(function()
        local statics = StaticFindObject("/Script/Falcon.Default__FalconGameplayStatics")
        local slot = statics:GetActiveSaveSlotIndex(pawn)
        local gs = UEHelpers.GetGameplayStatics():GetGameState(pawn)
        gs["start game"](gs, game - 1, slot)
    end)
    log("autotest: switching to Spyro %d with start game (%s)", game, ok and "ok" or tostring(err))
    return ok
end

local function startStop(pawn, pc, cmc)
    local entry = currentEntry()
    if not entry then return end
    local stop = entry.stop
    if run.skipLevel == stop.level then
        run.phase = "next"
        return
    end
    run.skipLevel = nil
    -- Out of a subworld: the level is loaded again, which always hands the controller back to Spyro.
    -- (A next stop in another level gets that from the travel below anyway.)
    if run.forceReload then
        run.forceReload = nil
        if levels.current(pawn) == stop.level then
            anim.release(run.targetHeld)
            run.targetHeld, run.targetOrigin, run.target = nil, nil, nil
            igc.forget()
            if quicksave.travel(pawn, stop.level) then
                run.phase = "travel"
                return
            end
        end
    end
    -- Several stops in a row that could not move: load the level again, which closes whatever had hold
    -- of him. Travelling to the level he is already in is the cheapest reset available.
    -- but only so many times in one level. A stop teleported hard against a wall never moves from its
    -- first frame, which looks exactly like being held, and reloading does not help it: LS321 spent 13
    -- reloads on an ice wall, a coal pit and a boxing arena. Two is enough to clear a conversation that
    -- really is stuck; past that the level is telling us the spots are the problem, not the game.
    if run.reloadLevel ~= stop.level then
        run.reloadLevel, run.reloads, run.reloadsNoted = stop.level, 0, nil
    end
    if (run.lockedStops or 0) >= LOCKED_STOPS and run.reloads >= MAX_RELOADS then
        run.lockedStops = 0
        if not run.reloadsNoted then
            run.reloadsNoted = true
            log("autotest: %s has had its %d reloads; the stops that cannot move here are the spots",
                stop.level, MAX_RELOADS)
        end
    elseif (run.lockedStops or 0) >= LOCKED_STOPS then
        run.lockedStops, run.reloads = 0, run.reloads + 1
        log("autotest: %d stops in a row could not move, loading %s again to clear it (%d of %d)",
            LOCKED_STOPS, stop.level, run.reloads, MAX_RELOADS)
        -- Let go of the character first: reloading destroys everything in the level, and a held
        -- reference to an actor that is being torn down is a pointer into freed memory.
        anim.release(run.targetHeld)
        run.targetHeld, run.targetOrigin, run.target = nil, nil, nil
        igc.forget()
        if quicksave.travel(pawn, stop.level) then
            run.phase = "travel"
            return
        end
    end
    -- Another game: through "start game" first (switchGame), then the travel below from its level.
    local want = tonumber(stop.level:match("^LS(%d)"))
    local have = tonumber(tostring(levels.current(pawn)):match("^LS(%d)"))
    if want and have and want ~= have then
        if run.skipGame == want then
            run.phase = "next"
            return
        end
        anim.release(run.targetHeld)
        run.targetHeld, run.targetOrigin, run.target = nil, nil, nil
        igc.forget()
        if switchGame(pawn, want) then
            run.phase, run.switchTo, run.switchStarted = "switch", want, os.clock()
        else
            run.skipGame, run.phase = want, "next"
        end
        return
    end
    if levels.current(pawn) ~= stop.level then
        anim.release(run.targetHeld) -- the level it lives in is about to go away
        run.targetHeld, run.targetOrigin, run.target = nil, nil, nil
        igc.forget()
        if not quicksave.travel(pawn, stop.level) then
            run.skipLevel = stop.level
            log("autotest: %s skipped, travel failed (the rest of the level too)", stop.level)
            run.phase = "next"
            return
        end
        run.phase = "travel"
        return
    end
    -- Never teleport out of a conversation. A cinematic holds the camera and the input, and it keeps
    -- holding them wherever he is put next, so the stop after this one is lost as well -- which is how
    -- one NPC used to cost a whole run. Finish it first and only then move him.
    if igc.active(stop.level) then
        local now = os.clock()
        if not run.clearing then
            run.clearing, run.nextClear = now + CLEAR_SECONDS, 0
            log("autotest: a conversation is still running; finishing it before the teleport")
        end
        -- Continue is pressed on its text box until it closes by itself (lib/dialogue.lua spaces the
        -- presses out); a cutscene with no text box is left to end on its own.
        if now >= run.nextClear then
            run.nextClear = now + CLEAR_RETRY
            igc.close(pc, pawn, stop.level)
        end
        if now < run.clearing then
            run.phase = "clearing"
            return
        end
        log("autotest: the conversation would not finish in %.0f s; teleporting anyway", CLEAR_SECONDS)
    end
    run.clearing, run.nextClear = nil, nil
    local _, origin = levels.current(pawn)
    local x, y = routes.place(stop, origin)
    run.target = findTarget(pawn, stop, x, y)
    local ok, why, spot = place(pawn, pc, cmc, stop, yawTo(run.target, x, y))
    if not ok then
        log("autotest: %s stop %d skipped, can't place it (%s)", stop.level, entry.id, tostring(why))
        run.phase = "next"
        return
    end
    run.phase, run.settled, run.elapsed, run.samples, run.nextSample = "settle", 0, 0, 0, 0
    run.arrived, run.everMoved, run.talking = nil, nil, nil
    run.character, run.inSubworld = subworld.character(pawn), nil
    run.spot = spot
end

local function nextStop(pawn, pc, cmc, setFpsCap)
    local was = run.plan[run.index]
    run.index = run.index + 1
    if run.index > #run.plan then
        log("autotest: done, %d stops at %d framerates; %s", #run.stops, #run.caps, CSV)
        if run.review then
            log("review: %d rated, %d fine, %d wrong; %s", run.review.count, run.review.fine or 0,
                run.review.wrong or 0, REVIEW)
        end
        input.clear(pawn, pc)
        -- Never leave the game in a text box because the route happened to end at an NPC.
        igc.close(pc, pawn, levels.current(pawn))
        igc.forget()
        invuln.clear()
        os.remove(PROGRESS)
        run = nil
        return
    end
    local now = run.plan[run.index]
    if not was or was.cap ~= now.cap or was.entry.stop.level ~= now.entry.stop.level then
        log("autotest: %s at %d FPS", now.entry.stop.level, now.cap)
    end
    setFpsCap(currentCap())
    writeProgress()
    startStop(pawn, pc, cmc)
end

-- `slot` is the sample time the row stands for (0, 0.1, 0.2 ...), the same in every pass so the passes
-- join; tActual is the game time it was really taken at, a fraction of a frame later.
local function sample(r, entry, slot)
    local file = openCsv()
    if not file then return end
    file:write(string.format("%d,%s,%d,%s,%s,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%d,%.3f,%.3f,%.1f,%.1f\n",
        currentCap(), entry.stop.level, entry.id, entry.stop.script, entry.stop.note:gsub(",", " "),
        slot, run.elapsed, r.x - run.x0, r.y - run.y0, r.z - run.z0, r.yaw, r.speed or 0, r.mode,
        r.camYaw, r.camPitch, r.camDist, r.camHeight))
    run.samples = run.samples + 1
end

-- One animation row for a character: what it is playing, which state it is in and where it has moved to
-- since the script started. Positions are relative to where that character was then, so the two
-- framerates line up whatever offset the level streamed in at.
local function sampleAnim(file, entry, slot, who, actor, origin)
    if not (actor and pcall(function() return actor:IsValid() end) and actor:IsValid()) then return end
    local s = anim.state(actor)
    local okClass, class = pcall(function() return actor:GetClass():GetFName():ToString() end)
    local loc = actor:K2_GetActorLocation()
    local yaw, speed, mode = 0, 0, 0
    pcall(function() yaw = actor:K2_GetActorRotation().Yaw end)
    pcall(function()
        local cmc = actor.CharacterMovement
        local v = cmc.Velocity
        speed = math.sqrt(v.X * v.X + v.Y * v.Y)
        mode = cmc.MovementMode
    end)
    file:write(string.format("%d,%s,%d,%s,%s,%.3f,%s,%s,%s,%.4f,%s,%.3f,%s,%s,%.3f,%.2f,%.2f,%.2f,%.2f,%.2f,%d\n",
        currentCap(), entry.stop.level, entry.id, entry.stop.script, entry.stop.note:gsub(",", " "),
        slot, who, okClass and class or "?", s.montage, s.position, s.section, s.rate, tostring(s.rootMotion),
        s.enemyState, s.enemyStateTime, loc.X - origin.x, loc.Y - origin.y, loc.Z - origin.z,
        yaw, speed, mode))
end

-- The player and the character the stop was recorded in front of, every sample.
local function sampleAnims(pawn, entry, slot)
    local file = openAnimCsv()
    if not file then return end
    PLAYER_ORIGIN.x, PLAYER_ORIGIN.y, PLAYER_ORIGIN.z = run.x0, run.y0, run.z0
    sampleAnim(file, entry, slot, "player", pawn, PLAYER_ORIGIN)
    if run.target and run.targetOrigin then
        sampleAnim(file, entry, slot, "target", run.target, run.targetOrigin)
    end
end

-- The character this stop was recorded in front of (tools/scan.lua notes its class), so the walk can stop
-- when it gets there. The nearest one of that class to the stop, since a level has several of most kinds.
function findTarget(pawn, stop, x, y)
    local best, bestDist
    for _, actor in ipairs(FindAllOf("PhasmidCharacter") or {}) do
        local ok = pcall(function() return actor:IsValid() end) and actor:IsValid()
        if ok and actor:GetAddress() ~= pawn:GetAddress() then
            local okClass, class = pcall(function() return actor:GetClass():GetFName():ToString() end)
            if okClass and class == stop.note then
                local loc = actor:K2_GetActorLocation()
                local dist = (loc.X - x) ^ 2 + (loc.Y - y) ^ 2
                if not bestDist or dist < bestDist then best, bestDist = actor, dist end
            end
        end
    end
    return best
end

-- How far the character is from this stop's target, or nil when there isn't one any more.
local function targetDistance(r)
    local target = run.target
    if not (target and pcall(function() return target:IsValid() end) and target:IsValid()) then return nil end
    local ok, loc = pcall(function() return target:K2_GetActorLocation() end)
    if not ok then return nil end
    return math.sqrt((loc.X - r.x) ^ 2 + (loc.Y - r.y) ^ 2)
end

-- Is he about to walk over an edge? Traces down a step ahead of him, along the way he is facing. Chasing
-- a character that runs off towards water walked him in after it, and pulling him back after the fall had
-- already started was too late (LS104's thief drowned twice, 2026-09-20).
local function atEdge(pawn, r)
    if r.mode ~= 1 and r.mode ~= 2 then return false end -- only while walking
    local rad = math.rad(r.yaw)
    local x, y = r.x + math.cos(rad) * LOOK_AHEAD, r.y + math.sin(rad) * LOOK_AHEAD
    return ground.zAt(pawn, x, y, r.z, 50, DROP_AHEAD) == nil
end

-- Sends the phase's input for this frame (held sticks and buttons, and the taps of a dialogue phase).
-- Walking stops once the target is reached (the point is to meet the character) and at the edge of a
-- drop, and from then on he stands still for the rest of the stop.
-- The stick pointed at the stop target, from where the camera faces: what a player does to walk up to
-- somebody. Only for a phase that walks straight ahead, and only while the target is further than
-- STEER_FROM; returns nil otherwise and the phase's own stick is used.
local function steerAt(pc, phase, r, distance)
    local axes = phase.axes
    if not (axes and (axes.leftY or 0) > 0 and (axes.leftX or 0) == 0) then return nil end
    if not (distance and distance > STEER_FROM) then return nil end
    local ok, loc = pcall(function() return run.target:K2_GetActorLocation() end)
    if not ok then return nil end
    local okYaw, yaw = pcall(function() return pc:GetControlRotation().Yaw end)
    if not okYaw then return nil end
    local d = math.rad(math.deg(math.atan(loc.Y - r.y, loc.X - r.x)) - yaw)
    STEER.leftY, STEER.leftX = math.cos(d) * axes.leftY, math.sin(d) * axes.leftY
    return STEER
end

local function drive(pawn, pc, phase, into, r)
    local distance = targetDistance(r)
    local edge = not run.arrived and atEdge(pawn, r)
    -- Walking into a character stops against its collision, which can be further out than ARRIVE: he
    -- never gets to the distance that counts as arrived, so he is left pushing into it for the whole
    -- stop and read as "cannot move". Standing still this close to what he was sent at IS arriving.
    local blocked = not run.arrived and distance and distance <= BLOCKED_BY_TARGET
        and (r.speed or 0) < LOCKED_SPEED and run.elapsed > BLOCKED_AFTER
    -- A conversation stop walks until it touches the character or the conversation opens: stopping
    -- at ARRIVE left some NPCs just out of talking range.
    local talks = currentEntry().stop.script == "enterPlay"
    local reached = distance and distance <= (talks and TALK_ARRIVE or ARRIVE)
    local talking = talks and igc.active(currentEntry().stop.level)
    local arrived = run.arrived or edge or blocked or reached or talking
    if arrived and not run.arrived then
        run.arrived = run.elapsed
        log("autotest: %s after %.1f s, no more walking for the rest of the stop",
            edge and "stopped at the edge of a drop" or
            talking and not (blocked or reached) and ("in conversation with " .. currentEntry().stop.note) or
            ((blocked and "up against " or "reached ") .. currentEntry().stop.note), run.elapsed)
    end
    -- Reaching the character (or a drop) lets go of the sticks, but the script's buttons carry on: a
    -- dialogue or minigame script has to keep tapping once it is standing in front of whoever starts it,
    -- and a flame or a jump is meant to happen where he ends up.
    input.hold(arrived and NO_AXES or steerAt(pc, phase, r, distance) or phase.axes)
    -- Being told to walk and not walking means the game has taken input away: a conversation that never
    -- closed is the usual one (a Spyro 2 NPC holds him until the dialogue is dismissed, and every stop
    -- after that records a Spyro who cannot move). Count the time it has been asked and refused.
    local walking = not arrived and phase.axes and (phase.axes.leftY or phase.axes.leftX)
    if walking and (r.speed or 0) < LOCKED_SPEED then
        run.lockedFor = (run.lockedFor or 0) + r.dt
    elseif walking then
        run.lockedFor = 0
        run.everMoved = true
    end
    local wanted = {}
    for _, button in ipairs(phase.hold or {}) do wanted[button] = true end
    local tap = phase.tap
    if tap then
        wanted[tap.button] = (into % tap.period) < (tap.width or tap.period / 2)
    end
    for button in pairs(input.BUTTONS) do
        if wanted[button] then input.press(button) else input.release(button) end
    end
    input.apply(pawn, pc)
end

-- Review mode: F3 (fine) or F4 (wrong) on the stop being played. Written to REVIEW with what can be
-- measured about it -- how far the target is and how far off his facing it stands, whether a
-- conversation is open -- so "wrong" can be matched with the description of why. F4 also holds the
-- tour on this stop once its script is done (stopFinished), and F3 carries on from there.
local function rate(r, verdict)
    local entry = currentEntry()
    if not (entry and run.review) then return end
    if run.phase == "held" then
        if verdict == "fine" then
            log("review: carrying on")
            run.phase = "next"
        end
        return
    end
    run.review.count = run.review.count + 1
    run.review[verdict] = (run.review[verdict] or 0) + 1
    local stop = entry.stop
    local distance = targetDistance(r)
    local off = "?"
    local ok, loc = pcall(function() return run.target:K2_GetActorLocation() end)
    if ok and loc then
        local bearing = math.deg(math.atan(loc.Y - r.y, loc.X - r.x))
        off = string.format("%.0f", (bearing - r.yaw + 540) % 360 - 180)
    end
    local line = string.format("#%d %s | %s | %s stop %d | %s | %s | %.1f s in (%s) | target %s away, %s deg off his facing%s",
        run.review.count, verdict:upper(), os.date("%H:%M:%S"), stop.level, entry.id, stop.script, stop.note,
        run.elapsed or 0, run.phase, distance and string.format("%.0f", distance) or "?", off,
        igc.active(stop.level) and " | in a conversation" or "")
    local file = io.open(REVIEW, "a")
    if file then file:write(line, "\n"); file:close() end
    log("review: %s", line)
    if verdict == "wrong" then
        run.hold = true
        log("review: #%d -- the tour holds here once this stop's script is done; F3 carries on", run.review.count)
    end
end

local function update(pawn, pc, cmc, r, setFpsCap)
    -- The trigger file between runs, the stop file during one: a run of a thousand stops has to be
    -- stoppable from outside the game, and reading the trigger while one is going would restart it.
    if os.clock() >= nextPoll then
        nextPoll = os.clock() + 1
        if run then
            local file = io.open(STOP, "r")
            if file then
                file:close()
                os.remove(STOP)
                requested = true
            end
        else
            local options = readOptions()
            if options then
                requested = true
                run = { options = options }
            end
        end
    end
    if requested then
        requested = false
        local options = (run and run.options) or {}
        if run and run.stops then
            log("autotest: stopped")
            input.clear(pawn, pc)
            anim.release(run.targetHeld)
            invuln.clear()
            run = nil
            return
        end
        routes.load()
        local stops = buildStops(options)
        if #stops == 0 then
            log("autotest: no stops recorded yet (stand somewhere and press M, then edit routes.txt)")
            run = nil
            return
        end
        local index = 1
        if not options.restart then
            local _, savedIndex = readProgress()
            index = math.max(savedIndex, 1)
        end
        local caps = parseCaps(options.caps or (options.review and "30" or ""))
        local plan = buildPlan(stops, caps, options.review)
        if index > #plan then index = 1 end
        run = { caps = caps, stops = stops, plan = plan, index = index,
                phase = "start", started = os.clock(), review = options.review and { count = 0 } or nil }
        log("autotest: %d stops at %d framerates (%s), %d in all, starting at %d; each level is run at "
            .. "every framerate before the next one",
            #stops, #caps, table.concat(caps, "/"), #plan, run.index)
        setFpsCap(currentCap())
        startStop(pawn, pc, cmc)
        return
    end
    if not run or not run.stops then return end
    if pendingRating then
        local verdict = pendingRating
        pendingRating = nil
        rate(r, verdict)
    end
    if run.phase == "held" then return end
    invuln.update(pawn)
    local entry = currentEntry()

    if run.phase == "travel" then
        if quicksave.travelling() then return end
        if levels.current(pawn) ~= entry.stop.level then
            -- A level that can't be travelled to can't be travelled to for any of its stops, and each
            -- attempt costs the whole travel timeout. Give up on the level, not on one stop at a time:
            -- LS201 cost 90 s a stop for every stop in it before this.
            run.skipLevel = entry.stop.level
            log("autotest: %s skipped, never arrived (the rest of the level too)", entry.stop.level)
            run.phase = "next"
        else
            run.phase, run.grace = "grace", TRAVEL_GRACE
        end
    end
    if run.phase == "switch" then
        local here = tostring(levels.current(pawn))
        if here:match("^LS" .. run.switchTo) then
            log("autotest: in Spyro %d (%s) after %.0f s", run.switchTo, here, os.clock() - run.switchStarted)
            run.phase, run.grace = "grace", TRAVEL_GRACE
        elseif os.clock() - run.switchStarted > SWITCH_TIMEOUT then
            log("autotest: never got into Spyro %d (still in %s); skipping its stops", run.switchTo, here)
            run.skipGame, run.phase = run.switchTo, "next"
        end
        return
    end
    if run.phase == "grace" then
        run.grace = run.grace - r.dt
        if run.grace <= 0 then startStop(pawn, pc, cmc) end
        return
    end
    -- Waiting for a conversation to finish before the teleport (startStop).
    if run.phase == "clearing" then
        startStop(pawn, pc, cmc)
        return
    end
    if run.phase == "settle" then
        run.settled = run.settled + r.dt
        -- A stop can still land over a drop (the scan's ground check only traces straight down), and a
        -- character who falls out of the level drowns and reloads it. If he hasn't landed by the end of
        -- the settle, the stop is dropped instead of played.
        -- Teleporting onto a stop can leave him a short drop above it, so a fall is given SETTLE_MAX to
        -- land; only a spot with nothing under it at all is skipped.
        if r.mode == 3 then
            if run.settled >= SETTLE_MAX then
                log("autotest: %s stop %d skipped, still falling after %.1f s (the spot is over a drop)",
                    entry.stop.level, entry.id, run.settled)
                run.phase = "next"
            end
            return
        end
        if run.settled >= SETTLE then
            -- The last stop could not move, so before this one is played, find out whether he still
            -- cannot. Here is the place to ask: the teleport has moved him away from whoever was
            -- talking to him. Asking at the locked stop itself only ever said yes, because the NPC was
            -- still standing there saying it.
            if run.checkNext then
                run.phase, run.verifyFor, run.verifyBest = "verify", 0, 0
                return
            end
            run.phase = "play"
            run.x0, run.y0, run.z0 = r.x, r.y, r.z
            run.elapsed, run.nextSample = 0, 0
            -- Where the target stands now, so its own movement during the script is what is compared,
            -- and its mesh is pinned to ticking every frame (a character the camera isn't looking at
            -- otherwise ticks its animation at a reduced rate, which is not the framerate difference
            -- this is after). lib/anim.lua puts both back when the stop ends.
            if run.target and pcall(function() return run.target:IsValid() end) and run.target:IsValid() then
                local loc = run.target:K2_GetActorLocation()
                run.targetOrigin = { x = loc.X, y = loc.Y, z = loc.Z }
                run.targetHeld = anim.hold(run.target)
            end
        end
        return
    end
    -- Dead: the death animation, the respawn and the fall back into place are not this stop's script, so
    -- nothing is driven or sampled until he is back on his feet, and the stop is given up rather than
    -- compared. The enemy that did it is written down, because that is the interesting part.
    if run.phase == "dead" then
        input.clear(pawn, pc)
        local health = invuln.health(pawn)
        if (health or 0) > 0 and r.mode ~= 3 and not r.rootMotion then
            run.deadFor = (run.deadFor or 0) + r.dt
            if run.deadFor >= DEATH_SETTLE then stopFinished(pawn, pc, "died") end
        else
            run.deadFor = 0
        end
        return
    end
    if run.phase == "play" then
        -- Somebody else is holding the controller: the conversation handed over to Sheila, Sgt Byrd,
        -- Bentley or Agent 9 and their minigame is running in a sublevel of this same level. Play it
        -- for a while, sampling as usual -- these animations are reachable no other way, because the
        -- tour cannot record a stop inside a minigame that is not running when the level is scanned --
        -- and then leave by loading the level again, the game's own load. Leaving through the pause
        -- menu never worked, and the tour does not touch the HUD.
        local now = subworld.character(pawn)
        if now and run.character and now ~= run.character and not run.inSubworld then
            run.inSubworld, run.subworldFor = now, 0
            log("autotest: %s took over at stop %d; playing its minigame", now, entry.id)
        end
        if run.inSubworld then
            if run.elapsed >= run.nextSample then
                sample(r, entry, run.nextSample)
                sampleAnims(pawn, entry, run.nextSample)
                run.nextSample = run.nextSample + SAMPLE
            end
            run.subworldFor = run.subworldFor + r.dt
            run.elapsed = run.elapsed + r.dt
            if run.subworldFor >= SUBWORLD_SECONDS then
                log("autotest: played %s for %.0f s; loading %s again to leave", run.inSubworld,
                    run.subworldFor, entry.stop.level)
                run.inSubworld = nil
                stopFinished(pawn, pc, "played a subworld")
                run.forceReload = true -- startStop loads the level again, whatever the reload count
                return
            end
            -- Whatever the character is, forward and jumping is playing it.
            local playPhase, playInto = scripts.phaseAt("play", run.subworldFor % scripts.duration("play"))
            if playPhase then drive(pawn, pc, playPhase, playInto, r) end
            return
        end
        local health = invuln.health(pawn)
        if health and health <= 0 then
            local entryStop = entry.stop
            log("autotest: DIED at %s stop %d (%s, %s) %.1f s into the script, %d FPS pass",
                entryStop.level, entry.id, entryStop.script, entryStop.note, run.elapsed, currentCap())
            local deaths = io.open(DEATHS, "a")
            if deaths then
                deaths:write(string.format("%s %s stop %d %s %s at %.1f s, %d FPS\n", os.date("%Y-%m-%d %H:%M:%S"),
                    entryStop.level, entry.id, entryStop.script, entryStop.note, run.elapsed, currentCap()))
                deaths:close()
            end
            run.phase, run.deadFor = "dead", 0
            input.clear(pawn, pc)
            return
        end
        -- Off an edge: a character walked into the water dies, the level reloads and the rest of the run
        -- is thrown off, so the moment he is below the stop he is put back on it and the stop ends.
        if r.mode == 3 and run.z0 - r.z > FELL_HEIGHT and not entry.stop.script:find("glide") then
            input.clear(pawn, pc)
            if run.spot then
                pawn:K2_TeleportTo({ X = run.spot.x, Y = run.spot.y, Z = run.spot.z },
                    { Pitch = 0, Yaw = r.yaw, Roll = 0 })
                cmc.Velocity = { X = 0, Y = 0, Z = 0 }
            end
            stopFinished(pawn, pc, "walked off an edge (put back on the stop)")
            return
        end
        -- Somewhere else entirely (a respawn): nothing left to compare.
        if math.abs(r.z - run.z0) > LOST_HEIGHT or math.abs(r.x - run.x0) > LOST_DISTANCE
           or math.abs(r.y - run.y0) > LOST_DISTANCE then
            stopFinished(pawn, pc, "left the area (fell or respawned)")
            return
        end
        -- Held forward for this long without moving. If he walked earlier in this stop he has run into
        -- something -- a wall, a pit edge, the character he was sent at -- so stop walking and let the
        -- rest of the script play where he stands, which is what the stop is for. Only a Spyro who never
        -- moved at all is one the game has taken input from, and that is the one worth ending early and
        -- recovering from.
        if (run.lockedFor or 0) >= LOCKED_SECONDS then
            -- A lead stop is not trying to reach anybody: it is Spyro performing one of his own
            -- abilities, and its walk exists only so the button press lands while he is moving. Wedged
            -- or not, the flame and the charge still have to happen, so it keeps holding the stick and
            -- plays the script out rather than ending the stop or giving up on the walk.
            if currentlyMeasuring() then
                run.lockedFor = 0
            elseif run.everMoved then
                run.arrived = run.elapsed
                run.lockedFor = 0
                log("autotest: up against something after %.1f s, no more walking for the rest of the stop",
                    run.elapsed)
            else
                stopFinished(pawn, pc, "could not move at all (input taken away)")
                return
            end
        end
        local phase, into = scripts.phaseAt(entry.stop.script, run.elapsed)
        if not phase then
            -- The script has run out, but a conversation this stop started is still going. Ending the
            -- stop here teleports him out of it mid-sentence, which is what walking into Bentley used
            -- to look like. Wait for it instead, and keep sampling while it plays: the talking is a
            -- character animating, which is the whole point of the stop.
            if igc.active(entry.stop.level) then
                igc.close(pc, pawn, entry.stop.level) -- Continue, as a player would, until it ends
                run.talking = (run.talking or 0) + r.dt
                if run.talking < TALK_SECONDS then
                    if run.elapsed >= run.nextSample then
                        sample(r, entry, run.nextSample)
                        sampleAnims(pawn, entry, run.nextSample)
                        run.nextSample = run.nextSample + SAMPLE
                    end
                    run.elapsed = run.elapsed + r.dt
                    return
                end
            end
            sample(r, entry, run.nextSample)
            sampleAnims(pawn, entry, run.nextSample)
            stopFinished(pawn, pc, (run.talking or 0) > 0 and "played (waited out a conversation)" or "played")
        else
            if run.elapsed >= run.nextSample then
                sample(r, entry, run.nextSample)
                sampleAnims(pawn, entry, run.nextSample)
                run.nextSample = run.nextSample + SAMPLE
            end
            drive(pawn, pc, phase, into, r)
            run.elapsed = run.elapsed + r.dt
        end
    end
    -- Pushing forward at the start of a stop that follows a locked one. If he moves, the conversation
    -- ended with the stop and nothing is lost; if he does not, the level is loaded again, which is the
    -- only thing that reliably clears one.
    if run.phase == "verify" then
        input.hold(FORWARD)
        for name in pairs(input.BUTTONS) do input.release(name) end
        input.apply(pawn, pc)
        run.verifyFor = run.verifyFor + r.dt
        run.verifyBest = math.max(run.verifyBest, r.speed or 0)
        if run.verifyFor < VERIFY_SECONDS then return end
        input.clear(pawn, pc)
        local moved = run.verifyBest >= LOCKED_SPEED
        run.checkNext, run.verifyFor, run.verifyBest = nil, nil, nil
        if moved then
            -- Back through the settle, which is what pins the target's mesh and records where it
            -- started; going straight to "play" would skip all of it.
            run.lockedStops = 0
            run.phase, run.settled = "settle", SETTLE
        else
            log("autotest: still cannot move at the next stop; loading %s again", entry.stop.level)
            run.lockedStops = LOCKED_STOPS
            run.phase = "next"
        end
        return
    end
    if run.phase == "next" then nextStop(pawn, pc, cmc, setFpsCap) end
end

function autotest.update(pawn, pc, cmc, r, setFpsCap)
    local ok, err = pcall(update, pawn, pc, cmc, r, setFpsCap)
    if not ok then
        log("autotest error: %s", tostring(err))
        input.clear(pawn, pc)
        if run then anim.release(run.targetHeld) end
        run = nil
    end
end

function autotest.toggle()
    requested = true
end

-- Review mode keys (main.lua): F3 = this stop looks fine (or carry on after F4), F4 = it is wrong.
function autotest.reviewing()
    return run ~= nil and run.stops ~= nil and run.review ~= nil
end

function autotest.rate(verdict)
    pendingRating = verdict
end

-- True while a run is going, so lib/resume.lua knows a restart should carry on with it.
function autotest.running()
    return run ~= nil and run.stops ~= nil
end

-- True during the LEAD_SCRIPTS stops at the head of each level, which are the ones the camera and jump
-- trackers exist to measure. They measure the level, not the character standing in it.
function autotest.measuring()
    return run ~= nil and run.plan ~= nil and currentlyMeasuring()
end

return autotest
