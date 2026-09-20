-- Keeps Spyro alive while a test tool runs (enemies attack him while he stands still): every REFILL_INTERVAL
-- it tops Sparx up to full by applying the game's GE_BasicHeal (+1 HealthCurrent, the butterfly heal) once
-- per missing point, read from his PhasmidHealthSystemAttributeSet (HealthCurrent/HealthMax). He still takes
-- hits and knockback.
--
-- Tried first (2026-09-19), both dropped: GE_Invincibility (DamageSystem.CannotTakeDamage) didn't stop hits
-- or knockback (the GA_Spyro_Damage_* knockbacks are triggered straight by gameplay events, and DamageLibrary
-- MakeInvulnerable(Force) strips every effect granting the tag); a "ghost" Spyro (collision off, held in
-- Flying) slowly rose through the air every few seconds.
-- Call update(pawn) every frame while wanted; clear() when done.
local log = require("lib.log")

local invuln = {}

local HEAL = "/CharacterCommon/Abilities/GameplayEffects/GE_BasicHeal.GE_BasicHeal_C"
local REFILL_INTERVAL = 2 -- seconds

local nextRefill = 0
local attrs = nil -- { pawnAddress, set }
local failed = false

local function loadClass(path)
    local cls = StaticFindObject(path)
    if cls and cls:IsValid() then return cls end
    pcall(LoadAsset, path)
    cls = StaticFindObject(path)
    if cls and cls:IsValid() then return cls end
    error("can't load " .. path)
end

-- His health attribute set: a subobject of the pawn. Looked up once per pawn (FindAllOf scans every object).
local function healthSet(pawn)
    local address = pawn:GetAddress()
    if attrs and attrs.pawnAddress == address and attrs.set:IsValid() then return attrs.set end
    for _, set in ipairs(FindAllOf("PhasmidHealthSystemAttributeSet") or {}) do
        local ok, outer = pcall(function() return set:GetOuter():GetAddress() end)
        if ok and outer == address then
            attrs = { pawnAddress = address, set = set }
            return set
        end
    end
    error("no PhasmidHealthSystemAttributeSet on Spyro")
end

-- These attributes are plain floats in this game (2026-09-19: "attempt to index a number value"), not
-- FGameplayAttributeData; accept either.
local function attribute(v)
    if type(v) == "number" then return v end
    return v.CurrentValue
end

local function refill(pawn)
    local set = healthSet(pawn)
    local current, max = attribute(set.HealthCurrent), attribute(set.HealthMax)
    local missing = math.floor(max - current + 0.5)
    if missing <= 0 then return end
    local asc, heal = pawn.AbilitySystem, loadClass(HEAL)
    for _ = 1, missing do asc:BP_ApplyGameplayEffectToSelf(heal, 1.0, asc:MakeEffectContext()) end
    log("invulnerable: Sparx topped up %.0f -> %.0f (now %.0f)", current, max, attribute(set.HealthCurrent))
end

function invuln.update(pawn)
    if failed or os.clock() < nextRefill then return end
    nextRefill = os.clock() + REFILL_INTERVAL
    local ok, err = pcall(refill, pawn)
    if not ok then
        failed = true
        log("invulnerable: can't top up Sparx: %s", tostring(err))
    end
end

function invuln.clear()
    nextRefill, failed = 0, false
end

return invuln
