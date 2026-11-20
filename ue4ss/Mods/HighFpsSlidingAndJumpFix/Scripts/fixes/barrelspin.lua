-- Bamboo Terrace rolling boulders and barrels (Spyro 3, LS314: Bentley's section)
--
-- BP_LS314_DestructibleBarrel_C's ReceiveTick spins a rolling barrel by adding its RotationAxis (10 deg
-- of yaw by default) to the capsule's local rotation once per tick:
--   ExecuteUbergraph_BP_LS314_DestructibleBarrel(629): if Rolling then
--       Capsule.K2_AddLocalRotation(RotationAxis)
-- a fixed step per frame with no DeltaSeconds in it. BP_LS314_PandaRock_C (the panda boulders) is a
-- subclass and does not override ReceiveTick, so it spins the same way. Its own parent, the Spyro 1
-- Dockworkers' BP_Barrel_Base, scales its spin by DeltaSeconds; only this level's subclass replaced
-- that with the per-tick step.
--
-- Measured 2026-11-19 on PandaRock1 with Spyro beside it (a far actor ticks every 0.1 s instead, which
-- hides it): 30 FPS 300 deg/s (10.0 deg a frame), ~318 FPS 3184 deg/s (10.0 deg a frame).
--
-- The hook runs after the body (a Blueprint hook in this UE4SS build runs only as pre, after the body),
-- so it adds RotationAxis * (dt * 30 - 1) more: the tick's total becomes RotationAxis * dt * 30, the 30
-- FPS rate. RotationAxis is a single-axis rotator on every instance, so scaling it is exact. Ticks of
-- 1/30 s or longer, which includes the 0.1 s ticks of far actors, are left alone.
--
-- Not changed: the facing turn toward the next path point (Rotate: RLerp 0.5 per tick) is also per
-- frame, but the path itself is walked with DeltaSeconds * 300, so only the barrel's visual heading
-- settles faster.

local config = require("config")
local engine = require("lib.engine")
local log = require("lib.log")
local lookup = require("lib.lookup")
local profiler = require("profiler")
local util = require("lib.util")

local fix = { name = "Bamboo Terrace barrel spin fix", enabled = config.FIX_BARREL_SPIN, failed = false }

local hook = {
    class = "BP_LS314_DestructibleBarrel_C",
    path = "/LS314_BambooTerrace/Blueprints/BP_LS314_DestructibleBarrel.BP_LS314_DestructibleBarrel_C:ReceiveTick",
    hooked = nil, failures = 0, retryIn = 0, lookups = 1,
}

local handled = {} -- barrel address -> engine.frame of the last correction (pre and post both call)
local EXTRA = { Pitch = 0, Yaw = 0, Roll = 0 }
local HIT = {}

local function correct(barrel, dt)
    if not barrel.Rolling or not util.aboveReferenceFps(dt) then return end
    local address = barrel:GetAddress()
    if handled[address] == engine.frame then return end
    handled[address] = engine.frame
    local axis = barrel.RotationAxis
    local scale = dt / util.REFERENCE_DT - 1
    EXTRA.Pitch, EXTRA.Yaw, EXTRA.Roll = axis.Pitch * scale, axis.Yaw * scale, axis.Roll * scale
    barrel.Capsule:K2_AddLocalRotation(EXTRA, false, util.clearHit(HIT), false)
end

local onTick = profiler.wrapHook("barrelspin", function(context, deltaSeconds)
    if fix.failed then return end
    local ok, err = pcall(function() correct(context:get(), deltaSeconds:get()) end)
    if not ok then
        fix.failed = true
        log("%s disabled after hook error: %s", fix.name, tostring(err))
    end
end)

function fix.update()
    local result = lookup.hookLevelFunction(hook, onTick, fix.name)
    if result == "hooked" then handled = {} end
    if result == "failed" then fix.failed = true end
end

if fix.enabled then
    lookup.watch("/Script/Engine.BlueprintGeneratedClass", hook.class, hook)
end

return fix
