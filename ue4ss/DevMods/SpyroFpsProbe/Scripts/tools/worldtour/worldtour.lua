-- The world tour (O, or create autotest.txt or review.txt in this mod folder): drives the game itself
-- through every recorded stop (tools/routes.lua), across all three games, and plays a preset input script
-- at each one (scripts.lua), so the same gameplay can be compared frame for frame between framerates.
--
-- This file starts and stops a run and steps it from one stop to the next. The rest of tools/worldtour/:
--   plan.lua     which stops, in what order, at which framerates, and the progress file
--   arrive.lua   getting onto a stop: travel, a game switch, a conversation pressed through, the teleport
--   play.lua     playing it: settle, the script, and whatever ends it early (a death, a fall, no input)
--   drive.lua    moving him: placing him, finding the character he was sent at, the stick every frame
--   samples.lua  the two CSVs
--   review.lua   F3/F4 verdicts in a review run
--   scripts.lua  the input scripts
--
-- Each level starts with Spyro on his own: a flame, a charge, a short hop and a glide, once each, before
-- any stop walks into a character (plan.lua). Those are what the camera and jump trackers measure, and
-- they belong to the level rather than to each of its fifty characters.
--
--   autotest_<stamp>.csv, autotest_anims_<stamp>.csv  the samples (samples.lua)
--   review_<stamp>.txt     the verdicts of a review run (review.lua)
--   autotest_deaths.txt    one line per death (play.lua)
--   autotest_progress.txt  how far the run has got (plan.lua)
--   "autotest" lines       start/stop, each cap, each stop (or why it was skipped), and the run total
--
-- The files and the log lines keep the name the tour had as tools/autotest.lua, so the CSVs already
-- written, tools/Compare-Autotest.ps1 and tools/Compare-Anims.ps1 still line up.
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
-- review.txt starts a review the same way, "review restart" implied (put "resume" in it to carry on from
-- autotest_progress.txt instead), other options as above.
--
-- An empty autotest.stop file stops a run that is already going (the trigger file is only read between
-- runs, so dropping autotest.txt again would start a second one).
local anim = require("lib.anim")
local igc = require("lib.igc")
local input = require("lib.input")
local invuln = require("lib.invuln")
local levels = require("lib.levels")
local log = require("lib.log")
local paths = require("lib.paths")
local arrive = require("tools.worldtour.arrive")
local plan = require("tools.worldtour.plan")
local play = require("tools.worldtour.play")
local review = require("tools.worldtour.review")
local samples = require("tools.worldtour.samples")

local worldtour = {}

local TRIGGER = paths.modDir .. "\\autotest.txt"
local STOP = paths.modDir .. "\\autotest.stop" -- an empty file that stops a run that is already going
local REVIEW_TRIGGER = paths.modDir .. "\\review.txt" -- a review run (options as in autotest.txt)

local requested = false
-- The run, handed to the other modules, which keep their own fields on it. Here: options (before it
-- starts), caps, stops, plan (every (stop, cap) in run order), index, step (= plan[index]: entry =
-- { stop, id }, cap, measure), phase, review (the verdict counts, in a review run).
local run = nil
local pendingRating = nil -- "fine" or "wrong", from F3/F4 in review mode, handled on the next update
local nextPoll = 0

local function readOptions()
    -- review.txt is autotest.txt with "review restart" already in it.
    local path, text = TRIGGER, nil
    local file = io.open(TRIGGER, "r")
    if not file then
        path, file = REVIEW_TRIGGER, io.open(REVIEW_TRIGGER, "r")
        if not file then return nil end
    end
    text = file:read("a") or ""
    file:close()
    os.remove(path)
    -- "resume" in it carries on from autotest_progress.txt instead of starting again.
    if path == REVIEW_TRIGGER then text = text .. (text:find("resume") and " review" or " review restart") end
    local options = {}
    for word in text:gmatch("%S+") do
        local key, value = word:match("^(%w+)=(.*)$")
        if key then options[key] = value else options[word] = true end
    end
    return options
end

-- The trigger file between runs, the stop file during one: a run of a thousand stops has to be
-- stoppable from outside the game, and reading the trigger while one is going would restart it.
local function poll()
    if os.clock() < nextPoll then return end
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

