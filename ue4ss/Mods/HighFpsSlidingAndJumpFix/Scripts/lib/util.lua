-- Constants and small helpers shared by several fixes.

local util = {}

util.MIN_TICK_TIME = 1e-6   -- the engine's own "did any time pass" threshold (UE 4.19 movement code)
util.REFERENCE_FPS = 30     -- the framerate the game was tuned at; every fix reproduces its behaviour
util.REFERENCE_DT = 1 / 30
util.MOVE_WALKING = 1       -- EMovementMode values we care about
util.MOVE_NAV_WALKING = 2   -- AI walking on the navmesh (Buzz's ChargeRun)
util.MOVE_FALLING = 3
-- Charging sets MaxWalkSpeed 458.5 and charge jumping 358; running is 268.5. A float property read
-- costs nothing, so this is the cheap "might be charging" test the charge and dust fixes gate on
-- before they read anything that allocates.
util.CHARGE_MIN_WALK_SPEED = 350

-- True while a frame is shorter than a 30 FPS frame, i.e. while there is anything to fix. Frames
-- that are 1/30 s or longer (and the odd zero-length one) are left exactly as the game runs them.
function util.aboveReferenceFps(dt)
    return dt >= util.MIN_TICK_TIME and dt < util.REFERENCE_DT - 1e-4
end

-- A sweep's FHitResult out-param table, emptied for its next use. Pass every `K2_Set*`/`K2_Add*`
-- sweep result through this, even when nothing reads it.
--
-- UE4SS copies a struct out-param back into the very table it was handed (push_structproperty's
-- GetNonTrivialLocal with create_new false), so a table reused between calls comes back holding all
-- 18 of FHitResult's fields -- among them its three TWeakObjectPtr members, PhysMaterial, Actor and
-- Component. Handing those back in on the next call reaches push_weakobjectproperty's Operation::Set,
-- which is unsupported and only logs "Operation::Set is not supported": three synchronous log writes
-- (file plus console, measured at 0.122 ms each) on the game thread, per call, forever. An empty
-- table is skipped field by field instead, which also spares the table-to-struct conversion of the
-- fields the engine is about to overwrite anyway.
function util.clearHit(hit)
    for k in next, hit do hit[k] = nil end
    return hit
end

-- An angle difference folded into (-180, 180].
function util.wrapDegrees(a)
    a = a % 360
    if a > 180 then a = a - 360 end
    return a
end

return util
