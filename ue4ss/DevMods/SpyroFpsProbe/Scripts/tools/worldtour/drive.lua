-- Moving the played character: putting him on a stop, finding the character the stop was recorded in
-- front of, and the stick and buttons each frame of a script (lib/input.lua), which walk him up to that
-- character and stop him there, or at the edge of a drop.
local ground = require("lib.ground")
local igc = require("lib.igc")
local input = require("lib.input")
local levels = require("lib.levels")
local log = require("lib.log")
local routes = require("tools.routes")

local drive = {}

local LOOK_AHEAD = 260     -- how far ahead the walk looks for ground before stepping there
local DROP_AHEAD = 180     -- a drop deeper than this ahead of him counts as an edge, not a step down
local ARRIVE = 100         -- distance to the stop target at which the walk stops (it has been reached).
                           -- 170 stopped him short of the range an NPC starts talking at, so the stops
                           -- meant to open a dialogue never opened one.
local TALK_ARRIVE = 40     -- the same for a stop that is meant to open a conversation: 100 was still
                           -- short of some NPCs (2026-09-22), so it walks on until it touches them
                           -- (BLOCKED_BY_TARGET) or the conversation opens, and this is only a floor.
local STEER_FROM = 60      -- steer at the character while further than this, so a target that stands
                           -- off the recorded line (or wanders) is still walked into, not past
local CHASE_FROM = 15      -- the same for a charge, which is steered at its target until it is on it
local BYSTANDER_RADIUS = 2500   -- enemies this near a stop, other than its target, are slowed while it plays
local BYSTANDER_DILATION = 0.05 -- to this fraction of their own speed
local LEVEL_WITH = 150     -- he and a target count as on the same level within this much height
local STAND_ABOVE = 100    -- how far above the traced ground he is put, to land on it
local BLOCKED_BY_TARGET = 300 -- but a character has collision, and he stops against it further out than
                           -- ARRIVE. Standing still this close to the one he was sent at is arriving,
                           -- not being stuck: without this he pushes into it for the whole stop and the
                           -- stop is thrown away as one where the game took input off him.
local BLOCKED_AFTER = 1.0  -- seconds of walking before that counts, so a standing start is not "blocked"
drive.LOCKED_SPEED = 5     -- below this while being told to walk, he is not walking at all

local NO_AXES = {}   -- sticks centred, reused so driving a frame allocates nothing
local STEER = { leftX = 0, leftY = 0 } -- the stick pointed at the target, reused the same way
local FORWARD = { leftY = 1 } -- the same, for the check at the start of a stop after a locked one

-- Puts the character on the stop, still, facing `yaw` (the recorded way if nil), with the camera behind
-- him. Walking follows the control rotation, so that is what decides where the script walks. Returns
-- true and where he was put, or false and why not.
function drive.place(pawn, pc, cmc, stop, yaw)
    local level, origin = levels.current(pawn)
    if level ~= stop.level or not origin then return false, "in " .. tostring(level) end
    local x, y, z = routes.place(stop, origin)
    yaw = yaw or stop.yaw
    pawn:K2_TeleportTo({ X = x, Y = y, Z = z }, { Pitch = 0, Yaw = yaw, Roll = 0 })
    cmc.Velocity = { X = 0, Y = 0, Z = 0 }
    pc:SetControlRotation({ Pitch = stop.ctrlPitch, Yaw = yaw, Roll = 0 })
    pcall(function() pawn.FollowCamera:ResetBehind(true) end)
    return true, nil, { x = x, y = y, z = z }
end

-- The yaw from the stop to the character it was recorded in front of. Characters walk about between the
-- scan and the run, and the recorded facing is the one they had then, so this is worked out fresh: without
-- it the script sometimes walked away from the target instead of into it.
function drive.yawTo(target, x, y)
    if not (target and pcall(function() return target:IsValid() end) and target:IsValid()) then return nil end
    local ok, loc = pcall(function() return target:K2_GetActorLocation() end)
    if not ok then return nil end
    local dx, dy = loc.X - x, loc.Y - y
    if dx * dx + dy * dy < 1 then return nil end
    return math.deg(math.atan(dy, dx))
end

