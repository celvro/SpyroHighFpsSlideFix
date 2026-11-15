-- Free phase of a test room run (tools/animtest.lua with spawn=): the montage phase pins the character
-- and plays its montages in place, so the animations the character's AnimGraph picks from its movement
-- (walk and run blends, flee, being launched) never play there. This lets it loose instead: a fresh copy
-- of the character is spawned for every trial, Spyro does one thing to it (stands still, walks up, flames,
-- charges), and what the character does is recorded, at each framerate cap in turn.
--
-- Some characters only show their reactions to a powered-up Spyro: a Cowlek is launched by a super flame,
-- some enemies only fall to a super charge. A trial can give Spyro a powerup first, the same way the
-- game's own pickups do:
--   * the powerup gates (GameplayCommon/LevelMechanics/AbilityGate/AbilityGate_*) call one interface on
--     the player, IForceCharacterAbilities: IForceAbility:SuperFire(true), :SuperFly, :Invincibility,
--     :IceBreath, :SuperJump, :SuperCharge(true, true); false takes it away again;
--   * super charge comes from a BP_SuperChargeVolume, so one is spawned over the arena, pointing from
--     Spyro at the character. Applying its GE_SpyroSuperChargeEnabled straight to Spyro crashed the game
--     (2026-11-14, an access violation in a physics query under a Blueprint hook): the volume first calls
--     SuperchargeBeginOverlap on Spyro's SuperchargeManager component, and only applies the effect while
--     he faces along it (dot >= 0.8). Destroying the volume runs its own end-overlap code, which removes
--     the effect and calls SuperchargeEndOverlap.
-- Any other gameplay effect can be given by its class path, and any other IForceAbility function as
-- "iface:<Name>". A raw effect skips whatever the game normally does around it, as the super charge one
-- showed, so read what applies it in the game first (AssetDump --code) and prefer that.
--
-- Acts (the "act=" option; each can name its own powerup):
--   idle         Spyro stands still: what the character does on its own (patrol, seek, flee)
--   approach     Spyro walks up to it and stops 150 away
--   flame        walks to 140 away and breathes fire once
--   charge       charges at it from where he stands and runs through it
--   superflame   flame with IForceAbility:SuperFire (a fireball)
--   supercharge  charge with GE_SpyroSuperChargeEnabled, from 3000 away so the stages have time to build
--   icebreath    flame with IForceAbility:IceBreath
--   superjump    flame after IForceAbility:SuperJump has been given (what a gate does before a jump)
-- "power=" adds powerups to every act: a name from POWERS, "iface:<Function>" or a gameplay effect path.
--
--   animtest_free_<stamp>.csv     one row per trial: what the character did (see HEADER)
--   animtest_freesamples_<stamp>.csv  one row every SAMPLE seconds of a trial: where it is, its state and montage
--   "freetest" lines              each trial's summary, and every powerup given or refused
local UEHelpers = require("UEHelpers")
local anim = require("lib.anim")
local input = require("lib.input")
local log = require("lib.log")
local paths = require("lib.paths")
local testroom = require("tools.testroom")

local freetest = {}

local DURATION = 8        -- seconds per trial, from the moment Spyro starts doing his act
local SETTLE = 1.0        -- seconds after the spawn before the act starts (its BeginPlay, Spyro landing)
local CAP_SETTLE = 0.5    -- seconds after a cap change (t.MaxFPS is applied on the game thread)
local SAMPLE = 0.05
local FLAME_RANGE = 140   -- inside the breath's reach (a Cowlek was hit from 130, tools/worldtour/scripts.lua)
local APPROACH_RANGE = 150
local APPROACH_TIMEOUT = 4
local FLAME_HOLD = 0.25
local CHARGE_TIME = 2.5   -- longest a charge is held
local SUPERCHARGE_TIME = 6
local SUPERCHARGE_START = 3000 -- the stages come at 0.75 s and 1.75 s (docs/findings/super-charge.md)
local PASS_BY = 300       -- a charge is let go this far past its closest approach

local SUPERCHARGE_VOLUME = "/GameplayCommon/LevelMechanics/Spyro_SuperCharge/BP_SuperChargeVolume.BP_SuperChargeVolume_C"
local VOLUME_EXTENT = { X = 4500, Y = 4500, Z = 400 } -- covers a supercharge's 3000 run-up and the far side
local ALWAYS_SPAWN = 2

