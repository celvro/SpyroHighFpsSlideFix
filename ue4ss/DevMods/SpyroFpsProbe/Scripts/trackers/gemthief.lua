-- Artisans gem thief (BP_CES1012_GemThief): reported running away in his idle animation at 320 FPS,
-- but only when VSync was already on while the level loaded (30 FPS with VSync, or VSync switched on
-- after the load, both animate).
--
-- His Flee state (FalconEnemyState_Flee, EFalconMovementMode::FleeFromPlayer) is the one state with no
-- Montage, so while fleeing his pose comes only from the anim Blueprint's blendspace
-- (BS_CES1195_GemThiefNew_Locomotion). Its X is ABP_CES1195_GemThiefNew_C's Speed, which
-- BlueprintUpdateAnimation sets to Lerp(Speed, VSize2D(GetVelocity()), DeltaTime * 4). So the pose
-- sticks at the idle sample if either the anim Blueprint stops updating (mesh anim tick, URO, paused
-- anims) or GetVelocity reads ~0 while the flee moves him. This reads both sides every frame.
--
--   "gemthief" lines   one per state change and every LOG_INTERVAL while a thief exists: the state, the
--                      movement mode, the component velocity, the ABP's Speed and Direction, the X that
--                      reached the blendspace node, the DeltaTime the ABP last saw (animDt: stale or 0
--                      means BlueprintUpdateAnimation isn't running), the blendspace it points at, and
--                      everything that can stop a mesh animating (lib/anim.diagnose).
--   "gemthief nan"     the ABP Speed is not a number. Measured 2026-09-27 16:47 in LS101 at 320 FPS: both
--                      thieves ran with animSpeed and bsX at -nan(ind) while vel read 296-405 and animDt a
--                      normal 0.0031, every mesh flag nominal. Speed feeds back into its own Lerp, so one
--                      bad frame (NaN, or an inf that becomes inf-inf the next frame) sticks for the level.
--   "gemthief poisoned" the frame Speed stopped being finite, with the values it had just before.
--   "gemthief healed"  HEAL wrote the live speed back over a NaN, which is the fix to try: the Lerp
--                      converges normally from any finite value. Only counted when the velocity itself
--                      was finite, since writing a NaN over a NaN achieves nothing.
--   "gemthief stalepose" one per stretch of running in the idle pose, with the framerate cap, how long it
--                      lasted, how many of those frames had a montage playing, the X it was frozen at and
--                      the Speed the Blueprint had reached meanwhile. This is the per-chase bug (B), not
--                      the permanent NaN one (A).
--   "gemthief verdict" VERDICT_WINDOW seconds after a heal: HELD (he ran, nothing went non-finite and the
--                      blendspace X kept up), BROKE, or INCONCLUSIVE when he never ran in the window.
--   "gemthief moving-idle" the thief is moving (velocity over MOVING_SPEED) while the
--                      blendspace X is under IDLE_SPEED, i.e. the pose the game shows is the idle one.
local anim = require("lib.anim")
local state_lib = require("lib.state")
local log = require("lib.log")
local util = require("lib.util")

local num = util.num

local gemthief = { CLASSES = { BP_CES1012_GemThief_C = true, BP_CES1195_GemThiefNew_C = true } }

local LOG_INTERVAL = 1      -- seconds between "gemthief" lines for one thief
local GRACE = 1.0           -- seconds to leave a newly constructed thief alone before reading him
local MOVING_SPEED = 40     -- horizontal speed that counts as running
local IDLE_SPEED = 5        -- blendspace X below which the pose is the idle sample
local BLENDSPACE_X = "AnimGraphNode_BlendSpacePlayer_581DD95C4C6817BE6F6AA08BA69716AC"
local HEAL = true           -- write the live speed over a NaN Speed, to see the animation come back

local VERDICT_WINDOW = 5    -- seconds watched after a heal, to say whether it held
local POISON_HOLD = 5       -- seconds the T test holds the heal back, so the broken pose is visible
local MIN_STALE = 0.05      -- shorter idle-pose stretches are single frames of blend and not worth a line
local NAN = 0 / 0

local entries = {}          -- address -> { actor, name, state, nextLog, warned, finite, verdict }
local pending = {}          -- PhasmidCharacters reported by NotifyOnNewObject, resolved on a later frame
local running = true        -- on by default; Y turns it (and the level-wide sweep) off and on again
local poisonRequest = false -- T asks for the NaN to be injected (see gemthief.poison)
local errorLogged = false

local function get(fn, ...)
    local ok, value = pcall(fn, ...)
    if ok then return value end
    return nil
end

-- A NaN compares false against everything, so every test here goes through this.
local function finiteNumber(v)
    return type(v) == "number" and v == v and v > -math.huge and v < math.huge
end

-- Fed by main.lua's /Script/Phasmid.PhasmidCharacter notification, the same way trackers/stalls.lua
-- learns about characters, rather than calling FindAllOf for these class names on a timer (CLAUDE.md:
-- never poll for something that may not exist). The startup crashes during this investigation were
-- **not** from that polling, as first suspected — they were two unrelated pak mods in
-- `Content/Paks/~mods` and went away when those were removed (docs/probe.md).
function gemthief.onNewObject(object)
    pending[#pending + 1] = object
end

local function resolve(time)
    for i = #pending, 1, -1 do
        local actor = pending[i]
        pending[i] = nil
        if actor:IsValid() then
            local class = get(function() return actor:GetClass():GetFName():ToString() end)
            local name = class and gemthief.CLASSES[class]
                and get(function() return actor:GetFName():ToString() end)
            local address = name and actor:GetAddress()
            if address and not entries[address] and not name:match("^Default__") then
                -- Nothing is read until he has been alive for GRACE: an actor the engine is still
                -- building is what the startup crashes looked like.
                entries[address] = { actor = actor, name = name, nextLog = 0, readyAt = time + GRACE }
            end
        end
    end
end

-- Y, together with the level-wide sweep in trackers/nanspeed.lua. This one starts on: it only reads two
-- actors in one level.
function gemthief.toggle()
    running = not running
    local n = 0
    for _ in pairs(entries) do n = n + 1 end
    log("gemthief %s (%d thief/thieves known)", running and "on" or "off", n)
end

-- T. The real poisoning needs a world that has been alive for hours (see the header), so this puts the
-- NaN into the anim Blueprint by hand and holds the heal back for POISON_HOLD seconds: he should run in
-- his idle pose for those seconds, then animate again when the heal lands, and the verdict line says so.
function gemthief.poison()
    poisonRequest = true
end

function gemthief.pawnChanged()
    entries = {}
end

local function stateName(actor)
    local component = get(function() return actor.FalconEnemy end)
    if not component or not component:IsValid() then return "?" end
    local name = get(function() return component:BP_GetCurrentStateName():ToString() end)
    return name or "?"
end

local function sample(e, r)
    local actor = e.actor
    local cmc = get(function() return actor.CharacterMovement end)
    local velocity = cmc and cmc:IsValid() and get(function() return cmc.Velocity end)
    local speed = velocity and math.sqrt(velocity.X * velocity.X + velocity.Y * velocity.Y) or -1
    local mode = cmc and cmc:IsValid() and get(function() return cmc.MovementMode end) or -1
    local instance = anim.instance(actor)
    local animSpeed = instance and get(function() return instance.Speed end)
    local animDt = instance and get(function() return instance.Time end)
    local blendX = instance and get(function() return instance[BLENDSPACE_X].X end)
    local blendspace = instance and get(function()
        local bs = instance.LocomotionBlendspace
        return bs:IsValid() and bs:GetFName():ToString() or "none"
    end)
    local mesh = anim.mesh(actor)
    local lastRender = mesh and get(function() return mesh.LastRenderTime end)
    local state = stateName(actor)

    -- The pose the game is showing comes from blendX (Speed reaches the node through
    -- EvaluateGraphExposedInputs), so that is what decides whether he looks idle. A NaN blendspace X
    -- reads as the idle sample, and a NaN compares false against everything, so test for it first.
    local finite = finiteNumber(animSpeed)
    local shown = blendX or animSpeed
    local movingIdle = (not finite) or (speed > MOVING_SPEED and shown ~= nil and shown < IDLE_SPEED)

    -- The frame it went bad, with the last good values: the only chance to see where it comes from.
    if not finite and e.finite then
        log("gemthief poisoned %s state=%s mode=%s vel=%s animSpeed=%s prevSpeed=%s animDt=%s prevDt=%s time=%s",
            e.name, state, util.MOVE_MODE_NAMES[mode] or tostring(mode), num(speed), num(animSpeed),
            num(e.prevSpeed), num(animDt), num(e.prevDt), num(r.time))
    end
    e.finite, e.prevSpeed, e.prevDt = finite, animSpeed, animDt

    if HEAL and not finite and instance and r.time >= (e.healHoldUntil or 0) then
        -- Speed is its own Lerp's input, so a finite value is all it needs to converge again. On the
        -- poisoned frame the velocity is NaN too, and writing a NaN over a NaN achieves nothing, so this
        -- only counts as a heal once a finite value actually went in.
        local wrote = finiteNumber(speed) and pcall(function() instance.Speed = speed end)
        -- Rate limited: if a write ever failed to stick, this would otherwise log 320 times a second.
        if wrote and r.time >= (e.nextHealLog or 0) then
            e.nextHealLog = r.time + LOG_INTERVAL
            log("gemthief healed %s wrote Speed=%s over %s (watching %ds)",
                e.name, num(speed), num(animSpeed), VERDICT_WINDOW)
            -- Does it hold? Counted every frame until the window closes, then one verdict line.
            -- startsAt skips the frame the write happened on: animSpeed and blendX in this sample were
            -- read before it, so counting them would always report one NaN frame and call it broken.
            e.verdict = { startsAt = r.time, endsAt = r.time + VERDICT_WINDOW, frames = 0, moving = 0,
                          idleWhileMoving = 0, nanFrames = 0, maxVel = 0, maxShown = 0 }
        end
    end

    -- Bug B, the one that comes back on every fresh chase: while a montage owns the DefaultSlot the node
    -- has bAlwaysUpdateSourcePose = False, so the blendspace under it is not updated and its X keeps the
    -- value it had when he was standing still. He then runs in the idle pose until the montage releases.
    -- One line per stretch, with the framerate cap, so 30 and 320 can be compared directly.
    local poseStale = finiteNumber(speed) and speed > MOVING_SPEED
        and (not finiteNumber(shown) or shown < IDLE_SPEED)
    if poseStale then
        local s = e.stale
        if not s then
            s = { start = r.time, frames = 0, maxVel = 0, bsX = shown, montageFrames = 0, animSpeedMax = 0 }
            e.stale = s
        end
        s.frames = s.frames + 1
        s.endsAt = r.time
        s.state = state
        if speed > s.maxVel then s.maxVel = speed end
        if finiteNumber(animSpeed) and animSpeed > s.animSpeedMax then s.animSpeedMax = animSpeed end
        if get(function() return instance:IsAnyMontagePlaying() end) then
            s.montageFrames = s.montageFrames + 1
        end
    elseif e.stale then
        local s = e.stale
        e.stale = nil
        if (s.endsAt or r.time) - s.start >= MIN_STALE then
        log("gemthief stalepose %s state=%s cap=%s dur=%.3fs frames=%d montageFrames=%d frozenAt=%s "
            .. "animSpeedReached=%s maxVel=%s nowBsX=%s",
            e.name, tostring(s.state), tostring(state_lib.fpsCap or "?"), (s.endsAt or r.time) - s.start,
            s.frames, s.montageFrames, num(s.bsX), num(s.animSpeedMax), num(s.maxVel), num(shown))
        end
    end

    local v = e.verdict
    if v and r.time > v.startsAt then
        v.frames = v.frames + 1
        if not finite then v.nanFrames = v.nanFrames + 1 end
        if finiteNumber(speed) and speed > v.maxVel then v.maxVel = speed end
        if finiteNumber(shown) and shown > v.maxShown then v.maxShown = shown end
        if finiteNumber(speed) and speed > MOVING_SPEED then
            v.moving = v.moving + 1
            if not (finiteNumber(shown) and shown >= IDLE_SPEED) then
                v.idleWhileMoving = v.idleWhileMoving + 1
            end
        end
        if r.time >= v.endsAt then
            e.verdict = nil
            local held = v.nanFrames == 0 and v.moving > 0 and v.idleWhileMoving == 0
            log("gemthief verdict %s %s frames=%d moving=%d idleWhileMoving=%d nanFrames=%d maxVel=%s maxBlendX=%s",
                e.name, held and "HELD" or (v.moving == 0 and "INCONCLUSIVE (he never ran)" or "BROKE"),
                v.frames, v.moving, v.idleWhileMoving, v.nanFrames, num(v.maxVel), num(v.maxShown))
        end
    end
    -- The first bad frame is worth a line of its own; after that the once-a-second line carries it, so a
    -- thief stuck for a whole level doesn't write 320 lines a second.
    local firstBad = movingIdle and not e.warned
    e.warned = movingIdle
    if not (firstBad or state ~= e.state or r.time >= e.nextLog) then return end
    e.state = state
    e.nextLog = r.time + LOG_INTERVAL

    local line = string.format(
        "gemthief %s state=%s mode=%s vel=%s animSpeed=%s bsX=%s animDt=%s blendspace=%s lastRender=%s time=%s %s",
        e.name, state, util.MOVE_MODE_NAMES[mode] or tostring(mode), num(speed), num(animSpeed),
        num(blendX), animDt and string.format("%.4f", animDt) or "?", tostring(blendspace),
        num(lastRender), num(r.time), anim.diagnose(actor, instance, nil))
    if not finite then
        log("gemthief nan %s", line)
    elseif movingIdle then
        log("gemthief moving-idle %s", line)
    else
        log("%s", line)
    end
end

function gemthief.update(r)
    if errorLogged then return end
    local ok, err = pcall(function()
        resolve(r.time)
        if not running then return end
        local poison = poisonRequest
        poisonRequest = false
        for address, e in pairs(entries) do
            if not e.actor:IsValid() then
                entries[address] = nil
            elseif r.time >= e.readyAt then
                if poison then
                    local instance = anim.instance(e.actor)
                    local wrote = instance and pcall(function() instance.Speed = NAN end)
                    e.healHoldUntil = r.time + POISON_HOLD
                    log("gemthief poison-test %s %s, heal held %ds", e.name,
                        wrote and "Speed set to NaN" or "could not write Speed", POISON_HOLD)
                end
                sample(e, r)
            end
        end
    end)
    if not ok then
        errorLogged = true
        log("gemthief error: %s", tostring(err))
    end
end

return gemthief
