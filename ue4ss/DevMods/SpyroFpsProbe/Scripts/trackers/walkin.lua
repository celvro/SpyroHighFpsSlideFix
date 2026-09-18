-- Freed dragon walk-in (Collectable_Dragon): SimpleMoveToLocation walks Spyro to `Walk to Target Point`,
-- Delay 1 s, then while he's < 50 away (3D) StopMovement and the turn montage (after 0.2 s); otherwise it
-- re-checks every 0.25 s. Its Level Sequence plays alongside and later hides and teleports him.
--
--   "walkin" lines  one per path following move: timing from the move request, the walk, the wait after
--                   arrival, how it ended (turn, teleport, input, timeout), frame hitches, and the sequence
--                   position at each step.
local log = require("lib.log")
local state = require("lib.state")

local WALKIN_TURN_RATE = 30   -- deg/s of yaw change while standing that counts as the turn starting
local WALKIN_TELEPORT = 50    -- units moved in one frame that count as the cutscene teleport
local WALKIN_TIMEOUT = 5      -- seconds after arrival before giving up on a turn or teleport
local WALKIN_HITCH = 0.05     -- frames longer than this count as hitches

local walkin = {}

local path = { component = nil, class = nil } -- the controller's PathFollowingComponent
local event = nil
local count = 0
local errorLogged = false

local function pathMoveActive(pc, cmc)
    local request = cmc.RequestedVelocity
    if request.X == 0 and request.Y == 0 and request.Z == 0 then return false end
    if not (path.component and path.component:IsValid()) then
        path.class = path.class or StaticFindObject("/Script/AIModule.PathFollowingComponent")
        local component = pc:GetComponentByClass(path.class)
        path.component = (component and component:IsValid()) and component or nil
    end
    -- EPathFollowingAction: 0 Error, 1 NoMove (idle), 2 DirectMove, 3 PartialPath, 4 PathToGoal.
    return path.component ~= nil and path.component:GetPathActionType() >= 2
end

-- The Collectable_Dragon running its walk-in (CutsceneActive), nearest to Spyro. FindAllOf scans the object
-- array, so this only runs once per walk-in.
local function findWalkinDragon(r)
    local best, bestDist
    for _, dragon in ipairs(FindAllOf("Collectable_Dragon_C") or {}) do
        if dragon:IsValid() and dragon.CutsceneActive then
            local loc = dragon:K2_GetActorLocation()
            local d = (loc.X - r.x) ^ 2 + (loc.Y - r.y) ^ 2
            if not bestDist or d < bestDist then best, bestDist = dragon, d end
        end
    end
    return best
end

local function walkinTarget(e)
    local target = e.dragon and e.dragon:IsValid() and e.dragon["Walk to Target Point"]
    return (target and target:IsValid()) and target:K2_GetActorLocation() or nil
end

local function sequencePosition(e)
    local ok, pos = pcall(function() return e.dragon.Level_Sequence.SequencePlayer:GetPlaybackPosition() end)
    return ok and type(pos) == "number" and pos or 0 / 0
end

local function finish(e, endedBy, r)
    local target = e.target
    local function dist(x, y, z)
        if not target or not x then return "n/a", "n/a" end
        return string.format("%.1f", math.sqrt((x - target.X) ^ 2 + (y - target.Y) ^ 2 + (z - target.Z) ^ 2)),
            string.format("%.1f", math.sqrt((x - target.X) ^ 2 + (y - target.Y) ^ 2))
    end
    local start3, start2 = dist(e.startX, e.startY, e.startZ)
    local arrive3, arrive2 = dist(e.arriveX, e.arriveY, e.arriveZ)
    local function since(t) return t and string.format("%.3f", t - e.start) or "n/a" end
    log("walkin %d cap=%s avgFps=%.1f maxDt=%.1fms hitches=%d (%.3fs) dragon=%s startDist=%s (2D %s) moveAt=%s arriveAt=%s walked=%.1f maxSpeed=%.1f stalledFrames=%d reissued=%d arriveDist=%s (2D %s) wait=%s endedBy=%s at=%s seqPos start=%.3f arrive=%.3f end=%.3f",
        count, tostring(state.fpsCap or "?"), e.frames / math.max(e.dtSum, 1e-9), e.maxDt * 1000,
        e.hitches, e.hitchTime, e.dragonName or "?", start3, start2, since(e.moveAt), since(e.arriveAt), e.walked, e.maxSpeed,
        e.stalledFrames, e.restarts or 0, arrive3, arrive2, e.arriveAt and string.format("%.3f", r.time - e.arriveAt) or "n/a",
        endedBy, since(r.time), e.seqStart, e.seqArrive or 0 / 0, sequencePosition(e))
    event = nil
end

local function update(pc, cmc, r, prev)
    local active = pathMoveActive(pc, cmc)
    local e = event
    if not e then
        if not active then return end
        count = count + 1
        e = { start = r.time, startX = r.x, startY = r.y, startZ = r.z, frames = 0, dtSum = 0, maxDt = 0, hitches = 0,
              hitchTime = 0, walked = 0, maxSpeed = 0, stalledFrames = 0 }
        local ok, dragon = pcall(findWalkinDragon, r)
        if ok and dragon then
            e.dragon, e.dragonName = dragon, dragon:GetFName():ToString()
            local okTarget, target = pcall(walkinTarget, e)
            e.target = okTarget and target and { X = target.X, Y = target.Y, Z = target.Z } or nil
        elseif not ok then
            log("walkin dragon lookup error: %s", tostring(dragon))
        end
        e.seqStart = sequencePosition(e)
        event = e
        log("walkin %d path move started", count)
        return
    end
    e.frames, e.dtSum, e.maxDt = e.frames + 1, e.dtSum + r.dt, math.max(e.maxDt, r.dt)
    if r.dt > WALKIN_HITCH then e.hitches, e.hitchTime = e.hitches + 1, e.hitchTime + r.dt end
    local step = prev and math.sqrt((r.x - prev.x) ^ 2 + (r.y - prev.y) ^ 2 + (r.z - prev.z) ^ 2) or 0
    if step > WALKIN_TELEPORT then return finish(e, "teleport", r) end
    if active then
        e.walked = e.walked + step
        e.maxSpeed = math.max(e.maxSpeed, r.speed)
        if r.speed > 1 and not e.moveAt then e.moveAt = r.time end
        if r.speed == 0 then e.stalledFrames = e.stalledFrames + 1 end
        if e.arriveAt then
            -- The Blueprint re-issues the move every 0.25 s while he's still >= 50 away.
            e.arriveAt, e.arriveX, e.seqArrive = nil, nil, nil
            e.restarts = (e.restarts or 0) + 1
        end
        return
    end
    if not e.arriveAt then
        e.arriveAt, e.arriveX, e.arriveY, e.arriveZ = r.time, r.x, r.y, r.z
        e.seqArrive = sequencePosition(e)
        log("walkin %d path move ended after %.3fs", count, r.time - e.start)
        return
    end
    if math.abs(r.accelX) + math.abs(r.accelY) > 1e-3 then return finish(e, "input", r) end
    if r.speed < 1 and math.abs(r.yawRate) > WALKIN_TURN_RATE then return finish(e, "turn", r) end
    if r.time - e.arriveAt > WALKIN_TIMEOUT then return finish(e, "timeout", r) end
end

function walkin.update(pc, cmc, r, prev)
    local ok, err = pcall(update, pc, cmc, r, prev)
    if not ok then
        event = nil
        if not errorLogged then
            errorLogged = true
            log("walkin error: %s", tostring(err))
        end
    end
end

return walkin
