-- Super charges.
--
--   "supercharge" lines  each super charge (Character.MoveState.SuperCharging tag): stage change times,
--                        speed thresholds (t<speed>) next to the ideal MaxAcceleration-per-second ramp and
--                        air time, then one "supercharge N stage S" line per stage with speed, friction,
--                        acceleration and camera averages (distance, height, pitch, FOV, yaw offset,
--                        m_ctrInterp, m_radDefault).
-- The stage also goes on each row (sc_stage), which the airborne "seg" and "turn" lines report.
local log = require("lib.log")
local state = require("lib.state")
local trace = require("lib.trace")
local util = require("lib.util")

local num, isGrounded, tryCall = util.num, util.isGrounded, util.tryCall
local newStats, addFrame, avgFps = util.newStats, util.addFrame, util.avgFps

local SUPERCHARGE_TAG = "Character.MoveState.SuperCharging"
local SUPERCHARGE_STAGE_TAGS = { -- GA_Spyro_Charge's SuperChargeLevel for each stage effect's tag
    { 3, "Character.MoveState.SuperCharging.StageThree" },
    { 2, "Character.MoveState.SuperCharging.StageTwo" },
    { 1, "Character.MoveState.SuperCharging.StageOne" },
    { -1, "Character.MoveState.SuperCharging.StageAlt" },
}
-- t<speed> thresholds, just under the stage 0-2 (750) and stage 3 (1025) MaxWalkSpeed so rounding still reaches them.
local SUPERCHARGE_SPEEDS = { 550, 650, 745, 850, 950, 1020 }
local SUPERCHARGE_BASE_WALK_SPEED = 750   -- GE_Spyro_Movement_SuperCharging_S0-S2 (Alt: 850)
local SUPERCHARGE_STAGE3_WALK_SPEED = 1025 -- GE_Spyro_Movement_SuperCharging_S3

local supercharge = {}

local asc = nil -- { pawn = address, component = AbilitySystemComponent }

