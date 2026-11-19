-- Makes NPCs talkable again after the level replay's sublevel reload (tools/replay.lua, PgUp / End), by
-- sending the reloaded conversation actors the two level-start events they missed.
--
-- Why (Zephyr, LS213, 2026-11-17/18): after a reset, Spyro walked up to Sergeant Tub on the cannon and no
-- conversation started, so Tub stayed on the cannon for good. Two separate events are missing, and each
-- one alone stops every conversation in the level:
--
-- 1. PlayerReady, for the selectors. Every NPC conversation goes through an IGC_Selector_C actor (Tub's
--    is IGC_Selector2_3253). Entering its volume starts IGC_Current, the dialogue at IGC_Index in its
--    IGC_List, and when that dialogue needs no prompt it starts by itself (a DoOnce, so one try per
--    volume entry). The selector only assigns IGC_Current in its PlayerReady event, which
--    ReceiveBeginPlay binds to the game state's OnPlayerReady delegate. The game broadcasts that when the
--    player enters a level or respawns, never when tools/quicksave.lua streams the gameplay sublevels
--    out and back in. So every reloaded selector sat with IGC_Current = null. Measured in LS213:
--    IGC_Current null after a reset; PlayerReady() on the selector assigned 1_SergeantTub0_Intro_DoEvent.
--
-- 2. The game state change, for the dialogues and cutscenes themselves (Spyro_IGC_Base_C: every
--    _Dialog, _DoEvent, _Sequence, _RewardOrb ...). Their StartIGC only plays when GameState_CutsceneReady
--    is set; otherwise it sets QueueReady and waits. Only GameStateChange sets that flag (NextState == 3,
--    the in-game state), bound at ReceiveBeginPlay to the game state's OnGameStateChanged, and the game
--    state does not change when sublevels reload. So with PlayerReady sent, the selector did start
--    Tub's intro (it walks Spyro to his talking spot), and the intro queued itself for a state change
--    that never came: no text box, and Tub never got the MissionAlert that sends him off the cannon.
--    Measured in LS213 (2026-11-18): GameState_CutsceneReady false on all 36 IGC actors after a reset,
--    theCurrentGameState = 3. GameStateChange(thePreviousGameState, theCurrentGameState) on them set
--    all 36; the next volume entry played Tub's intro, its text box closed on Continue, the selector
--    moved on to 1_SergeantTub1_Instructions and Tub walked off the cannon.
--
-- How: once the reload is back, one FindAllOf("Actor") walk (17 ms in LS213, once per reset, never per
-- frame): PlayerReady() on every IGC_Selector_C (and subclass) and GameStateChange(previous, current)
-- on every Spyro_IGC_Base_C (and subclass) in the reloaded sublevels -- exactly the calls they missed,
-- with the state the game is in. Only those classes: the game state's own OnPlayerReadyCallback would
-- broadcast to everything already in the level as well, and calling PlayerReady on all 21 reloaded
-- actors that have one (Zoe, reward and sequence cinematics) started a cinematic by itself.
--
-- Not the cause, though it looked like it: the save component's checkpoint records. Tub's controller
-- writes one when his conversation ends, but with that record present (and committed by Zoe's
-- checkpoint save) a reset still brought him back on the cannon in his first-visit state.
local log = require("lib.log")

local playerready = {}

-- The sublevels tools/quicksave.lua reloads (its RELOAD_SUFFIXES).
playerready.SUFFIXES = { design = true, enemy = true, loot = true, cinematics = true }
playerready.CLASS = "IGC_Selector_C"   -- gets PlayerReady
playerready.IGC_CLASS = "Spyro_IGC_Base_C" -- gets GameStateChange
playerready.GAME_STATE_CLASS = "FalconGameStateBase"

local kinds = {} -- class address -> { [class name] = true/false }

local function alive(object)
    if object == nil then return false end
    local ok, valid = pcall(function() return object:IsValid() end)
    return ok and valid == true
end

