-- Skelos Badlands (LS212) lava lizards, the "dinosaurs" of the orb mission: they walk to the caveman
-- babies (`FalconEnemyState_WalkToGuy`, MovementMode TraverseWaypointsOnce, montage AM_CES2031_Walk) and
-- eat them. Reported: at high FPS one of them cannot climb two steps near the end of its route and only
-- gets up after many tries. That is the blocked-frame family of `docs/findings/charge-wall-stall.md`: at
-- MaxWalkSpeed 143 a frame's move is 4.8 units at 30 FPS but 0.45 at 320, so a sweep that blocks at
-- Time 0 leaves no displacement and PhysWalking resets Velocity to 0.
--
-- Blueprint defaults (BP_LavaLizard, chunk1 CES2031_LavaLizard): MaxStepHeight 50, MaxWalkSpeed 143,
-- MaxAcceleration 2048 (inherited), capsule radius 23.49 half-height 40, DefaultLandMovementMode Walking,
-- WalkableFloorAngle 50. `MyMaxStepHeight` is the Blueprint's own copy, saved at BeginPlay and written
-- back to `CharacterMovement.MaxStepHeight` on a mission reset.
--
--   lizard_<stamp>.csv       one row per frame per active lizard (header below)
--   lizard_hits_<stamp>.csv  every blocking hit of a lizard's own moves, from BP_Base_Enemy's capsule hit
--                            event: what was hit, the normals, the sweep and its Time
--   "lizardstall" lines   a stretch in a moving state that got nowhere: duration, still frames, where it
--                         stood, z gained, the velocity and request it had, the hits that blocked it
--                         (normals and how many at Time 0), and what ended it
--   "lizardstep" lines    a climb: the z gain, the dt of the frame that managed it against the running
--                         average, and how long and how many blocked frames it took to get up
--   "lizardsummary" lines per lizard when it leaves a moving state: time, distance, stalled time, climbs
--   "lizardcmc" dump      every reflected movement-component property, once, for the first lizard found
local dump = require("lib.dump")
local log = require("lib.log")
local paths = require("lib.paths")
local state = require("lib.state")
local util = require("lib.util")

local num, tryCall, lookupDue = util.num, util.tryCall, util.lookupDue

local lizard = { CLASS = "BP_LavaLizard_C" }

-- BP_Base_Enemy binds this to its CapsuleComponent's OnComponentHit, so every enemy's blocking hits come
-- through it (params: HitComponent, OtherActor, OtherComp, NormalImpulse, Hit).
local HIT_FUNCTION = "/CharacterCommon/BaseClasses/BP_Base_Enemy.BP_Base_Enemy_C:"
    .. "BndEvt__CapsuleComponent_K2Node_ComponentBoundEvent_3_ComponentHitSignature__DelegateSignature"
local HOOK_RETRY_FRAMES = 60
local MAX_PENDING = 32          -- hits kept per lizard per frame
local MAX_ROWS = 8              -- CSV rows per frame, worst case 16 lizards are loaded
local FAR = 12000               -- lizards further than this from the player are left alone
local MOVING_STATES = { WalkToGuy = true, TurnToGuy = true }
local STALL_STATES = { WalkToGuy = true }  -- TurnToGuy turns in place, so standing still there is not a stall
local STILL = 0.001             -- horizontal displacement counted as no move at all
local STALL_MIN_TIME = 0.05     -- a stall shorter than this isn't logged
local STALL_MIN_FRAMES = 5
local STALL_CLEAR = 5.0         -- net distance from the stall's start that ends it
local STALL_GAP = 0.25          -- seconds of not wanting to move that end it
local STEP_MIN = 3.0            -- z gain in one frame counted as a climb
local STEP_LOG_MAX = 40         -- climbs logged per lizard, so a long session can't flood the log

local actors = {}
local entries = {}  -- address -> { name, prevLoc, stateName, dtAvg, stall, climbs, run, hits }
local lookup = { lookups = util.NEW_OBJECT_LOOKUPS, nextLookup = 0 }
local pending = {}  -- address -> list of hits since the last frame
local registered, hookFailed, retryIn = false, false, 0
local cmcDumped = false
local errorLogged = false
local file, hitFile = nil, nil

local function actorName(object)
    local ok, s = pcall(function() return object:GetFName():ToString() end)
    return ok and s or "?"
end

local function className(object)
    local ok, s = pcall(function() return object:GetClass():GetFName():ToString() end)
    return ok and s or "?"
