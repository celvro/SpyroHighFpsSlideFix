-- Montage sweep (I, or an animtest.txt trigger file): plays every animation of every kind of character
-- in the level, one montage at a time, at 30 FPS and then at 320, and records what each one did. The
-- point is the animations themselves, not the gameplay that would normally start them: a montage is
-- played straight through AnimInstance:Montage_Play, so a character's whole repertoire is covered in
-- seconds instead of being provoked one attack at a time.
--
-- Both framerates are measured in the same level visit, one after the other, so the same set of montages
-- is loaded for both and each level is travelled to once. A montage already measured at every cap in an
-- earlier level is skipped (the rhynocs share most of theirs), which is what keeps the run to hours
-- rather than days.
--
-- What a montage can do differently at 320 FPS: end at a different time (the anim update is per frame),
-- move the character a different distance if it has root motion (the same rounding as the walking bugs),
-- or fire its notifies a different number of times -- the charge dust and the Alpine Ridge druid were
-- both notify bugs (docs/findings/charge-dust.md, druid-energize.md). So each montage is measured for
-- its duration in game time, its root-motion displacement, and how many particle and audio components
-- its notifies spawned while it ran.
--
--   animtest_<stamp>.csv         one row per montage per framerate (see HEADER). "duration" is how long
--                                one pass through it took, "result" says whether it ended on its own
--                                (played), ran back to its start (looped) or never did either (stuck);
--                                "fx"/"audio" are the components its notifies made for that character,
--                                "fxWorld"/"audioWorld" everything the level made meanwhile, as the
--                                background rate to read them against
--   animtest_samples_<stamp>.csv one row every SAMPLE seconds of a montage: montage position and where
--                                the character has moved to (off with the "nosamples" option)
--   "animtest" lines             start/stop, each level and cap, each montage that did not simply play,
--                                and the run total
--   animtest_progress.txt        level index, cap index and montage index, rewritten after every montage
--   animtest_done.txt            "<cap> <montage path>" per measured montage, so a resumed run does not
--                                repeat what it already has (deleted by the "restart" option)
--
-- animtest.txt may hold options, one per line or space separated:
--   restart          start over: forget the progress and the measured montages
--   caps=30,320      framerate caps to measure, in order (0 is uncapped)
--   level=LS102      only this level
--   here             only the level Spyro is in now
--   class=Rhynoc     only characters whose class name contains this
--   montage=Attack   only montages whose name contains this
--   nosamples        summary rows only, no per-sample CSV
--   all              every montage the skeleton can play, not just the ones from this character's folder
--
-- An empty animtest.stop file in the same folder stops a run that is already going (the trigger file is
-- only read between runs), the same as pressing I.
local anim = require("lib.anim")
local invuln = require("lib.invuln")
local levels = require("lib.levels")
local log = require("lib.log")
local paths = require("lib.paths")
local quicksave = require("tools.quicksave")
local util = require("lib.util")

local animtest = {}

local CAPS = { 30, 320 }
local SAMPLE = 0.05       -- seconds of game time between sample rows
local RESET = 0.2         -- seconds standing still before a montage starts
local SETTLE = 2.0        -- seconds after arriving in a level before the characters are listed
local TRAVEL_GRACE = 5    -- seconds after a travel arrives before anything is measured
local TAIL = 0.25         -- seconds of sampling after the montage reports it has stopped
local TIMEOUT_FACTOR = 2  -- a montage is given this many times its length, plus TIMEOUT_EXTRA
local TIMEOUT_EXTRA = 1.0
local UNKNOWN_TIMEOUT = 10 -- seconds for a montage whose SequenceLength couldn't be read
local CUT_SHORT = 0.1      -- ending this far before the montage's length means something interrupted it
local RANGE = 30000       -- characters further than this are in a neighbouring level (as tools/scan.lua)
local MAX_PER_CLASS = 200 -- a sanity limit, so one shared skeleton cannot swallow a whole run
-- Flight levels and speedways: Spyro never walks there and a crash ends on a screen
-- that stops the run.
local SKIP_LEVELS = { LS105 = true, LS111 = true, LS117 = true, LS123 = true, LS129 = true,
                      LS209 = true, LS220 = true, LS221 = true, LS228 = true,
                      LS307 = true, LS316 = true, LS325 = true, LS334 = true }

