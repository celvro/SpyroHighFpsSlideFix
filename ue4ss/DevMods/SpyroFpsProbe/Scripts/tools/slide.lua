-- Slide pose for screenshots (J): starts Spyro's steep-slope slide wherever he stands, and ends it
-- on the next press.
--
-- GA_Spyro_SlideDown triggers on the gameplay event Character.Event.SlideDown.Start and ends on
-- Character.Event.SlideDown.End (its AbilityActionDispatcher). While active it loops
-- AM_CPS1999_SlideDownLoop, spawns the charge dust trail and camera wind lines, and applies
-- GE_SpyroSlideDown; it owns the tag Character.MoveState.SlideDown, which this tool reads to decide
-- whether the press starts or ends the slide. It can't start while charging, swimming, climbing,
-- skateboarding or firing (the ability's BlockAbilitiesWithTag).
--
--   "slide" lines  the start/end request, then whether the tag appeared, and how long the slide
--                  lasted if something other than J ended it (e.g. the game's slope check on flat ground).
local log = require("lib.log")

local SLIDE_TAG = "Character.MoveState.SlideDown"
local START_EVENT = "Character.Event.SlideDown.Start"
local END_EVENT = "Character.Event.SlideDown.End"

local slide = {}

local requested = false
local active = nil -- { t0, confirmed } while a slide this tool started is running

function slide.request()
    requested = true
end

local function library()
    local lib = StaticFindObject("/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary")
    if not (lib and lib:IsValid()) then error("AbilitySystemBlueprintLibrary not found") end
    return lib
end

local function isSliding(pawn)
    local component = library():GetAbilitySystemComponent(pawn)
    if not (component and component:IsValid()) then error("no AbilitySystemComponent") end
    return component:HasMatchingGameplayTag({ TagName = FName(SLIDE_TAG) }) == true
end

local function sendEvent(pawn, name)
    local tag = { TagName = FName(name) }
    library():SendGameplayEventToActor(pawn, tag, { EventTag = tag, EventMagnitude = 0 })
end

local function step(pawn, r)
    if requested then
        requested = false
        if isSliding(pawn) then
            sendEvent(pawn, END_EVENT)
            active = nil
            log("slide: end requested")
        else
            sendEvent(pawn, START_EVENT)
            active = { t0 = r.time, confirmed = false }
            log("slide: start requested")
        end
        return
    end
    if not active then return end
    local sliding = isSliding(pawn)
    if not active.confirmed then
        active.confirmed = true
        if not sliding then
            active = nil
            log("slide: didn't start (blocked by the current move state?)")
        end
    elseif not sliding then
        log("slide: ended by the game after %.2f s", r.time - active.t0)
        active = nil
    end
end

function slide.update(pawn, r)
    if not (requested or active) then return end
    local ok, err = pcall(step, pawn, r)
    if not ok then
        active = nil
        log("slide error: %s", tostring(err))
    end
end

return slide