-- How each named powerup is given and taken away.
local POWERS = {
    superflame  = { iface = "SuperFire", on = { true }, off = { false } },
    superfire   = { iface = "SuperFire", on = { true }, off = { false } },
    icebreath   = { iface = "IceBreath", on = { true }, off = { false } },
    superfly    = { iface = "SuperFly", on = { true }, off = { false } },
    invincible  = { iface = "Invincibility", on = { true }, off = { false } },
    superjump   = { iface = "SuperJump", on = {}, off = nil },
    supercharge = { volume = SUPERCHARGE_VOLUME },
}

-- What each act does: its script and the powerups it needs.
local ACTS = {
    idle        = { script = "idle" },
    approach    = { script = "approach" },
    flame       = { script = "flame" },
    charge      = { script = "charge" },
    superflame  = { script = "flame", powers = { "superflame" } },
    supercharge = { script = "charge", powers = { "supercharge" }, start = SUPERCHARGE_START, chargeTime = SUPERCHARGE_TIME },
    icebreath   = { script = "flame", powers = { "icebreath" } },
    superjump   = { script = "flame", powers = { "superjump" } },
}
freetest.DEFAULT_ACTS = "idle,approach,flame,charge"

local CSV = string.format("%s\\animtest_free_%s.csv", paths.modDir, paths.stamp)
local SAMPLES = string.format("%s\\animtest_freesamples_%s.csv", paths.modDir, paths.stamp)
local HEADER = "cap,level,class,act,powers,try,arena,startDist,duration,frames,avgFps,path,net,vmax,zMax,zMin,"
    .. "air,modes,states,montages,reacted,react,gone,closest,animSpeedMax,animSpeedNaN,result\n"
local SAMPLE_HEADER = "cap,level,class,act,try,t,x,y,z,speed,mode,state,montage,spyroDist\n"

local csv, samplesCsv = nil, nil
local ROT = { Pitch = 0, Yaw = 0, Roll = 0 }

local function open(path, header)
    local file = io.open(path, "a")
    if file and file:seek("end") == 0 then file:write(header) end
    return file
end

