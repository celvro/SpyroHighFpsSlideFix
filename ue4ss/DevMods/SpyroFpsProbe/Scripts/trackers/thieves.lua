-- Chasing thieves (the Gnorc egg thieves and their S2/S3 counterparts: anything with a ChaseSpeedManager).
--
--   "thief" lines            once a second per chasing or moving thief: speed (from position) and velocity
--                            next to the MaxWalkSpeed the manager sets, % of time at it, observed acceleration
--                            vs MaxAcceleration, distance to Spyro vs the desired distance, chase time, enemy
--                            state and predicted laughs.
--   thieves_<stamp>.csv      one row per frame per active thief.
--
-- The manager's tick: DesiredDistance lerps 300 -> 120 over 40 s of ChaseTime, DesiredSpeed =
-- MapRangeClamped(DesiredDistance - distance to Spyro, -50..50 -> 290..700), MaxWalkSpeed =
-- Lerp(MaxWalkSpeed, DesiredSpeed, dt * 0.7). It laughs (sound only, 3 s cooldown) when Spyro's
-- horizontal speed dropped by more than 150 since its last tick, which is per frame, so "laughs" counts
-- those drops. Sampled before the world tick, like the dragons.
local log = require("lib.log")
local paths = require("lib.paths")
local state = require("lib.state")
local util = require("lib.util")

local num, isGrounded, tryCall, lookupDue = util.num, util.isGrounded, util.tryCall, util.lookupDue

