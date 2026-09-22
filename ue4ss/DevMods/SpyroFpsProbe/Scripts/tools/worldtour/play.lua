-- Playing a stop once he is on it: standing still for SETTLE seconds (the camera and the ground check),
-- then the stop's script (scripts.lua, moved by drive.lua) while samples.lua writes a row every 0.1 s,
-- until the script runs out, he dies, falls, is carried off, or cannot move. Phases "settle", "verify",
-- "play" and "dead"; each ends the stop through finish(), which leaves the phase at "next" (or "held",
-- review.lua).
--
-- A stop that ends "could not move" is one where he was held forward and stayed put with nothing near
-- him to explain it. Walking into the character he was sent at is not that: a character has collision
-- and he stops against it further out than it counts as arriving (drive.lua). What is left is a spot
-- facing a rock, or the rarer case of the game taking input away. The next stop then starts by pushing
-- forward for a moment ("verify"), and if he still cannot move the level is loaded again (arrive.lua).
--
-- Dialogue is an in-game cinematic and it takes input away until it closes. Holding the probe's own face
-- buttons never skipped one (29 of 32 failed): they go to the character, not to the cinematic. So text
-- boxes get Continue and cutscenes the skip button, each sent to the widget or actor that reads it
-- (lib/igc.lua), and a stop that still cannot move gets the level loaded again.
--
--   autotest_deaths.txt  one line per death: the stop and the character
local anim = require("lib.anim")
local igc = require("lib.igc")
local input = require("lib.input")
local invuln = require("lib.invuln")
local log = require("lib.log")
local paths = require("lib.paths")
local subworld = require("lib.subworld")
local arrive = require("tools.worldtour.arrive")
local drive = require("tools.worldtour.drive")
local plan = require("tools.worldtour.plan")
local samples = require("tools.worldtour.samples")
local scripts = require("tools.worldtour.scripts")

local play = {}

local SETTLE = 1.0   -- seconds standing still after the teleport, before the script starts
local SETTLE_MAX = 4.0 -- but a fall from the teleport is given this long to land before the stop is dropped
local FELL_HEIGHT = 90     -- below the stop AND falling: put him back before the water kills him. Walking
                           -- down steps and slopes is not falling, so it does not count.
local DEATH_SETTLE = 1.0    -- seconds on his feet again after a death before the run carries on
local VERIFY_SECONDS = 0.6 -- pushing forward at the next stop, to see whether he is still held
local LOST_HEIGHT = 1000   -- drop from the stop that means he is out of the level, not playing the script
local LOST_DISTANCE = 5000 -- and the same sideways (a respawn puts him at the level entrance)
local LOCKED_SECONDS = 2.0 -- held forward for this long without moving: the game has taken input away
local TALK_SECONDS = 25.0  -- longest a stop waits for a conversation it started to finish
local SUBWORLD_SECONDS = 12.0 -- how long to play as whoever a subworld handed the controller to
local DEATHS = paths.modDir .. "\\autotest_deaths.txt"

-- Ends the stop: lets go of the input and of the target, moves along any conversation it opened, and
-- notes whether he could move (the level is loaded again after LOCKED_STOPS that could not).
local function finish(run, pawn, pc, reason)
    local entry = run.step.entry
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
        run.step.cap, entry.stop.level, entry.id, entry.stop.script, entry.stop.note,
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
    plan.saveProgress(run.index)
end

-- "settle": standing still on the spot before the script.
function play.settle(run, r)
    local entry = run.step.entry
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
    if run.settled < SETTLE then return end
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

-- "verify": pushing forward at the start of a stop that follows a locked one. If he moves, the
-- conversation ended with the stop and nothing is lost; if he does not, the level is loaded again, which
-- is the only thing that reliably clears one.
function play.verify(run, pawn, pc, r)
    drive.forward(pawn, pc)
    run.verifyFor = run.verifyFor + r.dt
    run.verifyBest = math.max(run.verifyBest, r.speed or 0)
    if run.verifyFor < VERIFY_SECONDS then return end
    input.clear(pawn, pc)
    local moved = run.verifyBest >= drive.LOCKED_SPEED
    run.checkNext, run.verifyFor, run.verifyBest = nil, nil, nil
    if moved then
        -- Back through the settle, which is what pins the target's mesh and records where it
        -- started; going straight to "play" would skip all of it.
        run.lockedStops = 0
        run.phase, run.settled = "settle", SETTLE
    else
        log("autotest: still cannot move at the next stop; loading %s again", run.step.entry.stop.level)
        run.lockedStops = arrive.LOCKED_STOPS
        run.phase = "next"
    end
end

-- "dead": the death animation, the respawn and the fall back into place are not this stop's script, so
-- nothing is driven or sampled until he is back on his feet, and the stop is given up rather than
-- compared.
function play.dead(run, pawn, pc, r)
    input.clear(pawn, pc)
    local health = invuln.health(pawn)
    if (health or 0) > 0 and r.mode ~= 3 and not r.rootMotion then
        run.deadFor = (run.deadFor or 0) + r.dt
        if run.deadFor >= DEATH_SETTLE then finish(run, pawn, pc, "died") end
    else
        run.deadFor = 0
    end
