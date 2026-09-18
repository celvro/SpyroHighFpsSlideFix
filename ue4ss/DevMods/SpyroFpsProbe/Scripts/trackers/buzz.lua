-- Buzz (Spyro 3 boss, LS308 Buzz's Dungeon) and Sheila in that fight (BP_Sheila_SP3NPC_Buzz): his ChargeRun
-- state played the run montage without moving at high FPS; she walks up to him (SeekBurningBuzz) to stomp him.
--
--   "buzzrun" lines     one per moving state (Buzz: ChargeRun, RollAttack, RollRetreat; Sheila: SeekBurningBuzz,
--                       JumpOnBuzz, PatrolMoveIn/Out): duration, distance moved, average/max speed from position
--                       and from Velocity, frames with no displacement, time to 50%/90% of MaxWalkSpeed,
--                       the state it left to, and the movement settings it ran with.
--   "buzzcmc"/"sheilacmc" dump  every reflected property of the movement component, once per actor
--                       (camdump_<time>_buzzcmc.txt / _sheilacmc.txt).
--   buzz_<stamp>.csv    one row per frame per tracked actor (the buzz column names it).
--
-- ChargeRun: MovementMode SeekPlayer, the Blueprint enables PhasmidCharacterMovement.bEnableCarMovement
-- (native) and sets CarTurningRate/RotationRate from the distance to the arena centre every tick.
local dump = require("lib.dump")
local log = require("lib.log")
local paths = require("lib.paths")
local state = require("lib.state")
local util = require("lib.util")

local num, tryCall, lookupDue = util.num, util.tryCall, util.lookupDue

local buzz = { CLASSES = { BP_CBS3002_Buzz2_C = true, BP_CBS3002_Buzz2_LS326_C = true, BP_Sheila_SP3NPC_Buzz_C = true } }

local MOVING_STATES = { ChargeRun = true, RollAttack = true, RollRetreat = true, -- Buzz
                        SeekBurningBuzz = true, JumpOnBuzz = true, PatrolMoveIn = true, PatrolMoveOut = true } -- Sheila
local STILL_DISPLACEMENT = 0.001 -- units per frame counted as not moving

local actors = {}
local entries = {} -- address -> { prevLoc, stateName, run, name }
local lookup = { lookups = 1, nextLookup = 0 }
local classSeen = false
local errorLogged = false
local file = nil

local function newRun(stateName, r, loc, entry)
    return { stateName = stateName, start = r.time, startLoc = loc, frames = 0, dtSum = 0, dist = 0,
             speedMax = 0, velSum = 0, velMax = 0, stillFrames = 0, firstMove = nil, t50 = nil, t90 = nil,
             from = entry.stateName or "?" }
end

local function logRun(e, run, nextState, cmc, car)
    local t = run.dtSum
    if t <= 0 then return end
    log("buzzrun %s state=%s from=%s to=%s cap=%s avgFps=%.1f time=%.3fs dist=%.1f speed=%.1f (max %.1f) velocity=%.1f (max %.1f) stillFrames=%d/%d firstMove=%s t50=%s t90=%s maxWalkSpeed=%.1f maxAccel=%.1f car=%s carTurn=%.1f",
        e.name, run.stateName, run.from, nextState, tostring(state.fpsCap or "?"), run.frames / t, t, run.dist,
        run.dist / t, run.speedMax, run.velSum / t, run.velMax, run.stillFrames, run.frames,
        run.firstMove and string.format("%.3fs", run.firstMove) or "never",
        run.t50 and string.format("%.3fs", run.t50) or "n/a", run.t90 and string.format("%.3fs", run.t90) or "n/a",
        num(cmc.MaxWalkSpeed), num(cmc.MaxAcceleration), tostring(car), num(cmc.CarTurningRate))
end

local function update(r, prev)
    if lookupDue(lookup, r.time) then
        actors = {}
        for className in pairs(buzz.CLASSES) do
            for _, actor in ipairs(FindAllOf(className) or {}) do actors[#actors + 1] = actor end
        end
    end
    local dt = prev and r.time - prev.time or 0
    if dt <= 0 then return end
    for _, actor in ipairs(actors) do
        if actor:IsValid() then
            local address = actor:GetAddress()
            local loc = actor:K2_GetActorLocation()
            local cmc = actor.CharacterMovement
            local stateName = tryCall("buzz FalconEnemy:BP_GetCurrentStateName", function()
                return actor.FalconEnemy:BP_GetCurrentStateName():ToString()
            end) or "?"
            local e = entries[address]
            if not e or r.time < e.start then
                e = { start = r.time, prevLoc = loc, name = actor:GetFName():ToString() }
                entries[address] = e
                if cmc:IsValid() then dump.write(e.name:find("Sheila") and "sheilacmc" or "buzzcmc", dump.object(cmc)) end
            end
            if cmc:IsValid() then
                local vel = cmc.Velocity
                local dx, dy, dz = loc.X - e.prevLoc.X, loc.Y - e.prevLoc.Y, loc.Z - e.prevLoc.Z
                local disp = math.sqrt(dx * dx + dy * dy)
                local speed = disp / dt
                local velSpeed = math.sqrt(vel.X * vel.X + vel.Y * vel.Y)
                local car = cmc.bEnableCarMovement
                local accel = tryCall("buzz GetCurrentAcceleration", function() return cmc:GetCurrentAcceleration() end)
                local rot = actor:K2_GetActorRotation()
                local stateTime = tryCall("buzz FalconEnemy:GetCurrentStateTime", function()
                    return actor.FalconEnemy:GetCurrentStateTime()
                end)

                if stateName ~= e.stateName then
                    if e.run then logRun(e, e.run, stateName, cmc, car) end
                    if file then file:flush() end
                    e.run = MOVING_STATES[stateName] and newRun(stateName, r, loc, e) or nil
                    e.stateName = stateName
                elseif e.run then
                    local run = e.run
                    run.frames, run.dtSum = run.frames + 1, run.dtSum + dt
                    run.dist = run.dist + disp
                    run.speedMax = math.max(run.speedMax, speed)
                    run.velSum, run.velMax = run.velSum + velSpeed * dt, math.max(run.velMax, velSpeed)
                    if disp < STILL_DISPLACEMENT then
                        run.stillFrames = run.stillFrames + 1
                    elseif not run.firstMove then
                        run.firstMove = r.time - run.start
                    end
                    local maxWalk = num(cmc.MaxWalkSpeed)
                    if not run.t50 and speed >= 0.5 * maxWalk then run.t50 = r.time - run.start end
                    if not run.t90 and speed >= 0.9 * maxWalk then run.t90 = r.time - run.start end
                end

                if not file then
                    file = io.open(paths.buzz, "w")
                    if file then
                        file:write("time,dt,fps_cap,buzz,state,state_time,x,y,z,yaw,disp,speed,vel_x,vel_y,vel_z,vel_speed,accel_x,accel_y,accel_z,move_mode,car,car_turn,rot_rate_yaw,max_walk_speed,max_accel,dilation,spyro_x,spyro_y,req_x,req_y\n")
                    end
                end
                if file then
                    file:write(string.format("%.5f,%.5f,%s,%s,%s,%s,%.4f,%.4f,%.4f,%.3f,%.5f,%.3f,%.4f,%.4f,%.4f,%.4f,%s,%s,%s,%d,%s,%.2f,%.2f,%.2f,%.1f,%.3f,%.3f,%.3f,%.3f,%.3f\n",
                        r.time, dt, tostring(state.fpsCap or ""), e.name, stateName, stateTime and string.format("%.4f", stateTime) or "",
                        loc.X, loc.Y, loc.Z, rot.Yaw, disp, speed, vel.X, vel.Y, vel.Z, velSpeed,
                        accel and string.format("%.3f", accel.X) or "", accel and string.format("%.3f", accel.Y) or "",
                        accel and string.format("%.3f", accel.Z) or "",
                        cmc.MovementMode, tostring(car), num(cmc.CarTurningRate), num(cmc.RotationRate.Yaw),
                        num(cmc.MaxWalkSpeed), num(cmc.MaxAcceleration), num(actor.CustomTimeDilation), r.x, r.y,
                        cmc.RequestedVelocity.X, cmc.RequestedVelocity.Y))
                end
            end
            e.prevLoc = loc
        end
    end
end

function buzz.update(r, prev)
    local ok, err = pcall(update, r, prev)
    if not ok and not errorLogged then
        errorLogged = true
        log("buzz error: %s", tostring(err))
    end
end

function buzz.classLoaded()
    lookup.lookups, lookup.nextLookup, classSeen = util.NEW_OBJECT_LOOKUPS, 0, true
end

function buzz.pawnChanged()
    if classSeen then lookup.lookups, lookup.nextLookup = util.NEW_OBJECT_LOOKUPS, 0 end
end

return buzz