end

local function vec(v)
    return { num(v.X), num(v.Y), num(v.Z) }
end

local function add(actor)
    if not (actor and actor:IsValid()) then return end
    local name = actorName(actor)
    if name:match("^Default__") then return end
    local address = actor:GetAddress()
    for _, known in ipairs(actors) do
        if known:IsValid() and known:GetAddress() == address then return end
    end
    actors[#actors + 1] = actor
end

-- Hits of the lizards' own moves. The engine calls this for the step-up and slide sweeps too, which is
-- what tells a blocked climb from a lizard that never tried.
local function onHit(context, hitComp, otherActor, otherComp, normalImpulse, hit)
    local actor = context:get()
    if not (actor and actor:IsValid()) then return end
    if className(actor) ~= lizard.CLASS then return end
    local address = actor:GetAddress()
    local list = pending[address]
    if not list then
        list = {}
        pending[address] = list
    end
    if #list >= MAX_PENDING then return end
    local h = hit:get()
    local other, comp = otherActor:get(), otherComp:get()
    local entry = {
        other = (other and other:IsValid()) and actorName(other) or "none",
        comp = (comp and comp:IsValid()) and actorName(comp) or "none",
        normal = vec(h.Normal), impactNormal = vec(h.ImpactNormal), impactPoint = vec(h.ImpactPoint),
        location = vec(h.Location), traceStart = vec(h.TraceStart), traceEnd = vec(h.TraceEnd),
        time = num(h.Time), startPenetrating = h.bStartPenetrating, penetration = num(h.PenetrationDepth),
    }
    -- A Blueprint hook here fires the pre callback only, but it is registered as both (CLAUDE.md), so
    -- drop a repeat of the hit that was just stored.
    local last = list[#list]
    if last and last.time == entry.time and last.impactPoint[1] == entry.impactPoint[1]
        and last.impactPoint[2] == entry.impactPoint[2] and last.impactPoint[3] == entry.impactPoint[3] then
        return
    end
    list[#list + 1] = entry
end

-- Registered once a lizard exists, so the function name is never looked up while it cannot be there
-- (a StaticFindObject miss scans the whole object array).
local function tryRegister()
    if registered or hookFailed then return end
    if retryIn > 0 then
        retryIn = retryIn - 1
        return
    end
    retryIn = HOOK_RETRY_FRAMES
    local fn = StaticFindObject(HIT_FUNCTION)
    if not (fn and fn:IsValid()) then return end -- no enemies loaded yet; never polled for a missing name
    local hitErrorLogged = false
    local function guarded(...)
        local ok, err = pcall(onHit, ...)
        if not ok and not hitErrorLogged then
            hitErrorLogged = true
            log("lizard hit hook error: %s", tostring(err))
        end
    end
    local ok, err = pcall(RegisterHook, HIT_FUNCTION, guarded, guarded)
    if ok then
        registered = true
        log("lizard capsule hit hook registered")
    else
        hookFailed = true
        log("lizard capsule hit hook unavailable: %s", tostring(err))
    end
end

local function hitSummary(stall)
    local parts = {}
    for key, count in pairs(stall.normals) do
        parts[#parts + 1] = string.format("%s x%d", key, count)
    end
    table.sort(parts)
    return #parts > 0 and table.concat(parts, " ") or "none"
end

local function logStall(e, stall, endedBy)
    if stall.dtSum < STALL_MIN_TIME or stall.stillFrames < STALL_MIN_FRAMES then return end
    log("lizardstall %s state=%s cap=%s avgFps=%.1f dur=%.3fs still=%d/%d frames at=(%.3f,%.3f,%.3f) "
        .. "moved=%.3f zGain=%.3f velMax=%.1f reqMax=%.1f accelMax=%.1f hits=%d t0=%d stepHeight=%.1f "
        .. "normals=%s endedBy=%s",
        e.name, stall.stateName, tostring(state.fpsCap or "?"),
        stall.dtSum > 0 and stall.frames / stall.dtSum or 0 / 0, stall.dtSum, stall.stillFrames, stall.frames,
        stall.x, stall.y, stall.z, stall.moved, stall.zGain, stall.velMax, stall.reqMax, stall.accelMax,
        stall.hits, stall.hitsT0, stall.stepHeight, hitSummary(stall), endedBy)
end

local function endStall(e, endedBy)
    if not e.stall then return end
    logStall(e, e.stall, endedBy)
    e.stall = nil
end

local function logSummary(e, nextState)
    local run = e.run
    if not run or run.dtSum <= 0 then return end
    log("lizardsummary %s state=%s to=%s cap=%s avgFps=%.1f dur=%.3fs dist=%.1f stalled=%.3fs (%d stalls) "
        .. "climbs=%d still=%d/%d frames velMax=%.1f",
        e.name, run.stateName, nextState, tostring(state.fpsCap or "?"), run.frames / run.dtSum, run.dtSum,
        run.dist, run.stalledTime, run.stalls, run.climbs, run.stillFrames, run.frames, run.velMax)
    e.run = nil
end

local function writeHitRows(r, e, list, disp)
    if not hitFile then
        hitFile = io.open(string.format("%s\\lizard_hits_%s.csv", paths.modDir, paths.stamp), "w")
        if not hitFile then return end
        hitFile:write("time,dt,fps_cap,lizard,state,x,y,z,disp,other,comp,normal_x,normal_y,normal_z,"
            .. "impact_nx,impact_ny,impact_nz,impact_x,impact_y,impact_z,loc_x,loc_y,loc_z,"
            .. "start_x,start_y,start_z,end_x,end_y,end_z,hit_time,start_penetrating,penetration\n")
    end
    for _, h in ipairs(list) do
        hitFile:write(string.format("%.5f,%.5f,%s,%s,%s,%.4f,%.4f,%.4f,%.5f,%s,%s,%.4f,%.4f,%.4f,"
            .. "%.4f,%.4f,%.4f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.4f,%s,%.4f\n",
            r.time, r.dt, tostring(state.fpsCap or ""), e.name, e.stateName or "?", e.x, e.y, e.z, disp,
            h.other, h.comp, h.normal[1], h.normal[2], h.normal[3],
            h.impactNormal[1], h.impactNormal[2], h.impactNormal[3],
            h.impactPoint[1], h.impactPoint[2], h.impactPoint[3], h.location[1], h.location[2], h.location[3],
            h.traceStart[1], h.traceStart[2], h.traceStart[3], h.traceEnd[1], h.traceEnd[2], h.traceEnd[3],
            h.time, tostring(h.startPenetrating), h.penetration))
    end
end

local function writeRow(r, e, f)
    if not file then
        file = io.open(string.format("%s\\lizard_%s.csv", paths.modDir, paths.stamp), "w")
        if not file then return end
        file:write("time,dt,fps_cap,lizard,state,state_time,mode,custom_mode,x,y,z,disp,dz,speed,vel_x,vel_y,vel_z,"
            .. "vel_speed,req_x,req_y,req_speed,accel_x,accel_y,accel_speed,max_walk_speed,max_accel,"
            .. "max_step_height,floor_dist,floor_nz,floor_walkable,root_motion,hits,hits_t0,stalling,"
            .. "dist_to_spyro\n")
    end
    file:write(string.format("%.5f,%.5f,%s,%s,%s,%s,%d,%d,%.4f,%.4f,%.4f,%.5f,%.5f,%.3f,%.4f,%.4f,%.4f,%.3f,"
        .. "%.3f,%.3f,%.3f,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f,%s,%s,%s,%s,%d,%d,%s,%.1f\n",
        r.time, r.dt, tostring(state.fpsCap or ""), e.name, f.stateName, f.stateTime or "", f.mode, f.customMode,
        f.x, f.y, f.z, f.disp, f.dz, f.speed, f.vx, f.vy, f.vz, f.velSpeed, f.rx, f.ry, f.reqSpeed,
        f.ax, f.ay, f.accelSpeed, f.maxWalkSpeed, f.maxAccel, f.stepHeight,
        f.floorDist and string.format("%.4f", f.floorDist) or "",
        f.floorNz and string.format("%.4f", f.floorNz) or "", tostring(f.floorWalkable),
        tostring(f.rootMotion), f.hits, f.hitsT0, tostring(e.stall ~= nil), f.distToSpyro))
end

local function updateActor(actor, r, dt)
    local address = actor:GetAddress()
    local loc = actor:K2_GetActorLocation()
    local distToSpyro = math.sqrt((loc.X - r.x) ^ 2 + (loc.Y - r.y) ^ 2 + (loc.Z - r.z) ^ 2)
    local e = entries[address]
    if not e or r.time < e.time then
        e = { name = actorName(actor), time = r.time, climbs = 0, logged = 0,
              x = loc.X, y = loc.Y, z = loc.Z }
        entries[address] = e
    end
    local list = pending[address]
    pending[address] = nil
    if distToSpyro > FAR and not list then
        e.prevLoc, e.time = loc, r.time
        return false
    end

    local cmc = actor.CharacterMovement
    if not (cmc and cmc:IsValid()) then return false end
    if not cmcDumped then
        cmcDumped = true
        dump.write("lizardcmc", dump.object(cmc))
    end

    local prevLoc = e.prevLoc
    local dx = prevLoc and loc.X - prevLoc.X or 0
    local dy = prevLoc and loc.Y - prevLoc.Y or 0
    local dz = prevLoc and loc.Z - prevLoc.Z or 0
    local disp = math.sqrt(dx * dx + dy * dy)
    local vel, req, acc = cmc.Velocity, cmc.RequestedVelocity, cmc.Acceleration
    local velSpeed = math.sqrt(num(vel.X) ^ 2 + num(vel.Y) ^ 2)
    local reqSpeed = math.sqrt(num(req.X) ^ 2 + num(req.Y) ^ 2)
    local accelSpeed = math.sqrt(num(acc.X) ^ 2 + num(acc.Y) ^ 2)
    local mode = cmc.MovementMode
    local stateName = tryCall("lizard FalconEnemy:BP_GetCurrentStateName", function()
        return actor.FalconEnemy:BP_GetCurrentStateName():ToString()
    end) or "?"
    local hits, hitsT0 = 0, 0
    if list then
        hits = #list
        for _, h in ipairs(list) do
            if h.time == 0 then hitsT0 = hitsT0 + 1 end
        end
    end

    e.x, e.y, e.z = loc.X, loc.Y, loc.Z
    e.prevLoc, e.time = loc, r.time
    e.dtAvg = e.dtAvg and (e.dtAvg * 0.95 + dt * 0.05) or dt
    local wants = MOVING_STATES[stateName] or velSpeed > 0 or reqSpeed > 0 or accelSpeed > 0
    local active = wants or disp > STILL or hits > 0

    -- One run per moving state, so a summary line lands when it gives up or arrives.
    if stateName ~= e.stateName then
        endStall(e, "state")
        logSummary(e, stateName)
        e.stateName = stateName
        if MOVING_STATES[stateName] then
            e.run = { stateName = stateName, frames = 0, dtSum = 0, dist = 0, stalledTime = 0, stalls = 0,
                      climbs = 0, stillFrames = 0, velMax = 0 }
        end
    end
    if not prevLoc then return active end

    local run = e.run
    if run then
        run.frames, run.dtSum = run.frames + 1, run.dtSum + dt
        run.dist = run.dist + disp
        run.velMax = math.max(run.velMax, velSpeed)
        if disp <= STILL then run.stillFrames = run.stillFrames + 1 end
    end

    local stepHeight = num(cmc.MaxStepHeight)
    local stall = e.stall
    if stall then
        stall.frames, stall.dtSum = stall.frames + 1, stall.dtSum + dt
        stall.zGain = stall.zGain + dz
        stall.moved = math.sqrt((loc.X - stall.x) ^ 2 + (loc.Y - stall.y) ^ 2)
        stall.velMax = math.max(stall.velMax, velSpeed)
        stall.reqMax = math.max(stall.reqMax, reqSpeed)
        stall.accelMax = math.max(stall.accelMax, accelSpeed)
        stall.hits, stall.hitsT0 = stall.hits + hits, stall.hitsT0 + hitsT0
        if disp <= STILL then
            stall.stillFrames = stall.stillFrames + 1
        else
            stall.lastMove = r.time
        end
        if wants then stall.lastWant = r.time end
        if run then run.stalledTime = run.stalledTime + dt end
        if list then
            for _, h in ipairs(list) do
                local key = string.format("%s/%s n=(%.2f,%.2f,%.2f)%s", h.other, h.comp,
                    h.normal[1], h.normal[2], h.normal[3], h.time == 0 and " T0" or "")
                stall.normals[key] = (stall.normals[key] or 0) + 1
            end
        end
        if stall.moved > STALL_CLEAR then
            endStall(e, "moved")
        elseif r.time - stall.lastWant > STALL_GAP then
            endStall(e, "gap")
        end
    elseif wants and disp <= STILL and STALL_STATES[stateName] then
        e.stall = { stateName = stateName, start = r.time, lastMove = r.time, lastWant = r.time,
                    x = loc.X, y = loc.Y, z = loc.Z, frames = 1, dtSum = dt, stillFrames = 1, zGain = 0,
                    moved = 0, velMax = velSpeed, reqMax = reqSpeed, accelMax = accelSpeed,
                    hits = hits, hitsT0 = hitsT0, stepHeight = stepHeight, normals = {} }
        if run then run.stalls = run.stalls + 1 end
    end

    -- A climb: one frame's z gain over a step. Its dt against the running average says whether only a
    -- long frame gets him up.
    if dz >= STEP_MIN then
        e.climbs = e.climbs + 1
        if run then run.climbs = run.climbs + 1 end
        if e.logged < STEP_LOG_MAX then
            e.logged = e.logged + 1
            local tries = e.stall and (r.time - e.stall.start) or 0
            local blocked = e.stall and e.stall.stillFrames or 0
            log("lizardstep %s.%d state=%s cap=%s z %.3f -> %.3f dz=%.3f disp=%.3f dt=%.2fms (avg %.2fms) "
                .. "speed=%.1f vel=%.1f req=%.1f stepHeight=%.1f stalledFor=%.3fs blockedFrames=%d at=(%.3f,%.3f)",
                e.name, e.climbs, stateName, tostring(state.fpsCap or "?"), loc.Z - dz, loc.Z, dz, disp,
                dt * 1000, (e.dtAvg or dt) * 1000, disp / dt, velSpeed, reqSpeed, stepHeight, tries, blocked,
                loc.X, loc.Y)
        end
    end

    if active then
        local floor = cmc.CurrentFloor
        writeRow(r, e, {
            stateName = stateName,
            stateTime = tryCall("lizard FalconEnemy:GetCurrentStateTime", function()
                return string.format("%.4f", actor.FalconEnemy:GetCurrentStateTime())
            end),
            mode = mode, customMode = cmc.CustomMovementMode,
            x = loc.X, y = loc.Y, z = loc.Z, disp = disp, dz = dz, speed = disp / dt,
            vx = num(vel.X), vy = num(vel.Y), vz = num(vel.Z), velSpeed = velSpeed,
            rx = num(req.X), ry = num(req.Y), reqSpeed = reqSpeed,
            ax = num(acc.X), ay = num(acc.Y), accelSpeed = accelSpeed,
            maxWalkSpeed = num(cmc.MaxWalkSpeed), maxAccel = num(cmc.MaxAcceleration), stepHeight = stepHeight,
            floorDist = floor and num(floor.FloorDist) or nil,
            floorNz = floor and num(floor.HitResult.ImpactNormal.Z) or nil,
            floorWalkable = floor and floor.bWalkableFloor or nil,
            rootMotion = tryCall("lizard IsPlayingRootMotion", function() return actor:IsPlayingRootMotion() end),
            hits = hits, hitsT0 = hitsT0, distToSpyro = distToSpyro,
        })
    end
    if list then writeHitRows(r, e, list, disp) end
    return active
end

local function update(r, prev)
    if lookupDue(lookup, r.time) then
        for _, actor in ipairs(FindAllOf(lizard.CLASS) or {}) do add(actor) end
    end
    if #actors == 0 then
        pending = {}
        return
    end
    tryRegister()
    local dt = prev and r.time - prev.time or 0
    if dt <= 0 then return end

    local live, rows = {}, 0
    for _, actor in ipairs(actors) do
        if actor:IsValid() then
            live[#live + 1] = actor
            if rows < MAX_ROWS and updateActor(actor, r, dt) then rows = rows + 1 end
        end
    end
    actors = live
    pending = {}
    if file and (prev == nil or math.floor(r.time) ~= math.floor(prev.time)) then file:flush() end
    if hitFile and (prev == nil or math.floor(r.time) ~= math.floor(prev.time)) then hitFile:flush() end
end

function lizard.update(r, prev)
    local ok, err = pcall(update, r, prev)
    if not ok and not errorLogged then
        errorLogged = true
        log("lizard error: %s", tostring(err))
    end
end

function lizard.onNewObject(object)
    if className(object) ~= lizard.CLASS then return end
    local ok, err = pcall(add, object)
    if not ok and not errorLogged then
        errorLogged = true
        log("lizard error: %s", tostring(err))
    end
end

-- A level load or a respawn replaces them, and a hot reload starts with none known.
function lizard.pawnChanged()
    actors, entries, pending = {}, {}, {}
    lookup.lookups, lookup.nextLookup = util.NEW_OBJECT_LOOKUPS, 0
end

return lizard