end

-- Somebody else is holding the controller: the conversation handed over to Sheila, Sgt Byrd, Bentley or
-- Agent 9 and their minigame is running in a sublevel of this same level. Play it for a while, sampling
-- as usual -- these animations are reachable no other way, because the tour cannot record a stop inside a
-- minigame that is not running when the level is scanned -- and then leave by loading the level again,
-- the game's own load. Leaving through the pause menu never worked, and the tour does not touch the HUD.
local function playSubworld(run, pawn, pc, r)
    samples.due(run, pawn, r)
    run.subworldFor = run.subworldFor + r.dt
    run.elapsed = run.elapsed + r.dt
    if run.subworldFor >= SUBWORLD_SECONDS then
        log("autotest: played %s for %.0f s; loading %s again to leave", run.inSubworld,
            run.subworldFor, run.step.entry.stop.level)
        run.inSubworld = nil
        finish(run, pawn, pc, "played a subworld")
        run.forceReload = true -- arrive.start loads the level again, whatever the reload count
        return
    end
    -- Whatever the character is, forward and jumping is playing it.
    local phase, into = scripts.phaseAt("play", run.subworldFor % scripts.duration("play"))
    if phase then drive.frame(run, pawn, pc, phase, into, r) end
end

-- Whatever ends a stop before its script does: a death, a fall, being carried off, or never moving at
-- all. True when the stop is over (or has gone to "dead").
local function trouble(run, pawn, pc, cmc, r)
    local entry = run.step.entry
    local health = invuln.health(pawn)
    if health and health <= 0 then
        -- The enemy that did it is written down, because that is the interesting part.
        local stop = entry.stop
        log("autotest: DIED at %s stop %d (%s, %s) %.1f s into the script, %d FPS pass",
            stop.level, entry.id, stop.script, stop.note, run.elapsed, run.step.cap)
        local deaths = io.open(DEATHS, "a")
        if deaths then
            deaths:write(string.format("%s %s stop %d %s %s at %.1f s, %d FPS\n", os.date("%Y-%m-%d %H:%M:%S"),
                stop.level, entry.id, stop.script, stop.note, run.elapsed, run.step.cap))
            deaths:close()
        end
        run.phase, run.deadFor = "dead", 0
        input.clear(pawn, pc)
        return true
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
        finish(run, pawn, pc, "walked off an edge (put back on the stop)")
        return true
    end
    -- Somewhere else entirely (a respawn): nothing left to compare.
    if math.abs(r.z - run.z0) > LOST_HEIGHT or math.abs(r.x - run.x0) > LOST_DISTANCE
       or math.abs(r.y - run.y0) > LOST_DISTANCE then
        finish(run, pawn, pc, "left the area (fell or respawned)")
        return true
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
        if run.step.measure then
            run.lockedFor = 0
        elseif run.everMoved then
            run.arrived = run.elapsed
            run.lockedFor = 0
            log("autotest: up against something after %.1f s, no more walking for the rest of the stop",
                run.elapsed)
        else
            finish(run, pawn, pc, "could not move at all (input taken away)")
            return true
        end
    end
    return false
end

-- A frame of the stop's own script. True while a conversation it started is being waited out.
local function playScript(run, pawn, pc, r)
    local entry = run.step.entry
    local level = entry.stop.level
    -- A cutscene or a text box that opened during the script: skip or Continue it as it comes, the
    -- way a player would, rather than only once the script is over.
    if igc.active(level) then igc.close(pc, pawn, level) end
    local phase, into = scripts.phaseAt(entry.stop.script, run.elapsed)
    if phase then
        samples.due(run, pawn, r)
        drive.frame(run, pawn, pc, phase, into, r)
        run.elapsed = run.elapsed + r.dt
        return false
    end
    -- The script has run out, but a conversation this stop started is still going. Ending the
    -- stop here teleports him out of it mid-sentence, which is what walking into Bentley used
    -- to look like. Wait for it instead, and keep sampling while it plays: the talking is a
    -- character animating, which is the whole point of the stop.
    if igc.active(level) then
        igc.close(pc, pawn, level) -- Continue, as a player would, until it ends
        run.talking = (run.talking or 0) + r.dt
        if run.talking < TALK_SECONDS then
            samples.due(run, pawn, r)
            run.elapsed = run.elapsed + r.dt
            return true
        end
    end
    samples.take(run, pawn, r, run.nextSample)
    finish(run, pawn, pc, (run.talking or 0) > 0 and "played (waited out a conversation)" or "played")
    return false
end

-- "play": a frame of the stop. True when that is all for this frame; false lets the caller go straight
-- on to the next stop when this one has just finished.
function play.step(run, pawn, pc, cmc, r)
    local now = subworld.character(pawn)
    if now and run.character and now ~= run.character and not run.inSubworld then
        run.inSubworld, run.subworldFor = now, 0
        log("autotest: %s took over at stop %d; playing its minigame", now, run.step.entry.id)
    end
    if run.inSubworld then
        playSubworld(run, pawn, pc, r)
        return true
    end
    if trouble(run, pawn, pc, cmc, r) then return true end
    return playScript(run, pawn, pc, r)
end

return play
