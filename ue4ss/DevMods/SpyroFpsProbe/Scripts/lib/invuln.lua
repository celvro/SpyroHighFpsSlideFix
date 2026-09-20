-- Keeps Spyro alive while the probe runs (enemies attack him while he stands still): every REFILL_INTERVAL
-- it sets the life count to 99 and tops Sparx up to full by applying the game's GE_BasicHeal (+1 HealthCurrent, the butterfly heal) once
-- per missing point, read from his PhasmidHealthSystemAttributeSet (HealthCurrent/HealthMax). He still takes
-- hits and knockback.
--
-- Tried first (2026-09-19), both dropped: GE_Invincibility (DamageSystem.CannotTakeDamage) didn't stop hits
-- or knockback (the GA_Spyro_Damage_* knockbacks are triggered straight by gameplay events, and DamageLibrary
-- MakeInvulnerable(Force) strips every effect granting the tag); a "ghost" Spyro (collision off, held in
-- Flying) slowly rose through the air every few seconds.
-- Call update(pawn) every frame while wanted; clear() when done.
local UEHelpers = require("UEHelpers")
local log = require("lib.log")

local invuln = {}

local HEAL = "/CharacterCommon/Abilities/GameplayEffects/GE_BasicHeal.GE_BasicHeal_C"
local REFILL_INTERVAL = 2 -- seconds
-- Deaths still happen (a test walks him into enemies and off ledges), and running out of lives ends the
-- run on the game-over screen, so the life count is kept topped up. EIT_Life is 18 in EInventoryType
-- (listed with tools/dumpstate.lua, 2026-09-20); the game state's own setter is what the pickups call.
local LIFE_ITEM = 18
local LIVES = 99

local nextRefill = 0
local attrs = nil -- { pawnAddress, set }
local failed = false
local livesFailed = false
local livesLogged = false

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

-- Sparx's health now and at full, for the death check in tools/autotest.lua.
function invuln.health(pawn)
    local ok, current, max = pcall(function()
        local set = healthSet(pawn)
        return attribute(set.HealthCurrent), attribute(set.HealthMax)
    end)
    if not ok then return nil end
    return current, max
end

local function topUpLives(pawn)
    local gs = UEHelpers.GetGameplayStatics():GetGameState(pawn)
    gs["set player inventory item count"](gs, LIFE_ITEM, LIVES, true)
end

function invuln.update(pawn)
    if failed or os.clock() < nextRefill then return end
    nextRefill = os.clock() + REFILL_INTERVAL
    local ok, err = pcall(refill, pawn)
    if not ok then
        failed = true
        log("invulnerable: can't top up Sparx: %s", tostring(err))
    end
    if livesFailed then return end
    local okLives, livesErr = pcall(topUpLives, pawn)
    if not okLives then
        livesFailed = true
        log("invulnerable: can't set the life count: %s", tostring(livesErr))
    elseif not livesLogged then
        livesLogged = true
        log("invulnerable: life count held at %d", LIVES)
    end
end

function invuln.clear()
    nextRefill, failed, livesFailed = 0, false, false
end

return invuln
