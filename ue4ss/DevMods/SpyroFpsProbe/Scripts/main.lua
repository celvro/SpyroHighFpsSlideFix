-- SpyroFpsProbe: records Spyro's movement every frame so jump, glide, sliding and charge behaviour can
-- be compared across framerates. A development mod: deploy it with tools/Install-UE4SS.ps1 -Probe, and
-- leave it off when profiling the fix mod (its per-frame garbage lands in the fixes' timed region).
--
-- Keys (game window focused; not F11, which toggles fullscreen, nor anything DefaultInput.ini binds):
--   F5 / F6 / F7 / F8  set t.MaxFPS to 30 / 60 / 120 / 0 (uncapped)
--   F9                 dump Spyro's FollowCameraComponent properties to camdump_*_manual.txt
--   F10                rescan for flame particle components (if a flame isn't picked up automatically)
--   K                  cycle the flame muzzle experiment: normal / noHardMuzzle / velocity30
--   V / B / L / N      quicksave: save this spot / go back to it / reload the level / dump the transporter
--
-- Output, in this mod folder and the UE4SS console and log:
--   trace_<stamp>.csv    one row per frame (columns in lib/trace.lua)
--   thieves_<stamp>.csv  one row per frame per active thief (trackers/thieves.lua)
--   flames_<stamp>.csv   one row per frame per active flame (trackers/flames.lua)
--   hits_<stamp>.csv     one row per blocking hit during a ground charge (trackers/hits.lua)
--   camdump_*.txt        every reflected FollowCameraComponent property (trackers/camera.lua)
--   log lines            "seg", "drift", "rise" (trackers/movement.lua); "charge", "turn" (trackers/charge.lua);
--                        "camlock", "camstuck", "camtransition", "camdump diff" (trackers/camera.lua);
--                        "supercharge" (trackers/supercharge.lua); "dragon" (trackers/dragons.lua);
--                        "thief" (trackers/thieves.lua); "flame" (trackers/flames.lua); "walkin"
--                        (trackers/walkin.lua); "flight", "flightramp", "flightrun" (trackers/flight.lua);
--                        "chargestall" (trackers/hits.lua);
--                        quicksave, reload and travel lines (tools/quicksave.lua)
--
-- Scripts/
--   lib/       shared helpers: logging, the row sampled each frame, the trace CSV, object dumps, level queries
--   trackers/  one module per measurement, each documenting its own log lines
--   tools/     the quicksave / reload / travel testing aid

local UEHelpers = require("UEHelpers")
local log = require("lib.log")
local mouse = require("lib.mouse")
local paths = require("lib.paths")
local row = require("lib.row")
local state = require("lib.state")
local trace = require("lib.trace")
local util = require("lib.util")
local camera = require("trackers.camera")
local charge = require("trackers.charge")
local dragons = require("trackers.dragons")
local flames = require("trackers.flames")
local flight = require("trackers.flight")
local hits = require("trackers.hits")
local movement = require("trackers.movement")
local supercharge = require("trackers.supercharge")
local thieves = require("trackers.thieves")
local walkin = require("trackers.walkin")
local quicksave = require("tools.quicksave")

local DEFAULT_SIM_STEP = 0.05 -- engine default MaxSimulationTimeStep; the game never changes it
local RECENT_FRAMES = 10

local function sample()
    mouse.register()
    hits.register()
    flames.beforeSample()
    local pc = UEHelpers.GetPlayerController()
    if not pc:IsValid() then return end
    local pawn = pc.Pawn
    if not pawn:IsValid() then return end
    local cmc = pawn.CharacterMovement
    if not cmc:IsValid() then return end

    local statics = UEHelpers.GetGameplayStatics()
    local time = statics:GetTimeSeconds(pawn)
    if state.lastTime == time then return end -- paused or same frame
    state.lastTime = time

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
    supercharge.update(r, prev)
    charge.update(r, prev)
    camera.updateTransition(r, prev)
    camera.updateDump(pawn, r)
    dragons.update(r.time, frameTime)
    -- A new pawn (level load, respawn) may come with new thieves, dragons or flame components.
    local pawnAddress = pawn:GetAddress()
    if pawnAddress ~= state.pawnAddress then
        state.pawnAddress = pawnAddress
        dragons.pawnChanged()
        thieves.pawnChanged()
        flames.rescan()
    end
    thieves.update(r, prev)
    flames.update(r, frameTime)
    quicksave.update(pawn, pc, cmc, r)
    walkin.update(pc, cmc, r, prev)
    flight.update(pawn, cmc, r, prev)
    hits.update(r, prev)

    trace.writeRow(r)
    state.prevRow = r
    table.insert(state.recent, r)
    if #state.recent > RECENT_FRAMES then table.remove(state.recent, 1) end
end

local function setFpsCap(cap)
    ExecuteInGameThread(function()
        local pc = UEHelpers.GetPlayerController()
        if not pc:IsValid() then return end
        UEHelpers.GetKismetSystemLibrary():ExecuteConsoleCommand(pc, "t.MaxFPS " .. cap, pc)
        state.fpsCap = cap
        log("t.MaxFPS %d", cap)
    end)
end

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

NotifyOnNewObject("/Script/Engine.ParticleSystemComponent", flames.onNewComponent)

-- Level Blueprint classes load with their level; look for their instances for a while afterwards.
local levelClasses = { [dragons.CLASS] = dragons }
for className in pairs(thieves.CLASSES) do levelClasses[className] = thieves end
NotifyOnNewObject("/Script/Engine.BlueprintGeneratedClass", function(object)
    local ok, name = pcall(function() return object:GetFName():ToString() end)
    local tracker = ok and levelClasses[name]
    if tracker then tracker.classLoaded() end
end)

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

log("loaded; writing %s", paths.trace)