local function list(text)
    local out = {}
    for word in tostring(text or ""):gmatch("[^,]+") do out[#out + 1] = word end
    return out
end

-- The trials to run, in order: every act at the first cap, then every act at the next.
-- Returns nil and the reason for an act or a powerup it does not know.
function freetest.plan(caps, options)
    local acts = list(options.act or freetest.DEFAULT_ACTS)
    local extra = list(options.power)
    for _, name in ipairs(extra) do
        if not (POWERS[name] or name:match("^iface:%w+$") or name:find("/", 1, true)) then
            return nil, "unknown power=" .. name .. " (known: superflame, supercharge, superfly, invincible, icebreath, superjump, iface:<Name> or a gameplay effect path)"
        end
    end
    local tries = math.max(1, tonumber(options.tries) or 1)
    local duration = tonumber(options.free) or DURATION
    local trials = {}
    for _, cap in ipairs(caps) do
        for _, act in ipairs(acts) do
            local recipe = ACTS[act]
            if not recipe then
                return nil, "unknown act=" .. act .. " (known: idle, approach, flame, charge, superflame, supercharge, icebreath, superjump)"
            end
            local powers = {}
            for _, p in ipairs(recipe.powers or {}) do powers[#powers + 1] = p end
            for _, p in ipairs(extra) do powers[#powers + 1] = p end
            for try = 1, tries do
                trials[#trials + 1] = { cap = cap, act = act, recipe = recipe, powers = powers, try = try,
                                        duration = duration }
            end
        end
    end
    return trials
end

local function loadClass(path)
    local class = StaticFindObject(path)
    if class and class:IsValid() then return class end
    pcall(LoadAsset, (path:gsub("_C$", "")))
    class = StaticFindObject(path)
    if class and class:IsValid() then return class end
    error("not found after LoadAsset: " .. path)
end

-- A volume Blueprint covering the arena, its forward axis pointing from Spyro's start at the character.
local function spawnVolume(pawn, room, path)
    local class = loadClass(path)
    local half = math.rad(room.yaw) / 2
    local transform = {
        Rotation = { X = 0, Y = 0, Z = math.sin(half), W = math.cos(half) },
        Translation = { X = room.centre.X, Y = room.centre.Y, Z = room.top + VOLUME_EXTENT.Z / 2 },
        Scale3D = { X = 1, Y = 1, Z = 1 },
    }
    local statics = UEHelpers.GetGameplayStatics()
    local volume = statics:BeginDeferredActorSpawnFromClass(pawn, class, transform, ALWAYS_SPAWN, nil)
    if not volume or not volume:IsValid() then error("the volume did not spawn") end
    statics:FinishSpawningActor(volume, transform)
    pcall(function() volume.TriggerVolume:SetBoxExtent(VOLUME_EXTENT, true) end)
    return volume
end

-- Gives (on = true) or takes away one powerup. Returns true when the game took the call.
local function power(pawn, name, on, room, trial)
    local def = POWERS[name]
    if not def then
        local iface = name:match("^iface:(%w+)$")
        def = iface and { iface = iface, on = { true }, off = { false } } or { effect = name }
    end
    local ok, err = pcall(function()
        if def.volume then
            trial.volumes = trial.volumes or {}
            if on then
                trial.volumes[name] = spawnVolume(pawn, room, def.volume)
            else
                local volume = trial.volumes[name]
                trial.volumes[name] = nil
                if volume and volume:IsValid() then volume:K2_DestroyActor() end
            end
        elseif def.iface then
            local args = on and def.on or def.off
            if not args then return end
            local fn = "IForceAbility:" .. def.iface
            pawn[fn](pawn, table.unpack(args))
        else
            local asc = pawn.AbilitySystem
            local class = loadClass(def.effect)
            if on then
                asc:BP_ApplyGameplayEffectToSelf(class, 1.0, asc:MakeEffectContext())
            else
                asc:RemoveActiveGameplayEffectBySourceEffect(class, asc, -1)
            end
        end
    end)
    if not ok then log("freetest: could not %s %s: %s", on and "give" or "take away", name, tostring(err)) end
    return ok
end

local function powersOff(pawn, trial)
    if not trial.powered then return end
    trial.powered = false
    for i = #trial.powers, 1, -1 do power(pawn, trial.powers[i], false, nil, trial) end
end

local function horizontal(a, b)
    return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2)
end

local function face(pc, from, to)
    ROT.Pitch = pc:GetControlRotation().Pitch
    ROT.Yaw = math.deg(math.atan(to.Y - from.Y, to.X - from.X))
    pc:SetControlRotation(ROT)
end

local function newTrial(trial)
    trial.t, trial.frames, trial.dtSum = 0, 0, 0
    trial.path, trial.vmax, trial.zMax, trial.zMin, trial.air = 0, 0, 0, 0, 0
    trial.modes, trial.states, trial.montages, trial.seenMontage = {}, {}, {}, {}
    trial.closest, trial.nextSample = math.huge, 0
    trial.animSpeedMax, trial.animSpeedNaN = 0, false
    trial.step, trial.stepT = "start", 0
end

-- Spyro, fresh character, powerups: everything a trial starts from.
local function setUp(pawn, pc, room, trial)
    if room.actor and room.actor:IsValid() then pcall(function() room.actor:K2_DestroyActor() end) end
    room.actor = nil
    input.clear(pawn, pc)
    local start = trial.recipe.start or room.distance
    local rad = math.rad(room.yaw)
    local spot = { X = room.centre.X - math.cos(rad) * start, Y = room.centre.Y - math.sin(rad) * start, Z = room.spyro.Z }
    -- Powerups first: a volume has to be there before Spyro is teleported into it, so the move starts
    -- the overlap the way walking in would.
    trial.powered = true
    for _, name in ipairs(trial.powers) do power(pawn, name, true, room, trial) end
    pawn:K2_TeleportTo(spot, { Pitch = 0, Yaw = room.yaw, Roll = 0 })
    pcall(function() pawn.CharacterMovement.Velocity = { X = 0, Y = 0, Z = 0 } end)
    face(pc, spot, room.centre)
    local actor, home = testroom.spawn(pawn, room, trial.classPath)
    trial.actor, trial.home = actor, { X = home.X, Y = home.Y, Z = home.Z }
    trial.held = anim.hold(actor) -- tick the mesh every frame, as in the montage phase; its AI is left alone
    trial.startDist = horizontal(spot, home)
    newTrial(trial)
end

-- One frame of Spyro's act. Returns nothing; trial.attackAt is when the act reached the character.
local function drive(pawn, pc, trial, dt, enemyLoc)
    local script = trial.recipe.script
    local me = pawn:K2_GetActorLocation()
    local dist = horizontal(me, enemyLoc)
    trial.stepT = trial.stepT + dt
    if script == "idle" then
        input.hold({})
    elseif script == "approach" or (script == "flame" and trial.step ~= "breath" and trial.step ~= "done") then
        local range = script == "flame" and FLAME_RANGE or APPROACH_RANGE
        if dist > range and trial.stepT < APPROACH_TIMEOUT and trial.step ~= "done" then
            face(pc, me, enemyLoc)
            input.hold({ leftY = 1 })
            trial.step = "walk"
        elseif script == "flame" then
            input.hold({})
            face(pc, me, enemyLoc)
            input.press("flame")
            trial.step, trial.stepT, trial.attackAt = "breath", 0, trial.t
        else
            input.hold({})
            trial.attackAt = trial.attackAt or trial.t
            trial.step = "done"
        end
    elseif script == "flame" and trial.step == "breath" then
        if trial.stepT >= FLAME_HOLD then
            input.release("flame")
            trial.step = "done"
        end
    elseif script == "charge" and trial.step ~= "done" then
        trial.chargeClosest = math.min(trial.chargeClosest or math.huge, dist)
        local passed = trial.chargeClosest < 250 and dist > trial.chargeClosest + PASS_BY
        if passed or trial.stepT >= (trial.recipe.chargeTime or CHARGE_TIME) then
            input.hold({})
            input.release("charge")
            trial.step = "done"
        else
            if trial.chargeClosest > 250 then face(pc, me, enemyLoc) end -- steer until it is reached, then run on
            input.hold({ leftY = 1 })
            input.press("charge")
            if dist < 250 and not trial.attackAt then trial.attackAt = trial.t end
            trial.step = "charging"
        end
    end
    input.apply(pawn, pc)
end

local function sample(pawn, trial, dt, level)
    local actor = trial.actor
    if not (actor and actor:IsValid()) then
        trial.gone = trial.gone or trial.t
        return nil
    end
    local loc = actor:K2_GetActorLocation()
    local s = anim.state(actor)
    local speed, mode = 0, -1
    pcall(function()
        local cmc = actor.CharacterMovement
        local v = cmc.Velocity
        speed = math.sqrt(v.X * v.X + v.Y * v.Y)
        mode = cmc.MovementMode
    end)
    if trial.last then trial.path = trial.path + horizontal(loc, trial.last) end
    trial.last = { X = loc.X, Y = loc.Y, Z = loc.Z }
    trial.vmax = math.max(trial.vmax, speed)
    local dz = loc.Z - trial.home.Z
    trial.zMax, trial.zMin = math.max(trial.zMax, dz), math.min(trial.zMin, dz)
    if mode == 3 then trial.air = trial.air + dt end
    trial.modes[tostring(mode)] = true
    local state = s.enemyState ~= "" and s.enemyState or "-"
    local states = trial.states
    if #states == 0 or states[#states].name ~= state then
        states[#states + 1] = { name = state, time = 0, at = trial.t }
        if #states > 1 and trial.attackAt and not trial.react and trial.t >= trial.attackAt then
            trial.react = trial.t - trial.attackAt
        end
    end
    states[#states].time = states[#states].time + dt
    if s.montage ~= "" and not trial.seenMontage[s.montage] then
        trial.seenMontage[s.montage] = true
        trial.montages[#trial.montages + 1] = s.montage
    end
    -- The anim Blueprint's own Speed, where it has one: the gem thief's went NaN (docs/findings/gem-thief-anim.md).
    if trial.animSpeedOk ~= false then
        local ok, value = pcall(function() return anim.instance(actor).Speed end)
        if ok and type(value) == "number" then
            trial.animSpeedOk = true
            if value ~= value or value == math.huge or value == -math.huge then
                trial.animSpeedNaN = true
            else
                trial.animSpeedMax = math.max(trial.animSpeedMax, value)
            end
        elseif trial.animSpeedOk == nil then
            trial.animSpeedOk = false
        end
    end
    local spyroDist = horizontal(pawn:K2_GetActorLocation(), loc)
    trial.closest = math.min(trial.closest, spyroDist)
    if trial.t >= trial.nextSample then
        trial.nextSample = trial.nextSample + SAMPLE
        samplesCsv = samplesCsv or open(SAMPLES, SAMPLE_HEADER)
        if samplesCsv then
            samplesCsv:write(string.format("%d,%s,%s,%s,%d,%.3f,%.2f,%.2f,%.2f,%.2f,%d,%s,%s,%.1f\n", trial.cap, level,
                trial.class, trial.act, trial.try, trial.t, loc.X - trial.home.X, loc.Y - trial.home.Y, dz, speed,
                mode, state, s.montage, spyroDist))
        end
    end
    return loc
end

local function finish(pawn, pc, trial, level, arena)
    input.clear(pawn, pc)
    powersOff(pawn, trial)
    anim.release(trial.held)
    trial.held = nil
    local net = trial.last and horizontal(trial.last, trial.home) or 0
    local stateParts = {}
    for _, s in ipairs(trial.states) do stateParts[#stateParts + 1] = string.format("%s:%.2f", s.name, s.time) end
    local modes = {}
    for m in pairs(trial.modes) do modes[#modes + 1] = m end
    table.sort(modes)
    local avgFps = trial.frames / math.max(trial.dtSum, 1e-6)
    local moved = trial.path > 50 or trial.zMax > 50
    local result = trial.gone and "gone" or (moved and "moved" or "still")
    csv = csv or open(CSV, HEADER)
    if csv then
        csv:write(string.format("%d,%s,%s,%s,%s,%d,%s,%.0f,%.3f,%d,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f,%.3f,%s,%s,%s,%s,%s,%s,%.0f,%.1f,%s,%s\n",
            trial.cap, level, trial.class, trial.act, table.concat(trial.powers, "+"), trial.try, arena,
            trial.startDist, trial.t, trial.frames, avgFps, trial.path, net, trial.vmax, trial.zMax, trial.zMin,
            trial.air, table.concat(modes, "/"), table.concat(stateParts, ">"), table.concat(trial.montages, ">"),
            tostring(#trial.states > 1), trial.react and string.format("%.3f", trial.react) or "",
            trial.gone and string.format("%.3f", trial.gone) or "", trial.closest,
            trial.animSpeedMax, tostring(trial.animSpeedNaN), result))
        csv:flush()
    end
    log("freetest: %d FPS %s%s try %d: %s, path %.0f net %.0f vmax %.0f zMax %.0f air %.2fs avgFps %.0f | %s | %s",
        trial.cap, trial.act, #trial.powers > 0 and ("+" .. table.concat(trial.powers, "+")) or "", trial.try, result,
        trial.path, net, trial.vmax, trial.zMax, trial.air, avgFps, table.concat(stateParts, ">"),
        table.concat(trial.montages, ">"))
end

-- Runs the trials one after another. Call every frame; returns true once they are all done.
-- ctx: { trials, room, path, class, level, arena, setFpsCap, capNow }
function freetest.update(pawn, pc, r, ctx)
    local trial = ctx.trials[ctx.index or 1]
    ctx.index = ctx.index or 1
    if not trial then return true end
    if not trial.phase then
        trial.classPath, trial.class = ctx.path, ctx.class
        if ctx.capNow ~= trial.cap then
            ctx.setFpsCap(trial.cap)
            ctx.capNow = trial.cap
            trial.phase, trial.wait = "cap", CAP_SETTLE
        else
            trial.phase = "spawn"
        end
        if trial.try == 1 then
            log("freetest: %d FPS, act %s%s", trial.cap, trial.act,
                #trial.powers > 0 and (" with " .. table.concat(trial.powers, "+")) or "")
        end
    end
    if trial.phase == "cap" then
        trial.wait = trial.wait - r.dt
        if trial.wait <= 0 then trial.phase = "spawn" end
        return false
    end
    if trial.phase == "spawn" then
        local ok, err = pcall(setUp, pawn, pc, ctx.room, trial)
        if not ok then
            log("freetest: %s trial could not start: %s", trial.act, tostring(err))
            powersOff(pawn, trial)
            ctx.index = ctx.index + 1
            return false
        end
        trial.phase, trial.wait = "settle", SETTLE
        return false
    end
    if trial.phase == "settle" then
        input.hold({})
        input.apply(pawn, pc)
        trial.wait = trial.wait - r.dt
        if trial.wait <= 0 then trial.phase = "run" end
        return false
    end
    -- run
    trial.t = trial.t + r.dt
    trial.frames, trial.dtSum = trial.frames + 1, trial.dtSum + r.dt
    local loc = sample(pawn, trial, r.dt, ctx.level)
    if loc then drive(pawn, pc, trial, r.dt, loc) else input.clear(pawn, pc) end
    if trial.t >= trial.duration then
        finish(pawn, pc, trial, ctx.level, ctx.arena)
        ctx.index = ctx.index + 1
    end
    return false
end

-- Puts everything back when a run stops part way through a trial.
function freetest.abort(pawn, pc, ctx)
    local trial = ctx and ctx.trials[ctx.index or 1]
    if not trial then return end
    pcall(input.clear, pawn, pc)
    pcall(powersOff, pawn, trial)
    if trial.held then pcall(anim.release, trial.held) end
end

return freetest
