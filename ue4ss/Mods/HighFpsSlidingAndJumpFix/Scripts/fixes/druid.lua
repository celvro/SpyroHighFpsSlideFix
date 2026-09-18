-- Green druid Energize fix
--
-- The green druids (e.g. Alpine Ridge's stairs, door and walkway) move their mechanism from an
-- Energize anim notify in their cast montage. AM_CES1035_GreenDruid_Casting_Up is 0.5 s long and
-- starts blending out at 0.25 s; that ends the druid's cast state, and the next state's montage
-- interrupts it, so later notifies never fire. Its Energize notify sits at 0.25089 s, so it only
-- fires when one frame steps from before 0.25 to past 0.25089: always at 30 FPS (0.233 -> 0.267),
-- never at 60, 120 or 144 FPS, which land exactly on 0.25. The druid only switches between its up
-- and down casts inside that notify, so it then repeats the up cast forever and the mechanism
-- never moves again. This moves the notify to 0.24986 s, where the casting-down montage
-- (AM_..._Casting_Out) has its own, which fires at every framerate. At 30 FPS it fires on the same
-- frame as before. It only acts where the montage is loaded, i.e. on the levels with green druids.

local config = require("config")
local log = require("lib.log")
local lookup = require("lib.lookup")

local DRUID_MONTAGE = "/CES1035_GreenDruid/Animations/Montages/AM_CES1035_GreenDruid_Casting_Up.AM_CES1035_GreenDruid_Casting_Up"
local DRUID_NOTIFY_TIME = 0.25089103       -- the montage's Energize notify time (skip the fix if the asset differs)
local DRUID_FIXED_NOTIFY_TIME = 0.24986279 -- AM_CES1035_GreenDruid_Casting_Out's Energize notify time

local fix = {
    name = "druid Energize fix",
    enabled = config.FIX_DRUID_ENERGIZE,
    retryIn = 0, lookups = 1, -- lookup bookkeeping (see lib/lookup.lua)
}

-- Moves the druid montage's Energize notify (see the header). Notify extraction reads the trigger
-- time live as the notify's time (LinkValue) plus TriggerTimeOffset, so only the offset changes.
-- Returns the new trigger time, or nil if this montage object is already patched.
local function patchDruidMontage(montage)
    local notifies = montage.Notifies
    for i = 1, notifies:GetArrayNum() do
        local notify = notifies[i]
        if notify.NotifyName:ToString() == "Energize" then
            local time = notify.LinkValue
            if math.abs(time - DRUID_NOTIFY_TIME) > 1e-4 then
                error(string.format("unexpected Energize notify time %.5f", time))
            end
            local offset = DRUID_FIXED_NOTIFY_TIME - time
            if math.abs(notify.TriggerTimeOffset - offset) < 1e-6 then return nil end
            notify.TriggerTimeOffset = offset
            local triggerTime = time + notify.TriggerTimeOffset -- read back
            if math.abs(triggerTime - DRUID_FIXED_NOTIFY_TIME) > 1e-6 then
                error(string.format("TriggerTimeOffset write didn't stick (trigger time %.5f)", triggerTime))
            end
            return triggerTime
        end
    end
    error("no Energize notify")
end

-- Only the druid levels' own assets reference the montage (LS113, LS114, LS115, LS118), so it is
-- looked up once it is created (see lookup.watch), each time one of those levels loads.
function fix.update()
    local montage = lookup.find(fix, DRUID_MONTAGE)
    if not montage then return end
    -- Created but not loaded yet: try again later (found lookups don't hitch).
    if montage.Notifies:GetArrayNum() == 0 then fix.lookups = math.max(fix.lookups, 1) return end
    fix.lookups = 0
    local triggerTime = patchDruidMontage(montage)
    if triggerTime then log("druid Energize notify moved to %.5f s", triggerTime) end
end

if fix.enabled then
    lookup.watch("/Script/Engine.AnimMontage", "AM_CES1035_GreenDruid_Casting_Up", fix)
end

return fix
