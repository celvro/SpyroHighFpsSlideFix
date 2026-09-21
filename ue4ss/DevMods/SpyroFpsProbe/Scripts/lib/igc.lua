-- Getting control back when an in-game cinematic has taken it, which is what a conversation with an NPC
-- does.
--
-- Talking to an NPC plays a Spyro_IGC_Dialogue, and while it runs the game takes input away. A scripted
-- tour that walks into an NPC therefore loses not just that stop but every stop after it, because nothing
-- in the tour's own inputs closes one: the skip is a button HELD (Spyro_IGC_Base has SkipCheck and
-- StartSkipTimer), and holding each face button for a second and a half failed 29 times in 32.
--
-- Loading the level again does clear it, at about twelve seconds a time, and Spyro 3 spent most of its
-- run doing that. This is the cheaper way. From the disassembly of Spyro_IGC_Base's ubergraph:
--
--     956: this.SkipCheck = true
--     968: if not (this.SkipCheck) goto 997
--     982: Dialogue Complete()
--
-- so setting SkipCheck on the running cinematic makes it finish itself on its next 0.05 s tick, which is
-- what the skip button would have done. It is a property write rather than a call with arguments guessed
-- from a signature, which is why it is the one worth trying first.
--
--   "igc" lines  what was found and what was set, once per attempt
local log = require("lib.log")

local igc = {}

-- Every IGC is a Spyro_IGC_Base_C, but instances are of the level's own subclass, and UE4SS matches
-- FindAllOf by class name. Ask for the base first (some builds do match subclasses), then for the types
-- a conversation actually uses.
local CLASSES = {
    "Spyro_IGC_Base_C",
    "Spyro_IGC_Dialogue_C",
    "Spyro_IGC_Sequence_C",
    "Spyro_IGC_MissionStart_C",
}

local function instances()
    local found, seen = {}, {}
    for _, name in ipairs(CLASSES) do
        local ok, list = pcall(FindAllOf, name)
        if ok and list then
            for _, object in ipairs(list) do
                local valid = false
                pcall(function() valid = object:IsValid() end)
                if valid then
                    local address = object:GetAddress()
                    if not seen[address] then
                        seen[address] = true
                        found[#found + 1] = object
                    end
                end
            end
        end
    end
    return found
end

-- Whatever is holding him, let go. Three things are tried, cheapest first, because which one applies is
-- not knowable from outside: the cinematic is found by class name only if UE4SS matches the level's own
-- subclass, and a conversation takes input away through the player controller whether it is found or not.
-- Returns what was done, so a caller can fall back to reloading the level.
function igc.close(pc)
    local done = {}
    -- The controller's own input gates. A cinematic raises these and lowers them when it ends; if it
    -- never ends, lowering them by hand gives control back even though the cinematic is still there.
    if pc and pc:IsValid() then
        if pcall(function() pc:ResetIgnoreMoveInput() end) then done[#done + 1] = "move input" end
        if pcall(function() pc:ResetIgnoreLookInput() end) then done[#done + 1] = "look input" end
        -- SetCinematicMode(inCinematicMode, hidePlayer, affectsHUD, affectsMovement, affectsTurning)
        if pcall(function() pc:SetCinematicMode(false, false, false, true, true) end) then
            done[#done + 1] = "cinematic mode"
        end
    end
    local closed = 0
    for _, object in ipairs(instances()) do
        if pcall(function() object.SkipCheck = true end) then closed = closed + 1 end
    end
    if closed > 0 then done[#done + 1] = string.format("%d cinematic(s)", closed) end
    if #done > 0 then log("igc: released %s", table.concat(done, ", ")) end
    return #done
end

-- What is loaded right now, for working out whether the class names above are the right ones. Logged by
-- the first attempt in a run so a tour that never finds one says so instead of silently falling back.
function igc.report()
    local list = instances()
    log("igc: %d cinematic object(s) found", #list)
    for i, object in ipairs(list) do
        if i > 5 then break end
        local name = "?"
        pcall(function() name = object:GetFullName() end)
        log("igc:   %s", tostring(name))
    end
end

return igc
