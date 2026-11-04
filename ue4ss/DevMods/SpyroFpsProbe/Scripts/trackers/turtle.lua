-- Sunny Beach (LS206) turtle soup: the box turtles of the orb challenge, walking and after a charge.
--
-- The minigame turtles are `BP_BoxTurtle_Spawned_C` (LS206_SunnyBeach/Blueprints), spawned by
-- BP_Orb_Turtle_Controller. They walk to the cauldron and jump in; charging one sends it sliding away on
-- its shell. Two different movement systems, so two different ways a framerate can change them:
--
--   Walking   `FalconEnemyStateComponent` states MoveOutOfTube (TraverseWaypointsOnce), MoveToCauldron /
--             MoveToCauldron_Invuln / MoveToDummy (SeekPlayer towards a Target) and RunAway
--             (FleeFromPlayer). NavWalking, MaxWalkSpeed 80, MaxStepHeight 20, MaxAcceleration the
--             native 2048, so a SeekPlayer move from rest is the quantization stall of
--             `docs/findings/npc-stalls.md` (threshold ~304-362 FPS), and LS206 sits at
--             (300000, -300000), where BOTH axes are on the 1/32 position grid.
--   Sliding   on a Damage.Charge hit the Blueprint turns the turtle away from Spyro, activates its
--             `PhasmidProjectileMovement` and sets the velocity to 300 in local X (MaxSpeed 300,
--             bShouldBounce, Friction 0, BounceVelocityStopSimulatingThreshold 0, bConstrainToPlane).
--             SlideIn (montage 0.167 s) -> Slide (3 s) -> SlideOut (0.5 s) -> MoveToCauldron, and the
--             component is deactivated when Slide exits. None of the slide animations has root motion,
--             so every unit of that travel is the projectile component's.
--
-- The level's own turtles (`CES2225_BoxTurtle_C`, `_NoPlate_C`) are tracked too: same model, plain
-- MoveToTarget walking, no projectile slide, so they are the walking control.
--
--   turtle_<stamp>.csv       one row per frame per active turtle (header below): the character movement
--                            component and the projectile component side by side
--   turtle_hits_<stamp>.csv  every blocking hit of a turtle's own moves (lib/enemyhits.lua): what was
--                            hit, the normals, the sweep and its Time
--   "turtleslide" lines   one per slide, hit to back-on-its-feet: duration, path length, net distance
--                         and heading change from where it was hit, bounces, projectile speed. THE line
--                         to compare across framerates.
--   "turtlerun" lines     one per state: duration, distance, max/avg speed, still frames, hits
--   "turtlestall" lines   a walking state that got nowhere: duration, still frames, where, the velocity
--                         and request it had, the blocking hits (normals, and how many at Time 0)
--   "turtlestart" lines   a walk from rest: time and distance to 50% and 90% of MaxWalkSpeed
--   "turtlecmc" / "turtlepmc" dumps  every reflected property of both movement components, once, for the
--                         first minigame turtle found (the native Phasmid defaults: gravity scale,
--                         bounciness, substepping, plane constraint)
local dump = require("lib.dump")
local enemyhits = require("lib.enemyhits")
local log = require("lib.log")
local paths = require("lib.paths")
local state = require("lib.state")
local util = require("lib.util")

local num, tryCall, lookupDue = util.num, util.tryCall, util.lookupDue

local turtle = {}

turtle.SPAWNED = "BP_BoxTurtle_Spawned_C"       -- the minigame turtles, the ones that slide
turtle.CLASSES = {
    [turtle.SPAWNED] = true,
    CES2225_BoxTurtle_C = true,                 -- the level's own turtles: the walking control
    CES2225_BoxTurtle_NoPlate_C = true,
}

local MAX_PENDING = 32      -- hits kept per turtle per frame
local MAX_ROWS = 12         -- CSV rows per frame; the challenge runs a handful of turtles at once
local FAR = 12000           -- turtles further than this from the player are left alone
local SLIDE_STATES = { SlideIn = true, Slide = true, SlideOut = true }
-- Standing still in these is a stall; Idle, Pause, Jump (a timeline), TurnAway and the slides are not.
local WALK_STATES = {
    MoveOutOfTube = true, MoveToCauldron = true, MoveToCauldron_Invuln = true, MoveToDummy = true,
    RunAway = true, GameOver = true,
}
local STILL = 0.001         -- horizontal displacement counted as no move at all
local STALL_MIN_TIME = 0.05 -- a stall shorter than this isn't logged
local STALL_MIN_FRAMES = 5
local STALL_CLEAR = 5.0     -- net distance from the stall's start that ends it
local STALL_GAP = 0.25      -- seconds of not wanting to move that end it
local BOUNCE_ANGLE = 20     -- degrees of velocity heading change in one frame counted as a bounce
local WALL_NZ = 0.7         -- |normal.Z| below this is a wall rather than the floor
local LOG_MAX = 40          -- slides and starts logged per turtle, so a long session can't flood the log

