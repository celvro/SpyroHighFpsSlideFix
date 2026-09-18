-- The raw mouse/right-stick X argument of InputAxis_RightStick_X (the trace's mouse_raw), recorded
-- by the probe's own hook before the fix mod can replace the stored value (stick_rx).
local log = require("lib.log")

local MOUSE_AXIS_FUNCTION = "/CharacterCommon/Components/CharacterInputComponent/CharacterInputComponent_Spyro.CharacterInputComponent_Spyro_C:InputAxis_RightStick_X"
local HOOK_RETRY_FRAMES = 60

local mouse = { raw = 0 / 0 } -- raw: the last InputAxis_RightStick_X argument
local registered, failed, retryIn = false, false, 0

-- The input Blueprint loads after the mods, so keep looking for it.
function mouse.register()
    if registered or failed then return end
    if retryIn > 0 then
        retryIn = retryIn - 1
        return
    end
    retryIn = HOOK_RETRY_FRAMES
    local fn = StaticFindObject(MOUSE_AXIS_FUNCTION)
    if not (fn and fn:IsValid()) then return end
    local ok, err = pcall(RegisterHook, MOUSE_AXIS_FUNCTION, function(context, axisValue)
        local okGet, raw = pcall(function() return axisValue:get() end)
        if okGet and type(raw) == "number" then mouse.raw = raw end
    end)
    if ok then
        registered = true
        log("mouse axis hook registered")
    else
        failed = true
        log("mouse axis hook unavailable: %s", tostring(err))
    end
end

return mouse
