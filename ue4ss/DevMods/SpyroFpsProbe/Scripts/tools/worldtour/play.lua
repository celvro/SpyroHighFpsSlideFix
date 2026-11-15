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
local APPROACH_MAX = 6.0   -- seconds of walking at the target before he is put next to it instead
local APPROACH_STALL = 1.0 -- told to walk and not moving for this long: the same
local APPROACH_FACING = 12 -- degrees off the target he may face and still be counted as lined up
local PLACED_DISTANCE = 300 -- how far off the spot he may still be and be counted as placed on it
local FELL_HEIGHT = 90     -- below the stop AND falling: put him back before the water kills him. Walking
                           -- down steps and slopes is not falling, so it does not count.
local DEATH_SETTLE = 1.0    -- seconds on his feet again after a death before the run carries on
local VERIFY_SECONDS = 0.6 -- pushing forward at the next stop, to see whether he is still held
local LOST_HEIGHT = 1000   -- drop from the stop that means he is out of the level, not playing the script
local LOST_DISTANCE = 5000 -- and the same sideways (a respawn puts him at the level entrance)
local LOCKED_SECONDS = 2.0 -- held forward for this long without moving: the game has taken input away
-- A gameplay camera sits about 150 units behind him. A cinematic one is thousands: LS101 measured
-- 2948 for every stop after Marco the Balloonist, with the camera and the input both gone. So a camera
-- this far out, on a stop that cannot move, is the game driving rather than a stop wedged against a
-- rock -- and it is believed in preference to igc.active(), which did not see that state at all.
local CINEMATIC_CAM_DIST = 600
local TALK_SECONDS = 25.0  -- longest a stop waits for a conversation it started to finish
local SUBWORLD_SECONDS = 12.0 -- how long to play as whoever a subworld handed the controller to
local DEATHS = paths.modDir .. "\\autotest_deaths.txt"
-- One line per flame or charge stop that ended without the target being damaged or killed: the stop is
-- not measuring what it was recorded for, and is to be fixed (a flyer he cannot reach, a target behind
-- something, a character that takes neither). Tour-Unattended.ps1 copies it into the run folder.
local NOHIT = paths.modDir .. "\\autotest_nohit.txt"
local HIT_WORDS = { "hit", "death", "dead", "die", "flamed", "burn", "damage", "stun", "knock", "charged" }
local HIT_CHECK = 0.1 -- seconds between looks at the target: each is several reflection calls

-- Ends the stop: lets go of the input and of the target, moves along any conversation it opened, and
-- notes whether he could move (the level is loaded again after LOCKED_STOPS that could not).
-- Has the stop's target been damaged or killed yet? Three signs, any of which will do: it is gone (a
-- kill destroys the actor), its health is below where it started, or its enemy state or montage has
-- become one named for being hit. Looked at every HIT_CHECK seconds while the script plays.
-- The target's health attribute set, looked for once when the watch starts: FindAllOf walks every object
-- (CLAUDE.md), and lib/invuln.lua's own lookup keeps one slot, for Spyro, so asking it about the target
-- every tenth of a second would have walked the object array each time. Nil for a character without one.
local function healthSetOf(actor)
    local address = actor:GetAddress()
    for _, set in ipairs(FindAllOf("PhasmidHealthSystemAttributeSet") or {}) do
        local ok, outer = pcall(function() return set:GetOuter():GetAddress() end)
        if ok and outer == address then return set end
    end
    return nil
end

local function healthOf(set)
    if not (set and set:IsValid()) then return nil end
    local ok, value = pcall(function() return set.HealthCurrent end)
    if not ok then return nil end
    if type(value) == "number" then return value end
    local okValue, current = pcall(function() return value.CurrentValue end)
    return okValue and type(current) == "number" and current or nil
end

local function hitWord(text)
    text = text:lower()
    for _, word in ipairs(HIT_WORDS) do
        if text:find(word, 1, true) then return true end
    end
    return false
end

local function watchHit(run, r)
    if run.hit or not run.hitWatch then return end
    run.hitNext = (run.hitNext or 0) - r.dt
    if run.hitNext > 0 then return end
    run.hitNext = HIT_CHECK
    local target = run.target
    if not (target and pcall(function() return target:IsValid() end) and target:IsValid()) then
        run.hit = "killed (the actor is gone)"
        return
    end
    local distance = drive.targetDistance(run, r)
    if distance and distance < (run.hitClosest or math.huge) then run.hitClosest = distance end
    local okLoc, loc = pcall(function() return target:K2_GetActorLocation() end)
    if okLoc then run.hitApart = loc.Z - r.z end
    local health = healthOf(run.hitSet)
    if health and run.hitHealth and health < run.hitHealth then
        run.hit = string.format("damaged (health %.0f to %.0f)", run.hitHealth, health)
        return
    end
    local state = anim.state(target)
    local now = state.enemyState .. " " .. state.montage
    if now ~= run.hitStart and hitWord(now) then run.hit = "reacted (" .. now .. ")" end
