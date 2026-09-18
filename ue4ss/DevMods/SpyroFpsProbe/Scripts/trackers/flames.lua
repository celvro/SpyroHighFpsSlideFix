-- Spyro's flame breath, and the K experiment on its muzzle emitter.
--
--   "flame" lines          each flame breath (PS_VFX_Flame_Breath or _Rage component active): the particle
--                          system's world bounds measured along Spyro's facing: reach (farthest forward from
--                          the component), halfWidth (half the extent across, and its sideways centre),
--                          halfHeight, and the SP_Flames_* trace parameters the native flame actor sets.
--                          Bounds are a world axis-aligned box, so the across extent also picks up some of
--                          the flame's length unless Spyro faces along a world axis; "aligned" repeats the
--                          numbers for frames within FLAME_ALIGNED_DEG of one. Compare breaths with the same
--                          heading. "tail" is the widest the lingering particles got in FLAME_TAIL after
--                          deactivation. The world bounds turned out unusable (empty emitters stretch them to
--                          the world origin, and otherwise particle size padding dominates), so judge the
--                          K experiment by eye.
--   flames_<stamp>.csv     one row per frame per active (or lingering) flame.
--   "flame component found ... at 0x..."  lets tools/Capture-FlameParticles.ps1 read the particles.
local UEHelpers = require("UEHelpers")
local log = require("lib.log")
local paths = require("lib.paths")
local state = require("lib.state")
local util = require("lib.util")

local num, tryCall, outVector, describeOut = util.num, util.tryCall, util.outVector, util.describeOut

-- Flame breath effects SpyroFlameBreathActor (FireAttackActorTrace_C) spawns.
local FLAME_TEMPLATES = { PS_VFX_Flame_Breath = "flame", PS_VFX_Flame_Breath_Rage = "rage" }
local FLAME_PARAMETERS = { "SP_Flames_C", "SP_Flames_L1", "SP_Flames_R1", "SP_Flames_L2", "SP_Flames_R2" }
local FLAME_PENDING_FRAMES = 30 -- frames a new ParticleSystemComponent may take to get its template
local FLAME_TAIL = 1.0          -- seconds a deactivated flame's lingering particles stay in the CSV and the tail max
local FLAME_ALIGNED_DEG = 5     -- headings within this of a world axis count as "aligned" (world AABB ~ flame box)
local FLAME_TEMPLATE_PATHS = {
    "/VFX_Spryo/Shared/Particles/Characters/Spyro/FlameThrower/PS_VFX_Flame_Breath.PS_VFX_Flame_Breath",
    "/VFX_Spryo/Shared/Particles/Characters/Spyro/FlameThrower/PS_VFX_Flame_Breath_Rage.PS_VFX_Flame_Breath_Rage",
}
-- K experiment modes. Cause (particle capture and experiments 2026-09-16): hard_flames_velocity_muzzle is a
-- local-space, velocity-aligned (PSA_Velocity) sprite emitter moving only ~9 units/s, so at high FPS a frame
-- moves its particles ~0.02 units. The sprite direction comes from that per-frame move, which becomes
-- unstable, and the long thin sprites point straight up or sideways. Switching the emitter off removes them.
--   noHardMuzzle: the emitter's LOD bEnabled off
--   velocity30:   its StartVelocity scaled by (1/30)/dt so a frame moves it as far as at 30 FPS (candidate fix;
--                 the particles drift ~k times farther forward than the ~2 units they drift at 30 FPS)
-- Don't use it with the fix mod's flame fix on: both rewrite the same StartVelocity table.
local FLAME_EXPERIMENTS = { "normal", "noHardMuzzle", "velocity30" }
local FLAME_HARD_MUZZLE_EMITTER = "hard_flames_velocity_muzzle"
local FLAME_VELOCITY_RESCALE = 0.05 -- velocity30 re-applies when the scale for the current FPS differs this much
-- Particle module classes whose default object address (and so vtable) is logged at startup, for disassembly.
local PARTICLE_MODULE_CDOS = { "ParticleModule", "ParticleModuleAttractorPoint", "ParticleModuleAccelerationDrag",
                               "ParticleModuleAccelerationConstant", "ParticleModuleVelocityInheritParent",
                               "ParticleModuleVelocity", "ParticleModuleSize", "ParticleModuleLifetime" }

local flames = {}

-- pending: new ParticleSystemComponents whose template isn't known yet ({ component, frames });
-- tracked: component address -> { component, kind, breath }; scan: FindAllOf rescan requested (startup, F10)
local f = { pending = {}, tracked = {}, count = 0, scan = true, errorLogged = false }
local file = nil

