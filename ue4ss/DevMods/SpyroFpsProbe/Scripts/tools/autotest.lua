-- Scripted tour (O, or create autotest.txt in this mod folder): drives the game itself through every
-- recorded stop (tools/routes.lua) and plays a preset input script there (tools/scripts.lua), so the
-- same gameplay can be compared frame for frame between framerates.
--
-- Framerates are run one after the other, not at once: a run is the whole route at 30 FPS, then the
-- whole route at 60, 144 and 320. Each stop starts from the same teleport, facing the same way, at a
-- standstill, so the runs line up; tools/Compare-Autotest.ps1 joins them on (level, stop, script, t)
-- and reports where the high-framerate runs drift away from the 30 FPS one.
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
-- autotest.txt may hold options, one per line or space separated:
--   restart          start from the beginning instead of resuming autotest_progress.txt
--   caps=30,144      run these framerate caps (0 is uncapped)
--   level=LS102      only stops in this level
--   script=jump      only stops with this script
--
-- Progress is written to autotest_progress.txt after every stop, so a crash or a restart
-- (tools/Restart-Game.ps1 with lib/resume.lua) picks the run up where it stopped.
local ground = require("lib.ground")
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
local ARRIVE = 170         -- distance to the stop target at which the walk stops (it has been reached)
local LOST_HEIGHT = 1000   -- drop from the stop that means he is out of the level, not playing the script
local LOST_DISTANCE = 5000 -- and the same sideways (a respawn puts him at the level entrance)
local TRIGGER = paths.modDir .. "\\autotest.txt"
local PROGRESS = paths.modDir .. "\\autotest_progress.txt"
local DEATHS = paths.modDir .. "\\autotest_deaths.txt" -- one line per death: the stop and the character
local CSV = string.format("%s\\autotest_%s.csv", paths.modDir, paths.stamp)
local HEADER = "cap,level,stop,script,note,t,tActual,x,y,z,yaw,speed,mode,camYaw,camPitch,camDist,camHeight\n"
-- What the two characters that matter are animating at each sample: the one being played and the one the
-- stop was recorded in front of. The scripted walk into an enemy is what starts its chase or attack, so
-- this is where the animations the player actually sees are compared between framerates.
local ANIM_CSV = string.format("%s\\autotest_anims_%s.csv", paths.modDir, paths.stamp)
local ANIM_HEADER = "cap,level,stop,script,note,t,who,class,montage,montagePos,section,rate,rootMotion,"
    .. "state,stateTime,x,y,z,yaw,speed,mode\n"

local requested = false
local run = nil      -- { caps, capIndex, stops, index, phase, ... }
local csv, animCsv = nil, nil
local nextPoll = 0
local NO_AXES = {}   -- sticks centred, reused so driving a frame allocates nothing
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
    file:write(string.format("%d %d\n", run.capIndex, run.index))
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