end

local function reportHit(run)
    if not run.hitWatch then return end
    local entry = run.step.entry
    if run.hit then
        run.dirty = true -- arrive.lua puts the enemies back before the next stop aimed at one
        log("autotest: %s stop %d (%s, %s) hit its target: %s", entry.stop.level, entry.id,
            entry.stop.script, entry.stop.note, run.hit)
    else
        local line = string.format("%s stop %d %s %s at %d FPS: NOT HIT in %.1f s (%.1f s walking in, closest %.0f units, %s)",
            entry.stop.level, entry.id, entry.stop.script, entry.stop.note, run.step.cap,
            (run.elapsed or 0) + (run.approachFor or 0), run.approachFor or 0, run.hitClosest or -1,
            run.hitApart and string.format("target %.0f units %s him", math.abs(run.hitApart), run.hitApart > 0 and "above" or "below") or "height unknown")
        log("autotest: %s -- flagged in autotest_nohit.txt", line)
        local file = io.open(NOHIT, "a")
        if file then
            file:write(os.date("%Y-%m-%d %H:%M:%S") .. " " .. line .. "\n")
            file:close()
        end
    end
    run.hitWatch, run.hit, run.hitHealth, run.hitStart, run.hitClosest, run.hitNext = nil, nil, nil, nil, nil, nil
    run.hitSet = nil
end

local function finish(run, pawn, pc, reason)
    local entry = run.step.entry
    input.clear(pawn, pc)
    reportHit(run)
    drive.thaw(run.frozen)
    run.frozen = nil
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
function play.settle(run, r, pawn, pc, cmc)
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
    -- Settling for a second is not the same as having arrived. The teleport does not always take effect
    -- in that second: in the trilogy run of 2026-11-04, 349 of 3733 runs (9%) started their script still
    -- standing where the last stop left them, 3000-odd units away, and snapped onto the spot a second
    -- later. The origin is taken below, so every sample of such a run is offset by the distance between
    -- the two places and the input was driven at the wrong one -- unrepairable afterwards, and loud
    -- enough to fill the top of the report. How many frames the teleport takes depends on the framerate,
    -- so it reads as a framerate difference (11% of the 30 FPS runs, 7% of the 160 FPS ones).
    if run.spot then
        local dx, dy, dz = r.x - run.spot.x, r.y - run.spot.y, r.z - run.spot.z
        if dx * dx + dy * dy + dz * dz > PLACED_DISTANCE * PLACED_DISTANCE then
            if run.settled >= SETTLE_MAX then
                log("autotest: %s stop %d skipped, still %.0f units from the spot after %.1f s " ..
                    "(the teleport never landed)", entry.stop.level, entry.id,
                    math.sqrt(dx * dx + dy * dy + dz * dz), run.settled)
                run.phase = "next"
            end
            return
        end
    end
    -- The last stop could not move, so before this one is played, find out whether he still
    -- cannot. Here is the place to ask: the teleport has moved him away from whoever was
    -- talking to him. Asking at the locked stop itself only ever said yes, because the NPC was
    -- still standing there saying it.
    if run.checkNext then
        run.phase, run.verifyFor, run.verifyBest = "verify", 0, 0
        return
    end
    -- A flame or a charge at a character has to start within reach of it (scripts.approach): the
    -- recorded spot is 400 units off and the character has wandered since the scan. So he walks up to
    -- it first ("approach"), and the script's clock, origin and samples all start from where that ends.
    if pawn and not run.approached and scripts.approach(entry.stop.script)
       and drive.targetDistance(run, r) then
        run.phase, run.approachFor, run.approachStalled, run.approachPlaced = "approach", 0, 0, nil
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
        -- A flame or a charge at it is meant to land: watch for that (watchHit), from how it is now.
        if scripts.approach(entry.stop.script) then
            local state = anim.state(run.target)
            run.hitWatch, run.hit, run.hitNext, run.hitClosest = true, nil, 0, nil
            run.hitSet = healthSetOf(run.target)
            run.hitHealth = healthOf(run.hitSet)
            run.hitStart = state.enemyState .. " " .. state.montage
        end
    end
end

