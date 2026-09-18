-- Constants and small helpers shared by several fixes.

local util = {}

util.MIN_TICK_TIME = 1e-6   -- the engine's own "did any time pass" threshold (UE 4.19 movement code)
util.REFERENCE_FPS = 30     -- the framerate the game was tuned at; every fix reproduces its behaviour
util.REFERENCE_DT = 1 / 30
util.MOVE_WALKING = 1       -- EMovementMode values we care about
util.MOVE_FALLING = 3

-- True while a frame is shorter than a 30 FPS frame, i.e. while there is anything to fix. Frames
-- that are 1/30 s or longer (and the odd zero-length one) are left exactly as the game runs them.
function util.aboveReferenceFps(dt)
    return dt >= util.MIN_TICK_TIME and dt < util.REFERENCE_DT - 1e-4
end

-- An angle difference folded into (-180, 180].
function util.wrapDegrees(a)
    a = a % 360
    if a > 180 then a = a - 360 end
    return a
end

return util
