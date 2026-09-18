-- Balloon camera spin fix
--
-- The balloonist transporters (BalloonTransporter for Spyro 1, S3BalloonTransporter for Spyro 3)
-- play Timeline_0 (45 s) once the balloon has risen, and its update adds a fixed 0.5 deg to the
-- camera spring arm's yaw every tick: 15 deg/s at 30 FPS, 160 deg/s at 320. It runs behind the
-- loading screen, and when the load completes the Blueprint hides the loading screen, fades in
-- for 1 s and only then stops the timeline and snaps the arm to yaw 180, so at high FPS the camera
-- visibly whirls around the balloon during that fade. After each update this takes the 0.5 back
-- and adds 0.5 * dt * 30 instead, so the arm turns at 15 deg/s. At 30 FPS or lower it changes
-- nothing.

local config = require("config")
local engine = require("lib.engine")
local log = require("lib.log")
local lookup = require("lib.lookup")
local util = require("lib.util")

local SPIN_PER_UPDATE = 0.5 -- deg the Timeline_0 update adds to SpringArm's yaw

-- Reused so the hook doesn't allocate every frame (the sweep result is an unread out-param).
local ROTATION = { Pitch = 0, Yaw = 0, Roll = 0 }
local SWEEP_HIT = {}

local fix = {
    name = "balloon camera spin fix",
    enabled = config.FIX_BALLOON_CAMERA_SPIN,
    failed = false,
}

-- One hook per transporter Blueprint, each with its own lookup bookkeeping (see lib/lookup.lua).
local targets = {
    {
        class = "BalloonTransporter_C",
        path = "/GameplayCommon/LevelMechanics/LevelStreaming/Actors/BalloonTransporter.BalloonTransporter_C:Timeline_0__UpdateFunc",
    },
    {
        class = "S3BalloonTransporter_C",
        path = "/GameplayCommon/LevelMechanics/LevelStreaming/Actors/S3BalloonTransporter.S3BalloonTransporter_C:Timeline_0__UpdateFunc",
    },
}
for _, target in ipairs(targets) do
    target.hooked, target.failures, target.retryIn, target.lookups = nil, 0, 0, 1
end

local lastFrame, lastActor = -1, nil -- the timeline updates once per tick: correct each call once

-- Runs after the update's body with this UE4SS build (see CLAUDE.md), so the 0.5 is already added.
local function onSpinUpdate(context)
    local transporter = context:get()
    local address = transporter:GetAddress()
    if lastFrame == engine.frame and lastActor == address then return end
    lastFrame, lastActor = engine.frame, address
    local dt = engine.worldDeltaSeconds(transporter) * transporter.CustomTimeDilation
    if not util.aboveReferenceFps(dt) then return end
    local arm = transporter.SpringArm
    local rotation = arm.RelativeRotation
    ROTATION.Pitch, ROTATION.Roll = rotation.Pitch, rotation.Roll
    ROTATION.Yaw = rotation.Yaw - SPIN_PER_UPDATE + SPIN_PER_UPDATE * dt * util.REFERENCE_FPS
    arm:K2_SetRelativeRotation(ROTATION, false, SWEEP_HIT, false)
end

local function onSpinUpdateGuarded(context)
    if fix.failed then return end
    local ok, err = pcall(onSpinUpdate, context)
    if not ok then
        fix.failed = true
        log("balloon camera spin fix disabled after hook error: %s", tostring(err))
    end
end

-- The transporters load with the home worlds, and their function objects are replaced when the
-- level loads again, so each time a class is created (see lookup.watch) it is looked up and hooked
-- again. RegisterHook can fail while the level is still loading, so failures are retried too.
local function hookTarget(target)
    local fn = lookup.find(target, target.path)
    if not fn then return end
    local address = fn:GetAddress()
    if address == target.hooked then target.lookups = 0 return end
    target.lookups = math.max(target.lookups, 1)
    local ok, err = pcall(RegisterHook, target.path, onSpinUpdateGuarded)
    if ok then
        target.hooked = address
        target.lookups = 0
        target.failures = 0
        log("balloon camera spin hook registered (%s)", target.class)
    else
        target.failures = target.failures + 1
        if target.failures >= lookup.MAX_FAILURES then
            fix.failed = true
            log("balloon camera spin fix disabled: RegisterHook failed: %s", tostring(err))
        end
    end
end

function fix.update()
    if fix.failed then return end
    for _, target in ipairs(targets) do hookTarget(target) end
end

if fix.enabled then
    for _, target in ipairs(targets) do
        lookup.watch("/Script/Engine.BlueprintGeneratedClass", target.class, target)
    end
end

return fix
