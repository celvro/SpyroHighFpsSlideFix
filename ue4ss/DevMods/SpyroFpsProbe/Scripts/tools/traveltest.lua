-- Travel test (Y, or create traveltest.txt in this mod folder; it waits until Spyro is in a level): tries each way the game might move
-- Spyro to another level or another game, one after the other, and logs whether he arrived.
--
-- The old probe travel called GlobalTransporter.StartAtLevelCheckpoint with Spyro1_StreamData, whose rows
-- are LevelStreamingData; the transporter reads them as MasterLevelData (SpyroStreamData's row struct), so
-- GetDataTableRowFromName fails and the event returns without doing anything.
--
--   A  transporter StartAtLevelCheckpoint with SpyroStreamData, a level in the same game
--   B  FalconGameState.BP_LoadIntoLevel(row, portal, screen), the game's own portal load, same game
--   C  A into another game's homeworld, game index left alone
--   D  FalconGameState "set game index", then A into that game's homeworld
--   E  FalconGameplayStatics SetActiveGameIndex + SetGameIndex, then B into that game's homeworld
--   F  FalconGameState ReturnToTitle(false), then "start game"(game, save slot): the menu's own switch
--
-- Each step waits until Spyro is in the target level (the target game, for F) and walking for 0.5 s, or
-- times out. "traveltest" lines: the step, the target, result (arrived/timeout/error), how long it took,
-- where he ended up, and the game index (GetGameIndex/GetActiveGameIndex) before and after.
-- F saves the game (quitting to the title does); snapshot the save first (tools/Save-GameSnapshot.ps1).
local UEHelpers = require("UEHelpers")
local levels = require("lib.levels")
local log = require("lib.log")
local paths = require("lib.paths")

local traveltest = {}

local TABLE = "/GameplayCommon/LevelMechanics/LevelStreaming/StreamingData/LevelStreams/SpyroStreamData.SpyroStreamData"
local TIMEOUT = 40         -- seconds per step
local SWITCH_TIMEOUT = 120 -- F: title screen plus loading the other game's save
local SETTLE = 0.5
local HOMES = { [0] = "LS101", [1] = "LS201", [2] = "LS301" }
local SECOND_LEVEL = { [0] = "LS102", [1] = "LS202", [2] = "LS302" }
local TRIGGER = paths.modDir .. "\\traveltest.txt"

local requested = false
local run = nil -- { steps, index, step }
local nextPoll = 0

local function statics()
    return StaticFindObject("/Script/Falcon.Default__FalconGameplayStatics")
end

local function gameState(pawn)
    return UEHelpers.GetGameplayStatics():GetGameState(pawn)
end

local function gameIndices(pawn)
    local ok, a, b = pcall(function()
        local s = statics()
        return s:GetGameIndex(pawn), s:GetActiveGameIndex(pawn)
    end)
    if ok then return a, b end
    return "?", "?"
end

local function gameOf(level)
    local d = level and level:match("^LS(%d)")
    return d and tonumber(d) - 1 or nil
end

local function findTransporter()
    for _, obj in ipairs(FindAllOf("GlobalTransporter_C") or {}) do
        if obj:IsValid() and not obj:GetFullName():match("Default__") then return obj end
    end
    error("no GlobalTransporter_C instance")
end

local function streamTable()
    local t = StaticFindObject(TABLE)
    if t and t:IsValid() then return t end
    t = LoadAsset(TABLE)
    if t and t:IsValid() then return t end
    error("can't find or load " .. TABLE)
end

local function viaTransporter(level)
    findTransporter():StartAtLevelCheckpoint({ DataTable = streamTable(), RowName = FName(level) }, false, 0, "")
end

local function viaGameState(pawn, level)
    streamTable() -- the game state reads its own copy; make sure it's loaded
    gameState(pawn):BP_LoadIntoLevel(FName(level), FName("None"), 0)
end

local function setIndexGameState(pawn, index)
    local gs = gameState(pawn)
    gs["set game index"](gs, index)
end

local function setIndexStatics(pawn, index)
    local s = statics()
    s:SetActiveGameIndex(pawn, index)
    s:SetGameIndex(pawn, index)
end

-- Steps are built as the run goes, from where Spyro is at that moment, so each cross-game step
-- really crosses (C, D and E each go to a game other than the current one).
local function otherGame(current)
    return ((current or 0) + 1) % 3
end

local STEPS = {
    { id = "A", what = "transporter + SpyroStreamData, same game", target = function(cur)
        local g = gameOf(cur) or 0
        return cur == SECOND_LEVEL[g] and HOMES[g] or SECOND_LEVEL[g]
    end, start = function(pawn, level) viaTransporter(level) end },
    { id = "B", what = "FalconGameState.BP_LoadIntoLevel, same game", target = function(cur)
        local g = gameOf(cur) or 0
        return cur == HOMES[g] and SECOND_LEVEL[g] or HOMES[g]
    end, start = function(pawn, level) viaGameState(pawn, level) end },
    { id = "C", what = "transporter into another game, index unchanged", target = function(cur)
        return HOMES[otherGame(gameOf(cur))]
    end, start = function(pawn, level) viaTransporter(level) end },
    { id = "D", what = "'set game index' + transporter into another game", target = function(cur)
        return HOMES[otherGame(gameOf(cur))]
    end, start = function(pawn, level)
        setIndexGameState(pawn, gameOf(level))
        viaTransporter(level)
    end },
    { id = "E", what = "statics SetActiveGameIndex/SetGameIndex + BP_LoadIntoLevel into another game", target = function(cur)
        return HOMES[otherGame(gameOf(cur))]
    end, start = function(pawn, level)
        setIndexStatics(pawn, gameOf(level))
        viaGameState(pawn, level)
    end },
    { id = "F", what = "ReturnToTitle + 'start game' (menu game switch)", switch = true, target = function(cur)
        return "game " .. otherGame(gameOf(cur))
    end, start = function(pawn, level, step)
        step.game = tonumber(level:match("%d+"))
        step.slot = statics():GetActiveSaveSlotIndex(pawn)
        gameState(pawn):ReturnToTitle(false)
        step.phase = "title"
    end },
}

local function finish(step, result, pawn, current)
    local gi, ai = "?", "?"
    if pawn and pawn:IsValid() then gi, ai = gameIndices(pawn) end
    log("traveltest %s %s: %s -> %s: %s after %.1f s, now in %s, gameIndex %s/%s -> %s/%s%s",
        step.id, step.what, tostring(step.from), step.target, result, os.clock() - step.started,
        tostring(current), tostring(step.gi), tostring(step.ai), tostring(gi), tostring(ai),
        step.note and (" (" .. step.note .. ")") or "")
    run.step = nil
end

local function startStep(pawn)
    run.index = run.index + 1
    local def = STEPS[run.index]
    if not def then
        log("traveltest: done")
        run = nil
        return
    end
    local current = levels.current(pawn)
    local step = { id = def.id, what = def.what, def = def, from = current, target = def.target(current),
                   started = os.clock(), settled = 0 }
    step.gi, step.ai = gameIndices(pawn)
    run.step = step
    log("traveltest %s: %s, %s -> %s", step.id, step.what, tostring(current), step.target)
    local ok, err = pcall(def.start, pawn, step.target, step)
    if not ok then
        step.note = tostring(err)
        finish(step, "error", pawn, current)
        return startStep(pawn)
    end
end

-- F: once the title screen is up (no pawn, or the game state back to 0), start the other game.
local function updateSwitch(pawn, step)
    if step.phase == "title" then
        local ok, state = pcall(function() return gameState(pawn).theCurrentGameState end)
        if ok and state == 0 and os.clock() - step.started > 2 then
            local ok2, err = pcall(function()
                local gs = gameState(pawn)
                gs["start game"](gs, step.game, step.slot)
            end)
            step.note = ok2 and string.format("start game(%d, slot %s) at %.1f s", step.game, tostring(step.slot), os.clock() - step.started)
                or ("start game failed: " .. tostring(err))
            step.phase = "loading"
        end
        return nil
    end
    local current = levels.current(pawn)
    if gameOf(current) == step.game then return current end
    return nil
end

local function update()
    local pc = UEHelpers.GetPlayerController()
    local pawn = pc:IsValid() and pc.Pawn or nil
    local hasPawn = pawn and pawn:IsValid()
    local world = hasPawn and pawn or pc

    -- The trigger file waits for a level: create it before starting the game and the run begins on arrival.
    if hasPawn and not run and os.clock() >= nextPoll then
        nextPoll = os.clock() + 1
        local f = io.open(TRIGGER, "r")
        if f then
            f:close()
            os.remove(TRIGGER)
            requested = true
        end
    end
    if requested then
        requested = false
        if run then
            log("traveltest: stopped")
            run = nil
            return
        end
        if not hasPawn then
            log("traveltest: start it in a level")
            return
        end
        run = { index = 0 }
        log("traveltest: starting (%d steps)", #STEPS)
        startStep(pawn)
        return
    end
    if not run or not run.step then return end
    local step = run.step
    local limit = step.def.switch and SWITCH_TIMEOUT or TIMEOUT
    local current
    if step.def.switch then
        if pc:IsValid() then current = updateSwitch(world, step) end
    elseif hasPawn then
        local here = levels.current(pawn)
        if here == step.target then current = here end
    end
    if current and hasPawn then
        local cmc = pawn.CharacterMovement
        local walking = cmc:IsValid() and cmc.MovementMode == 1
        step.settled = walking and step.settled + (os.clock() - (step.lastClock or os.clock())) or 0
        step.lastClock = os.clock()
        if step.settled >= SETTLE then
            finish(step, "arrived", pawn, current)
            startStep(pawn)
            return
        end
    end
    if os.clock() - step.started > limit then
        finish(step, "timeout", hasPawn and pawn or nil, hasPawn and levels.current(pawn) or "no pawn")
        if hasPawn then startStep(pawn) else run = nil end
    end
end

-- Runs every frame before the probe's pawn checks, so it keeps going through the title screen.
function traveltest.update()
    local ok, err = pcall(update)
    if not ok then
        log("traveltest error: %s", tostring(err))
        run = nil
    end
end

function traveltest.toggle()
    requested = true
end

return traveltest