local TRIGGER = paths.modDir .. "\\animtest.txt"
local STOP = paths.modDir .. "\\animtest.stop" -- an empty file that stops a run that is already going
local PROGRESS = paths.modDir .. "\\animtest_progress.txt"
local DONE = paths.modDir .. "\\animtest_done.txt"
local CSV = string.format("%s\\animtest_%s.csv", paths.modDir, paths.stamp)
local SAMPLES = string.format("%s\\animtest_samples_%s.csv", paths.modDir, paths.stamp)
local HEADER = "cap,level,class,actor,montage,path,length,blendOut,rateScale,duration,frames,avgFps,maxPos,"
    .. "rootFrames,moveDist,moveZ,drift,fx,fxWorld,audio,audioWorld,startState,endState,result\n"
local SAMPLE_HEADER = "cap,level,class,montage,t,pos,x,y,z,speed\n"

local requested = false
local run = nil       -- { caps, capIndex, levels, levelIndex, jobs, jobIndex, phase, ... }
local csv, samplesCsv = nil, nil
local nextPoll = 0
-- Components created since the current montage started. A level makes particle components all the time
-- on its own (75 a second in Town Square), so the ones that belong to the character being measured are
-- counted apart: a component made for an actor has that actor as its outer, which is set by the time
-- NotifyOnNewObject sees it. The world total is kept too, as the background rate to judge it against.
local fxOwned, fxAll, audioOwned, audioAll = 0, 0, 0, 0
local watching = nil -- address of the actor whose montage is playing
-- Reused, so holding a character still allocates nothing per frame.
local ZERO = { X = 0, Y = 0, Z = 0 }
local HOME = { X = 0, Y = 0, Z = 0 }
local HIT = {} -- the teleport's SweepHitResult out-param, never read

local function madeFor(object, address)
    if not address then return false end
    local ok, outer = pcall(function() return object:GetOuter():GetAddress() end)
    return ok and outer == address
end

-- main.lua sends every new ParticleSystemComponent and AudioComponent here; counting is all that
-- happens, so it costs nothing while no run is going.
function animtest.onNewFx(object)
    fxAll = fxAll + 1
    if watching and madeFor(object, watching) then fxOwned = fxOwned + 1 end
end

function animtest.onNewAudio(object)
    audioAll = audioAll + 1
    if watching and madeFor(object, watching) then audioOwned = audioOwned + 1 end
end

local function openCsv()
    if csv then return csv end
    csv = io.open(CSV, "a")
    if not csv then
        log("animtest: could not write %s", CSV)
        return nil
    end
    if csv:seek("end") == 0 then csv:write(HEADER) end
    return csv
end

local function openSamples()
    if samplesCsv or (run and run.options.nosamples) then return samplesCsv end
    samplesCsv = io.open(SAMPLES, "a")
    if samplesCsv and samplesCsv:seek("end") == 0 then samplesCsv:write(SAMPLE_HEADER) end
    return samplesCsv
end

-- Montages already measured, as "<cap> <path>" keys, so a resumed run carries on instead of repeating.
local function loadDone()
    local done = {}
    local file = io.open(DONE, "r")
    if not file then return done end
    for line in file:lines() do
        if line:match("%S") then done[line] = true end
    end
    file:close()
    return done
end

local function markDone(key)
    run.done[key] = true
    local file = io.open(DONE, "a")
    if not file then return end
    file:write(key .. "\n")
    file:close()
end

-- Only the level is remembered: what is left to do at each cap comes from animtest_done.txt, so a
-- resumed run starts this level over and skips the montages it already has.
local function writeProgress()
    local file = io.open(PROGRESS, "w")
    if not file then return end
    file:write(string.format("%d\n", run.levelIndex))
    file:close()
end

local function readProgress()
    local file = io.open(PROGRESS, "r")
    if not file then return 1 end
    local line = file:read("l") or ""
    file:close()
    return tonumber(line:match("^(%d+)")) or 1
end