-- "approach": walking up to the stop's target until it is within the script's reach, facing it. Not part
-- of the script: nothing is sampled and its clock does not run, so every pass starts its flame or charge
-- from the same distance however long the walk took. A walk that cannot get there (a drop between them,
-- a wall, a character that outruns him) ends with him put at that distance instead, and that is logged,
-- because a stop that had to be placed is one where the walk-in itself is not comparable.
function play.approach(run, pawn, pc, cmc, r)
    local entry = run.step.entry
    local want = scripts.approach(entry.stop.script)
    local distance = drive.targetDistance(run, r)
    local function done(how)
        input.clear(pawn, pc)
        log("autotest: %s stop %d (%s, %s) %s, %.0f units away after %.1f s", entry.stop.level, entry.id,
            entry.stop.script, entry.stop.note, how, distance or -1, run.approachFor)
        run.approached, run.arrived, run.lockedFor = true, nil, nil
        run.spot = { x = r.x, y = r.y, z = r.z }
        run.phase, run.settled = "settle", SETTLE
    end
    if not distance then return done("lost its target on the way in") end
    run.approachFor = run.approachFor + r.dt
    local yaw = drive.yawTo(run.target, r.x, r.y)
    local facing = yaw and math.abs((r.yaw - yaw + 180) % 360 - 180) or 0
    local grounded = r.mode ~= 3
    local level = drive.levelWith(run.target, r)
    if distance <= want and facing <= APPROACH_FACING and grounded and level then
        return done(run.approachPlaced and "was put next to it" or "walked up to it")
    end
    if (r.speed or 0) < drive.LOCKED_SPEED then
        run.approachStalled = run.approachStalled + r.dt
    else
        run.approachStalled = 0
    end
    -- Within reach on the map but on another level (a perch above him, a field below a ledge): no
    -- amount of walking at it closes that, and a charge from here runs under it or off the edge.
    local apart = distance <= want and grounded and not level
    local walking = not run.approachPlaced and not apart and drive.walkAt(run, pawn, pc, r)
    if walking and run.approachStalled < APPROACH_STALL and run.approachFor < APPROACH_MAX then return end
    -- The walk is not getting there. Put him at the distance, on the side he is already on, facing it;
    -- again each frame it has moved out of reach, until he is standing there.
    input.clear(pawn, pc)
    if run.approachFor > APPROACH_MAX * 2 then return done("could not be put next to it") end
    if not grounded and run.approachPlaced then return end
    -- Only once he has landed from the last placing, and then only if that left him out of reach.
    if run.approachPlaced and distance <= want and level then
        local toYaw = drive.yawTo(run.target, r.x, r.y)
        if toYaw then
            pawn:K2_SetActorRotation({ Pitch = 0, Yaw = toYaw, Roll = 0 }, false)
            pc:SetControlRotation({ Pitch = 0, Yaw = toYaw, Roll = 0 })
        end
        return
    end
    local reach = want * 0.85
    local spot = drive.spotBeside(pawn, run.target, r, reach)
    if not spot then
        -- Nowhere to stand beside it. Under it, at the distance, is the best there is; the stop will
        -- most likely end without a hit and be flagged.
        local loc = run.target:K2_GetActorLocation()
        local dx, dy = r.x - loc.X, r.y - loc.Y
        local len = math.sqrt(dx * dx + dy * dy)
        if len < 1 then dx, dy, len = 1, 0, 1 end
        if run.approachPlaced then return done("has nowhere to stand beside it") end
        spot = { x = loc.X + dx / len * reach, y = loc.Y + dy / len * reach, z = r.z,
                 yaw = math.deg(math.atan(-dy, -dx)) }
    end
    pawn:K2_TeleportTo({ X = spot.x, Y = spot.y, Z = spot.z }, { Pitch = 0, Yaw = spot.yaw, Roll = 0 })
    cmc.Velocity = { X = 0, Y = 0, Z = 0 }
    pc:SetControlRotation({ Pitch = 0, Yaw = spot.yaw, Roll = 0 })
    pcall(function() pawn.FollowCamera:ResetBehind(true) end)
    run.approachPlaced = true
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
    -- The game has the camera as well as the input: it is playing something (a balloon ride, a
    -- transporter, a cutscene with no IGC actor saying so), and nothing measured while that happens is
    -- this stop's script. Ending here and escalating straight to arrive.lua's reload is what stops the
    -- rest of the level being written down as a standstill -- which it was, for two whole passes of
    -- LS101 on 2026-11-04, at 25 s a stop.
    if (run.lockedFor or 0) >= LOCKED_SECONDS and (r.camDist or 0) > CINEMATIC_CAM_DIST then
        run.lockedStops = arrive.LOCKED_STOPS
        finish(run, pawn, pc, string.format(
            "the game has the camera (%.0f units out, gameplay is about 150) and the input", r.camDist))
        return true
    end
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
    watchHit(run, r)
    if trouble(run, pawn, pc, cmc, r) then return true end
    return playScript(run, pawn, pc, r)
end

return play