local function start(pawn, pc, cmc, options, setFpsCap)
    local stops = plan.stops(options)
    if #stops == 0 then
        log("autotest: no stops recorded yet (stand somewhere and press M, then edit routes.txt)")
        run = nil
        return
    end
    local index = 1
    if not options.restart then index = math.max(plan.savedIndex(), 1) end
    local caps = plan.caps(options)
    local steps = plan.build(stops, caps, options.review)
    if index > #steps then index = 1 end
    run = { caps = caps, stops = stops, plan = steps, index = index, step = steps[index],
            phase = "start", started = os.clock(), review = options.review and { count = 0 } or nil }
    log("autotest: %d stops at %d framerates (%s), %d in all, starting at %d; each level is run at "
        .. "every framerate before the next one",
        #stops, #caps, table.concat(caps, "/"), #steps, run.index)
    setFpsCap(run.step.cap)
    arrive.start(run, pawn, pc, cmc)
end

local function nextStop(pawn, pc, cmc, setFpsCap)
    local was = run.step
    run.index = run.index + 1
    run.step = run.plan[run.index]
    local now = run.step
    if not now then
        log("autotest: done, %d stops at %d framerates; %s", #run.stops, #run.caps, samples.CSV)
        if run.review then review.summary(run) end
        input.clear(pawn, pc)
        -- Never leave the game in a text box because the route happened to end at an NPC.
        igc.close(pc, pawn, levels.current(pawn))
        igc.forget()
        invuln.clear()
        plan.forgetProgress()
        run = nil
        return
    end
    if not was or was.cap ~= now.cap or was.entry.stop.level ~= now.entry.stop.level then
        log("autotest: %s at %d FPS", now.entry.stop.level, now.cap)
    end
    setFpsCap(now.cap)
    plan.saveProgress(run.index)
    arrive.start(run, pawn, pc, cmc)
end

local function update(pawn, pc, cmc, r, setFpsCap)
    poll()
    if requested then
        requested = false
        if run and run.stops then
            log("autotest: stopped")
            input.clear(pawn, pc)
            anim.release(run.targetHeld)
            invuln.clear()
            run = nil
            return
        end
        start(pawn, pc, cmc, (run and run.options) or {}, setFpsCap)
        return
    end
    if not run or not run.stops then return end
    if pendingRating then
        local verdict = pendingRating
        pendingRating = nil
        review.rate(run, r, verdict)
    end
    if run.phase == "held" then return end
    invuln.update(pawn)
    -- Some phases hand straight on to the next in the same frame: an arrived travel to "grace", and a
    -- finished stop to "next".
    if run.phase == "travel" and arrive.travel(run, pawn) then return end
    if run.phase == "switch" then arrive.switch(run, pawn); return end
    if run.phase == "grace" then arrive.grace(run, pawn, pc, cmc, r); return end
    if run.phase == "clearing" then arrive.start(run, pawn, pc, cmc); return end
    if run.phase == "settle" then play.settle(run, r); return end
    if run.phase == "verify" then play.verify(run, pawn, pc, r); return end
    if run.phase == "dead" then play.dead(run, pawn, pc, r); return end
    if run.phase == "play" and play.step(run, pawn, pc, cmc, r) then return end
    if run.phase == "next" then nextStop(pawn, pc, cmc, setFpsCap) end
end

function worldtour.update(pawn, pc, cmc, r, setFpsCap)
    local ok, err = pcall(update, pawn, pc, cmc, r, setFpsCap)
    if not ok then
        log("autotest error: %s", tostring(err))
        input.clear(pawn, pc)
        if run then anim.release(run.targetHeld) end
        run = nil
    end
end

function worldtour.toggle()
    requested = true
end

-- Review mode keys (main.lua): F3 = this stop looks fine (or carry on after F4), F4 = it is wrong.
function worldtour.reviewing()
    return run ~= nil and run.stops ~= nil and run.review ~= nil
end

function worldtour.rate(verdict)
    pendingRating = verdict
end

-- True while a run is going (main.lua presses Continue through a prompt that pauses the world, and leaves
-- the level trackers to the lead stops).
function worldtour.running()
    return run ~= nil and run.stops ~= nil
end

-- True during the lead stops at the head of each level (plan.lua), which are the ones the camera and jump
-- trackers exist to measure. They measure the level, not the character standing in it.
function worldtour.measuring()
    return run ~= nil and run.step ~= nil and run.step.measure == true
end

return worldtour