local actors = {}
local entries = {}  -- address -> { name, class, prevLoc, stateName, run, slide, stall, start, ... }
local lookup = { lookups = util.NEW_OBJECT_LOOKUPS, nextLookup = 0 }
local pending = {}  -- address -> list of hits since the last frame
local dumped = false
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

-- Hits of the turtles' own moves, from the hook shared with the other enemy trackers. During a slide
-- these are the bounces off the arena walls; while walking they are the blocked sweeps.
local function onHit(actor, entry)
    local address = actor:GetAddress()
    local list = pending[address]
    if not list then
        list = {}
        pending[address] = list
    end
    if #list >= MAX_PENDING then return end
    if enemyhits.sameHit(list[#list], entry) then return end
    list[#list + 1] = entry
end

for class in pairs(turtle.CLASSES) do enemyhits.subscribe(class, onHit) end

local function hitSummary(normals)
    local parts = {}
    for key, count in pairs(normals) do
        parts[#parts + 1] = string.format("%s x%d", key, count)
    end
    table.sort(parts)
    return #parts > 0 and table.concat(parts, " ") or "none"
end

local function avgFps(frames, dtSum)
    return dtSum > 0 and frames / dtSum or 0 / 0
end

-- The whole slide, from the charge hit to the turtle being back on its feet. Path length against net
-- distance says whether it bounced; both against the 30 FPS numbers say whether the framerate changed it.
local function logSlide(e, s, endedBy)
    if e.logged >= LOG_MAX then return end
    e.logged = e.logged + 1
    log("turtleslide %s.%d cap=%s avgFps=%.1f dur=%.3fs path=%.1f net=%.1f (dx=%.1f dy=%.1f dz=%.1f) "
        .. "headingTurn=%.1f bounces=%d hits=%d t0=%d pmcSpeed max=%.1f avg=%.1f still=%d/%d frames "
        .. "states=%s endedBy=%s",
        e.name, e.slides, tostring(state.fpsCap or "?"), avgFps(s.frames, s.dtSum), s.dtSum, s.path,
        math.sqrt((s.endX - s.x) ^ 2 + (s.endY - s.y) ^ 2), s.endX - s.x, s.endY - s.y, s.endZ - s.z,
        s.headingTurn, s.bounces, s.hits, s.hitsT0, s.pmcMax,
        s.pmcFrames > 0 and s.pmcSum / s.pmcFrames or 0 / 0, s.stillFrames, s.frames,
        table.concat(s.states, ">"), endedBy)
end

-- A walk from rest: how long the state took to reach half and most of MaxWalkSpeed. At 30 FPS that is
-- a frame or two; a turtle whose first moves round away never gets there at all.
local function logStart(e, st, why)
    if e.logged >= LOG_MAX then return end
    e.logged = e.logged + 1
    log("turtlestart %s state=%s cap=%s avgFps=%.1f target=%.1f t50=%s t90=%s firstMove=%s "
        .. "dist=%.1f dur=%.3fs still=%d/%d frames endedBy=%s",
        e.name, st.stateName, tostring(state.fpsCap or "?"), avgFps(st.frames, st.dtSum), st.target,
        st.t50 and string.format("%.3fs", st.t50) or "never",
        st.t90 and string.format("%.3fs", st.t90) or "never",
        st.firstMove and string.format("%.3fs", st.firstMove) or "never",
        st.dist, st.dtSum, st.stillFrames, st.frames, why)
end

local function logStall(e, stall, endedBy)
    if stall.dtSum < STALL_MIN_TIME or stall.stillFrames < STALL_MIN_FRAMES then return end
    log("turtlestall %s state=%s cap=%s avgFps=%.1f dur=%.3fs still=%d/%d frames at=(%.3f,%.3f,%.3f) "
        .. "moved=%.3f velMax=%.1f reqMax=%.1f accelMax=%.1f maxWalkSpeed=%.1f maxAccel=%.1f hits=%d "
        .. "t0=%d normals=%s endedBy=%s",
        e.name, stall.stateName, tostring(state.fpsCap or "?"), avgFps(stall.frames, stall.dtSum),
        stall.dtSum, stall.stillFrames, stall.frames, stall.x, stall.y, stall.z, stall.moved,
        stall.velMax, stall.reqMax, stall.accelMax, stall.maxWalkSpeed, stall.maxAccel, stall.hits,
        stall.hitsT0, hitSummary(stall.normals), endedBy)
end

local function endStall(e, endedBy)
    if not e.stall then return end
    logStall(e, e.stall, endedBy)
    e.stall = nil
end

-- `net` straighter than `dist` is how a wandering path shows up, so it is worth having, but a turtle
-- that was destroyed or respawned during the state ends up at a position in another frame of reference
-- (a `net` of 421601 on a 392-unit walk, 2026-10-10). A net longer than the path travelled is
-- impossible, so report that as a jump instead of a measurement.
local function netDistance(e, run)
    local net = math.sqrt((e.x - run.x) ^ 2 + (e.y - run.y) ^ 2)
    if net > run.dist + 1 then return nil end
    return net
end

local function logRun(e, nextState)
    local run = e.run
    if not run or run.dtSum <= 0 then return end
    local net = netDistance(e, run)
    log("turtlerun %s state=%s to=%s cap=%s avgFps=%.1f dur=%.3fs dist=%.1f net=%s speed max=%.1f "
        .. "avg=%.1f velMax=%.1f stalled=%.3fs (%d stalls) still=%d/%d frames hits=%d",
        e.name, run.stateName, nextState, tostring(state.fpsCap or "?"), avgFps(run.frames, run.dtSum),
        run.dtSum, run.dist, net and string.format("%.1f", net) or "jumped", run.speedMax,
        run.dtSum > 0 and run.dist / run.dtSum or 0 / 0, run.velMax, run.stalledTime, run.stalls,
        run.stillFrames, run.frames, run.hits)
    e.run = nil
end

local function writeHitRows(r, e, list, disp)
    if not hitFile then
        hitFile = io.open(string.format("%s\\turtle_hits_%s.csv", paths.modDir, paths.stamp), "w")
        if not hitFile then return end
        hitFile:write("time,dt,fps_cap,turtle,class,state,x,y,z,disp,sliding,other,comp,"
            .. "normal_x,normal_y,normal_z,impact_nx,impact_ny,impact_nz,impact_x,impact_y,impact_z,"
            .. "loc_x,loc_y,loc_z,start_x,start_y,start_z,end_x,end_y,end_z,hit_time,"
            .. "start_penetrating,penetration\n")
    end
    for _, h in ipairs(list) do
        hitFile:write(string.format("%.5f,%.5f,%s,%s,%s,%s,%.4f,%.4f,%.4f,%.5f,%s,%s,%s,"
            .. "%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,"
            .. "%.3f,%.3f,%.3f,%.4f,%s,%.4f\n",
            r.time, r.dt, tostring(state.fpsCap or ""), e.name, e.class, e.stateName or "?",
            e.x, e.y, e.z, disp, tostring(e.slide ~= nil), h.other, h.comp,
            h.normal[1], h.normal[2], h.normal[3],
            h.impactNormal[1], h.impactNormal[2], h.impactNormal[3],
            h.impactPoint[1], h.impactPoint[2], h.impactPoint[3],
            h.location[1], h.location[2], h.location[3],
            h.traceStart[1], h.traceStart[2], h.traceStart[3],
            h.traceEnd[1], h.traceEnd[2], h.traceEnd[3],
            h.time, tostring(h.startPenetrating), h.penetration))
    end
end

local function writeRow(r, e, f)
    if not file then
        file = io.open(string.format("%s\\turtle_%s.csv", paths.modDir, paths.stamp), "w")
        if not file then return end
        file:write("time,dt,fps_cap,turtle,class,state,state_time,sliding,mode,custom_mode,x,y,z,yaw,"
            .. "disp,dz,speed,vel_x,vel_y,vel_z,vel_speed,req_x,req_y,req_speed,accel_x,accel_y,"
            .. "accel_speed,max_walk_speed,max_accel,max_step_height,floor_dist,floor_nz,"
            .. "floor_walkable,root_motion,pmc_active,pmc_x,pmc_y,pmc_z,pmc_speed,pmc_max_speed,"
            .. "pmc_heading,hits,hits_t0,wall_hits,stalling,dist_to_spyro,dist_to_target\n")
    end
    file:write(string.format("%.5f,%.5f,%s,%s,%s,%s,%s,%s,%d,%d,%.4f,%.4f,%.4f,%.3f,%.5f,%.5f,%.3f,"
        .. "%.4f,%.4f,%.4f,%.3f,%.3f,%.3f,%.3f,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f,%s,%s,%s,%s,"
        .. "%s,%.4f,%.4f,%.4f,%.3f,%.1f,%s,%d,%d,%d,%s,%.1f,%s\n",
        r.time, r.dt, tostring(state.fpsCap or ""), e.name, e.class, f.stateName, f.stateTime or "",
        tostring(e.slide ~= nil), f.mode, f.customMode, f.x, f.y, f.z, f.yaw, f.disp, f.dz, f.speed,
        f.vx, f.vy, f.vz, f.velSpeed, f.rx, f.ry, f.reqSpeed, f.ax, f.ay, f.accelSpeed,
        f.maxWalkSpeed, f.maxAccel, f.stepHeight,
        f.floorDist and string.format("%.4f", f.floorDist) or "",
        f.floorNz and string.format("%.4f", f.floorNz) or "", tostring(f.floorWalkable),
        tostring(f.rootMotion), tostring(f.pmcActive), f.px, f.py, f.pz, f.pmcSpeed, f.pmcMaxSpeed,
        f.pmcHeading and string.format("%.2f", f.pmcHeading) or "",
        f.hits, f.hitsT0, f.wallHits, tostring(e.stall ~= nil), f.distToSpyro,
        f.distToTarget and string.format("%.1f", f.distToTarget) or ""))
end

-- The actor the current state is walking at: the cauldron for MoveToCauldron, the spawned dummy for
-- MoveToDummy. Only read for the minigame turtles, which are the only class that has them.
local function targetDistance(actor, class, stateName, loc)
    if class ~= turtle.SPAWNED then return nil end
    local target = tryCall("turtle target", function()
        if stateName == "MoveToDummy" then return actor.MyDummy end
        return actor.Cauldron
    end)
    if not (target and target:IsValid()) then return nil end
    local ok, d = pcall(function()
        local t = target:K2_GetActorLocation()
        return math.sqrt((t.X - loc.X) ^ 2 + (t.Y - loc.Y) ^ 2 + (t.Z - loc.Z) ^ 2)
    end)
    return ok and d or nil
end

local function updateActor(actor, r, dt)
    local address = actor:GetAddress()
    local loc = actor:K2_GetActorLocation()
    local distToSpyro = math.sqrt((loc.X - r.x) ^ 2 + (loc.Y - r.y) ^ 2 + (loc.Z - r.z) ^ 2)
    local e = entries[address]
    if not e or r.time < e.time then
        e = { name = actorName(actor), class = className(actor), time = r.time, slides = 0, logged = 0,
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
    -- The projectile component is the Blueprint's own variable, so only the minigame turtles have it.
    local pmc = tryCall("turtle PhasmidProjectileMovement", function() return actor.PhasmidProjectileMovement end)
    if pmc and not pmc:IsValid() then pmc = nil end
    if not dumped and e.class == turtle.SPAWNED then
        dumped = true
        dump.write("turtlecmc", dump.object(cmc))
        if pmc then dump.write("turtlepmc", dump.object(pmc)) end
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
    local maxWalkSpeed, maxAccel = num(cmc.MaxWalkSpeed), num(cmc.MaxAcceleration)
    local stateName = tryCall("turtle FalconEnemy:BP_GetCurrentStateName", function()
        return actor.FalconEnemy:BP_GetCurrentStateName():ToString()
    end) or "?"

    local pmcActive, px, py, pz, pmcSpeed, pmcMaxSpeed, pmcHeading = nil, 0, 0, 0, 0, 0, nil
    if pmc then
        pmcActive = tryCall("turtle pmc bIsActive", function() return pmc.bIsActive end)
        local pv = pmc.Velocity
        px, py, pz = num(pv.X), num(pv.Y), num(pv.Z)
        pmcSpeed = math.sqrt(px * px + py * py)
        pmcMaxSpeed = num(pmc.MaxSpeed)
        if pmcSpeed > 1 then pmcHeading = math.deg(math.atan(py, px)) end
    end

    local hits, hitsT0, wallHits = 0, 0, 0
    if list then
        hits = #list
        for _, h in ipairs(list) do
            if h.time == 0 then hitsT0 = hitsT0 + 1 end
            if math.abs(h.normal[3]) < WALL_NZ then wallHits = wallHits + 1 end
        end
    end

    e.x, e.y, e.z = loc.X, loc.Y, loc.Z
    e.prevLoc, e.time = loc, r.time
    local sliding = SLIDE_STATES[stateName] or false
    local wants = WALK_STATES[stateName] or reqSpeed > 0 or accelSpeed > 0
    local active = sliding or wants or velSpeed > 0 or disp > STILL or hits > 0

    -- One run per state, so a summary lands on every transition; the slide spans three states, so it is
    -- kept separately, from the first slide state to the first state that is not one.
    if stateName ~= e.stateName then
        endStall(e, "state")
        if e.start then
            logStart(e, e.start, "state")
            e.start = nil
        end
        logRun(e, stateName)
        if e.slide and not sliding then
            e.slide.endX, e.slide.endY, e.slide.endZ = loc.X, loc.Y, loc.Z
            logSlide(e, e.slide, stateName)
            e.slide = nil
        end
        if sliding and not e.slide then
            e.slides = e.slides + 1
            e.slide = { x = loc.X, y = loc.Y, z = loc.Z, endX = loc.X, endY = loc.Y, endZ = loc.Z,
                        frames = 0, dtSum = 0, path = 0, bounces = 0, hits = 0, hitsT0 = 0,
                        pmcMax = 0, pmcSum = 0, pmcFrames = 0, stillFrames = 0, headingTurn = 0,
                        states = {} }
        end
        if e.slide then e.slide.states[#e.slide.states + 1] = stateName end
        e.stateName = stateName
        if wants then
            e.run = { stateName = stateName, frames = 0, dtSum = 0, dist = 0, speedMax = 0, velMax = 0,
                      stalledTime = 0, stalls = 0, stillFrames = 0, hits = 0, x = loc.X, y = loc.Y }
            -- A walking state entered at a standstill is a start from rest; that is where the
            -- quantization stall lives, so time it against MaxWalkSpeed.
            if velSpeed < 1 and maxWalkSpeed > 0 then
                e.start = { stateName = stateName, frames = 0, dtSum = 0, dist = 0, stillFrames = 0,
                            target = maxWalkSpeed, t50 = nil, t90 = nil, firstMove = nil }
            end
        elseif not sliding then
            e.run = nil
        end
    end
    if not prevLoc then return active end

    local run = e.run
    if run then
        run.frames, run.dtSum = run.frames + 1, run.dtSum + dt
        run.dist = run.dist + disp
        run.speedMax = math.max(run.speedMax, disp / dt)
        run.velMax = math.max(run.velMax, velSpeed)
        run.hits = run.hits + hits
        if disp <= STILL then run.stillFrames = run.stillFrames + 1 end
    end

    local st = e.start
    if st then
        st.frames, st.dtSum = st.frames + 1, st.dtSum + dt
        st.dist = st.dist + disp
        if disp <= STILL then st.stillFrames = st.stillFrames + 1 end
        if not st.firstMove and disp > STILL then st.firstMove = st.dtSum end
        if not st.t50 and velSpeed >= 0.5 * st.target then st.t50 = st.dtSum end
        if not st.t90 and velSpeed >= 0.9 * st.target then
            st.t90 = st.dtSum
            logStart(e, st, "reached")
            e.start = nil
        elseif st.dtSum > 5 then
            logStart(e, st, "timeout")
            e.start = nil
        end
    end

    local slide = e.slide
    if slide then
        slide.frames, slide.dtSum = slide.frames + 1, slide.dtSum + dt
        slide.path = slide.path + disp
        slide.endX, slide.endY, slide.endZ = loc.X, loc.Y, loc.Z
        slide.hits, slide.hitsT0 = slide.hits + hits, slide.hitsT0 + hitsT0
        if disp <= STILL then slide.stillFrames = slide.stillFrames + 1 end
        if pmcSpeed > 0 then
            slide.pmcMax = math.max(slide.pmcMax, pmcSpeed)
            slide.pmcSum, slide.pmcFrames = slide.pmcSum + pmcSpeed, slide.pmcFrames + 1
        end
        -- A bounce shows as the velocity heading turning in one frame; wall hits are counted next to it
        -- because a deflection the component resolves within a frame leaves no heading change.
        if pmcHeading and slide.heading then
            local turned = math.abs(util.angleDiff(pmcHeading, slide.heading))
            slide.headingTurn = slide.headingTurn + turned
            if turned >= BOUNCE_ANGLE then slide.bounces = slide.bounces + 1 end
        end
        slide.heading = pmcHeading or slide.heading
    end

    local stall = e.stall
    if stall then
        stall.frames, stall.dtSum = stall.frames + 1, stall.dtSum + dt
        stall.moved = math.sqrt((loc.X - stall.x) ^ 2 + (loc.Y - stall.y) ^ 2)
        stall.velMax = math.max(stall.velMax, velSpeed)
        stall.reqMax = math.max(stall.reqMax, reqSpeed)
        stall.accelMax = math.max(stall.accelMax, accelSpeed)
        stall.hits, stall.hitsT0 = stall.hits + hits, stall.hitsT0 + hitsT0
        if disp <= STILL then stall.stillFrames = stall.stillFrames + 1 end
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
    elseif wants and disp <= STILL and WALK_STATES[stateName] then
        e.stall = { stateName = stateName, lastWant = r.time, x = loc.X, y = loc.Y, z = loc.Z,
                    frames = 1, dtSum = dt, stillFrames = 1, moved = 0, velMax = velSpeed,
                    reqMax = reqSpeed, accelMax = accelSpeed, maxWalkSpeed = maxWalkSpeed,
                    maxAccel = maxAccel, hits = hits, hitsT0 = hitsT0, normals = {} }
        if run then run.stalls = run.stalls + 1 end
    end

    if active then
        local floor = cmc.CurrentFloor
        local rot = actor:K2_GetActorRotation()
        writeRow(r, e, {
            stateName = stateName,
            stateTime = tryCall("turtle FalconEnemy:GetCurrentStateTime", function()
                return string.format("%.4f", actor.FalconEnemy:GetCurrentStateTime())
            end),
            mode = cmc.MovementMode, customMode = cmc.CustomMovementMode,
            x = loc.X, y = loc.Y, z = loc.Z, yaw = num(rot.Yaw), disp = disp, dz = dz, speed = disp / dt,
            vx = num(vel.X), vy = num(vel.Y), vz = num(vel.Z), velSpeed = velSpeed,
            rx = num(req.X), ry = num(req.Y), reqSpeed = reqSpeed,
            ax = num(acc.X), ay = num(acc.Y), accelSpeed = accelSpeed,
            maxWalkSpeed = maxWalkSpeed, maxAccel = maxAccel, stepHeight = num(cmc.MaxStepHeight),
            floorDist = floor and num(floor.FloorDist) or nil,
            floorNz = floor and num(floor.HitResult.ImpactNormal.Z) or nil,
            floorWalkable = floor and floor.bWalkableFloor or nil,
            rootMotion = tryCall("turtle IsPlayingRootMotion", function() return actor:IsPlayingRootMotion() end),
            pmcActive = pmcActive, px = px, py = py, pz = pz, pmcSpeed = pmcSpeed,
            pmcMaxSpeed = pmcMaxSpeed, pmcHeading = pmcHeading,
            hits = hits, hitsT0 = hitsT0, wallHits = wallHits,
            distToSpyro = distToSpyro, distToTarget = targetDistance(actor, e.class, stateName, loc),
        })
    end
    if list then writeHitRows(r, e, list, disp) end
    return active
end

local function update(r, prev)
    if lookupDue(lookup, r.time) then
        for class in pairs(turtle.CLASSES) do
            for _, actor in ipairs(FindAllOf(class) or {}) do add(actor) end
        end
    end
    if #actors == 0 then
        pending = {}
        return
    end
    enemyhits.register()
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

function turtle.update(r, prev)
    local ok, err = pcall(update, r, prev)
    if not ok and not errorLogged then
        errorLogged = true
        log("turtle error: %s", tostring(err))
    end
end

function turtle.onNewObject(object)
    if not turtle.CLASSES[className(object)] then return end
    local ok, err = pcall(add, object)
    if not ok and not errorLogged then
        errorLogged = true
        log("turtle error: %s", tostring(err))
    end
end

-- A level load, a respawn or a mission reset replaces them, and a hot reload starts with none known.
function turtle.pawnChanged()
    actors, entries, pending = {}, {}, {}
    lookup.lookups, lookup.nextLookup = util.NEW_OBJECT_LOOKUPS, 0
end

return turtle
