-- Drives the probe's lib/igc.lua against stubbed modules and fake actors, so the thing that cost the
-- world tour every unattended run is checked without the game: a cinematic actor that the level freed
-- while igc.lua still held it must never be touched again.
--
-- The fake actors are the point. An actor marked `freed` records any access as a VIOLATION and then
-- raises. In the game that access is not a Lua error at all -- it is an access violation inside UE4SS.dll
-- that takes the process down, and the pcall around it catches nothing -- so the raise is only there to
-- make a failure loud. The assertion is that `violations` is empty: nothing asked a freed actor anything.
--
-- igc.lua is testable this way because it reaches the game through two globals (FindAllOf, FName) and two
-- modules (lib.dialogue, lib.log), all stubbed below.
--
--   lua tools\tests\igc_test.lua
--
-- Exits non-zero on a failure.
local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\]tools[/\\]tests[/\\]") or "."
package.path = here .. "\\ue4ss\\DevMods\\SpyroFpsProbe\\Scripts\\?.lua;" .. package.path

local violations = {}   -- every access made to an actor after it was freed
local logLines = {}
local dialogueUp = false
local clock = 0         -- os.clock stands still unless a test moves it

package.preload["lib.log"] = function()
    return function(fmt, ...)
        local line = string.format(fmt, ...)
        logLines[#logLines + 1] = line
        return line
    end
end
package.preload["lib.dialogue"] = function()
    return { advance = function() return dialogueUp end }
end

os.clock = function() return clock end

-- Fake classes, with a super chain the way the game's have: BP_LS201_IGC_C -> Spyro_IGC_Base_C -> Actor.
local nextAddress = 0x1000
local function address()
    nextAddress = nextAddress + 0x80
    return nextAddress
end

local function makeClass(name, super)
    local at = address()
    return {
        IsValid = function() return true end,
        GetAddress = function() return at end,
        GetFName = function() return { ToString = function() return name end } end,
        GetSuperStruct = function() return super end,
    }
end

local actorClass = makeClass("Actor", nil)
local igcBase = makeClass("Spyro_IGC_Base_C", actorClass)
local igcLevel = makeClass("BP_LS201_IGC_C", igcBase)       -- a level's own subclass, as the game has
local fairyClass = makeClass("Spyro_IGC_SavePoint0_C", igcBase)
local dragonClass = makeClass("Collectable_Dragon_C", actorClass)
local movieClass = makeClass("BP_SP3_CinematicActor_C", actorClass)
local sceneryClass = makeClass("BP_Rock_C", actorClass)

-- An actor that answers like a UObject wrapper and remembers how it was treated.
local function makeActor(name, class, props)
    local at = address()
    local actor = { name = name, freed = false, presses = 0 }
    local api = {}
    api.GetAddress = function() return at end
    api.GetClass = function() return class end
    api.GetFullName = function() return "x " .. name end
    -- The one skip event name that works on this class, as a cutscene actor binds it.
    api.InpActEvt_SkipCutscene_K2Node_InputActionEvent_0 = function(_, key)
        assert(key and key.KeyName, "the skip press must carry a key")
        actor.presses = actor.presses + 1
    end
    return setmetatable(actor, {
        __index = function(t, key)
            -- IsValid is the one question that is safe to ask a wrapper that has gone dead: UE4SS
            -- answers it from its own bookkeeping without dereferencing the pointer.
            if key == "IsValid" then return function() return not t.freed end end
            if t.freed then
                violations[#violations + 1] = string.format("%s was asked %q after it was freed",
                    t.name, tostring(key))
                error("ACCESS VIOLATION: " .. t.name .. "." .. tostring(key))
            end
            return api[key] or props[key]
        end,
    })
end

local world = { actors = {} }
FindAllOf = function(className)
    if className ~= "Actor" then return nil end
    local list = {}
    for _, a in ipairs(world.actors) do list[#list + 1] = a end
    return list
end
FName = function(name) return { KeyName = name } end

local igc = require("lib.igc")

local failures = 0
local function check(name, ok, detail)
    if ok then
        print("ok   " .. name)
    else
        failures = failures + 1
        print("FAIL " .. name .. (detail and ("  -- " .. detail) or ""))
    end
end

local function countLogged(pattern)
    local n = 0
    for _, line in ipairs(logLines) do if line:find(pattern) then n = n + 1 end end
    return n
end

local function untouched()
    return #violations == 0, violations[1]
end

local function reset(actors)
    world.actors = actors
    violations, logLines = {}, {}
    dialogueUp = false
    clock = 0
    igc.forget()
end

-- 1. The sweep finds cinematics by class chain, ignores scenery, and says nothing is running.
local idleTalker = makeActor("idleTalker", igcLevel, { CurrentlyActiveIGC = false })
local fairy = makeActor("fairy", fairyClass, { CurrentlyActiveIGC = false })
local rock = makeActor("rock", sceneryClass, {})
reset({ idleTalker, fairy, rock })
check("nothing running to start with", igc.active("LS201") == false)
check("the sweep logs what it found", countLogged("^igc: ") > 0)

-- 2. One of them starts talking.
local talker = makeActor("talker", igcLevel, { CurrentlyActiveIGC = true })
reset({ talker, fairy, rock })
check("a running cinematic is seen", igc.active("LS201") == true)

-- 3. THE REGRESSION. The level streams a sublevel out and frees the actor that was talking, while the
--    cache still holds it. Nothing may touch it, and the answer must be "nothing is running".
talker.freed = true
clock = 1.7 -- inside CACHE_SECONDS, so the cache is reused rather than re-swept
local stillActive = igc.active("LS201")
check("a freed cinematic is never touched", untouched())
check("a freed cinematic does not count as running", stillActive == false)
check("the drop is logged", countLogged("were freed since the sweep") == 1)

-- 4. It is dropped, not re-checked: more questions, still no touch, and the line is logged once.
clock = 2.0
igc.active("LS201")
clock = 2.1
igc.active("LS201")
check("a dropped cinematic stays dropped", untouched())
check("the drop line is logged once per sweep", countLogged("were freed since the sweep") == 1)

-- 5. A live one next to the freed one is still answered.
local liveFairy = makeActor("liveFairy", fairyClass, { CurrentlyActiveIGC = true })
local deadTalker = makeActor("deadTalker", igcLevel, { CurrentlyActiveIGC = true })
reset({ deadTalker, liveFairy, rock })
check("both are found", igc.active("LS201") == true)
deadTalker.freed = true
clock = 1.0
check("a live cinematic is still seen with a freed one beside it", igc.active("LS201") == true)
check("and the freed one was not touched", untouched())

-- 6. The skip press goes to the live one only.
clock = 2.0
igc.close(nil, nil, "LS201")
check("the skip press reached the live cinematic", liveFairy.presses == 1,
    "presses=" .. tostring(liveFairy.presses))
check("no press reached the freed one", untouched())

-- 7. An actor already freed when the sweep runs is not added to the list at all.
local bornDead = makeActor("bornDead", igcLevel, { CurrentlyActiveIGC = true })
bornDead.freed = true
reset({ bornDead, rock })
check("an actor freed before the sweep is skipped", igc.active("LS201") == false)
check("and it was not touched during the sweep", untouched())

-- 8. Kinds: a Spyro 1 dragon statue reads CutsceneActive, a Spyro 3 movie reads Started/Finished.
local dragonProps = { CutsceneActive = true, CurrentlyActiveIGC = false }
local dragon = makeActor("dragon", dragonClass, dragonProps)
reset({ dragon })
check("a dragon statue's cutscene is seen through CutsceneActive", igc.active("LS101") == true)
dragonProps.CutsceneActive = false
check("and it stops when CutsceneActive clears", igc.active("LS101") == false)

local movieProps = { Started = true, Finished = false, CurrentlyActiveIGC = false }
local movie = makeActor("movie", movieClass, movieProps)
reset({ movie })
check("a started movie counts as running", igc.active("LS301") == true)
movieProps.Finished = true
check("a finished movie does not", igc.active("LS301") == false)

-- 9. A new level sweeps again rather than answering from the last level's actors.
local other = makeActor("other", igcLevel, { CurrentlyActiveIGC = true })
reset({ other })
check("the new level's cinematic is found", igc.active("LS202") == true)
world.actors = {}
check("the same level still answers from the cache", igc.active("LS202") == true)
check("a different level sweeps again and finds nothing", igc.active("LS203") == false)

-- 10. The cache expires after CACHE_SECONDS, so a cinematic that loaded after the sweep is found.
reset({})
check("nothing in the level yet", igc.active("LS204") == false)
world.actors = { other }
check("still nothing while the sweep is fresh", igc.active("LS204") == false)
clock = 6 -- past CACHE_SECONDS
check("the expired cache is swept again", igc.active("LS204") == true)

-- 11. forget() drops the cache even inside CACHE_SECONDS.
reset({ other })
check("found before forget", igc.active("LS202") == true)
world.actors = {}
igc.forget()
check("forget re-sweeps", igc.active("LS202") == false)

-- 12. A text box takes priority over the actor sweep: igc.close returns at once.
reset({ liveFairy })
liveFairy.presses = 0
dialogueUp = true
check("igc.close presses Continue on a text box and stops there", igc.close(nil, nil, "LS201") == 1)
check("and sends no skip button", liveFairy.presses == 0)

print("")
if failures > 0 then
    print(string.format("%d check(s) failed", failures))
    os.exit(1)
end
print("all checks passed")
