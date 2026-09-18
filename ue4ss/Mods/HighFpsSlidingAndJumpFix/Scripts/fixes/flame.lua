-- Flame breath stray lines fix
--
-- Spyro's flame breath (PS_VFX_Flame_Breath, and _Rage) has a muzzle emitter,
-- hard_flames_velocity_muzzle, of thin sprites up to ~240 units long that are aligned to their
-- movement (PSA_Velocity) but only move ~9 units/s. The renderer takes that direction from each
-- frame's change in position: ~0.3 units at 30 FPS, but only ~0.02 at 320 FPS, too small for a
-- stable direction, so a few of the sprites flip to point straight up or sideways and show as long
-- lines sticking out of the flame. Particle captures showed the emitter simulating identically at
-- both framerates. Above 30 FPS this scales the emitter's start velocity in both flame templates
-- by (1/30)/dt, so each frame moves its particles as far as at 30 FPS and the sprites keep their
-- direction. The particles drift a little farther from the mouth over their 0.2-0.3 s life (~2
-- units at 30 FPS, ~10 at 144, ~21 at 320). At 30 FPS or lower the asset's own values are kept.
--
-- Caveat: the originals are read from the live template, so a hot reload while the velocity is
-- scaled would take the scaled values as the originals and compound them. Restart the game instead.

local config = require("config")
local log = require("lib.log")
local lookup = require("lib.lookup")
local util = require("lib.util")

local FLAME_TEMPLATE_PATHS = {
    "/VFX_Spryo/Shared/Particles/Characters/Spyro/FlameThrower/PS_VFX_Flame_Breath.PS_VFX_Flame_Breath",
    "/VFX_Spryo/Shared/Particles/Characters/Spyro/FlameThrower/PS_VFX_Flame_Breath_Rage.PS_VFX_Flame_Breath_Rage",
}
local FLAME_MUZZLE_EMITTER = "hard_flames_velocity_muzzle"
local FLAME_VELOCITY_RESCALE = 0.1 -- rewrite the muzzle velocity when the wanted scale differs from the written one by this fraction

local fix = { name = "flame muzzle lines fix", enabled = config.FIX_FLAME_MUZZLE_LINES }

local avgDt = nil
-- Per template: the object, the StartVelocity lookup tables of its muzzle emitter
-- ({ values, original }) and the velocity scale written to them. Keyed by the template's object
-- name, which is what lookup.watch matches on.
local templates = {}
for _, templatePath in ipairs(FLAME_TEMPLATE_PATHS) do
    templates[templatePath:match("%.([^.]+)$")] = { path = templatePath, lookups = 1, retryIn = 0 }
end

-- Writes a velocity scale into a template's muzzle StartVelocity tables (1 restores the asset's values).
local function scaleFlameMuzzle(t, scale)
    for _, entry in ipairs(t.tables) do
        for n, original in ipairs(entry.original) do entry.values[n] = original * scale end
    end
    t.scale = scale
end

-- Reads the muzzle emitter's StartVelocity lookup tables (and their asset values) out of a template.
local function readMuzzleTables(template)
    local tables = {}
    local emitters = template.Emitters
    for i = 1, emitters:GetArrayNum() do
        local emitter = emitters[i]
        if emitter:IsValid() and emitter.EmitterName:ToString() == FLAME_MUZZLE_EMITTER then
            local lods = emitter.LODLevels
            for j = 1, lods:GetArrayNum() do
                local modules = lods[j].Modules
                for k = 1, modules:GetArrayNum() do
                    local module = modules[k]
                    if module:IsValid() and module:GetClass():GetFName():ToString() == "ParticleModuleVelocity" then
                        -- Cooked distributions are read from the lookup table (Distribution is null).
                        local values = module.StartVelocity.Table.Values
                        local entry = { values = values, original = {} }
                        for n = 1, values:GetArrayNum() do entry.original[n] = values[n] end
                        table.insert(tables, entry)
                    end
                end
            end
        end
    end
    return tables
end

-- Scales the flame breath's hard muzzle emitter velocity above 30 FPS (see the header). The velocity
-- module reads the template's table when a particle spawns, so the change applies to new particles.
function fix.update(ctx)
    local dt = ctx.dt
    if dt >= util.MIN_TICK_TIME then avgDt = avgDt and (avgDt * 0.9 + dt * 0.1) or dt end
    if not avgDt then return end
    local want = math.max(1, util.REFERENCE_DT / avgDt)
    for name, t in pairs(templates) do
        if t.object and not t.object:IsValid() then t.object, t.tables, t.scale = nil, nil, nil end
        if not t.object then
            local template = lookup.find(t, t.path)
            if template then
                -- Created but not loaded yet: try again later (found lookups don't hitch).
                if template.Emitters:GetArrayNum() == 0 then
                    t.lookups = math.max(t.lookups, 1)
                else
                    t.lookups = 0
                    t.object, t.tables, t.scale = template, readMuzzleTables(template), 1
                    if #t.tables == 0 then log("flame muzzle lines fix: %s has no %s velocity", name, FLAME_MUZZLE_EMITTER) end
                end
            end
        end
        if t.object and #t.tables > 0 then
            local rescale = math.abs(want - t.scale) > FLAME_VELOCITY_RESCALE * want or (want == 1 and t.scale ~= 1)
            if rescale then
                if (want == 1) ~= (t.scale == 1) then
                    log("flame muzzle lines fix: %s velocity %s in %s", FLAME_MUZZLE_EMITTER,
                        want == 1 and "restored" or string.format("scaled x%.1f", want), name)
                end
                scaleFlameMuzzle(t, want)
            end
        end
    end
end

-- Puts every found flame template's muzzle velocity back (after an error).
function fix.disable()
    for _, t in pairs(templates) do
        if t.object and t.tables then pcall(scaleFlameMuzzle, t, 1) end
    end
end

if fix.enabled then
    for name, t in pairs(templates) do
        lookup.watch("/Script/Engine.ParticleSystem", name, t)
    end
end

return fix
