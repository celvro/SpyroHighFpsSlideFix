-- The frame state the trackers share: the row that was sampled last, and the measurement each
-- tracker currently has in progress (the trace's id columns come from these). Everything that only
-- one tracker touches lives in that tracker instead.
return {
    fpsCap = nil,        -- last t.MaxFPS set with F5-F8, for the log lines
    lastTime = nil,      -- game time of the last sample, to skip paused and repeated frames
    prevRow = nil,       -- the previous frame's row
    recent = {},         -- last RECENT_FRAMES rows, oldest first
    pawnAddress = nil,   -- to notice a new pawn (level load, respawn)
    simStepChecked = false,
    errorLogged = false,

    segment = nil, segmentCount = 0,           -- trackers/movement.lua
    drift = nil, driftCount = 0,
    rise = nil, riseCount = 0,
    charge = nil, chargeCount = 0,             -- trackers/charge.lua
    turn = nil,
    camLock = nil,                             -- trackers/camera.lua
    camTransition = nil, camTransitionCount = 0,
    superCharge = nil, superChargeCount = 0,   -- trackers/supercharge.lua
    glide = nil,                               -- trackers/glide.lua (the glide in progress, for the trace)
}