-- The stops this run covers, in level order so each level is travelled to once.
local function buildStops(options)
    local all, picked = routes.all(), {}
    for index, stop in ipairs(all) do
        local wanted = (not options.level or stop.level == options.level)
            and (not options.script or stop.script == options.script)
        if wanted then
            if scripts.exists(stop.script) then
                picked[#picked + 1] = { stop = stop, id = index }
            else
                log("autotest: stop %d (%s) has no script %q, skipped", index, stop.level, tostring(stop.script))
            end
        end
    end
    table.sort(picked, function(a, b)
        if a.stop.level ~= b.stop.level then return a.stop.level < b.stop.level end
        return a.id < b.id
    end)
    return picked
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
    local entry = run.stops[run.index]
    input.clear(pawn, pc)
    anim.release(run.targetHeld)
    run.targetHeld, run.targetOrigin = nil, nil
    log("autotest %d FPS %s stop %d (%s, %s): %s after %.1f s, %d samples",
        run.caps[run.capIndex], entry.stop.level, entry.id, entry.stop.script, entry.stop.note,
        reason, run.elapsed or 0, run.samples or 0)
    run.phase = "next"
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

local function startStop(pawn, pc, cmc)
    local entry = run.stops[run.index]
    if not entry then return end
    local stop = entry.stop
    if levels.current(pawn) ~= stop.level then
        if not quicksave.travel(pawn, stop.level) then
            log("autotest: %s stop %d skipped, travel failed", stop.level, entry.id)
            run.phase = "next"
            return
        end
        run.phase = "travel"
        return
    end
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
    run.arrived = nil
    run.spot = spot
end

local function nextStop(pawn, pc, cmc, setFpsCap)
    run.index = run.index + 1
    if run.index > #run.stops then
        run.capIndex, run.index = run.capIndex + 1, 1
        if run.capIndex > #run.caps then
            log("autotest: done, %d stops at %d framerates; %s", #run.stops, #run.caps, CSV)
            input.clear(pawn, pc)
            invuln.clear()
            os.remove(PROGRESS)
            run = nil
            return
        end
        log("autotest: %d FPS pass (%d stops)", run.caps[run.capIndex], #run.stops)
    end
    setFpsCap(run.caps[run.capIndex])
    writeProgress()
    startStop(pawn, pc, cmc)
end

-- `slot` is the sample time the row stands for (0, 0.1, 0.2 ...), the same in every pass so the passes
-- join; tActual is the game time it was really taken at, a fraction of a frame later.
local function sample(r, entry, slot)
    local file = openCsv()
    if not file then return end
    file:write(string.format("%d,%s,%d,%s,%s,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%d,%.3f,%.3f,%.1f,%.1f\n",
        run.caps[run.capIndex], entry.stop.level, entry.id, entry.stop.script, entry.stop.note:gsub(",", " "),
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
        run.caps[run.capIndex], entry.stop.level, entry.id, entry.stop.script, entry.stop.note:gsub(",", " "),
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
local function drive(pawn, pc, phase, into, r)
    local distance = targetDistance(r)
    local edge = not run.arrived and atEdge(pawn, r)
    local arrived = run.arrived or edge or (distance and distance <= ARRIVE)
    if arrived and not run.arrived then
        run.arrived = run.elapsed
        log("autotest: %s after %.1f s, no more walking for the rest of the stop",
            edge and "stopped at the edge of a drop" or
            ("reached " .. run.stops[run.index].stop.note), run.elapsed)
    end
    -- Reaching the character (or a drop) lets go of the sticks, but the script's buttons carry on: a
    -- dialogue or minigame script has to keep tapping once it is standing in front of whoever starts it,
    -- and a flame or a jump is meant to happen where he ends up.
    input.hold(arrived and NO_AXES or phase.axes)
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

local function update(pawn, pc, cmc, r, setFpsCap)
    if not run and os.clock() >= nextPoll then
        nextPoll = os.clock() + 1
        local options = readOptions()
        if options then
            requested = true
            run = { options = options }
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
        local capIndex, index = 1, 1
        if not options.restart then
            local savedCap, savedIndex = readProgress()
            capIndex, index = savedCap, math.max(savedIndex, 1)
        end
        run = { caps = parseCaps(options.caps or ""), capIndex = capIndex, stops = stops, index = index,
                phase = "start", started = os.clock() }
        if run.capIndex > #run.caps then run.capIndex = 1 end
        log("autotest: %d stops, caps %s, starting at pass %d stop %d",
            #stops, table.concat(run.caps, "/"), run.capIndex, run.index)
        setFpsCap(run.caps[run.capIndex])
        startStop(pawn, pc, cmc)
        return
    end
    if not run or not run.stops then return end
    invuln.update(pawn)
    local entry = run.stops[run.index]

    if run.phase == "travel" then
        if quicksave.travelling() then return end
        if levels.current(pawn) ~= entry.stop.level then
            log("autotest: %s stop %d skipped, never arrived", entry.stop.level, entry.id)
            run.phase = "next"
        else
            run.phase, run.grace = "grace", TRAVEL_GRACE
        end
    end
    if run.phase == "grace" then
        run.grace = run.grace - r.dt
        if run.grace <= 0 then startStop(pawn, pc, cmc) end
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
        local health = invuln.health(pawn)
        if health and health <= 0 then
            local entryStop = entry.stop
            log("autotest: DIED at %s stop %d (%s, %s) %.1f s into the script, %d FPS pass",
                entryStop.level, entry.id, entryStop.script, entryStop.note, run.elapsed, run.caps[run.capIndex])
            local deaths = io.open(DEATHS, "a")
            if deaths then
                deaths:write(string.format("%s %s stop %d %s %s at %.1f s, %d FPS\n", os.date("%Y-%m-%d %H:%M:%S"),
                    entryStop.level, entry.id, entryStop.script, entryStop.note, run.elapsed, run.caps[run.capIndex]))
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
        local phase, into = scripts.phaseAt(entry.stop.script, run.elapsed)
        if not phase then
            sample(r, entry, run.nextSample)
            sampleAnims(pawn, entry, run.nextSample)
            stopFinished(pawn, pc, "played")
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

-- True while a run is going, so lib/resume.lua knows a restart should carry on with it.
function autotest.running()
    return run ~= nil and run.stops ~= nil
end

return autotest
