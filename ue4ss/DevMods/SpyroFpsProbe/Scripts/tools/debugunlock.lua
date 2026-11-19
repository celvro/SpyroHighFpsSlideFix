-- Debug unlocks, switched in config.lua (DEBUG_UNLOCKS): the guidebook travels to every level, and Spyro
-- has the moves the game otherwise makes him earn. Applied again whenever the game or the pawn changes,
-- since each game keeps its own save data.
--
-- **Guidebook travel to any level.** The guidebook (UI_Inventory) and its level list
-- (UI_InventoryLevelList) already have a developer switch for this: both read
-- DebugFunctionLibrary."Get Toggle Setting"("show_unvisited_levels") and, when it is on, ask
-- GameMapsFunctionLib for every homeworld and every level instead of the visited ones. Travelling is
-- gated only by the native FalconGameStateBase.CanLoadLevel (a patch check), not by visits. The toggle
-- is stored as global float data "debug.show_unvisited_levels" (DebugFunctionLibrary "Add Toggle
-- Setting" -> "Save Debug Setting" -> FalconGameplayStatics.SetGlobalFloatData), so this writes that.
-- FalconGameState even has "set default show unvisited levels if running in windows", which would turn it
-- on for PC, but nothing calls it. (AssetDump --code of UI_Inventory, UI_InventoryLevelList,
-- DebugFunctionLibrary and FalconGameState, 2026-11-17.)
--
-- **Spyro 2's moves.** Climbing, head bash and swimming underwater are inventory items Moneybags sells:
-- EInventoryType EIT_Climbing 30, EIT_HeadBash 31, EIT_Swimming 32 (enumerator order read from the
-- exe's reflection strings). BP_Base_Playable.UpdateSettingsSpyro2 applies GE_Enable_Climbing /
-- _HeadBash / _SwimmingUnderwater when the count is above 0. The game state's own setter, "set player
-- inventory item count"(item, count, UpdateSettings = true), sets the count and then calls the player
-- controller's PlayerSettingsUpdated, which re-runs that on the pawn, so the moves work at once.
-- EIT_Superflame 33 is the permanent super flame (GE_Enable_PermanentSuperFire, read by both Spyro 2 and
-- Spyro 3): it replaces the normal flame, so it has its own switch.
--
-- **Spyro 3.** UpdateSettingsSpyro3 gives climbing, swimming and head bash unconditionally already. What
-- Spyro 3 has Spyro earn is Sparx's four powers from the Sparx levels: EIT_SparxPower_GemCollectRange 45,
-- _GemFinder 46, _ExtraHP 47, _ChestBreaking 48, set the same way (the setter routes them to "set sparx
-- power obtained").
--
-- **Not here: Spyro 3's playable characters.** Sheila, Sgt. Byrd, Bentley and Agent 9 have no single
-- unlock flag. Each rescue is a set of states on the native quest system's board in the save (in
-- Sunrise Spring: "Sheila" = trapped, "sheila jail" = Locked, "Sheila's Sign" = Illegible,
-- "LS306_SheilasAlp_Start" = Closed), and every level's character door is its own quest state, read by
-- C++ quest code (QuestFramework/QuestCore) rather than Blueprint. The guidebook switch above does reach
-- each character's own level (Sheila's Alp, Sgt. Byrd's Base, Bentley's Outpost, Agent 9's Lab), where
-- you play as that character.
--
-- All of this lands in the save the next time the game saves (global float data and inventory are save
-- data): back the save up first (tools/Save-GameSnapshot.ps1). Setting `guidebook = false` clears the
-- flag again on the next level load; the inventory items stay, as they would after buying them.
--
--   "debugunlock" lines  what was applied, per pawn, and anything that failed
local UEHelpers = require("UEHelpers")
local config = require("config")
local log = require("lib.log")

local debugunlock = {}

-- nil when config.lua has no DEBUG_UNLOCKS table: then nothing is written at all.
local SETTINGS = config.DEBUG_UNLOCKS

local GUIDEBOOK_KEY = "debug.show_unvisited_levels"

-- EInventoryType values (0-based enumerator order in the exe).
local SPYRO2_MOVES = {
    { item = 30, name = "climbing" },
    { item = 31, name = "head bash" },
    { item = 32, name = "swimming underwater" },
}
local SPYRO3_SPARX = {
    { item = 45, name = "Sparx gem collect range" },
    { item = 46, name = "Sparx gem finder" },
    { item = 47, name = "Sparx extra hit" },
    { item = 48, name = "Sparx chest breaking" },
}
local SUPERFLAME = { item = 33, name = "permanent super flame" }

local CHECK_INTERVAL = 1 -- seconds between looks at the game index and pawn

local appliedTo = nil  -- "<game index>:<pawn address>" the unlocks were last applied for
local nextCheck = 0
local failed = false   -- an error disables the module for the session (logged once)
local cachedStatics = nil

-- A /Script CDO lives as long as the game, so one lookup is enough (CLAUDE.md: no repeated finds).
local function statics()
    if cachedStatics and cachedStatics:IsValid() then return cachedStatics end
    local s = StaticFindObject("/Script/Falcon.Default__FalconGameplayStatics")
    if not (s and s:IsValid()) then error("FalconGameplayStatics not found") end
    cachedStatics = s
    return s
end

-- Writes the guidebook switch to match the config, so turning it off in config.lua also clears it.
local function applyGuidebook(pawn)
    local value = SETTINGS.guidebook and 1.0 or 0.0
    statics():SetGlobalFloatData(pawn, GUIDEBOOK_KEY, value)
    return SETTINGS.guidebook and "guidebook lists every level" or nil
end

local function grant(gs, list, granted)
    for _, entry in ipairs(list) do
        gs["set player inventory item count"](gs, entry.item, 1, true)
        granted[#granted + 1] = entry.name
    end
end

local function applyItems(pawn, game)
    local gs = UEHelpers.GetGameplayStatics():GetGameState(pawn)
    if not gs:IsValid() then error("no game state") end
    local granted = {}
    if SETTINGS.moves then
        if game == 1 then grant(gs, SPYRO2_MOVES, granted) end
        if game == 2 then grant(gs, SPYRO3_SPARX, granted) end
    end
    if SETTINGS.superflame and game >= 1 then grant(gs, { SUPERFLAME }, granted) end
    return granted
end

-- Applies everything the config asks for, now. Safe to call again: each write sets a value rather than
-- adding to it.
function debugunlock.apply(pawn)
    local game = statics():GetActiveGameIndex(pawn) -- 0 = Spyro 1, 1 = Spyro 2, 2 = Spyro 3
    local done = {}
    local guidebook = applyGuidebook(pawn)
    if guidebook then done[#done + 1] = guidebook end
    for _, name in ipairs(applyItems(pawn, game)) do done[#done + 1] = name end
    log("debugunlock: Spyro %d: %s", game + 1, #done > 0 and table.concat(done, ", ") or "nothing to unlock")
end

-- Every frame with a pawn; looks once a second. Reapplies when the game or the pawn changes. The game
-- index is part of the key because a game swap's new pawn can come back at the old one's address
-- (measured 2026-11-17: Spyro 2 -> 3 through the title, same address, so a pawn-only key never fired),
-- and each game has its own save data to write.
function debugunlock.update(pawn)
    if failed or not SETTINGS then return end
    local now = os.clock()
    if now < nextCheck then return end
    nextCheck = now + CHECK_INTERVAL
    local ok, err = pcall(function()
        local key = string.format("%d:%x", statics():GetActiveGameIndex(pawn), pawn:GetAddress())
        if key == appliedTo then return end
        appliedTo = key
        debugunlock.apply(pawn)
    end)
    if not ok then
        failed = true
        log("debugunlock: failed, off for this session: %s", tostring(err))
    end
end

return debugunlock