-- A component's world bounds (origin, extent, sphere radius) from KismetSystemLibrary:GetComponentBounds.
local function componentBounds(ksl, component)
    local o, e, sr = {}, {}, {}
    local ret = ksl:GetComponentBounds(component, o, e, sr)
    local tables = { o, e, sr }
    local origin, extent = outVector(tables, o, "Origin"), outVector(tables, e, "BoxExtent")
    local radius = sr.SphereRadius or o.SphereRadius or e.SphereRadius
    if not origin or not extent then
        error(string.format("GetComponentBounds out-params: return=%s origin=%s extent=%s radius=%s",
            tostring(ret), describeOut(o), describeOut(e), describeOut(sr)))
    end
    return origin, extent, num(radius)
end

local function trackFlameComponent(component)
    if not component:IsValid() then return true end
    local template = component.Template
    if not template:IsValid() then return false end
    local kind = FLAME_TEMPLATES[template:GetFName():ToString()]
    local address = component:GetAddress()
    if kind and not f.tracked[address] then
        f.tracked[address] = { component = component, kind = kind }
        -- The address lets tools/Capture-FlameParticles.ps1 read the component's particles from memory.
        log("flame component found: %s (%s) at 0x%X", component:GetFullName(), kind, address)
    end
    return true
end

-- SP_Flames_* parameter values (name -> value) from the component's InstanceParameters.
local function flameParameters(component)
    local values = {}
    local params = component.InstanceParameters
    for i = 1, params:GetArrayNum() do
        local p = params[i]
        values[p.Name:ToString()] = p.Scalar
    end
    return values
end

local function newFlameBreath(r, kind)
    f.count = f.count + 1
    local b = { id = f.count, kind = kind, start = r.time, yaw = r.yaw, frames = 0, dtSum = 0, speedSum = 0,
                reachMax = 0, widthSum = 0, widthMax = 0, centerSum = 0, heightSum = 0, heightMax = 0,
                alignedFrames = 0, alignedReachMax = 0, alignedWidthSum = 0, alignedWidthMax = 0, tailWidthMax = 0,
                paramSum = {}, paramMin = {}, paramFrames = 0 }
    for _, name in ipairs(FLAME_PARAMETERS) do b.paramSum[name], b.paramMin[name] = 0, math.huge end
    return b
end

