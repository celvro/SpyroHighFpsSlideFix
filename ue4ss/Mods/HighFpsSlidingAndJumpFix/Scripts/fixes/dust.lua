-- Charge dust fix
--
-- Every frame of a ground charge, Spyro's Blueprint (Charge_UpdateGroundEffects) deactivates the
-- dust trail effect and spawns a new one, so each effect only emits during its first tick. Its
-- emitters spawn 60 particles per second, and one 30 FPS tick adds up to one particle per side,
-- but one 60+ FPS tick adds up to less than one, so no dust appears at all. Once every 1/30 s
-- this stretches a new effect's only tick to 1/30 s (CustomTimeDilation), so it emits exactly
-- what a 30 FPS frame's effect does, and slows the effects spawned in between to almost a
-- standstill so they emit nothing. The next frame gives them normal time back for their
-- remaining particles. The shallow water splash takes the same path. At 30 FPS or lower it
-- changes nothing.

local config = require("config")
local engine = require("lib.engine")
local log = require("lib.log")
local lookup = require("lib.lookup")
local util = require("lib.util")

local CHARGE_DUST_FUNCTION = "/CPS1999_Spyro/Blueprints/BP_CPS1999_Playable.BP_CPS1999_Playable_C:Charge_UpdateGroundEffects"
local DUST_SILENT_DILATION = 1e-3 -- time scale for dust effects spawned between 30 FPS frames (0 could divide by zero)

-- The lookup and hook bookkeeping lives on the fix itself: a RegisterHook that gives up (failed)
-- disables the fix, which is also what the guarded callbacks below check.
local fix = {
    name = "charge dust fix",
    enabled = config.FIX_CHARGE_DUST,
    registered = false, failed = false, retryIn = 0, lookups = 1,
}

-- Spyro's Blueprint replaces Charge_GroundEffects in Charge_UpdateGroundEffects. With this UE4SS
-- build only the "pre" callback of a Blueprint function hook runs, and it runs after the body, so
-- one callback is registered as both: it only acts on an effect address it hasn't seen.
local dust = {
    pawn = nil,          -- address of the player's pawn this frame (other actors' calls are ignored)
    frame = -1,          -- engine.frame of the last callback
    frameStart = nil,    -- effect address when this frame started, before the Blueprint could replace it
    handled = nil,       -- address of the newest effect already given a time scale
    dilated = {},        -- effects with a changed CustomTimeDilation, reset on the next frame
    sinceDue = 0,        -- seconds since the last effect that emits, so they stay 1/30 s apart
    lastSpawnFrame = -1, -- engine.frame when a new effect was last seen (a gap means a new charge)
}

-- Gives the dust effects we stretched or slowed normal time back. Runs on the next frame, after
-- their one tick before the Blueprint deactivates them, so their particles then age normally.
local function resetDustDilations()
    for i = #dust.dilated, 1, -1 do
        local effect = dust.dilated[i]
        dust.dilated[i] = nil
        if effect:IsValid() then effect.CustomTimeDilation = 1 end
    end
end

-- Both hook callbacks (pre and post) run this.
local function onDustHook(context)
    local pawn = context:get()
    if not dust.pawn or pawn:GetAddress() ~= dust.pawn then return end
    if dust.frame ~= engine.frame then
        dust.frame = engine.frame
        resetDustDilations()
    end
    local current = pawn.Charge_GroundEffects
    if not current:IsValid() then return end
    local address = current:GetAddress()
    -- Only an effect spawned this frame can still be changed before its first tick.
    if address == dust.frameStart or address == dust.handled then return end
    dust.handled = address

    local period = util.REFERENCE_DT
    local continuing = dust.lastSpawnFrame == engine.frame - 1
    dust.lastSpawnFrame = engine.frame
    local dt = engine.worldDeltaSeconds(pawn)
    if not util.aboveReferenceFps(dt) then return end
    -- A new charge emits right away; after that, one effect every 1/30 s.
    dust.sinceDue = continuing and dust.sinceDue + dt or period
    if dust.sinceDue >= period - 1e-4 then
        dust.sinceDue = math.max(dust.sinceDue - period, 0)
        -- Its only tick then covers one 30 FPS frame, so every emitter spawns what it does at 30 FPS.
        current.CustomTimeDilation = period / dt
    else
        current.CustomTimeDilation = DUST_SILENT_DILATION
    end
    dust.dilated[#dust.dilated + 1] = current
end

-- A hook error would repeat every frame, so the first one turns the fix off.
local function onDustHookGuarded(context)
    if fix.failed then return end
    local ok, err = pcall(onDustHook, context)
    if not ok then
        fix.failed = true
        pcall(resetDustDilations)
        log("charge dust fix disabled after hook error: %s", tostring(err))
    end
end

local function readDustEffectAddress(pawn)
    local effect = pawn.Charge_GroundEffects
    return effect and effect:IsValid() and effect:GetAddress() or nil
end

-- Runs before each world tick: remembers the pawn and its current effect for the hook callbacks.
function fix.update(ctx)
    local pawn = ctx.pawn
    dust.pawn = pawn:GetAddress()
    local ok, address = pcall(readDustEffectAddress, pawn)
    dust.frameStart = ok and address or nil
    -- Callbacks stopped (pause, level change): don't leave effects slowed down.
    if dust.frame < engine.frame - 1 and #dust.dilated > 0 then resetDustDilations() end
    -- Registered as both the pre and the post callback (see the dust state above).
    lookup.registerBlueprintHook(fix, CHARGE_DUST_FUNCTION, onDustHookGuarded, onDustHookGuarded, "charge dust")
end

function fix.disable()
    pcall(resetDustDilations)
end

if fix.enabled then
    lookup.watch("/Script/Engine.BlueprintGeneratedClass", "BP_CPS1999_Playable_C", fix)
end

return fix
