-- SpyroFpsProbe: records Spyro's movement every frame so jump, glide, sliding and charge behaviour can
-- be compared across framerates. A development mod: deploy it with tools/Install-UE4SS.ps1 -Probe, and
-- leave it off when profiling the fix mod (its per-frame garbage lands in the fixes' timed region).
--
-- Keys (game window focused; not F11, which toggles fullscreen, nor anything DefaultInput.ini binds):
--   F1 / F2 / C        minigame recording: mark a glitch / retry this one / drop into the next one
--   F3                 press Continue on the text box that is up (lib/dialogue.lua); in a review tour: looks fine
--   F4                 in a review tour (review.txt): wrong, and hold on this stop until F3
--   F5 / F6 / F7 / F8  set t.MaxFPS to 30 / 60 / 120 / 0 (uncapped); F4 sets 320
--   F9                 dump Spyro's FollowCameraComponent properties to camdump_*_manual.txt
--   F10                rescan for flame particle components (if a flame isn't picked up automatically)
--   K                  cycle the flame muzzle experiment: normal / noHardMuzzle / velocity30
--   V / B / L / N      quicksave: save this spot / go back to it / reload the level / dump the transporter
--   G                  scripted glide from a standstill, 600 above the saved spot (tools/glidetest.lua)
--   U                  spawn test: every chase/flee character type in front of Spyro, one at a time (tools/spawntest.lua)
--   J                  slide pose for screenshots: start the steep-slope slide here, press again to end it (tools/slide.lua)
--   R                  stuck charge camera repro: cycles 5 presets per press (12/33 deg at the 130.8 stick
--                      rate, the same two at the 210 mouse rate, then stop-and-restart), again to cancel.
--                      The controlled A/B for FIX_STUCK_CAMERA; needs ROW_CAMERA (tools/camrepro.lua)
--   M                  a minigame take: start/stop recording; otherwise record a tour stop (routes.txt)
--   H                  record a stop in front of every kind of character in this level (tools/scan.lua).
--                      For every level instead, drop a scansweep.txt file in this mod folder: it travels
--                      to each one in turn and scans it, which is how routes.txt is built without
--                      playing through all three games (tools/scansweep.lua). No key: a sweep runs for
--                      hours and every letter is bound already.
--   O                  world tour: every recorded stop, playing its input script, at 30/60/144/320 FPS (tools/worldtour/)
--   I                  montage sweep: every animation of every kind of character here, at 30 and 320 FPS (tools/animtest.lua)
--   Y                  non-finite velocity and anim speed: the gem thief (trackers/gemthief.lua) and a sweep
--                      over every NPC and enemy (trackers/nanspeed.lua). The thief is watched from the
--                      start; Y turns him off and the sweep on.
--   T                  poison test: write NaN into the gem thief's anim Blueprint Speed and hold the heal
--                      back for 5 s, to watch the pose break and come back (trackers/gemthief.lua)
--
-- Sparx is kept full while the probe is loaded (KEEP_SPARX_FULL below, lib/invuln.lua), so a test is not
-- cut short by a death and a level reload; Spyro still takes hits and knockback.
--
-- Output, in this mod folder and the UE4SS console and log:
--   trace_<stamp>.csv    one row per frame (columns in lib/trace.lua)
--   thieves_<stamp>.csv  one row per frame per active thief (trackers/thieves.lua)
--   flames_<stamp>.csv   one row per frame per active flame (trackers/flames.lua)
--   buzz_<stamp>.csv     one row per frame while Buzz exists (trackers/buzz.lua)
--   hits_<stamp>.csv     one row per blocking hit during a ground charge (trackers/hits.lua)
--   stalls_<stamp>.csv   one row per NPC/enemy movement stretch (trackers/stalls.lua)
--   lizard_<stamp>.csv   one row per frame per active Skelos Badlands lava lizard, plus
--   lizard_hits_<stamp>.csv  their blocking hits (trackers/lizard.lua)
--   turtle_<stamp>.csv   one row per frame per active Sunny Beach box turtle, plus
--   turtle_hits_<stamp>.csv  their blocking hits and slide bounces (trackers/turtle.lua)
--   autotest_<stamp>.csv one row per world tour sample, per framerate (tools/worldtour/samples.lua)
--   animtest_<stamp>.csv one row per montage per framerate (tools/animtest.lua)
--   scansweep_<stamp>.txt one line per level scanned by a sweep (tools/scansweep.lua)
--   camdump_*.txt        every reflected FollowCameraComponent property (trackers/camera.lua)
--   log lines            "seg", "drift", "rise" (trackers/movement.lua); "charge", "turn" (trackers/charge.lua);
--                        "camlock", "camstuck", "camtransition", "camdump diff" (trackers/camera.lua);
--                        "supercharge" (trackers/supercharge.lua); "dragon" (trackers/dragons.lua);
--                        "thief" (trackers/thieves.lua); "flame" (trackers/flames.lua); "walkin"
--                        (trackers/walkin.lua); "glide", "hover", "glideair" (trackers/glide.lua);
--                        "flight", "flightramp", "flightrun" (trackers/flight.lua);
--                        "chargestall" (trackers/hits.lua); "buzzrun" (trackers/buzz.lua);
--                        "stall", "stallsummary" (trackers/stalls.lua); "lizardstall", "lizardstep",
--                        "lizardsummary" (trackers/lizard.lua); "turtleslide", "turtlerun",
--                        "turtlestall", "turtlestart" (trackers/turtle.lua); "gemthief" (trackers/gemthief.lua); "nanspeed" (trackers/nanspeed.lua); "autotest", "review" (tools/worldtour/); "animtest" (tools/animtest.lua); "routes" (tools/routes.lua); "scan" (tools/scan.lua); "scansweep" (tools/scansweep.lua); "resume" (lib/resume.lua); "spawntest" (tools/spawntest.lua); "slide" (tools/slide.lua);
--                        quicksave, reload and travel lines (tools/quicksave.lua); "glidetest" (tools/glidetest.lua)
--
-- Scripts/
--   lib/       shared helpers: logging, the row sampled each frame, the trace CSV, object dumps, level queries
--   trackers/  one module per measurement, each documenting its own log lines
--   tools/     the quicksave / reload / travel aid and the test tools (the world tour in tools/worldtour/)

local UEHelpers = require("UEHelpers")
local log = require("lib.log")
local config = require("config")
local profile = require("lib.profile")
local levels = require("lib.levels")
local igc = require("lib.igc")
local dialogue = require("lib.dialogue")
local invuln = require("lib.invuln")
local mouse = require("lib.mouse")
local paths = require("lib.paths")
local row = profile.wrap("row", require("lib.row"))
local state = require("lib.state")
local trace = profile.wrap("trace", require("lib.trace"))
local util = require("lib.util")

-- Which trackers run is config.lua, because each one costs frame time on the game thread (see the
-- comments there). A tracker that is off is still loaded, so its constants still read as themselves
-- (stalls.CLASS, thieves.CLASSES), but every function on it is replaced by a no-op: it costs nothing
-- per frame, measures nothing and logs nothing. config.PROFILE instead times each one into its own
-- bucket (lib/profile.lua).
local function noop() end
local function tracker(name)
    local module = require("trackers." .. name)
    if config.TRACKERS[name] then return profile.wrap(name, module) end
    local disabled = {}
    for key, value in pairs(module) do
        disabled[key] = type(value) == "function" and noop or value
    end
    return disabled
end

-- True if any of the named trackers is on; used to skip a NotifyOnNewObject nothing is listening for.
local function anyOn(...)
    for _, name in ipairs({ ... }) do
        if config.TRACKERS[name] then return true end
    end
    return false
end

local buzz = tracker("buzz")
local camera = tracker("camera")
local charge = tracker("charge")
local dragons = tracker("dragons")
local flames = tracker("flames")
local flight = tracker("flight")
local glide = tracker("glide")
local hits = tracker("hits")
local movement = tracker("movement")
local supercharge = tracker("supercharge")
local thieves = tracker("thieves")
local stalls = tracker("stalls")
local lizard = tracker("lizard")
local turtle = tracker("turtle")
local gemthief = tracker("gemthief")
local nanspeed = tracker("nanspeed")
local walkin = tracker("walkin")
local resume = require("lib.resume")
local gameswap = require("lib.gameswap")
local quicksave = require("tools.quicksave")
local glidetest = require("tools.glidetest")
local spawntest = require("tools.spawntest")
local slide = require("tools.slide")
local camrepro = require("tools.camrepro")
local worldtour = require("tools.worldtour.worldtour")
local minigame = require("tools.minigame")
local animtest = require("tools.animtest")
local routes = require("tools.routes")
local scan = require("tools.scan")
local scansweep = require("tools.scansweep")
local dumpstate = require("tools.dumpstate")

-- Sparx is topped up to full every couple of seconds while the probe runs, so a test is not cut short by a
-- death and a level reload. He still takes hits and knockback (lib/invuln.lua).
local KEEP_SPARX_FULL = true
local DEFAULT_SIM_STEP = 0.05 -- engine default MaxSimulationTimeStep; the game never changes it
local RECENT_FRAMES = 10
local setFpsCap -- defined with the key binds below; the world tour sets its caps with it
local requestRecord = false -- P: record this spot as a tour stop (tools/routes.lua)
local requestClose = false -- F3: press Continue on the text box that is up (lib/dialogue.lua)

local function sample()
    mouse.register()
    hits.register()
    flames.beforeSample()
    resume.update()     -- also runs with no pawn: it drives the title screen after a restart
    gameswap.update()   -- the same, for a tour swapping games through the title (lib/gameswap.lua)
    dumpstate.update()  -- the dumpstate.txt diagnostic, also with no pawn
    local pc = UEHelpers.GetPlayerController()
    if not pc:IsValid() then return end
    local pawn = pc.Pawn
    if not pawn:IsValid() then return end
    local cmc = pawn.CharacterMovement
    if not cmc:IsValid() then return end
    glide.register() -- after the pawn exists: its abilities are loaded by then

    local statics = UEHelpers.GetGameplayStatics()
    local time = statics:GetTimeSeconds(pawn)
    if state.lastTime == time then
        -- Paused. A save fairy's or Moneybags' prompt pauses the world, and returning here is
        -- what used to leave the scripted tour sitting in one: nothing ran to answer it. The
        -- tour answers it the way a player does, with Continue (lib/dialogue.lua). An unattended
        -- run of any kind has to get out of one: a paused world never reaches its own stop file.
        if worldtour.running() or scansweep.running() then dialogue.advance() end
        return
    end
    state.lastTime = time
    profile.beginFrame(pc, statics)

    local prev = state.prevRow
    local r = row.build(pc, pawn, cmc, statics, time, prev)
    r.superStage, r.superDetectedBy = supercharge.stage(pawn, r)

    -- Older probe builds could shrink the substep for experiments; substeps smaller than a frame
    -- reproduce the high-FPS quantization bugs at any framerate, so always restore the default.
    if not state.simStepChecked then
        state.simStepChecked = true
        if math.abs(r.simStep - DEFAULT_SIM_STEP) > 1e-6 then
            cmc.MaxSimulationTimeStep = DEFAULT_SIM_STEP
            log("MaxSimulationTimeStep was %.4f; restored engine default %.2f", r.simStep, DEFAULT_SIM_STEP)
        end
    end

    local frameTime = prev and r.time - prev.time or 0
    movement.update(r, util.isGrounded(r.mode))
    -- The scripted tour teleports Spyro onto a thousand stops and walks him at a character. His jump
    -- height, glide, charge and camera belong to the level, not the character, so they run on the first few
    -- stops of each level at each framerate instead of at every character for the hours a tour takes.
    local touring = worldtour.running()
    local measureLevel = (not touring) or worldtour.measuring()
    if measureLevel then
        glide.update(r, prev, util.isGrounded(r.mode))
        supercharge.update(r, prev)
        charge.update(r, prev)
        camera.updateTransition(r, prev)
        camera.updateDump(pawn, r)
    end
    dragons.update(r.time, frameTime)
    -- A new pawn (level load, respawn) may come with new thieves, dragons or flame components.
    local pawnAddress = pawn:GetAddress()
    if pawnAddress ~= state.pawnAddress then
        state.pawnAddress = pawnAddress
        dragons.pawnChanged()
        thieves.pawnChanged()
        buzz.pawnChanged()
        stalls.pawnChanged()
        lizard.pawnChanged()
        turtle.pawnChanged()
        gemthief.pawnChanged()
        nanspeed.pawnChanged()
        flames.rescan()
    end
    if measureLevel then
        thieves.update(r, prev)
        buzz.update(r, prev)
    end
    stalls.update(r, prev, pawn)
    lizard.update(r, prev)
    turtle.update(r, prev)
    gemthief.update(r)
    nanspeed.update(r)
    flames.update(r, frameTime)
    if KEEP_SPARX_FULL then invuln.update(pawn) end
    quicksave.update(pawn, pc, cmc, r)
    glidetest.update(pawn, pc, cmc, r)
    spawntest.update(pawn, pc, setFpsCap, frameTime)
    slide.update(pawn, r)
    camrepro.update(pawn, r)
    worldtour.update(pawn, pc, cmc, r, setFpsCap)
    minigame.update(pawn, pc, cmc, r, state.fpsCap or 0)
    animtest.update(pawn, pc, r, setFpsCap)
    scan.update(pawn, pc)
    scansweep.update(pawn, pc, r, touring)
    if requestClose then
        requestClose = false
        igc.forget() -- asked for by hand, so never trust a list from an earlier level
        igc.close(pc, pawn, levels.current(pawn)) -- presses Continue on a text box, if one is up
    end
    if requestRecord then
        requestRecord = false
        -- M means two things, and which one is never ambiguous: once tools/minigame.lua has dropped you
        -- into a minigame it starts and stops a take, and otherwise it records a tour stop as it always
        -- did.
        if minigame.running() then
            minigame.toggleRecord()
        else
            local okRecord, recordErr = pcall(routes.record, pawn, pc, r)
            if not okRecord then log("routes error: %s", tostring(recordErr)) end
        end
    end
    if measureLevel then
        walkin.update(pc, cmc, r, prev)
        flight.update(pawn, cmc, r, prev)
        hits.update(r, prev)
    end

    trace.writeRow(r)
    state.prevRow = r
    table.insert(state.recent, r)
    if #state.recent > RECENT_FRAMES then table.remove(state.recent, 1) end
    profile.endFrame(r.dt)
end

setFpsCap = function(cap)
    ExecuteInGameThread(function()
        local pc = UEHelpers.GetPlayerController()
        if not pc:IsValid() then return end
        UEHelpers.GetKismetSystemLibrary():ExecuteConsoleCommand(pc, "t.MaxFPS " .. cap, pc)
        state.fpsCap = cap
        log("t.MaxFPS %d", cap)
    end)
end

-- F3 and F4 are the review verdicts while a review tour runs (tools/worldtour/review.lua: F3 fine or
-- carry on, F4 wrong and hold); otherwise F3 presses Continue and F4 sets 320 FPS.
RegisterKeyBind(Key.F4, function()
    if worldtour.reviewing() then worldtour.rate("wrong") else setFpsCap(320) end
end)
RegisterKeyBind(Key.F5, function() setFpsCap(30) end)
RegisterKeyBind(Key.F6, function() setFpsCap(60) end)
RegisterKeyBind(Key.F7, function() setFpsCap(120) end)
RegisterKeyBind(Key.F8, function() setFpsCap(0) end)
RegisterKeyBind(Key.F9, camera.requestDump)
RegisterKeyBind(Key.F10, flames.rescan)
RegisterKeyBind(Key.V, function() quicksave.request("save") end)
RegisterKeyBind(Key.B, function() quicksave.request("load") end)
RegisterKeyBind(Key.L, function() quicksave.request("reload") end)
RegisterKeyBind(Key.N, function() quicksave.request("transporter") end)
RegisterKeyBind(Key.K, flames.cycleExperiment)
RegisterKeyBind(Key.G, glidetest.request)
RegisterKeyBind(Key.U, spawntest.toggle)
RegisterKeyBind(Key.J, slide.request)
RegisterKeyBind(Key.R, camrepro.arm)
RegisterKeyBind(Key.O, worldtour.toggle)
RegisterKeyBind(Key.M, function() requestRecord = true end)
RegisterKeyBind(Key.F3, function()
    if worldtour.reviewing() then worldtour.rate("fine") else requestClose = true end
end)
RegisterKeyBind(Key.F1, minigame.mark)
RegisterKeyBind(Key.F2, minigame.retry)
RegisterKeyBind(Key.C, function() minigame.request("next") end)
RegisterKeyBind(Key.H, scan.request)
RegisterKeyBind(Key.I, animtest.toggle)
RegisterKeyBind(Key.T, gemthief.poison)
RegisterKeyBind(Key.Y, function()
    gemthief.toggle()
    nanspeed.toggle()
end)

-- Particle and audio components are watched by two things at once: the flame tracker wants the flame
-- ones, and the montage sweep counts everything an animation notify spawns while it plays.
NotifyOnNewObject("/Script/Engine.ParticleSystemComponent", function(object)
    animtest.onNewFx(object)
    flames.onNewComponent(object)
end)
NotifyOnNewObject("/Script/Engine.AudioComponent", animtest.onNewAudio)
-- One notification per class, fanned out: the trackers that want every character share a callback.
-- It fires on every character the game constructs, so it is only registered when one of them is on.
-- (The startup crashes while this was being written were two unrelated pak mods, not a second
-- registration here and not the FindAllOf polling it replaced — docs/probe.md.)
if anyOn("stalls", "nanspeed", "gemthief", "lizard", "turtle") then
    NotifyOnNewObject(stalls.CLASS, function(object)
        stalls.onNewObject(object)
        nanspeed.onNewObject(object)
        gemthief.onNewObject(object)
        lizard.onNewObject(object)
        turtle.onNewObject(object)
    end)
end

-- Level Blueprint classes load with their level; look for their instances for a while afterwards.
if anyOn("dragons", "thieves", "buzz") then
    local levelClasses = { [dragons.CLASS] = dragons }
    for className in pairs(thieves.CLASSES) do levelClasses[className] = thieves end
    for className in pairs(buzz.CLASSES) do levelClasses[className] = buzz end
    NotifyOnNewObject("/Script/Engine.BlueprintGeneratedClass", function(object)
        local ok, name = pcall(function() return object:GetFName():ToString() end)
        local watcher = ok and levelClasses[name]
        if watcher then watcher.classLoaded() end
    end)
end

if not EngineTickAvailable then
    log("EngineTick hook unavailable; per-frame sampling disabled")
    return
end

quicksave.load()

LoopInGameThreadAfterFrames(1, function()
    local ok, err = pcall(sample)
    if not ok and not state.errorLogged then
        state.errorLogged = true
        log("sample error: %s", tostring(err))
    end
end)

-- What this run measures goes in the log, so a CSV with a column missing can be traced back to the
-- switches it was recorded with (config.lua).
local on = {}
for name, enabled in pairs(config.TRACKERS) do
    if enabled then on[#on + 1] = name end
end
table.sort(on)
log("loaded; trackers on: %s", #on > 0 and table.concat(on, " ") or "none")
if config.TRACE then
    log("writing %s", paths.trace)
else
    log("trace CSV off (config.TRACE)")
end