-- Is this sublevel one of `level`'s reloaded ones? "LS213_design" for "LS213".
function playerready.wanted(sublevel, level)
    if type(sublevel) ~= "string" or type(level) ~= "string" then return false end
    local prefix, suffix = sublevel:match("^(LS%d+)_(.+)$")
    return prefix == level and playerready.SUFFIXES[suffix:lower()] == true
end

-- Is `wantedName` in the actor's class chain? Cached per class.
function playerready.derives(actor, wantedName)
    local class
    if not pcall(function() class = actor:GetClass() end) or not alive(class) then return false end
    local key
    if not pcall(function() key = class:GetAddress() end) then return false end
    local known = kinds[key]
    if not known then
        known = {}
        kinds[key] = known
    end
    if known[wantedName] ~= nil then return known[wantedName] end
    local answer, at = false, class
    for _ = 1, 16 do
        if not alive(at) then break end
        local name
        if not pcall(function() name = at:GetFName():ToString() end) then break end
        if name == wantedName then answer = true; break end
        local super
        if not pcall(function() super = at:GetSuperStruct() end) then break end
        at = super
    end
    known[wantedName] = answer
    return answer
end

function playerready.isSelector(actor) return playerready.derives(actor, playerready.CLASS) end
function playerready.isIgc(actor) return playerready.derives(actor, playerready.IGC_CLASS) end

local function sublevelOf(actor)
    local name
    pcall(function() name = actor:GetOuter():GetOuter():GetFName():ToString() end)
    return name
end

-- The state the game is in now, and the one before it (FalconGameStateBase.theCurrentGameState /
-- thePreviousGameState). nil when there is no game state to read.
function playerready.gameState()
    local gs = FindFirstOf(playerready.GAME_STATE_CLASS)
    if not alive(gs) then return nil end
    local cur, prev
    if not pcall(function() cur, prev = gs.theCurrentGameState, gs.thePreviousGameState end) then return nil end
    if type(cur) ~= "number" then return nil end
    return cur, type(prev) == "number" and prev or cur
end

-- The two calls on `level`'s reloaded sublevels. Returns a result:
--   ready / readyFailed   selector names PlayerReady was / could not be called on
--   state / stateFailed   IGC names GameStateChange was / could not be called on
--   current, previous     the game state sent (nil: none could be read, so no GameStateChange was sent)
function playerready.notify(level)
    local result = { ready = {}, readyFailed = {}, state = {}, stateFailed = {} }
    result.current, result.previous = playerready.gameState()
    for _, actor in ipairs(FindAllOf("Actor") or {}) do
        if alive(actor) and playerready.wanted(sublevelOf(actor), level) then
            if playerready.isSelector(actor) then
                local name = actor:GetFName():ToString()
                local list = pcall(function() actor:PlayerReady() end) and result.ready or result.readyFailed
                list[#list + 1] = name
            elseif result.current and playerready.isIgc(actor) then
                local name = actor:GetFName():ToString()
                local list = pcall(function() actor:GameStateChange(result.previous, result.current) end)
                    and result.state or result.stateFailed
                list[#list + 1] = name
            end
        end
    end
    return result
end

-- notify() for tools/replay.lua, with its log line. Never raises.
function playerready.notifyAndLog(level)
    local ok, result = pcall(playerready.notify, level)
    if not ok then
        log("replay: level-start events for the reloaded NPC dialogues failed: %s", tostring(result))
        return
    end
    local failed = {}
    for _, name in ipairs(result.readyFailed) do failed[#failed + 1] = name end
    for _, name in ipairs(result.stateFailed) do failed[#failed + 1] = name end
    local stateText = result.current
        and string.format("game state %d sent to %d dialogue/cutscene actor(s)", result.current, #result.state)
        or "no game state to send to the dialogue/cutscene actors"
    log("replay: PlayerReady sent to %d reloaded NPC dialogue selector(s), %s in %s%s", #result.ready, stateText,
        tostring(level), #failed > 0 and ("; failed on " .. table.concat(failed, ", ")) or "")
end

return playerready