local function logFlameBreath(b)
    local n = math.max(b.frames, 1)
    local params = {}
    for _, name in ipairs(FLAME_PARAMETERS) do
        local short = name:sub(#"SP_Flames_" + 1)
        if b.paramFrames > 0 then
            table.insert(params, string.format("%s %.3f (min %.3f)", short, b.paramSum[name] / b.paramFrames, b.paramMin[name]))
        end
    end
    local aligned = b.alignedFrames > 0
        and string.format("aligned %d frames: reach %.1f, halfWidth avg %.1f max %.1f", b.alignedFrames, b.alignedReachMax,
            b.alignedWidthSum / b.alignedFrames, b.alignedWidthMax)
        or "aligned 0 frames"
    log("flame %d %s: fps %.1f, active %.3f s, yaw %.1f, speed %.1f, reach %.1f, halfWidth avg %.1f max %.1f (centre %+.1f), halfHeight avg %.1f max %.1f, tail halfWidth max %.1f; %s; params %s",
        b.id, b.kind, b.dtSum > 0 and b.frames / b.dtSum or 0 / 0, b.activeTime or (b.dtSum), b.yaw, b.speedSum / n,
        b.reachMax, b.widthSum / n, b.widthMax, b.centerSum / n, b.heightSum / n, b.heightMax, b.tailWidthMax, aligned,
        #params > 0 and table.concat(params, ", ") or "unavailable")
    if file then file:flush() end
end

-- One tracked component's frame: starts, samples and ends its breath, and writes its CSV row.
local function updateComponent(address, t, r, dt, ksl, c, s, aligned)
    local component = t.component
    if not component:IsValid() then
        if t.breath then logFlameBreath(t.breath) end
        f.tracked[address] = nil
        return
    end
    local active = component:IsActive()
    local b = t.breath
    if active and (not b or b.activeTime) then
        if b then logFlameBreath(b) end
        b = newFlameBreath(r, t.kind)
        t.breath = b
    end
    if b and not active and not b.activeTime then b.activeTime = r.time - b.start end
    if b and b.activeTime and r.time - b.start - b.activeTime > FLAME_TAIL then
        logFlameBreath(b)
        t.breath, b = nil, nil
    end
    if not (b and dt > 0) then return end
    local loc = component:K2_GetComponentLocation()
    -- Without bounds (logged once as unavailable) the parameters are still recorded; sizes read 0.
    local bounds = tryCall("GetComponentBounds", function() return { componentBounds(ksl, component) } end)
        or { loc, { X = 0, Y = 0, Z = 0 }, 0 / 0 }
    local origin, extent, radius = bounds[1], bounds[2], bounds[3]
    local dx, dy = origin.X - loc.X, origin.Y - loc.Y
    local forwardCenter, lateralCenter = dx * c + dy * s, -dx * s + dy * c
    local forwardHalf = math.abs(c) * extent.X + math.abs(s) * extent.Y
    local lateralHalf = math.abs(s) * extent.X + math.abs(c) * extent.Y
    local reach = forwardCenter + forwardHalf
    local values = tryCall("ParticleSystemComponent.InstanceParameters", function() return flameParameters(component) end) or {}
    if active then
        b.frames, b.dtSum = b.frames + 1, b.dtSum + dt
        b.speedSum = b.speedSum + r.speed
        b.reachMax = math.max(b.reachMax, reach)
        b.widthSum, b.widthMax = b.widthSum + lateralHalf, math.max(b.widthMax, lateralHalf)
        b.centerSum = b.centerSum + lateralCenter
        b.heightSum, b.heightMax = b.heightSum + extent.Z, math.max(b.heightMax, extent.Z)
        if aligned then
            b.alignedFrames = b.alignedFrames + 1
            b.alignedReachMax = math.max(b.alignedReachMax, reach)
            b.alignedWidthSum = b.alignedWidthSum + lateralHalf
            b.alignedWidthMax = math.max(b.alignedWidthMax, lateralHalf)
        end
        if values.SP_Flames_C then
            b.paramFrames = b.paramFrames + 1
            for _, name in ipairs(FLAME_PARAMETERS) do
                -- A parameter can be missing on some frames; count it at its default of 1.
                local v = type(values[name]) == "number" and values[name] or 1
                b.paramSum[name] = b.paramSum[name] + v
                b.paramMin[name] = math.min(b.paramMin[name], v)
            end
        end
    else
        b.tailWidthMax = math.max(b.tailWidthMax, lateralHalf)
    end
    if not file then
        file = io.open(paths.flames, "w")
        if file then
            file:write("time,dt,fps_cap,breath,kind,active,spyro_speed,yaw,comp_x,comp_y,comp_z,origin_x,origin_y,origin_z,extent_x,extent_y,extent_z,radius,"
                .. "forward_center,lateral_center,forward_half,lateral_half,reach,aligned,p_c,p_l1,p_r1,p_l2,p_r2\n")
        end
    end
    if file then
        file:write(string.format("%.5f,%.5f,%s,%d,%s,%s,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%s,%.4f,%.4f,%.4f,%.4f,%.4f\n",
            r.time, dt, tostring(state.fpsCap or ""), b.id, b.kind, tostring(active), r.speed, r.yaw,
            loc.X, loc.Y, loc.Z, origin.X, origin.Y, origin.Z, extent.X, extent.Y, extent.Z, radius,
            forwardCenter, lateralCenter, forwardHalf, lateralHalf, reach, tostring(aligned),
            num(values.SP_Flames_C), num(values.SP_Flames_L1), num(values.SP_Flames_R1),
            num(values.SP_Flames_L2), num(values.SP_Flames_R2)))
    end
end

-- Spyro's flame breath: the particle system component's world bounds, measured along his facing, and the
-- trace parameters that set its emitters' lifetimes. One "flame" line per activation.
local function update(r, dt)
    if dt > 0 then f.dtAvg = f.dtAvg and (f.dtAvg * 0.95 + dt * 0.05) or dt end
    for i = #f.pending, 1, -1 do
        local e = f.pending[i]
        e.frames = e.frames + 1
        if trackFlameComponent(e.component) or e.frames >= FLAME_PENDING_FRAMES then table.remove(f.pending, i) end
    end
    if f.scan then
        f.scan = false
        for _, component in ipairs(FindAllOf("ParticleSystemComponent") or {}) do trackFlameComponent(component) end
    end

    local ksl = UEHelpers.GetKismetSystemLibrary()
    local yawRad = math.rad(r.yaw)
    local c, s = math.cos(yawRad), math.sin(yawRad)
    local aligned = math.min(math.abs(c), math.abs(s)) <= math.sin(math.rad(FLAME_ALIGNED_DEG))
    for address, t in pairs(f.tracked) do
        local ok, err = pcall(updateComponent, address, t, r, dt, ksl, c, s, aligned)
        if not ok and not f.componentErrorLogged then
            f.componentErrorLogged = true
            log("flame component error: %s", tostring(err))
        end
    end
end

function flames.update(r, dt)
    local ok, err = pcall(update, r, dt)
    if not ok and not f.errorLogged then
        f.errorLogged = true
        log("flame stats error: %s", tostring(err))
    end
end

-- Applies the K experiment to hard_flames_velocity_muzzle in the loaded flame templates (see FLAME_EXPERIMENTS);
-- other modes restore the asset's own values. New flame components pick the settings up when created, so
-- judge the next breath after switching.
local function applyExperiment(quiet)
    local mode = FLAME_EXPERIMENTS[f.experiment or 1]
    f.original = f.original or {} -- "address.property[index]" -> original value
    local scale = 1
    if mode == "velocity30" and f.dtAvg and f.dtAvg > 0 then scale = math.max(1, (1 / 30) / f.dtAvg) end
    local changed, templates, emitters = 0, 0, 0
    local function set(obj, key, get, put, value)
        key = string.format("%X.%s", obj:GetAddress(), key)
        if f.original[key] == nil then f.original[key] = get() end
        if value == nil then value = f.original[key] end
        if get() ~= value then
            put(value)
            changed = changed + 1
        end
    end
    for _, path in ipairs(FLAME_TEMPLATE_PATHS) do
        local template = StaticFindObject(path)
        if template and template:IsValid() then
            templates = templates + 1
            local list = template.Emitters
            for i = 1, list:GetArrayNum() do
                local emitter = list[i]
                if emitter.EmitterName:ToString() == FLAME_HARD_MUZZLE_EMITTER then
                    emitters = emitters + 1
                    local lods = emitter.LODLevels
                    for j = 1, lods:GetArrayNum() do
                        local lod = lods[j]
                        set(lod, "bEnabled", function() return lod.bEnabled end, function(v) lod.bEnabled = v end,
                            mode == "noHardMuzzle" and false or nil)
                        local modules = lod.Modules
                        for k = 1, modules:GetArrayNum() do
                            local module = modules[k]
                            if module:IsValid() and module:GetClass():GetFName():ToString() == "ParticleModuleVelocity" then
                                -- Cooked distributions are read from the lookup table (Distribution is null).
                                local values = module.StartVelocity.Table.Values
                                for n = 1, values:GetArrayNum() do
                                    local key = "StartVelocity[" .. n .. "]"
                                    local original = f.original[string.format("%X.%s", module:GetAddress(), key)]
                                    if original == nil then original = values[n] end
                                    set(module, key, function() return values[n] end, function(v) values[n] = v end,
                                        original * scale)
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    f.appliedScale = scale
    if not quiet or changed > 0 then
        log("flame experiment %d: %s (%d templates loaded, %d hard muzzle emitters, velocity scale %.2f, %d values changed)",
            f.experiment or 1, mode, templates, emitters, scale, changed)
    end
end

local function logParticleModuleAddresses()
    for _, name in ipairs(PARTICLE_MODULE_CDOS) do
        local cdo = StaticFindObject(string.format("/Script/Engine.Default__%s", name))
        if cdo and cdo:IsValid() then
            log("particle module CDO %s at 0x%X", name, cdo:GetAddress())
        else
            log("particle module CDO %s not found", name)
        end
    end
end

-- Runs at the start of every sample, before the pawn checks: the one-time CDO log, a pending K switch,
-- and velocity30 following the framerate (e.g. after F5/F8).
function flames.beforeSample()
    if not f.cdosLogged then
        f.cdosLogged = true
        tryCall("particle module CDO addresses", logParticleModuleAddresses)
    end
    if f.experimentRequested then
        f.experimentRequested = false
        tryCall("flame experiment", function() applyExperiment(false) end)
    end
    if FLAME_EXPERIMENTS[f.experiment or 1] == "velocity30" and f.dtAvg then
        local want = math.max(1, (1 / 30) / f.dtAvg)
        if math.abs(want - (f.appliedScale or 1)) > FLAME_VELOCITY_RESCALE * want then
            tryCall("flame experiment", function() applyExperiment(true) end)
        end
    end
end

-- F10, and whenever the pawn changes.
function flames.rescan()
    f.scan = true
end

-- K.
function flames.cycleExperiment()
    f.experiment = (f.experiment or 1) % #FLAME_EXPERIMENTS + 1
    f.experimentRequested = true
end

-- Flame breath components may be created at any time; their template is checked from the tick.
function flames.onNewComponent(object)
    if #f.pending < 1000 then table.insert(f.pending, { component = object, frames = 0 }) end
end

return flames
