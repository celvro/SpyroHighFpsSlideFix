-- Knowing when an in-game cinematic is running, which is what a conversation with an NPC is, and what a
-- save fairy is, and moving a conversation along the way a player does.
--
-- Talking to an NPC plays an in-game cinematic, and while it runs the game has the camera and the input.
-- A scripted tour must not teleport out of one (it keeps hold of him wherever he lands, so the next stop
-- is lost too) and must not end on one (the game sits in a text box for as long as nobody is watching).
-- So the tour waits for it, pressing Continue on its text box (lib/dialogue.lua) until it closes by
-- itself. Nothing here ends a cinematic, skips one, or touches input or the HUD: see igc.close.
--
-- Finding the running one: FindAllOf matches a class name exactly, and no instance is ever a plain
-- Spyro_IGC_Base_C: every one is of the level's own subclass (LS321 has BP_LS321_IGCBoxing_C), and a
-- save fairy is a Spyro_IGC_SavePoint0_C. Listing the names would only ever cover the levels already
-- looked at, so each actor's class chain is walked for Spyro_IGC_Base_C instead. CurrentlyActiveIGC
-- says whether it is running.
--
--   "igc" lines  what cinematics a level has, and a cutscene being waited out
local dialogue = require("lib.dialogue")
local log = require("lib.log")

local igc = {}

-- The sweep is a walk of every actor in the level (~1400 of them), so the objects are kept rather than
-- swept for every question. But not for the whole level: a minigame streams its own sublevel in while
-- the level stays the same, and the cinematic that starts it is not in a list swept before it existed.
-- So the list goes stale after CACHE_SECONDS and is swept again -- at most once a stop, which is about
-- ten milliseconds of the eight seconds a stop takes.
local CACHE_SECONDS = 5
local found = nil
local foundFor = nil
local foundAt = 0

local quiet = false -- whether "a cutscene is running" has already been said for this level
local lastSummary = nil -- what the last sweep found, so an unchanged one is not logged again

-- Whether a class is Spyro_IGC_Base_C or descends from it. Reading a property off an actor that does
-- not have one does NOT come back nil in this UE4SS build (every actor in LS321 answered SkipCheck), so
-- the class chain is the only honest test. Answers are cached per class, not per actor.
local isBase = {}

local function derivesFromBase(object)
    local class
    if not pcall(function() class = object:GetClass() end) or not class then return false end
    local key
    if not pcall(function() key = class:GetAddress() end) then return false end
    if isBase[key] ~= nil then return isBase[key] end
    local answer, at = false, class
    for _ = 1, 16 do
        if not at then break end
        local name
        if not pcall(function() name = at:GetFName():ToString() end) then break end
        if name == "Spyro_IGC_Base_C" then answer = true; break end
        -- Belt and braces while the chain walk is new: a class whose own name says IGC counts too, so a
        -- build where GetSuperStruct is unavailable still finds the level subclasses.
        if name and name:find("IGC") then answer = true; break end
        local super
        if not pcall(function() super = at:GetSuperStruct() end) then break end
        if not super or not super:IsValid() then break end
        at = super
    end
    isBase[key] = answer
    return answer
end

local function isActive(object)
    local ok, value = pcall(function() return object.CurrentlyActiveIGC end)
    return ok and value == true
end

-- Every actor that is a Spyro_IGC_Base subclass, whatever its own class is called.
local function instances(level)
    if found and foundFor == level and os.clock() - foundAt < CACHE_SECONDS then return found end
    local list = {}
    local ok, actors = pcall(FindAllOf, "Actor")
    if ok and actors then
        for _, actor in ipairs(actors) do
            local valid = false
            pcall(function() valid = actor:IsValid() end)
            if valid and derivesFromBase(actor) then
                list[#list + 1] = actor
            end
        end
        if foundFor ~= level then quiet = false end
        found, foundFor, foundAt = list, level, os.clock()
        local kinds, order = {}, {}
        for _, object in ipairs(list) do
            local name = "?"
            pcall(function() name = object:GetClass():GetFName():ToString() end)
            if not kinds[name] then kinds[name] = 0; order[#order + 1] = name end
            kinds[name] = kinds[name] + 1
        end
        local parts = {}
        for _, name in ipairs(order) do parts[#parts + 1] = string.format("%s x%d", name, kinds[name]) end
        -- Swept again every few seconds, so only say so when what is there has changed: a minigame
        -- streaming in is worth a line, the same three actors every stop is not.
        local summary = string.format("%d cinematic(s) in %s out of %d actors: %s", #list,
            tostring(level), #actors, #parts > 0 and table.concat(parts, ", ") or "none")
        if summary ~= lastSummary then
            lastSummary = summary
            log("igc: %s", summary)
        end
    end
    return list
end

-- Whether a cinematic is running right now: a conversation holds the camera and the input, and it keeps
-- holding them through a teleport, so the next stop is lost too. Cheap after the first call in a level.
function igc.active(level)
    for _, object in ipairs(instances(level)) do
        if isActive(object) then return true end
    end
    return false
end

-- The level has changed (or is about to), so the actors kept above are gone.
function igc.forget()
    found, foundFor, foundAt, quiet, lastSummary = nil, nil, 0, false, nil
end

-- Moves a running conversation along the way a player would: Continue on its text box (lib/dialogue.lua).
-- Called as often as convenient; the presses are spaced out there.
--
-- This used to end conversations from outside: SkipCheck, "Dialogue Complete", then EndIGC, followed by
-- resetting the controller's ignore flags and cinematic mode, and forcing game-only input. That is how
-- input went missing after a drop-in, and ending a conversation from outside skips what it was going to
-- start -- which, next to an NPC who runs a minigame, is the minigame. So it only presses the button now.
-- Returns 1 while a text box is up, 0 when there is none.
function igc.close(pc, pawn, level)
    if dialogue.advance() then return 1 end
    if not quiet and pawn and pawn:IsValid() and igc.active(level) then
        -- A cinematic with no text box is a cutscene: it ends on its own, so say so once and wait.
        quiet = true
        log("igc: a cinematic is running with no text box; waiting for it to end by itself")
    end
    return 0
end

return igc