local function finish(r)
    local sc = state.superCharge
    state.superCharge = nil
    local stages = {}
    for _, s in ipairs(sc.stageOrder) do stages[#stages + 1] = string.format("%d@%.3f", s.stage, s.at) end
    local speeds = {}
    for _, thr in ipairs(SUPERCHARGE_SPEEDS) do
        local t = sc.tSpeed[thr]
        if t then
            -- Ideal: speed grows by MaxAcceleration per second from the start (or from stage 3 above 750).
            local ideal
            if not (sc.accel and sc.accel > 0) then
                ideal = nil
            elseif thr <= SUPERCHARGE_BASE_WALK_SPEED then
                ideal = sc.startSpeed < thr and (thr - sc.startSpeed) / sc.accel or nil
            elseif sc.fastAt then
                ideal = sc.fastAt + math.max(thr - sc.fastSpeed, 0) / sc.accel
            end
            speeds[#speeds + 1] = string.format("t%d=%.3fs(ideal %s)", thr, t, ideal and string.format("%.3f", ideal) or "n/a")
        end
    end
    log("supercharge %d cap=%s avgFps=%.1f dt=%.1f-%.1fms dur=%.3fs startSpeed=%.1f attrDelay=%s stage3SpeedAt=%s speedMax=%.1f air=%.3fs airSegments=%d stages=%s %s detectedBy=%s",
        sc.id, tostring(state.fpsCap or "?"), avgFps(sc), sc.dtMin * 1000, sc.dtMax * 1000, r.time - sc.origin,
        sc.startSpeed, sc.attrDelay and string.format("%.3fs", sc.attrDelay) or "n/a",
        sc.fastAt and string.format("%.3fs", sc.fastAt) or "n/a",
        sc.maxSpeed, sc.airTime, sc.airSegments, table.concat(stages, ","), table.concat(speeds, " "), sc.detectedBy)
    for _, entry in ipairs(sc.stageOrder) do
        local st = sc.stats[entry.stage]
        local g = st.groundTime
        local function avg(key) return g > 0 and st[key] / g or 0 / 0 end
        log("supercharge %d stage %d: time=%.3fs grounded=%.3fs speedAvg=%.1f speedMax=%.1f accelObserved=%s groundFriction=%.2f maxAccel=%.0f maxWalkSpeed=%.0f camDist=%.1f camHeight=%.1f camPitch=%.2f camFov=%.2f camOffsetAbs=%.1f ctrInterp=%.3f radDefault=%.1f",
            sc.id, entry.stage, st.time, g, avg("speed"), st.maxSpeed,
            -- Speed gained per second on grounded frames below MaxWalkSpeed (compare with maxAccel).
            st.accelTime > 0 and string.format("%.1f", st.accelGain / st.accelTime) or "n/a",
            avg("friction"), avg("maxAccel"), avg("maxWalk"), avg("camDist"), avg("camHeight"), avg("camPitch"),
            avg("camFov"), avg("camOffset"), avg("ctrInterp"), avg("radDefault"))
    end
    trace.flush()
end

-- One super charge, from the first frame with a super charge stage until it ends.
function supercharge.update(r, prev)
    local sc = state.superCharge
    if r.superStage == nil then
        if sc then finish(r) end
        return
    end
    if not sc then
        state.superChargeCount = state.superChargeCount + 1
        local start = prev or r -- as for t400: this frame already moved with the super charge attributes
        sc = newStats(r)
        sc.id, sc.origin, sc.startSpeed, sc.maxSpeed, sc.detectedBy = state.superChargeCount, start.time, start.speed, r.speed, r.superDetectedBy
        sc.stageOrder, sc.stats, sc.tSpeed, sc.airTime, sc.airSegments = {}, {}, {}, 0, 0
        state.superCharge = sc
    end
    local elapsed = r.time - sc.origin
    -- Speed timing starts at the last frame before the super charge MaxWalkSpeed, which may lag the tag.
    if not sc.accel and num(r.maxWalkSpeed) >= SUPERCHARGE_BASE_WALK_SPEED - 1 then
        local start = (prev and prev.time < r.time) and prev or r
        sc.accel, sc.speedOrigin, sc.startSpeed = num(r.maxAccel), start.time, start.speed
        sc.attrDelay = start.time - sc.origin
    end
    local stage = r.superStage
    local st = sc.stats[stage]
    if not st then
        st = { time = 0, groundTime = 0, maxSpeed = 0, speed = 0, friction = 0, maxAccel = 0, maxWalk = 0, camDist = 0,
               camHeight = 0, camPitch = 0, camFov = 0, camOffset = 0, ctrInterp = 0, radDefault = 0, accelGain = 0, accelTime = 0 }
        sc.stats[stage] = st
        sc.stageOrder[#sc.stageOrder + 1] = { stage = stage, at = elapsed }
    end
    if sc.speedOrigin and not sc.fastAt and num(r.maxWalkSpeed) >= SUPERCHARGE_STAGE3_WALK_SPEED - 1 then
        local start = (prev and prev.time < r.time) and prev or r
        sc.fastAt, sc.fastSpeed = start.time - sc.speedOrigin, start.speed
    end
    if not prev or prev.time >= r.time then return end
    local step = r.time - prev.time
    addFrame(sc, r)
    sc.maxSpeed = math.max(sc.maxSpeed, r.speed)
    st.time = st.time + step
    st.maxSpeed = math.max(st.maxSpeed, r.speed)
    if not isGrounded(r.mode) then
        sc.airTime = sc.airTime + step
        if isGrounded(prev.mode) then sc.airSegments = sc.airSegments + 1 end
    else
        st.groundTime = st.groundTime + step
        local function add(key, v) if v == v then st[key] = st[key] + v * step end end -- skips NaN
        add("speed", r.speed)
        add("friction", num(r.groundFriction))
        add("maxAccel", num(r.maxAccel))
        add("maxWalk", num(r.maxWalkSpeed))
        add("camDist", r.camDist)
        add("camHeight", r.camHeight)
        add("camPitch", r.camPitch)
        add("camFov", r.camFov)
        add("camOffset", math.abs(r.camOffset))
        add("ctrInterp", r.camCtrInterp)
        add("radDefault", r.camRadDefault)
        if isGrounded(prev.mode) and prev.speed < num(r.maxWalkSpeed) - 1 and r.speed < num(r.maxWalkSpeed) - 1 then
            st.accelGain = st.accelGain + (r.speed - prev.speed)
            st.accelTime = st.accelTime + step
        end
    end
    for _, thr in ipairs(SUPERCHARGE_SPEEDS) do
        if sc.speedOrigin and not sc.tSpeed[thr] and r.speed >= thr and prev.speed < thr then
            local f = (thr - prev.speed) / (r.speed - prev.speed)
            sc.tSpeed[thr] = prev.time + step * f - sc.speedOrigin
        end
    end
end

-- The super charge stage (-1 Alt, 0-3) or nil when not super charging, and how it was detected.
-- Prefers the gameplay tags GA_Spyro_Charge applies; falls back on the movement attributes of
-- GE_Spyro_Movement_SuperCharging_S0-S3 / _Alt (stages 0-2 share them, so those read as 0).
function supercharge.stage(pawn, r)
    local component = tryCall("GetAbilitySystemComponent", function()
        local address = pawn:GetAddress()
        if asc and asc.pawn == address and asc.component:IsValid() then return asc.component end
        local lib = StaticFindObject("/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary")
        local found = lib:GetAbilitySystemComponent(pawn)
        if not (found and found:IsValid()) then error("no AbilitySystemComponent") end
        asc = { pawn = address, component = found }
        return found
    end)
    if component then
        local stage = tryCall("HasMatchingGameplayTag", function()
            local function has(tag)
                local v = component:HasMatchingGameplayTag({ TagName = FName(tag) })
                if type(v) ~= "boolean" then error("returned " .. tostring(v)) end
                return v
            end
            if not has(SUPERCHARGE_TAG) then return false end
            for _, entry in ipairs(SUPERCHARGE_STAGE_TAGS) do
                if has(entry[2]) then return entry[1] end
            end
            return 0
        end)
        if stage ~= nil then return stage ~= false and stage or nil, "tag" end
    end
    local accel, walk = num(r.maxAccel), num(r.maxWalkSpeed)
    if accel == 150 and walk >= SUPERCHARGE_BASE_WALK_SPEED then return walk >= SUPERCHARGE_STAGE3_WALK_SPEED - 1 and 3 or 0, "attributes" end
    if accel == 500 and walk == 850 then return -1, "attributes" end
    local prev = state.prevRow
    -- Jumps swap the movement effect; stay in the super charge until he lands.
    if prev and prev.superStage and not isGrounded(r.mode) then return prev.superStage, "attributes" end
    return nil, "attributes"
end

return supercharge