local THIEF_REPORT_INTERVAL = 1.0 -- seconds of game time per thief line
local THIEF_MOVING_SPEED = 1      -- thieves slower than this that aren't chasing are left out
local THIEF_LAUGH_DROP = 150      -- ChaseSpeedManager laughs when Spyro's horizontal speed drops more than this in one tick
local THIEF_LAUGH_COOLDOWN = 3    -- seconds (the laugh's Delay)

-- Chasing thieves get their MaxWalkSpeed from this component.
local thieves = { CLASSES = { ChaseSpeedManager_C = true, ChaseSpeedManager_S3_C = true } }

local managers = {}  -- ChaseSpeedManager components
local entries = {}   -- thief address -> { prevLoc, prevSpeed, lastLaugh, stats, name }
local lookup = { lookups = 1, nextLookup = 0 }
local classSeen = false
local errorLogged = false
local file = nil

local function newThiefStats(time)
    return { start = time, frames = 0, dtSum = 0, activeTime = 0, speedSum = 0, speedMax = 0, velSpeedSum = 0,
             maxWalkSum = 0, maxWalkMin = math.huge, maxWalkMax = 0, maxAccel = 0 / 0, atMaxTime = 0,
             desiredSpeedSum = 0, desiredDistSum = 0, distSum = 0, spyroSpeedSum = 0, chaseTime = 0 / 0, chasingTime = 0,
             accelGain = 0, accelTime = 0, laughs = 0, states = {} }
end

local function logThief(name, s)
    local t = s.activeTime
    local function avg(key) return s[key] / t end
    local topState, topTime = "?", -1
    for stateName, stateTime in pairs(s.states) do
        if stateTime > topTime then topState, topTime = stateName, stateTime end
    end
    log("thief %s cap=%s avgFps=%.1f active=%.2fs chasing=%.2fs chaseTime=%.1fs state=%s speed=%.1f (velocity %.1f, max %.1f) maxWalkSpeed=%.1f (%.1f-%.1f) atMaxWalkSpeed=%.0f%% desiredSpeed=%.1f accelObserved=%s maxAccel=%.0f distance=%.1f desiredDistance=%.1f spyroSpeed=%.1f laughs=%d",
        name, tostring(state.fpsCap or "?"), s.frames / s.dtSum, t, s.chasingTime, s.chaseTime, topState,
        avg("speedSum"), avg("velSpeedSum"), s.speedMax, avg("maxWalkSum"), s.maxWalkMin, s.maxWalkMax,
        100 * s.atMaxTime / t, avg("desiredSpeedSum"),
        -- Speed gained per second on grounded frames that sped up below MaxWalkSpeed (compare with maxAccel).
        s.accelTime > 0 and string.format("%.1f", s.accelGain / s.accelTime) or "n/a",
        s.maxAccel, avg("distSum"), avg("desiredDistSum"), avg("spyroSpeedSum"), s.laughs)
end

local function update(r, prev)
    if lookupDue(lookup, r.time) then
        managers = {}
        for className in pairs(thieves.CLASSES) do
            for _, manager in ipairs(FindAllOf(className) or {}) do managers[#managers + 1] = manager end
        end
    end
    local dt = prev and r.time - prev.time or 0
    if dt <= 0 then return end
    for _, manager in ipairs(managers) do
        local thief = manager:IsValid() and manager:GetOwner() or nil
        if thief and thief:IsValid() then
            local address = thief:GetAddress()
            local loc = thief:K2_GetActorLocation()
            local e = entries[address]
            if not e or r.time < e.stats.start then -- new thief, or a reloaded world reusing the address
                e = { prevLoc = loc, lastLaugh = -math.huge, stats = newThiefStats(r.time), name = thief:GetFName():ToString() }
                entries[address] = e
            else
                local cmc = thief.CharacterMovement
                local vel = cmc.Velocity
                local speed = math.sqrt((loc.X - e.prevLoc.X) ^ 2 + (loc.Y - e.prevLoc.Y) ^ 2) / dt
                local velSpeed = math.sqrt(vel.X * vel.X + vel.Y * vel.Y)
                local prevSpeed = e.prevSpeed
                e.prevLoc, e.prevSpeed = loc, speed
                local chasing = manager.ChaseIsOn == true
                local s = e.stats
                if chasing or speed > THIEF_MOVING_SPEED then
                    local maxWalk, mode = num(cmc.MaxWalkSpeed), cmc.MovementMode
                    local desiredSpeed, desiredDist = num(manager.CurrentDesiredSpeed), num(manager.CurrentDesiredDistance)
                    local distance = math.sqrt((loc.X - r.x) ^ 2 + (loc.Y - r.y) ^ 2 + (loc.Z - r.z) ^ 2)
                    local stateName = tryCall("thief FalconEnemy:BP_GetCurrentStateName", function()
                        return thief.FalconEnemy:BP_GetCurrentStateName():ToString()
                    end) or "?"
                    s.frames, s.dtSum = s.frames + 1, s.dtSum + dt
                    s.activeTime = s.activeTime + dt
                    s.speedSum = s.speedSum + speed * dt
                    s.speedMax = math.max(s.speedMax, speed)
                    s.velSpeedSum = s.velSpeedSum + velSpeed * dt
                    s.maxWalkSum = s.maxWalkSum + maxWalk * dt
                    s.maxWalkMin, s.maxWalkMax = math.min(s.maxWalkMin, maxWalk), math.max(s.maxWalkMax, maxWalk)
                    s.maxAccel = num(cmc.MaxAcceleration)
                    if speed >= maxWalk - 1 then s.atMaxTime = s.atMaxTime + dt end
                    s.desiredSpeedSum = s.desiredSpeedSum + desiredSpeed * dt
                    s.desiredDistSum = s.desiredDistSum + desiredDist * dt
                    s.distSum = s.distSum + distance * dt
                    s.spyroSpeedSum = s.spyroSpeedSum + r.speed * dt
                    s.states[stateName] = (s.states[stateName] or 0) + dt
                    if chasing then
                        s.chasingTime = s.chasingTime + dt
                        s.chaseTime = num(manager.ChaseTime)
                        if prev.speed - r.speed > THIEF_LAUGH_DROP and r.time - e.lastLaugh >= THIEF_LAUGH_COOLDOWN then
                            e.lastLaugh = r.time
                            s.laughs = s.laughs + 1
                        end
                    end
                    if isGrounded(mode) and prevSpeed and speed > prevSpeed and speed < maxWalk - 1 then
                        s.accelGain = s.accelGain + (speed - prevSpeed)
                        s.accelTime = s.accelTime + dt
                    end
                    if not file then
                        file = io.open(paths.thieves, "w")
                        if file then
                            file:write("time,dt,fps_cap,thief,x,y,z,speed,vel_speed,vz,move_mode,max_walk_speed,max_accel,chase_on,chase_time,desired_distance,desired_speed,distance,spyro_speed,state\n")
                        end
                    end
                    if file then
                        file:write(string.format("%.5f,%.5f,%s,%s,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%d,%.3f,%.1f,%s,%.3f,%.2f,%.2f,%.2f,%.3f,%s\n",
                            r.time, dt, tostring(state.fpsCap or ""), e.name, loc.X, loc.Y, loc.Z, speed, velSpeed, vel.Z,
                            mode, maxWalk, s.maxAccel, tostring(chasing), num(manager.ChaseTime), desiredDist, desiredSpeed,
                            distance, r.speed, stateName))
                    end
                end
                if r.time - s.start >= THIEF_REPORT_INTERVAL then
                    if s.activeTime > 0 then
                        logThief(e.name, s)
                        if file then file:flush() end
                    end
                    e.stats = newThiefStats(r.time)
                end
            end
        end
    end
end

function thieves.update(r, prev)
    local ok, err = pcall(update, r, prev)
    if not ok and not errorLogged then
        errorLogged = true
        log("thief stats error: %s", tostring(err))
    end
end

-- A ChaseSpeedManager class was created: its level is loading, so look for the managers for a while.
function thieves.classLoaded()
    lookup.lookups, lookup.nextLookup, classSeen = util.NEW_OBJECT_LOOKUPS, 0, true
end

-- A new pawn (level load, respawn) may come with new thieves; look again if their class has loaded.
function thieves.pawnChanged()
    if classSeen then lookup.lookups, lookup.nextLookup = util.NEW_OBJECT_LOOKUPS, 0 end
end

return thieves