-- The character this stop was recorded in front of (tools/scan.lua notes its class), so the walk can stop
-- when it gets there. The nearest one of that class to the stop, since a level has several of most kinds.
function drive.findTarget(pawn, stop, x, y)
    local best, bestDist
    local others = {}
    for _, actor in ipairs(FindAllOf("PhasmidCharacter") or {}) do
        local ok = pcall(function() return actor:IsValid() end) and actor:IsValid()
        if ok and actor:GetAddress() ~= pawn:GetAddress() then
            local okClass, class = pcall(function() return actor:GetClass():GetFName():ToString() end)
            if okClass then
                local loc = actor:K2_GetActorLocation()
                local dist = (loc.X - x) ^ 2 + (loc.Y - y) ^ 2
                if class == stop.note then
                    -- One that an earlier stop killed is still an actor for a while, lying where it
                    -- fell: a stop sent at it flames a corpse.
                    local okState, state = pcall(function()
                        return actor.FalconEnemy:BP_GetCurrentStateName():ToString():lower()
                    end)
                    local dead = okState and (state:find("death", 1, true) or state:find("dead", 1, true))
                    if not dead and (not bestDist or dist < bestDist) then best, bestDist = actor, dist end
                end
                if dist < BYSTANDER_RADIUS * BYSTANDER_RADIUS and (class:find("^BP_CES") or class:find("^BP_CBS")) then
                    others[#others + 1] = actor
                end
            end
        end
    end
    -- Everything hostile near the stop except the one it is aimed at.
    local bystanders = {}
    for _, actor in ipairs(others) do
        if not best or actor:GetAddress() ~= best:GetAddress() then bystanders[#bystanders + 1] = actor end
    end
    return best, bystanders
end

-- Slows the enemies around a stop to a crawl while it plays, all but its target. They are not what the
-- stop measures, and what they do to it is knock him back out of his walk-in and his script: time lost,
-- and a stop that then differs between passes by an arrow rather than by the framerate. Not stopped
-- dead: a zero time step is the kind of thing that turns a velocity into a NaN (gem-thief-anim.md).
-- Each actor is IsValid-checked again before it is touched (CLAUDE.md), here and in thaw.
function drive.freeze(bystanders)
    local frozen = {}
    for _, actor in ipairs(bystanders or {}) do
        if actor:IsValid() then
            local ok, was = pcall(function() return actor.CustomTimeDilation end)
            if ok and type(was) == "number" and pcall(function() actor.CustomTimeDilation = BYSTANDER_DILATION end) then
                frozen[#frozen + 1] = { actor = actor, was = was }
            end
        end
    end
    return frozen
end

function drive.thaw(frozen)
    for _, entry in ipairs(frozen or {}) do
        if entry.actor:IsValid() then pcall(function() entry.actor.CustomTimeDilation = entry.was end) end
    end
end

-- A place to stand `reach` from the target, on ground at the target's own height, facing it: the side
-- he is on first, then round the target either way. Nil when there is none (a flyer, a perch too small
-- to share). The ground half way in is checked too, so the spot is not across a gap from it.
local AROUND = { 0, 45, -45, 90, -90, 135, -135, 180 }
function drive.spotBeside(pawn, target, r, reach)
    local ok, loc = pcall(function() return target:K2_GetActorLocation() end)
    if not ok then return nil end
    local base = math.atan(r.y - loc.Y, r.x - loc.X)
    for _, turn in ipairs(AROUND) do
        local angle = base + math.rad(turn)
        local cx, cy = math.cos(angle), math.sin(angle)
        local x, y = loc.X + cx * reach, loc.Y + cy * reach
        local z = ground.zAt(pawn, x, y, loc.Z, LEVEL_WITH, LEVEL_WITH)
        local mid = z and ground.zAt(pawn, loc.X + cx * reach / 2, loc.Y + cy * reach / 2, loc.Z, LEVEL_WITH, LEVEL_WITH)
        if z and mid then
            return { x = x, y = y, z = z + STAND_ABOVE, yaw = math.deg(math.atan(-cy, -cx)) }
        end
    end
    return nil
end

-- Is he standing at the target's height, near enough for a flame or a charge along the ground to meet it?
function drive.levelWith(target, r)
    local ok, loc = pcall(function() return target:K2_GetActorLocation() end)
    return ok and math.abs(loc.Z - r.z) <= LEVEL_WITH
end

-- How far the character is from this stop's target, or nil when there isn't one any more.
function drive.targetDistance(run, r)
    local target = run.target
    if not (target and pcall(function() return target:IsValid() end) and target:IsValid()) then return nil end
    local ok, loc = pcall(function() return target:K2_GetActorLocation() end)
    if not ok then return nil end
    return math.sqrt((loc.X - r.x) ^ 2 + (loc.Y - r.y) ^ 2)
end

-- Is he about to walk over an edge? Traces down a step ahead of him, along the way he is facing. Chasing
-- a character that runs off towards water walked him in after it, and pulling him back after the fall had
-- already started was too late (LS104's thief drowned twice, 2026-09-20).
local function atEdge(pawn, r)
    if r.mode ~= 1 and r.mode ~= 2 then return false end -- only while walking
    local rad = math.rad(r.yaw)
    local x, y = r.x + math.cos(rad) * LOOK_AHEAD, r.y + math.sin(rad) * LOOK_AHEAD
    return ground.zAt(pawn, x, y, r.z, 50, DROP_AHEAD) == nil
end

-- The stick pointed at the stop target, from where the camera faces: what a player does to walk up to
-- somebody. Only for a phase that walks straight ahead, and only while the target is further than
-- STEER_FROM; returns nil otherwise and the phase's own stick is used.
local function steerAt(run, pc, phase, r, distance, chase)
    local axes = phase.axes
    if not (axes and (axes.leftY or 0) > 0 and (axes.leftX or 0) == 0) then return nil end
    if not (distance and distance > (chase and CHASE_FROM or STEER_FROM)) then return nil end
    local ok, loc = pcall(function() return run.target:K2_GetActorLocation() end)
    if not ok then return nil end
    local okYaw, yaw = pcall(function() return pc:GetControlRotation().Yaw end)
    if not okYaw then return nil end
    local d = math.rad(math.deg(math.atan(loc.Y - r.y, loc.X - r.x)) - yaw)
    STEER.leftY, STEER.leftX = math.cos(d) * axes.leftY, math.sin(d) * axes.leftY
    return STEER
end

-- Sends the phase's input for this frame (held sticks and buttons, and the taps of a dialogue phase).
-- Walking stops once the target is reached (the point is to meet the character) and at the edge of a
-- drop, and from then on he stands still for the rest of the stop.
function drive.frame(run, pawn, pc, phase, into, r)
    local stop = run.step.entry.stop
    local distance = drive.targetDistance(run, r)
    -- Walking into a character stops against its collision, which can be further out than ARRIVE: he
    -- never gets to the distance that counts as arrived, so he is left pushing into it for the whole
    -- stop and read as "cannot move". Standing still this close to what he was sent at IS arriving.
    local blocked = not run.arrived and distance and distance <= BLOCKED_BY_TARGET
        and (r.speed or 0) < drive.LOCKED_SPEED and run.elapsed > BLOCKED_AFTER
    -- A conversation stop walks until it touches the character or the conversation opens: stopping
    -- at ARRIVE left some NPCs just out of talking range.
    -- A charge at a character is steered at it for the whole script: the charge is what is being
    -- measured, and one that lets go of the stick 100 units out, or after the first bump, runs past a
    -- target that stepped aside. Only a drop ahead still stops it.
    local chase = distance and stop.script:find("^charge") ~= nil
    if chase then blocked = false end
    -- An edge ends a walk for good. It only pauses a charge that is chasing something, and not even
    -- that while the target is nearer than the look-ahead: then the target is on this side of the
    -- drop, and letting go of the stick there is what made a charge run past a Cowlek 77 units off.
    local edgeAhead = (chase or not run.arrived) and atEdge(pawn, r)
    local edge = edgeAhead and not chase
    local pause = edgeAhead and chase and distance > LOOK_AHEAD
    local talks = stop.script == "enterPlay"
    local reached = not chase and distance and distance <= (talks and TALK_ARRIVE or ARRIVE)
    local talking = talks and igc.active(stop.level)
    local arrived = run.arrived or edge or blocked or reached or talking
    if arrived and not run.arrived then
        run.arrived = run.elapsed
        log("autotest: %s after %.1f s, no more walking for the rest of the stop",
            edge and "stopped at the edge of a drop" or
            talking and not (blocked or reached) and ("in conversation with " .. stop.note) or
            ((blocked and "up against " or "reached ") .. stop.note), run.elapsed)
    end
    -- Reaching the character (or a drop) lets go of the sticks, but the script's buttons carry on: a
    -- dialogue or minigame script has to keep tapping once it is standing in front of whoever starts it,
    -- and a flame or a jump is meant to happen where he ends up.
    input.hold((arrived or pause) and NO_AXES or steerAt(run, pc, phase, r, distance, chase) or phase.axes)
    -- Being told to walk and not walking means the game has taken input away: a conversation that never
    -- closed is the usual one (a Spyro 2 NPC holds him until the dialogue is dismissed, and every stop
    -- after that records a Spyro who cannot move). Count the time it has been asked and refused.
    local walking = not arrived and phase.axes and (phase.axes.leftY or phase.axes.leftX)
    if walking and (r.speed or 0) < drive.LOCKED_SPEED then
        run.lockedFor = (run.lockedFor or 0) + r.dt
    elseif walking then
        run.lockedFor = 0
        run.everMoved = true
    end
    local wanted = {}
    for _, button in ipairs(phase.hold or {}) do wanted[button] = true end
    local tap = phase.tap
    if tap then
        wanted[tap.button] = (into % tap.period) < (tap.width or tap.period / 2)
    end
    for button in pairs(input.BUTTONS) do
        if wanted[button] then input.press(button) else input.release(button) end
    end
    input.apply(pawn, pc)
end

-- Walks at the stop's target with every button up, for play.lua's approach. False when he should not
-- take another step: the target is gone, or the ground ahead is a drop.
local WALK = { axes = { leftY = 1 } }
function drive.walkAt(run, pawn, pc, r)
    local distance = drive.targetDistance(run, r)
    if not distance or atEdge(pawn, r) then return false end
    input.hold(steerAt(run, pc, WALK, r, distance) or WALK.axes)
    for name in pairs(input.BUTTONS) do input.release(name) end
    input.apply(pawn, pc)
    return true
end

-- The stick held forward and every button up: the check for whether he can move at all.
function drive.forward(pawn, pc)
    input.hold(FORWARD)
    for name in pairs(input.BUTTONS) do input.release(name) end
    input.apply(pawn, pc)
end

return drive
