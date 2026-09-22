-- Getting control back when an in-game cinematic has taken it, which is what a conversation with an NPC
-- does, and what a save fairy does.
--
-- Talking to an NPC plays an in-game cinematic, and while it runs the game takes input away. A scripted
-- tour that walks into an NPC therefore loses not just that stop but every stop after it, because nothing
-- in the tour's own inputs closes one: the skip is a button HELD (Spyro_IGC_Base has SkipCheck and
-- StartSkipTimer), and holding each face button for a second and a half failed 29 times in 32. Worse, a
-- tour that ENDS in one leaves the game sitting in a text box for as long as nobody is watching.
--
-- Loading the level again does clear it, at about twelve seconds a time. This is the cheaper way. From
-- the disassembly of Spyro_IGC_Base's ubergraph:
--
--     956: this.SkipCheck = true
--     968: if not (this.SkipCheck) goto 997
--     982: Dialogue Complete()
--
-- so setting SkipCheck makes it finish itself on its next 0.05 s tick, which is what the skip button
-- would have done, and "Dialogue Complete" is the same step called outright.
--
-- Finding the running one is the part that took two tries. FindAllOf matches a class name exactly, and
-- no instance is ever a plain Spyro_IGC_Base_C: every one is of the level's own subclass (LS321 has
-- BP_LS321_IGCBoxing_C), and a save fairy is a Spyro_IGC_SavePoint0_C. Listing the names that exist and
-- adding them here would only ever cover the levels already looked at, so instead every actor is asked
-- whether it HAS SkipCheck. Only a Spyro_IGC_Base subclass does, whatever it calls itself.
--
--   "igc" lines  what was found, what was set, and what was still active afterwards
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
local tries = {} -- address -> how many times close() has asked this one to finish
local quiet = false -- whether "nothing is running" has already been said for this level
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
    found, foundFor, foundAt, tries, quiet, lastSummary = nil, nil, 0, {}, false, nil
end

-- Whatever is holding him, let go. The controller gates are released first because they are cheap and
-- cost nothing when they were never raised; then each cinematic that says it is running is told to
-- finish. A second attempt on the same one escalates from the skip to EndIGC, which is what the
-- cinematic calls on itself when it is done.
-- Returns how many cinematics were asked to finish.
-- `takeInput` forces the controller back to game-only input. That is a blunt thing to do: it clears
-- whatever widget had focus, and a text box that has not opened yet may be expecting to take it. So it
-- is NOT done on the automatic paths -- only F3, where somebody has looked at a dead pad and asked.
function igc.close(pc, pawn, level, takeInput)
    if pc and pc:IsValid() then
        pcall(function() pc:ResetIgnoreMoveInput() end)
        pcall(function() pc:ResetIgnoreLookInput() end)
        -- SetCinematicMode(inCinematicMode, hidePlayer, affectsHUD, affectsMovement, affectsTurning)
        pcall(function() pc:SetCinematicMode(false, false, false, true, true) end)
        -- A text box that took focus for itself leaves the controller in UI-only mode, where the pad
        -- goes to a widget that is no longer on the screen and the game gets nothing -- which looks
        -- exactly like input being dead while IsMoveInputIgnored says false and no cinematic reports
        -- itself running. Taking input back fixes that, and costs any widget that WANTED focus its
        -- focus, so it is only done when asked for.
        if takeInput then
            -- Game only, which is what gameplay wants: it captures the mouse. GameAndUI was tried in
            -- its place to be gentler on widgets and is wrong here -- without capture, mouse look only
            -- works while a button is held down, which is exactly what it looked like.
            local restored = pcall(function()
                local umg = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
                umg:SetInputMode_GameOnly(pc)
            end)
            log("igc: input mode set back to game only (%s)", restored and "ok" or "failed")
            pcall(function() pc.bShowMouseCursor = false end)
        end
    end
    local asked = 0
    for _, object in ipairs(instances(level)) do
        if isActive(object) then
            local address = object:GetAddress()
            tries[address] = (tries[address] or 0) + 1
            local name = "?"
            pcall(function() name = object:GetFullName() end)
            pcall(function() object.SkipCheck = true end)
            if tries[address] == 1 then
                pcall(function() object["Dialogue Complete"](object) end)
                log("igc: %s is running; skipped it", name)
            else
                pcall(function() object["EndIGC"](object, object) end)
                log("igc: %s is still running after %d tries; ended it", name, tries[address])
            end
            asked = asked + 1
        end
    end
    if asked == 0 and not quiet and pawn and pawn:IsValid() then
        -- Nothing said it was running, so if he still cannot move it is not a conversation. Said once
        -- per level: close() is called at the end of every stop, and a line each would drown the log.
        quiet = true
        local ignored
        pcall(function() ignored = pawn:IsMoveInputIgnored() end)
        log("igc: nothing is running (pawn IsMoveInputIgnored = %s)", tostring(ignored))
    end
    return asked
end

return igc
