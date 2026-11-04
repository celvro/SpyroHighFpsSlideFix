-- The blocking hits of every enemy's own moves, from one hook.
--
-- BP_Base_Enemy binds a single function to its CapsuleComponent's OnComponentHit, so every enemy that
-- derives from it reports its hits through that one function. Trackers subscribe by class name and are
-- handed the hits of their own actors, which keeps one RegisterHook for the function however many
-- trackers want hits (registering the same Blueprint function twice is not worth finding out about).
--
-- The engine calls it for the step-up and slide sweeps too, which is what tells a blocked climb or a
-- bounce from an actor that never tried to move.
local log = require("lib.log")

local HIT_FUNCTION = "/CharacterCommon/BaseClasses/BP_Base_Enemy.BP_Base_Enemy_C:"
    .. "BndEvt__CapsuleComponent_K2Node_ComponentBoundEvent_3_ComponentHitSignature__DelegateSignature"
local HOOK_RETRY_FRAMES = 60

local enemyhits = {}

local handlers = {}  -- class name -> function(actor, hit)
local registered, hookFailed, retryIn = false, false, 0
local errorLogged = false

local function num(v)
    return type(v) == "number" and v or 0 / 0
end

local function vec(v)
    return { num(v.X), num(v.Y), num(v.Z) }
end

local function className(object)
    local ok, s = pcall(function() return object:GetClass():GetFName():ToString() end)
    return ok and s or "?"
end

local function actorName(object)
    local ok, s = pcall(function() return object:GetFName():ToString() end)
    return ok and s or "?"
end

-- Params: HitComponent, OtherActor, OtherComp, NormalImpulse, Hit.
local function onHit(context, hitComp, otherActor, otherComp, normalImpulse, hit)
    local actor = context:get()
    if not (actor and actor:IsValid()) then return end
    local handler = handlers[className(actor)]
    if not handler then return end
    local h = hit:get()
    local other, comp = otherActor:get(), otherComp:get()
    handler(actor, {
        other = (other and other:IsValid()) and actorName(other) or "none",
        comp = (comp and comp:IsValid()) and actorName(comp) or "none",
        normal = vec(h.Normal), impactNormal = vec(h.ImpactNormal), impactPoint = vec(h.ImpactPoint),
        location = vec(h.Location), traceStart = vec(h.TraceStart), traceEnd = vec(h.TraceEnd),
        time = num(h.Time), startPenetrating = h.bStartPenetrating, penetration = num(h.PenetrationDepth),
    })
end

-- A Blueprint hook here fires the pre callback only, but it is registered as both (CLAUDE.md), so each
-- tracker drops a repeat of the hit it just stored. Same test for all of them, so the hits of two
-- trackers can be compared.
function enemyhits.sameHit(a, b)
    return a ~= nil and b ~= nil and a.time == b.time
        and a.impactPoint[1] == b.impactPoint[1] and a.impactPoint[2] == b.impactPoint[2]
        and a.impactPoint[3] == b.impactPoint[3]
end

function enemyhits.subscribe(class, handler)
    handlers[class] = handler
end

-- Called by a subscriber once one of its actors exists, so the function name is never looked up while it
-- cannot be there (a StaticFindObject miss scans the whole object array, ~10 ms).
function enemyhits.register()
    if registered or hookFailed then return end
    if retryIn > 0 then
        retryIn = retryIn - 1
        return
    end
    retryIn = HOOK_RETRY_FRAMES
    local fn = StaticFindObject(HIT_FUNCTION)
    if not (fn and fn:IsValid()) then return end -- no enemies loaded yet
    local function guarded(...)
        local ok, err = pcall(onHit, ...)
        if not ok and not errorLogged then
            errorLogged = true
            log("enemy hit hook error: %s", tostring(err))
        end
    end
    local ok, err = pcall(RegisterHook, HIT_FUNCTION, guarded, guarded)
    if ok then
        registered = true
        log("enemy capsule hit hook registered")
    else
        hookFailed = true
        log("enemy capsule hit hook unavailable: %s", tostring(err))
    end
end

return enemyhits