local function readOptions()
    local file = io.open(TRIGGER, "r")
    if not file then return nil end
    local text = file:read("a") or ""
    file:close()
    os.remove(TRIGGER)
    local options = {}
    for word in text:gmatch("%S+") do
        local key, value = word:match("^(%w+)=(.*)$")
        if key then options[key] = value else options[word] = true end
    end
    return options
end

local function parseCaps(text)
    local caps = {}
    for value in tostring(text):gmatch("[^,]+") do
        local n = tonumber(value)
        if n then caps[#caps + 1] = n end
    end
    return #caps > 0 and caps or CAPS
end

-- The levels to visit, in the stream table's order, starting at the one Spyro is in.
local function levelList(pawn, options)
    local current = levels.current(pawn)
    if options.here then return current and { current } or {} end
    if options.level then return { options.level } end
    local names = quicksave.levelNames() or {}
    if #names == 0 then
        -- The stream data table is only readable once a level is loaded; the fixed list is the same rows.
        names = levels.fixedNames()
        log("animtest: can't read the level table, using the fixed list")
    end
    local ordered, start = {}, 0
    for index, name in ipairs(names) do
        if name == current then start = index - 1 end
    end
    for index = start + 1, #names do ordered[#ordered + 1] = names[index] end
    for index = 1, start do ordered[#ordered + 1] = names[index] end
    return ordered
end

local function className(actor)
    local ok, name = pcall(function() return actor:GetClass():GetFName():ToString() end)
    return ok and name or nil
end

local function actorName(actor)
    local ok, name = pcall(function() return actor:GetFName():ToString() end)
    return ok and name or "?"
end

-- One character of each class in this level, plus the player: the characters whose montages this level
-- visit covers. Twenty of the same rhynoc all play the same animations.
local function charactersHere(pawn, options)
    local here = pawn:K2_GetActorLocation()
    local found, order = {}, {}
    local function consider(actor)
        local class = className(actor)
        if not class or found[class] then return end
        if options.class and not class:find(options.class, 1, true) then return end
        found[class] = actor
        -- Where this character stands now is where every one of its montages starts, in both passes. A
        -- montage with root motion leaves it somewhere else, and the next montage played from there can
        -- run into a wall or a slope: Spyro's LoopEntrance covered 834 units from one spot and 427 from
        -- another, which read as a framerate difference until every montage started from the same place.
        local loc, rot = actor:K2_GetActorLocation(), actor:K2_GetActorRotation()
        order[#order + 1] = { actor = actor, class = class,
                              home = { X = loc.X, Y = loc.Y, Z = loc.Z },
                              facing = { Pitch = 0, Yaw = rot.Yaw, Roll = 0 } }
    end
    consider(pawn)
    for _, actor in ipairs(FindAllOf("PhasmidCharacter") or {}) do
        local ok = pcall(function() return actor:IsValid() end) and actor:IsValid()
        local name = ok and actorName(actor) or ""
        if ok and not name:match("^Default__") and actor:GetAddress() ~= pawn:GetAddress() then
            local loc = actor:K2_GetActorLocation()
            if (loc.X - here.X) ^ 2 + (loc.Y - here.Y) ^ 2 <= RANGE * RANGE then consider(actor) end
        end
    end
    return order
end

-- Every montage to play in this level, as { actor, class, montage, name, path, length, rateScale }.
-- A montage is given to the character whose own folder it comes from; one that no character here claims
-- goes to the first character whose skeleton can play it, so nothing loaded is left out.
local function buildJobs(pawn, options)
    anim.forget()
    local characters = charactersHere(pawn, options)
    local claimed, jobs = {}, {}
    for _, entry in ipairs(characters) do
        local count = 0
        for _, montage in ipairs(anim.montagesFor(entry.actor)) do
            local mine = anim.belongsTo(montage.path, entry.class)
            local free = not claimed[montage.path]
            local wanted = (not options.montage or montage.name:find(options.montage, 1, true))
                and (mine or (free and options.all))
            if wanted and free and count < MAX_PER_CLASS then
                claimed[montage.path] = true
                count = count + 1
                jobs[#jobs + 1] = { actor = entry.actor, class = entry.class, montage = montage.montage,
                                    home = entry.home, facing = entry.facing,
                                    name = montage.name, path = montage.path,
                                    length = montage.length, rateScale = montage.rateScale,
                                    blendOut = montage.blendOut }
            end
        end
    end
    -- A second pass for the montages nobody claimed by folder: the first compatible character plays them.
    if not options.all then
        for _, entry in ipairs(characters) do
            for _, montage in ipairs(anim.montagesFor(entry.actor)) do
                local wanted = not options.montage or montage.name:find(options.montage, 1, true)
                if wanted and not claimed[montage.path] then
                    claimed[montage.path] = true
                    jobs[#jobs + 1] = { actor = entry.actor, class = entry.class, montage = montage.montage,
                                        home = entry.home, facing = entry.facing,
                                        name = montage.name, path = montage.path,
                                        length = montage.length, rateScale = montage.rateScale,
                                        blendOut = montage.blendOut }
                end
            end
        end
    end
    table.sort(jobs, function(a, b)
        if a.class ~= b.class then return a.class < b.class end
        return a.name < b.name
    end)
    return jobs, #characters
end

-- Stops the character's AI and pins it where it stands, so what the montage does to it is the only thing
-- measured. The player is left ticking (his tick drives input and the camera); he is only stopped moving.
local function freeze(job, pawn)
    local actor = job.actor
    job.held = anim.hold(actor)
    if actor:GetAddress() ~= pawn:GetAddress() then
        pcall(function() actor:SetActorTickEnabled(false) end)
        -- The actor's own tick is not what walks it: the Falcon state component and the AI controller
        -- tick separately and keep asking it to move. A character walking when its montage starts would
        -- otherwise carry that walk into the measurement, and one frame of it is eleven times further at
        -- 30 FPS than at 320, which looks exactly like the bug being looked for.
        pcall(function() actor.FalconEnemy:SetComponentTickEnabled(false) end)
        pcall(function()
            local controller = actor.Controller
            if controller:IsValid() then controller:SetActorTickEnabled(false) end
        end)
    end
    pcall(function()
        local cmc = actor.CharacterMovement
        if cmc:IsValid() then cmc:StopMovementImmediately() end
    end)
end

local function thaw(job, pawn)
    if not job then return end
    anim.release(job.held)
    job.held = nil
    local actor = job.actor
    if actor and pcall(function() return actor:IsValid() end) and actor:IsValid()
       and actor:GetAddress() ~= pawn:GetAddress() then
        pcall(function() actor:SetActorTickEnabled(true) end)
        pcall(function() actor.FalconEnemy:SetComponentTickEnabled(true) end)
        pcall(function()
            local controller = actor.Controller
            if controller:IsValid() then controller:SetActorTickEnabled(true) end
        end)
    end
end

-- Everything a montage is measured for, so a row is written even when it never started.
local function newMeasure()
    return { duration = 0, frames = 0, maxPos = 0, prevPos = 0, rootFrames = 0, moveDist = 0, moveZ = 0,
             drift = 0, rootSeen = false, fx = 0, fxWorld = 0, audio = 0, audioWorld = 0, startState = "", endState = "",
             x0 = 0, y0 = 0, z0 = 0, lastX = 0, lastY = 0, lastZ = 0,
             nextSample = 0, timeout = 0, ended = nil, tail = 0 }
end

-- A montage that was never tried (its character walked off, or has no anim instance here) is not marked
-- done: the next level that holds the same character measures it instead.
local UNTRIED = { ["actor gone"] = true, ["no anim instance"] = true }

local function finishMontage(pawn, result)
    local job, m = run.job, run.measure
    local file = openCsv()
    if file then
        local avgFps = m.frames > 0 and m.frames / math.max(m.duration, 1e-6) or 0
        file:write(string.format("%d,%s,%s,%s,%s,%s,%.3f,%.3f,%.3f,%.4f,%d,%.1f,%.4f,%d,%.2f,%.2f,%.2f,%d,%d,%d,%d,%s,%s,%s\n",
            run.caps[run.capIndex], run.level, job.class, actorName(job.actor), job.name, job.path,
            job.length, job.blendOut or 0, job.rateScale, m.duration, m.frames, avgFps, m.maxPos,
            m.rootFrames, m.moveDist, m.moveZ, m.drift, m.fx, m.fxWorld, m.audio, m.audioWorld,
            m.startState, m.endState, result))
        file:flush()
    end
    if result ~= "played" and result ~= "looped" then
        log("animtest: %s %s %s: %s (%.2f s of %.2f, %d frames, %.0f units, %d fx)", run.level, job.class,
            job.name, result, m.duration, job.length, m.frames, m.moveDist, m.fx)
    end
    watching = nil
    if run.instance then anim.stop(run.instance, job.montage) end
    thaw(job, pawn)
    if not UNTRIED[result] then markDone(string.format("%d %s", run.caps[run.capIndex], job.path)) end
    run.job, run.measure, run.instance = nil, nil, nil
    run.phase = "next"
    writeProgress()
end

-- Plays the montage in run.job, which the caller has picked.
local function startMontage(pawn)
    local job = run.job
    run.measure = newMeasure()
    if not (job.actor and pcall(function() return job.actor:IsValid() end) and job.actor:IsValid()) then
        finishMontage(pawn, "actor gone")
        return
    end
    freeze(job, pawn)
    -- Back to the spot and facing it had when the level's montages were listed, so the same montage
    -- starts from the same place in both passes whatever the montages before it did to the character.
    if job.home then
        pcall(function() job.actor:K2_TeleportTo(job.home, job.facing) end)
    end
    run.phase, run.resetLeft = "reset", RESET
end

local function playMontage(pawn)
    local job, m = run.job, run.measure
    local instance = anim.instance(job.actor)
    if not instance then
        finishMontage(pawn, "no anim instance")
        return
    end
    local before = anim.state(job.actor, instance)
    m.startState, m.endState = before.enemyState, before.enemyState
    if not anim.play(instance, job.montage) then
        finishMontage(pawn, "refused")
        return
    end
    local loc = job.actor:K2_GetActorLocation()
    fxOwned, fxAll, audioOwned, audioAll = 0, 0, 0, 0
    watching = job.actor:GetAddress()
    run.instance = instance
    m.x0, m.y0, m.z0 = loc.X, loc.Y, loc.Z
    m.lastX, m.lastY, m.lastZ = loc.X, loc.Y, loc.Z
    m.timeout = job.length > 0 and job.length * TIMEOUT_FACTOR + TIMEOUT_EXTRA or UNKNOWN_TIMEOUT
    run.phase = "play"
end

local function sampleMontage(job, m, s, loc, speed)
    local file = openSamples()
    if not file then return end
    file:write(string.format("%d,%s,%s,%s,%.3f,%.4f,%.2f,%.2f,%.2f,%.2f\n",
        run.caps[run.capIndex], run.level, job.class, job.name, m.nextSample, s.position,
        loc.X - m.x0, loc.Y - m.y0, loc.Z - m.z0, speed))
end

-- The character's own AI keeps walking it about while the montage plays (its state component and its
-- movement tick on with the actor's tick off: the chickens wandered 80 units through their Squawk), and
-- that walk would be read as the animation's own displacement. So the only frames that count towards the
-- displacement are the ones where the montage's root motion is driving it; on every other frame the
-- character is put back where the last such frame left it. `drift` is how far it had to be pulled back,
-- which says how hard its AI was pulling.
local function holdStill(actor, m, loc, rootMotion)
    if rootMotion then m.rootSeen = true end
    -- Once the montage's root motion has taken over, every frame counts: the frame it starts on is a
    -- whole 33 ms of movement at 30 FPS against 3 ms at 320, so leaving those out biases the comparison
    -- by a frame's worth. Before that, the character is pinned.
    if m.rootSeen then
        m.moveDist = m.moveDist + math.sqrt((loc.X - m.lastX) ^ 2 + (loc.Y - m.lastY) ^ 2)
        m.moveZ = m.moveZ + (loc.Z - m.lastZ)
        m.lastX, m.lastY, m.lastZ = loc.X, loc.Y, loc.Z
        return
    end
    local moved = math.sqrt((loc.X - m.lastX) ^ 2 + (loc.Y - m.lastY) ^ 2 + (loc.Z - m.lastZ) ^ 2)
    if moved < 0.01 then return end
    m.drift = m.drift + moved
    HOME.X, HOME.Y, HOME.Z = m.lastX, m.lastY, m.lastZ
    pcall(function() actor:K2_SetActorLocation(HOME, false, HIT, true) end)
    pcall(function()
        local cmc = actor.CharacterMovement
        if not cmc:IsValid() then return end
        cmc.Velocity = ZERO
        cmc.Acceleration = ZERO
        cmc.RequestedVelocity = ZERO
        cmc.bHasRequestedVelocity = false
    end)
end

local function updatePlay(pawn, r)
    local job, m = run.job, run.measure
    if not (job.actor and pcall(function() return job.actor:IsValid() end) and job.actor:IsValid()) then
        finishMontage(pawn, "actor gone")
        return
    end
    local s = anim.state(job.actor, run.instance)
    local loc = job.actor:K2_GetActorLocation()
    local speed = 0
    pcall(function()
        local v = job.actor.CharacterMovement.Velocity
        speed = math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z)
    end)
    -- The notify counts carry on through the tail, so an effect spawned on the last frame is counted.
    m.fx, m.fxWorld, m.audio, m.audioWorld = fxOwned, fxAll, audioOwned, audioAll
    if not m.ended then
        local playing = s.playing and s.montage == job.name
        -- A montage that loops (its last section runs back into itself) never stops on its own: the
        -- position going backwards is the end of one pass through it, which is what is measured.
        local wrapped = playing and s.position + 1e-4 < m.prevPos
        m.duration = m.duration + r.dt
        m.frames = m.frames + 1
        m.maxPos = math.max(m.maxPos, s.position)
        m.prevPos = s.position
        if s.rootMotion then m.rootFrames = m.rootFrames + 1 end
        m.endState = s.enemyState
        holdStill(job.actor, m, loc, s.rootMotion)
        if m.duration >= m.nextSample then
            sampleMontage(job, m, s, loc, speed)
            m.nextSample = m.nextSample + SAMPLE
        end
        if not playing then
            -- It stopped before it got anywhere: the character's own state machine played something else
            -- over it. That is not a measurement of this animation, so it is called what it is.
            local reached = job.length - (job.blendOut or 0) - CUT_SHORT
            m.ended = (job.length > 0 and m.maxPos < reached) and "cut short" or "played"
        elseif wrapped then
            m.ended = "looped"
        elseif m.duration >= m.timeout then
            -- A montage whose loop is shorter than a frame comes back to the same position every time it
            -- is read, so it never looks like it wrapped: at 30 FPS the chicken's 0.03 s death loop reads
            -- 0.000 for ever, while at 320 the same loop is caught wrapping. That is the sampling, not
            -- the game, so it is named for what it is and tools/Compare-Animtest.ps1 does not time it.
            local avgDt = m.duration / math.max(m.frames, 1)
            local subFrame = m.maxPos <= avgDt
            if not subFrame then
                log("animtest: %s %s %s stuck at %.3f: %s", run.level, job.class, job.name, m.maxPos,
                    anim.diagnose(job.actor, run.instance, job.montage))
            end
            finishMontage(pawn, subFrame and "sub-frame loop" or "stuck")
        end
        return
    end
    m.tail = m.tail + r.dt
    if m.tail >= TAIL then finishMontage(pawn, m.ended) end
end

local function nextLevel(pawn, setFpsCap)
    run.levelIndex = run.levelIndex + 1
    run.capIndex, run.jobIndex, run.jobs = 1, 1, nil
    local level = run.levels[run.levelIndex]
    if not level then
        log("animtest: done, %d levels, %d montages measured; %s", run.levelIndex - 1, run.measured, CSV)
        invuln.clear()
        os.remove(PROGRESS)
        run = nil
        return
    end
    if SKIP_LEVELS[level] then
        log("animtest: %s skipped (flight level or speedway)", level)
        run.phase = "level"
        return
    end
    run.level = level
    setFpsCap(run.caps[1])
    if level == levels.current(pawn) then
        run.phase, run.settleLeft = "settle", SETTLE
    elseif quicksave.travel(pawn, level) then
        run.phase = "travel"
    else
        log("animtest: %s skipped, travel failed", level)
        run.phase = "level"
    end
    writeProgress()
end

-- The jobs still to do at this cap: montages measured at this cap in an earlier level are dropped here,
-- which is what stops the shared rhynoc animations being replayed in every level.
local function jobsLeft()
    local cap, left = run.caps[run.capIndex], {}
    for _, job in ipairs(run.jobs) do
        if not run.done[string.format("%d %s", cap, job.path)] then left[#left + 1] = job end
    end
    return left
end

local function startCap(pawn, setFpsCap)
    local cap = run.caps[run.capIndex]
    setFpsCap(cap)
    run.jobsForCap, run.jobIndex = jobsLeft(), 1
    log("animtest: %s at %d FPS, %d montages (%d in the level, %d already measured)", run.level, cap,
        #run.jobsForCap, #run.jobs, #run.jobs - #run.jobsForCap)
    run.phase = "next"
end

local function update(pawn, pc, r, setFpsCap)
    if os.clock() >= nextPoll then
        nextPoll = os.clock() + 1
        if run and run.levels then
            -- The trigger file is only read between runs, so a run going for hours is stopped with its
            -- own file (as tools/spawntest.lua does), no game window needed.
            local stop = io.open(STOP, "r")
            if stop then
                stop:close()
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
        if run and run.levels then
            log("animtest: stopped at %s", tostring(run.level))
            thaw(run.job, pawn)
            watching = nil
            invuln.clear()
            run = nil
            return
        end
        local options = (run and run.options) or {}
        if options.restart then os.remove(DONE) end
        local list = levelList(pawn, options)
        local levelIndex = 1
        if not options.restart and not options.here and not options.level then
            levelIndex = readProgress()
        end
        local done = options.restart and {} or loadDone()
        local already = 0
        for _ in pairs(done) do already = already + 1 end
        run = { options = options, caps = parseCaps(options.caps or ""), levels = list,
                levelIndex = levelIndex - 1, capIndex = 1, jobIndex = 1,
                done = done, measured = 0, phase = "level" }
        log("animtest: %d levels, caps %s, %d montages already measured, starting at level %d (%s)",
            #list, table.concat(run.caps, "/"), already, levelIndex, tostring(list[levelIndex]))
        nextLevel(pawn, setFpsCap)
        return
    end
    if not run or not run.levels then return end
    invuln.update(pawn)

    if run.phase == "travel" then
        if quicksave.travelling() then return end
        if levels.current(pawn) ~= run.level then
            log("animtest: %s skipped, never arrived", run.level)
            run.phase = "level"
        else
            run.phase, run.settleLeft = "settle", SETTLE + TRAVEL_GRACE
        end
    end
    if run.phase == "settle" then
        run.settleLeft = run.settleLeft - r.dt
        if run.settleLeft > 0 then return end
        local jobs, characters = buildJobs(pawn, run.options)
        run.jobs = jobs
        log("animtest: %s has %d kinds of character and %d montages", run.level, characters, #jobs)
        if #jobs == 0 then
            run.phase = "level"
        else
            startCap(pawn, setFpsCap)
        end
    end
    if run.phase == "reset" then
        run.resetLeft = run.resetLeft - r.dt
        if run.resetLeft <= 0 then playMontage(pawn) end
        return
    end
    if run.phase == "play" then
        updatePlay(pawn, r)
        return
    end
    if run.phase == "next" then
        local index = run.jobIndex
        run.jobIndex = index + 1
        if index <= #(run.jobsForCap or {}) then
            run.job = run.jobsForCap[index]
            run.measured = run.measured + 1
            startMontage(pawn)
            return
        end
        run.capIndex, run.jobIndex = run.capIndex + 1, 1
        if run.capIndex > #run.caps then
            nextLevel(pawn, setFpsCap)
        else
            startCap(pawn, setFpsCap)
        end
        return
    end
    if run.phase == "level" then nextLevel(pawn, setFpsCap) end
end

function animtest.update(pawn, pc, r, setFpsCap)
    local ok, err = pcall(update, pawn, pc, r, setFpsCap)
    if not ok then
        log("animtest error: %s", tostring(err))
        if run then thaw(run.job, pawn) end
        run = nil
    end
end

function animtest.toggle()
    requested = true
end

return animtest
