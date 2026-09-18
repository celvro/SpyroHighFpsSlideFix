-- Blocking hits during ground charges, from a hook on BP_Base_Playable's ReceiveHit (the engine calls it
-- for every blocking hit of Spyro's own moves, including step-up and slide sweeps).
--
--   hits_<stamp>.csv    one row per hit while charging on the ground: the frame's time, what was hit, the
--                       hit and impact normals, the sweep (TraceStart -> TraceEnd, Time) and penetration.
--   "chargestall" lines a ground charge frame whose speed dropped below STALL_KEEP of the last frame's
--                       (from at least STALL_MIN_SPEED): position, displacement, speeds, and the hits that
--                       arrived since the previous sample. At most STALL_LOG_MAX per charge; the CSV has all.
local log = require("lib.log")
local paths = require("lib.paths")
local state = require("lib.state")
local util = require("lib.util")

local num = util.num

local HIT_FUNCTION = "/CharacterCommon/BaseClasses/BP_Base_Playable.BP_Base_Playable_C:ReceiveHit"
local HOOK_RETRY_FRAMES = 60
local MAX_PENDING = 64
local STALL_MIN_SPEED = 30
local STALL_KEEP = 0.5
local STALL_LOG_MAX = 8

local hits = {}

local registered, failed, retryIn = false, false, 0
local pending = {}  -- hits since the last sample
local file = nil
local stallCharge, stallCount = nil, 0

local function name(object)
    local ok, s = pcall(function()
        if not (object and object:IsValid()) then return "none" end
        return object:GetFName():ToString()
    end)
    return ok and s or "?"
end

local function vec(v)
    return { num(v.X), num(v.Y), num(v.Z) }
end

local function onHit(context, myComp, other, otherComp, selfMoved, hitLocation, hitNormal, normalImpulse, hit)
    if #pending >= MAX_PENDING then return end
    local actor = context:get()
    if not (actor and actor:IsValid()) or actor:GetAddress() ~= state.pawnAddress then return end
    local h = hit:get()
    local otherActor, otherComponent = other:get(), otherComp:get()
    table.insert(pending, {
        other = name(otherActor), comp = name(otherComponent),
        normal = vec(h.Normal), impactNormal = vec(h.ImpactNormal), impactPoint = vec(h.ImpactPoint),
        location = vec(h.Location), traceStart = vec(h.TraceStart), traceEnd = vec(h.TraceEnd),
        time = num(h.Time), startPenetrating = h.bStartPenetrating, penetration = num(h.PenetrationDepth),
    })
end

function hits.register()
    if registered or failed then return end
    if retryIn > 0 then
        retryIn = retryIn - 1
        return
    end
    retryIn = HOOK_RETRY_FRAMES
    local fn = StaticFindObject(HIT_FUNCTION)
    if not (fn and fn:IsValid()) then return end
    local errorLogged = false
    local function guarded(...)
        local ok, err = pcall(onHit, ...)
        if not ok and not errorLogged then
            errorLogged = true
            log("hit hook error: %s", tostring(err))
        end
    end
    -- A Blueprint hook here only calls the pre callback (after the body), so register it as both.
    local ok, err = pcall(RegisterHook, HIT_FUNCTION, guarded, guarded)
    if ok then
        registered = true
        log("ReceiveHit hook registered")
    else
        failed = true
        log("ReceiveHit hook unavailable: %s", tostring(err))
    end
end

local function writeHits(r, list)
    if not file then
        file = io.open(string.format("%s\\hits_%s.csv", paths.modDir, paths.stamp), "w")
        if not file then return end
        file:write("time,dt,charge,x,y,z,speed,other,comp,normal_x,normal_y,normal_z,impact_nx,impact_ny,impact_nz,"
            .. "impact_x,impact_y,impact_z,loc_x,loc_y,loc_z,start_x,start_y,start_z,end_x,end_y,end_z,hit_time,start_penetrating,penetration\n")
    end
    for _, h in ipairs(list) do
        file:write(string.format("%.5f,%.5f,%s,%.3f,%.3f,%.3f,%.2f,%s,%s,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.4f,%s,%.4f\n",
            r.time, r.dt, tostring(state.charge and state.charge.id or 0), r.x, r.y, r.z, r.speed, h.other, h.comp,
            h.normal[1], h.normal[2], h.normal[3], h.impactNormal[1], h.impactNormal[2], h.impactNormal[3],
            h.impactPoint[1], h.impactPoint[2], h.impactPoint[3], h.location[1], h.location[2], h.location[3],
            h.traceStart[1], h.traceStart[2], h.traceStart[3], h.traceEnd[1], h.traceEnd[2], h.traceEnd[3],
            h.time, tostring(h.startPenetrating), h.penetration))
    end
end

local function describe(h)
    local dx, dy, dz = h.traceEnd[1] - h.traceStart[1], h.traceEnd[2] - h.traceStart[2], h.traceEnd[3] - h.traceStart[3]
    return string.format("%s/%s n=(%.3f,%.3f,%.3f) in=(%.3f,%.3f,%.3f) at=(%.2f,%.2f,%.2f) sweep=(%.3f,%.3f,%.3f)x%.3f pen=%s/%.3f",
        h.other, h.comp, h.normal[1], h.normal[2], h.normal[3], h.impactNormal[1], h.impactNormal[2], h.impactNormal[3],
        h.impactPoint[1], h.impactPoint[2], h.impactPoint[3], dx, dy, dz, h.time, tostring(h.startPenetrating), h.penetration)
end

function hits.update(r, prev)
    local list = pending
    pending = {}
    local chargeId = state.charge and state.charge.id
    if not (chargeId and r.mode == 1) then return end
    if #list > 0 then writeHits(r, list) end
    if not (prev and prev.charging and prev.speed >= STALL_MIN_SPEED and r.speed < prev.speed * STALL_KEEP) then return end
    if stallCharge ~= chargeId then stallCharge, stallCount = chargeId, 0 end
    stallCount = stallCount + 1
    if stallCount > STALL_LOG_MAX then return end
    local parts = {}
    for _, h in ipairs(list) do table.insert(parts, describe(h)) end
    log("chargestall %s.%d dt=%.2fms at=(%.3f,%.3f,%.3f) moved=(%.3f,%.3f,%.3f) speed %.1f -> %.1f yaw=%.2f floorNz=%.4f floorDist=%.3f hits=%d %s",
        tostring(chargeId), stallCount, r.dt * 1000, r.x, r.y, r.z, r.x - prev.x, r.y - prev.y, r.z - prev.z,
        prev.speed, r.speed, r.yaw, num(r.floorNz), num(r.floorDist), #list, table.concat(parts, " | "))
    if file then file:flush() end
end

return hits
