-- Knowing when an in-game cinematic is running, which is what a conversation with an NPC is, what a save
-- fairy is and what a cutscene is, and moving it along the way a player does.
--
-- Talking to an NPC plays an in-game cinematic, and while it runs the game has the camera and the input.
-- A scripted tour must not teleport out of one (it keeps hold of him wherever he lands, so the next stop
-- is lost too) and must not end on one (the game sits in a text box for as long as nobody is watching).
-- So the tour waits for it, pressing Continue on its text box (lib/dialogue.lua), or the skip button on
-- a cutscene, until it closes by itself. Nothing here ends a cinematic from outside or touches input or
-- the HUD: see igc.close.
--
-- Finding the running one: FindAllOf matches a class name exactly, and no instance is ever a plain
-- Spyro_IGC_Base_C: every one is of the level's own subclass (LS321 has BP_LS321_IGCBoxing_C), and a
-- save fairy is a Spyro_IGC_SavePoint0_C. Listing the names would only ever cover the levels already
-- looked at, so each actor's class chain is walked for Spyro_IGC_Base_C instead (and Collectable_Dragon_C,
-- Spyro 1's dragon statues). CurrentlyActiveIGC (CutsceneActive for a dragon) says whether it is running.
--
--   "igc" lines  what cinematics a level has, each skip pressed, and a cutscene being waited out
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
-- The skip button (pressSkip, below).
local SKIP_KEY = "Gamepad_FaceButton_Top"
local SKIP_AGAIN = 2.0 -- seconds between presses on a cutscene that is still playing
local skipName = {}    -- class address -> the event name, or false when the class has none
local skippedAt = {}   -- actor address -> os.clock() of the last press
local skipKey = nil

-- What kind of cinematic a class is: "igc" for Spyro_IGC_Base_C and everything under it, "dragon" for a
-- Spyro 1 dragon statue (Collectable_Dragon_C, which runs its own release cutscene), false otherwise.
-- Reading a property off an actor that does not have one does NOT come back nil in this UE4SS build
-- (every actor in LS321 answered SkipCheck), so the class chain is the only honest test. Answers are
-- cached per class, not per actor.
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
        if name == "Collectable_Dragon_C" then answer = "dragon"; break end
        if name == "SP3_CinematicsActor" or name == "BP_SP3_CinematicActor_C" then answer = "movie"; break end
        if name == "Spyro_IGC_Base_C" then answer = "igc"; break end
        -- Belt and braces while the chain walk is new: a class whose own name says IGC counts too, so a
        -- build where GetSuperStruct is unavailable still finds the level subclasses.
        if name and name:find("IGC") then answer = "igc"; break end
        local super
        if not pcall(function() super = at:GetSuperStruct() end) then break end
        if not super or not super:IsValid() then break end
        at = super
    end
    isBase[key] = answer
    return answer
end

local function isActive(object)
    local kind = derivesFromBase(object)
    local ok, value = pcall(function()
        if kind == "dragon" then return object.CutsceneActive end
        if kind == "movie" then return object.Started == true and object.Finished ~= true end
        return object.CurrentlyActiveIGC
    end)
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
    skippedAt = {}
end

-- The skip button. A cutscene that can be skipped binds the SkipCutscene input action (DefaultInput.ini:
-- Gamepad_FaceButton_Top, SpaceBar, LeftMouseButton) as an event on its own actor, which the engine
-- calls on the press while the cutscene has input enabled:
--
--   Spyro_IGC_Sequence (every level's sequence cutscenes): DisableInput, then FadeOutControl to its end.
--                      No check of its own that it is playing, so it is only pressed while
--                      CurrentlyActiveIGC says so.
--   Collectable_Dragon (Spyro 1's dragons): checks CutsceneActive, "Bypass Available" and DontSkipIGC
--                      itself, then stops its level sequence. Bypass only becomes available a moment in,
--                      so it is pressed again every SKIP_AGAIN seconds while it plays.
--   BP_SP3_CinematicActor (Spyro 3's movie cutscenes, native SP3_CinematicsActor): skips when Started
--                      and not Special; it is only pressed between Started and Finished, because the skip
--                      also ends its mission and must not run again after the movie is over.
--
-- The event is InpActEvt_SkipCutscene_K2Node_InputActionEvent_<n>, n differing per class, so the name
-- that works is found once per class. The transporters bind it too, to end a travel "mission"; the tour
-- never rides one, so they are not looked for.
local function pressSkip(object)
    local address = object:GetAddress()
    if skippedAt[address] and os.clock() - skippedAt[address] < SKIP_AGAIN then return true end
    local classKey = object:GetClass():GetAddress()
    if skipName[classKey] == false then return false end
    skipKey = skipKey or { KeyName = FName(SKIP_KEY) }
    local names = skipName[classKey] and { skipName[classKey] } or {}
    if #names == 0 then
        for n = 0, 3 do names[#names + 1] = "InpActEvt_SkipCutscene_K2Node_InputActionEvent_" .. n end
    end
    for _, name in ipairs(names) do
        local ok = pcall(function() object[name](object, skipKey) end)
        if ok then
            skipName[classKey], skippedAt[address] = name, os.clock()
            local who = "?"
            pcall(function() who = object:GetClass():GetFName():ToString() end)
            log("igc: pressed skip on %s", who)
            return true
        end
    end
    skipName[classKey] = false
    return false
end

-- Moves a running conversation or cutscene along the way a player would: Continue on its text box
-- (lib/dialogue.lua), or the skip button on a cutscene with no text box (pressSkip). Called as often as
-- convenient; the presses are spaced out.
--
-- This used to end conversations from outside: SkipCheck, "Dialogue Complete", then EndIGC, followed by
-- resetting the controller's ignore flags and cinematic mode, and forcing game-only input. That is how
-- input went missing after a drop-in, and ending a conversation from outside skips what it was going to
-- start -- which, next to an NPC who runs a minigame, is the minigame. So it only presses buttons now.
-- Returns 1 while a text box or a cutscene is up, 0 when there is neither.
function igc.close(pc, pawn, level)
    if dialogue.advance() then return 1 end
    local running, pressed = false, false
    for _, object in ipairs(instances(level)) do
        if isActive(object) then
            running = true
            local ok, did = pcall(pressSkip, object)
            pressed = pressed or (ok and did)
        end
    end
    if running and not pressed and not quiet then
        -- Running, with no text box and nothing that takes the skip button: it ends on its own.
        quiet = true
        log("igc: a cinematic is running that has no skip; waiting for it to end by itself")
    end
    return running and 1 or 0
end

return igc
